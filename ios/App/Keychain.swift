// Deploy Center for iPhone — Tokens live in the iOS keychain, on this device only (never synced).

import Foundation
import Security

enum Keychain {
    private static let service = "app.deploycenter.ios"

    static func get(_ key: String) -> String? {
        var item: CFTypeRef?
        let q: [String: Any] = [kSecClass as String: kSecClassGenericPassword, kSecAttrService as String: service,
                                kSecAttrAccount as String: key, kSecReturnData as String: true,
                                kSecMatchLimit as String: kSecMatchLimitOne]
        guard SecItemCopyMatching(q as CFDictionary, &item) == errSecSuccess, let d = item as? Data else { return nil }
        return String(data: d, encoding: .utf8)
    }

    /// An empty value deletes the item. "After first unlock" so the background refresh can read it;
    /// "this device only" so it never leaves the phone, not even in a backup.
    /// The old value is replaced in place, so a failed write never leaves the account without a key.
    @discardableResult
    static func set(_ key: String, _ value: String) -> Bool {
        let base: [String: Any] = [kSecClass as String: kSecClassGenericPassword, kSecAttrService as String: service,
                                   kSecAttrAccount as String: key]
        let v = value.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !v.isEmpty else {
            let s = SecItemDelete(base as CFDictionary)
            return s == errSecSuccess || s == errSecItemNotFound
        }
        if get(key) == v { return true }
        let attrs: [String: Any] = [kSecValueData as String: Data(v.utf8),
                                    kSecAttrAccessible as String: kSecAttrAccessibleAfterFirstUnlockThisDeviceOnly]
        let u = SecItemUpdate(base as CFDictionary, attrs as CFDictionary)
        if u == errSecSuccess { return true }
        guard u == errSecItemNotFound else { return false }
        return SecItemAdd(base.merging(attrs) { _, b in b } as CFDictionary, nil) == errSecSuccess
    }
}
