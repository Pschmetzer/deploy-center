// Deploy Center — The build log and the details of one project.

import SwiftUI
import AppKit
import Charts
import UserNotifications
import ServiceManagement

// MARK: - Build log

struct BuildLog: View {
    @ObservedObject var store: Store
    /// The row as it was when the sheet opened; `live` follows the store.
    let item: Item
    @Environment(\.dismiss) private var dismiss
    @AppStorage("demoMode") private var demoMode = false
    @State private var text: String?
    @State private var lines: [String] = []
    @State private var firstError: Int?
    @State private var error: String?
    @State private var onlyErrors = false
    @State private var jump = 0
    @State private var attempt = 0
    /// The last lines first; "Load more" asks for ten times as many.
    @State private var lineCount = 200
    /// The lines as the screen shows them (scrubbed in demo mode), made once per load.
    @State private var shownLines: [String] = []
    /// ⌘+ and ⌘− in the log; remembered.
    @AppStorage("logFontSize") private var fontSize = Double(NSFont.smallSystemFontSize)

    private var live: Item { store.items[item.platform]?.first { $0.id == item.id } ?? item }

    private func copy(_ s: String) { NSPasteboard.general.clearContents(); NSPasteboard.general.setString(s, forType: .string) }

    /// Changes when a deploy starts or ends, so the log is read again then and not on every poll.
    private var reloadKey: String { "\(attempt)|\(lineCount)|\(live.state.isActive)|\(live.lastAt?.timeIntervalSince1970 ?? 0)|\(live.state == .idle)" }

    var body: some View {
        let live = self.live
        VStack(alignment: .leading, spacing: 0) {
            HStack {
                VStack(alignment: .leading, spacing: 1) {
                    Text(L("Build log: ", "Build-Log: ") + Demo.mask(live.name)).font(.headline)
                    // Which deploy this is: the commit and when, or that it is still running.
                    Text(subtitle(live)).font(.caption).foregroundStyle(.secondary).lineLimit(1)
                }
                if live.state.isActive { ProgressView().controlSize(.small) }
                Spacer()
                if let text {
                    if lines.count >= lineCount - 1 && lineCount < 2000 {
                        Button(L("Load more", "Mehr laden")) { lineCount = 2000 }
                            .help(L("Up to 2000 lines instead of the last 200", "Bis zu 2000 Zeilen statt der letzten 200"))
                    }
                    Toggle(L("Errors only", "Nur Fehler"), isOn: $onlyErrors).toggleStyle(.button)
                        .disabled(firstError == nil)
                    ClaudeMenu(store: store, item: live, waiting: false)
                    // The two copies in one menu: the header had too many buttons.
                    Menu(L("Copy", "Kopieren")) {
                        Button(L("Copy the log", "Log kopieren")) { copied(text) }
                        Button(L("Copy for Claude (prompt with the error)", "Für Claude kopieren (Prompt mit Fehler)")) {
                            var msg: String?
                            if case .failed(let m) = live.state { msg = m }
                            copied(LogTools.claudePrompt(name: live.name, repo: live.repo, ref: live.ref, sha: live.headSha, message: msg, log: text))
                        }
                    }
                    .fixedSize()
                    .help(L("The log, or a prompt with the error and the log around it, ready to paste", "Das Log, oder ein Prompt mit Fehler und Log drumherum, zum Einfügen"))
                    // Text size, remembered: ⌘+ and ⌘−.
                    Button { fontSize = min(20, fontSize + 1) } label: { Image(systemName: "textformat.size.larger") }
                        .keyboardShortcut("+").buttonStyle(.borderless).help(L("Larger text (⌘+)", "Größere Schrift (⌘+)"))
                        .accessibilityLabel(L("Larger text", "Größere Schrift"))
                    Button { fontSize = max(8, fontSize - 1) } label: { Image(systemName: "textformat.size.smaller") }
                        .keyboardShortcut("-").buttonStyle(.borderless).help(L("Smaller text (⌘−)", "Kleinere Schrift (⌘−)"))
                        .accessibilityLabel(L("Smaller text", "Kleinere Schrift"))
                }
                Button(L("Close", "Schließen")) { dismiss() }.keyboardShortcut(.cancelAction)
            }
            .padding(12)
            Divider()
            if let error {
                VStack(alignment: .leading, spacing: 10) {
                    Text(Demo.scrub(error, items: [live])).foregroundStyle(.secondary).textSelection(.enabled)
                    Button(L("Try again", "Nochmal versuchen")) { self.error = nil; attempt += 1 }
                }
                .padding(16)
            }
            else if text != nil {
                LogText(lines: shownLines, onlyErrors: onlyErrors, firstError: firstError, jump: jump, fontSize: fontSize)
                    .overlay(alignment: .bottomTrailing) {
                        if firstError != nil {
                            Button(L("Jump to the first error", "Zum ersten Fehler")) { jump += 1 }
                                .buttonStyle(.borderedProminent).padding(12)
                        }
                    }
            } else { ProgressView().frame(maxWidth: .infinity, maxHeight: .infinity) }
        }
        .frame(minWidth: 760, maxWidth: .infinity, minHeight: 420, idealHeight: 520, maxHeight: .infinity)
        .task(id: reloadKey) {
            await load()
            // While the build runs, the log follows it: read again every 5 seconds.
            while self.live.state.isActive && !Task.isCancelled {
                try? await Task.sleep(nanoseconds: 5_000_000_000)
                if Task.isCancelled { break }
                await load()
            }
        }
        .onChange(of: demoMode) { _, _ in shownLines = scrubbed(lines) }
    }

