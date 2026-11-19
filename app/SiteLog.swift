// Deploy Center — The site checks after going live and while watching, kept small on this Mac
// (FEA-097): at most 300 answers per project, none older than 30 days. Uptime is read from them.

import Foundation

enum SiteLog {
    struct Check: Codable, Equatable { let t: Double; let ok: Bool }
    static let key = "siteChecks"
    /// Room for a long watch: checks of one burst (a few minutes, same answer) are merged, see `note`.
    static let keep = 1500
    private static let lock = NSLock()
    /// Answers closer than this with the same result are one check (a watch writes many).
    static let merge = 300.0
    /// A gap longer than this is "not watched", not "up".
    static let gapCap = 6.0 * 3600
    static let days = 30.0

    /// An answer that was fine counts as up; broken counts as down. "Unreachable" (this Mac
    /// offline) and "odd" (a 4xx, maybe a wrong path) are not the site's uptime and are not kept.
    static func note(_ project: String, up: Bool, at: Date = Date()) {
        lock.lock(); defer { lock.unlock() }
        var all = load()
        var list = all[project] ?? []
        let t = at.timeIntervalSince1970
        if let last = list.last, last.ok == up, t - last.t < merge, t >= last.t { list[list.count - 1] = Check(t: t, ok: up) }
        else { list.append(Check(t: t, ok: up)) }
        all[project] = trim(list, now: at)
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
    /// The share of time the site was up: each check counts for the time until the next one (at most
    /// `gapCap`), the last one as long as the one before. Ten quick checks after a deploy weigh
    /// ten seconds, not ten days. Nil without any check.
    static func uptime(_ list: [Check]) -> Double? {
        guard !list.isEmpty else { return nil }
        let l = list.sorted { $0.t < $1.t }
        var up = 0.0, total = 0.0, prev = 1.0
        for (i, c) in l.enumerated() {
            let w = i + 1 < l.count ? min(max(l[i + 1].t - c.t, 0), gapCap) : prev
            prev = max(w, 1)
            up += c.ok ? w : 0; total += w
        }
        return total > 0 ? up / total : Double(l.filter(\.ok).count) / Double(l.count)
    }
}
