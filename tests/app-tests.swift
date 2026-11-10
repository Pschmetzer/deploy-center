// Tests for the rules in the app that decide what a row says. No network, no window.
// Run: tests/app-tests.sh (compiles this with the app's sources, without App.swift).

import AppKit

var fails = 0
func expect(_ name: String, _ got: Any, _ want: Any) {
    if "\(got)" == "\(want)" { print("ok   \(name)") } else { print("FAIL \(name): expected [\(want)], got [\(got)]"); fails += 1 }
}
func item(_ p: Platform = .vercel, changed: Bool? = nil, last: String? = "a", head: String? = "b",
          commits: Int? = nil, prs: Int? = nil, partial: Bool = false, rewritten: Bool = false,
          repo: String? = "me/app", kind: String? = nil) -> Item {
    var i = Item(id: p == .render ? "srv-1" : "app", name: "app", detail: "", platform: p, deployable: true, auto: false, note: nil, link: nil)
    i.changed = changed; i.lastSha = last; i.headSha = head; i.pendingCommits = commits; i.pendingPRs = prs
    i.pendingPartial = partial; i.rewritten = rewritten; i.repo = repo; i.ref = "main"; i.kind = kind
    return i
}

// What has changes: the script's word first, commits as a fallback.
expect("script says changed", item(changed: true, last: "a", head: "a").hasNewCommits, true)
expect("script says not changed", item(changed: false).hasNewCommits, false)
expect("no word: different commits", item().hasNewCommits, true)
expect("no word: same commit", item(head: "a").hasNewCommits, false)

// What the row says.
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
expect("failures of the last deploys", "\(Journal.failures(of: "a\"b", in: je))", "(failed: 1, total: 2)")

// The journal: formulas, platforms, stable ids.
let fx = [JournalEntry(platform: "Vercel", name: "=HYPERLINK(1)", result: "failed", seconds: nil, detail: "@x")]
expect("csv defuses formulas", Journal.csv(fx).contains("\"'=HYPERLINK(1)\",failed,,\"'@x\""), true)
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
expect("killTree closes the pipe at once", Date().timeIntervalSince(t0) < 3, true)
// Build logs: what is a failure, what leaves the app.
expect("cache miss is no error", LogTools.isErrorLine("Build Cache not found, building from scratch"), false)
expect("ErrorBoundary file is no error", LogTools.isErrorLine("  src/ErrorBoundary.tsx  2.1 kB"), false)
expect("0 failed is good news", LogTools.isErrorLine("Tests: 0 failed, 12 passed"), false)
expect("a real error", LogTools.isErrorLine("Type error: Cannot read x"), true)
expect("npm ERR!", LogTools.isErrorLine("npm ERR! code ELIFECYCLE"), true)
expect("command failed", LogTools.isErrorLine("Command \"npm run build\" exited with 1"), true)
expect("GitHub token masked", LogTools.maskSecrets("using ghp_abcdefghijklmnopqrstuvwxyz0123 now"), "using [GITHUB TOKEN] now")
expect("bearer masked", LogTools.maskSecrets("Authorization: Bearer abc.def-123456"), "Authorization: Bearer [HIDDEN]")
expect("env value masked", LogTools.maskSecrets("STRIPE_SECRET_KEY=sk_live_1234"), "STRIPE_SECRET_KEY=[HIDDEN]")
expect("sk- key masked", LogTools.maskSecrets("key sk-proj-ABCDEFGHIJKLMNOPQRST"), "key [API KEY]")
expect("password in a URL masked", LogTools.maskSecrets("postgres://app:hunter2@db:5432/x"), "postgres://app:[HIDDEN]@db:5432/x")
expect("email masked", LogTools.maskSecrets("committed by dev.ops+ci@example.co.uk today"), "committed by [EMAIL] today")
expect("Anthropic key masked", LogTools.maskSecrets("ANTHROPIC=sk-ant-api03-ABCDEFGHIJKLMNOPQRSTUV"), "ANTHROPIC=[API KEY]")
expect("Claude prompt carries no secrets", ["ghp_abcdefghijklmnopqrstuvwxyz0123", "hunter2", "me@example.com"].filter {
    LogTools.claudePrompt(name: "web", repo: "me/web", ref: "main", sha: "abc", message: "failed for me@example.com",
                          log: "npm ERR! token ghp_abcdefghijklmnopqrstuvwxyz0123\npostgres://u:hunter2@db/x\nby me@example.com").contains($0) }.count, 0)
