// App tests: logos-reload-rollback. Called from tests/app/main.swift.

import AppKit

@MainActor func suite_logos_reload_rollback() {
    // Logos: a white mark on a clear ground gets a dark one; a coloured square does not.
    func image(_ fill: NSColor, clear: Bool) -> NSImage {
        let img = NSImage(size: NSSize(width: 32, height: 32))
        img.lockFocus()
        if !clear { NSColor.systemBlue.setFill(); NSRect(x: 0, y: 0, width: 32, height: 32).fill() }
        fill.setFill(); NSRect(x: 8, y: 8, width: 16, height: 16).fill()
        img.unlockFocus()
        return img
    }
    expect("white on clear", image(.white, clear: true).isLightOnClear, true)
    expect("white on blue", image(.white, clear: false).isLightOnClear, false)
    expect("black on clear", image(.black, clear: true).isLightOnClear, false)

    // A reload while a deploy is followed keeps what cancelling, the timer and promoting need.
    MainActor.assumeIsolated {
        let store = Store()
        var running = item(); running.state = .running("building"); running.deployId = "dpl_1"; running.startedAt = Date(timeIntervalSince1970: 5); running.selected = false
        store.items[.vercel] = [running]
        store.merge(.vercel, [item()])
        let after = store.items[.vercel]![0]
        expect("reload keeps the deploy id", after.deployId ?? "nil", "dpl_1")
        expect("reload keeps the start time", after.startedAt?.timeIntervalSince1970 ?? 0, 5.0)
        expect("reload keeps the state", after.state.isActive, true)
        var idle = item(); idle.deployId = "old"
        store.items[.vercel] = [idle]
        store.merge(.vercel, [item()])
        expect("an idle row takes the fresh data", store.items[.vercel]![0].deployId ?? "nil", "nil")
    }

    // Rollback leaves the project behind the branch; a shared repo counts its PRs once.
    @MainActor func moreTests() {
        let store = Store()
        var a = item(changed: true, commits: 1, prs: 1); a.state = .idle
        var b = item(.render, changed: true, commits: 1, prs: 1)
        b = Item(id: "srv-2", name: "api", detail: "", platform: .render, deployable: true, auto: false, note: nil, link: nil)
        b.changed = true; b.pendingCommits = 1; b.pendingPRs = 1; b.repo = "me/app"
        store.items[.vercel] = [a]; store.items[.render] = [b]
        expect("two projects of one repo count the PR once", store.waiting.prs, 1)
        expect("but both projects are listed", store.waiting.projects, 2)
        // Staging on another branch of the same repo waits for its own commits.
        var c = Item(id: "staging", name: "staging", detail: "", platform: .vercel, deployable: true, auto: false, note: nil, link: nil)
        c.changed = true; c.pendingCommits = 4; c.pendingPRs = 2; c.repo = "me/app"; c.ref = "develop"
        store.items[.vercel] = [a, c]
        expect("another branch of one repo counts on its own", store.waiting.prs, 3)
        // Not deployable: no stale alarm, no count.
        var nd = Item(id: "nd", name: "nd", detail: "", platform: .vercel, deployable: false, auto: false, note: nil, link: nil)
        nd.changed = true; nd.repo = "me/other"
        store.items[.vercel] = [a, nd]
        expect("a project that cannot deploy does not wait", store.waiting.projects, 2)
    }
    MainActor.assumeIsolated { moreTests() }

    // Reading a log.
    expect("first error line", LogTools.firstErrorLine(["ok", "0 errors", "npm ERR! missing", "x"]) ?? -1, 2)
    expect("no error in a clean log", LogTools.firstErrorLine(["ok", "done"]) == nil, true)
    expect("prompt names the project", LogTools.claudePrompt(name: "web", repo: "me/web", ref: "main", sha: nil, message: nil, log: "a\nError: x").contains("\"web\""), true)

    let c1 = Details.Commit(sha: "a", full: nil, url: nil, msg: "Fix login", author: "ann", bot: false, at: 0, pr: 12)
    let c2 = Details.Commit(sha: "b", full: nil, url: nil, msg: "Bump x", author: "dependabot", bot: true, at: 0, pr: nil)
    expect("release notes list humans first", LogTools.releaseNotes(name: "web", commits: [c2, c1]),
           "## web\n- Fix login (#12) – ann\n\nDependency updates:\n- Bump x – dependabot")

    // Hide with a way back.
    MainActor.assumeIsolated {
        let st = Store(); let it = item()
        st.hideWithUndo(it)
        expect("hidden after hide", st.isHidden(it), true)
        st.toast?.undo?()
        expect("shown again after undo", st.isHidden(it), false)
        UserDefaults.standard.removeObject(forKey: "hidden")
    }

    // The journal: CSV quoting and the failure count.
    let je = [JournalEntry(platform: "Vercel", name: "a\"b", result: "failed", seconds: 61, detail: "x"),
              JournalEntry(platform: "Vercel", name: "a\"b", result: "live", seconds: 30, detail: nil)]
    expect("csv quotes names", Journal.csv(je).contains("\"a\"\"b\""), true)
    expect("csv: a price per build in the last column", Journal.csv(je, perBuild: { _ in 0.126 }).split(separator: "\n").map { $0.split(separator: ",", omittingEmptySubsequences: false).last.map(String.init) ?? "" },
           ["usd_estimate", "0.13", "0.13"])
    expect("csv: no price, empty", Journal.csv(je).hasSuffix(","), true)
    expect("failures of the last deploys", "\(Journal.failures(of: "a\"b", in: je))", "(failed: 1, total: 2)")

    // The journal: formulas, platforms, stable ids.
    let fx = [JournalEntry(platform: "Vercel", name: "=HYPERLINK(1)", result: "failed", seconds: nil, detail: "@x")]
    expect("csv defuses formulas", Journal.csv(fx).contains("\"'=HYPERLINK(1)\",failed,,\"'@x\""), true)
    // IDEEN-11 203/204/224: names are masked, tokens in a detail or a note never reach an export.
    var tok = JournalEntry(platform: "Vercel", name: "shop", result: "failed", seconds: nil, detail: "deploy failed with token ghp_abcdefgh12345678")
    tok.note = "key sk-abcdefghijklmnopqrstu"
    let tokCSV = Journal.csv([tok], mask: { $0 == "shop" ? "Atlas-1" : $0 }, scrub: { $0.replacingOccurrences(of: "deploy", with: "ship") })
    expect("csv masks name", tokCSV.contains("Atlas-1") && !tokCSV.contains(",\"shop\""), true)
    expect("csv masks tokens", tokCSV.contains("ghp_abcdefgh") || tokCSV.contains("sk-abcdef"), false)
    expect("csv scrubs names in details", tokCSV.contains("ship failed"), true)
    expect("markdown masks tokens", JournalStats.markdown([tok]).contains("ghp_abcdefgh"), false)
    expect("postmortem masks tokens", JournalStats.postmortem(tok).contains("ghp_abcdefgh") || JournalStats.postmortem(tok).contains("sk-abcdef"), false)
    let mix = [JournalEntry(platform: "Vercel", name: "shop", result: "failed", seconds: nil, detail: nil),
               JournalEntry(platform: "Render", name: "shop", result: "live", seconds: nil, detail: nil)]
    expect("failures per platform", "\(Journal.failures(of: "shop", platform: "Render", in: mix))", "(failed: 0, total: 1)")
    expect("failure table per platform", "\(Journal.failureTable(mix)["Vercel/shop"].map { "\($0.failed)/\($0.total)" } ?? "nil")", "1/1")
    let fixed = Date(timeIntervalSince1970: 1000)
    expect("journal id is stable", JournalEntry(at: fixed, platform: "Vercel", name: "a", result: "live", seconds: nil, detail: nil).id
           == JournalEntry(at: fixed, platform: "Vercel", name: "a", result: "live", seconds: nil, detail: nil).id, true)

    // Health paths.
    expect("health path gets a slash", Store.cleanPath("health") ?? "nil", "/health")
    expect("health path with a space", Store.cleanPath("/my health") ?? "nil", "/my%20health")
    expect("health path already encoded", Store.cleanPath("/my%20health") ?? "nil", "/my%20health")
    expect("empty health path", Store.cleanPath("  ") ?? "nil", "nil")
    do {
        func row(_ id: String, auto: Bool) -> Item { Item(id: id, name: id, detail: "", platform: .vercel, deployable: true, auto: auto, note: nil, link: nil) }
        expect("auto-deploy on again: off before, on now", Store.autoOnAgain(old: [row("app", auto: false)], fresh: [row("app", auto: true)]).map(\.id), ["app"])
        expect("auto-deploy: a row new to the list says nothing", Store.autoOnAgain(old: [row("app", auto: false)], fresh: [row("new", auto: true)]).map(\.id), [String]())
        expect("auto-deploy: still on says nothing", Store.autoOnAgain(old: [row("app", auto: true)], fresh: [row("app", auto: true)]).map(\.id), [String]())
    }
    expect("several health paths", Store.cleanPaths(" /health, api/ping ,,/health"), ["/health", "/api/ping"])
    expect("check links: front page without paths", Store.checkLinks("https://a.app/", []), ["https://a.app/"])
    expect("check links: each path", Store.checkLinks("https://a.app/", ["/health", "/api"]), ["https://a.app/health", "https://a.app/api"])
    expect("page text: case and spaces aside", Store.pageHas("<h1>Welcome  to\nShop</h1>", "welcome to shop"), true)
    expect("page text: missing", Store.pageHas("<h1>Error</h1>", "Welcome"), false)
    expect("page text: none asked", Store.pageHas("", "  "), true)

    // A reload keeps how a deploy ended only while the branch has not moved.
    var was = item(head: "h1"); was.state = .done(nil)
    var now = item(head: "h1")
    expect("end state kept, same head", Store.keepsState(old: was, fresh: now), true)
    now.headSha = "h2"
    expect("end state dropped on a new commit", Store.keepsState(old: was, fresh: now), false)
    was.state = .running("building")
    expect("running kept on a new commit", Store.keepsState(old: was, fresh: now), true)
    was.state = .idle
    expect("idle has nothing to keep", Store.keepsState(old: was, fresh: now), false)

    // The day key is the Mac's day, not UTC's.
    let lateUTC = Date(timeIntervalSince1970: 1_762_816_500)   // 2025-11-10 23:15 UTC
    expect("day in UTC", localDay(lateUTC, timeZone: TimeZone(identifier: "UTC")!), "2025-11-10")
    expect("day in Berlin", localDay(lateUTC, timeZone: TimeZone(identifier: "Europe/Berlin")!), "2025-11-11")

    // A timeout ends the whole tree, not only bash.
    let tree = Process(); tree.executableURL = URL(fileURLWithPath: "/bin/bash")
    tree.arguments = ["-c", "sleep 30 & sleep 30; wait"]
    let treeOut = Pipe(); tree.standardOutput = treeOut
    try? tree.run(); usleep(300_000)
    let t0 = Date()
    Tool.killTree(tree.processIdentifier)
    _ = treeOut.fileHandleForReading.readDataToEndOfFile()   // returns only once every child is gone
    // Two sleeps of 30 s: "at once" is anything well below that, also on a busy CI runner.
    expect("killTree closes the pipe at once", Date().timeIntervalSince(t0) < 10, true)
}
