// Deploy Center — the guided first start (FEA-106), after docs/SAFE-START.md: look first, see
// what turning auto-deploy off would save (the simulator, a dry run), then turn it off for one
// project only, after a confirmation. Shown once; Settings → Advanced opens it again.

import SwiftUI

enum FirstStart {
    static let key = "firstStartDone"
    /// Once, and only when there is something to turn off (a project that still builds on every push).
    nonisolated static func due(done: Bool, autoOn: Int) -> Bool { !done && autoOn > 0 }
}

struct FirstStartView: View {
    @ObservedObject var store: Store
    @Environment(\.dismiss) private var dismiss
    @AppStorage(FirstStart.key) private var done = false
    @State private var step = 1
    @State private var pick: String?
    @State private var confirming = false

    private var autoOn: [Item] { Platform.allCases.flatMap { store.autoOn($0) } }
    private var picked: Item? { autoOn.first { Store.key($0) == pick } }

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            HStack {
                Text(L("Try it safely", "Sicher ausprobieren")).font(.title2.bold())
                Spacer()
                Text(L("Step \(step) of 3", "Schritt \(step) von 3")).foregroundStyle(.secondary)
            }.padding(16)
            Divider()
            ScrollView {
                VStack(alignment: .leading, spacing: 14) {
                    switch step {
                    case 1: look
                    case 2: SimulatorView()
                    default: one
                    }
                }.padding(16).frame(maxWidth: .infinity, alignment: .leading)
            }
            Divider()
            HStack {
                Button(L("Skip", "Überspringen")) { finish() }
                Spacer()
                if step > 1 { Button(L("Back", "Zurück")) { step -= 1 } }
                if step < 3 { Button(L("Next", "Weiter")) { step += 1 }.keyboardShortcut(.defaultAction) }
                else { Button(L("Done", "Fertig")) { finish() }.keyboardShortcut(.defaultAction) }
            }.padding(12)
        }
        .frame(minWidth: 620, idealWidth: 680, minHeight: 480, idealHeight: 560)
        .alert(L("Turn off auto-deploy?", "Auto-Deploy ausschalten?"), isPresented: $confirming) {
            Button(L("Cancel", "Abbrechen"), role: .cancel) {}
            Button(L("Turn off", "Ausschalten")) { if let i = picked { Task { await store.turnOffAutoDeploy(i) } } }
        } message: {
            Text(L("Only \(Demo.mask(picked?.name ?? "")). A push will no longer build it; you deploy it from here. It can be turned on again any time.",
                   "Nur \(Demo.mask(picked?.name ?? "")). Ein Push baut es nicht mehr; du deployst es von hier. Es lässt sich jederzeit wieder einschalten."))
        }
    }

    @ViewBuilder private var look: some View {
        Text(L("1. Only look", "1. Nur ansehen")).font(.headline)
        Text(L("Opening the app changes nothing on Vercel, Render or GitHub. Nothing changes until you press a button and confirm.",
               "Die App zu öffnen ändert nichts bei Vercel, Render oder GitHub. Es ändert sich erst etwas, wenn du einen Knopf drückst und bestätigst."))
        Text(L("\(autoOn.count) projects still build on every push.", "\(autoOn.count) Projekte bauen noch bei jedem Push."))
        let bad = Health.checks(store.doctor, budget: store.githubBudget, on: Set(store.enabledProviders.map(\.id))).filter { !$0.ok }
        if bad.isEmpty {
            Label(L("Everything needed is connected.", "Alles Nötige ist verbunden."), systemImage: "checkmark.circle.fill").foregroundStyle(.green)
        } else {
            ForEach(bad) { c in
                Label(c.text + (c.fix.map { " → " + $0 } ?? ""), systemImage: "exclamationmark.triangle.fill").foregroundStyle(.orange)
            }
        }
        Text(L("Next: a dry run of what turning auto-deploy off would save.", "Als Nächstes: ein Trockenlauf, was das Abschalten von Auto-Deploy sparen würde."))
            .foregroundStyle(.secondary)
    }

    @ViewBuilder private var one: some View {
        Text(L("3. One project first", "3. Erst ein Projekt")).font(.headline)
        Text(L("Pick one you can afford to have wait a little. Auto-deploy goes off for it alone; the rest stays as it is.",
               "Nimm eins, das ruhig etwas warten darf. Auto-Deploy geht nur dort aus; der Rest bleibt, wie er ist."))
        if autoOn.isEmpty {
            Label(L("No project builds on every push any more.", "Kein Projekt baut mehr bei jedem Push."), systemImage: "checkmark.circle.fill").foregroundStyle(.green)
        } else {
            Picker(L("Project", "Projekt"), selection: $pick) {
                Text(L("Choose …", "Wählen …")).tag(String?.none)
                ForEach(autoOn, id: \.id) { i in Text(Demo.mask(i.name) + " (\(i.platform.rawValue))").tag(Optional(Store.key(i))) }
            }
            Button(L("Turn off auto-deploy for it …", "Auto-Deploy dafür ausschalten …")) { confirming = true }
                .disabled(picked == nil || store.observer)
        }
        Text(L("Later: Turn off auto-deploy above the list does all of a platform at once.",
               "Später: „Auto-Deploy ausschalten“ über der Liste macht eine ganze Plattform auf einmal."))
            .font(.caption).foregroundStyle(.secondary)
    }

    private func finish() { done = true; dismiss() }
}
