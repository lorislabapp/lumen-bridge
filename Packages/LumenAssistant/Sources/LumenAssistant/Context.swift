import Foundation
import LumenHearing

/// Who said this utterance. Backed by LumenHearing Phase 2 (diarizer
/// embedding + consented voice gallery); nothing is stored.
public protocol UtteranceSpeakerIdentifier: Sendable {
    func identify(_ audio: PCMAudio, camera: String) async -> SpeakerStanding
}

public struct NoSpeakerIdentifier: UtteranceSpeakerIdentifier {
    public init() {}
    public func identify(_ audio: PCMAudio, camera: String) async -> SpeakerStanding { .notIdentified }
}

/// LumenHearing-backed identification. Honours `VoiceGate` (identification
/// on, camera not excluded, consent, staff mode) and the match/maybe bands;
/// a child profile never counts as an adult.
public struct HearingVoiceIdentifier: UtteranceSpeakerIdentifier {
    private let diarizer: any SpeakerDiarizer
    private let store: VoiceStore
    private let hearing: @Sendable () async -> HearingSettings
    private let voices: @Sendable () async -> VoiceSettings
    private let proAllows: @Sendable () async -> Bool

    public init(diarizer: any SpeakerDiarizer, store: VoiceStore,
                hearing: @escaping @Sendable () async -> HearingSettings,
                voices: @escaping @Sendable () async -> VoiceSettings,
                proAllows: @escaping @Sendable () async -> Bool) {
        self.diarizer = diarizer
        self.store = store
        self.hearing = hearing
        self.voices = voices
        self.proAllows = proAllows
    }

    public func identify(_ audio: PCMAudio, camera: String) async -> SpeakerStanding {
        let settings = await voices()
        guard VoiceGate.decision(hearing: await hearing(), voices: settings, camera: camera,
                                 proAllowsProcessing: await proAllows()) == .identify,
              await diarizer.readiness() == .ready,
              let diarization = try? await diarizer.diarize(audio).normalized(),
              let main = diarization.speakers.max(by: { $0.speechSeconds < $1.speechSeconds }),
              let vector = main.embedding else { return .notIdentified }
        // Short commands: allow 1 s (a name needs ≥ 2 s in transcripts; here a
        // match only ever LOWERS rights, it never grants more than the default).
        var thresholds = settings.thresholds.validated
        thresholds.minimumSpeechSeconds = min(thresholds.minimumSpeechSeconds, 1.0)
        let gallery = (try? await store.gallery()) ?? []
        let result = VoiceMatcher.match(vector, speechSeconds: main.speechSeconds, gallery: gallery, thresholds: thresholds)
        switch result.band {
        case .match, .confirmed:
            guard let id = result.profileID, let profile = try? await store.profile(id: id) else { return .unknown }
            return profile.isChild ? .child(profileID: id) : .adult(profileID: id)
        case .maybe: return .maybe
        case .unknown, .ignored: return result.tooShort ? .notIdentified : .unknown
        }
    }
}

/// "Is someone in that room?" — from Frigate person detections on the room's cameras.
public protocol PresenceOracle: Sendable {
    func personSeen(cameras: [String], within seconds: TimeInterval) async -> Bool?
}

public struct UnknownPresence: PresenceOracle {
    public init() {}
    public func personSeen(cameras: [String], within seconds: TimeInterval) async -> Bool? { nil }
}

/// Fixed answers, for tests and demos.
public struct FixedPresence: PresenceOracle {
    public var seen: Bool?
    public init(_ seen: Bool?) { self.seen = seen }
    public func personSeen(cameras: [String], within seconds: TimeInterval) async -> Bool? { seen }
}
