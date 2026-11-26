// Deploy Center — Claude Code cloud sessions: which ones finished, wait or seem stuck (`deploys sessions --json`).
// GitHub is the signal (lib/sessions.sh): a merged pull request means a session is done and a slot is free.
// Read only: nothing here pushes, merges or closes anything.

import SwiftUI
import AppKit

struct SessionsReport: Decodable, Equatable {
    struct Settings: Decodable, Equatable { let prefix: String; let wait: Int; let idle: Int; let hours: Int }
    struct Summary: Decodable, Equatable { let merged: Int; let mergedLastHour: Int; let open: Int; let waiting: Int; let stuck: Int; let closed: Int }
    struct RepoError: Decodable, Equatable { let repo: String; let error: String }
    struct Row: Decodable, Equatable, Identifiable {
        let repo: String; let branch: String; let state: String; let title: String?
        let pr: Int?; let url: String?; let session: String?
        let began: String?; let ended: String?; let minutes: Int?; let idleMinutes: Int?
        var id: String { repo + "#" + branch }
    }
    let settings: Settings; let repos: [String]; let errors: [RepoError]; let summary: Summary; let sessions: [Row]
}

/// Pure: which rows are news since the keys already seen. A key is "repo#branch:state", so every state is told once.
enum SessionsNews {
    static func key(_ r: SessionsReport.Row) -> String { r.id + ":" + r.state }
    static let told: Set<String> = ["merged", "closed", "waiting", "stuck"]
    static func fresh(_ rows: [SessionsReport.Row], seen: Set<String>) -> [SessionsReport.Row] {
        rows.filter { told.contains($0.state) && !seen.contains(key($0)) }
    }
    /// The keys to remember. Pruned to the rows still in the window only when every repo was read: a repo that
    /// failed this time has no rows in `live`, and forgetting its keys would tell them as news next time.
    static func kept(seen: Set<String>, live: Set<String>, complete: Bool) -> Set<String> {
        complete ? seen.intersection(live) : seen
    }
    /// The notifications for the news: finished ones as one note ("3 sessions done"), the others one each.
    static func notes(_ news: [SessionsReport.Row], hold: Int) -> [(id: String, title: String, body: String)] {
        var out: [(id: String, title: String, body: String)] = []
        let done = news.filter { $0.state == "merged" || $0.state == "closed" }
        if !done.isEmpty {
            let names = done.prefix(4).map { $0.title ?? $0.branch }.joined(separator: " · ")
            let n = done.count
            out.append(("sessions-done-\(Int(Date().timeIntervalSince1970))",
                        n == 1 ? L("Cloud session done: room for a new one", "Cloud-Session fertig: Platz für eine neue")
                               : L("\(n) cloud sessions done: room for \(n) new ones", "\(n) Cloud-Sessions fertig: Platz für \(n) neue"),
                        names))
        }
        for r in news where r.state == "waiting" {
            out.append(("sessions-" + key(r), L("Pull request waits: #\(r.pr ?? 0)", "Pull Request wartet: #\(r.pr ?? 0)"), r.title ?? r.branch))
        }
        for r in news where r.state == "stuck" {
            out.append(("sessions-" + key(r), L("Session seems stuck for \(r.idleMinutes ?? hold) min", "Session hängt seit \(r.idleMinutes ?? hold) Min."),
                        (r.pr.map { "#\($0) " } ?? "") + (r.title ?? r.branch)))
        }
        return out
    }
}

/// Polls `deploys sessions --json` once a minute while the app runs and tells news as Mac notifications.
/// The first answer after a start only fills the memory, so a restart does not repeat old news.
@MainActor final class SessionsWatch: ObservableObject {
    static let shared = SessionsWatch()
    @Published private(set) var report: SessionsReport?
    @Published private(set) var error: String?
    @Published private(set) var loading = false
    @Published private(set) var checkedAt: Date?
    private var timer: Timer?
    private let seenKey = "sessionsSeen"

    /// The menu bar line: "Cloud sessions: 2 done, 1 waiting" when something is there.
    var menuTitle: String {
        guard let s = report?.summary else { return L("Cloud Sessions …", "Cloud-Sessions …") }
        var parts: [String] = []
        if s.mergedLastHour > 0 { parts.append(L("\(s.mergedLastHour) done", "\(s.mergedLastHour) fertig")) }
        if s.waiting > 0 { parts.append(L("\(s.waiting) waiting", "\(s.waiting) wartet")) }
        if s.stuck > 0 { parts.append(L("\(s.stuck) stuck", "\(s.stuck) hängt")) }
        return parts.isEmpty ? L("Cloud Sessions …", "Cloud-Sessions …") : L("Cloud sessions: ", "Cloud-Sessions: ") + parts.joined(separator: ", ")
    }

