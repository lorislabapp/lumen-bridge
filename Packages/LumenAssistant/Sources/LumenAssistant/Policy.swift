import Foundation
import LumenHearing

public enum AssistantMode: String, Codable, Sendable, CaseIterable {
    /// "Lumen, …" first. The default.
    case wakePhrase
    /// No wake word, T0 only, known voice + person seen in that room.
    case natural
}

/// Who spoke, from LumenHearing's voice attribution. Voice is weak evidence:
/// it can only LOWER rights (replay, TV and clones fool it).
public enum SpeakerStanding: Sendable, Equatable, Codable {
    case adult(profileID: String)
    case child(profileID: String)
    /// Close to someone, not sure.
    case maybe
    case unknown
    /// Voice naming is off or the clip was too short.
    case notIdentified

    public var isKnown: Bool {
        switch self {
        case .adult, .child: true
        default: false
        }
    }

    public var label: String {
        switch self {
        case .adult(let id): "adult:\(id)"
        case .child(let id): "child:\(id)"
        case .maybe: "maybe"
        case .unknown: "unknown"
        case .notIdentified: "not-identified"
        }
    }
}

/// Owner choices. Private defaults: off, wake phrase, preview only.
public struct AssistantSettings: Codable, Sendable, Equatable {
    public var enabled = false
    public var mode: AssistantMode = .wakePhrase
    /// Cameras the assistant listens to. Each must also pass LumenHearing's
    /// gate (indoor, consent, not staff mode) at the moment of listening.
    public var cameras: Set<String> = []
    /// Preview only: everything is logged as "would do", nothing is sent to Home Assistant.
    public var dryRun = true
    /// Highest tier a known adult may run from a camera mic (T2 is never executed here).
    public var maxTierFromCameras: ActionTier = .t1
    public var undoSeconds: Double = 10
    public var naturalThreshold: Double = AddressClassifier.defaultThreshold
    /// Speak the reply on the Mac (AVSpeechSynthesizer).
    public var speakReplies = false
    public var notifyPhone = true
    public var homeAssistantURL: String = ""
    public var llmURL: String = "http://127.0.0.1:8012"
    public var llmEnabled = true
    /// Days the command audit log is kept.
    public var auditRetentionDays = 30

    public init() {}

    public init(from decoder: any Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        let d = AssistantSettings()
        enabled = try c.decodeIfPresent(Bool.self, forKey: .enabled) ?? d.enabled
        mode = (try? c.decodeIfPresent(AssistantMode.self, forKey: .mode)) ?? d.mode
        cameras = try c.decodeIfPresent(Set<String>.self, forKey: .cameras) ?? d.cameras
        dryRun = try c.decodeIfPresent(Bool.self, forKey: .dryRun) ?? d.dryRun
        let tier = (try? c.decodeIfPresent(ActionTier.self, forKey: .maxTierFromCameras)) ?? d.maxTierFromCameras
        maxTierFromCameras = min(tier, .t1)
        undoSeconds = min(30, max(3, try c.decodeIfPresent(Double.self, forKey: .undoSeconds) ?? d.undoSeconds))
        naturalThreshold = min(0.99, max(0.6, try c.decodeIfPresent(Double.self, forKey: .naturalThreshold) ?? d.naturalThreshold))
        speakReplies = try c.decodeIfPresent(Bool.self, forKey: .speakReplies) ?? d.speakReplies
        notifyPhone = try c.decodeIfPresent(Bool.self, forKey: .notifyPhone) ?? d.notifyPhone
        homeAssistantURL = try c.decodeIfPresent(String.self, forKey: .homeAssistantURL) ?? d.homeAssistantURL
        llmURL = try c.decodeIfPresent(String.self, forKey: .llmURL) ?? d.llmURL
        llmEnabled = try c.decodeIfPresent(Bool.self, forKey: .llmEnabled) ?? d.llmEnabled
        auditRetentionDays = min(90, max(1, try c.decodeIfPresent(Int.self, forKey: .auditRetentionDays) ?? d.auditRetentionDays))
    }
}

public struct AssistantSettingsStore: Sendable {
    public static let key = "lumenhub.assistant.settings.v1"
    private let suiteName: String?
    public init(suiteName: String? = nil) { self.suiteName = suiteName }
    private var defaults: UserDefaults { suiteName.flatMap(UserDefaults.init(suiteName:)) ?? .standard }

    public func load() -> AssistantSettings {
        guard let data = defaults.data(forKey: Self.key),
              let settings = try? JSONDecoder().decode(AssistantSettings.self, from: data) else { return AssistantSettings() }
        return settings
    }

    public func save(_ settings: AssistantSettings) {
        guard let data = try? JSONEncoder().encode(settings) else { return }
        defaults.set(data, forKey: Self.key)
    }
}

