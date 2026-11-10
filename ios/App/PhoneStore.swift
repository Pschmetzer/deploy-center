// Deploy Center for iPhone — The state: projects from Vercel, Render and GitHub, deploys and rollbacks.
// Everything goes from this phone straight to the person's own accounts. There is no server of ours.

import Foundation
import LocalAuthentication
import UIKit
import UserNotifications
import WidgetKit

@MainActor
final class PhoneStore: ObservableObject {
    @Published var projects: [PhoneProject] = []
    @Published var loading = false
    @Published var loadedAt: Date?
    @Published var errors: [String] = []
    /// Providers whose newest read failed: their rows are the last ones read successfully.
    @Published var stale: Set<ProviderKind> = []
    @Published var running: [String: String] = [:]      // project key → state of the deploy being followed
    @Published var message: String?
    @Published var messageIsError = false
    /// A project to show, from a widget link or a notification.
    @Published var openKey: String?
    /// The iCloud Keychain item was read once (off the main thread); until then "no account" is not sure.
    @Published var booted = false
    @Published var demo: Bool {
        didSet { UserDefaults.standard.set(demo, forKey: "demo"); Task { await reload() } }
    }
    /// "Do not use the Mac's keys on this iPhone": a local choice, the Mac keeps sharing them.
    @Published var ignoreLink: Bool {
        didSet { UserDefaults.standard.set(ignoreLink, forKey: "ignoreMacLink"); Task { await reload() } }
    }

    enum TokenKey: String, CaseIterable { case vercel, vercelTeam, render, github }

    private var again = false
    private var teamCache: (token: String, id: String?)?
    private var deployIds: [String: String] = [:]       // project key → id of the deploy being followed

    init() {
        #if DEBUG
        let argDemo = ProcessInfo.processInfo.arguments.contains("-demo")
        #else
        let argDemo = false
        #endif
        demo = argDemo || UserDefaults.standard.bool(forKey: "demo")
        ignoreLink = UserDefaults.standard.bool(forKey: "ignoreMacLink")
        // The last state at once, then the network: the list is never empty only because it is loading.
        if !demo, let last = Background.loadLast() { projects = Self.sorted(last.projects); loadedAt = last.at }
    }

    /// The keys the Mac app handed over through iCloud Keychain (shared/PhoneLink.swift), if any.
    @Published var linked: LinkedKeys?

    var hasAccount: Bool { token(.vercel) != nil || token(.render) != nil }
    /// A key typed (or scanned) on this phone wins; otherwise the one from the Mac.
    func token(_ k: TokenKey) -> String? { ownToken(k) ?? linkedToken(k) }
    func ownToken(_ k: TokenKey) -> String? { Keychain.get(k.rawValue).flatMap { $0.isEmpty ? nil : $0 } }
    func linkedToken(_ k: TokenKey) -> String? {
        guard let l = linked, !ignoreLink else { return nil }
        let v: String
        switch k { case .vercel: v = l.vercel; case .vercelTeam: v = l.vercelTeam; case .render: v = l.render; case .github: v = l.github }
        return v.isEmpty ? nil : v
    }
    /// iCloud Keychain can take a minute after the Mac wrote: read again when the app comes back.
    /// Synced items can be slow to read, so never on the main thread.
    func refreshLink() async {
        let l = await Task.detached { PhoneLink.read() }.value
        if l != linked { linked = l }
        booted = true
    }
    var linkAvailable: Bool { PhoneLink.group != nil }

    /// Keys from the Mac's QR code: kept on this phone only, like typed ones. Empty fields keep what
    /// is already here (a code without a GitHub token does not remove the one typed on the phone).
    @discardableResult
    func adopt(_ k: LinkedKeys) -> Bool {
        var ok = true
        let pairs: [(TokenKey, String)] = [(.vercel, k.vercel), (.vercelTeam, k.vercelTeam), (.render, k.render), (.github, k.github)]
        for (key, v) in pairs where !v.isEmpty { ok = Keychain.set(key.rawValue, v) && ok }
        if !ok { say(L("Could not save every key in this device's keychain. Try again.",
                       "Konnte nicht jeden Schlüssel im Schlüsselbund dieses Geräts sichern. Versuch es noch einmal."), error: true) }
        if demo { demo = false } else { Task { await reload() } }
        return ok
    }

