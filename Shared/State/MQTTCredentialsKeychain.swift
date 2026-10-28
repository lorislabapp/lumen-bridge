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
/// - Keychain applies system data protection and iCloud Keychain's
///   end-to-end encrypted synchronization. Generic-password entries are
///   not Secure Enclave keys, so we deliberately do not claim they are.
/// - iCloud Keychain Sync provides the same cross-device replication.
enum MQTTCredentialsKeychain {
    private static let service = "com.lorislabapp.lumenbridge.mqtt"
    private static let account = "broker.password"

    /// Persist the password. Pass `nil` to remove it. Existing entry is
    /// updated in place; a fresh add only happens if the lookup misses.
    @discardableResult
    static func set(_ password: String?) -> Bool {
        let baseQuery: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: service,
            kSecAttrAccount as String: account,
            // Match BOTH synced and non-synced entries during delete so
            // we don't leave stale rows behind on devices that were
            // signed in/out of iCloud at different times.
            kSecAttrSynchronizable as String: kSecAttrSynchronizableAny,
        ]
        guard let password, !password.isEmpty else {
            let status = SecItemDelete(baseQuery as CFDictionary)
            guard status == errSecSuccess || status == errSecItemNotFound else {
                logger.error("Keychain SecItemDelete failed (\(status))")
                return false
            }
            logger.info("MQTT password cleared from Keychain")
            return true
        }

        let value = Data(password.utf8)
        let update: [String: Any] = [
            kSecValueData as String: value,
            kSecAttrAccessible as String: kSecAttrAccessibleAfterFirstUnlock,
        ]
        let updateStatus = SecItemUpdate(baseQuery as CFDictionary, update as CFDictionary)
        if updateStatus == errSecSuccess {
            logger.info("MQTT password updated in Keychain")
            return true
        }
        guard updateStatus == errSecItemNotFound else {
            logger.error("Keychain SecItemUpdate failed (\(updateStatus))")
            return false
        }

        let addQuery: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: service,
            kSecAttrAccount as String: account,
            kSecAttrAccessible as String: kSecAttrAccessibleAfterFirstUnlock,
            kSecAttrSynchronizable as String: kCFBooleanTrue!,
            kSecValueData as String: value,
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
        if get() == nil, !set(legacy) {
            logger.error("MQTT password KVS → Keychain migration failed; preserving legacy value")
            return false
        }
        kvs.removeObject(forKey: legacyKey)
        kvs.synchronize()
        logger.info("Migrated MQTT password KVS → Keychain")
        return true
    }

    /// One-time migration from the historical local UserDefaults key.
    /// The plaintext value is removed only after a Keychain value is known
    /// to exist, so an unavailable Keychain never destroys the credential.
    @discardableResult
    static func migrateFromUserDefaults(_ defaults: UserDefaults = .standard, legacyKey: String) -> Bool {
        guard let legacy = defaults.string(forKey: legacyKey), !legacy.isEmpty else {
            return false
        }
        if get() == nil, !set(legacy) {
            logger.error("MQTT password UserDefaults → Keychain migration failed; preserving legacy value")
            return false
        }
        defaults.removeObject(forKey: legacyKey)
        logger.info("Migrated MQTT password UserDefaults → Keychain")
        return true
    }
}
