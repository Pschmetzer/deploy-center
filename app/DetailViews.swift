// Deploy Center — The build log and the details of one project.

import SwiftUI
import AppKit
import Charts
import UserNotifications
import ServiceManagement

// MARK: - Where a repo lives

/// GitHub or GitLab, from the script's repo string (lib/githost.sh): GitHub repos are "owner/name",
/// GitLab ones carry their host ("gitlab.com/group/name", or a self-managed host). A GitHub owner
/// never holds a dot, so a dot in the first part means a host.
enum GitHost: Equatable {
    case github
    case gitlab(host: String)

    init(repo: String?) {
        let parts = (repo ?? "").split(separator: "/")
        if parts.count >= 3, parts[0].contains("."), parts[0].lowercased() != "github.com" {
            self = .gitlab(host: String(parts[0]))
        } else { self = .github }
    }
    init(_ item: Item) { self.init(repo: item.repo) }

    /// "GitHub" or "GitLab", for "On GitHub", "Asking GitLab …".
    var name: String { self == .github ? "GitHub" : "GitLab" }

    /// The repo's web page.
    static func web(_ repo: String) -> String {
        switch GitHost(repo: repo) {
        case .github: return "https://github.com/" + (repo.lowercased().hasPrefix("github.com/") ? String(repo.dropFirst(11)) : repo)
        case .gitlab: return "https://" + repo
        }
    }
    /// A pull request (GitHub) or merge request (GitLab) by its number.
    static func prURL(_ repo: String, _ n: Int) -> URL? {
        URL(string: web(repo) + (GitHost(repo: repo) == .github ? "/pull/\(n)" : "/-/merge_requests/\(n)"))
    }
    /// "#12" on GitHub, "!12" on GitLab, as each site writes it.
    static func prLabel(_ repo: String?, _ n: Int) -> String { GitHost(repo: repo) == .github ? "#\(n)" : "!\(n)" }
    /// The commits between what is live and the branch, on the repo's own site.
    static func compareURL(_ item: Item) -> URL? {
        guard case .gitlab = GitHost(item), let repo = item.repo else { return item.compareURL }
        guard let live = item.lastSha, !live.isEmpty, item.hasNewCommits else { return nil }
        let branch = item.ref ?? item.headSha ?? "main"
        let safe = branch.addingPercentEncoding(withAllowedCharacters: .urlPathAllowed.subtracting(CharacterSet(charactersIn: "#?"))) ?? branch
        return URL(string: web(repo) + "/-/compare/\(live)...\(safe)")
    }
}

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
    /// When the log on screen was read, and since when reading it again fails.
    @State private var loadedAt: Date?
    @State private var reloadFailed: Date?

    private var live: Item { store.items[item.platform]?.first { $0.id == item.id } ?? item }

    private func copy(_ s: String) { NSPasteboard.general.clearContents(); NSPasteboard.general.setString(s, forType: .string) }

    /// Changes when a deploy starts or ends, so the log is read again then and not on every poll.
    private var reloadKey: String { "\(attempt)|\(lineCount)|\(live.state.isActive)|\(live.lastAt?.timeIntervalSince1970 ?? 0)|\(live.state == .idle)" }

    var body: some View {
        let live = self.live
        VStack(alignment: .leading, spacing: 0) {
            HStack {
                Text(L("Build log: ", "Build-Log: ") + Demo.mask(live.name)).font(.headline)
                if live.state.isActive { ProgressView().controlSize(.small) }
                Spacer()
                if let text {
                    if lines.count >= lineCount - 1 && lineCount < 2000 {
                        Button(L("Load more", "Mehr laden")) { lineCount = 2000 }
                            .help(L("Up to 2000 lines instead of the last 200", "Bis zu 2000 Zeilen statt der letzten 200"))
                    }
                    Toggle(L("Errors only", "Nur Fehler"), isOn: $onlyErrors).toggleStyle(.button)
                        .disabled(firstError == nil)
                    // Tokens masked like "Copy for Claude"; with ⌥ held the raw log.
                    CopyButton(title: L("Copy", "Kopieren")) { NSEvent.modifierFlags.contains(.option) ? text : LogTools.maskSecrets(text) }
                        .help(L("Copies the log with tokens hidden; hold ⌥ for the raw log", "Kopiert das Log mit verdeckten Tokens; mit ⌥ das Roh-Log"))
                    ClaudeMenu(store: store, item: live, waiting: false)
                    CopyButton(title: L("Copy for Claude", "Für Claude kopieren")) {
                        var msg: String?
                        if case .failed(let m) = live.state { msg = m }
                        // In demo mode the stand-ins, like on screen: a pasted prompt is seen in the demo too.
                        guard Demo.on else {
                            return LogTools.claudePrompt(name: live.name, repo: live.repo, ref: live.ref, sha: live.headSha, message: msg, log: text)
                        }
                        return LogTools.claudePrompt(name: Demo.mask(live.name), repo: live.repo.map(Demo.mask), ref: live.ref, sha: live.headSha,
                                                     message: msg.map { Demo.scrub($0, items: [live]) }, log: Demo.scrub(text, items: [live]))
                    }
                    .help(L("A prompt with the error and the log around it, ready to paste", "Ein Prompt mit Fehler und Log drumherum, zum Einfügen"))
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
                if let reloadFailed {
                    // The log on screen is older than it looks: say so, with a way to try again.
                    HStack(spacing: 6) {
                        Image(systemName: "exclamationmark.triangle.fill").foregroundStyle(.orange).accessibilityHidden(true)
                        Text(L("As of \(reloadFailed.formatted(date: .omitted, time: .shortened)) – reloading failed",
                               "Stand von \(reloadFailed.formatted(date: .omitted, time: .shortened)) – Neuladen fehlgeschlagen"))
                        Button(L("Try again", "Nochmal")) { attempt += 1 }.buttonStyle(.link)
                        Spacer()
                    }
                    .font(.caption).foregroundStyle(.secondary).padding(.horizontal, 12).padding(.vertical, 4)
                }
                LogText(lines: demoMode ? lines.map { Demo.scrub($0, items: [live]) } : lines,
                        onlyErrors: onlyErrors, firstError: firstError, jump: jump,
                        label: L("Build log of \(Demo.mask(live.name))", "Build-Log von \(Demo.mask(live.name))"))
                    .overlay(alignment: .bottomTrailing) {
                        if firstError != nil {
                            Button(L("Jump to the first error", "Zum ersten Fehler")) { jump += 1 }
                                .buttonStyle(.borderedProminent).padding(12)
                        }
                    }
            } else { ProgressView().frame(maxWidth: .infinity, maxHeight: .infinity) }
        }
        // Not wider than the main window may be (680), so the sheet never sticks out of it.
        .frame(minWidth: 640, idealWidth: 760, maxWidth: .infinity, minHeight: 420, idealHeight: 520, maxHeight: .infinity)
        .task(id: reloadKey) {
            do {
                // Through the project's own platform, the way the store cancels and rolls back:
                // a name on two platforms is not ambiguous then.
                let data = try await Tool.run([item.platform.cli, "logs", item.id, "\(lineCount)"])
                let t = String(data: data, encoding: .utf8).map { $0.isEmpty ? L("(empty)", "(leer)") : $0 } ?? ""
                // Split and searched once per load, not on every redraw.
                lines = t.components(separatedBy: "\n"); firstError = LogTools.firstErrorLine(lines)
                text = t; self.error = nil; loadedAt = Date(); reloadFailed = nil
            } catch {
                if text == nil { self.error = error.localizedDescription } else { reloadFailed = loadedAt ?? Date() }
            }
        }
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
    /// What VoiceOver calls the text view ("Build log of shop").
    var label = ""
    @Environment(\.accessibilityDifferentiateWithoutColor) private var noColour

    /// An error line as the log shows it: with "Differentiate without colour" a mark in front, not red alone.
    static func shown(_ line: String, bad: Bool, noColour: Bool) -> String { bad && noColour ? "✖ " + line : line }

    final class Coordinator { var shown: [String]?; var filter = false; var noColour = false; var jump = 0; var errorRange: NSRange? }
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
        if tv.accessibilityLabel() != label { tv.setAccessibilityLabel(label) }
        let c = context.coordinator
        if c.shown != lines || c.filter != onlyErrors || c.noColour != noColour {
            c.shown = lines; c.filter = onlyErrors; c.noColour = noColour
            let font = NSFont.monospacedSystemFont(ofSize: NSFont.smallSystemFontSize, weight: .regular)
            let bold = NSFont.monospacedSystemFont(ofSize: NSFont.smallSystemFontSize, weight: .bold)
            let out = NSMutableAttributedString()
            c.errorRange = nil
            for (n, raw) in lines.enumerated() {
                let bad = LogTools.isErrorLine(raw)
                if onlyErrors && !bad { continue }
                let line = Self.shown(raw, bad: bad, noColour: noColour)
                var attrs: [NSAttributedString.Key: Any] = [.font: bad && noColour ? bold : font,
                                                            .foregroundColor: bad ? NSColor.systemRed : NSColor.textColor]
                if n == firstError { attrs[.backgroundColor] = NSColor.systemRed.withAlphaComponent(0.12) }
                let start = out.length
                out.append(NSAttributedString(string: line + "\n", attributes: attrs))
                if n == firstError { c.errorRange = NSRange(location: start, length: (line as NSString).length) }
            }
            tv.textStorage?.setAttributedString(out)
            tv.scrollToEndOfDocument(nil)
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
    @Environment(\.dismiss) private var dismiss
    @State private var commitToDeploy: Details.Commit?
    @State private var details: Details?
    @State private var error: String?
    @AppStorage("demoMode") private var demoMode = false
    @AppStorage("hideBotCommits") private var hideBots = false
    @State private var attempt = 0
    @State private var loadedAt: Date?
    @State private var reloadFailed: Date?
    @State private var showAllCommits = false
    /// Waiting commits listed at first; the rest behind "Show … more".
    static let commitsShown = 30
    /// Vercel's Ignored Build Step: compares with the last deployed commit, so a deploy by hand over several
    /// commits is not skipped because the newest one touched another folder. Without a previous deploy
    /// the variable is empty; then the last commit stands in, never an empty argument (that would skip).
    static let ignoredBuildStep = "git diff --quiet ${VERCEL_GIT_PREVIOUS_SHA:-HEAD^} HEAD -- ."

    private var live: Item { store.items[item.platform]?.first { $0.id == item.id } ?? item }
    private var allItems: [Item] { Platform.allCases.flatMap { store.items[$0] ?? [] } }
    private func scrub(_ s: String) -> String { Demo.scrub(s, items: allItems) }

    /// The release notes for the clipboard; in demo mode with stand-ins, as the screen shows them.
    static func releaseNotes(_ item: Item, _ commits: [Details.Commit], all: [Item]) -> String {
        let notes = LogTools.releaseNotes(name: Demo.mask(item.name), commits: Demo.on ? commits.map {
            Details.Commit(sha: $0.sha, full: $0.full, url: $0.url, msg: Demo.scrub($0.msg, items: all), author: Demo.person($0.author),
                           bot: $0.bot, at: $0.at, pr: $0.pr)
        } : commits)
        return notes
    }

    var body: some View {
        let item = self.live
        VStack(alignment: .leading, spacing: 0) {
            HStack(spacing: 12) {
                Logo(domain: Demo.on ? nil : item.domain, name: Demo.mask(item.name))
                VStack(alignment: .leading, spacing: 2) {
                    Text(Demo.mask(item.name)).font(.title3.weight(.semibold))
                    Text(demoMode ? item.platform.rawValue : item.detail).font(.caption).foregroundStyle(.secondary)
                }
                if item.state.isActive { ProgressView().controlSize(.small) }
                Spacer()
                ClaudeMenu(store: store, item: item, waiting: !(details?.commits.isEmpty ?? true))
                if let d = details, !d.commits.isEmpty {
                    CopyButton(title: L("Copy release notes", "Release-Notes kopieren")) { Self.releaseNotes(item, d.commits, all: allItems) }
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
                if let reloadFailed {
                    HStack(spacing: 6) {
                        Image(systemName: "exclamationmark.triangle.fill").foregroundStyle(.orange).accessibilityHidden(true)
                        Text(L("As of \(reloadFailed.formatted(date: .omitted, time: .shortened)) – reloading failed",
                               "Stand von \(reloadFailed.formatted(date: .omitted, time: .shortened)) – Neuladen fehlgeschlagen"))
                        Button(L("Try again", "Nochmal")) { attempt += 1 }.buttonStyle(.link)
                        Spacer()
                    }
                    .font(.caption).foregroundStyle(.secondary).padding(.horizontal, 16).padding(.vertical, 4)
                }
                ScrollView { content(d).padding(16) }
            } else {
                ProgressView(L("Asking \(GitHost(item).name) …", "Frage \(GitHost(item).name) …")).frame(maxWidth: .infinity, maxHeight: .infinity)
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
                // Without a known branch the branch's newest commit stands in for it: "main" would
                // compare the wrong branch in a repo on "master" or "develop".
                details = try await Tool.json(["details", repo, item.lastSha ?? "", item.ref ?? item.headSha ?? "main"], as: Details.self)
                error = nil; loadedAt = Date(); reloadFailed = nil
            } catch {
                if details == nil { self.error = error.localizedDescription } else { reloadFailed = loadedAt ?? Date() }
            }
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
            Label(AgentChips.allowedText(until), systemImage: "bolt.badge.clock").font(.callout).foregroundStyle(.orange)
        }
    }

    /// Security check: counts per tool; secrets as "rotate this key", the rest can go to a bug scan.
    @ViewBuilder private func checkBlock(_ item: Item) -> some View {
        if item.repo != nil, store.scan?.tools?.any == true {
            let c = store.checkRun(item)
            VStack(alignment: .leading, spacing: 6) {
                HStack(spacing: 10) {
                    Button { Task { await store.securityCheck(item) } } label: {
                        HStack(spacing: 4) {
                            if c?.running == true { ProgressView().controlSize(.small) }
                            Text(L("Security check", "Sicherheits-Check"))
                        }
                    }
                    .disabled(!store.canCheck(item))
                    if let c, c.status == "done" {
                        Text(L("\(c.osv ?? 0) vulnerable packages · \(c.gitleaks ?? 0) secrets · \(c.semgrep ?? 0) code findings",
                               "\(c.osv ?? 0) unsichere Pakete · \(c.gitleaks ?? 0) Secrets · \(c.semgrep ?? 0) Code-Funde"))
                            .font(.caption).foregroundStyle(c.fixable + (c.gitleaks ?? 0) == 0 ? Color.green : Color.orange)
                        if c.fixable > 0, !store.observer {
                            Button(L("Fix with Claude", "Mit Claude beheben")) { Task { await store.scanForBugs(item, findings: true) } }
                                .disabled(!store.canScan(item))
                        }
                    } else if let c, c.status == "failed" {
                        Text(scrub(c.error ?? L("Check failed", "Check fehlgeschlagen"))).font(.caption).foregroundStyle(.red).lineLimit(2)
                    }
                }
                if let c, let leaks = store.checkLeaks[c.id], !leaks.isEmpty {
                    Text(L("Rotate these keys (a commit does not remove them from the history):",
                           "Diese Keys neu erzeugen (ein Commit entfernt sie nicht aus der Historie):")).font(.caption).foregroundStyle(.red)
                    ForEach(leaks, id: \.self) { l in
                        Text("\(l.rule) – \(scrub(l.file))\(l.line.map { ":\($0)" } ?? "")\(l.commit.map { " (\($0))" } ?? "")")
                            .font(.caption.monospaced()).textSelection(.enabled)
                    }
                }
            }
            .task(id: c?.id) { if let c, c.status == "done" { await store.loadLeaks(c) } }
        }
    }

    /// Bug scan: Claude Code on this Mac looks through the repo and opens one fix PR.
    @ViewBuilder private func scanBlock(_ item: Item) -> some View {
        if item.repo != nil, !store.observer {
            let run = store.scanRun(item), starting = item.repo.map { store.scanStarting.contains($0) } ?? false
            HStack(spacing: 10) {
                Button { Task { await store.scanForBugs(item) } } label: {
                    HStack(spacing: 4) {
                        if starting || run?.running == true { ProgressView().controlSize(.small) }
                        Text(L("Find bugs with Claude", "Mit Claude nach Bugs suchen"))
                    }
                }
                .disabled(!store.canScan(item))
                if let run {
                    switch run.status {
                    case "running": Text(L("Claude is looking for bugs …", "Claude sucht nach Bugs …")).font(.caption).foregroundStyle(.secondary)
                    case "clean": Text(L("Last scan: nothing to fix", "Letzter Scan: nichts zu beheben")).font(.caption).foregroundStyle(.green)
                    case "pr":
                        if let u = run.prUrl.flatMap(URL.init(string:)) {
                            Link(L("Fix PR with \(run.fixes ?? 0) fix(es)", "Fix-PR mit \(run.fixes ?? 0) Fix(es)"), destination: u).font(.caption)
                        }
                    default: Text(scrub(run.error ?? L("Scan failed", "Scan fehlgeschlagen"))).font(.caption).foregroundStyle(.red).lineLimit(2)
                    }
                }
            }
        }
    }

    @ViewBuilder private func content(_ d: Details) -> some View {
        let item = self.live
        VStack(alignment: .leading, spacing: 18) {
            autofixBlock(item)
            scanBlock(item)
            checkBlock(item)
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
               // Vercel projects only: a Render backend in the same repo builds on Render, not here.
               (store.items[.vercel] ?? []).filter({ $0.repo == repo }).count > 1 {
                VStack(alignment: .leading, spacing: 4) {
                    Text(L("Fewer builds in a monorepo", "Weniger Builds im Monorepo")).font(.headline)
                    Text(L("In Vercel's project settings, Git → Ignored Build Step, this command skips a build when nothing in the project's folder changed:",
                           "In Vercels Projekteinstellungen unter Git → Ignored Build Step überspringt dieser Befehl einen Build, wenn sich im Ordner des Projekts nichts geändert hat:"))
                        .font(.caption).foregroundStyle(.secondary)
                    HStack {
                        Text(Self.ignoredBuildStep).font(.system(.caption, design: .monospaced)).textSelection(.enabled)
                        CopyButton(title: L("Copy the command", "Befehl kopieren"), systemImage: "doc.on.doc") { Self.ignoredBuildStep }
                            .buttonStyle(.borderless)
                    }
                    .padding(6).background(RoundedRectangle(cornerRadius: 5).fill(Color.secondary.opacity(0.1)))
                    Text(L("It compares with the last deployed commit, so a deploy by hand over several commits still builds when any of them touched the folder.",
                           "Er vergleicht mit dem zuletzt deployten Commit, darum baut ein Handdeploy über mehrere Commits trotzdem, wenn einer davon den Ordner betraf."))
                        .font(.caption).foregroundStyle(.secondary)
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
                        Button(L("On \(GitHost(item).name)", "Auf \(GitHost(item).name)")) { NSWorkspace.shared.open(u) }.buttonStyle(.link)
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
                if d.commits.contains(where: { $0.bot == true }) && !d.onlyBots {
                    Toggle(L("Hide dependency updates", "Abhängigkeits-Updates ausblenden"), isOn: $hideBots)
                        .toggleStyle(.checkbox).font(.caption)
                }
                let commits = d.commits.filter { !(hideBots && !d.onlyBots && $0.bot == true) }
                ForEach(showAllCommits ? commits : Array(commits.prefix(Self.commitsShown))) { c in
                    HStack(alignment: .firstTextBaseline, spacing: 8) {
                        if let pr = c.pr, let repo = item.repo, let u = GitHost.prURL(repo, pr) {
                            Button(GitHost.prLabel(repo, pr)) { NSWorkspace.shared.open(u) }.buttonStyle(.link).font(.caption.monospacedDigit())
                                .accessibilityLabel(L("Open pull request \(pr): \(scrub(c.msg))", "Pull Request \(pr) öffnen: \(scrub(c.msg))"))
                        } else if let u = c.url.flatMap(URL.init(string:)) {
                            Button(c.sha) { NSWorkspace.shared.open(u) }.buttonStyle(.link).font(.caption.monospaced())
                                .accessibilityLabel(L("Open commit \(c.sha): \(scrub(c.msg))", "Commit \(c.sha) öffnen: \(scrub(c.msg))"))
                        }
                        Text(scrub(c.msg)).font(.callout).lineLimit(2).help(scrub(c.msg))
                        Spacer(minLength: 8)
                        Text([Demo.person(c.author), Row.ago(Date(timeIntervalSince1970: c.at))].compactMap { $0 }.filter { !$0.isEmpty }.joined(separator: " · "))
                            .font(.caption2).foregroundStyle(.secondary).lineLimit(1)
                        // Not at the branch's newest commit: there it is a plain deploy of everything.
                        if deployCommit != nil, item.deployable, let full = c.full, full != item.headSha {
                            Button { commitToDeploy = c } label: { Image(systemName: "paperplane") }
                                .buttonStyle(.borderless).accessibilityLabel(L("Deploy up to this commit", "Bis zu diesem Commit deployen")).help(L("Deploy up to this commit", "Bis zu diesem Commit deployen"))
                        }
                    }
                }
                // A long list would push the risk notes out of sight; the rest on request.
                if !showAllCommits && commits.count > Self.commitsShown {
                    Button(L("Show \(commits.count - Self.commitsShown) more commits", "\(commits.count - Self.commitsShown) weitere Commits zeigen")) { showAllCommits = true }
                        .buttonStyle(.link).font(.caption)
                }
            }
        } else if item.hasNewCommits {
            Text(L("\(GitHost(item).name) could not compare what is live with the branch (rewritten branch, or the live commit is unknown).",
                   "\(GitHost(item).name) konnte Live-Stand und Branch nicht vergleichen (Branch umgeschrieben oder Live-Commit unbekannt)."))
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
            ForEach(d.open) { pr in
                HStack(alignment: .firstTextBaseline, spacing: 8) {
                    Button(GitHost.prLabel(live.repo, pr.number)) { if let u = URL(string: pr.url) { NSWorkspace.shared.open(u) } }
                        .buttonStyle(.link).font(.caption.monospacedDigit())
                        .accessibilityLabel(L("Open pull request \(pr.number): \(scrub(pr.title))", "Pull Request \(pr.number) öffnen: \(scrub(pr.title))"))
                    Text(scrub(pr.title)).font(.callout).lineLimit(2)
                    if pr.draft { tag(L("draft", "Entwurf")) }
                    if pr.bot == true { tag("bot") }
                    Spacer(minLength: 8)
                    Image(systemName: pr.ci == "failed" ? "xmark.circle.fill" : pr.ci == "running" ? "clock" : pr.ci == "passed" ? "checkmark.circle.fill" : "minus.circle")
                        .foregroundStyle(pr.ci == "failed" ? .red : pr.ci == "passed" ? .green : .secondary)
                        .help(Self.ciText(pr.ci)).accessibilityLabel(Self.ciText(pr.ci))
                }
            }
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