    /// Removes every key typed or scanned on this phone. The Mac's iCloud item stays (it is the Mac's).
    func forgetOwnKeys() {
        for k in TokenKey.allCases { Keychain.set(k.rawValue, "") }
        teamCache = nil
        Task { await reload() }
    }

    var waiting: [PhoneProject] { projects.filter { $0.group == .waiting } }
    var waitingPRs: Int {
        // Projects of one repo share commits and PRs: count each repo once.
        var perRepo: [String: Int] = [:]
        for p in waiting { perRepo[p.repo ?? p.key] = max(perRepo[p.repo ?? p.key] ?? 0, p.pendingPRs ?? 0) }
        return perRepo.values.reduce(0, +)
    }

    func say(_ text: String, error: Bool = false) {
        message = text; messageIsError = error
        UIAccessibility.post(notification: .announcement, argument: text)
    }

    // MARK: Loading

    /// Reads everything. A call while a read runs (the demo switch, new keys) reads again right after.
    func reload() async {
        guard !loading else { again = true; return }
        loading = true; defer { loading = false }
        repeat { again = false; await load() } while again && !Task.isCancelled
    }

    private func load() async {
        await refreshLink()
        if demo {
            projects = DemoData.projects(); loadedAt = Date(); errors = []; stale = []; writeSnapshot(); return
        }
        let previous = projects.isEmpty ? (Background.loadLast()?.projects ?? []) : projects
        var all: [PhoneProject] = [], errs: [String] = [], failed: Set<ProviderKind> = []
        if token(.vercel) != nil {
            do { all += try await vercel().projects() }
            catch { errs.append("Vercel: " + describe(error, .vercel)); failed.insert(.vercel) }
        }
        if let r = token(.render) {
            do { all += try await Render(key: r).projects() }
            catch { errs.append("Render: " + describe(error, .render)); failed.insert(.render) }
        }
        // iOS ended the background time: keep what was there, write nothing half-done.
        if Task.isCancelled { return }
        await fillFromGitHub(&all)
        if Task.isCancelled { return }
        // A provider that failed keeps its last rows: an outage or a spent limit is not "nothing waits".
        for k in failed { all += previous.filter { $0.provider == k } }
        projects = Self.sorted(all)
        errors = errs; stale = failed; loadedAt = Date()
        writeSnapshot()
        await updateBadge()
        // What the person has seen; the background refresh only notes what is new after this.
        Background.saveLast(projects)
    }

    /// One GitHub read per repo and branch, then one per other live commit of it (the open PRs are
    /// the repo's, so they are read once). At most four at a time.
    private func fillFromGitHub(_ all: inout [PhoneProject]) async {
        let gh = GitHub(token: token(.github))
        func rb(_ p: PhoneProject) -> String? { guard let r = p.repo, let b = p.branch else { return nil }; return r + "@" + b }
        var first: [String: PhoneProject] = [:]
        for p in all { if let k = rb(p), first[k] == nil { first[k] = p } }
        let filled = await Self.fillAll(gh, first.map { ($0.key, $0.value, nil) })
        var second: [String: (PhoneProject, (Int, Bool)?)] = [:]
        for p in all {
            guard let k = rb(p), let f = filled[k], f.liveSha != p.liveSha else { continue }
            second[k + "@" + (p.liveSha ?? "")] = (p, f.openPRs.map { ($0, f.openPRsCapped) })
        }
        let more = await Self.fillAll(gh, second.map { ($0.key, $0.value.0, $0.value.1) })
        for i in all.indices {
            guard let k = rb(all[i]), let f = filled[k] else { continue }
            if f.liveSha == all[i].liveSha { all[i] = .merging(all[i], f) }
            else if let m = more[k + "@" + (all[i].liveSha ?? "")] { all[i] = .merging(all[i], m) }
        }
    }

