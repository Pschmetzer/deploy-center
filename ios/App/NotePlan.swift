// Deploy Center for iPhone — How a local notification is grouped and ranked. Pure logic (no UserNotifications),
// so ios/Tests can check it; Notes.post turns the plan into a notification.

import Foundation

struct NotePlan: Equatable {
    enum Level: Equatable { case active, passive }

    /// Notifications with the same thread are stacked together: one thread per project, one for the summary.
    let thread: String
    /// 0...1: what rises in the notification summary and what falls.
    let relevance: Double
    let level: Level
    /// A waiting note offers "Deploy with Face ID"; every other note offers Open and Mute.
    let waiting: Bool
    /// The name the stack summary uses ("3 more from <name>"); nil when the lock screen must not name projects.
    let summaryArgument: String?

    /// `id` is "kind:project" ("failed:site", "waiting:site", "recovered:...", "live:..."); `project` is the key of the project, if any.
    static func make(id: String?, project: String?, projectName: String? = nil, hideNames: Bool) -> NotePlan {
        let kind = (id ?? "").split(separator: ":").first.map(String.init) ?? ""
        let relevance: Double
        switch kind {
        case "failed": relevance = 1.0
        case "waiting": relevance = 0.3
        case "recovered", "live": relevance = 0.5
        default: relevance = 0.7
        }
        let name = hideNames ? nil : projectName.flatMap { $0.isEmpty ? nil : $0 }
        return NotePlan(thread: project.map { "deploy-center-" + $0 } ?? "deploy-center",
                        relevance: relevance,
                        level: kind == "failed" ? .active : .passive,
                        waiting: (id ?? "").hasPrefix("waiting:"),
                        summaryArgument: name)
    }

    /// The identifier of a request: the same news replaces itself instead of piling up.
    static func identifier(id: String?, project: String?) -> String { id ?? "deploy-\(project ?? "")" }
}
