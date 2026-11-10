// Deploy Center for iPhone — One project or service, and the rule for "waiting".

import Foundation

enum ProviderKind: String, Codable, CaseIterable { case vercel = "Vercel", render = "Render" }

struct PhoneProject: Identifiable, Equatable, Codable {
    let provider: ProviderKind
    let id: String
    let name: String
    var repo: String? = nil
    var repoId: Int? = nil
    var branch: String? = nil
    var domain: String? = nil
    var autoDeploy = false
    var paused = false
    var deployable = false
    var liveId: String? = nil
    var liveSha: String? = nil
    var liveMsg: String? = nil
    var liveAt: Date? = nil
    var liveState: String? = nil
    var latestState: String? = nil
    var latestId: String? = nil
    var headSha: String? = nil
    var headAt: Date? = nil
    var headMsg: String? = nil
    var pendingCommits: Int? = nil
    var pendingPRs: Int? = nil
    var oldestPendingAt: Date? = nil
    var compareStatus: String? = nil
    var rewritten = false
    var openPRs: Int? = nil
    var fetchError: String? = nil
    /// Titles of the commits that wait (oldest first), at most 20: what goes live with the next deploy.
    var pendingTitles: [String]? = nil
    /// GitHub lists at most 100 open PRs per page and 250 commits per compare: the counts are then "at least".
    var openPRsCapped = false
    var pendingCapped = false
    /// The repo is on a host this app does not read (GitLab, Bitbucket): no "waiting" for it.
    var otherHost: String? = nil

    var key: String { provider.rawValue + "/" + id }

    static let buildingStates: Set<String> = ["building", "queued", "initializing", "created", "build_in_progress",
                                             "update_in_progress", "pre_deploy_in_progress"]
    static let failedStates: Set<String> = ["error", "build_failed", "update_failed", "pre_deploy_failed", "canceled"]

    var building: Bool {
        [liveState, latestState].compactMap { $0?.lowercased() }.contains { Self.buildingStates.contains($0) }
    }
    var failed: Bool {
        guard !building, let s = latestState?.lowercased() else { return false }
        return Self.failedStates.contains(s) && s != "canceled"
    }
    /// The newest attempt was canceled: neither building nor failed, but worth saying.
    var canceled: Bool { !building && ["canceled", "cancelled"].contains(latestState?.lowercased() ?? "") }
    /// The same rule as `deploys changed` (CHANGED_RULE): there is something newer than what is live.
    var changed: Bool {
        guard deployable, !paused, headSha != nil || headAt != nil, !building, fetchError == nil,
              compareStatus != "behind" else { return false }
        if let l = liveSha, let h = headSha { return l != h }
        if let h = headAt, let l = liveAt { return h > l }
        return false
    }
    var unknown: Bool { deployable && !paused && (fetchError != nil || (headSha == nil && headAt == nil)) }

    /// A provider state ("BUILDING", "build_failed", …) in words.
    static func stateWord(_ raw: String) -> String {
        switch raw.lowercased() {
        case "queued", "created", "initializing": L("queued", "in der Warteschlange")
        case "building", "build_in_progress": L("building", "baut")
        case "update_in_progress", "pre_deploy_in_progress", "deploying": L("going live", "geht live")
        case "ready", "live", "succeeded": L("live", "live")
        case "error", "build_failed": L("build failed", "Build fehlgeschlagen")
        case "update_failed": L("update failed", "Update fehlgeschlagen")
        case "pre_deploy_failed": L("pre-deploy failed", "Pre-Deploy fehlgeschlagen")
        case "canceled", "cancelled": L("canceled", "abgebrochen")
        case "deactivated": L("replaced", "abgelöst")
        case "starting": L("starting", "startet")
        case "rollback": L("rolling back", "rollt zurück")
        default: raw.lowercased()
        }
    }

    enum Group: Int, CaseIterable { case attention, waiting, live
        var title: String {
            switch self {
            case .attention: L("Building or failed", "Baut oder fehlgeschlagen")
            case .waiting: L("Waiting", "Wartet")
            case .live: L("Up to date", "Aktuell")
            }
        }
    }
    var group: Group { building || failed ? .attention : (changed ? .waiting : .live) }

    var snapshotStatus: DeploySnapshot.Project.Status? {
        building ? .building : failed ? .failed : changed ? .waiting : nil
    }
}

/// The language iOS picked for this app: it follows Settings → Deploy Center → Language and the order
/// of the person's languages, limited to en and de, so the app's text matches the system dialogs.
let appIsGerman = Bundle.main.preferredLocalizations.first?.hasPrefix("de") == true

func L(_ en: String, _ de: String) -> String { appIsGerman ? de : en }

/// "1 commit", "3 commits", "100+ PRs": the number with the singular or plural word.
func plural(_ n: Int, _ one: (String, String), _ many: (String, String), atLeast: Bool = false) -> String {
    "\(n)\(atLeast ? "+" : "") " + (n == 1 && !atLeast ? L(one.0, one.1) : L(many.0, many.1))
}
