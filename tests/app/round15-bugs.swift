
@MainActor func suite_round15_a11y() {
    var cal = Calendar(identifier: .gregorian); cal.timeZone = TimeZone(identifier: "UTC")!
    let now = Date(timeIntervalSince1970: 1_800_000_000)
    expect("message time: today is only the time", uiTimeOrDay(now.addingTimeInterval(-60), now: now, calendar: cal), uiTime(now.addingTimeInterval(-60)))
    expect("message time: another day has the date", uiTimeOrDay(now.addingTimeInterval(-3 * 86400), now: now, calendar: cal) != uiTime(now.addingTimeInterval(-3 * 86400)), true)
}
