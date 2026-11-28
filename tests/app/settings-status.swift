// App tests: settings-status. Called from tests/app/main.swift.

import AppKit

@MainActor func suite_settings_status() {
    // Status pages: from the provider, https only; a feed only for the known Statuspage sites.
    do {
        let p = try! JSONDecoder().decode([ProviderInfo].self, from: Data(#"[{"id":"netlify","statusPage":"https://example.org/status"},{"id":"cloudflare","statusPage":"http://x"},{"id":"amplify"},{"id":"newhost"}]"#.utf8))
        expect("status: the script's page", p[0].statusURL?.absoluteString ?? "", "https://example.org/status")
        expect("status: the known feed is still used", p[0].statusFeed?.absoluteString ?? "", "https://www.netlifystatus.com/api/v2/status.json")
        expect("status: http is not taken, the known page is", p[1].statusURL?.absoluteString ?? "", "https://www.cloudflarestatus.com")
        expect("status: a page without a feed", "\(p[2].statusURL != nil) \(p[2].statusFeed == nil)", "true true")
        expect("status: unknown provider has none", p[3].statusURL == nil, true)
    }

    // The GitHub budget: one reload after it resets, only when it is low and the reset is near.
    do {
        let now = Date(timeIntervalSince1970: 1_000_000)
        let low = try! JSONDecoder().decode(Store.Budget.self, from: Data(#"{"remaining":10,"limit":5000,"reset":1000600}"#.utf8))
        expect("budget reload: 30 s after the reset", Store.budgetReloadDelay(low, now: now) ?? -1, 630.0)
        let fine = try! JSONDecoder().decode(Store.Budget.self, from: Data(#"{"remaining":4000,"limit":5000,"reset":1000600}"#.utf8))
        expect("budget reload: not when there is budget", Store.budgetReloadDelay(fine, now: now) == nil, true)
        let past = try! JSONDecoder().decode(Store.Budget.self, from: Data(#"{"remaining":10,"limit":5000,"reset":999000}"#.utf8))
        expect("budget reload: not for a reset in the past", Store.budgetReloadDelay(past, now: now) == nil, true)
    }

    // Messages carry the project they are about.
    expect("message: project key kept", Store.Message(date: Date(), text: "x", ok: false, project: "vercel/app").project ?? "", "vercel/app")

    // Settings paths in texts come from the tab, so a renamed tab changes them too.
    expect("settings path: names the tab", SettingsTab.team.path.hasSuffix("→ " + SettingsTab.team.title), true)
    expect("settings path: every tab has one", SettingsTab.allCases.allSatisfy { $0.path.contains(" → ") && !$0.title.isEmpty }, true)
    expect("settings tab: every tab survives its stored value", SettingsTab.allCases.allSatisfy { SettingsTab.resolve($0.rawValue) == $0 }, true)
    // Every settings link written anywhere in the sources names a tab that exists (a typo would open General).
    do {
        let re = try! NSRegularExpression(pattern: #"deploycenter://settings(?:/|\?tab=)([A-Za-z]+)"#)
        var bad: [String] = [], found = 0
        let fm = FileManager.default
        for dir in ["app", "shared", "ios", "widgets", "lib", "integrations", "scripts"] {
            guard let e = fm.enumerator(atPath: dir) else { continue }
            for case let f as String in e where [".swift", ".sh", ".js", ".ts", ".py", ".md"].contains(where: { f.hasSuffix($0) }) {
                guard let text = try? String(contentsOfFile: dir + "/" + f, encoding: .utf8) else { continue }
                for m in re.matches(in: text, range: NSRange(text.startIndex..., in: text)) {
                    guard let r = Range(m.range(at: 1), in: text) else { continue }
                    found += 1
                    let name = text[r].lowercased()
                    if SettingsTab(rawValue: name) == nil { bad.append("\(dir)/\(f): \(name)") }
                }
            }
        }
        for f in ["deploys"] {
            guard let text = try? String(contentsOfFile: f, encoding: .utf8) else { continue }
            for m in re.matches(in: text, range: NSRange(text.startIndex..., in: text)) {
                guard let r = Range(m.range(at: 1), in: text) else { continue }
                found += 1
                if SettingsTab(rawValue: text[r].lowercased()) == nil { bad.append("\(f): \(text[r])") }
            }
        }
        expect("settings links: some are found", found > 0, true)
        expect("settings links: each names a tab", bad, [String]())
    }

    // The costs sheet's budget sentence and the days of a month (UTC, like the billing data).
    expect("costs: days in November", CostsSheet.daysInMonth("2026-11-10"), 30)
    expect("costs: days in a leap February", CostsSheet.daysInMonth("2028-02-03"), 29)
    expect("costs: unreadable day counts 30", CostsSheet.daysInMonth("soon"), 30)
    let monthDays = (1...10).map { Costs.Day(day: String(format: "2026-11-%02d", $0), total: 2, build: 2) }
    expect("budget line: none without a budget", CostsSheet.budgetLine(budget: 0, days: monthDays, today: "2026-11-10") == nil, true)
    expect("budget line: left until month end", CostsSheet.budgetLine(budget: 50, days: monthDays, today: "2026-11-10")?.over == false, true)
    expect("budget line: left names the rest", CostsSheet.budgetLine(budget: 50, days: monthDays, today: "2026-11-10")?.text.contains("30") ?? false, true)
    expect("budget line: over this month", CostsSheet.budgetLine(budget: 10, days: monthDays, today: "2026-11-10")?.over == true, true)
    let lateDays = (15...28).map { Costs.Day(day: "2026-11-\($0)", total: 4, build: 4) }
    expect("budget line: without the 1st the pace counts", CostsSheet.budgetLine(budget: 100, days: lateDays, today: "2026-11-28")?.over == true, true)
    expect("budget line: pace under the budget", CostsSheet.budgetLine(budget: 500, days: lateDays, today: "2026-11-28")?.over == false, true)
    expect("budget line: nothing without whole days", CostsSheet.budgetLine(budget: 100, days: [], today: "2026-11-28") == nil, true)

    // The deploy question lists the ones that are already up to date.
    expect("confirm: up-to-date ones named", DeployConfirm.unchangedNote([item(changed: false, last: "a", head: "a")]).isEmpty, false)
    expect("confirm: nothing when all wait", DeployConfirm.unchangedNote([item(changed: true)]), "")

    // Round 6, app logic: data folders, messages, selection, waiting, providers, cancel, snapshot, allowances.
    expect("data dirs: the test runner never uses the real folders", AppDirs.override != nil
           && !Journal.dir.path.contains("/Library/Application Support/") && !Store.cacheDir.path.contains("/Library/Caches/")
           && !Log.url.path.contains("/Library/Logs/"), true)
    do {
        let enc = JSONEncoder(); enc.dateEncodingStrategy = .iso8601
        let dec = JSONDecoder(); dec.dateDecodingStrategy = .iso8601
        let m = Store.Message(date: Date(timeIntervalSince1970: 1_000), text: "app failed", ok: false, project: "vercel/app")
        let back = try! dec.decode([Store.Message].self, from: try! enc.encode([m]))
        expect("messages: kept across a restart", "\(back[0].text) \(back[0].ok) \(back[0].project ?? "") \(back[0].date.timeIntervalSince1970)", "app failed false vercel/app 1000.0")
    }
    func pump(_ seconds: Double = 20, _ work: @escaping @MainActor () async -> Void) {
        nonisolated(unsafe) var done = false
        Task { @MainActor in await work(); done = true }
        let end = Date().addingTimeInterval(seconds)
        while !done && Date() < end { RunLoop.main.run(until: Date().addingTimeInterval(0.05)) }
    }
    MainActor.assumeIsolated {
        let st = Store()
        st.messages = (0..<(Timing.messageLimit + 5)).map { Store.Message(date: Date(), text: "m\($0)", ok: true) }
        expect("messages: at most the limit, the newest kept", "\(st.messages.count) \(st.messages.first?.text ?? "")", "\(Timing.messageLimit) m0")
        st.messages.insert(Store.Message(date: Date(), text: "newest", ok: true), at: 0)
        Store.flushMessages()
        let onDisk = Store.readMessages()
        expect("messages: a full list is still written", "\(onDisk.count) \(onDisk.first?.text ?? "")", "\(Timing.messageLimit) newest")

        // Ticking what changed: never a hidden row, a running one or one without changes.
        func row(_ id: String, changed: Bool, state: RunState = .idle) -> Item {
            var i = Item(id: id, name: id, detail: "", platform: .vercel, deployable: true, auto: false, note: nil, link: nil)
            i.changed = changed; i.state = state; return i
        }
        st.items[.vercel] = [row("c1", changed: true), row("c2", changed: true), row("run", changed: true, state: .running("d")), row("same", changed: false)]
        let hiddenBefore = st.hidden
        st.toggleHidden(st.items[.vercel]![1])
        st.selectChanged(.vercel)
        expect("select changed: only the visible, idle, changed row", st.selected(.vercel).map(\.id), ["c1"])
        st.clearSelection(.vercel)
        st.selectChanged(.vercel, only: ["vercel/same"])
        expect("select changed: limited to the given rows", st.selected(.vercel).map(\.id), [String]())
        st.toggleHidden(st.items[.vercel]![1])
        expect("select changed: hidden state restored", st.hidden, hiddenBefore)

        // One repo, two branches: different commits, both counted; same branch: counted once.
        func proj(_ id: String, ref: String?, commits: Int, prs: Int) -> Item {
            var i = Item(id: id, name: id, detail: "", platform: .vercel, deployable: true, auto: false, note: nil, link: nil)
            i.changed = true; i.repo = "me/app"; i.ref = ref; i.pendingCommits = commits; i.pendingPRs = prs; return i
        }
        st.items[.vercel] = [proj("staging", ref: "develop", commits: 3, prs: 1), proj("prod", ref: "main", commits: 5, prs: 2)]
        expect("waiting: two branches of one repo add up", "\(st.waiting.projects) \(st.waiting.commits) \(st.waiting.prs)", "2 8 3")
        st.items[.vercel] = [proj("web", ref: "main", commits: 3, prs: 1), proj("api", ref: nil, commits: 5, prs: 2)]
        expect("waiting: no branch is main, counted once", "\(st.waiting.projects) \(st.waiting.commits) \(st.waiting.prs)", "2 5 2")

        // The widget's snapshot: building, failed, waiting; hidden rows and quiet ones are not in it.
        let b = row("b-build", changed: false, state: .running("d"))
        var f = row("f-fail", changed: false); f.lastState = "build_failed"
        let w = row("w-wait", changed: true)
        let q = row("q-quiet", changed: false)
        let h = row("h-hidden", changed: true)
        st.items[.vercel] = [w, f, q, h, b]
        st.toggleHidden(h)
        let snap = st.makeSnapshot()
        expect("snapshot: order building, failed, waiting", snap.projects.map(\.name), ["b-build", "f-fail", "w-wait"])
        expect("snapshot: counts", "\(snap.building) \(snap.failed) \(snap.waitingProjects)", "1 1 1")
        UserDefaults.standard.set(true, forKey: "demoMode")
        let masked = st.makeSnapshot()
        UserDefaults.standard.removeObject(forKey: "demoMode")
        expect("snapshot: demo mode masks the names", masked.demo && !masked.projects.contains { $0.name == "w-wait" }, true)
        st.toggleHidden(h)
        let later = DeploySnapshot(at: snap.at.addingTimeInterval(60), demo: snap.demo, waitingProjects: snap.waitingProjects,
                                   waitingCommits: snap.waitingCommits, waitingPRs: snap.waitingPRs, building: snap.building,
                                   failed: snap.failed, byPlatform: snap.byPlatform, saving: snap.saving, projects: snap.projects, language: snap.language,
                                   nextScheduled: snap.nextScheduled, today: snap.today)
        expect("snapshot: only the time differs, same content", later.sameContent(as: snap), true)
        var other = later; other.language = snap.language == "de" ? "en" : "de"
        expect("snapshot: a new language is new content", other.sameContent(as: snap), false)
        st.items[.vercel] = []
    }

    // One rule for "failed": a deploy that failed here, or the platform's last build; a cancel is none.
    do {
        var i = item(); i.lastState = "build_failed"
        expect("failed: Render build_failed", i.failed && ClaudeAI.isFailed(i), true)
        i.lastState = "ERROR"; expect("failed: Vercel ERROR", i.failed, true)
        i.lastState = "canceled"; expect("failed: a cancel is not a failure", i.failed, false)
        i.state = .failed("x"); expect("failed: a deploy that failed here", i.failed, true)
    }

    // Auto-deploy allowances: seconds, milliseconds, ISO with and without fractions.
    do {
        func exp(_ v: String) -> Double? {
            (try? JSONDecoder().decode(AutoDeployAllowance.self, from: Data(#"{"platform":"Vercel","project":"app","expiresAt":\#(v)}"#.utf8)))?.expiresAt.timeIntervalSince1970
        }
        expect("allowance: seconds", exp("1800000000") ?? -1, 1800000000.0)
        expect("allowance: milliseconds", exp("1800000000000") ?? -1, 1800000000.0)
        expect("allowance: ISO", exp(#""2027-01-15T10:00:00Z""#) ?? -1, 1800007200.0)
        expect("allowance: ISO with fractions", exp(#""2027-01-15T10:00:00.250Z""#) ?? -1, 1800007200.25)
        expect("allowance: not a date is refused", exp(#""soon""#) == nil, true)
    }

    // A load that fails for its login asks the doctor again; other errors do not.
    expect("auth failure: Render key", Store.isAuthFailure("Render GET /services -> HTTP 401 (the Render key is wrong or expired: deploys render set-key)"), true)
    expect("auth failure: Vercel login", Store.isAuthFailure("The vercel CLI is not logged in. Run: vercel login"), true)
    expect("auth failure: a timeout is none", Store.isAuthFailure("No answer after 120 seconds – try again."), false)

    expect("Render type in words", Store.typeName("background_worker"), L("Worker", "Hintergrunddienst"))
    expect("unknown Render type without underscores", Store.typeName("new_kind"), "New Kind")
    expect("Claude's Markdown is rendered", String(ClaudeAI.rendered("a **bold** `x`").characters), "a bold x")
    expect("Claude's line breaks stay", String(ClaudeAI.rendered("- one\n- two").characters), "- one\n- two")
    expect("Claude config: keys in a stable order", String(decoding: try! ClaudeConfig.encode(["b": 1, "a": ["d": 1, "c": 2]]), as: UTF8.self),
           "{\n  \"a\" : {\n    \"c\" : 2,\n    \"d\" : 1\n  },\n  \"b\" : 1\n}\n")
    expect("diagnostics: the script's version", SettingsText.diagnostics(version: "1.0", os: "macOS", doctor: nil, providers: [], counts: [:],
                                                                         gitlabRepos: 0, autofix: nil, script: "0.9").hasPrefix("Deploy Center 1.0, deploys 0.9\n"), true)

    // Savings reports move out of the preferences into files, once.
    do {
        let d = UserDefaults(suiteName: "dc-tests-savings")!
        d.removePersistentDomain(forName: "dc-tests-savings")
        try? FileManager.default.removeItem(at: SavingsModel.ledgerURL)
        d.set(Data("{\"x\":1}".utf8), forKey: "savingsLedger")
        SavingsModel.moveOutOfDefaults(d)
        expect("savings: ledger moved to a file", "\(d.data(forKey: "savingsLedger") == nil) \(String(decoding: (try? Data(contentsOf: SavingsModel.ledgerURL)) ?? Data(), as: UTF8.self))", "true {\"x\":1}")
        d.removePersistentDomain(forName: "dc-tests-savings")
    }

    // The provider list and Tool.run's cancel, with a stand-in script.
    do {
        let dir = FileManager.default.temporaryDirectory.appendingPathComponent("dc-prov-\(UUID().uuidString)")
        try! FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        let script = dir.appendingPathComponent("deploys")
        try! """
        case "$1" in
          providers)
            n="$(cat "\(dir.path)/count" 2>/dev/null || echo 0)"; echo $((n + 1)) > "\(dir.path)/count"
            [ "$n" = 0 ] && echo '[{"id":"vercel","label":"Vercel","enabled":true},{"id":"render","label":"Render","enabled":false},{"id":"netlify","label":"Netlify","enabled":true}]' || exit 1 ;;
          hang) sleep 30 ;;
        esac
        """.write(to: script, atomically: true, encoding: .utf8)
        Tool.testPath = script.path
        let disabledBefore = UserDefaults.standard.object(forKey: "disabledProviders")
        nonisolated(unsafe) var firstIds = "", secondIds = ""
        pump {
            let st = Store()
            await st.loadProviders()
            firstIds = st.providers.map { "\($0.id):\($0.enabled)" }.joined(separator: ",")
            await st.loadProviders()
            secondIds = st.providers.map { "\($0.id):\($0.enabled)" }.joined(separator: ",") + " \(st.providersFromScript)"
        }
        expect("providers: the script's list", firstIds, "vercel:true,render:false,netlify:true")
        expect("providers: a failed second read keeps it", secondIds, "vercel:true,render:false,netlify:true true")
        if let disabledBefore { UserDefaults.standard.set(disabledBefore, forKey: "disabledProviders") } else { UserDefaults.standard.removeObject(forKey: "disabledProviders") }

        let t0 = Date(), box = DispatchSemaphore(value: 0)
        nonisolated(unsafe) var outcome = "none"
        let task = Task.detached {
            do { _ = try await Tool.run(["hang"], timeout: 60); outcome = "answered" }
            catch is CancellationError { outcome = "cancelled" }
            catch { outcome = "other: \(error)" }
            box.signal()
        }
        Thread.sleep(forTimeInterval: 0.5)
        task.cancel()
        let ended = box.wait(timeout: .now() + 10) == .success
        expect("run: a cancelled task ends with CancellationError", outcome, "cancelled")
        expect("run: and does not wait for the process", ended && Date().timeIntervalSince(t0) < 8, true)
        Tool.testPath = nil
        try? FileManager.default.removeItem(at: dir)
    }

    // doctor: a provider's flags under providers.<p> win over the flat copy; the flat one alone still counts.
    let docNested = try? JSONDecoder().decode(Doctor.self, from: Data(#"{"jq":true,"vercelCli":false,"renderKey":false,"providers":{"vercel":{"vercelCli":true,"vercelApi":true,"vercelLoggedIn":true},"render":{"renderKey":true}}}"#.utf8))
    expect("doctor: nested vercel flags win", docNested?.vercelCli ?? false, true)
    expect("doctor: nested render key wins", docNested?.renderKey ?? false, true)
    let docFlat = try? JSONDecoder().decode(Doctor.self, from: Data(#"{"jq":true,"vercelLoggedIn":true,"renderKey":true}"#.utf8))
    expect("doctor: flat (older script) still read", (docFlat?.vercelLoggedIn ?? false) && (docFlat?.renderKey ?? false), true)

    // LOG-108: the iPhone's GitHub token. A link made before the switch existed keeps getting it;
    // a new one does not; a choice once made stays.
    do {
        let suite = "dc-test-phone-gh"
        let d = UserDefaults(suiteName: suite)!; d.removePersistentDomain(forName: suite)
        PhoneLinkModel.migrateGitHub(d, linkExists: { true })
        expect("existing link: GitHub token stays on", d.bool(forKey: PhoneLinkModel.githubKey), true)
        d.removePersistentDomain(forName: suite)
        PhoneLinkModel.migrateGitHub(d, linkExists: { false })
        expect("new link: GitHub token off (and decided)", d.object(forKey: PhoneLinkModel.githubKey) != nil && !d.bool(forKey: PhoneLinkModel.githubKey), true)
        var asked = false
        PhoneLinkModel.migrateGitHub(d, linkExists: { asked = true; return true })
        expect("decided once: not asked again", asked, false)
        expect("decided once: stays off", d.bool(forKey: PhoneLinkModel.githubKey), false)
        d.removePersistentDomain(forName: suite)
        // At launch: the link switched on (a QR-only Mac, or no keychain group) counts as existing.
        d.set(true, forKey: "phoneLink")
        PhoneLinkModel.migrateGitHubAtLaunch(d)
        expect("launch: link on, no keychain entry: token stays on", d.bool(forKey: PhoneLinkModel.githubKey), true)
        d.removePersistentDomain(forName: suite)
    }

    // The QR code of the iPhone link: the keys go there and back unchanged; anything else is refused.
    // Made now: a code older than PhoneLink.qrMaxAge is refused as a photo of the screen.
    let linkKeys = LinkedKeys(vercel: "v-key", vercelTeam: "team", render: "r-key", github: "g-key",
                              updated: Date(timeIntervalSince1970: Date().timeIntervalSince1970.rounded()))
    let qr = PhoneLink.qrText(linkKeys) ?? ""
    expect("qr: has the prefix", qr.hasPrefix(PhoneLink.qrPrefix), true)
    expect("qr: round trip", PhoneLink.parse(qr: qr) == linkKeys, true)
    expect("qr: another prefix is refused", PhoneLink.parse(qr: "deploycenter-link:2:" + qr.dropFirst(PhoneLink.qrPrefix.count)) == nil, true)
    expect("qr: broken base64 is refused", PhoneLink.parse(qr: PhoneLink.qrPrefix + "%%%") == nil, true)
    expect("qr: other JSON is refused", PhoneLink.parse(qr: PhoneLink.qrPrefix + Data("{}".utf8).base64EncodedString()) == nil, true)
    expect("qr: no Vercel or Render key is refused", PhoneLink.parse(qr: PhoneLink.qrText(LinkedKeys(github: "g")) ?? "") == nil, true)

    // The widget file: what the Mac writes, the widgets and the iPhone read back.
    let snap = DeploySnapshot(at: Date(timeIntervalSince1970: 1_762_816_500), demo: false, waitingProjects: 1, waitingCommits: 3,
                              waitingPRs: 1, building: 0, failed: 1, saving: .init(before: 2, after: 0.5),
                              projects: [.init(name: "app", platform: "Vercel", status: .failed, commits: 3, prs: 1,
                                               since: Date(timeIntervalSince1970: 1_762_800_000), message: "Fix login")],
                              language: "de")
    let snapData = (try? DeploySnapshot.encoder.encode(snap)) ?? Data()
    expect("snapshot: round trip", (try? DeploySnapshot.decoder.decode(DeploySnapshot.self, from: snapData)) == snap, true)
    expect("snapshot: saving a month", snap.saving?.month ?? -1, 45.0)
    expect("snapshot: broken JSON is refused", (try? DeploySnapshot.decoder.decode(DeploySnapshot.self, from: Data("{\"at\":1}".utf8))) == nil, true)

    // Claude connection: finding node/claude and running them. Temp files only, no login shell
    // (a candidate always hits), never the real Claude config.
    let envDir = NSTemporaryDirectory() + "dc-env-\(UUID().uuidString)"
    try? FileManager.default.createDirectory(atPath: envDir, withIntermediateDirectories: true)
    let exe = envDir + "/node", plainFile = envDir + "/notes.txt"
    FileManager.default.createFile(atPath: exe, contents: Data("#!/bin/sh\n".utf8), attributes: [.posixPermissions: 0o755])
    FileManager.default.createFile(atPath: plainFile, contents: Data("x".utf8), attributes: [.posixPermissions: 0o644])
    expect("isExec: an executable file", ClaudeEnv.isExec(exe), true)
    expect("isExec: a file without x", ClaudeEnv.isExec(plainFile), false)
    expect("isExec: a folder is not a program", ClaudeEnv.isExec(envDir), false)
    expect("isExec: missing", ClaudeEnv.isExec(envDir + "/gone"), false)
    expect("find: the first candidate that runs", waitFor { await ClaudeEnv.find("node", overrideKey: "dcTestNoSuchKey", candidates: [envDir + "/gone", plainFile, exe]) } ?? "-", exe)
    let both = waitFor { await ClaudeRun.run("/bin/sh", ["-c", "echo out; echo err >&2"]) }
    expect("ClaudeRun: ok, stdout and stderr together", "\(both.ok) \(both.out.contains("out")) \(both.out.contains("err"))", "true true true")
    expect("ClaudeRun: an exit code is not ok", waitFor { await ClaudeRun.run("/bin/sh", ["-c", "exit 3"]) }.ok, false)
    expect("ClaudeRun: a missing program is not ok", waitFor { await ClaudeRun.run(envDir + "/gone", []) }.ok, false)
    let slowStart = Date()
    let slow = waitFor { await ClaudeRun.run("/bin/sleep", ["20"], timeout: 0.5) }
    expect("ClaudeRun: a hang is ended at the timeout", "\(slow.ok) \(Date().timeIntervalSince(slowStart) < 10)", "false true")
    try? FileManager.default.removeItem(atPath: envDir)

}
