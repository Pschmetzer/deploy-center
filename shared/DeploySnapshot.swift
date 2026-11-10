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
        var id: String { platform + "/" + name }
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
    let at: Date
    let demo: Bool
    let waitingProjects: Int
    let waitingCommits: Int
    let waitingPRs: Int
    let building: Int
    let failed: Int
    /// The counts of each platform (all rows, not only the ten in `projects`), so a widget can
    /// show one platform. Nil from older apps.
    var byPlatform: [PlatformCount]? = nil
    let saving: Saving?
    /// Building and failed first, then waiting by the number of PRs; at most ten.
    let projects: [Project]
    /// "en" or "de": the language the Mac app shows, so its widgets match it. Nil from older apps.
    var language: String? = nil

    static let fileName = "snapshot.json"
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
    static func read(_ url: URL? = groupURL) -> DeploySnapshot? {
        guard let url, let data = try? Data(contentsOf: url) else { return nil }
        return try? decoder.decode(DeploySnapshot.self, from: data)
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