    nonisolated private static func fillAll(_ gh: GitHub, _ jobs: [(String, PhoneProject, (Int, Bool)?)]) async -> [String: PhoneProject] {
        var out: [String: PhoneProject] = [:]
        await withTaskGroup(of: (String, PhoneProject).self) { g in
            var n = 0
            for (key, p, prs) in jobs {
                if n >= 4, let (k, v) = await g.next() { out[k] = v; n -= 1 }
                g.addTask { var x = p; await gh.fill(&x, openPRs: prs); return (key, x) }
                n += 1
            }
            for await (k, v) in g { out[k] = v }
        }
        return out
    }

    /// Building and failed first; waiting by PRs, then the longest waiting; the rest by name.
    static func sorted(_ all: [PhoneProject]) -> [PhoneProject] {
        all.sorted { a, b in
            if a.group != b.group { return a.group.rawValue < b.group.rawValue }
            if a.group == .waiting {
                if (a.pendingPRs ?? 0) != (b.pendingPRs ?? 0) { return (a.pendingPRs ?? 0) > (b.pendingPRs ?? 0) }
                let da = a.oldestPendingAt ?? .distantFuture, db = b.oldestPendingAt ?? .distantFuture
                if da != db { return da < db }
            }
            return a.name.lowercased() < b.name.lowercased()
        }
    }

    /// An error in words; a refused key that came from the Mac says where to fix it.
    func describe(_ error: Error, _ provider: ProviderKind) -> String {
        let key: TokenKey = provider == .vercel ? .vercel : .render
        if let e = error as? APIError, e.status == 401, ownToken(key) == nil, linkedToken(key) != nil {
            return L("The key from the Mac was refused. Connect again in the Mac app (Settings → iPhone).",
                     "Der Schlüssel vom Mac wurde abgelehnt. Verbinde in der Mac-App neu (Einstellungen → iPhone).")
        }
        return explain(error)
    }

    // MARK: Deploy, cancel and rollback (Face ID first)

    func authenticate(_ reason: String) async -> Bool {
        let ctx = LAContext()
        var err: NSError?
        // Face ID or Touch ID, with the passcode as a fallback.
        guard ctx.canEvaluatePolicy(.deviceOwnerAuthentication, error: &err) else {
            say(L("Set a passcode on this device to deploy from it.", "Lege einen Code für dieses Gerät fest, um von hier zu deployen."), error: true)
            return false
        }
        do { return try await ctx.evaluatePolicy(.deviceOwnerAuthentication, localizedReason: reason) }
        catch let e as LAError {
            switch e.code {
            case .userCancel, .systemCancel, .appCancel, .userFallback:
                say(L("Canceled. Nothing was started.", "Abgebrochen. Es wurde nichts gestartet."))
            case .biometryLockout:
                say(L("Face ID is locked after too many tries. Unlock the device with its code, then try again.",
                      "Face ID ist nach zu vielen Versuchen gesperrt. Entsperre das Gerät mit dem Code und versuch es dann noch einmal."), error: true)
            case .authenticationFailed:
                say(L("Not recognized. Nothing was started.", "Nicht erkannt. Es wurde nichts gestartet."), error: true)
            default: say(e.localizedDescription, error: true)
            }
            return false
        } catch { say(error.localizedDescription, error: true); return false }
    }

    func deploy(_ p: PhoneProject) async {
        // Taken before Face ID: a second tap meanwhile must not start a second build.
        guard running[p.key] == nil else { return }
        running[p.key] = "starting"; defer { running[p.key] = nil; deployIds[p.key] = nil }
        guard await authenticate(L("Deploy \(p.name)", "\(p.name) deployen")) else { return }
        if demo { await simulate(p, L("Deploy started (demo).", "Deploy gestartet (Demo)."), L("\(p.name) is live (demo).", "\(p.name) ist live (Demo).")); return }
        let started = Date()
        do {
            let id: String
            switch p.provider {
            case .vercel: id = try await vercel().deploy(p)
            case .render: id = try await Render(key: token(.render) ?? "").deploy(p)
            }
            say(L("Deploy of \(p.name) started.", "Deploy von \(p.name) gestartet."))
            await follow(p, id)
        } catch let e as URLError where e.code != .cancelled {
            // The request may have arrived although its answer did not: look before calling it failed.
            if let id = try? await recentDeploy(p, since: started) {
                say(L("The answer got lost, but a deploy of \(p.name) runs. Following it.",
                      "Die Antwort ging verloren, aber ein Deploy von \(p.name) läuft. Er wird verfolgt."))
                await follow(p, id)
            } else { say(explain(e), error: true) }
        } catch { say(describe(error, p.provider), error: true) }
    }

