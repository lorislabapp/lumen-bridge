import Foundation
import Observation

/// Central observable state for the menu-bar UI. Updated by the MQTT client,
/// Discovery browser, and CloudKit writer as their status changes. Kept
/// minimal on purpose — this is what the user sees at a glance.
@Observable
final class BridgeState {
    /// True when both Frigate MQTT is connected AND CloudKit is reachable.
    var isConnected: Bool {
        mqttConnected && cloudKitStatus.isHealthy
    }

    // MARK: - Frigate / MQTT

    var mqttConnected: Bool = false
    /// True when the MQTT connection uses TLS (shown in Settings; plain MQTT
    /// gets a warning because credentials and events cross the LAN in clear).
    var mqttEncrypted: Bool = false
    // MARK: - Zone alerts

    var zoneAlerts: [ZoneAlert] = []
    /// End time of each alert's last visit.
    var lastZoneVisits: [UUID: Date] = [:]
    /// Result of each alert's last iPhone push.
    var lastZonePushOutcome: [UUID: String] = [:]
    /// Cameras → zones and labels seen on MQTT, to fill the alert pickers
    /// without asking the owner to type Frigate names. Bounded.
    private(set) var seenZones: [String: Set<String>] = [:]
    private(set) var seenLabels: Set<String> = []

    func learn(camera: String, zones: [String], label: String) {
        guard seenZones.count < 64 || seenZones[camera] != nil else { return }
        var set = seenZones[camera] ?? []
        for zone in zones where set.count < 64 { set.insert(zone) }
        if seenZones[camera] != set { seenZones[camera] = set }
        if seenLabels.count < 64, !seenLabels.contains(label) { seenLabels.insert(label) }
    }

    var frigateHost: String?
    var frigatePort: Int?
    var mqttUsername: String?
    var mqttPassword: String?
    var lastMQTTError: String?
    var eventsReceived: Int = 0
    var eventsForwarded: Int = 0
    var lastEventAt: Date?

    // MARK: - CloudKit

    var cloudKitStatus: CloudKitStatus = .unknown

    // MARK: - HomeKit (Phase 5)

    var hapStatus: HAPStatus = .stopped
    #if os(macOS)
    /// Lifecycle of the optional Homebridge sidecar that powers HomeKit
    /// camera streaming (Phase 5 v0.2). macOS-only — tvOS doesn't host
    /// HAP camera accessories. Independent of `hapStatus` so users can
    /// have motion sensors alone, cameras alone, or both.
    var homebridgeStatus: HomebridgeStatus = .stopped
    var cameraStatuses: [BridgeCameraStatus] = []
    var notificationTestSentAt: Date?
    var notificationTestFailed = false
    #endif

    // MARK: - Discovery

    var discoveredInstances: [DiscoveredFrigate] = []
}

/// Lifecycle state of the optional HomeKit Accessory Protocol bridge.
/// Only the macOS Bridge currently supports HAP (tvOS would require its
/// own pairing flow). Surfaced in the menu-bar UI so users can grab the
/// pairing QR code and see how many accessories are exposed.
enum HAPStatus: Equatable {
    case stopped
    case running(setupCode: String, setupID: String, accessoryCount: Int)
    case error(String)

    var isRunning: Bool {
        if case .running = self { return true }
        return false
    }
}

enum CloudKitStatus: Equatable {
    case unknown
    case noAccount
    case available
    case error(String)

    var isHealthy: Bool {
        if case .available = self { return true }
        return false
    }

    var humanReadable: String {
        switch self {
        case .unknown:
            return String(localized: "Checking…")
        case .noAccount:
            return String(localized: "Sign in to iCloud in System Settings")
        case .available:
            return String(localized: "Connected to iCloud")
        case .error(let reason):
            return String(localized: "Error: \(reason)")
        }
    }
}

struct DiscoveredFrigate: Identifiable, Equatable {
    let id: String     // service name, unique on the network
    let host: String
    let port: Int
    let netServiceName: String
}
