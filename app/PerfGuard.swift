// Deploy Center — The performance guard in the menu bar: a green, yellow or red dot for how full the Mac is, and in
// the menu the reason, the biggest consumers and whether a heavy check may start now. The figures come from
// `deploys perf status --json` (lib/perf.sh); when the launchd agent runs (deploys perf install), its status.json
// is read instead, so nothing is started every half minute. Read-only: nothing is stopped from here.

import AppKit
import SwiftUI

struct PerfStatus: Decodable, Equatable {
    struct Group: Decodable, Equatable { let key: String; let label: String; let count: Int; let mb: Int }
    struct Load: Decodable, Equatable { let one: Double; let cores: Int; let perCore: Double }
    struct Swap: Decodable, Equatable { let usedMB: Int; let freeMB: Int?; let swapoutMBPerMin: Double? }
    struct Checks: Decodable, Equatable { let running: Int; let cap: Int }
    let time: Int
    let level: String
    let reasons: [String]
    let admit: Bool
    let load: Load
    let swap: Swap
    let checks: Checks
    let claudeSessions: Int
    let groups: [Group]
}

/// A Docker stack from `deploys perf docker --json` (lib/perfdocker.sh).
struct DockerStack: Decodable, Equatable, Identifiable {
    let stack: String; let kind: String; let running: Int; let total: Int; let memMB: Int; let active: Bool; let always: Bool
    var id: String { stack }
}

/// A process tree from `deploys perf reap --all --json` (lib/perfclean.sh): its class (check, testbrowser, mcp,
/// npmexec, devserver) and verdict (ok, hang, orphan, useless).
struct CheckRun: Decodable, Equatable, Identifiable {
    let pid: Int; let kind: String; let verdict: String; let reason: String; let key: String
    let ageS: Int; let mb: Int; let folder: String?
    enum CodingKeys: String, CodingKey { case pid, kind = "class", verdict, reason, key, ageS, mb, folder }
    var id: Int { pid }
    var flagged: Bool { verdict != "ok" }
    var verdictText: String {
        switch verdict {
        case "hang": return L("hangs", "hängt")
        case "orphan": return L("orphaned", "verwaist")
        case "useless": return L("unused", "ungenutzt")
        default: return L("in use", "in Benutzung")
        }
    }
    var line: String {
        let place = folder.map { URL(fileURLWithPath: $0).lastPathComponent } ?? "?"
        return "\(key) (\(kind)) – \(ageS / 60) min – \(PerfText.gb(mb)) – \(verdictText) (\(Demo.mask(place)))"
    }
}
private struct ReapAnswer: Decodable { let runs: [CheckRun] }

enum PerfLevel: String {
    case green, yellow, red
    var color: NSColor { self == .green ? .systemGreen : (self == .yellow ? .systemYellow : .systemRed) }
    var text: String {
        switch self {
        case .green: return L("Mac: room to spare", "Mac: genug Luft")
        case .yellow: return L("Mac: busy", "Mac: ausgelastet")
        case .red: return L("Mac: overloaded", "Mac: überlastet")
        }
    }
}

enum PerfText {
    static func gb(_ mb: Int) -> String { mb >= 1024 ? String(format: "%.1f GB", Double(mb) / 1024) : "\(mb) MB" }
    /// "Claude Code sessions 5.8 GB" for the three biggest groups that are not "Other".
    static func top(_ s: PerfStatus, _ n: Int = 3) -> [String] {
        s.groups.filter { $0.key != "other" }.prefix(n).map { "\($0.label) (\($0.count)) – \(gb($0.mb))" }
    }
    static func admit(_ s: PerfStatus) -> String {
        s.admit ? L("Heavy checks may start now", "Schwere Checks dürfen jetzt starten")
                : L("Heavy checks wait for room", "Schwere Checks warten auf Platz")
    }
}

@MainActor
final class PerfMonitor: ObservableObject {
    static let shared = PerfMonitor()
    @Published private(set) var status: PerfStatus?
    @Published private(set) var docker: [DockerStack] = []
    /// Stacks the guard stopped (perf/docker-stopped.json): these get "Wake".
    @Published private(set) var stopped: [String] = []
    @Published private(set) var message: String?
    @Published private(set) var runs: [CheckRun] = []
    private var lastRuns = Date.distantPast
    private var task: Task<Void, Never>?
    private var lastDocker = Date.distantPast

    var level: PerfLevel? { status.flatMap { PerfLevel(rawValue: $0.level) } }

    func start() {
        guard task == nil else { return }
        task = Task { [weak self] in
            while !Task.isCancelled {
                await self?.refresh()
                await self?.refreshDocker()
                await self?.refreshRuns()
                try? await Task.sleep(nanoseconds: 30_000_000_000)
            }
        }
    }

    static var agentFile: URL {
        let base = ProcessInfo.processInfo.environment["DEPLOYS_CONFIG"].map { URL(fileURLWithPath: $0) }
            ?? FileManager.default.homeDirectoryForCurrentUser.appendingPathComponent(".config/deploys")
        return base.appendingPathComponent("perf/status.json")
    }

    /// The agent's file when it is at most 3 minutes old, else one `deploys perf status --json` (at most every minute).
    private var lastRun = Date.distantPast
    func refresh() async {
        let f = Self.agentFile
        if let a = try? FileManager.default.attributesOfItem(atPath: f.path), let m = a[.modificationDate] as? Date,
           Date().timeIntervalSince(m) < 180, let d = try? Data(contentsOf: f),
           let s = try? JSONDecoder().decode(PerfStatus.self, from: d) {
            if s != status { status = s }
            return
        }
        guard Date().timeIntervalSince(lastRun) >= 60 else { return }
        lastRun = Date()
        if let s = try? await Tool.json(["perf", "status", "--json"], as: PerfStatus.self, timeout: 30), s != status { status = s }
    }