    private func recentDeploy(_ p: PhoneProject, since: Date) async throws -> String? {
        switch p.provider {
        case .vercel: try await vercel().recentDeploy(p, since: since)
        case .render: try await Render(key: token(.render) ?? "").recentDeploy(p, since: since)
        }
    }

    /// The build this app follows, else the newest attempt the list shows.
    func buildId(_ p: PhoneProject) -> String? { deployIds[p.key] ?? (p.building ? p.latestId : nil) }

    func cancelBuild(_ p: PhoneProject) async {
        guard let id = buildId(p) else { return }
        guard await authenticate(L("Cancel the build of \(p.name)", "Build von \(p.name) abbrechen")) else { return }
        if demo { say(L("Build of \(p.name) canceled (demo).", "Build von \(p.name) abgebrochen (Demo).")); return }
        do {
            switch p.provider {
            case .vercel: try await vercel().cancel(id)
            case .render: try await Render(key: token(.render) ?? "").cancel(p, id)
            }
            say(L("Build of \(p.name) canceled.", "Build von \(p.name) abgebrochen."))
            if running[p.key] == nil { await reload() }    // a followed deploy ends its loop itself
        } catch { say(describe(error, p.provider), error: true) }
    }

    func rollbackTarget(_ p: PhoneProject) async -> RollbackTarget? {
        if demo {
            return RollbackTarget(id: "demo", sha: p.liveSha.map { String($0.prefix(7)) }, title: p.liveMsg, at: p.liveAt?.addingTimeInterval(-86400))
        }
        do {
            switch p.provider {
            case .vercel: return try await vercel().rollbackTarget(p)
            case .render: return try await Render(key: token(.render) ?? "").rollbackTarget(p)
            }
        } catch { say(describe(error, p.provider), error: true); return nil }
    }

    func rollback(_ p: PhoneProject, to target: RollbackTarget) async {
        guard running[p.key] == nil else { return }
        running[p.key] = "rollback"; defer { running[p.key] = nil; deployIds[p.key] = nil }
        guard await authenticate(L("Roll back \(p.name)", "\(p.name) zurückrollen")) else { return }
        if demo { await simulate(p, L("Rolling back (demo).", "Wird zurückgerollt (Demo)."), L("Rolled back (demo).", "Zurückgerollt (Demo).")); return }
        do {
            switch p.provider {
            case .vercel:
                let v = try await vercel()
                try await v.rollback(p, to: target.id)
                say(L("\(p.name) is rolling back.", "\(p.name) wird zurückgerollt."))
                // Vercel moves the domain to the old deploy: done when the project's production target is it.
                await follow(p, target.id, rollback: true, limit: 5 * 60) { try await v.productionId(p) == target.id ? "ready" : "rollback" }
            case .render:
                let r = Render(key: token(.render) ?? "")
                let id = try await r.rollback(p, to: target.id)
                say(L("\(p.name) is rolling back.", "\(p.name) wird zurückgerollt."))
                if let id { await follow(p, id, rollback: true) } else { try? await Task.sleep(for: .seconds(4)); await reload() }
            }
        } catch { say(describe(error, p.provider), error: true) }
    }

    /// Render: pause, resume or restart, after Face ID.
    func serviceAction(_ p: PhoneProject, _ a: RenderAction) async {
        guard p.provider == .render, running[p.key] == nil else { return }
        running[p.key] = "starting"; defer { running[p.key] = nil }
        guard await authenticate(a.title.replacingOccurrences(of: " …", with: "") + ": " + p.name) else { return }
        if demo { say("\(p.name): \(a.done) (demo)."); return }
        do {
            try await Render(key: token(.render) ?? "").service(p, a)
            say("\(p.name): \(a.done).")
            try? await Task.sleep(for: .seconds(2)); await reload()
        } catch { say(describe(error, p.provider), error: true) }
    }

    // MARK: History and build logs (read only)