/// Everything the policy looks at. Filled by code, never by the model.
public struct PolicyContext: Sendable {
    public var camera: String
    public var mode: AssistantMode
    public var speaker: SpeakerStanding
    /// Frigate saw a person on a camera of that room just now (nil = unknown).
    public var personSeenInRoom: Bool?
    /// A TV/speaker in that room is playing (its sound may be what we heard).
    public var mediaPlayingInRoom: Bool
    /// Natural-mode "addressed to the house" score.
    public var addressScore: Double
    public var source: CommandSource

    public init(camera: String, mode: AssistantMode, speaker: SpeakerStanding, personSeenInRoom: Bool?,
                mediaPlayingInRoom: Bool, addressScore: Double = 1, source: CommandSource = .rules) {
        self.camera = camera
        self.mode = mode
        self.speaker = speaker
        self.personSeenInRoom = personSeenInRoom
        self.mediaPlayingInRoom = mediaPlayingInRoom
        self.addressScore = addressScore
        self.source = source
    }
}

public enum RefusalReason: String, Codable, Sendable, Equatable {
    case tierTooHigh
    case childProfile
    case unknownVoiceForT1
    case t2NeedsKnownAdult
    case naturalModeT0Only
    case naturalModeNeedsKnownVoice
    case naturalModeNeedsPerson
    case mediaPlaying
    case notAddressed
    case rateLimited
    case duplicate
}

public enum PolicyDecision: Sendable, Equatable {
    case execute
    /// Read-only answer (status question).
    case answer
    /// T2: pending proposal + push; Face ID on the iPhone; never run here.
    case propose
    case refuse(RefusalReason)
}

/// The deterministic gate between the parser (or the LLM) and the house.
public struct PolicyEngine: Sendable {
    public var settings: AssistantSettings
    public init(settings: AssistantSettings) { self.settings = settings }

    public func decide(_ plan: ActionPlan, context: PolicyContext) -> PolicyDecision {
        let tier = plan.tier
        if context.mode == .natural {
            // Natural mode: T0 only, a known voice, a person seen in that room, no TV playing.
            guard tier == .t0 else { return .refuse(.naturalModeT0Only) }
            guard context.speaker.isKnown else { return .refuse(.naturalModeNeedsKnownVoice) }
            guard context.personSeenInRoom == true else { return .refuse(.naturalModeNeedsPerson) }
            guard !context.mediaPlayingInRoom else { return .refuse(.mediaPlaying) }
            guard context.addressScore >= settings.naturalThreshold else { return .refuse(.notAddressed) }
        }
        if plan.action.isReadOnly { return .answer }

        switch tier {
        case .t0:
            return .execute
        case .t1:
            if case .child = context.speaker { return .refuse(.childProfile) }
            guard settings.maxTierFromCameras >= .t1 else { return .refuse(.tierTooHigh) }
            // Voice can only lower rights: T1 needs a confident adult match.
            guard case .adult = context.speaker else { return .refuse(.unknownVoiceForT1) }
            return .execute
        case .t2:
            if case .child = context.speaker { return .refuse(.childProfile) }
            guard case .adult = context.speaker else { return .refuse(.t2NeedsKnownAdult) }
            return .propose
        }
    }
}

/// Sliding-window limits per tier, plus duplicate suppression: two cameras
/// often hear the same sentence, which must not toggle a light twice.
public struct RateLimiter: Sendable {
    public struct Limit: Sendable, Equatable {
        public var count: Int
        public var window: TimeInterval
        public init(count: Int, window: TimeInterval) {
            self.count = count
            self.window = window
        }
    }

    public var limits: [ActionTier: Limit] = [
        .t0: Limit(count: 12, window: 60),
        .t1: Limit(count: 6, window: 600),
        .t2: Limit(count: 3, window: 600),
    ]
    public var duplicateWindow: TimeInterval = 4
    private var history: [(Date, ActionTier, String)] = []

    public init() {}

    /// Checks and, when allowed, records the attempt.
    public mutating func admit(_ plan: ActionPlan, at now: Date) -> RefusalReason? {
        let horizon = (limits.values.map(\.window).max() ?? 600)
        history.removeAll { now.timeIntervalSince($0.0) > horizon }
        let key = Self.key(plan)
        if history.contains(where: { $0.2 == key && now.timeIntervalSince($0.0) < duplicateWindow }) { return .duplicate }
        let tier = plan.tier
        if let limit = limits[tier] {
            let recent = history.filter { $0.1 == tier && now.timeIntervalSince($0.0) < limit.window }.count
            if recent >= limit.count { return .rateLimited }
        }
        history.append((now, tier, key))
        return nil
    }

    static func key(_ plan: ActionPlan) -> String {
        ([plan.action.rawValue] + plan.targets.map(\.entityID).sorted()).joined(separator: ",")
    }
}
