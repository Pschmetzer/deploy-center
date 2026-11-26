// App tests: rounds-cost-quiet. Called from tests/app/main.swift.

import AppKit

@MainActor func suite_rounds_cost_quiet() {
    // Error messages link to their section of TROUBLESHOOTING.md.
    do {
        expect("help: known message", ErrorHelp.url(for: "Deploy window closed (09:00)", german: false)?.absoluteString.hasSuffix("TROUBLESHOOTING.md#deploy-window-closed") ?? false, true)
        expect("help: german file", ErrorHelp.url(for: "no anthropic api key", german: true)?.absoluteString.contains("TROUBLESHOOTING.de.md#") ?? false, true)
        expect("help: unknown message goes to the top", ErrorHelp.url(for: "something odd", german: false)?.absoluteString.hasSuffix("TROUBLESHOOTING.md") ?? false, true)
        expect("help: empty message", ErrorHelp.url(for: "  ", german: false) == nil, true)
        for file in ["docs/TROUBLESHOOTING.md", "docs/TROUBLESHOOTING.de.md"] {
            let text = (try? String(contentsOfFile: file, encoding: .utf8)) ?? ""
            let slugs = Set(text.components(separatedBy: "\n").filter { $0.hasPrefix("### ") }.map { ErrorHelp.slug(String($0.dropFirst(4)).trimmingCharacters(in: .whitespaces)) })
            let missing = ErrorHelp.topics.filter { !slugs.contains($0.anchor) }.map(\.needle)
            expect("help: anchors exist in \(file)", missing, [String]())
        }
    }

    // Log search and grouping of identical build errors across projects.
    do {
        let a = "Error: Cannot find module '/build/abc1234/app/x.js' at 12:03"
        let b = "error: cannot find module '/work/def5678/shop/x.js' at 40:9"
        expect("group: same signature", LogGroups.signature(a), LogGroups.signature(b))
        expect("group: different error", LogGroups.signature(a) == LogGroups.signature("Error: out of memory") ? "same" : "differs", "differs")
        let logs: [(project: String, text: String)] = [("one", "ok\n" + a), ("two", b + "\nmore"), ("three", "Error: out of memory"), ("four", "all fine")]
        let g = LogGroups.group(logs)
        expect("group: count", g.count, 2)
        expect("group: biggest first", g[0].projects, ["one", "two"])
        let h = LogGroups.search("MODULE  cannot", in: logs)
        expect("search: hits", h.map { "\($0.project):\($0.line)" }, ["one:2", "two:1"])
        expect("search: empty query", LogGroups.search("  ", in: logs).count, 0)
        expect("search: cap per project", LogGroups.search("x", in: [("p", String(repeating: "x\n", count: 50))], perProject: 5).count, 5)
    }

    // Token age.
    do {
        let now = Date(), old = now.addingTimeInterval(-100 * 86400).timeIntervalSince1970
        expect("age days", TokenAge.days(["vercel": old], id: "vercel", now: now) ?? -1, 100)
        expect("age unknown", TokenAge.days([:], id: "vercel", now: now) == nil, true)
        expect("update keeps first day", TokenAge.update(["vercel": old], signedIn: ["vercel": true], now: now)["vercel"] ?? 0, old)
        let blip = TokenAge.update(["vercel": old], signedIn: ["vercel": false], now: now)
        expect("one failed check keeps the age", blip["vercel"] ?? 0, old)
        expect("signed out for a day forgets", TokenAge.update(blip, signedIn: ["vercel": false], now: now.addingTimeInterval(90_000))["vercel"] == nil, true)
        expect("signed in again clears the blip", TokenAge.update(blip, signedIn: ["vercel": true], now: now)["vercel.off"] == nil, true)
    }

    // Quiet hours bundle the good news into one note.
    do {
        var cal = Calendar(identifier: .gregorian); cal.timeZone = TimeZone(identifier: "UTC")!
        let night = Date(timeIntervalSince1970: TimeInterval(1_800_000_000 - 1_800_000_000 % 86400 + 23 * 3600))   // 23:00 UTC
        expect("digest: seconds until 07:00", Int(QuietDigest.seconds(until: 7, now: night, calendar: cal)), 8 * 3600)
        let seven = Date(timeIntervalSince1970: TimeInterval(1_800_000_000 - 1_800_000_000 % 86400 + 7 * 3600))   // 07:00 UTC
        expect("digest: at the end hour itself the next end is tomorrow", Int(QuietDigest.seconds(until: 7, now: seven, calendar: cal)), 24 * 3600)
        var held = QuietDigest.adding("a: one", to: [], now: night)
        held = QuietDigest.adding("b: two", to: held, now: night.addingTimeInterval(60))
        expect("digest: two held", held.count, 2)
        expect("digest: old line falls out", QuietDigest.adding("c", to: held, now: night.addingTimeInterval(21 * 3600)).count, 1)
        expect("digest: note body", QuietDigest.note(held, neutral: false).body, "a: one\nb: two")
        expect("digest: more than shown", QuietDigest.note(held, neutral: false, shown: 1).body.hasPrefix("a: one\n"), true)
        expect("digest: neutral hides the text", QuietDigest.note(held, neutral: true).body.contains("a: one"), false)
    }

    // The quiet hours example in Settings.
    do {
        expect("quiet hint: off mentions an example", SettingsText.quietHint(from: 0, to: 0).contains("22:00"), true)
        expect("quiet hint: over midnight", SettingsText.quietHint(from: 22, to: 7).contains("22:00") && SettingsText.quietHint(from: 22, to: 7).contains("07:00"), true)
        expect("quiet hint: same day has no midnight note", SettingsText.quietHint(from: 12, to: 14).contains("12:00"), true)
    }

    // Palette shortcuts from notes.
    do {
        expect("alias: words with @", PaletteAlias.aliases("api for shop @pay, and @x. mail@home @"), ["pay", "x"])
        expect("alias: none", PaletteAlias.aliases(nil), [String]())
        expect("alias: texts", PaletteAlias.texts(note: "@pay", "deploy", "deployen"), ["pay deploy", "pay deployen"])
        expect("alias: found by shortcut", fuzzyScore("pay dep", "pay deploy") != nil, true)
    }

    // Cost trend.
    do {
        func days(_ v: [Double]) -> [Costs.Day] { v.enumerated().map { Costs.Day(day: "2026-11-\(String(format: "%02d", $0.offset + 1))", total: $0.element, build: $0.element) } }
        expect("trend up", CostInsights.trend(days(Array(repeating: 1, count: 7) + Array(repeating: 2, count: 7))) ?? 0, 100.0)
        expect("trend short data", CostInsights.trend(days([1, 2, 3])) == nil, true)
        expect("trend from zero", CostInsights.trend(days(Array(repeating: 0, count: 7) + Array(repeating: 2, count: 7))) == nil, true)
        // Today's unfinished day is left out (IDEEN-11 163): 14 full days + a tiny today is still "up".
        expect("trend ignores today", CostInsights.trend(days(Array(repeating: 1, count: 7) + Array(repeating: 2, count: 7) + [0.1]), today: "2026-11-15") ?? 0, 100.0)
        expect("arrow up", CostInsights.arrow(20), "↑")
        expect("arrow down", CostInsights.arrow(-20), "↓")
        expect("arrow flat", CostInsights.arrow(3), "→")
    }

    // Round 12: quick filter chips, freeze note, week digest, waiting copy, savings fold.
    do {
        expect("chip: toggled on", SearchQuery.toggled("shop", "is:running"), "shop is:running")
        expect("chip: toggled off", SearchQuery.toggled("shop is:Running", "is:running"), "shop")
        expect("chip: active", QuickFilter.waiting.active(in: "is:waiting x") && !QuickFilter.failed.active(in: "is:waiting x"), true)
        expect("chip: running operator parsed", SearchQuery("is:running api").running && SearchQuery("is:running api").text == "api", true)
        expect("chip: platform cycles", [
            SearchQuery.cycledPlatform("", ids: ["vercel", "render"]),
            SearchQuery.cycledPlatform("platform:vercel", ids: ["vercel", "render"]),
            SearchQuery.cycledPlatform("a platform:render", ids: ["vercel", "render"]),
        ], ["platform:vercel", "platform:render", "a"])
        expect("chip: platform keeps other operators", SearchQuery.cycledPlatform("is:failed host:vercel", ids: ["vercel", "render"]), "is:failed platform:render")
        expect("chip: keys differ", Set(QuickFilter.allCases.map(\.key)).count, QuickFilter.allCases.count)

        let closed = try! JSONDecoder().decode(FreezeReply.self, from: Data(#"{"configured":true,"closedNow":true,"reason":"Release week","rules":[{"n":1,"days":["fri"],"from":"15:00","to":"24:00","reason":"Release week"}]}"#.utf8))
        expect("freeze: closed text", closed.visible && closed.closed && closed.footerText().contains("Release week"), true)
        expect("freeze: demo hides the reason", closed.footerText(demo: true).contains("Release week"), false)
        expect("freeze: rule text", FreezeReply.ruleText(closed.rules![0]), "\(DeployWindowSettings.dayName("fri")) 15:00-24:00")
        let open = try! JSONDecoder().decode(FreezeReply.self, from: Data(#"{"configured":true,"closedNow":false,"reason":null,"rules":[{"n":1,"days":null,"from":"22:00","to":"24:00"},{"n":2}]}"#.utf8))
        expect("freeze: open with two rules", "\(open.visible) \(open.closed) \(open.ruleCount)", "true false 2")
        expect("freeze: no rules, nothing shown", try! JSONDecoder().decode(FreezeReply.self, from: Data(#"{"configured":false,"closedNow":false,"rules":[]}"#.utf8)).visible, false)

        let t0 = Date(timeIntervalSince1970: 1_700_000_000)
        func e(_ days: Double, _ n: String, _ r: String, _ d: String? = nil) -> JournalEntry {
            JournalEntry(at: t0.addingTimeInterval(-days * 86400), platform: "vercel", name: n, result: r, seconds: nil, detail: d)
        }
        let list = [e(0.5, "a", "live"), e(1, "a", "failed", "Build error"), e(2, "b", "live"), e(3, "a", "rollback"), e(4, "b", "forced"), e(5, "c", "preview"),
                    e(9, "a", "live"), e(10, "a", "live"), e(30, "z", "live")]
        let w = WeekDigest.make(list, now: t0)
        expect("digest: counts", "\(w.deploys) \(w.failed) \(w.rollbacks) \(w.forced) \(w.previousDeploys)", "5 1 1 1 2")
        expect("digest: projects, preview not counted", w.projects.map { "\($0.name)\($0.count)" }, ["a3", "b2"])
        expect("digest: latest failure", w.latestFailures.map(\.name), ["a"])
        expect("digest: delta", "\(WeekDigest.delta(5, 2)) \(WeekDigest.delta(2, 5)) \(WeekDigest.delta(3, 3))", "+3 −3 ±0")
        expect("digest: empty", WeekDigest.make([], now: t0).isEmpty, true)
        expect("digest: markdown masks names and scrubs", WeekDigest.make(list, now: t0).markdown(mask: { "X-" + $0 }, scrub: { $0.replacingOccurrences(of: "error", with: "###") }).contains("X-a: Build ###"), true)

        var waiting = Item(id: "1", name: "shop", detail: "", platform: .vercel, deployable: true, auto: false, note: nil, link: nil)
        waiting.changed = true; waiting.pendingCommits = 2; waiting.headMsg = "Fix cart"; waiting.headSha = "abcdef1234"
        expect("copy: waiting commits", Row.waitingCopy(waiting)?.contains("abcdef1 Fix cart") ?? false, true)
        expect("copy: nothing waiting, nothing to copy", Row.waitingCopy(Item(id: "2", name: "calm", detail: "", platform: .vercel, deployable: true, auto: false, note: nil, link: nil)) == nil, true)
        for g in ShortcutCatalog.groups {
            let keys = g.entries.map(\.keys)
            expect("shortcuts: no key twice in \(g.name)", Set(keys).count, keys.count)
            expect("shortcuts: every entry has words", g.entries.allSatisfy { !$0.title.isEmpty && !$0.keys.isEmpty }, true)
        }
        expect("shortcuts: the sheet's own key is listed", ShortcutCatalog.groups.flatMap(\.entries).contains { $0.keys == "⌘/" }, true)
        do {
            let d = UserDefaults(suiteName: "sel-test")!; d.removePersistentDomain(forName: "sel-test")
            var a = Item(id: "a", name: "a", detail: "", platform: .vercel, deployable: true, auto: false, note: nil, link: nil)
            var b = a; b = Item(id: "b", name: "b", detail: "", platform: .vercel, deployable: false, auto: false, note: nil, link: nil)
            SelectionMemory.save(.vercel, rows: [], defaults: d)
            a.selected = true
            SelectionMemory.save(.vercel, rows: [a, b], defaults: d)
            expect("selection memory: saved ids", SelectionMemory.load(.vercel, defaults: d), ["a"])
            expect("selection memory: another platform is separate", SelectionMemory.load(.render, defaults: d), [])
            SelectionMemory.save(.vercel, rows: [], defaults: d)
            expect("selection memory: an empty list does not erase", SelectionMemory.load(.vercel, defaults: d), ["a"])
            a.selected = false; b.selected = false
            let r = SelectionMemory.restore([a, b], remembered: ["a", "b", "gone"])
            expect("selection memory: restored, not for a project that cannot deploy", r.map(\.selected), [true, false])
            d.removePersistentDomain(forName: "sel-test")
        }
        expect("why waiting: nothing known, no line", WaitReason.text(.init()) == nil, true)
        expect("why waiting: key first", WaitReason.text(.init(keyMissing: true, observer: true, freezeClosed: true)), WaitReason.text(.init(keyMissing: true)))
        expect("why waiting: freeze with reason", WaitReason.text(.init(freezeClosed: true, freezeReason: "release week"))?.contains("release week") ?? false, true)
        expect("why waiting: freeze beats queue", WaitReason.text(.init(freezeClosed: true, queue: "place 2 of 3")), WaitReason.text(.init(freezeClosed: true)))
        expect("why waiting: queue", WaitReason.text(.init(queue: "place 2 of 3"))?.contains("place 2 of 3") ?? false, true)
        do {
            var rc = RulesConfig()
            var hold = RulesConfig.Rule(); hold.name = "Hold shop"; hold.projects = ["vercel/shop"]; hold.then = .hold
            var off = hold; off.name = "off"; off.enabled = false; off.projects = []
            rc.rules = [off, hold]
            expect("why waiting: hold rule by project", WaitReason.holdRule(project: "shop", platform: .vercel, in: rc) ?? "", "Hold shop")
            expect("why waiting: other project, other platform", WaitReason.holdRule(project: "shop", platform: .render, in: rc) == nil, true)
        }
        expect("savings: fold key",SavingsEntry.collapsedKey, "savingsBannerCollapsed")
    }
}
