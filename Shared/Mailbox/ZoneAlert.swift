import Foundation

/// One owner-defined zone alert: "tell me when someone (or a car…) passes
/// through this zone of this camera". The mailbox is one example; a gate,
/// a front door or a driveway work the same way.
struct ZoneAlert: Codable, Sendable, Equatable, Identifiable {
    var id: UUID = UUID()
    /// Shown in the notification title and as the HomeKit doorbell name.
    var name: String
    var enabled: Bool = true
    var configuration: MailboxMonitor.Configuration

    var isValid: Bool {
        !name.trimmingCharacters(in: .whitespaces).isEmpty && name.count <= 64 && configuration.isValid
    }
}

/// Persistence for zone alerts (UserDefaults, JSON). Migrates the single
/// mailbox configuration saved by earlier builds into one alert.
enum ZoneAlertStore {
    static let key = "lumenbridge.zone_alerts.v1"
    /// Single-mailbox setting saved by earlier builds.
    static let legacyMailboxKey = "lumenbridge.mailbox.configuration.v1"
    static let maximumAlerts = 16

    static func load(defaults: UserDefaults = .standard) -> [ZoneAlert] {
        if let data = defaults.data(forKey: key),
           let alerts = try? JSONDecoder().decode([ZoneAlert].self, from: data) {
            return alerts
        }
        // One-time migration from the mailbox-only setting.
        if let data = defaults.data(forKey: legacyMailboxKey),
           let legacy = try? JSONDecoder().decode(MailboxMonitor.Configuration.self, from: data) {
            let migrated = [ZoneAlert(name: String(localized: "Mailbox", comment: "HomeKit doorbell accessory name"),
                                      configuration: legacy)]
            save(migrated, defaults: defaults)
            defaults.removeObject(forKey: legacyMailboxKey)
            return migrated
        }
        return []
    }

    static func save(_ alerts: [ZoneAlert], defaults: UserDefaults = .standard) {
        let kept = Array(alerts.filter(\.isValid).prefix(maximumAlerts))
        if let data = try? JSONEncoder().encode(kept) {
            defaults.set(data, forKey: key)
        }
    }
}