    func start() {
        guard timer == nil else { return }
        Task { await refresh() }
        timer = Timer.scheduledTimer(withTimeInterval: 60, repeats: true) { _ in Task { @MainActor in await SessionsWatch.shared.refresh() } }
    }

    func refresh() async {
        guard !loading else { return }
        loading = true; defer { loading = false }
        do {
            let r = try await Tool.json(["sessions", "--json"], as: SessionsReport.self, timeout: 45)
            report = r; error = nil; checkedAt = Date()
            tell(r)
        } catch {
            self.error = (error as? ToolError)?.message ?? error.localizedDescription
        }
    }

    private func tell(_ r: SessionsReport) {
        let d = UserDefaults.standard
        let first = d.object(forKey: seenKey) == nil
        var seen = Set(d.stringArray(forKey: seenKey) ?? [])
        let news = SessionsNews.fresh(r.sessions, seen: seen)
        guard !news.isEmpty || first else { return }
        if !first && d.object(forKey: "sessionNotifications") as? Bool ?? true {
            for n in SessionsNews.notes(news, hold: r.settings.idle) { Notify.remind(n.title, n.body, id: n.id) }
        }
        news.forEach { seen.insert(SessionsNews.key($0)) }
        // Only keys of rows still in the window are kept, so the memory does not grow without end.
        let live = Set(r.sessions.map(SessionsNews.key))
        d.set(Array(SessionsNews.kept(seen: seen, live: live, complete: r.errors.isEmpty)), forKey: seenKey)
    }

    /// `deploys sessions add|remove <owner/name>`, then a fresh look.
    func change(_ verb: String, _ repo: String) async {
        do { _ = try await Tool.run(["sessions", verb, repo], timeout: 15) } catch {
            self.error = (error as? ToolError)?.message ?? error.localizedDescription; return
        }
        await refresh()
    }
}

struct SessionsView: View {
    @ObservedObject var watch = SessionsWatch.shared
    @State private var newRepo = ""
    @AppStorage("sessionNotifications") private var notify = true

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            header
            if let e = watch.error { Text(Demo.mask(e)).foregroundStyle(Color.dangerText).font(.callout).textSelection(.enabled) }
            if let r = watch.report {
                ForEach(r.errors, id: \.repo) { e in
                    Text(L("\(Demo.mask(e.repo)): not read – \(Demo.mask(e.error))", "\(Demo.mask(e.repo)): nicht gelesen – \(Demo.mask(e.error))")).foregroundStyle(Color.warningText).font(.callout)
                }
                if r.sessions.isEmpty {
                    Text(r.repos.isEmpty ? L("No repo is watched yet. Add one below (owner/name).", "Noch kein Repo beobachtet. Unten eines hinzufügen (owner/name).")
                                         : L("No session branch or pull request in the last \(r.settings.hours) h.", "Kein Session-Branch und kein Pull Request in den letzten \(r.settings.hours) Std."))
                        .foregroundStyle(.secondary).frame(maxWidth: .infinity, minHeight: 80)
                } else {
                    List(r.sessions) { SessionRow(row: $0, multiRepo: r.repos.count > 1) }.listStyle(.inset(alternatesRowBackgrounds: true))
                }
                footer(r)
            } else if watch.loading {
                ProgressView().frame(maxWidth: .infinity, minHeight: 80)
            }
        }
        .padding(14)
        .frame(minWidth: 560, minHeight: 360)
        .task { SessionsWatch.shared.start(); await watch.refresh() }
    }

    private var header: some View {
        HStack(alignment: .firstTextBaseline) {
            if let s = watch.report?.summary {
                Text(L("\(s.mergedLastHour) done in the last hour", "\(s.mergedLastHour) fertig in der letzten Stunde")).font(.headline)
                badge(s.waiting, L("waiting", "wartet"), .orange)
                badge(s.stuck, L("stuck", "hängt"), .red)
                badge(s.open, L("open", "offen"), .blue)
            } else { Text(L("Cloud sessions", "Cloud-Sessions")).font(.headline) }
            Spacer()
            if let at = watch.checkedAt { Text(L("As of ", "Stand ") + uiTime(at)).foregroundStyle(.secondary).font(.caption) }
            Button { Task { await watch.refresh() } } label: { Image(systemName: "arrow.clockwise") }
                .disabled(watch.loading).help(L("Check now", "Jetzt prüfen"))
        }
    }

    private func badge(_ n: Int, _ label: String, _ color: Color) -> some View {
        Text("\(n) \(label)").font(.callout).padding(.horizontal, 7).padding(.vertical, 2)
            .background(Capsule().fill(color.opacity(n > 0 ? 0.18 : 0.06))).foregroundStyle(n > 0 ? color : .secondary)
    }

    private func footer(_ r: SessionsReport) -> some View {
        VStack(alignment: .leading, spacing: 6) {
            HStack {
                ForEach(r.repos, id: \.self) { repo in
                    Text(repo).font(.caption).padding(.horizontal, 6).padding(.vertical, 2).background(Capsule().fill(.quaternary))
                        .contextMenu { Button(L("Stop watching", "Nicht mehr beobachten")) { Task { await watch.change("remove", repo) } } }
                }
                TextField(L("owner/name", "owner/name"), text: $newRepo).textFieldStyle(.roundedBorder).frame(maxWidth: 200)
                    .onSubmit(add)
                Button(L("Watch", "Beobachten"), action: add).disabled(!valid)
            }
            HStack {
                Toggle(L("Notify me", "Mitteilungen"), isOn: $notify)
                Text(L("Branches \(r.settings.prefix.isEmpty ? "(all)" : r.settings.prefix) · waits after \(r.settings.wait) min · stuck after \(r.settings.idle) min · deploys sessions set …",
                       "Branches \(r.settings.prefix.isEmpty ? "(alle)" : r.settings.prefix) · wartet nach \(r.settings.wait) Min. · hängt nach \(r.settings.idle) Min. · deploys sessions set …"))
                    .font(.caption).foregroundStyle(.secondary)
            }
        }
    }

    private var valid: Bool { newRepo.range(of: "^[A-Za-z0-9_.-]+/[A-Za-z0-9_.-]+$", options: .regularExpression) != nil }
    private func add() {
        guard valid else { return }
        let r = newRepo; newRepo = ""
        Task { await watch.change("add", r) }
    }
}

