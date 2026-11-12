// Deploy Center — Settings > Deploy & guard > Deploy window: the times without deploys, edited here
// instead of by hand (DeployWindowConfig in Model.swift reads and writes the file `deploys window` reads).

import SwiftUI

struct DeployWindowSettings: View {
    @State private var config = DeployWindowConfig.load()
    @State private var saved = DeployWindowConfig.load()
    @State private var error: String?
    @State private var done = false

    static func dayName(_ d: String) -> String {
        let en = ["mon": "Mon", "tue": "Tue", "wed": "Wed", "thu": "Thu", "fri": "Fri", "sat": "Sat", "sun": "Sun"]
        let de = ["mon": "Mo", "tue": "Di", "wed": "Mi", "thu": "Do", "fri": "Fr", "sat": "Sa", "sun": "So"]
        return L(en[d] ?? d, de[d] ?? d)
    }

    var body: some View {
        Section {
            if config.deny.isEmpty {
                Text(L("No times without deploys. Add one, e.g. Friday from 15:00.",
                       "Keine Zeiten ohne Deploys. Füge eine hinzu, z. B. Freitag ab 15:00."))
                    .font(.caption).foregroundStyle(.secondary)
            }
            ForEach($config.deny) { $rule in
                VStack(alignment: .leading, spacing: 6) {
                    HStack(spacing: 4) {
                        ForEach(DeployWindowConfig.weekdays, id: \.self) { d in
                            let on = rule.days.contains(d)
                            Button(Self.dayName(d)) {
                                if on { rule.days.removeAll { $0 == d } }
                                else { rule.days = DeployWindowConfig.weekdays.filter { rule.days.contains($0) || $0 == d } }
                            }
                            .buttonStyle(.bordered).controlSize(.small)
                            .tint(on ? .accentColor : .secondary)
                            .accessibilityValue(on ? L("on", "an") : L("off", "aus"))
                        }
                        Spacer()
                        Button(role: .destructive) { config.deny.removeAll { $0.id == rule.id } } label: { Image(systemName: "trash") }
                            .buttonStyle(.borderless).help(L("Remove this rule", "Diese Regel entfernen"))
                    }
                    HStack {
                        TextField(L("from", "ab"), text: Binding(get: { rule.from ?? "" }, set: { rule.from = $0.isEmpty ? nil : $0 }), prompt: Text("00:00"))
                            .frame(width: 70)
                        Text("–")
                        TextField(L("to", "bis"), text: Binding(get: { rule.to ?? "" }, set: { rule.to = $0.isEmpty ? nil : $0 }), prompt: Text("24:00"))
                            .frame(width: 70)
                        TextField(L("Reason", "Grund"), text: Binding(get: { rule.reason ?? "" }, set: { rule.reason = $0.isEmpty ? nil : $0 }),
                                  prompt: Text(L("e.g. weekend", "z. B. Wochenende")))
                    }
                    .labelsHidden()
                    Text(Self.summary(rule)).font(.caption).foregroundStyle(.secondary)
                }
            }
            HStack {
                Button(L("Add a time", "Zeit hinzufügen")) { config.deny.append(.init(days: ["fri"], from: "15:00")) }
                Spacer()
                if done { Text(L("Saved", "Gespeichert")).font(.caption).foregroundStyle(.secondary) }
                Button(L("Revert", "Zurücksetzen")) { config = saved; error = nil }.disabled(config == saved)
                Button(L("Save", "Speichern")) {
                    error = config.save()
                    if error == nil { saved = config; done = true }
                }
                .disabled(config == saved || config.problem != nil)
            }
            if let p = config.problem ?? error { ErrorText(p) }
        } header: {
            Text(L("Deploy window", "Deploy-Fenster"))
        } footer: {
            Text(L("At these times a production deploy needs a reason, in the app and on the command line (deploys window). Previews and rollbacks still go out.",
                   "Zu diesen Zeiten braucht ein Deploy auf Produktion einen Grund, in der App und auf der Kommandozeile (deploys window). Vorschauen und Rollbacks gehen weiter."))
                .font(.caption).foregroundStyle(.secondary)
        }
        .onChange(of: config) { _, _ in done = false }
    }

    /// "Fri, Sat 15:00–24:00" / "every day 22:00–06:00 (over midnight)", plus the fixed dates.
    static func summary(_ r: DeployWindowConfig.Rule) -> String {
        let days = r.days.isEmpty ? L("every day", "jeden Tag") : r.days.map(dayName).joined(separator: ", ")
        let from = r.from ?? "00:00", to = r.to ?? "24:00"
        var s = days + " " + from + "–" + to
        if from > to { s += L(" (over midnight)", " (über Mitternacht)") }
        if !r.dates.isEmpty { s += " · " + r.dates.joined(separator: ", ") }
        return s
    }
}
