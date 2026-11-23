// Deploy Center for iPhone — Recent deploys of all projects in one list, newest first, grouped by day. Pure logic (no UIKit).
// It only sorts and groups deploys that were already read; it starts and changes nothing.

import Foundation

enum DeployTimeline {
    /// The deploys read for one project.
    struct Source {
        let key: String
        let name: String
        let records: [DeployRecord]
    }

    struct Item: Identifiable, Equatable {
        /// Project key and deploy id: a deploy id alone may repeat across providers.
        let id: String
        let projectKey: String
        let projectName: String
        let record: DeployRecord
        let at: Date
    }

    enum DayLabel: Equatable { case today, yesterday, date(Date) }

    struct Day: Identifiable, Equatable {
        let start: Date
        let label: DayLabel
        let items: [Item]
        var id: Date { start }
        var failures: Int { items.filter { $0.record.failed }.count }
    }

    /// The newest `limit` deploys of the last `days` days (today counts as one), grouped by calendar day, newest day first.
    /// A deploy without a time is left out; one dated in the future (a clock that differs) counts as today's.
    static func build(_ sources: [Source], now: Date, calendar: Calendar = .current, days: Int = 7, limit: Int = 60) -> [Day] {
        let today = calendar.startOfDay(for: now)
        guard days > 0, limit > 0, let first = calendar.date(byAdding: .day, value: -(days - 1), to: today) else { return [] }
        var items: [Item] = []
        for s in sources {
            for r in s.records {
                guard let at = r.at, at >= first else { continue }
                items.append(Item(id: s.key + "/" + r.id, projectKey: s.key, projectName: s.name, record: r, at: min(at, now)))
            }
        }
        items.sort { $0.at != $1.at ? $0.at > $1.at : $0.id < $1.id }
        var out: [Day] = []
        var current: (start: Date, items: [Item])?
        func flush() {
            guard let c = current else { return }
            out.append(Day(start: c.start, label: label(c.start, today: today, calendar: calendar), items: c.items))
        }
        for item in items.prefix(limit) {
            let day = calendar.startOfDay(for: item.at)
            if current?.start == day { current?.items.append(item) } else { flush(); current = (day, [item]) }
        }
        flush()
        return out
    }

    private static func label(_ day: Date, today: Date, calendar: Calendar) -> DayLabel {
        if day == today { return .today }
        if let y = calendar.date(byAdding: .day, value: -1, to: today), day == y { return .yesterday }
        return .date(day)
    }
}
