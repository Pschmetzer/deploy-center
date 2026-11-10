// Deploy Center — The link between the Mac app and the iPhone app. Shared by both.
//
// The Mac app puts the keys it already uses into one iCloud Keychain item, in a keychain group of
// the developer team ("<TEAMID>.app.deploycenter.shared"). iCloud Keychain carries it, end-to-end
// encrypted, to every device signed in with the same Apple ID, and the iPhone app reads it there.
// There is no server of ours: the person's Apple ID is the account.
// The other way, without iCloud: the Mac shows the same keys as a QR code for a minute.

import Foundation
import Security

struct LinkedKeys: Codable, Equatable {
    var vercel = ""
    var vercelTeam = ""
    var render = ""
    var github = ""
    var updated = Date()

    var isEmpty: Bool { vercel.isEmpty && render.isEmpty }
}

enum PhoneLink {
    static let service = "app.deploycenter.link"
    static let account = "keys"
    static let qrPrefix = "deploycenter-link:1:"

    /// The keychain group, from the Info.plist key DCKeychainGroup. nil when this build has none
    /// (a build without the team, or the Mac app without its profile): then there is no iCloud link.
    static var group: String? {
        guard let g = Bundle.main.object(forInfoDictionaryKey: "DCKeychainGroup") as? String,
              !g.hasPrefix("."), !g.contains("$("), g.count > ".app.deploycenter.shared".count else { return nil }
        return g
    }

    private static func base(_ group: String) -> [String: Any] {
        var q: [String: Any] = [kSecClass as String: kSecClassGenericPassword, kSecAttrService as String: service,
                                kSecAttrAccount as String: account, kSecAttrAccessGroup as String: group]
        #if os(macOS)
        q[kSecUseDataProtectionKeychain as String] = true   // the only macOS keychain that syncs
        #endif
        return q
    }

    /// The keys the Mac put into iCloud Keychain, or nil. Synced items are only found with
    /// kSecAttrSynchronizableAny.
    static func read() -> LinkedKeys? {
        guard let g = group else { return nil }
        var q = base(g)
        q[kSecAttrSynchronizable as String] = kSecAttrSynchronizableAny
        q[kSecReturnData as String] = true
        q[kSecMatchLimit as String] = kSecMatchLimitOne
        var out: CFTypeRef?
        guard SecItemCopyMatching(q as CFDictionary, &out) == errSecSuccess, let d = out as? Data else { return nil }
        return try? JSONDecoder().decode(LinkedKeys.self, from: d)
    }

    /// Writes the keys (Mac). "After first unlock", not "this device only": that is what lets it sync.
    @discardableResult
    static func write(_ keys: LinkedKeys) -> OSStatus {
        guard let g = group else { return errSecMissingEntitlement }
        guard let d = try? JSONEncoder().encode(keys) else { return errSecParam }
        var del = base(g); del[kSecAttrSynchronizable as String] = kSecAttrSynchronizableAny
        SecItemDelete(del as CFDictionary)
        var add = base(g)
        add[kSecAttrSynchronizable as String] = kCFBooleanTrue
        add[kSecAttrAccessible as String] = kSecAttrAccessibleAfterFirstUnlock
        add[kSecAttrLabel as String] = "Deploy Center: keys for the iPhone"
        add[kSecValueData as String] = d
        return SecItemAdd(add as CFDictionary, nil)
    }

    /// Removes the item here and, through iCloud Keychain, on the other devices.
    @discardableResult
    static func remove() -> OSStatus {
        guard let g = group else { return errSecMissingEntitlement }
        var del = base(g); del[kSecAttrSynchronizable as String] = kSecAttrSynchronizableAny
        return SecItemDelete(del as CFDictionary)
    }

    // MARK: QR code

    static func qrText(_ keys: LinkedKeys) -> String? {
        guard let d = try? JSONEncoder().encode(keys) else { return nil }
        return qrPrefix + d.base64EncodedString()
    }

    /// The Mac shows a code for a minute; older ones (a photo, a screenshot) are refused.
    /// A little slack both ways for clocks that are not quite in step.
    static let qrMaxAge: TimeInterval = 120

    enum QRResult: Equatable { case keys(LinkedKeys), notOurs, expired }

    static func read(qr: String, now: Date = Date()) -> QRResult {
        guard qr.hasPrefix(qrPrefix), let d = Data(base64Encoded: String(qr.dropFirst(qrPrefix.count))),
              let k = try? JSONDecoder().decode(LinkedKeys.self, from: d), !k.isEmpty else { return .notOurs }
        guard abs(now.timeIntervalSince(k.updated)) <= qrMaxAge else { return .expired }
        return .keys(k)
    }

    static func parse(qr: String) -> LinkedKeys? {
        if case .keys(let k) = read(qr: qr) { return k }
        return nil
    }
}
