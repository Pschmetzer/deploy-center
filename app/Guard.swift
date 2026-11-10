// Deploy Center — Settings > Auto-deploy guard: `deploys guard` without a terminal.
// The guard (a launchd job every 30 minutes) turns auto-deploy off wherever it is on without a
// running allowance. An allowance turns it on for a few hours. All the work is in the script
// (docs/GUARD.md); this view only calls it.

import SwiftUI

struct GuardStatus: Decodable {
    struct Action: Decodable, Identifiable {
        let at: Double
        let platform: String
        let project: String?
        let action: String          // off | wouldOff | failed | error
        let error: String?
        var id: String { "\(platform)-\(project ?? "")-\(action)-\(at)" }
    }
    struct Allowance: Decodable, Identifiable {
        let platform: String        // vercel | render | all
        let project: String         // a name, or * for all of the platform
        let expiresAt: Double       // epoch seconds; the script may also send milliseconds or ISO 8601
        var id: String { "\(platform):\(project)" }
        init(from decoder: Decoder) throws {
            let c = try decoder.container(keyedBy: K.self)
            platform = try c.decode(String.self, forKey: .platform)
            project = try c.decode(String.self, forKey: .project)
            expiresAt = try AutoDeployAllowance.expiry(c, .expiresAt).timeIntervalSince1970
        }
        private enum K: String, CodingKey { case platform, project, expiresAt }
    }
    let enabled: Bool
    let lastRun: Double?
    let lastDry: Bool?
    let lastActions: [Action]
    let allowances: [Allowance]
    /// A broken entry is skipped; the rest of the section still shows.
    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: K.self)
        enabled = ((try? c.decodeIfPresent(Bool.self, forKey: .enabled)) ?? nil) ?? false
        lastRun = (try? c.decodeIfPresent(Double.self, forKey: .lastRun)) ?? nil
        lastDry = (try? c.decodeIfPresent(Bool.self, forKey: .lastDry)) ?? nil
        lastActions = (((try? c.decodeIfPresent([Lossy<Action>].self, forKey: .lastActions)) ?? nil) ?? []).compactMap(\.value)
        allowances = (((try? c.decodeIfPresent([Lossy<Allowance>].self, forKey: .allowances)) ?? nil) ?? []).compactMap(\.value)
    }
    private enum K: String, CodingKey { case enabled, lastRun, lastDry, lastActions, allowances }
}

struct GuardSettings: View {
    @ObservedObject var store: Store
    @State private var status: GuardStatus?
    @State private var busy = false
    @State private var message: String?
    @State private var failed = false

    var body: some View {
        Section {
            Text(L("Every 30 minutes the guard turns auto-deploy off wherever it was turned on again (in a dashboard, by a Blueprint, by hand). An allowance below keeps it on for a while. The first run only reports.",
                   "Alle 30 Minuten schaltet der Wächter Auto-Deploy überall dort ab, wo es wieder eingeschaltet wurde (im Dashboard, per Blueprint, von Hand). Eine Erlaubnis unten lässt es eine Zeit lang an. Der erste Lauf meldet nur."))
                .font(.caption).foregroundStyle(.secondary)

            Toggle(L("Guard auto-deploy every 30 minutes", "Auto-Deploy alle 30 Minuten bewachen"), isOn: Binding(
                get: { status?.enabled ?? false },
                set: { on in Task { await run(["guard", "schedule", on ? "on" : "off"]) } }))
                .disabled(busy || status == nil)

            GuardLastRun(status: status)

            HStack {
                Button(L("Test (changes nothing)", "Testen (ändert nichts)")) { Task { await run(["guard", "--dry-run"], show: true) } }
                    .disabled(busy)
                if busy { ProgressView().controlSize(.small) }
            }
            if let message {
                Text(message).font(.caption.monospaced()).textSelection(.enabled)
                    .foregroundStyle(failed ? .red : .secondary)
            }

            GuardAllowances(allowances: status?.allowances ?? [], busy: busy) { a in
                Task { await run(["autodeploy", "revoke", a.platform, a.project == "*" ? "--all" : a.project], show: true) }
            }

            GuardAllowForm(store: store, busy: busy) { platform, project, hours in
                Task { await run(["autodeploy", "allow", platform, project, String(hours)], show: true) }
            }
        } header: {
            Text(L("Auto-deploy guard", "Auto-Deploy-Wächter"))
        }
        .task { await reload() }
    }

    private func reload() async {
        status = try? await Tool.json(["guard", "status", "--json"], as: GuardStatus.self, timeout: 20)
    }

    /// A script call; with `show` its output is shown under the buttons. Auto-deploy may have
    /// changed, so the lists are read again too.
    private func run(_ args: [String], show: Bool = false) async {
        busy = true; defer { busy = false }
        do {
            let out = String(data: try await Tool.run(args, timeout: 300), encoding: .utf8)?
                .trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
            message = show ? (out.isEmpty ? L("Nothing to do.", "Nichts zu tun.") : Demo.mask(out)) : (out.isEmpty ? nil : Demo.mask(out))
            failed = false
        } catch { message = error.localizedDescription; failed = true }
        await reload()
        for p in [Platform.vercel, .render] { await store.load(p) }
    }
}

/// When the guard last ran and what it did.
private struct GuardLastRun: View {
    let status: GuardStatus?

