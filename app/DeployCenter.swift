// Deploy Center — turn off auto-deploy on Vercel and Render, then deploy by hand from one window.
// All the work is done by the `deploys` script bundled with the app; the app only calls it.
// Built by build.sh (swiftc, Swift 5 mode, no Xcode project needed).

import SwiftUI
import AppKit
import Charts

// MARK: - Language (German if the Mac prefers it, English otherwise)

let isGerman = (Locale.preferredLanguages.first ?? "en").hasPrefix("de")
func L(_ en: String, _ de: String) -> String { isGerman ? de : en }

// MARK: - Calling the script

enum Tool {
    /// The script ships inside the app, so a download needs nothing but the app.
    static var path: String {
        Bundle.main.path(forResource: "deploys", ofType: nil) ?? NSHomeDirectory() + "/bin/deploys"
    }

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
                env["PATH"] = "/opt/homebrew/bin:/usr/local/bin:" + NSHomeDirectory() + "/.local/bin:/usr/bin:/bin:/usr/sbin:/sbin"
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
                    cont.resume(throwing: ToolError(message: msg.isEmpty ? "Exit code \(p.terminationStatus)" : msg))
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

// MARK: - Data

enum Platform: String, CaseIterable, Identifiable {
    case vercel = "Vercel", render = "Render"
    var id: String { rawValue }
    var cli: String { rawValue.lowercased() }
}

struct Doctor: Decodable {
    let jq: Bool; let vercelCli: Bool; let vercelApi: Bool; let vercelLoggedIn: Bool; let githubCli: Bool; let renderKey: Bool
}

struct VercelProject: Decodable {
    let name: String; let auto: Bool; let repo: String?; let ref: String?; let deployable: Bool
    let domain: String?; let lastAt: Double?; let lastState: String?; let headAt: Double?; let headMsg: String?
    let lastSha: String?; let headSha: String?
}
struct RenderService: Decodable {
    let id: String; let name: String; let type: String; let paused: Bool; let auto: Bool; let deployable: Bool
    let url: String?; let domain: String?; let repo: String?; let ref: String?
    let lastAt: Double?; let lastState: String?; let headAt: Double?; let headMsg: String?
    let lastSha: String?; let headSha: String?
}
struct Costs: Decodable {
    struct Day: Decodable, Identifiable { let day: String; let total: Double; let build: Double; var id: String { day } }
    struct Project: Decodable { let name: String; let build: Double }
    let days: [Day]; let projects: [Project]
}
struct Trigger: Decodable, Identifiable {
    let kind: String; let `where`: String; let detail: String
    var id: String { kind + `where` + detail }
}
struct Started: Decodable { let id: String; let url: String?; let state: String? }
struct StatusReply: Decodable { let id: String; let url: String?; let state: String?; let error: String? }

enum RunState: Equatable {
    case idle, starting, running(String), done(String?), failed(String), skipped(String)
    var isActive: Bool { switch self { case .starting, .running: return true; default: return false } }
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
    var selected = false
    var state: RunState = .idle

    /// A commit on GitHub that is not live yet.
    var hasNewCommits: Bool {
        // Compare commits when both are known; times only as a fallback.
        if let live = lastSha, let head = headSha, !live.isEmpty, !head.isEmpty { return live != head }
        guard let h = headAt else { return false }
        guard let l = lastAt else { return true }
        return h > l.addingTimeInterval(60)
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
            costs = try? await Tool.json(["costs", "7"], as: Costs.self)
        }
        triggers = (try? await Tool.json(["triggers"], as: [Trigger].self)) ?? []
    }

    func buildCost(_ project: String) -> Double? {
        costs?.projects.first(where: { $0.name == project }).map(\.build)
    }

