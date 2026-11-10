// Deploy Center — Touch ID (or the Mac's password) before the risky actions, opt-in in
// Settings → Deploy & guard: deploying several projects at once, a rollback by hand, and allowing
// auto-deploy. Automatic steps (the rollback after a failed check) never wait for it.

import Foundation
import LocalAuthentication
import AppKit

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

/// Projects marked critical (row menu) go live only after their name is typed (FEA-030).
/// An NSAlert of its own, so every way to a live deploy (row, palette, details, Dock, footer)
/// passes the same check without a view to present it.
enum NameCheck {
    /// Whether what was typed is the name as shown (masked in the demo), case and spaces aside.
    nonisolated static func matches(_ typed: String, _ name: String) -> Bool {
        let t = typed.trimmingCharacters(in: .whitespacesAndNewlines)
        return !t.isEmpty && t.caseInsensitiveCompare(name.trimmingCharacters(in: .whitespacesAndNewlines)) == .orderedSame
    }

    /// True once the name was typed; false on Cancel. Asks again with a hint on a wrong name.
    @MainActor static func confirm(_ name: String) -> Bool {
        var wrong = false
        while true {
            let a = NSAlert()
            a.messageText = L("Type the name to go live", "Zum Live-Schalten den Namen tippen")
            a.informativeText = (wrong ? L("That was not the name. ", "Das war nicht der Name. ") : "")
                + L("\(name) is marked critical. Type its name to put it live.",
                    "\(name) ist als kritisch markiert. Zum Live-Schalten den Namen tippen.")
            let field = NSTextField(frame: NSRect(x: 0, y: 0, width: 260, height: 24))
            field.placeholderString = name
            a.accessoryView = field
            a.addButton(withTitle: L("Deploy", "Deployen"))
            a.addButton(withTitle: L("Cancel", "Abbrechen"))
            a.window.initialFirstResponder = field
            NSApp.activate(ignoringOtherApps: true)
            guard a.runModal() == .alertFirstButtonReturn else { return false }
            if matches(field.stringValue, name) { return true }
            wrong = true
        }
    }
}