// Claude in the app: the script calls, and what counts as a failed build.
expect("ai notes args", ClaudeAI.Ask.notes("de").args(project: "web"), ["ai", "notes", "web", "--json", "--lang", "de"])
expect("ai explain args", ClaudeAI.Ask.explain.args(project: "srv-1"), ["ai", "explain", "srv-1", "--json"])
expect("ai failed: platform error", { var i = item(); i.lastState = "build_failed"; return ClaudeAI.isFailed(i) }(), true)
expect("ai failed: a ready build is not", { var i = item(); i.lastState = "READY"; return ClaudeAI.isFailed(i) }(), false)
expect("ai off by default", UserDefaults(suiteName: "dc-test-\(UUID())")!.bool(forKey: ClaudeAI.enabledKey), false)
expect("plain text untouched", LogTools.maskSecrets("Error: module not found"), "Error: module not found")
expect("ANSI codes out", LogTools.clean("\u{1B}[31mError\u{1B}[0m: x"), "Error: x")
expect("long lines cut", LogTools.clean(String(repeating: "a", count: 1000)).count, 402)
expect("fence outgrows backticks", LogTools.fence(for: "a ```` b"), "`````")
expect("prompt masks secrets", LogTools.claudePrompt(name: "w", repo: nil, ref: nil, sha: nil, message: nil,
       log: "Error: token=abc123secret").contains("abc123secret"), false)

let f1 = Details.Commit(sha: "a", full: nil, url: nil, msg: "feat(ui): Dark mode", author: nil, bot: false, at: 0, pr: 3)
let f2 = Details.Commit(sha: "b", full: nil, url: nil, msg: "fix: Login loop", author: nil, bot: false, at: 0, pr: nil)
let f3 = Details.Commit(sha: "c", full: nil, url: nil, msg: "Tidy up", author: nil, bot: false, at: 0, pr: nil)
expect("release notes grouped", LogTools.releaseNotes(name: "web", commits: [f3, f2, f1]),
       "## web\n\n### Features\n- Dark mode (#3)\n\n### Fixes\n- Login loop\n\n### Other\n- Tidy up")

