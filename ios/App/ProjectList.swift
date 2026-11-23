// The project list, its empty state and the relative time.

import CoreSpotlight
import SwiftUI
import UniformTypeIdentifiers
import UserNotifications

struct ProjectList: View {
    @ObservedObject var store: PhoneStore
    @ObservedObject var asks: Asks
    @Binding var selection: String?
    @Binding var settings: Bool
    @State private var query = ""
    @State private var scope = Scope.all
    @State private var showAllLive = false
    @FocusState private var searchFocus: Bool
    @Environment(\.openURL) private var openURL
    static let collapseAbove = 15, collapseTo = 10
    /// What the search covers besides the text (the scope bar under the search field).
    enum Scope: Hashable { case all, failed, vercel, render }

    var body: some View {
        // Also offline at the first start: nothing was ever read, and an empty list says nothing (IDEEN-12 C7).
        if store.projects.isEmpty && !store.loading && (store.loadedAt != nil || store.offline) {
            EmptyState(store: store, settings: $settings)
        } else {
            list
        }
    }

    private var list: some View {
        List(selection: $selection) {
            Section {
                if store.offline {
                    Label(L("Offline. You can read the list; deploying and rolling back are off until the connection is back.",
                            "Offline. Du kannst die Liste lesen; Deployen und Zurückrollen sind aus, bis die Verbindung wieder da ist."),
                          systemImage: "wifi.slash").font(.footnote).foregroundStyle(.secondary)
                }
                Summary(store: store)
                PhoneHealthCard(store: store)
                let ready = store.projects.filter { $0.group == .waiting && asks.canDeploy($0, store) }
                if ready.count >= 2 {
                    Button { asks.deployAll = ready } label: {
                        Label(L("Deploy all \(ready.count) waiting …", "Alle \(ready.count) wartenden deployen …"), systemImage: "paperplane.fill")
                    }
                }
                let auto = store.projects.filter(\.autoDeploy).count
                if auto > 0 {
                    // The point of the app: these build on every push, and every build costs.
                    Label(auto == 1 ? L("1 project builds on every push (auto-deploy on).", "1 Projekt baut bei jedem Push (Auto-Deploy an).")
                                    : L("\(auto) projects build on every push (auto-deploy on).", "\(auto) Projekte bauen bei jedem Push (Auto-Deploy an)."),
                          systemImage: "bolt.fill")
                        .font(.footnote).foregroundStyle(Color.warningText)
                }
            } footer: {
                VStack(alignment: .leading, spacing: 4) {
                    if let at = store.loadedAt {
                        // Read again every half minute, so "a minute ago" does not stay "now".
                        TimelineView(.periodic(from: .now, by: 30)) { _ in
                            Text((store.offline ? L("Offline · ", "Offline · ") : "")
                                 + (store.demo ? L("Demo data · ", "Demodaten · ") : "") + L("Updated ", "Stand ") + relative(at))
                        }
                    } else if store.offline {
                        Text(L("Offline", "Offline"))
                    }
                    // By position: two notes with the same wording are two rows, not one id twice.
                    ForEach(Array(store.errors.enumerated()), id: \.offset) { Text($0.element).foregroundStyle(.red) }
                    if !store.stale.isEmpty {
                        Text(L("Shown as last read: ", "Angezeigt wie zuletzt gelesen: ") + store.stale.map(\.rawValue).sorted().joined(separator: ", "))
                    }
                    if store.keyRefused {
                        Button(L("Check the keys in Settings", "Schlüssel in den Einstellungen prüfen")) { settings = true }
                            .font(.footnote)
                    }
                }
            }
            ForEach(PhoneProject.Group.allCases, id: \.self) { g in
                let all = store.projects.filter { $0.group == g && matches($0) }
                // A long "Up to date" list is cut to its first rows until asked for (IDEEN-12 C52); a search shows everything it finds.
                let cut = g == .live && all.count > Self.collapseAbove && !showAllLive && query.isEmpty
                let rows = cut ? Array(all.prefix(Self.collapseTo)) : all
                if !rows.isEmpty {
                    Section {
                        ForEach(rows) { p in
                            Row(p: p, running: store.running[p.key]).tag(p.key)
                                .contextMenu { menu(p) }
                                .swipeActions(edge: .trailing) {
                                    if asks.canDeploy(p, store) {
                                        Button { asks.deploy = p } label: { Label(L("Deploy", "Deployen"), systemImage: "paperplane") }
                                            .tint(.accentColor)
                                            .accessibilityInputLabels([L("Deploy", "Deployen")])
                                    }
                                }
                                // VoiceOver: the same actions as the detail view, without opening it.
                                .accessibilityActions {
                                    if asks.canDeploy(p, store) { Button(L("Deploy …", "Deployen …")) { asks.deploy = p } }
                                    if asks.canRollBack(p, store) { Button(L("Roll back …", "Zurückrollen …")) { asks.askRollback(p, store) } }
                                    if let d = p.domain, let url = URL(string: "https://" + d) {
                                        Button(L("Open domain", "Domain öffnen")) { openURL(url) }
                                    }
                                }
                        }
                        if cut {
                            Button(L("Show all \(all.count)", "Alle \(all.count) zeigen")) { showAllLive = true }
                        }
                    } header: { Text(g.title) }
                }
            }
        }
        .searchable(text: $query, prompt: L("Projects", "Projekte"))
        .searchScopes($scope) {
            Text(L("All", "Alle")).tag(Scope.all)
            Text(L("Failed", "Fehler")).tag(Scope.failed)
            Text("Vercel").tag(Scope.vercel)
            Text("Render").tag(Scope.render)
        }
        .searchFocused($searchFocus)
        // ⌘F, for a keyboard on the iPad.
        .background { Button("") { searchFocus = true }.keyboardShortcut("f").opacity(0).accessibilityHidden(true) }
        .refreshable { await store.refreshByHand() }
        .overlay { if store.loading && store.projects.isEmpty { ProgressView().accessibilityLabel(L("Loading projects", "Projekte werden geladen")) } }
        .toolbar {
            ToolbarItem(placement: .topBarLeading) {
                ShareLink(item: store.shareText) { Image(systemName: "square.and.arrow.up") }
                    .accessibilityLabel(L("Share the state", "Stand teilen"))
            }
        }
    }

