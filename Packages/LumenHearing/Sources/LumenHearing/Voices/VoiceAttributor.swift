import Foundation

/// The Phase 2 `SpeakerAttributionStage`: diarizes each transcribed speech
/// event, labels transcript lines S1/S2…, and — only when the owner opted
/// in — matches voices against people who consented, files unknown voices
/// into clusters and records face ↔ voice evidence.
///
/// It never fails a transcription: any voice error leaves the text as is.
public actor VoiceAttributor: SpeakerAttributionStage {
    public struct Report: Sendable, Equatable {
        public var eventID: String
        public var speakers: Int
        public var identified: Int
        public var audioSeconds: Double
        public var processingSeconds: Double
        public var skipped: String?
    }

    private let diarizer: any SpeakerDiarizer
    private let store: VoiceStore?
    private let hearing: @Sendable () async -> HearingSettings
    private let voices: @Sendable () async -> VoiceSettings
    private let proAllows: @Sendable () async -> Bool
    private let faces: (any FaceSightingSource)?
    private let now: @Sendable () -> Date
    private(set) public var lastReport: Report?
    private var observers: [@Sendable (Report) -> Void] = []

    public init(diarizer: any SpeakerDiarizer, store: VoiceStore?,
                hearing: @escaping @Sendable () async -> HearingSettings,
                voices: @escaping @Sendable () async -> VoiceSettings,
                proAllows: @escaping @Sendable () async -> Bool,
                faces: (any FaceSightingSource)? = nil,
                now: @escaping @Sendable () -> Date = { Date() }) {
        self.diarizer = diarizer
        self.store = store
        self.hearing = hearing
        self.voices = voices
        self.proAllows = proAllows
        self.faces = faces
        self.now = now
    }

    public func observe(_ handler: @escaping @Sendable (Report) -> Void) { observers.append(handler) }

    /// Without the event there is nothing safe to do: the text is returned unchanged.
    public func attribute(_ transcript: EngineTranscript, audio: PCMAudio) async throws -> EngineTranscript { transcript }

    public func attribute(_ transcript: EngineTranscript, audio: PCMAudio, context: SpeakerContext) async throws -> EngineTranscript {
        let event = context.event
        var report = Report(eventID: event.id, speakers: 0, identified: 0, audioSeconds: audio.duration, processingSeconds: 0)
        defer { finish(report) }

        let decision = await currentDecision(event)
        guard decision == .diarizeOnly || decision == .identify else {
            report.skipped = "off"
            return transcript
        }
        guard await diarizer.readiness() == .ready else {
            report.skipped = "model not downloaded"
            return transcript
        }
        let diarization: Diarization
        do {
            diarization = try await diarizer.diarize(audio).normalized()
        } catch {
            report.skipped = "diarization failed"
            return transcript
        }
        report.speakers = diarization.speakers.count
        report.processingSeconds = diarization.processingSeconds
        guard !diarization.turns.isEmpty else { return transcript }

        var labelled = transcript
        labelled.segments = SpeakerLabeler.label(transcript.segments, words: transcript.words, turns: diarization.turns)

        // Staff may have arrived, or the owner switched voices off, during diarization.
        let final = await currentDecision(event)
        guard final == .diarizeOnly || final == .identify else {
            report.skipped = "off"
            return transcript
        }
        guard let store else { return labelled }

        let clipTurns = diarization.turns.map {
            SpeakerTurn(speaker: $0.speaker, start: context.sourceTime($0.start), end: max(context.sourceTime($0.start), context.sourceTime($0.end)))
        }
        var assignments = diarization.speakers.map { SpeakerAssignment(speaker: $0.label) }
        if final == .identify {
            let settings = await voices()
            assignments = await identify(diarization.speakers, event: event, settings: settings, store: store)
            report.identified = assignments.filter { $0.band == .match || $0.band == .confirmed }.count
        }
        do {
            try await store.recordEvent(eventID: event.id, camera: event.camera, eventStart: event.start,
                                        turns: clipTurns, assignments: assignments, at: now())
        } catch {
            report.skipped = "store failed"
        }
        // After the rows exist, so a promotion relabels this event too.
        if final == .identify {
            await linkFace(diarization, assignments: assignments, event: event, audio: audio, store: store)
        }
        return labelled
    }

    private func currentDecision(_ event: SpeechEvent) async -> VoiceGate.Decision {
        VoiceGate.decision(hearing: await hearing(), voices: await voices(), camera: event.camera,
                           eventStart: event.start, proAllowsProcessing: await proAllows())
    }

    private func identify(_ speakers: [DiarizedSpeaker], event: SpeechEvent, settings: VoiceSettings,
                          store: VoiceStore) async -> [SpeakerAssignment] {
        let gallery = (try? await store.gallery()) ?? []
        let profiles = Dictionary(((try? await store.profiles()) ?? []).map { ($0.id, $0) }, uniquingKeysWith: { a, _ in a })
        let t = settings.thresholds.validated
        var out: [SpeakerAssignment] = []
        for speaker in speakers {
            guard let vector = speaker.embedding else { out.append(.init(speaker: speaker.label)); continue }
            let result = VoiceMatcher.match(vector, speechSeconds: speaker.speechSeconds, gallery: gallery, thresholds: t)
            switch result.band {
            case .match, .maybe:
                out.append(.init(speaker: speaker.label, band: result.band, profileID: result.profileID, score: result.score))
                // Auto-learn: very confident adult matches add a capped camera sample.
                if result.band == .match, settings.autoLearn, let id = result.profileID, let profile = profiles[id],
                   !profile.isChild, let score = result.score, score >= min(0.95, t.match + 0.1),
                   speaker.speechSeconds >= t.minimumSpeechSeconds + 1 {
                    try? await store.addEmbeddings(profileID: id, [.init(vector: vector, camera: event.camera, source: "auto",
                                                                          eventID: event.id, speaker: speaker.label,
                                                                          speechSeconds: speaker.speechSeconds)], at: now())
                }
            default:
                guard settings.rememberUnknownVoices, !result.tooShort,
                      let filed = try? await store.fileUnknown(vector, speechSeconds: speaker.speechSeconds, camera: event.camera,
                                                               eventID: event.id, speaker: speaker.label,
                                                               threshold: t.clusterJoin, at: now()) else {
                    out.append(.init(speaker: speaker.label, band: .unknown, score: result.score))
                    continue
                }
                out.append(.init(speaker: speaker.label, band: filed.ignored ? .ignored : .unknown,
                                 clusterID: filed.id, score: result.score))
            }
        }
        return out
    }

    /// One recognised face + one voice on this camera at this time → evidence;
    /// three agreeing events promote into a consenting adult's profile.
    private func linkFace(_ diarization: Diarization, assignments: [SpeakerAssignment], event: SpeechEvent,
                          audio: PCMAudio, store: VoiceStore) async {
        guard let faces, diarization.speakers.count == 1, let only = assignments.first,
              only.band == .unknown, let clusterID = only.clusterID else { return }
        let end = event.end ?? event.start.addingTimeInterval(max(audio.duration, 1))
        guard let sightings = try? await faces.faces(camera: event.camera, from: event.start, to: end),
              let face = FaceVoiceRule.candidate(faces: sightings, speechStart: event.start, speechEnd: end,
                                                 speakers: diarization.speakers) else { return }
        try? await store.addFaceEvidence(clusterID: clusterID, face: face, eventID: event.id, at: now())
        _ = try? await store.promoteIfReady(clusterID: clusterID, at: now())
    }

    private func finish(_ report: Report) {
        lastReport = report
        observers.forEach { $0(report) }
    }
}

