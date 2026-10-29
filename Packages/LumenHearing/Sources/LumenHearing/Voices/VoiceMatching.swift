import Foundation

/// Cosine thresholds for named voices. Three bands:
/// score ≥ `match` → the person's name; `maybe` ≤ score < `match` → "<name>?";
/// below `maybe` → unknown.
///
/// Why these defaults (WeSpeaker ResNet34 embeddings from pyannote
/// community-1, cosine on L2-normalised vectors):
/// - FluidAudio reports same-speaker cosine ≈ 0.81 vs different ≈ 0.26 on an
///   easy clean set (Benchmarks.md, CAM++); WeSpeaker sits in the same range.
///   Far-field camera audio pulls same-speaker scores down (FFSVC far-field
///   EER is 5–10× clean), so a single cut-off would either miss family members
///   or name strangers.
/// - `match` is high on purpose: a guest must never get a household name
///   unless the score clears it (research Q2). Measured on this Mac with two
///   synthetic `say` voices: see `VoiceIntegrationTests` output.
/// - Short clips are unreliable below ~2 s of net speech (ERes2NetV2, DAME),
///   so shorter speakers are only diarized, never named.
/// - A match also needs a lead over the second-best person (`margin`);
///   otherwise it is shown as "maybe".
public struct VoiceThresholds: Codable, Sendable, Equatable {
    public var match: Float = 0.72
    public var maybe: Float = 0.52
    public var margin: Float = 0.06
    public var minimumSpeechSeconds: Double = 2.0
    /// Two unknown voices join one cluster at this similarity or more.
    public var clusterJoin: Float = 0.60

    public static let defaults = VoiceThresholds()
    public static let range: ClosedRange<Float> = 0.30...0.95

    public init() {}

    public init(match: Float, maybe: Float, margin: Float = 0.06, minimumSpeechSeconds: Double = 2.0,
                clusterJoin: Float = 0.60) {
        self.match = match
        self.maybe = maybe
        self.margin = margin
        self.minimumSpeechSeconds = minimumSpeechSeconds
        self.clusterJoin = clusterJoin
    }

    /// Clamped to sane values; `maybe` always sits at least 0.05 under `match`.
    public var validated: VoiceThresholds {
        var t = self
        t.match = min(Self.range.upperBound, max(Self.range.lowerBound + 0.05, t.match))
        t.maybe = min(t.match - 0.05, max(Self.range.lowerBound, t.maybe))
        t.margin = min(0.3, max(0, t.margin))
        t.minimumSpeechSeconds = min(10, max(1, t.minimumSpeechSeconds))
        t.clusterJoin = min(Self.range.upperBound, max(Self.range.lowerBound, t.clusterJoin))
        return t
    }
}

public enum VoiceBand: String, Sendable, Codable, CaseIterable {
    case match, maybe, unknown
    /// The owner named this voice (from a cluster or a suggestion).
    case confirmed
    /// An unknown voice the owner chose to ignore ("this is the TV").
    case ignored
}

/// One enrolled embedding in the gallery.
public struct EnrolledVoice: Sendable, Equatable {
    public var profileID: String
    public var camera: String?
    public var vector: VoiceVector
    public init(profileID: String, camera: String?, vector: VoiceVector) {
        self.profileID = profileID
        self.camera = camera
        self.vector = vector
    }
}

public struct VoiceMatch: Sendable, Equatable {
    public var band: VoiceBand
    /// Best person, also set for `maybe`; nil when unknown.
    public var profileID: String?
    public var score: Float?
    /// True when the clip was too short to try.
    public var tooShort: Bool = false
}

public enum VoiceMatcher {
    /// Scores one clip-speaker against every person (best of each person's
    /// embeddings, so per-camera samples count) and returns its band.
    public static func match(_ vector: VoiceVector, speechSeconds: TimeInterval, gallery: [EnrolledVoice],
                             thresholds raw: VoiceThresholds) -> VoiceMatch {
        let t = raw.validated
        guard speechSeconds >= t.minimumSpeechSeconds else { return VoiceMatch(band: .unknown, tooShort: true) }
        var best: [String: Float] = [:]
        for item in gallery {
            let score = vector.cosine(item.vector)
            if score > best[item.profileID] ?? -2 { best[item.profileID] = score }
        }
        let ranked = best.sorted { ($0.value, $1.key) > ($1.value, $0.key) }
        guard let top = ranked.first else { return VoiceMatch(band: .unknown) }
        let lead = top.value - (ranked.dropFirst().first?.value ?? -1)
        if top.value >= t.match, lead >= t.margin {
            return VoiceMatch(band: .match, profileID: top.key, score: top.value)
        }
        if top.value >= t.maybe {
            return VoiceMatch(band: .maybe, profileID: top.key, score: top.value)
        }
        return VoiceMatch(band: .unknown, score: top.value)
    }
}

