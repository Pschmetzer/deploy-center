import SwiftUI

/// `deploys disk --json`: where the disk space goes, per category.
struct DiskReport: Decodable {
    struct Category: Decodable, Identifiable {
        let id: String
        let kb: Int
        let action: String
        let timedOut: Bool?
        let stale: Bool?
        let freeableKB: Int?
        struct Part: Decodable { let name: String }
        let parts: [Part]?
    }
    let freeKB: Int
    let diskKB: Int
    let usedKB: Int
    let autoKB: Int?
    let unassignedKB: Int?
    let cached: Bool?
    let ageSec: Int?
    let categories: [Category]
}

/// `deploys disk free --json`: the plan (without --yes) or the result (with --yes).
struct DiskFreeResult: Decodable {
    struct Step: Decodable, Identifiable { let id: String; let kb: Int?; let what: String?; let status: String? }
    let deleted: Bool
    let freeKB: Int?
    let estimateKB: Int?
    let freedKB: Int?
    let failed: Int?
    let steps: [Step]
}

enum DiskText {
    static func gb(_ kb: Int) -> String { String(format: "%.1f GB", Double(kb) / 1_048_576) }

    static func name(_ id: String) -> String {
        switch id {
        case "worktrees": return L("Build folders in old worktrees", "Build-Ordner alter Worktrees")
        case "docker": return L("Docker", "Docker")
        case "npm": return L("npm cache", "npm-Cache")
        case "pnpm": return L("pnpm store", "pnpm-Speicher")
        case "yarn": return L("Yarn cache", "Yarn-Cache")
        case "brew": return L("Homebrew cache", "Homebrew-Cache")
        case "bun": return L("bun cache", "bun-Cache")
        case "pip": return L("pip cache", "pip-Cache")
        case "xcode": return L("Xcode DerivedData", "Xcode DerivedData")
        case "simulators": return L("iOS simulators", "iOS-Simulatoren")
        case "caches": return L("Other app caches", "Andere App-Caches")
        case "trash": return L("Trash", "Papierkorb")
        case "claude-projects": return L("Claude Code transcripts", "Claude-Code-Verläufe")
        case "claude-app": return L("Claude app folders", "Ordner der Claude-App")
        case "huggingface": return L("Downloaded models", "Heruntergeladene Modelle")
        case "tmp": return L("Temporary files", "Temporäre Dateien")
        case "dotcache": return L("Other tool caches (.cache)", "Andere Tool-Caches (.cache)")
        case "applications": return L("Apps", "Programme")
        case "library": return L("System library", "System-Library")
        case "snapshots": return L("Local snapshots", "Lokale Snapshots")
        case "clean": return L("Old worktrees and Docker build cache", "Alte Worktrees und Docker-Build-Cache")
        default: return id
        }
    }

    static func rule(_ c: DiskReport.Category) -> String {
        switch c.id {
        case "trash": return L("Empty it in Finder", "Im Finder leeren")
        case "claude-projects": return L("Kept 30 days; cleanupPeriodDays in Claude Code's settings sets fewer", "30 Tage behalten; cleanupPeriodDays in den Claude-Code-Einstellungen setzt weniger")
        case "claude-app", "huggingface", "applications", "library": return L("Stays", "Bleibt")
        case "snapshots": return L("macOS keeps them; installing or cancelling a pending update frees one", "macOS behält sie; ein anstehendes Update installieren oder abbrechen gibt einen frei")
        case "tmp": return L("Entries older than 3 days that no process uses", "Einträge älter als 3 Tage, die kein Prozess nutzt")
        case "docker": return L("Build cache and dangling images; volumes stay", "Build-Cache und verwaiste Images; Volumes bleiben")
        default: return c.action == "auto" ? L("Freed by the button", "Räumt der Knopf") : L("You decide", "Entscheidest du")
        }
    }
}

