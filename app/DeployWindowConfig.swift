// Deploy Center — The deploy window rules (~/.config/deploys/window.json), edited in the app.

import Foundation

/// ~/.config/deploys/window.json, the rules `deploys window` reads (docs/SAFE-DEPLOY.md), for
/// editing in the app. Keys the app does not know stay as they are when it is saved.
struct DeployWindowConfig: Equatable {
    struct Rule: Equatable, Identifiable {
        var id = UUID()
        /// "mon" … "sun"; empty is every day.
        var days: [String] = []
        /// "2026-12-24"; empty is any date.
        var dates: [String] = []
        /// "15:00"; nil is 00:00 (from) or 24:00 (to). A "from" after "to" runs over midnight.
        var from: String? = nil
        var to: String? = nil
        var reason: String? = nil
        /// Keys of the rule this app does not know (projects, tz …), written back unchanged (IDEEN-11 177).
        var extra: [String: Any] = [:]
        static func == (a: Rule, b: Rule) -> Bool {
            a.days == b.days && a.dates == b.dates && a.from == b.from && a.to == b.to && a.reason == b.reason
                && NSDictionary(dictionary: a.extra).isEqual(to: b.extra)
        }
    }
    var deny: [Rule] = []

    static var url: URL {
        let dir = ProcessInfo.processInfo.environment["DEPLOYS_CONFIG"].map { URL(fileURLWithPath: $0) }
            ?? FileManager.default.homeDirectoryForCurrentUser.appendingPathComponent(".config/deploys")
        return dir.appendingPathComponent("window.json")
    }
    /// The file exists but is not a JSON object (a typo by hand): the app does not write over it.
    static func unreadable(_ data: Data?) -> Bool {
        guard let data, !data.isEmpty else { return false }
        return ((try? JSONSerialization.jsonObject(with: data)) as? [String: Any]) == nil
    }
    static let weekdays = ["mon", "tue", "wed", "thu", "fri", "sat", "sun"]

    /// "9:5" is not a time; "09:05" and "24:00" are.
    static func validTime(_ s: String) -> Bool {
        let p = s.split(separator: ":", omittingEmptySubsequences: false)
        guard p.count == 2, p[0].count == 2, p[1].count == 2, let h = Int(p[0]), let m = Int(p[1]) else { return false }
        return (0...23).contains(h) && (0...59).contains(m) || (h == 24 && m == 0)
    }
    /// Why the rules cannot be saved, or nil.
    var problem: String? {
        for r in deny {
            for t in [r.from, r.to].compactMap({ $0 }) where !Self.validTime(t) {
                return L("\"\(t)\" is not a time like 15:00", "\"\(t)\" ist keine Uhrzeit wie 15:00")
            }
            if let d = r.days.first(where: { !Self.weekdays.contains($0) }) { return L("Unknown day \"\(d)\"", "Unbekannter Tag \"\(d)\"") }
        }
        return nil
    }

    static func parse(_ data: Data?) -> DeployWindowConfig {
        guard let data, let root = (try? JSONSerialization.jsonObject(with: data)) as? [String: Any],
              let rules = root["deny"] as? [[String: Any]] else { return DeployWindowConfig() }
        return DeployWindowConfig(deny: rules.map { r in
            Rule(days: (r["days"] as? [String] ?? []).map { String($0.lowercased().prefix(3)) }, dates: r["dates"] as? [String] ?? [],
                 from: r["from"] as? String, to: r["to"] as? String, reason: r["reason"] as? String,
                 extra: r.filter { !["days", "dates", "from", "to", "reason"].contains($0.key) })
        })
    }

    /// The file's text with `deny` replaced; other keys of `old` are kept.
    func encoded(over old: Data?) throws -> Data {
        var root = old.flatMap { (try? JSONSerialization.jsonObject(with: $0)) as? [String: Any] } ?? [:]
        root["deny"] = deny.map { r -> [String: Any] in
            var o: [String: Any] = r.extra
            if !r.days.isEmpty { o["days"] = r.days }
            if !r.dates.isEmpty { o["dates"] = r.dates }
            if let f = r.from, !f.isEmpty { o["from"] = f }
            if let t = r.to, !t.isEmpty { o["to"] = t }
            if let w = r.reason, !w.isEmpty { o["reason"] = w }
            return o
        }
        var d = try JSONSerialization.data(withJSONObject: root, options: [.prettyPrinted, .sortedKeys, .withoutEscapingSlashes])
        d.append(0x0A)
        return d
    }

    static func load() -> DeployWindowConfig { parse(try? Data(contentsOf: url)) }
    /// Writes the rules (none: `"deny": []`, other keys stay). An error text when it failed.
    func save() -> String? {
        if let p = problem { return p }
        let u = Self.url
        let old = try? Data(contentsOf: u)
        if Self.unreadable(old) {
            return L("window.json is not valid JSON; nothing was changed. Fix it by hand first.",
                     "window.json ist kein gültiges JSON; es wurde nichts geändert. Erst von Hand korrigieren.")
        }
        // No file and no rules: nothing to write.
        if deny.isEmpty && old == nil { return nil }
        do {
            try PrivateFile.write(try encoded(over: old), to: u)
            return nil
        } catch { return error.localizedDescription }
    }
}
