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
func decodeLossy<T: Decodable>(_ type: T.Type, from data: Data, label: String) throws -> [T] {
    let all = try JSONDecoder().decode([Lossy<T>].self, from: data)
    let bad = all.enumerated().filter { $0.element.value == nil }
    if let first = bad.first {
        Log.write("\(label): skipped \(bad.count) of \(all.count) entries; first at \(first.offset): \(first.element.error ?? "")")
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
}
struct Costs: Decodable {
    struct Day: Decodable, Identifiable { let day: String; let total: Double; let build: Double; var id: String { day } }
    struct Project: Decodable { let name: String; let build: Double; let builds: Int? }
    let days: [Day]; let projects: [Project]; let offDay: String?; let buildsComplete: Bool?

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
    /// Asks first only when the person was never asked, so the first alarm of a run is not lost.
    private static func add(_ title: String, _ body: String, id: String) {
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
            try? await center.add(UNNotificationRequest(identifier: id, content: c, trigger: nil))
        }
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
