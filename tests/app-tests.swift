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

print("")
if fails == 0 { print("All app tests passed.") } else { print("\(fails) failed."); exit(1) }