    func start() async {
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
            switch p {
            case .vercel:
                let list = try await Tool.json(["vercel", "json"], as: [VercelProject].self)
                items[.vercel] = list.map { v in
                    Item(id: v.name, name: v.name,
                         detail: v.repo.map { "\($0) · \(v.ref ?? "main")" } ?? L("no Git repository", "kein Git-Repo"),
                         platform: .vercel, deployable: v.deployable, auto: v.auto,
                         note: v.auto ? L("deploys on every push", "deployt bei jedem Push")
                             : (v.deployable ? nil : L("repo unknown", "Repo unbekannt")),
                         link: v.domain.map { "https://\($0)" },
                         domain: v.domain, lastAt: date(v.lastAt), lastState: v.lastState,
                         headAt: date(v.headAt), headMsg: v.headMsg, lastSha: v.lastSha, headSha: v.headSha)
                }
            case .render:
                let list = try await Tool.json(["render", "json"], as: [RenderService].self)
                items[.render] = list.map { r in
                    Item(id: r.id, name: r.name,
                         detail: Self.typeName(r.type) + (r.repo.map { " · \($0) · \(r.ref ?? "main")" } ?? ""),
                         platform: .render, deployable: r.deployable, auto: r.auto,
                         note: r.paused ? L("suspended", "pausiert")
                             : (r.auto ? L("deploys on every push", "deployt bei jedem Push") : nil),
                         link: r.url, domain: r.domain, lastAt: date(r.lastAt), lastState: r.lastState,
                         headAt: date(r.headAt), headMsg: r.headMsg, lastSha: r.lastSha, headSha: r.headSha)
                }
            }
        } catch {
            loadError[p] = error.localizedDescription
        }
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
        if case .done = s, countsAsLive {
            items[p]![i].lastSha = items[p]![i].headSha
            items[p]![i].lastAt = Date(); items[p]![i].lastState = p == .vercel ? "READY" : "live"
        }
    }

    func deploySelected(_ p: Platform, preview: Bool = false) {
        let chosen = selected(p)
        clearSelection(p)
        for item in chosen { Task { await deploy(item, preview: preview) } }
    }

    func deployOne(_ item: Item, preview: Bool) { Task { await deploy(item, preview: preview) } }

    /// Production back to what was live before.
    func rollback(_ item: Item) {
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

    private func deploy(_ item: Item, preview: Bool = false) async {
        let p = item.platform
        set(p, item.id, .starting)
        do {
            let started = try await Tool.json([p.cli, "deploy-json", item.id] + (preview ? ["--preview"] : []), as: Started.self)
            set(p, item.id, .running(started.state ?? L("started", "gestartet")))
            try await follow(item, deployId: started.id, url: started.url, preview: preview)
        } catch {
            set(p, item.id, .failed(error.localizedDescription))
        }
    }

    /// Asks every 6 seconds until the deploy is live or failed (40 minutes at most).
    private func follow(_ item: Item, deployId: String, url: String?, preview: Bool = false) async throws {
        let p = item.platform
        for _ in 0..<400 {
            try await Task.sleep(nanoseconds: 6_000_000_000)
            let args = p == .vercel ? ["vercel", "status", deployId] : ["render", "status", item.id, deployId]
            guard let s = try? await Tool.json(args, as: StatusReply.self) else { continue }
            let state = (s.state ?? "").lowercased()
            switch (p, state) {
            case (.vercel, "ready"), (.render, "live"):
                if preview { set(p, item.id, .done(s.url ?? url), countsAsLive: false) }
                else { set(p, item.id, .done(p == .vercel ? (item.link ?? s.url ?? url) : item.link)) }
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
    @StateObject private var store = Store()
    @State private var platform: Platform = .vercel
    @State private var search = ""
    @State private var confirming = false
    @State private var confirmingOff = false
    @State private var onlyChanged = false
    @State private var rollbackItem: Item?

    private var visible: [Item] {
        var all = store.items[platform] ?? []
        if onlyChanged { all = all.filter { $0.hasNewCommits } }
        guard !search.isEmpty else { return all }
        return all.filter { $0.name.localizedCaseInsensitiveContains(search) || $0.detail.localizedCaseInsensitiveContains(search)
            || ($0.domain ?? "").localizedCaseInsensitiveContains(search) }
    }

    var body: some View {
        VStack(spacing: 0) {
            header
            Divider()
            if let msg = store.busyMessage {
                HStack { ProgressView().controlSize(.small); Text(msg) }.padding(8)
            }
            triggerBanner
            autoBanner
            if platform == .vercel, let c = store.costs { CostBar(costs: c) }
            content
            Divider()
            footer
        }
        .frame(minWidth: 680, minHeight: 540)
        .task { await store.start() }
        .alert(L("Deploy to production?", "Live deployen?"), isPresented: $confirming) {
            Button(L("Cancel", "Abbrechen"), role: .cancel) {}
            Button(L("Deploy", "Deployen")) { store.deploySelected(platform) }
        } message: {
            Text(store.selected(platform).map(\.name).joined(separator: "\n")
                 + "\n\n" + L("The newest commit on GitHub goes live on \(platform.rawValue).",
                               "Der neueste Stand von GitHub geht auf \(platform.rawValue) live."))
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
            Picker("", selection: $platform) {
                ForEach(Platform.allCases) { p in
                    Text("\(p.rawValue)  \(store.items[p]?.count ?? 0)").tag(p)
                }
            }
            .pickerStyle(.segmented).labelsHidden().frame(width: 240)

            TextField(L("Search", "Suchen"), text: $search).textFieldStyle(.roundedBorder)

            Toggle(isOn: $onlyChanged) {
                Text(L("Changed only", "Nur mit Änderungen") + " (\(store.changedCount(platform)))")
            }
            .toggleStyle(.button)
            .help(L("Only projects with a commit on GitHub that is not live yet",
                    "Nur Projekte mit einem Commit auf GitHub, der noch nicht live ist"))

            Button { Task { await store.load(platform) } } label: { Image(systemName: "arrow.clockwise") }
                .help(L("Reload", "Neu laden"))
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
        } else if store.doctor == nil {
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
        } else {
            List(visible) { item in
                Row(item: item, cost: platform == .vercel ? store.buildCost(item.name) : nil) { store.toggle(platform, item.id) }
                    .contextMenu {
                        if item.deployable && !item.state.isActive {
                            Button(L("Deploy to production", "Live deployen")) { store.deployOne(item, preview: false) }
                            if platform == .vercel {
                                Button(L("Preview deploy (not live)", "Vorschau-Deploy (nicht live)")) { store.deployOne(item, preview: true) }
                            }
                            Divider()
                            Button(L("Roll back production …", "Live zurückrollen …")) { rollbackItem = item }
                        }
                        if let l = item.link, let u = URL(string: l) {
                            Button(L("Open site", "Seite öffnen")) { NSWorkspace.shared.open(u) }
                        }
                    }
            }
            .listStyle(.inset)
        }
    }

    private var footer: some View {
        let count = store.selected(platform).count
        return HStack {
            Text(count == 0 ? L("Tick the projects that should go live", "Projekte anhaken, die live gehen sollen")
                            : L("\(count) selected", "\(count) ausgewählt"))
                .foregroundStyle(.secondary)
            Spacer()
            if count > 0 {
                Button(L("Clear", "Auswahl leeren")) { store.clearSelection(platform) }
            } else if store.changedCount(platform) > 0 {
                Button(L("Select all changed", "Alle mit Änderungen anhaken")) { store.selectChanged(platform) }
            }
            if platform == .vercel {
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
    private var week: Double { costs.days.map(\.build).reduce(0, +) }

    var body: some View {
        HStack(spacing: 16) {
            VStack(alignment: .leading, spacing: 2) {
                Text(L("Vercel builds, last 7 days", "Vercel-Builds, letzte 7 Tage")).font(.caption).foregroundStyle(.secondary)
                Text(week, format: .currency(code: "USD")).font(.title3.weight(.semibold).monospacedDigit())
                if let last = costs.days.last {
                    Text(L("yesterday ", "gestern ") + last.build.formatted(.currency(code: "USD")))
                        .font(.caption2).foregroundStyle(.secondary)
                }
            }
            Chart(costs.days) { d in
                BarMark(x: .value("Day", String(d.day.suffix(5))), y: .value("USD", d.build))
                    .foregroundStyle(Color.accentColor.gradient)
            }
            .chartYAxis { AxisMarks(position: .leading) { _ in AxisValueLabel() } }
            .frame(height: 54)
        }
        .padding(.horizontal, 12).padding(.vertical, 8)
        .background(Color.secondary.opacity(0.06))
        .help(L("Build costs from Vercel's billing data. Total spend incl. other usage: ",
                "Build-Kosten aus Vercels Abrechnung. Gesamt inkl. sonstiger Nutzung: ")
              + costs.days.map(\.total).reduce(0, +).formatted(.currency(code: "USD")))
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
    let toggle: () -> Void

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
                    Text(item.name).font(.body.weight(.medium))
                    if let d = item.domain, let u = item.link.flatMap(URL.init(string:)) {
                        Button { NSWorkspace.shared.open(u) } label: { Text(d).font(.caption) }
                            .buttonStyle(.link).help(L("Open site", "Seite öffnen"))
                    }
                }
                Text(item.detail).font(.caption).foregroundStyle(.secondary)
                HStack(spacing: 8) {
                    lastDeploy
                    if let cost, cost >= 0.01 {
                        Text(L("builds 7 days: ", "Builds 7 Tage: ") + cost.formatted(.currency(code: "USD")))
                            .font(.caption2).foregroundStyle(cost >= 5 ? .orange : .secondary)
                    }
                    if item.hasNewCommits {
                        Label(L("New changes", "Neue Änderungen"), systemImage: "arrow.up.circle.fill")
                            .font(.caption2.weight(.semibold)).foregroundStyle(.blue)
                            .help(item.headMsg.map { L("Newest commit: ", "Neuester Commit: ") + $0
                                + (item.headAt.map { " (\(Self.ago($0)))" } ?? "") } ?? "")
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
        }
        .padding(.vertical, 4)
        .contentShape(Rectangle())
        .opacity(item.deployable ? 1 : 0.55)
        .onTapGesture { if !item.state.isActive { toggle() } }
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
            .help(at.formatted(date: .complete, time: .shortened))
        } else {
            Text(L("Never deployed", "Noch nie deployt")).font(.caption2).foregroundStyle(.secondary)
        }
    }

    @ViewBuilder private var status: some View {
        switch item.state {
        case .idle:
            EmptyView()
        case .starting:
            HStack(spacing: 6) { ProgressView().controlSize(.small); Text(L("starting", "startet")).font(.caption) }
        case .running(let s):
            HStack(spacing: 6) { ProgressView().controlSize(.small); Text(s).font(.caption) }
        case .done(let url):
            HStack(spacing: 6) {
                Label("Live", systemImage: "checkmark.circle.fill").foregroundStyle(.green).font(.caption.weight(.semibold))
                if let url, let u = URL(string: url) {
                    Button { NSWorkspace.shared.open(u) } label: { Image(systemName: "arrow.up.right.square") }
                        .buttonStyle(.borderless).help(url)
                }
            }
        case .skipped(let msg):
            Label(L("Skipped", "Übersprungen"), systemImage: "forward.circle.fill")
                .foregroundStyle(.secondary).font(.caption.weight(.semibold))
                .help(msg)
        case .failed(let msg):
            Label(L("Failed", "Fehler"), systemImage: "xmark.octagon.fill")
                .foregroundStyle(.red).font(.caption.weight(.semibold))
                .help(msg)
        }
    }
}

// MARK: - Logos

/// Fetches the icon from the site itself (link rel="apple-touch-icon"/"icon", then the usual paths).
/// Without a domain or an icon: a letter on a colour derived from the name.
actor LogoCache {
    static let shared = LogoCache()
    private var cache: [String: NSImage?] = [:]

    func image(for domain: String) async -> NSImage? {
        if let hit = cache[domain] { return hit }
        let img = await fetch(domain)
        cache[domain] = img
        return img
    }

    private func get(_ url: URL) async -> Data? {
        var req = URLRequest(url: url, timeoutInterval: 8)
        req.setValue("Mozilla/5.0 (Macintosh) DeployCenter", forHTTPHeaderField: "User-Agent")
        guard let (data, resp) = try? await URLSession.shared.data(for: req),
              let http = resp as? HTTPURLResponse, http.statusCode == 200, !data.isEmpty else { return nil }
        return data
    }

    private func fetch(_ domain: String) async -> NSImage? {
        guard let base = URL(string: "https://\(domain)/") else { return nil }
        var candidates: [URL] = []
        if let html = await get(base), let text = String(data: html, encoding: .utf8) {
            candidates += Self.iconLinks(in: text).compactMap { URL(string: $0, relativeTo: base)?.absoluteURL }
        }
        candidates += ["apple-touch-icon.png", "favicon.svg", "favicon.png", "favicon.ico"]
            .compactMap { URL(string: $0, relativeTo: base)?.absoluteURL }
        for url in candidates {
            if let data = await get(url), let img = NSImage(data: data), img.size.width > 0 { return img }
        }
        return nil
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
                    .background(RoundedRectangle(cornerRadius: 8).fill(Color.white))
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

@main
struct DeployCenterApp: App {
    var body: some Scene {
        WindowGroup("Deploy Center") { ContentView() }
            .windowResizability(.contentMinSize)
    }
}