/// The "Disk space" section: categories with GB and a "Free space" button with a confirmation.
struct DiskSpaceSection: View {
    @State private var report: DiskReport?
    @State private var plan: DiskFreeResult?
    @State private var busy = false
    @State private var error: String?
    @State private var freeError: String?
    @State private var done: String?
    @State private var confirming = false

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack {
                Text(L("Disk space", "Speicher")).font(.title2.bold())
                Spacer()
                if let r = report {
                    Text(L("\(DiskText.gb(r.freeKB)) free of \(DiskText.gb(r.diskKB))", "\(DiskText.gb(r.freeKB)) frei von \(DiskText.gb(r.diskKB))")).foregroundStyle(.secondary)
                }
            }
            if let e = freeError { Text(e).foregroundStyle(Color.dangerText).font(.callout) }
            if let e = error { Text(e).foregroundStyle(Color.dangerText).font(.callout) }
            if let d = done { Label(d, systemImage: "checkmark.circle.fill").foregroundStyle(.green) }
            if let r = report {
                ForEach(r.categories.filter { $0.kb > 0 || ($0.id == "snapshots" && !($0.parts ?? []).isEmpty) }.sorted { $0.kb > $1.kb }) { c in
                    HStack(alignment: .firstTextBaseline) {
                        Image(systemName: c.action == "auto" ? "arrow.3.trianglepath" : (c.action == "never" ? "lock" : "hand.raised"))
                            .foregroundStyle(.secondary).frame(width: 18)
                        VStack(alignment: .leading, spacing: 1) {
                            Text(DiskText.name(c.id))
                            Text(DiskText.rule(c)).font(.caption).foregroundStyle(.secondary)
                        }
                        Spacer()
                        Text(c.id == "snapshots" ? L("\(c.parts?.count ?? 0) snapshots", "\(c.parts?.count ?? 0) Snapshots") : DiskText.gb(c.kb) + ((c.timedOut ?? false) ? (c.stale ?? false ? " ⏱" : "+") : ""))
                            .monospacedDigit()
                            .help((c.timedOut ?? false) ? L("Time ran out while measuring: an older or partial number", "Beim Messen lief die Zeit ab: eine ältere oder unvollständige Zahl") : "")
                    }
                }
                if let u = r.unassignedKB, u > r.usedKB / 10 {
                    Text(L("Not assigned: \(DiskText.gb(u)) (other users, system data, snapshots, folders not measured here)",
                           "Nicht zugeordnet: \(DiskText.gb(u)) (andere Benutzer, Systemdaten, Snapshots, hier nicht gemessene Ordner)"))
                        .font(.caption).foregroundStyle(.secondary)
                }
                if let a = r.cached, a, let age = r.ageSec {
                    Text(L("Measured \(age / 60) min ago", "Vor \(age / 60) Min. gemessen")).font(.caption).foregroundStyle(.secondary)
                }
            } else if busy {
                ProgressView(L("Measuring … (up to 2 minutes)", "Wird gemessen … (bis zu 2 Minuten)"))
            }
            HStack {
                Button(L("Measure again", "Neu messen")) { Task { await load(refresh: true) } }.disabled(busy)
                Spacer()
                Button(L("Free space …", "Platz freigeben …")) { Task { await prepare() } }
                    .buttonStyle(.borderedProminent)
                    .disabled(busy || report == nil)
            }
        }
        .task { await load(refresh: false) }
        .sheet(isPresented: $confirming) { confirmSheet }
    }

    private var confirmSheet: some View {
        VStack(alignment: .leading, spacing: 10) {
            Text(L("Free disk space?", "Platz freigeben?")).font(.title3.bold())
            Text(L("Only what comes back by itself on the next install or build. The Trash, Docker volumes, Claude's folders and your code stay.",
                   "Nur was beim nächsten Installieren oder Bauen von selbst wiederkommt. Papierkorb, Docker-Volumes, Claudes Ordner und dein Code bleiben."))
                .font(.callout).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
            ForEach(plan?.steps ?? []) { s in
                HStack { Text(DiskText.name(s.id)); Text(s.what ?? "").font(.caption).foregroundStyle(.secondary).lineLimit(1); Spacer(); Text(DiskText.gb(s.kb ?? 0)).monospacedDigit() }
            }
            Divider()
            HStack { Text(L("About", "Etwa")).bold(); Spacer(); Text(DiskText.gb(plan?.estimateKB ?? 0)).bold().monospacedDigit() }
            HStack {
                Spacer()
                Button(L("Cancel", "Abbrechen"), role: .cancel) { confirming = false }.keyboardShortcut(.cancelAction)
                Button(L("Free space", "Platz freigeben"), role: .destructive) { confirming = false; Task { await free() } }
                    .buttonStyle(.borderedProminent).keyboardShortcut(.defaultAction)
            }
        }
        .padding(20).frame(width: 480)
    }

    private func load(refresh: Bool) async {
        busy = true; error = nil; defer { busy = false }
        do { report = try JSONDecoder().decode(DiskReport.self, from: try await Tool.run(["disk", "--json"] + (refresh ? ["--refresh"] : []), timeout: 600)) }
        catch { self.error = "\(error.localizedDescription)" }
    }

    private func prepare() async {
        busy = true; error = nil; freeError = nil; defer { busy = false }
        do {
            plan = try JSONDecoder().decode(DiskFreeResult.self, from: try await Tool.run(["disk", "free", "--json"], timeout: 600))
            confirming = true
        } catch { self.error = "\(error.localizedDescription)" }
    }

    private func free() async {
        busy = true; freeError = nil; done = nil
        do {
            let r = try JSONDecoder().decode(DiskFreeResult.self, from: try await Tool.run(["disk", "free", "--yes", "--json"], timeout: 3600))
            let gb = DiskText.gb(r.freedKB ?? 0)
            done = L("Freed \(gb)", "\(gb) freigegeben") + ((r.failed ?? 0) > 0 ? L(", \(r.failed!) steps failed", ", \(r.failed!) Schritte fehlgeschlagen") : "")
            Notify.post(L("Disk space freed", "Speicher freigegeben"),
                        L("\(gb) freed, \(DiskText.gb(r.freeKB ?? 0)) free now.", "\(gb) freigegeben, jetzt \(DiskText.gb(r.freeKB ?? 0)) frei."))
        } catch { freeError = L("Freeing failed: ", "Freigeben fehlgeschlagen: ") + error.localizedDescription }
        busy = false
        await load(refresh: false)
    }
}
