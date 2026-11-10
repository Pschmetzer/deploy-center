// Deploy Center — What the script answers, and one project as the window keeps it.

import SwiftUI
import AppKit
import Charts
import UserNotifications
import ServiceManagement

// MARK: - Data

enum Platform: String, CaseIterable, Identifiable {
    case vercel = "Vercel", render = "Render"
    var id: String { rawValue }
    var cli: String { rawValue.lowercased() }
}

struct Doctor: Decodable {
    let jq: Bool; let vercelCli: Bool; let vercelApi: Bool; let vercelLoggedIn: Bool; let githubCli: Bool; let githubLoggedIn: Bool?; let renderKey: Bool
    /// Observer mode (DEPLOYS_READONLY or ~/.config/deploys/readonly): the script refuses every deploy.
    let readonly: Bool
    /// A field the script does not send (older or newer script) counts as "no", instead of the
    /// whole answer failing and the app showing nothing.
    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        func flag(_ k: CodingKeys) -> Bool { ((try? c.decodeIfPresent(Bool.self, forKey: k)) ?? nil) ?? false }
        jq = flag(.jq); vercelCli = flag(.vercelCli); vercelApi = flag(.vercelApi); vercelLoggedIn = flag(.vercelLoggedIn)
        githubCli = flag(.githubCli); renderKey = flag(.renderKey); readonly = flag(.readonly)
        githubLoggedIn = (try? c.decodeIfPresent(Bool.self, forKey: .githubLoggedIn)) ?? nil
    }
    private enum CodingKeys: String, CodingKey { case jq, vercelCli, vercelApi, vercelLoggedIn, githubCli, githubLoggedIn, renderKey, readonly }
}

/// One element of a list that may not decode; the rest of the list still does.
struct Lossy<T: Decodable>: Decodable {
    let value: T?; let error: String?
    init(from decoder: Decoder) throws {
        do { value = try T(from: decoder); error = nil } catch { value = nil; self.error = "\(error)" }
    }
}
/// A list where a broken element is skipped and named, not the reason the whole list is gone.
/// With `maxBadShare`, a list where more than that share broke is an error, not a short list:
/// a changed format must not be taken (and cached) as "most projects are gone".
func decodeLossy<T: Decodable>(_ type: T.Type, from data: Data, label: String, maxBadShare: Double = 1) throws -> [T] {
    let all = try JSONDecoder().decode([Lossy<T>].self, from: data)
    let bad = all.enumerated().filter { $0.element.value == nil }
    if let first = bad.first {
        Log.write("\(label): skipped \(bad.count) of \(all.count) entries; first at \(first.offset): \(first.element.error ?? "")")
        if all.count >= 3, Double(bad.count) / Double(all.count) > maxBadShare {
            throw ToolError(message: L("Unexpected answer: \(bad.count) of \(all.count) entries unreadable – details in the log.",
                                       "Unerwartete Antwort: \(bad.count) von \(all.count) Einträgen unlesbar – Details im Log."))
        }
    }
    return all.compactMap(\.value)
}

struct VercelProject: Decodable {
    let name: String; let auto: Bool; let repo: String?; let ref: String?; let deployable: Bool
    let domain: String?; let lastAt: Double?; let lastState: String?; let headAt: Double?; let headMsg: String?
    let lastSha: String?; let headSha: String?
    let changed: Bool?; let pendingCommits: Int?; let pendingPRs: Int?; let openPRs: Int?
    let building: Bool?; let pendingPartial: Bool?; let oldestPendingAt: Double?; let rewritten: Bool?
    let openDrafts: Int?; let openBots: Int?
    let lastMsg: String?
    let risk: Risk?
    /// The newest attempt (any outcome); `lastState` is what production serves.
    let latestState: String?; let latestId: String?; let latestSha: String?
}
struct RenderService: Decodable {
    let id: String; let name: String; let type: String; let paused: Bool; let auto: Bool; let deployable: Bool
    let url: String?; let domain: String?; let repo: String?; let ref: String?
    let lastAt: Double?; let lastState: String?; let headAt: Double?; let headMsg: String?
    let lastSha: String?; let headSha: String?
    let changed: Bool?; let pendingCommits: Int?; let pendingPRs: Int?; let openPRs: Int?
    let building: Bool?; let pendingPartial: Bool?; let oldestPendingAt: Double?; let rewritten: Bool?
    let openDrafts: Int?; let openBots: Int?
    let lastMsg: String?
    let risk: Risk?
    let latestId: String?; let latestSha: String?
}
struct Costs: Decodable {
    struct Day: Decodable, Identifiable { let day: String; let total: Double; let build: Double; var id: String { day } }
    struct Project: Decodable { let name: String; let build: Double; let builds: Int? }
    let days: [Day]; let projects: [Project]; let offDay: String?; let buildsComplete: Bool?
    /// The cost per day before auto-deploy went off, kept on this Mac (see `Store.loadExtras`):
    /// two weeks after `offDay` the window of `costs 14` no longer holds a day before it.
    struct Baseline: Codable, Equatable { let offDay: String; let perDay: Double; let days: Int }
    var baseline: Baseline? = nil
    private enum CodingKeys: String, CodingKey { case days, projects, offDay, buildsComplete }

