import Foundation
import Testing
@testable import LumenHearing
@testable import LumenHearingFluid

/// Live check against a real Frigate (UAT only, never production). Opt-in:
///
///     LUMEN_HEARING_UAT=http://10.9.8.209:5000 \
///     LUMEN_HEARING_UAT_CAMERA=speech_test \
///     LUMEN_HEARING_MODELS_DIR=/Volumes/.../models LUMEN_HEARING_PARAKEET=1 swift test --filter UATTests
///
/// It reads ended `speech` events, downloads each clip.mp4 the same way the Hub
/// does (GET /api/events/<id>/clip.mp4), and scores every engine against the
/// sentences the UAT test camera plays (macOS `say`, see the Lumen findings doc).
/// Read-only on Frigate: it never calls a write endpoint.
@Suite(.serialized) struct UATTests {
    static let env = ProcessInfo.processInfo.environment
    static var base: URL? { env["LUMEN_HEARING_UAT"].flatMap(URL.init(string:)) }
    static var camera: String { env["LUMEN_HEARING_UAT_CAMERA"] ?? "speech_test" }

    /// What the UAT camera says, in a loop.
    static let truth: [HearingLanguage: String] = [
        .english: "Hello, this is a delivery for Kevin. I left the package next to the front door. Please call me back if anything is missing.",
        .french: "Bonjour, c'est le facteur. J'ai un colis pour vous, je le laisse devant la porte du garage. Bonne journée.",
    ]

    struct RawEvent: Decodable {
        let id: String
        let camera: String
        let label: String
        let start_time: Double
        let end_time: Double?
    }

    static func endedSpeechEvents(limit: Int = 6) async throws -> [SpeechEvent] {
        let base = try #require(base)
        var components = URLComponents(url: base.appendingPathComponent("api/events"), resolvingAgainstBaseURL: false)!
        components.queryItems = [.init(name: "label", value: "speech"), .init(name: "cameras", value: camera),
                                 .init(name: "limit", value: String(limit))]
        let (data, response) = try await URLSession.shared.data(from: components.url!)
        #expect((response as? HTTPURLResponse)?.statusCode == 200)
        return try JSONDecoder().decode([RawEvent].self, from: data).compactMap { e in
            // Like the Hub's settle delay: Frigate saves the recording a bit after the end.
            guard e.label == "speech", let end = e.end_time, Date().timeIntervalSince1970 - end > 45 else { return nil }
            return SpeechEvent(id: e.id, camera: e.camera, start: Date(timeIntervalSince1970: e.start_time),
                               end: Date(timeIntervalSince1970: end))
        }
    }

    /// Same request the Hub's `BridgeFrigateAccess.eventClip` makes.
    struct ClipSource: SpeechAudioSource {
        let base: URL
        func audio(for event: SpeechEvent) async throws -> PCMAudio {
            let url = base.appendingPathComponent("api/events/\(event.id)/clip.mp4")
            let (file, response) = try await URLSession.shared.download(from: url)
            let http = try #require(response as? HTTPURLResponse)
            guard http.statusCode == 200 else {
                throw [400, 404].contains(http.statusCode) ? HearingError.clipNotReady : HearingError.decodeFailed
            }
            let mp4 = file.deletingPathExtension().appendingPathExtension("mp4")
            try? FileManager.default.removeItem(at: mp4)
            try FileManager.default.moveItem(at: file, to: mp4)
            defer { try? FileManager.default.removeItem(at: mp4) }
            return try await AudioDecoder.decode16kMono(url: mp4)
        }
    }

    // MARK: Word error rate

    static func words(_ text: String) -> [String] {
        let folded = text.folding(options: [.caseInsensitive, .diacriticInsensitive, .widthInsensitive], locale: nil)
        return folded.components(separatedBy: CharacterSet.alphanumerics.inverted).filter { !$0.isEmpty }
    }

    /// Levenshtein over words / reference length (case, accents and punctuation ignored).
    static func wer(_ hypothesis: String, reference: String) -> Double {
        let h = words(hypothesis), r = words(reference)
        guard !r.isEmpty else { return h.isEmpty ? 0 : 1 }
        var previous = Array(0...h.count)
        for i in 1...r.count {
            var current = [i] + Array(repeating: 0, count: h.count)
            for j in stride(from: 1, through: h.count, by: 1) {
                current[j] = min(previous[j] + 1, current[j - 1] + 1, previous[j - 1] + (r[i - 1] == h[j - 1] ? 0 : 1))
            }
            previous = current
        }
        return Double(previous[h.count]) / Double(r.count)
    }

    /// The sentence a clip holds: the truth closest to what the engine heard.
    static func closestTruth(_ text: String) -> (HearingLanguage, Double) {
        truth.map { ($0.key, wer(text, reference: $0.value)) }.min { $0.1 < $1.1 }!
    }

    static func report(_ label: String, _ event: SpeechEvent, _ t: EngineTranscript, clip: Double) {
        let (language, error) = closestTruth(t.text)
        print(String(format: "[UAT] %@ event=%@ clip=%.1fs gated=%.1fs processing=%.3fs RTF=%.4f truth=%@ WER=%.1f%% text=%@",
                     label, event.id, clip, t.audioSeconds, t.processingSeconds, t.realTimeFactor,
                     language.rawValue, error * 100, t.text))
    }

    @Test func werHelperIsSane() {
        #expect(Self.wer("Hello this is", reference: "hello, this is") == 0)
        #expect(Self.wer("Bonne journee", reference: "Bonne journée") == 0)
        #expect(abs(Self.wer("a b x", reference: "a b c") - 1.0 / 3) < 0.001)
    }

