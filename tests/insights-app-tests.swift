// Tests for the app's insight features (error patterns, forecast, accounts, health score, weekly card).
// Compiled with the app's sources by tests/app-tests.sh; app-tests.swift calls insightsAppTests(expect).

import Foundation

func insightsAppTests(_ expect: (String, Any, Any) -> Void) {
    // Error patterns.
    expect("pattern: lockfile", ErrorPatterns.match("ERR_PNPM_OUTDATED_LOCKFILE Cannot install")?.id ?? "", "lockfile")
    expect("pattern: memory", ErrorPatterns.match("FATAL ERROR: JavaScript heap out of memory")?.id ?? "", "memory")
    expect("pattern: node", ErrorPatterns.match("error: The engine \"node\" is incompatible with this module")?.id ?? "", "node")
    expect("pattern: env", ErrorPatterns.match("Error: Missing environment variable DATABASE_URL")?.id ?? "", "env")
    expect("pattern: auth", ErrorPatterns.match("npm ERR! 403 Forbidden - GET https://registry")?.id ?? "", "auth")
    expect("pattern: auth 401", ErrorPatterns.match("fetch failed: 401 Unauthorized")?.id ?? "", "auth")
    expect("pattern: room is not oom", ErrorPatterns.match("the room is empty") == nil, true)
    expect("pattern: oom as a word", ErrorPatterns.match("process died: OOM")?.id ?? "", "memory")
    expect("pattern: nothing", ErrorPatterns.match("") == nil, true)
    expect("pattern: every pattern has a command or hint", ErrorPatterns.all.allSatisfy { !$0.hint.isEmpty && !$0.title.isEmpty }, true)

    // Grouping.
    let g = ErrorPatterns.group([("b", "lockfile"), ("a", "lockfile"), ("a", "lockfile"), ("c", "memory"), ("d", "auth"), ("e", "auth"), ("f", "auth"), ("g", "unknown")])
    expect("group: biggest first", g.map(\.pattern.id), ["auth", "lockfile"])
    expect("group: names sorted, no duplicates", g[1].projects, ["a", "b"])
    expect("group: a single project is no group", ErrorPatterns.group([("a", "memory")]).count, 0)

    // The cause store.
    let d = UserDefaults(suiteName: "insights-test-\(UUID().uuidString)")!
    let now = Date()
    FailureCauses.record(project: "a", cause: "lockfile", now: now, d)
    FailureCauses.record(project: "b", cause: "lockfile", now: now.addingTimeInterval(-20 * 86400), d)
    expect("causes: fresh one is kept", FailureCauses.current(failed: ["a", "b", "c"], d, now: now).map(\.project), ["a"])
    FailureCauses.forget(project: "a", d)
    expect("causes: forget", FailureCauses.current(failed: ["a"], d, now: now).count, 0)

    // Forecast and platform switch.
    let costsJSON = #"{"days":[],"projects":[{"name":"shop","build":7.0,"builds":10},{"name":"blog","build":0.7,"builds":2},{"name":"idle","build":0}]}"#
    if let c = try? JSONDecoder().decode(Costs.self, from: Data(costsJSON.utf8)) {
        let ls = CostForecast.lines(c, budgets: [BudgetKey.key(platform: "vercel", name: "shop"): 20], daysInMonth: 30)
        expect("forecast: names", ls.map(\.name), ["shop", "blog"])
        expect("forecast: month", ls[0].month, 30.0)
        expect("forecast: over", ls[0].over ?? 0, 10.0)
        expect("forecast: no budget no warning", CostForecast.warning(ls[1]) == nil, true)
        expect("forecast: warning", CostForecast.warning(ls[0]) != nil, true)
    } else { expect("forecast: costs decode", false, true) }
    let simJSON = #"{"days":30,"projects":[{"platform":"vercel","name":"shop","pushes":60,"avgBuildMinutes":2},{"platform":"render","name":"api","pushes":30,"avgBuildMinutes":4},{"platform":"vercel","name":"noprice","pushes":5}]}"#
    if let r = try? JSONDecoder().decode(SimulateReport.self, from: Data(simJSON.utf8)) {
        let opts = PlatformSwitch.options(r, rates: ["vercel": 0.01, "render": 0.005])
        expect("switch: only priced projects", opts.map(\.name).sorted(), ["api", "shop"])
        let shop = opts.first { $0.name == "shop" }!
        expect("switch: minutes", shop.minutes, 120.0)
        expect("switch: now", shop.costNow, 1.2)
        expect("switch: there", shop.costThere, 0.6)
        expect("switch: no rates, no options", PlatformSwitch.options(r, rates: [:]).count, 0)
    } else { expect("switch: report decode", false, true) }
    expect("rates: read", PlatformSwitch.rates(Data(#"{"vercelUsdPerMinute":0.014,"renderUsdPerMinute":0}"#.utf8)), ["vercel": 0.014])
    expect("rates: broken file", PlatformSwitch.rates(Data("x".utf8)).count, 0)
}

func insightsAppTests2(_ expect: (String, Any, Any) -> Void) {
    let now = Date()
    func e(_ days: Double, _ result: String, _ name: String = "app") -> JournalEntry {
        JournalEntry(at: now.addingTimeInterval(-days * 86400), platform: "vercel", name: name, result: result, seconds: nil, detail: nil)
    }
    // Health score: the CLI's formula.
    let clean = HealthScore.score(platform: "vercel", name: "app", entries: [e(1, "live"), e(2, "live")], now: now)
    expect("health: clean project", clean.score ?? -1, 100)
    let half = HealthScore.score(platform: "vercel", name: "app", entries: [e(5, "live"), e(4, "failed"), e(3, "live"), e(2, "failed")], now: now)
    expect("health: open failure", half.openOutage, true)
    expect("health: open failure score", half.score ?? -1, 24)
    expect("health: failures part", half.parts["failures"]?.points ?? -1, 0.0)
    let stale = HealthScore.score(platform: "vercel", name: "app", entries: [e(100, "live")], now: now)
    expect("health: only freshness left, scaled", stale.score ?? -1, 0)
    expect("health: no entries, no score", HealthScore.score(platform: "vercel", name: "x", entries: [], now: now).score == nil, true)
    let red = HealthScore.score(platform: "vercel", name: "app", entries: [e(1, "live")], now: now, ci: "red")
    expect("health: red CI costs 15 of 100", red.score ?? -1, 85)
    let all = HealthScore.all([e(1, "live", "good"), e(2, "failed", "bad"), e(1, "failed", "bad")], now: now)
    expect("health: worst first", all.rows.map(\.name), ["bad", "good"])
    expect("health: average", all.average ?? -1, 50)
    expect("health: rating", clean.rating ?? "", "good")

    // Weekly comparison.
    let list = [e(1, "live"), e(2, "live"), e(3, "failed"), e(9, "live"), e(10, "live"), e(11, "live"), e(12, "live"), e(13, "failed")]
    let rows = WeeklyCompare.rows(list, now: now)
    expect("weekly: deploys now and before", rows[0].now + "/" + rows[0].before, "2/4")
    expect("weekly: deploys arrow down", rows[0].arrow, "↓")
    expect("weekly: failed same", rows[1].now + "/" + rows[1].before + rows[1].arrow, "1/1→")
    expect("weekly: note", WeeklyCompare.beforeNote(list, now: now)?.contains("4") ?? false, true)
    expect("weekly: no note without a week before", WeeklyCompare.beforeNote([e(1, "live")], now: now) == nil, true)
    expect("weekly: arrow from nothing", WeeklyCompare.arrow(now: 3, before: 0), "↑")
    expect("weekly: markdown", WeeklyCompare.markdown(rows).hasPrefix("| |"), true)
}