    /// The Docker stacks, at most every 5 minutes (docker stats takes a few seconds); force after a click.
    func refreshDocker(force: Bool = false) async {
        guard force || Date().timeIntervalSince(lastDocker) >= 300 else { return }
        lastDocker = Date()
        if let d = try? await Tool.json(["perf", "docker", "--json"], as: [DockerStack].self, timeout: 60), d != docker { docker = d }
        let f = Self.agentFile.deletingLastPathComponent().appendingPathComponent("docker-stopped.json")
        let keys = (try? Data(contentsOf: f)).flatMap { try? JSONSerialization.jsonObject(with: $0) as? [String: Any] }?.keys.sorted() ?? []
        if keys != stopped { stopped = keys }
    }

    /// The running check runs, at most every 2 minutes.
    func refreshRuns(force: Bool = false) async {
        guard force || Date().timeIntervalSince(lastRuns) >= 120 else { return }
        lastRuns = Date()
        if let r = try? await Tool.json(["perf", "reap", "--all", "--json"], as: ReapAnswer.self, timeout: 60), r.runs != runs { runs = r.runs }
    }

    /// Stop one run with its whole process tree: only from a click.
    func stopRun(_ r: CheckRun) async {
        do {
            _ = try await Tool.run(["perf", "reap", "--pid", String(r.pid), "--yes"], timeout: 60)
            message = L("Stopped \(r.key)", "\(r.key) beendet")
        } catch { message = LogTools.maskSecrets(error.localizedDescription) }
        await refreshRuns(force: true)
    }

    /// Stop or wake one stack: only from a click. Containers, volumes and data stay.
    func act(_ stack: String, wake: Bool) async {
        let args = wake ? ["perf", "wake", stack] : ["perf", "stop", stack, "--yes"]
        do {
            _ = try await Tool.run(args, timeout: 120)
            message = wake ? L("Started \(stack)", "\(stack) gestartet") : L("Stopped \(stack)", "\(stack) gestoppt")
        } catch { message = LogTools.maskSecrets(error.localizedDescription) }
        await refreshDocker(force: true)
    }

    /// A small colored dot for the menu bar (not a template image, so the color stays).
    static func dot(_ level: PerfLevel) -> NSImage {
        let img = NSImage(size: NSSize(width: 8, height: 8), flipped: false) { r in
            level.color.setFill(); NSBezierPath(ovalIn: r.insetBy(dx: 0.5, dy: 0.5)).fill(); return true
        }
        img.isTemplate = false
        img.accessibilityDescription = level.text
        return img
    }
}

/// The lines in the menu: level and reason, the biggest groups, sessions and checks, and whether a check may start.
struct PerfMenuSection: View {
    @ObservedObject var perf = PerfMonitor.shared

    var body: some View {
        if let s = perf.status, let lvl = perf.level {
            Divider()
            Label {
                Text(lvl.text + (s.reasons.first.map { " – " + $0 } ?? ""))
            } icon: { Image(nsImage: PerfMonitor.dot(lvl)) }
            ForEach(PerfText.top(s), id: \.self) { Text("   " + $0).font(.caption) }
            Text(L("\(s.claudeSessions) Claude Code sessions · \(s.checks.running) heavy checks (cap \(s.checks.cap))",
                   "\(s.claudeSessions) Claude-Code-Sitzungen · \(s.checks.running) schwere Checks (Grenze \(s.checks.cap))"))
                .font(.caption)
            Text(PerfText.admit(s)).font(.caption)
            if !perf.runs.isEmpty {
                let flagged = perf.runs.filter(\.flagged)
                // The flagged ones first, then the biggest of the rest.
                let shown = flagged + perf.runs.filter { !$0.flagged }.prefix(max(0, 10 - flagged.count))
                Menu(L("Processes (\(flagged.count) hung or unused)", "Prozesse (\(flagged.count) hängen oder ungenutzt)")) {
                    ForEach(shown) { r in
                        Button((r.flagged ? "⚠︎ " : "") + L("Stop ", "Beenden: ") + r.line) { Task { await perf.stopRun(r) } }
                    }
                    Divider()
                    Text(L("Stops the process with everything under it.", "Beendet den Prozess mit allem darunter."))
                }
            }
            let running = perf.docker.filter { $0.running > 0 }
            if !running.isEmpty || !perf.stopped.isEmpty {
                Menu(L("Docker (\(running.count) running)", "Docker (\(running.count) laufen)")) {
                    ForEach(running) { d in
                        Button(L("Stop ", "Stoppen: ") + Demo.mask(d.stack) + " – \(PerfText.gb(d.memMB))" + (d.active ? L(" (in use)", " (in Benutzung)") : "")) {
                            Task { await perf.act(d.stack, wake: false) }
                        }
                        .disabled(d.always)
                    }
                    if !perf.stopped.isEmpty { Divider() }
                    ForEach(perf.stopped, id: \.self) { k in
                        Button(L("Wake ", "Wecken: ") + Demo.mask(k)) { Task { await perf.act(k, wake: true) } }
                    }
                    Divider()
                    Text(L("Stop keeps containers, volumes and data.", "Stoppen behält Container, Volumes und Daten."))
                }
            }
            if let m = perf.message { Text(m).font(.caption).foregroundStyle(.secondary) }
        }
    }
}
