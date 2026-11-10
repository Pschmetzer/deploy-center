// Deploy Center — One project row of the main window, its chips, and the allowance banner.

import SwiftUI
import AppKit

struct Row: View {
    let item: Item
    /// Under "All": a small platform name after the key figure.
    var showPlatform = false
    var cost: Double? = nil
    var perBuild: Double? = nil
    var pinned = false
    var note: String? = nil
    var showDetails: (() -> Void)? = nil
    var showLog: (() -> Void)? = nil
    var onCancel: (() -> Void)? = nil
    var onRetry: (() -> Void)? = nil
    var usualMinutes: Int? = nil
    var queueText: String? = nil
    var search = ""
    var autofix: RowAutofix? = nil
    var allowedUntil: Date? = nil
    var autofixBusy = false
    var onAutofix: (() -> Void)? = nil
    let toggle: () -> Void
    @Environment(\.accessibilityDifferentiateWithoutColor) private var noColour

    /// How the search finds a text and how the row marks it: one rule for both, so a row the list
    /// keeps always shows why (any case, and "uber" finds "Über").
    static let matchOptions: String.CompareOptions = [.caseInsensitive, .diacriticInsensitive]
    static func matches(_ text: String, _ search: String) -> Bool {
        !search.isEmpty && text.range(of: search, options: matchOptions) != nil
    }

    /// The part of a text that matches the search, marked.
    private func highlighted(_ text: String) -> AttributedString {
        var a = AttributedString(text)
        guard !search.isEmpty, let r = a.range(of: search, options: Self.matchOptions) else { return a }
        a[r].backgroundColor = .yellow.opacity(0.35)
        return a
    }

    var body: some View { forVoiceOver(layout) }

    private var layout: some View {
        HStack(spacing: 12) {
            Button(action: toggle) {
                Image(systemName: item.selected ? "checkmark.circle.fill" : "circle")
                    .font(.title3)
                    .foregroundStyle(item.selected ? Color.accentColor : .secondary)
                    .opacity(item.deployable ? 1 : 0.3)
            }
            .buttonStyle(.plain)
            .disabled(!item.deployable || item.state.isActive)
            .help(!item.deployable ? L("Deploy Center cannot deploy this project (no Git source it can build from)",
                                       "Deploy Center kann dieses Projekt nicht deployen (keine Git-Quelle, aus der es bauen kann)")
                  : item.state.isActive ? L("A deploy is running", "Ein Deploy läuft gerade") : "")
            .accessibilityLabel(Demo.mask(item.name))
            .accessibilityValue(item.selected ? L("selected", "ausgewählt") : L("not selected", "nicht ausgewählt"))

            Logo(domain: Demo.on ? nil : item.domain, name: Demo.mask(item.name))

            // Redrawn once a minute, so "3 minutes ago" does not stand still between two loads.
            TimelineView(.everyMinute) { _ in
            VStack(alignment: .leading, spacing: 3) {
                HStack(spacing: 6) {
                    if pinned { Image(systemName: "pin.fill").font(.caption2).foregroundStyle(.secondary) }
                    Text(Demo.on ? AttributedString(Demo.mask(item.name)) : highlighted(item.name)).font(.body.weight(.medium))
                    // Only red is shown in the row; yellow and the reasons are in the details.
                    if item.hasNewCommits, let r = item.risk, r.isRed {
                        Circle().fill(Color.red).frame(width: 7, height: 7)
                            .help(L("Risky to ship: ", "Riskant zum Ausliefern: ") + r.reasons.filter { $0.level == "red" }.map(r.text).joined(separator: "; "))
                            .accessibilityHidden(true)   // said in `spoken`
                    }
                    if let d = item.domain, let u = item.link.flatMap(URL.init(string:)) {
                        Button { NSWorkspace.shared.open(u) } label: { Text(Demo.on ? AttributedString(Demo.mask(d)) : highlighted(d)).font(.caption) }
                            .buttonStyle(.link).help(L("Open site", "Seite öffnen"))
                    }
                }
                // Found by its source only (repo, service type): show that line, so the hit has a reason.
                if !Demo.on, !search.isEmpty, !Self.matches(item.name, search), !Self.matches(item.domain ?? "", search),
                   Self.matches(item.detail, search) {
                    Text(highlighted(item.detail)).font(.caption2).foregroundStyle(.secondary).lineLimit(1)
                }
                if let note { Label(note, systemImage: "note.text").font(.caption.italic()).foregroundStyle(.secondary) }
                // One figure per row; the rest is in the tooltip and for VoiceOver.
                HStack(spacing: 6) {
                    keyFigure
                    AgentChips(autofix: autofix, allowedUntil: allowedUntil, busy: autofixBusy, onFix: onAutofix)
                    if showPlatform {
                        Text("· " + item.platform.rawValue).font(.caption2).foregroundStyle(.tertiary)
                    }
                }
                .help(moreText)
                // What went wrong, readable without the tooltip: its first line, cut to one.
                if case .failed(let m) = item.state, !Self.firstLine(m).isEmpty {
                    Text(Demo.scrub(Self.firstLine(m), items: [item])).font(.caption2).foregroundStyle(.secondary)
                        .lineLimit(1).truncationMode(.tail)
                }
            }

            }

            Spacer()

            if let note = item.note, item.state == .idle {
                // From the platform, not one's own note (that one is italic, under the name): it says so.
                Text(item.platform.rawValue + ": " + note)
                    .font(.caption)
                    .help(L("Reported by \(item.platform.rawValue)", "Meldung von \(item.platform.rawValue)"))
                    .padding(.horizontal, 7).padding(.vertical, 2)
                    .background(Capsule().fill(item.auto ? Color.orange.opacity(0.2) : Color.secondary.opacity(0.15)))
            }
            status
            if let showDetails {
                Button(action: showDetails) { Image(systemName: "info.circle") }
                    .buttonStyle(.borderless)
                    .help(L("Details: waiting commits, files, CI, open PRs", "Details: wartende Commits, Dateien, CI, offene PRs"))
                    .accessibilityLabel(L("Details for \(Demo.mask(item.name))", "Details zu \(Demo.mask(item.name))"))
            } else {
                Image(systemName: "info.circle").foregroundStyle(.tertiary)
                    .help(L("No details: no GitHub or GitLab repo is linked to this project", "Keine Details: mit diesem Projekt ist kein GitHub- oder GitLab-Repo verknüpft"))
                    .accessibilityHidden(true)
            }
        }
        .padding(.vertical, 4)
        .contentShape(Rectangle())
        .opacity(item.deployable ? 1 : 0.55)
        .onTapGesture { if !item.state.isActive { toggle() } }
    }

