// App tests: mac-track. Called from tests/app/main.swift.

import AppKit

@MainActor func suite_mac_track() {
    // Mac track (rest): deploy window editor, language, the script runner, Claude nudge, CLI texts, snapshot, phone link, Handoff.
    expect("window rule summary", DeployWindowSettings.summary(.init(days: ["fri", "sat"], from: "15:00")),
           L("Fri, Sat 15:00–24:00", "Fr, Sa 15:00–24:00"))
    expect("window rule over midnight", DeployWindowSettings.summary(.init(from: "22:00", to: "06:00")),
           L("every day 22:00–06:00 (over midnight)", "jeden Tag 22:00–06:00 (über Mitternacht)"))
    do {
        let suite = "dc-test-lang-\(UUID().uuidString)"
        let d = UserDefaults(suiteName: suite)!
        expect("language: nothing chosen is the Mac's", AppLanguage.chosen(in: d, domain: suite), AppLanguage.system)
        AppLanguage.de.save(to: d)
        expect("language: German saved", AppLanguage.chosen(in: d, domain: suite), AppLanguage.de)
        AppLanguage.system.save(to: d)
        expect("language: same as the Mac removes the key", d.persistentDomain(forName: suite)?["AppleLanguages"] == nil, true)
        expect("language: system follows a German Mac", AppLanguage.system.resolved(mac: ["de-DE", "en"]), AppLanguage.de)
        expect("language: system follows another Mac as English", AppLanguage.system.resolved(mac: ["fr-FR"]), AppLanguage.en)
        expect("language: a choice stays", AppLanguage.en.resolved(mac: ["de"]), AppLanguage.en)
        d.removePersistentDomain(forName: suite)
    }
    do {
        // A stand-in for `deploys`, and a log of the test's own: nothing real is started or written.
        let dir = FileManager.default.temporaryDirectory.appendingPathComponent("dc-tool-\(UUID().uuidString)")
        try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        let script = dir.appendingPathComponent("deploys")
        try? """
        case "$1" in
          big) head -c 200000 /dev/zero | tr '\\0' x >&2; printf ok ;;
          echo) read -r l; printf '%s' "$l" ;;
          slow) sleep 5 ;;
          fail) echo "Error: app not found" >&2; exit 3 ;;
        esac
        """.write(to: script, atomically: true, encoding: .utf8)
        Tool.testScript = script.path; Log.testURL = dir.appendingPathComponent("test.log")
        func run(_ args: [String], stdin: String? = nil, timeout: Double = 10, cancelAfter: Double? = nil) -> Result<String, Error> {
            let done = DispatchSemaphore(value: 0)
            nonisolated(unsafe) var r: Result<String, Error> = .success("")
            let t = Task.detached {
                do { r = .success(String(decoding: try await Tool.run(args, stdin: stdin, timeout: timeout), as: UTF8.self)) }
                catch { r = .failure(error) }
                done.signal()
            }
            if let c = cancelAfter { Thread.sleep(forTimeInterval: c); t.cancel() }
            _ = done.wait(timeout: .now() + 15)
            return r
        }
        expect("tool: 200 KB on stderr does not hang", (try? run(["big"]).get()) ?? "error", "ok")
        expect("tool: stdin reaches the script", (try? run(["echo"], stdin: "hello").get()) ?? "error", "hello")
        if case .failure(let e as ToolError) = run(["slow"], timeout: 0.5) { expect("tool: timeout", e.timedOut, true) } else { expect("tool: timeout", "no timeout", "timeout") }
        if case .failure(let e as ToolError) = run(["fail"]) {
            expect("tool: exit code and message", "\(e.exitCode ?? 0) \(e.message)", "3 " + L("Error: app not found", "Fehler: app nicht gefunden"))
        } else { expect("tool: failure", "no failure", "failure") }
        if case .failure(let e) = run(["slow"], cancelAfter: 0.3) { expect("tool: cancel", e is CancellationError, true) } else { expect("tool: cancel", "not cancelled", "cancelled") }
        Tool.testScript = nil; Log.testURL = nil
        try? FileManager.default.removeItem(at: dir)
    }
    let ours = Data(#"{"mcpServers":{"deploy-center":{"command":"node"}}}"#.utf8), other = Data(#"{"mcpServers":{"x":{}}}"#.utf8)
    expect("nudge: desktop without our entry", ClaudeNudge.wanted(desktopInstalled: true, desktopData: other, codeData: nil, cliFound: false), true)
    expect("nudge: desktop connected", ClaudeNudge.wanted(desktopInstalled: true, desktopData: ours, codeData: nil, cliFound: false), false)
    expect("nudge: unreadable desktop config is not offered", ClaudeNudge.wanted(desktopInstalled: true, desktopData: Data("{".utf8), codeData: nil, cliFound: false), false)
    expect("nudge: no desktop app", ClaudeNudge.wanted(desktopInstalled: false, desktopData: nil, codeData: nil, cliFound: false), false)
    expect("nudge: Claude Code found, not connected", ClaudeNudge.wanted(desktopInstalled: false, desktopData: nil, codeData: other, cliFound: true), true)
    expect("nudge: Claude Code connected", ClaudeNudge.wanted(desktopInstalled: false, desktopData: nil, codeData: ours, cliFound: true), false)
    expect("cli text: German with the name", CLIText.german("Error: No deploy of web found"), "Fehler: Kein Deploy von web gefunden")
    expect("cli text: the cap", CLIText.german("This month's Claude cap is reached (5 of 9 tokens). Raise it in Settings > Claude in the app, or: deploys ai cap <tokens>"),
           "Das Claude-Limit dieses Monats ist erreicht (5 von 9 Tokens). Erhöhen unter Einstellungen > Claude in der App oder: deploys ai cap <tokens>")
    expect("cli text: unknown stays", CLIText.german("Something new"), "Something new")
    do {
        let rows: [DeploySnapshot.Project] = [
            .init(name: "a", platform: "Vercel", status: .waiting, commits: 1, prs: 2, since: nil, message: nil),
            .init(name: "b", platform: "Render", status: .failed, commits: 0, prs: 0, since: nil, message: nil),
            .init(name: "c", platform: "Vercel", status: .building, commits: 0, prs: 0, since: nil, message: nil)]
        expect("snapshot: counts per platform", Store.counts(rows).map { "\($0.platform) \($0.waiting) \($0.prs) \($0.building) \($0.failed)" },
               ["Render 0 0 0 1", "Vercel 1 2 1 0"])
        let f = FileManager.default.temporaryDirectory.appendingPathComponent("dc-snap-\(UUID().uuidString).json")
        try? Data(#"{"version":2,"at":"2026-11-10T10:00:00Z","demo":false,"waitingProjects":1,"waitingCommits":1,"waitingPRs":0,"building":0,"failed":0,"projects":[],"newField":true}"#.utf8).write(to: f)
        expect("snapshot: a newer version still reads", DeploySnapshot.read(f)?.waitingProjects ?? -1, 1)
        try? FileManager.default.removeItem(at: f)
    }
    var k1 = LinkedKeys(); k1.vercel = "v"; var k2 = k1; k2.updated = Date().addingTimeInterval(99); k2.once = "x"
    expect("phone link: only the time changed is the same", k1.sameContent(as: k2), true)
    k2.render = "r"
    expect("phone link: a new key is a change", k1.sameContent(as: k2), false)
    let hand = item(.render)
    expect("handoff key is the iPhone's", Handoff.key(hand), "Render/srv-1")
    expect("handoff finds the project", Handoff.item(for: "Render/srv-1", in: [item(), hand])?.platform.cli ?? "", "render")
    expect("updates: on by default", [Updater.automaticChecks(nil), Updater.automaticChecks(false)], [true, false])

    expect("quiet hours", [Notify.quiet(hour: 23, from: 22, to: 7), Notify.quiet(hour: 6, from: 22, to: 7), Notify.quiet(hour: 7, from: 22, to: 7),
                            Notify.quiet(hour: 13, from: 12, to: 14), Notify.quiet(hour: 3, from: 0, to: 0)], [true, true, false, true, false])

    expect("owner check: several projects ask, one does not", [OwnerCheck.needed(projects: 1), OwnerCheck.needed(projects: 2)], [false, true])
    expect("owner check is off by default", OwnerCheck.on, false)

    do {
        let nested = try? JSONDecoder().decode(Doctor.self, from: Data(#"{"jq":true,"providers":{"vercel":{"vercelCli":true,"vercelLoggedIn":true},"render":{"renderKey":true}},"jobsMissing":["autofix:gh"]}"#.utf8))
        expect("doctor: provider flags under providers", "\(nested?.vercelLoggedIn ?? false) \(nested?.renderKey ?? false) \(nested?.jobsMissing ?? [])", "true true [\"autofix:gh\"]")
        let flat = try? JSONDecoder().decode(Doctor.self, from: Data(#"{"renderKey":true,"providers":{"render":{"renderKey":false}}}"#.utf8))
        expect("doctor: the provider's own object wins over the flat copy", flat?.renderKey ?? true, false)
        let g = try? JSONDecoder().decode(GuardStatus.self, from: Data(#"{"enabled":true,"lastActions":[],"allowances":[],"pathMissing":["vercel"]}"#.utf8))
        expect("guard: a tool the job no longer finds", g?.pathMissing ?? [], ["vercel"])
        let a = try? JSONDecoder().decode(AutofixReport.self, from: Data(#"{"token":true,"scheduled":true,"fires":[]}"#.utf8))
        expect("autofix: older script, nothing missing", a?.pathMissing ?? ["?"], [String]())
    }

    expect("cost note: all builds known", Store.costNote(perBuild: [1.5, 0.5], month: nil, budget: 0),
           "\n\n" + L("These builds cost about \(2.0.formatted(.currency(code: "USD"))).", "Diese Builds kosten etwa \(2.0.formatted(.currency(code: "USD")))."))
    expect("cost note: nothing known, budget fine", Store.costNote(perBuild: [nil], month: 10, budget: 20), "")
    expect("cost note: budget used up", Store.costNote(perBuild: [], month: 30, budget: 20).contains("20"), true)
    expect("project month", Store.projectMonth(build: 7, days: 7) ?? 0, 30.0)

    expect("watch: one bad answer is a blip", Store.watchFails([.fine, .broken]), false)
    expect("watch: two in a row count", Store.watchFails([.fine, .broken, .broken]), true)
    expect("watch: offline is never a failure", Store.watchFails([.unreachable, .unreachable]), false)
    expect("slower: twice and half a second more", [Store.slower(before: 0.2, after: 0.5), Store.slower(before: 0.4, after: 1.2)], [false, true])

    do {
        let old = Data(#"{"rules":[{"name":"Docs","when":{"ciGreen":true,"paths":["docs/**"],"onlyPaths":true,"branch":"main"},"then":"deploy","color":"red"}],"version":2}"#.utf8)
        let rc = RulesConfig.parse(old)
        expect("rules: read", "\(rc.rules.count) \(rc.rules.first?.then.rawValue ?? "") \(rc.rules.first?.onlyPaths ?? false)", "1 deploy true")
        let back = (try? rc.encoded(over: old)).flatMap { try? JSONSerialization.jsonObject(with: $0) as? [String: Any] }
        let r0 = (back?["rules"] as? [[String: Any]])?.first
        expect("rules: unknown keys stay", "\(back?["version"] as? Int ?? 0) \(r0?["color"] as? String ?? "") \((r0?["when"] as? [String: Any])?["branch"] as? String ?? "")", "2 red main")
        expect("rules: unchanged reads back the same", RulesConfig.parse(try? rc.encoded(over: old)) == rc, true)
        var bare = RulesConfig(); bare.rules = [.init(name: "all", then: .deploy)]
        expect("rules: deploying everything is refused", bare.problem != nil, true)
        bare.rules[0].labels = ["ship"]
        expect("rules: with a condition it may", bare.problem == nil, true)
        expect("rules: summary", RulesConfig.summary(rc.rules[0]),
               L("When CI is green and only docs/** changed: deploy it", "Wenn CI grün ist und nur docs/** geändert: deployen"))
        expect("rules: list", RulesConfig.list(" a, b\n,c "), ["a", "b", "c"])
    }

    expect("cli text: need_cap", CLIText.german("Error: Render cannot deploy a preview (api)"), "Fehler: Render kann keine Vorschau deployen (api)")
    expect("cli text: fetchWarn", CLIText.german("custom domains could not be read; the address shown may be the default one"),
           "Eigene Domains waren nicht lesbar; die gezeigte Adresse ist vielleicht die Standardadresse")
    if let hk = try? JSONDecoder().decode(VercelProject.self, from: Data(#"{"name":"h","auto":false,"deployable":true,"lastState":"triggered","lastSha":"abc","triggeredSha":"abc","phase":"queued"}"#.utf8)) {
        let hi = hk.item(id: "h", platform: .vercel, detail: "", note: nil, link: nil, latestState: nil)
        expect("hook: triggered, not live", "\(hi.triggered) \(hi.lastState ?? "")", "true queued")
    } else { expect("hook row decodes", "no", "yes") }
    expect("cli text: a shell's own error stays", CLIText.german("bash: foo: command not found"), "bash: foo: command not found")
    // Ticking what changed: never a hidden project; ⌘A only the rows on screen.
    MainActor.assumeIsolated {
        let st = Store()
        var shown = item(changed: true, commits: 1); shown.state = .idle
        var gone = Item(id: "web2", name: "web2", detail: "", platform: .vercel, deployable: true, auto: false, note: nil, link: nil)
        gone.changed = true
        st.items[.vercel] = [shown, gone]
        st.hidden = [Store.key(gone)]
        st.selectChanged(.vercel)
        expect("select changed skips a hidden project", st.selected(.vercel).map(\.id), ["app"])
        st.clearSelection(.vercel); st.hidden = []
        st.selectChanged(.vercel, only: [Store.key(gone)])
        expect("⌘A ticks only the visible rows", st.selected(.vercel).map(\.id), ["web2"])
        st.clearSelection(.vercel)
    }

    // After 40 minutes without a result the row stays busy, so no second build can start.
    expect("overdue build stays active", Store.overdueState.isActive, true)

    // The auto-rollback only goes ahead while the checked deploy is still the newest one.
    var live = item(); live.state = .done(nil); live.deployId = "d1"
    expect("rollback due for the checked deploy", Store.rollbackStillDue(live, checkedId: "d1", newerQueued: false), true)
    var newer = live; newer.deployId = "d2"
    expect("no rollback over a newer deploy", Store.rollbackStillDue(newer, checkedId: "d1", newerQueued: false), false)
    var busy = live; busy.state = .running("building")
    expect("no rollback while a deploy runs", Store.rollbackStillDue(busy, checkedId: "d1", newerQueued: false), false)
    expect("no rollback while one is queued", Store.rollbackStillDue(live, checkedId: "d1", newerQueued: true), false)
    expect("no rollback for a row that is gone", Store.rollbackStillDue(nil, checkedId: "d1", newerQueued: false), false)

    // Allowances with the script's wildcards cover every project.
    let later = Date().addingTimeInterval(3600)
    expect("allowance for all platforms", AutoDeployAllowance(platform: "all", project: "app", expiresAt: later).covers(item(.render)), true)
    expect("allowance for every project", AutoDeployAllowance(platform: "vercel", project: "*", expiresAt: later).covers(item()), true)
    expect("allowance for everything", AutoDeployAllowance(platform: "all", project: "*", expiresAt: later).covers(item(.render)), true)
    expect("wildcard project, other platform", AutoDeployAllowance(platform: "render", project: "*", expiresAt: later).covers(item()), false)
    expect("named project still exact", AutoDeployAllowance(platform: "vercel", project: "other", expiresAt: later).covers(item()), false)

    // Words in the row: one of each also in the "at least" case.
    expect("partial, one of each", Row.waitingText(item(changed: true, commits: 1, prs: 1, partial: true)),
           L("1 commit, at least 1 PR waiting", "1 Commit, mindestens 1 PR wartet"))

    // A cancelled deploy is no failure, in both spellings.
    expect("canceled looks cancelled", Row.look("CANCELED"), Row.DeployLook.cancelled)
    expect("cancelled looks cancelled", Row.look("cancelled"), Row.DeployLook.cancelled)
    expect("build_failed looks failed", Row.look("build_failed"), Row.DeployLook.failed)
    expect("ready looks ok", Row.look("READY"), Row.DeployLook.ok)
    var cancelledRow = item(changed: false); cancelledRow.lastAt = Date(); cancelledRow.lastState = "canceled"
    expect("cancelled is not the failed key figure", Row.keyFigure(cancelledRow), Row.KeyFigure.lastDeploy)

    // Search: the filter and the highlight use one rule, any case and without accents.
    expect("search ignores case", Row.matches("my-App", "app"), true)
    expect("search ignores accents", Row.matches("Über-Shop", "uber"), true)
    expect("empty search matches nothing", Row.matches("app", ""), false)
    expect("search misses", Row.matches("shop", "app"), false)

    // Where a repo lives.
    expect("owner/name is GitHub", GitHost(repo: "me/app"), GitHost.github)
    expect("gitlab.com path is GitLab", GitHost(repo: "gitlab.com/group/app"), GitHost.gitlab(host: "gitlab.com"))
    expect("self-managed GitLab", GitHost(repo: "git.example.org/team/sub/app").name, "GitLab")
    expect("github.com prefix is GitHub", GitHost(repo: "github.com/me/app"), GitHost.github)
    expect("GitHub PR link", GitHost.prURL("me/app", 12)?.absoluteString ?? "", "https://github.com/me/app/pull/12")
    expect("GitLab MR link", GitHost.prURL("gitlab.com/group/app", 12)?.absoluteString ?? "", "https://gitlab.com/group/app/-/merge_requests/12")
    expect("PR labels", GitHost.prLabel("me/app", 3) + " " + GitHost.prLabel("gitlab.com/g/app", 3), "#3 !3")
    var labItem = item(changed: true, last: "aaa", head: "bbb", repo: "gitlab.com/group/app")
    expect("GitLab compare link", labItem.compareURL?.absoluteString ?? "", "https://gitlab.com/group/app/-/compare/aaa...main")
    labItem.repo = "git.example.org/team/sub/app"
    expect("self-managed GitLab compare link", labItem.compareURL?.absoluteString ?? "", "https://git.example.org/team/sub/app/-/compare/aaa...main")
    labItem.repo = "me/app"
    expect("GitHub compare link unchanged", labItem.compareURL?.absoluteString ?? "", "https://github.com/me/app/compare/aaa...main")

    // The month at this pace: whole days only.
    let paceDays = (1...8).map { Costs.Day(day: "2026-11-0\($0)", total: 2, build: 2) } + [Costs.Day(day: "2026-11-09", total: 0, build: 0)]
    expect("pace leaves today out", CostsSheet.dailyPace(paceDays, today: "2026-11-09"), 2.0)
    expect("pace of the last 7 days", CostsSheet.dailyPace(paceDays, today: "2026-11-10"), Double(12) / 7)
    expect("pace without days", CostsSheet.dailyPace([], today: "2026-11-10"), 0.0)

    // What leaves the app from a row and the details.
    expect("copied error is masked", Row.errorCopy(item(), "push failed: ghp_abcdefghijklmnopqrstuvwxyz0123456789").contains("ghp_abcdef"), false)
    expect("first line of a failure", Row.firstLine("Build failed\nat step 3"), "Build failed")
    expect("ignored build step has a fallback", ProjectDetail.ignoredBuildStep, "git diff --quiet ${VERCEL_GIT_PREVIOUS_SHA:-HEAD^} HEAD -- .")
    expect("error line marked without colour", LogText.shown("Error: x", bad: true, noColour: true), "✖ Error: x")
    expect("error line plain with colour", LogText.shown("Error: x", bad: true, noColour: false), "Error: x")

    // Window texts.
    expect("closed notices ignore order", ContentView.issuesKey(["Vercel: a", "GitHub: b"]) == ContentView.issuesKey(["GitHub: b", "Vercel: a"]), true)
    var repoA = item(changed: true, commits: 4), repoB = item(.render, changed: true, commits: 2)
    expect("repo header", ContentView.repoSummary([repoA, repoB]), L("2 projects · 4 commits waiting", "2 Projekte · 4 Commits warten"))
    repoA.changed = false; repoB.changed = false
    expect("repo header, nothing waits", ContentView.repoSummary([repoA, repoB]), L("2 projects", "2 Projekte"))
    expect("confirmation names the platform", DeployConfirm.line(item(.render, changed: true, commits: 1), platform: true),
           "app (Render) – " + L("1 commit waiting", "1 Commit wartet"))

}
