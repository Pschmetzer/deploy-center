// Deploy Center — A tip a day (FEA-111): one line in the menu bar about something the app can do.
// Off in Settings → General.

import Foundation

enum Tips {
    static let key = "tipOfTheDay"
    static var on: Bool { UserDefaults.standard.object(forKey: key) as? Bool ?? true }

    static var all: [String] { [
        L("⌘K opens the command palette.", "⌘K öffnet die Befehlspalette."),
        L("Right-click a row: pin it, add a note, or set pages to check after a deploy.", "Rechtsklick auf eine Zeile: anheften, Notiz, oder Seiten für die Prüfung nach dem Deploy."),
        L("Mark a project critical: going live then asks for its name.", "Ein Projekt als kritisch markieren: der Live-Gang fragt dann nach dem Namen."),
        L("The simulator shows what auto-deploy would cost.", "Der Simulator zeigt, was Auto-Deploy kosten würde."),
        L("⌘Y opens the deploy history; Figures shows when deploys fail.", "⌘Y öffnet den Deploy-Verlauf; Zahlen zeigt, wann Deploys fehlschlagen."),
        L("A preview deploy builds without touching production.", "Ein Vorschau-Deploy baut, ohne Live anzufassen."),
        L("Settings → Deploy: wait a few seconds before a build starts, to cancel in time.", "Einstellungen → Deploy: ein paar Sekunden warten, bevor ein Build startet, um rechtzeitig abzubrechen."),
        L("Demo mode hides project names for screenshots.", "Der Demo-Modus verbirgt Projektnamen für Screenshots."),
        L("⇧⌘U reads the summary aloud.", "⇧⌘U liest die Zusammenfassung vor."),
        L("A project can roll back by itself when its site fails the check (its details).", "Ein Projekt kann selbst zurückrollen, wenn seine Seite den Check nicht besteht (seine Details)."),
    ] }

    /// The same tip all day, the next one tomorrow.
    static func tip(on day: Date = Date(), calendar: Calendar = .current) -> String {
        let n = calendar.ordinality(of: .day, in: .era, for: day) ?? 0
        let list = all
        return list[((n % list.count) + list.count) % list.count]
    }
}
