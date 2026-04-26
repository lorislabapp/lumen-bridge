import Foundation
import os

private let logger = Logger(subsystem: "com.lorislabapp.lumenbridge", category: "ConfigSync")

/// Cross-device sync of the Frigate MQTT config. Non-secret fields
/// (host, port, username) live in NSUbiquitousKeyValueStore. The
/// password is stored in iCloud Keychain via `MQTTCredentialsKeychain`
/// per Apple's secrets-handling guidance (KVS is for preferences, not
/// credentials).
///
/// Cross-device replication semantics are unchanged — both KVS and
/// iCloud Keychain replicate within seconds of a change.
///
/// KVS has a 1MB total cap and per-value soft limits well above what we
/// store here (host ~30 bytes). Updates are observed via
/// `NSUbiquitousKeyValueStore.didChangeExternallyNotification` so the
/// remote (tvOS) reconnects within seconds of a change on the source
/// (macOS).
@MainActor
final class BridgeConfigSync {
    nonisolated static let hostKey  = "lumenbridge.kvs.frigate.host"
    nonisolated static let portKey  = "lumenbridge.kvs.frigate.port"
    nonisolated static let userKey  = "lumenbridge.kvs.frigate.user"
    /// Legacy key — only kept for the one-time migration path that
    /// pulls any pre-existing KVS value into Keychain on launch.
    /// Do NOT write through this key.
    nonisolated static let legacyPassKey = "lumenbridge.kvs.frigate.pass"

    private let kvs = NSUbiquitousKeyValueStore.default
    private var observerToken: NSObjectProtocol?

    init() {
        // Migrate any legacy KVS-stored password to Keychain on first
        // launch after the upgrade. No-op if there's nothing to move.
        MQTTCredentialsKeychain.migrateFromKVS(legacyKey: Self.legacyPassKey)
    }

    /// Pulls the freshest known config. Host/port/username come from
    /// KVS; password from Keychain. Returns nil when the user hasn't
    /// set a host yet.
    var current: PersistedConfig? {
        guard let host = kvs.string(forKey: Self.hostKey), !host.isEmpty else { return nil }
        let port = Int(kvs.longLong(forKey: Self.portKey))
        return PersistedConfig(
            host: host,
            port: port > 0 ? port : 1883,
            username: kvs.string(forKey: Self.userKey),
            password: MQTTCredentialsKeychain.get()
        )
    }

    /// Pushes the user's config up. Host/port/username → KVS, password
    /// → iCloud Keychain. Same Apple ID's other Bridge installs (tvOS,
    /// future watchOS) inherit both without re-entry.
    func push(host: String, port: Int, username: String?, password: String?) {
        kvs.set(host, forKey: Self.hostKey)
        kvs.set(Int64(port), forKey: Self.portKey)
        if let username, !username.isEmpty {
            kvs.set(username, forKey: Self.userKey)
        } else {
            kvs.removeObject(forKey: Self.userKey)
        }
        kvs.synchronize()
        MQTTCredentialsKeychain.set(password)
        logger.info("Config push: \(host):\(port) (password via Keychain)")
    }

    /// Subscribe to remote changes so the bridge reconnects when the user
    /// edits the config on a different device under the same Apple ID.
    func observeRemoteChanges(_ handler: @escaping @MainActor (PersistedConfig) -> Void) {
        observerToken = NotificationCenter.default.addObserver(
            forName: NSUbiquitousKeyValueStore.didChangeExternallyNotification,
            object: kvs,
            queue: .main
        ) { note in
            // Filter — we only react when one of OUR keys changed.
            let changed = note.userInfo?[NSUbiquitousKeyValueStoreChangedKeysKey] as? [String] ?? []
            // Legacy passKey still observed so a tail-end migration on a
            // remote device fires the reconnect handler — even though we
            // never write the password through KVS anymore.
            let ours: Set<String> = [Self.hostKey, Self.portKey, Self.userKey, Self.legacyPassKey]
            guard changed.contains(where: ours.contains) else { return }
            // Hop back to the main actor before touching `current`, which
            // is @MainActor-isolated. The notification queue is `.main`
            // but the closure is treated as Sendable by the compiler.
            Task { @MainActor [weak self] in
                guard let self, let cfg = self.current else { return }
                handler(cfg)
            }
        }
        // Kick KVS to fetch latest from server before we read.
        kvs.synchronize()
    }

    // Intentionally no `deinit` cleanup of `observerToken`: the manager
    // is owned by `BridgeCoordinator` for the app's lifetime. Reaching
    // into a non-Sendable observer reference from a nonisolated deinit
    // trips Swift 6 strict concurrency, and there's no real-world path
    // where this object outlives the process.

    struct PersistedConfig: Equatable, Sendable {
        let host: String
        let port: Int
        let username: String?
        let password: String?
    }
}
