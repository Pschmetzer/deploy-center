// Deploy Center for iPhone — Tokens live in the iOS keychain, on this device only (never synced).

import Foundation
import Security

enum Keychain {
    private static let service = "app.deploycenter.ios"

    /// The app's own keychain group, "<TEAMID>.<bundle id>" (its application-identifier, always
    /// allowed). Without it iOS puts new items into the first keychain-access-groups entry: the team
    /// group of the Mac link, which every app of the team can read. nil without a team (unsigned or
    /// simulator builds): then iOS picks, as before.
    private static let ownGroup: String? = {
        let suffix = ".app.deploycenter.shared"
        guard let shared = PhoneLink.group, shared.hasSuffix(suffix),
              let id = Bundle.main.bundleIdentifier, !id.isEmpty else { return nil }
        return String(shared.dropLast(suffix.count)) + "." + id
    }()

    private static func query(_ key: String, group: String?) -> [String: Any] {
        var q: [String: Any] = [kSecClass as String: kSecClassGenericPassword, kSecAttrService as String: service,
                                kSecAttrAccount as String: key]
        if let group { q[kSecAttrAccessGroup as String] = group }
        return q
    }

    static func get(_ key: String) -> String? {
        if case .found(let v) = lookup(key) { return v }
        return nil
    }

    /// "Not there" and "could not read" apart: a locked device (before the first unlock) answers
    /// errSecInteractionNotAllowed, which must not count as "no key".
    enum Lookup { case found(String), missing, failed }
    static func lookup(_ key: String) -> Lookup {
        let r = read(key, group: ownGroup)
        guard case .missing = r, let own = ownGroup else { return r }
        // Written by an older version, into the team group: moved into the app's own group once.
        let old = read(key, group: nil)
        if case .found(let v) = old, write(key, v, group: own) == errSecSuccess {
            SecItemDelete(query(key, group: PhoneLink.group) as CFDictionary)
        }
        return old
    }

    private static func read(_ key: String, group: String?) -> Lookup {
        var item: CFTypeRef?
        var q = query(key, group: group)
        q[kSecReturnData as String] = true
        q[kSecMatchLimit as String] = kSecMatchLimitOne
        switch SecItemCopyMatching(q as CFDictionary, &item) {
        case errSecSuccess:
            guard let d = item as? Data, let s = String(data: d, encoding: .utf8) else { return .failed }
            return .found(s)
        case errSecItemNotFound: return .missing
        // A build whose own group is not in its signature: as if there were no group.
        case errSecMissingEntitlement where group != nil: return read(key, group: nil)
        default: return .failed
        }
    }

    /// An empty value deletes the item. "After first unlock" so the background refresh can read it;
    /// "this device only" so it never leaves the phone, not even in a backup.
    @discardableResult
    static func set(_ key: String, _ value: String) -> Bool {
        let v = value.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !v.isEmpty else {
            // Both places: the app's own group and an older copy in the team group.
            let a = SecItemDelete(query(key, group: ownGroup) as CFDictionary)
            var ok = a == errSecSuccess || a == errSecItemNotFound
            if ownGroup != nil, let shared = PhoneLink.group {
                let b = SecItemDelete(query(key, group: shared) as CFDictionary)
                ok = ok && (b == errSecSuccess || b == errSecItemNotFound || b == errSecMissingEntitlement)
            }
            return ok
        }
        var s = write(key, v, group: ownGroup)
        if s == errSecMissingEntitlement, ownGroup != nil { s = write(key, v, group: nil) }
        return s == errSecSuccess
    }

    /// Update in place, so a failed write never leaves the old key deleted.
    private static func write(_ key: String, _ v: String, group: String?) -> OSStatus {
        let base = query(key, group: group)
        let attrs: [String: Any] = [kSecValueData as String: Data(v.utf8),
                                    kSecAttrAccessible as String: kSecAttrAccessibleAfterFirstUnlockThisDeviceOnly]
        let u = SecItemUpdate(base as CFDictionary, attrs as CFDictionary)
        guard u == errSecItemNotFound else { return u }
        var add = base
        add.merge(attrs) { $1 }
        return SecItemAdd(add as CFDictionary, nil)
    }
}