    private func load() async {
        do {
            let data = try await Tool.run(["logs", item.id, "\(lineCount)"])
            let t = String(data: data, encoding: .utf8).map { $0.isEmpty ? L("(empty)", "(leer)") : $0 } ?? ""
            // Split, searched and scrubbed once per load, not on every redraw.
            let l = t.components(separatedBy: "\n")
            if l != lines { lines = l; firstError = LogTools.firstErrorLine(l); shownLines = scrubbed(l) }
            text = t; self.error = nil
        } catch { if text == nil { self.error = error.localizedDescription } }
    }

    private func scrubbed(_ l: [String]) -> [String] { Demo.on ? l.map { Demo.scrub($0, items: [live]) } : l }

    private func copied(_ s: String) {
        copy(s)
        AccessibilityNotification.Announcement(L("Copied", "Kopiert")).post()
        store.show(Store.Toast(text: L("Copied", "Kopiert"), ok: true))
    }

    private func subtitle(_ i: Item) -> String {
        if i.state.isActive { return L("Running now – the log follows", "Läuft gerade – das Log läuft mit") }
        var parts: [String] = []
        if let s = i.lastSha { parts.append(String(s.prefix(7))) }
        if let at = i.lastAt { parts.append(Row.ago(at)) }
        if let st = i.lastState, !st.isEmpty { parts.append(Row.stateText(st)) }
        return parts.joined(separator: " · ")
    }
}

/// The log as one text view: several lines can be marked and copied at once, which a list of
/// separate lines does not allow. Set again only when the lines or the filter change, so a poll
/// in the background keeps the selection and the scroll position.
struct LogText: NSViewRepresentable {
    let lines: [String]
    let onlyErrors: Bool
    let firstError: Int?
    let jump: Int
    var fontSize = Double(NSFont.smallSystemFontSize)

    final class Coordinator { var shown: [String]?; var filter = false; var jump = 0; var errorRange: NSRange?; var size = 0.0 }
    func makeCoordinator() -> Coordinator { Coordinator() }

    func makeNSView(context: Context) -> NSScrollView {
        let sv = NSTextView.scrollableTextView()
        if let tv = sv.documentView as? NSTextView {
            tv.isEditable = false; tv.isSelectable = true; tv.drawsBackground = false
            tv.textContainerInset = NSSize(width: 8, height: 8)
            tv.isAutomaticLinkDetectionEnabled = false
            tv.usesFindBar = true; tv.isIncrementalSearchingEnabled = true
        }
        sv.drawsBackground = false
        return sv
    }

