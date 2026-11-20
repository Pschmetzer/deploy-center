// Deploy Center — The small picture the Mac app hands to its widgets and the iOS companion.
// Foundation only: the Mac app, the widget extension and the iOS app all compile this file.

import Foundation

struct DeploySnapshot: Codable, Equatable {
    struct Saving: Codable, Equatable {
        let before: Double   // average build cost a day before auto-deploy was turned off
        let after: Double    // and since, whole days only
        var month: Double { max(0, before - after) * 30 }
    }
    struct Project: Codable, Equatable, Identifiable {
        enum Status: String, Codable { case waiting, building, failed }
        let name: String          // already masked when the Mac app was in demo mode
        let platform: String      // "Vercel" or "Render"
        let status: Status
        let commits: Int
        let prs: Int
        let since: Date?          // oldest commit waiting, or when the deploy started
        let message: String?      // newest commit message, masked in demo mode
        /// The provider's own id ("Vercel/prj_…"), so two projects of one name (two teams) stay apart.
        /// Last and optional: older snapshots and the Mac app's rows without it still decode and build.
        var key: String? = nil
        var id: String { key ?? (platform + "/" + name) }
    }

    struct PlatformCount: Codable, Equatable {
        let platform: String      // "Vercel", "Render", …
        let waiting: Int          // projects
        let prs: Int
        let building: Int
        let failed: Int
    }

    static let version = 1
    var version = Self.version
    var at: Date
    let demo: Bool
    var waitingProjects: Int
    var waitingCommits: Int
    var waitingPRs: Int
    var building: Int
    var failed: Int
    /// The counts of each platform (all rows, not only the ten in `projects`), so a widget can
    /// show one platform. Nil from older apps.
    var byPlatform: [PlatformCount]? = nil
    let saving: Saving?
    /// Building and failed first, then waiting by the number of PRs; at most ten.
    var projects: [Project]
    /// "en" or "de": the language the Mac app shows, so its widgets match it. Nil from older apps.
    var language: String? = nil
    /// false: the iOS app has no account yet, so "nothing waits" would not be true. Nil from the Mac.
    var connected: Bool? = nil
    /// The next deploy that a schedule will start (a deploy window or a timer). Nil: none is planned, or an
    /// older app that does not write it. The widget only shows it; nothing here starts a deploy.
    var nextScheduled: NextRun? = nil

    struct NextRun: Codable, Equatable {
        let name: String          // already masked when the Mac app was in demo mode
        let platform: String      // empty for a schedule that covers every platform
        let at: Date
    }

    /// The next time a daily schedule ("HH:MM", optionally Monday to Friday) fires after `now`; nil for a bad time.
    static func nextDaily(at hhmm: String, weekdaysOnly: Bool, after now: Date, calendar: Calendar = .current) -> Date? {
        let parts = hhmm.split(separator: ":").compactMap { Int($0) }
        guard parts.count == 2, (0..<24).contains(parts[0]), (0..<60).contains(parts[1]) else { return nil }
        var comps = DateComponents(); comps.hour = parts[0]; comps.minute = parts[1]; comps.second = 0
        var from = now
        for _ in 0..<8 {
            guard let d = calendar.nextDate(after: from, matching: comps, matchingPolicy: .nextTime) else { return nil }
            let wd = calendar.component(.weekday, from: d)   // 1 = Sunday, 7 = Saturday
            if !weekdaysOnly || (2...6).contains(wd) { return d }
            from = d
        }
        return nil
    }

    /// English or German by a language code ("de", "de-DE" give German; nil gives the system's first).
    /// The iOS app and the widgets pick their texts with it, so both follow the same rule.
    static func localized(_ language: String?, _ en: String, _ de: String) -> String {
        isGerman(language ?? Self.systemLanguage(Locale.preferredLanguages)) ? de : en
    }
    /// The first of the person's languages that the apps have texts in ("fr", "de" gives German, not English).
    static func systemLanguage(_ preferred: [String]) -> String {
        preferred.first { $0.hasPrefix("de") || $0.hasPrefix("en") } ?? "en"
    }
    private static func isGerman(_ code: String) -> Bool { code.hasPrefix("de") }
    /// A text in the language this snapshot was written in.
    func text(_ en: String, _ de: String) -> String { Self.localized(language, en, de) }

    /// The counts of each platform from all rows (not only the ten shown).
    static func platformCounts(_ rows: [Project]) -> [PlatformCount] {
        Set(rows.map(\.platform)).sorted().map { p in
            let mine = rows.filter { $0.platform == p }
            return PlatformCount(platform: p, waiting: mine.filter { $0.status == .waiting }.count,
                                 prs: mine.filter { $0.status == .waiting }.map(\.prs).reduce(0, +),
                                 building: mine.filter { $0.status == .building }.count, failed: mine.filter { $0.status == .failed }.count)
        }
    }

