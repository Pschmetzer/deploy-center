// Deploy Center for iPhone — Starts, updates and ends the Live Activity of a followed deploy.
// Nothing happens when Live Activities are off for the app. No push: updates only while the app runs.

import ActivityKit
import Foundation

@MainActor
final class LiveDeploy {
    private var activity: Activity<DeployActivity>?
    private var last: String?
    private var lastUpdate = Date.distantPast
    /// The same words are sent again after this long, so the activity does not go stale while the app follows it.
    static let refreshEvery: TimeInterval = 60

    static func start(_ p: PhoneProject, rollback: Bool) -> LiveDeploy {
        let l = LiveDeploy()
        guard ActivityAuthorizationInfo().areActivitiesEnabled else { return l }
        // After a cold start of a followed deploy (FollowedRuns) the activity on the lock screen is picked up again, not doubled (IDEEN-12 C21).
        if let old = Activity<DeployActivity>.activities.first(where: { $0.attributes.key == p.key && $0.activityState == .active }) {
            l.activity = old
            return l
        }
        let attrs = DeployActivity(project: p.name, platform: p.provider.rawValue, started: Date(), rollback: rollback, german: appIsGerman, key: p.key, domain: p.domain)
        l.activity = try? Activity.request(attributes: attrs, content: content(.running, PhoneProject.stateWord("queued")), pushType: nil)
        return l
    }

    /// At launch nothing is followed yet: an activity that is still on the lock screen belongs to a run that
    /// ended with the app (killed, or out of background time) and would say "Building" for hours. Ended now.
    static func endOrphans() {
        // A run the app was following when it was killed is picked up again at launch (PhoneStore.resumeFollowed): its activity stays.
        let keep = Set(FollowedRuns.fresh().map(\.key))
        for a in Activity<DeployActivity>.activities where !(a.attributes.key.map(keep.contains) ?? false) {
            Task { await a.end(content(.unknown, L("No longer followed", "Wird nicht mehr verfolgt"), final: true), dismissalPolicy: .immediate) }
        }
    }

    /// Every activity at once and without a lock-screen stay: their text names projects (keys removed).
    static func endAll() {
        for a in Activity<DeployActivity>.activities {
            Task { await a.end(nil, dismissalPolicy: .immediate) }
        }
    }

    private static func content(_ phase: DeployActivity.ContentState.Phase, _ words: String, final: Bool = false,
                                expected: TimeInterval? = nil) -> ActivityContent<DeployActivity.ContentState> {
        ActivityContent(state: .init(phase: phase, words: words, updated: Date(), expected: expected),
                        staleDate: final ? nil : Date().addingTimeInterval(DeployActivity.staleAfter))
    }

    /// A new state, or the same one again so that it does not go stale while the app follows it.
    func update(_ words: String, expected: TimeInterval? = nil) {
        guard let a = activity else { return }
        // Not on every poll: a changed text, or the minute's refresh (IDEEN-12 C5).
        let now = Date()
        guard words != last || now.timeIntervalSince(lastUpdate) >= Self.refreshEvery else { return }
        last = words; lastUpdate = now
        Task { await a.update(Self.content(.running, words, expected: expected)) }
    }

    /// The end: shown for a quarter of an hour on the lock screen, then gone.
    func finish(_ phase: DeployActivity.ContentState.Phase, _ words: String) {
        guard let a = activity else { return }
        activity = nil
        Task { await a.end(Self.content(phase, words, final: true), dismissalPolicy: .after(Date().addingTimeInterval(15 * 60))) }
    }
}