    @ViewBuilder private func menu(_ p: PhoneProject) -> some View {
        Button { asks.deploy = p } label: { Label(L("Deploy …", "Deployen …"), systemImage: "paperplane") }
            .disabled(!asks.canDeploy(p, store))
            .accessibilityInputLabels([L("Deploy", "Deployen")])
        Button(role: .destructive) { asks.askRollback(p, store) } label: { Label(L("Roll back …", "Zurückrollen …"), systemImage: "arrow.uturn.backward") }
            .disabled(!asks.canRollBack(p, store))
            .accessibilityInputLabels([L("Roll back", "Zurückrollen")])
        if let d = p.domain, let url = URL(string: "https://" + d) {
            Button { openURL(url) } label: { Label(L("Open domain", "Domain öffnen"), systemImage: "safari") }
        }
        if let s = p.liveSha {
            Button { UIPasteboard.general.string = s } label: { Label(L("Copy live SHA", "Live-SHA kopieren"), systemImage: "doc.on.doc") }
        }
        if let url = p.dashboardURL {
            Button { openURL(url) } label: { Label(L("Open in the Render dashboard", "Im Render-Dashboard öffnen"), systemImage: "arrow.up.forward.app") }
        }
    }

    private func matches(_ p: PhoneProject) -> Bool {
        switch scope {
        case .all: break
        case .failed: if !p.failed { return false }
        case .vercel: if p.provider != .vercel { return false }
        case .render: if p.provider != .render { return false }
        }
        let q = query.trimmingCharacters(in: .whitespaces)
        guard !q.isEmpty else { return true }
        return [p.name, p.repo ?? "", p.domain ?? "", p.provider.rawValue].contains { $0.localizedCaseInsensitiveContains(q) }
    }
}

/// Keys are set, but nothing came back: why, and what to do.
struct EmptyState: View {
    @ObservedObject var store: PhoneStore
    @Binding var settings: Bool
    var body: some View {
        ContentUnavailableView {
            if store.offline && store.loadedAt == nil {
                Label(L("You are offline", "Du bist offline"), systemImage: "wifi.slash")
            } else if store.errors.isEmpty {
                Label(L("No projects found", "Keine Projekte gefunden"), systemImage: "tray")
            } else {
                Label(L("Could not read your projects", "Konnte deine Projekte nicht lesen"), systemImage: "exclamationmark.triangle")
            }
        } description: {
            if store.offline && store.loadedAt == nil {
                Text(L("Deploy Center needs a connection to read your projects. They load when you are back online.",
                       "Deploy Center braucht eine Verbindung, um deine Projekte zu lesen. Sie laden, sobald du wieder online bist."))
            } else if store.errors.isEmpty {
                Text(L("The keys work, but these accounts show no projects or services. For a Vercel team, enter its team id in Settings.",
                       "Die Schlüssel funktionieren, aber diese Konten zeigen keine Projekte oder Dienste. Für ein Vercel-Team trage seine Team-ID in den Einstellungen ein."))
            } else {
                Text(store.errors.joined(separator: "\n"))
            }
        } actions: {
            Button(L("Try again", "Erneut versuchen")) { Task { await store.reload() } }.buttonStyle(.borderedProminent)
            Button(L("Settings", "Einstellungen")) { settings = true }
        }
    }
}

/// "5 minutes ago" in the app's language.
func relative(_ d: Date) -> String {
    d.formatted(Date.RelativeFormatStyle(presentation: .named, locale: appLocale))
}
