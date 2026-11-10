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

// The updater: version order, rate limit, trusted downloads, where the app lives, and the swap script.
expect("0.10.0 is newer than 0.9.1", Updater.isNewer("0.10.0", than: "0.9.1"), true)
expect("same version is not newer", Updater.isNewer("0.7.0", than: "0.7.0"), false)
expect("no downgrade", Updater.isNewer("0.6.9", than: "0.7.0"), false)
expect("429 is the rate limit", Updater.rateLimit(status: 429, remaining: nil, reset: nil) != nil, true)
expect("403 with none left is the rate limit", Updater.rateLimit(status: 403, remaining: "0", reset: "0") != nil, true)
expect("403 with requests left is not", Updater.rateLimit(status: 403, remaining: "12", reset: nil) == nil, true)
expect("asset of this repo", Updater.trustedAsset(URL(string: "https://github.com/\(Updater.repo)/releases/download/v1/a.zip")!), true)
expect("asset elsewhere", Updater.trustedAsset(URL(string: "https://example.com/\(Updater.repo)/releases/download/v1/a.zip")!), false)
expect("asset over http", Updater.trustedAsset(URL(string: "http://github.com/\(Updater.repo)/releases/download/v1/a.zip")!), false)
expect("asset of another repo", Updater.trustedAsset(URL(string: "https://github.com/someone/else/releases/download/v1/a.zip")!), false)
expect("team id shape", [Updater.validTeam("AB12CD34EF"), Updater.validTeam("ab12cd34ef"), Updater.validTeam("AB\" or 1")], [true, false, false])
expect("requirement pins team and bundle", Updater.requirement(team: "AB12CD34EF").contains("leaf[subject.OU] = \"AB12CD34EF\"")
       && Updater.requirement(team: "AB12CD34EF").contains("identifier \"\(Updater.bundleID)\""), true)
expect("translocated app is refused",
       Updater.locationProblem(URL(fileURLWithPath: "/private/var/folders/x/AppTranslocation/1/d/Deploy Center.app")) != nil, true)

func swapRun(_ name: String, newExists: Bool) -> (kept: String?, old: Bool, tmp: Bool, started: String?) {
    let fm = FileManager.default
    let base = fm.temporaryDirectory.appendingPathComponent("dc-swap \(UUID().uuidString) \(name)")
    let place = base.appendingPathComponent("Apps $HOME `x` \"q\" 'o'")
    let tmp = base.appendingPathComponent("tmp $(touch pwned) ;")
    let target = place.appendingPathComponent("Deploy Center.app"), new = tmp.appendingPathComponent("Deploy Center.app")
    try? fm.createDirectory(at: target, withIntermediateDirectories: true)
    try? "old".write(to: target.appendingPathComponent("v"), atomically: true, encoding: .utf8)
    try? fm.createDirectory(at: tmp, withIntermediateDirectories: true)
    if newExists {
        try? fm.createDirectory(at: new, withIntermediateDirectories: true)
        try? "new".write(to: new.appendingPathComponent("v"), atomically: true, encoding: .utf8)
    }
    // A stale .old from an earlier run must not swallow the app.
    try? fm.createDirectory(at: URL(fileURLWithPath: target.path + ".old"), withIntermediateDirectories: true)
    let started = base.appendingPathComponent("started")
    let opener = base.appendingPathComponent("opener.sh")
    try? "#!/bin/sh\nprintf '%s' \"$1\" > \"$(dirname \"$0\")/started\"\n".write(to: opener, atomically: true, encoding: .utf8)
    try? fm.setAttributes([.posixPermissions: 0o755], ofItemAtPath: opener.path)
    let dead = Process(); dead.executableURL = URL(fileURLWithPath: "/usr/bin/true"); try? dead.run(); dead.waitUntilExit()
    let sh = Process(); sh.executableURL = URL(fileURLWithPath: "/bin/sh")
    sh.arguments = Updater.swapArguments(pid: dead.processIdentifier, target: target.path, new: new.path, tmp: tmp.path, opener: opener.path)
    sh.currentDirectoryURL = base
    try? sh.run(); sh.waitUntilExit()
    let kept = try? String(contentsOf: target.appendingPathComponent("v"), encoding: .utf8)
    let result = (kept, fm.fileExists(atPath: target.path + ".old"), fm.fileExists(atPath: tmp.path),
                  try? String(contentsOf: started, encoding: .utf8))
    expect("\(name): no command ran from a path", fm.fileExists(atPath: base.appendingPathComponent("pwned").path)
           || fm.fileExists(atPath: "pwned"), false)
    try? fm.removeItem(at: base)
    return result
}
let ok = swapRun("swap", newExists: true)
expect("swap: new app in place", ok.kept ?? "nil", "new")
expect("swap: .old removed", ok.old, false)
expect("swap: temp removed", ok.tmp, false)
expect("swap: the app is started", ok.started?.hasSuffix("/Deploy Center.app") ?? false, true)
let back = swapRun("rollback", newExists: false)
expect("rollback: old app restored", back.kept ?? "nil", "old")
expect("rollback: .old gone", back.old, false)
expect("rollback: the old app is started", back.started?.hasSuffix("/Deploy Center.app") ?? false, true)

