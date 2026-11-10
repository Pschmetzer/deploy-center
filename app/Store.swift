// Deploy Center — The state of the app: lists, deploys and their queue, costs, the person's marks.

import SwiftUI
import AppKit
import Charts
import UserNotifications
import ServiceManagement

// MARK: - Model

@MainActor
final class Store: ObservableObject {
    @Published var items: [Platform: [Item]] = [.vercel: [], .render: []]
    @Published var loading: Set<Platform> = []
    @Published var loadError: [Platform: String] = [:]
    @Published var doctor: Doctor?
    /// An observer by a shared list (deploy-center.json), as Settings > Team last read it.
    @Published var teamObserver = false
    /// Observer mode: the window shows no deploy buttons, and the script would refuse anyway.
    var observer: Bool { doctor?.readonly == true || teamObserver }
    @Published var busyMessage: String?

    @Published var doctorError: String?
    @Published var costs: Costs?
    @Published var triggers: [Trigger] = []
    /// The platforms `deploys providers --json` reports (Vercel and Render without it), see Providers.swift.
    @Published var providers: [ProviderInfo] = ProviderInfo.builtIn
    @Published var providersFromScript = false

    /// Costs and stray build triggers load after the lists; neither blocks deploying.
    private var lastExtras = Date.distantPast
    /// When a part last failed to load; the values from before stay and count as out of date.
    @Published var extrasFailedAt: [String: Date] = [:]
    func loadExtras() async {
        lastExtras = Date()
        Task { await checkProviders() }
        // All three at once; each can take a minute (many API calls). A failure keeps the old values.
        let vercel = doctor?.vercelLoggedIn == true, github = doctor?.githubLoggedIn == true
        async let c = vercel ? Self.extra(["costs", "14"], Costs.self) : nil
        async let t = Self.extra(["triggers"], [Trigger].self)
        async let b = github ? Self.extra(["github-budget"], Budget.self) : nil
        if let r = await c { if case .success(let v) = r { costs = v; checkBudget(); writeSnapshot() }; note("costs", r) }
        if let r = await t { if case .success(let v) = r { triggers = v }; note("triggers", r) }
        if let r = await b { if case .success(let v) = r { githubBudget = v }; note("github-budget", r) }
    }
    nonisolated private static func extra<T: Decodable & Sendable>(_ args: [String], _ type: T.Type) async -> Result<T, Error>? {
        do { return .success(try await Tool.json(args, as: T.self, timeout: 300)) } catch { return .failure(error) }
    }
    private func note<T>(_ name: String, _ r: Result<T, Error>) {
        switch r {
        case .success: extrasFailedAt[name] = nil
        case .failure(let e): extrasFailedAt[name] = Date(); Log.write("\(name): \(e.localizedDescription)")
        }
    }

    /// Once a day: commits that have waited longer than the chosen number of days (Settings).
    private func checkStale() {
        let d = UserDefaults.standard
        let days = d.integer(forKey: "staleDays")
        let today = localDay()
        guard days > 0, d.string(forKey: "lastStaleAlarm") != today else { return }
        let old = items.values.joined().filter { i in
            i.hasNewCommits && i.state == .idle && !isHidden(i)
                && (i.oldestPendingAt.map { Date().timeIntervalSince($0) > Double(days) * 86400 } ?? false)
        }
        guard !old.isEmpty else { return }
        d.set(today, forKey: "lastStaleAlarm")
        say(L("\(old.count) projects wait for more than \(days) days", "\(old.count) Projekte warten schon über \(days) Tage"),
            old.prefix(5).map(\.name).joined(separator: ", "), ok: false)
    }

    /// "Place 2 of 5" for a queued row; nil when it is alone.
    func queueText(_ i: Item) -> String? {
        guard queue.count > 1, let k = queue.firstIndex(where: { $0.item.id == i.id }) else { return nil }
        return L("place \(k + 1) of \(queue.count)", "Platz \(k + 1) von \(queue.count)")
    }

    /// Once a day: if the pace of the last 7 days passes 80 % of the monthly budget (Settings), say so.
    private func checkBudget() {
        let d = UserDefaults.standard
        let budget = d.double(forKey: "monthlyBudget")
        guard budget > 0, let days = costs?.days.suffix(7), !days.isEmpty else { return }
        let month = days.map(\.build).reduce(0, +) / Double(days.count) * 30
        let today = localDay()
        guard month > budget * 0.8, d.string(forKey: "lastBudgetAlarm") != today else { return }
        d.set(today, forKey: "lastBudgetAlarm")
        let m = month.formatted(.currency(code: "USD")), b = budget.formatted(.currency(code: "USD"))
        say(L("Build costs near your budget", "Build-Kosten nahe am Budget"),
            L("At this pace ≈ \(m) a month, budget \(b)", "Bei diesem Tempo ≈ \(m) im Monat, Budget \(b)"), ok: false)
    }

    /// Outages at Vercel, Render and GitHub: a failing deploy may not be the project's fault.
    @Published var providerIssues: [String] = []
    func checkProviders() async {
        let feeds = [("Vercel", "https://www.vercel-status.com/api/v2/status.json"),
                     ("Render", "https://status.render.com/api/v2/status.json"),
                     ("GitHub", "https://www.githubstatus.com/api/v2/status.json")]
        let found = await withTaskGroup(of: (Int, String?).self) { group -> [(Int, String)] in
            for (k, feed) in feeds.enumerated() {
                group.addTask {
                    guard let url = URL(string: feed.1),
                          let (data, _) = try? await URLSession.shared.data(for: URLRequest(url: url, timeoutInterval: 10)),
                          let st = (try? JSONSerialization.jsonObject(with: data) as? [String: Any])?["status"] as? [String: Any],
                          let indicator = st["indicator"] as? String, indicator != "none" else { return (k, nil) }
                    return (k, "\(feed.0): \(st["description"] as? String ?? indicator)")
                }
            }
            var out: [(Int, String)] = []
            for await (k, text) in group { if let text { out.append((k, text)) } }
            return out
        }
        let issues = found.sorted { $0.0 < $1.0 }.map(\.1)
        providerIssues = issues
    }

    // MARK: Autofix and auto-deploy allowances, read with the lists (both are local and cheap)

    @Published var autofix: AutofixReport?
    @Published var allowances: [AutoDeployAllowance] = []
    /// Rows being handed to Claude right now (`Store.key`), for disabling the button.
    @Published var autofixRunning: Set<String> = []
    /// The last answer of "Fix with Claude" per row, for the details sheet.
    @Published var autofixResult: [String: Message] = [:]

    /// Bug scans by the local Claude Code CLI (`deploys scan`), and the repos being started right now.
    @Published var scan: ScanReport?
    @Published var scanStarting: Set<String> = []
    private var scanPoll: Task<Void, Never>?

