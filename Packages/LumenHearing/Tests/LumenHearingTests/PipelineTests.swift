import Foundation
import Testing
@testable import LumenHearing

// MARK: Stubs

final class Box<T: Sendable>: @unchecked Sendable {
    private let lock = NSLock()
    private var value: T
    init(_ value: T) { self.value = value }
    func get() -> T { lock.withLock { value } }
    func set(_ newValue: T) { lock.withLock { value = newValue } }
    func update(_ change: (inout T) -> Void) { lock.withLock { change(&value) } }
}

/// One second of a 440 Hz tone between half-second silences: "speech" for the energy gate.
let toneClip: PCMAudio = {
    var samples = [Float](repeating: 0, count: 8_000)
    samples += (0..<16_000).map { Float(sin(Double($0) * 2 * .pi * 440 / 16_000) * 0.3) }
    samples += [Float](repeating: 0, count: 8_000)
    return PCMAudio(samples: samples)
}()

struct StubAudio: SpeechAudioSource {
    var clip: PCMAudio = toneClip
    var fetched = Box<[String]>([])
    var error: HearingError?
    func audio(for event: SpeechEvent) async throws -> PCMAudio {
        fetched.update { $0.append(event.id) }
        if let error { throw error }
        return clip
    }
}

actor StubEngine: TranscriptionEngine {
    nonisolated let kind: EngineKind
    let text: String
    var running = 0
    var maxConcurrent = 0
    var calls = 0
    var failuresBeforeSuccess: Int
    var onTranscribe: (@Sendable () -> Void)?

    init(kind: EngineKind = .appleSpeech, text: String = "Au secours, il y a quelqu'un dans la maison",
         failuresBeforeSuccess: Int = 0) {
        self.kind = kind
        self.text = text
        self.failuresBeforeSuccess = failuresBeforeSuccess
    }
    func setHook(_ hook: @escaping @Sendable () -> Void) { onTranscribe = hook }
    func readiness() async -> EngineReadiness { .ready }
    func prepare(progress: (@Sendable (Double) -> Void)?) async throws {}
    func transcribe(_ audio: PCMAudio, language: HearingLanguage) async throws -> EngineTranscript {
        calls += 1
        running += 1
        maxConcurrent = max(maxConcurrent, running)
        defer { running -= 1 }
        onTranscribe?()
        try await Task.sleep(for: .milliseconds(20))
        if failuresBeforeSuccess > 0 {
            failuresBeforeSuccess -= 1
            throw HearingError.insufficientResources
        }
        return EngineTranscript(text: text, segments: [.init(start: 0.1, end: 0.9, text: text)], language: nil,
                                engine: kind, audioSeconds: audio.duration, processingSeconds: 0.02)
    }
}

struct RecordingSink: KeywordAlertSink {
    let alerts = Box<[KeywordAlert]>([])
    func keywordHeard(_ alert: KeywordAlert) async { alerts.update { $0.append(alert) } }
}

let consentAt = Date(timeIntervalSince1970: 1_800_000_000)

func enabledSettings(keywords: [String] = ["au secours"]) -> HearingSettings {
    var s = HearingSettings()
    s.enabled = true
    try! s.grantConsent(camera: "salon", placement: .indoor, at: consentAt)
    s.setKeywords(keywords)
    return s
}

func event(_ n: Int, camera: String = "salon") -> SpeechEvent {
    let start = consentAt.addingTimeInterval(Double(60 + n))
    return SpeechEvent(id: "1800000060.\(n)-abc", camera: camera, start: start, end: start.addingTimeInterval(4))
}

struct Harness {
    let settings: Box<HearingSettings>
    let audio: StubAudio
    let engine: StubEngine
    let store: TranscriptStore
    let sink = RecordingSink()
    let pipeline: HearingPipeline

