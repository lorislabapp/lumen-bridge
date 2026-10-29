import Foundation
import Testing
@testable import LumenHearing
@testable import LumenHearingFluid

/// Real audio through the real decoders and engines. Fixtures were generated
/// on this Mac with `say` (Samantha EN, Thomas FR) → AAC m4a, with 1.5 s of
/// silence before and after the speech.
@Suite(.serialized) struct IntegrationTests {
    static func fixture(_ name: String) throws -> URL {
        try #require(Bundle.module.url(forResource: "speech-\(name)", withExtension: "m4a", subdirectory: "Fixtures"))
    }

    static var modelsRoot: URL? {
        ProcessInfo.processInfo.environment["LUMEN_HEARING_MODELS_DIR"].map { URL(fileURLWithPath: $0) }
    }

    static func report(_ label: String, _ t: EngineTranscript) {
        print(String(format: "[RTF] %@ engine=%@ audio=%.2fs processing=%.3fs RTF=%.4f (%.0fx real time) text=%@",
                     label, t.engine.rawValue, t.audioSeconds, t.processingSeconds, t.realTimeFactor,
                     t.realTimeFactor > 0 ? 1 / t.realTimeFactor : 0, t.text))
    }

    @Test func decodesAACTo16kMono() async throws {
        let audio = try await AudioDecoder.decode16kMono(url: try Self.fixture("fr"))
        #expect(audio.duration > 6 && audio.duration < 12)
        #expect(audio.samples.contains { abs($0) > 0.05 })
    }

    @Test func refusesFilesWithoutAudio() async throws {
        let url = FileManager.default.temporaryDirectory.appendingPathComponent("not-audio-\(UUID()).mp4")
        try Data("not a movie".utf8).write(to: url)
        defer { try? FileManager.default.removeItem(at: url) }
        await #expect(throws: (any Error).self) { try await AudioDecoder.decode16kMono(url: url) }
    }

    @Test func energyGateTrimsLeadingAndTrailingSilence() async throws {
        let audio = try await AudioDecoder.decode16kMono(url: try Self.fixture("en"))
        let regions = try await EnergyVoiceGate().speechRegions(in: audio)
        let first = try #require(regions.first), last = try #require(regions.last)
        #expect(first.start > 1.0)
        #expect(last.end < audio.duration - 0.8)
    }

    @Test func appleEngineTranscribesEnglishAndFrench() async throws {
        guard #available(macOS 26.0, *) else { return }
        let engine = AppleSpeechEngine()
        if case .unsupported(let why) = await engine.readiness() {
            Issue.record("Apple engine unsupported here: \(why)")
            return
        }
        for (name, language, expected) in [("en", HearingLanguage.english, ["delivery", "door"]),
                                            ("fr", HearingLanguage.french, ["facteur", "colis", "porte"])] {
            let audio = try await AudioDecoder.decode16kMono(url: try Self.fixture(name))
            _ = try await engine.transcribe(PCMAudio.silence(seconds: 1), language: language) // warm-up
            let t = try await engine.transcribe(audio, language: language)
            Self.report("apple-\(name)", t)
            let found = KeywordMatcher(keywords: expected).matches(in: t.text)
            #expect(found.count >= expected.count - 1, "\(name): \(t.text)")
            #expect(!t.segments.isEmpty)
            #expect(t.language == name)
        }
    }

    /// Needs network once (≈ 480 MB from huggingface.co). Opt-in:
    /// LUMEN_HEARING_PARAKEET=1 LUMEN_HEARING_MODELS_DIR=/Volumes/... swift test
    @Test func parakeetWithSileroTranscribesEnglishAndFrench() async throws {
        guard ProcessInfo.processInfo.environment["LUMEN_HEARING_PARAKEET"] == "1", let root = Self.modelsRoot else { return }
        let engine = ParakeetEngine(modelsRoot: root)
        let gate = SileroVoiceGate(modelsRoot: root)
        let loadStart = ContinuousClock.now
        try await engine.prepare(progress: nil)
        try await gate.prepare()
        print("[RTF] parakeet+silero prepare (download/compile/load) took \(loadStart.duration(to: .now))")
        for (name, expected) in [("en", ["delivery", "door"]), ("fr", ["facteur", "colis", "porte"])] {
            let audio = try await AudioDecoder.decode16kMono(url: try Self.fixture(name))
            let vadStart = ContinuousClock.now
            let regions = try await gate.speechRegions(in: audio)
            print("[RTF] silero-\(name) regions=\(regions.count) took \(vadStart.duration(to: .now)) for \(audio.duration)s")
            #expect(!regions.isEmpty)
            let gated = SpeechCompactor.compact(audio, regions: regions)
            #expect(gated.audio.duration < audio.duration)
            _ = try await engine.transcribe(gated.audio, language: .automatic) // warm-up
            let t = try await engine.transcribe(gated.audio, language: .automatic)
            Self.report("parakeet-\(name)", t)
            let found = KeywordMatcher(keywords: expected).matches(in: t.text)
            #expect(found.count >= expected.count - 1, "\(name): \(t.text)")
            #expect(LanguageGuess.detect(t.text) == name)
            #expect(!t.segments.isEmpty)
        }
    }

    /// Full pipeline with the real Apple engine and real decoding.
    @Test func endToEndPipelineWithAppleEngine() async throws {
        guard #available(macOS 26.0, *) else { return }
        struct FileAudio: SpeechAudioSource {
            let url: URL
            func audio(for event: SpeechEvent) async throws -> PCMAudio { try await AudioDecoder.decode16kMono(url: url) }
        }
        var settings = enabledSettings(keywords: ["colis"])
        settings.engine = .apple
        settings.language = .french
        let frozen = settings
        let store = try TranscriptStore(url: nil)
        let sink = RecordingSink()
        let pipeline = HearingPipeline(settings: { frozen }, audioSource: FileAudio(url: try Self.fixture("fr")),
                                       gate: { EnergyVoiceGate() },
                                       engines: EngineSelector(parakeet: nil, apple: AppleSpeechEngine()),
                                       store: store, alerts: sink)
        #expect(await pipeline.enqueue(event(1)) == .queued)
        await pipeline.waitUntilIdle()
        let hits = try await store.search("facteur")
        let lastError = await pipeline.snapshot.lastError
        #expect(hits.count == 1, "lastError=\(String(describing: lastError))")
        #expect(sink.alerts.get().count == 1)
        if let rtf = await pipeline.snapshot.lastRealTimeFactor { print("[RTF] pipeline-apple-fr RTF=\(rtf)") }
    }
}
