import AppKit
import SwiftUI

/// Quitting apps the person picked when the Mac is full (docs/PERF.md, "Quitting apps"). Off unless switched on in
/// Settings → General; perf.json "quitApps": {"enabled", "apps": [bundle ids], "idleMin": 30, "helpers": false}.
/// Only while the Mac is red with memory pressure for 5 minutes (dev-server and Docker shedding, lib/perfshed.sh, had
/// their turn), one app at a time, biggest first, at most one every 2 minutes; only apps in the background that were
/// not active for idleMin minutes. Only `terminate()`, the same as ⌘Q: an app with unsaved documents asks and stays
/// open, and is left alone until the pressure is over. Never force. With "helpers", windowless helper processes inside
/// a quit app's bundle get a TERM. The app does this, not the launchd agent: it knows which app is in front and when
/// each was active, and needs no Apple Events permission. Without the app running nothing is quit.
struct QuitAppsConfig: Equatable {
    var enabled = false
    var apps: [String] = []
    var idleMin = 30
    var helpers = false
}

enum QuitApps {
    /// Never quit, whatever perf.json says: Claude, terminals, Xcode, the Simulator, Finder, Deploy Center, the system.
    static let never: Set<String> = ["com.anthropic.claudefordesktop", "com.apple.Terminal", "com.googlecode.iterm2",
                                     "com.apple.dt.Xcode", "com.apple.iphonesimulator", "com.apple.finder",
                                     "com.apple.loginwindow", "com.apple.dock", "com.apple.systemuiserver",
                                     "com.apple.controlcenter", "com.apple.systempreferences"]
    /// Not in the "not needed" suggestion (they may still be picked by hand).
    static let notSuggested: Set<String> = ["com.google.Chrome"]

    static func allowed(_ id: String) -> Bool {
        !never.contains(id) && !id.hasPrefix("com.anthropic.") && !id.hasPrefix("app.deploycenter.")
            && !id.hasPrefix("dev.warp.") && !id.hasPrefix("com.mitchellh.ghostty")
    }

    static var configDir: URL {
        ProcessInfo.processInfo.environment["DEPLOYS_CONFIG"].map { URL(fileURLWithPath: $0) }
            ?? FileManager.default.homeDirectoryForCurrentUser.appendingPathComponent(".config/deploys")
    }
    static var confFile: URL { configDir.appendingPathComponent("perf.json") }

    static func load() -> QuitAppsConfig {
        guard let d = try? Data(contentsOf: confFile),
              let o = try? JSONSerialization.jsonObject(with: d) as? [String: Any],
              let q = o["quitApps"] as? [String: Any] else { return QuitAppsConfig() }
        var c = QuitAppsConfig()
        c.enabled = q["enabled"] as? Bool ?? false
        c.apps = (q["apps"] as? [String] ?? []).filter(allowed)
        c.idleMin = max(5, q["idleMin"] as? Int ?? 30)
        c.helpers = q["helpers"] as? Bool ?? false
        return c
    }

    /// Writes "quitApps" into perf.json and keeps every other key.
    static func save(_ c: QuitAppsConfig) {
        var o: [String: Any] = [:]
        if let d = try? Data(contentsOf: confFile), let x = try? JSONSerialization.jsonObject(with: d) as? [String: Any] { o = x }
        o["quitApps"] = ["enabled": c.enabled, "apps": c.apps.filter(allowed), "idleMin": c.idleMin, "helpers": c.helpers]
        guard let d = try? JSONSerialization.data(withJSONObject: o, options: [.sortedKeys]) else { return }
        try? FileManager.default.createDirectory(at: configDir, withIntermediateDirectories: true)
        try? d.write(to: confFile, options: .atomic)
    }

    /// RSS in MB of each pid with everything below it (one ps). Shared pages count twice: enough to sort by.
    static func treeMB(_ pids: [pid_t]) -> [pid_t: Int] {
        let p = Process(); p.executableURL = URL(fileURLWithPath: "/bin/ps"); p.arguments = ["-axo", "pid=,ppid=,rss="]
        let pipe = Pipe(); p.standardOutput = pipe; p.standardError = FileHandle.nullDevice
        guard (try? p.run()) != nil else { return [:] }
        let data = pipe.fileHandleForReading.readDataToEndOfFile(); p.waitUntilExit()
        var kids: [pid_t: [pid_t]] = [:], rss: [pid_t: Int] = [:]
        for line in String(decoding: data, as: UTF8.self).split(separator: "\n") {
            let f = line.split(separator: " ", omittingEmptySubsequences: true)
            guard f.count >= 3, let pid = pid_t(f[0]), let pp = pid_t(f[1]), let r = Int(f[2]) else { continue }
            kids[pp, default: []].append(pid); rss[pid] = r
        }
        func sum(_ x: pid_t, _ depth: Int) -> Int {
            depth > 40 ? 0 : (rss[x] ?? 0) + (kids[x] ?? []).reduce(0) { $0 + sum($1, depth + 1) }
        }
        var out: [pid_t: Int] = [:]
        for x in pids { out[x] = sum(x, 0) / 1024 }
        return out
    }