    /// What one build of a project cost on average, only when every build of the week was counted.
    func perBuild(_ name: String) -> Double? {
        guard buildsComplete == true, let p = projects.first(where: { $0.name == name }), let n = p.builds, n > 0 else { return nil }
        return p.build / Double(n)
    }
}
struct Trigger: Decodable, Identifiable {
    let kind: String; let `where`: String; let detail: String
    var id: String { kind + `where` + detail }
}
/// One repo in detail, read when the details are opened (`deploys details`).
struct Details: Decodable {
    struct Commit: Decodable, Identifiable {
        let sha: String; let full: String?; let url: String?; let msg: String; let author: String?; let bot: Bool?; let at: Double; let pr: Int?
        var id: String { sha }
    }
    struct Checks: Decodable { let total: Int; let failed: Int; let running: Int }
    struct OpenPR: Decodable, Identifiable {
        let number: Int; let title: String; let author: String?; let bot: Bool?; let draft: Bool; let updatedAt: String; let url: String; let ci: String
        var id: Int { number }
    }
    let commits: [Commit]; let files: Int; let additions: Int; let deletions: Int; let risky: [String]
    let onlyBots: Bool; let compareUrl: String?; let checks: Checks?; let open: [OpenPR]
}

/// What waits to go live, scored by the script (`deploys risk`): green, yellow or red, and why.
struct Risk: Decodable, Equatable {
    struct Reason: Decodable, Equatable { let kind: String; let level: String; let files: [String]?; let text: String }
    let level: String; let reasons: [Reason]; let files: Int?; let lines: Int?
    var isRed: Bool { level == "red" }

    /// One reason in the app's language; the script's English text for a kind it does not know.
    func text(_ r: Reason) -> String {
        let f = (r.files ?? []).prefix(3).joined(separator: ", ") + ((r.files?.count ?? 0) > 3 ? " …" : "")
        switch r.kind {
        case "migrations": return L("Database migrations: ", "Datenbank-Migrationen: ") + f
        case "lockfile": return L("Dependencies changed: ", "Abhängigkeiten geändert: ") + f
        case "env": return L("Environment files: ", "Umgebungsdateien: ") + f
        case "config": return L("Build or platform config: ", "Build- oder Plattform-Konfiguration: ") + f
        case "size":
            let n = files ?? 0, l = lines ?? 0
            return r.level == "red" ? L("A very large diff: \(n) files, \(l) lines", "Ein sehr großer Diff: \(n) Dateien, \(l) Zeilen")
                                    : L("A large diff: \(n) files, \(l) lines", "Ein großer Diff: \(n) Dateien, \(l) Zeilen")
        default: return r.text
        }
    }
}
/// `deploys ci … --json`: the CI verdict of one commit.
struct CIReply: Decodable { let state: String; let reason: String }
/// `deploys window --json`: whether the deploy window is closed now, and by which rule.
struct WindowReply: Decodable { let denied: Bool; let reason: String? }

/// ~/.config/deploys/window.json, the rules `deploys window` reads (docs/SAFE-DEPLOY.md), for
/// editing in the app. Keys the app does not know stay as they are when it is saved.
struct DeployWindowConfig: Equatable {
    struct Rule: Equatable, Identifiable {
        var id = UUID()
        /// "mon" … "sun"; empty is every day.
        var days: [String] = []
        /// "2026-12-24"; empty is any date.
        var dates: [String] = []
        /// "15:00"; nil is 00:00 (from) or 24:00 (to). A "from" after "to" runs over midnight.
        var from: String? = nil
        var to: String? = nil
        var reason: String? = nil
        static func == (a: Rule, b: Rule) -> Bool {
            a.days == b.days && a.dates == b.dates && a.from == b.from && a.to == b.to && a.reason == b.reason
        }
    }
    var deny: [Rule] = []

