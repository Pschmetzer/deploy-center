// Deploy Center — What the platforms call a deploy's state, in words. One table for the row
// ("build failed") and for the running label ("going live").

import Foundation

enum DeployState {
    /// States the app knows by name while a deploy runs; any other is shown as the platform sent it.
    static let known: Set<String> = ["", "queued", "created", "initializing", "building", "build_in_progress",
                                           "update_in_progress", "pre_deploy_in_progress"]

    /// A finished or running state in words ("build_failed" → "build failed").
    static func text(_ raw: String) -> String {
        switch raw.lowercased() {
        case "": return L("unknown", "unbekannt")
        case "ready", "live", "succeeded": return L("live", "live")
        case "error": return L("failed", "fehlgeschlagen")
        case "build_failed": return L("build failed", "Build fehlgeschlagen")
        case "update_failed": return L("update failed", "Update fehlgeschlagen")
        case "pre_deploy_failed": return L("pre-deploy step failed", "Pre-Deploy-Schritt fehlgeschlagen")
        case "canceled", "cancelled": return L("cancelled", "abgebrochen")
        case "deactivated": return L("deactivated", "deaktiviert")
        case "building", "build_in_progress": return L("building", "baut")
        case "update_in_progress": return L("updating", "wird aktualisiert")
        case "pre_deploy_in_progress": return L("pre-deploy step running", "Pre-Deploy-Schritt läuft")
        case "queued", "created": return L("queued", "wartet")
        case "triggered": return L("triggered", "ausgelöst")
        case "initializing": return L("starting", "startet")
        case let s where s.hasPrefix("trigger failed"):
            return L("trigger failed", "Auslösen fehlgeschlagen") + String(raw.dropFirst("trigger failed".count))
        default: return raw.replacingOccurrences(of: "_", with: " ")
        }
    }

    /// The label while a deploy is on its way ("building", "going live").
    static func running(_ s: String) -> String {
        switch s {
        case "queued", "created", "initializing": return L("queued", "wartet")
        case "building", "build_in_progress": return L("building", "baut")
        case "update_in_progress", "pre_deploy_in_progress": return L("going live", "geht live")
        default: return s.isEmpty ? L("running", "läuft") : s.replacingOccurrences(of: "_", with: " ")
        }
    }
}
