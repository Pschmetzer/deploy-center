// Deploy Center — Hover on a waiting row: who pushed, when, and how many files changed.

import Foundation

enum WaitingHover {
    /// Up to three lines: the authors, the newest commit's age, the files. Bots are named as people are.
    static func lines(_ d: Details, person: (String?) -> String? = { $0 }) -> [String] {
        var out: [String] = []
        var seen: [String] = []
        for c in d.commits { if let a = person(c.author), !a.isEmpty, !seen.contains(a) { seen.append(a) } }
        let n = d.commits.count
        if n > 0 {
            let who = seen.prefix(3).joined(separator: ", ") + (seen.count > 3 ? " …" : "")
            out.append(who.isEmpty ? plural(n, "commit", "commits") : L("\(plural(n, "commit", "commits")) by \(who)", "\(plural(n, "Commit", "Commits")) von \(who)"))
        }
        if let newest = d.commits.map(\.at).max() {
            let date = Date(timeIntervalSince1970: newest)
            out.append(L("Newest: ", "Neuester: ") + Row.ago(date))
        }
        if d.files > 0 {
            out.append(L(plural(d.files, "file", "files") + ", +\(d.additions) −\(d.deletions) lines",
                         plural(d.files, "Datei", "Dateien") + ", +\(d.additions) −\(d.deletions) Zeilen"))
        }
        return out
    }

    /// The same read the details sheet makes (shared one-minute cache), only for a project with a repo and waiting commits.
    @MainActor static func load(_ item: Item) async -> [String] {
        guard let repo = item.repo, item.hasNewCommits else { return [] }
        let ck = "\(repo)|\(item.lastSha ?? "")|\(item.ref ?? item.headSha ?? "main")"
        if let hit = DetailsCache.hit(ck) { return lines(hit, person: Demo.person) }
        guard let d = try? await Tool.json(["details", repo, item.lastSha ?? "", item.ref ?? item.headSha ?? "main"], as: Details.self) else { return [] }
        DetailsCache.put(ck, d)
        return lines(d, person: Demo.person)
    }
}
