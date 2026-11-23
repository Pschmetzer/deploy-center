// App tests: autofix-savings. Called from tests/app/main.swift.

import AppKit

@MainActor func suite_autofix_savings() {
    // Autofix in the rows: old and new status shapes, each state and when it ends by itself.
    let oldShape = fire(#"{"routine":"trig_1","token":true,"scheduled":false,"fires":[{"at":100,"project":"app","platform":"vercel","status":"fired","session":"https://claude.ai/code/s1","pr":7,"mergedSha":null},{"broken":true}]}"#)
    expect("old status decodes, broken fire skipped", "\(oldShape.fires.count) \(oldShape.fires[0].prNumber ?? 0) \(oldShape.ready)", "1 7 true")
    let newShape = fire(#"{"routine":null,"token":false,"fires":[{"at":100,"project":"app","platform":"vercel","status":"fired","prNumber":9,"prState":"OPEN","prUrl":"https://github.com/me/app/pull/9"}]}"#)
    expect("new status decodes", "\(newShape.fires[0].prNumber ?? 0) \(newShape.fires[0].prState ?? "") \(newShape.ready)", "9 open false")
    expect("empty status decodes", fire("{}").fires.count, 0)

    expect("fixing while failed", RowAutofix.of(failedItem(), F(at: 1, project: "app", platform: "vercel", status: "fired", session: "https://claude.ai/code/s1"), now: soon) == .fixing(session: URL(string: "https://claude.ai/code/s1")), true)
    expect("no PR long after the hand-over: not fixing any more", RowAutofix.of(failedItem(), F(at: 1, project: "app", platform: "vercel", status: "fired", session: "https://claude.ai/code/s1"), now: late) == .noPR(session: URL(string: "https://claude.ai/code/s1")), true)
    expect("an open PR is never stalled", RowAutofix.of(failedItem(), F(at: 1, project: "app", platform: "vercel", status: "fired", prNumber: 4, prState: "open"), now: late) == .prOpen(number: 4, url: nil), true)
    expect("sync while a PR may still come", RowAutofix.needsSync(F(at: 1, project: "app", platform: "vercel", status: "fired"), now: soon), true)
    expect("no sync for a stalled hand-over", RowAutofix.needsSync(F(at: 1, project: "app", platform: "vercel", status: "fired"), now: late), false)
    expect("sync for an open PR, however old", RowAutofix.needsSync(F(at: 1, project: "app", platform: "vercel", status: "fired", prNumber: 4, prState: "open"), now: late), true)
    var doneFire = F(at: 1, project: "app", platform: "vercel", status: "fired"); doneFire.done = true
    expect("no sync for a fire that is green again", RowAutofix.needsSync(doneFire, now: soon), false)
    expect("done decodes", fire(#"{"fires":[{"at":1,"project":"a","status":"fired","done":true}]}"#).fires[0].done, true)
    expect("rate limited is not 'no PR'", RowAutofix.of(failedItem(), F(at: 1, project: "app", platform: "vercel", status: "ratelimited"), now: late) == .waiting(.rateLimit), true)
    expect("pending, fresh: starting", RowAutofix.of(failedItem(), F(at: 1, project: "app", platform: "vercel", status: "pending"), now: soon) == .waiting(.starting), true)
    expect("pending for long: unclear", RowAutofix.of(failedItem(), F(at: 1, project: "app", platform: "vercel", status: "pending"),
                                                       now: Date(timeIntervalSince1970: 1 + RowAutofix.unclearAfter + 1)) == .waiting(.unclear), true)
    expect("a start that failed is its own case", RowAutofix.of(failedItem(), F(at: 1, project: "app", platform: "vercel", status: "failed")) == .handedBack(.startFailed), true)
    expect("unsupported carries the reason",
           RowAutofix.of(failedItem(), fire(#"{"fires":[{"at":1,"project":"app","platform":"vercel","status":"unsupported","reason":"autofix works with GitHub repos only"}]}"#).fires[0])
             == .unsupported(reason: "autofix works with GitHub repos only"), true)
    expect("start failed and fix failed read differently", AgentChips.text(.handedBack(.startFailed)) != AgentChips.text(.handedBack(.fixFailed)), true)
    expect("an unsupported chip can be dismissed", AgentChips.dismissable(.unsupported(reason: nil)), true)
    expect("a running fix cannot be dismissed", AgentChips.dismissable(.fixing(session: nil)), false)
    expect("no PR chip links the session", AgentChips.link(.noPR(session: URL(string: "https://claude.ai/code/s1")))?.absoluteString ?? "", "https://claude.ai/code/s1")
    expect("fixing ends when green again", RowAutofix.of(green, F(at: 1, project: "app", platform: "vercel", status: "fired")) == nil, true)
    expect("PR open", RowAutofix.of(failedItem(), F(at: 1, project: "app", platform: "vercel", status: "fired", prNumber: 4, prState: "open")) == .prOpen(number: 4, url: nil), true)
    var waiting = failedItem(); waiting.changed = true; waiting.headSha = "bbbbbbb2"
    expect("merged, not live", RowAutofix.of(waiting, F(at: 1, project: "app", platform: "vercel", status: "fired", prNumber: 4, mergedSha: "bbbbbbb2ffff")) == .merged(sha: "bbbbbbb2ffff", pr: 4, url: nil), true)
    var brokeAgain = waiting; brokeAgain.latestSha = "ccccccc3"
    expect("merged, but a newer build failed: not 'deploy the fix'", RowAutofix.of(brokeAgain, F(at: 1, project: "app", platform: "vercel", status: "fired", prNumber: 4, mergedSha: "bbbbbbb2ffff", sha: "aaaaaaa1")) == nil, true)
    var fixFailed = waiting; fixFailed.latestSha = "bbbbbbb2"
    expect("merged fix that itself failed is handed back", RowAutofix.of(fixFailed, F(at: 1, project: "app", platform: "vercel", status: "fired", prNumber: 4, mergedSha: "bbbbbbb2ffff", sha: "aaaaaaa1")) == .handedBack(.fixFailed), true)
    var stillOld = waiting; stillOld.latestSha = "aaaaaaa1"
    expect("merged, the handed-over failure still newest: deploy the fix", RowAutofix.of(stillOld, F(at: 1, project: "app", platform: "vercel", status: "fired", prNumber: 4, mergedSha: "bbbbbbb2ffff", sha: "aaaaaaa1")) == .merged(sha: "bbbbbbb2ffff", pr: 4, url: nil), true)
    var shipped = waiting; shipped.lastSha = "bbbbbbb2"; shipped.changed = false
    expect("merged ends once live", RowAutofix.of(shipped, F(at: 1, project: "app", platform: "vercel", status: "fired", mergedSha: "bbbbbbb2ffff")) == nil, true)
    expect("fix failed too", RowAutofix.of(failedItem(), F(at: 1, project: "app", platform: "vercel", status: "skipped")) == .handedBack(.fixFailed), true)
    expect("PR closed unmerged", RowAutofix.of(failedItem(), F(at: 1, project: "app", platform: "vercel", status: "fired", prNumber: 4, prState: "closed")) == .handedBack(.fixFailed), true)
    expect("chip words", AgentChips.text(.prOpen(number: 12, url: nil)), L("Fix PR #12 open", "Fix-PR #12 offen"))

    // Fires name a Render service by its name, not its id; the newest one counts; the platform must match.
    let many = AutofixReport(routine: "trig_1", token: true, fires: [
        F(at: 1, project: "app", platform: "render", status: "skipped"),
        F(at: 5, project: "app", platform: "render", status: "fired"),
        F(at: 9, project: "app", platform: "vercel", status: "skipped"),
        F(at: 9, project: "srv-1", platform: "render", status: "skipped")])
    expect("render matched by name, newest", many.newest(for: failedItem(.render))?.at ?? 0, 5.0)

    // Allowances: epoch or ISO date; a Render one by id or name.
    let allow = try! JSONDecoder().decode(AllowanceReport.self, from: Data(#"{"allowances":[{"platform":"vercel","project":"app","expiresAt":2000000000},{"platform":"Render","project":"srv-1","expiresAt":"2033-05-18T03:33:20Z"},{"platform":"vercel","project":"x","expiresAt":"soon"}]}"#.utf8))
    expect("allowances decode, bad date skipped", allow.allowances.count, 2)
    expect("both date forms", allow.allowances[0].expiresAt == allow.allowances[1].expiresAt, true)
    expect("render allowance by id", allow.allowances[1].covers(item(.render)), true)
    expect("no guard answer decodes empty", (try? JSONDecoder().decode(AllowanceReport.self, from: Data("{}".utf8)))?.allowances.count ?? -1, 0)

    // A merged fix ticks its row once; unticked, the next load leaves it.
    MainActor.assumeIsolated {
        UserDefaults.standard.removeObject(forKey: "autofixPreselected")
        let st = Store()
        st.items[.vercel] = [waiting]
        st.autofix = AutofixReport(routine: "trig_1", token: true, fires: [F(at: 1, project: "app", platform: "vercel", status: "fired", mergedSha: "bbbbbbb2ffff")])
        st.preselectMergedFixes()
        expect("merged fix preselected", st.items[.vercel]![0].selected, true)
        st.items[.vercel]![0].selected = false
        st.preselectMergedFixes()
        expect("preselected only once", st.items[.vercel]![0].selected, false)
        expect("no button while a fix waits", st.canFixWithClaude(st.items[.vercel]![0]), false)
        st.autofix = AutofixReport(routine: "trig_1", token: true, fires: [F(at: Date().timeIntervalSince1970 - 60, project: "app", platform: "vercel", status: "fired")])
        st.items[.vercel] = [failedItem()]
        expect("menu bar count", st.fixingCount, 1)
        st.autofix = AutofixReport(routine: "trig_1", token: true, fires: [F(at: 1, project: "app", platform: "vercel", status: "fired")])
        expect("a stalled hand-over is not counted as fixing", st.fixingCount, 0)
        expect("no button for a stalled hand-over (not handed over twice)", st.canFixWithClaude(st.items[.vercel]![0]), false)
        st.autofix = AutofixReport(routine: "trig_1", token: true, fires: [])
        expect("button on a failed row", st.canFixWithClaude(st.items[.vercel]![0]), true)
        st.allowances = [AutoDeployAllowance(platform: "vercel", project: "app", expiresAt: Date().addingTimeInterval(-60))]
        expect("expired allowance ignored", st.allowance(st.items[.vercel]![0]) == nil && st.activeAllowances.isEmpty, true)
        UserDefaults.standard.removeObject(forKey: "autofixPreselected")
    }

    // Savings: the simulator and the ledger read what lib/savings.sh prints, and odd fields do not break them.
    func savingsData(_ file: String) -> Data { (try? Data(contentsOf: URL(fileURLWithPath: "tests/fixtures/savings/" + file))) ?? Data() }
    if let sim = try? JSONDecoder().decode(SimulateReport.self, from: savingsData("simulate-report.json")) {
        expect("simulate: rows", sim.projects.map(\.name), ["web", "api", "svc", "lost"])
        expect("simulate: auto-deploy a month", sim.autoMonth.usd ?? -1, 3.2)
        expect("simulate: once a day a month", sim.dailyMonth.usd ?? -1, 2.4)
        expect("simulate: Render minutes", sim.autoMonth.renderMinutes ?? -1, 20.0)
        expect("simulate: Render without price", sim.projects[2].autoMonth.usd == nil, true)
        expect("simulate: incomplete prices are said", sim.usdComplete, false)
        expect("simulate: a problem is kept", sim.projects[3].problem != nil, true)
        // web: min(6, 2×2) × $0.20, api: min(3, 3×2) × $0.67; svc min(4, 1×2) builds without a price.
        let w = sim.whatIf(perDay: 2)
        expect("what if twice a day", "\((w.usd * 100).rounded() / 100) \(w.builds) \(w.complete)", "2.81 9.0 false")
        expect("what if: more than the pushes counts the pushes", sim.whatIf(perDay: 8).builds, 13.0)
    } else { expect("simulate fixture decodes", false, true) }
    if let led = try? JSONDecoder().decode(LedgerReport.self, from: savingsData("ledger-report.json")) {
        expect("ledger: since", led.since ?? "", "2026-01-20")
        expect("ledger: total", "\(led.usd ?? -1) \(led.skipped) \(led.vercelMinutes) \(led.renderMinutes)", "0.8 6.0 12.0 10.0")
        expect("ledger: skipped pushes", led.projects[0].skippedPushes.map(\.sha), ["a4", "a3", "a2", "a1"])
        // (0.8 + 0.2) / 11 days before, 0.2 / 11 since: the share card gets per-day numbers.
        expect("ledger: per day for the share card", led.perDay.map { "\(($0.before * 11).rounded()) \((($0.after * 11) * 10).rounded())" } ?? "", "1.0 2.0")
    } else { expect("ledger fixture decodes", false, true) }
    let oddLedger = Data(#"{"since":null,"days":"3","projects":[{"name":"ok","skipped":"2","savedUsd":"x"},{"nope":1},7],"total":{"usd":null}}"#.utf8)
    if let led = try? JSONDecoder().decode(LedgerReport.self, from: oddLedger) {
        expect("lenient: bad rows are dropped, numbers as text read", "\(led.projects.map(\.name)) \(led.projects[0].skipped) \(led.days)", "[\"ok\"] 2.0 3.0")
        expect("lenient: unreadable dollars are unknown", led.projects[0].savedUsd == nil, true)
        expect("lenient: no start, no ledger", led.hasStarted, false)
    } else { expect("lenient ledger decodes", false, true) }
    do {
        let now = Date(timeIntervalSince1970: 1_000_000)
        expect("certificate: 30 days left says nothing", Store.certificateWarning(expires: now.addingTimeInterval(30 * 86_400), now: now) == nil, true)
        expect("certificate: 10 days left", Store.certificateWarning(expires: now.addingTimeInterval(10.5 * 86_400), now: now) ?? -99, 10)
        expect("certificate: expired", (Store.certificateWarning(expires: now.addingTimeInterval(-86_400), now: now) ?? 99) <= 0, true)
    }
    do {
        let f = [JournalEntry(platform: "Vercel", name: "a", result: "failed", seconds: nil, detail: "Build failed: exit code 1\nmore"),
                 JournalEntry(platform: "Vercel", name: "b", result: "failed", seconds: nil, detail: "Build failed: exit code 2"),
                 JournalEntry(platform: "Vercel", name: "a", result: "failed", seconds: nil, detail: "Timeout after 600 s"),
                 JournalEntry(platform: "Vercel", name: "a", result: "live", seconds: nil, detail: "Build failed: exit code 1")]
        let c = JournalStats.failureCauses(f)
        expect("failure causes: alike ones together", "\(c.first?.cause ?? "") \(c.first?.count ?? 0) \(c.first?.projects ?? [])", "Build failed: exit code # 2 [\"a\", \"b\"]")
        expect("failure causes: ids become #", JournalStats.cause("Deployment dpl_8f3k2 failed at a1b2c3d") ?? "", "Deployment # failed at #")
    }
    expect("prompt template", LogTools.fill("Fix {name} at {sha}: {log} {other}", ["name": "web", "sha": "abc", "log": "{name}"]), "Fix web at abc: {name} {other}")
    do {
        let now = Date(timeIntervalSince1970: 10_000_000)
        let old = SiteLog.Check(t: now.timeIntervalSince1970 - 40 * 86_400, ok: false)
        let list = [old] + (0..<(SiteLog.keep + 10)).map { SiteLog.Check(t: now.timeIntervalSince1970 - Double($0), ok: $0 % 10 != 0) }
        let t = SiteLog.trim(list, now: now)
        expect("site log: old and too many dropped", "\(t.count) \(t.contains(old))", "\(SiteLog.keep) false")
        expect("site log: uptime", SiteLog.uptime([SiteLog.Check(t: 1, ok: true), SiteLog.Check(t: 2, ok: false)]) ?? -1, 0.5)
        expect("site log: ten quick checks do not outweigh a long up time", SiteLog.uptime([SiteLog.Check(t: 0, ok: true), SiteLog.Check(t: 20_000, ok: false)] + (1...9).map { SiteLog.Check(t: 20_000 + Double($0), ok: false) }) ?? -1 > 0.5, true)
        expect("site log: no checks, no uptime", SiteLog.uptime([]) == nil, true)
    }
    do {
        let d = Date(timeIntervalSince1970: 1_700_000_000)
        expect("tip: the same all day", Tips.tip(on: d) == Tips.tip(on: d.addingTimeInterval(60)), true)
        expect("tip: another the next day", Tips.tip(on: d) != Tips.tip(on: d.addingTimeInterval(86_400)), true)
    }
    expect("spotlight entries sorted", Spotlight.entries([(key: "vercel/b", name: "b", platform: "Vercel"), (key: "render/a", name: "a", platform: "Render")]),
           ["render/a\ta\tRender", "vercel/b\tb\tVercel"])
    expect("goal share", [SavingsModel.goalShare(saved: 25, goal: 100), SavingsModel.goalShare(saved: 300, goal: 100), SavingsModel.goalShare(saved: 5, goal: 0), SavingsModel.goalShare(saved: nil, goal: 50)].map { $0.map { String($0) } ?? "nil" }, ["0.25", "1.0", "nil", "nil"])
    expect("milestones", [5, 10, 99, 100, 1999, 2500].map { SavingsModel.milestone(saved: $0).map { Int($0) } ?? 0 }, [0, 10, 50, 100, 1000, 2000])
    expect("lenient: an empty object is an empty simulation",
           (try? JSONDecoder().decode(SimulateReport.self, from: Data("{}".utf8)))?.projects.count ?? -1, 0)
    UserDefaults.standard.set(true, forKey: "demoMode")
    expect("savings: names masked in demo mode", SavingsFormat.name("shop-api") != "shop-api", true)
    UserDefaults.standard.removeObject(forKey: "demoMode")
    expect("savings: estimates carry ≈", SavingsFormat.usd(1.5).hasPrefix("≈ "), true)

}