    func loadScanStatus() async {
        if case .success(let r)? = await Self.extra(["scan", "status", "--json"], ScanReport.self) { scan = r }
        // While a scan runs, look again every 20 seconds; it takes minutes, the app must not block.
        if scan?.anyRunning == true, scanPoll == nil {
            scanPoll = Task { [weak self] in
                while !Task.isCancelled {
                    try? await Task.sleep(nanoseconds: 20_000_000_000)
                    guard let self else { return }
                    if case .success(let r)? = await Self.extra(["scan", "status", "--json"], ScanReport.self) { self.scan = r }
                    if self.scan?.anyRunning != true { self.scanPoll = nil; return }
                }
            }
        }
    }
    func scanRun(_ i: Item) -> ScanReport.Run? { scan?.newest(repo: i.repo) }
    func checkRun(_ i: Item) -> ScanReport.Check? { scan?.newestCheck(repo: i.repo) }
    @Published var checkLeaks: [String: [CheckDetails.Leak]] = [:]
    func canCheck(_ i: Item) -> Bool {
        guard let r = i.repo, scan?.tools?.any != false else { return false }
        return !scanStarting.contains("check:" + r) && checkRun(i)?.running != true
    }

    /// "Security check": OSV-Scanner, gitleaks and Semgrep on the repo, read-only, in the background.
    func securityCheck(_ i: Item) async {
        guard let repo = i.repo, canCheck(i) else { return }
        let key = Self.key(i), name = Demo.mask(i.name)
        scanStarting.insert("check:" + repo); defer { scanStarting.remove("check:" + repo) }
        do {
            _ = try await Tool.run(["check", "start", repo, i.ref ?? "main"], timeout: 60)
            tell(L("\(name): security check started", "\(name): Sicherheits-Check gestartet"),
                 L("OSV-Scanner, gitleaks and Semgrep, read-only", "OSV-Scanner, gitleaks und Semgrep, nur lesend"), ok: true, key: key)
        } catch {
            tell(L("\(name): security check not started", "\(name): Sicherheits-Check nicht gestartet"), error.localizedDescription, ok: false, key: key)
        }
        await loadScanStatus()
    }

    /// The secrets of a check, for the details sheet. Never sent anywhere.
    func loadLeaks(_ c: ScanReport.Check) async {
        guard (c.gitleaks ?? 0) > 0, checkLeaks[c.id] == nil else { return }
        if case .success(let d)? = await Self.extra(["check", "show", c.id], CheckDetails.self) { checkLeaks[c.id] = d.leaks }
    }
    func canScan(_ i: Item) -> Bool {
        guard let r = i.repo, !observer else { return false }
        return !scanStarting.contains(r) && scanRun(i)?.running != true
    }

    /// "Find bugs with Claude": `deploys scan start <repo> <branch>`, detached; the result comes as a PR.
    func scanForBugs(_ i: Item, findings: Bool = false) async {
        guard let repo = i.repo, canScan(i) else { return }
        let key = Self.key(i), name = Demo.mask(i.name)
        if let s = scan, !s.installed || !s.loggedIn {
            tell(L("\(name): bug scan not possible", "\(name): Bug-Scan nicht möglich"),
                 s.installed ? L("Claude Code is not logged in. In Terminal: claude login", "Claude Code ist nicht angemeldet. Im Terminal: claude login")
                             : L("Claude Code is not installed. In Terminal: npm i -g @anthropic-ai/claude-code", "Claude Code ist nicht installiert. Im Terminal: npm i -g @anthropic-ai/claude-code"),
                 ok: false, key: key)
            return
        }
        scanStarting.insert(repo); defer { scanStarting.remove(repo) }
        do {
            var args = ["scan", "start", repo, i.ref ?? "main"]
            if findings, let c = checkRun(i), c.status == "done", c.fixable > 0 { args += ["--findings", c.id] }
            _ = try await Tool.run(args, timeout: 120)
            tell(L("\(name): Claude is looking for bugs", "\(name): Claude sucht nach Bugs"),
                 L("takes 10–30 minutes; fixes come as a pull request, nothing is merged or deployed",
                   "dauert 10–30 Minuten; Fixes kommen als Pull Request, nichts wird gemergt oder deployt"), ok: true, key: key)
        } catch {
            tell(L("\(name): bug scan not started", "\(name): Bug-Scan nicht gestartet"), error.localizedDescription, ok: false, key: key)
        }
        await loadScanStatus()
    }

    /// When `autofix sync` last ran, so a refresh every few seconds does not ask GitHub every time.
    private var lastAutofixSync = Date.distantPast

    func loadAgentStatus() async {
        await loadScanStatus()
        // A hand-over still marked "fixing": bring it up to date with its PR first. The 10-minute
        // job does this too, but it may not be running, and then a merged fix said "fixing" for hours.
        // Before the first status (nil): once, which also loads a schedule launchd dropped.
        if autofix?.fires.contains(where: { RowAutofix.needsSync($0) }) ?? true,
           Date().timeIntervalSince(lastAutofixSync) > 180 {
            lastAutofixSync = Date()
            _ = try? await Tool.run(["autofix", "sync"], timeout: 90)
        }
        async let a = Self.extra(["autofix", "status", "--json"], AutofixReport.self)
        async let g = Self.extra(["guard", "status", "--json"], AllowanceReport.self)
        // A script without these commands: nothing is shown, nothing is said.
        if case .success(let r)? = await a { autofix = r; preselectMergedFixes() }
        if case .success(let r)? = await g { allowances = r.allowances } else { allowances = [] }
    }

    func autofixState(_ i: Item) -> RowAutofix? { RowAutofix.of(i, autofix?.newest(for: i)) }
    func allowance(_ i: Item, now: Date = Date()) -> AutoDeployAllowance? {
        allowances.first { $0.covers(i) && $0.expiresAt > now }
    }
    var activeAllowances: [AutoDeployAllowance] { allowances.filter { $0.expiresAt > Date() } }
    /// Failed builds a Claude session is working on, over both platforms (the menu bar).
    var fixingCount: Int {
        guard autofix != nil else { return 0 }
        return items.values.joined().filter { if case .fixing? = autofixState($0) { return true } else { return false } }.count
    }
    /// The button: the last deploy failed and no session or fix PR is on it already.
    func canFixWithClaude(_ i: Item) -> Bool {
        guard i.lastFailed, i.repo != nil, !i.state.isActive else { return false }
        // .noPR too: the script does not hand the same failed build over twice.
        switch autofixState(i) { case .fixing?, .prOpen?, .merged?, .noPR?: return false; default: return true }
    }

