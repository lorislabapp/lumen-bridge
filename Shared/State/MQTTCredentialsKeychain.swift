import Foundation
import Security
import os

private let logger = Logger(subsystem: "com.lorislabapp.lumenbridge", category: "Keychain")

/// Keychain-backed storage for the MQTT broker password. Synchronizes
/// across the user's devices via iCloud Keychain (`kSecAttrSynchronizable`)
/// so the tvOS Bridge inherits credentials entered on the macOS Bridge
/// — same UX as the previous KVS path, but with the right Apple-recommended
/// API for secrets.
///
/// Why move off `NSUbiquitousKeyValueStore`:
/// - KVS is documented for *preferences*. Apple's privacy / security
///   review explicitly flags credential storage in KVS.
/// - Keychain entries are protected by Secure Enclave when available,
///   not just iCloud's E2E encryption.
/// - iCloud Keychain Sync provides the same cross-device replication.
enum MQTTCredentialsKeychain {
    private static let service = "com.lorislabapp.lumenbridge.mqtt"
    private static let account = "broker.password"

    /// Persist the password. Pass `nil` to remove it. Existing entry is
    /// updated in place; a fresh add only happens if the lookup misses.
    @discardableResult
    static func set(_ password: String?) -> Bool {
        // Always purge any existing entry first — `SecItemAdd` errors
        // out with `errSecDuplicateItem` if we don't, and the partial-
        // update path is brittle when `kSecAttrSynchronizable` flips.
        let baseQuery: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: service,
            kSecAttrAccount as String: account,
            // Match BOTH synced and non-synced entries during delete so
            // we don't leave stale rows behind on devices that were
            // signed in/out of iCloud at different times.
            kSecAttrSynchronizable as String: kSecAttrSynchronizableAny,
        ]
        SecItemDelete(baseQuery as CFDictionary)

        guard let password, !password.isEmpty else {
            logger.info("MQTT password cleared from Keychain")
            return true
        }

        let addQuery: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: service,
            kSecAttrAccount as String: account,
            kSecAttrAccessible as String: kSecAttrAccessibleAfterFirstUnlock,
            kSecAttrSynchronizable as String: kCFBooleanTrue!,
            kSecValueData as String: Data(password.utf8),
        ]
        let status = SecItemAdd(addQuery as CFDictionary, nil)
        if status == errSecSuccess {
            logger.info("MQTT password stored in Keychain (synced)")
            return true
        }
        logger.error("Keychain SecItemAdd failed (\(status))")
        return false
    }

    static func get() -> String? {
        let query: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: service,
            kSecAttrAccount as String: account,
            kSecAttrSynchronizable as String: kSecAttrSynchronizableAny,
            kSecReturnData as String: true,
            kSecMatchLimit as String: kSecMatchLimitOne,
        ]
        var item: CFTypeRef?
        let status = SecItemCopyMatching(query as CFDictionary, &item)
        guard status == errSecSuccess,
              let data = item as? Data,
              let password = String(data: data, encoding: .utf8) else {
            if status != errSecItemNotFound {
                logger.warning("Keychain lookup status=\(status)")
            }
            return nil
        }
        return password
    }

    /// One-time migration: pull a password previously stored under the
    /// KVS key into Keychain, then remove it from KVS. Idempotent —
    /// returns `true` only on the run where the migration actually
    /// happened (so the caller can log it without spamming on every
    /// launch).
    @discardableResult
    static func migrateFromKVS(legacyKey: String) -> Bool {
        let kvs = NSUbiquitousKeyValueStore.default
        guard let legacy = kvs.string(forKey: legacyKey), !legacy.isEmpty else {
            return false
        }
        // Don't clobber an existing Keychain entry on the destination
        // device — Keychain wins if both exist, since we're moving TO
        // Keychain.
        if get() == nil {
            _ = set(legacy)
        }
        kvs.removeObject(forKey: legacyKey)
        kvs.synchronize()
        logger.info("Migrated MQTT password KVS → Keychain")
        return true
    }
}