    init(settings: HearingSettings = enabledSettings(), audio: StubAudio = StubAudio(), engine: StubEngine = StubEngine()) throws {
        let box = Box(settings)
        self.settings = box
        self.audio = audio
        self.engine = engine
        let store = try TranscriptStore(url: nil)
        self.store = store
        var config = HearingPipeline.Configuration()
        config.retryDelay = .milliseconds(10)
        pipeline = HearingPipeline(settings: { box.get() }, audioSource: audio, gate: { EnergyVoiceGate() },
                                   engines: EngineSelector(parakeet: nil, apple: engine), store: store,
                                   alerts: sink, now: { consentAt.addingTimeInterval(3600) }, configuration: config)
    }
}

// MARK: Tests

@Suite struct PipelineTests {
    @Test func offByDefaultNothingIsFetched() async throws {
        let h = try Harness(settings: HearingSettings())
        #expect(await h.pipeline.enqueue(event(1)) == .blocked(.featureOff))
        await h.pipeline.waitUntilIdle()
        #expect(h.audio.fetched.get().isEmpty)
        #expect(await h.engine.calls == 0)
    }

    @Test func transcribesStoresAndAlertsWithoutText() async throws {
        let h = try Harness()
        #expect(await h.pipeline.enqueue(event(1)) == .queued)
        await h.pipeline.waitUntilIdle()
        let rows = try await h.store.search("secours")
        #expect(rows.count == 1)
        #expect(rows.first?.language == "fr")
        // Segment times are mapped back to the clip (speech starts ~0.25 s after padding at 0.5 s).
        let segment = try #require(rows.first?.segments.first)
        #expect(segment.start >= 0.2 && segment.start <= 0.6)
        let alerts = h.sink.alerts.get()
        #expect(alerts.count == 1)
        #expect(alerts.first?.camera == "salon")
        #expect(await h.pipeline.snapshot.transcribed == 1)
    }

    @Test func oneSharedEngineRunsJobsStrictlyOneAtATime() async throws {
        let h = try Harness()
        for n in 0..<8 { _ = await h.pipeline.enqueue(event(n)) }
        await h.pipeline.waitUntilIdle()
        #expect(await h.engine.calls == 8)
        #expect(await h.engine.maxConcurrent == 1)
        #expect(try await h.store.count() == 8)
    }

    @Test func duplicatesAreIgnored() async throws {
        let h = try Harness()
        #expect(await h.pipeline.enqueue(event(1)) == .queued)
        #expect(await h.pipeline.enqueue(event(1)) == .duplicate)
        await h.pipeline.waitUntilIdle()
        #expect(await h.pipeline.enqueue(event(1)) == .duplicate)
        #expect(await h.engine.calls == 1)
    }

    @Test func staffModeDropsNewEventsForGood() async throws {
        var s = enabledSettings()
        s.staffPresent = true
        let h = try Harness(settings: s)
        #expect(await h.pipeline.enqueue(event(1)) == .blocked(.staffPresent))
        // Turning staff mode off later must not resurrect that event.
        h.settings.update { $0.staffPresent = false }
        #expect(await h.pipeline.enqueue(event(1)) == .duplicate)
        await h.pipeline.waitUntilIdle()
        #expect(h.audio.fetched.get().isEmpty)
    }

    @Test func staffArrivingMidQueueBlocksJobsBeforeTranscription() async throws {
        let h = try Harness()
        let settings = h.settings
        await h.engine.setHook { settings.update { $0.staffPresent = true } }
        var refused = 0
        for n in 0..<3 where await h.pipeline.enqueue(event(n)) == .blocked(.staffPresent) { refused += 1 }
        await h.pipeline.waitUntilIdle()
        // The job already inside the engine finishes; every later job is refused or skipped before fetch.
        #expect(await h.engine.calls == 1)
        #expect(h.audio.fetched.get().count == 1)
        #expect(await h.pipeline.snapshot.skipped + refused == 2)
    }

    @Test func outdoorCameraIsNeverProcessed() async throws {
        var s = enabledSettings()
        s.setPlacement(.outdoor, camera: "salon")
        let h = try Harness(settings: s)
        #expect(await h.pipeline.enqueue(event(1)) == .blocked(.outdoorLocked))
        #expect(await h.pipeline.process(event(2)) == .skipped(.outdoorLocked))
        #expect(h.audio.fetched.get().isEmpty)
    }

