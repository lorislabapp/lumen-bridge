import Foundation
import Testing
@testable import LumenHearing

struct StubFaces: FaceSightingSource {
    var names: [String]
    func faces(camera: String, from: Date, to: Date) async throws -> [FaceSighting] {
        names.map { FaceSighting(name: $0, start: from.addingTimeInterval(-5), end: to) }
    }
}

actor ThrowingDiarizer: SpeakerDiarizer {
    func readiness() async -> EngineReadiness { .ready }
    func prepare(progress: (@Sendable (Double) -> Void)?) async throws {}
    func diarize(_ audio: PCMAudio) async throws -> Diarization { throw HearingError.decodeFailed }
}

/// Runs a hook in the middle of diarization (e.g. staff arriving).
actor HookDiarizer: SpeakerDiarizer {
    let result: Diarization
    let hook: @Sendable () -> Void
    init(result: Diarization, hook: @escaping @Sendable () -> Void) {
        self.result = result
        self.hook = hook
    }
    func readiness() async -> EngineReadiness { .ready }
    func prepare(progress: (@Sendable (Double) -> Void)?) async throws {}
    func diarize(_ audio: PCMAudio) async throws -> Diarization {
        hook()
        return result
    }
}

let twoSpeakers = Diarization(
    turns: [SpeakerTurn(speaker: "S1", start: 0, end: 4), SpeakerTurn(speaker: "S2", start: 4.5, end: 7.5)],
    speakers: [DiarizedSpeaker(label: "S1", embedding: axis, speechSeconds: 4),
               DiarizedSpeaker(label: "S2", embedding: VoiceVector([0, 0, 1, 0])!, speechSeconds: 3)],
    audioSeconds: 8, processingSeconds: 0.02)

let oneUnknown = Diarization(turns: [SpeakerTurn(speaker: "S1", start: 0, end: 4)],
                             speakers: [DiarizedSpeaker(label: "S1", embedding: VoiceVector([0, 1, 0, 0])!, speechSeconds: 4)],
                             audioSeconds: 4, processingSeconds: 0.01)

let transcript = EngineTranscript(text: "Bonjour. Hello.", segments: [.init(start: 0.5, end: 3, text: "Bonjour."),
                                                                      .init(start: 5, end: 7, text: "Hello.")],
                                  language: "fr", engine: .appleSpeech, audioSeconds: 8, processingSeconds: 0.1)

@Suite struct VoiceAttributorTests {
    func identifying() -> VoiceSettings {
        var v = VoiceSettings()
        v.identificationEnabled = true
        return v
    }

    func attributor(_ diarizer: any SpeakerDiarizer, store: VoiceStore?, hearing: Box<HearingSettings> = Box(enabledSettings()),
                    voices: VoiceSettings = VoiceSettings(), pro: Bool = true, faces: (any FaceSightingSource)? = nil) -> VoiceAttributor {
        VoiceAttributor(diarizer: diarizer, store: store, hearing: { hearing.get() }, voices: { voices },
                        proAllows: { pro }, faces: faces, now: { consentAt.addingTimeInterval(3600) })
    }

    @Test func diarizeOnlyLabelsLinesAndStoresClipTimeTurns() async throws {
        let store = try VoiceStore(url: nil, sealer: testSealer())
        let a = attributor(FakeDiarizer(result: twoSpeakers), store: store)
        let out = try await a.attribute(transcript, audio: .silence(seconds: 8),
                                        context: SpeakerContext(event: event(1), sourceTime: { $0 + 10 }))
        #expect(out.segments.map(\.speaker) == ["S1", "S2"])
        #expect(out.text == transcript.text)
        #expect(try await store.turns(eventID: event(1).id).map(\.start) == [10, 14.5])
        #expect(try await store.clusters().isEmpty) // no identity without opt-in
        #expect(try await store.embeddingCount() == 0)
    }

    @Test func staffPresentProOffOrMissingModelDoNothing() async throws {
        let store = try VoiceStore(url: nil, sealer: testSealer())
        var staff = enabledSettings()
        staff.staffPresent = true
        let diarizer = FakeDiarizer(result: twoSpeakers)
        for a in [attributor(diarizer, store: store, hearing: Box(staff), voices: identifying()),
                  attributor(diarizer, store: store, voices: identifying(), pro: false),
                  attributor(FakeDiarizer(result: twoSpeakers, ready: false), store: store, voices: identifying())] {
            let out = try await a.attribute(transcript, audio: .silence(seconds: 8), context: SpeakerContext(event: event(1)))
            #expect(out == transcript)
        }
        #expect(await diarizer.calls == 0)
        #expect(try await store.turns(eventID: event(1).id).isEmpty)
    }

    @Test func outdoorCameraIsNeverDiarized() async throws {
        let store = try VoiceStore(url: nil, sealer: testSealer())
        var outdoor = enabledSettings()
        outdoor.setPlacement(.outdoor, camera: "salon")
        let diarizer = FakeDiarizer(result: twoSpeakers)
        let out = try await attributor(diarizer, store: store, hearing: Box(outdoor), voices: identifying())
            .attribute(transcript, audio: .silence(seconds: 8), context: SpeakerContext(event: event(1)))
        #expect(out == transcript)
        #expect(await diarizer.calls == 0)
    }

    @Test func staffArrivingDuringDiarizationWritesNothing() async throws {
        let store = try VoiceStore(url: nil, sealer: testSealer())
        let hearing = Box(enabledSettings())
        let diarizer = HookDiarizer(result: twoSpeakers) { hearing.update { $0.staffPresent = true } }
        let out = try await attributor(diarizer, store: store, hearing: hearing, voices: identifying())
            .attribute(transcript, audio: .silence(seconds: 8), context: SpeakerContext(event: event(1)))
        #expect(out == transcript)
        #expect(try await store.turns(eventID: event(1).id).isEmpty)
        #expect(try await store.clusters().isEmpty)
    }