    /// Windowless helpers inside a quit app's bundle (not login items, not XPC services, not launchd jobs), this user's.
    static func helpers(of bundle: URL) -> [pid_t] {
        let path = bundle.standardizedFileURL.path
        let home = FileManager.default.homeDirectoryForCurrentUser.path
        guard path.hasPrefix("/Applications/") || path.hasPrefix(home + "/Applications/") else { return [] }
        let p = Process(); p.executableURL = URL(fileURLWithPath: "/bin/ps"); p.arguments = ["-U", String(getuid()), "-o", "pid=,comm="]
        let pipe = Pipe(); p.standardOutput = pipe; p.standardError = FileHandle.nullDevice
        guard (try? p.run()) != nil else { return [] }
        let data = pipe.fileHandleForReading.readDataToEndOfFile(); p.waitUntilExit()
        // Without a readable launchd list nothing is stopped (fail closed).
        guard let jobs = launchdPids() else { return [] }
        var out: [pid_t] = []
        for line in String(decoding: data, as: UTF8.self).split(separator: "\n") {
            let s = line.trimmingCharacters(in: .whitespaces)
            guard let sp = s.firstIndex(of: " "), let pid = pid_t(s[..<sp]) else { continue }
            let exe = String(s[sp...]).trimmingCharacters(in: .whitespaces)
            guard exe.hasPrefix(path + "/"), !exe.contains("/Contents/Library/LoginItems/"), !exe.contains("/Contents/XPCServices/"),
                  !jobs.contains(pid), pid != getpid() else { continue }
            // Windowless only: a process macOS counts as a regular app (Dock icon, windows) is quit with ⌘Q or not at all.
            if let ra = NSRunningApplication(processIdentifier: pid), ra.activationPolicy == .regular { continue }
            out.append(pid)
        }
        return out
    }

    private static func launchdPids() -> Set<pid_t>? {
        let p = Process(); p.executableURL = URL(fileURLWithPath: "/bin/launchctl"); p.arguments = ["list"]
        let pipe = Pipe(); p.standardOutput = pipe; p.standardError = FileHandle.nullDevice
        guard (try? p.run()) != nil else { return nil }
        let data = pipe.fileHandleForReading.readDataToEndOfFile(); p.waitUntilExit()
        guard p.terminationStatus == 0, !data.isEmpty else { return nil }
        return Set(String(decoding: data, as: UTF8.self).split(separator: "\n").compactMap { pid_t($0.split(separator: "\t").first ?? "") })
    }
}

/// A running app as the settings and the plan show it.
struct RunningAppInfo: Identifiable, Equatable {
    let id: String          // bundle id
    let name: String
    let mb: Int
    let idleMin: Int
    let front: Bool
}

@MainActor
final class AppQuitter: ObservableObject {
    static let shared = AppQuitter()
    @Published private(set) var apps: [RunningAppInfo] = []
    @Published var config = QuitApps.load()

    private let started = Date()
    private var lastActive: [String: Date] = [:]
    private var tightSince: Date?
    private var keptOpen: Set<String> = []
    private var pending: (app: NSRunningApplication, id: String, name: String, mb: Int, at: Date)?
    private var lastQuit = Date.distantPast
    private var observing = false

    /// When each app was last in front: its deactivation (or activation) time. Unknown means "since Deploy Center
    /// started", so nothing is quit before idleMin after a restart.
    func start() {
        guard !observing else { return }
        observing = true
        let nc = NSWorkspace.shared.notificationCenter
        for name in [NSWorkspace.didActivateApplicationNotification, NSWorkspace.didDeactivateApplicationNotification] {
            nc.addObserver(forName: name, object: nil, queue: .main) { n in
                guard let a = n.userInfo?[NSWorkspace.applicationUserInfoKey] as? NSRunningApplication, let id = a.bundleIdentifier else { return }
                MainActor.assumeIsolated { AppQuitter.shared.lastActive[id] = Date() }
            }
        }
    }

    func save() { QuitApps.save(config) }

