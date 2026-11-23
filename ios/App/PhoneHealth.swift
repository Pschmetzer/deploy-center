// Deploy Center for iPhone — open outages and the health score, from what the list and the cached
// histories already know. Read only; nothing here starts a deploy. The formula is shared/HealthFormula.swift.

import Foundation

enum PhoneHealth {
    struct Outage: Equatable, Identifiable {
        let key: String
        let name: String
        /// The failed deploy that has not been followed by a good one; nil when the history does not say.
        let since: Date?
        var id: String { key }
    }

    /// Records, newest first as the hosts answer, as the formula's events. Canceled and other states do not count.
    static func events(_ records: [DeployRecord]) -> [HealthFormula.Event] {
        records.compactMap { r in
            guard let at = r.finishedAt ?? r.at else { return nil }
            if r.failed { return .init(at, .failed) }
            if ["ready", "live", "deactivated"].contains(r.state.lowercased()) { return .init(at, .good) }
            return nil
        }
    }

    static func score(_ records: [DeployRecord], now: Date = Date()) -> HealthFormula.Outcome {
        HealthFormula.score(events(records), now: now)
    }

    /// The projects whose newest deploy failed, the longest-running first.
    static func outages(_ projects: [PhoneProject], history: (String) -> [DeployRecord]?, now: Date = Date()) -> [Outage] {
        projects.filter(\.failed).map { p in
            let o = history(p.key).map { score($0, now: now) }
            return Outage(key: p.key, name: p.name, since: o?.openSince)
        }.sorted { ($0.since ?? .distantFuture) < ($1.since ?? .distantFuture) }
    }

    /// The average over the projects whose history is cached and gives a score; nil when none does.
    static func average(_ projects: [PhoneProject], history: (String) -> [DeployRecord]?, now: Date = Date()) -> (score: Int, projects: Int)? {
        let s = projects.compactMap { p in history(p.key).flatMap { score($0, now: now).score } }
        guard !s.isEmpty else { return nil }
        return (Int((Double(s.reduce(0, +)) / Double(s.count)).rounded()), s.count)
    }
}
