import SwiftUI

/// `deploys repos … --json` (lib/repos.sh): the local checkouts and how they stand against origin.
struct RepoCareReport: Decodable {
    struct Repo: Decodable, Identifiable {
        let name: String; let path: String; let branch: String; let `default`: String
        let state: String; let action: String; let behind: Int; let ahead: Int; let note: String
        let worktrees: Int; let needsHand: Bool
        var id: String { path }
    }
    struct Summary: Decodable { let repos: Int; let updated: Int; let needsHand: Int; let unmerged: Int; let worktrees: Int }
    let ranAt: String?
    let applied: Bool?
    let repos: [Repo]
    let summary: Summary?
}

/// Window "Repo Upkeep": every checkout, the ones that need a person on top, "Sync now" and the schedule.
/// Sync only does what cannot lose work (fast-forward, back to main from a merged branch); the click is the --yes.
struct RepoCareView: View {
    @State private var report: RepoCareReport?
    @State private var busy = false
    @State private var error: String?
    @State private var done: String?
    @State private var scheduled = false
    @State private var scheduleOnDisk: Bool?   // what the job is now; the toggle only acts when it differs

    private var needsHand: [RepoCareReport.Repo] { report?.repos.filter { $0.needsHand } ?? [] }
    private var others: [RepoCareReport.Repo] { report?.repos.filter { !$0.needsHand } ?? [] }

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            Text(L("Repo upkeep", "Repo-Pflege")).font(.title2.bold())
            Text(L("Keeps the local checkouts on top of origin/main: a clean main is fast-forwarded, a merged branch goes back to main. Changes, conflicts and branches with work of their own are never touched.",
                   "Hält die lokalen Checkouts auf dem Stand von origin/main: ein sauberer main wird vorgespult, ein gemergter Branch geht zurück auf main. Änderungen, Konflikte und Branches mit eigener Arbeit werden nie angefasst."))
                .font(.callout).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
            Toggle(L("Every 30 minutes and at login", "Alle 30 Minuten und beim Anmelden"), isOn: $scheduled)
                .onChange(of: scheduled) { _, on in if let d = scheduleOnDisk, d != on { Task { await setSchedule(on) } } }
            if let e = error { Text(e).foregroundStyle(.red).font(.callout) }
            if let d = done { Label(d, systemImage: "checkmark.circle.fill").foregroundStyle(.green) }
            if report != nil {
                List {
                    if !needsHand.isEmpty {
                        Section(L("Needs you", "Braucht dich")) { ForEach(needsHand) { row($0) } }
                    }
                    Section(L("Checkouts", "Checkouts")) { ForEach(others) { row($0) } }
                }
                .frame(minHeight: 260)
                if let at = report?.ranAt { Text(L("Last run: \(at)", "Letzter Lauf: \(at)")).font(.caption).foregroundStyle(.secondary) }
            } else if busy {
                ProgressView(L("Looking …", "Wird geprüft …"))
            }
            HStack {
                Button(L("Check again", "Neu prüfen")) { Task { await load(fetch: true) } }.disabled(busy)
                Spacer()
                if busy { ProgressView().controlSize(.small) }
                Button(L("Sync now", "Jetzt pflegen")) { Task { await sync() } }
                    .buttonStyle(.borderedProminent).disabled(busy)
            }
        }
        .padding(20)
        .frame(minWidth: 560, minHeight: 460)
        .task { await readSchedule(); await load(fetch: false) }
    }

    private func icon(_ s: String) -> (String, Color) {
        switch s {
        case "current", "updated", "switched": return ("checkmark.circle.fill", .green)
        case "behind", "merged": return ("arrow.down.circle", .blue)
        case "unmerged", "detached", "no-remote": return ("arrow.triangle.branch", .secondary)
        default: return ("exclamationmark.triangle.fill", .orange)
        }
    }

    @ViewBuilder private func row(_ r: RepoCareReport.Repo) -> some View {
        let look = icon(r.state)
        HStack(alignment: .top) {
            Image(systemName: look.0).foregroundStyle(look.1)
            VStack(alignment: .leading, spacing: 2) {
                HStack {
                    Text(r.name).bold()
                    Text(r.branch.isEmpty ? "–" : r.branch).font(.caption.monospaced()).foregroundStyle(.secondary)
                    Spacer()
                    if r.behind > 0 { Text(L("\(r.behind) behind", "\(r.behind) zurück")).font(.caption).monospacedDigit() }
                    if r.ahead > 0 { Text(L("\(r.ahead) ahead", "\(r.ahead) voraus")).font(.caption).monospacedDigit() }
                }
                if !r.action.isEmpty { Text(r.action).font(.caption) }
                if !r.note.isEmpty { Text(r.note).font(.caption).foregroundStyle(.secondary).textSelection(.enabled) }
            }
        }
        .contextMenu {
            Button(L("Show in Finder", "Im Finder zeigen")) { NSWorkspace.shared.activateFileViewerSelecting([URL(fileURLWithPath: r.path)]) }
        }
    }

    /// The last result first (no network); "Check again" fetches.
    private func load(fetch: Bool) async {
        busy = true; error = nil
        do {
            let args = fetch ? ["repos", "status", "--json"] : ["repos", "last", "--json"]
            let r = try JSONDecoder().decode(RepoCareReport.self, from: try await Tool.run(args, timeout: 900))
            if !fetch && r.ranAt == nil { await load(fetch: true); return }
            report = r
        } catch { self.error = "\(error.localizedDescription)" }
        busy = false
    }

    private func sync() async {
        busy = true; error = nil; done = nil
        do {
            let r = try JSONDecoder().decode(RepoCareReport.self, from: try await Tool.run(["repos", "sync", "--yes", "--json"], timeout: 1800))
            report = r
            let s = r.summary
            done = L("\(s?.updated ?? 0) updated, \(s?.worktrees ?? 0) worktrees removed, \(s?.needsHand ?? 0) need you",
                     "\(s?.updated ?? 0) aktualisiert, \(s?.worktrees ?? 0) Worktrees entfernt, \(s?.needsHand ?? 0) brauchen dich")
        } catch { self.error = "\(error.localizedDescription)" }
        busy = false
    }

    private func readSchedule() async {
        if let d = try? await Tool.run(["repos", "schedule", "status"], timeout: 30), let t = String(data: d, encoding: .utf8) {
            scheduleOnDisk = t.hasPrefix("on"); scheduled = t.hasPrefix("on")
        }
    }

    private func setSchedule(_ on: Bool) async {
        do { _ = try await Tool.run(["repos", "schedule", on ? "on" : "off"], timeout: 60); scheduleOnDisk = on }
        catch { self.error = "\(error.localizedDescription)" }
    }
}

/// Deploy menu → "Repo Upkeep …".
struct RepoCareCommand: Commands {
    @Environment(\.openWindow) private var openWindow
    var body: some Commands {
        CommandGroup(after: .toolbar) {
            Button(L("Repo Upkeep …", "Repo-Pflege …")) { openWindow(id: "repos"); NSApp.activate(ignoringOtherApps: true) }
        }
    }
}
