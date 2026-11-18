// Deploy Center — From an error text to the matching section of TROUBLESHOOTING.md.

import Foundation

enum ErrorHelp {
    /// A phrase of the message (lowercase) and the anchor of its section in docs/TROUBLESHOOTING.md.
    /// The tests check that every anchor still exists in both languages' files.
    static let topics: [(needle: String, anchor: String)] = [
        ("install the vercel cli", "connect-vercel--install-the-vercel-cli-then-log-in-once-in-terminal"),
        ("log in once in terminal", "connect-vercel--log-in-once-in-terminal-the-app-uses-that-login"),
        ("several vercel teams", "several-vercel-teams-choose-one-deploys-vercel-team-id"),
        ("ignored build step", "skipped-or-canceled-by-vercel-ignored-build-step"),
        ("github cli is not logged in", "github-cli-is-not-logged-in-so-the-waiting-commits-and-prs-cannot-be-counted-in-terminal-gh-auth-login"),
        ("hourly budget", "githubs-hourly-budget-is-nearly-spent-"),
        ("the render key is wrong", "---http-401-the-render-key-is-wrong-or-expired-deploys-render-set-key"),
        ("rate limit: try again", "---http-429-rate-limit-try-again-in-a-minute"),
        ("deploy window closed", "deploy-window-closed"),
        ("no anthropic api key", "no-anthropic-api-key-run-pbpaste--deploys-ai-set-key-or-set-anthropic_api_key"),
        ("is being started already", "project-is-being-started-already-wait-a-minute"),
    ]

    static let base = "https://github.com/Pschmetzer/deploy-center/blob/main/docs/"

    /// The link for an error text: its section when one matches, else the top of the page. nil for an empty text.
    static func url(for message: String, german: Bool = Locale.preferredLanguages.first?.hasPrefix("de") == true) -> URL? {
        let m = message.lowercased()
        guard !m.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else { return nil }
        let file = german ? "TROUBLESHOOTING.de.md" : "TROUBLESHOOTING.md"
        let anchor = topics.first(where: { m.contains($0.needle) })?.anchor
        return URL(string: base + file + (anchor.map { "#" + $0 } ?? ""))
    }

    /// GitHub's anchor for a heading: lowercase, only letters, digits, `_`, `-` and spaces, spaces to hyphens.
    static func slug(_ heading: String) -> String {
        String(heading.lowercased().unicodeScalars.filter { CharacterSet.alphanumerics.contains($0) || $0 == "_" || $0 == "-" || $0 == " " }
            .map(Character.init)).replacingOccurrences(of: " ", with: "-")
    }
}