    static var url: URL {
        let dir = ProcessInfo.processInfo.environment["DEPLOYS_CONFIG_DIR"].map { URL(fileURLWithPath: $0) }
            ?? FileManager.default.homeDirectoryForCurrentUser.appendingPathComponent(".config/deploys")
        return dir.appendingPathComponent("window.json")
    }
    static let weekdays = ["mon", "tue", "wed", "thu", "fri", "sat", "sun"]

    /// "9:5" is not a time; "09:05" and "24:00" are.
    static func validTime(_ s: String) -> Bool {
        let p = s.split(separator: ":", omittingEmptySubsequences: false)
        guard p.count == 2, p[0].count == 2, p[1].count == 2, let h = Int(p[0]), let m = Int(p[1]) else { return false }
        return (0...23).contains(h) && (0...59).contains(m) || (h == 24 && m == 0)
    }
    /// Why the rules cannot be saved, or nil.
    var problem: String? {
        for r in deny {
            for t in [r.from, r.to].compactMap({ $0 }) where !Self.validTime(t) {
                return L("\"\(t)\" is not a time like 15:00", "\"\(t)\" ist keine Uhrzeit wie 15:00")
            }
            if let d = r.days.first(where: { !Self.weekdays.contains($0) }) { return L("Unknown day \"\(d)\"", "Unbekannter Tag \"\(d)\"") }
        }
        return nil
    }

    static func parse(_ data: Data?) -> DeployWindowConfig {
        guard let data, let root = (try? JSONSerialization.jsonObject(with: data)) as? [String: Any],
              let rules = root["deny"] as? [[String: Any]] else { return DeployWindowConfig() }
        return DeployWindowConfig(deny: rules.map { r in
            Rule(days: (r["days"] as? [String] ?? []).map { String($0.lowercased().prefix(3)) }, dates: r["dates"] as? [String] ?? [],
                 from: r["from"] as? String, to: r["to"] as? String, reason: r["reason"] as? String)
        })
    }

    /// The file's text with `deny` replaced; other keys of `old` are kept.
    func encoded(over old: Data?) throws -> Data {
        var root = old.flatMap { (try? JSONSerialization.jsonObject(with: $0)) as? [String: Any] } ?? [:]
        root["deny"] = deny.map { r -> [String: Any] in
            var o: [String: Any] = [:]
            if !r.days.isEmpty { o["days"] = r.days }
            if !r.dates.isEmpty { o["dates"] = r.dates }
            if let f = r.from, !f.isEmpty { o["from"] = f }
            if let t = r.to, !t.isEmpty { o["to"] = t }
            if let w = r.reason, !w.isEmpty { o["reason"] = w }
            return o
        }
        var d = try JSONSerialization.data(withJSONObject: root, options: [.prettyPrinted, .sortedKeys, .withoutEscapingSlashes])
        d.append(0x0A)
        return d
    }

    static func load() -> DeployWindowConfig { parse(try? Data(contentsOf: url)) }
    /// Writes the rules (no rules: the file goes, so nothing is ever closed). An error text when it failed.
    func save() -> String? {
        if let p = problem { return p }
        let u = Self.url
        do {
            if deny.isEmpty {
                if FileManager.default.fileExists(atPath: u.path) { try FileManager.default.removeItem(at: u) }
                return nil
            }
            try FileManager.default.createDirectory(at: u.deletingLastPathComponent(), withIntermediateDirectories: true)
            try encoded(over: try? Data(contentsOf: u)).write(to: u, options: .atomic)
            return nil
        } catch { return error.localizedDescription }
    }
}

struct Started: Decodable { let id: String; let url: String?; let state: String? }
struct StatusReply: Decodable { let id: String; let url: String?; let state: String?; let error: String? }

enum RunState: Equatable {
    case idle, queued, starting, running(String), done(String?), failed(String), skipped(String)
    var isActive: Bool { switch self { case .queued, .starting, .running: return true; default: return false } }
}

