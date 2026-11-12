// Deploy Center — The site checks after going live and while watching, kept small on this Mac
// (FEA-097): at most 300 answers per project, none older than 30 days. Uptime is read from them.

import Foundation

enum SiteLog {
    struct Check: Codable, Equatable { let t: Double; let ok: Bool }
    static let key = "siteChecks"
    static let keep = 300
    static let days = 30.0

    /// An answer that was fine counts as up; broken counts as down. "Unreachable" (this Mac
    /// offline) and "odd" (a 4xx, maybe a wrong path) are not the site's uptime and are not kept.
    static func note(_ project: String, up: Bool, at: Date = Date()) {
        var all = load()
        all[project] = trim((all[project] ?? []) + [Check(t: at.timeIntervalSince1970, ok: up)], now: at)
        if let d = try? JSONEncoder().encode(all) { UserDefaults.standard.set(d, forKey: key) }
    }
    static func load() -> [String: [Check]] {
        guard let d = UserDefaults.standard.data(forKey: key) else { return [:] }
        return (try? JSONDecoder().decode([String: [Check]].self, from: d)) ?? [:]
    }
    static func checks(_ project: String, now: Date = Date()) -> [Check] { trim(load()[project] ?? [], now: now) }

    static func trim(_ list: [Check], now: Date = Date()) -> [Check] {
        let from = now.timeIntervalSince1970 - days * 86_400
        return Array(list.filter { $0.t >= from }.suffix(keep))
    }
    /// The share of answers that were up, nil without any.
    static func uptime(_ list: [Check]) -> Double? {
        list.isEmpty ? nil : Double(list.filter(\.ok).count) / Double(list.count)
    }
}
