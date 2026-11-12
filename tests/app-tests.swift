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
// Two sleeps of 30 s: "at once" is anything well below that, also on a busy CI runner.
expect("killTree closes the pipe at once", Date().timeIntervalSince(t0) < 10, true)
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
expect("autofix status without scheduled", (try? JSONDecoder().decode(AutofixStatus.self, from: Data(#"{"routine":"trig_1","token":true,"fires":[]}"#.utf8)))?.routine ?? "nil", "trig_1")
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
final class Box<T>: @unchecked Sendable { var value: T?; init() {} }
func waitFor<T>(_ f: @escaping @Sendable () async -> T) -> T {
    let sem = DispatchSemaphore(value: 0), box = Box<T>()
    Task.detached { box.value = await f(); sem.signal() }
    sem.wait()
    return box.value!
}
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

// --- CI lane: palette by item state, Claude nudge, the status models, the deploys JSON contract ---

// The palette: which verbs a row gets depends on its state; hidden rows and real names in demo mode stay out.
MainActor.assumeIsolated {
    let st = Store()
    var busy = item(changed: true); busy.state = .running("building")
    var linked = Item(id: "srv-9", name: "linked", detail: "", platform: .render, deployable: false, auto: false, note: nil, link: "https://linked.example")
    linked.kind = "static_site"
    let secret = Item(id: "secret", name: "secret", detail: "", platform: .vercel, deployable: true, auto: false, note: nil, link: nil)
    st.items[.vercel] = [busy, secret]
    st.items[.render] = [linked]
    st.hidden = [Store.key(secret)]
    let ids = PaletteCommands.all(st).map(\.id)
    expect("palette: a running row has no deploy or rollback", ids.contains("deploy|vercel/app") || ids.contains("rollback|vercel/app"), false)
    expect("palette: a running row can still show its log", ids.contains("log|vercel/app"), true)
    expect("palette: stop all appears while something runs", ids.contains("action.stopAll"), true)
    expect("palette: not deployable, no deploy", ids.contains("deploy|render/srv-9"), false)
    expect("palette: a link gives open", "\(ids.contains("open|render/srv-9")) \(ids.contains("open|vercel/app"))", "true false")
    expect("palette: Vercel and Render rows have a dashboard", "\(ids.contains("dashboard|vercel/app")) \(ids.contains("dashboard|render/srv-9"))", "true true")
    expect("palette: a hidden row is not offered", ids.contains { $0.hasSuffix("|vercel/secret") }, false)
    UserDefaults.standard.set(true, forKey: "demoMode")
    let demo = PaletteCommands.all(st)
    expect("palette, demo mode: the real name is not searchable",
           demo.contains { c in c.texts.contains { $0.contains("linked") } || c.title.contains("linked") }, false)
    expect("palette, demo mode: the stand-in is", demo.contains { $0.texts.contains("log " + Demo.mask("linked")) }, true)
    UserDefaults.standard.removeObject(forKey: "demoMode")
    expect("palette verbs: every verb has an English and a German word",
           PaletteVerb.allCases.allSatisfy { !$0.words.en.isEmpty && !$0.words.de.isEmpty }, true)
    expect("palette verbs: only deploy and rollback ask first", PaletteVerb.allCases.filter(\.asks).map(\.rawValue), ["deploy", "rollback"])
}

// The Claude nudge: stored only when it changes; once dismissed, refresh leaves it alone (and reads no config).
let nudgeKeys = [ClaudeNudge.wantedKey, ClaudeNudge.dismissedKey]
let nudgeBefore = nudgeKeys.map { UserDefaults.standard.object(forKey: $0) }
ClaudeNudge.store(wanted: true)
expect("nudge: stored", UserDefaults.standard.bool(forKey: ClaudeNudge.wantedKey), true)
ClaudeNudge.store(wanted: false)
expect("nudge: cleared", UserDefaults.standard.bool(forKey: ClaudeNudge.wantedKey), false)
UserDefaults.standard.set(true, forKey: ClaudeNudge.wantedKey)
UserDefaults.standard.set(true, forKey: ClaudeNudge.dismissedKey)
waitFor { await ClaudeNudge.refresh() }
expect("nudge: dismissed, refresh changes nothing", UserDefaults.standard.bool(forKey: ClaudeNudge.wantedKey), true)
for (k, v) in zip(nudgeKeys, nudgeBefore) { if let v { UserDefaults.standard.set(v, forKey: k) } else { UserDefaults.standard.removeObject(forKey: k) } }

// The status models. Missing fields are read with defaults (main, "Settings parts read an answer
// with fields missing"), so only the shape that matters is checked here.
let dec = JSONDecoder()
func decodes<T: Decodable>(_ t: T.Type, _ s: String) -> Bool { (try? dec.decode(t, from: Data(s.utf8))) != nil }
expect("GuardStatus: a minimal answer", decodes(GuardStatus.self, #"{"enabled":false,"lastActions":[],"allowances":[]}"#), true)
let team = try? dec.decode(TeamConfig.self, from: Data(#"{"readonly":{"value":true,"from":"x"},"sources":[],"projects":{"b":{"approvals":{"value":1,"from":"x"}},"a":{"approvals":{"value":3,"from":"x"}},"c":{"approvals":{"value":0,"from":"x"}},"d":{}}}"#.utf8))
expect("TeamConfig.guarded: only approvals above 0, by name", team.map { $0.guarded.map { "\($0.name)=\($0.approvals)" } } ?? [], ["a=3", "b=1"])

// The contract: what `deploys` really answers (tests/contract-json.sh), read with the app's own models.
if let dir = ProcessInfo.processInfo.environment["DC_CONTRACT"] {
    func load<T: Decodable>(_ t: T.Type, _ f: String) -> T? {
        guard let d = FileManager.default.contents(atPath: dir + "/" + f) else { expect("contract: \(f) exists", false, true); return nil }
        do { return try dec.decode(t, from: d) } catch { expect("contract: \(f) decodes as \(t)", "\(error)", "no error"); return nil }
    }
    if let g = load(GuardStatus.self, "guard.json") {
        expect("contract guard: actions and allowances", "\(g.lastActions.map(\.action)) \(g.allowances.map(\.platform).sorted())", "[\"off\", \"failed\"] [\"all\", \"vercel\"]")
        expect("contract guard: the error of a failed switch", g.lastActions.last?.error ?? "-", "could not disconnect web")
    }
    if let a = load(AutofixStatus.self, "autofix.json") {
        expect("contract autofix: routine, token, newest first", "\(a.routine ?? "-") \(a.token) \(a.fires.map(\.project))", "routine-1 true [\"web\", \"api\"]")
        expect("contract autofix: the PR and the merged commit", "\(a.fires.first?.pr ?? 0) \(a.fires.first?.mergedSha ?? "-")", "9 ffff999")
    }
    if let c = load(TeamConfig.self, "config.json") {
        expect("contract config: not an observer, web needs 2 approvals", "\(c.readonly.value) \(c.guarded.map { "\($0.name)=\($0.approvals)" })", "false [\"web=2\"]")
    }
    if let w = load(WindowReply.self, "window.json") {
        expect("contract window: closed, with the reason", "\(w.denied) \(w.reason ?? "-")", "true freeze")
    }
} else {
    print("skip contract tests (DC_CONTRACT not set; tests/app-tests.sh sets it)")
}

print("")
if fails == 0 { print("All app tests passed.") } else { print("\(fails) failed."); exit(1) }
