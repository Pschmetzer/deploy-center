// Deploy Center — turn off auto-deploy on Vercel and Render, then deploy by hand from one window.
// All the work is done by the `deploys` script bundled with the app; the app only calls it.
// Built by build.sh (swiftc, Swift 5 mode, no Xcode project needed).

import SwiftUI
import AppKit
import Charts
import UserNotifications
import ServiceManagement

// MARK: - Language (German if the Mac prefers it, English otherwise)

let isGerman = (Locale.preferredLanguages.first ?? "en").hasPrefix("de")
func L(_ en: String, _ de: String) -> String { isGerman ? de : en }

// MARK: - Calling the script

enum Tool {
    /// The script ships inside the app, so a download needs nothing but the app.
    static var path: String {
        Bundle.main.path(forResource: "deploys", ofType: nil) ?? NSHomeDirectory() + "/bin/deploys"
    }

    /// The PATH of the person's login shell, read once, so `vercel` installed through nvm, volta or
    /// fnm is found too. The usual places come first in case the shell says nothing in time.
    static let searchPath: String = {
        let fixed = "/opt/homebrew/bin:/usr/local/bin:" + NSHomeDirectory() + "/.local/bin:/usr/bin:/bin:/usr/sbin:/sbin"
        let p = Process()
        p.executableURL = URL(fileURLWithPath: ProcessInfo.processInfo.environment["SHELL"] ?? "/bin/zsh")
        p.arguments = ["-lc", "printf %s \"$PATH\""]
        let out = Pipe(); p.standardOutput = out; p.standardError = FileHandle.nullDevice
        guard (try? p.run()) != nil else { return fixed }
        let killer = DispatchWorkItem { if p.isRunning { p.terminate() } }
        DispatchQueue.global().asyncAfter(deadline: .now() + 3, execute: killer)
        let data = out.fileHandleForReading.readDataToEndOfFile()
        p.waitUntilExit(); killer.cancel()
        let shell = String(data: data, encoding: .utf8)?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
        return shell.isEmpty ? fixed : fixed + ":" + shell
    }()

    /// Runs off the main thread. A GUI app does not get the shell's PATH, and `vercel` needs node.
    /// stdout and stderr are read at the same time (reading one to the end first can deadlock
    /// once the other fills its pipe), and a command that hangs is ended after `timeout` seconds.
    static func run(_ args: [String], stdin: String? = nil, timeout: Double = 120) async throws -> Data {
        try await withCheckedThrowingContinuation { cont in
            DispatchQueue.global(qos: .userInitiated).async {
                let p = Process()
                p.executableURL = URL(fileURLWithPath: "/bin/bash")
                p.arguments = [path] + args
                var env = ProcessInfo.processInfo.environment
                env["PATH"] = searchPath
                p.environment = env
                let out = Pipe(), err = Pipe()
                p.standardOutput = out
                p.standardError = err
                if let stdin {
                    let inPipe = Pipe()
                    p.standardInput = inPipe
                    inPipe.fileHandleForWriting.write(Data((stdin + "\n").utf8))
                    try? inPipe.fileHandleForWriting.close()
                }
                do { try p.run() } catch { cont.resume(throwing: error); return }
                var errData = Data()
                let errDone = DispatchGroup()
                errDone.enter()
                DispatchQueue.global().async { errData = err.fileHandleForReading.readDataToEndOfFile(); errDone.leave() }
                var timedOut = false
                let killer = DispatchWorkItem { if p.isRunning { timedOut = true; p.terminate() } }
                DispatchQueue.global().asyncAfter(deadline: .now() + timeout, execute: killer)
                let data = out.fileHandleForReading.readDataToEndOfFile()
                errDone.wait()
                p.waitUntilExit()
                killer.cancel()
                if timedOut {
                    cont.resume(throwing: ToolError(message: L("No answer after \(Int(timeout)) seconds – try again.",
                                                              "Keine Antwort nach \(Int(timeout)) Sekunden – nochmal versuchen.")))
                } else if p.terminationStatus == 0 {
                    cont.resume(returning: data)
                } else {
                    let msg = String(data: errData, encoding: .utf8)?
                        .trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
                    let text = msg.isEmpty ? "Exit code \(p.terminationStatus)" : msg
                    Log.write("deploys \(args.joined(separator: " ")): \(text)")
                    cont.resume(throwing: ToolError(message: text))
                }
            }
        }
    }

    static func json<T: Decodable>(_ args: [String], as type: T.Type) async throws -> T {
        try JSONDecoder().decode(T.self, from: try await run(args))
    }
}

struct ToolError: LocalizedError {
    let message: String
    var errorDescription: String? { message }
}

/// Errors go to ~/Library/Logs/DeployCenter.log, so one can be attached to an issue.
/// Only what the script said and when; no keys ever reach the script's output.
enum Log {
    static let url = FileManager.default.homeDirectoryForCurrentUser.appendingPathComponent("Library/Logs/DeployCenter.log")
    static func write(_ line: String) {
        let text = "\(Date().formatted(.iso8601))  \(line)\n"
        if let h = try? FileHandle(forWritingTo: url) { h.seekToEndOfFile(); h.write(Data(text.utf8)); try? h.close() }
        else { try? Data(text.utf8).write(to: url) }
        // Kept small: past 1 MB the older half goes.
        if let size = try? FileManager.default.attributesOfItem(atPath: url.path)[.size] as? Int, size > 1_000_000,
           let data = try? Data(contentsOf: url) { try? data.suffix(500_000).write(to: url) }
    }
}

// MARK: - Data

enum Platform: String, CaseIterable, Identifiable {
    case vercel = "Vercel", render = "Render"
    var id: String { rawValue }
    var cli: String { rawValue.lowercased() }
}

struct Doctor: Decodable {
    let jq: Bool; let vercelCli: Bool; let vercelApi: Bool; let vercelLoggedIn: Bool; let githubCli: Bool; let githubLoggedIn: Bool?; let renderKey: Bool
}

struct VercelProject: Decodable {
    let name: String; let auto: Bool; let repo: String?; let ref: String?; let deployable: Bool
    let domain: String?; let lastAt: Double?; let lastState: String?; let headAt: Double?; let headMsg: String?
    let lastSha: String?; let headSha: String?
    let changed: Bool?; let pendingCommits: Int?; let pendingPRs: Int?; let openPRs: Int?
    let building: Bool?; let pendingPartial: Bool?; let oldestPendingAt: Double?; let rewritten: Bool?
    let openDrafts: Int?; let openBots: Int?
    let lastMsg: String?
}
struct RenderService: Decodable {
    let id: String; let name: String; let type: String; let paused: Bool; let auto: Bool; let deployable: Bool
    let url: String?; let domain: String?; let repo: String?; let ref: String?
    let lastAt: Double?; let lastState: String?; let headAt: Double?; let headMsg: String?
    let lastSha: String?; let headSha: String?
    let changed: Bool?; let pendingCommits: Int?; let pendingPRs: Int?; let openPRs: Int?
    let building: Bool?; let pendingPartial: Bool?; let oldestPendingAt: Double?; let rewritten: Bool?
    let openDrafts: Int?; let openBots: Int?
    let lastMsg: String?
}
struct Costs: Decodable {
    struct Day: Decodable, Identifiable { let day: String; let total: Double; let build: Double; var id: String { day } }
    struct Project: Decodable { let name: String; let build: Double; let builds: Int? }
    let days: [Day]; let projects: [Project]; let offDay: String?; let buildsComplete: Bool?

    /// What one build of a project cost on average, only when every build of the week was counted.
    func perBuild(_ name: String) -> Double? {
        guard buildsComplete == true, let p = projects.first(where: { $0.name == name }), let n = p.builds, n > 0 else { return nil }
        return p.build / Double(n)
    }
}
struct Trigger: Decodable, Identifiable {
    let kind: String; let `where`: String; let detail: String
    var id: String { kind + `where` + detail }
}
/// One repo in detail, read when the details are opened (`deploys details`).
struct Details: Decodable {
    struct Commit: Decodable, Identifiable {
        let sha: String; let full: String?; let url: String?; let msg: String; let author: String?; let bot: Bool?; let at: Double; let pr: Int?
        var id: String { sha }
    }
    struct Checks: Decodable { let total: Int; let failed: Int; let running: Int }
    struct OpenPR: Decodable, Identifiable {
        let number: Int; let title: String; let author: String?; let bot: Bool?; let draft: Bool; let updatedAt: String; let url: String; let ci: String
        var id: Int { number }
    }
    let commits: [Commit]; let files: Int; let additions: Int; let deletions: Int; let risky: [String]
    let onlyBots: Bool; let compareUrl: String?; let checks: Checks?; let open: [OpenPR]
}

struct Started: Decodable { let id: String; let url: String?; let state: String? }
struct StatusReply: Decodable { let id: String; let url: String?; let state: String?; let error: String? }

enum RunState: Equatable {
    case idle, queued, starting, running(String), done(String?), failed(String), skipped(String)
    var isActive: Bool { switch self { case .queued, .starting, .running: return true; default: return false } }
}

struct Item: Identifiable {
    let id: String          // Vercel: project name, Render: service id
    let name: String
    let detail: String
    let platform: Platform
    let deployable: Bool
    let auto: Bool
    let note: String?
    let link: String?
    var domain: String? = nil
    var lastAt: Date? = nil
    var lastState: String? = nil
    var headAt: Date? = nil
    var headMsg: String? = nil
    var lastSha: String? = nil
    var headSha: String? = nil
    var repo: String? = nil
    var ref: String? = nil
    var kind: String? = nil        // Render service type, for the dashboard link
    /// Decided by the script (`changed`), so the app and `deploys changed` never disagree.
    var changed: Bool? = nil
    var pendingCommits: Int? = nil
    var pendingPRs: Int? = nil
    var openPRs: Int? = nil
    var lastMsg: String? = nil
    var openDrafts: Int? = nil
    var openBots: Int? = nil
    var building = false
    var pendingPartial = false
    var oldestPendingAt: Date? = nil
    var rewritten = false
    var selected = false
    var state: RunState = .idle
    var startedAt: Date? = nil
    var deployId: String? = nil      // the deploy being followed, for cancelling
    var previewId: String? = nil     // a finished preview, for promoting it

    /// GitHub's page of the commits between what is live and the branch.
    var compareURL: URL? {
        guard let repo, let live = lastSha, !live.isEmpty, hasNewCommits else { return nil }
        return URL(string: "https://github.com/\(repo)/compare/\(live)...\(ref ?? headSha ?? "main")")
    }

    /// The service's page on Render; Vercel's address needs the team's slug, which the list does not carry.
    var dashboardURL: URL? {
        guard platform == .render else { return nil }
        let section = ["static_site": "static", "cron_job": "cron", "background_worker": "worker"][kind ?? ""] ?? "web"
        return URL(string: "https://dashboard.render.com/\(section)/\(id)")
    }

    /// A commit on GitHub that is not live yet.
    var hasNewCommits: Bool {
        if let changed { return changed }
        // An older script without `changed`: compare commits, times only as a fallback.
        if let live = lastSha, let head = headSha, !live.isEmpty, !head.isEmpty { return live != head }
        guard let h = headAt else { return false }
        guard let l = lastAt else { return true }
        return h > l.addingTimeInterval(60)
    }
}

/// A Mac notification when a deploy ends while the window is in the background.
/// Permission is asked at the first deploy, not at launch. An ad-hoc build may be refused; then nothing shows.
@MainActor
enum Notify {
    private static var asked = false
    static func ask() {
        guard !asked else { return }
        asked = true
        UNUserNotificationCenter.current().requestAuthorization(options: [.alert, .sound]) { _, _ in }
    }
    /// A reminder the person set up themselves: shown whether or not the window is in front.
    static func remind(_ title: String, _ body: String) {
        let c = UNMutableNotificationContent()
        c.title = title; c.body = body; c.sound = .default
        UNUserNotificationCenter.current().add(UNNotificationRequest(identifier: "daily-reminder", content: c, trigger: nil))
    }
    static func post(_ title: String, _ body: String) {
        guard asked, !NSApp.isActive, UserDefaults.standard.object(forKey: "notifications") as? Bool ?? true else { return }
        let c = UNMutableNotificationContent()
        c.title = title; c.body = body; c.sound = .default
        UNUserNotificationCenter.current().add(UNNotificationRequest(identifier: UUID().uuidString, content: c, trigger: nil))
    }
}

func date(_ secs: Double?) -> Date? { secs.flatMap { $0 > 0 ? Date(timeIntervalSince1970: $0) : nil } }

// MARK: - Model

@MainActor
final class Store: ObservableObject {
    @Published var items: [Platform: [Item]] = [.vercel: [], .render: []]
    @Published var loading: Set<Platform> = []
    @Published var loadError: [Platform: String] = [:]
    @Published var doctor: Doctor?
    @Published var busyMessage: String?

    @Published var doctorError: String?
    @Published var costs: Costs?
    @Published var triggers: [Trigger] = []

