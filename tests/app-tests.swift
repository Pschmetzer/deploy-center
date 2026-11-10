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
expect("summary with saving", summaryLine(wait, saved: 41), L("12 PRs waiting · \(usd0(41)) saved", "12 PRs warten · \(usd0(41)) gespart"))
expect("summary without saving", summaryLine(wait, saved: nil), L("12 PRs waiting", "12 PRs warten"))
wait.prs = 0
expect("summary without PRs", summaryLine(wait, saved: nil), L("3 projects waiting", "3 Projekte warten"))
expect("summary when all is live", summaryLine(Store.Waiting(), saved: nil), L("Everything merged is live", "Alles Gemergte ist live"))
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
expect("rate limited is not 'no PR'", RowAutofix.of(failedItem(), F(at: 1, project: "app", platform: "vercel", status: "ratelimited"), now: late) == .fixing(session: nil), true)
expect("no PR chip links the session", AgentChips.link(.noPR(session: URL(string: "https://claude.ai/code/s1")))?.absoluteString ?? "", "https://claude.ai/code/s1")
var green = failedItem(); green.lastState = "READY"
expect("fixing ends when green again", RowAutofix.of(green, F(at: 1, project: "app", platform: "vercel", status: "fired")) == nil, true)
expect("PR open", RowAutofix.of(failedItem(), F(at: 1, project: "app", platform: "vercel", status: "fired", prNumber: 4, prState: "open")) == .prOpen(number: 4, url: nil), true)
var waiting = failedItem(); waiting.changed = true; waiting.headSha = "bbbbbbb2"
expect("merged, not live", RowAutofix.of(waiting, F(at: 1, project: "app", platform: "vercel", status: "fired", prNumber: 4, mergedSha: "bbbbbbb2ffff")) == .merged(sha: "bbbbbbb2ffff", pr: 4, url: nil), true)
var shipped = waiting; shipped.lastSha = "bbbbbbb2"; shipped.changed = false
expect("merged ends once live", RowAutofix.of(shipped, F(at: 1, project: "app", platform: "vercel", status: "fired", mergedSha: "bbbbbbb2ffff")) == nil, true)
expect("fix failed too", RowAutofix.of(failedItem(), F(at: 1, project: "app", platform: "vercel", status: "skipped")) == .handedBack, true)
expect("PR closed unmerged", RowAutofix.of(failedItem(), F(at: 1, project: "app", platform: "vercel", status: "fired", prNumber: 4, prState: "closed")) == .handedBack, true)
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
expect("GitLab compare link", GitHost.compareURL(labItem)?.absoluteString ?? "", "https://gitlab.com/group/app/-/compare/aaa...main")
labItem.repo = "me/app"
expect("GitHub compare link unchanged", GitHost.compareURL(labItem)?.absoluteString ?? "", "https://github.com/me/app/compare/aaa...main")

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

print("")
if fails == 0 { print("All app tests passed.") } else { print("\(fails) failed."); exit(1) }