    var body: some View {
        if let s = status, let t = s.lastRun {
            DisclosureGroup(title(s, t)) {
                if s.lastActions.isEmpty {
                    Text(L("Nothing was on without an allowance.", "Nichts war ohne Erlaubnis an."))
                        .font(.caption).foregroundStyle(.secondary)
                }
                ForEach(s.lastActions) { a in
                    HStack {
                        Text(a.platform.capitalized).foregroundStyle(.secondary)
                        Text(Demo.mask(a.project ?? "–"))
                        Spacer()
                        Text(label(a)).foregroundStyle(a.action == "failed" || a.action == "error" ? .red : .secondary)
                    }
                    .font(.caption)
                    .help(a.error ?? "")
                }
            }
        } else {
            LabeledContent(L("Last run", "Letzter Lauf"), value: L("never", "noch nie"))
        }
    }

    private func title(_ s: GuardStatus, _ t: Double) -> String {
        let when = Date(timeIntervalSince1970: t).formatted(date: .abbreviated, time: .shortened)
        let dry = s.lastDry == true ? L(" (report only)", " (nur Bericht)") : ""
        return L("Last run: ", "Letzter Lauf: ") + when + dry + " · \(s.lastActions.count)"
    }

    private func label(_ a: GuardStatus.Action) -> String {
        switch a.action {
        case "off": return L("turned off", "abgeschaltet")
        case "wouldOff": return L("would be turned off", "würde abgeschaltet")
        case "failed": return L("could not turn off", "Abschalten fehlgeschlagen")
        case "error": return L("could not be read", "nicht lesbar")
        default: return a.action
        }
    }
}

/// The running allowances, with the time left and "revoke now".
private struct GuardAllowances: View {
    let allowances: [GuardStatus.Allowance]
    let busy: Bool
    let revoke: (GuardStatus.Allowance) -> Void

    var body: some View {
        if !allowances.isEmpty {
            TimelineView(.periodic(from: .now, by: 60)) { ctx in
                VStack(alignment: .leading, spacing: 6) {
                    Text(L("Allowed right now", "Gerade erlaubt")).font(.caption.bold())
                    ForEach(allowances) { a in
                        row(a, now: ctx.date)
                    }
                }
            }
        }
    }

    private func row(_ a: GuardStatus.Allowance, now: Date) -> some View {
        HStack {
            Image(systemName: "exclamationmark.triangle.fill").foregroundStyle(.orange)
            Text(scope(a))
            Spacer()
            Text(left(a, now: now)).foregroundStyle(.secondary).monospacedDigit()
            Button(L("Revoke now", "Jetzt widerrufen")) { revoke(a) }.disabled(busy)
        }
        .font(.caption)
    }

    private func scope(_ a: GuardStatus.Allowance) -> String {
        if a.platform == "all" { return L("All projects", "Alle Projekte") }
        if a.project == "*" { return L("All of ", "Alles bei ") + a.platform.capitalized }
        return a.platform.capitalized + " · " + Demo.mask(a.project)
    }

    private func left(_ a: GuardStatus.Allowance, now: Date) -> String {
        let m = max(0, Int((a.expiresAt - now.timeIntervalSince1970) / 60))
        return L("\(m / 60) h \(m % 60) min left", "noch \(m / 60) h \(m % 60) min")
    }
}

/// The emergency switch: auto-deploy on for one project or all, for 1, 4 or 24 hours.
private struct GuardAllowForm: View {
    @ObservedObject var store: Store
    let busy: Bool
    let allow: (_ platform: String, _ project: String, _ hours: Int) -> Void
    @State private var target = "all"          // "all" or "<cli platform>\t<name>"
    @State private var hours = 1
    @State private var confirming = false

    private var projects: [Item] {
        [Platform.vercel, .render].flatMap { store.items[$0] ?? [] }.sorted { $0.name.lowercased() < $1.name.lowercased() }
    }

    var body: some View {
        Picker(L("Allow auto-deploy for", "Auto-Deploy erlauben für"), selection: $target) {
            Text(L("All projects", "Alle Projekte")).tag("all")
            ForEach(projects) { i in
                Text("\(Demo.mask(i.name)) (\(i.platform.rawValue))").tag("\(i.platform.cli)\t\(i.name)")
            }
        }
        Picker(L("For", "Für"), selection: $hours) {
            Text("1 h").tag(1)
            Text("4 h").tag(4)
            Text("24 h").tag(24)
        }
        .pickerStyle(.segmented)
        Button(L("Allow auto-deploy …", "Auto-Deploy erlauben …"), role: .destructive) { confirming = true }
            .disabled(busy)
            .confirmationDialog(L("Allow auto-deploy for \(hours) h?", "Auto-Deploy für \(hours) h erlauben?"), isPresented: $confirming) {
                Button(L("Allow and turn on", "Erlauben und einschalten"), role: .destructive) { submit() }
                Button(L("Cancel", "Abbrechen"), role: .cancel) {}
            } message: {
                Text(warning)
            }
        Text(L("While allowed, every push and every merged fix PR builds and costs money.",
               "Solange erlaubt, baut jeder Push und jeder gemergte Fix-PR und kostet Geld."))
            .font(.caption).foregroundStyle(.orange)
    }

    private var warning: String {
        L("Until then every push, and every merged fix PR, builds on Vercel or Render and costs money. When the allowance ends, the guard turns auto-deploy off again.",
          "Bis dahin baut jeder Push und jeder gemergte Fix-PR auf Vercel oder Render und kostet Geld. Wenn die Erlaubnis endet, schaltet der Wächter Auto-Deploy wieder ab.")
    }

    private func submit() {
        if target == "all" { allow("all", "--all", hours); return }
        let parts = target.split(separator: "\t", maxSplits: 1).map(String.init)
        guard parts.count == 2 else { return }
        allow(parts[0], parts[1], hours)
    }
}
