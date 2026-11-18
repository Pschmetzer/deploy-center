// Deploy Center — a weekly goal ("at most N deploys") and projects without a deploy for a long
// time, both from this Mac's journal. Pure rules first (tested), the settings section after.

import SwiftUI

enum WeekGoals {
    /// Deploys that went somewhere since Monday 00:00 of the week `now` is in.
    nonisolated static func thisWeek(_ list: [JournalEntry], now: Date = Date(), calendar: Calendar = .current) -> Int {
        var cal = calendar; cal.firstWeekday = 2
        guard let start = cal.dateInterval(of: .weekOfYear, for: now)?.start else { return 0 }
        return JournalStats.outcomes(list).filter { $0.at >= start && $0.at <= now }.count
    }

    enum State: Equatable { case off, ok, last, over }
    /// "At most N": green below, "last one" at N−1, over above N. 0 = no goal.
    nonisolated static func state(count: Int, goal: Int) -> State {
        guard goal > 0 else { return .off }
        return count > goal ? .over : (count >= goal ? .last : .ok)
    }

    /// Projects whose last deploy is older than `days`, oldest first, as "platform/name".
    nonisolated static func idle(_ list: [JournalEntry], days: Int = 90, now: Date = Date()) -> [(project: String, last: Date)] {
        var last: [String: Date] = [:]
        for e in JournalStats.outcomes(list) { let k = "\(e.platform)/\(e.name)"; if (last[k] ?? .distantPast) < e.at { last[k] = e.at } }
        let limit = now.addingTimeInterval(-Double(days) * 86400)
        return last.filter { $0.value < limit }.map { (project: $0.key, last: $0.value) }.sorted { $0.last < $1.last }
    }
}

struct GoalsSection: View {
    @AppStorage("weeklyGoal") private var goal = 0
    @State private var entries: [JournalEntry] = []
    var body: some View {
        Section(L("Goals and idle projects", "Ziele und ruhende Projekte")) {
            HStack {
                Text(L("At most this many deploys a week (0 = off)", "Höchstens so viele Deploys pro Woche (0 = aus)"))
                Spacer()
                Stepper(value: $goal, in: 0...999) { Text("\(goal)").monospacedDigit() }
                    .accessibilityLabel(L("Weekly deploy goal", "Wochenziel für Deploys"))
            }
            let n = WeekGoals.thisWeek(entries)
            if goal > 0 {
                let s = WeekGoals.state(count: n, goal: goal)
                Text(L("This week: \(n) of \(goal)", "Diese Woche: \(n) von \(goal)"))
                    .foregroundStyle(s == .over ? Color.red : (s == .last ? Color.orange : Color.secondary))
            }
            // The week in review: the last 7 days, and the 7 before them for comparison.
            let p = JournalStats.periods(entries, days: 7)
            if let line = JournalStats.summaryLine(p.recent) {
                Text(L("Last 7 days: ", "Letzte 7 Tage: ") + line)
                if let before = JournalStats.summaryLine(p.before) {
                    Text(L("The 7 days before: ", "Die 7 Tage davor: ") + before).font(.caption).foregroundStyle(.secondary)
                }
            }
            let idle = WeekGoals.idle(entries)
            if !idle.isEmpty {
                Text(L("No deploy for 90 days (consider pausing):", "Seit 90 Tagen kein Deploy (Pausieren erwägen):")).font(.caption)
                ForEach(idle.prefix(8), id: \.project) { i in
                    Text(Demo.mask(i.project) + " · " + i.last.formatted(date: .abbreviated, time: .omitted)).font(.caption).foregroundStyle(.secondary)
                }
            }
        }
        .task { entries = Journal.load(limit: .max) }
    }
}
