// Deploy Center — known build failures: a pattern in a log, what it means and the command that
// usually fixes it, with a copy button. Failed builds with the same cause across projects are grouped.
// Pure rules first (tested in tests/insights-app-tests.swift), the views after.

import SwiftUI

struct ErrorPattern: Equatable {
    let id: String
    /// Lowercase phrases; one of them in the log is enough.
    let needles: [String]
    let title: String
    let hint: String
    /// A command to copy; nil when the fix is a setting, not a command.
    let command: String?
}

enum ErrorPatterns {
    /// The most specific first: the first pattern with a match in the text wins.
    static var all: [ErrorPattern] {[
        ErrorPattern(id: "lockfile",
                     needles: ["err_pnpm_outdated_lockfile", "lockfile is not up to date", "frozen-lockfile", "npm ci can only install", "package-lock.json and package.json are not in sync", "yarn.lock needs to be updated"],
                     title: L("The lockfile is out of date", "Die Lock-Datei ist veraltet"),
                     hint: L("package.json and the lockfile disagree. Install locally, commit the lockfile and build again.",
                             "package.json und die Lock-Datei passen nicht zusammen. Lokal installieren, die Lock-Datei committen, dann neu bauen."),
                     command: "npm install   # or: pnpm install / yarn install"),
        ErrorPattern(id: "memory",
                     needles: ["heap out of memory", "javascript heap", "killed: 9", "exit code 137", "out of memory", "oom"],
                     title: L("The build ran out of memory", "Dem Build ging der Speicher aus"),
                     hint: L("Raise Node's memory for the build, or split the build into smaller steps.",
                             "Den Speicher von Node für den Build erhöhen oder den Build in kleinere Schritte teilen."),
                     command: "NODE_OPTIONS=--max-old-space-size=4096"),
        ErrorPattern(id: "node",
                     needles: ["the engine \"node\" is incompatible", "unsupported engine", "requires node", "node version", "unsupported node"],
                     title: L("The Node version does not fit", "Die Node-Version passt nicht"),
                     hint: L("Set the Node version the project needs: the engines field in package.json or the host's Node setting.",
                             "Die Node-Version setzen, die das Projekt braucht: das Feld engines in package.json oder die Node-Einstellung beim Host."),
                     command: "npm pkg set engines.node=\">=20\""),
        ErrorPattern(id: "env",
                     needles: ["missing environment variable", "environment variable is not set", "env var", "is not defined in the environment", "undefined environment variable", "missing required env"],
                     title: L("An environment variable is missing", "Eine Umgebungsvariable fehlt"),
                     hint: L("Add the variable named in the log to the project's settings at the host, then build again.",
                             "Die im Log genannte Variable in den Projekteinstellungen beim Host ergänzen, dann neu bauen."),
                     command: nil),
        ErrorPattern(id: "auth",
                     needles: ["401 unauthorized", "403 forbidden", "http 401", "http 403", "status code 401", "status code 403", "permission denied (publickey)", "authentication failed", "e401", "e403"],
                     title: L("A token or key was refused (401/403)", "Ein Token oder Schlüssel wurde abgelehnt (401/403)"),
                     hint: L("A private package or API refused the build's token. Renew the token and update it at the host.",
                             "Ein privates Paket oder eine API hat das Token des Builds abgelehnt. Token erneuern und beim Host eintragen."),
                     command: nil),
    ]}

    /// The first known pattern in a log or error text; nil when none matches.
    static func match(_ text: String) -> ErrorPattern? {
        let t = text.lowercased()
        guard !t.isEmpty else { return nil }
        return all.first { p in p.needles.contains { needle in
            // "oom" and "env var" are short: only as a word, not inside "room" or "environment".
            needle.count <= 7 ? wordMatch(t, needle) : t.contains(needle)
        } }
    }

    private static func wordMatch(_ text: String, _ word: String) -> Bool {
        var from = text.startIndex
        while let r = text.range(of: word, range: from..<text.endIndex) {
            let before = r.lowerBound == text.startIndex ? " " : text[text.index(before: r.lowerBound)]
            let after = r.upperBound == text.endIndex ? " " : text[r.upperBound]
            if !before.isLetter && !after.isLetter { return true }
            from = r.upperBound
        }
        return false
    }

    // MARK: Grouping

    struct Group: Equatable {
        let pattern: ErrorPattern
        let projects: [String]
    }

    /// Failed builds by cause: only causes that hit at least `minimum` projects, the biggest group first.
    static func group(_ causes: [(project: String, cause: String)], minimum: Int = 2) -> [Group] {
        var byCause: [String: [String]] = [:]
        for c in causes where !(byCause[c.cause]?.contains(c.project) ?? false) { byCause[c.cause, default: []].append(c.project) }
        return byCause.compactMap { id, names in
            guard names.count >= minimum, let p = all.first(where: { $0.id == id }) else { return nil }
            return Group(pattern: p, projects: names.sorted())
        }.sorted { $0.projects.count != $1.projects.count ? $0.projects.count > $1.projects.count : $0.pattern.id < $1.pattern.id }
    }