struct Item: Identifiable {
    let id: String          // Vercel: project name, Render: service id
    let name: String
    let detail: String
    let platform: Platform
    let deployable: Bool
    let auto: Bool
    let note: String?
    let link: String?
    var domain: String? = nil
    var lastAt: Date? = nil
    var lastState: String? = nil
    var headAt: Date? = nil
    var headMsg: String? = nil
    var lastSha: String? = nil
    var headSha: String? = nil
    var repo: String? = nil
    var ref: String? = nil
    var kind: String? = nil        // Render service type, for the dashboard link
    /// Decided by the script (`changed`), so the app and `deploys changed` never disagree.
    var changed: Bool? = nil
    var pendingCommits: Int? = nil
    var pendingPRs: Int? = nil
    var openPRs: Int? = nil
    var lastMsg: String? = nil
    var openDrafts: Int? = nil
    var openBots: Int? = nil
    var building = false
    var pendingPartial = false
    var oldestPendingAt: Date? = nil
    var rewritten = false
    var risk: Risk? = nil
    /// The newest deploy attempt, which may have failed while production still serves an older one
    /// (Vercel). Autofix decides by it, so the row must too.
    var latestState: String? = nil
    var latestId: String? = nil
    var latestSha: String? = nil
    var selected = false
    var state: RunState = .idle
    var startedAt: Date? = nil
    var deployId: String? = nil      // the deploy being followed, for cancelling
    var previewId: String? = nil     // a finished preview, for promoting it

    /// GitHub's page of the commits between what is live and the branch.
    var compareURL: URL? {
        guard let repo, let live = lastSha, !live.isEmpty, hasNewCommits else { return nil }
        // A branch may hold characters a URL cannot (#, %, spaces); "/" stays as GitHub expects it.
        let branch = ref ?? headSha ?? "main"
        let safe = branch.addingPercentEncoding(withAllowedCharacters: .urlPathAllowed.subtracting(CharacterSet(charactersIn: "#?"))) ?? branch
        return URL(string: "https://github.com/\(repo)/compare/\(live)...\(safe)")
    }

    /// The service's page on Render; Vercel's address needs the team's slug, which the list does not carry.
    var dashboardURL: URL? {
        guard platform == .render else { return nil }
        let section = ["static_site": "static", "cron_job": "cron", "background_worker": "worker"][kind ?? ""] ?? "web"
        return URL(string: "https://dashboard.render.com/\(section)/\(id)")
    }

    /// A commit on GitHub that is not live yet.
    var hasNewCommits: Bool {
        if let changed { return changed }
        // An older script without `changed`: compare commits, times only as a fallback.
        if let live = lastSha, let head = headSha, !live.isEmpty, !head.isEmpty { return live != head }
        guard let h = headAt else { return false }
        guard let l = lastAt else { return true }
        return h > l.addingTimeInterval(60)
    }
}

/// A Mac notification when a deploy ends while the window is in the background.
/// Permission is asked at the first deploy, when a reminder is turned on, or – if neither came first –
/// when the first alarm (stale commits, budget) is due, which may be while the window is in the
/// background. macOS asks the person only once.
/// An ad-hoc build may be refused; then nothing shows.
@MainActor
enum Notify {
    static func ask(then: (@Sendable (Bool) -> Void)? = nil) {
        UNUserNotificationCenter.current().requestAuthorization(options: [.alert, .sound]) { granted, _ in then?(granted) }
    }
    /// A reminder the person set up themselves: shown whether or not the window is in front.
    static func remind(_ title: String, _ body: String) {
        add(title, body, id: "daily-reminder")
    }
    static func post(_ title: String, _ body: String) {
        guard !NSApp.isActive, UserDefaults.standard.object(forKey: "notifications") as? Bool ?? true else { return }
        add(title, body, id: UUID().uuidString)
    }
    /// The countdown before an automatic rollback: shown even with the window in front, with Cancel.
    static func countdown(_ title: String, _ body: String, id: String) {
        add(title, body, id: id, category: NotifyRouter.rollbackCategory)
    }
    static func remove(_ id: String) {
        UNUserNotificationCenter.current().removeDeliveredNotifications(withIdentifiers: [id])
        UNUserNotificationCenter.current().removePendingNotificationRequests(withIdentifiers: [id])
    }
    /// Asks first only when the person was never asked, so the first alarm of a run is not lost.
    private static func add(_ title: String, _ body: String, id: String, category: String? = nil) {
        Task {
            let center = UNUserNotificationCenter.current()
            switch await center.notificationSettings().authorizationStatus {
            case .authorized, .provisional: break
            case .notDetermined:
                guard (try? await center.requestAuthorization(options: [.alert, .sound])) == true else { return }
            default: return
            }
            let c = UNMutableNotificationContent()
            c.title = title; c.body = body; c.sound = .default
            if let category { c.categoryIdentifier = category }
            try? await center.add(UNNotificationRequest(identifier: id, content: c, trigger: nil))
        }
    }
}

