// Deploy Center — The state of the app: lists, deploys and their queue, costs, the person's marks.

import SwiftUI
import AppKit

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
    /// `deploys --version`, read once, for "Copy diagnostics".
    @Published var scriptVersion: String?
    @Published var costs: Costs?
    @Published var triggers: [Trigger] = []
    /// The platforms `deploys providers --json` reports (Vercel and Render without it), see Providers.swift.
    @Published var providers: [ProviderInfo] = ProviderInfo.builtIn
    @Published var providersFromScript = false

    /// Costs and stray build triggers load after the lists; neither blocks deploying.
    private var lastExtras = Date.distantPast
    /// When a part last failed to load; the values from before stay and count as out of date.
    @Published var extrasFailedAt: [String: Date] = [:]
    /// When a part ("costs", "triggers") was last read fine: shown as "as of …" while a newer read fails.
    @Published var extrasLoadedAt: [String: Date] = [:]
    /// "As of 09:12" for a part whose last read failed and whose values are older; nil while it is current.
    func staleNote(_ part: String) -> String? {
        guard extrasFailedAt[part] != nil else { return nil }
        guard let at = extrasLoadedAt[part] else { return L("Could not be read", "Ließ sich nicht lesen") }
        return L("As of ", "Stand ") + at.formatted(Calendar.current.isDateInToday(at) ? .dateTime.hour().minute() : .dateTime.day().month().hour().minute())
    }
    func loadExtras() async {
        lastExtras = Date()
        Task { await checkProviders() }
        // Being added to (or taken off) a repo's observers list must not wait for Settings > Team.
        Task { await readTeamObserver() }
        // All three at once; each can take a minute (many API calls). A failure keeps the old values.
        let vercel = doctor?.vercelLoggedIn == true, github = doctor?.githubLoggedIn == true
        async let c = vercel ? Self.extra(["costs", "14"], Costs.self) : nil
        async let t = Self.extra(["triggers"], [Trigger].self)
        async let b = github ? Self.extra(["github-budget"], Budget.self) : nil
        if let r = await c { if case .success(let v) = r { costs = v; checkBudget(); writeSnapshot() }; note("costs", r) }
        if let r = await t { if case .success(let v) = r { triggers = v }; note("triggers", r) }
        if let r = await b { if case .success(let v) = r { githubBudget = v; reloadWhenBudgetResets(v) }; note("github-budget", r) }
    }

    /// The GitHub budget is (nearly) spent: one reload shortly after it resets, so the counts come
    /// back without a click. Once per reset time, so a budget still low afterwards cannot loop.
    private var budgetReloadFor: Double?
    private func reloadWhenBudgetResets(_ b: Budget, now: Date = Date()) {
        guard let wait = Self.budgetReloadDelay(b, now: now), budgetReloadFor != b.reset else { return }
        budgetReloadFor = b.reset
        Task { [weak self] in
            try? await Task.sleep(nanoseconds: UInt64(wait * 1_000_000_000))
            guard let self, !self.screensAsleep else { return }
            // The counts are what is missing: read the budget again, then the lists.
            self.lastExtras = .distantPast
            await self.autoRefresh()
        }
    }
    /// Seconds until a reload after the reset (30 s later), or nil: budget not low, or the reset is
    /// past or more than an hour away (a wrong clock).
    nonisolated static func budgetReloadDelay(_ b: Budget, now: Date = Date()) -> Double? {
        guard b.remaining < 300 else { return nil }
        let wait = b.reset - now.timeIntervalSince1970 + 30
        return wait > 0 && wait <= 3630 ? wait : nil
    }
    /// Only the observer flag of `config --json`, so a field the rest of Settings > Team needs cannot stop it.
    private struct ReadonlyFlag: Decodable { struct Flag: Decodable { let value: Bool }; let readonly: Flag? }
    func readTeamObserver() async {
        if let t = try? await Tool.json(["config", "--json"], as: ReadonlyFlag.self, timeout: 60), let f = t.readonly { teamObserver = f.value }
    }
    nonisolated private static func extra<T: Decodable & Sendable>(_ args: [String], _ type: T.Type) async -> Result<T, Error>? {
        do { return .success(try await Tool.json(args, as: T.self, timeout: 300)) } catch { return .failure(error) }
    }
    private func note<T>(_ name: String, _ r: Result<T, Error>) {
        switch r {
        case .success: extrasFailedAt[name] = nil; extrasLoadedAt[name] = Date()
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
            i.hasNewCommits && i.state == .idle && i.deployable && !isHidden(i)
                && (i.oldestPendingAt.map { Date().timeIntervalSince($0) > Double(days) * 86400 } ?? false)
        }
        guard !old.isEmpty else { return }
        d.set(today, forKey: "lastStaleAlarm")
        let n = old.count
        say(L("\(plural(n, "project waits", "projects wait")) for more than \(days) days",
              "\(plural(n, "Projekt wartet", "Projekte warten")) schon über \(days) Tage"),
            old.prefix(5).map(\.name).joined(separator: ", "), ok: false)
    }

    /// "Place 2 of 5" for a queued row; nil when it is alone.
    func queueText(_ i: Item) -> String? {
        guard queue.count > 1, let k = queue.firstIndex(where: { $0.item.id == i.id }) else { return nil }
        return L("place \(k + 1) of \(queue.count)", "Platz \(k + 1) von \(queue.count)")
    }

    /// Build costs a month at the pace of the last 7 whole days. Today is not over yet: half a day
    /// of builds would pull the pace down (billing days are UTC, like `today`).
    nonisolated static func monthPace(_ days: [Costs.Day], today: String) -> Double? {
        let whole = days.filter { $0.day < today }.suffix(7)
        guard !whole.isEmpty else { return nil }
        return whole.map(\.build).reduce(0, +) / Double(whole.count) * 30
    }

    /// Once a day: if the pace of the last 7 days passes 80 % of the monthly budget (Settings), say so.
    private func checkBudget() {
        let d = UserDefaults.standard
        let budget = d.double(forKey: "monthlyBudget")
        guard budget > 0, let days = costs?.days, let month = Self.monthPace(days, today: CostsSheet.today()) else { return }
        let today = localDay()
        guard month > budget * 0.8, d.string(forKey: "lastBudgetAlarm") != today else { return }
        d.set(today, forKey: "lastBudgetAlarm")
        let m = month.formatted(.currency(code: "USD")), b = budget.formatted(.currency(code: "USD"))
        say(L("Build costs near your budget", "Build-Kosten nahe am Budget"),
            L("At this pace ≈ \(m) a month, budget \(b)", "Bei diesem Tempo ≈ \(m) im Monat, Budget \(b)"), ok: false)
    }

    /// Outages at the platforms that are on and at GitHub: a failing deploy may not be the project's fault.
    @Published var providerIssues: [String] = []
    /// The status pages the banner links to: one per platform that is on, then GitHub.
    var statusLinks: [(label: String, url: URL)] {
        enabledProviders.compactMap { p in p.statusURL.map { (p.label, $0) } }
            + ProviderInfo.gitHosts.compactMap { g in URL(string: g.page).map { (g.label, $0) } }
    }
    func checkProviders() async {
        let feeds = enabledProviders.compactMap { p in p.statusFeed.map { (p.label, $0.absoluteString) } }
            + ProviderInfo.gitHosts.map { ($0.label, $0.feed) }
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
            // A failure is logged and marked, so a "fixing" that does not move has a reason somewhere.
            do { _ = try await Tool.run(["autofix", "sync"], timeout: 90); extrasFailedAt["autofix-sync"] = nil }
            catch is CancellationError {}
            catch { extrasFailedAt["autofix-sync"] = Date(); Log.write("autofix sync: \(error.localizedDescription)") }
        }
        async let a = Self.extra(["autofix", "status", "--json"], AutofixReport.self)
        async let g = Self.extra(["guard", "status", "--json"], AllowanceReport.self)
        // A script without these commands: nothing is shown, nothing is said.
        if case .success(let r)? = await a { autofix = r; preselectMergedFixes() }
        // A failure keeps the last allowances: their badge warns about costs.
        if case .success(let r)? = await g { allowances = r.allowances }
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
        guard !observer else { return }   // nothing to deploy from this Mac
        let d = UserDefaults.standard
        var seen = d.stringArray(forKey: "autofixPreselected") ?? []
        var current = Set<String>()
        for p in Platform.allCases {
            for k in (items[p] ?? []).indices {
                let i = items[p]![k]
                guard case .merged(let sha, _, _)? = autofixState(i), i.deployable, !i.state.isActive, !isHidden(i) else { continue }
                let key = RowAutofix.preselectKey(i, sha: sha)
                current.insert(key)
                if seen.contains(key) { continue }
                seen.append(key); items[p]![k].selected = true
            }
        }
        d.set(Self.keepPreselected(seen, current: current), forKey: "autofixPreselected")
    }
    /// The last 100 keys, and always those of rows still showing a merged fix, so one is not ticked again.
    nonisolated static func keepPreselected(_ seen: [String], current: Set<String>) -> [String] {
        let recent = Set(seen.suffix(100))
        return seen.filter { recent.contains($0) || current.contains($0) }
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
            if Self.autofixNotSetUp(error) { offerAutofixSetup(); return }
            tell(L("\(name): not handed to Claude", "\(name): nicht an Claude übergeben"), msg, ok: false, key: key)
        }
        await loadAgentStatus()
    }

    /// `autofix --only` exits 5 without a routine or its token; the text is only the fallback of an older script.
    nonisolated static func autofixNotSetUp(_ error: Error) -> Bool {
        if let e = error as? ToolError, e.exitCode == 5 { return true }
        return error.localizedDescription.localizedCaseInsensitiveContains("no routine")
    }

    /// A toast and a line in the messages, names scrubbed in demo mode.
    private func tell(_ title: String, _ body: String, ok: Bool, key: String) {
        let b = Demo.scrub(body, items: Array(items.values.joined()))
        let text = title + (b.isEmpty ? "" : " – " + b)
        show(Toast(text: text, ok: ok))
        let m = Message(date: Date(), text: text, ok: ok, project: key)
        messages.insert(m, at: 0); autofixResult[key] = m
    }

    private func offerAutofixSetup() {
        show(Toast(text: L("Autofix is not set up: no routine yet", "Autofix ist nicht eingerichtet: noch keine Routine"), ok: false,
                   undoLabel: L("Open Settings", "Einstellungen öffnen"), undo: { [weak self] in
            self?.openSettings(.claude, anchor: "autofix")
        }))
    }

    /// A tab of Settings (and a part of it) to open; the main window opens it with SwiftUI's
    /// `openSettings`, see ContentView. No private selector.
    @Published var settingsRequest: SettingsTab?
    func openSettings(_ tab: SettingsTab, anchor: String? = nil) {
        SettingsNav.prepare(tab, anchor: anchor)
        NSApp.activate(ignoringOtherApps: true)
        settingsRequest = tab
        // No main window to take it (menu bar only): the app menu's own Settings item (⌘,) is clicked.
        Task { [weak self] in
            try? await Task.sleep(nanoseconds: 400_000_000)
            guard let self, self.settingsRequest != nil else { return }
            self.settingsRequest = nil
            Self.clickSettingsMenuItem()
        }
    }
    private static func clickSettingsMenuItem() {
        guard let menu = NSApp.mainMenu?.items.first?.submenu,
              let k = menu.items.firstIndex(where: { $0.keyEquivalent == "," && $0.keyEquivalentModifierMask == .command }) else { return }
        menu.performActionForItem(at: k)
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

    nonisolated static let cacheDir: URL = AppDirs.caches
    private func cacheURL(_ p: Platform) -> URL { Self.cacheDir.appendingPathComponent("\(p.cli)-v2.json") }

    private func readCache() {
        // Not the copy of a platform switched off at the last start (the provider list comes later).
        let off = Set(UserDefaults.standard.stringArray(forKey: "disabledProviders") ?? [])
        for p in Platform.allCases where !off.contains(p.cli) {
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
        NSWorkspace.shared.notificationCenter.addObserver(forName: NSWorkspace.screensDidSleepNotification, object: nil, queue: .main) { [weak self] _ in
            Task { @MainActor in self?.screensAsleep = true }
        }
        NSWorkspace.shared.notificationCenter.addObserver(forName: NSWorkspace.screensDidWakeNotification, object: nil, queue: .main) { [weak self] _ in
            Task { @MainActor in
                guard let self, self.screensAsleep else { return }
                self.screensAsleep = false
                await self.autoRefresh(); self.remindIfDue()
            }
        }
        NSWorkspace.shared.notificationCenter.addObserver(forName: NSWorkspace.didWakeNotification, object: nil, queue: .main) { [weak self] _ in
            Task { @MainActor in
                try? await Task.sleep(nanoseconds: 5_000_000_000)   // the network needs a moment
                await self?.autoRefresh(); self?.remindIfDue()
            }
        }
        // More builds at once in Settings: start what waits now, not when a running deploy ends.
        knownParallel = maxParallel
        NotificationCenter.default.addObserver(forName: UserDefaults.didChangeNotification, object: nil, queue: .main) { [weak self] _ in
            Task { @MainActor in
                guard let self, self.maxParallel != self.knownParallel else { return }
                self.knownParallel = self.maxParallel; self.pump()
            }
        }
        Task {
            await start()
            // Short naps, so a new interval in Settings counts at once and not after the old one ran out.
            var last = Date()
            while !Task.isCancelled {
                try? await Task.sleep(nanoseconds: 60_000_000_000)
                // Screens asleep: nobody looks; one round when they wake (below). Low Power Mode: half as often.
                guard !screensAsleep,
                      Self.refreshDue(since: last, minutes: refreshMinutes * (ProcessInfo.processInfo.isLowPowerModeEnabled ? 2 : 1)) else { continue }
                last = Date()
                await autoRefresh()
                remindIfDue()
            }
        }
    }
    nonisolated static func refreshDue(since last: Date, minutes: Int, now: Date = Date()) -> Bool {
        now.timeIntervalSince(last) >= Double(minutes) * 60
    }

    private var knownParallel = 0
    private var screensAsleep = false

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
        Task { await readTeamObserver() }
        if scriptVersion == nil {
            Task { if let v = try? await Tool.run(["--version"], timeout: 10) {
                scriptVersion = String(decoding: v, as: UTF8.self).trimmingCharacters(in: .whitespacesAndNewlines) } }
        }
        await loadProviders()
        // Both at once: each takes several seconds. A platform switched off in Settings is not read.
        let v = canLoad(.vercel), r = canLoad(.render)
        async let a: Void = v ? load(.vercel) : ()
        async let b: Void = r ? load(.render) : ()
        _ = await (a, b)
        await loadAgentStatus()
        await loadExtras()
    }

    /// The same rule for the start and every reload: logged in, with API access, and switched on.
    func canLoad(_ p: Platform) -> Bool {
        guard let d = doctor, isEnabled(p) else { return false }
        return p == .vercel ? d.vercelLoggedIn && d.vercelApi : d.renderKey
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
            if Self.isAuthFailure(error.localizedDescription) { Task { await recheckDoctor() } }
        }
    }

    /// A login or key that was fine at the start and has run out since: the script says
    /// "HTTP 401/403", "wrong or expired" or "not logged in".
    nonisolated static func isAuthFailure(_ text: String) -> Bool {
        let t = text.lowercased()
        return ["http 401", "http 403", "wrong or expired", "not logged in", "vercel login", "bad credentials"].contains { t.contains($0) }
    }
    /// After a load failed for its login: the doctor again, so the setup view appears. One at a
    /// time and at most every 5 minutes, since both platforms can fail at once.
    private var lastAuthDoctor = Date.distantPast
    private func recheckDoctor() async {
        guard Date().timeIntervalSince(lastAuthDoctor) > 300 else { return }
        lastAuthDoctor = Date()
        if let fresh = try? await Tool.json(["doctor"], as: Doctor.self, timeout: 60) { doctor = fresh; doctorError = nil; lastDoctor = Date() }
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
                    Item(v, id: v.name,
                         detail: v.repo.map { "\($0) · \(v.ref ?? "main")" } ?? L("no Git repository", "kein Git-Repo"),
                         platform: .vercel,
                         note: v.auto ? L("deploys on every push", "deployt bei jedem Push")
                             : (v.deployable ? nil : L("repo unknown", "Repo unbekannt")),
                         link: v.domain.map { "https://\($0)" })
                }
            case .render:
                let list = try decodeLossy(RenderService.self, from: data, label: "render json")
                return list.map { r in
                    Item(r, id: r.id,
                         detail: Self.typeName(r.type) + (r.repo.map { " · \($0) · \(r.ref ?? "main")" } ?? ""),
                         platform: .render,
                         note: r.paused ? L("suspended", "pausiert")
                             : (r.auto ? L("deploys on every push", "deployt bei jedem Push") : nil),
                         link: r.url, kind: r.type)
                }
            }
    }

    /// Lists only, both platforms; costs and triggers cost many GitHub calls and stay manual.
    /// Not while something is deploying, so nothing being followed is disturbed.
    private var lastDoctor = Date()
    /// The wake handler and the loop can both call `autoRefresh`; `loading` is set only after the
    /// doctor's await, so this flag keeps a second round from starting meanwhile.
    private var refreshInFlight = false
    func autoRefresh() async {
        guard loading.isEmpty, !refreshInFlight else { return }
        refreshInFlight = true; defer { refreshInFlight = false }
        if doctor == nil { await start(); return }
        // Something was missing (a login, the Render key): ask again, at most every 30 minutes.
        if let d = doctor, !(d.vercelLoggedIn && d.vercelApi && d.renderKey && d.githubLoggedIn != false),
           Date().timeIntervalSince(lastDoctor) > 1800 {
            lastDoctor = Date()
            if let fresh = try? await Tool.json(["doctor"], as: Doctor.self, timeout: 60) { doctor = fresh; doctorError = nil }
        }
        // Only the platform with a deploy under way is left alone; the other one stays current.
        let v = canLoad(.vercel) && !(items[.vercel] ?? []).contains { $0.state.isActive }
        let r = canLoad(.render) && !(items[.render] ?? []).contains { $0.state.isActive }
        async let a: Void = v ? load(.vercel) : ()
        async let b: Void = r ? load(.render) : ()
        _ = await (a, b)
        await loadAgentStatus()
        // Costs and strays cost many calls: hourly. The status feeds are cheap: every time.
        // In Low Power Mode costs and strays wait (many calls); the status feeds stay.
        if Date().timeIntervalSince(lastExtras) > 3600, !ProcessInfo.processInfo.isLowPowerModeEnabled { await loadExtras() } else { await checkProviders() }
    }

    // MARK: What is waiting on GitHub, over both platforms

    struct Waiting { var projects = 0, commits = 0, prs = 0, openPRs = 0 }
    var waiting: Waiting {
        var w = Waiting()
        let all = Array(items.values.joined())
        // Projects of one repo (frontend + backend) share their commits and PRs: count them once.
        // Keyed by repo and branch: staging on `develop` and production on `main` wait for different commits.
        var perRepo: [String: (commits: Int, prs: Int)] = [:]
        // What the person hid, or what the app cannot deploy, is not waiting on them.
        for i in all where i.hasNewCommits && i.state == .idle && i.deployable && !isHidden(i) {
            w.projects += 1
            if let r = i.repo {
                let key = r + "#" + (i.ref ?? "main")   // no branch named: the default, as the row shows
                let o = perRepo[key] ?? (0, 0)
                perRepo[key] = (max(o.commits, i.pendingCommits ?? 0), max(o.prs, i.pendingPRs ?? 0))
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

    nonisolated static func typeName(_ t: String) -> String {
        switch t {
        case "web_service": return L("Web Service", "Webdienst")
        case "static_site": return L("Static Site", "Statische Seite")
        case "cron_job": return L("Cron Job", "Cronjob")
        case "background_worker": return L("Worker", "Hintergrunddienst")
        case "private_service": return L("Private Service", "Privater Dienst")
        default: return t.replacingOccurrences(of: "_", with: " ")
        }
    }

    func selected(_ p: Platform) -> [Item] { (items[p] ?? []).filter { $0.selected } }
    func autoOn(_ p: Platform) -> [Item] { (items[p] ?? []).filter { $0.auto } }
    /// Projects with changes on a platform, without the hidden ones: the list and `waiting` leave them out too.
    func changedCount(_ p: Platform) -> Int { (items[p] ?? []).filter { $0.deployable && $0.hasNewCommits && !isHidden($0) }.count }

    func toggle(_ p: Platform, _ id: String) {
        guard let i = items[p]?.firstIndex(where: { $0.id == id }), items[p]![i].deployable else { return }
        items[p]![i].selected.toggle()
    }

    func clearSelection(_ p: Platform) {
        for i in (items[p] ?? []).indices { items[p]![i].selected = false }
    }

    /// Ticks what has changes; never a hidden project. `only`: just these rows (`Store.key`), e.g. the ones on screen.
    func selectChanged(_ p: Platform, only keys: Set<String>? = nil) {
        for i in (items[p] ?? []).indices where items[p]![i].deployable && items[p]![i].hasNewCommits && !items[p]![i].state.isActive
            && !isHidden(items[p]![i]) && keys.map({ $0.contains(Self.key(items[p]![i])) }) ?? true {
            items[p]![i].selected = true
        }
    }

    func turnOffAutoDeploy(_ p: Platform) async {
        busyMessage = L("Turning off auto-deploy …", "Schalte Auto-Deploy aus …")
        defer { busyMessage = nil }
        var failure: String?
        do { _ = try await Tool.run([p.cli, "autodeploy-off", "--all"]) }
        catch { failure = error.localizedDescription }
        await load(p)
        // After the reload, which clears `loadError`: otherwise the error would never be seen.
        if let failure {
            say(L("Auto-deploy not turned off", "Auto-Deploy nicht ausgeschaltet"), failure, ok: false)
        }
    }

    func saveRenderKey(_ key: String) async -> String? {
        do {
            _ = try await Tool.run(["render", "set-key"], stdin: key.trimmingCharacters(in: .whitespacesAndNewlines))
            // A failed check keeps the last answer: nil would mean "not set up" and a fresh start.
            if let fresh = try? await Tool.json(["doctor"], as: Doctor.self) { doctor = fresh }
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
        holdAwake()
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
        let name = items[p]![i].name, rowKey = Self.key(items[p]![i])
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
            if countsAsLive { say(L("\(name) is live", "\(name) ist live"), p.rawValue, ok: true, project: rowKey) }
            else if items[p]![i].previewId != nil { say(L("\(name): preview is ready", "\(name): Vorschau ist fertig"), p.rawValue, ok: true, project: rowKey) }
            else { say(L("\(name) rolled back", "\(name) zurückgerollt"), p.rawValue, ok: true, project: rowKey) }
        case .failed(let m):
            if byPerson { say(L("\(name) cancelled", "\(name) abgebrochen"), p.rawValue, ok: true, project: rowKey) }
            else { say(L("\(name) failed", "\(name) fehlgeschlagen"), m, ok: false, project: rowKey) }
        case .skipped(let m): say(L("\(name) skipped", "\(name) übersprungen"), m, ok: true, project: rowKey)
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
    /// Another "Undo" waits too, so its button (a rollback's Cancel, say) is never lost.
    @Published var toast: Toast? {
        didSet { if toast == nil, !toastQueue.isEmpty { let next = toastQueue.removeFirst(); DispatchQueue.main.async { self.show(next) } } }
    }
    private var toastQueue: [Toast] = []
    /// At most two plain toasts wait behind "Undo" (older news is in `messages` anyway); every "Undo" waits.
    nonisolated static func queued(_ q: [Toast], _ t: Toast) -> [Toast] {
        var q = q + [t]
        while q.filter({ $0.undo == nil }).count > 2, let k = q.firstIndex(where: { $0.undo == nil }) { q.remove(at: k) }
        return q
    }
    func show(_ t: Toast) {
        if let cur = toast, cur.undo != nil { toastQueue = Self.queued(toastQueue, t); return }
        toast = t
        // "Undo" gets longer to be reached.
        let secs: UInt64 = t.undo == nil ? 5 : 10
        Task { try? await Task.sleep(nanoseconds: secs * 1_000_000_000); if toast == t { toast = nil } }
    }
    /// The last messages, newest first, so a line that vanished after 5 seconds can still be read.
    /// `project` is the row's `Store.key` when the line is about one project: a click opens its log.
    struct Message: Identifiable, Codable {
        var id = UUID(); let date: Date; let text: String; let ok: Bool; var project: String? = nil
        init(date: Date, text: String, ok: Bool, project: String? = nil) { self.date = date; self.text = text; self.ok = ok; self.project = project }
        private enum CodingKeys: String, CodingKey { case date, text, ok, project }
    }
    /// Kept in Application Support, so the bell is not empty after an update or a language switch.
    /// At most 30, also for lines added without `say` (a rollback countdown).
    @Published var messages: [Message] = Store.readMessages() {
        didSet {
            if messages.count > 30 { messages = Array(messages.prefix(30)) }   // no second didSet: written below
            Self.writeMessages(messages)
        }
    }
    nonisolated static var messagesURL: URL { AppDirs.support.appendingPathComponent("messages.json") }
    nonisolated static func readMessages() -> [Message] {
        guard let d = try? Data(contentsOf: messagesURL) else { return [] }
        let dec = JSONDecoder(); dec.dateDecodingStrategy = .iso8601
        return Array(((try? dec.decode([Message].self, from: d)) ?? []).prefix(30))
    }
    /// In order: the newest list is the one that stays on disk.
    nonisolated private static let messageQueue = DispatchQueue(label: "app.deploycenter.messages", qos: .utility)
    /// Waits until every list handed to `writeMessages` is on disk (tests).
    nonisolated static func flushMessages() { messageQueue.sync {} }
    nonisolated static func writeMessages(_ list: [Message]) {
        let enc = JSONEncoder(); enc.dateEncodingStrategy = .iso8601
        guard let d = try? enc.encode(list) else { return }
        messageQueue.async {
            try? FileManager.default.createDirectory(at: AppDirs.support, withIntermediateDirectories: true)
            try? d.write(to: messagesURL, options: .atomic)
        }
    }
    /// Names scrubbed in demo mode: a Mac notification shows up in a screen recording too.
    private func say(_ title: String, _ body: String, ok: Bool, project: String? = nil) {
        let all = Array(items.values.joined())
        let title = Demo.scrub(title, items: all), body = Demo.scrub(body, items: all)
        Notify.post(title, body)
        show(Toast(text: title, ok: ok))
        messages.insert(Message(date: Date(), text: title + (body.isEmpty ? "" : " – " + body), ok: ok, project: project), at: 0)
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

    /// Set by the menu bar or a `deploycenter://select` link: the window shows exactly this project.
    @Published var pendingShow: ShowRequest?
    /// One project to show: `key` (`Store.key`) when it is known, else every project of that name.
    struct ShowRequest: Equatable { let name: String; let key: String? }
    /// What a link's `project=` value points at: `platform:name` or a bare name. A bare name on two
    /// platforms (or one not loaded yet) shows every project of that name. Nothing is ticked or started.
    nonisolated static func showRequest(_ value: String, items: [Item]) -> ShowRequest? {
        let v = value.trimmingCharacters(in: .whitespaces)
        guard !v.isEmpty else { return nil }
        var name = v, platform: String?
        if let c = v.firstIndex(of: ":"), Platform.allCases.contains(where: { $0.cli == v[..<c].lowercased() }) {
            platform = v[..<c].lowercased(); name = String(v[v.index(after: c)...])
        }
        let hits = items.filter { $0.name == name && (platform == nil || $0.platform.cli == platform) }
        return ShowRequest(name: name, key: hits.count == 1 ? "\(hits[0].platform.cli)/\(hits[0].id)" : nil)   // = Store.key
    }
    func show(_ i: Item) { pendingShow = ShowRequest(name: i.name, key: Self.key(i)) }
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
        let chosen = selected(p).filter { !isHidden($0) }   // a hidden project never goes out with the others
        // Observer mode refuses in enqueue; the ticks stay, so nothing is lost without a deploy.
        guard !refusedAsObserver() else { return }
        clearSelection(p)
        enqueue(chosen.map { Job(item: $0, preview: preview, whenGreen: whenGreen, force: force) })
    }

    /// Whether the deploy window (window.json) is closed now. Nil when the script could not say.
    func deployWindow() async -> WindowReply? {
        try? await Tool.json(["window", "--json"], as: WindowReply.self, timeout: 30)
    }

    func deployOne(_ item: Item, preview: Bool, sha: String? = nil, clearCache: Bool = false, whenGreen: Bool = false, force: String? = nil) {
        enqueue([Job(item: item, preview: preview, sha: sha, clearCache: clearCache, whenGreen: whenGreen, force: force)])
    }
    /// Set by the palette: one project to deploy; the window asks about the deploy window like for a row.
    @Published var pendingDeploy: Item?

    /// Seconds between the click and the first build; in this time "cancel" in the row still costs nothing.
    var undoSeconds: Int { UserDefaults.standard.object(forKey: "undoSeconds") as? Int ?? 8 }
    private var batch: [(Platform, String)] = []

    /// Starts that got no answer in time, by row: they may be building anyway (see `deploy`).
    private var unsureStarts: [String: Date] = [:]
    private static let unsureWait: Double = 600

    /// Observer mode: says so and is true; deploys and rollbacks then start nothing.
    private func refusedAsObserver() -> Bool {
        guard observer else { return false }
        say(L("Observer mode", "Beobachter-Modus"), L("This Mac only looks. Turn it off in Settings → Team.", "Dieser Mac schaut nur zu. Abschalten unter Einstellungen → Team."), ok: false)
        return true
    }

    func enqueue(_ jobs: [Job]) {
        guard !refusedAsObserver() else { return }
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
        let states = batch.compactMap { (p, id) in items[p]?.first(where: { $0.id == id }).map { ($0.state, endedByCancel.contains(id)) } }
        let r = Self.summary(states)
        say(r.title, L("Deploy run finished", "Deploy-Lauf beendet"), ok: r.ok)
    }
    /// "5 live, 1 failed, 3 skipped": every way a row of the run ended, so none is left out of the sum.
    nonisolated static func summary(_ states: [(RunState, cancelled: Bool)]) -> (title: String, ok: Bool) {
        var ok = 0, bad = 0, stopped = 0, skipped = 0
        for (s, byPerson) in states {
            switch s {
            case .done: ok += 1
            case .failed: if byPerson { stopped += 1 } else { bad += 1 }
            case .skipped: skipped += 1
            default: break
            }
        }
        var title = L("\(ok) live, \(bad) failed", "\(ok) live, \(bad) fehlgeschlagen")
        if skipped > 0 { title += L(", \(skipped) skipped", ", \(skipped) übersprungen") }
        if stopped > 0 { title += L(", \(stopped) cancelled", ", \(stopped) abgebrochen") }
        return (title, bad == 0)
    }

    private func itemNow(_ i: Item) -> Item? { items[i.platform]?.first { $0.id == i.id } }
    private func clearPreview(_ i: Item) {
        if let k = items[i.platform]?.firstIndex(where: { $0.id == i.id }) { items[i.platform]![k].previewId = nil }
    }

    private func pump() {
        // Waiting for green checks takes no build slot; the job comes back to the queue once they are green.
        while let k = queue.firstIndex(where: { $0.whenGreen && !$0.preview && $0.readyAt <= Date() && waitsFor($0) == nil }) {
            let job = queue.remove(at: k)
            ciWaits[job.item.id] = Task { await waitForChecks(job) }
        }
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
                // Never started: skipped, not a failed build in the journal.
                set(job.item.platform, job.item.id, .skipped(L("Not started: the backend of the same repo failed",
                                                             "Nicht gestartet: das Backend desselben Repos ist fehlgeschlagen")))
            }
        }
        holdAwake()
        if queue.isEmpty && running == 0 && ciWaits.isEmpty {
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
        if let t = ciWaits.removeValue(forKey: item.id) {   // still waiting for checks: nothing was started
            t.cancel(); set(item.platform, item.id, .idle); pump(); return
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
                say(L("Could not cancel \(item.name)", "\(item.name) ließ sich nicht abbrechen"), error.localizedDescription, ok: false, project: Self.key(item))
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
        Notify.remind(L("Time for the daily deploy", "Zeit für den täglichen Deploy"), Self.reminderText(w))
    }

    /// "3 PRs in 2 projects wait to go live."; commits when no PR is counted.
    nonisolated static func reminderText(_ w: Waiting) -> String {
        let one = w.prs > 0 ? w.prs == 1 : w.commits == 1
        let what = w.prs > 0 ? L(plural(w.prs, "PR", "PRs"), plural(w.prs, "PR", "PRs"))
            : L(plural(w.commits, "commit", "commits"), plural(w.commits, "Commit", "Commits"))
        return L("\(what) in \(plural(w.projects, "project", "projects")) \(one ? "waits" : "wait") to go live.",
                 "\(what) in \(plural(w.projects, "Projekt", "Projekten")) \(one ? "wartet" : "warten") darauf, live zu gehen.")
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
        guard !refusedAsObserver() else { return }
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

    /// Jobs waiting for their checks, by row; outside the queue and the build slots, and cancellable.
    private var ciWaits: [String: Task<Void, Never>] = [:]

    /// Only once the CI of the commit is green (waits up to 30 minutes for running checks).
    private func waitForChecks(_ job: Job) async {
        guard !Task.isCancelled else { return }   // cancelled before it began
        let item = job.item, p = item.platform
        if p == .render { queueBatch.insert(item.id) }
        // Cancelled in the row: cancel() already took it out (a new wait for the row may be there now).
        defer { if !Task.isCancelled { ciWaits[item.id] = nil; pump() } }
        // The commit that is checked is the one that goes out: a newer push waits for the next deploy.
        guard let repo = item.repo, let commit = job.sha ?? item.headSha else {
            set(p, item.id, .skipped(L("Checks unknown: no commit or repo known", "Checks unbekannt: kein Commit oder Repo bekannt"))); return
        }
        set(p, item.id, .running(L("waiting for checks", "wartet auf Checks")))
        do {
            let ci = try await Tool.json(["ci", repo, commit, "--wait", "30m", "--json"], as: CIReply.self, timeout: 32 * 60)
            guard !Task.isCancelled else { return }
            switch ci.state {
            case "green", "none":
                var next = job; next.sha = commit; next.whenGreen = false; next.readyAt = .distantPast
                set(p, item.id, .queued)
                queue.append(next)
            case "red":
                set(p, item.id, .skipped(L("CI is red: ", "CI ist rot: ") + ci.reason))
            default:
                set(p, item.id, .skipped(L("Checks not done after 30 minutes: ", "Checks nach 30 Minuten nicht fertig: ") + ci.reason))
            }
        } catch {
            guard !Task.isCancelled else { return }
            set(p, item.id, .failed(error.localizedDescription))
        }
    }

    private func deploy(_ job: Job) async {
        let item = job.item, p = item.platform
        if p == .render { queueBatch.insert(item.id) }
        set(p, item.id, .starting)
        cancelled.remove(item.id)
        clearPreview(item)   // an older preview must not be promoted over what this deploy brings
        do {
            let sha = job.sha   // with "only when green" the checked commit, see waitForChecks
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

    /// Shown when a build has no result after 40 minutes: still active, so no second build can start.
    nonisolated static var overdueState: RunState { .running(L("no result after 40 min – still asking, check the dashboard",
                                                             "nach 40 Min. kein Ergebnis – fragt weiter, im Dashboard nachsehen")) }
    /// Asks every 6 seconds until the deploy is live or failed; after 40 minutes every 30 seconds,
    /// still "running" (a build may take longer, and a free button would pay for a second one), for 12 hours at most.
    private func follow(_ item: Item, deployId: String, url: String?, preview: Bool = false, rolledBack: Bool = false) async throws {
        let p = item.platform
        defer { cancelled.remove(item.id) }   // however it ended, a later deploy can be cancelled again
        var misses = 0
        // A deadline, not a count of rounds: slow status answers must not stretch 40 minutes to hours.
        let start = Date(), overdue = start.addingTimeInterval(40 * 60), deadline = start.addingTimeInterval(12 * 3600)
        var toldOverdue = false
        let usual = usualMinutes(item)
        while Date() < deadline {
            let wait = Date() < overdue ? Self.pollSeconds(elapsed: Date().timeIntervalSince(start), usualMinutes: usual) : 30
            try await Task.sleep(nanoseconds: UInt64(wait) * 1_000_000_000)
            if !toldOverdue, Date() >= overdue, !cancelled.contains(item.id) {
                toldOverdue = true
                set(p, item.id, Self.overdueState)
                say(L("\(item.name) has no result after 40 minutes", "\(item.name) hat nach 40 Minuten kein Ergebnis"),
                    L("Still asking. Check the dashboard; the deploy button stays locked until it ends.",
                      "Fragt weiter. Im Dashboard nachsehen; der Deploy-Knopf bleibt gesperrt, bis er endet."), ok: false)
            }
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
                // A cron job or a one-off run ended well: like "live", without a site to ask.
                if rolledBack { set(p, item.id, .done(nil), countsAsLive: false); markBehind(p, item.id) }
                else { recordDuration(item); set(p, item.id, .done(nil)) }
                return
            case (.vercel, "canceled"):
                // Usually the project's "Ignored Build Step" decided nothing changed.
                set(p, item.id, .skipped(L("Skipped or canceled by Vercel (Ignored Build Step?)",
                                          "Von Vercel übersprungen oder abgebrochen (Ignored Build Step?)"))); return
            case (.vercel, "error"), (.render, "build_failed"), (.render, "update_failed"),
                 (.render, "canceled"), (.render, "pre_deploy_failed"), (.render, "deactivated"):
                set(p, item.id, .failed(s.error ?? Row.stateText(state))); return
            default:
                if !Self.knownStates.contains(state), Self.loggedStates.insert(state).inserted {
                    Log.write("\(p.cli) status: unknown state \"\(state)\" for \(item.name), shown as it is")
                }
                if !cancelled.contains(item.id) { set(p, item.id, toldOverdue ? Self.overdueState : .running(Self.stateName(state))) }
            }
        }
        // Still no end after 12 hours: the button frees, but a start right away is held (see enqueue).
        unsureStarts[Self.key(item)] = Date()
        set(p, item.id, .failed(L("No result after 12 hours – check the dashboard", "Kein Ergebnis nach 12 Stunden – im Dashboard nachsehen")))
    }

    /// Seconds between status questions: every 6 s in the first two minutes and from a minute before
    /// the usual build time on (when it most likely ends), every 15 s in between. Each one starts bash and node.
    nonisolated static func pollSeconds(elapsed: TimeInterval, usualMinutes: Int?) -> Int {
        if elapsed < 120 { return 6 }
        if let u = usualMinutes, elapsed >= Double(u - 1) * 60 { return 6 }
        return 15
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

    var healthPathCount: Int { healthPaths.values.filter { Self.cleanPath($0) != nil }.count }
    /// Settings → Projects: one kind of mark off for every project (the dialog asked first).
    func clearMarks(_ m: ProjectMarks) {
        let d = UserDefaults.standard
        switch m {
        case .pinned: pinned = []; d.set([String](), forKey: "pinned")
        case .notes: notes = [:]; d.set([String: String](), forKey: "notes")
        case .checkPaths: healthPaths = [:]; d.set([String: String](), forKey: "healthPaths")
        case .autoRollback: autoRollback = []; d.set([String](), forKey: "autoRollback")
        case .ignoredTriggers: break   // an @AppStorage string of the window, cleared by Settings itself
        }
    }
    static let rollbackSeconds = 10
    nonisolated static let rollbackPrefix = "rollback|"

    /// Ten seconds to say no, in a notification and a toast, then production goes back.
    private func countDownToRollback(_ item: Item, _ link: String, _ code: Int?) {
        let key = Self.key(item), id = Self.rollbackPrefix + key, n = Self.rollbackSeconds
        guard rollbackCountdowns[key] == nil else { return }
        let name = Demo.mask(item.name), shownLink = Demo.scrub(link, items: Array(items.values.joined()))
        let title = L("\(name) fails its check – rolling back in \(n) s", "\(name) besteht den Check nicht – Zurückrollen in \(n) s")
        Notify.countdown(title, shownLink + " → " + (code.map(String.init) ?? L("no answer", "keine Antwort")), id: id)
        show(Toast(text: title, ok: false, undoLabel: L("Cancel", "Abbrechen"), undo: { [weak self] in self?.cancelRollback(key) }))
        messages.insert(Message(date: Date(), text: title + " – " + shownLink, ok: false), at: 0)
        let checkedId = itemNow(item)?.deployId
        rollbackCountdowns[key] = Task { [weak self] in
            try? await Task.sleep(nanoseconds: UInt64(n) * 1_000_000_000)
            guard !Task.isCancelled, let self, self.rollbackCountdowns.removeValue(forKey: key) != nil else { return }
            Notify.remove(id)
            let now = self.itemNow(item)
            // A newer deploy (a fix) is queued, waiting or building, or already went out: it is not rolled back.
            let newer = self.queue.contains { $0.item.id == item.id } || self.ciWaits[item.id] != nil
            guard Self.rollbackStillDue(now, checkedId: checkedId, newerQueued: newer) else {
                self.say(L("Rollback skipped", "Zurückrollen ausgelassen"),
                         L("A newer deploy of \(item.name) is under way or live.", "Ein neuerer Deploy von \(item.name) läuft oder ist live."), ok: true)
                return
            }
            self.rollback(now ?? item)
        }
    }
    /// The countdown's rollback only goes ahead while the deploy it checked is still the newest one.
    nonisolated static func rollbackStillDue(_ now: Item?, checkedId: String?, newerQueued: Bool) -> Bool {
        guard let now, !newerQueued, !now.state.isActive else { return false }
        return now.deployId == checkedId
    }
    func cancelRollback(_ key: String) {
        guard let t = rollbackCountdowns.removeValue(forKey: key) else { return }
        t.cancel(); Notify.remove(Self.rollbackPrefix + key)
        say(L("Rollback cancelled", "Zurückrollen abgebrochen"), L("The new deploy stays live.", "Der neue Deploy bleibt live."), ok: true)
    }

    // MARK: Updates come from Sparkle (SoftwareUpdate.swift); it asks this before it restarts the app.

    /// While deploys are queued or building: no App Nap (it stretches the status naps, "live" would come
    /// minutes late) and no idle sleep (the queue would stop in the middle). Ends with the last deploy.
    private var awake: NSObjectProtocol?
    private func holdAwake() {
        let busy = deploysBusy || !ciWaits.isEmpty
        if busy, awake == nil {
            awake = ProcessInfo.processInfo.beginActivity(options: [.userInitiated, .idleSystemSleepDisabled],
                                                          reason: "Deploys are running")
        } else if !busy, let a = awake {
            ProcessInfo.processInfo.endActivity(a); awake = nil
        }
    }

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
