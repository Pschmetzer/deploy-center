// App tests, round 15: more known build failures, token limits, unread failures. Called from tests/app/main.swift.

import AppKit

@MainActor func suite_round15_ux() {
    let logs: [(String, String)] = [
        ("module", "Module not found: Can't resolve './Button' in '/src'"),
        ("module", "Error: Cannot find module 'left-pad'"),
        ("typescript", "src/app.ts(3,5): error TS2345: Argument of type"),
        ("typescript", "Failed to compile.\n\nType error: Property 'x' does not exist"),
        ("disk", "write /tmp/x: ENOSPC: no space left on device"),
        ("timeout", "Build timed out after 45 minutes"),
        ("prisma", "Error: @prisma/client did not initialize yet. Please run \"prisma generate\""),
        ("python", "ERROR: Could not find a version that satisfies the requirement foo==9"),
        ("python", "ERROR: ResolutionImpossible: for help visit"),
        ("ratelimit", "npm ERR! code E429 ... 429 Too Many Requests"),
        ("dns", "getaddrinfo ENOTFOUND registry.example.invalid"),
    ]
    for (id, log) in logs { expect("pattern: \(id) in “\(log.prefix(28))”", ErrorPatterns.match(log)?.id ?? "none", id) }
    expect("pattern: all ids are unique", Set(ErrorPatterns.all.map(\.id)).count, ErrorPatterns.all.count)
    expect("pattern: the old ones still win", ErrorPatterns.match("heap out of memory, then Cannot find module")?.id ?? "", "memory")
    expect("pattern: plain text matches none", ErrorPatterns.match("Build completed in 41s") == nil, true)

    expect("cap: Tsd.", ClaudeAI.parseCap("5 Tsd.") ?? 0, 5_000)
    expect("cap: tsd", ClaudeAI.parseCap("500tsd") ?? 0, 500_000)
    expect("cap: a bare t is no suffix", ClaudeAI.parseCap("2t") == nil, true)
    expect("cap: T is no suffix", ClaudeAI.parseCap("2T") == nil, true)
    expect("cap: plain number with a trailing dot", ClaudeAI.parseCap("1000.") ?? 0, 1000)

    let t0 = Date(timeIntervalSince1970: 1_000)
    let list = [Store.Message(date: t0.addingTimeInterval(10), text: "a", ok: false), Store.Message(date: t0.addingTimeInterval(20), text: "b", ok: true),
                Store.Message(date: t0.addingTimeInterval(-5), text: "c", ok: false)]
    expect("unread: only newer failures", Store.unreadFailures(list, since: t0), 1)
    expect("unread: nothing after the newest", Store.unreadFailures(list, since: t0.addingTimeInterval(30)), 0)
}