    @Test func unknownCameraIsBlocked() async throws {
        let h = try Harness()
        #expect(await h.pipeline.enqueue(event(1, camera: "bureau")) == .blocked(.cameraNotEnabled))
    }

    @Test func malformedEventIdsAreRefused() async throws {
        let h = try Harness()
        let bad = SpeechEvent(id: "../../etc", camera: "salon", start: consentAt.addingTimeInterval(9), end: nil)
        #expect(await h.pipeline.enqueue(bad) == .blocked(.cameraNotEnabled))
    }

    @Test func silenceIsNotSentToTheEngine() async throws {
        let h = try Harness(audio: StubAudio(clip: .silence(seconds: 5)))
        _ = await h.pipeline.enqueue(event(1))
        await h.pipeline.waitUntilIdle()
        #expect(await h.engine.calls == 0)
        #expect(try await h.store.count() == 0)
        #expect(try await h.store.hasProcessed(eventID: event(1).id))
    }

    @Test func clipWithoutAudioTrackIsSkipped() async throws {
        let h = try Harness(audio: StubAudio(error: .noAudioTrack))
        #expect(await h.pipeline.process(event(1)) == .noAudio)
    }

    @Test func insufficientResourcesIsRetried() async throws {
        let h = try Harness(engine: StubEngine(failuresBeforeSuccess: 2))
        _ = await h.pipeline.enqueue(event(1))
        await h.pipeline.waitUntilIdle()
        #expect(await h.engine.calls == 3)
        #expect(try await h.store.count() == 1)
    }

    /// UAT 0.18: clip.mp4 answers 400 "No recordings found" until the segment is saved.
    @Test func clipNotReadyIsRetriedThenTranscribed() async throws {
        struct LateClip: SpeechAudioSource {
            let misses = Box(1)
            func audio(for event: SpeechEvent) async throws -> PCMAudio {
                var miss = false
                misses.update { if $0 > 0 { $0 -= 1; miss = true } }
                if miss { throw HearingError.clipNotReady }
                return toneClip
            }
        }
        let store = try TranscriptStore(url: nil)
        var config = HearingPipeline.Configuration()
        config.retryDelay = .milliseconds(10)
        let settings = enabledSettings()
        let pipeline = HearingPipeline(settings: { settings }, audioSource: LateClip(), gate: { EnergyVoiceGate() },
                                       engines: EngineSelector(parakeet: nil, apple: StubEngine()), store: store,
                                       alerts: RecordingSink(), now: { consentAt.addingTimeInterval(3600) },
                                       configuration: config)
        _ = await pipeline.enqueue(event(1))
        await pipeline.waitUntilIdle()
        #expect(try await store.count() == 1)
        #expect(await pipeline.snapshot.failed == 0)
    }

    @Test func insufficientResourcesGivesUpAfterMaxAttempts() async throws {
        let h = try Harness(engine: StubEngine(failuresBeforeSuccess: 10))
        _ = await h.pipeline.enqueue(event(1))
        await h.pipeline.waitUntilIdle()
        #expect(await h.engine.calls == 3)
        #expect(await h.pipeline.snapshot.failed == 1)
        #expect(try await h.store.count() == 0)
    }

    @Test func noKeywordNoAlert() async throws {
        let h = try Harness(settings: enabledSettings(keywords: ["cambrioleur"]))
        _ = await h.pipeline.enqueue(event(1))
        await h.pipeline.waitUntilIdle()
        #expect(h.sink.alerts.get().isEmpty)
    }
}

@Suite struct EnvelopeAndCompactorTests {
    @Test func keywordPushCarriesNoWords() throws {
        let alert = KeywordAlert(eventID: "1800000060.1-abc", camera: "salon", detectedAt: consentAt,
                                 matchedKeywords: ["au secours"])
        let envelope = KeywordAlertEnvelope.make(alert: alert, reviewID: "r1", severity: "alert",
                                                 title: "Keyword heard", cameraDisplayName: "Salon")
        #expect(Set(envelope.keys).isSubset(of: KeywordAlertEnvelope.allowedKeys))
        let json = String(decoding: try JSONSerialization.data(withJSONObject: envelope), as: UTF8.self).lowercased()
        #expect(!json.contains("secours"))
        #expect(!json.contains("transcript"))
        #expect(envelope["custom_body"] as? String == "Salon")
    }