    private func forVoiceOver(_ v: some View) -> some View {
        v
        // VoiceOver: one stop per project, its buttons as actions (VO-Command-Space).
        .accessibilityElement(children: .ignore)
        .accessibilityLabel(spoken)
        .accessibilityValue(item.deployable ? (item.selected ? L("selected", "ausgewählt") : L("not selected", "nicht ausgewählt")) : L("cannot be deployed here", "hier nicht deploybar"))
        .accessibilityAddTraits(item.deployable ? .isButton : [])
        .accessibilityAction { if item.deployable && !item.state.isActive { toggle() } }
        .accessibilityActions {
            if let showDetails { Button(L("Details", "Details"), action: showDetails) }
            if let showLog { Button(L("Build log", "Build-Log"), action: showLog) }
            if case .failed = item.state, let onRetry { Button(L("Try again", "Erneut versuchen"), action: onRetry) }
            if let onAutofix, !autofixBusy { Button(L("Fix with Claude", "Mit Claude beheben"), action: onAutofix) }
            if item.state.isActive, let onCancel { Button(L("Cancel the deploy", "Deploy abbrechen"), action: onCancel) }
            if let u = item.link.flatMap(URL.init(string:)) { Button(L("Open site", "Seite öffnen")) { NSWorkspace.shared.open(u) } }
        }
    }

    /// What the row's one line shows: a failed last deploy first, then what waits, then the last deploy.
    enum KeyFigure: Equatable { case failed, waiting, lastDeploy, never }
    static func keyFigure(_ i: Item) -> KeyFigure {
        if i.lastAt != nil, look(i.lastState ?? "") == .failed { return .failed }
        if i.hasNewCommits { return .waiting }
        return i.lastAt == nil ? .never : .lastDeploy
    }

    @ViewBuilder private var keyFigure: some View {
        switch Self.keyFigure(item) {
        case .waiting:
            Label(Self.waitingText(item), systemImage: "arrow.up.circle.fill")
                .font(.caption2.weight(.semibold)).foregroundStyle(.blue)
        case .failed, .lastDeploy, .never:
            lastDeploy
        }
    }

