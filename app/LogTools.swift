// Deploy Center — Reading a build log: where it went wrong, and a prompt to hand it to Claude.

import Foundation

enum LogTools {
    /// Words that mark a failing line in the logs of npm, pnpm, tsc, pip, Docker, Vercel and Render.
    static let errorWords = ["error", "err!", "failed", "fatal", "cannot find", "not found", "exception", "traceback"]

    static func isErrorLine(_ line: String) -> Bool {
        let l = line.lowercased()
        // "0 errors" and "no errors" are good news, not a failure.
        if l.contains("0 errors") || l.contains("no errors") || l.contains("errors: 0") { return false }
        return errorWords.contains { l.contains($0) }
    }

    /// Index of the first line that looks like the cause (the first error, not the cascade after it).
    static func firstErrorLine(_ lines: [String]) -> Int? { lines.firstIndex(where: isErrorLine) }

    /// A ready prompt: what failed, where, and the log's tail around the first error.
    static func claudePrompt(name: String, repo: String?, ref: String?, sha: String?, message: String?, log: String) -> String {
        let lines = log.components(separatedBy: "\n")
        let from = max(0, (firstErrorLine(lines) ?? max(0, lines.count - 40)) - 10)
        let excerpt = lines[from..<min(lines.count, from + 80)].joined(separator: "\n")
        var head = "The deploy of \"\(name)\" failed."
        if let repo { head += " Repo: \(repo)" + (ref.map { " (\($0))" } ?? "") + "." }
        if let sha { head += " Commit: \(sha)." }
        if let message, !message.isEmpty { head += " Status: \(message)." }
        return head + "\n\nBuild log (excerpt around the first error):\n```\n\(excerpt)\n```\n\nFind the cause and propose a fix."
    }
}

extension LogTools {
    /// What is about to go live, as Markdown for a release mail or a chat message. Bot commits last.
    static func releaseNotes(name: String, commits: [Details.Commit]) -> String {
        let human = commits.filter { !($0.bot ?? false) }, bots = commits.filter { $0.bot ?? false }
        func line(_ c: Details.Commit) -> String {
            "- \(c.msg)" + (c.pr.map { " (#\($0))" } ?? "") + (c.author.map { " – \($0)" } ?? "")
        }
        var out = "## \(name)\n" + human.map(line).joined(separator: "\n")
        if !bots.isEmpty { out += "\n\nDependency updates:\n" + bots.map(line).joined(separator: "\n") }
        return out
    }
}

/// Demo mode: names, repos and domains are replaced by stable stand-ins, so a screenshot or a
/// screen recording can be shared without showing real projects (the repo is public).
enum Demo {
    static var on: Bool { UserDefaults.standard.bool(forKey: "demoMode") }
    private static let words = ["Atlas", "Birch", "Cedar", "Delta", "Ember", "Fjord", "Garnet", "Harbor", "Iris", "Juno",
                                "Kite", "Lumen", "Maple", "Nova", "Onyx", "Pixel", "Quartz", "River", "Sage", "Tundra"]
    /// The same input always gives the same stand-in.
    static func mask(_ s: String) -> String {
        guard on, !s.isEmpty else { return s }
        var h: UInt64 = 1469598103934665603
        for b in s.utf8 { h = (h ^ UInt64(b)) &* 1099511628211 }
        return "\(words[Int(h % UInt64(words.count))])-\(Int((h / 20) % 90) + 10)"
    }
}
