// App tests: ci-lane-contract. Called from tests/app/main.swift.

import AppKit

@MainActor func suite_ci_lane_contract() {
    // --- CI lane: palette by item state, Claude nudge, the status models, the deploys JSON contract ---

    // The palette: which verbs a row gets depends on its state; hidden rows and real names in demo mode stay out.
    MainActor.assumeIsolated {
        let st = Store()
        var busy = item(changed: true); busy.state = .running("building")
        var linked = Item(id: "srv-9", name: "linked", detail: "", platform: .render, deployable: false, auto: false, note: nil, link: "https://linked.example")
        linked.kind = "static_site"
        let secret = Item(id: "secret", name: "secret", detail: "", platform: .vercel, deployable: true, auto: false, note: nil, link: nil)
        st.items[.vercel] = [busy, secret]
        st.items[.render] = [linked]
        st.hidden = [Store.key(secret)]
        let ids = PaletteCommands.all(st).map(\.id)
        expect("palette: a running row has no deploy or rollback", ids.contains("deploy|vercel/app") || ids.contains("rollback|vercel/app"), false)
        expect("palette: a running row can still show its log", ids.contains("log|vercel/app"), true)
        expect("palette: stop all appears while something runs", ids.contains("action.stopAll"), true)
        expect("palette: not deployable, no deploy", ids.contains("deploy|render/srv-9"), false)
        expect("palette: a link gives open", "\(ids.contains("open|render/srv-9")) \(ids.contains("open|vercel/app"))", "true false")
        expect("palette: Vercel and Render rows have a dashboard", "\(ids.contains("dashboard|vercel/app")) \(ids.contains("dashboard|render/srv-9"))", "true true")
        // A hidden row only offers "show" (our palette verb for hidden projects), nothing that acts on it.
        expect("palette: a hidden row is not offered", ids.filter { $0.hasSuffix("|vercel/secret") }.allSatisfy { $0.hasPrefix("show|") }, true)
        UserDefaults.standard.set(true, forKey: "demoMode")
        let demo = PaletteCommands.all(st)
        expect("palette, demo mode: the real name is not searchable",
               demo.contains { c in c.texts.contains { $0.contains("linked") } || c.title.contains("linked") }, false)
        expect("palette, demo mode: the stand-in is", demo.contains { $0.texts.contains("log " + Demo.mask("linked")) }, true)
        UserDefaults.standard.removeObject(forKey: "demoMode")
        expect("palette verbs: every verb has an English and a German word",
               PaletteVerb.allCases.allSatisfy { !$0.words.en.isEmpty && !$0.words.de.isEmpty }, true)
        expect("palette verbs: only deploy, rollback and preview ask first", PaletteVerb.allCases.filter(\.asks).map(\.rawValue), ["deploy", "rollback", "preview"])
    }

    // The Claude nudge: stored only when it changes; once dismissed, refresh leaves it alone (and reads no config).
    let nudgeKeys = [ClaudeNudge.wantedKey, ClaudeNudge.dismissedKey]
    let nudgeBefore = nudgeKeys.map { UserDefaults.standard.object(forKey: $0) }
    ClaudeNudge.store(wanted: true)
    expect("nudge: stored", UserDefaults.standard.bool(forKey: ClaudeNudge.wantedKey), true)
    ClaudeNudge.store(wanted: false)
    expect("nudge: cleared", UserDefaults.standard.bool(forKey: ClaudeNudge.wantedKey), false)
    UserDefaults.standard.set(true, forKey: ClaudeNudge.wantedKey)
    UserDefaults.standard.set(true, forKey: ClaudeNudge.dismissedKey)
    waitFor { await ClaudeNudge.refresh() }
    expect("nudge: dismissed, refresh changes nothing", UserDefaults.standard.bool(forKey: ClaudeNudge.wantedKey), true)
    for (k, v) in zip(nudgeKeys, nudgeBefore) { if let v { UserDefaults.standard.set(v, forKey: k) } else { UserDefaults.standard.removeObject(forKey: k) } }

    // The status models. Missing fields are read with defaults (main, "Settings parts read an answer
    // with fields missing"), so only the shape that matters is checked here.
    let dec = JSONDecoder()
    func decodes<T: Decodable>(_ t: T.Type, _ s: String) -> Bool { (try? dec.decode(t, from: Data(s.utf8))) != nil }
    expect("GuardStatus: a minimal answer", decodes(GuardStatus.self, #"{"enabled":false,"lastActions":[],"allowances":[]}"#), true)
    let team = try? dec.decode(TeamConfig.self, from: Data(#"{"readonly":{"value":true,"from":"x"},"sources":[],"projects":{"b":{"approvals":{"value":1,"from":"x"}},"a":{"approvals":{"value":3,"from":"x"}},"c":{"approvals":{"value":0,"from":"x"}},"d":{}}}"#.utf8))
    expect("TeamConfig.guarded: only approvals above 0, by name", team.map { $0.guarded.map { "\($0.name)=\($0.approvals)" } } ?? [], ["a=3", "b=1"])

    // The contract: what `deploys` really answers (tests/contract-json.sh), read with the app's own models.
    if let dir = ProcessInfo.processInfo.environment["DC_CONTRACT"] {
        func load<T: Decodable>(_ t: T.Type, _ f: String) -> T? {
            guard let d = FileManager.default.contents(atPath: dir + "/" + f) else { expect("contract: \(f) exists", false, true); return nil }
            do { return try dec.decode(t, from: d) } catch { expect("contract: \(f) decodes as \(t)", "\(error)", "no error"); return nil }
        }
        if let g = load(GuardStatus.self, "guard.json") {
            expect("contract guard: actions and allowances", "\(g.lastActions.map(\.action)) \(g.allowances.map(\.platform).sorted())", "[\"off\", \"failed\"] [\"all\", \"vercel\"]")
            expect("contract guard: the error of a failed switch", g.lastActions.last?.error ?? "-", "could not disconnect web")
        }
        if let a = load(AutofixReport.self, "autofix.json") {
            expect("contract autofix: routine, token, newest first", "\(a.routine ?? "-") \(a.token) \(a.fires.map(\.project))", "routine-1 true [\"web\", \"api\"]")
            expect("contract autofix: the PR and the merged commit", "\(a.fires.first?.prNumber ?? 0) \(a.fires.first?.mergedSha ?? "-")", "9 ffff999")
        }
        if let c = load(TeamConfig.self, "config.json") {
            expect("contract config: not an observer, web needs 2 approvals", "\(c.readonly.value) \(c.guarded.map { "\($0.name)=\($0.approvals)" })", "false [\"web=2\"]")
        }
        if let w = load(WindowReply.self, "window.json") {
            expect("contract window: closed, with the reason", "\(w.denied) \(w.reason ?? "-")", "true freeze")
        }
        if let s = load(SessionsSnapshot.self, "sessions.json") {
            expect("contract sessions: count, twins, cloud unknown", "\(s.local.count) \(s.duplicates.map(\.pids)) \(s.cloud.count == nil)", "2 [[501, 502]] true")
        }
    } else {
        print("skip contract tests (DC_CONTRACT not set; tests/app-tests.sh sets it)")
    }

    // Round 7: the ledger on open respects the GitHub budget; links and keys; numbers follow the app's language.
    expect("ledger on open: no budget known runs", SavingsModel.budgetAllows(nil), true)
    expect("ledger on open: plenty left runs", SavingsModel.budgetAllows(Store.Budget(remaining: 4000, limit: 5000, reset: 0)), true)
    expect("ledger on open: under a fifth left waits", SavingsModel.budgetAllows(Store.Budget(remaining: 500, limit: 5000, reset: 0)), false)
    expect("web links: https opens", SafeLink.ok(URL(string: "https://github.com/a/b/pull/1")!), true)
    expect("web links: file does not", SafeLink.ok(URL(string: "file:///etc/hosts")!), false)
    expect("web links: a custom scheme does not", SafeLink.ok(URL(string: "x-apple.systempreferences:com.apple")!), false)
    expect("web links: http only for localhost", [SafeLink.ok(URL(string: "http://example.com")!), SafeLink.ok(URL(string: "http://localhost:3000")!)], [false, true])
    expect("masker: a SendGrid key", LogTools.maskSecrets("key SG.abcdefghijklmnop1234.abcdefghijklmnop5678 end").contains("abcdefghijklmnop1234"), false)
    expect("masker: a Supabase secret", LogTools.maskSecrets("sb_secret_abcdefgh1234").contains("abcdefgh1234"), false)
    expect("decimal: one digit", decimal(12.34), isGerman ? "12,3" : "12.3")

    // Round 10: journal, dates, run-state keys.
    let jm = Journal.masked(JournalEntry(platform: "vercel", name: "a", result: "failed", seconds: 1, detail: "clone https://user:hunter2secret@host.example/x.git failed", sha: "abc", deployId: "d1"))
    expect("journal: error text is masked before it is written", (jm.detail ?? "").contains("hunter2secret"), false)
    expect("journal: masking keeps sha and deploy id", "\(jm.sha ?? "")|\(jm.deployId ?? "")", "abc|d1")
    let jplain = JournalEntry(platform: "vercel", name: "a", result: "failed", seconds: 1, detail: "build failed", sha: nil, deployId: nil)
    expect("journal: a plain text stays", Journal.masked(jplain).detail ?? "", "build failed")
    let jt = Date(timeIntervalSince1970: 1_700_000_000)
    let j1 = JournalEntry(at: jt, platform: "vercel", name: "a", result: "live", seconds: 1, detail: nil, sha: nil, deployId: "dpl_1")
    let j2 = JournalEntry(at: jt, platform: "vercel", name: "a", result: "live", seconds: 1, detail: nil, sha: nil, deployId: "dpl_2")
    expect("journal: two entries in the same second have two ids", j1.id != j2.id, true)
    expect("date: seconds", Int(date(1_700_000_000)?.timeIntervalSince1970 ?? 0), 1_700_000_000)
    expect("date: milliseconds are divided", Int(date(1_700_000_000_000)?.timeIntervalSince1970 ?? 0), 1_700_000_000)
    expect("date: zero is none", date(0) == nil, true)
    expect("quiet hours over midnight", Notify.quiet(hour: 23, from: 22, to: 7), true)
    expect("quiet hours: midnight itself", Notify.quiet(hour: 0, from: 22, to: 7), true)
    expect("quiet hours: same hour is off", Notify.quiet(hour: 5, from: 5, to: 5), false)
    expect("digest waits at least a minute", QuietDigest.seconds(until: 7) >= 60, true)
    expect("quiet hours: outside", Notify.quiet(hour: 12, from: 22, to: 7), false)

    print("")
    // Cost helpers: budget light, once-a-day estimate, report.
    do {
        expect("light green", CostInsights.light(week: 10, budget: 100)?.rawValue ?? "", "green")
        expect("light yellow", CostInsights.light(week: 22, budget: 100)?.rawValue ?? "", "yellow")
        expect("light red", CostInsights.light(week: 30, budget: 100)?.rawValue ?? "", "red")
        expect("light none", CostInsights.light(week: 30, budget: 0) == nil, true)
        let c = try! JSONDecoder().decode(Costs.self, from: Data(#"{"days":[{"day":"2026-11-01","total":2,"build":1},{"day":"2026-11-02","total":3,"build":2}],"projects":[{"name":"a","build":10,"builds":10},{"name":"b","build":4,"builds":2}],"offDay":null,"buildsComplete":true}"#.utf8))
        expect("once a day saving", CostInsights.onceADaySaving(c), 3.0)
        expect("series", CostInsights.series(c.days), [1.0, 2.0])
        expect("report escapes a pipe in a name", CostInsights.mdCell("a|b\nc"), "a\\|b c")
        expect("plural one", plural(1, "project", "projects"), "1 project")
        expect("plural many", plural(3, "project", "projects"), "3 projects")
        expect("report masks names", CostInsights.report(c, budget: 0, today: "2026-11-02", names: false).contains("| a |"), false)
    }

    // Weekly goal and idle projects.
    do {
        expect("goal off", WeekGoals.state(count: 3, goal: 0), WeekGoals.State.off)
        expect("goal ok", WeekGoals.state(count: 2, goal: 5), WeekGoals.State.ok)
        expect("goal last", WeekGoals.state(count: 5, goal: 5), WeekGoals.State.last)
        expect("goal over", WeekGoals.state(count: 6, goal: 5), WeekGoals.State.over)
        let now = Date()
        let old = JournalEntry(at: now.addingTimeInterval(-100 * 86400), platform: "vercel", name: "old", result: "live", seconds: nil, detail: nil)
        let fresh = JournalEntry(at: now.addingTimeInterval(-3600), platform: "vercel", name: "new", result: "live", seconds: nil, detail: nil)
        expect("idle finds the old one", WeekGoals.idle([old, fresh], now: now).map(\.project), ["vercel/old"])
        expect("idle skips one with a fresh deploy", WeekGoals.idle([old, fresh, JournalEntry(at: now, platform: "vercel", name: "old", result: "live", seconds: nil, detail: nil)], now: now).count, 0)
    }

}
