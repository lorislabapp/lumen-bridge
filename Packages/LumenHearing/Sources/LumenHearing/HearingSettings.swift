import Foundation

/// Where a camera points. Outdoor and street-facing cameras can never be
/// transcribed: French CNIL doctrine forbids sound capture of the street and
/// covert capture of visitors is an art. 226-1 Code pénal offence.
public enum CameraPlacement: String, Codable, Sendable, CaseIterable {
    case indoor
    case outdoor
    case street

    public var isLocked: Bool { self != .indoor }
}

public enum EnginePreference: String, Codable, Sendable, CaseIterable {
    /// Parakeet when its model is on disk, else Apple's system engine.
    case automatic
    case parakeet
    case apple
}

public enum HearingLanguage: String, Codable, Sendable, CaseIterable {
    /// Parakeet detects the language itself; Apple's engine uses the Mac's language (fr or en).
    case automatic
    case french = "fr"
    case english = "en"
}

/// Per-camera opt-in. Consent is a record of the owner confirming the
/// household and visitors are informed, tied to the text version they saw.
public struct CameraHearingPolicy: Codable, Sendable, Equatable {
    public var enabled: Bool = false
    public var placement: CameraPlacement?
    public var consentAcceptedAt: Date?
    public var consentVersion: Int?

    public init(enabled: Bool = false, placement: CameraPlacement? = nil,
                consentAcceptedAt: Date? = nil, consentVersion: Int? = nil) {
        self.enabled = enabled
        self.placement = placement
        self.consentAcceptedAt = consentAcceptedAt
        self.consentVersion = consentVersion
    }

    public init(from decoder: any Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        enabled = try c.decodeIfPresent(Bool.self, forKey: .enabled) ?? false
        placement = try? c.decodeIfPresent(CameraPlacement.self, forKey: .placement)
        consentAcceptedAt = try c.decodeIfPresent(Date.self, forKey: .consentAcceptedAt)
        consentVersion = try c.decodeIfPresent(Int.self, forKey: .consentVersion)
    }
}

public enum BlockReason: String, Sendable, Equatable, Codable {
    case featureOff
    case cameraNotEnabled
    case consentMissing
    case outdoorLocked
    case staffPresent
    /// The event started before the owner gave consent for this camera.
    case beforeConsent
}

public enum Eligibility: Sendable, Equatable {
    case allowed
    case blocked(BlockReason)
}

/// All user choices for the transcription feature. Every default is the
/// private one: off, no camera, no keyword, 30-day retention.
public struct HearingSettings: Codable, Sendable, Equatable {
    /// Bump when the consent text changes materially: cameras then need consent again.
    public static let consentVersion = 1
    public static let retentionChoices = [1, 7, 14, 30]
    public static let maxKeywords = 20
    public static let keywordLength = 2...40

    public var enabled: Bool = false
    public var cameras: [String: CameraHearingPolicy] = [:]
    /// "Staff present": a nanny, cleaner or carer is in the home. Pauses all
    /// audio processing; events recorded meanwhile are dropped, never queued.
    public var staffPresent: Bool = false
    public var retentionDays: Int = 30
    public var keywords: [String] = []
    public var engine: EnginePreference = .automatic
    public var language: HearingLanguage = .automatic

    public init() {}

    public init(from decoder: any Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        enabled = try c.decodeIfPresent(Bool.self, forKey: .enabled) ?? false
        cameras = try c.decodeIfPresent([String: CameraHearingPolicy].self, forKey: .cameras) ?? [:]
        staffPresent = try c.decodeIfPresent(Bool.self, forKey: .staffPresent) ?? false
        retentionDays = Self.clampRetention(try c.decodeIfPresent(Int.self, forKey: .retentionDays) ?? 30)
        keywords = Self.sanitizedKeywords(try c.decodeIfPresent([String].self, forKey: .keywords) ?? [])
        engine = (try? c.decodeIfPresent(EnginePreference.self, forKey: .engine)) ?? .automatic
        language = (try? c.decodeIfPresent(HearingLanguage.self, forKey: .language)) ?? .automatic
    }

    // MARK: Safeguards

    /// The single gate every job passes, at enqueue time and again right
    /// before audio is fetched and before it is transcribed.
    public func eligibility(camera: String, eventStart: Date? = nil) -> Eligibility {
        guard enabled else { return .blocked(.featureOff) }
        guard !staffPresent else { return .blocked(.staffPresent) }
        guard let policy = cameras[camera] else { return .blocked(.cameraNotEnabled) }
        if policy.placement?.isLocked ?? false { return .blocked(.outdoorLocked) }
        guard policy.enabled else { return .blocked(.cameraNotEnabled) }
        guard policy.placement == .indoor, let consentAt = policy.consentAcceptedAt,
              policy.consentVersion == Self.consentVersion else { return .blocked(.consentMissing) }
        if let eventStart, eventStart < consentAt { return .blocked(.beforeConsent) }
        return .allowed
    }

    public var activeCameras: [String] {
        cameras.keys.filter { eligibility(camera: $0) == .allowed }.sorted()
    }

