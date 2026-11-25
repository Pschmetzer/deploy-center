// App tests: queue-phone-link. Called from tests/app/main.swift.

import AppKit

@MainActor func suite_queue_phone_link() {
    // LOG-116: the queue and following, with the script answered by the test (no network).
    // The main run loop turns while waiting, so the store's tasks (main actor) run.
    MainActor.assumeIsolated {
        func spin(until done: () -> Bool) {
            let end = Date().addingTimeInterval(3)
            while !done() && Date() < end { RunLoop.main.run(until: Date().addingTimeInterval(0.02)) }
        }
        let oldUndo = UserDefaults.standard.object(forKey: "undoSeconds")
        UserDefaults.standard.set(0, forKey: "undoSeconds")
        Store.pollNanos = 20_000_000
        Tool.testRunner = { args in
            switch (args.first ?? "", args.dropFirst().first ?? "") {
            case ("window", _): return Data(#"{"denied":false}"#.utf8)
            case ("vercel", "deploy-json"): return Data(#"{"id":"dpl_1","state":"QUEUED"}"#.utf8)
            case ("vercel", "status"): return Data(#"{"id":"dpl_1","state":"READY"}"#.utf8)
            case ("ci", _): try await Task.sleep(nanoseconds: 5_000_000_000); return Data(#"{"state":"green","reason":""}"#.utf8)
            default: throw ToolError(message: "not in this test")
            }
        }
        let st = Store()
        var a = item(changed: true, commits: 1); a.repo = "me/app"
        st.items[.vercel] = [a]
        st.deployOne(a, preview: false)
        spin { if case .done = st.items[.vercel]![0].state { return true } else { return false } }
        let i = st.items[.vercel]![0]
        expect("deploy followed to live", "\(i.state)", "done(nil)")
        expect("live row is current", "\(i.hasNewCommits) \(i.lastFailed)", "false false")
        expect("nothing left to follow after the end", Store.readFollowed().isEmpty, true)

        // The follow deadline (40 minutes, 12 hours), on a short clock: a deploy that never ends frees the row.
        Store.followLimits = (.milliseconds(100), .milliseconds(400))
        Tool.testRunner = { args in
            switch (args.first ?? "", args.dropFirst().first ?? "") {
            case ("window", _): return Data(#"{"denied":false}"#.utf8)
            case ("vercel", "deploy-json"): return Data(#"{"id":"dpl_2","state":"QUEUED"}"#.utf8)
            case ("vercel", "status"): return Data(#"{"id":"dpl_2","state":"BUILDING"}"#.utf8)
            default: throw ToolError(message: "not in this test")
            }
        }
        let slow = Store()
        var c = item(changed: true, commits: 1); c.repo = "me/app"
        slow.items[.vercel] = [c]
        slow.deployOne(c, preview: false)
        var sawOverdue = false
        spin {
            if slow.items[.vercel]![0].state == Store.overdueState { sawOverdue = true }
            if case .failed = slow.items[.vercel]![0].state { return true } else { return false }
        }
        expect("follow: overdue said before giving up", sawOverdue, true)
        expect("follow: no result after the deadline", "\(slow.items[.vercel]![0].state)",
               "failed(\"\(L("No result after 12 hours – check the dashboard", "Kein Ergebnis nach 12 Stunden – im Dashboard nachsehen"))\")")
        expect("follow: nothing left to follow after the deadline", Store.readFollowed().isEmpty, true)
        Store.followLimits = (.seconds(40 * 60), .seconds(12 * 3600))

        Tool.testRunner = nil
        Store.pollNanos = nil
        if let oldUndo { UserDefaults.standard.set(oldUndo, forKey: "undoSeconds") } else { UserDefaults.standard.removeObject(forKey: "undoSeconds") }
        UserDefaults.standard.removeObject(forKey: "followedDeploys")
    }

    // Review fixes: one summary line, window.json never overwritten unread, hover hold per toast.
    expect("waiting summary: projects and PRs", waitingSummary(Store.Waiting(projects: 7, commits: 9, prs: 44, openPRs: 0), saved: 41),
           L("7 projects · 44 PRs waiting · \(usd0(41)) saved", "7 Projekte · 44 PRs warten · \(usd0(41)) gespart"))
    expect("waiting summary: one project, no PRs", waitingSummary(Store.Waiting(projects: 1, commits: 2, prs: 0, openPRs: 0), saved: nil),
           L("1 project waiting", "1 Projekt wartet"))
    expect("window.json with a typo is not written over", DeployWindowConfig.unreadable(Data("{\"deny\": [".utf8)), true)
    expect("missing window.json may be written", DeployWindowConfig.unreadable(nil), false)
    let emptyWin = (try? DeployWindowConfig().encoded(over: Data(#"{"deny":[{"days":["fri"]}],"note":"x"}"#.utf8)))
        .flatMap { try? JSONSerialization.jsonObject(with: $0) as? [String: Any] }
    expect("no rules keep the other keys", "\((emptyWin?["deny"] as? [Any])?.count ?? -1) \(emptyWin?["note"] as? String ?? "")", "0 x")
    MainActor.assumeIsolated {
        let st = Store()
        st.show(Store.Toast(text: "a", ok: true)); st.holdToast(true)
        st.show(Store.Toast(text: "b", ok: true))
        expect("a new toast is not held by the old hover", st.toastHeld, false)
    }

    // Additive values of newer scripts (CLI, providers): read when sent, harmless when not.
    do {
        let v = try JSONDecoder().decode(VercelProject.self, from: Data(#"{"name":"a","auto":false,"deployable":true,"openPRs":100,"openPRsPartial":true,"budgetLow":true,"partial":true}"#.utf8))
        let i = v.item(id: "a", platform: .vercel, detail: "", note: nil, link: nil, latestState: nil)
        expect("new list flags reach the row", "\(i.openPRsPartial) \(i.budgetLow) \(i.partial)", "true true true")
        expect("capped open PRs say 'at least'", Row.openText(i, 100), L("at least 100 open PRs", "mindestens 100 offene PRs"))
        expect("a partial list is a quiet hint, two of them here", Row.gapTexts(i).count, 2)
        let warned = try JSONDecoder().decode(RenderService.self, from: Data(#"{"id":"s","name":"a","type":"web","paused":false,"auto":false,"deployable":true,"fetchWarn":"domains could not be read"}"#.utf8))
            .item(id: "s", platform: .render, detail: "", note: nil, link: nil, latestState: nil)
        expect("a provider's fetchWarn is a hint too", Row.gapTexts(warned), ["domains could not be read"])
        let old = try JSONDecoder().decode(VercelProject.self, from: Data(#"{"name":"a","auto":false,"deployable":true}"#.utf8))
            .item(id: "a", platform: .vercel, detail: "", note: nil, link: nil, latestState: nil)
        expect("an older script: no hints", "\(old.partial) \(Row.gapTexts(old).count)", "false 0")
        let d = try JSONDecoder().decode(Doctor.self, from: Data(#"{"jq":true,"perl":false,"curl":true}"#.utf8))
        expect("doctor names a missing perl", d.missingTools, ["perl"])
        let d0 = try JSONDecoder().decode(Doctor.self, from: Data(#"{"jq":true}"#.utf8))
        expect("an older doctor misses nothing", d0.missingTools, [])
        let ai = try JSONDecoder().decode(ClaudeAIStatus.self, from: Data(#"{"key":true,"source":"env","model":"m","models":["m"],"cap":1,"used":0,"month":"2026-11","envHidesKeychain":true}"#.utf8))
        expect("ai status: the environment hides the keychain", ai.envHidesKeychain == true, true)
        let ai0 = try JSONDecoder().decode(ClaudeAIStatus.self, from: Data(#"{"key":true,"source":"env","model":"m","models":["m"],"cap":1,"used":0,"month":"2026-11"}"#.utf8))
        expect("ai status from an older script", ai0.envHidesKeychain == nil, true)
    } catch { expect("newer script values decode", "\(error)", "no error") }
    // The phone link: new fields are optional both ways.
    do {
        var k = LinkedKeys(); k.vercel = "v"; k.savingPerMonth = 42; k.once = "id1"
        let back = try JSONDecoder().decode(LinkedKeys.self, from: try JSONEncoder().encode(k))
        expect("saving and once id travel", "\(back.savingPerMonth ?? 0) \(back.once ?? "")", "42.0 id1")
        let older = try JSONDecoder().decode(LinkedKeys.self, from: Data(#"{"vercel":"v","vercelTeam":"","render":"","github":"","updated":0}"#.utf8))
        expect("keys from an older Mac app still read", older.savingPerMonth == nil && older.once == nil && older.vercel == "v", true)
    } catch { expect("linked keys decode", "\(error)", "no error") }
    let snapEN = DeploySnapshot(at: Date(), demo: false, waitingProjects: 1, waitingCommits: 1, waitingPRs: 0, building: 0, failed: 0,
                                saving: nil, projects: [], language: "en")
    var snapNext = snapEN; snapNext.nextScheduled = .init(name: "Atlas-214", platform: "Vercel", at: Date().addingTimeInterval(600))
    expect("a snapshot with a planned deploy round-trips",
           (try? JSONDecoder().decode(DeploySnapshot.self, from: JSONEncoder().encode(snapNext)))?.nextScheduled?.name ?? "", "Atlas-214")
    do {
        var cal = Calendar(identifier: .gregorian); cal.timeZone = TimeZone(identifier: "UTC")!
        func at(_ d: String) -> Date { let f = ISO8601DateFormatter(); return f.date(from: d)! }
        let fri = at("2026-11-20T10:00:00Z")   // a Friday
        expect("next daily: later today", DeploySnapshot.nextDaily(at: "18:30", weekdaysOnly: false, after: fri, calendar: cal) == at("2026-11-20T18:30:00Z"), true)
        expect("next daily: already past is tomorrow", DeploySnapshot.nextDaily(at: "09:00", weekdaysOnly: false, after: fri, calendar: cal) == at("2026-11-21T09:00:00Z"), true)
        expect("next daily: weekdays skip the weekend", DeploySnapshot.nextDaily(at: "09:00", weekdaysOnly: true, after: fri, calendar: cal) == at("2026-11-23T09:00:00Z"), true)
        expect("next daily: a bad time is none", DeploySnapshot.nextDaily(at: "25:00", weekdaysOnly: false, after: fri, calendar: cal) == nil, true)
        let tmp = FileManager.default.temporaryDirectory.appendingPathComponent("nx-\(UUID().uuidString)")
        let cfg = tmp.appendingPathComponent("cfg"), launch = tmp.appendingPathComponent("launch")
        try? FileManager.default.createDirectory(at: cfg, withIntermediateDirectories: true)
        try? FileManager.default.createDirectory(at: launch, withIntermediateDirectories: true)
        try? Data(#"{"daily":{"at":"07:15","args":[]}}"#.utf8).write(to: cfg.appendingPathComponent("schedule.json"))
        let env = ["DEPLOYS_CONFIG": cfg.path, "DEPLOYS_LAUNCH_DIR": launch.path]
        expect("no launchd job: nothing planned", Store.nextScheduled(german: false, home: tmp, env: env) == nil, true)
        FileManager.default.createFile(atPath: launch.appendingPathComponent("app.deploycenter.daily.plist").path, contents: Data())
        expect("a daily job is planned", Store.nextScheduled(german: true, home: tmp, env: env)?.name ?? "", "Täglicher Deploy")
        try? FileManager.default.removeItem(at: tmp)
    }
    expect("a11y: saved mark", AutofixSettings.savedLabel(true), L("Saved", "Gespeichert"))
    expect("a11y: not saved mark", AutofixSettings.savedLabel(false), L("Not saved", "Nicht gespeichert"))
    expect("a11y: the two marks differ", AutofixSettings.savedLabel(true) != AutofixSettings.savedLabel(false), true)
    var snapDE = snapEN; snapDE.language = "de"
    expect("a language switch is a change for the widgets", snapEN.sameContent(as: snapDE), false)
    expect("only the time is not", snapEN.sameContent(as: DeploySnapshot(at: .distantPast, demo: false, waitingProjects: 1, waitingCommits: 1, waitingPRs: 0,
                                                                         building: 0, failed: 0, saving: nil, projects: [], language: "en")), true)
    // Settings: a pasted repo address, the hand-over list with PR states.
    expect("team: owner/repo stays", TeamSettings.ownerRepo(" me/app ") ?? "", "me/app")
    expect("team: a github.com address", TeamSettings.ownerRepo("https://github.com/me/app.git") ?? "", "me/app")
    expect("team: a git remote", TeamSettings.ownerRepo("git@github.com:me/app.git") ?? "", "me/app")
    expect("team: a page of the repo", TeamSettings.ownerRepo("github.com/me/app/tree/main") ?? "", "me/app")
    expect("team: another host is not a repo", TeamSettings.ownerRepo("https://gitlab.com/me/app") == nil, true)
    expect("team: no slash is no repo", TeamSettings.ownerRepo("app") == nil, true)
    expect("team: a trailing slash", TeamSettings.ownerRepo("https://github.com/me/app/") ?? "", "me/app")
    expect("team: ssh address with the user", TeamSettings.ownerRepo("ssh://git@github.com/me/app.git") ?? "", "me/app")
    expect("team: letters beyond ASCII are fine", TeamSettings.ownerRepo("münchen/app") ?? "", "münchen/app")
    expect("team: empty is no repo", TeamSettings.ownerRepo("  ") == nil, true)
    expect("autofix list: an open PR is said",
           AutofixSettings.label(F(at: 1, project: "a", platform: "vercel", status: "fired", prNumber: 3, prState: "open")), L("fix PR open", "Fix-PR offen"))
    expect("autofix list: a closed PR is said",
           AutofixSettings.label(F(at: 1, project: "a", platform: "vercel", status: "fired", prNumber: 3, prState: "closed")), L("fix PR closed unmerged", "Fix-PR ungemergt geschlossen"))
    expect("an empty tab names what waits elsewhere",
           waitingSummary(Store.Waiting(), saved: nil, elsewhere: 7, here: "Render"),
           L("Nothing waits on Render · 7 projects on other platforms", "Auf Render wartet nichts · 7 Projekte auf anderen Plattformen"))
    let now0 = Date()
    expect("ledger: due without a last run", SavingsModel.ledgerDue(at: nil, budget: nil, now: now0), true)
    expect("ledger: not again within a week", SavingsModel.ledgerDue(at: now0.addingTimeInterval(-3 * 86400), budget: nil, now: now0), false)
    expect("ledger: not on a nearly spent GitHub budget",
           SavingsModel.ledgerDue(at: nil, budget: Store.Budget(remaining: 500, limit: 5000, reset: 0), now: now0), false)
    expect("a JSON error on stdout is the message", Tool.jsonError(Data(#"{"error":"No project named x","exit":1}"#.utf8)) ?? "", "No project named x")
    expect("other stdout is no error message", Tool.jsonError(Data(#"[{"name":"a"}]"#.utf8)) == nil, true)

}
