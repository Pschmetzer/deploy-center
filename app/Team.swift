// Deploy Center — Settings > Team: the shared deploy-center.json this Mac found, and the observer switch.
// The merge, the observer rule and the two-person rule are all in the script (lib/team.sh); this
// view shows `deploys config --json` and calls `deploys readonly on|off` and `deploys team add`.

import SwiftUI
import AppKit

/// The part of `deploys config --json` the app shows. A field the script does not send is nil.
struct TeamConfig: Decodable {
    struct Flag: Decodable { let value: Bool; let from: String }
    struct Source: Decodable, Identifiable {
        let repo: String
        let path: String?
        let found: Bool
        let stale: Bool?
        let error: String?
        var id: String { repo }
    }
    struct Value: Decodable { let from: String }
    struct Approvals: Decodable { let value: Int; let from: String }
    struct Project: Decodable { let approvals: Approvals? }
    let me: String?
    let readonly: Flag
    let sources: [Source]
    let projects: [String: Project]?
    let groups: [String: Value]?
    let observers: Observers?
    struct Observers: Decodable { let value: [String] }

    /// Projects that need someone else's approval before they go live.
    var guarded: [(name: String, approvals: Int)] {
        (projects ?? [:]).compactMap { e -> (name: String, approvals: Int)? in
            guard let n = e.value.approvals?.value, n > 0 else { return nil }
            return (name: e.key, approvals: n)
        }.sorted { $0.name < $1.name }
    }
}

struct TeamSettings: View {
    @ObservedObject var store: Store
    @State private var config: TeamConfig?
    @State private var repo = ""
    @State private var busy = false
    @State private var message: String?
    @State private var failed = false

    /// The switch is this Mac's file; DEPLOYS_READONLY and the observers list are shown, not switched.
    private var fromFile: Bool { config?.readonly.from.hasSuffix("/readonly exists") ?? false }
    private var forcedElsewhere: Bool { (config?.readonly.value ?? false) && !fromFile }

    var body: some View {
        Section {
            Text(L("A deploy-center.json in a repo gives everyone the same settings, without a server. This Mac's own settings win over it. Details: docs/TEAM.md.",
                   "Eine deploy-center.json im Repo gibt allen dieselben Einstellungen, ohne Server. Die Einstellungen dieses Macs gehen vor. Details: docs/TEAM.md."))
                .font(.caption).foregroundStyle(.secondary)

            Toggle(L("Observer (look, never deploy)", "Beobachter (nur ansehen, nie deployen)"), isOn: Binding(
                get: { config?.readonly.value ?? store.observer },
                set: { on in Task { await run(["readonly", on ? "on" : "off"]) } }))
                .disabled(busy || forcedElsewhere || config == nil)
            if forcedElsewhere, let from = config?.readonly.from {
                Text(L("Set by \(from).", "Gesetzt durch \(from).")).font(.caption).foregroundStyle(.secondary)
            }

            if let c = config {
                let found = c.sources.filter { $0.found }
                if found.isEmpty {
                    Text(L("No shared config found in the repos this Mac knows.", "In den Repos, die dieser Mac kennt, keine gemeinsame Konfiguration gefunden."))
                        .foregroundStyle(.secondary)
                }
                ForEach(found) { s in
                    LabeledContent(Demo.mask(s.repo)) {
                        Text((s.path ?? "") + ((s.stale ?? false) ? L(" (saved copy)", " (gespeicherte Kopie)") : ""))
                            .foregroundStyle(.secondary)
                    }
                }
                ForEach(c.sources.filter { $0.error != nil }) { s in
                    Text("⚠︎ " + Demo.mask(s.repo) + ": " + Demo.scrub(s.error ?? "", items: allItems)).font(.caption).foregroundStyle(Color.warningText)
                }
                if !c.guarded.isEmpty {
                    LabeledContent(L("Two-person rule", "Vier-Augen-Prinzip")) {
                        Text(c.guarded.map { "\(Demo.mask($0.name)) (\($0.approvals))" }.joined(separator: ", "))
                            .foregroundStyle(.secondary).multilineTextAlignment(.trailing)
                    }
                }
                if let g = c.groups, !g.isEmpty {
                    LabeledContent(L("Groups", "Gruppen")) { Text(g.keys.sorted().map { Demo.mask($0) }.joined(separator: ", ")).foregroundStyle(.secondary) }
                }
                if let me = c.me {
                    LabeledContent(L("You on GitHub", "Du auf GitHub")) { Text(Demo.person(me) ?? me).foregroundStyle(.secondary) }
                }
            }

            HStack {
                TextField(L("Another repo", "Weiteres Repo"), text: $repo, prompt: Text("owner/repo"))
                    .onSubmit { if canAdd { add() } }
                Button(L("Add", "Hinzufügen")) { add() }
                    .disabled(!canAdd)
                Button(L("Read again", "Neu lesen")) { Task { await run(["team", "refresh"]) } }.disabled(busy)
                if busy { ProgressView().controlSize(.small) }
            }
            if let message {
                if failed { ErrorText(Demo.scrub(message, items: allItems)) }
                else { Text(Demo.scrub(message, items: allItems)).font(.caption.monospaced()).textSelection(.enabled).foregroundStyle(.secondary) }
            }
        } header: {
            Text(L("Team", "Team"))
        }
        .task { await reload() }
    }

    private var allItems: [Item] { store.items.values.flatMap { $0 } }
    private var canAdd: Bool { repo.contains("/") && !busy }

    /// The field empties only when the repo was added, so a typo can be fixed.
    private func add() {
        Task {
            await run(["team", "add", repo.trimmingCharacters(in: .whitespaces)], show: true)
            if !failed { repo = "" }
        }
    }

    private func reload() async {
        config = try? await Tool.json(["config", "--json"], as: TeamConfig.self, timeout: 60)
        if let c = config { store.teamObserver = c.readonly.value }
    }

    private func run(_ args: [String], show: Bool = false) async {
        busy = true; defer { busy = false }
        do {
            let out = String(data: try await Tool.run(args, timeout: 60), encoding: .utf8)?
                .trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
            message = show && !out.isEmpty ? out : nil; failed = false
        } catch { message = error.localizedDescription; failed = true }
        await reload()
        // The doctor carries the observer flag for the window; read it again.
        if let d = try? await Tool.json(["doctor"], as: Doctor.self, timeout: 60) { store.doctor = d }
    }
}
