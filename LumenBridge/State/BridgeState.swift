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
    var frigateHost: String?
    var frigatePort: Int?
    var eventsReceived: Int = 0
    var eventsForwarded: Int = 0
    var lastEventAt: Date?

    // MARK: - CloudKit

    var cloudKitStatus: CloudKitStatus = .unknown

    // MARK: - Discovery

    var discoveredInstances: [DiscoveredFrigate] = []
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
            return "Checking…"
        case .noAccount:
            return "Sign in to iCloud in System Settings"
        case .available:
            return "Connected to iCloud"
        case .error(let reason):
            return "Error: \(reason)"
        }
    }
}

struct DiscoveredFrigate: Identifiable, Equatable {
    let id: String     // service name, unique on the network
    let host: String
    let port: Int
    let netServiceName: String
}
