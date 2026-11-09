// Deploy Center — The build log and the details of one project.

import SwiftUI
import AppKit
import Charts
import UserNotifications
import ServiceManagement

// MARK: - Build log

struct BuildLog: View {
    let item: Item
    @Environment(\.dismiss) private var dismiss
    @State private var text: String?
    @State private var error: String?
    @State private var onlyErrors = false

    private var lines: [String] { (text ?? "").components(separatedBy: "\n") }
    private var firstError: Int? { LogTools.firstErrorLine(lines) }

    private func copy(_ s: String) { NSPasteboard.general.clearContents(); NSPasteboard.general.setString(s, forType: .string) }

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            HStack {
                Text(L("Build log: ", "Build-Log: ") + item.name).font(.headline)
                Spacer()
                if let text {
                    Toggle(L("Errors only", "Nur Fehler"), isOn: $onlyErrors).toggleStyle(.button)
                        .disabled(firstError == nil)
                    Button(L("Copy", "Kopieren")) { copy(text) }
                    Button(L("Copy for Claude", "Für Claude kopieren")) {
                        var msg: String?
                        if case .failed(let m) = item.state { msg = m }
                        copy(LogTools.claudePrompt(name: item.name, repo: item.repo, ref: item.ref, sha: item.headSha, message: msg, log: text))
                    }
                    .help(L("A prompt with the error and the log around it, ready to paste", "Ein Prompt mit Fehler und Log drumherum, zum Einfügen"))
                }
                Button(L("Close", "Schließen")) { dismiss() }.keyboardShortcut(.cancelAction)
            }
            .padding(12)
            Divider()
            if let error { Text(error).foregroundStyle(.secondary).padding(16).textSelection(.enabled) }
            else if text != nil {
                ScrollViewReader { proxy in
                    ScrollView {
                        LazyVStack(alignment: .leading, spacing: 0) {
                            ForEach(Array(lines.enumerated()), id: \.offset) { n, line in
                                let bad = LogTools.isErrorLine(line)
                                if !onlyErrors || bad {
                                    Text(line.isEmpty ? " " : line)
                                        .font(.system(.caption, design: .monospaced)).textSelection(.enabled)
                                        .foregroundStyle(bad ? Color.red : Color.primary)
                                        .frame(maxWidth: .infinity, alignment: .leading)
                                        .background(n == firstError ? Color.red.opacity(0.12) : Color.clear)
                                        .id(n)
                                }
                            }
                        }
                        .padding(12)
                    }
                    .defaultScrollAnchor(.bottom)
                    .overlay(alignment: .bottomTrailing) {
                        if let e = firstError {
                            Button(L("Jump to the first error", "Zum ersten Fehler")) { withAnimation { proxy.scrollTo(e, anchor: .center) } }
                                .buttonStyle(.borderedProminent).padding(12)
                        }
                    }
                }
            } else { ProgressView().frame(maxWidth: .infinity, maxHeight: .infinity) }
        }
        .frame(width: 760, height: 520)
        .task {
            do {
                let data = try await Tool.run(["logs", item.id, "200"])
                text = String(data: data, encoding: .utf8).map { $0.isEmpty ? L("(empty)", "(leer)") : $0 }
            } catch { self.error = error.localizedDescription }
        }
    }
}

// MARK: - One project in detail

