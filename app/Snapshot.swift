// Deploy Center — Writes the small snapshot the widgets read (App Group container).
// Without an App Group (the plain build) nothing is written and nothing changes.

import Foundation
import WidgetKit

extension Store {
    private static var lastSnapshot: DeploySnapshot?
    /// Watches only the demo switch (KVO on its key), not every write to the defaults.
    private static var demoWatch: NSKeyValueObservation?

    /// Called after every reload of a list and of the costs. Cheap: a few KB, only when something changed.
    func writeSnapshot() {
        guard let url = DeploySnapshot.groupURL else { return }
        if Self.demoWatch == nil {
            // Demo mode masks names in the snapshot too: the widget cannot read the app's settings.
            Self.demoWatch = UserDefaults.standard.observe(\.demoMode, options: [.new]) { [weak self] _, _ in
                DispatchQueue.main.async { MainActor.assumeIsolated { self?.writeSnapshot() } }
            }
        }
        watchToday()
        let snap = makeSnapshot()
        if let last = Self.lastSnapshot, last.sameContent(as: snap) { return }
        // Only the "Today" part changed (a session, the free memory): reload only that widget.
        let onlyToday = Self.lastSnapshot.map { var a = $0; a.today = snap.today; return a.sameContent(as: snap) } ?? false
        do {
            try FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
            try DeploySnapshot.encoder.encode(snap).write(to: url, options: .atomic)
            Self.lastSnapshot = snap
            if onlyToday { WidgetCenter.shared.reloadTimelines(ofKind: DeploySnapshot.todayKind) }
            else { WidgetCenter.shared.reloadAllTimelines() }
        } catch {
            Log.write("snapshot: \(error.localizedDescription)")
        }
    }

    func makeSnapshot() -> DeploySnapshot {
        let w = waiting
        var rows: [DeploySnapshot.Project] = []
        for i in allItems where i.deployable && !isHidden(i) {
            let status: DeploySnapshot.Project.Status
            if i.building || i.state.isActive { status = .building }
            else if i.failed { status = .failed }
            else if i.hasNewCommits && i.state == .idle { status = .waiting }
            else { continue }
            rows.append(.init(name: Demo.mask(i.name), platform: i.platform.rawValue, status: status,
                              commits: i.pendingCommits ?? 0, prs: i.pendingPRs ?? 0,
                              since: status == .waiting ? i.oldestPendingAt : (i.startedAt ?? i.lastAt),
                              message: i.headMsg.map { Demo.scrub($0, items: allItems) }))
        }
        let order: [DeploySnapshot.Project.Status: Int] = [.building: 0, .failed: 1, .waiting: 2]
        rows.sort { (a: DeploySnapshot.Project, b: DeploySnapshot.Project) -> Bool in
            let oa: Int = order[a.status] ?? 3, ob: Int = order[b.status] ?? 3
            if oa != ob { return oa < ob }
            if a.prs != b.prs { return a.prs > b.prs }
            if a.commits != b.commits { return a.commits > b.commits }
            return a.name < b.name
        }
        return DeploySnapshot(at: Date(), demo: Demo.on, waitingProjects: w.projects, waitingCommits: w.commits,
                              waitingPRs: w.prs, building: rows.filter { $0.status == .building }.count,
                              failed: rows.filter { $0.status == .failed }.count, byPlatform: Self.counts(rows), saving: snapshotSaving,
                              projects: Array(rows.prefix(10)), language: isGerman ? "de" : "en",
                              nextScheduled: Self.nextScheduled(german: isGerman),
                              today: makeToday(failed: rows.filter { $0.status == .failed }))
    }

    /// The daily deploy (`deploys schedule daily`): its file and its launchd job. Read only; this starts nothing.
    nonisolated static func nextScheduled(german: Bool, now: Date = Date(), home: URL = FileManager.default.homeDirectoryForCurrentUser,
                                          env: [String: String] = ProcessInfo.processInfo.environment) -> DeploySnapshot.NextRun? {
        let config = env["DEPLOYS_CONFIG"].map { URL(fileURLWithPath: $0) } ?? home.appendingPathComponent(".config/deploys")
        let launch = env["DEPLOYS_LAUNCH_DIR"].map { URL(fileURLWithPath: $0) } ?? home.appendingPathComponent("Library/LaunchAgents")
        guard FileManager.default.fileExists(atPath: launch.appendingPathComponent("app.deploycenter.daily.plist").path),
              let data = try? Data(contentsOf: config.appendingPathComponent("schedule.json")),
              let obj = (try? JSONSerialization.jsonObject(with: data)) as? [String: Any],
              let daily = obj["daily"] as? [String: Any], let at = daily["at"] as? String,
              let when = DeploySnapshot.nextDaily(at: at, weekdaysOnly: (daily["weekdays"] as? Bool) ?? false, after: now) else { return nil }
        return .init(name: german ? "Täglicher Deploy" : "Daily deploy", platform: "", at: when)
    }

    /// Per platform, sorted by name; platforms with nothing to say are left out.
    nonisolated static func counts(_ rows: [DeploySnapshot.Project]) -> [DeploySnapshot.PlatformCount] {
        Set(rows.map(\.platform)).sorted().map { p in
            let mine = rows.filter { $0.platform == p }
            return .init(platform: p, waiting: mine.filter { $0.status == .waiting }.count,
                         prs: mine.filter { $0.status == .waiting }.map(\.prs).reduce(0, +),
                         building: mine.filter { $0.status == .building }.count, failed: mine.filter { $0.status == .failed }.count)
        }
    }

    /// The app's own sum (Costs.saving, with the kept baseline and the same day), so the widget
    /// and the window never disagree.
    private var snapshotSaving: DeploySnapshot.Saving? {
        guard let s = costs?.saving(today: CostsSheet.today()) else { return nil }
        return DeploySnapshot.Saving(before: s.before, after: s.after)
    }

    /// The saving a month for the iPhone (LinkedKeys.savingPerMonth): whole dollars, nil under one.
    var savingPerMonth: Double? {
        guard let s = costs?.saving(today: CostsSheet.today()) else { return nil }
        let v = ((s.before - s.after) * 30).rounded()
        return v >= 1 ? v : nil
    }
}

extension DeploySnapshot {
    /// Everything but `at`: a new language or platform split must reach the widgets too.
    /// A copy of every field (the "Today" part too), so a new field cannot be forgotten here.
    func sameContent(as o: DeploySnapshot) -> Bool { var c = o; c.at = at; return c == self }
}

extension UserDefaults {
    /// For KVO: the defaults key "demoMode" (Demo.on).
    @objc dynamic var demoMode: Bool { bool(forKey: "demoMode") }
}

/// Handoff with the iPhone app: the project open in the details, as "Vercel/<id>" (the iPhone's key).
/// Receiving needs the type in Info.plist (NSUserActivityTypes); it only shows the project, never deploys.
enum Handoff {
    static let type = "app.deploycenter.project"
    static func key(_ i: Item) -> String { i.platform.rawValue + "/" + i.id }
    /// The project a handed-off key names, if this Mac lists it.
    static func item(for key: String, in items: [Item]) -> Item? { items.first { Self.key($0) == key } }
}