    @Test func compactorMapsGatedTimesBackToTheClip() {
        let audio = PCMAudio.silence(seconds: 10)
        let gated = SpeechCompactor.compact(audio, regions: [.init(start: 2, end: 3), .init(start: 7, end: 8)],
                                            padding: 0, joinGap: 0.5)
        #expect(abs(gated.audio.duration - 2.5) < 0.001)
        #expect(abs(gated.sourceTime(0.5) - 2.5) < 0.001)
        #expect(abs(gated.sourceTime(1.6) - 7.1) < 0.001)
        #expect(abs(gated.speechSeconds - 2) < 0.001)
    }

    @Test func compactorMergesCloseRegions() {
        let gated = SpeechCompactor.compact(.silence(seconds: 10), regions: [.init(start: 1, end: 2), .init(start: 2.2, end: 3)],
                                            padding: 0.1, joinGap: 0.3)
        #expect(gated.pieces.count == 1)
    }

    @Test func energyGateFindsTheToneOnly() async throws {
        let regions = try await EnergyVoiceGate().speechRegions(in: toneClip)
        #expect(regions.count == 1)
        let r = try #require(regions.first)
        #expect(abs(r.start - 0.5) < 0.05)
        #expect(abs(r.end - 1.5) < 0.05)
    }

    @Test func segmenterSplitsOnPausesAndSentences() {
        let words = [TimedWord(text: "Bonjour,", start: 0, end: 0.3), TimedWord(text: "Marie.", start: 0.35, end: 0.7),
                     TimedWord(text: "Tu", start: 0.8, end: 0.9), TimedWord(text: "viens", start: 0.95, end: 1.2),
                     TimedWord(text: "demain", start: 3, end: 3.4)]
        let segments = TranscriptSegmenter.segments(from: words)
        #expect(segments.map(\.text) == ["Bonjour, Marie.", "Tu viens", "demain"])
        #expect(segments[2].start == 3)
    }
}

@Suite struct IngestorTests {
    struct Feed: SpeechEventFeed {
        let events: Box<[SpeechEvent]>
        let calls = Box<[Date]>([])
        func speechEvents(after: Date, limit: Int) async throws -> [SpeechEvent] {
            calls.update { $0.append(after) }
            return events.get().filter { $0.start >= after }
        }
    }

    @Test func firstStartNeverBackfillsAndWaitsForClipsToSettle() async throws {
        let h = try Harness()
        let now = Box(consentAt.addingTimeInterval(1000))
        let cursor = Box<Date?>(nil)
        let old = SpeechEvent(id: "1.old-a", camera: "salon", start: consentAt.addingTimeInterval(100), end: consentAt.addingTimeInterval(104))
        let fresh = SpeechEvent(id: "2.fresh-b", camera: "salon", start: consentAt.addingTimeInterval(1010), end: consentAt.addingTimeInterval(1015))
        let feed = Feed(events: Box([old, fresh]))
        var config = SpeechEventIngestor.Configuration()
        config.overlap = 60
        let ingestor = SpeechEventIngestor(feed: feed, pipeline: h.pipeline, loadCursor: { cursor.get() },
                                           saveCursor: { cursor.set($0) }, now: { now.get() }, configuration: config)
        await ingestor.primeCursor()
        #expect(cursor.get() == consentAt.addingTimeInterval(1000))
        // Event ended 0 s ago: not settled yet.
        now.set(consentAt.addingTimeInterval(1016))
        #expect(await ingestor.pollOnce().isEmpty)
        now.set(consentAt.addingTimeInterval(1061)) // 46 s after the end (settleDelay 45 s)
        #expect(await ingestor.pollOnce() == [.queued])
        await h.pipeline.waitUntilIdle()
        #expect(h.audio.fetched.get() == ["2.fresh-b"])
        #expect(cursor.get() == fresh.start)
        #expect(await ingestor.pollOnce() == [.duplicate])
    }
}
