// Deploy Center — your open pull requests in every repo, kept free of merge conflicts and merged (`deploys prs`,
// lib/prs.sh and lib/prsfix.sh). The menu shows one line ("PRs: 2 conflicts, 1 resolving, 3 merged today"), a Mac
// notification goes out once per repo#pr:headOid, and Settings turn the automatic parts on (both off by default).
// Every field is optional, so the output of an older script still decodes.

import SwiftUI
import AppKit

struct PRsReport: Decodable, Equatable {
    struct Settings: Decodable, Equatable { let autoResolve: Bool?; let autoMerge: Bool?; let perRun: Int?; let perDay: Int? }
    struct Summary: Decodable, Equatable {
        let open: Int?; let conflicts: Int?; let unknown: Int?; let ready: Int?; let red: Int?; let behind: Int?
        let resolving: Int?; let mergedToday: Int?; let resolvedToday: Int?; let failedToday: Int?
    }
    struct Row: Decodable, Equatable, Identifiable {
        let repo: String; let pr: Int; let title: String?; let url: String?; let state: String?; let why: String?; let key: String?
        var id: String { key ?? "\(repo)#\(pr)" }
    }
    struct Event: Decodable, Equatable {
        let at: Int?; let kind: String?; let repo: String?; let pr: Int?; let key: String?; let title: String?; let result: String?; let detail: String?
    }
    struct Failure: Decodable, Equatable { let error: String? }
    let settings: Settings?; let schedule: Bool?; let summary: Summary?
    let conflicts: [Row]?; let events: [Event]?; let errors: [Failure]?
}

/// Pure: the notifications not yet sent. One per repo#pr:headOid for a conflict, one per event (merged, failed).
enum PRsNews {
    static func notes(_ r: PRsReport, seen: Set<String>) -> [(id: String, title: String, body: String)] {
        var out: [(id: String, title: String, body: String)] = []
        for c in r.conflicts ?? [] where !seen.contains("conflict:" + c.id) {
            out.append(("conflict:" + c.id, L("Merge conflict: \(c.repo)#\(c.pr)", "Merge-Konflikt: \(c.repo)#\(c.pr)"), c.title ?? ""))
        }
        for e in r.events ?? [] {
            guard let key = e.key, let kind = e.kind, let result = e.result, result != "would" else { continue }
            let id = kind + ":" + result + ":" + key
            guard !seen.contains(id) else { continue }
            let name = "\(e.repo ?? "")#\(e.pr ?? 0)"
            let title: String
            switch (kind, result) {
            case ("merge", "merged"): title = L("Merged: \(name)", "Gemergt: \(name)")
            case (_, "pushed"): title = L("Conflict resolved: \(name)", "Konflikt gelöst: \(name)")
            case (_, "failed"): title = L("Could not finish \(name)", "\(name) nicht geschafft")
            default: continue
            }
            out.append((id, title, e.detail ?? e.title ?? ""))
        }
        return out
    }

    /// "PRs: 2 conflicts, 1 resolving, 3 merged today", or nil when there is nothing to say.
    static func line(_ r: PRsReport) -> String? {
        guard let s = r.summary else { return nil }
        var parts: [String] = []
        if let n = s.conflicts, n > 0 { parts.append(n == 1 ? L("1 conflict", "1 Konflikt") : L("\(n) conflicts", "\(n) Konflikte")) }
        if let n = s.resolving, n > 0 { parts.append(L("\(n) resolving", "\(n) wird gelöst")) }
        if let n = s.mergedToday, n > 0 { parts.append(L("\(n) merged today", "\(n) heute gemergt")) }
        if let n = s.failedToday, n > 0 { parts.append(L("\(n) failed", "\(n) fehlgeschlagen")) }
        return parts.isEmpty ? nil : "PRs: " + parts.joined(separator: ", ")
    }
}

/// Polls `deploys prs --json` every 5 minutes while the app runs. The first answer after a start only fills the memory.
@MainActor final class PRsWatch: ObservableObject {
    static let shared = PRsWatch()
    @Published private(set) var report: PRsReport?
    @Published private(set) var message: String?
    @Published private(set) var busy = false
    private var timer: Timer?
    private let seenKey = "prsSeen"

