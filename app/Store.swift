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
    @Published var busyMessage: String?

    @Published var doctorError: String?
    @Published var costs: Costs?
    @Published var triggers: [Trigger] = []

    /// Costs and stray build triggers load after the lists; neither blocks deploying.
    private var lastExtras = Date.distantPast
    func loadExtras() async {
        lastExtras = Date()
        if doctor?.vercelLoggedIn == true {
            costs = try? await Tool.json(["costs", "14"], as: Costs.self)
            checkBudget()
        }
        Task { await checkProviders() }
        triggers = (try? await Tool.json(["triggers"], as: [Trigger].self)) ?? []
        if doctor?.githubLoggedIn == true {
            githubBudget = try? await Tool.json(["github-budget"], as: Budget.self)
        }
    }

    /// Once a day: commits that have waited longer than the chosen number of days (Settings).
    private func checkStale() {
        let d = UserDefaults.standard
        let days = d.integer(forKey: "staleDays")
        let today = Date().formatted(.iso8601.year().month().day())
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
        let today = Date().formatted(.iso8601.year().month().day())
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
        for p in Platform.allCases { try? FileManager.default.removeItem(at: Self.cacheDir.appendingPathComponent("\(p.cli)-v1.json")) }
        // After sleep the lists can be hours old, and the daily reminder may be overdue.
        NSWorkspace.shared.notificationCenter.addObserver(forName: NSWorkspace.didWakeNotification, object: nil, queue: .main) { [weak self] _ in
            Task { @MainActor in
                try? await Task.sleep(nanoseconds: 5_000_000_000)   // the network needs a moment
                await self?.autoRefresh(); self?.remindIfDue()
            }
        }
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
            checkStale()
        } catch {
            loadError[p] = error.localizedDescription
        }
    }

    /// A reload keeps what the person did: ticks stay, a deploy being followed keeps its state.
    func merge(_ p: Platform, _ fresh: [Item]) {
        let old = Dictionary((items[p] ?? []).map { ($0.id, $0) }, uniquingKeysWith: { a, _ in a })
        items[p] = fresh.map { n in
            var n = n
            if let o = old[n.id] {
                n.selected = o.selected && n.deployable
                // A deploy being followed keeps what cancelling, the timer and promoting need.
                if o.state != .idle { n.state = o.state; n.deployId = o.deployId; n.startedAt = o.startedAt; n.previewId = o.previewId }
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
        guard loading.isEmpty else { return }
        if doctor == nil { await start(); return }
        // Only the platform with a deploy under way is left alone; the other one stays current.
        let v = doctor?.vercelLoggedIn == true && !(items[.vercel] ?? []).contains { $0.state.isActive }
        let r = doctor?.renderKey == true && !(items[.render] ?? []).contains { $0.state.isActive }
        async let a: Void = v ? load(.vercel) : ()
        async let b: Void = r ? load(.render) : ()
        _ = await (a, b)
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
        for i in all where i.hasNewCommits && i.state == .idle {
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
        let took = items[p]![i].startedAt.map { Date().timeIntervalSince($0) }
        switch s {
        case .done: Journal.append(JournalEntry(platform: p.rawValue, name: name, result: countsAsLive ? "live" : "other", seconds: took, detail: nil))
        case .failed(let m): Journal.append(JournalEntry(platform: p.rawValue, name: name, result: "failed", seconds: took, detail: m))
        case .skipped(let m): Journal.append(JournalEntry(platform: p.rawValue, name: name, result: "skipped", seconds: took, detail: m))
        default: break
        }
        switch s {
        case .done:
            if countsAsLive { say(L("\(name) is live", "\(name) ist live"), p.rawValue, ok: true) }
            else if items[p]![i].previewId != nil { say(L("\(name): preview is ready", "\(name): Vorschau ist fertig"), p.rawValue, ok: true) }
            else { say(L("\(name) rolled back", "\(name) zurückgerollt"), p.rawValue, ok: true) }
        case .failed(let m): say(L("\(name) failed", "\(name) fehlgeschlagen"), m, ok: false)
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
    @Published var toast: Toast?
    /// The last messages, newest first, so a line that vanished after 5 seconds can still be read.
    struct Message: Identifiable { let id = UUID(); let date: Date; let text: String; let ok: Bool }
    @Published var messages: [Message] = []
    private func say(_ title: String, _ body: String, ok: Bool) {
        Notify.post(title, body)
        let t = Toast(text: title, ok: ok)
        toast = t
        messages.insert(Message(date: Date(), text: title + (body.isEmpty ? "" : " – " + body), ok: ok), at: 0)
        if messages.count > 30 { messages.removeLast() }
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
    /// Hide with a way back: the toast offers "Undo" for a few seconds.
    func hideWithUndo(_ i: Item) {
        toggleHidden(i)
        toast = Toast(text: L("\(i.name) hidden", "\(i.name) ausgeblendet"), ok: true,
                      undoLabel: L("Undo", "Rückgängig"), undo: { [weak self] in self?.toggleHidden(i) })
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

    /// Seconds between the click and the first build; in this time "cancel" in the row still costs nothing.
    var undoSeconds: Int { UserDefaults.standard.object(forKey: "undoSeconds") as? Int ?? 8 }
    private var holdUntil = Date.distantPast
    private var batch: [(Platform, String)] = []

    func enqueue(_ jobs: [Job]) {
        Notify.ask()
        var added = 0
        for j in jobs where !(itemNow(j.item)?.state.isActive ?? false) {
            set(j.item.platform, j.item.id, .queued)
            queue.append(j); batch.append((j.item.platform, j.item.id)); added += 1
        }
        if added > 0, undoSeconds > 0 {
            let n = undoSeconds
            holdUntil = Date().addingTimeInterval(Double(n))
            toast = Toast(text: L("Starting in \(n) s – cancel in the row to stop", "Startet in \(n) s – in der Zeile abbrechen"), ok: true)
            Task { try? await Task.sleep(nanoseconds: UInt64(n) * 1_000_000_000 + 300_000_000); pump() }
        }
        pump()
    }

    /// Stops everything that is queued or building.
    func cancelAll() { for i in Array(items.values.joined()) where i.state.isActive { cancel(i) } }

    private func summarize() {
        defer { batch = [] }
        guard batch.count >= 2 else { return }
        var ok = 0, bad = 0
        for (p, id) in batch {
            guard let s = items[p]?.first(where: { $0.id == id })?.state else { continue }
            if case .done = s { ok += 1 } else if case .failed = s { bad += 1 }
        }
        say(L("\(ok) live, \(bad) failed", "\(ok) live, \(bad) fehlgeschlagen"), L("Deploy run finished", "Deploy-Lauf beendet"), ok: bad == 0)
    }

    private func itemNow(_ i: Item) -> Item? { items[i.platform]?.first { $0.id == i.id } }
    private func clearPreview(_ i: Item) {
        if let k = items[i.platform]?.firstIndex(where: { $0.id == i.id }) { items[i.platform]![k].previewId = nil }
    }

    private func pump() {
        while Date() >= holdUntil, running < maxParallel, let k = queue.firstIndex(where: { waitsFor($0) == nil }) {
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
        if queue.isEmpty && running == 0 {
            queueBatch = []
            if Date() >= holdUntil {
                let hadRun = !batch.isEmpty
                summarize()
                // The row says "current" from what the app remembers; read what GitHub says now.
                if hadRun { Task { await autoRefresh() } }
            }
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
            toast = Toast(text: L("\(item.name) is still starting – try again in a moment", "\(item.name) startet noch – gleich nochmal versuchen"), ok: false)
            return
        }
        cancelled.insert(item.id)
        Task {
            let args = item.platform == .vercel ? ["vercel", "cancel", id] : ["render", "cancel", item.id, id]
            do { _ = try await Tool.run(args); set(item.platform, item.id, .failed(L("Cancelled", "Abgebrochen"))) }
            catch { cancelled.remove(item.id); say(L("Could not cancel \(item.name)", "\(item.name) ließ sich nicht abbrechen"), error.localizedDescription, ok: false) }
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

    /// After a rollback production is older than the branch: the project has changes again.
    private func markBehind(_ p: Platform, _ id: String) {
        guard let i = items[p]?.firstIndex(where: { $0.id == id }) else { return }
        items[p]![i].changed = true; items[p]![i].lastSha = nil
        items[p]![i].lastAt = Date()
    }

    /// Production back to what was live before.
    func rollback(_ item: Item) {
        Notify.ask()
        clearPreview(item)
        Task {
            let p = item.platform
            set(p, item.id, .starting)
            do {
                let r = try await Tool.json([p.cli, "rollback", item.id], as: Started.self)
                if p == .vercel { set(p, item.id, .done(item.link), countsAsLive: false); markBehind(p, item.id) }
                else { set(p, item.id, .running(L("rolling back", "rollt zurück"))); try await follow(item, deployId: r.id, url: item.link, rolledBack: true) }
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
    private func follow(_ item: Item, deployId: String, url: String?, preview: Bool = false, rolledBack: Bool = false) async throws {
        let p = item.platform
        var misses = 0
        for _ in 0..<400 {
            try await Task.sleep(nanoseconds: 6_000_000_000)
            if cancelled.contains(item.id) { return }
            let args = p == .vercel ? ["vercel", "status", deployId] : ["render", "status", item.id, deployId]
            guard let s = try? await Tool.json(args, as: StatusReply.self) else {
                // Network or login gone: say so instead of spinning for 40 minutes without a word.
                misses += 1
                if misses >= 5 { set(p, item.id, .running(L("status unavailable, retrying", "Status nicht abrufbar, neuer Versuch"))) }
                continue
            }
            misses = 0
            let state = (s.state ?? "").lowercased()
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
                    if let l = item.link { Task { await checkSite(item.name, l.hasSuffix("/") ? String(l.dropLast()) + healthPath(item) : l + healthPath(item)) } }
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
                set(p, item.id, .running(Self.stateName(state)))
            }
        }
        set(p, item.id, .failed(L("No result after 40 minutes – check the dashboard", "Kein Ergebnis nach 40 Minuten – im Dashboard nachsehen")))
    }

    /// A path to ask after going live instead of the front page (/health), per project. Kept on this Mac.
    func healthPath(_ i: Item) -> String { ((UserDefaults.standard.dictionary(forKey: "healthPaths") as? [String: String]) ?? [:])[Self.key(i)] ?? "" }
    func setHealthPath(_ i: Item, _ path: String) {
        var all = (UserDefaults.standard.dictionary(forKey: "healthPaths") as? [String: String]) ?? [:]
        let t = path.trimmingCharacters(in: .whitespacesAndNewlines)
        all[Self.key(i)] = t.isEmpty ? nil : (t.hasPrefix("/") ? t : "/" + t)
        UserDefaults.standard.set(all, forKey: "healthPaths")
    }

    /// After going live: does the site answer? A deploy can be "ready" and the page still broken.
    private func checkSite(_ name: String, _ link: String) async {
        guard let url = URL(string: link) else { return }
        var code: Int?
        // A fresh Render service can answer 502/503 for a few seconds: ask up to three times.
        for attempt in 0..<3 {
            var req = URLRequest(url: url, timeoutInterval: 20)
            req.setValue("DeployCenter (post-deploy check)", forHTTPHeaderField: "User-Agent")
            code = ((try? await URLSession.shared.data(for: req))?.1 as? HTTPURLResponse)?.statusCode
            // 401/403: the site answers but is protected (Deployment Protection, login) — not broken.
            if let c = code, c < 400 || c == 401 || c == 403 { return }
            if attempt < 2 { try? await Task.sleep(nanoseconds: 6_000_000_000) }
        }
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