    /// Everything the row no longer shows as text: source, last deploy, newest commit, costs, open PRs.
    private var moreText: String {
        var lines = [Demo.on ? item.platform.rawValue : item.detail]
        if Self.keyFigure(item) != .waiting, item.hasNewCommits { lines.append(Self.waitingText(item)) }
        if let at = item.lastAt, Self.keyFigure(item) == .waiting {
            lines.append(L("Last deploy ", "Zuletzt deployt ") + Self.ago(at) + " (" + Self.stateText(item.lastState ?? "") + ")")
        }
        if item.hasNewCommits, let m = item.headMsg {
            lines.append(L("Newest commit: ", "Neuester Commit: ") + (Demo.on ? "…" : m) + (item.headAt.map { " (\(Self.ago($0)))" } ?? ""))
        }
        if item.hasNewCommits, let since = item.oldestPendingAt {
            lines.append(L("Oldest waiting commit ", "Ältester wartender Commit ") + Self.ago(since))
        }
        if let o = item.openPRs, o > 0 { lines.append(Self.openText(item, o)) }
        if let cost, cost >= 0.01 {
            lines.append(L("Builds 7 days: ", "Builds 7 Tage: ") + cost.formatted(.currency(code: "USD"))
                         + (perBuild.map { L(", about ", ", etwa ") + $0.formatted(.currency(code: "USD")) + L(" per build", " pro Build") } ?? ""))
        }
        return lines.filter { !$0.isEmpty }.joined(separator: "\n")
    }

    /// What VoiceOver says for the row: name, what waits, the last deploy and what runs now.
    private var spoken: String {
        var parts = [Demo.mask(item.name), Demo.on ? item.platform.rawValue : item.detail]
        if pinned { parts.append(L("pinned", "angeheftet")) }
        if item.hasNewCommits { parts.append(Self.waitingText(item)) }
        if item.hasNewCommits, item.risk?.isRed == true { parts.append(L("risky to ship", "riskant zum Ausliefern")) }
        if let at = item.lastAt {
            let s = item.lastState ?? ""
            parts.append(L("last deploy ", "zuletzt deployt ") + Self.ago(at) + (["ready", "live", "succeeded"].contains(s.lowercased()) ? "" : ", " + Self.stateText(s)))
        }
        switch item.state {
        case .queued: parts.append(queueText ?? L("queued", "in der Schlange"))
        case .starting: parts.append(L("starting", "startet"))
        case .running(let s): parts.append(s)
        case .done: parts.append(item.previewId != nil ? L("preview ready", "Vorschau fertig") : L("live", "live"))
        case .failed(let m): parts.append(L("failed: ", "fehlgeschlagen: ") + Demo.scrub(m, items: [item]))
        case .skipped: parts.append(L("skipped", "übersprungen"))
        case .idle: break
        }
        if let autofix { parts.append(AgentChips.text(autofix)) }
        if let allowedUntil { parts.append(AgentChips.allowedText(allowedUntil)) }
        if let note { parts.append(L("note: ", "Notiz: ") + note) }
        return parts.filter { !$0.isEmpty }.joined(separator: ", ")
    }

    static func waitingText(_ i: Item) -> String {
        if i.rewritten { return L("New changes (branch was rewritten)", "Neue Änderungen (Branch wurde umgeschrieben)") }
        guard let c = i.pendingCommits, c > 0 else { return L("New changes", "Neue Änderungen") }
        let prs = i.pendingPRs ?? 0
        if i.pendingPartial {
            return L("\(c) \(c == 1 ? "commit" : "commits"), at least \(prs) \(prs == 1 ? "PR" : "PRs") waiting",
                     "\(c) \(c == 1 ? "Commit" : "Commits"), mindestens \(prs) \(prs == 1 ? "PR wartet" : "PRs warten")")
        }
        let commits = L("\(c) \(c == 1 ? "commit" : "commits")", "\(c) \(c == 1 ? "Commit" : "Commits")")
        return prs > 0 ? commits + " · " + L("\(prs) \(prs == 1 ? "PR" : "PRs") waiting", "\(prs) \(prs == 1 ? "PR wartet" : "PRs warten")")
                       : commits + L(" waiting", c == 1 ? " wartet" : " warten")
    }

    /// "Copy the error": tokens masked like the log's Copy; in demo mode with the stand-ins the screen shows.
    static func errorCopy(_ i: Item, _ msg: String) -> String {
        LogTools.maskSecrets(Demo.on ? Demo.mask(i.name) + ": " + Demo.scrub(msg, items: [i]) : i.name + ": " + msg)
    }

