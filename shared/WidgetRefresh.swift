// Deploy Center — When a widget asks for its next timeline. Pure logic, so ios/Tests can check it.
// The app reloads the widgets after each change; this is the fallback for the times it is not running.
// WidgetKit gives a limited budget of reloads a day: ask sooner only while something is moving, and less when nothing can have changed.

import Foundation

enum WidgetRefresh {
    /// Nothing moves: look again after half an hour.
    static let idle: TimeInterval = 30 * 60
    /// A build runs: the picture should follow it.
    static let busy: TimeInterval = 5 * 60
    /// The snapshot is out of date (the app has not run for hours): a quick look again finds the same file, so wait longer.
    static let outdated: TimeInterval = 60 * 60

    static func interval(snapshotAt: Date?, building: Int, now: Date) -> TimeInterval {
        guard let at = snapshotAt else { return idle }
        if now.timeIntervalSince(at) > Words.staleAfter { return outdated }
        return building > 0 ? busy : idle
    }

    static func nextReload(snapshotAt: Date?, building: Int, now: Date) -> Date {
        now.addingTimeInterval(interval(snapshotAt: snapshotAt, building: building, now: now))
    }

    /// The next midnight after `now`: the "Today" widget's numbers end there, so it gets an entry of its own.
    static func nextMidnight(after now: Date, calendar: Calendar = .current) -> Date {
        calendar.nextDate(after: now, matching: DateComponents(hour: 0, minute: 0, second: 0), matchingPolicy: .nextTime)
            ?? calendar.startOfDay(for: now.addingTimeInterval(86_400))
    }

    /// The moment "out of date" should show without the app: a second entry in the timeline, only while that moment is ahead.
    static func staleEntryDate(snapshotAt: Date?, now: Date) -> Date? {
        guard let at = snapshotAt else { return nil }
        let d = at.addingTimeInterval(Words.staleAfter)
        return d > now ? d : nil
    }
}