    func updateNSView(_ sv: NSScrollView, context: Context) {
        guard let tv = sv.documentView as? NSTextView else { return }
        let c = context.coordinator
        if c.shown != lines || c.filter != onlyErrors || c.size != fontSize {
            // Follow the end only when the reader was there (or on the first fill); a filter change
            // goes to the first error; a size change keeps the place.
            let first = c.shown == nil, filterChanged = c.filter != onlyErrors, sizeChanged = c.size != fontSize && !first
            let visible = sv.contentView.documentVisibleRect
            let atEnd = first || visible.maxY >= tv.bounds.height - 30
            c.shown = lines; c.filter = onlyErrors; c.size = fontSize
            let font = NSFont.monospacedSystemFont(ofSize: CGFloat(fontSize), weight: .regular)
            let out = NSMutableAttributedString()
            c.errorRange = nil
            for (n, line) in lines.enumerated() {
                let bad = LogTools.isErrorLine(line)
                if onlyErrors && !bad { continue }
                var attrs: [NSAttributedString.Key: Any] = [.font: font, .foregroundColor: bad ? NSColor.systemRed : NSColor.textColor]
                if n == firstError { attrs[.backgroundColor] = NSColor.systemRed.withAlphaComponent(0.12) }
                let start = out.length
                out.append(NSAttributedString(string: line + "\n", attributes: attrs))
                if n == firstError { c.errorRange = NSRange(location: start, length: (line as NSString).length) }
            }
            tv.textStorage?.setAttributedString(out)
            if filterChanged, let r = c.errorRange { tv.scrollRangeToVisible(r) }
            else if sizeChanged || !atEnd { tv.scroll(visible.origin) }
            else { tv.scrollToEndOfDocument(nil) }
        }
        if c.jump != jump {
            c.jump = jump
            if let r = c.errorRange { tv.scrollRangeToVisible(r); tv.showFindIndicator(for: r) }
        }
    }
}

// MARK: - One project in detail

struct ProjectDetail: View {
    @ObservedObject var store: Store
    /// The row as it was when the sheet opened; `live` follows the store.
    let item: Item
    var deployCommit: ((String) -> Void)? = nil
    /// Opens the build log (the window closes this sheet first).
    var openLog: (() -> Void)? = nil
    @Environment(\.dismiss) private var dismiss
    /// The monorepo hint, folded once read; remembered.
    @AppStorage("monorepoHintOpen") private var monorepoOpen = true
    /// Long lists show this many; the rest is on GitHub.
    private let listLimit = 50
    @State private var commitToDeploy: Details.Commit?
    @State private var details: Details?
    @State private var error: String?
    @AppStorage("demoMode") private var demoMode = false
    @AppStorage("hideBotCommits") private var hideBots = false
    @State private var attempt = 0

    private var live: Item { store.items[item.platform]?.first { $0.id == item.id } ?? item }
    private func scrub(_ s: String) -> String { Demo.scrub(s, items: Platform.allCases.flatMap { store.items[$0] ?? [] }) }

