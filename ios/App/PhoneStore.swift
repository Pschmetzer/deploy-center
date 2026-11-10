// Deploy Center for iPhone — The state: projects from Vercel, Render and GitHub, deploys and rollbacks.
// Everything goes from this phone straight to the person's own accounts. There is no server of ours.

import Foundation
import LocalAuthentication
import UserNotifications
import WidgetKit

@MainActor
final class PhoneStore: ObservableObject {
    @Published var projects: [PhoneProject] = []
    @Published var loading = false
    @Published var loadedAt: Date?
    @Published var errors: [String] = []
    @Published var running: [String: String] = [:]      // project key → state of the deploy being followed
    @Published var message: String?
    @Published var demo: Bool { didSet { UserDefaults.standard.set(demo, forKey: "demo"); Task { await reload() } } }

    enum TokenKey: String { case vercel, vercelTeam, render, github }

    init() {
        let args = ProcessInfo.processInfo.arguments
        demo = args.contains("-demo") || UserDefaults.standard.bool(forKey: "demo")
    }

    /// The keys the Mac app handed over through iCloud Keychain (shared/PhoneLink.swift), if any.
    @Published var linked: LinkedKeys? = PhoneLink.read()

    var hasAccount: Bool { token(.vercel) != nil || token(.render) != nil }
    /// A key typed (or scanned) on this phone wins; otherwise the one from the Mac.
    func token(_ k: TokenKey) -> String? { ownToken(k) ?? linkedToken(k) }
    func ownToken(_ k: TokenKey) -> String? { Keychain.get(k.rawValue).flatMap { $0.isEmpty ? nil : $0 } }
    func linkedToken(_ k: TokenKey) -> String? {
        guard let l = linked else { return nil }
        let v: String
        switch k { case .vercel: v = l.vercel; case .vercelTeam: v = l.vercelTeam; case .render: v = l.render; case .github: v = l.github }
        return v.isEmpty ? nil : v
    }
    /// iCloud Keychain can take a minute after the Mac wrote: read again when the app comes back.
    func refreshLink() { let l = PhoneLink.read(); if l != linked { linked = l } }
    var linkAvailable: Bool { PhoneLink.group != nil }

    /// Keys from the Mac's QR code: kept on this phone only, like typed ones.
    func adopt(_ k: LinkedKeys) {
        Keychain.set(TokenKey.vercel.rawValue, k.vercel)
        Keychain.set(TokenKey.vercelTeam.rawValue, k.vercelTeam)
        Keychain.set(TokenKey.render.rawValue, k.render)
        Keychain.set(TokenKey.github.rawValue, k.github)
        demo = false
        Task { await reload() }
    }

    var waiting: [PhoneProject] { projects.filter { $0.group == .waiting } }
    var waitingPRs: Int {
        // Projects of one repo share commits and PRs: count each repo once.
        var perRepo: [String: Int] = [:]
        for p in waiting { perRepo[p.repo ?? p.key] = max(perRepo[p.repo ?? p.key] ?? 0, p.pendingPRs ?? 0) }
        return perRepo.values.reduce(0, +)
    }

    // MARK: Loading

    func reload() async {
        guard !loading else { return }
        refreshLink()
        loading = true; defer { loading = false }
        if demo {
            projects = DemoData.projects(); loadedAt = Date(); errors = []; writeSnapshot(); return
        }
        var all: [PhoneProject] = [], errs: [String] = []
        if let v = token(.vercel) {
            do {
                var team = token(.vercelTeam)
                if team == nil { team = try await Vercel.resolveTeam(token: v) }
                all += try await Vercel(token: v, team: team).projects()
            } catch { errs.append("Vercel: \(error.localizedDescription)") }
        }
        if let r = token(.render) {
            do { all += try await Render(key: r).projects() } catch { errs.append("Render: \(error.localizedDescription)") }
        }
        let gh = GitHub(token: token(.github))
        // One GitHub read per repo and branch, at most four at a time.
        var cache: [String: PhoneProject] = [:]
        let keys = Array(Set(all.compactMap { p -> String? in guard let r = p.repo, let b = p.branch else { return nil }; return r + "@" + b }))
        await withTaskGroup(of: (String, PhoneProject).self) { g in
            var n = 0
            for k in keys {
                if n >= 4, let (key, val) = await g.next() { cache[key] = val; n -= 1 }
                guard let sample = all.first(where: { ($0.repo ?? "") + "@" + ($0.branch ?? "") == k }) else { continue }
                g.addTask { var p = sample; await gh.fill(&p); return (k, p) }
                n += 1
            }
            for await (key, val) in g { cache[key] = val }
        }
        // The live commit differs per project; compare again only where it differs from the sample.
        for i in all.indices {
            guard let r = all[i].repo, let b = all[i].branch, let filled = cache[r + "@" + b] else { continue }
            if filled.liveSha == all[i].liveSha {
                all[i] = PhoneProject.merging(all[i], filled)
            } else {
                var p = all[i]; await gh.fill(&p); all[i] = p
            }
        }
        projects = all.sorted { ($0.group.rawValue, $0.name.lowercased()) < ($1.group.rawValue, $1.name.lowercased()) }
        errors = errs; loadedAt = Date()
        writeSnapshot()
        // What the person has seen; the background refresh only notes what is new after this.
        try? JSONEncoder().encode(projects).write(to: Background.lastURL, options: .atomic)
    }

