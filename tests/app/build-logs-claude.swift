// App tests: build-logs-claude. Called from tests/app/main.swift.

import AppKit

@MainActor func suite_build_logs_claude() {
    // Build logs: what is a failure, what leaves the app.
    expect("cache miss is no error", LogTools.isErrorLine("Build Cache not found, building from scratch"), false)
    expect("ErrorBoundary file is no error", LogTools.isErrorLine("  src/ErrorBoundary.tsx  2.1 kB"), false)
    expect("0 failed is good news", LogTools.isErrorLine("Tests: 0 failed, 12 passed"), false)
    expect("a real error", LogTools.isErrorLine("Type error: Cannot read x"), true)
    expect("npm ERR!", LogTools.isErrorLine("npm ERR! code ELIFECYCLE"), true)
    expect("command failed", LogTools.isErrorLine("Command \"npm run build\" exited with 1"), true)
    expect("GitHub token masked", LogTools.maskSecrets("using ghp_abcdefghijklmnopqrstuvwxyz0123 now"), "using [GITHUB TOKEN] now")
    expect("cap: plain", ClaudeAI.parseCap("1000000") ?? 0, 1_000_000)
    expect("cap: dotted", ClaudeAI.parseCap("1.000.000") ?? 0, 1_000_000)
    expect("cap: Mio", ClaudeAI.parseCap("2 Mio") ?? 0, 2_000_000)
    expect("cap: k", ClaudeAI.parseCap("500k") ?? 0, 500_000)
    expect("cap: decimal comma", ClaudeAI.parseCap("1,5m") ?? 0, 1_500_000)
    expect("cap: decimal Mio", ClaudeAI.parseCap("1.5 Mio") ?? 0, 1_500_000)
    expect("cap: thousands k", ClaudeAI.parseCap("500.000k") ?? 0, 500_000_000)
    let cut = (["-----BEGIN PRIVATE KEY-----"] + (0..<100).map { "MIIEvQIBADANBgkqhkiG9w0BAQEFAASC\($0)" } + ["-----END PRIVATE KEY-----"] + (0..<50).map { "error line \($0)" }).joined(separator: "\n")
    expect("prompt: cut inside a key keeps no key", LogTools.claudePrompt(name: "x", repo: nil, ref: nil, sha: nil, message: nil, log: cut).contains("MIIEvQ"), false)
    expect("cap: junk", ClaudeAI.parseCap("abc") == nil && ClaudeAI.parseCap("0") == nil && ClaudeAI.parseCap("") == nil, true)
    expect("bearer masked", LogTools.maskSecrets("Authorization: Bearer abc.def-123456"), "Authorization: Bearer [HIDDEN]")
    for k in ["shpat_0123456789abcdef0123", "hf_abcdefghijklmnopqrstuvwx", "gsk_abcdefghijkl", "r8_abcdefghijkl", "ntn_abcdefghijkl", "nfp_abcdefghijkl", "fo1_abcdefghijkl", "pscale_tkn_abcdefghij", "napi_abcdefghijkl", "123456789:ABCdefGHIjklMNOpqrSTUvwxYZ012345678"] {
        expect("more keys masked: \(k.prefix(6))", LogTools.maskSecrets("x \(k) y").contains(k), false)
    }
    expect("OSC hyperlink removed", LogTools.clean("a\u{1B}]8;;http://evil.example\u{07}link\u{1B}]8;;\u{07}b"), "alinkb")
    expect("author and tokens count stay", LogTools.maskSecrets("author: Anna, tokens: 12"), "author: Anna, tokens: 12")
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

    // Round 12: log lines, release-note marks, budget keys, the owner check.
    expect("error-boundary file name is no error", LogTools.isErrorLine("  dist/error-boundary.js  1.2 kB"), false)
    expect("error.js file name is no error", LogTools.isErrorLine("  src/error.js"), false)
    expect("a path with error in it is no error", LogTools.isErrorLine("compiling packages/error/index.ts"), false)
    expect("plain error: still an error", LogTools.isErrorLine("error: something broke"), true)
    expect("Error at the end of a sentence", LogTools.isErrorLine("Build failed."), true)
    let g1 = Details.Commit(sha: "a", full: nil, url: nil, msg: "Tidy up", author: nil, bot: false, at: 0, pr: 7)
    expect("GitLab release notes use !", LogTools.releaseNotes(name: "web", commits: [g1], prMark: "!"), "## web\n- Tidy up (!7)")
    expect("GitHub release notes use #", LogTools.releaseNotes(name: "web", commits: [g1]), "## web\n- Tidy up (#7)")
    expect("budget key", BudgetKey.key(platform: "vercel", name: "shop"), "vercel/shop")
    expect("budget migration", BudgetKey.migrate(["shop": 5, "render/api": 3, "vercel/prj_1": 2]).sorted { $0.key < $1.key }.map { "\($0.key)=\($0.value)" },
           ["render/api=3.0", "vercel/prj_1=2.0", "vercel/shop=5.0"])
    expect("cancelling the owner check is silent", OwnerCheck.silent(.userCancel), true)
    expect("a technical failure is not silent", OwnerCheck.silent(.biometryNotAvailable), false)

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

}