// A folder the app cannot write to is refused before anything is downloaded.
do {
    let fm = FileManager.default
    let ro = fm.temporaryDirectory.appendingPathComponent("dc-ro \(UUID().uuidString)")
    let app = ro.appendingPathComponent("Deploy Center.app")
    try? fm.createDirectory(at: app, withIntermediateDirectories: true)
    expect("writable folder is fine", Updater.locationProblem(app) == nil, true)
    try? fm.setAttributes([.posixPermissions: 0o555], ofItemAtPath: ro.path)
    expect("read-only folder is refused", Updater.locationProblem(app) != nil, true)
    try? fm.setAttributes([.posixPermissions: 0o755], ofItemAtPath: ro.path)
    try? fm.removeItem(at: ro)
}

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

// Autofix in the rows: old and new status shapes, each state and when it ends by itself.
func fire(_ json: String) -> AutofixReport { try! JSONDecoder().decode(AutofixReport.self, from: Data(json.utf8)) }
let oldShape = fire(#"{"routine":"trig_1","token":true,"scheduled":false,"fires":[{"at":100,"project":"app","platform":"vercel","status":"fired","session":"https://claude.ai/code/s1","pr":7,"mergedSha":null},{"broken":true}]}"#)
expect("old status decodes, broken fire skipped", "\(oldShape.fires.count) \(oldShape.fires[0].prNumber ?? 0) \(oldShape.ready)", "1 7 true")
let newShape = fire(#"{"routine":null,"token":false,"fires":[{"at":100,"project":"app","platform":"vercel","status":"fired","prNumber":9,"prState":"OPEN","prUrl":"https://github.com/me/app/pull/9"}]}"#)
expect("new status decodes", "\(newShape.fires[0].prNumber ?? 0) \(newShape.fires[0].prState ?? "") \(newShape.ready)", "9 open false")
expect("empty status decodes", fire("{}").fires.count, 0)

func failedItem(_ p: Platform = .vercel) -> Item { var i = item(p, changed: false, last: "aaaaaaa1", head: "aaaaaaa1"); i.lastState = p == .vercel ? "ERROR" : "build_failed"; return i }
typealias F = AutofixReport.Fire
expect("fixing while failed", RowAutofix.of(failedItem(), F(at: 1, project: "app", platform: "vercel", status: "fired", session: "https://claude.ai/code/s1")) == .fixing(session: URL(string: "https://claude.ai/code/s1")), true)
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
    st.autofix = AutofixReport(routine: "trig_1", token: true, fires: [F(at: 1, project: "app", platform: "vercel", status: "fired")])
    st.items[.vercel] = [failedItem()]
    expect("menu bar count", st.fixingCount, 1)
    st.autofix = AutofixReport(routine: "trig_1", token: true, fires: [])
    expect("button on a failed row", st.canFixWithClaude(st.items[.vercel]![0]), true)
    st.allowances = [AutoDeployAllowance(platform: "vercel", project: "app", expiresAt: Date().addingTimeInterval(-60))]
    expect("expired allowance ignored", st.allowance(st.items[.vercel]![0]) == nil && st.activeAllowances.isEmpty, true)
    UserDefaults.standard.removeObject(forKey: "autofixPreselected")
}

print("")
if fails == 0 { print("All app tests passed.") } else { print("\(fails) failed."); exit(1) }
