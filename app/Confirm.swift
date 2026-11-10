// Deploy Center — Touch ID (or the Mac's password) before the risky actions, opt-in in
// Settings → Deploy & guard: deploying several projects at once, a rollback by hand, and allowing
// auto-deploy. Automatic steps (the rollback after a failed check) never wait for it.

import Foundation
import LocalAuthentication

enum OwnerCheck {
    static let key = "ownerCheck"
    static var on: Bool { UserDefaults.standard.bool(forKey: key) }
    /// Whether this Mac can ask at all (Touch ID or a password; any Mac with a login can).
    static var available: Bool { LAContext().canEvaluatePolicy(.deviceOwnerAuthentication, error: nil) }

    /// True when the switch is off, or the person confirmed. `reason` completes "Deploy Center wants to …".
    @MainActor static func confirm(_ reason: String) async -> Bool {
        guard on else { return true }
        let ctx = LAContext()
        ctx.localizedCancelTitle = L("Cancel", "Abbrechen")
        guard ctx.canEvaluatePolicy(.deviceOwnerAuthentication, error: nil) else {
            Log.write("owner check: not available on this Mac, the action goes on without it")
            return true
        }
        do { return try await ctx.evaluatePolicy(.deviceOwnerAuthentication, localizedReason: reason) }
        catch { return false }
    }

    /// When several projects go live at once, it asks; one project alone does not.
    nonisolated static func needed(projects: Int) -> Bool { projects > 1 }
}
