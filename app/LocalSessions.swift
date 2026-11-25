// Deploy Center — The session counter in the menu: how many Claude Code sessions run on this Mac, a green or yellow
// dot against a high threshold (20-30 sessions are fine), and a "Bundle tasks" menu: sessions started together on one
// repo beyond the first few (they should have been one to three sessions), the same task twice, two in one folder, idle. The figures come from `deploys localsessions --json` (lib/sessions.sh). Read-only: a session is
// ended only after a click and a confirmation (`deploys localsessions stop <pid> --yes`). Cloud sessions: unknown.

import AppKit
import SwiftUI

struct SessionsSnapshot: Decodable, Equatable {
    struct Count: Decodable, Equatable { let count: Int; let max: Int; let over: Bool }
    struct Cloud: Decodable, Equatable { let count: Int?; let max: Int; let status: String }
    struct Twin: Decodable, Equatable { let title: String; let pids: [Int] }
    struct Folder: Decodable, Equatable { let cwd: String; let folder: String; let pids: [Int] }
    /// More than `keep` sessions started within burstMin minutes on one repo; `extra` are the ones beyond `keep`.
    struct Burst: Decodable, Equatable { let repo: String; let folder: String; let count: Int; let keep: Int; let pids: [Int]; let extra: [Int]; let from: Int; let to: Int }
    let level: String
    let local: Count
    let cloud: Cloud
    let idleMin: Int
    let burstMin: Int
    let bundleTo: Int
    let sessions: [ClaudeSession]
    let bursts: [Burst]
    let duplicates: [Twin]
    let sameFolder: [Folder]
    let idle: [Int]
    let hint: String?
}

struct ClaudeSession: Decodable, Equatable, Identifiable {
    let pid: Int
    let sessionId: String
    let cwd: String
    let title: String
    let state: String
    let folder: String
    let idleMin: Int?
    let cpu: Double
    let mb: Int
    let duplicate: Bool
    let sameFolder: Bool
    let burst: Bool
    let burstExtra: Bool
    let idle: Bool
    var id: Int { pid }
}

enum SessionsText {
    /// "Claude Code: 9 on this Mac · cloud: unknown"
    static func summary(_ s: SessionsSnapshot) -> String {
        let cloud = s.cloud.count.map { L("cloud: \($0)", "Cloud: \($0)") } ?? L("cloud: unknown", "Cloud: unbekannt")
        return L("Claude Code: \(s.local.count) on this Mac", "Claude Code: \(s.local.count) auf diesem Mac") + " · " + cloud
    }

    static func threshold(_ s: SessionsSnapshot) -> String {
        s.local.over ? L("Yellow from \(s.local.max): bundle tasks into fewer sessions", "Gelb ab \(s.local.max): Aufgaben in weniger Sitzungen bündeln")
                     : L("Yellow from \(s.local.max)", "Gelb ab \(s.local.max)")
    }

    /// "Shop: 6 started within 4 min – should be 3 at most"
    static func burst(_ b: SessionsSnapshot.Burst) -> String {
        let min = max(0, (b.to - b.from) / 60)
        return L("\(Demo.mask(b.folder)): \(b.count) started within \(min) min – \(b.keep) at most",
                 "\(Demo.mask(b.folder)): \(b.count) innerhalb von \(min) min gestartet – höchstens \(b.keep)")
    }

    static func age(_ m: Int?) -> String {
        guard let m else { return "?" }
        if m < 60 { return "\(m) min" }
        if m < 2880 { return "\(m / 60) h" }
        return L("\(m / 1440) d", "\(m / 1440) T")
    }

    /// The sessions worth closing, each once, in this order: started together beyond the first few, the same task
    /// twice, two in one folder, idle.
    static func candidates(_ s: SessionsSnapshot) -> [ClaudeSession] {
        let order: (ClaudeSession) -> Int = { $0.burstExtra ? 0 : ($0.duplicate ? 1 : ($0.sameFolder ? 2 : 3)) }
        return s.sessions.filter { $0.burstExtra || $0.duplicate || $0.sameFolder || $0.idle }
            .sorted { (order($0), -($0.idleMin ?? 0)) < (order($1), -($1.idleMin ?? 0)) }
    }

    /// Why a session is in the list: "twice", "same folder", "idle 3 h".
    static func reason(_ c: ClaudeSession) -> String {
        var r: [String] = []
        if c.burstExtra { r.append(L("started together", "zusammen gestartet")) }
        if c.duplicate { r.append(L("twice", "doppelt")) }
        if c.sameFolder { r.append(L("same folder", "selber Ordner")) }
        if c.idle { r.append(L("idle \(age(c.idleMin))", "untätig \(age(c.idleMin))")) }
        return r.joined(separator: ", ")
    }