    public enum ChangeError: Error, Equatable {
        case outdoorLocked
        case consentRequired
    }

    /// Records the owner's consent for one indoor camera and turns it on.
    public mutating func grantConsent(camera: String, placement: CameraPlacement, at date: Date = Date()) throws {
        var policy = cameras[camera] ?? CameraHearingPolicy()
        policy.placement = placement
        guard !placement.isLocked else {
            policy.enabled = false
            cameras[camera] = policy
            throw ChangeError.outdoorLocked
        }
        policy.consentAcceptedAt = date
        policy.consentVersion = Self.consentVersion
        policy.enabled = true
        cameras[camera] = policy
    }

    /// Turns a camera on or off. Turning on needs a current consent and an indoor placement.
    public mutating func setCamera(_ camera: String, enabled on: Bool) throws {
        var policy = cameras[camera] ?? CameraHearingPolicy()
        guard on else {
            policy.enabled = false
            cameras[camera] = policy
            return
        }
        if policy.placement?.isLocked ?? false { throw ChangeError.outdoorLocked }
        guard policy.placement == .indoor, policy.consentAcceptedAt != nil,
              policy.consentVersion == Self.consentVersion else { throw ChangeError.consentRequired }
        policy.enabled = true
        cameras[camera] = policy
    }

    /// Marking a camera outdoor or street-facing switches it off at once.
    /// Changing placement also clears consent: the owner must re-read the sheet.
    public mutating func setPlacement(_ placement: CameraPlacement, camera: String) {
        var policy = cameras[camera] ?? CameraHearingPolicy()
        guard policy.placement != placement else { return }
        policy.placement = placement
        policy.enabled = false
        policy.consentAcceptedAt = nil
        policy.consentVersion = nil
        cameras[camera] = policy
    }

    /// Best guess from the camera's Frigate name, used to pre-select the
    /// placement in the consent sheet (the owner always confirms).
    public static func suggestedPlacement(cameraName: String) -> CameraPlacement? {
        let name = KeywordMatcher.normalize(cameraName.replacingOccurrences(of: "_", with: " ")
            .replacingOccurrences(of: "-", with: " "))
        let words = Set(name.split(separator: " ").map(String.init))
        let street: Set = ["street", "rue", "road", "route", "sidewalk", "trottoir", "voie", "parking", "public"]
        let outdoor: Set = ["outdoor", "outside", "exterieur", "ext", "garden", "jardin", "yard", "driveway",
                            "allee", "gate", "portail", "porch", "perron", "terrasse", "terrace", "patio",
                            "doorbell", "sonnette", "front", "facade", "cour", "courtyard", "garage", "boite",
                            "mailbox", "balcon", "balcony", "back", "backyard", "pool", "piscine"]
        let indoor: Set = ["indoor", "inside", "interieur", "salon", "living", "kitchen", "cuisine", "hall",
                           "entree", "couloir", "hallway", "office", "bureau", "bedroom", "chambre", "nursery",
                           "playroom", "sejour", "stairs", "escalier"]
        if !words.isDisjoint(with: street) { return .street }
        if !words.isDisjoint(with: outdoor) { return .outdoor }
        if !words.isDisjoint(with: indoor) { return .indoor }
        return nil
    }

    // MARK: Retention and keywords

    public static func clampRetention(_ days: Int) -> Int {
        retentionChoices.last { $0 <= days } ?? retentionChoices[0]
    }

    public mutating func setRetention(days: Int) { retentionDays = Self.clampRetention(days) }

    /// Trims, drops too short/long entries and normalized duplicates, keeps order, caps the count.
    public static func sanitizedKeywords(_ raw: [String]) -> [String] {
        var seen = Set<String>()
        var out: [String] = []
        for item in raw {
            let trimmed = item.trimmingCharacters(in: .whitespacesAndNewlines)
            let key = KeywordMatcher.normalize(trimmed)
            guard keywordLength.contains(trimmed.count), !key.isEmpty, seen.insert(key).inserted else { continue }
            out.append(trimmed)
            if out.count == maxKeywords { break }
        }
        return out
    }

    public mutating func setKeywords(_ raw: [String]) { keywords = Self.sanitizedKeywords(raw) }
}

/// JSON persistence in UserDefaults (same pattern as the Hub's zone alerts).
public struct HearingSettingsStore: Sendable {
    public static let key = "lumenhub.hearing.settings.v1"
    private let suiteName: String?

    public init(suiteName: String? = nil) { self.suiteName = suiteName }

    private var defaults: UserDefaults { suiteName.flatMap(UserDefaults.init(suiteName:)) ?? .standard }

    public func load() -> HearingSettings {
        guard let data = defaults.data(forKey: Self.key),
              let settings = try? JSONDecoder().decode(HearingSettings.self, from: data) else { return HearingSettings() }
        return settings
    }

    public func save(_ settings: HearingSettings) {
        guard let data = try? JSONEncoder().encode(settings) else { return }
        defaults.set(data, forKey: Self.key)
    }
}
