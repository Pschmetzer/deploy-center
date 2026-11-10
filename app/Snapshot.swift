// Deploy Center — Writes the small snapshot the widgets read (App Group container).
// Without an App Group (the plain build) nothing is written and nothing changes.

import Foundation
import WidgetKit

extension Store {
    private static var lastSnapshot: DeploySnapshot?
    private static var watchingDemo = false

    /// Called after every reload of a list and of the costs. Cheap: a few KB, only when something changed.
    func writeSnapshot() {
        guard let url = DeploySnapshot.groupURL else { return }
        if !Self.watchingDemo {
            Self.watchingDemo = true
            // Demo mode masks names in the snapshot too: the widget cannot read the app's settings.
            var demo = Demo.on
            NotificationCenter.default.addObserver(forName: UserDefaults.didChangeNotification, object: nil, queue: .main) { _ in
                MainActor.assumeIsolated {
                    guard Demo.on != demo else { return }
                    demo = Demo.on; self.writeSnapshot()
                }
            }
        }
        let snap = makeSnapshot()
        if let last = Self.lastSnapshot, last.sameContent(as: snap) { return }
        do {
            try FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
            try DeploySnapshot.encoder.encode(snap).write(to: url, options: .atomic)
            Self.lastSnapshot = snap
            WidgetCenter.shared.reloadAllTimelines()
        } catch {
            Log.write("snapshot: \(error.localizedDescription)")
        }
    }

    func makeSnapshot() -> DeploySnapshot {
        let w = waiting
        var rows: [DeploySnapshot.Project] = []
        for i in Array(items.values.joined()) where i.deployable && !isHidden(i) {
            let status: DeploySnapshot.Project.Status
            if i.building || i.state.isActive { status = .building }
            else if i.failed { status = .failed }
            else if i.hasNewCommits && i.state == .idle { status = .waiting }
            else { continue }
            rows.append(.init(name: Demo.mask(i.name), platform: i.platform.rawValue, status: status,
                              commits: i.pendingCommits ?? 0, prs: i.pendingPRs ?? 0,
                              since: status == .waiting ? i.oldestPendingAt : (i.startedAt ?? i.lastAt),
                              message: i.headMsg.map { Demo.scrub($0, items: Array(items.values.joined())) }))
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
                              failed: rows.filter { $0.status == .failed }.count, saving: snapshotSaving,
                              projects: Array(rows.prefix(10)), language: isGerman ? "de" : "en")
    }

    /// The same sum as the costs panel, on the same day (billing days are UTC, see `CostsSheet.today`).
    private var snapshotSaving: DeploySnapshot.Saving? {
        guard let s = costs?.saving(today: CostsSheet.today()) else { return nil }
        return DeploySnapshot.Saving(before: s.before, after: s.after)
    }
}

extension DeploySnapshot {
    /// Everything but `at`: a new language must reach the widgets too.
    func sameContent(as o: DeploySnapshot) -> Bool { o.dated(at) == self }
    private func dated(_ d: Date) -> DeploySnapshot {
        var c = DeploySnapshot(at: d, demo: demo, waitingProjects: waitingProjects, waitingCommits: waitingCommits,
                               waitingPRs: waitingPRs, building: building, failed: failed, saving: saving, projects: projects, language: language)
        c.version = version
        return c
    }
}