    /// Costs and stray build triggers load after the lists; neither blocks deploying.
    func loadExtras() async {
        if doctor?.vercelLoggedIn == true {
            costs = try? await Tool.json(["costs", "14"], as: Costs.self)
        }
        triggers = (try? await Tool.json(["triggers"], as: [Trigger].self)) ?? []
        if doctor?.githubLoggedIn == true {
            githubBudget = try? await Tool.json(["github-budget"], as: Budget.self)
        }
    }

    func buildCost(_ project: String) -> Double? {
        costs?.projects.first(where: { $0.name == project }).map(\.build)
    }

    /// When each list was last read, and which ones are still the copy from the last run.
    @Published var loadedAt: [Platform: Date] = [:]
    @Published var fromCache: Set<Platform> = []

    // MARK: Cache — the last lists, so the window is full at once instead of after 10 seconds

    nonisolated static let cacheDir: URL = {
        let base = FileManager.default.urls(for: .cachesDirectory, in: .userDomainMask)[0]
        return base.appendingPathComponent("app.deploycenter.mac", isDirectory: true)
    }()
    private func cacheURL(_ p: Platform) -> URL { Self.cacheDir.appendingPathComponent("\(p.cli)-v2.json") }

    private func readCache() {
        for p in Platform.allCases {
            guard let data = try? Data(contentsOf: cacheURL(p)), let list = try? decode(p, data) else { continue }
            items[p] = list
            fromCache.insert(p)
            loadedAt[p] = (try? FileManager.default.attributesOfItem(atPath: cacheURL(p).path)[.modificationDate]) as? Date
        }
    }

    private func writeCache(_ p: Platform, _ data: Data) {
        try? FileManager.default.createDirectory(at: Self.cacheDir, withIntermediateDirectories: true)
        try? data.write(to: cacheURL(p), options: .atomic)
    }

    /// Started once, by whichever comes first: the window or the menu bar. The refresh loop lives
    /// here and not in a view, so the menu bar stays true while the window is closed.
    private var booted = false
    func boot() {
        guard !booted else { return }
        booted = true
        if UserDefaults.standard.bool(forKey: "hideDock") { NSApp.setActivationPolicy(.accessory) }
        LogoCache.sweep()
        Task { await checkForUpdate() }
        Task {
            await start()
            while !Task.isCancelled {
                try? await Task.sleep(nanoseconds: UInt64(refreshMinutes) * 60 * 1_000_000_000)
                await autoRefresh()
                remindIfDue()
            }
        }
    }

    /// Minutes between automatic reloads (Settings).
    var refreshMinutes: Int {
        let m = UserDefaults.standard.integer(forKey: "refreshMinutes")
        return m >= 5 ? m : 15
    }

    func start() async {
        if items.values.allSatisfy({ $0.isEmpty }) { readCache() }
        do {
            doctor = try await Tool.json(["doctor"], as: Doctor.self); doctorError = nil
        } catch {
            doctorError = error.localizedDescription; return
        }
        guard doctor?.jq == true else { return }
        // Both at once: each takes several seconds.
        let v = doctor?.vercelLoggedIn == true && doctor?.vercelApi == true
        let r = doctor?.renderKey == true
        async let a: Void = v ? load(.vercel) : ()
        async let b: Void = r ? load(.render) : ()
        _ = await (a, b)
        await loadExtras()
    }

    func load(_ p: Platform) async {
        loading.insert(p); loadError[p] = nil
        defer { loading.remove(p) }
        do {
            let data = try await Tool.run([p.cli, "json"])
            merge(p, try decode(p, data))
            writeCache(p, data)
            fromCache.remove(p); loadedAt[p] = Date()
            recordHistory()
        } catch {
            loadError[p] = error.localizedDescription
        }
    }

    /// A reload keeps what the person did: ticks stay, a deploy being followed keeps its state.
    private func merge(_ p: Platform, _ fresh: [Item]) {
        let old = Dictionary((items[p] ?? []).map { ($0.id, $0) }, uniquingKeysWith: { a, _ in a })
        items[p] = fresh.map { n in
            var n = n
            if let o = old[n.id] {
                n.selected = o.selected && n.deployable
                if o.state != .idle { n.state = o.state }
            }
            return n
        }
    }

    private func decode(_ p: Platform, _ data: Data) throws -> [Item] {
            switch p {
            case .vercel:
                let list = try JSONDecoder().decode([VercelProject].self, from: data)
                return list.map { v in
                    Item(id: v.name, name: v.name,
                         detail: v.repo.map { "\($0) · \(v.ref ?? "main")" } ?? L("no Git repository", "kein Git-Repo"),
                         platform: .vercel, deployable: v.deployable, auto: v.auto,
                         note: v.auto ? L("deploys on every push", "deployt bei jedem Push")
                             : (v.deployable ? nil : L("repo unknown", "Repo unbekannt")),
                         link: v.domain.map { "https://\($0)" },
                         domain: v.domain, lastAt: date(v.lastAt), lastState: v.lastState,
                         headAt: date(v.headAt), headMsg: v.headMsg, lastSha: v.lastSha, headSha: v.headSha,
                         repo: v.repo, ref: v.ref, changed: v.changed, pendingCommits: v.pendingCommits,
                         pendingPRs: v.pendingPRs, openPRs: v.openPRs, lastMsg: v.lastMsg, openDrafts: v.openDrafts, openBots: v.openBots,
                         building: v.building ?? false, pendingPartial: v.pendingPartial ?? false,
                         oldestPendingAt: date(v.oldestPendingAt), rewritten: v.rewritten ?? false)
                }
            case .render:
                let list = try JSONDecoder().decode([RenderService].self, from: data)
                return list.map { r in
                    Item(id: r.id, name: r.name,
                         detail: Self.typeName(r.type) + (r.repo.map { " · \($0) · \(r.ref ?? "main")" } ?? ""),
                         platform: .render, deployable: r.deployable, auto: r.auto,
                         note: r.paused ? L("suspended", "pausiert")
                             : (r.auto ? L("deploys on every push", "deployt bei jedem Push") : nil),
                         link: r.url, domain: r.domain, lastAt: date(r.lastAt), lastState: r.lastState,
                         headAt: date(r.headAt), headMsg: r.headMsg, lastSha: r.lastSha, headSha: r.headSha,
                         repo: r.repo, ref: r.ref, kind: r.type, changed: r.changed, pendingCommits: r.pendingCommits,
                         pendingPRs: r.pendingPRs, openPRs: r.openPRs, lastMsg: r.lastMsg, openDrafts: r.openDrafts, openBots: r.openBots,
                         building: r.building ?? false, pendingPartial: r.pendingPartial ?? false,
                         oldestPendingAt: date(r.oldestPendingAt), rewritten: r.rewritten ?? false)
                }
            }
    }

    /// Lists only, both platforms; costs and triggers cost many GitHub calls and stay manual.
    /// Not while something is deploying, so nothing being followed is disturbed.
    func autoRefresh() async {
        let busy = items.values.joined().contains { $0.state.isActive }
        guard !busy, loading.isEmpty else { return }
        if doctor == nil { await start(); return }
        async let a: Void = doctor?.vercelLoggedIn == true ? load(.vercel) : ()
        async let b: Void = doctor?.renderKey == true ? load(.render) : ()
        _ = await (a, b)
    }

    // MARK: What is waiting on GitHub, over both platforms

    struct Waiting { var projects = 0, commits = 0, prs = 0, openPRs = 0 }
    var waiting: Waiting {
        var w = Waiting()
        let all = Array(items.values.joined())
        for i in all where i.hasNewCommits && i.state == .idle {
            w.projects += 1; w.commits += i.pendingCommits ?? 0; w.prs += i.pendingPRs ?? 0
        }
        // Open pull requests belong to a repo, and several projects can share one.
        var seen = Set<String>()
        for i in all { if let r = i.repo, let n = i.openPRs, seen.insert(r).inserted { w.openPRs += n } }
        return w
    }

    static func typeName(_ t: String) -> String {
        switch t {
        case "web_service": return "Web Service"
        case "static_site": return "Static Site"
        case "cron_job": return "Cron Job"
        case "background_worker": return "Worker"
        default: return t
        }
    }

    func selected(_ p: Platform) -> [Item] { (items[p] ?? []).filter { $0.selected } }
    func autoOn(_ p: Platform) -> [Item] { (items[p] ?? []).filter { $0.auto } }
    func changedCount(_ p: Platform) -> Int { (items[p] ?? []).filter { $0.deployable && $0.hasNewCommits }.count }

    func toggle(_ p: Platform, _ id: String) {
        guard let i = items[p]?.firstIndex(where: { $0.id == id }), items[p]![i].deployable else { return }
        items[p]![i].selected.toggle()
    }

    func clearSelection(_ p: Platform) {
        for i in (items[p] ?? []).indices { items[p]![i].selected = false }
    }

    func selectChanged(_ p: Platform) {
        for i in (items[p] ?? []).indices where items[p]![i].deployable && items[p]![i].hasNewCommits && !items[p]![i].state.isActive {
            items[p]![i].selected = true
        }
    }

    func turnOffAutoDeploy(_ p: Platform) async {
        busyMessage = L("Turning off auto-deploy …", "Schalte Auto-Deploy aus …")
        defer { busyMessage = nil }
        do { _ = try await Tool.run([p.cli, "autodeploy-off", "--all"]) }
        catch { loadError[p] = error.localizedDescription }
        await load(p)
    }

    func saveRenderKey(_ key: String) async -> String? {
        do {
            _ = try await Tool.run(["render", "set-key"], stdin: key.trimmingCharacters(in: .whitespacesAndNewlines))
            doctor = try? await Tool.json(["doctor"], as: Doctor.self)
            await load(.render)
            return nil
        } catch { return error.localizedDescription }
    }

    private func set(_ p: Platform, _ id: String, _ s: RunState, countsAsLive: Bool = true) {
        guard let i = items[p]?.firstIndex(where: { $0.id == id }) else { return }
        items[p]![i].state = s
        if case .starting = s { items[p]![i].startedAt = Date() }
        if case .done = s, countsAsLive {
            items[p]![i].lastSha = items[p]![i].headSha
            items[p]![i].lastAt = Date(); items[p]![i].lastState = p == .vercel ? "READY" : "live"
            items[p]![i].changed = false; items[p]![i].pendingCommits = 0; items[p]![i].pendingPRs = 0
        }
        let name = items[p]![i].name
        switch s {
        case .done: say(L("\(name) is live", "\(name) ist live"), p.rawValue, ok: true)
        case .failed(let m): say(L("\(name) failed", "\(name) fehlgeschlagen"), m, ok: false)
        case .skipped(let m): say(L("\(name) skipped", "\(name) übersprungen"), m, ok: true)
        default: break
        }
    }

    /// The end of a deploy: a Mac notification when the app is in the background, a line in the
    /// window in any case (the person may be looking at the other tab).
    struct Toast: Equatable { let id = UUID(); let text: String; let ok: Bool }
    @Published var toast: Toast?
    private func say(_ title: String, _ body: String, ok: Bool) {
        Notify.post(title, body)
        let t = Toast(text: title, ok: ok)
        toast = t
        Task { try? await Task.sleep(nanoseconds: 5_000_000_000); if toast == t { toast = nil } }
    }

    /// GitHub's hourly budget for the gh login; the counts need it.
    struct Budget: Decodable { let remaining: Int; let limit: Int; let reset: Double }
    @Published var githubBudget: Budget?

    // MARK: The person's own marks: pinned, hidden, a note. Kept in this Mac's preferences.

    @Published var pinned: Set<String> = Set(UserDefaults.standard.stringArray(forKey: "pinned") ?? [])
    @Published var hidden: Set<String> = Set(UserDefaults.standard.stringArray(forKey: "hidden") ?? [])
    @Published var notes: [String: String] = (UserDefaults.standard.dictionary(forKey: "notes") as? [String: String]) ?? [:]
    static func key(_ i: Item) -> String { "\(i.platform.cli)/\(i.id)" }
    func isPinned(_ i: Item) -> Bool { pinned.contains(Self.key(i)) }
    func isHidden(_ i: Item) -> Bool { hidden.contains(Self.key(i)) }
    func note(_ i: Item) -> String? { notes[Self.key(i)] }
    func togglePin(_ i: Item) {
        if pinned.remove(Self.key(i)) == nil { pinned.insert(Self.key(i)) }
        UserDefaults.standard.set(Array(pinned), forKey: "pinned")
    }
    func toggleHidden(_ i: Item) {
        if hidden.remove(Self.key(i)) == nil { hidden.insert(Self.key(i)); items[i.platform]?.indices.forEach { j in
            if items[i.platform]![j].id == i.id { items[i.platform]![j].selected = false } } }
        UserDefaults.standard.set(Array(hidden), forKey: "hidden")
    }
    func setNote(_ i: Item, _ text: String) {
        let t = text.trimmingCharacters(in: .whitespacesAndNewlines)
        notes[Self.key(i)] = t.isEmpty ? nil : t
        UserDefaults.standard.set(notes, forKey: "notes")
    }

