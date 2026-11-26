// Deploy Center for iPhone — One project or service, and the rule for "waiting".

import Foundation

enum ProviderKind: String, Codable, CaseIterable { case vercel = "Vercel", render = "Render" }

/// `deploycenter://select?project=…` as the Mac app, Alfred and Raycast write it: a name, or `platform:name`
/// (the platform in any case), with the platform optionally in a parameter of its own.
enum DeepLink {
    static func target(project: String, platform: String?) -> (name: String, platform: String?) {
        if let i = project.firstIndex(of: ":") {
            let p = String(project[..<i]), n = String(project[project.index(after: i)...])
            if !n.isEmpty && ProviderKind.allCases.contains(where: { $0.rawValue.lowercased() == p.lowercased() }) { return (n, p) }
        }
        return (project, platform)
    }
    /// No platform asked, or the same one, whatever its case.
    static func samePlatform(_ raw: String, _ asked: String?) -> Bool { asked.map { raw.lowercased() == $0.lowercased() } ?? true }
    /// A link that arrived before the list was read waits this long for it; later it is dropped.
    static let patience: TimeInterval = 60
}

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
    /// Some waiting commits could not be matched to a PR (too many, or a failed lookup): the PR count is a minimum.
    var pendingPRsAtLeast = false
    var prsAtLeast: Bool { pendingCapped || pendingPRsAtLeast }
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
    /// Commits exist, but nothing was ever deployed to production: the first deploy waits.
    var neverDeployed: Bool {
        DeployRule.neverDeployed(deployable: deployable, paused: paused, building: building, readError: fetchError != nil,
                                 liveSha: liveSha, liveAt: liveAt, liveState: liveState, headSha: headSha, headAt: headAt)
    }
    /// "Deploy" would build what is already live: nothing new, failed or unknown.
    var upToDate: Bool { !changed && !neverDeployed && !failed && !building && !unknown && liveSha != nil && liveSha == headSha }
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
    var group: Group { building || failed ? .attention : (changed || neverDeployed ? .waiting : .live) }

    var snapshotStatus: DeploySnapshot.Project.Status? {
        building ? .building : failed ? .failed : changed || neverDeployed ? .waiting : nil
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
        x.pendingTitles = filled.pendingTitles; x.openPRsCapped = filled.openPRsCapped; x.pendingCapped = filled.pendingCapped; x.pendingPRsAtLeast = filled.pendingPRsAtLeast
        x.fetchError = own.fetchError ?? filled.fetchError
        return x
    }
}

extension PhoneProject {
    /// Names as a person sorts them ("app2" before "app10", umlauts in place, case ignored); the key breaks a tie,
    /// so two projects of one name (two teams) keep their place between loads.
    static func nameOrder(_ a: PhoneProject, _ b: PhoneProject) -> Bool {
        switch a.name.localizedStandardCompare(b.name) {
        case .orderedAscending: return true
        case .orderedDescending: return false
        case .orderedSame: return a.key < b.key
        }
    }
    /// "Atlas, Harbor, Nova, Cedar, Quartz and 35 more": at most `limit` names, then the rest as a number.
    static func nameList(_ names: [String], limit: Int = 5) -> String {
        guard names.count > limit else { return names.joined(separator: ", ") }
        let more = names.count - limit
        return names.prefix(limit).joined(separator: ", ") + L(" and \(more) more", " und \(more) weitere")
    }
}

extension Array where Element == PhoneProject {
    /// The projects the app counts as "waiting" (not building, not failed): one rule for the app, the widgets and Siri.
    var waitingOnly: [PhoneProject] { filter { $0.group == .waiting } }
    /// PRs that wait. Projects of one repo share commits and PRs: each repo counts once.
    var waitingPRCount: Int {
        // One repo, one live commit: the same PRs wait for both projects. A project at another live commit
        // of the same repo has its own count (the PRs since that commit differ), so the key holds the commit too.
        var perRepo: [String: Int] = [:]
        for p in waitingOnly {
            let k = p.repo.map { $0 + "@" + (p.liveSha ?? "") } ?? p.key
            perRepo[k] = Swift.max(perRepo[k] ?? 0, p.pendingPRs ?? 0)
        }
        return perRepo.values.reduce(0, +)
    }
}


/// A key that was cut up on its way (a line break in the middle from a clipboard or a handoff) only ever
/// gives a 401 later. Checked before it is saved; nil when the shape is fine.
enum TokenShape {
    /// A Vercel team id is `team_…`; a team slug pasted instead gives a 403 only when the list loads.
    static func teamProblem(_ value: String) -> String? {
        let v = value.trimmingCharacters(in: .whitespacesAndNewlines)
        if v.isEmpty || v.hasPrefix("team_") { return nil }
        return L("A Vercel team id starts with team_ (Team Settings → General), not the team's name.",
                 "Eine Vercel-Team-ID beginnt mit team_ (Team-Einstellungen → Allgemein), nicht mit dem Namen des Teams.")
    }
    static func problem(_ value: String, render: Bool) -> String? {
        let v = value.trimmingCharacters(in: .whitespacesAndNewlines)
        if v.isEmpty { return nil }
        if v.contains(where: { $0.isWhitespace || $0.isNewline }) {
            return L("The key contains a space or a line break. Paste it again as one piece.",
                     "Der Schlüssel enthält ein Leerzeichen oder einen Zeilenumbruch. Füge ihn noch einmal als ein Stück ein.")
        }
        if render, !v.hasPrefix("rnd_") {
            return L("A Render key starts with rnd_. Check that it is the whole key.",
                     "Ein Render-Schlüssel beginnt mit rnd_. Prüfe, ob es der ganze Schlüssel ist.")
        }
        return nil
    }
}
