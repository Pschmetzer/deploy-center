// Deploy Center — Reading a build log: where it went wrong, and a prompt to hand it to Claude.

import Foundation

enum LogTools {
    /// Words that mark a failing line in the logs of npm, pnpm, tsc, pip, Docker, Vercel and Render.
    /// Matched as whole words, so `ErrorBoundary.tsx` or `onError` is not a failure.
    private static let errorPattern = try! NSRegularExpression(
        pattern: #"\b(error|errors|failed|failure|fatal|exception|traceback)\b|\berr!|cannot find|not found|exited with \d+"#,
        options: [.caseInsensitive])
    /// Good news and noise that contain those words.
    private static let harmless = try! NSRegularExpression(
        pattern: #"\b(0|no|zero) (errors?|failed|failures?)\b|\berrors?: 0\b|\bfailed: 0\b|cache not found|build cache|no cache found|\bif not found\b|deprecat|\bwarn(ing)?\b"#,
        options: [.caseInsensitive])

    static func isErrorLine(_ line: String) -> Bool {
        let r = NSRange(line.startIndex..., in: line)
        guard errorPattern.firstMatch(in: line, range: r) != nil else { return false }
        return harmless.firstMatch(in: line, range: r) == nil
    }

    /// Index of the first line that looks like the cause (the first error, not the cascade after it).
    static func firstErrorLine(_ lines: [String]) -> Int? { lines.firstIndex(where: isErrorLine) }

