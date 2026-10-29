#if LUMEN_HUB
import CloudKit
import Foundation
import LumenHearing
import Observation
import os
import Security

private let logger = Logger(subsystem: "com.lorislabapp.lumenbridge", category: "HubPro")

/// Read-only Lumen Pro check for Lumen Hub features.
///
/// The Lumen app publishes its StoreKit status as CloudKit record
/// `ProStatus/pro_status_v1` in the PRIVATE database of
/// `iCloud.com.lorislab.lumenforfrigate` (ProStatusPublisher). The Hub reads
/// that same record with the user's own iCloud account; it never writes it.
///
/// MISSING TODAY: the Hub's entitlements list only
/// `iCloud.com.lorislabapp.lumenbridge`. Reading needs
/// `iCloud.com.lorislab.lumenforfrigate` added to LumenHub.entitlements, the
/// container enabled on App ID `com.lorislabapp.lumenbridge` in the Developer
/// portal, and a regenerated Developer ID profile. Until then this reports
/// `.unknown(.containerNotEntitled)` (fail closed: no new enablement) and never
/// touches CKContainer — an unentitled CKContainer(identifier:) traps.
@MainActor @Observable
final class HubProStatus {
    static let shared = HubProStatus()
    nonisolated static let lumenContainerID = "iCloud.com.lorislab.lumenforfrigate"

    private(set) var access: ProAccess = .unknown(.offline)
    private(set) var lastChecked: Date?
    @ObservationIgnored private let cache = ProEntitlementCache()
    @ObservationIgnored private var loop: Task<Void, Never>?
    @ObservationIgnored private var listeners: [@MainActor (ProAccess) -> Void] = []

    private init() {
        // Until the first read finishes, a still-valid cached grant counts.
        if let grant = cache.validGrant() { access = .cachedPro(verifiedAt: grant.verifiedAt) }
    }

    func start() {
        guard loop == nil else { return }
        loop = Task { [weak self] in
            while !Task.isCancelled {
                await self?.refresh()
                try? await Task.sleep(for: .seconds(6 * 3600))
            }
        }
    }

    func onChange(_ handler: @escaping @MainActor (ProAccess) -> Void) { listeners.append(handler) }

    func refresh() async {
        let next: ProAccess
        if Self.internalOverride {
            next = .internalOverride
        } else {
            next = ProGate.evaluate(await Self.fetch(), cache: cache)
        }
        lastChecked = Date()
        guard next != access else { return }
        access = next
        logger.info("pro access: \(String(describing: next), privacy: .public)")
        listeners.forEach { $0(next) }
    }

    /// Debug builds only: `LUMEN_HUB_INTERNAL_PRO=1` for local qualification.
    nonisolated static var internalOverride: Bool {
        #if DEBUG
        ProcessInfo.processInfo.environment["LUMEN_HUB_INTERNAL_PRO"] == "1"
        #else
        false
        #endif
    }

    nonisolated static func fetch() async -> Result<ProStatusReading?, ProFetchFailure> {
        guard hasContainerEntitlement(lumenContainerID) else { return .failure(.init(.containerNotEntitled)) }
        let container = CKContainer(identifier: lumenContainerID)
        do {
            guard try await container.accountStatus() == .available else { return .failure(.init(.noICloudAccount)) }
            let record = try await container.privateCloudDatabase.record(for: CKRecord.ID(recordName: "pro_status_v1"))
            guard let updated = record["lastUpdated"] as? Date else { return .failure(.init(.error)) }
            let isPro = (record["isPro"] as? NSNumber)?.intValue == 1
            return .success(ProStatusReading(isPro: isPro, expiresAt: record["expiresAt"] as? Date, updatedAt: updated))
        } catch let error as CKError where error.code == .unknownItem {
            return .success(nil)
        } catch let error as CKError where [.networkUnavailable, .networkFailure, .serviceUnavailable,
                                             .requestRateLimited, .zoneBusy].contains(error.code) {
            return .failure(.init(.offline))
        } catch let error as CKError where error.code == .notAuthenticated {
            return .failure(.init(.noICloudAccount))
        } catch {
            return .failure(.init(.error))
        }
    }

    /// Reads this process's own signed entitlements.
    nonisolated static func hasContainerEntitlement(_ id: String) -> Bool {
        guard let task = SecTaskCreateFromSelf(nil),
              let value = SecTaskCopyValueForEntitlement(task, "com.apple.developer.icloud-container-identifiers" as CFString, nil)
        else { return false }
        return (value as? [String])?.contains(id) ?? false
    }
}
#endif