struct ProjectDetail: View {
    let item: Item
    var deployCommit: ((String) -> Void)? = nil
    @Environment(\.dismiss) private var dismiss
    @State private var commitToDeploy: Details.Commit?
    @State private var details: Details?
    @State private var error: String?

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            HStack(spacing: 12) {
                Logo(domain: item.domain, name: item.name)
                VStack(alignment: .leading, spacing: 2) {
                    Text(item.name).font(.title3.weight(.semibold))
                    Text(item.detail).font(.caption).foregroundStyle(.secondary)
                }
                Spacer()
                if let d = details, !d.commits.isEmpty {
                    Button(L("Copy release notes", "Release-Notes kopieren")) {
                        NSPasteboard.general.clearContents()
                        NSPasteboard.general.setString(LogTools.releaseNotes(name: item.name, commits: d.commits), forType: .string)
                    }
                    .help(L("The waiting commits as a list, ready for a mail or a chat message", "Die wartenden Commits als Liste, fertig für Mail oder Chat"))
                }
                Button(L("Close", "Schließen")) { dismiss() }.keyboardShortcut(.cancelAction)
            }
            .padding(16)
            Divider()
            if let error {
                Text(error).foregroundStyle(.secondary).padding(20).textSelection(.enabled)
            } else if let d = details {
                ScrollView { content(d).padding(16) }
            } else {
                ProgressView(L("Asking GitHub …", "Frage GitHub …")).frame(maxWidth: .infinity, maxHeight: .infinity)
            }
        }
        .frame(width: 620, height: 560)
        .alert(L("Deploy this commit?", "Diesen Commit deployen?"),
               isPresented: Binding(get: { commitToDeploy != nil }, set: { if !$0 { commitToDeploy = nil } })) {
            Button(L("Cancel", "Abbrechen"), role: .cancel) { commitToDeploy = nil }
            Button(L("Deploy", "Deployen")) {
                if let c = commitToDeploy, let full = c.full { deployCommit?(full); dismiss() }
                commitToDeploy = nil
            }
        } message: {
            Text(L("\(item.name) goes live at \(commitToDeploy?.sha ?? "") – \(commitToDeploy?.msg ?? ""). Newer commits stay waiting.",
                   "\(item.name) geht mit \(commitToDeploy?.sha ?? "") live – \(commitToDeploy?.msg ?? ""). Neuere Commits warten weiter."))
        }
        .task {
            guard let repo = item.repo else { return }
            do {
                details = try await Tool.json(["details", repo, item.lastSha ?? "", item.ref ?? "main"], as: Details.self)
            } catch { self.error = error.localizedDescription }
        }
    }

    @ViewBuilder private func content(_ d: Details) -> some View {
        VStack(alignment: .leading, spacing: 18) {
            // What is live, and what the branch would bring.
            if let live = item.lastMsg {
                labelled(L("Live now", "Jetzt live"), live + (item.lastSha.map { "  (\($0.prefix(7)))" } ?? ""))
            }
            if let checks = d.checks, checks.total > 0 {
                HStack(spacing: 6) {
                    Image(systemName: checks.failed > 0 ? "xmark.octagon.fill" : (checks.running > 0 ? "clock.fill" : "checkmark.seal.fill"))
                        .foregroundStyle(checks.failed > 0 ? .red : (checks.running > 0 ? .orange : .green))
                    Text(checks.failed > 0
                         ? L("CI on the branch: \(checks.failed) of \(checks.total) checks failed", "CI auf dem Branch: \(checks.failed) von \(checks.total) Checks rot")
                         : checks.running > 0
                           ? L("CI on the branch: \(checks.running) checks still running", "CI auf dem Branch: \(checks.running) Checks laufen noch")
                           : L("CI on the branch: all \(checks.total) checks passed", "CI auf dem Branch: alle \(checks.total) Checks grün"))
                        .font(.callout)
                }
            }
            if !d.commits.isEmpty {
                VStack(alignment: .leading, spacing: 6) {
                    HStack {
                        Text(L("Waiting to go live", "Wartet darauf, live zu gehen")).font(.headline)
                        if d.onlyBots {
                            Text(L("dependency updates only", "nur Abhängigkeits-Updates"))
                                .font(.caption).padding(.horizontal, 6).padding(.vertical, 1)
                                .background(Capsule().fill(Color.secondary.opacity(0.15)))
                        }
                        Spacer()
                        if let u = d.compareUrl.flatMap(URL.init(string:)) {
                            Button(L("On GitHub", "Auf GitHub")) { NSWorkspace.shared.open(u) }.buttonStyle(.link)
                        }
                    }
                    Text(L("\(d.files) files, +\(d.additions) −\(d.deletions) lines", "\(d.files) Dateien, +\(d.additions) −\(d.deletions) Zeilen"))
                        .font(.caption).foregroundStyle(.secondary)
                    if !d.risky.isEmpty {
                        HStack(alignment: .top, spacing: 6) {
                            Image(systemName: "exclamationmark.triangle.fill").foregroundStyle(.orange)
                            Text(L("Worth a look before it goes live: ", "Vor dem Live-Gang ansehen: ") + d.risky.prefix(8).joined(separator: ", ")
                                 + (d.risky.count > 8 ? " …" : ""))
                                .font(.caption).textSelection(.enabled)
                        }
                    }
                    ForEach(d.commits) { c in
                        HStack(alignment: .firstTextBaseline, spacing: 8) {
                            if let pr = c.pr, let repo = item.repo, let u = URL(string: "https://github.com/\(repo)/pull/\(pr)") {
                                Button("#\(pr)") { NSWorkspace.shared.open(u) }.buttonStyle(.link).font(.caption.monospacedDigit())
                            } else if let u = c.url.flatMap(URL.init(string:)) {
                                Button(c.sha) { NSWorkspace.shared.open(u) }.buttonStyle(.link).font(.caption.monospaced())
                            }
                            Text(c.msg).font(.callout).lineLimit(2)
                            Spacer(minLength: 8)
                            Text((c.author ?? "") + " · " + Row.ago(Date(timeIntervalSince1970: c.at)))
                                .font(.caption2).foregroundStyle(.secondary).lineLimit(1)
                            if deployCommit != nil, item.deployable, c.full != nil {
                                Button { commitToDeploy = c } label: { Image(systemName: "paperplane") }
                                    .buttonStyle(.borderless).help(L("Deploy up to this commit", "Bis zu diesem Commit deployen"))
                            }
                        }
                    }
                }
            } else if item.hasNewCommits {
                Text(L("GitHub could not compare what is live with the branch (rewritten branch, or the live commit is unknown).",
                       "GitHub konnte Live-Stand und Branch nicht vergleichen (Branch umgeschrieben oder Live-Commit unbekannt)."))
                    .font(.callout).foregroundStyle(.secondary)
            } else {
                Label(L("Everything merged is live", "Alles Gemergte ist live"), systemImage: "checkmark.circle.fill").foregroundStyle(.green)
            }
            if item.platform == .vercel {
                VStack(alignment: .leading, spacing: 4) {
                    Text(L("Fewer builds in a monorepo", "Weniger Builds im Monorepo")).font(.headline)
                    Text(L("In Vercel's project settings, Git → Ignored Build Step, this command skips a build when nothing in the project's folder changed:",
                           "In Vercels Projekteinstellungen unter Git → Ignored Build Step überspringt dieser Befehl einen Build, wenn sich im Ordner des Projekts nichts geändert hat:"))
                        .font(.caption).foregroundStyle(.secondary)
                    HStack {
                        Text("git diff --quiet HEAD^ HEAD -- .").font(.system(.caption, design: .monospaced)).textSelection(.enabled)
                        Button { NSPasteboard.general.clearContents(); NSPasteboard.general.setString("git diff --quiet HEAD^ HEAD -- .", forType: .string) }
                            label: { Image(systemName: "doc.on.doc") }.buttonStyle(.borderless)
                    }
                    .padding(6).background(RoundedRectangle(cornerRadius: 5).fill(Color.secondary.opacity(0.1)))
                }
            }
            VStack(alignment: .leading, spacing: 6) {
                Text(L("Open pull requests (not merged)", "Offene Pull Requests (nicht gemergt)")).font(.headline)
                if d.open.isEmpty {
                    Text(L("None", "Keine")).font(.callout).foregroundStyle(.secondary)
                }
                ForEach(d.open) { pr in
                    HStack(alignment: .firstTextBaseline, spacing: 8) {
                        Button("#\(pr.number)") { if let u = URL(string: pr.url) { NSWorkspace.shared.open(u) } }
                            .buttonStyle(.link).font(.caption.monospacedDigit())
                        Text(pr.title).font(.callout).lineLimit(2)
                        if pr.draft { tag(L("draft", "Entwurf")) }
                        if pr.bot == true { tag("bot") }
                        Spacer(minLength: 8)
                        Image(systemName: pr.ci == "failed" ? "xmark.circle.fill" : pr.ci == "running" ? "clock" : pr.ci == "passed" ? "checkmark.circle.fill" : "minus.circle")
                            .foregroundStyle(pr.ci == "failed" ? .red : pr.ci == "passed" ? .green : .secondary)
                            .help("CI: \(pr.ci)")
                    }
                }
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
    }

    private func labelled(_ title: String, _ text: String) -> some View {
        VStack(alignment: .leading, spacing: 2) {
            Text(title).font(.caption).foregroundStyle(.secondary)
            Text(text).font(.callout).textSelection(.enabled)
        }
    }

    private func tag(_ s: String) -> some View {
        Text(s).font(.caption2).padding(.horizontal, 5).padding(.vertical, 1)
            .background(Capsule().fill(Color.secondary.opacity(0.15)))
    }
}
