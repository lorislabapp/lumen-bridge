import CloudKit
import Foundation
import os

private let logger = Logger(subsystem: "com.lorislabapp.lumenbridge", category: "CloudKit")

/// Writes Frigate detection events to the user's CloudKit *private* database
/// so every Lumen install under the same Apple ID receives an APNs push via
/// CKQuerySubscription. The bridge itself doesn't send pushes — Apple does,
/// natively, with no third-party infrastructure.
///
/// CloudKit container identifier must match the entitlement value in
/// `LumenBridge.entitlements`. For Mac App Store submission the identifier
/// must also be registered under the Apple Developer account the app is
/// signed with.
actor CloudKitBridge {
    // MARK: - Configuration

    /// Matches the container configured in the Apple Developer account for
    /// this bundle ID. Share the same container with the other Lumen apps so
    /// records written here show up via CKQuerySubscription on iPhone / iPad
    /// / Mac / Watch / Vision Pro instances of Lumen.
    private static let containerID = "iCloud.com.lorislabapp.lumenbridge"
    private static let recordType = "FrigateEvent"

    // MARK: -

    private let container: CKContainer
    private var hasSchemaBeenCreated = false

    init() {
        self.container = CKContainer(identifier: Self.containerID)
    }

    // MARK: - Status

    /// Check iCloud account availability once on boot. The returned status is
    /// surfaced in the menu-bar UI so the user knows whether to open
    /// System Settings and sign in.
    func accountStatus() async -> CloudKitStatus {
        do {
            let status = try await container.accountStatus()
            switch status {
            case .available:
                return .available
            case .noAccount:
                return .noAccount
            case .restricted:
                return .error("iCloud restricted by profile")
            case .couldNotDetermine:
                return .error("Could not determine iCloud status")
            case .temporarilyUnavailable:
                return .error("iCloud temporarily unavailable")
            @unknown default:
                return .error("Unknown iCloud status")
            }
        } catch {
            logger.error("accountStatus failed: \(error.localizedDescription)")
            return .error(error.localizedDescription)
        }
    }

    // MARK: - Event ingestion

    /// Persists one Frigate event as a CloudKit record. Idempotent via the
    /// event ID — same event written twice produces one record (Frigate ID
    /// is used as the CKRecord.ID).
    func persist(event: FrigateMQTTClient.Event) async throws {
        let recordID = CKRecord.ID(recordName: event.id)
        let record = CKRecord(recordType: Self.recordType, recordID: recordID)
        record["camera"] = event.camera as CKRecordValue
        record["label"] = event.label as CKRecordValue
        record["zones"] = event.zones as CKRecordValue
        record["topScore"] = event.topScore as CKRecordValue
        record["detectedAt"] = event.startTime as CKRecordValue

        do {
            _ = try await container.privateCloudDatabase.save(record)
        } catch let ck as CKError where ck.code == .serverRecordChanged {
            // Already written by a previous run — that's fine, event ID is the
            // natural dedupe key.
            return
        }
    }
}
