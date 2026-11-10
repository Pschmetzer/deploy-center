// Deploy Center for iPhone — what waits on the Mac, read-only in this draft.
// The data comes from a SnapshotSource: iCloud key-value storage written by the Mac app once the
// iCloud container exists (see docs/WIDGETS-IOS.md), or made-up sample data with the -sample argument.

import SwiftUI

protocol SnapshotSource {
    var name: String { get }
    func load() async -> DeploySnapshot?
}

/// Made-up numbers: the simulator, screenshots, and the time before iCloud is set up.
struct SampleSource: SnapshotSource {
    var name: String { L("Sample data", "Beispieldaten") }
    func load() async -> DeploySnapshot? { .sample }
}

/// The Mac app writes the snapshot JSON under one key; iCloud carries it (1 MB limit, ours is a few KB).
/// Without the iCloud entitlement the store stays empty and this returns nil.
struct ICloudSource: SnapshotSource {
    static let key = "snapshot.v1"
    var name: String { "iCloud" }
    func load() async -> DeploySnapshot? {
        let kv = NSUbiquitousKeyValueStore.default
        kv.synchronize()
        guard let data = kv.data(forKey: Self.key) else { return nil }
        return try? DeploySnapshot.decoder.decode(DeploySnapshot.self, from: data)
    }
}

@MainActor
final class Model: ObservableObject {
    @Published var snap: DeploySnapshot?
    @Published var source: String = ""
    @Published var loading = false
    private let sources: [SnapshotSource]

    init() {
        let sample = ProcessInfo.processInfo.arguments.contains("-sample")
        // Sample data only when asked for: made-up projects next to a deploy button would mislead.
        sources = sample ? [SampleSource()] : [ICloudSource()]
    }
    func reload() async {
        loading = true; defer { loading = false }
        for s in sources { if let v = await s.load() { snap = v; source = s.name; return } }
        snap = nil; source = ""
    }
}

@main
struct CompanionApp: App {
    @StateObject private var model = Model()
    var body: some Scene {
        WindowGroup { ContentView(model: model).task { await model.reload() } }
    }
}

private func L(_ en: String, _ de: String) -> String {
    Locale.preferredLanguages.first?.hasPrefix("de") == true ? de : en
}
private func money(_ v: Double) -> String { v.formatted(.currency(code: "USD").precision(.fractionLength(0))) }

struct ContentView: View {
    @ObservedObject var model: Model
    var body: some View {
        NavigationStack {
            Group {
                if let s = model.snap { ListView(snap: s, source: model.source) }
                else if model.loading { ProgressView() }
                else {
                    ContentUnavailableView(L("No data yet", "Noch keine Daten"), systemImage: "icloud.slash",
                                           description: Text(L("Open Deploy Center on your Mac with iCloud turned on.",
                                                               "Öffne Deploy Center auf dem Mac mit eingeschaltetem iCloud.")))
                }
            }
            .navigationTitle("Deploy Center")
            .refreshable { await model.reload() }
        }
    }
}

struct ListView: View {
    let snap: DeploySnapshot
    let source: String
    var body: some View {
        List {
            Section {
                HStack(spacing: 0) {
                    Stat(value: "\(snap.waitingPRs)", label: L("PRs waiting", "PRs warten"), tint: .accentColor)
                    Stat(value: "\(snap.waitingProjects)", label: L("projects", "Projekte"), tint: .primary)
                    Stat(value: "\(snap.building)", label: L("building", "bauen"), tint: .blue)
                    Stat(value: "\(snap.failed)", label: L("failed", "Fehler"), tint: .red)
                }
                if let s = snap.saving, s.after < s.before {
                    Label(L("≈ \(money(s.month)) a month saved since auto-deploy is off",
                            "≈ \(money(s.month)) im Monat gespart, seit Auto-Deploy aus ist"), systemImage: "leaf.fill")
                        .font(.subheadline).foregroundStyle(.green)
                }
            } footer: {
                Text(L("Updated \(snap.at.formatted(.relative(presentation: .named))) · \(source)",
                       "Stand \(snap.at.formatted(.relative(presentation: .named))) · \(source)"))
            }
            Section(L("Projects", "Projekte")) {
                if snap.projects.isEmpty { Text(L("Nothing waits.", "Nichts wartet.")).foregroundStyle(.secondary) }
                ForEach(snap.projects) { p in
                    NavigationLink { DetailView(p: p) } label: { Row(p: p) }
                }
            }
        }
    }
}