    /// Keys and tokens a build may print, replaced before a log leaves the app (clipboard, prompt).
    private static let secrets: [(NSRegularExpression, String)] = [
        (#"\b(gh[pousr]_[A-Za-z0-9]{20,}|github_pat_[A-Za-z0-9_]{20,})"#, "[GITHUB TOKEN]"),
        (#"\bsk-[A-Za-z0-9_-]{16,}"#, "[API KEY]"),
        (#"\brnd_[A-Za-z0-9]{16,}"#, "[RENDER KEY]"),
        (#"\bAKIA[0-9A-Z]{16}\b"#, "[AWS KEY]"),
        (#"\bxox[abprs]-[A-Za-z0-9-]{10,}"#, "[SLACK TOKEN]"),
        (#"\beyJ[A-Za-z0-9_-]{10,}\.[A-Za-z0-9_-]{10,}\.[A-Za-z0-9_-]{10,}"#, "[JWT]"),
        (#"(?i)\b(bearer|basic)\s+[A-Za-z0-9._~+/=-]{8,}"#, "$1 [HIDDEN]"),
        (#"(?i)\b([A-Z0-9_]*(token|secret|password|passwd|api_?key|private_?key)[A-Z0-9_]*)(\s*[=:]\s*)("[^"]*"|'[^']*'|\S+)"#, "$1$3[HIDDEN]"),
        (#"(?i)(://[^/\s:@]+:)[^@\s/]+@"#, "$1[HIDDEN]@"),
        (#"\b[A-Za-z0-9._%+-]+@[A-Za-z0-9.-]+\.[A-Za-z]{2,}\b"#, "[EMAIL]"),
    ].map { (try! NSRegularExpression(pattern: $0.0), $0.1) }

    static func maskSecrets(_ text: String) -> String {
        secrets.reduce(text) { t, s in s.0.stringByReplacingMatches(in: t, range: NSRange(t.startIndex..., in: t), withTemplate: s.1) }
    }

    private static let ansi = try! NSRegularExpression(pattern: #"\u001B\[[0-9;?]*[ -/]*[@-~]"#)
    /// Colour codes out, and a line of minified code cut to something a reader (or Claude) can use.
    static func clean(_ line: String, max: Int = 400) -> String {
        let l = ansi.stringByReplacingMatches(in: line, range: NSRange(line.startIndex..., in: line), withTemplate: "")
        return l.count > max ? String(l.prefix(max)) + " …" : l
    }

    /// A Markdown fence longer than any run of backticks in the text, so the log cannot close it.
    static func fence(for text: String) -> String {
        var longest = 0, run = 0
        for ch in text { if ch == "`" { run += 1; longest = Swift.max(longest, run) } else { run = 0 } }
        return String(repeating: "`", count: Swift.max(3, longest + 1))
    }

    /// A ready prompt: what failed, where, and the log's tail around the first error. Secrets masked.
    static func claudePrompt(name: String, repo: String?, ref: String?, sha: String?, message: String?, log: String) -> String {
        let lines = log.components(separatedBy: "\n").map { clean($0) }
        let from = Swift.max(0, (firstErrorLine(lines) ?? Swift.max(0, lines.count - 40)) - 10)
        let excerpt = maskSecrets(lines[from..<Swift.min(lines.count, from + 80)].joined(separator: "\n"))
        var head = "The deploy of \"\(name)\" failed."
        if let repo { head += " Repo: \(repo)" + (ref.map { " (\($0))" } ?? "") + "." }
        if let sha { head += " Commit: \(sha)." }
        if let message, !message.isEmpty { head += " Status: \(maskSecrets(message))." }
        let f = fence(for: excerpt)
        return head + "\n\nBuild log (excerpt around the first error):\n\(f)\n\(excerpt)\n\(f)\n\nFind the cause and propose a fix."
    }
}

extension LogTools {
    /// What is about to go live, as Markdown for a release mail or a chat message: features, fixes,
    /// the rest, and bot commits last. A "feat:"/"fix(x):" prefix decides the group and is dropped.
    static func releaseNotes(name: String, commits: [Details.Commit]) -> String {
        let human = commits.filter { !($0.bot ?? false) }, bots = commits.filter { $0.bot ?? false }
        func split(_ msg: String) -> (kind: String?, text: String) {
            guard let m = conventional.firstMatch(in: msg, range: NSRange(msg.startIndex..., in: msg)),
                  let k = Range(m.range(at: 1), in: msg), let rest = Range(m.range(at: 2), in: msg) else { return (nil, msg) }
            return (msg[k].lowercased(), String(msg[rest]))
        }
        func line(_ c: Details.Commit, _ text: String) -> String {
            "- \(text)" + (c.pr.map { " (#\($0)" + ")" } ?? "") + (c.author.map { " – \($0)" } ?? "")
        }
        let parsed = human.map { ($0, split($0.msg)) }
        // Without any prefix the list stays as it was: one plain list.
        guard parsed.contains(where: { $0.1.kind != nil }) else {
            var out = "## \(name)\n" + human.map { line($0, $0.msg) }.joined(separator: "\n")
            if !bots.isEmpty { out += "\n\nDependency updates:\n" + bots.map { line($0, $0.msg) }.joined(separator: "\n") }
            return out
        }
        var out = "## \(name)"
        for (title, kinds) in [("Features", ["feat"]), ("Fixes", ["fix"])] {
            let these = parsed.filter { kinds.contains($0.1.kind ?? "") }
            if !these.isEmpty { out += "\n\n### \(title)\n" + these.map { line($0.0, $0.1.text) }.joined(separator: "\n") }
        }
        let rest = parsed.filter { !["feat", "fix"].contains($0.1.kind ?? "") }
        if !rest.isEmpty { out += "\n\n### Other\n" + rest.map { line($0.0, $0.1.kind == nil ? $0.0.msg : $0.1.text) }.joined(separator: "\n") }
        if !bots.isEmpty { out += "\n\n### Dependency updates\n" + bots.map { line($0, $0.msg) }.joined(separator: "\n") }
        return out
    }
    private static let conventional = try! NSRegularExpression(pattern: #"^([A-Za-z]+)(?:\([^)]*\))?!?:\s*(.+)$"#)
}

/// Demo mode: names, repos and domains are replaced by stable stand-ins, so a screenshot or a
/// screen recording can be shared without showing real projects (the repo is public).
enum Demo {
    static var on: Bool { UserDefaults.standard.bool(forKey: "demoMode") }
    private static let words = ["Atlas", "Birch", "Cedar", "Delta", "Ember", "Fjord", "Garnet", "Harbor", "Iris", "Juno",
                                "Kite", "Lumen", "Maple", "Nova", "Onyx", "Pixel", "Quartz", "River", "Sage", "Tundra",
                                "Umber", "Vale", "Willow", "Xenon", "Yarrow", "Zephyr", "Alder", "Basalt", "Comet", "Dune",
                                "Elm", "Flint", "Glacier", "Heron", "Indigo", "Jade", "Kelp", "Lark", "Mesa", "Nimbus"]
    /// The same input always gives the same stand-in.
    static func mask(_ s: String) -> String {
        guard on, !s.isEmpty else { return s }
        var h: UInt64 = 1469598103934665603
        for b in s.utf8 { h = (h ^ UInt64(b)) &* 1099511628211 }
        // 40 words × 900 numbers: two of 40 projects share a stand-in in about 2 % of cases (was 35 %).
        return "\(words[Int(h % UInt64(words.count))])-\(Int((h / UInt64(words.count)) % 900) + 100)"
    }
}
