// Deploy Center — a nudge to renew a login or key that has been in use for a long time. The script
// cannot tell a token's real age, so the app remembers the day it first saw a platform signed in
// and says "in use for N days" after 90. Only dates are stored, never a key.

import Foundation

enum TokenAge {
    static let key = "credentialFirstSeen"
    static let limitDays = 90

    /// Adds today for every platform that is signed in and not yet known; forgets the ones signed out
    /// (a new login starts a new count).
    nonisolated static func update(_ seen: [String: Double], signedIn: [String: Bool], now: Date = Date()) -> [String: Double] {
        var out = seen
        for (id, on) in signedIn {
            if on { if out[id] == nil { out[id] = now.timeIntervalSince1970 } } else { out.removeValue(forKey: id) }
        }
        return out
    }

    /// Whole days the platform has been signed in, nil when unknown.
    nonisolated static func days(_ seen: [String: Double], id: String, now: Date = Date()) -> Int? {
        seen[id].map { max(0, Int(now.timeIntervalSince1970 - $0) / 86400) }
    }

    static func load() -> [String: Double] { (UserDefaults.standard.dictionary(forKey: key) as? [String: Double]) ?? [:] }
    static func save(_ v: [String: Double]) { UserDefaults.standard.set(v, forKey: key) }
}
