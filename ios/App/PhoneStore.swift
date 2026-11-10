// Deploy Center for iPhone — The state: projects from Vercel, Render and GitHub, deploys and rollbacks.
// Everything goes from this phone straight to the person's own accounts. There is no server of ours.

import Foundation
import LocalAuthentication
import Network
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
    /// The message is an error: it stays longer and VoiceOver hears it as such.
    @Published var messageIsError = false
    @Published var demo: Bool { didSet { UserDefaults.standard.set(demo, forKey: "demo"); Task { await reload() } } }
    /// Set from the iOS Settings-like switch "Unlock on open": the list stays covered until Face ID passes.
    @Published var locked = false
    /// No network path: loads are skipped instead of waiting for three time-outs.
    @Published var offline = false
    /// A key was refused (401/403) in the last load: the list offers the settings.
    @Published var keyRefused = false
    /// Counts finished deploys and rollbacks, for the haptic feedback; `outcomeOK` says how it went.
    @Published var outcome = 0
    private(set) var outcomeOK = true

    enum TokenKey: String, CaseIterable {
        case vercel, vercelTeam, render, github
        /// The same key in what the Mac hands over.
        var linked: WritableKeyPath<LinkedKeys, String> {
            switch self {
            case .vercel: \.vercel
            case .vercelTeam: \.vercelTeam
            case .render: \.render
            case .github: \.github
            }
        }
    }

    /// One store for the app and the background refresh, so what the background read shows up on return.
    static let shared = PhoneStore()
    private let path = NWPathMonitor()

    private init() {
        let args = ProcessInfo.processInfo.arguments
        demo = args.contains("-demo") || UserDefaults.standard.bool(forKey: "demo")
        locked = Self.lockOnOpen && !demo
        path.pathUpdateHandler = { p in
            let off = p.status != .satisfied
            Task { @MainActor in
                let store = PhoneStore.shared
                guard store.offline != off else { return }
                store.offline = off
                // Back online after a skipped load: read again.
                if !off && store.hasAccount && !store.demo { await store.reload() }
            }
        }
        path.start(queue: DispatchQueue(label: "app.deploycenter.ios.path"))
    }

    func say(_ text: String) { message = text; messageIsError = false }
    func fail(_ text: String) { message = text; messageIsError = true }
    private func finished(_ ok: Bool) { outcomeOK = ok; outcome += 1 }

    /// The keys the Mac app handed over through iCloud Keychain (shared/PhoneLink.swift), if any.
    /// Ignored after "Remove all keys from this iPhone" until the person connects again.
    @Published var linked: LinkedKeys? = PhoneStore.readLink()
    static var ignoreLink: Bool {
        get { UserDefaults.standard.bool(forKey: "ignoreLink") }
        set { UserDefaults.standard.set(newValue, forKey: "ignoreLink") }
    }
    private static func readLink() -> LinkedKeys? { ignoreLink ? nil : PhoneLink.read() }

    // MARK: App lock (optional)

    static var lockOnOpen: Bool { UserDefaults.standard.bool(forKey: "lockOnOpen") }

    /// Face ID, Touch ID or the code. A device without any code cannot lock: it stays open.
    func unlock() async {
        guard locked, !unlocking else { return }
        unlocking = true
        defer { unlocking = false }
        let ctx = LAContext()
        guard ctx.canEvaluatePolicy(.deviceOwnerAuthentication, error: nil) else { locked = false; return }
        if (try? await ctx.evaluatePolicy(.deviceOwnerAuthentication, localizedReason: L("Unlock Deploy Center", "Deploy Center entsperren"))) == true {
            locked = false
        }
    }
    private var unlocking = false
    /// Only on going to the background: the Face ID sheet itself makes the app inactive.
    func lockIfWanted() { if Self.lockOnOpen && !demo { locked = true } }

    /// "Face ID", "Touch ID", "Optic ID" or the device code, for texts that name it.
    var unlockName: String {
        let ctx = LAContext()
        _ = ctx.canEvaluatePolicy(.deviceOwnerAuthenticationWithBiometrics, error: nil)   // sets biometryType
        switch ctx.biometryType {
        case .faceID: return "Face ID"
        case .touchID: return "Touch ID"
        case .opticID: return "Optic ID"
        default: return L("the device code", "dem Gerätecode")
        }
    }

    // MARK: Removing everything from this phone

    /// Deletes the keys typed or scanned here, forgets the Mac link on this phone (the Mac and iCloud keep theirs),
    /// and clears what the widget and the notes kept.
    func removeAllKeys() {
        for k in TokenKey.allCases { setOwnToken(k, "") }
        Self.ignoreLink = true; linked = nil
        teamCache = nil
        ETags.shared.removeAll()
        projects = []; errors = []; loadedAt = nil; keyRefused = false
        try? FileManager.default.removeItem(at: Background.lastURL)
        if let url = DeploySnapshot.groupURL { try? FileManager.default.removeItem(at: url) }
        WidgetCenter.shared.reloadAllTimelines()
    }

    var hasAccount: Bool { token(.vercel) != nil || token(.render) != nil }
    /// A key typed (or scanned) on this phone wins; otherwise the one from the Mac.
    func token(_ k: TokenKey) -> String? { ownToken(k) ?? linkedToken(k) }

    /// The keychain is read once per key, not on every redraw. A failed read (the device still locked
    /// after a restart) is not kept, so it does not count as "no key" until the app quits.
    private var ownCache: [TokenKey: String?] = [:]
    func ownToken(_ k: TokenKey) -> String? {
        if let kept = ownCache[k] { return kept }
        switch Keychain.lookup(k.rawValue) {
        case .found(let v): let t = v.isEmpty ? nil : v; ownCache[k] = .some(t); return t
        case .missing: ownCache[k] = .some(nil); return nil
        case .failed: return nil
        }
    }
    /// Every write goes through here, so the kept copy never differs from the keychain.
    @discardableResult
    func setOwnToken(_ k: TokenKey, _ value: String) -> Bool {
        let ok = Keychain.set(k.rawValue, value)
        ownCache[k] = nil
        return ok
    }
    /// The keychain may have changed while the app was away (or was locked): read it again.
    func forgetKeptTokens() { ownCache = [:] }
    func linkedToken(_ k: TokenKey) -> String? {
        guard let v = linked?[keyPath: k.linked], !v.isEmpty else { return nil }
        return v
    }
    /// iCloud Keychain can take a minute after the Mac wrote: read again when the app comes back.
    func refreshLink() { let l = Self.readLink(); if l != linked { linked = l } }
    /// "Check again" in the connect sheet: the person wants the Mac link back.
    func useLinkAgain() { Self.ignoreLink = false; refreshLink() }
    var linkAvailable: Bool { PhoneLink.group != nil }

    /// Keys from the Mac's QR code: kept on this phone only, like typed ones.
    /// An empty field in the code keeps the key already on this phone; the Vercel team goes with the Vercel token.
    func adopt(_ k: LinkedKeys) {
        func given(_ v: String) -> Bool { !v.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty }
        for key in TokenKey.allCases where key != .vercelTeam && given(k[keyPath: key.linked]) {
            setOwnToken(key, k[keyPath: key.linked])
            if key == .vercel { setOwnToken(.vercelTeam, k.vercelTeam) }
        }
        // Leaving demo mode reloads by itself (didSet); otherwise reload once here.
        if demo { demo = false } else { Task { await reload() } }
    }

    var waiting: [PhoneProject] { projects.filter { $0.group == .waiting } }
    var waitingPRs: Int {
        // Projects of one repo share commits and PRs: count each repo once.
        var perRepo: [String: Int] = [:]
        for p in waiting { perRepo[p.repo ?? p.key] = max(perRepo[p.repo ?? p.key] ?? 0, p.pendingPRs ?? 0) }
        return perRepo.values.reduce(0, +)
    }

    // MARK: Loading

    /// At launch: the list as it was last seen, with its time, while the first load runs.
    /// Not fresh, so neither the widget nor the "seen" file is written from it.
    func showLast() {
        guard projects.isEmpty, !demo, hasAccount, let last = Background.readLast(), !last.isEmpty else { return }
        projects = last
        loadedAt = (try? FileManager.default.attributesOfItem(atPath: Background.lastURL.path)[.modificationDate]) as? Date
    }

    /// A reload asked for while one runs is not dropped: it runs once more right after.
    private var reloadAgain = false

    /// Returns once a load that started after the call has finished (also when one was already running).
    /// False when it was cut off (the background refresh ran out of time): then nothing was replaced.
    @discardableResult
    func reload() async -> Bool {
        if loading {
            reloadAgain = true
            while loading && !Task.isCancelled { try? await Task.sleep(for: .milliseconds(200)) }
            return !Task.isCancelled && lastLoadComplete
        }
        loading = true
        repeat {
            reloadAgain = false
            lastLoadComplete = await load()
        } while reloadAgain && !Task.isCancelled
        loading = false
        return lastLoadComplete
    }
    private var lastLoadComplete = false

    /// The resolved Vercel team, per token: asked once, not on every status poll.
    private var teamCache: (token: String, team: String?, teams: Int)?
    private func vercelTeam(_ v: String) async throws -> (id: String?, teams: Int) {
        if let t = token(.vercelTeam) { return (t, 1) }
        if let c = teamCache, c.token == v { return (c.team, c.teams) }
        let r = try await Vercel.resolveTeam(token: v)
        teamCache = (v, r.id, r.teams)
        return r
    }

    private func load() async -> Bool {
        refreshLink()
        if demo {
            projects = DemoData.projects(); loadedAt = Date(); errors = []; keyRefused = false; writeSnapshot(); return true
        }
        // Offline: keep what is there; the list says so, and the path monitor reloads when it is back.
        if offline { return false }
        var all: [PhoneProject] = [], errs: [String] = [], refused = false
        func note(_ provider: String, _ error: Error) {
            if (error as? APIError)?.isAuth == true { refused = true }
            errs.append("\(provider): \(error.localizedDescription)")
        }
        if let v = token(.vercel) {
            do {
                teamCache = nil   // a new load may follow a new team; the polls in between reuse it
                let team = try await vercelTeam(v)
                if team.id == nil && team.teams > 1 {
                    errs.append(L("Vercel: \(team.teams) teams, so only the personal account is shown. Enter a team id in Settings.",
                                  "Vercel: \(team.teams) Teams, darum nur das persönliche Konto. Team-ID in den Einstellungen eintragen."))
                }
                let r = try await Vercel(token: v, team: team.id).projects()
                all += r.list; errs += r.notes.map { "Vercel: " + $0 }
            } catch { note("Vercel", error) }
        }
        if let r = token(.render) {
            do {
                let x = try await Render(key: r).projects()
                all += x.list; errs += x.notes.map { "Render: " + $0 }
            } catch { note("Render", error) }
        }
        // Cut off by iOS (end of the background time): keep what is there instead of an empty list.
        if Task.isCancelled { return false }
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
        // The live commit differs per project; compare again only where it differs from the sample,
        // in parallel too (at most four at a time).
        var again: [Int] = []
        for i in all.indices {
            guard let r = all[i].repo, let b = all[i].branch, let filled = cache[r + "@" + b] else { continue }
            if filled.liveSha == all[i].liveSha { all[i] = PhoneProject.merging(all[i], filled) } else { again.append(i) }
        }
        let snapshot = all
        await withTaskGroup(of: (Int, PhoneProject).self) { g in
            var n = 0
            for i in again {
                if n >= 4, let (j, p) = await g.next() { all[j] = p; n -= 1 }
                g.addTask { var p = snapshot[i]; await gh.fill(&p); return (i, p) }
                n += 1
            }
            for await (j, p) in g { all[j] = p }
        }
        if Task.isCancelled { return false }
        projects = all.sorted { ($0.group.rawValue, $0.name.lowercased()) < ($1.group.rawValue, $1.name.lowercased()) }
        errors = errs; loadedAt = Date(); keyRefused = refused
        writeSnapshot()
        // What the person has seen; the background refresh only notes what is new after this.
        Background.writeLast(projects)
        return true
    }

    // MARK: Deploy and rollback (Face ID first)

    func authenticate(_ reason: String) async -> Bool {
        let ctx = LAContext()
        var err: NSError?
        // Face ID or Touch ID, with the passcode as a fallback.
        guard ctx.canEvaluatePolicy(.deviceOwnerAuthentication, error: &err) else {
            fail(L("Set a passcode on this device to deploy from it.", "Lege einen Code für dieses Gerät fest, um von hier zu deployen."))
            return false
        }
        return (try? await ctx.evaluatePolicy(.deviceOwnerAuthentication, localizedReason: reason)) ?? false
    }

    func deploy(_ p: PhoneProject) async {
        // Taken before Face ID, so a second tap cannot start a second (paid) build.
        guard running[p.key] == nil else { return }
        running[p.key] = "starting"
        defer { running[p.key] = nil }
        // The demo deploys nothing: no device code needed (App Review devices may have none).
        if demo { await simulate(p, L("Deploy started (demo).", "Deploy gestartet (Demo).")); return }
        guard await authenticate(L("Deploy \(p.name)", "\(p.name) deployen")) else { return }
        do {
            let id: String
            switch p.provider {
            case .vercel: id = try await vercel().deploy(p)
            case .render: id = try await Render(key: token(.render) ?? "").deploy(p)
            }
            say(L("Deploy of \(p.name) started.", "Deploy von \(p.name) gestartet."))
            await follow(p, id)
        } catch { fail(error.localizedDescription); finished(false) }
    }

    func rollbackTarget(_ p: PhoneProject) async -> RollbackTarget? {
        if demo {
            return RollbackTarget(id: "demo", sha: "a0b1c2d", message: L("The version before", "Der Stand davor"),
                                  at: Date().addingTimeInterval(-86400))
        }
        do {
            switch p.provider {
            case .vercel: return try await vercel().rollbackTarget(p)
            case .render: return try await Render(key: token(.render) ?? "").rollbackTarget(p)
            }
        } catch { fail(error.localizedDescription); return nil }
    }

    func rollback(_ p: PhoneProject, to target: RollbackTarget) async {
        guard running[p.key] == nil else { return }
        running[p.key] = "rolling back"
        defer { running[p.key] = nil }
        if demo { await simulate(p, L("Rolled back (demo).", "Zurückgerollt (Demo).")); return }
        guard await authenticate(L("Roll back \(p.name)", "\(p.name) zurückrollen")) else { return }
        do {
            switch p.provider {
            case .vercel: try await vercel().rollback(p, to: target.id)
            case .render: try await Render(key: token(.render) ?? "").rollback(p, to: target.id)
            }
            say(L("\(p.name) is rolling back.", "\(p.name) wird zurückgerollt."))
            await followRollback(p, target)
        } catch { fail(error.localizedDescription); finished(false) }
    }

    /// Until the old version is live: Vercel moves the domains to the old deploy (its id is live),
    /// Render builds a new deploy of the old commit (its commit is live). At most 5 minutes.
    private func followRollback(_ p: PhoneProject, _ target: RollbackTarget) async {
        let end = Date().addingTimeInterval(5 * 60)
        var live = false
        while Date() < end && !Task.isCancelled {
            try? await Task.sleep(for: .seconds(5))
            do {
                switch p.provider {
                case .vercel:
                    live = try await vercel().liveDeployId(p) == target.id
                case .render:
                    let s = try await Render(key: token(.render) ?? "").liveCommit(p)
                    live = target.sha != nil && s == target.sha
                }
            } catch { continue }
            if live { break }
        }
        if live { say(L("\(p.name) is back on the previous version.", "\(p.name) ist wieder auf dem vorigen Stand.")) }
        else {
            fail(L("\(p.name): rollback state unknown, please check on \(p.provider.rawValue).",
                   "\(p.name): Stand des Zurückrollens unbekannt, bitte bei \(p.provider.rawValue) prüfen."))
        }
        finished(live)
        await reload()
    }

    private func vercel() async throws -> Vercel {
        let v = token(.vercel) ?? ""
        return Vercel(token: v, team: try await vercelTeam(v).id)
    }

    /// Polls the new deploy every 6 seconds until it ends, at most 20 minutes.
    private func follow(_ p: PhoneProject, _ id: String) async {
        running[p.key] = "queued"
        defer { running[p.key] = nil }
        let end = Date().addingTimeInterval(20 * 60)
        var ended = false, lastError: String?
        while Date() < end {
            try? await Task.sleep(for: .seconds(6))
            let s: String
            do {
                switch p.provider {
                case .vercel: s = try await vercel().status(id)
                case .render: s = try await Render(key: token(.render) ?? "").status(p, id)
                }
            } catch { lastError = error.localizedDescription; continue }
            lastError = nil
            running[p.key] = s.lowercased()
            if ["ready", "live", "succeeded"].contains(s.lowercased()) {
                // After an Instant Rollback a ready deploy keeps no domain until one is promoted (Vercel docs).
                if p.provider == .vercel, await stagedOnly(id) {
                    fail(L("\(p.name) is built but not live: after a rollback, Vercel keeps the old deploy until you promote this one in the dashboard.",
                           "\(p.name) ist gebaut, aber nicht live: Nach einem Zurückrollen behält Vercel den alten Deploy, bis du diesen im Dashboard beförderst."))
                } else {
                    say(L("\(p.name) is live.", "\(p.name) ist live."))
                }
                finished(true)
                ended = true; break
            }
            if PhoneProject.failedStates.contains(s.lowercased()) || s.lowercased() == "deactivated" {
                fail("\(p.name): \(PhoneProject.stateName(s))"); finished(false); ended = true; break
            }
        }
        if !ended {
            fail(L("\(p.name): state unknown, please check on \(p.provider.rawValue).",
                   "\(p.name): Stand unbekannt, bitte bei \(p.provider.rawValue) prüfen.")
                + (lastError.map { " (\($0))" } ?? ""))
            finished(false)
        }
        await reload()
    }

    /// True when the ready deploy still has no production traffic after about 30 s. READY and the domain
    /// assignment are separate steps, so one look right after READY could be too early.
    private func stagedOnly(_ id: String) async -> Bool {
        for attempt in 0..<6 {
            if attempt > 0 { try? await Task.sleep(for: .seconds(6)) }
            guard let s = try? await vercel().readySubstate(id) else { return false }   // unknown: do not alarm
            if s.uppercased() != "STAGED" { return false }
        }
        return true
    }

    private func simulate(_ p: PhoneProject, _ text: String) async {
        running[p.key] = "building"; say(text)
        try? await Task.sleep(for: .seconds(3))
        if let i = projects.firstIndex(where: { $0.key == p.key }) {
            projects[i].liveSha = projects[i].headSha; projects[i].latestState = p.provider == .vercel ? "READY" : "live"
            projects[i].liveState = projects[i].latestState; projects[i].pendingCommits = 0; projects[i].pendingPRs = 0
        }
        running[p.key] = nil
        say(L("\(p.name) is live (demo).", "\(p.name) ist live (Demo)."))
        finished(true)
        writeSnapshot()
    }

    // MARK: Test connection (Settings)

    /// One line per account: who the key belongs to and how much it sees. Keys as typed, else the Mac's.
    func testConnection(vercel: String, team: String, render: String, github: String) async -> [(ok: Bool, text: String)] {
        func pick(_ typed: String, _ k: TokenKey) -> String? {
            let t = typed.trimmingCharacters(in: .whitespacesAndNewlines)
            return t.isEmpty ? linkedToken(k) : t
        }
        var out: [(Bool, String)] = []
        if let v = pick(vercel, .vercel) {
            do {
                let t: (id: String?, teams: Int)
                if let given = pick(team, .vercelTeam) { t = (given, 1) } else { t = try await Vercel.resolveTeam(token: v) }
                let a = try await Vercel(token: v, team: t.id).account()
                let where_: String
                if let id = t.id { where_ = L("team \(id)", "Team \(id)") }
                else if t.teams > 1 { where_ = L("personal account (\(t.teams) teams: enter a team id)", "persönliches Konto (\(t.teams) Teams: Team-ID eintragen)") }
                else { where_ = L("personal account", "persönliches Konto") }
                out.append((true, L("Vercel: \(a.user), \(where_), \(a.projects) projects", "Vercel: \(a.user), \(where_), \(a.projects) Projekte")))
            } catch { out.append((false, "Vercel: " + error.localizedDescription)) }
        }
        if let r = pick(render, .render) {
            do {
                let a = try await Render(key: r).account()
                out.append((true, L("Render: \(a.owners.isEmpty ? "?" : a.owners), \(a.services) services",
                                    "Render: \(a.owners.isEmpty ? "?" : a.owners), \(a.services) Dienste")))
            } catch { out.append((false, "Render: " + error.localizedDescription)) }
        }
        if let g = pick(github, .github) {
            do { out.append((true, "GitHub: " + (try await GitHub(token: g).login() ?? "?"))) }
            catch { out.append((false, "GitHub: " + error.localizedDescription)) }
        }
        if out.isEmpty { out.append((false, L("No key to test.", "Kein Schlüssel zum Testen."))) }
        return out
    }

    // MARK: Widget snapshot and notifications

    func makeSnapshot() -> DeploySnapshot {
        let rows: [DeploySnapshot.Project] = projects.compactMap { p in
            guard let s = p.snapshotStatus else { return nil }
            // Building or failed: since the attempt started, not since what is live. No commit text: no widget shows it.
            return .init(name: p.name, platform: p.provider.rawValue, status: s, commits: p.pendingCommits ?? 0,
                         prs: p.pendingPRs ?? 0, since: s == .waiting ? p.oldestPendingAt : (p.latestAt ?? p.liveAt),
                         message: nil, key: p.key)
        }
        let order: [DeploySnapshot.Project.Status: Int] = [.building: 0, .failed: 1, .waiting: 2]
        let sorted = rows.sorted { (order[$0.status]!, -$0.prs, $0.name) < (order[$1.status]!, -$1.prs, $1.name) }
        return DeploySnapshot(at: loadedAt ?? Date(), demo: demo, waitingProjects: waiting.count,
                              waitingCommits: waiting.reduce(0) { $0 + ($1.pendingCommits ?? 0) }, waitingPRs: waitingPRs,
                              building: rows.filter { $0.status == .building }.count,
                              failed: rows.filter { $0.status == .failed }.count, saving: nil, projects: Array(sorted.prefix(10)),
                              language: appLanguage)
    }

    /// The widget is reloaded only when what it shows changed, or its time is half an hour old:
    /// each reload counts against the widget's daily budget.
    func writeSnapshot() {
        guard let url = DeploySnapshot.groupURL else { return }
        let snap = makeSnapshot()
        if let old = DeploySnapshot.read(url), old.sameShown(as: snap), snap.at.timeIntervalSince(old.at) < 30 * 60 { return }
        try? FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
        try? DeploySnapshot.encoder.encode(snap).write(to: url, options: .atomic)
        WidgetCenter.shared.reloadAllTimelines()
    }

    /// After a background refresh: a note for what newly failed or newly waits. Only local notifications.
    func notifyChanges(from before: [PhoneProject]) async {
        guard UserDefaults.standard.bool(forKey: "notify") else { return }
        let old = Dictionary(before.map { ($0.key, $0) }, uniquingKeysWith: { a, _ in a })
        var events: [(id: String, text: String)] = []
        for p in projects {
            let o = old[p.key]
            if p.failed && !(o?.failed ?? false) { events.append(("failed:" + p.key, L("\(p.name) failed", "\(p.name) fehlgeschlagen"))) }
            else if p.group == .waiting && o?.group != .waiting { events.append(("waiting:" + p.key, L("\(p.name) is waiting", "\(p.name) wartet"))) }
        }
        guard !events.isEmpty else { return }
        // A few: one note each, with a fixed id, so the same news replaces itself instead of piling up.
        // Many: one summary that says how many more there are.
        var notes: [(id: String, body: String)] = events.count <= 3 ? events.map { ($0.id, $0.text) } : []
        if events.count > 3 {
            let more = events.count - 3
            notes = [("summary", events.prefix(3).map(\.text).joined(separator: " · ")
                      + " · " + L("+\(more) more", "+\(more) weitere"))]
        }
        for n in notes {
            let c = UNMutableNotificationContent()
            c.title = "Deploy Center"; c.body = n.body; c.sound = .default; c.threadIdentifier = "deploy-center"
            try? await UNUserNotificationCenter.current().add(UNNotificationRequest(identifier: n.id, content: c, trigger: nil))
        }
    }
}
