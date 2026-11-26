// App tests, round 15: QuietHours. Called from tests/app/main.swift.

import AppKit

@MainActor func suite_round15_code() {
    var cal = Calendar(identifier: .gregorian); cal.timeZone = TimeZone(identifier: "UTC")!
    func at(_ h: Int) -> Date { cal.date(from: DateComponents(year: 2026, month: 11, day: 26, hour: h, minute: 30))! }
    let night = QuietHours(from: 22, to: 7)
    expect("quiet: 23:30 is quiet", night.isQuiet(at(23), calendar: cal), true)
    expect("quiet: 03:30 is quiet (over midnight)", night.isQuiet(at(3), calendar: cal), true)
    expect("quiet: 12:30 is not", night.isQuiet(at(12), calendar: cal), false)
    expect("quiet: 07:30 is not (the end is open)", night.isQuiet(at(7), calendar: cal), false)
    expect("quiet: equal hours are off", QuietHours(from: 0, to: 0).isQuiet(at(3), calendar: cal), false)
    expect("quiet: ends in 3.5 h at 03:30", Int(night.endsIn(at(3), calendar: cal)), 3 * 3600 + 1800)
    let d = UserDefaults(suiteName: "dc-r15-quiet-\(UUID().uuidString)")!
    d.set(21, forKey: QuietHours.fromKey); d.set(6, forKey: QuietHours.toKey)
    expect("quiet: read from the settings", QuietHours.current(d), QuietHours(from: 21, to: 6))
}
