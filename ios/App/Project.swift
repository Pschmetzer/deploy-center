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
    var latestAt: Date? = nil          // when the newest attempt started
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
    var kind: String? = nil            // Render's service type ("web_service", "static_site", …)
    /// Titles of the commits that wait (oldest first), at most 20: what goes live with the next deploy.
    var pendingTitles: [String]? = nil
    /// GitHub lists at most 100 open PRs per page and 250 commits per compare: the counts are then "at least".
    var openPRsCapped = false
    var pendingCapped = false
    /// The repo is on a host this app does not read (GitLab, Bitbucket): no "waiting" for it.
    var otherHost: String? = nil
    /// A repo outside GitHub (GitLab, Bitbucket): deployable, but only GitHub is compared.
    var foreignRepo: Bool { otherHost != nil }
    /// Render: the workspace (owner) id, for reading build logs.
    var owner: String? = nil

    var key: String { provider.rawValue + "/" + id }

    /// The service's page on Render. Vercel's address needs the team's slug, which the list does not carry.
    var dashboardURL: URL? {
        guard provider == .render else { return nil }
        let section = ["static_site": "static", "cron_job": "cron", "background_worker": "worker"][kind ?? ""] ?? "web"
        return URL(string: "https://dashboard.render.com/\(section)/\(id)")
    }

    static var buildingStates: Set<String> { DeployRule.buildingStates }
    static var failedStates: Set<String> { DeployRule.failedStates }

    /// The rule itself lives in shared/DeployRule.swift (the port of `deploys changed`'s CHANGED_RULE).
    var building: Bool { DeployRule.building(live: liveState, latest: latestState) }
    var failed: Bool { DeployRule.failed(latest: latestState, building: building) }
    /// The newest attempt was canceled: neither building nor failed, but worth saying.
    var canceled: Bool { !building && ["canceled", "cancelled"].contains(latestState?.lowercased() ?? "") }
    /// There is something newer than what is live.
    var changed: Bool {
        DeployRule.changed(deployable: deployable, paused: paused, building: building, readError: fetchError != nil,
                           compareStatus: compareStatus, liveSha: liveSha, headSha: headSha, liveAt: liveAt, headAt: headAt)
    }
    /// "Deploy" would build what is already live: nothing new, failed or unknown.
    var upToDate: Bool { !changed && !failed && !building && !unknown && liveSha != nil && liveSha == headSha }
    var unknown: Bool { deployable && !paused && !foreignRepo && (fetchError != nil || (headSha == nil && headAt == nil)) }

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
        case "rollback", "rolling back": L("rolling back", "rollt zurück")
        default: raw.lowercased().replacingOccurrences(of: "_", with: " ")
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

/// The language the app shows: what iOS picked from the bundle's localizations (en, de), so texts,
/// system dialogs and dates agree, also with a per-app language from the iOS Settings.
let appLanguage: String = Bundle.main.preferredLocalizations.first?.hasPrefix("de") == true ? "de" : "en"
/// Dates and relative times in the language of the texts; the region still sets the formats.
let appLocale: Locale = {
    var c = Locale.Components(locale: .current)
    c.languageComponents = .init(identifier: appLanguage)
    return Locale(components: c)
}()

func L(_ en: String, _ de: String) -> String { DeploySnapshot.localized(appLanguage, en, de) }
var appIsGerman: Bool { appLanguage == "de" }

/// "1 commit", "3 commits", "100+ PRs": the number with the singular or plural word.
func plural(_ n: Int, _ one: (String, String), _ many: (String, String), atLeast: Bool = false) -> String {
    "\(n)\(atLeast ? "+" : "") " + (n == 1 && !atLeast ? L(one.0, one.1) : L(many.0, many.1))
}

extension PhoneProject {
    /// Repo facts from `filled` (same repo, branch and live commit), deploy facts from `own`.
    static func merging(_ own: PhoneProject, _ filled: PhoneProject) -> PhoneProject {
        var x = own
        x.headSha = filled.headSha; x.headAt = filled.headAt; x.headMsg = filled.headMsg
        x.pendingCommits = filled.pendingCommits; x.pendingPRs = filled.pendingPRs; x.oldestPendingAt = filled.oldestPendingAt
        x.compareStatus = filled.compareStatus; x.rewritten = filled.rewritten; x.openPRs = filled.openPRs
        x.pendingTitles = filled.pendingTitles; x.openPRsCapped = filled.openPRsCapped; x.pendingCapped = filled.pendingCapped
        x.fetchError = own.fetchError ?? filled.fetchError
        return x
    }
}
