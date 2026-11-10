// Deploy Center — The rule for "building", "failed" and "waiting", as `deploys changed` decides it
// (CHANGED_RULE in the script). Foundation only: the Mac app, the widgets and the iOS app compile it,
// and ios/test.sh checks it.

import Foundation

enum DeployRule {
    static let buildingStates: Set<String> = ["building", "queued", "initializing", "created", "build_in_progress",
                                             "update_in_progress", "pre_deploy_in_progress"]
    static let failedStates: Set<String> = ["error", "build_failed", "update_failed", "pre_deploy_failed", "canceled"]

    /// The live or the newest attempt is still on its way.
    static func building(live: String?, latest: String?) -> Bool {
        [live, latest].compactMap { $0?.lowercased() }.contains { buildingStates.contains($0) }
    }

    /// The newest attempt failed (a canceled one does not count) and nothing builds.
    static func failed(latest: String?, building: Bool) -> Bool {
        guard !building, let s = latest?.lowercased() else { return false }
        return failedStates.contains(s) && s != "canceled"
    }

    /// There is something newer than what is live: by commit when both are known, else by time.
    /// Not while it builds, not when the branch could not be read, not when the branch is behind.
    static func changed(deployable: Bool, paused: Bool, building: Bool, readError: Bool, compareStatus: String?,
                        liveSha: String?, headSha: String?, liveAt: Date?, headAt: Date?) -> Bool {
        guard deployable, !paused, headSha != nil || headAt != nil, !building, !readError,
              compareStatus != "behind" else { return false }
        if let l = liveSha, let h = headSha { return l != h }
        if let h = headAt, let l = liveAt { return h > l }
        return false
    }
}