/// Unknown voices grouped over days (online, like Frigate's face library).
public enum VoiceClustering {
    public struct Centroid: Sendable, Equatable {
        public var id: Int64
        public var vector: VoiceVector
        public var events: Int
        public init(id: Int64, vector: VoiceVector, events: Int) {
            self.id = id
            self.vector = vector
            self.events = events
        }
    }

    /// Nearest cluster at or above `threshold`, else nil (start a new one).
    public static func nearest(_ vector: VoiceVector, in clusters: [Centroid], threshold: Float) -> (id: Int64, score: Float)? {
        let scored = clusters.map { ($0.id, vector.cosine($0.vector)) }
        guard let best = scored.max(by: { ($0.1, $1.0) < ($1.1, $0.0) }), best.1 >= threshold else { return nil }
        return (best.0, best.1)
    }

    /// Running mean: every event weighs the same.
    public static func adding(_ vector: VoiceVector, to centroid: VoiceVector, events: Int) -> VoiceVector {
        VoiceVector.mean([centroid, vector], weights: [Float(max(1, events)), 1]) ?? centroid
    }

    /// Pairs to merge (keep, absorb): clusters whose centroids drifted
    /// together. Greedy, highest similarity first; each cluster merges once per pass.
    public static func mergePlan(_ clusters: [Centroid], threshold: Float) -> [(keep: Int64, absorb: Int64)] {
        var pairs: [(Int64, Int64, Float)] = []
        for i in clusters.indices {
            for j in clusters.indices where j > i {
                let score = clusters[i].vector.cosine(clusters[j].vector)
                if score >= threshold {
                    // The busier cluster survives (older id on a tie).
                    let a = clusters[i], b = clusters[j]
                    let keepA = a.events > b.events || (a.events == b.events && a.id < b.id)
                    pairs.append(keepA ? (a.id, b.id, score) : (b.id, a.id, score))
                }
            }
        }
        var used = Set<Int64>()
        var plan: [(keep: Int64, absorb: Int64)] = []
        for (keep, absorb, _) in pairs.sorted(by: { $0.2 > $1.2 }) where !used.contains(keep) && !used.contains(absorb) {
            used.insert(keep)
            used.insert(absorb)
            plan.append((keep, absorb))
        }
        return plan
    }
}

/// A Frigate person event with a recognised face (`sub_label`).
public struct FaceSighting: Sendable, Equatable {
    public var name: String
    public var start: Date
    public var end: Date?
    public init(name: String, start: Date, end: Date?) {
        self.name = name
        self.start = start
        self.end = end
    }
}

/// Lists recognised faces seen on one camera during a time window.
public protocol FaceSightingSource: Sendable {
    func faces(camera: String, from: Date, to: Date) async throws -> [FaceSighting]
}

/// Face ↔ voice weak supervision (research Q3): one known face + one voice
/// on the same camera at the same time → a *suggested* label. Promotion
/// needs `promotionCount` agreeing events and no disagreeing one, or a tap.
public enum FaceVoiceRule {
    public static let promotionCount = 3

    /// Returns the face name when exactly one distinct recognised face
    /// overlaps the speech and exactly one speaker talked; else nil (the
    /// evidence is ambiguous and nothing is assigned).
    public static func candidate(faces: [FaceSighting], speechStart: Date, speechEnd: Date,
                                 speakers: [DiarizedSpeaker]) -> String? {
        guard speakers.count == 1 else { return nil }
        let names = Set(faces.filter { face in
            face.start <= speechEnd && (face.end ?? .distantFuture) >= speechStart
        }.map { $0.name.trimmingCharacters(in: .whitespacesAndNewlines) }.filter { !$0.isEmpty && $0.lowercased() != "unknown" })
        return names.count == 1 ? names.first : nil
    }

    public enum Decision: Sendable, Equatable {
        case none
        case suggest(face: String, agreeing: Int)
        case promote(face: String)
    }

