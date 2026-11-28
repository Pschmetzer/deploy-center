// Deploy Center — The "Today" part of the widget snapshot: Claude Code sessions, today's deploys, pull requests
// and the Mac's load in one place. Everything comes from what the app already reads (desktop-sessions, sessions,
// prs, the perf guard, the journal); nothing new is started for it. Read-only.

import Combine
import Foundation

enum TodaySummary {
    /// The perf agent's memory figures (perf/status.json). PerfStatus does not decode them, so they are read here.
    struct Memory: Decodable, Equatable {
        struct Part: Decodable, Equatable { let totalMB: Int?; let freePct: Int? }
        let time: Int?
        let memory: Part?
        /// Whole GB, so the 30-second tick does not rewrite the snapshot for every few MB.
        var freeGB: Int? {
            guard let t = memory?.totalMB, let p = memory?.freePct, t > 0, p >= 0 else { return nil }
            return Int((Double(t) * Double(p) / 100 / 1024).rounded())
        }
    }

    /// A reading counts for three minutes (as the guard's own rule); older is unknown.
    static let fresh: TimeInterval = 180

    /// Deploys that ended on the day of `now`: live (also rollbacks and forced) and failed.
    static func deploys(_ journal: [JournalEntry], now: Date, calendar: Calendar = .current) -> DeploySnapshot.Today.Deploys {
        let today = journal.filter { calendar.isDate($0.at, inSameDayAs: now) }
        return .init(live: today.filter { [.live, .rollback, .forced].contains($0.kind) }.count,
                     failed: today.filter { $0.kind == .failed }.count)
    }

    static func make(now: Date, calendar: Calendar = .current, desktop: DesktopSessionsSnapshot?, cloud: SessionsReport?,
                     prs: PRsReport?, level: String?, memory: Memory?, journal: [JournalEntry],
                     failed: [DeploySnapshot.Project], demo: Bool, mask: (String) -> String = Demo.mask) -> DeploySnapshot.Today {
        typealias Item = DeploySnapshot.Today.Item
        var items: [Item] = failed.map { Item(kind: .failed, title: $0.name, detail: $0.platform) }

        var sessions: DeploySnapshot.Today.Sessions?
        if let d = desktop {
            let t = d.totals
            sessions = .init(running: t.running, waiting: t.waiting, done: t.done, stopped: t.stopped)
            for a in d.accounts {
                let account = demo ? L("Account", "Konto") : a.label
                for s in a.sessions where s.state == "waiting" || s.state == "stopped" {
                    let name = mask(s.title.isEmpty ? s.folder : s.title)
                    items.append(s.state == "waiting" ? Item(kind: .waiting, title: name, detail: L("waits on you · ", "wartet auf dich · ") + account)
                                                      : Item(kind: .stopped, title: name, detail: L("stopped · ", "stehen geblieben · ") + account))
                }
            }
        }
        if let c = cloud {
            if sessions == nil { sessions = .init(running: 0, waiting: 0, done: 0, stopped: 0) }
            sessions?.cloudOpen = c.summary.open
            sessions?.cloudWaiting = c.summary.waiting
            sessions?.cloudStuck = c.summary.stuck
            for r in c.sessions where r.state == "stuck" {
                items.append(Item(kind: .stuck, title: mask(r.title ?? r.branch),
                                  detail: L("cloud, idle \(r.idleMinutes ?? 0) min", "Cloud, seit \(r.idleMinutes ?? 0) Min. still")))
            }
        }

        var prRow: DeploySnapshot.Today.PRs?
        if let p = prs, let s = p.summary, (p.errors ?? []).isEmpty {
            prRow = .init(mergedToday: s.mergedToday ?? 0, conflicts: s.conflicts ?? (p.conflicts?.count ?? 0))
            for r in p.conflicts ?? [] {
                items.append(Item(kind: .conflict, title: "\(mask(r.repo))#\(r.pr)",
                                  detail: demo ? L("merge conflict", "Merge-Konflikt") : (r.title ?? L("merge conflict", "Merge-Konflikt"))))
            }
        }

        var mac: DeploySnapshot.Today.Mac?
        if let level, ["green", "yellow", "red"].contains(level) {
            mac = .init(level: level, freeGB: memory?.freeGB)
            if level == "red" {
                items.append(Item(kind: .mac, title: L("Mac is overloaded", "Mac ist überlastet"),
                                  detail: memory?.freeGB.map { L("\($0) GB free", "\($0) GB frei") } ?? L("load is red", "Last ist rot")))
            }
        }

        return .init(day: calendar.startOfDay(for: now), sessions: sessions, deploys: deploys(journal, now: now, calendar: calendar),
                     prs: prRow, mac: mac, attention: DeploySnapshot.Today.sorted(items))
    }
}

extension Store {
    private static var todayWatch: AnyCancellable?
    private static var journalCache: (stamp: Date?, size: Int, entries: [JournalEntry])?

    /// The sources the "Today" widget shows change on their own clocks: write the snapshot after each (it is
    /// written only when its content changed).
    func watchToday() {
        guard Self.todayWatch == nil else { return }
        // @Published sends before the value is set: the debounce on the main queue reads the new one.
        let changes: [AnyPublisher<Void, Never>] = [
            DesktopSessionsMonitor.shared.$snapshot.map { _ in () }.eraseToAnyPublisher(),
            SessionsWatch.shared.$report.map { _ in () }.eraseToAnyPublisher(),
            PRsWatch.shared.$report.map { _ in () }.eraseToAnyPublisher(),
            PerfMonitor.shared.$status.map { _ in () }.eraseToAnyPublisher(),
            NotificationCenter.default.publisher(for: Journal.didAppend).map { _ in () }.eraseToAnyPublisher(),
        ]
        Self.todayWatch = Publishers.MergeMany(changes)
            .debounce(for: .seconds(2), scheduler: DispatchQueue.main)
            .sink { [weak self] in MainActor.assumeIsolated { self?.writeSnapshot() } }
    }

    func makeToday(failed: [DeploySnapshot.Project], now: Date = Date()) -> DeploySnapshot.Today {
        let perf = PerfMonitor.shared.status
        let level = perf.flatMap { now.timeIntervalSince1970 - Double($0.time) < TodaySummary.fresh ? $0.level : nil }
        let memory = (try? Data(contentsOf: PerfMonitor.agentFile)).flatMap { try? JSONDecoder().decode(TodaySummary.Memory.self, from: $0) }
        let freshMemory = memory.flatMap { m in m.time.map { now.timeIntervalSince1970 - Double($0) < TodaySummary.fresh } ?? false ? m : nil }
        return TodaySummary.make(now: now, desktop: DesktopSessionsMonitor.shared.snapshot, cloud: SessionsWatch.shared.report,
                                 prs: PRsWatch.shared.report, level: level, memory: freshMemory, journal: Self.todayJournal(),
                                 failed: failed, demo: Demo.on)
    }

    /// The journal's newest entries, read again only when the file changed.
    private static func todayJournal() -> [JournalEntry] {
        let attrs = try? FileManager.default.attributesOfItem(atPath: Journal.url.path)
        let stamp = attrs?[.modificationDate] as? Date, size = (attrs?[.size] as? NSNumber)?.intValue ?? 0
        if let c = journalCache, c.stamp == stamp, c.size == size { return c.entries }
        let entries = Journal.load(limit: 300)
        journalCache = (stamp, size, entries)
        return entries
    }
}