    func history(_ p: PhoneProject) async -> [DeployRecord]? {
        if demo { return DemoData.history(p) }
        do {
            switch p.provider {
            case .vercel: return try await vercel().history(p)
            case .render: return try await Render(key: token(.render) ?? "").history(p)
            }
        } catch { say(describe(error, p.provider), error: true); return nil }
    }

    /// The log of one deploy (else the newest attempt), masked before it is kept, shown or copied.
    /// Not masked means not shown: the raw text is never returned.
    func buildLog(_ p: PhoneProject, _ d: DeployRecord?) async -> BuildLog {
        let raw: [String]
        do {
            if demo { raw = DemoData.log(p) } else {
                switch p.provider {
                case .vercel:
                    guard let id = d?.id ?? p.latestId else { return .init(problem: L("No deploy to read.", "Kein Deploy zum Lesen.")) }
                    raw = try await vercel().buildLog(id)
                case .render:
                    let r = Render(key: token(.render) ?? "")
                    var pick = d
                    if pick == nil { pick = try await r.history(p, limit: 1).first }
                    guard let d = pick else {
                        return .init(problem: L("No deploy to read.", "Kein Deploy zum Lesen."))
                    }
                    raw = try await r.buildLog(p, d)
                }
            }
        } catch { return .init(problem: describe(error, p.provider)) }
        guard let masked = LogMask.mask(raw) else {
            return .init(problem: L("The log cannot be masked on this device, so it is not shown.",
                                    "Das Log kann auf diesem Gerät nicht maskiert werden, daher wird es nicht gezeigt."))
        }
        if masked.isEmpty { return .init(problem: L("\(p.provider.rawValue) has no log lines for this deploy.", "\(p.provider.rawValue) hat keine Log-Zeilen zu diesem Deploy.")) }
        let ex = LogMask.excerpt(masked)
        return .init(lines: ex.lines, errorAt: ex.errorAt, full: String(masked.joined(separator: "\n").suffix(60_000)))
    }

    private func vercel() async throws -> Vercel {
        let v = token(.vercel) ?? ""
        if let team = token(.vercelTeam) { return Vercel(token: v, team: team) }
        // Asked once per token, not on every poll.
        if let c = teamCache, c.token == v { return Vercel(token: v, team: c.id) }
        let id = try await Vercel.resolveTeam(token: v)
        teamCache = (v, id)
        return Vercel(token: v, team: id)
    }

    private func status(_ p: PhoneProject, _ id: String) async throws -> String {
        switch p.provider {
        case .vercel: try await vercel().status(id)
        case .render: try await Render(key: token(.render) ?? "").status(p, id)
        }
    }

    /// Polls every 6 seconds until the deploy ends, at most 20 minutes. When the app goes to the
    /// background meanwhile, iOS gives it some more time (and on iOS 26 a progress in the system),
    /// and the end comes as a notification.
    private func follow(_ p: PhoneProject, _ id: String, rollback: Bool = false, limit: TimeInterval = 20 * 60,
                        check: (() async throws -> String)? = nil) async {
        deployIds[p.key] = rollback ? nil : id
        running[p.key] = rollback ? "rollback" : "queued"
        let keep = KeepAlive.start(title: rollback ? L("Rolling back \(p.name)", "\(p.name) wird zurückgerollt") : L("Deploying \(p.name)", "\(p.name) wird deployt"),
                                   subtitle: p.provider.rawValue)
        let live = LiveDeploy.start(p, rollback: rollback)
        let start = Date(), end = start.addingTimeInterval(limit)
        var outcome: String?, ok = false, failed = false
        while Date() < end && !Task.isCancelled {
            try? await Task.sleep(for: .seconds(6))
            let s: String
            do { s = try await (check ?? { try await self.status(p, id) })().lowercased() } catch { continue }
            if !rollback { running[p.key] = s }
            keep.update(PhoneProject.stateWord(s), fraction: min(Date().timeIntervalSince(start) / 300, 0.95))
            live.update(rollback ? PhoneProject.stateWord("rollback") : PhoneProject.stateWord(s))
            if ["ready", "live", "succeeded"].contains(s) {
                ok = true
                outcome = rollback ? L("\(p.name) is rolled back.", "\(p.name) ist zurückgerollt.") : L("\(p.name) is live.", "\(p.name) ist live.")
                break
            }
            if PhoneProject.failedStates.contains(s) || ["deactivated", "cancelled"].contains(s) {
                outcome = "\(p.name): \(PhoneProject.stateWord(s))"; failed = true; break
            }
        }
        let text = outcome ?? L("\(p.name): no final state after \(Int(limit / 60)) minutes. Check it on \(p.provider.rawValue).",
                                "\(p.name): nach \(Int(limit / 60)) Minuten kein Endstand. Prüfe es bei \(p.provider.rawValue).")
        say(text, error: !ok)
        keep.finish(success: ok)
        live.finish(ok ? .live : failed ? .failed : .unknown,
                    ok ? (rollback ? L("Rolled back", "Zurückgerollt") : L("Live", "Live")) : failed ? text.replacingOccurrences(of: "\(p.name): ", with: "")
                       : L("No final state", "Kein Endstand"))
        if UIApplication.shared.applicationState != .active { await Notes.post(text, project: p.key) }
        await reload()
    }

