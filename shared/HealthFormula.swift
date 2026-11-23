// Deploy Center — the health score of one project, 0-100: the formula of `deploys health`
// (docs/CLI.md), for the Mac app and the iPhone app. Foundation only.
//   failures 40: failed / (deploys + failed) in the window: 0 % earns all, 50 % or more earns 0
//   recovery 25: a failure still open earns 0; none earns all; else the median time from a failure to the next
//                good deploy: 1 hour or less earns all, 72 hours or more earns 0
//   freshness 20: age of the last good deploy: 7 days or less earns all, 90 days or more earns 0
//   CI 15: green or none all, pending 10, red 0 (unknown: left out)
// A part without data is left out and the rest scaled to 100: a missing fact is never good or bad.

import Foundation

enum HealthFormula {
    enum Kind { case good, failed, rollback }
    struct Event: Equatable { let at: Date; let kind: Kind; init(_ at: Date, _ kind: Kind) { self.at = at; self.kind = kind } }
    struct Part: Equatable { let points: Double?; let max: Double }
    struct Outcome: Equatable {
        /// nil when no part had data.
        let score: Int?
        let deploys: Int
        let failures: Int
        /// A failure that no later good deploy or rollback has ended.
        let openSince: Date?
        let parts: [String: Part]
        var openOutage: Bool { openSince != nil }
        /// "good" 80 or more, "watch" 50 or more, else "poor".
        var rating: String? { score.map { $0 >= 80 ? "good" : ($0 >= 50 ? "watch" : "poor") } }
    }

    /// `best` or better earns `max`, `worst` or worse earns 0, linear between.
    static func lerp(_ v: Double, best: Double, worst: Double, max: Double) -> Double {
        v <= best ? max : (v >= worst ? 0 : max * (worst - v) / (worst - best))
    }

    static func median(_ v: [Double]) -> Double? {
        guard !v.isEmpty else { return nil }
        let s = v.sorted(), m = s.count / 2
        return s.count % 2 == 1 ? s[m] : (s[m - 1] + s[m]) / 2
    }

    /// `ci`: "green", "none", "pending" or "red"; anything else leaves that part out.
    static func score(_ events: [Event], now: Date = Date(), days: Int = 30, ci: String? = nil) -> Outcome {
        let e = events.filter { $0.at <= now }.sorted { $0.at < $1.at }
        let from = now.addingTimeInterval(-Double(days) * 86400)
        let window = e.filter { $0.at >= from }
        let d = window.filter { $0.kind == .good }.count, f = window.filter { $0.kind == .failed }.count
        var open: Date?
        var restore: [Double] = []
        for x in e {
            if x.kind == .failed { if open == nil { open = x.at } }
            else if let o = open { if x.at >= from { restore.append(x.at.timeIntervalSince(o)) }; open = nil }
        }
        let last = e.filter { $0.kind == .good }.map(\.at).max()
        let pf: Double? = d + f == 0 ? nil : lerp(Double(f) / Double(d + f), best: 0, worst: 0.5, max: 40)
        let pr: Double? = d + f == 0 ? nil : (open != nil ? 0 : (restore.isEmpty ? 25 : lerp(median(restore) ?? 0, best: 3600, worst: 259200, max: 25)))
        let pa: Double? = last.map { lerp(now.timeIntervalSince($0) / 86400, best: 7, worst: 90, max: 20) }
        let pc: Double? = ci.flatMap { ["green": 15.0, "none": 15, "pending": 10, "red": 0][$0] }
        let parts: [(String, Double?, Double)] = [("failures", pf, 40), ("recovery", pr, 25), ("freshness", pa, 20), ("ci", pc, 15)]
        let got = parts.filter { $0.1 != nil }
        let maxSum = got.map(\.2).reduce(0, +)
        let total = got.compactMap(\.1).reduce(0, +)
        return Outcome(score: got.isEmpty ? nil : Int((total * 100 / maxSum).rounded()), deploys: d, failures: f, openSince: open,
                       parts: Dictionary(uniqueKeysWithValues: parts.map { ($0.0, Part(points: $0.1.map { ($0 * 10).rounded() / 10 }, max: $0.2)) }))
    }
}
