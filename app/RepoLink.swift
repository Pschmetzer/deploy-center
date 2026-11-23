// Deploy Center — "Link repo": for a project the platform has no Git source for, the person names
// the repo. Kept on this Mac only (UserDefaults), used for the details and the waiting commits.

import Foundation

enum RepoLink {
    static let key = "repoLinks"

    /// "owner/name" for GitHub, "gitlab.com/group/name" for another host; nil for text that is no repo.
    /// Accepts the URL, the SSH form (git@github.com:o/n.git) and the short form.
    static func normalize(_ raw: String) -> String? {
        var t = raw.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !t.isEmpty, !t.contains(" ") else { return nil }
        if t.hasPrefix("git@") {
            t = String(t.dropFirst(4))
            if let c = t.firstIndex(of: ":") { t.replaceSubrange(c...c, with: "/") }
        }
        for p in ["https://", "http://", "ssh://"] where t.hasPrefix(p) { t = String(t.dropFirst(p.count)) }
        while t.hasSuffix("/") { t.removeLast() }
        if t.hasSuffix(".git") { t = String(t.dropLast(4)) }
        var parts = t.split(separator: "/").map(String.init)
        guard !parts.isEmpty else { return nil }
        var host: String?
        if parts[0].contains(".") { host = parts.removeFirst().lowercased() }
        guard parts.count >= 2 else { return nil }
        let ok = CharacterSet(charactersIn: "abcdefghijklmnopqrstuvwxyzABCDEFGHIJKLMNOPQRSTUVWXYZ0123456789-_.")
        guard parts.allSatisfy({ !$0.isEmpty && $0.unicodeScalars.allSatisfy(ok.contains) && $0 != "." && $0 != ".." }) else { return nil }
        if host == nil || host == "github.com" || host == "www.github.com" {
            guard parts.count == 2 else { return nil }
            return parts.joined(separator: "/")
        }
        return host! + "/" + parts.joined(separator: "/")
    }

    static func load(_ d: UserDefaults = .standard) -> [String: String] { (d.dictionary(forKey: key) as? [String: String]) ?? [:] }
    static func save(_ links: [String: String], _ d: UserDefaults = .standard) { d.set(links, forKey: key) }
}
