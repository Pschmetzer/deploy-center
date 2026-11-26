// App tests, round 15: the days a journal really covers. Called from tests/app/main.swift.

import AppKit

@MainActor func suite_round15_bugs2() {
    let now = Date(timeIntervalSince1970: 1_800_000_000)
    func ago(_ d: Double) -> Date { now.addingTimeInterval(-d * 86400) }
    expect("covered: the journal reaches back far enough", JournalStats.coveredDays(30, oldest: ago(90), end: now), 30)
    expect("covered: the journal starts 10 days ago", JournalStats.coveredDays(30, oldest: ago(10), end: now), 10)
    expect("covered: at least one day", JournalStats.coveredDays(30, oldest: ago(0), end: now), 1)
    expect("covered: no journal, the days as asked", JournalStats.coveredDays(30, oldest: nil, end: now), 30)
    expect("covered: the window before reaches back 5 days into it", JournalStats.coveredDays(30, oldest: ago(35), end: ago(30)), 5)
    expect("covered: the window before is fully covered", JournalStats.coveredDays(7, oldest: ago(60), end: ago(7)), 7)
}