    // MARK: How many PRs waited, per day (the highest count seen that day), for 30 days.

    @Published var history: [String: Int] = (UserDefaults.standard.dictionary(forKey: "waitingHistory") as? [String: Int]) ?? [:]
    private func recordHistory() {
        let day = Date().formatted(.iso8601.year().month().day())
        history[day] = max(history[day] ?? 0, waiting.prs)
        let keep = history.keys.sorted().suffix(30)
        history = history.filter { keep.contains($0.key) }
        UserDefaults.standard.set(history, forKey: "waitingHistory")
    }

    /// Set by the menu bar to show one project in the window.
    @Published var pendingSearch: String?
    /// Set by the menu bar: tick everything with changes and ask, in the window.
    @Published var pendingDeployAll = false

    // MARK: The queue: at most N builds at once, a frontend after the backend of its repo

    struct Job { let item: Item; var preview = false; var sha: String? = nil; var clearCache = false }
    private var queue: [Job] = []
    private var running = 0
    private var cancelled: Set<String> = []
    var maxParallel: Int { let n = UserDefaults.standard.integer(forKey: "maxParallel"); return n >= 1 ? n : 3 }

    func deploySelected(_ p: Platform, preview: Bool = false) {
        let chosen = selected(p)
        clearSelection(p)
        enqueue(chosen.map { Job(item: $0, preview: preview) })
    }

    func deployOne(_ item: Item, preview: Bool, sha: String? = nil, clearCache: Bool = false) {
        enqueue([Job(item: item, preview: preview, sha: sha, clearCache: clearCache)])
    }

    func enqueue(_ jobs: [Job]) {
        Notify.ask()
        for j in jobs where !(itemNow(j.item)?.state.isActive ?? false) {
            set(j.item.platform, j.item.id, .queued)
            queue.append(j)
        }
        pump()
    }

    private func itemNow(_ i: Item) -> Item? { items[i.platform]?.first { $0.id == i.id } }

    private func pump() {
        while running < maxParallel, let k = queue.firstIndex(where: { waitsFor($0) == nil }) {
            let job = queue.remove(at: k)
            running += 1
            Task { await deploy(job); running -= 1; pump() }
        }
        // A frontend whose backend failed in this batch does not go out alone.
        for job in queue {
            if case .failed? = waitsFor(job).flatMap({ itemNow($0)?.state }) {
                queue.removeAll { $0.item.id == job.item.id }
                set(job.item.platform, job.item.id, .failed(L("Not started: the backend of the same repo failed",
                                                             "Nicht gestartet: das Backend desselben Repos ist fehlgeschlagen")))
            }
        }
        if queue.isEmpty && running == 0 { queueBatch = [] }
    }

    /// The Render service of the same repo that a Vercel frontend waits for, while it is queued or building.
    private func waitsFor(_ job: Job) -> Item? {
        guard job.item.platform == .vercel, !job.preview, let repo = job.item.repo else { return nil }
        return (items[.render] ?? []).first { b in
            guard b.repo == repo else { return false }
            if b.state.isActive || queue.contains(where: { $0.item.id == b.id }) { return true }
            if case .failed = b.state, queueBatch.contains(b.id) { return true }
            return false
        }
    }
    /// Render services started in the current run of the queue, so an old failure does not hold a frontend.
    private var queueBatch: Set<String> = []

    func cancel(_ item: Item) {
        if let k = queue.firstIndex(where: { $0.item.id == item.id }) {
            queue.remove(at: k); set(item.platform, item.id, .idle); return
        }
        guard let id = itemNow(item)?.deployId else { return }
        cancelled.insert(item.id)
        Task {
            let args = item.platform == .vercel ? ["vercel", "cancel", id] : ["render", "cancel", item.id, id]
            do { _ = try await Tool.run(args); set(item.platform, item.id, .failed(L("Cancelled", "Abgebrochen"))) }
            catch { cancelled.remove(item.id); say(L("Could not cancel \(item.name)", "\(item.name) ließ sich nicht abbrechen"), error.localizedDescription, ok: false) }
        }
    }

    /// A finished Vercel preview goes live without another build.
    func promote(_ item: Item) {
        guard let pid = itemNow(item)?.previewId else { return }
        Task {
            set(item.platform, item.id, .starting)
            do { _ = try await Tool.run(["vercel", "promote", item.id, pid]); set(item.platform, item.id, .done(item.link)) }
            catch { set(item.platform, item.id, .failed(error.localizedDescription)) }
        }
    }

    // MARK: The daily reminder: a notification at the chosen hour when something waits.
    // It reminds; it never deploys by itself.

    private func remindIfDue() {
        let d = UserDefaults.standard
        let hour = d.integer(forKey: "reminderHour")   // 0 = off
        guard hour > 0, Calendar.current.component(.hour, from: Date()) >= hour else { return }
        let today = Date().formatted(.iso8601.year().month().day())
        guard d.string(forKey: "lastReminder") != today else { return }
        let w = waiting
        guard w.projects > 0 else { return }
        d.set(today, forKey: "lastReminder")
        Notify.remind(L("Time for the daily deploy", "Zeit für den täglichen Deploy"),
                      L("\(w.prs) PRs in \(w.projects) projects wait to go live.", "\(w.prs) PRs in \(w.projects) Projekten warten darauf, live zu gehen."))
    }

    // MARK: How long a build usually takes, per project (the last five)

    private var durations: [String: [Double]] {
        get { (UserDefaults.standard.dictionary(forKey: "durations") as? [String: [Double]]) ?? [:] }
        set { UserDefaults.standard.set(newValue, forKey: "durations") }
    }
    func usualMinutes(_ i: Item) -> Int? {
        guard let d = durations[Self.key(i)], !d.isEmpty else { return nil }
        return max(1, Int((d.reduce(0, +) / Double(d.count) / 60).rounded()))
    }
    private func recordDuration(_ i: Item) {
        guard let start = itemNow(i)?.startedAt else { return }
        var all = durations; var d = all[Self.key(i)] ?? []
        d.append(Date().timeIntervalSince(start)); all[Self.key(i)] = Array(d.suffix(5)); durations = all
    }

    /// Production back to what was live before.
    func rollback(_ item: Item) {
        Notify.ask()
        Task {
            let p = item.platform
            set(p, item.id, .starting)
            do {
                let r = try await Tool.json([p.cli, "rollback", item.id], as: Started.self)
                if p == .vercel { set(p, item.id, .done(item.link)) }
                else { set(p, item.id, .running(L("rolling back", "rollt zurück"))); try await follow(item, deployId: r.id, url: item.link) }
            } catch { set(p, item.id, .failed(error.localizedDescription)) }
        }
    }

    private func deploy(_ job: Job) async {
        let item = job.item, p = item.platform
        if p == .render { queueBatch.insert(item.id) }
        set(p, item.id, .starting)
        cancelled.remove(item.id)
        do {
            var args = [p.cli, "deploy-json", item.id]
            if job.preview { args.append("--preview") }
            if let sha = job.sha { args += ["--sha", sha] }
            if job.clearCache { args.append("--clear-cache") }
            let started = try await Tool.json(args, as: Started.self)
            if let k = items[p]?.firstIndex(where: { $0.id == item.id }) { items[p]![k].deployId = started.id }
            set(p, item.id, .running(started.state ?? L("started", "gestartet")))
            try await follow(item, deployId: started.id, url: started.url, preview: job.preview)
        } catch {
            set(p, item.id, .failed(error.localizedDescription))
        }
        pump()
    }

    /// Asks every 6 seconds until the deploy is live or failed (40 minutes at most).
    private func follow(_ item: Item, deployId: String, url: String?, preview: Bool = false) async throws {
        let p = item.platform
        for _ in 0..<400 {
            try await Task.sleep(nanoseconds: 6_000_000_000)
            if cancelled.contains(item.id) { return }
            let args = p == .vercel ? ["vercel", "status", deployId] : ["render", "status", item.id, deployId]
            guard let s = try? await Tool.json(args, as: StatusReply.self) else { continue }
            let state = (s.state ?? "").lowercased()
            switch (p, state) {
            case (.vercel, "ready"), (.render, "live"):
                if preview {
                    if let k = items[p]?.firstIndex(where: { $0.id == item.id }) { items[p]![k].previewId = deployId }
                    set(p, item.id, .done(s.url ?? url), countsAsLive: false)
                } else {
                    recordDuration(item)
                    set(p, item.id, .done(p == .vercel ? (item.link ?? s.url ?? url) : item.link))
                    if let l = item.link { await checkSite(item.name, l) }
                }
                return
            case (.render, "succeeded"):
                set(p, item.id, .done(nil)); return
            case (.vercel, "canceled"):
                // Usually the project's "Ignored Build Step" decided nothing changed.
                set(p, item.id, .skipped(L("Skipped or canceled by Vercel (Ignored Build Step?)",
                                          "Von Vercel übersprungen oder abgebrochen (Ignored Build Step?)"))); return
            case (.vercel, "error"), (.render, "build_failed"), (.render, "update_failed"),
                 (.render, "canceled"), (.render, "pre_deploy_failed"), (.render, "deactivated"):
                set(p, item.id, .failed(s.error ?? "Status: \(state)")); return
            default:
                set(p, item.id, .running(Self.stateName(state)))
            }
        }
        set(p, item.id, .failed(L("No result after 40 minutes – check the dashboard", "Kein Ergebnis nach 40 Minuten – im Dashboard nachsehen")))
    }

    /// After going live: does the site answer? A deploy can be "ready" and the page still broken.
    private func checkSite(_ name: String, _ link: String) async {
        guard let url = URL(string: link) else { return }
        var req = URLRequest(url: url, timeoutInterval: 20)
        req.setValue("DeployCenter (post-deploy check)", forHTTPHeaderField: "User-Agent")
        let code = ((try? await URLSession.shared.data(for: req))?.1 as? HTTPURLResponse)?.statusCode
        if let code, code < 400 { return }   // fine: the "is live" line already said enough
        say(L("\(name) is live, but the site answers \(code.map(String.init) ?? "nothing")",
              "\(name) ist live, aber die Seite antwortet mit \(code.map(String.init) ?? "nichts")"), link, ok: false)
    }

    // MARK: A newer version on GitHub, asked once a day (Settings can turn it off)

    @Published var newVersion: String?
    func checkForUpdate() async {
        let d = UserDefaults.standard
        guard d.object(forKey: "checkUpdates") as? Bool ?? true else { return }
        let last = d.double(forKey: "lastUpdateCheck")
        guard Date().timeIntervalSince1970 - last > 86400 else { newVersion = d.string(forKey: "newVersion"); return }
        d.set(Date().timeIntervalSince1970, forKey: "lastUpdateCheck")
        guard let url = URL(string: "https://api.github.com/repos/Pschmetzer/deploy-center/releases/latest"),
              let (data, _) = try? await URLSession.shared.data(from: url),
              let tag = (try? JSONSerialization.jsonObject(with: data) as? [String: Any])?["tag_name"] as? String else { return }
        let latest = tag.trimmingCharacters(in: CharacterSet(charactersIn: "v"))
        let mine = Bundle.main.infoDictionary?["CFBundleShortVersionString"] as? String ?? "0"
        let newer = latest.compare(mine, options: .numeric) == .orderedDescending
        newVersion = newer ? latest : nil
        d.set(newVersion, forKey: "newVersion")
    }

    static func stateName(_ s: String) -> String {
        switch s {
        case "queued", "created", "initializing": return L("queued", "wartet")
        case "building", "build_in_progress": return L("building", "baut")
        case "update_in_progress", "pre_deploy_in_progress": return L("going live", "geht live")
        default: return s.isEmpty ? L("running", "läuft") : s
        }
    }
}

// MARK: - Window

struct ContentView: View {
    @ObservedObject var store: Store
    @State private var platform: Platform = .vercel
    @State private var search = ""
    @State private var confirming = false
    @State private var confirmingOff = false
    @State private var onlyChanged = false
    @State private var rollbackItem: Item?
    @FocusState private var searchFocused: Bool
    @State private var unchangedItem: Item?
    @State private var detailItem: Item?
    @State private var showAll = false
    @State private var noteItem: Item?
    @State private var noteText = ""
    @State private var logItem: Item?
    @State private var promoteItem: Item?

    /// The platforms the list shows: one tab, or both under "All".
    private var scopes: [Platform] { showAll ? Platform.allCases : [platform] }

    private enum Tab: Hashable { case all, vercel, render }
    private var tab: Binding<Tab> {
        Binding(get: { showAll ? .all : (platform == .vercel ? .vercel : .render) },
                set: { t in showAll = t == .all; if t == .vercel { platform = .vercel } else if t == .render { platform = .render } })
    }