    /// A merged fix ticks its row once, so deploying it is one click; unticking is respected.
    func preselectMergedFixes() {
        let d = UserDefaults.standard
        var seen = d.stringArray(forKey: "autofixPreselected") ?? []
        for p in Platform.allCases {
            for k in (items[p] ?? []).indices {
                let i = items[p]![k]
                guard case .merged(let sha, _, _)? = autofixState(i), i.deployable, !i.state.isActive, !isHidden(i) else { continue }
                let key = RowAutofix.preselectKey(i, sha: sha)
                if seen.contains(key) { continue }
                seen.append(key); items[p]![k].selected = true
            }
        }
        d.set(Array(seen.suffix(100)), forKey: "autofixPreselected")
    }

    /// "Fix with Claude": `deploys autofix --only <platform> <project>`, the answer as a toast.
    func fixWithClaude(_ i: Item) async {
        let key = Self.key(i)
        guard !autofixRunning.contains(key) else { return }
        if let r = autofix, !r.ready { offerAutofixSetup(); return }
        autofixRunning.insert(key); defer { autofixRunning.remove(key) }
        let name = Demo.mask(i.name)
        do {
            let out = String(data: try await Tool.run(["autofix", "--only", i.platform.cli, i.name], timeout: 300), encoding: .utf8) ?? ""
            let last = out.split(separator: "\n").last.map(String.init)?.trimmingCharacters(in: .whitespaces) ?? ""
            tell(L("\(name): handed to Claude", "\(name): an Claude übergeben"), last, ok: true, key: key)
        } catch {
            let msg = error.localizedDescription
            if msg.localizedCaseInsensitiveContains("no routine") { offerAutofixSetup(); return }
            tell(L("\(name): not handed to Claude", "\(name): nicht an Claude übergeben"), msg, ok: false, key: key)
        }
        await loadAgentStatus()
    }

    /// A toast and a line in the messages, names scrubbed in demo mode.
    private func tell(_ title: String, _ body: String, ok: Bool, key: String) {
        let b = Demo.scrub(body, items: Array(items.values.joined()))
        let text = title + (b.isEmpty ? "" : " – " + b)
        show(Toast(text: text, ok: ok))
        let m = Message(date: Date(), text: text, ok: ok)
        messages.insert(m, at: 0); autofixResult[key] = m
        if messages.count > 30 { messages.removeLast() }
    }

    private func offerAutofixSetup() {
        show(Toast(text: L("Autofix is not set up: no routine yet", "Autofix ist nicht eingerichtet: noch keine Routine"), ok: false,
                   undoLabel: L("Open Settings", "Einstellungen öffnen"), undo: {
            UserDefaults.standard.set("claude", forKey: "settingsTab")
            NSApp.activate(ignoringOtherApps: true)
            NSApp.sendAction(Selector(("showSettingsWindow:")), to: nil, from: nil)
        }))
    }

    func buildCost(_ project: String) -> Double? {
        costs?.projects.first(where: { $0.name == project }).map(\.build)
    }

    /// When each list was last read, and which ones are still the copy from the last run.
    @Published var loadedAt: [Platform: Date] = [:]
    @Published var fromCache: Set<Platform> = []

    /// The last failed read of a list. Unlike `loadError` it stays while a reload runs and goes only
    /// when a read succeeds; the list in `items` is never dropped for it (it is the last good copy).
    struct LoadFailure: Equatable { let message: String; let at: Date }
    @Published var lastLoadError: [Platform: LoadFailure] = [:]