    // MARK: Deploy and rollback (Face ID first)

    func authenticate(_ reason: String) async -> Bool {
        let ctx = LAContext()
        var err: NSError?
        // Face ID or Touch ID, with the passcode as a fallback.
        guard ctx.canEvaluatePolicy(.deviceOwnerAuthentication, error: &err) else {
            message = L("Set a passcode on this device to deploy from it.", "Lege einen Code für dieses Gerät fest, um von hier zu deployen.")
            return false
        }
        return (try? await ctx.evaluatePolicy(.deviceOwnerAuthentication, localizedReason: reason)) ?? false
    }

    func deploy(_ p: PhoneProject) async {
        guard await authenticate(L("Deploy \(p.name)", "\(p.name) deployen")) else { return }
        if demo { await simulate(p, L("Deploy started (demo).", "Deploy gestartet (Demo).")); return }
        do {
            let id: String
            switch p.provider {
            case .vercel: id = try await vercel().deploy(p)
            case .render: id = try await Render(key: token(.render) ?? "").deploy(p)
            }
            message = L("Deploy of \(p.name) started.", "Deploy von \(p.name) gestartet.")
            await follow(p, id)
        } catch { message = error.localizedDescription }
    }

    func rollbackTarget(_ p: PhoneProject) async -> (id: String, sha: String?)? {
        if demo { return ("demo", "a0b1c2d") }
        do {
            switch p.provider {
            case .vercel: return try await vercel().rollbackTarget(p)
            case .render: return try await Render(key: token(.render) ?? "").rollbackTarget(p)
            }
        } catch { message = error.localizedDescription; return nil }
    }

    func rollback(_ p: PhoneProject, to target: String) async {
        guard await authenticate(L("Roll back \(p.name)", "\(p.name) zurückrollen")) else { return }
        if demo { await simulate(p, L("Rolled back (demo).", "Zurückgerollt (Demo).")); return }
        do {
            switch p.provider {
            case .vercel: try await vercel().rollback(p, to: target)
            case .render: try await Render(key: token(.render) ?? "").rollback(p, to: target)
            }
            message = L("\(p.name) is rolling back.", "\(p.name) wird zurückgerollt.")
            try? await Task.sleep(for: .seconds(4))
            await reload()
        } catch { message = error.localizedDescription }
    }

    private func vercel() async throws -> Vercel {
        let v = token(.vercel) ?? ""
        var team = token(.vercelTeam)
        if team == nil { team = try await Vercel.resolveTeam(token: v) }
        return Vercel(token: v, team: team)
    }

    /// Polls the new deploy every 6 seconds until it ends, at most 20 minutes.
    private func follow(_ p: PhoneProject, _ id: String) async {
        running[p.key] = "queued"
        defer { running[p.key] = nil }
        let end = Date().addingTimeInterval(20 * 60)
        while Date() < end {
            try? await Task.sleep(for: .seconds(6))
            let s: String
            do {
                switch p.provider {
                case .vercel: s = try await vercel().status(id)
                case .render: s = try await Render(key: token(.render) ?? "").status(p, id)
                }
            } catch { continue }
            running[p.key] = s.lowercased()
            if ["ready", "live", "succeeded"].contains(s.lowercased()) {
                message = L("\(p.name) is live.", "\(p.name) ist live."); break
            }
            if PhoneProject.failedStates.contains(s.lowercased()) || s.lowercased() == "deactivated" {
                message = L("\(p.name): \(s.lowercased())", "\(p.name): \(s.lowercased())"); break
            }
        }
        await reload()
    }