    /// The first line of a failure, for the row: the rest is in the tooltip and the log.
    static func firstLine(_ msg: String) -> String {
        msg.split(whereSeparator: \.isNewline).first.map { String($0).trimmingCharacters(in: .whitespaces) } ?? ""
    }

    static func openText(_ i: Item, _ o: Int) -> String {
        var parts: [String] = []
        if let d = i.openDrafts, d > 0 { parts.append(L("\(d) \(d == 1 ? "draft" : "drafts")", "\(d) \(d == 1 ? "Entwurf" : "Entwürfe")")) }
        if let b = i.openBots, b > 0 { parts.append(L("\(b) \(b == 1 ? "bot" : "bots")", "\(b) \(b == 1 ? "Bot" : "Bots")")) }
        let base = L("\(o) open \(o == 1 ? "PR" : "PRs")", "\(o) \(o == 1 ? "offener PR" : "offene PRs")")
        return parts.isEmpty ? base : base + " (" + parts.joined(separator: ", ") + ")"
    }

    /// Built once: a formatter per row and render was the most expensive part of a list update.
    private static let relative: RelativeDateTimeFormatter = {
        let f = RelativeDateTimeFormatter()
        f.locale = Locale(identifier: isGerman ? "de_DE" : "en_US")
        f.unitsStyle = .full
        return f
    }()

    static func ago(_ d: Date) -> String { relative.localizedString(for: d, relativeTo: Date()) }

    /// Vercel's and Render's deploy states in words ("build_failed" → "Build failed").
    static func stateText(_ raw: String) -> String {
        switch raw.lowercased() {
        case "": return L("unknown", "unbekannt")
        case "ready", "live", "succeeded": return L("live", "live")
        case "error": return L("failed", "fehlgeschlagen")
        case "build_failed": return L("build failed", "Build fehlgeschlagen")
        case "update_failed": return L("update failed", "Update fehlgeschlagen")
        case "pre_deploy_failed": return L("pre-deploy step failed", "Pre-Deploy-Schritt fehlgeschlagen")
        case "canceled", "cancelled": return L("cancelled", "abgebrochen")
        case "deactivated": return L("deactivated", "deaktiviert")
        case "building", "build_in_progress": return L("building", "baut")
        case "update_in_progress": return L("updating", "wird aktualisiert")
        case "pre_deploy_in_progress": return L("pre-deploy step running", "Pre-Deploy-Schritt läuft")
        case "queued", "created": return L("queued", "wartet")
        case "initializing": return L("starting", "startet")
        default: return raw.replacingOccurrences(of: "_", with: " ")
        }
    }

    /// How the last deploy's state looks: live, failed, stopped by someone, or still on its way.
    enum DeployLook: Equatable { case ok, failed, cancelled, other }
    static func look(_ raw: String) -> DeployLook {
        let s = raw.lowercased()
        if ["ready", "live", "succeeded"].contains(s) { return .ok }
        // A cancelled deploy is no failure: grey, and both spellings (Vercel "canceled", others "cancelled").
        if s == "canceled" || s == "cancelled" { return .cancelled }
        if s.contains("fail") || s == "error" { return .failed }
        return .other
    }

    @ViewBuilder private var lastDeploy: some View {
        if let at = item.lastAt {
            let s = (item.lastState ?? "").lowercased()
            let look = Self.look(s)
            let ok = look == .ok, failed = look == .failed
            HStack(spacing: 4) {
                if noColour {
                    Image(systemName: ok ? "checkmark.circle" : failed ? "xmark.circle" : look == .cancelled ? "minus.circle" : "clock").font(.caption2)
                } else {
                    Circle().fill(ok ? Color.green : failed ? Color.red : look == .cancelled ? Color.secondary : Color.orange).frame(width: 7, height: 7)
                }
                Text(L("Last deploy ", "Zuletzt deployt ") + Self.ago(at) + (ok ? "" : " · " + Self.stateText(s)))
                    .font(.caption2).foregroundStyle(.secondary)
                if failed, let showLog {
                    Button(action: showLog) { Image(systemName: "text.alignleft").font(.caption2) }
                        .buttonStyle(.borderless).help(L("Show the build log of the failed deploy", "Build-Log des fehlgeschlagenen Deploys zeigen"))
                        .accessibilityLabel(L("Build log", "Build-Log"))
                }
            }
            .help(at.formatted(date: .complete, time: .shortened) + (item.lastMsg.map { "\nLive: " + (Demo.on ? "…" : $0) } ?? ""))
        } else {
            Text(L("Never deployed", "Noch nie deployt")).font(.caption2).foregroundStyle(.secondary)
        }
    }