    /// The text for "Copy": the fix and the projects it concerns.
    static func summary(_ g: Group) -> String {
        var out = g.pattern.title + "\n" + g.pattern.hint
        if let c = g.pattern.command { out += "\n" + c }
        return out + "\n" + g.projects.joined(separator: ", ")
    }
}

/// The causes of failed builds seen in logs on this Mac, so failures can be grouped across projects.
/// Kept 14 days; a project that builds again fine is dropped by `forget`.
enum FailureCauses {
    static let key = "failureCauses"
    static let keepDays = 14.0
    struct Entry: Codable, Equatable { let cause: String; let at: Double }

    static func load(_ d: UserDefaults = .standard) -> [String: Entry] {
        guard let data = d.data(forKey: key), let m = try? JSONDecoder().decode([String: Entry].self, from: data) else { return [:] }
        return m
    }
    static func record(project: String, cause: String, now: Date = Date(), _ d: UserDefaults = .standard) {
        var m = load(d)
        m[project] = Entry(cause: cause, at: now.timeIntervalSince1970)
        save(prune(m, now: now), d)
    }
    static func forget(project: String, _ d: UserDefaults = .standard) {
        var m = load(d)
        guard m.removeValue(forKey: project) != nil else { return }
        save(m, d)
    }
    static func prune(_ m: [String: Entry], now: Date) -> [String: Entry] {
        let limit = now.timeIntervalSince1970 - keepDays * 86400
        return m.filter { $0.value.at >= limit }
    }
    private static func save(_ m: [String: Entry], _ d: UserDefaults) {
        if let data = try? JSONEncoder().encode(m) { d.set(data, forKey: key) }
    }
    /// The causes of the projects that fail right now.
    static func current(failed: [String], _ d: UserDefaults = .standard, now: Date = Date()) -> [(project: String, cause: String)] {
        let m = prune(load(d), now: now)
        return failed.compactMap { n in m[n].map { (n, $0.cause) } }
    }
}

/// Under a failed build's log: what the known pattern means, the fix and a copy button.
struct ErrorHintCard: View {
    let log: String
    let project: String
    var body: some View {
        if let p = ErrorPatterns.match(log) {
            VStack(alignment: .leading, spacing: 6) {
                HStack(spacing: 6) {
                    Image(systemName: "lightbulb.fill").foregroundStyle(Color.warningText).accessibilityHidden(true)
                    Text(p.title).font(.callout.weight(.semibold))
                }
                Text(p.hint).font(.callout).foregroundStyle(.secondary)
                if let c = p.command {
                    HStack {
                        Text(c).font(.caption.monospaced()).textSelection(.enabled).lineLimit(2)
                        Spacer()
                        CopyButton(title: L("Copy", "Kopieren")) { c }
                    }
                }
            }
            .padding(10)
            .background(RoundedRectangle(cornerRadius: 8).fill(Color.secondary.opacity(0.1)))
            .padding(.horizontal, 12).padding(.vertical, 6)
            .accessibilityElement(children: .combine)
            .onAppear { FailureCauses.record(project: project, cause: p.id) }
        }
    }
}

/// "3 projects fail for the same reason", in Settings → Platforms.
struct FailureGroupsCard: View {
    @ObservedObject var store: Store
    var body: some View {
        let failed = store.items.values.flatMap { $0 }.filter(\.failed).map(\.name)
        let groups = ErrorPatterns.group(FailureCauses.current(failed: failed))
        if !groups.isEmpty {
            Section(L("Failed builds with the same cause", "Fehlgeschlagene Builds mit gleicher Ursache")) {
                ForEach(groups, id: \.pattern.id) { g in
                    VStack(alignment: .leading, spacing: 4) {
                        Text(L("\(g.projects.count) projects: ", "\(g.projects.count) Projekte: ") + g.pattern.title).font(.callout.weight(.semibold))
                        Text(g.projects.map { Demo.mask($0) }.joined(separator: ", ")).font(.caption).foregroundStyle(.secondary)
                        Text(g.pattern.hint).font(.caption)
                        HStack {
                            if let c = g.pattern.command { Text(c).font(.caption.monospaced()).textSelection(.enabled) }
                            Spacer()
                            CopyButton(title: L("Copy fix", "Fix kopieren")) { ErrorPatterns.summary(g) }
                        }
                    }
                    .accessibilityElement(children: .combine)
                }
            }
        }
    }
}