/// The Cancel button of the rollback countdown, and the countdown shown while the app is in front.
/// Other notifications behave as before: not shown while the app is in front.
final class NotifyRouter: NSObject, UNUserNotificationCenterDelegate, @unchecked Sendable {
    static let shared = NotifyRouter()
    static let rollbackCategory = "rollback-countdown"
    static let cancelAction = "cancel-rollback"
    /// Gets the notification's id when Cancel is clicked.
    var onCancel: (@MainActor (String) -> Void)?

    func install() {
        let center = UNUserNotificationCenter.current()
        let cancel = UNNotificationAction(identifier: Self.cancelAction, title: L("Cancel", "Abbrechen"), options: [])
        center.setNotificationCategories([UNNotificationCategory(identifier: Self.rollbackCategory, actions: [cancel],
                                                                 intentIdentifiers: [], options: [])])
        center.delegate = self
    }
    func userNotificationCenter(_ center: UNUserNotificationCenter, willPresent notification: UNNotification,
                                withCompletionHandler completionHandler: @escaping (UNNotificationPresentationOptions) -> Void) {
        // The countdown and the person's own daily reminder show with the window in front too.
        let always = notification.request.content.categoryIdentifier == Self.rollbackCategory
            || notification.request.identifier == "daily-reminder"
        completionHandler(always ? [.banner, .sound] : [])
    }
    func userNotificationCenter(_ center: UNUserNotificationCenter, didReceive response: UNNotificationResponse,
                                withCompletionHandler completionHandler: @escaping () -> Void) {
        let id = response.notification.request.identifier
        if response.actionIdentifier == Self.cancelAction { Task { @MainActor in self.onCancel?(id) } }
        completionHandler()
    }
}

/// The calendar day on this Mac ("2026-11-10"), for "once a day" and the daily history.
/// Not UTC: a day must not end at 1 or 2 a.m. local time.
/// Always the Gregorian calendar, so a Mac set to another calendar keeps the same keys.
func localDay(_ d: Date = Date(), timeZone: TimeZone = .current) -> String {
    var cal = Calendar(identifier: .gregorian); cal.timeZone = timeZone
    let c = cal.dateComponents([.year, .month, .day], from: d)
    return String(format: "%04d-%02d-%02d", c.year ?? 0, c.month ?? 0, c.day ?? 0)
}

func date(_ secs: Double?) -> Date? { secs.flatMap { $0 > 0 ? Date(timeIntervalSince1970: $0) : nil } }

// MARK: - Autofix and auto-deploy allowances, as the rows show them

extension Item {
    /// Any failure the platform reports for the newest deploy: a build failure (`lastFailed`) or one
    /// at runtime (Render update_failed, pre_deploy_failed). For explaining, not for autofix.
    var anyFailure: Bool {
        if lastFailed { return true }
        return ["error", "build_failed", "update_failed", "pre_deploy_failed"].contains((lastState ?? "").lowercased())
    }

    /// The newest build failed: what autofix would hand to Claude. The same rule as the script's
    /// AUTOFIX_FAILED: Vercel's newest attempt is ERROR (production may still be READY), Render's
    /// newest deploy is build_failed. Runtime failures (update_failed, pre_deploy_failed) are not
    /// build failures; the script leaves them to the person.
    var lastFailed: Bool {
        switch platform {
        case .vercel: return (latestState ?? lastState ?? "").lowercased() == "error"
        case .render: return (lastState ?? "").lowercased() == "build_failed"
        }
    }
}