    /// A copy for the configurable widget: one platform (nil: all) and/or only failed deploys.
    /// The numbers come from the platform split when the snapshot has one.
    func filtered(platform: String?, onlyFailed: Bool) -> DeploySnapshot {
        var s = self
        s.projects = projects.filter { (platform == nil || $0.platform == platform) && (!onlyFailed || $0.status == .failed) }
        if let platform {
            let c = byPlatform?.first { $0.platform == platform }
            s.waitingProjects = c?.waiting ?? projects.filter { $0.platform == platform && $0.status == .waiting }.count
            s.waitingPRs = c?.prs ?? projects.filter { $0.platform == platform && $0.status == .waiting }.map(\.prs).reduce(0, +)
            s.building = c?.building ?? projects.filter { $0.platform == platform && $0.status == .building }.count
            s.failed = c?.failed ?? projects.filter { $0.platform == platform && $0.status == .failed }.count
            s.waitingCommits = projects.filter { $0.platform == platform && $0.status == .waiting }.map(\.commits).reduce(0, +)
        }
        if onlyFailed { s.waitingProjects = 0; s.waitingPRs = 0; s.waitingCommits = 0; s.building = 0 }
        return s
    }

    /// Equal apart from the time it was written: nothing a widget shows has changed.
    func sameShown(as o: DeploySnapshot) -> Bool {
        var a = self, b = o
        a.at = .distantPast; b.at = .distantPast
        return a == b
    }

    static let fileName = "snapshot.json"
    /// The widget's kind, for a reload of just this widget.
    static let widgetKind = "DeployCenterWaiting"
    /// The App Group shared by the Mac app and its widget. It is set at build time
    /// (`DCAppGroup` in Info.plist) so no team id lives in the source.
    static var appGroup: String? {
        #if os(iOS)
        // iOS groups carry no team id: the same name works for every developer account.
        return "group.app.deploycenter"
        #else
        return (Bundle.main.object(forInfoDictionaryKey: "DCAppGroup") as? String).flatMap { $0.isEmpty ? nil : $0 }
        #endif
    }
    static var groupURL: URL? {
        guard let g = appGroup else { return nil }
        return FileManager.default.containerURL(forSecurityApplicationGroupIdentifier: g)?.appendingPathComponent(fileName)
    }

    static let encoder: JSONEncoder = {
        let e = JSONEncoder(); e.dateEncodingStrategy = .iso8601; e.outputFormatting = [.sortedKeys]; return e
    }()
    static let decoder: JSONDecoder = { let d = JSONDecoder(); d.dateDecodingStrategy = .iso8601; return d }()

    /// Any version that decodes: a newer app may add optional fields, and an older widget still shows
    /// what it knows instead of "Open the app". A change that breaks this must rename a field.
    static func read(_ url: URL? = groupURL) -> DeploySnapshot? { readOutcome(url).snapshot }

    /// Why there is no snapshot to show: no file yet, a file that does not read, or a file that a newer app wrote
    /// (this widget is older than the app and needs the update). The widget says which, instead of always
    /// asking to open the app.
    enum ReadProblem: Equatable { case missing, unreadable, appNewer }

    static func readOutcome(_ url: URL? = groupURL) -> (snapshot: DeploySnapshot?, problem: ReadProblem?) {
        guard let url, let data = try? Data(contentsOf: url) else { return (nil, .missing) }
        if let s = try? decoder.decode(DeploySnapshot.self, from: data) { return (s, nil) }
        struct Head: Decodable { let version: Int? }
        if let v = (try? decoder.decode(Head.self, from: data))?.version, v > Self.version { return (nil, .appNewer) }
        return (nil, .unreadable)
    }

    /// How much the Smart Stack should raise the widget: 10 for a failed deploy, 6 for a build that runs longer
    /// than 15 minutes, 3 for a project that has waited over a day, else nil.
    func relevanceScore(at now: Date) -> Float? {
        if failed > 0 { return 10 }
        if projects.contains(where: { $0.status == .building && ($0.since.map { now.timeIntervalSince($0) > 15 * 60 } ?? false) }) { return 6 }
        if projects.contains(where: { $0.status == .waiting && ($0.since.map { now.timeIntervalSince($0) > 24 * 3600 } ?? false) }) { return 3 }
        return nil
    }

    /// Made-up numbers for the widget gallery, the simulator and screenshots.
    static let sample = DeploySnapshot(
        at: Date(), demo: true, waitingProjects: 3, waitingCommits: 9, waitingPRs: 5, building: 1, failed: 1,
        saving: Saving(before: 3.40, after: 0.62),
        projects: [
            Project(name: "Atlas-214", platform: "Vercel", status: .building, commits: 2, prs: 1, since: Date().addingTimeInterval(-95), message: "Fix the checkout total"),
            Project(name: "Cedar-551", platform: "Render", status: .failed, commits: 1, prs: 0, since: Date().addingTimeInterval(-3600), message: "Bump the worker image"),
            Project(name: "Harbor-307", platform: "Vercel", status: .waiting, commits: 5, prs: 3, since: Date().addingTimeInterval(-86400 * 2), message: "New pricing page"),
            Project(name: "Nova-820", platform: "Vercel", status: .waiting, commits: 3, prs: 2, since: Date().addingTimeInterval(-7200), message: "Dark mode for the docs"),
            Project(name: "Quartz-145", platform: "Render", status: .waiting, commits: 1, prs: 0, since: Date().addingTimeInterval(-600), message: "Log less on start"),
        ])
}
