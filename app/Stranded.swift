// Deploy Center — Work left behind in local checkouts and worktrees (uncommitted changes, commits on no remote),
// for example after a session was archived by mistake. The list comes from `deploys repos stranded --json`
// (lib/stranded.sh), scanned once an hour in the background. Rescuing one folder is a click and a confirmation: its
// changes go to a new branch and a draft pull request (`deploys repos rescue <folder> --yes`); the folder is not changed.

import AppKit
import SwiftUI

struct StrandedReport: Decodable, Equatable {
    struct Item: Decodable, Equatable, Identifiable {
        let path: String
        let name: String
        let repoName: String
        let branch: String
        let changed: Int
        let unpushed: Int
        let idleHours: Int
        let session: String
        let title: String
        let `class`: String
        var id: String { path }
    }
    struct Summary: Decodable, Equatable { let folders: Int; let archived: Int; let noSession: Int; let files: Int; let unpushed: Int }
    let items: [Item]
    let summary: Summary
    /// Set when the scan did not run (the Mac was overloaded): not a fresh look, so it changes no notification state.
    let skipped: String?
}

struct StrandedPlan: Decodable {
    let branch: String
    let base: String
    let visibility: String
    let files: Int
    let unpushed: Int
    let problems: [String]
    let state: String
    let note: String
    let pr: String?
}

enum StrandedText {
    static func summary(_ r: StrandedReport) -> String {
        L("Left-behind work: \(r.summary.folders) folders (\(r.summary.archived) from archived sessions)",
          "Liegengebliebene Arbeit: \(r.summary.folders) Ordner (\(r.summary.archived) aus archivierten Sitzungen)")
    }

    static func what(_ i: StrandedReport.Item) -> String {
        var p: [String] = []
        if i.changed > 0 { p.append(L("\(i.changed) files", "\(i.changed) Dateien")) }
        if i.unpushed > 0 { p.append(L("\(i.unpushed) unpushed", "\(i.unpushed) nicht gepusht")) }
        return p.joined(separator: ", ")
    }

    static func line(_ i: StrandedReport.Item) -> String {
        let tag = i.class == "archived" ? L("archived", "archiviert") : (i.class == "no-session" ? L("no session", "keine Sitzung") : L("idle", "untätig"))
        return "\(Demo.mask(i.name)) (\(Demo.mask(i.repoName))) – \(what(i)) – \(tag), \(LocalSessionsText.age(i.idleHours * 60))"
    }
}

@MainActor
final class StrandedMonitor: ObservableObject {
    static let shared = StrandedMonitor()
    @Published private(set) var report: StrandedReport?
    @Published private(set) var message: String?
    @Published private(set) var scanning = false
    private var task: Task<Void, Never>?
    private let seenKey = "strandedSeen"

    /// The last result at once (no git), then a full scan every hour.
    func start() {
        guard task == nil else { return }
        task = Task { [weak self] in
            if let r = try? await Tool.json(["repos", "stranded", "--cached", "--json"], as: StrandedReport.self, timeout: 30) { self?.report = r }
            while !Task.isCancelled {
                await self?.scan()
                try? await Task.sleep(nanoseconds: 3_600_000_000_000)
            }
        }
    }

    func scan() async {
        guard !scanning else { return }
        scanning = true; defer { scanning = false }
        guard let r = try? await Tool.json(["repos", "stranded", "--json"], as: StrandedReport.self, timeout: 900) else { return }
        if r != report { report = r }
        if r.skipped == nil { tell(r) }
    }

    /// A notification for a folder from an archived session that is new in the list; the first scan is silent.
    private func tell(_ r: StrandedReport) {
        let d = UserDefaults.standard
        let first = d.object(forKey: seenKey) == nil
        let seen = Set(d.stringArray(forKey: seenKey) ?? [])
        let fresh = r.items.filter { $0.class == "archived" && !seen.contains($0.path) }
        if !first && d.object(forKey: "sessionNotifications") as? Bool ?? true {
            for i in fresh.prefix(3) {
                Notify.remind(L("Work left in an archived session", "Arbeit in einer archivierten Sitzung liegen geblieben"),
                              L("\(Demo.mask(i.name)): \(StrandedText.what(i)). Rescue it as a draft pull request from the menu.",
                                "\(Demo.mask(i.name)): \(StrandedText.what(i)). Im Menü als Entwurfs-PR retten."),
                              id: "stranded-" + i.path)
            }
        }
        d.set(r.items.map(\.path), forKey: seenKey)
    }

