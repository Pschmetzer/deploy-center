// Deploy Center — Search the logs of the failed projects, and group the ones that fail the same way.
// Reads only (`logs`); nothing here starts a build or a deploy.

import SwiftUI
import AppKit

enum LogGroups {
    struct Group: Equatable { var signature: String; var sample: String; var projects: [String] }
    struct Hit: Equatable { var project: String; var line: Int; var text: String }

    private static let steps: [(NSRegularExpression, String)] = [
        (#"https?://\S+"#, "<url>"),
        (#"(?:~|\.{0,2})/[\w@.+\-/]+"#, "<path>"),
        (#"\b[0-9a-f]{7,40}\b"#, "<hash>"),
        (#"\d{4}-\d{2}-\d{2}[T ]\d{2}:\d{2}:\d{2}(\.\d+)?Z?"#, "<time>"),
        (#"\d+"#, "#"),
        (#"\s+"#, " "),
    ].map { (try! NSRegularExpression(pattern: $0.0), $0.1) }

    /// An error line without what differs between projects (paths, hashes, times, numbers), so the same failure reads the same.
    static func signature(_ line: String) -> String {
        var s = LogTools.clean(line).lowercased()
        for (re, rep) in steps { s = re.stringByReplacingMatches(in: s, range: NSRange(s.startIndex..., in: s), withTemplate: rep) }
        return s.trimmingCharacters(in: .whitespaces)
    }

    /// Projects whose first error line has the same signature, the biggest group first. A log without an error is left out.
    static func group(_ logs: [(project: String, text: String)]) -> [Group] {
        var order: [String] = [], by: [String: Group] = [:]
        for l in logs {
            let lines = l.text.components(separatedBy: "\n").map { LogTools.clean($0) }
            guard let i = LogTools.firstErrorLine(lines) else { continue }
            let sig = signature(lines[i])
            if by[sig] == nil { by[sig] = Group(signature: sig, sample: lines[i].trimmingCharacters(in: .whitespaces), projects: []); order.append(sig) }
            if !by[sig]!.projects.contains(l.project) { by[sig]!.projects.append(l.project) }
        }
        return order.compactMap { by[$0] }.sorted { $0.projects.count > $1.projects.count }
    }

    /// Lines that contain the query (every word, any case, accents ignored), at most `perProject` of each project.
    static func search(_ query: String, in logs: [(project: String, text: String)], perProject: Int = 20) -> [Hit] {
        let words = paletteFold(query).split(whereSeparator: { $0.isWhitespace }).map(String.init)
        guard !words.isEmpty else { return [] }
        var out: [Hit] = []
        for l in logs {
            var n = 0
            for (i, raw) in l.text.components(separatedBy: "\n").enumerated() {
                let line = LogTools.clean(raw), folded = paletteFold(line)
                guard words.allSatisfy({ folded.contains($0) }) else { continue }
                out.append(Hit(project: l.project, line: i + 1, text: line.trimmingCharacters(in: .whitespaces)))
                n += 1; if n >= perProject { break }
            }
        }
        return out
    }
}

struct LogSearchView: View {
    @ObservedObject var store: Store
    @Environment(\.dismiss) private var dismiss
    @State private var logs: [(project: String, text: String)] = []
    @State private var loading = true
    @State private var query = ""
    @AppStorage("demoMode") private var demoMode = false

    private var failed: [Item] { store.allItems.filter { $0.failed } }
    private func shown(_ s: String) -> String { Demo.scrub(s, items: failed) }

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            HStack {
                Text(L("Failed builds", "Fehlgeschlagene Builds")).font(.headline)
                Spacer()
                Button(L("Close", "Schließen")) { dismiss() }.keyboardShortcut(.cancelAction)
            }.padding(16)
            TextField(L("Search the logs of failed projects", "In den Logs fehlgeschlagener Projekte suchen"), text: $query)
                .textFieldStyle(.roundedBorder).padding(.horizontal, 16).padding(.bottom, 10)
                .accessibilityLabel(L("Search the logs", "Logs durchsuchen"))
            Divider()
            if loading {
                ProgressView(L("Reading the logs …", "Lese die Logs …")).padding(24).frame(maxWidth: .infinity)
            } else if logs.isEmpty {
                Text(L("No project has failed, so there is nothing to search.", "Kein Projekt ist fehlgeschlagen, also gibt es nichts zu durchsuchen."))
                    .foregroundStyle(.secondary).padding(24).frame(maxWidth: .infinity)
            } else {
                List {
                    if query.trimmingCharacters(in: .whitespaces).isEmpty {
                        let groups = LogGroups.group(logs)
                        if groups.isEmpty {
                            Text(L("No error line found in these logs.", "In diesen Logs steht keine Fehlerzeile.")).foregroundStyle(.secondary)
                        }
                        ForEach(groups, id: \.signature) { g in
                            VStack(alignment: .leading, spacing: 2) {
                                Text(shown(g.sample)).font(.system(.caption, design: .monospaced)).lineLimit(3).textSelection(.enabled)
                                Text(L("\(g.projects.count) projects: ", "\(g.projects.count) Projekte: ") + g.projects.map(shown).joined(separator: ", "))
                                    .font(.caption).foregroundStyle(.secondary)
                            }
                            .accessibilityElement(children: .combine)
                        }
                    } else {
                        let hits = LogGroups.search(query, in: logs)
                        if hits.isEmpty { Text(L("Nothing found.", "Nichts gefunden.")).foregroundStyle(.secondary) }
                        ForEach(Array(hits.enumerated()), id: \.offset) { _, h in
                            VStack(alignment: .leading, spacing: 2) {
                                Text(shown(h.text)).font(.system(.caption, design: .monospaced)).lineLimit(3).textSelection(.enabled)
                                Text("\(shown(h.project)) · " + L("line \(h.line)", "Zeile \(h.line)")).font(.caption).foregroundStyle(.secondary)
                            }
                            .accessibilityElement(children: .combine)
                        }
                    }
                }
            }
        }
        .frame(minWidth: 560, minHeight: 420)
        .task { await load() }
    }

    private func load() async {
        var got: [(project: String, text: String)] = []
        for i in failed {
            if let d = try? await Tool.run([i.platform.cli, "logs", i.id, "200"]), let t = String(data: d, encoding: .utf8) {
                got.append((i.name, t))
            }
        }
        logs = got; loading = false
    }
}
