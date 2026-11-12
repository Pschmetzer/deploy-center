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
    /// Tools the scheduled job no longer finds on its PATH (newer scripts); `guard schedule on` renews it.
    let pathMissing: [String]
    /// A broken entry is skipped; the rest of the section still shows.
    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: K.self)
        enabled = ((try? c.decodeIfPresent(Bool.self, forKey: .enabled)) ?? nil) ?? false
        lastRun = (try? c.decodeIfPresent(Double.self, forKey: .lastRun)) ?? nil
        lastDry = (try? c.decodeIfPresent(Bool.self, forKey: .lastDry)) ?? nil
        lastActions = (((try? c.decodeIfPresent([Lossy<Action>].self, forKey: .lastActions)) ?? nil) ?? []).compactMap(\.value)
        allowances = (((try? c.decodeIfPresent([Lossy<Allowance>].self, forKey: .allowances)) ?? nil) ?? []).compactMap(\.value)
        pathMissing = ((try? c.decodeIfPresent([String].self, forKey: .pathMissing)) ?? nil) ?? []
    }
    private enum K: String, CodingKey { case enabled, lastRun, lastDry, lastActions, allowances, pathMissing }
}

struct GuardSettings: View {
    @ObservedObject var store: Store
    @State private var status: GuardStatus?
    /// A failed read keeps the last good status, with this under it.
    @State private var readError: String?
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
            if let s = status, s.enabled, !s.pathMissing.isEmpty {
                PathMissingLine(missing: s.pathMissing, busy: busy) { Task { await run(["guard", "schedule", "on"]) } }
            }

            HStack {
                Button(L("Test (changes nothing)", "Testen (ändert nichts)")) { Task { await run(["guard", "--dry-run"], show: true) } }
                    .disabled(busy)
                if busy { ProgressView().controlSize(.small) }
            }
            if let readError {
                ErrorText(L("Could not read the guard status: ", "Wächter-Status nicht lesbar: ") + readError)
            }
            if let message {
                if failed { ErrorText(message) }
                else { Text(message).font(.caption.monospaced()).textSelection(.enabled).foregroundStyle(.secondary) }
            }

            GuardAllowances(allowances: status?.allowances ?? [], busy: busy, expired: { Task { await reload(); await store.loadAgentStatus() } }) { a in
                Task { await run(["autodeploy", "revoke", a.platform, a.project == "*" ? "--all" : a.project], show: true) }
            }

            GuardAllowForm(store: store, busy: busy) { platform, project, hours in
                Task {
                    guard await OwnerCheck.confirm(L("allow auto-deploy for \(hours) h", "Auto-Deploy für \(hours) h erlauben")) else { return }
                    await run(["autodeploy", "allow", platform, project, String(hours)], show: true)
                }
            }
        } header: {
            Text(L("Auto-deploy guard", "Auto-Deploy-Wächter"))
        }
        .task { await reload() }
    }

    private func reload() async {
        do {
            status = try await Tool.json(["guard", "status", "--json"], as: GuardStatus.self, timeout: 20)
            readError = nil
        } catch { readError = error.localizedDescription }
    }

    /// A script call; with `show` its output is shown under the buttons. Auto-deploy may have
    /// changed, so the lists are read again too.
    private func run(_ args: [String], show: Bool = false) async {
        busy = true; defer { busy = false }
        do {
            let out = String(data: try await Tool.run(args, timeout: 300), encoding: .utf8)?
                .trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
            // Only the names are replaced in demo mode; the rest of the report stays readable.
            let shown = Demo.scrub(out, items: store.items.values.flatMap { $0 })
            message = show ? (out.isEmpty ? L("Nothing to do.", "Nichts zu tun.") : shown) : (out.isEmpty ? nil : shown)
            failed = false
        } catch { message = error.localizedDescription; failed = true }
        await reload()
        // A test run changes nothing; allow, revoke and the schedule do.
        guard !args.contains("--dry-run") else { return }
        // The window's "allowed until" badges at once, not at the next refresh.
        await store.loadAgentStatus()
        await withTaskGroup(of: Void.self) { g in
            for p in Platform.allCases where store.canLoad(p) { g.addTask { await store.load(p) } }
        }
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
                        Text(ProviderInfo.label(for: a.platform)).foregroundStyle(.secondary)
                        Text(Demo.mask(a.project ?? "–"))
                        Spacer()
                        let bad = a.action == "failed" || a.action == "error"
                        if bad { Image(systemName: "xmark.octagon.fill").foregroundStyle(.red).accessibilityHidden(true) }
                        Text(label(a)).foregroundStyle(bad ? .red : .secondary)
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
        default: return unknownCode(a.action, L("result", "Ergebnis"))
        }
    }
}