    /// The running regular apps with their memory, biggest first.
    func refreshApps() async {
        let running = NSWorkspace.shared.runningApplications.filter { $0.activationPolicy == .regular && $0.bundleIdentifier != nil }
        let pids = running.map(\.processIdentifier)
        let mb = await Task.detached { QuitApps.treeMB(pids) }.value
        let now = Date()
        let list = running.map { a -> RunningAppInfo in
            let id = a.bundleIdentifier ?? ""
            let last = a.isActive ? now : (lastActive[id] ?? started)
            return RunningAppInfo(id: id, name: a.localizedName ?? id, mb: mb[a.processIdentifier] ?? 0,
                                  idleMin: Int(now.timeIntervalSince(last) / 60), front: a.isActive)
        }.sorted { $0.mb > $1.mb }
        if list != apps { apps = list }
    }

    /// The apps the "not needed" suggestion offers: running, allowed, not suggested against, not picked yet.
    var suggestion: [RunningAppInfo] {
        apps.filter { QuitApps.allowed($0.id) && !QuitApps.notSuggested.contains($0.id) && !config.apps.contains($0.id) }
    }

    /// The candidates now, biggest first.
    func candidates() -> [RunningAppInfo] {
        apps.filter { config.apps.contains($0.id) && QuitApps.allowed($0.id) && !$0.front && !keptOpen.contains($0.id) && $0.idleMin >= config.idleMin }
    }

    /// Every 30 s from PerfMonitor.refresh.
    func tick(level: String, memoryTight: Bool) async {
        start()
        config = QuitApps.load()
        await refreshApps()
        let now = Date()
        let pressed = level == "red" && memoryTight
        if pressed { tightSince = tightSince ?? now } else { tightSince = nil; keptOpen = [] }
        if let p = pending {
            if p.app.isTerminated {
                finish(p)
            } else if now.timeIntervalSince(p.at) >= 30 {
                keptOpen.insert(p.id); pending = nil
                Self.log("quit: \(p.name) stayed open (unsaved documents?); left alone until the pressure is over")
            }
        }
        writePlan(pressed: pressed)
        guard config.enabled, pressed, pending == nil, let since = tightSince, now.timeIntervalSince(since) >= 300,
              now.timeIntervalSince(lastQuit) >= 120, shedSettled(now) else { return }
        guard let c = candidates().first,
              let app = NSWorkspace.shared.runningApplications.first(where: { $0.bundleIdentifier == c.id && !$0.isActive }) else { return }
        lastQuit = now
        Self.log("quit: asking \(c.name) to quit (red with memory pressure for \(Int(now.timeIntervalSince(since) / 60)) min, idle \(c.idleMin) min, about \(c.mb) MB)")
        if app.terminate() { pending = (app, c.id, c.name, c.mb, now) } else { keptOpen.insert(c.id) }
    }

    /// A shedding pass that just ran gets 90 s to show its effect (perf/shed-done, lib/perfshed.sh).
    private func shedSettled(_ now: Date) -> Bool {
        let f = PerfMonitor.agentFile.deletingLastPathComponent().appendingPathComponent("shed-done")
        guard let m = (try? FileManager.default.attributesOfItem(atPath: f.path))?[.modificationDate] as? Date else { return true }
        return now.timeIntervalSince(m) >= 90
    }

    private func finish(_ p: (app: NSRunningApplication, id: String, name: String, mb: Int, at: Date)) {
        pending = nil
        var extra = ""
        if config.helpers, let url = p.app.bundleURL {
            let pids = QuitApps.helpers(of: url)
            for pid in pids { kill(pid, SIGTERM) }
            if !pids.isEmpty { extra = L(", \(pids.count) helper(s) stopped", ", \(pids.count) Helfer beendet") }
        }
        let gb = PerfText.gb(p.mb)
        Self.log("quit: \(p.name) quit, about \(p.mb) MB\(extra)")
        Notify.post(L("Quit \(p.name) to free memory", "\(p.name) beendet, um Speicher freizugeben"),
                    L("About \(gb) freed\(extra). The Mac was overloaded.", "Etwa \(gb) frei\(extra). Der Mac war überlastet."))
        Journal.append(JournalEntry(platform: "local", name: p.name, result: "shed", seconds: nil,
                                    detail: L("Quit under memory pressure (like ⌘Q), about \(gb)\(extra)", "Unter Speicherdruck beendet (wie ⌘Q), etwa \(gb)\(extra)")))
    }

