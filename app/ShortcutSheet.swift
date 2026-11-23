// Deploy Center — The keyboard shortcuts per window, on ⌘/.

import SwiftUI

/// One shortcut: the keys as they are drawn ("⌘K") and what they do.
struct ShortcutEntry: Identifiable, Equatable {
    let keys: String
    let title: String
    var id: String { keys + title }
}

/// A window's shortcuts under its name.
struct ShortcutGroup: Identifiable, Equatable {
    let name: String
    let entries: [ShortcutEntry]
    var id: String { name }
}

/// The list is kept here, in one place, so the sheet cannot drift from what the menus say:
/// `ShortcutCatalog.groups` is what the tests check for duplicates inside a window.
enum ShortcutCatalog {
    static var groups: [ShortcutGroup] {
        [
            ShortcutGroup(name: L("Main window", "Hauptfenster"), entries: [
                .init(keys: "⌘1 – ⌘9", title: L("Switch the tab", "Tab wechseln")),
                .init(keys: "⌘F", title: L("Search", "Suchen")),
                .init(keys: "⌘K", title: L("Command palette", "Befehlspalette")),
                .init(keys: "⌘R", title: L("Reload", "Neu laden")),
                .init(keys: "⌘A", title: L("Tick everything that waits", "Alles mit Änderungen anhaken")),
                .init(keys: "⌘↩", title: L("Deploy the ticked projects (asks first)", "Angehakte Projekte deployen (fragt vorher)")),
                .init(keys: "⌘Y", title: L("Deploy history", "Deploy-Verlauf")),
                .init(keys: "⌥⌘F", title: L("Show failed only", "Nur Fehlgeschlagene zeigen")),
                .init(keys: "⌥⌘1 – ⌥⌘4", title: L("Quick filters and platform", "Schnellfilter und Plattform")),
                .init(keys: "⇧⌘U", title: L("Read the summary aloud", "Zusammenfassung vorlesen")),
                .init(keys: "⌘/", title: L("This list", "Diese Liste")),
            ]),
            ShortcutGroup(name: L("Build log and details", "Build-Log und Details"), entries: [
                .init(keys: "⌘F", title: L("Find in the log", "Im Log suchen")),
                .init(keys: "⌘+  /  ⌘−", title: L("Larger or smaller text", "Größere oder kleinere Schrift")),
                .init(keys: "esc", title: L("Close", "Schließen")),
            ]),
            ShortcutGroup(name: L("Sheets and questions", "Blätter und Rückfragen"), entries: [
                .init(keys: "↩", title: L("The highlighted button", "Der hervorgehobene Knopf")),
                .init(keys: "esc", title: L("Cancel or close", "Abbrechen oder schließen")),
                .init(keys: "⌘D", title: L("Deploy, in a question about a risky deploy", "Deployen, bei einer Rückfrage zu einem riskanten Deploy")),
            ]),
            ShortcutGroup(name: L("Everywhere", "Überall"), entries: [
                .init(keys: "⌘O", title: L("Open Deploy Center (menu bar)", "Deploy Center öffnen (Menüleiste)")),
                .init(keys: "⇧⌘D", title: L("Demo mode", "Demo-Modus")),
                .init(keys: "⌘,", title: L("Settings", "Einstellungen")),
                .init(keys: "⌘Q", title: L("Quit", "Beenden")),
            ]),
        ]
    }
}

/// ⌘/: a sheet that lists the shortcuts, grouped per window.
struct ShortcutSheet: View {
    @Environment(\.dismiss) private var dismiss

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            Text(L("Keyboard shortcuts", "Tastenkürzel")).font(.title3.bold())
            ScrollView {
                VStack(alignment: .leading, spacing: 16) {
                    ForEach(ShortcutCatalog.groups) { g in
                        VStack(alignment: .leading, spacing: 6) {
                            Text(g.name).font(.headline).accessibilityAddTraits(.isHeader)
                            ForEach(g.entries) { e in
                                HStack(alignment: .firstTextBaseline) {
                                    Text(e.title)
                                    Spacer(minLength: 12)
                                    Text(e.keys).font(.system(.body, design: .monospaced)).foregroundStyle(.secondary)
                                }
                                .accessibilityElement(children: .ignore)
                                .accessibilityLabel(e.title)
                                .accessibilityValue(e.keys)
                            }
                        }
                    }
                }
                .frame(maxWidth: .infinity, alignment: .leading)
            }
            HStack { Spacer(); Button(L("Done", "Fertig")) { dismiss() }.keyboardShortcut(.defaultAction) }
        }
        .padding(20).frame(width: 440, height: 480)
    }
}