    private var visible: [Item] {
        var all = scopes.flatMap { store.items[$0] ?? [] }.filter { !store.isHidden($0) }
        if onlyChanged { all = all.filter { $0.hasNewCommits } }
        if !search.isEmpty {
            all = all.filter { $0.name.localizedCaseInsensitiveContains(search) || $0.detail.localizedCaseInsensitiveContains(search)
                || ($0.domain ?? "").localizedCaseInsensitiveContains(search) }
        }
        // What waits to go live first, most commits first; the rest by name as the script sorted it.
        // Pinned first, then what waits to go live (most commits first), then the rest by name.
        let pins = all.filter { store.isPinned($0) }
        let rest = all.filter { !store.isPinned($0) }
        let changed = rest.filter { $0.hasNewCommits && $0.deployable }
            .sorted { ($0.pendingCommits ?? 0) > ($1.pendingCommits ?? 0) }
        let others = rest.filter { !($0.hasNewCommits && $0.deployable) }
        return pins + changed + (showAll ? others.sorted { $0.name.localizedCaseInsensitiveCompare($1.name) == .orderedAscending } : others)
    }

    private var selectedAll: [Item] { scopes.flatMap { store.selected($0) } }

    /// A tick; with Shift held, everything between the last tick and this one (as the list shows it).
    @State private var lastTicked: String?
    private func tick(_ item: Item) {
        let key = Store.key(item)
        if NSEvent.modifierFlags.contains(.shift), let last = lastTicked,
           let a = visible.firstIndex(where: { Store.key($0) == last }), let b = visible.firstIndex(where: { Store.key($0) == key }) {
            for i in visible[min(a, b)...max(a, b)] where i.deployable && !i.state.isActive && !i.selected {
                store.toggle(i.platform, i.id)
            }
        } else {
            store.toggle(item.platform, item.id)
        }
        lastTicked = key
    }

    var body: some View {
        VStack(spacing: 0) {
            header
            Divider()
            if let msg = store.busyMessage {
                HStack { ProgressView().controlSize(.small); Text(msg) }.padding(8)
            }
            if let v = store.newVersion {
                HStack {
                    Image(systemName: "arrow.down.circle.fill").foregroundStyle(.blue)
                    Text(L("Version \(v) is out.", "Version \(v) ist da.")).font(.callout)
                    Button(L("Download", "Herunterladen")) {
                        NSWorkspace.shared.open(URL(string: "https://github.com/Pschmetzer/deploy-center/releases/latest")!)
                    }.buttonStyle(.link)
                    Spacer()
                    Button { store.newVersion = nil } label: { Image(systemName: "xmark") }.buttonStyle(.borderless)
                        .help(L("Not now", "Nicht jetzt"))
                }
                .padding(.horizontal, 12).padding(.vertical, 6).background(Color.blue.opacity(0.06))
            }
            triggerBanner
            autoBanner
            waitingBar
            githubBanner
            if platform == .vercel, let c = store.costs { CostBar(costs: c) }
            content
            Divider()
            footer
        }
        .frame(minWidth: 680, minHeight: 540)
        .overlay(alignment: .bottom) {
            if let t = store.toast {
                Label(t.text, systemImage: t.ok ? "checkmark.circle.fill" : "xmark.octagon.fill")
                    .font(.callout.weight(.medium))
                    .padding(.horizontal, 14).padding(.vertical, 8)
                    .background(Capsule().fill(.regularMaterial))
                    .overlay(Capsule().stroke(t.ok ? Color.green.opacity(0.5) : Color.red.opacity(0.5)))
                    .padding(.bottom, 72)
                    .transition(.move(edge: .bottom).combined(with: .opacity))
                    .accessibilityAddTraits(.updatesFrequently)
            }
        }
        .animation(.easeOut(duration: 0.2), value: store.toast)
        .sheet(item: $logItem) { item in BuildLog(item: item) }
        .sheet(item: $detailItem) { item in ProjectDetail(item: item) { sha in store.deployOne(item, preview: false, sha: sha) } }
        .alert(L("Make the preview live?", "Vorschau live schalten?"),
               isPresented: Binding(get: { promoteItem != nil }, set: { if !$0 { promoteItem = nil } })) {
            Button(L("Cancel", "Abbrechen"), role: .cancel) { promoteItem = nil }
            Button(L("Make live", "Live schalten")) { if let i = promoteItem { store.promote(i) }; promoteItem = nil }
        } message: {
            Text(L("\(promoteItem?.name ?? "")'s finished preview becomes production. Nothing is built again.",
                   "Die fertige Vorschau von \(promoteItem?.name ?? "") wird live. Es wird nichts neu gebaut."))
        }
        .onChange(of: store.pendingDeployAll) { _, go in
            guard go else { return }
            store.pendingDeployAll = false
            showAll = true; onlyChanged = true
            Platform.allCases.forEach { store.selectChanged($0) }
            if !selectedAll.isEmpty { confirming = true }
        }
        .alert(L("Note", "Notiz"), isPresented: Binding(get: { noteItem != nil }, set: { if !$0 { noteItem = nil } })) {
            TextField(L("e.g. only after the release mail", "z. B. erst nach der Release-Mail"), text: $noteText)
            Button(L("Cancel", "Abbrechen"), role: .cancel) { noteItem = nil }
            Button(L("Save", "Speichern")) { if let i = noteItem { store.setNote(i, noteText) }; noteItem = nil }
        } message: {
            Text(L("Shown under \(noteItem?.name ?? ""). Kept on this Mac only.", "Steht unter \(noteItem?.name ?? ""). Bleibt nur auf diesem Mac."))
        }
        .onChange(of: store.pendingSearch) { _, name in
            guard let name else { return }
            showAll = true; onlyChanged = false; search = name; store.pendingSearch = nil
        }
        .alert(L("Nothing new to deploy", "Nichts Neues zu deployen"),
               isPresented: Binding(get: { unchangedItem != nil }, set: { if !$0 { unchangedItem = nil } })) {
            Button(L("Cancel", "Abbrechen"), role: .cancel) { unchangedItem = nil }
            Button(L("Build anyway", "Trotzdem bauen")) { if let i = unchangedItem { store.deployOne(i, preview: false) }; unchangedItem = nil }
        } message: {
            Text(L("\(unchangedItem?.name ?? "") is already on the newest commit. A build costs build minutes and changes nothing.",
                   "\(unchangedItem?.name ?? "") ist schon auf dem neuesten Stand. Ein Build kostet Build-Minuten und ändert nichts."))
        }
        .task { store.boot() }
        .alert(L("Deploy to production?", "Live deployen?"), isPresented: $confirming) {
            Button(L("Cancel", "Abbrechen"), role: .cancel) {}
            Button(L("Deploy", "Deployen")) { scopes.forEach { store.deploySelected($0) } }
        } message: {
            Text(selectedAll.map { i in
                    i.name + ((i.pendingCommits ?? 0) > 0 ? " – " + Row.waitingText(i) : "") }.joined(separator: "\n")
                 + "\n\n" + L("The newest commit on GitHub goes live.",
                               "Der neueste Stand von GitHub geht live.")
                 + unchangedNote)
        }
        .alert(L("Roll back production?", "Live zurückrollen?"),
               isPresented: Binding(get: { rollbackItem != nil }, set: { if !$0 { rollbackItem = nil } })) {
            Button(L("Cancel", "Abbrechen"), role: .cancel) { rollbackItem = nil }
            Button(L("Roll back", "Zurückrollen"), role: .destructive) { if let i = rollbackItem { store.rollback(i) }; rollbackItem = nil }
        } message: {
            Text(L("\(rollbackItem?.name ?? "") goes back to the deploy that was live before this one.",
                   "\(rollbackItem?.name ?? "") geht zurück auf den Stand, der davor live war."))
        }
        .alert(L("Turn off auto-deploy?", "Auto-Deploy ausschalten?"), isPresented: $confirmingOff) {
            Button(L("Cancel", "Abbrechen"), role: .cancel) {}
            Button(L("Turn off", "Ausschalten")) { Task { await store.turnOffAutoDeploy(platform) } }
        } message: {
            Text(store.autoOn(platform).map(\.name).joined(separator: "\n") + "\n\n"
                 + (platform == .vercel
                    ? L("The Git connection is removed (the repo is remembered here). A push will no longer build. Reconnect any time in the Vercel dashboard.",
                        "Die Git-Verbindung wird getrennt (das Repo merkt sich die App). Ein Push baut nichts mehr. Wieder verbinden geht jederzeit im Vercel-Dashboard.")
                    : L("Auto-deploy is set to Off. A push will no longer build.",
                        "Auto-Deploy wird auf Off gestellt. Ein Push baut nichts mehr.")))
        }
    }

    private var header: some View {
        HStack(spacing: 12) {
            Picker("", selection: tab) {
                Text(L("All", "Alle")).tag(Tab.all)
                Text("Vercel  \(store.items[.vercel]?.count ?? 0)").tag(Tab.vercel)
                Text("Render  \(store.items[.render]?.count ?? 0)").tag(Tab.render)
            }
            .pickerStyle(.segmented).labelsHidden().frame(width: 290)

            TextField(L("Search", "Suchen"), text: $search).textFieldStyle(.roundedBorder)
                .focused($searchFocused)
                .onExitCommand { search = ""; searchFocused = false }
                .background {
                    // Keyboard only: ⌘F to the search, ⌘1 and ⌘2 to the tabs.
                    Group {
                        Button("") { searchFocused = true }.keyboardShortcut("f")
                        Button("") { showAll = false; platform = .vercel }.keyboardShortcut("1")
                        Button("") { showAll = false; platform = .render }.keyboardShortcut("2")
                        Button("") { showAll = true }.keyboardShortcut("3")
                    }
                    .opacity(0).frame(width: 0, height: 0).accessibilityHidden(true)
                }

            Toggle(isOn: $onlyChanged) {
                Text(L("Changed only", "Nur mit Änderungen") + " (\(scopes.map { store.changedCount($0) }.reduce(0, +)))")
            }
            .toggleStyle(.button)
            .help(L("Only projects with a commit on GitHub that is not live yet",
                    "Nur Projekte mit einem Commit auf GitHub, der noch nicht live ist"))

            if let at = store.loadedAt[platform] {
                Text((store.fromCache.contains(platform) ? L("saved ", "gespeichert ") : L("as of ", "Stand "))
                     + at.formatted(date: .omitted, time: .shortened))
                    .font(.caption2).foregroundStyle(.secondary).fixedSize()
            }
            Button { Task { for p in scopes { await store.load(p) }; await store.loadExtras() } } label: {
                if store.loading.contains(platform) { ProgressView().controlSize(.small) }
                else { Image(systemName: "arrow.clockwise") }
            }
            .help(L("Reload (⌘R)", "Neu laden (⌘R)") + (store.loadedAt[platform].map {
                "\n" + L("As of ", "Stand ") + $0.formatted(date: .omitted, time: .shortened)
                    + (store.fromCache.contains(platform) ? L(" (saved copy)", " (gespeicherte Kopie)") : "") } ?? ""))
            .keyboardShortcut("r")
            .disabled(store.loading.contains(platform))
        }
        .padding(12)
    }

    @ViewBuilder private var triggerBanner: some View {
        if !store.triggers.isEmpty {
            HStack(alignment: .top, spacing: 10) {
                Image(systemName: "exclamationmark.triangle.fill").font(.title2).foregroundStyle(.red)
                VStack(alignment: .leading, spacing: 3) {
                    Text(L("Something else still starts builds", "Etwas anderes startet noch Builds")).font(.headline)
                    ForEach(store.triggers.prefix(6)) { tr in
                        Text("• \(Self.triggerName(tr.kind)): \(tr.where) – \(tr.detail)").font(.caption).textSelection(.enabled)
                    }
                    if store.triggers.count > 6 {
                        Text(L("and \(store.triggers.count - 6) more", "und \(store.triggers.count - 6) weitere")).font(.caption).foregroundStyle(.secondary)
                    }
                }
                Spacer()
            }
            .padding(12).background(Color.red.opacity(0.1))
        }
    }

    static func triggerName(_ k: String) -> String {
        switch k {
        case "workflow": return L("GitHub workflow deploys", "GitHub-Workflow deployt")
        case "vercel-build": return L("Vercel build from Git", "Vercel-Build von Git")
        case "render-build": return L("Render build from push", "Render-Build durch Push")
        case "render-blueprint": return L("Render Blueprint auto-sync", "Render-Blueprint Auto-Sync")
        default: return k
        }
    }

    /// Ticked projects that are already on their newest commit: building them costs and changes nothing.
    private var unchangedNote: String {
        let same = selectedAll.filter { !$0.hasNewCommits && $0.headSha != nil }.map(\.name)
        guard !same.isEmpty else { return "" }
        return "\n\n" + L("Already up to date, builds anyway: ", "Schon aktuell, baut trotzdem: ") + same.joined(separator: ", ")
    }

