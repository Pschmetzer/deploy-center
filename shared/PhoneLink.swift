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
    /// What turning auto-deploy off saves a month, in USD, as the Mac app works it out; nil when
    /// not known. Older apps on either side leave it out.
    var savingPerMonth: Double? = nil
    /// QR code only: a fresh id per code, so a phone can refuse a code it has used before.
    var once: String? = nil

    var isEmpty: Bool { vercel.isEmpty && render.isEmpty }
    /// The same keys and figures; when they were written (and a QR code's id) do not count.
    func sameContent(as o: LinkedKeys) -> Bool {
        var a = self, b = o
        a.updated = .distantPast; b.updated = .distantPast; a.once = nil; b.once = nil
        return a == b
    }
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
    /// Unchanged keys write nothing; changed ones are updated in place, so the item never vanishes
    /// from the other devices in between (a delete syncs too) and a failed write keeps the old one.
    @discardableResult
    static func write(_ keys: LinkedKeys) -> OSStatus {
        guard let g = group else { return errSecMissingEntitlement }
        if let old = read(), old.sameContent(as: keys) { return errSecSuccess }
        guard let d = try? JSONEncoder().encode(keys) else { return errSecParam }
        var find = base(g); find[kSecAttrSynchronizable as String] = kSecAttrSynchronizableAny
        let s = SecItemUpdate(find as CFDictionary, [kSecValueData as String: d] as CFDictionary)
        guard s == errSecItemNotFound else { return s }
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

    enum QRResult: Equatable {
        case keys(LinkedKeys)
        case notOurs        // some other QR code
        case newerVersion   // "deploycenter-link:2:…": the Mac app is newer than this one
        case expired        // made more than qrMaxAge ago: a photo of the screen, not the screen
        case empty          // no Vercel or Render key in it
    }
    /// The Mac shows the code for a minute; the rest allows for clocks that differ a little.
    static let qrMaxAge: TimeInterval = 5 * 60

    static func read(qr: String, now: Date = Date()) -> QRResult {
        let ours = "deploycenter-link:"
        guard qr.hasPrefix(ours) else { return .notOurs }
        guard qr.hasPrefix(qrPrefix) else { return .newerVersion }
        guard let d = Data(base64Encoded: String(qr.dropFirst(qrPrefix.count))),
              let k = try? JSONDecoder().decode(LinkedKeys.self, from: d) else { return .notOurs }
        guard abs(now.timeIntervalSince(k.updated)) <= qrMaxAge else { return .expired }
        return k.isEmpty ? .empty : .keys(k)
    }

    static func parse(qr: String, now: Date = Date()) -> LinkedKeys? {
        if case .keys(let k) = read(qr: qr, now: now) { return k }
        return nil
    }
}
