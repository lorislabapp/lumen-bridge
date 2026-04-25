import Foundation
import os

private let logger = Logger(subsystem: "com.lorislabapp.lumenbridge", category: "ConfigSync")

/// Cross-device sync of the Frigate MQTT config via NSUbiquitousKeyValueStore
/// (iCloud Key-Value Store). Lets the tvOS Bridge pick up the host /
/// credentials a user already entered on the macOS Bridge — same Apple ID,
/// no manual re-entry on a remote with no keyboard.
///
/// KVS has a 1MB total cap and per-value soft limits well above what we
/// store here (host ~30 bytes, password ~50). Updates are observed via
/// `NSUbiquitousKeyValueStore.didChangeExternallyNotification` so the
/// remote (tvOS) reconnects within seconds of a change on the source
/// (macOS).
@MainActor
final class BridgeConfigSync {
    nonisolated static let hostKey  = "lumenbridge.kvs.frigate.host"
    nonisolated static let portKey  = "lumenbridge.kvs.frigate.port"
    nonisolated static let userKey  = "lumenbridge.kvs.frigate.user"
    nonisolated static let passKey  = "lumenbridge.kvs.frigate.pass"

    private let kvs = NSUbiquitousKeyValueStore.default
    private var observerToken: NSObjectProtocol?

    /// Pulls the freshest known config from KVS. Returns nil for any field
    /// the user hasn't set yet.
    var current: PersistedConfig? {
        guard let host = kvs.string(forKey: Self.hostKey), !host.isEmpty else { return nil }
        let port = Int(kvs.longLong(forKey: Self.portKey))
        return PersistedConfig(
            host: host,
            port: port > 0 ? port : 1883,
            username: kvs.string(forKey: Self.userKey),
            password: kvs.string(forKey: Self.passKey)
        )
    }

    /// Pushes the user's config up to KVS so the same Apple ID's other
    /// Bridge installs (tvOS, future watchOS) inherit it without re-entry.
    func push(host: String, port: Int, username: String?, password: String?) {
        kvs.set(host, forKey: Self.hostKey)
        kvs.set(Int64(port), forKey: Self.portKey)
        if let username, !username.isEmpty {
            kvs.set(username, forKey: Self.userKey)
        } else {
            kvs.removeObject(forKey: Self.userKey)
        }
        if let password, !password.isEmpty {
            kvs.set(password, forKey: Self.passKey)
        } else {
            kvs.removeObject(forKey: Self.passKey)
        }
        kvs.synchronize()
        logger.info("KVS config push: \(host):\(port)")
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
            let ours: Set<String> = [Self.hostKey, Self.portKey, Self.userKey, Self.passKey]
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