    /// Without a GitHub login, or with its hourly budget spent, the counts are missing. Say why.
    @ViewBuilder private var githubBanner: some View {
        if let d = store.doctor, d.githubCli, d.githubLoggedIn == false {
            HStack(spacing: 10) {
                Image(systemName: "person.crop.circle.badge.exclamationmark").foregroundStyle(.orange)
                Text(L("GitHub CLI is not logged in, so the waiting commits and PRs cannot be counted. In Terminal: gh auth login",
                       "Die GitHub-CLI ist nicht angemeldet, darum fehlen die Zahlen wartender Commits und PRs. Im Terminal: gh auth login"))
                    .font(.caption).textSelection(.enabled)
                Spacer()
            }
            .padding(.horizontal, 12).padding(.vertical, 6).background(Color.orange.opacity(0.08))
        } else if let b = store.githubBudget, b.remaining < 300 {
            HStack(spacing: 10) {
                Image(systemName: "gauge.with.dots.needle.0percent").foregroundStyle(.orange)
                Text(L("GitHub's hourly budget is nearly spent (\(b.remaining) of \(b.limit) left). Counts pause until ",
                       "GitHubs Stunden-Kontingent ist fast aufgebraucht (\(b.remaining) von \(b.limit) übrig). Die Zahlen pausieren bis ")
                     + Date(timeIntervalSince1970: b.reset).formatted(date: .omitted, time: .shortened) + ".")
                    .font(.caption)
                Spacer()
            }
            .padding(.horizontal, 12).padding(.vertical, 6).background(Color.orange.opacity(0.08))
        }
    }

    /// What GitHub has that is not live, over Vercel and Render together.
    @ViewBuilder private var waitingBar: some View {
        let w = store.waiting
        if w.projects > 0 || w.openPRs > 0 {
            HStack(spacing: 10) {
                Image(systemName: "shippingbox.fill").font(.title2).foregroundStyle(.blue)
                VStack(alignment: .leading, spacing: 2) {
                    if w.projects > 0 {
                        Text(L("\(w.prs) \(w.prs == 1 ? "PR" : "PRs") waiting to deploy",
                               "\(w.prs) \(w.prs == 1 ? "PR wartet" : "PRs warten") auf Deploy"))
                            .font(.headline).accessibilityAddTraits(.isHeader)
                        Text(L("\(w.commits) \(w.commits == 1 ? "commit" : "commits") in \(w.projects) \(w.projects == 1 ? "project" : "projects"), merged on GitHub and not live",
                               "\(w.commits) \(w.commits == 1 ? "Commit" : "Commits") in \(w.projects) \(w.projects == 1 ? "Projekt" : "Projekten"), auf GitHub gemergt und nicht live"))
                            .font(.caption).foregroundStyle(.secondary)
                    } else {
                        Text(L("Everything merged is live", "Alles Gemergte ist live")).font(.headline)
                    }
                    if w.openPRs > 0 {
                        Text(L("\(w.openPRs) more \(w.openPRs == 1 ? "PR is" : "PRs are") still open (not merged)",
                               "\(w.openPRs) weitere \(w.openPRs == 1 ? "PR ist" : "PRs sind") noch offen (nicht gemergt)"))
                            .font(.caption).foregroundStyle(.secondary)
                    }
                }
                Spacer()
                if store.history.count >= 2 {
                    // PRs waiting per day: does the daily deploy keep up?
                    let days = store.history.keys.sorted().suffix(14)
                    Chart(Array(days), id: \.self) { d in
                        LineMark(x: .value("Day", d), y: .value("PRs", store.history[d] ?? 0))
                        AreaMark(x: .value("Day", d), y: .value("PRs", store.history[d] ?? 0)).foregroundStyle(Color.blue.opacity(0.15))
                    }
                    .chartXAxis(.hidden).chartYAxis(.hidden)
                    .frame(width: 90, height: 30)
                    .help(L("PRs waiting per day, last 14 days", "Wartende PRs pro Tag, letzte 14 Tage"))
                    .accessibilityLabel(L("PRs waiting per day", "Wartende PRs pro Tag"))
                }
                if w.projects > 0 {
                    Button(L("Show them", "Anzeigen")) { onlyChanged = true; showAll = true }
                }
            }
            .padding(12).background(Color.blue.opacity(0.08))
        }
    }

    @ViewBuilder private var autoBanner: some View {
        let on = store.autoOn(platform)
        if !on.isEmpty {
            HStack(spacing: 10) {
                Image(systemName: "dollarsign.circle.fill").font(.title2).foregroundStyle(.orange)
                VStack(alignment: .leading, spacing: 2) {
                    Text(L("\(on.count) projects build on every push", "\(on.count) Projekte bauen bei jedem Push"))
                        .font(.headline)
                    Text(L("Every push costs build minutes. Turn it off and deploy here when you want.",
                           "Jeder Push kostet Build-Minuten. Ausschalten und hier deployen, wann du willst."))
                        .font(.caption).foregroundStyle(.secondary)
                }
                Spacer()
                Button(L("Turn off auto-deploy", "Auto-Deploy ausschalten")) { confirmingOff = true }
                    .buttonStyle(.borderedProminent).tint(.orange)
            }
            .padding(12)
            .background(Color.orange.opacity(0.1))
        }
    }

    @ViewBuilder private var content: some View {
        if let err = store.doctorError {
            Setup(title: L("Something is missing", "Etwas fehlt"), text: err, commands: []) { Task { await store.start() } }
        } else if store.doctor == nil && (store.items[platform] ?? []).isEmpty {
            ProgressView(L("Checking access …", "Prüfe Zugang …")).frame(maxWidth: .infinity, maxHeight: .infinity)
        } else if let d = store.doctor, !d.jq {
            Setup(title: L("jq is missing", "jq fehlt"),
                  text: L("Deploy Center needs the small tool jq. Install it with Homebrew:", "Deploy Center braucht das kleine Werkzeug jq. Installieren mit Homebrew:"),
                  commands: ["brew install jq"]) { Task { await store.start() } }
        } else if platform == .vercel, let d = store.doctor, d.vercelCli, !d.vercelApi {
            Setup(title: L("Update the Vercel CLI", "Vercel-CLI aktualisieren"),
                  text: L("Your Vercel CLI is too old (it has no `vercel api`).", "Deine Vercel-CLI ist zu alt (ihr fehlt `vercel api`)."),
                  commands: ["npm i -g vercel@latest"]) { Task { await store.start() } }
        } else if platform == .vercel, let d = store.doctor, !d.vercelLoggedIn {
            Setup(title: L("Connect Vercel", "Vercel verbinden"),
                  text: d.vercelCli
                    ? L("Log in once in Terminal. The app uses that login.", "Einmal im Terminal anmelden. Die App nutzt diese Anmeldung.")
                    : L("Install the Vercel CLI, then log in once in Terminal.", "Vercel-CLI installieren und einmal im Terminal anmelden."),
                  commands: d.vercelCli ? ["vercel login"] : ["npm i -g vercel", "vercel login"]) {
                Task { await store.start() }
            }
        } else if platform == .render, let d = store.doctor, !d.renderKey {
            RenderKeySetup(store: store)
        } else if let err = store.loadError[platform] {
            VStack(spacing: 10) {
                Image(systemName: "exclamationmark.triangle").font(.largeTitle).foregroundStyle(.orange)
                Text(L("Could not load \(platform.rawValue)", "\(platform.rawValue) konnte nicht geladen werden")).font(.headline)
                Text(err).font(.callout).foregroundStyle(.secondary).multilineTextAlignment(.center).textSelection(.enabled)
                Button(L("Try again", "Nochmal versuchen")) { Task { await store.load(platform) } }
            }
            .padding(30).frame(maxWidth: .infinity, maxHeight: .infinity)
        } else if store.loading.contains(platform) && (store.items[platform] ?? []).isEmpty {
            ProgressView(L("Loading \(platform.rawValue) …", "Lade \(platform.rawValue) …")).frame(maxWidth: .infinity, maxHeight: .infinity)
        } else if visible.isEmpty && (onlyChanged || !search.isEmpty) {
            VStack(spacing: 8) {
                Image(systemName: onlyChanged ? "checkmark.seal.fill" : "magnifyingglass").font(.system(size: 34))
                    .foregroundStyle(onlyChanged ? .green : .secondary)
                Text(onlyChanged ? L("Everything is live", "Alles ist live") : L("Nothing matches “\(search)”", "Nichts passt zu „\(search)“"))
                    .font(.headline)
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity)
        } else {
            List(visible) { item in
                Row(item: item, cost: item.platform == .vercel ? store.buildCost(item.name) : nil,
                    perBuild: item.platform == .vercel ? store.costs?.perBuild(item.name) : nil,
                    pinned: store.isPinned(item), note: store.note(item),
                    showDetails: item.repo == nil ? nil : { detailItem = item },
                    showLog: { logItem = item },
                    onCancel: { store.cancel(item) },
                    onRetry: item.deployable ? { store.deployOne(item, preview: false) } : nil,
                    onPromote: item.platform == .vercel ? { promoteItem = item } : nil,
                    usualMinutes: store.usualMinutes(item), search: search) { tick(item) }
                    .contextMenu {
                        if item.repo != nil {
                            Button(L("Details …", "Details …")) { detailItem = item }
                            Divider()
                        }
                        if item.deployable && !item.state.isActive {
                            Button(L("Deploy to production", "Live deployen")) {
                                if item.hasNewCommits || item.headSha == nil { store.deployOne(item, preview: false) }
                                else { unchangedItem = item }
                            }
                            if item.platform == .render {
                                Button(L("Deploy with a cleared build cache", "Mit geleertem Build-Cache deployen")) { store.deployOne(item, preview: false, clearCache: true) }
                            }
                            if item.platform == .vercel {
                                Button(L("Preview deploy (not live)", "Vorschau-Deploy (nicht live)")) { store.deployOne(item, preview: true) }
                            }
                            Divider()
                            Button(L("Roll back production …", "Live zurückrollen …")) { rollbackItem = item }
                        }
                        if let l = item.link, let u = URL(string: l) {
                            Button(L("Open site", "Seite öffnen")) { NSWorkspace.shared.open(u) }
                        }
                        Button(L("Last build log …", "Letztes Build-Log …")) { logItem = item }
                        if let u = item.compareURL {
                            Button(L("Show the waiting commits on GitHub", "Wartende Commits auf GitHub ansehen")) { NSWorkspace.shared.open(u) }
                        }
                        if let u = item.dashboardURL {
                            Button(L("Open in the Render dashboard", "Im Render-Dashboard öffnen")) { NSWorkspace.shared.open(u) }
                        }
                        Divider()
                        Button(store.isPinned(item) ? L("Unpin", "Nicht mehr anheften") : L("Pin to the top", "Oben anheften")) { store.togglePin(item) }
                        Button(store.note(item) == nil ? L("Add a note …", "Notiz hinzufügen …") : L("Edit the note …", "Notiz ändern …")) {
                            noteText = store.note(item) ?? ""; noteItem = item
                        }
                        Button(L("Hide", "Ausblenden")) { store.toggleHidden(item) }
                    }
            }
            .listStyle(.inset)
        }
    }

    private var footer: some View {
        let count = selectedAll.count
        let changedHere = scopes.map { store.changedCount($0) }.reduce(0, +)
        return HStack {
            Text(count == 0 ? L("Tick the projects that should go live", "Projekte anhaken, die live gehen sollen")
                            : L("\(count) selected", "\(count) ausgewählt"))
                .foregroundStyle(.secondary)
            Spacer()
            if count > 0 {
                Button(L("Clear", "Auswahl leeren")) { scopes.forEach { store.clearSelection($0) } }
            } else if changedHere > 0 {
                Button(L("Select all changed", "Alle mit Änderungen anhaken")) { scopes.forEach { store.selectChanged($0) } }
                    // The saved copy may be hours old; tick from what is true now. If reading it
                    // again failed, the error is on screen and the copy is all there is.
                    .disabled(scopes.contains { store.fromCache.contains($0) && store.loadError[$0] == nil })
            }
            if !showAll && platform == .vercel {
                Button(L("Preview", "Vorschau")) { store.deploySelected(platform, preview: true) }
                    .disabled(count == 0)
                    .help(L("Build a preview deployment. Production stays as it is.", "Baut einen Vorschau-Deploy. Live bleibt unverändert."))
            }
            Button { confirming = true } label: {
                Label(count > 1 ? L("Deploy \(count)", "\(count) deployen") : L("Deploy", "Deployen"),
                      systemImage: "paperplane.fill").padding(.horizontal, 6)
            }
            .buttonStyle(.borderedProminent).controlSize(.large)
            .keyboardShortcut(.return, modifiers: .command)
            .disabled(count == 0)
        }
        .padding(12)
    }
}

struct CostBar: View {
    let costs: Costs
    private var last7: [Costs.Day] { Array(costs.days.suffix(7)) }
    private var week: Double { last7.map(\.build).reduce(0, +) }
    private var average: Double { last7.isEmpty ? 0 : week / Double(last7.count) }

    /// Average build cost per day before auto-deploy was turned off and since, whole days only.
    private var saving: (before: Double, after: Double)? {
        guard let off = costs.offDay else { return nil }
        let before = costs.days.filter { $0.day < off }, after = costs.days.filter { $0.day > off }
        guard !before.isEmpty, !after.isEmpty else { return nil }
        return (before.map(\.build).reduce(0, +) / Double(before.count), after.map(\.build).reduce(0, +) / Double(after.count))
    }