    /// Rescue one folder: first what would happen, then the person says yes.
    func rescue(_ i: StrandedReport.Item) async {
        let plan: StrandedPlan
        do { plan = try await Tool.json(["repos", "rescue", i.path, "--json"], as: StrandedPlan.self, timeout: 120) }
        catch { message = LogTools.maskSecrets((error as? ToolError)?.message ?? error.localizedDescription); return }
        let a = NSAlert()
        NSApp.activate(ignoringOtherApps: true)
        guard plan.state == "plan" else {
            a.messageText = plan.state == "refused" ? L("Not rescued", "Nicht gerettet") : L("Nothing to do", "Nichts zu tun")
            a.informativeText = ([plan.note] + plan.problems).joined(separator: "\n")
            a.runModal(); return
        }
        a.messageText = L("Rescue “\(Demo.mask(i.name))” as a draft pull request?", "„\(Demo.mask(i.name))“ als Entwurfs-PR retten?")
        var t = L("\(StrandedText.what(i)) go to the new branch \(plan.branch) on origin, with a draft pull request into \(plan.base). The folder itself is not changed. A pull request can start CI.",
                  "\(StrandedText.what(i)) kommen auf den neuen Branch \(plan.branch) auf origin, mit einer Entwurfs-PR nach \(plan.base). Der Ordner selbst bleibt unverändert. Eine PR kann CI starten.")
        if plan.visibility == "PUBLIC" { t += "\n\n" + L("This repository is PUBLIC: pushing publishes this work.", "Dieses Repository ist ÖFFENTLICH: Pushen veröffentlicht diese Arbeit.") }
        a.informativeText = t
        a.addButton(withTitle: L("Cancel", "Abbrechen"))
        a.addButton(withTitle: L("Push and open draft PR", "Pushen und Entwurfs-PR öffnen"))
        guard a.runModal() == .alertSecondButtonReturn else { return }
        do {
            let r = try await Tool.json(["repos", "rescue", i.path, "--yes", "--json"], as: StrandedPlan.self, timeout: 300)
            message = r.note
            if let pr = r.pr, let u = URL(string: pr), u.scheme == "https" { NSWorkspace.shared.open(u) }
        } catch { message = LogTools.maskSecrets((error as? ToolError)?.message ?? error.localizedDescription) }
        await scan()
    }
}

struct StrandedMenuSection: View {
    @ObservedObject var mon = StrandedMonitor.shared

    var body: some View {
        if let r = mon.report, r.summary.folders > 0 {
            Menu(StrandedText.summary(r)) {
                Text(L("Uncommitted changes or commits on no remote, oldest first within each group.",
                       "Nicht committete Änderungen oder Commits auf keinem Remote, je Gruppe die ältesten zuerst."))
                Divider()
                ForEach(r.items.prefix(20)) { i in
                    Button(L("Rescue: ", "Retten: ") + StrandedText.line(i) + " …") { Task { await mon.rescue(i) } }
                }
                if r.items.count > 20 {
                    Text(L("\(r.items.count - 20) more: deploys repos stranded", "\(r.items.count - 20) weitere: deploys repos stranded")).font(.caption)
                }
                Divider()
                Button(mon.scanning ? L("Checking …", "Prüfe …") : L("Check now", "Jetzt prüfen")) { Task { await mon.scan() } }.disabled(mon.scanning)
                Text(L("Asks first. Nothing is pushed without your click.", "Fragt vorher. Ohne deinen Klick wird nichts gepusht.")).font(.caption)
            }
            if let m = mon.message { Text(Demo.mask(m)).font(.caption).foregroundStyle(.secondary) }
        }
    }
}
