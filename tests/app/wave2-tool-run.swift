// App tests: wave2-tool-run. Called from tests/app/main.swift.

import AppKit

@MainActor func suite_wave2_tool_run() {
    // Wave 2: logic fixes.
    expect("plural one", plural(1, "project", "projects"), "1 project")
    expect("plural many", plural(3, "project", "projects"), "3 projects")
    var rw = Store.Waiting(); rw.projects = 1; rw.prs = 1
    expect("reminder, one PR", Store.reminderText(rw), L("1 PR in 1 project waits to go live.", "1 PR in 1 Projekt wartet darauf, live zu gehen."))
    rw.projects = 2; rw.prs = 0; rw.commits = 3
    expect("reminder, commits only", Store.reminderText(rw), L("3 commits in 2 projects wait to go live.", "3 Commits in 2 Projekten warten darauf, live zu gehen."))
    let budgetDays = try! JSONDecoder().decode([Costs.Day].self, from: Data("""
    [{"day":"2026-11-08","total":1,"build":10},{"day":"2026-11-09","total":1,"build":10},{"day":"2026-11-10","total":0,"build":0}]
    """.utf8))
    expect("budget pace leaves out today", Store.monthPace(budgetDays, today: "2026-11-10") ?? -1, 300.0)
    expect("budget pace with only today", Store.monthPace(Array(budgetDays.suffix(1)), today: "2026-11-10") == nil, true)
    let sum = Store.summary([(.done(nil), false), (.failed("x"), false), (.skipped("red"), false), (.skipped("red"), false), (.failed("c"), true)])
    expect("summary counts skipped rows", sum.title, L("1 live, 1 failed, 2 skipped, 1 cancelled", "1 live, 1 fehlgeschlagen, 2 übersprungen, 1 abgebrochen"))
    expect("summary ok only without failures", sum.ok, false)
    expect("summary: stopped in the queue counts as cancelled", Store.summary([(.done(nil), false), (.idle, true)]).title, L("1 live, 0 failed, 1 cancelled", "1 live, 0 fehlgeschlagen, 1 abgebrochen"))
    expect("median of the last measurements", [Store.median([]) as Any?, Store.median([0.2, 0.1, 5, 0.3, 0.2]) as Any?, Store.median([1, 3]) as Any?].map { "\($0 ?? "nil")" }, ["nil", "0.2", "2.0"])
    expect("friendlyError: a repo called offline-first is no network error", ContentView.friendlyError("repo offline-first: build failed", "Vercel") ?? "nil", "nil")
    expect("friendlyError: the word offline is", ContentView.friendlyError("Mac is offline", "Vercel") != nil, true)
    expect("friendlyError: timeout-service is no timeout", ContentView.friendlyError("deploy of timeout-service failed", "Render") ?? "nil", "nil")
    expect("ago: a time ahead reads now", !Row.ago(Date().addingTimeInterval(180)).lowercased().contains("in 3") && !Row.ago(Date().addingTimeInterval(180)).lowercased().contains("in drei"), true)
    expect("summary without skips", Store.summary([(.done(nil), false), (.done(nil), false)]).title, L("2 live, 0 failed", "2 live, 0 fehlgeschlagen"))
    let undoA = Store.Toast(text: "a", ok: false, undoLabel: "Cancel", undo: {}), undoB = Store.Toast(text: "b", ok: false, undoLabel: "Cancel", undo: {})
    let plain = (1...3).map { Store.Toast(text: "p\($0)", ok: true) }
    let tq = plain.reduce(Store.queued([], undoA)) { Store.queued($0, $1) }
    expect("an undo toast is never dropped from the queue", Store.queued(tq, undoB).map(\.text), ["a", "p2", "p3", "b"])
    expect("preselect keys of shown rows stay", Store.keepPreselected((0..<150).map { "k\($0)" }, current: ["k3"]).contains("k3"), true)
    expect("preselect keeps the last 100", Store.keepPreselected((0..<150).map { "k\($0)" }, current: []).count, 100)
    expect("poll often at first", Store.pollSeconds(elapsed: 30, usualMinutes: 20), 6)
    expect("poll less in the middle of a long build", Store.pollSeconds(elapsed: 600, usualMinutes: 20), 15)
    expect("poll often near the usual end", Store.pollSeconds(elapsed: 19 * 60, usualMinutes: 20), 6)
    expect("poll less without a usual time", Store.pollSeconds(elapsed: 600, usualMinutes: nil), 15)
    let refT = Date(timeIntervalSince1970: 0)
    expect("refresh not due yet", Store.refreshDue(since: refT, minutes: 15, now: refT.addingTimeInterval(14 * 60)), false)
    expect("refresh due with a shorter interval", Store.refreshDue(since: refT, minutes: 5, now: refT.addingTimeInterval(5 * 60)), true)
    expect("autofix not set up by exit code", Store.autofixNotSetUp(ToolError(message: "Fehler", exitCode: 5)), true)
    expect("autofix other error", Store.autofixNotSetUp(ToolError(message: "busy", exitCode: 3)), false)
    expect("autofix older script text", Store.autofixNotSetUp(ToolError(message: "autofix: no routine set")), true)

    // Tool.run with a stand-in script: output, errors with their exit code, timeouts, and a child that
    // keeps the pipe open after bash ended (the answer must not wait for it).
    let fakeDir = FileManager.default.temporaryDirectory.appendingPathComponent("dc-tool-\(UUID().uuidString)")
    try! FileManager.default.createDirectory(at: fakeDir, withIntermediateDirectories: true)
    let fake = fakeDir.appendingPathComponent("deploys")
    try! """
    case "$1" in
      hello) echo "hi $2" ;;
      fail) echo "it broke" >&2; exit 5 ;;
      hang) sleep 30 ;;
      daemon) (sleep 19.6 &) ; echo started ;;  # 19.6: no other test looks for this orphan
      big) head -c 300000 /dev/zero | tr '\\0' 'x' ;;
    esac
    """.write(to: fake, atomically: true, encoding: .utf8)
    Tool.testPath = fake.path
    func runFake(_ args: [String], timeout: Double = 20) -> (String, ToolError?, Double) {
        let t = Date(), box = DispatchSemaphore(value: 0)
        nonisolated(unsafe) var result: (String, ToolError?) = ("", nil)
        Task.detached {
            do { result = (String(decoding: try await Tool.run(args, timeout: timeout), as: UTF8.self), nil) }
            catch { result = ("", error as? ToolError) }
            box.signal()
        }
        box.wait()
        return (result.0, result.1, Date().timeIntervalSince(t))
    }
    expect("run: output", runFake(["hello", "there"]).0, "hi there\n")
    let failed = runFake(["fail"])
    expect("run: error text", failed.1?.message ?? "nil", "it broke")
    expect("run: exit code", failed.1?.exitCode.map { Int($0) } ?? -1, 5)
    let hung = runFake(["hang"], timeout: 1)
    expect("run: timeout", hung.1?.timedOut ?? false, true)
    expect("run: timeout answers soon", hung.2 < 8, true)
    let daemon = runFake(["daemon"])
    expect("run: a child holding the pipe does not hold the answer", daemon.0, "started\n")
    expect("run: answered within a few seconds", daemon.2 < 8, true)
    expect("run: large output is read whole", runFake(["big"]).0.count, 300000)
    func execFake(_ args: [String], timeout: Double) -> ((status: Int32?, out: Data), Double) {
        let t = Date(), box = DispatchSemaphore(value: 0)
        nonisolated(unsafe) var r: (status: Int32?, out: Data) = (nil, Data())
        Task.detached { r = await Tool.exec("/bin/bash", [fake.path] + args, mergeStderr: true, timeout: timeout); box.signal() }
        box.wait()
        return (r, Date().timeIntervalSince(t))
    }
    expect("exec: output and status", "\(execFake(["fail"], timeout: 10).0.status ?? -1) \(String(decoding: execFake(["fail"], timeout: 10).0.out, as: UTF8.self))", "5 it broke\n")
    let execHung = execFake(["hang"], timeout: 1)
    expect("exec: a hang ends without a status", execHung.0.status == nil && execHung.1 < 8, true)
    expect("exec: a child holding the pipe is not waited for", execFake(["daemon"], timeout: 20).1 < 8, true)
    Tool.testPath = nil
    try? FileManager.default.removeItem(at: fakeDir)

    var gl = item(changed: true); gl.repo = "gitlab.com/group/app"
    expect("GitLab compare link", gl.compareURL?.absoluteString ?? "nil", "https://gitlab.com/group/app/-/compare/a...main")
    func lossyError(_ json: String) -> String {
        do { _ = try decodeLossy(VercelProject.self, from: Data(json.utf8), label: "vercel json"); return "no error" }
        catch { return error.localizedDescription }
    }
    expect("an error object shows its text", lossyError(#"{"error":"Vercel login expired"}"#), "Vercel login expired")
    expect("other junk says where to look", lossyError("<html>"), L("Unexpected answer from vercel json – details in the log.", "Unerwartete Antwort von vercel json – Details im Log."))

    // Claude connection: an entry into a moved app is out of date; a failed re-add can bring the old one back.
    let mcpEntry: [String: Any] = ["command": "/opt/node", "args": ["/Apps/DC.app/mcp/server.mjs"], "env": ["DEPLOYS_BIN": "/Apps/DC.app/deploys", "DEPLOYS_MCP_ALLOW_DEPLOY": "1"]]
    expect("entry with every path there", ClaudeConfig.stale(mcpEntry, exists: { _ in true }), false)
    expect("entry into a moved app", ClaudeConfig.stale(mcpEntry, exists: { !$0.contains("DC.app") }), true)
    expect("restore args keep the switch", ClaudeConfig.codeAddArgs(restoring: mcpEntry)?.contains("DEPLOYS_MCP_ALLOW_DEPLOY=1") ?? false, true)
    expect("no restore without a server", ClaudeConfig.codeAddArgs(restoring: ["command": "/opt/node"]) == nil, true)
    let bakDir = FileManager.default.temporaryDirectory.appendingPathComponent("dc-bak-\(UUID().uuidString)")
    try! FileManager.default.createDirectory(at: bakDir, withIntermediateDirectories: true)
    let cfgPath = bakDir.appendingPathComponent("cfg.json").path
    for k in 0..<5 { FileManager.default.createFile(atPath: cfgPath + ".bak-20261110-10000\(k)", contents: Data()) }
    FileManager.default.createFile(atPath: bakDir.appendingPathComponent("other.bak-1").path, contents: Data())
    ClaudeFiles.pruneBackups(of: cfgPath, keep: 3)
    expect("only the newest three backups stay", (try! FileManager.default.contentsOfDirectory(atPath: bakDir.path)).sorted(),
           ["cfg.json.bak-20261110-100002", "cfg.json.bak-20261110-100003", "cfg.json.bak-20261110-100004", "other.bak-1"])
    try? FileManager.default.removeItem(at: bakDir)

    expect("platform label", ProviderInfo.label(for: "digitalocean"), "DigitalOcean App Platform")
    expect("unknown platform label", ProviderInfo.label(for: "railway"), "Railway")
    expect("German method for the ledger", SavingsFormat.methodGerman("Estimate. Since auto-deploy was turned off, every push …").hasPrefix("Schätzung. Seit Auto-Deploy aus ist"), true)
    expect("an unknown method is shown as written", SavingsFormat.methodGerman("New way of counting."), "New way of counting.")

    // Settings parts read an answer with fields missing instead of showing "not set up".
    expect("autofix status without scheduled", (try? JSONDecoder().decode(AutofixReport.self, from: Data(#"{"routine":"trig_1","token":true,"fires":[]}"#.utf8)))?.routine ?? "nil", "trig_1")
    // One reader for rows and Settings: an empty routine is none (Settings showed "1. Routine" as done).
    expect("autofix status: an empty routine is not ready", (try? JSONDecoder().decode(AutofixReport.self, from: Data(#"{"routine":"","token":true,"scheduled":true,"pathMissing":["gh"],"fires":[]}"#.utf8))).map { "\($0.ready) \($0.scheduled) \($0.pathMissing)" } ?? "nil", "false true [\"gh\"]")
    expect("guard status without lastActions", (try? JSONDecoder().decode(GuardStatus.self, from: Data(#"{"enabled":true}"#.utf8)))?.enabled ?? false, true)
    expect("team config without sources", (try? JSONDecoder().decode(TeamConfig.self, from: Data(#"{"readonly":{"value":true,"from":"repo"}}"#.utf8)))?.readonly.value ?? false, true)

    // The app's masker knows what the script's masker knows.
    expect("mask Stripe", LogTools.maskSecrets("key sk_live_abcdefgh12345678"), "key [STRIPE KEY]")
    expect("mask GitLab", LogTools.maskSecrets("glpat-abcdefghij1234567890"), "[GITLAB TOKEN]")
    expect("mask npm", LogTools.maskSecrets("npm_abcdefghijklmnopqrstuvwxyz0123456789"), "[NPM TOKEN]")
    expect("mask Google", LogTools.maskSecrets("AIzaSyA1234567890abcdefghijklmnopqrstu"), "[GOOGLE KEY]")
    expect("mask --token", LogTools.maskSecrets("vercel deploy --token abc123def"), "vercel deploy --token [HIDDEN]")
    expect("mask private key block", LogTools.maskSecrets("a\n-----BEGIN RSA PRIVATE KEY-----\nMIIE\nabc\n-----END RSA PRIVATE KEY-----\nb"), "a\n[PRIVATE KEY]\nb")
    expect("mask cut-off private key", LogTools.maskSecrets("x -----BEGIN PRIVATE KEY-----\nMIIE"), "x [PRIVATE KEY]")
    // The script's masker test reads the same lines (tests/script-tests.sh): what one hides, the other hides.
    if let sample = try? String(contentsOfFile: "tests/fixtures/mask/secrets.txt", encoding: .utf8),
       let plain = try? String(contentsOfFile: "tests/fixtures/mask/plain.txt", encoding: .utf8) {
        let left = LogTools.maskSecrets(sample).split(separator: "\n").map { $0.replacingOccurrences(of: "SECRET_KEY=", with: "S_K=") }.filter { $0.contains("SECRET") }
        expect("mask: no secret of the script's list survives", left, [])
        expect("mask: an ordinary build line is left as it is", LogTools.maskSecrets(plain), plain)
    } else { expect("mask fixtures readable", false, true) }
    // The phone's GitHub token: its own read-only one wins over the gh CLI's; neither unless asked.
    expect("phone GitHub: own token wins", PhoneLinkModel.githubSource(own: "github_pat_x", shareGh: true), PhoneLinkModel.GitHubSource.own)
    expect("phone GitHub: gh only when switched on", [PhoneLinkModel.githubSource(own: nil, shareGh: true), PhoneLinkModel.githubSource(own: "", shareGh: false)],
           [PhoneLinkModel.GitHubSource.gh, .none])
    var lk = LinkedKeys(); lk.render = "r"; var lk2 = lk; lk2.updated = Date().addingTimeInterval(99)
    expect("same keys at another time", PhoneLinkModel.sameKeys(lk, lk2), true)
    lk2.github = "g"
    expect("a changed key is pushed", PhoneLinkModel.sameKeys(lk, lk2), false)

    // Bug scan status: the newest run per repo, running, a PR link.
    do {
        let r = try! JSONDecoder().decode(ScanReport.self, from: Data(#"{"installed":true,"loggedIn":true,"perDay":4,"runs":[{"id":"b","repo":"me/web","base":"main","at":20,"status":"pr","step":"done","branch":"claude/scan-web-abc","prUrl":"https://github.com/me/web/pull/7","fixes":2,"error":null},{"id":"a","repo":"me/web","at":10,"status":"clean"},{"id":"c","repo":"me/api","at":30,"status":"running","step":"claude"}]}"#.utf8))
        expect("scan: newest run of a repo", r.newest(repo: "Me/Web")?.id ?? "", "b")
        expect("scan: PR and fixes", "\(r.newest(repo: "me/web")?.prUrl ?? "") \(r.newest(repo: "me/web")?.fixes ?? 0)", "https://github.com/me/web/pull/7 2")
        expect("scan: a running scan is seen", r.anyRunning, true)
        expect("scan: no repo, no run", r.newest(repo: nil) == nil, true)
        expect("scan: an old script without checks still decodes", r.checks == nil && r.tools == nil, true)
        let c = try! JSONDecoder().decode(ScanReport.self, from: Data(#"{"installed":true,"loggedIn":false,"runs":[],"tools":{"osv":true,"gitleaks":false,"semgrep":true},"checks":[{"id":"k1","repo":"me/web","at":5,"status":"done","osv":2,"gitleaks":1,"semgrep":3,"tools":{"osv":"found"},"error":null},{"id":"k2","repo":"me/api","at":6,"status":"running"}]}"#.utf8))
        expect("check: newest check of a repo, fixable without secrets", "\(c.newestCheck(repo: "me/web")?.id ?? "") \(c.newestCheck(repo: "me/web")?.fixable ?? 0)", "k1 5")
        expect("check: a running check keeps polling", c.anyRunning, true)
        expect("check: tools", c.tools?.any ?? false, true)
    }

    // Settings: tabs, links into them, pickers, diagnostics, budget text, connection.
    expect("settings tab: an old stored tab still opens", SettingsTab.resolve("team"), SettingsTab.team)
    expect("settings tab: an unknown one opens General", SettingsTab.resolve("advanced"), SettingsTab.general)
    expect("settings tab: none opens General", SettingsTab.resolve(nil), SettingsTab.general)
    expect("settings link: path", SettingsNav.tab(from: URL(string: "deploycenter://settings/claude")!) ?? .help, SettingsTab.claude)
    expect("settings link: query", SettingsNav.tab(from: URL(string: "deploycenter://settings?tab=Costs")!) ?? .help, SettingsTab.costs)
    expect("settings link: unknown tab opens General", SettingsNav.tab(from: URL(string: "deploycenter://settings/nope")!) ?? .help, SettingsTab.general)
    expect("settings link: a select link is not one", SettingsNav.tab(from: URL(string: "deploycenter://select?project=app")!) == nil, true)
    expect("settings link: another scheme is not one", SettingsNav.tab(from: URL(string: "https://settings/claude")!) == nil, true)
    do {
        let d = UserDefaults(suiteName: "dc-tests-settings")!
        d.removePersistentDomain(forName: "dc-tests-settings")
        SettingsNav.prepare(.claude, anchor: "autofix", defaults: d)
        expect("settings: tab and anchor stored", "\(d.string(forKey: "settingsTab") ?? "") \(d.string(forKey: "settingsAnchor") ?? "")", "claude autofix")
        d.set(4, forKey: "maxParallel"); d.set(10, forKey: "refreshMinutes"); d.set(99, forKey: "undoSeconds"); d.set(5, forKey: "staleDays")
        SettingsChoice.snapAll(d)
        expect("snap: unknown values become the nearest offered", "\(d.integer(forKey: "maxParallel")) \(d.integer(forKey: "refreshMinutes")) \(d.integer(forKey: "undoSeconds")) \(d.integer(forKey: "staleDays"))", "3 5 15 5")
        expect("snap: an unset value stays unset", d.object(forKey: "reminderHour") == nil, true)
        d.removePersistentDomain(forName: "dc-tests-settings")
    }
    expect("snap: a tie takes the smaller", SettingsChoice.snap(45, to: [5, 15, 30, 60]), 30)
    expect("snap: below the list", SettingsChoice.snap(-3, to: SettingsChoice.undoSeconds), 0)
    expect("snap: an allowed value stays", SettingsChoice.snap(8, to: SettingsChoice.undoSeconds), 8)
    expect("reset: General keeps the language and keys", SettingsTab.general.defaultsKeys.contains("AppleLanguages") || SettingsTab.general.defaultsKeys.contains { $0.lowercased().contains("key") && $0 != "paletteHotKey" }, false)
    expect("reset: project data is not a tab default", SettingsTab.allCases.flatMap(\.defaultsKeys).filter { ["pinned", "hidden", "notes", "healthPaths", "autoRollback"].contains($0) }, [String]())
    do {
        let doc = try! JSONDecoder().decode(Doctor.self, from: Data(#"{"jq":true,"vercelCli":true,"vercelApi":true,"vercelLoggedIn":true,"githubCli":true,"githubLoggedIn":true,"renderKey":false}"#.utf8))
        let prov = ProviderInfo.builtIn + [ProviderInfo(id: "netlify", label: "Netlify", enabled: true)]
        let text = SettingsText.diagnostics(version: "1.0", os: "macOS", doctor: doc, providers: prov, counts: ["vercel": 3, "render": 0],
                                            gitlabRepos: 2, autofix: nil)
        expect("diagnostics: every platform has a line", text.contains("Netlify: on") && text.contains("Render: on, key false, 0 projects") && text.contains("Vercel: on, cli true/api true/login true, 3 projects"), true)
        expect("diagnostics: GitLab and Autofix", text.contains("GitLab: 2 repos") && text.contains("Autofix: unknown"), true)
        expect("connection: Render without key", SettingsText.connection("render", doctor: doc)?.ok ?? true, false)
        expect("connection: Vercel signed in", SettingsText.connection("vercel", doctor: doc)?.ok ?? false, true)
        expect("connection: unknown for others", SettingsText.connection("netlify", doctor: doc) == nil, true)
    }
    expect("budget hint: off", SettingsText.budgetHint(budget: 0, pace: 10).contains("0"), true)
    expect("budget hint: 80 % of 100", SettingsText.budgetHint(budget: 100, pace: nil).contains("80"), true)
    expect("shortcuts: no system ⌥⌘D", SettingsText.shortcuts.contains { $0.keys == "⌥⌘D" }, false)

    // A link or a menu-bar click shows exactly one project, by platform when a name is on two.
    do {
        let both = [item(.vercel), item(.render)]
        expect("show: a name on two platforms shows both", Store.showRequest("app", items: both)!, Store.ShowRequest(name: "app", key: nil))
        expect("show: platform:name picks one", Store.showRequest("render:app", items: both)!, Store.ShowRequest(name: "app", key: "render/srv-1"))
        expect("show: a unique name gets its key", Store.showRequest("app", items: [item(.vercel)])!, Store.ShowRequest(name: "app", key: "vercel/app"))
        expect("show: a colon that is no platform is part of the name", Store.showRequest("a:b", items: both)?.name ?? "", "a:b")
        expect("show: empty is nothing", Store.showRequest("  ", items: both) == nil, true)
    }
    MainActor.assumeIsolated {
        let st = Store()
        var a = Item(id: "a1", name: "one", detail: "", platform: .vercel, deployable: true, auto: false, note: nil, link: nil); a.changed = true
        var b = Item(id: "b1", name: "two", detail: "", platform: .vercel, deployable: true, auto: false, note: nil, link: nil); b.changed = true
        st.items[.vercel] = [a, b]
        let before = st.hidden
        expect("changed count: both", st.changedCount(.vercel), 2)
        st.toggleHidden(b)
        expect("changed count: without the hidden one", st.changedCount(.vercel), 1)
        st.toggleHidden(b)
        expect("changed count: hidden state restored", st.hidden, before)
    }

}
