// Deploy Center for iPhone — Starts, updates and ends the Live Activity of a followed deploy.
// Nothing happens when Live Activities are off for the app. No push: updates only while the app runs.

import ActivityKit
import Foundation

@MainActor
final class LiveDeploy {
    private var activity: Activity<DeployActivity>?
    private var last: String?

    static func start(_ p: PhoneProject, rollback: Bool) -> LiveDeploy {
        let l = LiveDeploy()
        guard ActivityAuthorizationInfo().areActivitiesEnabled else { return l }
        let attrs = DeployActivity(project: p.name, platform: p.provider.rawValue, started: Date(), rollback: rollback, german: appIsGerman)
        l.activity = try? Activity.request(attributes: attrs, content: content(.running, PhoneProject.stateWord("queued")), pushType: nil)
        return l
    }

    private static func content(_ phase: DeployActivity.ContentState.Phase, _ words: String, final: Bool = false) -> ActivityContent<DeployActivity.ContentState> {
        ActivityContent(state: .init(phase: phase, words: words, updated: Date()),
                        staleDate: final ? nil : Date().addingTimeInterval(DeployActivity.staleAfter))
    }

    /// A new state, or the same one again so that it does not go stale while the app follows it.
    func update(_ words: String) {
        guard let a = activity else { return }
        last = words
        Task { await a.update(Self.content(.running, words)) }
    }

    /// The end: shown for a quarter of an hour on the lock screen, then gone.
    func finish(_ phase: DeployActivity.ContentState.Phase, _ words: String) {
        guard let a = activity else { return }
        activity = nil
        Task { await a.end(Self.content(phase, words, final: true), dismissalPolicy: .after(Date().addingTimeInterval(15 * 60))) }
    }
}