    var body: some View {
        HStack(spacing: 16) {
            VStack(alignment: .leading, spacing: 2) {
                Text(L("Vercel builds, last 7 days", "Vercel-Builds, letzte 7 Tage")).font(.caption).foregroundStyle(.secondary)
                Text(week, format: .currency(code: "USD")).font(.title3.weight(.semibold).monospacedDigit())
                Text(L("≈ ", "≈ ") + (average * 30).formatted(.currency(code: "USD")) + L(" a month at this pace", " im Monat bei diesem Tempo"))
                    .font(.caption2).foregroundStyle(.secondary)
                if let s = saving {
                    Text(L("per day: ", "pro Tag: ") + s.before.formatted(.currency(code: "USD")) + L(" before, ", " vorher, ")
                         + s.after.formatted(.currency(code: "USD")) + L(" since", " seitdem"))
                        .font(.caption2.weight(.medium)).foregroundStyle(s.after < s.before ? .green : .orange)
                } else if let off = costs.offDay {
                    Text(L("Auto-deploy off since \(off); the saving shows after a full day", "Auto-Deploy aus seit \(off); die Ersparnis zeigt sich nach einem ganzen Tag"))
                        .font(.caption2).foregroundStyle(.secondary)
                }
            }
            Chart(costs.days) { d in
                // A day over twice the average stands out.
                BarMark(x: .value("Day", String(d.day.suffix(5))), y: .value("USD", d.build))
                    .foregroundStyle(d.build > 2 * average && average > 0 ? Color.orange.gradient : Color.accentColor.gradient)
                if let off = costs.offDay, d.day == off {
                    RuleMark(x: .value("Day", String(d.day.suffix(5)))).foregroundStyle(.green).lineStyle(StrokeStyle(lineWidth: 1, dash: [3]))
                }
            }
            .chartYAxis { AxisMarks(position: .leading) { _ in AxisValueLabel() } }
            .chartXAxis { AxisMarks(values: .automatic(desiredCount: 7)) }
            .frame(height: 64)
            .accessibilityLabel(L("Build costs per day", "Build-Kosten pro Tag"))
        }
        .padding(.horizontal, 12).padding(.vertical, 8)
        .background(Color.secondary.opacity(0.06))
        .help(L("Build costs from Vercel's billing data; orange: over twice the average; green line: auto-deploy turned off. Total incl. other usage: ",
                "Build-Kosten aus Vercels Abrechnung; orange: mehr als doppelt so viel wie im Schnitt; grüne Linie: Auto-Deploy ausgeschaltet. Gesamt inkl. sonstiger Nutzung: ")
              + last7.map(\.total).reduce(0, +).formatted(.currency(code: "USD")))
    }
}

struct Setup: View {
    let title: String
    let text: String
    let commands: [String]
    let retry: () -> Void

    var body: some View {
        VStack(spacing: 14) {
            Image(systemName: "link.circle").font(.system(size: 40)).foregroundStyle(.secondary)
            Text(title).font(.title2.weight(.semibold))
            Text(text).foregroundStyle(.secondary).multilineTextAlignment(.center)
            ForEach(commands, id: \.self) { c in
                HStack {
                    Text(c).font(.system(.body, design: .monospaced)).textSelection(.enabled)
                    Button { NSPasteboard.general.clearContents(); NSPasteboard.general.setString(c, forType: .string) }
                        label: { Image(systemName: "doc.on.doc") }.buttonStyle(.borderless).help(L("Copy", "Kopieren"))
                }
                .padding(8).background(RoundedRectangle(cornerRadius: 6).fill(Color.secondary.opacity(0.12)))
            }
            Button(L("Done – check again", "Fertig – nochmal prüfen"), action: retry).buttonStyle(.borderedProminent)
        }
        .padding(30).frame(maxWidth: 460).frame(maxWidth: .infinity, maxHeight: .infinity)
    }
}

struct RenderKeySetup: View {
    @ObservedObject var store: Store
    @State private var key = ""
    @State private var error: String?
    @State private var saving = false

    var body: some View {
        VStack(spacing: 14) {
            Image(systemName: "key.fill").font(.system(size: 36)).foregroundStyle(.secondary)
            Text(L("Connect Render", "Render verbinden")).font(.title2.weight(.semibold))
            Text(L("Create an API key at dashboard.render.com → Account Settings → API Keys and paste it here. It is stored in your macOS keychain, nowhere else.",
                   "Erstelle einen API-Key unter dashboard.render.com → Account Settings → API Keys und füge ihn hier ein. Er wird nur im macOS-Schlüsselbund gespeichert."))
                .foregroundStyle(.secondary).multilineTextAlignment(.center)
            SecureField("rnd_…", text: $key).textFieldStyle(.roundedBorder).frame(width: 320)
            if let error { Text(error).font(.caption).foregroundStyle(.red).multilineTextAlignment(.center) }
            HStack {
                Button(L("Open Render", "Render öffnen")) {
                    NSWorkspace.shared.open(URL(string: "https://dashboard.render.com/u/settings#api-keys")!)
                }
                Button(saving ? L("Saving …", "Speichere …") : L("Save key", "Key speichern")) {
                    saving = true
                    Task { error = await store.saveRenderKey(key); saving = false; if error == nil { key = "" } }
                }
                .buttonStyle(.borderedProminent).disabled(key.count < 10 || saving)
            }
        }
        .padding(30).frame(maxWidth: 480).frame(maxWidth: .infinity, maxHeight: .infinity)
    }
}

struct Row: View {
    let item: Item
    var cost: Double? = nil
    var perBuild: Double? = nil
    var pinned = false
    var note: String? = nil
    var showDetails: (() -> Void)? = nil
    var showLog: (() -> Void)? = nil
    var onCancel: (() -> Void)? = nil
    var onRetry: (() -> Void)? = nil
    var onPromote: (() -> Void)? = nil
    var usualMinutes: Int? = nil
    var search = ""
    let toggle: () -> Void

    /// The part of the name that matches the search, marked.
    private func highlighted(_ text: String) -> AttributedString {
        var a = AttributedString(text)
        guard !search.isEmpty, let r = a.range(of: search, options: .caseInsensitive) else { return a }
        a[r].backgroundColor = .yellow.opacity(0.35)
        return a
    }

    var body: some View {
        HStack(spacing: 12) {
            Button(action: toggle) {
                Image(systemName: item.selected ? "checkmark.circle.fill" : "circle")
                    .font(.title3)
                    .foregroundStyle(item.selected ? Color.accentColor : .secondary)
                    .opacity(item.deployable ? 1 : 0.3)
            }
            .buttonStyle(.plain)
            .disabled(!item.deployable || item.state.isActive)
            .accessibilityLabel(item.name)
            .accessibilityValue(item.selected ? L("selected", "ausgewählt") : L("not selected", "nicht ausgewählt"))

            Logo(domain: item.domain, name: item.name)

            VStack(alignment: .leading, spacing: 3) {
                HStack(spacing: 6) {
                    if pinned { Image(systemName: "pin.fill").font(.caption2).foregroundStyle(.secondary) }
                    Text(highlighted(item.name)).font(.body.weight(.medium))
                    if let d = item.domain, let u = item.link.flatMap(URL.init(string:)) {
                        Button { NSWorkspace.shared.open(u) } label: { Text(d).font(.caption) }
                            .buttonStyle(.link).help(L("Open site", "Seite öffnen"))
                    }
                }
                Text(item.detail).font(.caption).foregroundStyle(.secondary)
                if let note { Text(note).font(.caption.italic()).foregroundStyle(.orange) }
                HStack(spacing: 8) {
                    lastDeploy
                    if let cost, cost >= 0.01 {
                        Text(L("builds 7 days: ", "Builds 7 Tage: ") + cost.formatted(.currency(code: "USD")))
                            .font(.caption2).foregroundStyle(cost >= 5 ? .orange : .secondary)
                            .help(perBuild.map { L("About ", "Etwa ") + $0.formatted(.currency(code: "USD")) + L(" per build", " pro Build") } ?? "")
                    }
                    if item.hasNewCommits {
                        Label(Self.waitingText(item), systemImage: "arrow.up.circle.fill")
                            .font(.caption2.weight(.semibold)).foregroundStyle(.blue)
                            .help(item.headMsg.map { L("Newest commit: ", "Neuester Commit: ") + $0
                                + (item.headAt.map { " (\(Self.ago($0)))" } ?? "") } ?? "")
                    }
                    if item.hasNewCommits, let since = item.oldestPendingAt {
                        Text(L("oldest waiting commit ", "ältester wartender Commit ") + Self.ago(since))
                            .font(.caption2).foregroundStyle(Date().timeIntervalSince(since) > 3 * 86400 ? .orange : .secondary)
                            .help(L("The oldest commit that is not live", "Der älteste Commit, der noch nicht live ist"))
                    }
                    if let o = item.openPRs, o > 0 {
                        Text(Self.openText(item, o))
                            .font(.caption2).foregroundStyle(.secondary)
                            .help(L("Pull requests on the repo that are not merged yet", "Pull Requests im Repo, die noch nicht gemergt sind"))
                    }
                }
            }

            Spacer()

            if let note = item.note, item.state == .idle {
                Text(note)
                    .font(.caption)
                    .padding(.horizontal, 7).padding(.vertical, 2)
                    .background(Capsule().fill(item.auto ? Color.orange.opacity(0.2) : Color.secondary.opacity(0.15)))
            }
            status
            if let showDetails {
                Button(action: showDetails) { Image(systemName: "info.circle") }
                    .buttonStyle(.borderless)
                    .help(L("Details: waiting commits, files, CI, open PRs", "Details: wartende Commits, Dateien, CI, offene PRs"))
                    .accessibilityLabel(L("Details for \(item.name)", "Details zu \(item.name)"))
            }
        }
        .padding(.vertical, 4)
        .contentShape(Rectangle())
        .opacity(item.deployable ? 1 : 0.55)
        .onTapGesture { if !item.state.isActive { toggle() } }
    }

    static func waitingText(_ i: Item) -> String {
        if i.rewritten { return L("New changes (branch was rewritten)", "Neue Änderungen (Branch wurde umgeschrieben)") }
        guard let c = i.pendingCommits, c > 0 else { return L("New changes", "Neue Änderungen") }
        let prs = i.pendingPRs ?? 0
        if i.pendingPartial {
            return L("\(c) commits, at least \(prs) PRs waiting", "\(c) Commits, mindestens \(prs) PRs warten")
        }
        let commits = L("\(c) \(c == 1 ? "commit" : "commits")", "\(c) \(c == 1 ? "Commit" : "Commits")")
        return prs > 0 ? commits + " · " + L("\(prs) \(prs == 1 ? "PR" : "PRs") waiting", "\(prs) \(prs == 1 ? "PR wartet" : "PRs warten")")
                       : commits + L(" waiting", " warten")
    }

    static func openText(_ i: Item, _ o: Int) -> String {
        var parts: [String] = []
        if let d = i.openDrafts, d > 0 { parts.append(L("\(d) \(d == 1 ? "draft" : "drafts")", "\(d) \(d == 1 ? "Entwurf" : "Entwürfe")")) }
        if let b = i.openBots, b > 0 { parts.append(L("\(b) \(b == 1 ? "bot" : "bots")", "\(b) \(b == 1 ? "Bot" : "Bots")")) }
        let base = L("\(o) open \(o == 1 ? "PR" : "PRs")", "\(o) \(o == 1 ? "offener PR" : "offene PRs")")
        return parts.isEmpty ? base : base + " (" + parts.joined(separator: ", ") + ")"
    }

    static func ago(_ d: Date) -> String {
        let f = RelativeDateTimeFormatter()
        f.locale = Locale(identifier: isGerman ? "de_DE" : "en_US")
        f.unitsStyle = .full
        return f.localizedString(for: d, relativeTo: Date())
    }

    @ViewBuilder private var lastDeploy: some View {
        if let at = item.lastAt {
            let s = (item.lastState ?? "").lowercased()
            let ok = ["ready", "live", "succeeded"].contains(s)
            let failed = s.contains("fail") || s == "error" || s == "canceled"
            HStack(spacing: 4) {
                Circle().fill(ok ? Color.green : (failed ? Color.red : Color.orange)).frame(width: 7, height: 7)
                Text(L("Last deploy ", "Zuletzt deployt ") + Self.ago(at) + (ok ? "" : " · \(s)"))
                    .font(.caption2).foregroundStyle(.secondary)
            }
            .help(at.formatted(date: .complete, time: .shortened) + (item.lastMsg.map { "\n" + L("Live: ", "Live: ") + $0 } ?? ""))
        } else {
            Text(L("Never deployed", "Noch nie deployt")).font(.caption2).foregroundStyle(.secondary)
        }
    }

    @ViewBuilder private var cancelButton: some View {
        if let onCancel {
            Button(action: onCancel) { Image(systemName: "stop.circle") }
                .buttonStyle(.borderless).help(L("Cancel", "Abbrechen"))
        }
    }