/// "Teach from event": the owner picks 3–5 real speech clips of one person.
/// Each clip is re-fetched from Frigate, cut to that speaker's turns and
/// embedded; nothing is kept from people who were not picked.
public actor VoiceEnroller {
    public static let sampleRange = 3...5

    public struct Sample: Sendable, Hashable {
        public var event: SpeechEvent
        public var speaker: String
        public init(event: SpeechEvent, speaker: String) {
            self.event = event
            self.speaker = speaker
        }
    }

    public enum EnrolError: Error, Equatable, Sendable {
        case needsThreeToFiveClips
        case sameEventTwice
        case speakerNotFound(String)
        case tooShort(String)
        case consentRequired
    }

    private let audioSource: any SpeechAudioSource
    private let diarizer: any SpeakerDiarizer
    private let store: VoiceStore
    private let minimumSpeech: @Sendable () async -> Double

    public init(audioSource: any SpeechAudioSource, diarizer: any SpeakerDiarizer, store: VoiceStore,
                minimumSpeech: @escaping @Sendable () async -> Double = { VoiceThresholds.defaults.minimumSpeechSeconds }) {
        self.audioSource = audioSource
        self.diarizer = diarizer
        self.store = store
        self.minimumSpeech = minimumSpeech
    }

    /// Returns the number of samples stored.
    @discardableResult
    public func enroll(profileID: String, samples: [Sample]) async throws -> Int {
        guard Self.sampleRange.contains(samples.count) else { throw EnrolError.needsThreeToFiveClips }
        guard Set(samples.map(\.event.id)).count == samples.count else { throw EnrolError.sameEventTwice }
        guard let profile = try? await store.profile(id: profileID), profile.consent.isCurrent else {
            throw EnrolError.consentRequired
        }
        let minimum = await minimumSpeech()
        var items: [VoiceStore.NewEmbedding] = []
        for sample in samples {
            let turns = try await store.turns(eventID: sample.event.id, speaker: sample.speaker)
            guard !turns.isEmpty else { throw EnrolError.speakerNotFound(sample.event.id) }
            let audio = try await audioSource.audio(for: sample.event)
            let (vector, seconds) = try await embedding(of: audio, turns: turns)
            guard let vector, seconds >= minimum else { throw EnrolError.tooShort(sample.event.id) }
            items.append(.init(vector: vector, camera: sample.event.camera, source: "event", eventID: sample.event.id,
                               speaker: sample.speaker, speechSeconds: seconds))
        }
        do {
            try await store.addEmbeddings(profileID: profileID, items)
        } catch VoiceStoreError.consentRequired {
            throw EnrolError.consentRequired
        }
        return items.count
    }

    /// Embedding of one speaker: the clip is cut to their turns, then the
    /// dominant diarized speaker of that cut is taken.
    public func embedding(of audio: PCMAudio, turns: [SpeakerTurn]) async throws -> (VoiceVector?, Double) {
        let regions = turns.map { SpeechRegion(start: $0.start, end: $0.end) }
        let cut = SpeechCompactor.compact(audio, regions: regions, padding: 0.05, joinGap: 0.2)
        guard cut.speechSeconds > 0 else { return (nil, 0) }
        let result = try await diarizer.diarize(cut.audio).normalized()
        guard let main = result.speakers.max(by: { $0.speechSeconds < $1.speechSeconds }) else { return (nil, 0) }
        return (main.embedding, main.speechSeconds)
    }
}