    private func simulate(_ p: PhoneProject, _ start: String, _ done: String) async {
        running[p.key] = "building"; say(start)
        let live = LiveDeploy.start(p, rollback: false)
        live.update(PhoneProject.stateWord("building"))
        try? await Task.sleep(for: .seconds(3))
        live.finish(.live, L("Live (demo)", "Live (Demo)"))
        if let i = projects.firstIndex(where: { $0.key == p.key }) {
            projects[i].liveSha = projects[i].headSha; projects[i].latestState = p.provider == .vercel ? "READY" : "live"
            projects[i].liveState = projects[i].latestState; projects[i].pendingCommits = 0; projects[i].pendingPRs = 0
            projects[i].pendingTitles = []
        }
        say(done)
        writeSnapshot()
    }

    // MARK: Widget snapshot, badge and notifications

    func makeSnapshot() -> DeploySnapshot {
        let rows: [DeploySnapshot.Project] = projects.compactMap { p in
            guard let s = p.snapshotStatus else { return nil }
            return .init(name: p.name, platform: p.provider.rawValue, status: s, commits: p.pendingCommits ?? 0,
                         prs: p.pendingPRs ?? 0, since: s == .waiting ? p.oldestPendingAt : p.liveAt, message: p.headMsg)
        }
        let order: [DeploySnapshot.Project.Status: Int] = [.building: 0, .failed: 1, .waiting: 2]
        let sorted = rows.sorted { (order[$0.status]!, -$0.prs, $0.name) < (order[$1.status]!, -$1.prs, $1.name) }
        // No saving on the phone: the Mac app knows what auto-deploy cost before; the widget hides the line.
        return DeploySnapshot(at: loadedAt ?? Date(), demo: demo, waitingProjects: waiting.count,
                              waitingCommits: waiting.reduce(0) { $0 + ($1.pendingCommits ?? 0) }, waitingPRs: waitingPRs,
                              building: rows.filter { $0.status == .building }.count,
                              failed: rows.filter { $0.status == .failed }.count, saving: nil, projects: Array(sorted.prefix(10)),
                              language: appIsGerman ? "de" : "en", connected: demo || hasAccount)
    }

    func writeSnapshot() {
        QuickActions.update(projects)
        Spotlight.index(projects, demo: demo)
        guard let url = DeploySnapshot.groupURL else { return }
        let snap = makeSnapshot()
        let old = DeploySnapshot.read(url)
        try? FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
        try? DeploySnapshot.encoder.encode(snap).write(to: url, options: .atomic)
        // Widget reloads have a daily budget: only when the picture changed, or every 15 minutes so its
        // "as of" time stays true.
        let last = UserDefaults.standard.object(forKey: "widgetReloadAt") as? Date ?? .distantPast
        var same = old; same?.at = snap.at
        if same != snap || Date().timeIntervalSince(last) > 15 * 60 {
            UserDefaults.standard.set(Date(), forKey: "widgetReloadAt")
            WidgetCenter.shared.reloadAllTimelines()    // both widgets read the same snapshot
            ControlCenter.shared.reloadAllControls()
        }
    }