    @Test func diarizationFailureKeepsTheTranscript() async throws {
        let out = try await attributor(ThrowingDiarizer(), store: nil)
            .attribute(transcript, audio: .silence(seconds: 8), context: SpeakerContext(event: event(1)))
        #expect(out == transcript)
    }

    @Test func identifiesConsentingPeopleAndFilesStrangers() async throws {
        let store = try VoiceStore(url: nil, sealer: testSealer())
        let marie = try await store.addProfile(name: "Marie", isChild: false, consent: fr)
        try await store.addEmbeddings(profileID: marie.id, [.init(vector: vec(0.97), camera: "salon", source: "event", speechSeconds: 4)])
        let a = attributor(FakeDiarizer(result: twoSpeakers), store: store, voices: identifying())
        _ = try await a.attribute(transcript, audio: .silence(seconds: 8), context: SpeakerContext(event: event(1)))
        let labels = try #require(try await store.labels(eventIDs: [event(1).id])[event(1).id])
        #expect(labels["S1"]?.name == "Marie" && labels["S1"]?.band == .match)
        #expect(labels["S2"]?.band == .unknown && labels["S2"]?.clusterID != nil)
        #expect(try await store.clusters().count == 1)
        // A 0.97 match is confident enough to add one automatic camera sample.
        #expect(try await store.profile(id: marie.id).sampleCount == 2)
        #expect(await a.lastReport?.identified == 1)
    }

    @Test func childrenAreNeverAutoLearned() async throws {
        let store = try VoiceStore(url: nil, sealer: testSealer())
        let leo = try await store.addProfile(name: "Léo", isChild: true, consent: fr)
        try await store.addEmbeddings(profileID: leo.id, [.init(vector: axis, camera: "salon", source: "event", speechSeconds: 4)])
        _ = try await attributor(FakeDiarizer(result: twoSpeakers), store: store, voices: identifying())
            .attribute(transcript, audio: .silence(seconds: 8), context: SpeakerContext(event: event(1)))
        #expect(try await store.profile(id: leo.id).sampleCount == 1)
    }

    @Test func faceAndVoicePromoteAfterThreeEvents() async throws {
        let store = try VoiceStore(url: nil, sealer: testSealer())
        let marie = try await store.addProfile(name: "Marie", faceName: "Marie", isChild: false, consent: fr)
        try await store.addEmbeddings(profileID: marie.id, [.init(vector: VoiceVector([0, 0, 0, 1])!, camera: "salon",
                                                                   source: "event", speechSeconds: 4)])
        let a = attributor(FakeDiarizer(result: oneUnknown), store: store, voices: identifying(), faces: StubFaces(names: ["Marie"]))
        for n in 1...2 {
            _ = try await a.attribute(transcript, audio: .silence(seconds: 4), context: SpeakerContext(event: event(n)))
        }
        #expect(try await store.faceSuggestions().first?.agreeing == 2)
        #expect(try await store.profile(id: marie.id).sampleCount == 1)
        _ = try await a.attribute(transcript, audio: .silence(seconds: 4), context: SpeakerContext(event: event(3)))
        #expect(try await store.clusters().isEmpty)
        #expect(try await store.profile(id: marie.id).sampleCount == 4)
        #expect(try await store.labels(eventIDs: [event(1).id])[event(1).id]?["S1"]?.name == "Marie")
    }

    @Test func twoFacesGiveNoEvidence() async throws {
        let store = try VoiceStore(url: nil, sealer: testSealer())
        let a = attributor(FakeDiarizer(result: oneUnknown), store: store, voices: identifying(),
                           faces: StubFaces(names: ["Marie", "Paul"]))
        _ = try await a.attribute(transcript, audio: .silence(seconds: 4), context: SpeakerContext(event: event(1)))
        #expect(try await store.faceSuggestions().isEmpty)
    }

    @Test func pipelineRunsTheStageAndMapsTimesToTheClip() async throws {
        let store = try VoiceStore(url: nil, sealer: testSealer())
        let settings = Box(enabledSettings())
        let diarizer = FakeDiarizer(result: Diarization(turns: [SpeakerTurn(speaker: "S1", start: 0, end: 1.2)],
                                                        speakers: [DiarizedSpeaker(label: "S1", embedding: axis, speechSeconds: 1.2)],
                                                        audioSeconds: 1.5, processingSeconds: 0.01))
        let stage = VoiceAttributor(diarizer: diarizer, store: store, hearing: { settings.get() }, voices: { VoiceSettings() },
                                    proAllows: { true })
        let transcripts = try TranscriptStore(url: nil)
        let pipeline = HearingPipeline(settings: { settings.get() }, audioSource: StubAudio(), gate: { EnergyVoiceGate() },
                                       engines: EngineSelector(parakeet: nil, apple: StubEngine()), speakers: stage,
                                       store: transcripts, alerts: RecordingSink(), now: { consentAt.addingTimeInterval(3600) })
        #expect(await pipeline.enqueue(event(7)) == .queued)
        await pipeline.waitUntilIdle()
        let row = try #require(try await transcripts.recent().first)
        #expect(row.segments.first?.speaker == "S1")
        // The tone starts at 0.5 s in the clip, padded by 0.25 s → gated 0 = clip 0.25.
        let turn = try #require(try await store.turns(eventID: event(7).id).first)
        #expect(abs(turn.start - 0.25) < 0.05)
    }
}
