// App tests: mac-logic. Called from tests/app/main.swift.

import AppKit

@MainActor func suite_mac_logic() {
    // MARK: - Mac logic (improve/mac-logic): failures, autofix fires, site check, savings, waiting rows, journal

    // LOG-036/041: a failure is what autofix calls one.
    var vNewestFailed = item(); vNewestFailed.lastState = "READY"; vNewestFailed.latestState = "ERROR"
    expect("vercel: newest attempt ERROR, production READY is failed", vNewestFailed.lastFailed, true)
    var vOld = item(); vOld.lastState = "ERROR"
    expect("vercel: no newest attempt known, last state decides", vOld.lastFailed, true)
    var rRuntime = item(.render); rRuntime.lastState = "update_failed"
    expect("render: update_failed is not a build failure", rRuntime.lastFailed, false)
    var rBuild = item(.render); rBuild.lastState = "build_failed"
    expect("render: build_failed is", rBuild.lastFailed, true)
    let latestJSON = #"[{"name":"web","auto":false,"deployable":true,"lastState":"READY","latestState":"ERROR","latestId":"dpl_2","latestSha":"cccc"}]"#
    expect("vercel list decodes the newest attempt", (try? decodeLossy(VercelProject.self, from: Data(latestJSON.utf8), label: "t"))?.first?.latestState ?? "", "ERROR")

    // LOG-037/038/117: which fire speaks for the row.
    var newFail = failedItem(); newFail.latestSha = "ddddddd4"
    expect("old done fire + new failure: nothing, so it can be handed over",
           RowAutofix.of(newFail, { var f = F(at: 1, project: "app", platform: "vercel", status: "fired", sha: "aaaaaaa1"); f.done = true; return f }(), now: late) == nil, true)
    expect("fire of another failed build: nothing",
           RowAutofix.of(newFail, F(at: 1, project: "app", platform: "vercel", status: "fired", session: "https://claude.ai/code/s1", sha: "aaaaaaa1"), now: late) == nil, true)
    expect("fire of this failed build: fixing",
           RowAutofix.of(newFail, F(at: 1, project: "app", platform: "vercel", status: "fired", sha: "ddddddd4ffff"), now: soon) == .fixing(session: nil), true)
    expect("fire sha decodes", fire(#"{"fires":[{"at":1,"project":"a","status":"fired","sha":"abc"}]}"#).fires[0].sha ?? "", "abc")
    var doneOpen = F(at: 1, project: "app", platform: "vercel", status: "fired", prNumber: 4, prState: "open"); doneOpen.done = true
    expect("done fire, PR open, fresh: still shown", RowAutofix.of(green, doneOpen, now: soon) == .prOpen(number: 4, url: nil), true)
    expect("done fire, PR open, a day later: gone", RowAutofix.of(green, doneOpen, now: Date(timeIntervalSince1970: 1 + RowAutofix.doneOpenFor + 1)) == nil, true)

    // LOG-001/021: the check after going live.
    expect("site: 200 fine", Store.siteVerdict(code: 200, networkUp: true), Store.SiteVerdict.fine)
    expect("site: 200 then 403 is a lost access", Store.accessLost(before: 200, now: 403), true)
    expect("site: 403 then 403 is no change", Store.accessLost(before: 403, now: 403), false)
    expect("site: first answer 403 is no change", Store.accessLost(before: nil, now: 401), false)
    expect("site: 200 then 500 is not an access change", Store.accessLost(before: 200, now: 500), false)
    expect("site: 429 is bot protection, fine", Store.siteVerdict(code: 429, networkUp: true), Store.SiteVerdict.fine)
    expect("site: 503 broken", Store.siteVerdict(code: 503, networkUp: true), Store.SiteVerdict.broken)
    expect("site: 404 odd, no rollback", Store.siteVerdict(code: 404, networkUp: true), Store.SiteVerdict.odd)
    expect("site: no answer, network up: broken", Store.siteVerdict(code: nil, networkUp: true), Store.SiteVerdict.broken)
    expect("site: no answer, Mac offline: never a rollback", Store.siteVerdict(code: nil, networkUp: false), Store.SiteVerdict.unreachable)

    // LOG-022: a health path with a query.
    expect("health path keeps its query", Store.cleanPath("/health?check=1") ?? "nil", "/health?check=1")
    expect("health path with space and query", Store.cleanPath("my health?a=b c") ?? "nil", "/my%20health?a=b%20c")

    // LOG-003: the saving after the costs window no longer reaches before offDay.
    var lateCosts = try! JSONDecoder().decode(Costs.self, from: Data("""
    {"days":[{"day":"2026-11-20","total":2,"build":2},{"day":"2026-11-21","total":2,"build":2}],"projects":[],"offDay":"2026-11-03"}
    """.utf8))
    expect("no 'before' in the window and none kept: unknown", lateCosts.saved(today: "2026-11-22") == nil, true)
    lateCosts.baseline = Costs.Baseline(offDay: "2026-11-03", perDay: 10, days: 2)
    expect("kept 'before': saved over all whole days since off", lateCosts.saved(today: "2026-11-22") ?? -1, 144.0)
    lateCosts.baseline = Costs.Baseline(offDay: "2026-10-01", perDay: 10, days: 2)
    expect("kept 'before' of another off day is not used", lateCosts.saved(today: "2026-11-22") == nil, true)
    expect("measured baseline", offCosts.measuredBaseline.map { "\($0.perDay) \($0.days)" } ?? "", "10.0 2")
    expect("days between", Costs.daysBetween("2026-02-27", "2026-03-02") ?? -1, 3)

    // LOG-051/055: no "≈ 0 minutes saved".
    let unknownLedger = try! JSONDecoder().decode(LedgerReport.self, from: Data(#"{"since":"2026-01-20","days":3,"projects":[{"name":"web","skipped":3,"savedMinutes":null}],"total":{"skipped":3,"pushes":3,"builds":0,"usd":null,"vercelMinutes":0,"renderMinutes":0}}"#.utf8))
    expect("ledger: skipped, duration unknown", unknownLedger.headline, L("3 builds skipped, duration not known yet", "3 Builds übersprungen, Dauer noch unbekannt"))
    expect("ledger: minutes incomplete", unknownLedger.minutesComplete, false)
    let nothingLedger = try! JSONDecoder().decode(LedgerReport.self, from: Data(#"{"since":"2026-01-20","days":3,"projects":[],"total":{"skipped":0,"usd":0}}"#.utf8))
    expect("ledger: nothing skipped is said, not $0.00", nothingLedger.headline, L("Nothing skipped yet – every push was built", "Noch nichts übersprungen – jeder Push wurde gebaut"))
    let noBuiltPrice = try! JSONDecoder().decode(LedgerReport.self, from: Data(#"{"since":"2026-01-20","days":3,"projects":[],"total":{"skipped":2,"usd":4}}"#.utf8))
    expect("share card: no price of the built ones is not $0", noBuiltPrice.perDay == nil, true)

    // LOG-004/UI-002: one rule for what waits.
    MainActor.assumeIsolated {
        let st = Store()
        var a = item(changed: true, commits: 1); a.repo = "me/a"
        var b = Item(id: "b", name: "b", detail: "", platform: .vercel, deployable: true, auto: false, note: nil, link: nil); b.changed = true; b.repo = "me/b"
        var c = Item(id: "c", name: "c", detail: "", platform: .vercel, deployable: true, auto: false, note: nil, link: nil); c.changed = true; c.state = .running("x")
        var r = item(.render, changed: true); r.repo = "me/r"
        st.items[.vercel] = [a, b, c]; st.items[.render] = [r]
        st.hidden = ["vercel/b"]
        expect("changed count leaves out hidden and running rows", st.changedCount(.vercel), 1)
        expect("tab counts add up to the summary", Platform.allCases.map { st.changedCount($0) }.reduce(0, +), st.waiting.projects)
        expect("waiting for one tab", st.waiting(for: [.render]).projects, 1)
        st.selectChanged(.vercel)
        expect("select changed skips hidden rows", st.selected(.vercel).map(\.id), ["app"])
        st.clearSelection(.vercel)
        st.selectChanged(.vercel, only: ["vercel/zzz"])
        expect("select changed only among the rows shown", st.selected(.vercel).count, 0)
        // The deploy question names the person's own note on a project; a project without marks adds nothing.
        st.notes["vercel/app"] = "after the release mail"
        expect("confirm marks name the note", st.confirmMarks([a]).contains("after the release mail"), true)
        expect("confirm marks: nothing marked, nothing said", st.confirmMarks([b]), "")
        st.notes = [:]
        st.hidden = []
    }

    // The journal: kinds, search and days.
    let jk = [JournalEntry(at: Date(timeIntervalSince1970: 1_800_000_000), platform: "Vercel", name: "shop", result: "preview", seconds: nil, detail: nil),
              JournalEntry(at: Date(timeIntervalSince1970: 1_800_000_100), platform: "Render", name: "api", result: "failed", seconds: nil, detail: "build exploded"),
              JournalEntry(at: Date(timeIntervalSince1970: 1_800_200_000), platform: "Render", name: "api", result: "brand-new", seconds: nil, detail: nil)]
    expect("journal: preview is its own kind", jk[0].kind, JournalEntry.Kind.preview)
    expect("journal: an unknown word is other", jk[2].kind, JournalEntry.Kind.other)
    expect("journal: search finds the reason", Journal.filter(jk, text: "exploded", kind: nil).map(\.name), ["api"])
    expect("journal: filter by kind", Journal.filter(jk, text: "", kind: .failed).count, 1)
    expect("journal: newest day first", Journal.byDay(jk).first?.entries.first?.result ?? "", "brand-new")
    expect("journal: since drops the older ones", Journal.filter(jk, text: "", kind: nil, since: Date(timeIntervalSince1970: 1_800_100_000)).map(\.result), ["brand-new"])
    expect("journal: filter by platform", Journal.filter(jk, text: "", kind: nil, platform: "Vercel").map(\.name), ["shop"])
    // The commit and deploy id travel with the entry; an older line without them still reads.
    let withSha = JournalEntry(platform: "Vercel", name: "shop", result: "live", seconds: 3, detail: nil, sha: "abc1234def", deployId: "dpl_1")
    let shaData = try! JSONEncoder().encode(withSha)
    let shaBack = try! JSONDecoder().decode(JournalEntry.self, from: shaData)
    expect("journal: sha and deploy id round-trip", [shaBack.sha ?? "", shaBack.deployId ?? ""], ["abc1234def", "dpl_1"])
    let oldLine = Data(#"{"at":1800000000,"platform":"Vercel","name":"shop","result":"live"}"#.utf8)
    let oldDec = JSONDecoder(); oldDec.dateDecodingStrategy = .secondsSince1970
    expect("journal: an older line has no sha", (try? oldDec.decode(JournalEntry.self, from: oldLine))?.sha == nil, true)
    // One table for the words of a deploy state, and one list for the row colours.
    expect("state table: running label", DeployState.running("update_in_progress"), L("going live", "geht live"))
    expect("project colour: unknown reads as gray", ProjectColor(name: "chartreuse"), ProjectColor.gray)
    expect("project colour: names match the store", Store.projectColorNames, ProjectColor.allCases.map(\.rawValue))

    // Settings formats (LOG-068/074/118) and small guards.
    let guardJSON = #"{"enabled":true,"lastActions":[{"broken":1}],"allowances":[{"platform":"vercel","project":"web","expiresAt":1800000000000},{"platform":"render","project":"api","expiresAt":"2028-01-15T08:00:00Z"},{"nope":true}]}"#
    if let g = try? JSONDecoder().decode(GuardStatus.self, from: Data(guardJSON.utf8)) {
        expect("guard: milliseconds read as seconds", g.allowances.first?.expiresAt ?? 0, 1_800_000_000.0)
        expect("guard: ISO date read", g.allowances.count == 2 && g.allowances[1].expiresAt > 1_800_000_000, true)
        expect("guard: a broken action is skipped", g.lastActions.count, 0)
    } else { expect("guard status decodes", false, true) }
    let afJSON = #"{"routine":"trig","token":true,"scheduled":false,"fires":[{"at":1,"project":"a","status":"fired"},{"at":"x"}]}"#
    expect("autofix settings: a broken fire is skipped", (try? JSONDecoder().decode(AutofixReport.self, from: Data(afJSON.utf8)))?.fires.count ?? -1, 1)
    expect("a name like an option is not passed on", "\(Store.safeArg("-rf")) \(Store.safeArg("web"))", "false true")
    expect("PATH with a folder that is gone is read again", Tool.pathFoldersExist(FileManager.default.homeDirectoryForCurrentUser.path + "/.nvm/versions/node/v0-\(UUID().uuidString)/bin:/usr/bin"), false)
    expect("PATH of system folders only is kept", Tool.pathFoldersExist("/usr/bin:/bin"), true)
    expect("a missing ~/.local/bin does not drop the cache", Tool.pathFoldersExist(NSHomeDirectory() + "/.local/bin-\(UUID().uuidString):/usr/bin"), true)
    do {
        let dir = NSTemporaryDirectory() + "baks-\(UUID().uuidString)"
        try FileManager.default.createDirectory(atPath: dir, withIntermediateDirectories: true)
        let file = dir + "/c.json"
        FileManager.default.createFile(atPath: file, contents: Data("{}".utf8))
        for n in 1...8 { FileManager.default.createFile(atPath: file + ".bak-2026010\(n)", contents: Data()) }
        ClaudeFiles.pruneBackups(of: file, keep: 5)
        let left = try FileManager.default.contentsOfDirectory(atPath: dir).filter { $0.contains(".bak-") }.sorted()
        expect("only the newest five backups stay", left, (4...8).map { "c.json.bak-2026010\($0)" })
        try? FileManager.default.removeItem(atPath: dir)
    } catch { expect("backup prune ran", "\(error)", "no error") }

    // LOG-039: a rate-limited hand-over leaves the button free.
    MainActor.assumeIsolated {
        let st = Store()
        var f = failedItem(); f.repo = "me/app"
        st.items[.vercel] = [f]
        st.autofix = AutofixReport(routine: "r", token: true, fires: [F(at: Date().timeIntervalSince1970, project: "app", platform: "vercel", status: "ratelimited")])
        expect("rate limited: waiting in the row, not 'fixing'", st.autofixState(f) == .waiting(.rateLimit), true)
        expect("rate limited does not count as fixing", st.fixingCount, 0)
        expect("rate limited: the button stays free", st.canFixWithClaude(f), true)
        st.autofix = AutofixReport(routine: "r", token: true, fires: [F(at: Date().timeIntervalSince1970, project: "app", platform: "vercel", status: "fired", session: "https://claude.ai/code/s")])
        expect("a running session locks the button", st.canFixWithClaude(f), false)
    }

    // LOG-014: a list that mostly broke is an error, not a short list.
    let mostlyBroken = Data(#"[{"name":"a","auto":false,"deployable":true},{"x":1},{"y":2},{"z":3}]"#.utf8)
    expect("mostly broken list is an error", (try? decodeLossy(VercelProject.self, from: mostlyBroken, label: "t", maxBadShare: 0.3)) == nil, true)
    expect("without a limit the rest is kept", (try? decodeLossy(VercelProject.self, from: mostlyBroken, label: "t"))?.count ?? -1, 1)

    // UI-036: an unknown Render type in words; UI-011: a chip can be waved away.
    expect("unknown service type readable", Store.typeName("key_value_store"), "Key Value Store")
    MainActor.assumeIsolated {
        let st = Store()
        let f = failedItem()
        st.items[.vercel] = [f]
        st.autofix = AutofixReport(routine: "r", token: true, fires: [F(at: 1, project: "app", platform: "vercel", status: "fired", session: "https://claude.ai/code/s")])
        let had = st.autofixState(f) != nil
        st.dismissAutofix(f)
        expect("dismissed chip is gone", "\(had) \(st.autofixState(f) == nil)", "true true")
        UserDefaults.standard.removeObject(forKey: "autofixDismissed")
    }

    // Second round: model names, one fire type, start times, cached counts.
    expect("model name known", ClaudeAI.modelName("claude-opus-5-5"), "Claude Opus 5.5")
    expect("model name new, with a date", ClaudeAI.modelName("claude-sonnet-6-0-20270101"), "Claude Sonnet 6.0")
    expect("model name foreign stays", ClaudeAI.modelName("gpt-x"), "gpt-x")
    expect("settings fire has error and id", fire(#"{"fires":[{"at":2,"project":"a","status":"failed","error":"HTTP 500"}]}"#).fires.map { "\($0.error ?? "") \($0.id)" }, ["HTTP 500 /a-2.0"])
    expect("this process has a start time", Tool.startTime(getpid()) != nil, true)
    var rt = item(.render); rt.lastState = "update_failed"
    expect("runtime failure can be explained, not autofixed", "\(ClaudeAI.isFailed(rt)) \(rt.lastFailed)", "true false")
    MainActor.assumeIsolated {
        let st = Store()
        st.items[.vercel] = [item(changed: true)]
        expect("cached count", st.changedCount(.vercel), 1)
        st.items[.vercel]![0].changed = false
        expect("cache follows a change of a row", st.changedCount(.vercel), 0)
        st.items[.vercel]![0].changed = true; st.hidden = ["vercel/app"]
        expect("cache follows hiding", st.changedCount(.vercel), 0)
        st.hidden = []
    }

    // The deploy window as data (UI-029), followed deploys on disk (LOG-012).
    let win = DeployWindowConfig.parse(Data(#"{"deny":[{"days":["Friday"],"from":"15:00"},{"dates":["2026-12-24"],"reason":"Xmas"}],"note":"mine"}"#.utf8))
    expect("window: rules read, days short", win.deny.map { "\($0.days) \($0.from ?? "-") \($0.reason ?? "-")" }, ["[\"fri\"] 15:00 -", "[] - Xmas"])
    let winOut = (try? win.encoded(over: Data(#"{"deny":[],"note":"mine"}"#.utf8))).flatMap { try? JSONSerialization.jsonObject(with: $0) as? [String: Any] }
    expect("window: other keys stay", winOut?["note"] as? String ?? "", "mine")
    expect("window: no empty fields written", ((winOut?["deny"] as? [[String: Any]])?[1].keys.sorted()) ?? [], ["dates", "reason"])
    expect("window: times", [DeployWindowConfig.validTime("15:00"), DeployWindowConfig.validTime("24:00"), DeployWindowConfig.validTime("9:5"), DeployWindowConfig.validTime("25:00")], [true, true, false, false])
    var badWin = win; badWin.deny[0].to = "7pm"
    expect("window: a bad time is named", badWin.problem != nil, true)
    expect("window: unreadable file is no rules", DeployWindowConfig.parse(Data("nope".utf8)).deny.count, 0)
    let fol = Store.Followed(platform: "render", id: "srv-1", deployId: "dep-1", startedAt: 100, preview: false, rolledBack: true, sha: "abc")
    expect("followed deploy round trip", (try? JSONDecoder().decode(Store.Followed.self, from: JSONEncoder().encode(fol))) == fol, true)

    // LOG-048: one row builder for both platforms.
    if let r = try? decodeLossy(RenderService.self, from: Data(#"[{"id":"srv-9","name":"api","type":"web_service","paused":false,"auto":false,"deployable":true,"lastState":"build_failed","latestSha":"abc","changed":true}]"#.utf8), label: "t").first {
        let i = r.item(id: r.id, platform: .render, detail: "", note: nil, link: nil, latestState: r.lastState)
        expect("render row: id, newest attempt, failure", "\(i.id) \(i.latestSha ?? "") \(i.lastFailed) \(i.hasNewCommits)", "srv-9 abc true true")
    } else { expect("render row decodes", false, true) }

}