    @Test func realClipsHaveAudioAndSpeech() async throws {
        guard let base = Self.base else { return }
        let events = try await Self.endedSpeechEvents()
        try #require(!events.isEmpty, "no ended speech events on \(Self.camera)")
        for event in events.prefix(2) {
            let audio = try await ClipSource(base: base).audio(for: event)
            let regions = try await EnergyVoiceGate().speechRegions(in: audio)
            let gated = SpeechCompactor.compact(audio, regions: regions)
            print(String(format: "[UAT] clip event=%@ duration=%.1fs energy-regions=%d speech=%.1fs",
                         event.id, audio.duration, regions.count, gated.speechSeconds))
            #expect(audio.duration > 5, "short clip = recording gap on the Frigate side")
            #expect(!regions.isEmpty)
        }
    }

    @Test func appleEngineOnRealClips() async throws {
        guard let base = Self.base, #available(macOS 26.0, *) else { return }
        let engine = AppleSpeechEngine()
        if case .unsupported(let why) = await engine.readiness() { Issue.record("Apple engine: \(why)"); return }
        try await engine.prepare(progress: nil)
        for event in try await Self.endedSpeechEvents().prefix(4) {
            let audio = try await ClipSource(base: base).audio(for: event)
            let gated = SpeechCompactor.compact(audio, regions: try await EnergyVoiceGate().speechRegions(in: audio))
            guard gated.speechSeconds >= 0.4 else { print("[UAT] skip \(event.id): no speech in clip"); continue }
            // Run both languages; the right one must match its sentence closely.
            var best = 1.0
            for language in [HearingLanguage.english, .french] {
                let t = try await engine.transcribe(gated.audio, language: language)
                Self.report("apple-\(language.rawValue)", event, t, clip: audio.duration)
                if Self.closestTruth(t.text).0 == language { best = min(best, Self.closestTruth(t.text).1) }
            }
            #expect(best < 0.35, "event \(event.id)")
        }
    }

    @Test func parakeetOnRealClips() async throws {
        guard let base = Self.base, Self.env["LUMEN_HEARING_PARAKEET"] == "1",
              let root = Self.env["LUMEN_HEARING_MODELS_DIR"].map({ URL(fileURLWithPath: $0) }) else { return }
        let engine = ParakeetEngine(modelsRoot: root)
        let gate = SileroVoiceGate(modelsRoot: root)
        try await engine.prepare(progress: nil)
        try await gate.prepare()
        var warmed = false
        for event in try await Self.endedSpeechEvents().prefix(4) {
            let audio = try await ClipSource(base: base).audio(for: event)
            let vadStart = ContinuousClock.now
            let regions = try await gate.speechRegions(in: audio)
            print("[UAT] silero event=\(event.id) regions=\(regions.count) took \(vadStart.duration(to: .now)) for \(audio.duration)s")
            let gated = SpeechCompactor.compact(audio, regions: regions)
            guard gated.speechSeconds >= 0.4 else { print("[UAT] skip \(event.id): no speech in clip"); continue }
            if !warmed { _ = try await engine.transcribe(gated.audio, language: .automatic); warmed = true }
            let t = try await engine.transcribe(gated.audio, language: .automatic)
            Self.report("parakeet-auto", event, t, clip: audio.duration)
            #expect(Self.closestTruth(t.text).1 < 0.35, "event \(event.id): \(t.text)")
            #expect(LanguageGuess.detect(t.text) == Self.closestTruth(t.text).0.rawValue)
        }
    }

    /// The Hub path end to end: real clip → pipeline → SQLite FTS → keyword alert.
    @Test func pipelineEndToEndOnRealClips() async throws {
        guard let base = Self.base, #available(macOS 26.0, *) else { return }
        let events = try await Self.endedSpeechEvents().prefix(4)
        try #require(!events.isEmpty)
        var settings = HearingSettings()
        settings.enabled = true
        try settings.grantConsent(camera: Self.camera, placement: .indoor, at: Date(timeIntervalSince1970: 1_700_000_000))
        settings.setKeywords(["colis", "package"])
        settings.engine = .apple
        settings.language = .automatic
        let frozen = settings
        let store = try TranscriptStore(url: nil)
        let sink = RecordingSink()
        let pipeline = HearingPipeline(settings: { frozen }, audioSource: ClipSource(base: base),
                                       gate: { EnergyVoiceGate() },
                                       engines: EngineSelector(parakeet: nil, apple: AppleSpeechEngine()),
                                       store: store, alerts: sink)
        for event in events { #expect(await pipeline.enqueue(event) == .queued) }
        await pipeline.waitUntilIdle()
        let snapshot = await pipeline.snapshot
        print("[UAT] pipeline processed=\(events.count) snapshot=\(snapshot) lastError=\(String(describing: snapshot.lastError)) RTF=\(String(describing: snapshot.lastRealTimeFactor)) alerts=\(sink.alerts.get().count)")
        let stored = try await store.search("package") + store.search("garage")
        for record in stored {
            let (truth, error) = Self.closestTruth(record.text)
            print(String(format: "[UAT] stored event=%@ lang=%@ truth=%@ WER=%.1f%% text=%@", record.eventID,
                         record.language ?? "-", truth.rawValue, error * 100, record.text))
            #expect(error < 0.35)
            #expect(record.language == truth.rawValue)
        }
        #expect(snapshot.lastError == nil)
        #expect(!stored.isEmpty)
    }
}