    /// The number on the app icon: waiting PRs, when notifications are on.
    func updateBadge() async {
        let on = UserDefaults.standard.bool(forKey: "notify")
        try? await UNUserNotificationCenter.current().setBadgeCount(on && !demo ? waitingPRs : 0)
    }

    /// After a background refresh: a note for what newly failed or newly waits. Only local notifications.
    func notifyChanges(from before: [PhoneProject]) async {
        guard UserDefaults.standard.bool(forKey: "notify") else { return }
        let old = Dictionary(before.map { ($0.key, $0) }, uniquingKeysWith: { a, _ in a })
        // A provider with no rows before (a new key, or a run that failed) has nothing to compare with:
        // all its projects would look new.
        let seen = Set(before.map(\.provider))
        var lines: [(key: String, text: String)] = []
        for p in projects where seen.contains(p.provider) && !stale.contains(p.provider) {
            let o = old[p.key]
            if p.failed && !(o?.failed ?? false) { lines.append((p.key, L("\(p.name) failed", "\(p.name) fehlgeschlagen"))) }
            else if p.group == .waiting && o?.group != .waiting { lines.append((p.key, L("\(p.name) is waiting", "\(p.name) wartet"))) }
        }
        guard !lines.isEmpty else { return }
        let body = lines.prefix(4).map(\.text).joined(separator: " · ")
            + (lines.count > 4 ? L(" · +\(lines.count - 4) more", " · +\(lines.count - 4) weitere") : "")
        await Notes.post(body, project: lines.count == 1 ? lines[0].key : nil, id: "changes-" + lines.map(\.text).joined(separator: "|"), news: true)
    }
}

/// Local notifications: grouped in one thread; the same news replaces itself instead of piling up.
/// Actions on a notification: open the project, or no more news today (a deploy started here still reports its end).
enum Notes {
    static let category = "deploy-center.news"
    static let openAction = "open", muteAction = "mute-today"
    static let mutedKey = "notesMutedUntil"

    static func registerActions() {
        let open = UNNotificationAction(identifier: openAction, title: L("Open", "Öffnen"), options: [.foreground])
        let mute = UNNotificationAction(identifier: muteAction, title: L("Mute for today", "Heute stumm"), options: [])
        UNUserNotificationCenter.current().setNotificationCategories([
            UNNotificationCategory(identifier: category, actions: [open, mute], intentIdentifiers: [], options: [])
        ])
    }
    /// Until the start of tomorrow, in this device's calendar.
    static func muteToday(now: Date = Date()) {
        let cal = Calendar.current
        UserDefaults.standard.set(cal.date(byAdding: .day, value: 1, to: cal.startOfDay(for: now)), forKey: mutedKey)
    }
    static var muted: Bool { (UserDefaults.standard.object(forKey: mutedKey) as? Date).map { Date() < $0 } ?? false }

    static func post(_ body: String, project: String?, id: String? = nil, news: Bool = false) async {
        if news && muted { return }
        let c = UNMutableNotificationContent()
        c.title = "Deploy Center"; c.body = body; c.sound = .default
        c.threadIdentifier = "deploy-center"
        c.categoryIdentifier = category
        if let project { c.userInfo = ["project": project] }
        let r = UNNotificationRequest(identifier: id ?? "deploy-\(project ?? "")", content: c, trigger: nil)
        try? await UNUserNotificationCenter.current().add(r)
    }
}

extension PhoneProject {
    /// Repo facts from `filled` (same repo, branch and live commit), deploy facts from `own`.
    static func merging(_ own: PhoneProject, _ filled: PhoneProject) -> PhoneProject {
        var x = own
        x.headSha = filled.headSha; x.headAt = filled.headAt; x.headMsg = filled.headMsg
        x.pendingCommits = filled.pendingCommits; x.pendingPRs = filled.pendingPRs; x.oldestPendingAt = filled.oldestPendingAt
        x.compareStatus = filled.compareStatus; x.rewritten = filled.rewritten; x.openPRs = filled.openPRs
        x.pendingTitles = filled.pendingTitles; x.openPRsCapped = filled.openPRsCapped; x.pendingCapped = filled.pendingCapped
        x.fetchError = own.fetchError ?? filled.fetchError
        return x
    }
}