/// `deploys autofix status --json`. Older scripts send `pr` and no PR state; newer ones
/// `prNumber`, `prState`, `prUrl`. A missing field is nil, a broken fire is skipped.
struct AutofixReport: Decodable {
    /// Also Settings > Autofix (`AutofixStatus.Fire`): one reader for one format.
    struct Fire: Decodable, Identifiable {
        var id: String { "\(project)-\(at)" }
        /// Why a start failed or was skipped.
        var error: String? = nil
        let at: Double
        let project: String
        let platform: String?
        let status: String
        let session: String?
        let prNumber: Int?
        let prState: String?
        let prUrl: String?
        let mergedSha: String?
        let redeployedSha: String?
        /// The commit of the failed build that was handed over.
        let sha: String?
        /// Green again: the script stopped watching it.
        var done = false
        init(at: Double, project: String, platform: String?, status: String, session: String? = nil, prNumber: Int? = nil,
             prState: String? = nil, prUrl: String? = nil, mergedSha: String? = nil, redeployedSha: String? = nil, sha: String? = nil) {
            self.at = at; self.project = project; self.platform = platform; self.status = status; self.session = session
            self.prNumber = prNumber; self.prState = prState; self.prUrl = prUrl; self.mergedSha = mergedSha; self.redeployedSha = redeployedSha
            self.sha = sha
        }
        init(from decoder: Decoder) throws {
            let c = try decoder.container(keyedBy: K.self)
            func s(_ k: K) -> String? { ((try? c.decodeIfPresent(String.self, forKey: k)) ?? nil).flatMap { $0.isEmpty ? nil : $0 } }
            func n(_ k: K) -> Int? { (try? c.decodeIfPresent(Int.self, forKey: k)) ?? nil }
            at = try c.decode(Double.self, forKey: .at)
            project = try c.decode(String.self, forKey: .project)
            status = try c.decode(String.self, forKey: .status)
            platform = s(.platform); session = s(.session); prState = s(.prState)?.lowercased(); prUrl = s(.prUrl)
            prNumber = n(.prNumber) ?? n(.pr); mergedSha = s(.mergedSha); redeployedSha = s(.redeployedSha)
            sha = s(.sha); error = s(.error)
            done = ((try? c.decodeIfPresent(Bool.self, forKey: .done)) ?? nil) ?? false
        }
        private enum K: String, CodingKey { case at, project, platform, status, session, prNumber, pr, prState, prUrl, mergedSha, redeployedSha, sha, error, done }
    }
    let routine: String?
    let token: Bool
    let fires: [Fire]
    /// A routine and its token are set: `deploys autofix --only` can hand a build over.
    var ready: Bool { routine != nil && token }
    init(routine: String?, token: Bool, fires: [Fire]) { self.routine = routine; self.token = token; self.fires = fires }
    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: K.self)
        routine = ((try? c.decodeIfPresent(String.self, forKey: .routine)) ?? nil).flatMap { $0.isEmpty ? nil : $0 }
        token = ((try? c.decodeIfPresent(Bool.self, forKey: .token)) ?? nil) ?? false
        fires = (((try? c.decodeIfPresent([Lossy<Fire>].self, forKey: .fires)) ?? nil) ?? []).compactMap(\.value)
    }
    private enum K: String, CodingKey { case routine, token, fires }

    /// The newest hand-over of this row. Fires name the project (a Render service by its name, not its id).
    func newest(for i: Item) -> Fire? {
        fires.filter { $0.project == i.name && ($0.platform?.lowercased() ?? i.platform.cli) == i.platform.cli }
            .max { $0.at < $1.at }
    }
}

/// What a row says about autofix. The status has no "done" flag, so each case ends by itself
/// when the row moves on (the build is green again, the merged fix is live).
enum RowAutofix: Equatable {
    case fixing(session: URL?)
    case prOpen(number: Int, url: URL?)
    case merged(sha: String, pr: Int?, url: URL?)
    case handedBack
    /// Handed over long ago and still no PR: the session most likely ended without one (a cause
    /// outside the code, say). Its report is in the session, so the chip links there.
    case noPR(session: URL?)

    /// After this long without a PR a hand-over no longer counts as "fixing".
    static let stalledAfter: TimeInterval = 90 * 60

    /// A `done` fire (green again) with a PR still open shows that PR this long, then nothing:
    /// the script no longer syncs it, so "open" may be stale.
    static let doneOpenFor: TimeInterval = 24 * 3600

