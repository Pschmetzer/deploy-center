// Deploy Center for iPhone — The Live Activity of a deploy started in the app (lock screen, Dynamic Island).
// Built into the app (starts and updates it) and the widget extension (draws it): ios/Common is in both targets.
// Local only: updates come while the app runs; after that it says when it was last updated.

#if os(iOS)
import ActivityKit
import Foundation

struct DeployActivity: ActivityAttributes {
    struct ContentState: Codable, Hashable {
        enum Phase: String, Codable { case running, live, failed, unknown }
        var phase: Phase
        /// The provider's state in words ("Building", "Build failed"), in the app's language.
        var words: String
        var updated: Date
    }
    let project: String
    let platform: String
    let started: Date
    let rollback: Bool
    /// The app's language when it started: the extension cannot read the app's choice.
    let german: Bool

    /// After this long without an update iOS marks the activity as stale; the view then says "open the app".
    static let staleAfter: TimeInterval = 90
}
#endif