// Decoding: one broken entry does not take the list with it.
let mixed = Data(#"[{"name":"ok","auto":false,"deployable":true},{"name":"broken"}]"#.utf8)
expect("lossy list keeps the good entry", ((try? decodeLossy(VercelProject.self, from: mixed, label: "test")) ?? []).map(\.name), ["ok"])
let doc = try? JSONDecoder().decode(Doctor.self, from: Data(#"{"jq":true,"renderKey":true}"#.utf8))
expect("doctor with missing fields", "\(doc?.jq ?? false) \(doc?.vercelLoggedIn ?? true) \(doc?.renderKey ?? false)", "true false true")
var odd = item(changed: true); odd.ref = "fix/#12 x"
expect("compare link encodes the branch", odd.compareURL?.absoluteString ?? "nil", "https://github.com/me/app/compare/a...fix/%2312%20x")

// Demo stand-ins rarely collide.
UserDefaults.standard.set(true, forKey: "demoMode")
expect("40 projects, 40 stand-ins", Set((0..<40).map { Demo.mask("project-\($0)") }).count >= 39, true)
UserDefaults.standard.removeObject(forKey: "demoMode")

// Processes and the queue.
expect("short errors stay", Tool.shorten("no key"), "no key")
expect("long errors keep the end", Tool.shorten(String(repeating: "x", count: 500) + "CAUSE").hasSuffix("CAUSE"), true)
expect("long errors are cut", Tool.shorten(String(repeating: "x", count: 500)).count, 302)
MainActor.assumeIsolated {
    let st = Store()
    let a = item(changed: true, commits: 2, prs: 1, repo: "me/a")
    var b = Item(id: "b", name: "b", detail: "", platform: .vercel, deployable: false, auto: false, note: nil, link: nil)
    b.changed = true; b.pendingPRs = 5; b.repo = "me/b"
    var c = Item(id: "c", name: "c", detail: "", platform: .vercel, deployable: true, auto: false, note: nil, link: nil)
    c.changed = true; c.pendingPRs = 7; c.repo = "me/c"
    st.items[.vercel] = [a, b, c]
    st.togglePin(c); st.togglePin(c)   // pins untouched
    st.toggleHidden(c)
    expect("waiting skips hidden and undeployable", "\(st.waiting.projects) \(st.waiting.prs)", "1 1")
    st.toggleHidden(c); UserDefaults.standard.removeObject(forKey: "hidden"); UserDefaults.standard.removeObject(forKey: "pinned")

    let undo = Store.Toast(text: "hidden", ok: true, undoLabel: "Undo", undo: {})
    st.show(undo)
    st.show(Store.Toast(text: "other", ok: true))
    expect("undo toast is not pushed away", st.toast?.text ?? "nil", "hidden")
}

// Safe deploys: the risk from the script, in the app's words; the window and CI answers.
do {
    let json = #"{"level":"red","files":120,"lines":4000,"reasons":[{"kind":"migrations","level":"red","files":["prisma/migrations/1/migration.sql"],"text":"x"},{"kind":"size","level":"red","files":[],"text":"x"},{"kind":"new","level":"yellow","text":"from a newer script"}]}"#
    let r = try JSONDecoder().decode(Risk.self, from: Data(json.utf8))
    expect("risk decodes, red", r.isRed, true)
    expect("risk: migrations named", r.text(r.reasons[0]), L("Database migrations: ", "Datenbank-Migrationen: ") + "prisma/migrations/1/migration.sql")
    expect("risk: size with numbers", r.text(r.reasons[1]), L("A very large diff: 120 files, 4000 lines", "Ein sehr großer Diff: 120 Dateien, 4000 Zeilen"))
    expect("risk: an unknown kind keeps the script's text", r.text(r.reasons[2]), "from a newer script")
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
let offCosts = try! JSONDecoder().decode(Costs.self, from: Data("""
{"days":[{"day":"2026-11-01","total":10,"build":10},{"day":"2026-11-02","total":10,"build":10},{"day":"2026-11-03","total":4,"build":4},
         {"day":"2026-11-04","total":1,"build":1},{"day":"2026-11-05","total":3,"build":3},{"day":"2026-11-06","total":9,"build":9}],
 "projects":[],"offDay":"2026-11-03","buildsComplete":true}
""".utf8))
expect("saved over whole days since off", offCosts.saved(today: "2026-11-06") ?? -1, 16.0)
expect("no saving before a whole day", offCosts.saved(today: "2026-11-04") == nil, true)

// Autofix in the rows: old and new status shapes, each state and when it ends by itself.
func fire(_ json: String) -> AutofixReport { try! JSONDecoder().decode(AutofixReport.self, from: Data(json.utf8)) }
let oldShape = fire(#"{"routine":"trig_1","token":true,"scheduled":false,"fires":[{"at":100,"project":"app","platform":"vercel","status":"fired","session":"https://claude.ai/code/s1","pr":7,"mergedSha":null},{"broken":true}]}"#)
expect("old status decodes, broken fire skipped", "\(oldShape.fires.count) \(oldShape.fires[0].prNumber ?? 0) \(oldShape.ready)", "1 7 true")
let newShape = fire(#"{"routine":null,"token":false,"fires":[{"at":100,"project":"app","platform":"vercel","status":"fired","prNumber":9,"prState":"OPEN","prUrl":"https://github.com/me/app/pull/9"}]}"#)
expect("new status decodes", "\(newShape.fires[0].prNumber ?? 0) \(newShape.fires[0].prState ?? "") \(newShape.ready)", "9 open false")
expect("empty status decodes", fire("{}").fires.count, 0)

func failedItem(_ p: Platform = .vercel) -> Item { var i = item(p, changed: false, last: "aaaaaaa1", head: "aaaaaaa1"); i.lastState = p == .vercel ? "ERROR" : "build_failed"; return i }
typealias F = AutofixReport.Fire
let soon = Date(timeIntervalSince1970: 1 + 60), late = Date(timeIntervalSince1970: 1 + RowAutofix.stalledAfter + 1)
expect("fixing while failed", RowAutofix.of(failedItem(), F(at: 1, project: "app", platform: "vercel", status: "fired", session: "https://claude.ai/code/s1"), now: soon) == .fixing(session: URL(string: "https://claude.ai/code/s1")), true)
expect("no PR long after the hand-over: not fixing any more", RowAutofix.of(failedItem(), F(at: 1, project: "app", platform: "vercel", status: "fired", session: "https://claude.ai/code/s1"), now: late) == .noPR(session: URL(string: "https://claude.ai/code/s1")), true)
expect("an open PR is never stalled", RowAutofix.of(failedItem(), F(at: 1, project: "app", platform: "vercel", status: "fired", prNumber: 4, prState: "open"), now: late) == .prOpen(number: 4, url: nil), true)
expect("sync while a PR may still come", RowAutofix.needsSync(F(at: 1, project: "app", platform: "vercel", status: "fired"), now: soon), true)
expect("no sync for a stalled hand-over", RowAutofix.needsSync(F(at: 1, project: "app", platform: "vercel", status: "fired"), now: late), false)
expect("sync for an open PR, however old", RowAutofix.needsSync(F(at: 1, project: "app", platform: "vercel", status: "fired", prNumber: 4, prState: "open"), now: late), true)
var doneFire = F(at: 1, project: "app", platform: "vercel", status: "fired"); doneFire.done = true
expect("no sync for a fire that is green again", RowAutofix.needsSync(doneFire, now: soon), false)
expect("done decodes", fire(#"{"fires":[{"at":1,"project":"a","status":"fired","done":true}]}"#).fires[0].done, true)
expect("rate limited is not 'no PR'", RowAutofix.of(failedItem(), F(at: 1, project: "app", platform: "vercel", status: "ratelimited"), now: late) == .waiting(.rateLimit), true)
expect("pending, fresh: starting", RowAutofix.of(failedItem(), F(at: 1, project: "app", platform: "vercel", status: "pending"), now: soon) == .waiting(.starting), true)
expect("pending for long: unclear", RowAutofix.of(failedItem(), F(at: 1, project: "app", platform: "vercel", status: "pending"),
                                                   now: Date(timeIntervalSince1970: 1 + RowAutofix.unclearAfter + 1)) == .waiting(.unclear), true)
expect("a start that failed is its own case", RowAutofix.of(failedItem(), F(at: 1, project: "app", platform: "vercel", status: "failed")) == .handedBack(.startFailed), true)
expect("unsupported carries the reason",
       RowAutofix.of(failedItem(), fire(#"{"fires":[{"at":1,"project":"app","platform":"vercel","status":"unsupported","reason":"autofix works with GitHub repos only"}]}"#).fires[0])
         == .unsupported(reason: "autofix works with GitHub repos only"), true)
expect("start failed and fix failed read differently", AgentChips.text(.handedBack(.startFailed)) != AgentChips.text(.handedBack(.fixFailed)), true)
expect("an unsupported chip can be dismissed", AgentChips.dismissable(.unsupported(reason: nil)), true)
expect("a running fix cannot be dismissed", AgentChips.dismissable(.fixing(session: nil)), false)
expect("no PR chip links the session", AgentChips.link(.noPR(session: URL(string: "https://claude.ai/code/s1")))?.absoluteString ?? "", "https://claude.ai/code/s1")
var green = failedItem(); green.lastState = "READY"
expect("fixing ends when green again", RowAutofix.of(green, F(at: 1, project: "app", platform: "vercel", status: "fired")) == nil, true)
expect("PR open", RowAutofix.of(failedItem(), F(at: 1, project: "app", platform: "vercel", status: "fired", prNumber: 4, prState: "open")) == .prOpen(number: 4, url: nil), true)
var waiting = failedItem(); waiting.changed = true; waiting.headSha = "bbbbbbb2"
expect("merged, not live", RowAutofix.of(waiting, F(at: 1, project: "app", platform: "vercel", status: "fired", prNumber: 4, mergedSha: "bbbbbbb2ffff")) == .merged(sha: "bbbbbbb2ffff", pr: 4, url: nil), true)
var shipped = waiting; shipped.lastSha = "bbbbbbb2"; shipped.changed = false
expect("merged ends once live", RowAutofix.of(shipped, F(at: 1, project: "app", platform: "vercel", status: "fired", mergedSha: "bbbbbbb2ffff")) == nil, true)
expect("fix failed too", RowAutofix.of(failedItem(), F(at: 1, project: "app", platform: "vercel", status: "skipped")) == .handedBack(.fixFailed), true)
expect("PR closed unmerged", RowAutofix.of(failedItem(), F(at: 1, project: "app", platform: "vercel", status: "fired", prNumber: 4, prState: "closed")) == .handedBack(.fixFailed), true)
expect("chip words", AgentChips.text(.prOpen(number: 12, url: nil)), L("Fix PR #12 open", "Fix-PR #12 offen"))

// Fires name a Render service by its name, not its id; the newest one counts; the platform must match.
let many = AutofixReport(routine: "trig_1", token: true, fires: [
    F(at: 1, project: "app", platform: "render", status: "skipped"),
    F(at: 5, project: "app", platform: "render", status: "fired"),
    F(at: 9, project: "app", platform: "vercel", status: "skipped"),
    F(at: 9, project: "srv-1", platform: "render", status: "skipped")])
expect("render matched by name, newest", many.newest(for: failedItem(.render))?.at ?? 0, 5.0)

// Allowances: epoch or ISO date; a Render one by id or name.
let allow = try! JSONDecoder().decode(AllowanceReport.self, from: Data(#"{"allowances":[{"platform":"vercel","project":"app","expiresAt":2000000000},{"platform":"Render","project":"srv-1","expiresAt":"2033-05-18T03:33:20Z"},{"platform":"vercel","project":"x","expiresAt":"soon"}]}"#.utf8))
expect("allowances decode, bad date skipped", allow.allowances.count, 2)
expect("both date forms", allow.allowances[0].expiresAt == allow.allowances[1].expiresAt, true)
expect("render allowance by id", allow.allowances[1].covers(item(.render)), true)
expect("no guard answer decodes empty", (try? JSONDecoder().decode(AllowanceReport.self, from: Data("{}".utf8)))?.allowances.count ?? -1, 0)

// A merged fix ticks its row once; unticked, the next load leaves it.
MainActor.assumeIsolated {
    UserDefaults.standard.removeObject(forKey: "autofixPreselected")
    let st = Store()
    st.items[.vercel] = [waiting]
    st.autofix = AutofixReport(routine: "trig_1", token: true, fires: [F(at: 1, project: "app", platform: "vercel", status: "fired", mergedSha: "bbbbbbb2ffff")])
    st.preselectMergedFixes()
    expect("merged fix preselected", st.items[.vercel]![0].selected, true)
    st.items[.vercel]![0].selected = false
    st.preselectMergedFixes()
    expect("preselected only once", st.items[.vercel]![0].selected, false)
    expect("no button while a fix waits", st.canFixWithClaude(st.items[.vercel]![0]), false)
    st.autofix = AutofixReport(routine: "trig_1", token: true, fires: [F(at: Date().timeIntervalSince1970 - 60, project: "app", platform: "vercel", status: "fired")])
    st.items[.vercel] = [failedItem()]
    expect("menu bar count", st.fixingCount, 1)
    st.autofix = AutofixReport(routine: "trig_1", token: true, fires: [F(at: 1, project: "app", platform: "vercel", status: "fired")])
    expect("a stalled hand-over is not counted as fixing", st.fixingCount, 0)
    expect("no button for a stalled hand-over (not handed over twice)", st.canFixWithClaude(st.items[.vercel]![0]), false)
    st.autofix = AutofixReport(routine: "trig_1", token: true, fires: [])
    expect("button on a failed row", st.canFixWithClaude(st.items[.vercel]![0]), true)
    st.allowances = [AutoDeployAllowance(platform: "vercel", project: "app", expiresAt: Date().addingTimeInterval(-60))]
    expect("expired allowance ignored", st.allowance(st.items[.vercel]![0]) == nil && st.activeAllowances.isEmpty, true)
    UserDefaults.standard.removeObject(forKey: "autofixPreselected")
}

// Savings: the simulator and the ledger read what lib/savings.sh prints, and odd fields do not break them.
func savingsData(_ file: String) -> Data { (try? Data(contentsOf: URL(fileURLWithPath: "tests/fixtures/savings/" + file))) ?? Data() }
if let sim = try? JSONDecoder().decode(SimulateReport.self, from: savingsData("simulate-report.json")) {
    expect("simulate: rows", sim.projects.map(\.name), ["web", "api", "svc", "lost"])
    expect("simulate: auto-deploy a month", sim.autoMonth.usd ?? -1, 3.2)
    expect("simulate: once a day a month", sim.dailyMonth.usd ?? -1, 2.4)
    expect("simulate: Render minutes", sim.autoMonth.renderMinutes ?? -1, 20.0)
    expect("simulate: Render without price", sim.projects[2].autoMonth.usd == nil, true)
    expect("simulate: incomplete prices are said", sim.usdComplete, false)
    expect("simulate: a problem is kept", sim.projects[3].problem != nil, true)
} else { expect("simulate fixture decodes", false, true) }
if let led = try? JSONDecoder().decode(LedgerReport.self, from: savingsData("ledger-report.json")) {
    expect("ledger: since", led.since ?? "", "2026-01-20")
    expect("ledger: total", "\(led.usd ?? -1) \(led.skipped) \(led.vercelMinutes) \(led.renderMinutes)", "0.8 6.0 12.0 10.0")
    expect("ledger: skipped pushes", led.projects[0].skippedPushes.map(\.sha), ["a4", "a3", "a2", "a1"])
    // (0.8 + 0.2) / 11 days before, 0.2 / 11 since: the share card gets per-day numbers.
    expect("ledger: per day for the share card", led.perDay.map { "\(($0.before * 11).rounded()) \((($0.after * 11) * 10).rounded())" } ?? "", "1.0 2.0")
} else { expect("ledger fixture decodes", false, true) }
let oddLedger = Data(#"{"since":null,"days":"3","projects":[{"name":"ok","skipped":"2","savedUsd":"x"},{"nope":1},7],"total":{"usd":null}}"#.utf8)
if let led = try? JSONDecoder().decode(LedgerReport.self, from: oddLedger) {
    expect("lenient: bad rows are dropped, numbers as text read", "\(led.projects.map(\.name)) \(led.projects[0].skipped) \(led.days)", "[\"ok\"] 2.0 3.0")
    expect("lenient: unreadable dollars are unknown", led.projects[0].savedUsd == nil, true)
    expect("lenient: no start, no ledger", led.hasStarted, false)
} else { expect("lenient ledger decodes", false, true) }
expect("lenient: an empty object is an empty simulation",
       (try? JSONDecoder().decode(SimulateReport.self, from: Data("{}".utf8)))?.projects.count ?? -1, 0)
UserDefaults.standard.set(true, forKey: "demoMode")
expect("savings: names masked in demo mode", SavingsFormat.name("shop-api") != "shop-api", true)
UserDefaults.standard.removeObject(forKey: "demoMode")
expect("savings: estimates carry ≈", SavingsFormat.usd(1.5).hasPrefix("≈ "), true)

// The command palette's fuzzy search.
expect("fuzzy: letters in order", fuzzyScore("dpl", "deploy app") != nil, true)
expect("fuzzy: letters missing", fuzzyScore("xyz", "deploy app") == nil, true)
expect("fuzzy: wrong order", fuzzyScore("ba", "abc") == nil, true)
expect("fuzzy: empty query matches", fuzzyScore("  ", "anything") ?? -1, 0)
expect("fuzzy: case and accents", fuzzyScore("UBER zuruck", "Über – zurückrollen") != nil, true)
expect("fuzzy: word starts beat the middle", (fuzzyScore("sa", "shop-api") ?? 0) > (fuzzyScore("sa", "visa") ?? 0), true)
expect("fuzzy: a whole word beats scattered letters",
       (fuzzyScore("log", "log shop") ?? 0) > (fuzzyScore("log", "lots of good") ?? 0), true)
expect("fuzzy: shorter wins a tie", (fuzzyScore("open", "open a") ?? 0) > (fuzzyScore("open", "open abc") ?? 0), true)
let paletteEntries: [(id: String, texts: [String])] = [
    ("reload", ["Reload", "Neu laden"]), ("deploy|a", ["deploy alpha"]), ("deploy|b", ["deploy bravo"]), ("log|a", ["log alpha"])]
expect("palette: recent first without a query",
       paletteOrder(query: "", entries: paletteEntries, recent: ["log|a", "gone", "deploy|b", "log|a"]),
       ["log|a", "deploy|b", "reload", "deploy|a"])
expect("palette: only matches", paletteOrder(query: "alp", entries: paletteEntries, recent: []), ["log|a", "deploy|a"])
expect("palette: the other language", paletteOrder(query: "neu", entries: paletteEntries, recent: []), ["reload"])
expect("palette: a recent one ahead of an equal match",
       paletteOrder(query: "deploy", entries: paletteEntries, recent: ["deploy|b"]).prefix(2).joined(separator: ","), "deploy|b,deploy|a")
expect("palette: best match first", paletteOrder(query: "log", entries: paletteEntries, recent: []).first ?? "", "log|a")

// Settings > Claude: config merge and unmerge never touch other entries.
do {
    func js(_ s: String) -> Data { Data(s.utf8) }
    func obj(_ d: Data?) -> NSDictionary { (try? JSONSerialization.jsonObject(with: d ?? Data())) as? NSDictionary ?? [:] }
    let entry = ClaudeConfig.desktopEntry(node: "/opt/n/node", server: "/A B/server.mjs", deploys: "/A B/deploys", allowDeploy: false)
    let fixture = js(#"{"mcpServers":{"other":{"command":"x","args":["a/b"],"env":{"K":"v"}}},"preferences":{"on":true,"off":false,"n":null,"f":1.5,"i":3,"u":"Grüße ✓","url":"https://a/b"}}"#)

    let merged = try ClaudeConfig.merge(fixture, entry: entry)
    let m = obj(merged)
    expect("merge keeps other entry", (m["mcpServers"] as? NSDictionary)?["other"] as? NSDictionary == (obj(fixture)["mcpServers"] as? NSDictionary)?["other"] as? NSDictionary, true)
    expect("merge keeps other keys", m["preferences"] as? NSDictionary == obj(fixture)["preferences"] as? NSDictionary, true)
    expect("merge adds entry", ClaudeConfig.entry(merged)?["command"] as? String ?? "", "/opt/n/node")
    expect("merge sets DEPLOYS_BIN", (ClaudeConfig.entry(merged)?["env"] as? [String: Any])?["DEPLOYS_BIN"] as? String ?? "", "/A B/deploys")
    expect("deploy off by default", ClaudeConfig.allowsDeploy(ClaudeConfig.entry(merged)), false)
    expect("slashes not escaped", String(decoding: merged, as: UTF8.self).contains(#"https://a/b"#), true)
    let again = try ClaudeConfig.merge(merged, entry: ClaudeConfig.desktopEntry(node: "/n", server: "/s", deploys: "/d", allowDeploy: true))
    expect("merge replaces, not duplicates", ((obj(again)["mcpServers"] as? NSDictionary)?.count ?? 0), 2)
    expect("allow deploy written", ClaudeConfig.allowsDeploy(ClaudeConfig.entry(again)), true)

    let back = try ClaudeConfig.unmerge(merged)
    expect("unmerge restores the original", obj(back) == obj(fixture), true)
    let alone = try ClaudeConfig.merge(js(#"{"a":[1,true]}"#), entry: entry)
    expect("unmerge of the only entry leaves no empty mcpServers", obj(try ClaudeConfig.unmerge(alone)) == obj(js(#"{"a":[1,true]}"#)), true)
    expect("unmerge of absent entry writes nothing", try ClaudeConfig.unmerge(fixture) == nil, true)
    expect("unmerge of missing file writes nothing", try ClaudeConfig.unmerge(nil) == nil, true)

    expect("missing file gets mcpServers", (obj(try ClaudeConfig.merge(nil, entry: entry))["mcpServers"] as? NSDictionary)?.allKeys.count ?? 0, 1)
    expect("empty file gets mcpServers", ClaudeConfig.entry(try ClaudeConfig.merge(js("  \n"), entry: entry)) != nil, true)
    expect("file without mcpServers", ClaudeConfig.entry(try ClaudeConfig.merge(js(#"{"a":1}"#), entry: entry)) != nil, true)
    func refuses(_ s: String) -> String {
        do { _ = try ClaudeConfig.merge(js(s), entry: entry); return "wrote" } catch { return "\(error)" }
    }
    expect("invalid JSON is refused", refuses(#"{"mcpServers": {"#), "invalidJSON")
    expect("array top level is refused", refuses("[1,2]"), "notAnObject")
    expect("mcpServers not an object is refused", refuses(#"{"mcpServers":[1]}"#), "serversNotAnObject")
    expect("unmerge refuses invalid JSON", (try? ClaudeConfig.unmerge(js("{nope"))) == nil, true)

    expect("claude mcp add", ClaudeConfig.codeAddArgs(node: "/n", server: "/s", deploys: "/d", allowDeploy: false).joined(separator: " "),
           "mcp add -e DEPLOYS_BIN=/d --transport stdio --scope user deploy-center -- /n /s")
    expect("claude mcp add with deploy", ClaudeConfig.codeAddArgs(node: "/n", server: "/s", deploys: "/d", allowDeploy: true).joined(separator: " "),
           "mcp add -e DEPLOYS_BIN=/d -e DEPLOYS_MCP_ALLOW_DEPLOY=1 --transport stdio --scope user deploy-center -- /n /s")
    expect("claude mcp remove", ClaudeConfig.codeRemoveArgs().joined(separator: " "), "mcp remove deploy-center --scope user")

    // Files: backup, same mode, symlink kept, new file 600.
    let dir = FileManager.default.temporaryDirectory.appendingPathComponent("dc-claude-\(UUID().uuidString)").path
    try FileManager.default.createDirectory(atPath: dir, withIntermediateDirectories: true)
    defer { try? FileManager.default.removeItem(atPath: dir) }
    let file = dir + "/c.json", link = dir + "/link.json"
    FileManager.default.createFile(atPath: file, contents: fixture, attributes: [.posixPermissions: 0o640])
    try FileManager.default.createSymbolicLink(atPath: link, withDestinationPath: file)
    let bak = try ClaudeFiles.write(merged, to: link)
    func mode(_ p: String) -> Int { ((try? FileManager.default.attributesOfItem(atPath: p))?[.posixPermissions] as? NSNumber)?.intValue ?? -1 }
    expect("write keeps the mode", mode(file), 0o640)
    expect("backup has the old content", bak.map { FileManager.default.contents(atPath: $0) == fixture } ?? false, true)
    expect("backup has the same mode", bak.map(mode) ?? -1, 0o640)
    expect("symlink stays a symlink", (try? FileManager.default.destinationOfSymbolicLink(atPath: link)) == file, true)
    expect("written through the link", FileManager.default.contents(atPath: file) == merged, true)
    expect("no temp file left", (try FileManager.default.contentsOfDirectory(atPath: dir)).filter { $0.hasSuffix(".tmp") }.count, 0)
    let fresh = dir + "/new/c.json"
    expect("new file has no backup", try ClaudeFiles.write(merged, to: fresh) == nil, true)
    expect("new file is 600", mode(fresh), 0o600)
} catch { expect("claude config tests ran", "\(error)", "no error") }

// The palette in observer mode: like the window, nothing that deploys or rolls back.
MainActor.assumeIsolated {
    let st = Store()
    st.items[.vercel] = [item(changed: true, commits: 1)]
    let normal = PaletteCommands.all(st).map(\.id)
    expect("palette offers deploy, rollback and deploy all",
           normal.contains("deploy|vercel/app") && normal.contains("rollback|vercel/app") && normal.contains("action.deployChanged"), true)
    st.teamObserver = true
    let looking = PaletteCommands.all(st).map(\.id)
    expect("observer: no deploy or rollback in the palette",
           looking.contains { $0.hasPrefix("deploy|") || $0.hasPrefix("rollback|") || $0 == "action.deployChanged" }, false)
    expect("observer: the log is still there", looking.contains("log|vercel/app"), true)
}


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
    st.selectChanged(.vercel, among: ["vercel/zzz"])
    expect("select changed only among the rows shown", st.selected(.vercel).count, 0)
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

// Settings formats (LOG-068/074/118) and small guards.
let guardJSON = #"{"enabled":true,"lastActions":[{"broken":1}],"allowances":[{"platform":"vercel","project":"web","expiresAt":1800000000000},{"platform":"render","project":"api","expiresAt":"2028-01-15T08:00:00Z"},{"nope":true}]}"#
if let g = try? JSONDecoder().decode(GuardStatus.self, from: Data(guardJSON.utf8)) {
    expect("guard: milliseconds read as seconds", g.allowances.first?.expiresAt ?? 0, 1_800_000_000.0)
    expect("guard: ISO date read", g.allowances.count == 2 && g.allowances[1].expiresAt > 1_800_000_000, true)
    expect("guard: a broken action is skipped", g.lastActions.count, 0)
} else { expect("guard status decodes", false, true) }
let afJSON = #"{"routine":"trig","token":true,"scheduled":false,"fires":[{"at":1,"project":"a","status":"fired"},{"at":"x"}]}"#
expect("autofix settings: a broken fire is skipped", (try? JSONDecoder().decode(AutofixStatus.self, from: Data(afJSON.utf8)))?.fires.count ?? -1, 1)
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
expect("settings fire has error and id", fire(#"{"fires":[{"at":2,"project":"a","status":"failed","error":"HTTP 500"}]}"#).fires.map { "\($0.error ?? "") \($0.id)" }, ["HTTP 500 a-2.0"])
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

    let ci = Store()
    var b = item(changed: true, commits: 1); b.repo = "me/app"; b.selected = true
    ci.items[.vercel] = [b]
    ci.deploySelected(.vercel, whenGreen: true)
    spin { ci.items[.vercel]![0].state == .running(L("waiting for checks", "wartet auf Checks")) }
    expect("waiting for CI counts as busy", ci.deploysBusy, true)
    ci.cancel(ci.items[.vercel]![0])
    spin { !ci.items[.vercel]![0].state.isActive }
    expect("CI wait cancelled", "\(ci.items[.vercel]![0].state)", "failed(\"\(L("Cancelled", "Abgebrochen"))\")")

    Tool.testRunner = nil
    Store.pollNanos = 6_000_000_000
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
var snapDE = snapEN; snapDE.language = "de"
expect("a language switch is a change for the widgets", snapEN.sameContent(as: snapDE), false)
expect("only the time is not", snapEN.sameContent(as: DeploySnapshot(at: .distantPast, demo: false, waitingProjects: 1, waitingCommits: 1, waitingPRs: 0,
                                                                     building: 0, failed: 0, saving: nil, projects: [], language: "en")), true)
// Settings: a pasted repo address, the hand-over list with PR states.
expect("team: owner/repo stays", TeamSettings.ownerRepo(" me/app ") ?? "", "me/app")
expect("team: a github.com address", TeamSettings.ownerRepo("https://github.com/me/app.git") ?? "", "me/app")
expect("team: a git remote", TeamSettings.ownerRepo("git@github.com:me/app.git") ?? "", "me/app")
expect("team: a page of the repo", TeamSettings.ownerRepo("github.com/me/app/tree/main") ?? "", "me/app")
expect("team: no slash is no repo", TeamSettings.ownerRepo("app") == nil, true)
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

print("")
if fails == 0 { print("All app tests passed.") } else { print("\(fails) failed."); exit(1) }
