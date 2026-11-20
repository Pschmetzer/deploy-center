// Deploy Center for iPhone — Tokens live in the iOS keychain, on this device only (never synced).

import Foundation
import Security

/// The three calls the logic below needs from the keychain, so a test can answer them (the migration from the team group,
/// the fall back when a group is not in the signature) without a device.
protocol KeychainBackend {
    func copy(_ key: String, group: String?) -> (status: OSStatus, data: Data?)
    /// Update in place; adds when there is no item.
    func write(_ key: String, _ value: Data, group: String?) -> OSStatus
    func delete(_ key: String, group: String?) -> OSStatus
}

/// The real keychain of the device.
struct SystemKeychain: KeychainBackend {
    private let service = "app.deploycenter.ios"
    private func query(_ key: String, group: String?) -> [String: Any] {
        var q: [String: Any] = [kSecClass as String: kSecClassGenericPassword, kSecAttrService as String: service,
                                kSecAttrAccount as String: key]
        if let group { q[kSecAttrAccessGroup as String] = group }
        return q
    }
    func copy(_ key: String, group: String?) -> (status: OSStatus, data: Data?) {
        var item: CFTypeRef?
        var q = query(key, group: group)
        q[kSecReturnData as String] = true
        q[kSecMatchLimit as String] = kSecMatchLimitOne
        let s = SecItemCopyMatching(q as CFDictionary, &item)
        return (s, item as? Data)
    }
    func write(_ key: String, _ value: Data, group: String?) -> OSStatus {
        let base = query(key, group: group)
        let attrs: [String: Any] = [kSecValueData as String: value,
                                    kSecAttrAccessible as String: kSecAttrAccessibleAfterFirstUnlockThisDeviceOnly]
        let u = SecItemUpdate(base as CFDictionary, attrs as CFDictionary)
        guard u == errSecItemNotFound else { return u }
        var add = base
        add.merge(attrs) { $1 }
        return SecItemAdd(add as CFDictionary, nil)
    }
    func delete(_ key: String, group: String?) -> OSStatus { SecItemDelete(query(key, group: group) as CFDictionary) }
}

enum Keychain {
    /// Tests put a fake here.
    nonisolated(unsafe) static var backend: KeychainBackend = SystemKeychain()

    /// The app's own keychain group, "<TEAMID>.<bundle id>" (its application-identifier, always
    /// allowed). Without it iOS puts new items into the first keychain-access-groups entry: the team
    /// group of the Mac link, which every app of the team can read. nil without a team (unsigned or
    /// simulator builds): then iOS picks, as before.
    nonisolated(unsafe) static var ownGroup: String? = {
        let suffix = ".app.deploycenter.shared"
        guard let shared = PhoneLink.group, shared.hasSuffix(suffix),
              let id = Bundle.main.bundleIdentifier, !id.isEmpty else { return nil }
        return String(shared.dropLast(suffix.count)) + "." + id
    }()
    /// The team group of the Mac link (where older versions wrote the keys).
    nonisolated(unsafe) static var sharedGroup: String? = PhoneLink.group

    static func get(_ key: String) -> String? {
        if case .found(let v) = lookup(key) { return v }
        return nil
    }

    /// "Not there" and "could not read" apart: a locked device (before the first unlock) answers
    /// errSecInteractionNotAllowed, which must not count as "no key".
    enum Lookup: Equatable { case found(String), missing, failed }
    static func lookup(_ key: String) -> Lookup {
        let r = read(key, group: ownGroup)
        guard case .missing = r, let own = ownGroup else { return r }
        // Written by an older version, into the team group: moved into the app's own group once.
        let old = read(key, group: nil)
        if case .found(let v) = old, write(key, v, group: own) == errSecSuccess {
            _ = backend.delete(key, group: sharedGroup)
        }
        return old
    }

    private static func read(_ key: String, group: String?) -> Lookup {
        let r = backend.copy(key, group: group)
        switch r.status {
        case errSecSuccess:
            guard let d = r.data, let s = String(data: d, encoding: .utf8) else { return .failed }
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
            let a = backend.delete(key, group: ownGroup)
            var ok = a == errSecSuccess || a == errSecItemNotFound
            if ownGroup != nil, let shared = sharedGroup {
                let b = backend.delete(key, group: shared)
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
        backend.write(key, Data(v.utf8), group: group)
    }
}
