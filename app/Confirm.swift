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

/// What waits brings database migrations (`deploys risk`): going live asks for a tick that they
/// were looked at (FEA-036). On by default; Settings → Deploy turns it off.
enum MigrationCheck {
    static let key = "migrationCheck"
    static var on: Bool { UserDefaults.standard.object(forKey: key) as? Bool ?? true }

    /// Whether this live deploy brings migrations: only new commits do; a redeploy of a given
    /// commit (a rollback, say) brings nothing new.
    nonisolated static func needed(_ i: Item, sha: String?) -> Bool {
        sha == nil && i.hasNewCommits && (i.risk?.reasons.contains { $0.kind == "migrations" } ?? false)
    }

    /// True once the box was ticked; false on Cancel. Asks again with a hint when Deploy is
    /// clicked without the tick.
    @MainActor static func confirm(_ items: [Item]) -> Bool {
        let names = items.map { Demo.mask($0.name) }.joined(separator: ", ")
        let files = items.compactMap { i -> String? in
            guard let r = i.risk, let m = r.reasons.first(where: { $0.kind == "migrations" }) else { return nil }
            return r.text(m)
        }.prefix(3).joined(separator: "\n")
        var unticked = false
        while true {
            let a = NSAlert()
            a.messageText = L("Database migrations are about to go live", "Datenbank-Migrationen gehen gleich live")
            a.informativeText = (unticked ? L("Tick the box first. ", "Erst das Häkchen setzen. ") : "")
                + L("\(names) brings migrations. Make sure they are safe for the data that is live now.",
                    "\(names) bringt Migrationen mit. Prüfe, ob sie für die Daten sicher sind, die jetzt live sind.")
                + (files.isEmpty ? "" : "\n\n" + Demo.scrub(files, items: items))
            let box = NSButton(checkboxWithTitle: L("I checked the migrations", "Ich habe die Migrationen geprüft"), target: nil, action: nil)
            a.accessoryView = box
            a.addButton(withTitle: L("Deploy", "Deployen"))
            a.addButton(withTitle: L("Cancel", "Abbrechen"))
            NSApp.activate(ignoringOtherApps: true)
            guard a.runModal() == .alertFirstButtonReturn else { return false }
            if box.state == .on { return true }
            unticked = true
        }
    }
}