    func start() {
        guard timer == nil else { return }
        Task { await refresh() }
        timer = Timer.scheduledTimer(withTimeInterval: 300, repeats: true) { _ in Task { @MainActor in await PRsWatch.shared.refresh() } }
    }

    func refresh() async {
        do {
            let r = try await Tool.json(["prs", "--json"], as: PRsReport.self, timeout: 60)
            report = r
            if (r.errors ?? []).isEmpty { tell(r) }
        } catch {
            message = (error as? ToolError)?.message ?? error.localizedDescription
        }
    }

    private func tell(_ r: PRsReport) {
        let d = UserDefaults.standard
        let first = d.object(forKey: seenKey) == nil
        var seen = Set(d.stringArray(forKey: seenKey) ?? [])
        let news = PRsNews.notes(r, seen: seen)
        guard !news.isEmpty || first else { return }
        if !first && d.object(forKey: "prsNotifications") as? Bool ?? true {
            for n in news { Notify.remind(n.title, n.body, id: "prs-" + n.id) }
        }
        news.forEach { seen.insert($0.id) }
        d.set(Array(seen.suffix(600)), forKey: seenKey)
    }

    /// `deploys prs set …`, `deploys prs schedule …` or `deploys prs run --yes`: always after a click.
    func run(_ args: [String]) async {
        busy = true; defer { busy = false }
        do {
            let out = try await Tool.run(["prs"] + args, timeout: args.first == "run" ? 3600 : 30)
            message = String(decoding: out, as: UTF8.self).split(separator: "\n").last.map(String.init)
        } catch {
            message = (error as? ToolError)?.message ?? error.localizedDescription
        }
        await refresh()
    }
}

struct PRsMenuSection: View {
    @ObservedObject var watch = PRsWatch.shared
    var body: some View {
        if let r = watch.report, let line = PRsNews.line(r) {
            Text(line)
            if (r.summary?.conflicts ?? 0) > 0 || (r.summary?.ready ?? 0) > 0 {
                Button(L("Resolve and merge now", "Jetzt lösen und mergen")) { Task { await watch.run(["run", "--yes"]) } }.disabled(watch.busy)
            }
        }
    }
}

struct PRsSettingsSection: View {
    @ObservedObject var watch = PRsWatch.shared
    @AppStorage("prsNotifications") private var notify = true
    var body: some View {
        Section(L("Pull requests", "Pull Requests")) {
            let s = watch.report?.settings
            Toggle(L("Resolve merge conflicts automatically", "Merge-Konflikte automatisch lösen"), isOn: bind(s?.autoResolve, "autoResolve"))
                .help(L("Merges the base into the branch (Claude Code resolves what git cannot) and pushes only when the checks pass. Never a rebase or force push.",
                        "Merged die Basis in den Branch (Claude Code löst, was git nicht kann) und pusht nur, wenn die Checks grün sind. Nie Rebase oder Force-Push."))
            Toggle(L("Merge green pull requests automatically", "Grüne Pull Requests automatisch mergen"), isOn: bind(s?.autoMerge, "autoMerge"))
                .help(L("Only when not a draft, mergeable, the checks are green and no changes are requested. Never with --admin. Deploys nothing.",
                        "Nur wenn kein Entwurf, mergebar, Checks grün und keine Änderungen verlangt. Nie mit --admin. Deployt nichts."))
            Toggle(L("Run every 5 minutes", "Alle 5 Minuten ausführen"), isOn: Binding(
                get: { watch.report?.schedule ?? false },
                set: { on in Task { await watch.run(["schedule", on ? "on" : "off"]) } }))
                .help(L("The first pass only reports what it would do.", "Der erste Durchlauf zeigt nur, was er tun würde."))
            Toggle(L("Notify me about conflicts and merges", "Bei Konflikten und Merges benachrichtigen"), isOn: $notify)
            if let m = watch.message { Text(m).font(.caption).foregroundStyle(.secondary) }
        }
        .disabled(watch.busy)
        .task { await watch.refresh() }
    }

    private func bind(_ value: Bool?, _ key: String) -> Binding<Bool> {
        Binding(get: { value ?? false }, set: { on in Task { await watch.run(["set", key, on ? "on" : "off"]) } })
    }
}