    static func name(_ c: ClaudeSession) -> String {
        Demo.mask(c.title.isEmpty ? c.folder : c.title)
    }

    static func line(_ c: ClaudeSession) -> String {
        "\(name(c)) – \(Demo.mask(c.folder)) – \(reason(c)) – \(PerfText.gb(c.mb))"
    }
}

@MainActor
final class SessionsMonitor: ObservableObject {
    static let shared = SessionsMonitor()
    static let key = "localSessionsIndicator"
    @Published private(set) var snapshot: SessionsSnapshot?
    @Published private(set) var message: String?
    private var task: Task<Void, Never>?

    var level: PerfLevel? { snapshot.map { $0.level == "yellow" ? .yellow : .green } }

    func start() {
        guard task == nil else { return }
        task = Task { [weak self] in
            while !Task.isCancelled {
                await self?.refresh()
                try? await Task.sleep(nanoseconds: 60_000_000_000)
            }
        }
    }

    /// One `deploys localsessions --json` a minute while the line is switched on.
    func refresh() async {
        guard UserDefaults.standard.object(forKey: Self.key) as? Bool ?? true else { return }
        if let s = try? await Tool.json(["localsessions", "--json"], as: SessionsSnapshot.self, timeout: 30), s != snapshot { snapshot = s }
    }

    /// End one session: only from a click, after the person said yes.
    func close(_ c: ClaudeSession) async {
        let a = NSAlert()
        a.messageText = L("End the session “\(SessionsText.name(c))”?", "Sitzung „\(SessionsText.name(c))“ beenden?")
        let why = SessionsText.reason(c), cap = why.prefix(1).uppercased() + why.dropFirst()
        a.informativeText = L("\(cap). Its transcript file stays; the Claude app may show the session as stopped. Work it has not saved is lost.",
                              "\(cap). Die Transkript-Datei bleibt; die Claude-App zeigt die Sitzung evtl. als gestoppt. Nicht gesicherte Arbeit geht verloren.")
        // The safe answer is the default (Return); ending is the second button.
        a.addButton(withTitle: L("Keep running", "Weiterlaufen lassen"))
        a.addButton(withTitle: L("End session", "Sitzung beenden")).hasDestructiveAction = true
        NSApp.activate(ignoringOtherApps: true)
        guard a.runModal() == .alertSecondButtonReturn else { return }
        do {
            _ = try await Tool.run(["localsessions", "stop", String(c.pid), "--yes"], timeout: 30)
            message = L("Ended \(SessionsText.name(c))", "\(SessionsText.name(c)) beendet")
        } catch { message = LogTools.maskSecrets(error.localizedDescription) }
        await refresh()
    }
}

/// The lines in the menu: the count with its dot, and with a hint the "Bundle tasks" menu.
struct SessionsMenuSection: View {
    @ObservedObject var mon = SessionsMonitor.shared
    private func burstLine(_ b: SessionsSnapshot.Burst) -> String { "   " + SessionsText.burst(b) }

    var body: some View {
        if let s = mon.snapshot, let lvl = mon.level {
            Divider()
            Label { Text(SessionsText.summary(s)) } icon: { Image(nsImage: PerfMonitor.dot(lvl)) }
            Text(SessionsText.threshold(s)).font(.caption)
            let list = SessionsText.candidates(s)
            if s.hint != nil || !list.isEmpty {
                let extra = s.bursts.reduce(0) { $0 + $1.extra.count }
                Menu(L("Bundle tasks (\(extra) started together, \(s.duplicates.count) twice)", "Aufgaben bündeln (\(extra) zusammen gestartet, \(s.duplicates.count) doppelt)")) {
                    Text(L("Tasks started together belong in one to \(s.bundleTo) sessions that work them one after another.",
                           "Zusammen gestartete Aufgaben gehören in eine bis \(s.bundleTo) Sitzungen, die sie nacheinander abarbeiten."))
                    ForEach(s.bursts, id: \.pids) { b in Text(burstLine(b)) }
                    if !list.isEmpty { Divider() }
                    ForEach(list.prefix(15)) { c in
                        Button(L("End ", "Beenden: ") + SessionsText.line(c) + " …") { Task { await mon.close(c) } }
                    }
                    Divider()
                    Text(L("Asks first. Nothing is ended without your click.", "Fragt vorher. Ohne deinen Klick wird nichts beendet."))
                }
            }
            if let m = mon.message { Text(m).font(.caption).foregroundStyle(.secondary) }
        }
    }
}
