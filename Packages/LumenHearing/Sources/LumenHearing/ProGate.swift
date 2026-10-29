import Foundation

/// Lumen Hub features need Lumen Pro. The Lumen app writes its StoreKit
/// status to CloudKit (record `ProStatus` / `pro_status_v1`, private DB of
/// `iCloud.com.lorislab.lumenforfrigate`); the Hub only reads it.
///
/// Policy (mirrors Lumen's 7-day `PaidEntitlementCache`):
/// - a fresh Pro read → Pro, and the grant is cached;
/// - offline / iCloud unavailable → the cached grant counts for 7 days;
/// - unknown (never verified, cache too old) → new enablement is refused
///   (fail closed) but what already runs keeps running;
/// - a fresh "not Pro" or expired read → processing pauses.
/// Existing transcripts and voices are never deleted by this gate.
public struct ProStatusReading: Sendable, Equatable, Codable {
    public var isPro: Bool
    public var expiresAt: Date?
    public var updatedAt: Date
    public init(isPro: Bool, expiresAt: Date?, updatedAt: Date) {
        self.isPro = isPro
        self.expiresAt = expiresAt
        self.updatedAt = updatedAt
    }
}

public enum ProUnavailableReason: String, Sendable, Equatable, Codable {
    /// This build is not entitled to Lumen's iCloud container (see README).
    case containerNotEntitled
    case noICloudAccount
    /// No `ProStatus` record yet (Lumen never ran with iCloud on this account).
    case noRecord
    case offline
    case error
}

public enum ProAccess: Sendable, Equatable {
    case pro(expiresAt: Date?)
    /// Last verified grant, used while the status cannot be read.
    case cachedPro(verifiedAt: Date)
    case notPro
    case unknown(ProUnavailableReason)
    /// Local qualification override (debug builds only).
    case internalOverride

    public var canEnableNew: Bool {
        switch self {
        case .pro, .cachedPro, .internalOverride: return true
        case .notPro, .unknown: return false
        }
    }

    /// Only a definite "not Pro" pauses running work; unknown does not.
    public var allowsProcessing: Bool { self != .notPro }
}

public struct ProEntitlementCache: Sendable {
    public static let key = "lumenhub.pro.lastVerified.v1"
    public static let window: TimeInterval = 7 * 24 * 60 * 60

    struct Grant: Codable { var verifiedAt: Date; var expiresAt: Date? }

    private let suiteName: String?
    public init(suiteName: String? = nil) { self.suiteName = suiteName }
    private var defaults: UserDefaults { suiteName.flatMap(UserDefaults.init(suiteName:)) ?? .standard }

    public func save(verifiedAt: Date, expiresAt: Date?) {
        guard let data = try? JSONEncoder().encode(Grant(verifiedAt: verifiedAt, expiresAt: expiresAt)) else { return }
        defaults.set(data, forKey: Self.key)
    }

    /// The cached grant when it is less than 7 days old and not past its expiry.
    public func validGrant(now: Date = Date()) -> (verifiedAt: Date, expiresAt: Date?)? {
        guard let data = defaults.data(forKey: Self.key),
              let grant = try? JSONDecoder().decode(Grant.self, from: data),
              grant.verifiedAt <= now, now.timeIntervalSince(grant.verifiedAt) < Self.window,
              grant.expiresAt.map({ $0 > now }) ?? true else { return nil }
        return (grant.verifiedAt, grant.expiresAt)
    }

    public func clear() { defaults.removeObject(forKey: Self.key) }
}

public enum ProGate {
    /// `fetch`: `.success(nil)` means "read OK, no record".
    public static func evaluate(_ fetch: Result<ProStatusReading?, ProFetchFailure>, cache: ProEntitlementCache,
                                now: Date = Date()) -> ProAccess {
        switch fetch {
        case .success(let reading?):
            if reading.isPro, reading.expiresAt.map({ $0 > now }) ?? true {
                cache.save(verifiedAt: now, expiresAt: reading.expiresAt)
                return .pro(expiresAt: reading.expiresAt)
            }
            cache.clear()
            return .notPro
        case .success(nil):
            if let grant = cache.validGrant(now: now) { return .cachedPro(verifiedAt: grant.verifiedAt) }
            return .unknown(.noRecord)
        case .failure(let failure):
            if let grant = cache.validGrant(now: now) { return .cachedPro(verifiedAt: grant.verifiedAt) }
            return .unknown(failure.reason)
        }
    }
}

public struct ProFetchFailure: Error, Sendable, Equatable {
    public var reason: ProUnavailableReason
    public init(_ reason: ProUnavailableReason) { self.reason = reason }
}