    @ViewBuilder private var cancelButton: some View {
        if let onCancel {
            Button(action: onCancel) { Image(systemName: "stop.circle") }
                .buttonStyle(.borderless).help(L("Cancel", "Abbrechen")).accessibilityLabel(L("Cancel the deploy", "Deploy abbrechen"))
        }
    }

    @ViewBuilder private var status: some View {
        switch item.state {
        case .idle:
            EmptyView()
        case .queued:
            HStack(spacing: 6) {
                Image(systemName: "hourglass").foregroundStyle(.secondary)
                Text(queueText ?? L("queued", "in der Schlange")).font(.caption)
                cancelButton
            }
        case .starting:
            HStack(spacing: 6) { ProgressView().controlSize(.small); Text(L("starting", "startet")).font(.caption) }
        case .running(let s):
            HStack(spacing: 6) {
                ProgressView().controlSize(.small)
                if let start = item.startedAt {
                    // Seconds since the start, so a long build is seen as long.
                    TimelineView(.periodic(from: .now, by: 1)) { ctx in
                        let secs = Int(ctx.date.timeIntervalSince(start))
                        Text("\(s) · \(secs / 60):\(String(format: "%02d", secs % 60))"
                             + (usualMinutes.map { L(" (usually ~\($0) min)", " (meist ~\($0) Min)") } ?? ""))
                            .font(.caption.monospacedDigit())
                            // Twice as long as usual: something may be stuck.
                            .foregroundStyle(usualMinutes.map { secs > 120 * $0 } == true ? Color.warningText : Color.primary)
                    }
                } else { Text(s).font(.caption) }
                cancelButton
            }
        case .done(let url):
            HStack(spacing: 6) {
                // A preview is not live: it says so, in blue.
                if item.previewId != nil {
                    Label(L("Preview ready", "Vorschau fertig"), systemImage: "eye.circle.fill").foregroundStyle(.blue).font(.caption.weight(.semibold))
                } else {
                    Label("Live", systemImage: "checkmark.circle.fill").foregroundStyle(.green).font(.caption.weight(.semibold))
                }
                if let url, let u = URL(string: url) {
                    Button { NSWorkspace.shared.open(u) } label: { Image(systemName: "arrow.up.right.square") }
                        .buttonStyle(.borderless).help(url).accessibilityLabel(L("Open the deployed site", "Deployte Seite öffnen"))
                    if item.previewId != nil {
                        CopyButton(title: L("Copy the preview link", "Vorschau-Link kopieren"), systemImage: "link") { url }
                            .buttonStyle(.borderless)
                    }
                }
            }
        case .skipped(let msg):
            Label(L("Skipped", "Übersprungen"), systemImage: "forward.circle.fill")
                .foregroundStyle(.secondary).font(.caption.weight(.semibold))
                .help(Demo.scrub(msg, items: [item]))
        case .failed(let msg):
            HStack(spacing: 4) {
                Label(L("Failed", "Fehler"), systemImage: "xmark.octagon.fill")
                    .foregroundStyle(.red).font(.caption.weight(.semibold))
                    .help(Demo.scrub(msg, items: [item]))
                CopyButton(title: L("Copy the error", "Fehler kopieren"), systemImage: "doc.on.doc") { Self.errorCopy(item, msg) }
                    .buttonStyle(.borderless)
                if let showLog {
                    Button(action: showLog) { Image(systemName: "text.alignleft") }
                        .buttonStyle(.borderless).help(L("Build log", "Build-Log")).accessibilityLabel(L("Build log", "Build-Log"))
                }
                if let onRetry {
                    Button(action: onRetry) { Image(systemName: "arrow.clockwise") }
                        .buttonStyle(.borderless).help(L("Try again", "Erneut versuchen")).accessibilityLabel(L("Try again", "Erneut versuchen"))
                }
            }
        }
    }
}

/// Autofix and a temporary auto-deploy allowance, as small chips on the row. Own view, so the
/// row's body stays short enough for the type checker of older Xcode versions.
struct AgentChips: View {
    let autofix: RowAutofix?
    let allowedUntil: Date?
    var busy = false
    var onFix: (() -> Void)? = nil