    /// `counts`: events per face name seen with one unknown voice cluster.
    public static func decision(counts: [String: Int]) -> Decision {
        guard let top = counts.max(by: { ($0.value, $1.key) < ($1.value, $0.key) }), top.value > 0 else { return .none }
        let others = counts.filter { $0.key != top.key }.values.reduce(0, +)
        if top.value >= promotionCount && others == 0 { return .promote(face: top.key) }
        // Mixed evidence: only suggest when one face clearly dominates.
        if others == 0 || top.value >= 2 * others { return .suggest(face: top.key, agreeing: top.value) }
        return .none
    }
}

/// What a named voice may change. Voice ID can only ever LOWER what the
/// requesting device already allows (research: voice is spoofable by TV,
/// recordings and clones; Google removed voice unlock). It never unlocks,
/// disarms or authorises. Children's voices never count for permissions.
public enum VoiceRights {
    public enum Tier: Int, Sendable, Comparable, CaseIterable {
        case viewOnly = 0, comfort = 1, security = 2
        public static func < (a: Tier, b: Tier) -> Bool { a.rawValue < b.rawValue }
    }

    public enum Speaker: Sendable, Equatable {
        case none
        case unknown
        case maybe
        case adult
        case child
    }

    public static func effectiveTier(granted: Tier, speaker: Speaker) -> Tier {
        switch speaker {
        case .none, .adult: return granted // a match changes nothing
        case .unknown, .maybe, .child: return min(granted, .viewOnly)
        }
    }
}

/// Owner choices for Phase 2. Private defaults: speakers are separated
/// (no template stored), naming voices is off until the owner opts in.
public struct VoiceSettings: Codable, Sendable, Equatable {
    /// Bump when the consent text changes: people must consent again before new samples.
    public static let consentVersion = 1

    public var diarizationEnabled = true
    public var identificationEnabled = false
    /// Group voices nobody named yet (needs identification on). They expire
    /// with the transcript retention.
    public var rememberUnknownVoices = true
    /// Adds very confident matches as extra samples (adults only, capped).
    public var autoLearn = true
    public var thresholds = VoiceThresholds()
    /// Cameras where voices are never named (speakers still separated).
    public var excludedCameras: Set<String> = []

    public init() {}

    public init(from decoder: any Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        diarizationEnabled = try c.decodeIfPresent(Bool.self, forKey: .diarizationEnabled) ?? true
        identificationEnabled = try c.decodeIfPresent(Bool.self, forKey: .identificationEnabled) ?? false
        rememberUnknownVoices = try c.decodeIfPresent(Bool.self, forKey: .rememberUnknownVoices) ?? true
        autoLearn = try c.decodeIfPresent(Bool.self, forKey: .autoLearn) ?? true
        thresholds = (try? c.decodeIfPresent(VoiceThresholds.self, forKey: .thresholds))?.validated ?? VoiceThresholds()
        excludedCameras = try c.decodeIfPresent(Set<String>.self, forKey: .excludedCameras) ?? []
    }
}

public struct VoiceSettingsStore: Sendable {
    public static let key = "lumenhub.voices.settings.v1"
    private let suiteName: String?
    public init(suiteName: String? = nil) { self.suiteName = suiteName }
    private var defaults: UserDefaults { suiteName.flatMap(UserDefaults.init(suiteName:)) ?? .standard }

    public func load() -> VoiceSettings {
        guard let data = defaults.data(forKey: Self.key),
              let settings = try? JSONDecoder().decode(VoiceSettings.self, from: data) else { return VoiceSettings() }
        return settings
    }

    public func save(_ settings: VoiceSettings) {
        guard let data = try? JSONEncoder().encode(settings) else { return }
        defaults.set(data, forKey: Self.key)
    }
}

/// The one gate for voice work on a speech event, checked right before
/// diarization and again before anything is written.
public enum VoiceGate {
    public enum Decision: Sendable, Equatable {
        case off(BlockReason?)
        case diarizeOnly
        case identify
    }

    public static func decision(hearing: HearingSettings, voices: VoiceSettings, camera: String,
                                eventStart: Date? = nil, proAllowsProcessing: Bool) -> Decision {
        // Staff present, outdoor/street, no consent, feature off: nothing at all.
        if case .blocked(let reason) = hearing.eligibility(camera: camera, eventStart: eventStart) { return .off(reason) }
        guard proAllowsProcessing else { return .off(nil) }
        guard voices.diarizationEnabled else { return .off(nil) }
        guard voices.identificationEnabled, !voices.excludedCameras.contains(camera) else { return .diarizeOnly }
        return .identify
    }
}