    var body: some View {
        let item = self.live
        VStack(alignment: .leading, spacing: 0) {
            HStack(spacing: 12) {
                Logo(domain: item.domain, name: Demo.mask(item.name))
                VStack(alignment: .leading, spacing: 2) {
                    Text(Demo.mask(item.name)).font(.title3.weight(.semibold))
                    Text(demoMode ? item.platform.rawValue : item.detail).font(.caption).foregroundStyle(.secondary)
                }
                if item.state.isActive { ProgressView().controlSize(.small) }
                Spacer()
                // What one does from here, without closing the sheet first.
                if let d = details, let newest = d.commits.first, deployCommit != nil, item.deployable, !item.state.isActive, newest.full != nil {
                    Button(L("Deploy …", "Deployen …")) { commitToDeploy = newest }
                        .help(L("Put the newest waiting commit live (asks first)", "Den neuesten wartenden Commit live schalten (fragt vorher)"))
                }
                if let openLog {
                    Button { dismiss(); openLog() } label: { Image(systemName: "text.alignleft") }
                        .buttonStyle(.borderless).help(L("Build log", "Build-Log")).accessibilityLabel(L("Build log", "Build-Log"))
                }
                if let u = item.link.flatMap(URL.init(string:)) {
                    Button { NSWorkspace.shared.open(u) } label: { Image(systemName: "safari") }
                        .buttonStyle(.borderless).help(L("Open site", "Seite öffnen")).accessibilityLabel(L("Open site", "Seite öffnen"))
                }
                Button { attempt += 1 } label: { Image(systemName: "arrow.clockwise") }
                    .buttonStyle(.borderless).help(L("Ask GitHub again", "GitHub neu fragen")).accessibilityLabel(L("Reload", "Neu laden"))
                ClaudeMenu(store: store, item: item, waiting: !(details?.commits.isEmpty ?? true))
                if let d = details, !d.commits.isEmpty {
                    CopyButton(title: L("Copy release notes", "Release-Notes kopieren")) { LogTools.releaseNotes(name: item.name, commits: d.commits) }
                    .help(L("The waiting commits as a list, ready for a mail or a chat message", "Die wartenden Commits als Liste, fertig für Mail oder Chat"))
                }
                Button(L("Close", "Schließen")) { dismiss() }.keyboardShortcut(.cancelAction)
            }
            .padding(16)
            Divider()
            if let error {
                VStack(alignment: .leading, spacing: 10) {
                    Text(scrub(error)).foregroundStyle(.secondary).textSelection(.enabled)
                    Button(L("Try again", "Nochmal versuchen")) { self.error = nil; attempt += 1 }
                }
                .padding(20)
            } else if let d = details {
                ScrollView { content(d).padding(16) }
            } else {
                ProgressView(L("Asking GitHub …", "Frage GitHub …")).frame(maxWidth: .infinity, maxHeight: .infinity)
            }
        }
        .frame(minWidth: 620, maxWidth: .infinity, minHeight: 420, idealHeight: 560, maxHeight: .infinity)
        .alert(L("Deploy this commit?", "Diesen Commit deployen?"),
               isPresented: Binding(get: { commitToDeploy != nil }, set: { if !$0 { commitToDeploy = nil } })) {
            Button(L("Cancel", "Abbrechen"), role: .cancel) { commitToDeploy = nil }
            Button(L("Deploy", "Deployen")) {
                if let c = commitToDeploy, let full = c.full { deployCommit?(full); dismiss() }
                commitToDeploy = nil
            }
        } message: {
            Text(L("\(Demo.mask(item.name)) goes live at \(commitToDeploy?.sha ?? "") – \(scrub(commitToDeploy?.msg ?? "")). Newer commits stay waiting.",
                   "\(Demo.mask(item.name)) geht mit \(commitToDeploy?.sha ?? "") live – \(scrub(commitToDeploy?.msg ?? "")). Neuere Commits warten weiter."))
        }
        // Asked again when what is live or the branch moves (a deploy ended, a new commit came in).
        .task(id: "\(attempt)|\(item.lastSha ?? "")|\(item.headSha ?? "")") {
            guard let repo = item.repo else { return }
            do {
                details = try await Tool.json(["details", repo, item.lastSha ?? "", item.ref ?? "main"], as: Details.self)
                error = nil
            } catch { if details == nil { self.error = error.localizedDescription } }
        }
    }

    /// Autofix for this project: what Claude is doing, or the button to hand the failed build over.
    @ViewBuilder private func autofixBlock(_ item: Item) -> some View {
        let state = store.autofixState(item), can = store.canFixWithClaude(item)
        let busy = store.autofixRunning.contains(Store.key(item)), result = store.autofixResult[Store.key(item)]
        if state != nil || can || result != nil {
            VStack(alignment: .leading, spacing: 6) {
                HStack(spacing: 10) {
                    AgentChips(autofix: state, allowedUntil: nil)
                    if can {
                        Button { Task { await store.fixWithClaude(item) } } label: {
                            HStack(spacing: 4) {
                                if busy { ProgressView().controlSize(.small) }
                                Text(L("Fix with Claude", "Mit Claude beheben"))
                            }
                        }
                        .disabled(busy)
                    }
                }
                if let result {
                    Text(scrub(result.text)).font(.caption).foregroundStyle(result.ok ? Color.secondary : Color.red).textSelection(.enabled)
                }
            }
        }
        if let until = store.allowance(item)?.expiresAt {
            Label(AgentChips.allowedText(until), systemImage: "bolt.badge.clock").font(.callout).foregroundStyle(Color.warningText)
        }
    }