    /// What the list of a platform is right now.
    enum ListState: Equatable {
        case notLoaded          // nothing read yet in this run and no saved copy
        case cached(Date?)      // the copy saved by the last run (its time, if known)
        case fresh(Date)        // read in this run
    }
    func listState(_ p: Platform) -> ListState {
        if fromCache.contains(p) { return .cached(loadedAt[p]) }
        if let at = loadedAt[p] { return .fresh(at) }
        return .notLoaded
    }

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
        if !UserDefaults.standard.bool(forKey: "migratedCacheV2") {
            for p in Platform.allCases { try? FileManager.default.removeItem(at: Self.cacheDir.appendingPathComponent("\(p.cli)-v1.json")) }
            UserDefaults.standard.set(true, forKey: "migratedCacheV2")
        }
        Journal.migrate()
        // The Cancel of the rollback countdown (see countDownToRollback).
        NotifyRouter.shared.install()
        NotifyRouter.shared.onCancel = { [weak self] id in self?.cancelRollback(String(id.dropFirst(Store.rollbackPrefix.count))) }
        // After sleep the lists can be hours old, and the daily reminder may be overdue.
        NSWorkspace.shared.notificationCenter.addObserver(forName: NSWorkspace.didWakeNotification, object: nil, queue: .main) { [weak self] _ in
            Task { @MainActor in
                try? await Task.sleep(nanoseconds: 5_000_000_000)   // the network needs a moment
                await self?.autoRefresh(); self?.remindIfDue()
            }
        }
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
        Task { if let t = try? await Tool.json(["config", "--json"], as: TeamConfig.self, timeout: 60) { teamObserver = t.readonly.value } }
        await loadProviders()
        // Both at once: each takes several seconds. A platform switched off in Settings is not read.
        let v = doctor?.vercelLoggedIn == true && doctor?.vercelApi == true && isEnabled(.vercel)
        let r = doctor?.renderKey == true && isEnabled(.render)
        async let a: Void = v ? load(.vercel) : ()
        async let b: Void = r ? load(.render) : ()
        _ = await (a, b)
        await loadAgentStatus()
        await loadExtras()
    }

    private var emptyOnce: Set<Platform> = []
    /// Counts the reads of each list; only the newest one may change it, so an older, slower
    /// answer cannot overwrite a newer one.
    private var loadGeneration: [Platform: Int] = [:]
    func load(_ p: Platform) async {
        let gen = (loadGeneration[p] ?? 0) + 1
        loadGeneration[p] = gen
        loading.insert(p); loadError[p] = nil
        defer { if loadGeneration[p] == gen { loading.remove(p) } }
        do {
            let data = try await Tool.run([p.cli, "json"])
            guard loadGeneration[p] == gen else { return }
            let fresh = try decode(p, data)
            // An empty answer where there were projects is more likely a hiccup than every project gone.
            // A second empty answer in a row is believed (another account, or really nothing left).
            if fresh.isEmpty, !(items[p] ?? []).isEmpty, !emptyOnce.contains(p) {
                emptyOnce.insert(p)
                let text = L("The answer was empty; showing the last list.", "Die Antwort war leer; die letzte Liste bleibt stehen.")
                Log.write("\(p.cli) json: empty answer, kept \(items[p]?.count ?? 0) items")
                lastLoadError[p] = LoadFailure(message: text, at: Date())
                say(L("\(p.rawValue): empty list", "\(p.rawValue): leere Liste"), text, ok: false)
                return
            }
            emptyOnce.remove(p)
            merge(p, fresh)
            pruneDurations(p, keeping: fresh)
            writeCache(p, data)
            fromCache.remove(p); loadedAt[p] = Date(); lastLoadError[p] = nil
            recordHistory()
            writeSnapshot()
            checkStale()
        } catch {
            guard loadGeneration[p] == gen else { return }
            loadError[p] = error.localizedDescription
            lastLoadError[p] = LoadFailure(message: error.localizedDescription, at: Date())
        }
    }

    /// A reload keeps what the person did: ticks stay, a deploy being followed keeps its state.
    /// How a deploy ended stays only while the branch is where it was; a new commit makes the row wait again.
    func merge(_ p: Platform, _ fresh: [Item]) {
        let old = Dictionary((items[p] ?? []).map { ($0.id, $0) }, uniquingKeysWith: { a, _ in a })
        items[p] = fresh.map { n in
            var n = n
            if let o = old[n.id] {
                n.selected = o.selected && n.deployable
                if Self.keepsState(old: o, fresh: n) {
                    // A deploy being followed keeps what cancelling, the timer and promoting need.
                    n.state = o.state; n.deployId = o.deployId; n.startedAt = o.startedAt; n.previewId = o.previewId
                }
            }
            return n
        }
    }

    /// Whether a reload keeps the row's state: always while it runs; an end state (live, failed,
    /// skipped) only while the branch has no commit that came after it.
    nonisolated static func keepsState(old o: Item, fresh n: Item) -> Bool {
        if o.state == .idle { return false }
        if o.state.isActive { return true }
        guard let was = o.headSha, !was.isEmpty, let now = n.headSha else { return false }
        return was == now
    }

    private func decode(_ p: Platform, _ data: Data) throws -> [Item] {
            switch p {
            case .vercel:
                let list = try decodeLossy(VercelProject.self, from: data, label: "vercel json")
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
                         oldestPendingAt: date(v.oldestPendingAt), rewritten: v.rewritten ?? false, risk: v.risk)
                }
            case .render:
                let list = try decodeLossy(RenderService.self, from: data, label: "render json")
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
                         oldestPendingAt: date(r.oldestPendingAt), rewritten: r.rewritten ?? false, risk: r.risk)
                }
            }
    }

    /// Lists only, both platforms; costs and triggers cost many GitHub calls and stay manual.
    /// Not while something is deploying, so nothing being followed is disturbed.
    private var lastDoctor = Date()
    func autoRefresh() async {
        guard loading.isEmpty else { return }
        if doctor == nil { await start(); return }
        // Something was missing (a login, the Render key): ask again, at most every 30 minutes.
        if let d = doctor, !(d.vercelLoggedIn && d.vercelApi && d.renderKey && d.githubLoggedIn != false),
           Date().timeIntervalSince(lastDoctor) > 1800 {
            lastDoctor = Date()
            if let fresh = try? await Tool.json(["doctor"], as: Doctor.self, timeout: 60) { doctor = fresh; doctorError = nil }
        }
        // Only the platform with a deploy under way is left alone; the other one stays current.
        let v = doctor?.vercelLoggedIn == true && isEnabled(.vercel) && !(items[.vercel] ?? []).contains { $0.state.isActive }
        let r = doctor?.renderKey == true && isEnabled(.render) && !(items[.render] ?? []).contains { $0.state.isActive }
        async let a: Void = v ? load(.vercel) : ()
        async let b: Void = r ? load(.render) : ()
        _ = await (a, b)
        await loadAgentStatus()
        // Costs and strays cost many calls: hourly. The status feeds are cheap: every time.
        if Date().timeIntervalSince(lastExtras) > 3600 { await loadExtras() } else { await checkProviders() }
    }

    // MARK: What is waiting on GitHub, over both platforms

    struct Waiting { var projects = 0, commits = 0, prs = 0, openPRs = 0 }
    var waiting: Waiting {
        var w = Waiting()
        let all = Array(items.values.joined())
        // Projects of one repo (frontend + backend) share their commits and PRs: count them once.
        var perRepo: [String: (commits: Int, prs: Int)] = [:]
        // What the person hid, or what the app cannot deploy, is not waiting on them.
        for i in all where i.hasNewCommits && i.state == .idle && i.deployable && !isHidden(i) {
            w.projects += 1
            if let r = i.repo {
                let o = perRepo[r] ?? (0, 0)
                perRepo[r] = (max(o.commits, i.pendingCommits ?? 0), max(o.prs, i.pendingPRs ?? 0))
            } else {
                w.commits += i.pendingCommits ?? 0; w.prs += i.pendingPRs ?? 0
            }
        }
        for v in perRepo.values { w.commits += v.commits; w.prs += v.prs }
        // Open pull requests belong to a repo, and several projects can share one.
        var seen = Set<String>()
        for i in all where !isHidden(i) { if let r = i.repo, let n = i.openPRs, seen.insert(r).inserted { w.openPRs += n } }
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

    /// Rows whose last deploy was cancelled by the person: not a failure in the journal or the summary.
    private var endedByCancel: Set<String> = []
    private func set(_ p: Platform, _ id: String, _ s: RunState, countsAsLive: Bool = true, cancelled byPerson: Bool = false) {
        guard let i = items[p]?.firstIndex(where: { $0.id == id }) else { return }
        let was = items[p]![i].state
        items[p]![i].state = s
        if byPerson { endedByCancel.insert(id) } else if !s.isActive || s == .queued { endedByCancel.remove(id) }
        // A new start: the id of the last deploy must not be the one a cancel goes to.
        if case .starting = s { items[p]![i].startedAt = Date(); items[p]![i].deployId = nil }
        // Queued again: an older start time must not become this deploy's duration.
        if case .queued = s { items[p]![i].startedAt = nil }
        if case .done = s, countsAsLive {
            items[p]![i].lastSha = items[p]![i].headSha
            items[p]![i].lastAt = Date(); items[p]![i].lastState = p == .vercel ? "READY" : "live"
            items[p]![i].changed = false; items[p]![i].pendingCommits = 0; items[p]![i].pendingPRs = 0
        }
        let name = items[p]![i].name
        // Only a deploy that really started has a duration; a row that never left the queue has none.
        let took = was.isActive && was != .queued ? items[p]![i].startedAt.map { Date().timeIntervalSince($0) } : nil
        switch s {
        case .done: Journal.append(JournalEntry(platform: p.rawValue, name: name, result: countsAsLive ? "live" : "other", seconds: took, detail: nil))
        case .failed(let m): Journal.append(JournalEntry(platform: p.rawValue, name: name, result: byPerson ? "cancelled" : "failed", seconds: took, detail: m))
        case .skipped(let m): Journal.append(JournalEntry(platform: p.rawValue, name: name, result: "skipped", seconds: took, detail: m))
        default: break
        }
        switch s {
        case .done:
            if countsAsLive { say(L("\(name) is live", "\(name) ist live"), p.rawValue, ok: true) }
            else if items[p]![i].previewId != nil { say(L("\(name): preview is ready", "\(name): Vorschau ist fertig"), p.rawValue, ok: true) }
            else { say(L("\(name) rolled back", "\(name) zurückgerollt"), p.rawValue, ok: true) }
        case .failed(let m):
            if byPerson { say(L("\(name) cancelled", "\(name) abgebrochen"), p.rawValue, ok: true) }
            else { say(L("\(name) failed", "\(name) fehlgeschlagen"), m, ok: false) }
        case .skipped(let m): say(L("\(name) skipped", "\(name) übersprungen"), m, ok: true)
        default: break
        }
    }

    /// The end of a deploy: a Mac notification when the app is in the background, a line in the
    /// window in any case (the person may be looking at the other tab).
    struct Toast: Equatable {
        let id = UUID(); let text: String; let ok: Bool
        var undoLabel: String? = nil; var undo: (() -> Void)? = nil
        static func == (a: Toast, b: Toast) -> Bool { a.id == b.id }
    }
    /// One toast at a time. One with "Undo" is not pushed away by the next: those wait until it is gone.
    @Published var toast: Toast? {
        didSet { if toast == nil, !toastQueue.isEmpty { let next = toastQueue.removeFirst(); DispatchQueue.main.async { self.show(next) } } }
    }
    private var toastQueue: [Toast] = []
    func show(_ t: Toast) {
        // At most two wait behind "Undo"; older news is in `messages` anyway.
        if let cur = toast, cur.undo != nil, t.undo == nil { toastQueue = Array((toastQueue + [t]).suffix(2)); return }
        toast = t
        // "Undo" gets longer to be reached.
        let secs: UInt64 = t.undo == nil ? 5 : 10
        Task { try? await Task.sleep(nanoseconds: secs * 1_000_000_000); if toast == t { toast = nil } }
    }
    /// The last messages, newest first, so a line that vanished after 5 seconds can still be read.
    struct Message: Identifiable { let id = UUID(); let date: Date; let text: String; let ok: Bool }
    @Published var messages: [Message] = []
    private func say(_ title: String, _ body: String, ok: Bool) {
        Notify.post(title, body)
        show(Toast(text: title, ok: ok))
        messages.insert(Message(date: Date(), text: title + (body.isEmpty ? "" : " – " + body), ok: ok), at: 0)
        if messages.count > 30 { messages.removeLast() }
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
    /// Hide with a way back: the toast offers "Undo" for a few seconds.
    func hideWithUndo(_ i: Item) {
        toggleHidden(i)
        show(Toast(text: L("\(i.name) hidden", "\(i.name) ausgeblendet"), ok: true,
                   undoLabel: L("Undo", "Rückgängig"), undo: { [weak self] in self?.toggleHidden(i) }))
    }
    func unhide(_ key: String) {
        hidden.remove(key); UserDefaults.standard.set(Array(hidden), forKey: "hidden")
    }
    func setNote(_ i: Item, _ text: String) {
        let t = text.trimmingCharacters(in: .whitespacesAndNewlines)
        notes[Self.key(i)] = t.isEmpty ? nil : t
        UserDefaults.standard.set(notes, forKey: "notes")
    }

    // MARK: How many PRs waited, per day (the highest count seen that day), for 30 days.

    @Published var history: [String: Int] = (UserDefaults.standard.dictionary(forKey: "waitingHistory") as? [String: Int]) ?? [:]
    private func recordHistory() {
        let day = localDay()
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

    struct Job {
        let item: Item; var preview = false; var sha: String? = nil; var clearCache = false; var readyAt = Date.distantPast
        /// Only once the CI of the commit is green (waits up to 30 minutes for running checks).
        var whenGreen = false
        /// Why it goes out inside a closed deploy window; the script writes it to the journal.
        var force: String? = nil
    }
    private var queue: [Job] = []
    private var running = 0
    private var cancelled: Set<String> = []
    var maxParallel: Int { let n = UserDefaults.standard.integer(forKey: "maxParallel"); return n >= 1 ? n : 3 }

    func deploySelected(_ p: Platform, preview: Bool = false, whenGreen: Bool = false, force: String? = nil) {
        let chosen = selected(p)
        clearSelection(p)
        enqueue(chosen.map { Job(item: $0, preview: preview, whenGreen: whenGreen, force: force) })
    }

    /// Whether the deploy window (window.json) is closed now. Nil when the script could not say.
    func deployWindow() async -> WindowReply? {
        try? await Tool.json(["window", "--json"], as: WindowReply.self, timeout: 30)
    }

    func deployOne(_ item: Item, preview: Bool, sha: String? = nil, clearCache: Bool = false) {
        enqueue([Job(item: item, preview: preview, sha: sha, clearCache: clearCache)])
    }

    /// Seconds between the click and the first build; in this time "cancel" in the row still costs nothing.
    var undoSeconds: Int { UserDefaults.standard.object(forKey: "undoSeconds") as? Int ?? 8 }
    private var batch: [(Platform, String)] = []

    /// Starts that got no answer in time, by row: they may be building anyway (see `deploy`).
    private var unsureStarts: [String: Date] = [:]
    private static let unsureWait: Double = 600

    func enqueue(_ jobs: [Job]) {
        if observer {
            say(L("Observer mode", "Beobachter-Modus"), L("This Mac only looks. Turn it off in Settings → Team.", "Dieser Mac schaut nur zu. Abschalten unter Einstellungen → Team."), ok: false)
            return
        }
        Notify.ask()
        var added = 0
        for j in jobs where !(itemNow(j.item)?.state.isActive ?? false) {
            if let at = unsureStarts[Self.key(j.item)], Date().timeIntervalSince(at) < Self.unsureWait {
                let until = at.addingTimeInterval(Self.unsureWait).formatted(date: .omitted, time: .shortened)
                say(L("\(j.item.name) may be building already", "\(j.item.name) baut vielleicht schon"),
                    L("The last start got no answer. Check the dashboard; a new start is possible from \(until).",
                      "Der letzte Start blieb ohne Antwort. Im Dashboard nachsehen; neu starten geht ab \(until)."), ok: false)
                continue
            }
            set(j.item.platform, j.item.id, .queued)
            var j = j; j.readyAt = Date().addingTimeInterval(Double(undoSeconds))   // each job counts from its own click
            queue.append(j); batch.append((j.item.platform, j.item.id)); added += 1
        }
        if added > 0, undoSeconds > 0 {
            let n = undoSeconds
            show(Toast(text: L("Starting in \(n) s – cancel in the row to stop", "Startet in \(n) s – in der Zeile abbrechen"), ok: true))
            Task { try? await Task.sleep(nanoseconds: UInt64(n) * 1_000_000_000 + 300_000_000); pump() }
        }
        pump()
    }

    /// Stops everything that is queued or building.
    func cancelAll() { for i in Array(items.values.joined()) where i.state.isActive { cancel(i) } }

    private func summarize() {
        defer { batch = [] }
        guard batch.count >= 2 else { return }
        var ok = 0, bad = 0, stopped = 0
        for (p, id) in batch {
            guard let s = items[p]?.first(where: { $0.id == id })?.state else { continue }
            if case .done = s { ok += 1 }
            else if case .failed = s { if endedByCancel.contains(id) { stopped += 1 } else { bad += 1 } }
        }
        let title = stopped == 0 ? L("\(ok) live, \(bad) failed", "\(ok) live, \(bad) fehlgeschlagen")
            : L("\(ok) live, \(bad) failed, \(stopped) cancelled", "\(ok) live, \(bad) fehlgeschlagen, \(stopped) abgebrochen")
        say(title, L("Deploy run finished", "Deploy-Lauf beendet"), ok: bad == 0)
    }

    private func itemNow(_ i: Item) -> Item? { items[i.platform]?.first { $0.id == i.id } }
    private func clearPreview(_ i: Item) {
        if let k = items[i.platform]?.firstIndex(where: { $0.id == i.id }) { items[i.platform]![k].previewId = nil }
    }

    private func pump() {
        while running < maxParallel, let k = queue.firstIndex(where: { $0.readyAt <= Date() && waitsFor($0) == nil }) {
            let job = queue.remove(at: k)
            running += 1
            Task { await deploy(job); running -= 1; pump() }
        }
        // A frontend whose backend failed in this batch does not go out alone.
        for job in queue {
            let backend = waitsFor(job)
            if case .failed? = backend.flatMap({ itemNow($0)?.state }) {
                queue.removeAll { $0.item.id == job.item.id }
                // The person stopped the backend: the frontend simply does not go, it did not fail.
                if let b = backend, endedByCancel.contains(b.id) { set(job.item.platform, job.item.id, .idle); continue }
                set(job.item.platform, job.item.id, .failed(L("Not started: the backend of the same repo failed",
                                                             "Nicht gestartet: das Backend desselben Repos ist fehlgeschlagen")))
            }
        }
        if queue.isEmpty && running == 0 {
            queueBatch = []
            let hadRun = !batch.isEmpty
            summarize()
            // The row says "current" from what the app remembers; read what GitHub says now.
            if hadRun { Task { await autoRefresh() } }
        }
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
        guard let id = itemNow(item)?.deployId else {
            show(Toast(text: L("\(item.name) is still starting – try again in a moment", "\(item.name) startet noch – gleich nochmal versuchen"), ok: false))
            return
        }
        guard !cancelled.contains(item.id) else { return }
        // Following goes on until the platform says the deploy ended, so the row can never be
        // left "running" when the cancel fails or comes too late.
        cancelled.insert(item.id)
        let before = itemNow(item)?.state
        set(item.platform, item.id, .running(L("cancelling", "wird abgebrochen")))
        Task {
            let args = item.platform == .vercel ? ["vercel", "cancel", id] : ["render", "cancel", item.id, id]
            do { _ = try await Tool.run(args) }
            catch {
                cancelled.remove(item.id)
                if let before, itemNow(item)?.state == .running(L("cancelling", "wird abgebrochen")) { set(item.platform, item.id, before) }
                say(L("Could not cancel \(item.name)", "\(item.name) ließ sich nicht abbrechen"), error.localizedDescription, ok: false)
            }
        }
    }

    // MARK: The daily reminder: a notification at the chosen hour when something waits.
    // It reminds; it never deploys by itself.

    private func remindIfDue() {
        let d = UserDefaults.standard
        let hour = d.integer(forKey: "reminderHour")   // 0 = off
        guard hour > 0, Calendar.current.component(.hour, from: Date()) >= hour else { return }
        let today = localDay()
        guard d.string(forKey: "lastReminder") != today else { return }
        let w = waiting
        guard w.projects > 0 else { return }
        d.set(today, forKey: "lastReminder")
        Notify.remind(L("Time for the daily deploy", "Zeit für den täglichen Deploy"),
                      L("\(w.prs) PRs in \(w.projects) projects wait to go live.", "\(w.prs) PRs in \(w.projects) Projekten warten darauf, live zu gehen."))
    }

    // MARK: How long a build usually takes, per project (the last five)

    /// Read once; every row asks for it on each redraw.
    private lazy var durationsCache: [String: [Double]] = (UserDefaults.standard.dictionary(forKey: "durations") as? [String: [Double]]) ?? [:]
    private var durations: [String: [Double]] {
        get { durationsCache }
        set { durationsCache = newValue; UserDefaults.standard.set(newValue, forKey: "durations") }
    }
    func usualMinutes(_ i: Item) -> Int? {
        guard let d = durations[Self.key(i)], !d.isEmpty else { return nil }
        return max(1, Int((d.reduce(0, +) / Double(d.count) / 60).rounded()))
    }
    /// Build times of projects no longer in a (non-empty) list go. Notes, pins, hidden marks and
    /// health paths are the person's own and stay.
    private func pruneDurations(_ p: Platform, keeping fresh: [Item]) {
        guard !fresh.isEmpty else { return }
        let keep = Set(fresh.map(Self.key)), prefix = "\(p.cli)/"
        let gone = durations.keys.filter { $0.hasPrefix(prefix) && !keep.contains($0) }
        guard !gone.isEmpty else { return }
        var all = durations; gone.forEach { all[$0] = nil }; durations = all
    }
    private func recordDuration(_ i: Item) {
        guard let start = itemNow(i)?.startedAt else { return }
        var all = durations; var d = all[Self.key(i)] ?? []
        d.append(Date().timeIntervalSince(start)); all[Self.key(i)] = Array(d.suffix(5)); durations = all
    }

    /// After a rollback production is older than the branch: the project has changes again.
    private func markBehind(_ p: Platform, _ id: String) {
        guard let i = items[p]?.firstIndex(where: { $0.id == id }) else { return }
        items[p]![i].changed = true; items[p]![i].lastSha = nil
        items[p]![i].lastAt = Date()
    }

    /// Production back to what was live before.
    func rollback(_ item: Item) {
        Notify.ask()
        if let at = unsureStarts[Self.key(item)], Date().timeIntervalSince(at) < Self.unsureWait {
            say(L("\(item.name) may be busy already", "\(item.name) ist vielleicht schon beschäftigt"),
                L("The last start got no answer. Check the dashboard first.", "Der letzte Start blieb ohne Antwort. Erst im Dashboard nachsehen."), ok: false)
            return
        }
        clearPreview(item)
        Task {
            let p = item.platform
            set(p, item.id, .starting)
            do {
                let r = try await Tool.json([p.cli, "rollback", item.id], as: Started.self, timeout: 300)
                unsureStarts[Self.key(item)] = nil
                if p == .vercel { set(p, item.id, .done(item.link), countsAsLive: false); markBehind(p, item.id) }
                else {
                    // Kept, so the rollback can be cancelled like a deploy.
                    if let k = items[p]?.firstIndex(where: { $0.id == item.id }) { items[p]![k].deployId = r.id }
                    set(p, item.id, .running(L("rolling back", "rollt zurück")))
                    try await follow(item, deployId: r.id, url: item.link, rolledBack: true)
                }
            } catch let e as ToolError where e.timedOut {
                unsureStarts[Self.key(item)] = Date()
                set(p, item.id, .failed(L("No answer from the rollback – it may have happened anyway. Check the dashboard.",
                                          "Keine Antwort beim Zurückrollen – es ist vielleicht trotzdem passiert. Im Dashboard nachsehen.")))
            } catch { set(p, item.id, .failed(error.localizedDescription)) }
        }
    }

    private func deploy(_ job: Job) async {
        let item = job.item, p = item.platform
        if p == .render { queueBatch.insert(item.id) }
        set(p, item.id, .starting)
        cancelled.remove(item.id)
        clearPreview(item)   // an older preview must not be promoted over what this deploy brings
        do {
            var sha = job.sha
            if job.whenGreen && !job.preview {
                // The commit that is checked is the one that goes out: a newer push waits for the next deploy.
                guard let repo = item.repo, let commit = sha ?? item.headSha else {
                    set(p, item.id, .skipped(L("Checks unknown: no commit or repo known", "Checks unbekannt: kein Commit oder Repo bekannt"))); return
                }
                set(p, item.id, .running(L("waiting for checks", "wartet auf Checks")))
                let ci = try await Tool.json(["ci", repo, commit, "--wait", "30m", "--json"], as: CIReply.self, timeout: 32 * 60)
                switch ci.state {
                case "green", "none": sha = commit
                case "red":
                    set(p, item.id, .skipped(L("CI is red: ", "CI ist rot: ") + ci.reason)); return
                default:
                    set(p, item.id, .skipped(L("Checks not done after 30 minutes: ", "Checks nach 30 Minuten nicht fertig: ") + ci.reason)); return
                }
                set(p, item.id, .starting)
            }
            var args = [p.cli, "deploy-json", item.id]
            if job.preview { args.append("--preview") }
            if let sha { args += ["--sha", sha] }
            if job.clearCache { args.append("--clear-cache") }
            if let why = job.force { args += ["--force", why] }
            // Longer than a list read: a start that times out may have started anyway.
            let started = try await Tool.json(args, as: Started.self, timeout: 300)
            unsureStarts[Self.key(item)] = nil
            if let k = items[p]?.firstIndex(where: { $0.id == item.id }) { items[p]![k].deployId = started.id }
            set(p, item.id, .running(started.state ?? L("started", "gestartet")))
            try await follow(item, deployId: started.id, url: started.url, preview: job.preview)
        } catch let e as ToolError where e.timedOut {
            // No answer is not "not started": a second click right away could pay for two builds.
            // A fresh list says whether a build is under way; the wait below holds either way.
            unsureStarts[Self.key(item)] = Date()
            await load(p)
            set(p, item.id, .failed(itemNow(item)?.building == true
                ? L("No answer from the start, but a build is running – check the dashboard.",
                    "Keine Antwort beim Start, aber ein Build läuft – im Dashboard nachsehen.")
                : L("No answer from the start – it may be building anyway. Check the dashboard before starting again.",
                    "Keine Antwort beim Start – er baut vielleicht trotzdem. Vor einem neuen Start im Dashboard nachsehen.")))
        } catch {
            set(p, item.id, .failed(error.localizedDescription))
        }
        // pump() runs once this returns (see pump), not here as well.
    }

    /// Asks every 6 seconds until the deploy is live or failed (40 minutes at most).
    private func follow(_ item: Item, deployId: String, url: String?, preview: Bool = false, rolledBack: Bool = false) async throws {
        let p = item.platform
        defer { cancelled.remove(item.id) }   // however it ended, a later deploy can be cancelled again
        var misses = 0
        // A deadline, not a count of rounds: slow status answers must not stretch 40 minutes to hours.
        let deadline = Date().addingTimeInterval(40 * 60)
        while Date() < deadline {
            try await Task.sleep(nanoseconds: 6_000_000_000)
            let args = p == .vercel ? ["vercel", "status", deployId] : ["render", "status", item.id, deployId]
            guard let s = try? await Tool.json(args, as: StatusReply.self, timeout: 60) else {
                // Network or login gone: say so instead of spinning for 40 minutes without a word.
                misses += 1
                if misses >= 5 { set(p, item.id, .running(L("status unavailable, retrying", "Status nicht abrufbar, neuer Versuch"))) }
                continue
            }
            misses = 0
            let state = (s.state ?? "").lowercased()
            if state == "canceled", cancelled.remove(item.id) != nil {
                set(p, item.id, .failed(L("Cancelled", "Abgebrochen")), cancelled: true); return
            }
            switch (p, state) {
            case (.vercel, "ready"), (.render, "live"):
                if preview {
                    if let k = items[p]?.firstIndex(where: { $0.id == item.id }) { items[p]![k].previewId = deployId }
                    set(p, item.id, .done(s.url ?? url), countsAsLive: false)
                } else {
                    if rolledBack {
                        set(p, item.id, .done(item.link), countsAsLive: false); markBehind(p, item.id)
                    } else {
                        recordDuration(item)
                        set(p, item.id, .done(p == .vercel ? (item.link ?? s.url ?? url) : item.link))
                    }
                    if let l = item.link { Task { await checkSite(item, l.hasSuffix("/") ? String(l.dropLast()) + healthPath(item) : l + healthPath(item), mayRollBack: !rolledBack) } }
                }
                return
            case (.render, "succeeded"):
                set(p, item.id, .done(nil), countsAsLive: !rolledBack); return
            case (.vercel, "canceled"):
                // Usually the project's "Ignored Build Step" decided nothing changed.
                set(p, item.id, .skipped(L("Skipped or canceled by Vercel (Ignored Build Step?)",
                                          "Von Vercel übersprungen oder abgebrochen (Ignored Build Step?)"))); return
            case (.vercel, "error"), (.render, "build_failed"), (.render, "update_failed"),
                 (.render, "canceled"), (.render, "pre_deploy_failed"), (.render, "deactivated"):
                set(p, item.id, .failed(s.error ?? "Status: \(state)")); return
            default:
                if !Self.knownStates.contains(state), Self.loggedStates.insert(state).inserted {
                    Log.write("\(p.cli) status: unknown state \"\(state)\" for \(item.name), shown as it is")
                }
                if !cancelled.contains(item.id) { set(p, item.id, .running(Self.stateName(state))) }
            }
        }
        set(p, item.id, .failed(L("No result after 40 minutes – check the dashboard", "Kein Ergebnis nach 40 Minuten – im Dashboard nachsehen")))
    }

    /// A path to ask after going live instead of the front page (/health), per project. Kept on this Mac.
    private lazy var healthPaths: [String: String] = (UserDefaults.standard.dictionary(forKey: "healthPaths") as? [String: String]) ?? [:]
    func healthPath(_ i: Item) -> String { healthPaths[Self.key(i)].flatMap(Self.cleanPath) ?? "" }
    func setHealthPath(_ i: Item, _ path: String) {
        healthPaths[Self.key(i)] = Self.cleanPath(path)
        UserDefaults.standard.set(healthPaths, forKey: "healthPaths")
    }
    /// "/health", with a leading slash; spaces and other characters a URL cannot hold are encoded,
    /// so the check after going live is not silently skipped.
    nonisolated static func cleanPath(_ path: String) -> String? {
        let t = path.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !t.isEmpty else { return nil }
        let slashed = t.hasPrefix("/") ? t : "/" + t
        return slashed.removingPercentEncoding.flatMap { $0.addingPercentEncoding(withAllowedCharacters: .urlPathAllowed) } ?? slashed
    }

    /// After going live: does the site answer? A deploy can be "ready" and the page still broken.
    private func checkSite(_ item: Item, _ link: String, mayRollBack: Bool) async {
        let name = item.name
        guard let url = URL(string: link) else { return }
        var code: Int?
        // A fresh Render service can answer 502/503 for a few seconds: ask up to three times.
        for attempt in 0..<3 {
            var req = URLRequest(url: url, timeoutInterval: 20)
            req.setValue("DeployCenter (post-deploy check)", forHTTPHeaderField: "User-Agent")
            // Only the status is needed: stop reading once the headers are in.
            if let (bytes, resp) = try? await URLSession.shared.bytes(for: req) {
                code = (resp as? HTTPURLResponse)?.statusCode; bytes.task.cancel()
            } else { code = nil }
            // 401/403: the site answers but is protected (Deployment Protection, login) — not broken.
            if let c = code, c < 400 || c == 401 || c == 403 { return }
            if attempt < 2 { try? await Task.sleep(nanoseconds: 6_000_000_000) }
        }
        // A 5xx or no answer at all is broken; a 404 may only be a wrong path, so it is not rolled back.
        if mayRollBack, rollsBack(item), code.map({ $0 >= 500 }) ?? true { countDownToRollback(item, link, code); return }
        say(L("\(name) is live, but the site answers \(code.map(String.init) ?? "nothing")",
              "\(name) ist live, aber die Seite antwortet mit \(code.map(String.init) ?? "nichts")"), link, ok: false)
    }

    // MARK: Roll back by itself when the check after going live fails (opt-in per project, in the details)

    @Published private(set) var autoRollback: Set<String> = Set(UserDefaults.standard.stringArray(forKey: "autoRollback") ?? [])
    func rollsBack(_ i: Item) -> Bool { autoRollback.contains(Self.key(i)) }
    func setRollsBack(_ i: Item, _ on: Bool) {
        if on { autoRollback.insert(Self.key(i)) } else { autoRollback.remove(Self.key(i)) }
        UserDefaults.standard.set(Array(autoRollback), forKey: "autoRollback")
    }
    private var rollbackCountdowns: [String: Task<Void, Never>] = [:]
    static let rollbackSeconds = 10
    nonisolated static let rollbackPrefix = "rollback|"

    /// Ten seconds to say no, in a notification and a toast, then production goes back.
    private func countDownToRollback(_ item: Item, _ link: String, _ code: Int?) {
        let key = Self.key(item), id = Self.rollbackPrefix + key, n = Self.rollbackSeconds
        guard rollbackCountdowns[key] == nil else { return }
        let title = L("\(item.name) fails its check – rolling back in \(n) s", "\(item.name) besteht den Check nicht – Zurückrollen in \(n) s")
        Notify.countdown(title, link + " → " + (code.map(String.init) ?? L("no answer", "keine Antwort")), id: id)
        show(Toast(text: title, ok: false, undoLabel: L("Cancel", "Abbrechen"), undo: { [weak self] in self?.cancelRollback(key) }))
        messages.insert(Message(date: Date(), text: title + " – " + link, ok: false), at: 0)
        rollbackCountdowns[key] = Task { [weak self] in
            try? await Task.sleep(nanoseconds: UInt64(n) * 1_000_000_000)
            guard !Task.isCancelled, let self, self.rollbackCountdowns.removeValue(forKey: key) != nil else { return }
            Notify.remove(id)
            self.rollback(self.itemNow(item) ?? item)
        }
    }
    func cancelRollback(_ key: String) {
        guard let t = rollbackCountdowns.removeValue(forKey: key) else { return }
        t.cancel(); Notify.remove(Self.rollbackPrefix + key)
        say(L("Rollback cancelled", "Zurückrollen abgebrochen"), L("The new deploy stays live.", "Der neue Deploy bleibt live."), ok: true)
    }

    // MARK: Updates come from Sparkle (SoftwareUpdate.swift); it asks this before it restarts the app.

    /// Deploys queued or building; an update waits for them instead of quitting in the middle.
    var deploysBusy: Bool { !queue.isEmpty || running > 0 || items.values.joined().contains { $0.state.isActive } }

    /// States the app knows; any other is shown as the platform sent it, and logged once.
    static let knownStates: Set<String> = ["", "queued", "created", "initializing", "building", "build_in_progress",
                                           "update_in_progress", "pre_deploy_in_progress"]
    private static var loggedStates: Set<String> = []
    static func stateName(_ s: String) -> String {
        switch s {
        case "queued", "created", "initializing": return L("queued", "wartet")
        case "building", "build_in_progress": return L("building", "baut")
        case "update_in_progress", "pre_deploy_in_progress": return L("going live", "geht live")
        default: return s.isEmpty ? L("running", "läuft") : s
        }
    }
}
