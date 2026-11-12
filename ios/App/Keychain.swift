// Deploy Center for iPhone — Tokens live in the iOS keychain, on this device only (never synced).

import Foundation
import Security

enum Keychain {
    private static let service = "app.deploycenter.ios"

    static func get(_ key: String) -> String? {
        if case .found(let v) = lookup(key) { return v }
        return nil
    }

    /// "Not there" and "could not read" apart: a locked device (before the first unlock) answers
    /// errSecInteractionNotAllowed, which must not count as "no key".
    enum Lookup { case found(String), missing, failed }
    static func lookup(_ key: String) -> Lookup {
        var item: CFTypeRef?
        let q: [String: Any] = [kSecClass as String: kSecClassGenericPassword, kSecAttrService as String: service,
                                kSecAttrAccount as String: key, kSecReturnData as String: true,
                                kSecMatchLimit as String: kSecMatchLimitOne]
        switch SecItemCopyMatching(q as CFDictionary, &item) {
        case errSecSuccess:
            guard let d = item as? Data, let s = String(data: d, encoding: .utf8) else { return .failed }
            return .found(s)
        case errSecItemNotFound: return .missing
        default: return .failed
        }
    }

    /// An empty value deletes the item. "After first unlock" so the background refresh can read it;
    /// "this device only" so it never leaves the phone, not even in a backup.
    @discardableResult
    static func set(_ key: String, _ value: String) -> Bool {
        let base: [String: Any] = [kSecClass as String: kSecClassGenericPassword, kSecAttrService as String: service,
                                   kSecAttrAccount as String: key]
        let v = value.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !v.isEmpty else {
            let r = SecItemDelete(base as CFDictionary)
            return r == errSecSuccess || r == errSecItemNotFound
        }
        // Update in place, so a failed write never leaves the old key deleted.
        let attrs: [String: Any] = [kSecValueData as String: Data(v.utf8),
                                    kSecAttrAccessible as String: kSecAttrAccessibleAfterFirstUnlockThisDeviceOnly]
        let u = SecItemUpdate(base as CFDictionary, attrs as CFDictionary)
        if u == errSecSuccess { return true }
        guard u == errSecItemNotFound else { return false }
        var add = base
        add.merge(attrs) { $1 }
        return SecItemAdd(add as CFDictionary, nil) == errSecSuccess
    }
}