    static func text(_ a: RowAutofix) -> String {
        switch a {
        case .fixing: return L("Claude is fixing it", "Claude behebt gerade")
        case .prOpen(let n, _): return L("Fix PR #\(n) open", "Fix-PR #\(n) offen")
        case .merged: return L("Fix merged – deploy now", "Fix gemergt – jetzt deployen")
        case .handedBack: return L("Fix failed – over to you", "Fix fehlgeschlagen – an dich übergeben")
        case .noPR: return L("No fix PR from Claude – see session", "Kein Fix-PR von Claude – Sitzung ansehen")
        }
    }
    static func allowedText(_ until: Date) -> String {
        let t = until.formatted(date: Calendar.current.isDateInToday(until) ? .omitted : .abbreviated, time: .shortened)
        return L("Auto-deploy allowed until \(t)", "Auto-Deploy erlaubt bis \(t)")
    }
    /// The page a chip opens; none in demo mode, where a URL would show the repo.
    static func link(_ a: RowAutofix) -> URL? {
        switch a {
        case .fixing(let u), .noPR(let u): return u
        case .prOpen(_, let u), .merged(_, _, let u): return u
        case .handedBack: return nil
        }
    }

    var body: some View {
        if let autofix { chip(autofix) }
        if let allowedUntil {
            Label(Self.allowedText(allowedUntil), systemImage: "bolt.badge.clock")
                .font(.caption2.weight(.semibold)).foregroundStyle(.orange)
                .help(L("A temporary allowance: pushes deploy by themselves until then, then auto-deploy goes off again",
                        "Vorübergehend erlaubt: Pushes deployen bis dahin von selbst, danach ist Auto-Deploy wieder aus"))
        }
        if let onFix {
            Button(action: onFix) {
                HStack(spacing: 4) {
                    if busy { ProgressView().controlSize(.mini) } else { Image(systemName: "wand.and.stars") }
                    Text(L("Fix with Claude", "Mit Claude beheben"))
                }
            }
            .buttonStyle(.link).font(.caption2.weight(.semibold)).disabled(busy)
            .help(L("Hand this failed build to your Claude Code routine now; it opens a fix PR",
                    "Diesen fehlgeschlagenen Build jetzt an deine Claude-Code-Routine übergeben; sie öffnet einen Fix-PR"))
        }
    }

    @ViewBuilder private func chip(_ a: RowAutofix) -> some View {
        let (icon, colour): (String, Color) = {
            switch a {
            case .fixing: return ("sparkles", .purple)
            case .prOpen: return ("arrow.triangle.pull", .blue)
            case .merged: return ("checkmark.seal.fill", .green)
            case .handedBack: return ("person.fill.questionmark", Color.warningText)
            case .noPR: return ("exclamationmark.bubble", Color.warningText)
            }
        }()
        if let u = Self.link(a), !Demo.on {
            Button { NSWorkspace.shared.open(u) } label: { Label(Self.text(a), systemImage: icon) }
                .buttonStyle(.link).font(.caption2.weight(.semibold)).foregroundStyle(colour)
                .help(u.absoluteString)
        } else {
            Label(Self.text(a), systemImage: icon).font(.caption2.weight(.semibold)).foregroundStyle(colour)
        }
    }
}

/// Above the list while any project may deploy by itself for a while.
struct AllowanceBanner: View {
    @ObservedObject var store: Store
    let allItems: [Item]

    /// Its own function: as one expression in the body it was too long for the type checker on CI.
    static func text(_ on: [AutoDeployAllowance], until last: Date) -> String {
        let names: String = on.prefix(4).map { Demo.mask($0.project) }.joined(separator: ", ")
        let more: String = on.count > 4 ? L(" and \(on.count - 4) more", " und \(on.count - 4) weitere") : ""
        let style: Date.FormatStyle.DateStyle = Calendar.current.isDateInToday(last) ? .omitted : .abbreviated
        let when: String = last.formatted(date: style, time: .shortened)
        return L("Auto-deploy is allowed for a while: ", "Auto-Deploy ist vorübergehend erlaubt: ") + names + more + " · " + L("until ", "bis ") + when
    }
    var body: some View {
        let on = store.activeAllowances
        if let last = on.map(\.expiresAt).max() {
            HStack(spacing: 10) {
                Image(systemName: "bolt.badge.clock.fill").foregroundStyle(.orange)
                Text(Self.text(on, until: last)).font(.caption)
                Spacer()
            }
            .padding(.horizontal, 12).padding(.vertical, 6)
            .background(Color.orange.opacity(contrast == .increased ? 0.2 : 0.08))   // stronger with "Increase contrast"
        }
    }
    @Environment(\.colorSchemeContrast) private var contrast
}