struct SessionRow: View {
    let row: SessionsReport.Row
    let multiRepo: Bool

    var body: some View {
        HStack(spacing: 10) {
            Image(systemName: icon).foregroundStyle(color).frame(width: 18).help(stateText)
            VStack(alignment: .leading, spacing: 2) {
                Text(Demo.mask(row.title ?? row.branch)).lineLimit(1)
                Text((multiRepo ? Demo.mask(row.repo) + " · " : "") + Demo.mask(row.branch) + " · " + stateText + detail)
                    .font(.caption).foregroundStyle(.secondary).lineLimit(1)
            }
            Spacer()
            if let s = row.session, let u = URL(string: s) {
                Button { SafeLink.open(u) } label: { Image(systemName: "sparkles") }
                    .buttonStyle(.borderless).help(L("Open the Claude session", "Claude-Session öffnen"))
                    .accessibilityLabel(L("Open the Claude session of \(row.title ?? row.branch)", "Claude-Session von \(row.title ?? row.branch) öffnen"))
            }
            if let s = row.url, let u = URL(string: s), let n = row.pr {
                Button("#\(n)") { SafeLink.open(u) }.buttonStyle(.borderless).help(L("Open the pull request", "Pull Request öffnen"))
                    .accessibilityLabel(L("Open pull request \(n) of \(row.title ?? row.branch)", "Pull Request \(n) von \(row.title ?? row.branch) öffnen"))
            }
        }
        .padding(.vertical, 2)
    }

    private var stateText: String {
        switch row.state {
        case "merged": return L("merged", "gemergt")
        case "closed": return L("closed", "geschlossen")
        case "waiting": return L("pull request waits", "Pull Request wartet")
        case "stuck": return L("stuck", "hängt")
        case "pushed": return L("pushed, no pull request", "gepusht, kein Pull Request")
        default: return L("open", "offen")
        }
    }
    private var detail: String {
        var s = ""
        if let m = row.minutes { s += L(" · \(m) min since the first commit", " · \(m) Min. seit dem ersten Commit") }
        if let q = row.idleMinutes, row.state != "open" { s += L(" · quiet \(q) min", " · still seit \(q) Min.") }
        return s
    }
    private var icon: String {
        switch row.state {
        case "merged": return "checkmark.circle.fill"
        case "closed": return "xmark.circle"
        case "waiting": return "hourglass"
        case "stuck": return "exclamationmark.triangle.fill"
        default: return "arrow.triangle.branch"
        }
    }
    private var color: Color {
        switch row.state {
        case "merged": return .green
        case "waiting": return .orange
        case "stuck": return .red
        case "closed": return .secondary
        default: return .blue
        }
    }
}
