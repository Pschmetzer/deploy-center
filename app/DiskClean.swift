import SwiftUI

/// `deploys clean --json`: what old git worktrees hold and what can go.
struct CleanReport: Decodable {
    struct Item: Decodable { let kind: String; let kb: Int; let repo: String; let path: String; let what: String }
    let deleted: Bool?
    let skipped: Bool?
    let freeGB: Int
    let totalKB: Int?
    let freedKB: Int?
    let failed: Int?
    let keptRecent: Int?
    let items: [Item]
}

/// Window "Free Disk Space": a report first; nothing is deleted before the click and the confirmation.
struct DiskCleanView: View {
    @State private var report: CleanReport?
    @State private var busy = false
    @State private var error: String?
    @State private var worktrees = true
    @State private var confirming = false
    @State private var done: String?

    private static func gb(_ kb: Int) -> String { String(format: "%.1f GB", Double(kb) / 1_048_576) }

    private var byRepo: [(repo: String, kb: Int, n: Int)] {
        guard let r = report else { return [] }
        var d: [String: (Int, Int)] = [:]
        for i in r.items { let o = d[i.repo] ?? (0, 0); d[i.repo] = (o.0 + i.kb, o.1 + 1) }
        return d.map { (repo: ($0.key as NSString).lastPathComponent, kb: $0.value.0, n: $0.value.1) }.sorted { $0.kb > $1.kb }
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            Text(L("Free disk space", "Speicher freigeben")).font(.title2.bold())
            Text(L("Build output (node_modules, .next, dist …) in git worktrees unchanged for 2 days, and worktrees whose work is merged into main and that have no changes. Code with changes is never touched; branches stay.",
                   "Build-Reste (node_modules, .next, dist …) in Git-Worktrees, die 2 Tage nicht geändert wurden, und Worktrees, deren Arbeit in main ist und die keine Änderungen haben. Code mit Änderungen bleibt immer, Branches bleiben."))
                .font(.callout).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
            Toggle(L("Also remove merged worktrees", "Auch gemergte Worktrees entfernen"), isOn: $worktrees)
                .onChange(of: worktrees) { _, _ in Task { await load() } }
            if let e = error { Text(e).foregroundStyle(Color.dangerText).font(.callout) }
            if let d = done { Label(d, systemImage: "checkmark.circle.fill").foregroundStyle(.green) }
            if let r = report {
                HStack {
                    Text(L("Can go: ", "Kann weg: ") + Self.gb(r.totalKB ?? 0)).font(.headline)
                    Spacer()
                    Text(L("\(r.freeGB) GB free", "\(r.freeGB) GB frei")).foregroundStyle(.secondary)
                }
                List(byRepo, id: \.repo) { row in
                    HStack { Text(row.repo); Spacer(); Text("\(row.n)").foregroundStyle(.secondary); Text(Self.gb(row.kb)).monospacedDigit().frame(width: 80, alignment: .trailing) }
                }
                .frame(minHeight: 200)
                if let k = r.keptRecent, k > 0 {
                    Text(L("\(k) worktrees changed recently and are left alone.", "\(k) Worktrees wurden kürzlich geändert und bleiben.")).font(.caption).foregroundStyle(.secondary)
                }
            } else if busy {
                ProgressView(L("Looking …", "Wird geprüft …"))
            }
            HStack {
                Button(L("Check again", "Neu prüfen")) { Task { await load() } }.disabled(busy)
                Spacer()
                Button(L("Delete …", "Löschen …")) { confirming = true }
                    .buttonStyle(.borderedProminent)
                    .disabled(busy || (report?.items.isEmpty ?? true))
            }
        }
        .padding(20)
        .frame(minWidth: 480, minHeight: 420)
        .task { await load() }
        .alert(L("Delete for good?", "Endgültig löschen?"), isPresented: $confirming) {
            Button(L("Delete", "Löschen"), role: .destructive) { Task { await clean() } }
            Button(L("Cancel", "Abbrechen"), role: .cancel) {}
        } message: {
            Text(L("\(Self.gb(report?.totalKB ?? 0)) in \(report?.items.count ?? 0) folders. Build output comes back with npm install; removed worktrees keep their branch.",
                   "\(Self.gb(report?.totalKB ?? 0)) in \(report?.items.count ?? 0) Ordnern. Build-Reste kommen mit npm install zurück, entfernte Worktrees behalten ihren Branch."))
        }
    }

    private func args(_ extra: [String]) -> [String] { ["clean", "--json"] + (worktrees ? ["--worktrees"] : []) + extra }

    private func load() async {
        busy = true; error = nil; defer { busy = false }
        do { report = try JSONDecoder().decode(CleanReport.self, from: try await Tool.run(args([]), timeout: 1800)) }
        catch { report = nil; self.error = "\(error.localizedDescription)" }
    }

    private func clean() async {
        busy = true; error = nil; defer { busy = false }
        do {
            let r = try JSONDecoder().decode(CleanReport.self, from: try await Tool.run(args(["--yes"]), timeout: 3600))
            done = L("Freed \(Self.gb(r.freedKB ?? 0))", "\(Self.gb(r.freedKB ?? 0)) freigegeben") + ((r.failed ?? 0) > 0 ? L(", \(r.failed!) not removed", ", \(r.failed!) nicht entfernt") : "")
        } catch { self.error = "\(error.localizedDescription)" }
        busy = false
        await load()
    }
}

/// Deploy menu → "Free Disk Space …".
struct DiskCleanCommand: Commands {
    @Environment(\.openWindow) private var openWindow
    var body: some Commands {
        CommandGroup(after: .toolbar) {
            Button(L("Free Disk Space …", "Speicher freigeben …")) { openWindow(id: "clean"); NSApp.activate(ignoringOtherApps: true) }
        }
    }
}
