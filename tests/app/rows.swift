// App tests: rows. Called from tests/app/main.swift.

import AppKit

@MainActor func suite_rows() {
    // What has changes: the script's word first, commits as a fallback.
    expect("script says changed", item(changed: true, last: "a", head: "a").hasNewCommits, true)
    expect("script says not changed", item(changed: false).hasNewCommits, false)
    expect("no word: different commits", item().hasNewCommits, true)
    expect("no word: same commit", item(head: "a").hasNewCommits, false)

    // What the row says.
    do {
        let q = SearchQuery("is:waiting host:render repo:shop api")
        expect("search: waiting", q.waiting ? "y" : "n", "y")
        expect("search: host", q.platform ?? "", "render")
        expect("search: repo", q.repo ?? "", "shop")
        expect("search: text", q.text, "api")
    }
    expect("selection cost none", Store.selectionCost(perBuild: [nil, nil]), "")
    expect("selection cost partial", Store.selectionCost(perBuild: [0.5, nil]).hasSuffix("+") ? "y" : "n", "y")
    expect("selection cost all", Store.selectionCost(perBuild: [0.5, 0.25]).hasSuffix("+") ? "y" : "n", "n")
    expect("head note empty without changes", DeployConfirm.headNote([item(changed: false)]), "")
    do {
        var raw = SavedSearches.adding("is:failed", to: "")
        raw = SavedSearches.adding("host:render", to: raw)
        raw = SavedSearches.adding("is:failed", to: raw)
        expect("saved searches: newest first, no duplicate", SavedSearches.parse(raw).joined(separator: "|"), "is:failed|host:render")
        expect("saved searches: remove", SavedSearches.parse(SavedSearches.removing("is:failed", from: raw)).joined(separator: "|"), "host:render")
        var many = ""
        for n in 0..<20 { many = SavedSearches.adding("q\(n)", to: many) }
        expect("saved searches: limit", String(SavedSearches.parse(many).count), String(SavedSearches.limit))
    }
    expect("waiting list empty", DeployConfirm.waitingList([item(changed: false)]), "")
    expect("waiting list line", DeployConfirm.waitingList([item(changed: true, commits: 2, prs: 0)]).hasPrefix("- ") ? "y" : "n", "y")
    do {
        var a = item(changed: true, commits: 1, prs: 0)
        a.lastAt = Date().addingTimeInterval(-60)
        expect("freshness: just deployed", DeployConfirm.freshnessNote([a]).contains("5") ? "y" : "n", "y")
        var b = item(changed: true, commits: 1, prs: 0)
        b.headAt = Date().addingTimeInterval(-40 * 86400)
        expect("freshness: old commit", DeployConfirm.freshnessNote([b]).contains("30") ? "y" : "n", "y")
        expect("freshness: nothing", DeployConfirm.freshnessNote([item(changed: false)]), "")
    }
    expect("toggle failed on", SearchQuery.toggledFailed("api"), "api is:failed")
    expect("toggle failed off", SearchQuery.toggledFailed("api is:failed"), "api")
    expect("commits and PRs", Row.waitingText(item(changed: true, commits: 5, prs: 3)), L("5 commits · 3 PRs waiting", "5 Commits · 3 PRs warten"))
    expect("one of each", Row.waitingText(item(changed: true, commits: 1, prs: 1)), L("1 commit · 1 PR waiting", "1 Commit · 1 PR wartet"))
    expect("commits only", Row.waitingText(item(changed: true, commits: 2, prs: 0)), L("2 commits waiting", "2 Commits warten"))
    expect("past 250 commits it is a floor", Row.waitingText(item(changed: true, commits: 300, prs: 40, partial: true)),
           L("300 commits, at least 40 PRs waiting", "300 Commits, mindestens 40 PRs warten"))
    expect("rewritten branch", Row.waitingText(item(changed: true, rewritten: true)),
           L("New changes (branch was rewritten)", "Neue Änderungen (Branch wurde umgeschrieben)"))

    // Deploy states in words, not raw API values.
    expect("state build_failed", Row.stateText("build_failed"), L("build failed", "Build fehlgeschlagen"))
    expect("state ERROR", Row.stateText("ERROR"), L("failed", "fehlgeschlagen"))
    expect("state trigger failed", Row.stateText("trigger failed (HTTP 500)"), L("trigger failed", "Auslösen fehlgeschlagen") + " (HTTP 500)")
    expect("name check: case and spaces aside", "\(NameCheck.matches(" Shop-API ", "shop-api")) \(NameCheck.matches("", "")) \(NameCheck.matches("shop", "shop-api"))", "true false false")
    do {
        let d = try! JSONDecoder().decode(Doctor.self, from: Data(#"{"jq":true,"githubCli":true,"githubLoggedIn":false,"renderKey":false,"perl":true,"curl":true}"#.utf8))
        let c = Health.checks(d, budget: Store.Budget(remaining: 50, limit: 5000, reset: 600), on: ["render"], now: Date(timeIntervalSince1970: 0))
        expect("health: what is wrong", c.filter { !$0.ok }.map(\.id), ["ghlogin", "ghbudget", "renderkey"])
        expect("health: vercel only when on", c.contains { $0.group == "Vercel" }, false)
        expect("health: no doctor", Health.checks(nil, budget: nil, on: []).map(\.id), ["script"])
    }
    expect("first start: once, with something to turn off", "\(FirstStart.due(done: false, autoOn: 2)) \(FirstStart.due(done: true, autoOn: 2)) \(FirstStart.due(done: false, autoOn: 0))", "true false false")
    do {
        let t0 = Date(timeIntervalSince1970: 1_700_000_000)
        func je(_ m: Double, _ n: String, _ r: String, _ s: Double? = nil) -> JournalEntry { JournalEntry(at: t0.addingTimeInterval(m * 60), platform: "vercel", name: n, result: r, seconds: s, detail: nil) }
        let l = [je(0, "a", "live"), je(10, "a", "failed"), je(40, "a", "live"), je(50, "b", "preview"), je(60, "b", "rollback"), je(70, "b", "forced")]
        expect("stats: clean share", JournalStats.cleanShare(l).map { Int(($0 * 100).rounded()) } ?? -1, 60)
        let d = JournalStats.dora(l, days: 7)
        expect("stats: dora", "\(d.perWeek) \(Int((d.failRate ?? 0) * 100)) \(Int(d.restoreMedian ?? 0))", "3.0 40 1200")
        let fr = [je(0, "z", "live"), je(10, "z", "failed"), je(20, "z", "rollback"), je(30, "z", "live")]
        let df = JournalStats.dora(fr, days: 7)
        expect("stats: failed then rollback is one failure, recovered by the rollback", "\(Int((df.failRate ?? 0) * 100)) \(Int(df.restoreMedian ?? 0))", "25 600")
        expect("journal: duration", "\(Journal.duration(125)) \(Journal.duration(7500))", "2:05 2 h 05")
        expect("journal: search by sha", Journal.filter([JournalEntry(platform: "Vercel", name: "x", result: "live", seconds: nil, detail: nil, sha: "a1b2c3d4", deployId: "dpl_9")], text: "a1b2c3", kind: nil).count, 1)
        expect("stats: costly failures", JournalStats.costlyFailures(l, perBuild: { $0 == "a" ? 0.5 : nil }).map { "\($0.name) \($0.failed) \($0.usd)" }, ["a 1 0.5"])
        let tr = (0..<10).map { je(Double($0), "c", "live", $0 < 5 ? 60 : 120) }
        expect("stats: slower builds", JournalStats.trends(tr).map { "\($0.before) \($0.recent)" }, ["60.0 120.0"])
        expect("stats: markdown escapes a bar", JournalStats.markdown([JournalEntry(at: t0, platform: "vercel", name: "x|y", result: "live", seconds: nil, detail: nil)]).contains("x\\|y"), true)
        let pr = JournalStats.periods(l, days: 1, now: t0.addingTimeInterval(86400))
        expect("stats: periods", "\(pr.recent.count) \(pr.before.count)", "6 0")
    }
    do {
        var n = JournalEntry(platform: "vercel", name: "a", result: "live", seconds: nil, detail: nil); n.note = "release mail"
        let enc = JSONEncoder(); enc.dateEncodingStrategy = .iso8601
        let dec = JSONDecoder(); dec.dateDecodingStrategy = .iso8601
        expect("journal note round trip", (try? dec.decode(JournalEntry.self, from: enc.encode(n)))?.note ?? "", "release mail")
        expect("journal without note decodes", (try? dec.decode(JournalEntry.self, from: Data(#"{"at":"2026-01-01T00:00:00Z","platform":"vercel","name":"a","result":"live"}"#.utf8)))?.name ?? "", "a")
        let file = #"{"at":"2026-01-01T00:00:00.5Z","platform":"Vercel","name":"x","result":"live","extra":1}"# + "\n"
            + #"{"at":"2026-01-01T00:00:00Z","platform":"Vercel","name":"a","result":"live","seconds":null,"detail":"d","by":"script"}"# + "\n"
        let aId = (try? dec.decode(JournalEntry.self, from: Data(file.split(separator: "\n")[1].utf8)))?.id ?? ""
        let noted = Journal.withNote(file, id: aId, note: "hi") ?? ""
        expect("note: other lines stay byte for byte", noted.hasPrefix(String(file.split(separator: "\n")[0]) + "\n"), true)
        expect("note: unknown keys stay", noted.contains(#""by":"script""#) && noted.contains(#""note":"hi""#), true)
        expect("search finds a note", Journal.filter([n], text: "mail", kind: nil).count, 1)
        expect("summary line", JournalStats.summaryLine([n]) ?? "", L("1 deploys, 0 failed", "1 Deploys, 0 fehlgeschlagen"))
    }
    expect("spoken summary", Speech.summary(waiting: 3, failed: 0, running: 1), L("3 projects wait, 1 running.", "3 Projekte warten, 1 laufen."))
    expect("spoken summary, nothing", Speech.summary(waiting: 0, failed: 0, running: 0), L("Nothing waits, nothing failed.", "Nichts wartet, nichts ist fehlgeschlagen."))
    expect("state unknown word", Row.stateText("some_new_state"), "some new state")

    // Demo mode: names in free text become their stand-ins, in one pass.
    UserDefaults.standard.set(true, forKey: "demoMode")
    var shop = item(); shop = Item(id: "shop-api", name: "shop-api", detail: "", platform: .vercel, deployable: true, auto: false, note: nil, link: nil)
    shop.repo = "acme/shop"
    expect("demo scrub", Demo.scrub("shop-api failed (acme/shop)", items: [shop]), "\(Demo.mask("shop-api")) failed (\(Demo.mask("acme/shop")))")
    UserDefaults.standard.removeObject(forKey: "demoMode")
    expect("no demo, no change", Demo.scrub("shop-api failed", items: [shop]), "shop-api failed")

    // Links.
    expect("compare link", item(changed: true).compareURL?.absoluteString ?? "nil", "https://github.com/me/app/compare/a...main")
    expect("no compare link without changes", item(changed: false).compareURL?.absoluteString ?? "nil", "nil")
    expect("Render dashboard, web", item(.render).dashboardURL?.absoluteString ?? "nil", "https://dashboard.render.com/web/srv-1")
    expect("Render dashboard, cron", item(.render, kind: "cron_job").dashboardURL?.absoluteString ?? "nil", "https://dashboard.render.com/cron/srv-1")
    expect("Vercel has none", item().dashboardURL?.absoluteString ?? "nil", "nil")

    // A price per build only when every build was counted.
    let costs = try! JSONDecoder().decode(Costs.self, from: Data("""
    {"days":[],"projects":[{"name":"app","build":10,"builds":4}],"offDay":null,"buildsComplete":true}
    """.utf8))
    expect("per build", costs.perBuild("app") ?? -1, 2.5)
    let partial = try! JSONDecoder().decode(Costs.self, from: Data("""
    {"days":[],"projects":[{"name":"app","build":10,"builds":4}],"offDay":null,"buildsComplete":false}
    """.utf8))
    expect("no price from a short count", partial.perBuild("app") == nil, true)

}