    @ViewBuilder private var status: some View {
        switch item.state {
        case .idle:
            EmptyView()
        case .queued:
            HStack(spacing: 6) {
                Image(systemName: "hourglass").foregroundStyle(.secondary)
                Text(L("queued", "in der Schlange")).font(.caption)
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
                    }
                } else { Text(s).font(.caption) }
                cancelButton
            }
        case .done(let url):
            HStack(spacing: 6) {
                Label("Live", systemImage: "checkmark.circle.fill").foregroundStyle(.green).font(.caption.weight(.semibold))
                if let url, let u = URL(string: url) {
                    Button { NSWorkspace.shared.open(u) } label: { Image(systemName: "arrow.up.right.square") }
                        .buttonStyle(.borderless).help(url)
                    if item.previewId != nil {
                        Button { NSPasteboard.general.clearContents(); NSPasteboard.general.setString(url, forType: .string) }
                            label: { Image(systemName: "link") }
                            .buttonStyle(.borderless).help(L("Copy the preview link", "Vorschau-Link kopieren"))
                    }
                }
                if item.previewId != nil, let onPromote {
                    Button(L("Make live", "Live schalten"), action: onPromote).controlSize(.small)
                        .help(L("This preview goes live as it is, without another build", "Diese Vorschau geht so live, wie sie ist, ohne neuen Build"))
                }
            }
        case .skipped(let msg):
            Label(L("Skipped", "Übersprungen"), systemImage: "forward.circle.fill")
                .foregroundStyle(.secondary).font(.caption.weight(.semibold))
                .help(msg)
        case .failed(let msg):
            HStack(spacing: 4) {
                Label(L("Failed", "Fehler"), systemImage: "xmark.octagon.fill")
                    .foregroundStyle(.red).font(.caption.weight(.semibold))
                    .help(msg)
                Button { NSPasteboard.general.clearContents(); NSPasteboard.general.setString("\(item.name): \(msg)", forType: .string) }
                    label: { Image(systemName: "doc.on.doc") }
                    .buttonStyle(.borderless).help(L("Copy the error", "Fehler kopieren"))
                if let showLog {
                    Button(action: showLog) { Image(systemName: "text.alignleft") }
                        .buttonStyle(.borderless).help(L("Build log", "Build-Log"))
                }
                if let onRetry {
                    Button(action: onRetry) { Image(systemName: "arrow.clockwise") }
                        .buttonStyle(.borderless).help(L("Try again", "Erneut versuchen"))
                }
            }
        }
    }
}

// MARK: - Build log

struct BuildLog: View {
    let item: Item
    @Environment(\.dismiss) private var dismiss
    @State private var text: String?
    @State private var error: String?

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            HStack {
                Text(L("Build log: ", "Build-Log: ") + item.name).font(.headline)
                Spacer()
                if let text {
                    Button(L("Copy", "Kopieren")) { NSPasteboard.general.clearContents(); NSPasteboard.general.setString(text, forType: .string) }
                }
                Button(L("Close", "Schließen")) { dismiss() }.keyboardShortcut(.cancelAction)
            }
            .padding(12)
            Divider()
            if let error { Text(error).foregroundStyle(.secondary).padding(16).textSelection(.enabled) }
            else if let text {
                ScrollView { Text(text).font(.system(.caption, design: .monospaced)).textSelection(.enabled)
                    .frame(maxWidth: .infinity, alignment: .leading).padding(12) }
                    .defaultScrollAnchor(.bottom)
            } else { ProgressView().frame(maxWidth: .infinity, maxHeight: .infinity) }
        }
        .frame(width: 760, height: 520)
        .task {
            do {
                let data = try await Tool.run(["logs", item.id, "200"])
                text = String(data: data, encoding: .utf8).map { $0.isEmpty ? L("(empty)", "(leer)") : $0 }
            } catch { self.error = error.localizedDescription }
        }
    }
}

// MARK: - One project in detail