struct Stat: View {
    let value: String, label: String, tint: Color
    var body: some View {
        VStack(spacing: 2) {
            Text(value).font(.title2.weight(.bold).monospacedDigit()).foregroundStyle(tint)
            Text(label).font(.caption2).foregroundStyle(.secondary)
        }
        .frame(maxWidth: .infinity)
    }
}

extension DeploySnapshot.Project.Status {
    var icon: String { switch self { case .building: "hammer.fill"; case .failed: "xmark.octagon.fill"; case .waiting: "arrow.up.circle.fill" } }
    var tint: Color { switch self { case .building: .blue; case .failed: .red; case .waiting: .accentColor } }
    var text: String {
        switch self { case .building: L("building", "baut"); case .failed: L("failed", "fehlgeschlagen"); case .waiting: L("waiting", "wartet") }
    }
}

struct Row: View {
    let p: DeploySnapshot.Project
    var body: some View {
        HStack(spacing: 12) {
            Image(systemName: p.status.icon).foregroundStyle(p.status.tint).font(.title3)
            VStack(alignment: .leading, spacing: 2) {
                Text(p.name).font(.body.weight(.semibold))
                Text(summary).font(.caption).foregroundStyle(.secondary)
            }
        }
    }
    private var summary: String {
        p.status == .waiting
            ? (p.prs > 0 ? "\(p.prs) PR · " : "") + L("\(p.commits) commits · \(p.platform)", "\(p.commits) Commits · \(p.platform)")
            : "\(p.status.text) · \(p.platform)"
    }
}

struct DetailView: View {
    let p: DeploySnapshot.Project
    @State private var confirm = false
    @State private var explained = false
    var body: some View {
        List {
            Section {
                LabeledContent(L("Status", "Status")) {
                    HStack(spacing: 6) { Image(systemName: p.status.icon); Text(p.status.text) }.foregroundStyle(p.status.tint)
                }
                LabeledContent(L("Platform", "Plattform"), value: p.platform)
                LabeledContent(L("Commits waiting", "Wartende Commits"), value: "\(p.commits)")
                LabeledContent(L("Pull requests", "Pull Requests"), value: "\(p.prs)")
                if let d = p.since {
                    LabeledContent(p.status == .waiting ? L("Waiting since", "Wartet seit") : L("Since", "Seit"),
                                   value: d.formatted(.relative(presentation: .named)))
                }
            }
            if let m = p.message { Section(L("Newest commit", "Neuester Commit")) { Text(m) } }
            Section {
                Button(p.status == .failed ? L("Deploy again …", "Erneut deployen …") : L("Approve and deploy …", "Freigeben und deployen …")) {
                    confirm = true
                }
                .disabled(p.status == .building)
            } footer: {
                Text(L("Read-only for now: the Mac decides. A request from the phone is planned, see the docs.",
                       "Vorerst nur lesen: Der Mac entscheidet. Eine Anfrage vom iPhone ist geplant, siehe Doku."))
            }
        }
        .navigationTitle(p.name)
        .confirmationDialog(L("Deploy \(p.name)?", "\(p.name) deployen?"), isPresented: $confirm, titleVisibility: .visible) {
            Button(L("Deploy", "Deployen")) { explained = true }
            Button(L("Cancel", "Abbrechen"), role: .cancel) {}
        } message: {
            Text(L("\(p.commits) commits go live on \(p.platform).", "\(p.commits) Commits gehen auf \(p.platform) live."))
        }
        .alert(L("Not sent", "Nicht gesendet"), isPresented: $explained) {
            Button("OK", role: .cancel) {}
        } message: {
            Text(L("This draft only reads. Deploy from the Mac for now.", "Dieser Entwurf liest nur. Deploye vorerst am Mac."))
        }
    }
}