    static func of(_ i: Item, _ f: AutofixReport.Fire?, now: Date = Date()) -> RowAutofix? {
        guard let f else { return nil }
        let pr = f.prUrl.flatMap(URL.init(string:))
        if let m = f.mergedSha {
            if f.redeployedSha != nil { return nil }
            // Live already, or nothing on the branch left to deploy.
            if let live = i.lastSha, !live.isEmpty, live.hasPrefix(m) || m.hasPrefix(live) { return nil }
            return i.hasNewCommits ? .merged(sha: m, pr: f.prNumber, url: pr) : nil
        }
        if f.prState == "open", let n = f.prNumber {
            if f.done && now.timeIntervalSince1970 - f.at > doneOpenFor { return nil }
            return .prOpen(number: n, url: pr)
        }
        guard i.lastFailed else { return nil }   // green again: nothing to say
        // A failure now that is not the one handed over: an old fire (green since, or another
        // build) says nothing about it, and must not block handing this one over.
        if f.done { return nil }
        if let fs = f.sha, !fs.isEmpty, let cur = i.latestSha, !cur.isEmpty, !(fs.hasPrefix(cur) || cur.hasPrefix(fs)) { return nil }
        if f.prState == "closed" || f.prState == "merged" { return .handedBack }
        switch f.status {
        case "fired", "pending", "ratelimited":
            let session = f.session.flatMap(URL.init(string:))
            if f.status == "fired", f.prState == nil, now.timeIntervalSince1970 - f.at > stalledAfter { return .noPR(session: session) }
            return .fixing(session: session)
        case "skipped", "failed": return .handedBack
        default: return nil
        }
    }

    /// Worth an `autofix sync`: a hand-over whose PR can still appear, be merged or be closed.
    /// A stalled one (no PR long after) is left to the 10-minute job, so the app does not ask every few minutes forever.
    static func needsSync(_ f: AutofixReport.Fire, now: Date = Date()) -> Bool {
        guard f.status == "fired", !f.done, f.mergedSha == nil, f.prState != "closed" else { return false }
        return f.prState == "open" || now.timeIntervalSince1970 - f.at <= stalledAfter
    }

    /// Key for "preselected once": a person who unticks the row is not overruled by the next load.
    static func preselectKey(_ i: Item, sha: String) -> String { "\(i.platform.cli)/\(i.id)@\(sha)" }
}

/// A temporary auto-deploy allowance (`deploys guard status --json`). `expiresAt` is epoch
/// seconds or an ISO 8601 date, whichever the script sends.
struct AutoDeployAllowance: Decodable, Equatable {
    let platform: String
    let project: String
    let expiresAt: Date
    init(platform: String, project: String, expiresAt: Date) { self.platform = platform; self.project = project; self.expiresAt = expiresAt }
    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: K.self)
        platform = try c.decode(String.self, forKey: .platform).lowercased()
        project = try c.decode(String.self, forKey: .project)
        expiresAt = try Self.expiry(c, .expiresAt)
    }
    private enum K: String, CodingKey { case platform, project, expiresAt }

    /// Epoch seconds, milliseconds or an ISO 8601 date: whichever the script sends. Shared with
    /// Settings > Guard, so both read the same.
    static func expiry<Key: CodingKey>(_ c: KeyedDecodingContainer<Key>, _ key: Key) throws -> Date {
        if let n = try? c.decode(Double.self, forKey: key) { return Date(timeIntervalSince1970: n > 1e12 ? n / 1000 : n) }
        let s = try c.decode(String.self, forKey: key)
        let f = ISO8601DateFormatter(), g = ISO8601DateFormatter()
        g.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        guard let d = f.date(from: s) ?? g.date(from: s) else {
            throw DecodingError.dataCorruptedError(forKey: key, in: c, debugDescription: "not a date: \(s)")
        }
        return d
    }

    /// A Render allowance may name the service by id or by name.
    func covers(_ i: Item) -> Bool { platform == i.platform.cli && (project == i.name || project == i.id) }
}
struct AllowanceReport: Decodable {
    let allowances: [AutoDeployAllowance]
    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: K.self)
        allowances = (((try? c.decodeIfPresent([Lossy<AutoDeployAllowance>].self, forKey: .allowances)) ?? nil) ?? []).compactMap(\.value)
    }
    private enum K: String, CodingKey { case allowances }
}