    private func simulate(_ p: PhoneProject, _ text: String) async {
        running[p.key] = "building"; message = text
        try? await Task.sleep(for: .seconds(3))
        if let i = projects.firstIndex(where: { $0.key == p.key }) {
            projects[i].liveSha = projects[i].headSha; projects[i].latestState = p.provider == .vercel ? "READY" : "live"
            projects[i].liveState = projects[i].latestState; projects[i].pendingCommits = 0; projects[i].pendingPRs = 0
        }
        running[p.key] = nil
        message = L("\(p.name) is live (demo).", "\(p.name) ist live (Demo).")
        writeSnapshot()
    }

    // MARK: Widget snapshot and notifications

    func makeSnapshot() -> DeploySnapshot {
        let rows: [DeploySnapshot.Project] = projects.compactMap { p in
            guard let s = p.snapshotStatus else { return nil }
            return .init(name: p.name, platform: p.provider.rawValue, status: s, commits: p.pendingCommits ?? 0,
                         prs: p.pendingPRs ?? 0, since: s == .waiting ? p.oldestPendingAt : p.liveAt, message: p.headMsg)
        }
        let order: [DeploySnapshot.Project.Status: Int] = [.building: 0, .failed: 1, .waiting: 2]
        let sorted = rows.sorted { (order[$0.status]!, -$0.prs, $0.name) < (order[$1.status]!, -$1.prs, $1.name) }
        return DeploySnapshot(at: loadedAt ?? Date(), demo: demo, waitingProjects: waiting.count,
                              waitingCommits: waiting.reduce(0) { $0 + ($1.pendingCommits ?? 0) }, waitingPRs: waitingPRs,
                              building: rows.filter { $0.status == .building }.count,
                              failed: rows.filter { $0.status == .failed }.count, saving: nil, projects: Array(sorted.prefix(10)))
    }

    func writeSnapshot() {
        guard let url = DeploySnapshot.groupURL else { return }
        try? FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
        try? DeploySnapshot.encoder.encode(makeSnapshot()).write(to: url, options: .atomic)
        WidgetCenter.shared.reloadAllTimelines()
    }

    /// After a background refresh: a note for what newly failed or newly waits. Only local notifications.
    func notifyChanges(from before: [PhoneProject]) async {
        guard UserDefaults.standard.bool(forKey: "notify") else { return }
        let old = Dictionary(before.map { ($0.key, $0) }, uniquingKeysWith: { a, _ in a })
        var lines: [String] = []
        for p in projects {
            let o = old[p.key]
            if p.failed && !(o?.failed ?? false) { lines.append(L("\(p.name) failed", "\(p.name) fehlgeschlagen")) }
            else if p.group == .waiting && o?.group != .waiting { lines.append(L("\(p.name) is waiting", "\(p.name) wartet")) }
        }
        guard !lines.isEmpty else { return }
        let c = UNMutableNotificationContent()
        c.title = "Deploy Center"; c.body = lines.prefix(4).joined(separator: " · "); c.sound = .default
        try? await UNUserNotificationCenter.current().add(UNNotificationRequest(identifier: UUID().uuidString, content: c, trigger: nil))
    }
}

extension PhoneProject {
    /// Repo facts from `filled` (same repo, branch and live commit), deploy facts from `own`.
    static func merging(_ own: PhoneProject, _ filled: PhoneProject) -> PhoneProject {
        var x = own
        x.headSha = filled.headSha; x.headAt = filled.headAt; x.headMsg = filled.headMsg
        x.pendingCommits = filled.pendingCommits; x.pendingPRs = filled.pendingPRs; x.oldestPendingAt = filled.oldestPendingAt
        x.compareStatus = filled.compareStatus; x.rewritten = filled.rewritten; x.openPRs = filled.openPRs
        x.fetchError = own.fetchError ?? filled.fetchError
        return x
    }
}
