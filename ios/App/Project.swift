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
    var foreignRepo = false            // a repo outside GitHub: only GitHub is compared
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
    /// The same rule as `deploys changed` (CHANGED_RULE): there is something newer than what is live.
    var changed: Bool {
        guard deployable, !paused, headSha != nil || headAt != nil, !building, fetchError == nil,
              compareStatus != "behind" else { return false }
        if let l = liveSha, let h = headSha { return l != h }
        if let h = headAt, let l = liveAt { return h > l }
        return false
    }
    var unknown: Bool { deployable && !paused && !foreignRepo && (fetchError != nil || (headSha == nil && headAt == nil)) }

    /// A platform state in words ("build_failed" → "build failed"), as the Mac app shows it.
    static func stateName(_ raw: String) -> String {
        switch raw.lowercased() {
        case "starting", "initializing": return L("starting", "startet")
        case "rolling back": return L("rolling back", "rollt zurück")
        case "queued", "created": return L("queued", "in der Warteschlange")
        case "building", "build_in_progress": return L("building", "baut")
        case "update_in_progress": return L("updating", "aktualisiert")
        case "pre_deploy_in_progress": return L("pre-deploy running", "Pre-Deploy läuft")
        case "ready", "live", "succeeded": return L("live", "live")
        case "error", "build_failed": return L("build failed", "Build fehlgeschlagen")
        case "update_failed": return L("update failed", "Update fehlgeschlagen")
        case "pre_deploy_failed": return L("pre-deploy failed", "Pre-Deploy fehlgeschlagen")
        case "canceled", "cancelled": return L("canceled", "abgebrochen")
        case "deactivated": return L("replaced", "ersetzt")
        default: return raw.lowercased().replacingOccurrences(of: "_", with: " ")
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

func L(_ en: String, _ de: String) -> String { appLanguage == "de" ? de : en }