    @ViewBuilder private func content(_ d: Details) -> some View {
        let item = self.live
        VStack(alignment: .leading, spacing: 18) {
            autofixBlock(item)
            // What is live, and what the branch would bring.
            if let live = item.lastMsg {
                labelled(L("Live now", "Jetzt live"), scrub(live) + (item.lastSha.map { "  (\($0.prefix(7)))" } ?? ""))
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
            risk(item)
            waiting(d)
            Toggle(L("Roll back if the check fails", "Zurückrollen, wenn der Check fehlschlägt"),
                   isOn: Binding(get: { store.rollsBack(item) }, set: { store.setRollsBack(item, $0) }))
                .toggleStyle(.checkbox)
                .help(L("After going live the site (or the page to check) is asked three times. If it answers 5xx or not at all, a notification counts down \(Store.rollbackSeconds) seconds – with Cancel – and production goes back to the deploy before.",
                        "Nach dem Live-Gang wird die Seite (oder die Prüfseite) dreimal abgefragt. Antwortet sie mit 5xx oder gar nicht, zählt eine Mitteilung \(Store.rollbackSeconds) Sekunden herunter – mit Abbrechen – und Live geht auf den Deploy davor zurück."))
            if item.platform == .vercel, let repo = item.repo,
               Platform.allCases.flatMap({ store.items[$0] ?? [] }).filter({ $0.repo == repo }).count > 1 {
                DisclosureGroup(isExpanded: $monorepoOpen) {
                VStack(alignment: .leading, spacing: 4) {
                    Text(L("In Vercel's project settings, Git → Ignored Build Step, this command skips a build when nothing in the project's folder changed:",
                           "In Vercels Projekteinstellungen unter Git → Ignored Build Step überspringt dieser Befehl einen Build, wenn sich im Ordner des Projekts nichts geändert hat:"))
                        .font(.caption).foregroundStyle(.secondary)
                    HStack {
                        Text("git diff --quiet HEAD^ HEAD -- .").font(.system(.caption, design: .monospaced)).textSelection(.enabled)
                        CopyButton(title: L("Copy the command", "Befehl kopieren"), systemImage: "doc.on.doc") { "git diff --quiet HEAD^ HEAD -- ." }
                            .buttonStyle(.borderless)
                    }
                    .padding(6).background(RoundedRectangle(cornerRadius: 5).fill(Color.secondary.opacity(0.1)))
                }
                } label: {
                    Text(L("Fewer builds in a monorepo", "Weniger Builds im Monorepo")).font(.headline)
                }
            }
            openPRs(d)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
    }

    /// How risky what waits is (`deploys risk`): the level and every reason, from the list read.
    @ViewBuilder private func risk(_ item: Item) -> some View {
        if item.hasNewCommits, let r = item.risk, !r.reasons.isEmpty {
            VStack(alignment: .leading, spacing: 4) {
                HStack(spacing: 6) {
                    Circle().fill(r.isRed ? Color.red : (r.level == "yellow" ? Color.orange : Color.green)).frame(width: 9, height: 9)
                    Text(r.isRed ? L("Risk: high", "Risiko: hoch") : L("Risk: medium", "Risiko: mittel")).font(.headline)
                }
                ForEach(Array(r.reasons.enumerated()), id: \.offset) { _, reason in
                    Label(r.text(reason), systemImage: reason.level == "red" ? "exclamationmark.octagon.fill" : "exclamationmark.triangle")
                        .font(.caption).foregroundStyle(reason.level == "red" ? Color.red : Color.secondary).textSelection(.enabled)
                }
            }
        }
    }

    @ViewBuilder private func waiting(_ d: Details) -> some View {
        let item = self.live
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
                Text(L(plural(d.files, "file", "files") + ", +\(d.additions) −\(d.deletions) lines",
                       plural(d.files, "Datei", "Dateien") + ", +\(d.additions) −\(d.deletions) Zeilen"))
                    .font(.caption).foregroundStyle(.secondary)
                if !d.risky.isEmpty {
                    HStack(alignment: .top, spacing: 6) {
                        Image(systemName: "exclamationmark.triangle.fill").foregroundStyle(.orange)
                        Text(L("Worth a look before it goes live: ", "Vor dem Live-Gang ansehen: ") + d.risky.prefix(8).joined(separator: ", ")
                             + (d.risky.count > 8 ? " …" : ""))
                            .font(.caption).textSelection(.enabled)
                    }
                }
                if d.commits.contains(where: { $0.bot == true }) && !d.onlyBots {
                    Toggle(L("Hide dependency updates", "Abhängigkeits-Updates ausblenden"), isOn: $hideBots)
                        .toggleStyle(.checkbox).font(.caption)
                }
                let commits = d.commits.filter { !(hideBots && !d.onlyBots && $0.bot == true) }
                LazyVStack(alignment: .leading, spacing: 6) {
                ForEach(commits.prefix(listLimit)) { c in
                    HStack(alignment: .firstTextBaseline, spacing: 8) {
                        if let pr = c.pr, let repo = item.repo, let u = URL(string: "https://github.com/\(repo)/pull/\(pr)") {
                            Button("#\(pr)") { NSWorkspace.shared.open(u) }.buttonStyle(.link).font(.caption.monospacedDigit())
                        } else if let u = c.url.flatMap(URL.init(string:)) {
                            Button(c.sha) { NSWorkspace.shared.open(u) }.buttonStyle(.link).font(.caption.monospaced())
                        }
                        Text(scrub(c.msg)).font(.callout).lineLimit(2).help(scrub(c.msg))
                        Spacer(minLength: 8)
                        Text([Demo.person(c.author), Row.ago(Date(timeIntervalSince1970: c.at))].compactMap { $0 }.filter { !$0.isEmpty }.joined(separator: " · "))
                            .font(.caption2).foregroundStyle(.secondary).lineLimit(1)
                        if deployCommit != nil, item.deployable, c.full != nil {
                            Button { commitToDeploy = c } label: { Image(systemName: "paperplane") }
                                .buttonStyle(.borderless).accessibilityLabel(L("Deploy up to this commit", "Bis zu diesem Commit deployen")).help(L("Deploy up to this commit", "Bis zu diesem Commit deployen"))
                        }
                    }
                }
                }
                if commits.count > listLimit {
                    moreOnGitHub(commits.count - listLimit, d.compareUrl.flatMap(URL.init(string:)))
                }
            }
        } else if item.hasNewCommits {
            Text(L("GitHub could not compare what is live with the branch (rewritten branch, or the live commit is unknown).",
                   "GitHub konnte Live-Stand und Branch nicht vergleichen (Branch umgeschrieben oder Live-Commit unbekannt)."))
                .font(.callout).foregroundStyle(.secondary)
        } else {
            Label(L("Everything merged is live", "Alles Gemergte ist live"), systemImage: "checkmark.circle.fill").foregroundStyle(.green)
        }
    }