struct ProjectDetail: View {
    let item: Item
    var deployCommit: ((String) -> Void)? = nil
    @Environment(\.dismiss) private var dismiss
    @State private var commitToDeploy: Details.Commit?
    @State private var details: Details?
    @State private var error: String?

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            HStack(spacing: 12) {
                Logo(domain: item.domain, name: item.name)
                VStack(alignment: .leading, spacing: 2) {
                    Text(item.name).font(.title3.weight(.semibold))
                    Text(item.detail).font(.caption).foregroundStyle(.secondary)
                }
                Spacer()
                Button(L("Close", "Schließen")) { dismiss() }.keyboardShortcut(.cancelAction)
            }
            .padding(16)
            Divider()
            if let error {
                Text(error).foregroundStyle(.secondary).padding(20).textSelection(.enabled)
            } else if let d = details {
                ScrollView { content(d).padding(16) }
            } else {
                ProgressView(L("Asking GitHub …", "Frage GitHub …")).frame(maxWidth: .infinity, maxHeight: .infinity)
            }
        }
        .frame(width: 620, height: 560)
        .alert(L("Deploy this commit?", "Diesen Commit deployen?"),
               isPresented: Binding(get: { commitToDeploy != nil }, set: { if !$0 { commitToDeploy = nil } })) {
            Button(L("Cancel", "Abbrechen"), role: .cancel) { commitToDeploy = nil }
            Button(L("Deploy", "Deployen")) {
                if let c = commitToDeploy, let full = c.full { deployCommit?(full); dismiss() }
                commitToDeploy = nil
            }
        } message: {
            Text(L("\(item.name) goes live at \(commitToDeploy?.sha ?? "") – \(commitToDeploy?.msg ?? ""). Newer commits stay waiting.",
                   "\(item.name) geht mit \(commitToDeploy?.sha ?? "") live – \(commitToDeploy?.msg ?? ""). Neuere Commits warten weiter."))
        }
        .task {
            guard let repo = item.repo else { return }
            do {
                details = try await Tool.json(["details", repo, item.lastSha ?? "", item.ref ?? "main"], as: Details.self)
            } catch { self.error = error.localizedDescription }
        }
    }

    @ViewBuilder private func content(_ d: Details) -> some View {
        VStack(alignment: .leading, spacing: 18) {
            // What is live, and what the branch would bring.
            if let live = item.lastMsg {
                labelled(L("Live now", "Jetzt live"), live + (item.lastSha.map { "  (\($0.prefix(7)))" } ?? ""))
            }
            if let checks = d.checks, checks.total > 0 {
                HStack(spacing: 6) {
                    Image(systemName: checks.failed > 0 ? "xmark.octagon.fill" : (checks.running > 0 ? "clock.fill" : "checkmark.seal.fill"))
                        .foregroundStyle(checks.failed > 0 ? .red : (checks.running > 0 ? .orange : .green))
                    Text(checks.failed > 0
                         ? L("CI on the branch: \(checks.failed) of \(checks.total) checks failed", "CI auf dem Branch: \(checks.failed) von \(checks.total) Checks rot")
                         : checks.running > 0
                           ? L("CI on the branch: \(checks.running) checks still running", "CI auf dem Branch: \(checks.running) Checks laufen noch")
                           : L("CI on the branch: all \(checks.total) checks passed", "CI auf dem Branch: alle \(checks.total) Checks grün"))
                        .font(.callout)
                }
            }
            if !d.commits.isEmpty {
                VStack(alignment: .leading, spacing: 6) {
                    HStack {
                        Text(L("Waiting to go live", "Wartet darauf, live zu gehen")).font(.headline)
                        if d.onlyBots {
                            Text(L("dependency updates only", "nur Abhängigkeits-Updates"))
                                .font(.caption).padding(.horizontal, 6).padding(.vertical, 1)
                                .background(Capsule().fill(Color.secondary.opacity(0.15)))
                        }
                        Spacer()
                        if let u = d.compareUrl.flatMap(URL.init(string:)) {
                            Button(L("On GitHub", "Auf GitHub")) { NSWorkspace.shared.open(u) }.buttonStyle(.link)
                        }
                    }
                    Text(L("\(d.files) files, +\(d.additions) −\(d.deletions) lines", "\(d.files) Dateien, +\(d.additions) −\(d.deletions) Zeilen"))
                        .font(.caption).foregroundStyle(.secondary)
                    if !d.risky.isEmpty {
                        HStack(alignment: .top, spacing: 6) {
                            Image(systemName: "exclamationmark.triangle.fill").foregroundStyle(.orange)
                            Text(L("Worth a look before it goes live: ", "Vor dem Live-Gang ansehen: ") + d.risky.prefix(8).joined(separator: ", ")
                                 + (d.risky.count > 8 ? " …" : ""))
                                .font(.caption).textSelection(.enabled)
                        }
                    }
                    ForEach(d.commits) { c in
                        HStack(alignment: .firstTextBaseline, spacing: 8) {
                            if let pr = c.pr, let repo = item.repo, let u = URL(string: "https://github.com/\(repo)/pull/\(pr)") {
                                Button("#\(pr)") { NSWorkspace.shared.open(u) }.buttonStyle(.link).font(.caption.monospacedDigit())
                            } else if let u = c.url.flatMap(URL.init(string:)) {
                                Button(c.sha) { NSWorkspace.shared.open(u) }.buttonStyle(.link).font(.caption.monospaced())
                            }
                            Text(c.msg).font(.callout).lineLimit(2)
                            Spacer(minLength: 8)
                            Text((c.author ?? "") + " · " + Row.ago(Date(timeIntervalSince1970: c.at)))
                                .font(.caption2).foregroundStyle(.secondary).lineLimit(1)
                            if deployCommit != nil, item.deployable, c.full != nil {
                                Button { commitToDeploy = c } label: { Image(systemName: "paperplane") }
                                    .buttonStyle(.borderless).help(L("Deploy up to this commit", "Bis zu diesem Commit deployen"))
                            }
                        }
                    }
                }
            } else if item.hasNewCommits {
                Text(L("GitHub could not compare what is live with the branch (rewritten branch, or the live commit is unknown).",
                       "GitHub konnte Live-Stand und Branch nicht vergleichen (Branch umgeschrieben oder Live-Commit unbekannt)."))
                    .font(.callout).foregroundStyle(.secondary)
            } else {
                Label(L("Everything merged is live", "Alles Gemergte ist live"), systemImage: "checkmark.circle.fill").foregroundStyle(.green)
            }
            if item.platform == .vercel {
                VStack(alignment: .leading, spacing: 4) {
                    Text(L("Fewer builds in a monorepo", "Weniger Builds im Monorepo")).font(.headline)
                    Text(L("In Vercel's project settings, Git → Ignored Build Step, this command skips a build when nothing in the project's folder changed:",
                           "In Vercels Projekteinstellungen unter Git → Ignored Build Step überspringt dieser Befehl einen Build, wenn sich im Ordner des Projekts nichts geändert hat:"))
                        .font(.caption).foregroundStyle(.secondary)
                    HStack {
                        Text("git diff --quiet HEAD^ HEAD -- .").font(.system(.caption, design: .monospaced)).textSelection(.enabled)
                        Button { NSPasteboard.general.clearContents(); NSPasteboard.general.setString("git diff --quiet HEAD^ HEAD -- .", forType: .string) }
                            label: { Image(systemName: "doc.on.doc") }.buttonStyle(.borderless)
                    }
                    .padding(6).background(RoundedRectangle(cornerRadius: 5).fill(Color.secondary.opacity(0.1)))
                }
            }
            VStack(alignment: .leading, spacing: 6) {
                Text(L("Open pull requests (not merged)", "Offene Pull Requests (nicht gemergt)")).font(.headline)
                if d.open.isEmpty {
                    Text(L("None", "Keine")).font(.callout).foregroundStyle(.secondary)
                }
                ForEach(d.open) { pr in
                    HStack(alignment: .firstTextBaseline, spacing: 8) {
                        Button("#\(pr.number)") { if let u = URL(string: pr.url) { NSWorkspace.shared.open(u) } }
                            .buttonStyle(.link).font(.caption.monospacedDigit())
                        Text(pr.title).font(.callout).lineLimit(2)
                        if pr.draft { tag(L("draft", "Entwurf")) }
                        if pr.bot == true { tag("bot") }
                        Spacer(minLength: 8)
                        Image(systemName: pr.ci == "failed" ? "xmark.circle.fill" : pr.ci == "running" ? "clock" : pr.ci == "passed" ? "checkmark.circle.fill" : "minus.circle")
                            .foregroundStyle(pr.ci == "failed" ? .red : pr.ci == "passed" ? .green : .secondary)
                            .help("CI: \(pr.ci)")
                    }
                }
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
    }

    private func labelled(_ title: String, _ text: String) -> some View {
        VStack(alignment: .leading, spacing: 2) {
            Text(title).font(.caption).foregroundStyle(.secondary)
            Text(text).font(.callout).textSelection(.enabled)
        }
    }

    private func tag(_ s: String) -> some View {
        Text(s).font(.caption2).padding(.horizontal, 5).padding(.vertical, 1)
            .background(Capsule().fill(Color.secondary.opacity(0.15)))
    }
}

// MARK: - Logos

extension NSImage {
    /// Mostly light and partly transparent: drawn on white it would vanish.
    var isLightOnClear: Bool {
        guard let cg = cgImage(forProposedRect: nil, context: nil, hints: nil) else { return false }
        let n = 16
        var px = [UInt8](repeating: 0, count: n * n * 4)
        guard let ctx = CGContext(data: &px, width: n, height: n, bitsPerComponent: 8, bytesPerRow: n * 4,
                                  space: CGColorSpaceCreateDeviceRGB(), bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue) else { return false }
        ctx.draw(cg, in: CGRect(x: 0, y: 0, width: n, height: n))
        var lum = 0.0, weight = 0.0, clear = 0
        for i in stride(from: 0, to: px.count, by: 4) {
            let a = Double(px[i + 3]) / 255
            if a < 0.1 { clear += 1; continue }
            // premultiplied: divide by alpha to get the colour back
            let r = Double(px[i]) / 255 / a, g = Double(px[i + 1]) / 255 / a, b = Double(px[i + 2]) / 255 / a
            lum += (0.2126 * r + 0.7152 * g + 0.0722 * b) * a; weight += a
        }
        return clear > n * n / 8 && weight > 0 && lum / weight > 0.85
    }
}

/// Fetches the icon from the site itself (link rel="apple-touch-icon"/"icon", then the usual paths).
/// Without a domain or an icon: a letter on a colour derived from the name.
actor LogoCache {
    static let shared = LogoCache()
    private var cache: [String: NSImage?] = [:]

    /// Logos are kept on disk for a week; an empty file remembers "this site has none".
    private static let dir = Store.cacheDir.appendingPathComponent("logos", isDirectory: true)
    private static let week: TimeInterval = 7 * 24 * 3600

    /// Once at start: logos of sites not seen for a month go, so the folder does not grow for ever.
    nonisolated static func sweep() {
        let fm = FileManager.default
        guard let files = try? fm.contentsOfDirectory(at: dir, includingPropertiesForKeys: [.contentModificationDateKey]) else { return }
        for f in files {
            let at = (try? f.resourceValues(forKeys: [.contentModificationDateKey]).contentModificationDate) ?? .distantPast
            if Date().timeIntervalSince(at) > 30 * 24 * 3600 { try? fm.removeItem(at: f) }
        }
    }

    func image(for domain: String) async -> NSImage? {
        if let hit = cache[domain] { return hit }
        let file = Self.dir.appendingPathComponent(domain.replacingOccurrences(of: "/", with: "_"))
        if let attrs = try? FileManager.default.attributesOfItem(atPath: file.path),
           let at = attrs[.modificationDate] as? Date, Date().timeIntervalSince(at) < Self.week,
           let data = try? Data(contentsOf: file) {
            let img = data.isEmpty ? nil : NSImage(data: data)
            cache[domain] = img
            return img
        }
        let (img, data) = await fetch(domain)
        cache[domain] = img
        try? FileManager.default.createDirectory(at: Self.dir, withIntermediateDirectories: true)
        try? (data ?? Data()).write(to: file, options: .atomic)
        return img
    }

    private func get(_ url: URL) async -> Data? {
        var req = URLRequest(url: url, timeoutInterval: 8)
        req.setValue("Mozilla/5.0 (Macintosh) DeployCenter", forHTTPHeaderField: "User-Agent")
        guard let (data, resp) = try? await URLSession.shared.data(for: req),
              let http = resp as? HTTPURLResponse, http.statusCode == 200, !data.isEmpty else { return nil }
        return data
    }

    private func fetch(_ domain: String) async -> (NSImage?, Data?) {
        guard let base = URL(string: "https://\(domain)/") else { return (nil, nil) }
        var candidates: [URL] = []
        if let html = await get(base), let text = String(data: html, encoding: .utf8) {
            candidates += Self.iconLinks(in: text).compactMap { URL(string: $0, relativeTo: base)?.absoluteURL }
        }
        candidates += ["apple-touch-icon.png", "favicon.svg", "favicon.png", "favicon.ico"]
            .compactMap { URL(string: $0, relativeTo: base)?.absoluteURL }
        for url in candidates {
            if let data = await get(url), let img = NSImage(data: data), img.size.width > 0 { return (img, data) }
        }
        return (nil, nil)
    }

    /// apple-touch-icon first: it is large and square.
    static func iconLinks(in html: String) -> [String] {
        guard let re = try? NSRegularExpression(pattern: #"<link[^>]+>"#, options: .caseInsensitive) else { return [] }
        let ns = html as NSString
        var touch: [String] = [], icons: [String] = []
        for m in re.matches(in: html, range: NSRange(location: 0, length: ns.length)) {
            let tag = ns.substring(with: m.range)
            let lower = tag.lowercased()
            guard lower.contains("icon"), let href = attr("href", in: tag) else { continue }
            if lower.contains("apple-touch-icon") { touch.append(href) } else { icons.append(href) }
        }
        return touch + icons
    }

    private static func attr(_ name: String, in tag: String) -> String? {
        guard let re = try? NSRegularExpression(pattern: name + #"\s*=\s*["']([^"']+)["']"#, options: .caseInsensitive),
              let m = re.firstMatch(in: tag, range: NSRange(location: 0, length: (tag as NSString).length)) else { return nil }
        return (tag as NSString).substring(with: m.range(at: 1))
    }
}

struct Logo: View {
    let domain: String?
    let name: String
    @State private var image: NSImage?

    var body: some View {
        ZStack {
            if let image {
                Image(nsImage: image).resizable().interpolation(.high).scaledToFit()
                    .padding(3)
                    // A white logo on a transparent ground disappears on white; it gets a dark one.
                    .background(RoundedRectangle(cornerRadius: 8).fill(image.isLightOnClear ? Color(white: 0.18) : Color.white))
            } else {
                RoundedRectangle(cornerRadius: 8).fill(color.gradient)
                Text(String(name.prefix(1)).uppercased())
                    .font(.system(size: 16, weight: .bold, design: .rounded))
                    .foregroundStyle(.white)
            }
        }
        .frame(width: 34, height: 34)
        .clipShape(RoundedRectangle(cornerRadius: 8))
        .task(id: domain) {
            guard let domain else { return }
            image = await LogoCache.shared.image(for: domain)
        }
    }

    private var color: Color {
        let palette: [Color] = [.blue, .purple, .pink, .orange, .teal, .indigo, .green, .red, .mint, .cyan]
        let sum = name.unicodeScalars.reduce(0) { $0 &+ Int($1.value) }
        return palette[sum % palette.count]
    }
}

// MARK: - Settings (⌘,)

struct SettingsView: View {
    @ObservedObject var store: Store
    @AppStorage("refreshMinutes") private var refreshMinutes = 15
    @AppStorage("maxParallel") private var maxParallel = 3
    @AppStorage("reminderHour") private var reminderHour = 0
    @AppStorage("showMenuBar") private var showMenuBar = true
    @AppStorage("hideDock") private var hideDock = false
    @AppStorage("notifications") private var notifications = true
    @AppStorage("checkUpdates") private var checkUpdates = true
    @State private var openAtLogin = SMAppService.mainApp.status == .enabled
    @State private var loginError: String?

    var body: some View {
        Form {
            Picker(L("Reload the lists every", "Listen neu laden alle"), selection: $refreshMinutes) {
                ForEach([5, 15, 30, 60], id: \.self) { Text(L("\($0) minutes", "\($0) Minuten")).tag($0) }
            }
            Picker(L("Builds at the same time", "Builds gleichzeitig"), selection: $maxParallel) {
                ForEach([1, 2, 3, 5, 10], id: \.self) { Text("\($0)").tag($0) }
            }
            Toggle(L("Show in the menu bar", "In der Menüleiste zeigen"), isOn: $showMenuBar)
            Toggle(L("No Dock icon (menu bar only)", "Kein Dock-Symbol (nur Menüleiste)"), isOn: $hideDock)
                .disabled(!showMenuBar)
                .onChange(of: hideDock) { _, on in
                    NSApp.setActivationPolicy(on ? .accessory : .regular)
                    if !on { NSApp.activate(ignoringOtherApps: true) }
                }
            Toggle(L("Open at login", "Beim Anmelden öffnen"), isOn: $openAtLogin)
                .onChange(of: openAtLogin) { _, on in
                    do { if on { try SMAppService.mainApp.register() } else { try SMAppService.mainApp.unregister() }; loginError = nil }
                    catch { loginError = error.localizedDescription; openAtLogin = SMAppService.mainApp.status == .enabled }
                }
            if let loginError { Text(loginError).font(.caption).foregroundStyle(.red) }
            Toggle(L("Notify when a deploy ends", "Mitteilung, wenn ein Deploy fertig ist"), isOn: $notifications)
            Picker(L("Daily reminder to deploy", "Tägliche Erinnerung zum Deployen"), selection: $reminderHour) {
                Text(L("Off", "Aus")).tag(0)
                ForEach(7...20, id: \.self) { Text(L("at \($0):00", "um \($0):00 Uhr")).tag($0) }
            }
            .onChange(of: reminderHour) { _, h in if h > 0 { Notify.ask() } }
            .help(L("Only a reminder, and only when something waits. Nothing is deployed by itself.",
                    "Nur eine Erinnerung, und nur wenn etwas wartet. Es wird nichts von selbst deployt."))
            Toggle(L("Look for a new version once a day", "Einmal am Tag nach einer neuen Version sehen"), isOn: $checkUpdates)
            Button(L("Open the error log", "Fehlerprotokoll öffnen")) {
                if !FileManager.default.fileExists(atPath: Log.url.path) { Log.write("log started") }
                NSWorkspace.shared.open(Log.url)
            }
            if !store.hidden.isEmpty {
                Button(L("Show \(store.hidden.count) hidden projects again", "\(store.hidden.count) ausgeblendete Projekte wieder zeigen")) {
                    store.hidden = []; UserDefaults.standard.set([String](), forKey: "hidden")
                }
            }
            Text(L("Version ", "Version ") + (Bundle.main.infoDictionary?["CFBundleShortVersionString"] as? String ?? "?")
                 + L(" · no telemetry; GitHub, Vercel and Render are asked with your own logins", " · keine Telemetrie; GitHub, Vercel und Render werden mit deinen eigenen Anmeldungen gefragt"))
                .font(.caption).foregroundStyle(.secondary)
        }
        .formStyle(.grouped)
        .frame(width: 460)
    }
}

@main
struct DeployCenterApp: App {
    /// One store for the window and the menu bar, so both show the same counts.
    @StateObject private var store = Store()
    @AppStorage("showMenuBar") private var showMenuBar = true

    var body: some Scene {
        WindowGroup("Deploy Center", id: "main") { ContentView(store: store) }
            .windowResizability(.contentMinSize)
        Settings { SettingsView(store: store) }
        MenuBarExtra(isInserted: $showMenuBar) {
            MenuBarContent(store: store)
        } label: {
            let n = store.waiting.prs > 0 ? store.waiting.prs : store.waiting.projects
            Image(systemName: "paperplane").task { store.boot() }
            if n > 0 { Text("\(n)") }
        }
    }
}

/// The menu bar: what waits to go live, and a way to the window. Deploying stays in the window,
/// where the confirmation is.
struct MenuBarContent: View {
    @ObservedObject var store: Store
    @Environment(\.openWindow) private var openWindow

    var body: some View {
        let w = store.waiting
        let changed = Array(store.items.values.joined()).filter { $0.hasNewCommits && $0.deployable && $0.state == .idle }
            .sorted { ($0.pendingCommits ?? 0) > ($1.pendingCommits ?? 0) }
        if w.projects == 0 {
            Text(L("Everything merged is live", "Alles Gemergte ist live"))
        } else {
            Text(L("\(w.prs) PRs, \(w.commits) commits waiting", "\(w.prs) PRs, \(w.commits) Commits warten"))
            Divider()
            ForEach(changed.prefix(12)) { i in
                Button("\(i.name)  –  \(Row.waitingText(i))") {
                    store.pendingSearch = i.name
                    openWindow(id: "main"); NSApp.activate(ignoringOtherApps: true)
                }
            }
            if changed.count > 12 { Text(L("and \(changed.count - 12) more", "und \(changed.count - 12) weitere")) }
        }
        if w.openPRs > 0 {
            Text(L("\(w.openPRs) PRs still open", "\(w.openPRs) PRs noch offen"))
        }
        Divider()
        Button(L("Open Deploy Center", "Deploy Center öffnen")) {
            openWindow(id: "main"); NSApp.activate(ignoringOtherApps: true)
        }
        .keyboardShortcut("o")
        if w.projects > 0 {
            Button(L("Deploy everything with changes …", "Alles mit Änderungen deployen …")) {
                openWindow(id: "main"); NSApp.activate(ignoringOtherApps: true)
                store.pendingDeployAll = true
            }
        }
        Button(L("Reload", "Neu laden")) { Task { await store.autoRefresh() } }
        Divider()
        Button(L("Quit", "Beenden")) { NSApp.terminate(nil) }.keyboardShortcut("q")
    }
}