    /// perf/quit-plan.json: what would be quit now, for `deploys perf clean`. No window titles, only app names.
    private func writePlan(pressed: Bool) {
        let c = candidates()
        let o: [String: Any] = ["time": Int(Date().timeIntervalSince1970), "enabled": config.enabled, "pressed": pressed,
                                "pressedMin": tightSince.map { Int(Date().timeIntervalSince($0) / 60) } ?? 0,
                                "candidates": c.map { ["bundleId": $0.id, "name": $0.name, "mb": $0.mb, "idleMin": $0.idleMin] }]
        let f = PerfMonitor.agentFile.deletingLastPathComponent().appendingPathComponent("quit-plan.json")
        try? FileManager.default.createDirectory(at: f.deletingLastPathComponent(), withIntermediateDirectories: true)
        if let d = try? JSONSerialization.data(withJSONObject: o, options: [.sortedKeys]) { try? d.write(to: f, options: .atomic) }
    }

    static func log(_ s: String) {
        let f = PerfMonitor.agentFile.deletingLastPathComponent().appendingPathComponent("clean.log")
        let df = DateFormatter(); df.dateFormat = "yyyy-MM-dd HH:mm:ss"; df.locale = Locale(identifier: "en_US_POSIX")
        let line = Data((df.string(from: Date()) + " " + s + "\n").utf8)
        if let h = try? FileHandle(forWritingTo: f) { h.seekToEndOfFile(); h.write(line); try? h.close() }
        else { try? line.write(to: f) }
    }
}

/// Settings → General: which apps may be quit when the Mac is full.
struct QuitAppsSettings: View {
    @ObservedObject var q = AppQuitter.shared

    var body: some View {
        Toggle(L("Quit apps I picked when the Mac is overloaded", "Ausgewählte Apps beenden, wenn der Mac überlastet ist"), isOn: $q.config.enabled)
            .onChange(of: q.config.enabled) { _, _ in q.save() }
            .task { await q.refreshApps() }
            .help(L("Only when red with memory pressure for 5 minutes, only apps in the background, not used for a while, biggest first. Like ⌘Q: an app with unsaved documents stays open.",
                    "Nur bei Rot mit Speicherdruck seit 5 Minuten, nur Apps im Hintergrund, die eine Weile nicht benutzt wurden, größte zuerst. Wie ⌘Q: eine App mit ungesicherten Dokumenten bleibt offen."))
        if q.config.enabled {
            Stepper(value: $q.config.idleMin, in: 5...240, step: 5) {
                Text(L("Not used for at least \(q.config.idleMin) minutes", "Mindestens \(q.config.idleMin) Minuten nicht benutzt"))
            }
            .onChange(of: q.config.idleMin) { _, _ in q.save() }
            Toggle(L("Also stop their background helpers", "Auch ihre Hintergrund-Helfer beenden"), isOn: $q.config.helpers)
                .onChange(of: q.config.helpers) { _, _ in q.save() }
                .help(L("Windowless helper processes inside the app's bundle, after the app quit. Never login items, system services or launchd jobs.",
                        "Fensterlose Helfer im Bundle der App, nachdem sie beendet ist. Nie Anmeldeobjekte, Systemdienste oder launchd-Jobs."))
            ForEach(q.apps.filter { QuitApps.allowed($0.id) }) { a in
                Toggle(isOn: Binding(get: { q.config.apps.contains(a.id) }, set: { on in
                    if on { if !q.config.apps.contains(a.id) { q.config.apps.append(a.id) } } else { q.config.apps.removeAll { $0 == a.id } }
                    q.save()
                })) {
                    Text("\(Demo.mask(a.name)) – \(PerfText.gb(a.mb))").font(.callout)
                }
            }
            let notRunning = q.config.apps.filter { id in !q.apps.contains { $0.id == id } }
            if !notRunning.isEmpty {
                Text(L("Picked, not running: ", "Ausgewählt, läuft nicht: ") + notRunning.joined(separator: ", ")).font(.caption).foregroundStyle(.secondary)
            }
            let s = q.suggestion
            if !s.isEmpty {
                HStack {
                    Text(L("Not needed? ", "Nicht benötigt? ") + s.prefix(6).map { "\(Demo.mask($0.name)) (\(PerfText.gb($0.mb)))" }.joined(separator: ", "))
                        .font(.caption).foregroundStyle(.secondary).lineLimit(2)
                    Spacer()
                    Button(L("Pick all", "Alle übernehmen")) { q.config.apps.append(contentsOf: s.map(\.id)); q.save() }.controlSize(.small)
                }
            }
            Text(L("Never: Claude, terminals, Xcode, the Simulator, Finder, Deploy Center. Needs Deploy Center running. deploys perf clean shows what would be quit.",
                   "Nie: Claude, Terminals, Xcode, Simulator, Finder, Deploy Center. Deploy Center muss laufen. deploys perf clean zeigt, was beendet würde."))
                .font(.caption).foregroundStyle(.secondary)
        }
    }
}
