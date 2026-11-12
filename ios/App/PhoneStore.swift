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
    /// The message is an error: it stays longer and VoiceOver hears it as such.
    @Published var messageIsError = false
    @Published var demo: Bool { didSet { UserDefaults.standard.set(demo, forKey: "demo"); Task { await reload() } } }
    /// Set from the iOS Settings-like switch "Unlock on open": the list stays covered until Face ID passes.
    @Published var locked = false

    enum TokenKey: String, CaseIterable { case vercel, vercelTeam, render, github }

    /// One store for the app and the background refresh, so what the background read shows up on return.
    static let shared = PhoneStore()

    private init() {
        let args = ProcessInfo.processInfo.arguments
        demo = args.contains("-demo") || UserDefaults.standard.bool(forKey: "demo")
        locked = Self.lockOnOpen && !demo
    }

    func say(_ text: String) { message = text; messageIsError = false }
    func fail(_ text: String) { message = text; messageIsError = true }

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
        for k in TokenKey.allCases { Keychain.set(k.rawValue, "") }
        Self.ignoreLink = true; linked = nil
        teamCache = nil
        projects = []; errors = []; loadedAt = nil
        try? FileManager.default.removeItem(at: Background.lastURL)
        if let url = DeploySnapshot.groupURL { try? FileManager.default.removeItem(at: url) }
        WidgetCenter.shared.reloadAllTimelines()
    }

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
    func refreshLink() { let l = Self.readLink(); if l != linked { linked = l } }
    /// "Check again" in the connect sheet: the person wants the Mac link back.
    func useLinkAgain() { Self.ignoreLink = false; refreshLink() }
    var linkAvailable: Bool { PhoneLink.group != nil }

    /// Keys from the Mac's QR code: kept on this phone only, like typed ones.
    /// An empty field in the code keeps the key already on this phone; the Vercel team goes with the Vercel token.
    func adopt(_ k: LinkedKeys) {
        func given(_ v: String) -> Bool { !v.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty }
        if given(k.vercel) {
            Keychain.set(TokenKey.vercel.rawValue, k.vercel)
            Keychain.set(TokenKey.vercelTeam.rawValue, k.vercelTeam)
        }
        if given(k.render) { Keychain.set(TokenKey.render.rawValue, k.render) }
        if given(k.github) { Keychain.set(TokenKey.github.rawValue, k.github) }
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
            projects = DemoData.projects(); loadedAt = Date(); errors = []; writeSnapshot(); return true
        }
        var all: [PhoneProject] = [], errs: [String] = []
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
            } catch { errs.append("Vercel: \(error.localizedDescription)") }
        }
        if let r = token(.render) {
            do {
                let x = try await Render(key: r).projects()
                all += x.list; errs += x.notes.map { "Render: " + $0 }
            } catch { errs.append("Render: \(error.localizedDescription)") }
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
        // The live commit differs per project; compare again only where it differs from the sample.
        for i in all.indices {
            if Task.isCancelled { return false }
            guard let r = all[i].repo, let b = all[i].branch, let filled = cache[r + "@" + b] else { continue }
            if filled.liveSha == all[i].liveSha {
                all[i] = PhoneProject.merging(all[i], filled)
            } else {
                var p = all[i]; await gh.fill(&p); all[i] = p
            }
        }
        if Task.isCancelled { return false }
        projects = all.sorted { ($0.group.rawValue, $0.name.lowercased()) < ($1.group.rawValue, $1.name.lowercased()) }
        errors = errs; loadedAt = Date()
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
        } catch { fail(error.localizedDescription) }
    }

    func rollbackTarget(_ p: PhoneProject) async -> (id: String, sha: String?)? {
        if demo { return ("demo", "a0b1c2d") }
        do {
            switch p.provider {
            case .vercel: return try await vercel().rollbackTarget(p)
            case .render: return try await Render(key: token(.render) ?? "").rollbackTarget(p)
            }
        } catch { fail(error.localizedDescription); return nil }
    }

    func rollback(_ p: PhoneProject, to target: String) async {
        guard running[p.key] == nil else { return }
        running[p.key] = "rolling back"
        defer { running[p.key] = nil }
        if demo { await simulate(p, L("Rolled back (demo).", "Zurückgerollt (Demo).")); return }
        guard await authenticate(L("Roll back \(p.name)", "\(p.name) zurückrollen")) else { return }
        do {
            switch p.provider {
            case .vercel: try await vercel().rollback(p, to: target)
            case .render: try await Render(key: token(.render) ?? "").rollback(p, to: target)
            }
            say(L("\(p.name) is rolling back.", "\(p.name) wird zurückgerollt."))
            try? await Task.sleep(for: .seconds(4))
            await reload()
        } catch { fail(error.localizedDescription) }
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
                ended = true; break
            }
            if PhoneProject.failedStates.contains(s.lowercased()) || s.lowercased() == "deactivated" {
                fail("\(p.name): \(PhoneProject.stateName(s))"); ended = true; break
            }
        }
        if !ended {
            fail(L("\(p.name): state unknown, please check on \(p.provider.rawValue).",
                   "\(p.name): Stand unbekannt, bitte bei \(p.provider.rawValue) prüfen.")
                + (lastError.map { " (\($0))" } ?? ""))
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
        writeSnapshot()
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