/// The running allowances, with the time left and "revoke now".
private struct GuardAllowances: View {
    let allowances: [GuardStatus.Allowance]
    let busy: Bool
    /// One ran out: the lists are read again (the guard turns it off at its next run).
    var expired: () -> Void = {}
    let revoke: (GuardStatus.Allowance) -> Void

    var body: some View {
        if !allowances.isEmpty {
            TimelineView(.periodic(from: .now, by: 60)) { ctx in
                let live = allowances.filter { $0.expiresAt > ctx.date.timeIntervalSince1970 }
                VStack(alignment: .leading, spacing: 6) {
                    if !live.isEmpty { Text(L("Allowed right now", "Gerade erlaubt")).font(.caption.bold()) }
                    ForEach(live) { a in
                        row(a, now: ctx.date)
                    }
                }
                .onChange(of: live.count) { _, n in if n < allowances.count { expired() } }
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
        if a.project == "*" { return L("All of ", "Alles bei ") + ProviderInfo.label(for: a.platform) }
        return ProviderInfo.label(for: a.platform) + " · " + Demo.mask(a.project)
    }

    private func left(_ a: GuardStatus.Allowance, now: Date) -> String {
        let m = max(0, Int((a.expiresAt - now.timeIntervalSince1970) / 60))
        // Under an hour only the minutes: "5 min", not "0 h 5 min".
        if m < 60 { return L("\(m) min left", "noch \(m) min") }
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
        store.enabledProviders.compactMap(\.platform).flatMap { store.items[$0] ?? [] }.sorted { $0.name.lowercased() < $1.name.lowercased() }
    }

    var body: some View {
        Picker(L("Allow auto-deploy for", "Auto-Deploy erlauben für"), selection: $target) {
            Text(L("All projects", "Alle Projekte")).tag("all")
            ForEach(projects) { i in
                Text("\(Demo.mask(i.name)) (\(i.platform.rawValue))").tag("\(i.platform.cli)\t\(i.name)")
            }
        }
        // A project that left the list (reloaded, platform off) is no choice any more.
        .onChange(of: projects.map { "\($0.platform.cli)\t\($0.name)" }) { _, keys in
            if target != "all" && !keys.contains(target) { target = "all" }
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
            .font(.caption).foregroundStyle(Color.warningText)
    }

    private var warning: String {
        let base = L("Until then every push, and every merged fix PR, builds on Vercel or Render and costs money. When the allowance ends, the guard turns auto-deploy off again.",
                     "Bis dahin baut jeder Push und jeder gemergte Fix-PR auf Vercel oder Render und kostet Geld. Wenn die Erlaubnis endet, schaltet der Wächter Auto-Deploy wieder ab.")
        guard target == "all" else { return base }
        // "All" in numbers and names, so one click is not a surprise.
        let names = projects.filter(\.deployable).map { Demo.mask($0.name) }
        let shown = names.prefix(8).joined(separator: ", ") + (names.count > 8 ? L(" and \(names.count - 8) more", " und \(names.count - 8) weitere") : "")
        var head = L("\(plural(names.count, "project", "projects")) will build on every push: ", "\(plural(names.count, "Projekt", "Projekte")) bauen bei jedem Push: ") + shown + "."
        if let c = store.costs, c.days.count > 0 {
            let perHour = c.days.suffix(7).map(\.build).reduce(0, +) / Double(min(7, c.days.count)) / 24
            if perHour >= 0.01 {
                head += " " + L("Vercel builds cost ≈ \(perHour.formatted(.currency(code: "USD"))) an hour on average lately.",
                                "Vercel-Builds kosteten zuletzt im Schnitt ≈ \(perHour.formatted(.currency(code: "USD"))) pro Stunde.")
            }
        }
        return head + "\n\n" + base
    }

    private func submit() {
        if target == "all" { allow("all", "--all", hours); return }
        let parts = target.split(separator: "\t", maxSplits: 1).map(String.init)
        guard parts.count == 2 else { return }
        allow(parts[0], parts[1], hours)
    }
}

/// The scheduled job (launchd) runs with the PATH it got when it was set up; a tool that moved
/// since (a node or gh upgrade) is no longer found. Setting the schedule up again renews it.
struct PathMissingLine: View {
    let missing: [String]
    let busy: Bool
    let renew: () -> Void
    var body: some View {
        HStack {
            Text(L("The scheduled run no longer finds \(missing.joined(separator: ", ")).", "Der geplante Lauf findet \(missing.joined(separator: ", ")) nicht mehr."))
                .font(.caption).foregroundStyle(Color.warningText)
            Spacer()
            Button(L("Set up again", "Neu einrichten"), action: renew).disabled(busy)
        }
    }
}
