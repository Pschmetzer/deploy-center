// App tests: safe-deploys-providers. Called from tests/app/main.swift.

import AppKit

@MainActor func suite_safe_deploys_providers() {
    // Safe deploys: the risk from the script, in the app's words; the window and CI answers.
    do {
        let json = #"{"level":"red","files":120,"lines":4000,"reasons":[{"kind":"migrations","level":"red","files":["prisma/migrations/1/migration.sql"],"text":"x"},{"kind":"size","level":"red","files":[],"text":"x"},{"kind":"new","level":"yellow","text":"from a newer script"}]}"#
        let r = try JSONDecoder().decode(Risk.self, from: Data(json.utf8))
        expect("risk decodes, red", r.isRed, true)
        expect("risk: migrations named", r.text(r.reasons[0]), L("Database migrations: ", "Datenbank-Migrationen: ") + "prisma/migrations/1/migration.sql")
        expect("risk: size with numbers", r.text(r.reasons[1]), L("A very large diff: 120 files, 4000 lines", "Ein sehr großer Diff: 120 Dateien, 4000 Zeilen"))
        expect("risk: an unknown kind keeps the script's text", r.text(r.reasons[2]), "from a newer script")
        var m = item(changed: true); m.risk = r
        expect("migrations: new commits ask", MigrationCheck.needed(m, sha: nil), true)
        expect("migrations: a given commit (rollback) does not", MigrationCheck.needed(m, sha: "abc"), false)
        m.changed = false
        expect("migrations: nothing waits, nothing asked", MigrationCheck.needed(m, sha: nil), false)
        expect("migrations: no migration reason", MigrationCheck.needed(item(changed: true), sha: nil), false)
        let v = try JSONDecoder().decode(VercelProject.self, from: Data(#"{"name":"a","auto":false,"deployable":true}"#.utf8))
        expect("a list entry without risk still decodes", v.risk == nil, true)
        let w = try JSONDecoder().decode(WindowReply.self, from: Data(#"{"denied":true,"reason":"fri 15:00–24:00","configured":true}"#.utf8))
        expect("window reply", "\(w.denied) \(w.reason ?? "")", "true fri 15:00–24:00")
        let ci = try JSONDecoder().decode(CIReply.self, from: Data(#"{"repo":"me/app","state":"red","reason":"failed: test","checks":2}"#.utf8))
        expect("ci reply", ci.state, "red")
    } catch { expect("safe-deploy answers decode", error, "no error") }

    // Tabs from the enabled providers. No `deploys providers` (older script): Vercel and Render.
    func ids(_ l: [ProviderInfo]) -> [String] { l.map(\.id) }
    expect("no answer: Vercel and Render", ids(ProviderInfo.parse(nil).list), ["vercel", "render"])
    expect("no answer: not from the script", ProviderInfo.parse(nil).fromScript, false)
    expect("usage text instead of JSON: fallback", ids(ProviderInfo.parse(Data("Usage: deploys …".utf8)).list), ["vercel", "render"])
    expect("empty list: fallback", ids(ProviderInfo.parse(Data("[]".utf8)).list), ["vercel", "render"])
    let reported = ProviderInfo.parse(Data(#"""
    [{"id":"vercel","label":"Vercel","enabled":true,"caps":{"off":true,"preview":true}},
     {"id":"render","label":"Render","enabled":true,"caps":{"off":true}},
     {"id":"netlify","label":"Netlify","enabled":false,"caps":{}},
     {"label":"broken"},
     {"id":"vercel","enabled":false}]
    """#.utf8))
    expect("script list is read, broken and doubled entries skipped", ids(reported.list), ["vercel", "render", "netlify"])
    expect("script list is from the script", reported.fromScript, true)
    expect("only enabled ones are tabs", ids(ProviderInfo.enabled(reported.list)), ["vercel", "render"])
    expect("caps: missing means no", "\(reported.list[0].caps.preview) \(reported.list[1].caps.preview)", "true false")
    let noneOn = ProviderInfo.parse(Data(#"[{"id":"vercel","enabled":false}]"#.utf8)).list
    expect("nothing enabled: still Vercel and Render", ids(ProviderInfo.enabled(noneOn)), ["vercel", "render"])
    expect("label from the id when missing", ProviderInfo.parse(Data(#"[{"id":"fly","enabled":true}]"#.utf8)).list.first?.label ?? "", "Fly")
    expect("settings: reported first, then coming soon", ProviderInfo.settingsRows(reported.list).map { "\($0.info.id):\($0.available)" }.prefix(4).joined(separator: " "),
           "vercel:true render:true netlify:true cloudflare:false")
    expect("settings: no double of a reported one", ProviderInfo.settingsRows(reported.list).filter { $0.info.id == "netlify" }.count, 1)

    // The script lists alphabetically; the window keeps Vercel, Render first, the rest in the script's order.
    let alpha = ProviderInfo.parse(Data(#"[{"id":"amplify","enabled":true},{"id":"netlify","enabled":false},{"id":"render","enabled":true},{"id":"vercel","enabled":true}]"#.utf8)).list
    expect("Vercel and Render first", ids(alpha), ["vercel", "render", "amplify", "netlify"])
    expect("tabs keep ⌘1 Vercel", ProviderTab.shortcuts(ProviderTab.tabs(ProviderInfo.enabled(alpha)))[.provider("vercel")] ?? 0, 1)

    // Layout: 1 provider no tabs, 2–3 segmented with All, 4 and more a menu.
    expect("layout 1", TabLayout.decide(1), TabLayout.hidden)
    expect("layout 2", TabLayout.decide(2), TabLayout.segmented)
    expect("layout 3", TabLayout.decide(3), TabLayout.segmented)
    expect("layout 4", TabLayout.decide(4), TabLayout.menu)
    expect("layout 7", TabLayout.decide(7), TabLayout.menu)
    func prov(_ n: Int) -> [ProviderInfo] { (0..<n).map { ProviderInfo(id: "p\($0)", label: "P\($0)", enabled: true) } }
    expect("one provider: one tab, no All", ProviderTab.tabs(prov(1)), [ProviderTab.provider("p0")])
    expect("two providers: All first", ProviderTab.tabs(prov(2)), [ProviderTab.all, .provider("p0"), .provider("p1")])
    expect("four providers: All and four", ProviderTab.tabs(prov(4)).count, 5)
    let two = ProviderTab.tabs(ProviderInfo.builtIn)
    expect("shortcuts as before: ⌘1 Vercel, ⌘2 Render, ⌘3 All",
           "\(ProviderTab.shortcuts(two)[.provider("vercel")] ?? 0) \(ProviderTab.shortcuts(two)[.provider("render")] ?? 0) \(ProviderTab.shortcuts(two)[.all] ?? 0)", "1 2 3")
    expect("shortcuts stop at 9", ProviderTab.shortcuts(ProviderTab.tabs(prov(12))).values.max() ?? 0, 9)
    expect("remembered tab kept", ProviderTab.resolve(.provider("render"), in: two), ProviderTab.provider("render"))
    expect("gone tab: first provider", ProviderTab.resolve(.provider("netlify"), in: two), ProviderTab.provider("vercel"))
    expect("All with one provider: that provider", ProviderTab.resolve(.all, in: ProviderTab.tabs(prov(1))), ProviderTab.provider("p0"))

    // Rows of one repo sit together under one header; a single row gets none.
    func named(_ n: String, _ repo: String?) -> Item {
        var i = Item(id: n, name: n, detail: "", platform: .vercel, deployable: true, auto: false, note: nil, link: nil); i.repo = repo; return i
    }
    let mixedRows = [named("a", "me/x"), named("b", "me/y"), named("c", "me/x"), named("d", nil), named("e", nil)]
    let clustered = RepoGroup.cluster(mixedRows)
    expect("cluster keeps first appearance", clustered.map(\.name), ["a", "c", "b", "d", "e"])
    let groups = RepoGroup.groups(clustered)
    expect("groups", groups.map { $0.items.map(\.name).joined() }, ["ac", "b", "d", "e"])
    expect("header only for several rows", groups.map(\.showsHeader), [true, false, false, false])

    // One key figure per row.
    var failedRow = item(changed: true); failedRow.lastAt = Date(); failedRow.lastState = "ERROR"
    expect("failed deploy first", Row.keyFigure(failedRow), Row.KeyFigure.failed)
    var waitingRow = item(changed: true); waitingRow.lastAt = Date(); waitingRow.lastState = "READY"
    expect("then what waits", Row.keyFigure(waitingRow), Row.KeyFigure.waiting)
    var liveRow = item(changed: false); liveRow.lastAt = Date(); liveRow.lastState = "READY"
    expect("then the last deploy", Row.keyFigure(liveRow), Row.KeyFigure.lastDeploy)
    expect("never deployed", Row.keyFigure(item(changed: false)), Row.KeyFigure.never)

    // The summary line and the saving.
    var wait = Store.Waiting(); wait.projects = 3; wait.prs = 12
    expect("summary with saving", waitingSummary(wait, saved: 41), L("3 projects · 12 PRs waiting · \(usd0(41)) saved", "3 Projekte · 12 PRs warten · \(usd0(41)) gespart"))
    expect("summary without saving", waitingSummary(wait, saved: nil), L("3 projects · 12 PRs waiting", "3 Projekte · 12 PRs warten"))
    wait.prs = 0
    expect("summary without PRs", waitingSummary(wait, saved: nil), L("3 projects waiting", "3 Projekte warten"))
    expect("summary when all is live", waitingSummary(Store.Waiting(), saved: nil), L("Everything merged is live", "Alles Gemergte ist live"))
    expect("saved over whole days since off", offCosts.saved(today: "2026-11-06") ?? -1, 16.0)
    expect("no saving before a whole day", offCosts.saved(today: "2026-11-04") == nil, true)

}