    /// GitHub's CI word for a pull request, in words a person reads.
    static func ciText(_ ci: String) -> String {
        switch ci {
        case "failed": return L("CI: failed", "CI: rot")
        case "running": return L("CI: still running", "CI: läuft noch")
        case "passed": return L("CI: passed", "CI: grün")
        default: return L("CI: no checks", "CI: keine Checks")
        }
    }

    private func openPRs(_ d: Details) -> some View {
        VStack(alignment: .leading, spacing: 6) {
            Text(L("Open pull requests (not merged)", "Offene Pull Requests (nicht gemergt)")).font(.headline)
            if d.open.isEmpty {
                Text(L("None", "Keine")).font(.callout).foregroundStyle(.secondary)
            }
            LazyVStack(alignment: .leading, spacing: 6) {
            ForEach(d.open.prefix(listLimit)) { pr in
                HStack(alignment: .firstTextBaseline, spacing: 8) {
                    Button("#\(pr.number)") { if let u = URL(string: pr.url) { NSWorkspace.shared.open(u) } }
                        .buttonStyle(.link).font(.caption.monospacedDigit())
                    Text(scrub(pr.title)).font(.callout).lineLimit(2)
                    if pr.draft { tag(L("draft", "Entwurf")) }
                    if pr.bot == true { tag(L("bot", "Bot")) }
                    Spacer(minLength: 8)
                    Image(systemName: pr.ci == "failed" ? "xmark.circle.fill" : pr.ci == "running" ? "clock" : pr.ci == "passed" ? "checkmark.circle.fill" : "minus.circle")
                        .foregroundStyle(pr.ci == "failed" ? .red : pr.ci == "passed" ? .green : .secondary)
                        .help(Self.ciText(pr.ci)).accessibilityLabel(Self.ciText(pr.ci))
                }
            }
            }
            if d.open.count > listLimit {
                moreOnGitHub(d.open.count - listLimit, live.repo.flatMap { URL(string: "https://github.com/\($0)/pulls") })
            }
        }
    }

    private func moreOnGitHub(_ n: Int, _ url: URL?) -> some View {
        HStack {
            Text(L("and \(n) more", "und \(n) weitere")).font(.caption).foregroundStyle(.secondary)
            if let url, !Demo.on { Button(L("on GitHub", "auf GitHub")) { NSWorkspace.shared.open(url) }.buttonStyle(.link).font(.caption) }
        }
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
