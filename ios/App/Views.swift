// Deploy Center for iPhone and iPad — List, details, settings. System fonts and colours only:
// Dynamic Type, dark mode and VoiceOver come with them.

import CoreSpotlight
import SwiftUI
import UniformTypeIdentifiers
import UserNotifications

/// The questions before a deploy or a rollback, asked in one place for the list, the details,
/// VoiceOver actions, the context menu and the keyboard.
@MainActor
final class Asks: ObservableObject {
    @Published var deploy: PhoneProject?
    /// Several waiting projects at once: one question, one Face ID.
    @Published var deployAll: [PhoneProject]?
    @Published var rollback: (project: PhoneProject, target: RollbackTarget)?
    /// The project whose rollback target is being looked up.
    @Published var finding: String?

    func askRollback(_ p: PhoneProject, _ store: PhoneStore) {
        guard finding == nil else { return }
        finding = p.key
        Task {
            defer { finding = nil }
            store.message = nil
            if let t = await store.rollbackTarget(p) { rollback = (p, t) }
            else if store.message == nil { store.say(L("Nothing to roll back to.", "Nichts zum Zurückrollen.")) }
        }
    }
    /// Offline: off, and the list says why (a banner), instead of a deploy that fails after the question.
    func canDeploy(_ p: PhoneProject, _ store: PhoneStore) -> Bool { p.deployable && !p.building && store.running[p.key] == nil && !store.offline }
    func canRollBack(_ p: PhoneProject, _ store: PhoneStore) -> Bool {
        finding == nil && !p.paused && !p.building && store.running[p.key] == nil && !store.offline
    }
}

/// What the keyboard shortcuts of the focused window act on (iPad with a keyboard).
struct DeployActions {
    let reload: () -> Void
    let settings: () -> Void
    let deploy: (() -> Void)?
}
extension FocusedValues {
    @Entry var deployActions: DeployActions?
}

struct DeployCommands: Commands {
    @FocusedValue(\.deployActions) private var actions
    var body: some Commands {
        CommandGroup(after: .newItem) {
            Button(L("Reload", "Neu laden")) { actions?.reload() }
                .keyboardShortcut("r").disabled(actions == nil)
            Button(L("Deploy the selected project …", "Ausgewähltes Projekt deployen …")) { actions?.deploy?() }
                .keyboardShortcut("d").disabled(actions?.deploy == nil)
        }
        CommandGroup(replacing: .appSettings) {
            Button(L("Settings …", "Einstellungen …")) { actions?.settings() }
                .keyboardShortcut(",").disabled(actions == nil)
        }
    }
}

struct RootView: View {
    @ObservedObject var store: PhoneStore
    @StateObject private var asks = Asks()
    @Environment(\.scenePhase) private var phase
    @Environment(\.horizontalSizeClass) private var sizeClass
    /// Per window: with Stage Manager two windows can show two projects.
    @SceneStorage("selection") private var selection: String?
    @State private var settings = false
    @State private var connect = false
    @State private var captured = UIScreen.main.isCaptured
    /// A widget link that came before the list was read: name and platform.
    @State private var pendingOpen: [String]?
    /// When it was set: a link the first list does not hold is dropped after DeepLink.patience.
    @State private var pendingAt = Date.distantPast

    private var selected: PhoneProject? { selection.flatMap { key in store.projects.first { $0.key == key } } }

    var body: some View {
        NavigationSplitView {
            Group {
                if !store.booted && store.projects.isEmpty && !store.demo { ProgressView().accessibilityLabel(L("Loading projects", "Projekte werden geladen")) }
                else if !store.demo && !store.hasAccount { Welcome(store: store, settings: $settings, connect: $connect) }
                else { ProjectList(store: store, asks: asks, selection: $selection, settings: $settings) }
            }
            .navigationTitle("Deploy Center")
            .toolbar {
                ToolbarItem(placement: .topBarTrailing) {
                    Button { settings = true } label: { Image(systemName: "gearshape") }
                        .accessibilityLabel(L("Settings", "Einstellungen"))
                        .accessibilityInputLabels([L("Settings", "Einstellungen"), L("Preferences", "Optionen")])
                }
            }
        } detail: {
            if let p = selected {
                // A stack of its own: the log and the history push inside the detail column on iPad too.
                NavigationStack { ProjectDetail(store: store, asks: asks, project: p) }.id(p.key)
            } else {
                ContentUnavailableView(L("Choose a project", "Wähle ein Projekt"), systemImage: "square.stack.3d.up")
            }
        }
        .focusedSceneValue(\.deployActions, DeployActions(
            reload: { Task { await store.reload() } },
            settings: { settings = true },
            deploy: selected.flatMap { p in asks.canDeploy(p, store) ? { asks.deploy = p } : nil }))
        .deployQuestions(store: store, asks: asks)
        .sheet(isPresented: $settings) { SettingsView(store: store) }
        // Our own sentence first, then the system's question (IDEEN-12 C12).
        .alert(L("Report the end of deploys?", "Das Ende von Deploys melden?"), isPresented: $store.askNotes) {
            Button(L("Allow", "Erlauben")) { Task { await Notes.askOnce() } }
            // "Not now" is remembered: the question is not asked at every deploy.
            Button(L("Not now", "Nicht jetzt"), role: .cancel) { UserDefaults.standard.set(true, forKey: "notesAskDeclined") }
        } message: {
            Text(L("Deploy Center can tell you when a deploy you started is live or has failed, even when the app is in the background. The next question is the system's.",
                   "Deploy Center kann dir sagen, wann ein gestarteter Deploy live ist oder fehlgeschlagen ist, auch wenn die App im Hintergrund ist. Die nächste Frage kommt vom System."))
        }
        .sheet(isPresented: $connect) { ConnectMacView(store: store) }
        .onChange(of: phase) { _, p in
            guard p == .active, !store.demo, !store.loading else { return }
            store.forgetKeptTokens()    // the keychain may have changed while the app was away
            Task {
                let had = store.linked
                await store.refreshLink()
                // Back after a while: read again, the list would show an old state otherwise.
                let old = store.loadedAt.map { Date().timeIntervalSince($0) > 5 * 60 } ?? true
                if store.linked != had || old { await store.reload() }
            }
        }
        .onContinueUserActivity(CSSearchableItemActionType) { a in if let k = Spotlight.key(a) { selection = k } }
        .onContinueUserActivity(Spotlight.activity) { a in if let k = Spotlight.key(a) { selection = k } }
        .onChange(of: store.openKey, initial: true) { _, k in if let k { selection = k; store.openKey = nil } }
        .onChange(of: store.confirmDeployKey, initial: true) { _, k in
            guard let k else { return }
            store.confirmDeployKey = nil
            if let p = store.projects.first(where: { $0.key == k }), asks.canDeploy(p, store) { asks.deploy = p }
        }
        .onChange(of: store.projects) { _, _ in
            guard let w = pendingOpen, let first = w.first else { return }
            // A link from an hour ago must not open a project that appears now.
            if Date().timeIntervalSince(pendingAt) > DeepLink.patience { pendingOpen = nil; return }
            if first.hasPrefix("key:") {
                let k = String(first.dropFirst(4))
                if store.projects.contains(where: { $0.key == k }) { selection = k; pendingOpen = nil }
            } else { open(name: first, platform: w.count > 1 ? w[1] : nil) }
        }
        // A link to a project the first full list does not hold is dropped: a later list must not open it by surprise.
        .onChange(of: store.loadedAt) { _, t in
            guard t != nil, let w = pendingOpen, let first = w.first else { return }
            if Date().timeIntervalSince(pendingAt) > DeepLink.patience { pendingOpen = nil; return }
            if first.hasPrefix("key:") {
                let k = String(first.dropFirst(4))
                if store.projects.contains(where: { $0.key == k }) { selection = k }
            } else { open(name: first, platform: w.count > 1 ? w[1] : nil) }
            pendingOpen = nil
        }
        // deploycenter://select?project=<name>&platform=<Vercel|Render>, from the widget. It only shows the project.
        .onOpenURL { url in
            guard url.scheme == "deploycenter" else { return }
            let items = URLComponents(url: url, resolvingAgainstBaseURL: false)?.queryItems ?? []
            // deploycenter://settings and deploycenter://reload: harmless. deploycenter://deploy?key=…: only opens the question; a tap and Face ID still start it (IDEEN-12 C34).
            switch url.host {
            case "settings": settings = true; return
            case "reload": Task { await store.reload() }; return
            case "deploy":
                if let key = items.first(where: { $0.name == "key" })?.value { store.confirmDeployKey = key; selection = key }
                return
            default: break
            }
            // The key is exact; name and platform are the fallback for links from an older widget or the Mac.
            if let key = items.first(where: { $0.name == "key" })?.value, !key.isEmpty {
                if store.projects.contains(where: { $0.key == key }) { selection = key; pendingOpen = nil } else { pendingOpen = ["key:" + key]; pendingAt = Date() }
                return
            }
            guard let name = items.first(where: { $0.name == "project" })?.value else { return }
            open(name: name, platform: items.first { $0.name == "platform" }?.value)
        }
        .task {
            Background.schedule()
            await store.reload()
            Task { await store.resumeFollowed() }
            #if DEBUG
            // For screenshots: -open <name> selects a project, -settings shows the settings.
            let args = ProcessInfo.processInfo.arguments
            if let i = args.firstIndex(of: "-open"), i + 1 < args.count {
                selection = store.projects.first { $0.name == args[i + 1] }?.key
            }
            #endif
            // Wide screens: an empty detail column helps nobody. The window's own choice stays.
            if sizeClass == .regular && selected == nil {
                selection = (store.projects.first { $0.group == .attention } ?? store.projects.first { $0.group == .waiting })?.key
            }
            #if DEBUG
            if args.contains("-settings") { try? await Task.sleep(for: .seconds(1)); settings = true }
            // -keepalive: runs the background-time helper once, without a deploy (a check that it does not crash).
            if args.contains("-keepalive") {
                let k = KeepAlive.start(title: "Test", subtitle: "Deploy Center")
                try? await Task.sleep(for: .seconds(2)); k.update("building", fraction: 0.5)
                try? await Task.sleep(for: .seconds(2)); k.finish(success: true)
                store.say("keepalive ok")
            }
            #endif
        }
        // Under the list, not over its last row (IDEEN-12 C10).
        .safeAreaInset(edge: .bottom) {
            if let m = store.message { Toast(store: store, text: m) }
        }
        .sensoryFeedback(trigger: store.messageSerial) { _, _ in
            guard store.message != nil else { return nil }
            return store.messageIsError ? .error : .success
        }
        // App lock (optional) and the cover in the app switcher: nothing of the list shows.
        .overlay {
            // Not while Face ID asks: its sheet makes the app inactive too, and the cover would flicker over the question (IDEEN-12 C8).
            if store.locked || (PhoneStore.lockOnOpen && !store.demo && phase != .active && !store.authenticating) {
                LockCover(store: store)
            } else if captured && !store.demo {
                // Screen recording or mirroring: the names stay out of it (IDEEN-12 C41).
                CapturedCover()
            }
        }
        .onReceive(NotificationCenter.default.publisher(for: UIScreen.capturedDidChangeNotification)) { _ in captured = UIScreen.main.isCaptured }
        .onChange(of: phase) { _, p in if p == .active && store.locked { Task { await store.unlock() } } }
        // Sheets lie above the cover: close them when locking (the settings sheet takes its own QR sheet along).
        .onChange(of: store.locked) { _, on in if on { settings = false; connect = false } }
    }

    private func open(name: String, platform: String?) {
        // "vercel:web" (the Mac, Alfred and Raycast write it so) or a name with a platform parameter; any case.
        let t = DeepLink.target(project: name, platform: platform)
        if let p = store.projects.first(where: { $0.name == t.name && DeepLink.samePlatform($0.provider.rawValue, t.platform) }) {
            selection = p.key; pendingOpen = nil
        } else if pendingOpen == nil || pendingOpen?.first != t.name {
            pendingOpen = [t.name] + (t.platform.map { [$0] } ?? []); pendingAt = Date()
        }
    }
}

extension View {
    /// The deploy and rollback questions; `asks` says which one is open.
    func deployQuestions(store: PhoneStore, asks: Asks) -> some View { modifier(DeployQuestions(store: store, asks: asks)) }
}

struct DeployQuestions: ViewModifier {
    @ObservedObject var store: PhoneStore
    @ObservedObject var asks: Asks

    func body(content: Content) -> some View {
        let p = asks.deploy
        // Already on the newest commit: say so, as the Mac app does; a build changes nothing and costs minutes.
        let nothingNew = p?.upToDate ?? false
        content
            .confirmationDialog(nothingNew ? L("Nothing new to deploy", "Nichts Neues zu deployen")
                                           : L("Deploy \(p?.name ?? "")?", "\(p?.name ?? "") deployen?"),
                                isPresented: Binding(get: { asks.deploy != nil }, set: { if !$0 { asks.deploy = nil } }),
                                titleVisibility: .visible, presenting: p) { p in
                Button(nothingNew ? L("Build anyway", "Trotzdem bauen") : L("Deploy", "Deployen")) { Task { await store.deploy(p) } }
                Button(L("Cancel", "Abbrechen"), role: .cancel) {}
            } message: { p in
                if nothingNew {
                    Text(L("\(p.name) is already on the newest commit. A build costs build minutes and changes nothing.",
                           "\(p.name) ist schon auf dem neuesten Stand. Ein Build kostet Build-Minuten und ändert nichts."))
                } else {
                    Text(p.deploySummary)
                }
            }
            .confirmationDialog(L("Deploy \(asks.deployAll?.count ?? 0) projects?", "\(asks.deployAll?.count ?? 0) Projekte deployen?"),
                                isPresented: Binding(get: { asks.deployAll != nil }, set: { if !$0 { asks.deployAll = nil } }),
                                titleVisibility: .visible, presenting: asks.deployAll) { all in
                Button(L("Deploy all", "Alle deployen")) { Task { await store.deployMany(all) } }
                Button(L("Cancel", "Abbrechen"), role: .cancel) {}
            } message: { all in
                Text(all.map(\.name).joined(separator: ", ") + L(". Each build can cost build minutes. One \(store.unlockName) question for all.",
                                                                  ". Jeder Build kann Build-Minuten kosten. Eine \(store.unlockName)-Frage für alle."))
            }
            .confirmationDialog(L("Roll back \(asks.rollback?.project.name ?? "")?", "\(asks.rollback?.project.name ?? "") zurückrollen?"),
                                isPresented: Binding(get: { asks.rollback != nil }, set: { if !$0 { asks.rollback = nil } }),
                                titleVisibility: .visible, presenting: asks.rollback) { r in
                Button(L("Roll back", "Zurückrollen"), role: .destructive) { Task { await store.rollback(r.project, to: r.target) } }
                Button(L("Cancel", "Abbrechen"), role: .cancel) {}
            } message: { r in
                Text(Self.describe(r.target))
            }
    }

    /// "a1b2c3d “Fix the header”, from 3 days ago"; without a commit the deploy id names it.
    static func describe(_ t: RollbackTarget) -> String {
        var what = t.sha.map { String($0.prefix(7)) } ?? String(t.id.prefix(24))
        if let m = t.title, !m.isEmpty { what += " “\(m)”" }
        if let d = t.at { what += L(", from ", ", vom ") + d.formatted(Date.FormatStyle(date: .abbreviated, time: .shortened).locale(appLocale)) }
        return L("The previous deploy goes live again: \(what).", "Der vorige Deploy geht wieder live: \(what).")
    }
}

/// A short note at the bottom. VoiceOver hears it; errors (and everything while VoiceOver runs)
/// stay until closed, other notes for a few seconds.
struct Toast: View {
    @Environment(\.accessibilityReduceTransparency) private var reduceTransparency
    @ObservedObject var store: PhoneStore
    let text: String
    var body: some View {
        HStack(spacing: 10) {
            if store.messageIsError { Image(systemName: "exclamationmark.triangle.fill").foregroundStyle(.red).accessibilityHidden(true) }
            Text(text).font(.callout)
            Button { store.message = nil } label: {
                Image(systemName: "xmark.circle.fill").foregroundStyle(.secondary)
                    .frame(minWidth: 44, minHeight: 44).contentShape(Rectangle())
            }
                .buttonStyle(.plain)
                .accessibilityLabel(L("Close message", "Meldung schließen"))
                .accessibilityInputLabels([L("Close", "Schließen"), L("Dismiss", "Ausblenden")])
        }
        .padding(.leading, 16).padding(.trailing, 6).padding(.vertical, 2)
        .background(reduceTransparency ? AnyShapeStyle(Color(.secondarySystemBackground)) : AnyShapeStyle(.regularMaterial), in: RoundedRectangle(cornerRadius: 18))
        .padding(.horizontal, 16).padding(.bottom, 12)
        .accessibilityElement(children: .contain)
        .task(id: store.messageSerial) {
            AccessibilityNotification.Announcement(store.messageIsError ? L("Error: ", "Fehler: ") + text : text).post()
            guard !store.messageIsError, !UIAccessibility.isVoiceOverRunning else { return }
            // Switch Control needs longer to reach the close button (IDEEN-12 C48).
            let slow = UIAccessibility.isSwitchControlRunning
            try? await Task.sleep(for: .seconds(slow ? 20 : 5))
            if store.message == text { store.message = nil }
        }
    }
}

/// Shown while the screen is recorded or mirrored.
struct CapturedCover: View {
    var body: some View {
        ZStack {
            Rectangle().fill(.background).ignoresSafeArea()
            VStack(spacing: 12) {
                Image(systemName: "record.circle").font(.largeTitle).foregroundStyle(.secondary).accessibilityHidden(true)
                Text(L("Hidden while the screen is recorded", "Verdeckt, solange der Bildschirm aufgenommen wird"))
                    .font(.headline).multilineTextAlignment(.center)
            }.padding()
        }
    }
}

struct LockCover: View {
    @ObservedObject var store: PhoneStore
    var body: some View {
        ZStack {
            Rectangle().fill(.background).ignoresSafeArea()
            VStack(spacing: 16) {
                Image(systemName: "lock.fill").font(.largeTitle).foregroundStyle(.secondary).accessibilityHidden(true)
                Text("Deploy Center").font(.headline)
                if store.locked {
                    Button(L("Unlock", "Entsperren")) { Task { await store.unlock() } }.buttonStyle(.borderedProminent)
                }
            }
        }
        .task { await store.unlock() }   // at launch; on return the scene phase asks
    }
}

struct Welcome: View {
    @ObservedObject var store: PhoneStore
    @Binding var settings: Bool
    @Binding var connect: Bool
    var body: some View {
        ContentUnavailableView {
            Label(L("Your deploys, on the go", "Deine Deploys, unterwegs"), systemImage: "paperplane.fill")
        } description: {
            Text(L("Connect to Deploy Center on your Mac, or add a Vercel token or a Render API key. Keys go only to Vercel, Render and GitHub.",
                   "Verbinde dich mit Deploy Center auf deinem Mac, oder füge ein Vercel-Token oder einen Render-API-Key hinzu. Schlüssel gehen nur an Vercel, Render und GitHub."))
            Text(L("A Vercel token needs the scope of the team whose projects you want to see. A Render API key sees every workspace of its account.",
                   "Ein Vercel-Token braucht als Bereich das Team, dessen Projekte du sehen willst. Ein Render-API-Key sieht alle Workspaces seines Kontos."))
                .font(.footnote)
        } actions: {
            Button(L("Connect to the Mac", "Mit dem Mac verbinden")) { connect = true }.buttonStyle(.borderedProminent)
            Button(L("Enter a token", "Token eingeben")) { settings = true }
            Link(L("Create a Vercel token", "Vercel-Token anlegen"), destination: URL(string: "https://vercel.com/account/tokens")!)
            Link(L("Create a Render API key", "Render-API-Key anlegen"), destination: URL(string: "https://dashboard.render.com/u/settings#api-keys")!)
            Button(L("Try the demo", "Demo ausprobieren")) { store.demo = true }
        }
    }
}

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

struct Summary: View {
    @ObservedObject var store: PhoneStore
    @Environment(\.dynamicTypeSize) private var size
    var body: some View {
        let n = store.waitingPRs, w = store.waiting.count
        let prs = Stat(value: n, label: n == 1 ? L("PR waiting", "PR wartet") : L("PRs waiting", "PRs warten"), tint: .accentColor)
        let projects = Stat(value: w, label: w == 1 ? L("project", "Projekt") : L("projects", "Projekte"), tint: .primary)
        let building = Stat(value: store.projects.filter(\.building).count, label: L("building", "bauen"), tint: .blue)
        let failed = Stat(value: store.projects.filter(\.failed).count, label: L("failed", "Fehler"), tint: .red)
        Group {
            // Four in a row get too tight from the largest standard text size on: two rows of two then.
            if size.isAccessibilitySize {
                // One column: at accessibility sizes even two stats side by side do not fit (IDEEN-12 C46).
                VStack(alignment: .leading, spacing: 10) { prs; projects; building; failed }
            } else if size >= .xxxLarge {
                Grid(verticalSpacing: 12) { GridRow { prs; projects }; GridRow { building; failed } }
            } else {
                HStack(spacing: 0) { prs; projects; building; failed }
            }
        }
        .padding(.vertical, 4)
        // One sentence instead of the numbers and words read as separate pieces.
        .accessibilityElement(children: .ignore)
        .accessibilityLabel(L("\(plural(n, ("PR", "PR"), ("PRs", "PRs"))) waiting in \(plural(w, ("project", "Projekt"), ("projects", "Projekten"))), \(store.projects.filter(\.building).count) building, \(store.projects.filter(\.failed).count) failed",
                              "\(plural(n, ("PR", "PR"), ("PRs", "PRs"))) \(n == 1 ? "wartet" : "warten") in \(plural(w, ("project", "Projekt"), ("projects", "Projekten"))), \(store.projects.filter(\.building).count) im Bau, \(store.projects.filter(\.failed).count) fehlgeschlagen"))
    }
}

struct Stat: View {
    let value: Int, label: String, tint: Color
    var body: some View {
        VStack(spacing: 2) {
            Text("\(value)").font(.title2.weight(.bold).monospacedDigit()).foregroundStyle(tint)
            Text(label).font(.caption2).foregroundStyle(.secondary).lineLimit(2).multilineTextAlignment(.center)
                .minimumScaleFactor(0.85)
        }
        .frame(maxWidth: .infinity)
    }
}

extension PhoneProject {
    var icon: String {
        building ? "hammer.fill" : failed ? "xmark.octagon.fill" : changed ? "arrow.up.circle.fill"
            : unknown ? "questionmark.circle" : foreignRepo ? "minus.circle" : "checkmark.circle.fill"
    }
    var tint: Color { building ? .blue : failed ? .red : changed ? .accentColor : unknown ? .orange : foreignRepo ? .secondary : .green }
    var stateText: String {
        if building { return L("building", "baut") }
        if failed { return latestState.map(Self.stateWord) ?? L("failed", "fehlgeschlagen") }
        // Before `changed`: after a force push the compare fails and the count is unknown, not 0.
        if rewritten && changed { return L("history rewritten · count unknown", "Verlauf neu geschrieben · Anzahl unbekannt") }
        if changed {
            let prs = (pendingPRs ?? 0) > 0 ? plural(pendingPRs!, ("PR", "PR"), ("PRs", "PRs"), atLeast: prsAtLeast) + " · " : ""
            guard let n = pendingCommits else { return prs + L("waiting, count unknown", "wartet, Anzahl unbekannt") }
            return prs + (n == 1 ? L("1 commit waiting", "1 Commit wartet") : L("\(n) commits waiting", "\(n) Commits warten"))
        }
        if paused { return L("paused", "pausiert") }
        if rewritten { return L("history rewritten", "Verlauf neu geschrieben") }
        if let h = otherHost { return L("on \(h): not checked", "auf \(h): nicht geprüft") }
        if unknown { return L("state unknown", "Stand unbekannt") }
        if canceled { return L("up to date · last build canceled", "aktuell · letzter Build abgebrochen") }
        return L("up to date", "aktuell")
    }

    /// What goes live, for the confirmation: the newest commit, how much waits, and what it costs.
    var deploySummary: String {
        let sha = headSha.map { " (\($0.prefix(7)))" } ?? ""
        var s = headMsg.map { L("\"\($0)\"\(sha) ", "„\($0)“\(sha) ") } ?? ""
        if let n = pendingCommits, n > 0 {
            s += L("and \(plural(n, ("commit", "Commit"), ("commits", "Commits"))) in all", "und insgesamt \(plural(n, ("commit", "Commit"), ("commits", "Commits")))")
            if let k = pendingPRs, k > 0 { s += L(" from \(plural(k, ("PR", "PR"), ("PRs", "PRs"), atLeast: prsAtLeast))", " aus \(plural(k, ("PR", "PR"), ("PRs", "PRs"), atLeast: prsAtLeast))") }
            s += " "
        }
        let branch = branch ?? L("the branch", "dem Branch")
        let what = s.isEmpty ? L("The newest commit of \(branch) ", "Der neueste Commit von \(branch) ") : s
        return what + L("goes live on \(provider.rawValue). This can cost build minutes.", "geht auf \(provider.rawValue) live. Das kann Build-Minuten kosten.")
    }
}

struct Row: View {
    let p: PhoneProject
    let running: String?
    @ScaledMetric(relativeTo: .title3) private var iconWidth = 24.0
    var body: some View {
        HStack(spacing: 12) {
            if let r = running {
                ProgressView().frame(width: iconWidth).accessibilityLabel(PhoneProject.stateWord(r))
                    .accessibilityValue(p.latestAt.map { relative($0) } ?? "")
            } else {
                Image(systemName: p.icon).foregroundStyle(p.tint).font(.title3).frame(width: iconWidth).accessibilityHidden(true)
            }
            VStack(alignment: .leading, spacing: 2) {
                Text(p.name).font(.body.weight(.semibold))
                Text(line).font(.caption).foregroundStyle(.secondary)
            }
        }
        .accessibilityElement(children: .combine)
    }
    private var line: String {
        let state = running.map { $0 == "rollback" ? PhoneProject.stateWord($0) : L("deploying: ", "deployt: ") + PhoneProject.stateWord($0) } ?? p.stateText
        // Auto-deploy on means every push builds: the cost this app is about.
        return state + " · " + p.provider.rawValue + (p.autoDeploy ? " · " + L("auto-deploy", "Auto-Deploy") : "")
    }
}

struct ProjectDetail: View {
    @ObservedObject var store: PhoneStore
    @ObservedObject var asks: Asks
    let project: PhoneProject
    @State private var confirmCancel = false
    @State private var renderAction: RenderAction?

    var body: some View {
        let p = project
        let busy = store.running[p.key] != nil
        List {
            Section {
                LabeledContent(L("Status", "Status")) {
                    // A deploy followed here shows its live state, like the row does (IDEEN-12 C9).
                    if let r = store.running[p.key] {
                        HStack(spacing: 6) {
                            ProgressView().controlSize(.small).accessibilityHidden(true)
                            Text(r == "rollback" ? PhoneProject.stateWord(r) : L("deploying: ", "deployt: ") + PhoneProject.stateWord(r))
                        }.foregroundStyle(.blue)
                    } else {
                        HStack(spacing: 6) { Image(systemName: p.icon).accessibilityHidden(true); Text(p.stateText) }.foregroundStyle(p.tint)
                    }
                }
                LabeledContent(L("Platform", "Plattform"), value: p.provider.rawValue)
                LabeledContent(L("Auto-deploy", "Auto-Deploy")) {
                    Text(p.autoDeploy ? L("on: every push builds", "an: jeder Push baut") : L("off", "aus"))
                        .foregroundStyle(p.autoDeploy ? Color.warningText : .secondary)
                }
                if let r = p.repo { LabeledContent(L("Repository", "Repository"), value: r + (p.branch.map { " · \($0)" } ?? "")) }
                if let h = p.otherHost { LabeledContent(L("Repository", "Repository"), value: L("on \(h) (only GitHub is read)", "auf \(h) (gelesen wird nur GitHub)")) }
                if let d = p.domain { LabeledContent(L("Domain", "Domain"), value: d) }
                if let n = p.openPRs { LabeledContent(L("Open pull requests", "Offene Pull Requests"), value: "\(n)" + (p.openPRsCapped ? "+" : "")) }
                if let d = p.oldestPendingAt, p.changed {
                    TimelineView(.periodic(from: .now, by: 30)) { _ in
                        LabeledContent(L("Waiting since", "Wartet seit"), value: relative(d))
                    }
                }
                if let e = p.fetchError { Text(e).font(.footnote).foregroundStyle(.red) }
            } footer: {
                VStack(alignment: .leading, spacing: 4) {
                    if p.autoDeploy {
                        Text(L("Every push to \(p.branch ?? "the branch") builds and goes live, and each build can cost build minutes.",
                               "Jeder Push auf \(p.branch ?? "den Branch") baut und geht live, und jeder Build kann Build-Minuten kosten."))
                    }
                    if store.stale.contains(p.provider) {
                        Text(L("\(p.provider.rawValue) could not be read just now: this is the last state read.",
                               "\(p.provider.rawValue) war gerade nicht lesbar: das ist der zuletzt gelesene Stand."))
                    }
                }
            }
            Section(L("Commits", "Commits")) {
                if let m = p.headMsg { LabeledContent(L("Newest", "Neuester"), value: m) }
                if let m = p.liveMsg { LabeledContent(L("Live", "Live"), value: m) }
                // Both commits, so "SHA" is never ambiguous; long press copies the whole one.
                if let s = p.liveSha { ShaRow(label: L("Live commit", "Live-Commit"), sha: s) }
                if let s = p.headSha, s != p.liveSha { ShaRow(label: L("Newest commit", "Neuester Commit"), sha: s) }
            }
            .textSelection(.enabled)
            if p.changed, let titles = p.pendingTitles, !titles.isEmpty {
                Section {
                    ForEach(Array(titles.enumerated()), id: \.offset) { Text($0.element).font(.callout) }
                } header: { Text(L("Goes live with the next deploy", "Geht mit dem nächsten Deploy live")) } footer: {
                    if let n = p.pendingCommits, n > titles.count {
                        Text(L("Newest first; \(n - titles.count) older not shown.", "Neueste zuerst; \(n - titles.count) ältere nicht gezeigt."))
                    }
                }
            }
            Section(L("Deploys", "Deploys")) {
                if p.failed {
                    NavigationLink { BuildLogView(store: store, project: p, record: nil) } label: {
                        Label(L("Why it failed (log)", "Warum es fehlschlug (Log)"), systemImage: "exclamationmark.bubble")
                    }
                }
                NavigationLink { DeployHistoryView(store: store, project: p) } label: {
                    Label(L("History", "Verlauf"), systemImage: "clock.arrow.circlepath")
                }
            }
            if !store.demo, let links = links(p), !links.isEmpty {
                Section(L("Open", "Öffnen")) { ForEach(links, id: \.1) { Link($0.0, destination: $0.1) } }
            }
            Section {
                Button {
                    asks.deploy = p
                } label: {
                    Label(p.failed ? L("Deploy again …", "Erneut deployen …") : L("Deploy the newest commit …", "Neuesten Commit deployen …"),
                          systemImage: "paperplane")
                }
                .disabled(!asks.canDeploy(p, store))
                // A build that a push started: watch it here for the end note and the Live Activity.
                if p.building, store.running[p.key] == nil, p.latestId != nil, !store.offline {
                    Button { Task { await store.followBuild(p) } } label: { Label(L("Follow the build", "Build verfolgen"), systemImage: "eye") }
                }
                if store.buildId(p) != nil && (p.building || store.running[p.key].map { $0 != "rollback" && $0 != "starting" } == true) {
                    Button(role: .destructive) { confirmCancel = true } label: {
                        Label(L("Cancel the build …", "Build abbrechen …"), systemImage: "stop.circle")
                    }
                }
                Button(role: .destructive) {
                    asks.askRollback(p, store)
                } label: {
                    HStack {
                        Label(L("Roll back …", "Zurückrollen …"), systemImage: "arrow.uturn.backward")
                        if asks.finding == p.key { Spacer(); ProgressView() }
                    }
                }
                .disabled(!asks.canRollBack(p, store))
                if p.provider == .render {
                    ForEach(p.paused ? [RenderAction.resume] : [.restart, .suspend], id: \.self) { a in
                        Button(role: a == .suspend ? .destructive : nil) { renderAction = a } label: { Label(a.title, systemImage: a.icon) }
                            .disabled(busy || p.building)
                    }
                }
            } footer: {
                let how = store.unlockName
                Text(L("Each deploy, cancel and rollback asks for \(how). It goes straight from this device to \(p.provider.rawValue).",
                       "Jeder Deploy, jeder Abbruch und jedes Zurückrollen fragt nach \(how). Es geht direkt von diesem Gerät an \(p.provider.rawValue)."))
            }
        }
        .navigationTitle(p.name)
        .refreshable { await store.refreshByHand() }
        // With the app lock on, the project's name does not leave for other devices through Handoff.
        .userActivity(Spotlight.activity, isActive: !store.demo && !PhoneStore.lockOnOpen) { a in
            a.title = p.name; a.userInfo = ["project": p.key]
            a.isEligibleForHandoff = true; a.isEligibleForSearch = false
            // A Mac continues with the project's dashboard in its browser (IDEEN-12 C35); nothing is started by it.
            a.webpageURL = p.dashboardURL
        }
        .confirmationDialog(renderAction.map { $0.title.replacingOccurrences(of: " …", with: "?") } ?? "",
                            isPresented: Binding(get: { renderAction != nil }, set: { if !$0 { renderAction = nil } }), titleVisibility: .visible) {
            Button(renderAction?.title.replacingOccurrences(of: " …", with: "") ?? "", role: renderAction == .suspend ? .destructive : nil) {
                if let a = renderAction { Task { await store.serviceAction(p, a) } }
            }
            Button(L("Cancel", "Abbrechen"), role: .cancel) {}
        } message: {
            Text(renderAction == .suspend ? L("The service stops answering until it is resumed.", "Der Dienst antwortet nicht mehr, bis er fortgesetzt wird.")
                 : renderAction == .restart ? L("The live deploy starts again; nothing is built.", "Der Live-Deploy startet neu; gebaut wird nichts.")
                 : L("The service starts again with its last deploy.", "Der Dienst startet wieder mit seinem letzten Deploy."))
        }
        .confirmationDialog(L("Cancel the build of \(p.name)?", "Build von \(p.name) abbrechen?"), isPresented: $confirmCancel, titleVisibility: .visible) {
            Button(L("Cancel the build", "Build abbrechen"), role: .destructive) { Task { await store.cancelBuild(p) } }
            Button(L("Keep building", "Weiterbauen"), role: .cancel) {}
        } message: {
            Text(L("What is live stays live.", "Was live ist, bleibt live."))
        }
    }

    private func links(_ p: PhoneProject) -> [(String, URL)]? {
        var out: [(String, URL)] = []
        if let d = p.domain, let u = URL(string: "https://" + d) { out.append((d, u)) }
        if let r = p.repo, let u = URL(string: "https://github.com/" + r) {
            if let s = p.headSha, let c = URL(string: u.absoluteString + "/commit/" + s) { out.append((L("Newest commit on GitHub", "Neuester Commit auf GitHub"), c)) }
            if let l = p.liveSha, let h = p.headSha, l != h, let c = URL(string: u.absoluteString + "/compare/\(l)...\(h)") {
                out.append((L("What waits, on GitHub", "Was wartet, auf GitHub"), c))
            }
            if (p.openPRs ?? 0) > 0, let c = URL(string: u.absoluteString + "/pulls") {
                out.append((L("Open pull requests on GitHub", "Offene Pull Requests auf GitHub"), c))
            }
        }
        return out
    }
}

/// The last deploys of one project: state, time, commit; a built one can go live again.
struct DeployHistoryView: View {
    @ObservedObject var store: PhoneStore
    let project: PhoneProject
    @State private var records: [DeployRecord]?
    @State private var again: DeployRecord?
    /// The list could not be read: that is not "no deploys yet".
    @State private var loadFailed = false

    var body: some View {
        List {
            if let records {
                if records.isEmpty && loadFailed {
                    VStack(alignment: .leading, spacing: 8) {
                        Text(L("The history could not be loaded.", "Der Verlauf konnte nicht geladen werden.")).foregroundStyle(.secondary)
                        Button(L("Try again", "Noch einmal versuchen")) { Task { await load() } }
                    }
                } else if records.isEmpty { Text(L("No deploys yet.", "Noch keine Deploys.")).foregroundStyle(.secondary) }
                else if loadFailed {
                    // The refresh failed: what is shown is the last read, and the list says so.
                    Label(L("Could not refresh. This is the last state read.", "Konnte nicht aktualisieren. Das ist der zuletzt gelesene Stand."),
                          systemImage: "exclamationmark.triangle").font(.footnote).foregroundStyle(Color.warningText)
                }
                ForEach(records) { r in
                    NavigationLink { BuildLogView(store: store, project: project, record: r) } label: { row(r) }
                        .swipeActions {
                            if r.reusable {
                                Button(L("Live again", "Wieder live")) { again = r }.tint(.orange)
                            }
                        }
                        .contextMenu {
                            if r.reusable { Button(L("Make live again …", "Wieder live schalten …"), systemImage: "arrow.uturn.backward") { again = r } }
                        }
                }
            } else { HStack { Spacer(); ProgressView().accessibilityLabel(L("Loading history", "Verlauf wird geladen")); Spacer() } }
        }
        .navigationTitle(L("History", "Verlauf"))
        .task { await load() }
        .refreshable { await load() }
        .confirmationDialog(L("Make this deploy live again?", "Diesen Deploy wieder live schalten?"),
                            isPresented: Binding(get: { again != nil }, set: { if !$0 { again = nil } }), titleVisibility: .visible,
                            presenting: again) { r in
            Button(L("Make live again", "Wieder live schalten"), role: .destructive) {
                Task { await store.rollback(project, to: r.target) }
            }
            Button(L("Cancel", "Abbrechen"), role: .cancel) {}
        } message: { r in
            Text((r.title.map { L("\"\($0)\"", "„\($0)“") } ?? L("This deploy", "Dieser Deploy"))
                 + L(" goes live again. Asks for \(store.unlockName).", " geht wieder live. Fragt nach \(store.unlockName)."))
        }
    }

    /// A failed read keeps what is shown (refresh) and says so (first load) instead of an empty list.
    private func load() async {
        if let r = await store.history(project) { records = r; loadFailed = false }
        else { loadFailed = true; if records == nil { records = [] } }
    }

    private func row(_ r: DeployRecord) -> some View {
        VStack(alignment: .leading, spacing: 2) {
            HStack {
                Text(PhoneProject.stateWord(r.state)).foregroundStyle(r.failed ? .red : r.current ? .green : .secondary)
                if r.current { Text(L("live now", "jetzt live")).font(.caption).foregroundStyle(.green) }
                Spacer()
                if let a = r.at { Text(relative(a)).font(.caption).foregroundStyle(.secondary) }
            }
            HStack(spacing: 6) {
                if let s = r.sha { Text(s.prefix(7)).monospaced().font(.caption) }
                if let t = r.title { Text(t).font(.caption).lineLimit(1) }
            }.foregroundStyle(.secondary)
        }
        .accessibilityElement(children: .combine)
    }
}

/// Build output around the first error, with secrets masked. Copy takes the whole masked log.
struct BuildLogView: View {
    @ObservedObject var store: PhoneStore
    let project: PhoneProject
    let record: DeployRecord?
    @State private var log: BuildLog?
    @State private var copied = false
    /// Filters the lines shown (the copied and shared text stays the whole masked log).
    @State private var find = ""

    private func load() async { log = nil; log = await store.buildLog(project, record) }

    var body: some View {
        Group {
            if let log {
                if let problem = log.problem {
                    ContentUnavailableView {
                        Label(L("No log", "Kein Log"), systemImage: "doc.text.magnifyingglass")
                    } description: { Text(problem) } actions: {
                        // A log that is not there yet (a deploy that just started) or a failed read: ask again (IDEEN-12 C50).
                        Button(L("Try again", "Erneut versuchen")) { Task { await load() } }
                    }
                } else {
                    ScrollView {
                        LazyVStack(alignment: .leading, spacing: 1) {
                            ForEach(Array(log.lines.enumerated()), id: \.offset) { i, l in
                                if find.isEmpty || l.localizedCaseInsensitiveContains(find) {
                                    Text(l.isEmpty ? " " : l).font(.caption.monospaced())
                                        .foregroundStyle(i == log.errorAt ? .red : .primary)
                                        .fontWeight(i == log.errorAt ? .bold : .regular)
                                        // Colour is no information for VoiceOver: the first error line says so (IDEEN-12 C45).
                                        .accessibilityLabel(i == log.errorAt ? L("Error: ", "Fehler: ") + l : l)
                                        .accessibilityAddTraits(i == log.errorAt ? .isHeader : [])
                                }
                            }
                        }
                        .textSelection(.enabled)
                        .frame(maxWidth: .infinity, alignment: .leading)
                        .padding()
                    }
                    .refreshable { await load() }
                    .searchable(text: $find, prompt: L("Find in the log", "Im Log suchen"))
                    .safeAreaInset(edge: .bottom) {
                        Text(log.errorAt != nil ? L("From shortly before the first error line. Secrets are masked as well as known, check before sharing.",
                                                    "Ab kurz vor der ersten Fehlerzeile. Geheimnisse sind nach bestem Wissen maskiert, vor dem Teilen prüfen.")
                                                  : L("The last lines. Secrets are masked as well as known, check before sharing.",
                                                      "Die letzten Zeilen. Geheimnisse sind nach bestem Wissen maskiert, vor dem Teilen prüfen."))
                            .font(.footnote).foregroundStyle(.secondary).padding(8).frame(maxWidth: .infinity).background(.bar)
                    }
                }
            } else { ProgressView().accessibilityLabel(L("Loading log", "Log wird geladen")) }
        }
        .navigationTitle(L("Build log", "Build-Log"))
        .navigationBarTitleDisplayMode(.inline)
        .toolbar {
            if let full = log?.full, !full.isEmpty {
                Button {
                    // Only on this device, gone after ten minutes: a log is no thing for Universal Clipboard.
                    UIPasteboard.general.setItems([[UTType.plainText.identifier: full]],
                                                  options: [.localOnly: true, .expirationDate: Date().addingTimeInterval(600)])
                    copied = true
                } label: { Label(copied ? L("Copied", "Kopiert") : L("Copy", "Kopieren"), systemImage: copied ? "checkmark" : "doc.on.doc") }
                // The masked text only, like Copy (IDEEN-12 C50).
                ShareLink(item: full) { Image(systemName: "square.and.arrow.up") }
                    .accessibilityLabel(L("Share the masked log", "Maskiertes Log teilen"))
            }
        }
        // "Copied" is said once and goes back to "Copy" (IDEEN-12 C44).
        .task(id: copied) {
            guard copied else { return }
            AccessibilityNotification.Announcement(L("Copied", "Kopiert")).post()
            try? await Task.sleep(for: .seconds(3))
            copied = false
        }
        .task { await load() }
    }
}

extension PhoneStore {
    /// The state as text, for a chat or a ticket.
    var shareText: String {
        var lines = [L("Deploy Center: \(plural(waitingPRs, ("PR", "PR"), ("PRs", "PRs"))) waiting in \(plural(waiting.count, ("project", "Projekt"), ("projects", "Projekten")))",
                       "Deploy Center: \(plural(waitingPRs, ("PR", "PR"), ("PRs", "PRs"))) warten in \(plural(waiting.count, ("project", "Projekt"), ("projects", "Projekten")))")]
        for p in projects where p.group != .live { lines.append("• \(p.name) (\(p.provider.rawValue)): \(p.stateText)") }
        if demo { lines.append(L("(demo data)", "(Demodaten)")) }
        return lines.joined(separator: "\n")
    }
}

/// A commit, short, selectable, with "Copy" in its context menu.
struct ShaRow: View {
    let label: String
    let sha: String
    var body: some View {
        LabeledContent(label) {
            Text(String(sha.prefix(7))).font(.body.monospaced()).textSelection(.enabled)
        }
        .contextMenu {
            Button { UIPasteboard.general.string = sha } label: { Label(L("Copy", "Kopieren"), systemImage: "doc.on.doc") }
        }
        .accessibilityAction(named: L("Copy", "Kopieren")) { UIPasteboard.general.string = sha }
    }
}

struct SettingsView: View {
    @ObservedObject var store: PhoneStore
    @Environment(\.dismiss) private var dismiss
    @Environment(\.openURL) private var openURL
    typealias Key = PhoneStore.TokenKey
    @State private var fields: [Key: String] = [:]
    @State private var saved: [Key: String] = [:]
    @AppStorage("notify") private var notify = false
    @AppStorage("lockOnOpen") private var lockOnOpen = false
    @AppStorage("biometricsOnly") private var biometricsOnly = false
    @AppStorage("noSpotlight") private var noSpotlight = false
    @State private var connect = false
    @State private var notesDenied = false
    @State private var testResults: [String] = []
    @State private var saveFailed = false
    @State private var badKey: String?
    @State private var confirmRemove = false
    @State private var confirmDemo = false
    @State private var githubScopes: [String]?
    @State private var testing = false

    /// Typed but not saved: swiping the sheet away must not throw it away silently.
    private var dirty: Bool { Key.allCases.contains { (fields[$0] ?? "") != (saved[$0] ?? "") } }
    /// Scopes that can change repos: more than the phone needs (it only reads GitHub).
    private var writeScopes: [String] { (githubScopes ?? []).filter { ["repo", "workflow", "write:packages", "delete_repo", "admin:org"].contains($0) } }

    private func field(_ k: Key) -> Binding<String> { Binding(get: { fields[k] ?? "" }, set: { fields[k] = $0 }) }
    /// The placeholder says when the Mac's key is in use for an empty field.
    private func prompt(_ k: Key, _ en: String, _ de: String) -> String {
        store.linkedToken(k) != nil && (fields[k] ?? "").isEmpty ? L(en, de) + L(" (from the Mac)", " (vom Mac)") : L(en, de)
    }

    var body: some View {
        NavigationStack {
            Form {
                // The toast lies under this sheet: an error is shown here as text, not only said to VoiceOver (IDEEN-12 C11).
                if let m = store.message, store.messageIsError {
                    Section {
                        Label(m, systemImage: "exclamationmark.triangle.fill").foregroundStyle(.red)
                        Button(L("Dismiss", "Ausblenden")) { store.message = nil }
                    }
                }
                Section {
                    if store.linked != nil && !store.ignoreLink {
                        Label(L("Connected to the Mac (iCloud Keychain)", "Mit dem Mac verbunden (iCloud-Schlüsselbund)"), systemImage: "checkmark.circle.fill")
                            .foregroundStyle(.green)
                    }
                    Button(store.linked == nil || store.ignoreLink ? L("Connect to the Mac …", "Mit dem Mac verbinden …") : L("Connection details …", "Verbindung …")) { connect = true }
                } header: { Text("Mac") } footer: {
                    Text(L("Keys from the Mac are used when a field below is empty. A key typed here wins.",
                           "Schlüssel vom Mac gelten, wenn ein Feld unten leer ist. Ein hier eingetragener Schlüssel hat Vorrang."))
                }
                Section {
                    // No password content type: iOS would offer to save the tokens in iCloud Passwords, against "never synced".
                    SecureField(prompt(.vercel, "Vercel token", "Vercel-Token"), text: field(.vercel)).textContentType(nil).privacySensitive()
                    TextField(prompt(.vercelTeam, "Vercel team id (optional)", "Vercel-Team-ID (optional)"), text: field(.vercelTeam))
                        .textInputAutocapitalization(.never).autocorrectionDisabled()
                    SecureField(prompt(.render, "Render API key", "Render-API-Key"), text: field(.render)).textContentType(nil).privacySensitive()
                    SecureField(prompt(.github, "GitHub token (optional, for private repos)", "GitHub-Token (optional, für private Repos)"), text: field(.github))
                        .textContentType(nil).privacySensitive()
                    if !writeScopes.isEmpty {
                        Label(L("This GitHub token can also write (\(writeScopes.joined(separator: ", "))). The phone only reads: a fine-grained token with read-only access to contents and pull requests is enough.",
                                "Dieses GitHub-Token darf auch schreiben (\(writeScopes.joined(separator: ", "))). Das iPhone liest nur: Ein fein granulares Token mit Nur-Lese-Zugriff auf Inhalte und Pull Requests genügt."),
                              systemImage: "exclamationmark.shield").font(.footnote).foregroundStyle(Color.warningText)
                    }
                    Button { Task { await test() } } label: {
                        HStack { Text(L("Test the keys", "Schlüssel testen")); if testing { Spacer(); ProgressView() } }
                    }
                    .disabled(testing)
                    ForEach(testResults, id: \.self) { Text($0).font(.footnote) }
                } header: { Text(L("Accounts", "Konten")) } footer: {
                    Text(L("Keys typed here stay in this device's keychain, never synced. Sent only to api.vercel.com, api.render.com and api.github.com. Use the smallest scope and a short lifetime: a Vercel token for one team that expires, a read-only GitHub token.",
                           "Hier eingetragene Schlüssel bleiben im Schlüsselbund dieses Geräts, nie synchronisiert. Gesendet nur an api.vercel.com, api.render.com und api.github.com. Nimm den kleinsten Bereich und eine kurze Laufzeit: ein Vercel-Token für ein Team, das abläuft, ein Nur-Lese-GitHub-Token."))
                }
                Section {
                    Toggle(L("Unlock on open", "Beim Öffnen entsperren"), isOn: guarded($lockOnOpen, L("Turn off the lock", "Sperre ausschalten")))
                        .onChange(of: lockOnOpen) { _, _ in
                            Spotlight.index(store.projects, demo: store.demo); QuickActions.update(store.projects)
                        }
                    Toggle(L("Face ID or Touch ID only (no passcode) to deploy", "Zum Deployen nur Face ID oder Touch ID (kein Code)"), isOn: guarded($biometricsOnly, L("Allow the passcode to deploy", "Code zum Deployen erlauben")))
                    Toggle(L("Keep projects out of Spotlight", "Projekte nicht in Spotlight zeigen"), isOn: $noSpotlight)
                        .onChange(of: noSpotlight) { _, _ in Spotlight.index(store.projects, demo: store.demo) }
                } footer: {
                    Text(L("Asks for \(store.unlockName) when Deploy Center opens, and hides the list in the app switcher.",
                           "Fragt beim Öffnen nach \(store.unlockName) und verdeckt die Liste im App-Umschalter."))
                }
                Section {
                    // Turning it on replaces the real list with made-up projects: with keys in place, ask first.
                    Toggle(L("Demo mode (made-up projects)", "Demo-Modus (erfundene Projekte)"),
                           isOn: Binding(get: { store.demo }, set: { on in
                               if on && store.hasAccount { confirmDemo = true } else { store.demo = on }
                           }))
                    Toggle(L("Notify when something waits or fails", "Melden, wenn etwas wartet oder fehlschlägt"), isOn: $notify)
                        .onChange(of: notify) { _, on in
                            // Switched back off when iOS says no; the system settings can change that later.
                            Task {
                                if on, !(await Background.requestPermission()) {
                                    notify = false
                                    store.fail(L("Notifications are off for Deploy Center in the iOS Settings.",
                                                 "Mitteilungen sind für Deploy Center in den iOS-Einstellungen aus."))
                                }
                                await checkNotes(); await store.updateBadge(); Background.schedule()
                            }
                        }
                    if notesDenied {
                        Button(L("Notifications are off for Deploy Center. Open Settings …", "Mitteilungen sind für Deploy Center aus. Einstellungen öffnen …")) {
                            openSettings()
                        }
                    }
                } footer: {
                    VStack(alignment: .leading, spacing: 4) {
                        Text(L("Checks run in the background only when iOS allows it, which can be rarely or, in Low Power Mode, not at all. There is no server, so a note can come late or not at all.",
                               "Geprüft wird im Hintergrund nur, wenn iOS es erlaubt: manchmal selten, im Stromsparmodus gar nicht. Es gibt keinen Server, ein Hinweis kann also spät oder gar nicht kommen."))
                        if notify, let e = backgroundProblem { Text(e).foregroundStyle(Color.warningText) }
                        if notify {
                            // The last time iOS let the background check run (IDEEN-12 C19).
                            if let at = Background.lastRun {
                                Text(L("Last background check: ", "Letzte Prüfung im Hintergrund: ") + relative(at))
                            } else {
                                Text(L("No background check has run yet.", "Im Hintergrund wurde noch nichts geprüft."))
                            }
                        }
                    }
                }
                Section {
                    Button(L("Language …", "Sprache …")) { openSettings() }
                } footer: {
                    Text(L("The app follows your iPhone's language. To pick another one for this app only: Settings → Deploy Center → Language.",
                           "Die App folgt der Sprache deines iPhones. Eine andere nur für diese App: Einstellungen → Deploy Center → Sprache."))
                }
                Section {
                    Button(L("Remove all keys from this iPhone …", "Alle Schlüssel von diesem iPhone entfernen …"), role: .destructive) {
                        confirmRemove = true
                    }
                } footer: {
                    Text(L("Deletes the keys typed or scanned here and stops using the Mac's keys on this iPhone. The Mac keeps its keys.",
                           "Löscht die hier eingetragenen oder gescannten Schlüssel und nutzt die Schlüssel vom Mac auf diesem iPhone nicht mehr. Der Mac behält seine."))
                }
                Section {
                    Link(L("Privacy policy", "Datenschutz"), destination: URL(string: "https://deploycenter.app/datenschutz.html")!)
                    Link(L("Website and help", "Website und Hilfe"), destination: URL(string: "https://deploycenter.app")!)
                    LabeledContent(L("Version", "Version"), value: store.versionText)
                    // The report holds the version, the system and what is connected, never a key or a project name (IDEEN-12 C55).
                    if let u = store.reportURL { Link(L("Report a problem …", "Fehler melden …"), destination: u) }
                } footer: {
                    Text(L("Deploy Center is not affiliated with Vercel, Render or GitHub.",
                           "Deploy Center ist nicht mit Vercel, Render oder GitHub verbunden."))
                }
            }
            .navigationTitle(L("Settings", "Einstellungen"))
            .toolbar {
                ToolbarItem(placement: .confirmationAction) {
                    Button(L("Done", "Fertig")) { if save() { dismiss() } }
                }
                if dirty {
                    ToolbarItem(placement: .cancellationAction) { Button(L("Cancel", "Abbrechen")) { dismiss() } }
                }
            }
            // Swiping the sheet down would drop typed keys without a word.
            .interactiveDismissDisabled(dirty)
            .alert(L("This key looks wrong", "Dieser Schlüssel sieht falsch aus"), isPresented: Binding(get: { badKey != nil }, set: { if !$0 { badKey = nil } })) {
                Button("OK", role: .cancel) {}
            } message: { Text(badKey ?? "") }
            .alert(L("Could not save every key", "Konnte nicht jeden Schlüssel sichern"), isPresented: $saveFailed) {
                Button("OK", role: .cancel) {}
            } message: {
                Text(L("The device's keychain refused it. The keys that were there before are kept.",
                       "Der Schlüsselbund des Geräts hat abgelehnt. Die vorherigen Schlüssel bleiben erhalten."))
            }
            .onAppear(perform: loadFields)
            .task { await checkNotes() }
            .task(id: store.token(.github)) { githubScopes = await GitHub(token: store.token(.github)).scopes() }
            // A QR code scanned from here writes the keychain: read it again, or "Done" would save the old fields over it.
            .sheet(isPresented: $connect, onDismiss: loadFields) { ConnectMacView(store: store) }
            .confirmationDialog(L("Switch to demo data?", "Zu Demodaten wechseln?"), isPresented: $confirmDemo, titleVisibility: .visible) {
                Button(L("Show demo projects", "Demo-Projekte zeigen")) { store.demo = true }
                Button(L("Cancel", "Abbrechen"), role: .cancel) {}
            } message: {
                Text(L("The list shows made-up projects until you switch it off. Your keys stay.",
                       "Die Liste zeigt erfundene Projekte, bis du es ausschaltest. Deine Schlüssel bleiben."))
            }
            .confirmationDialog(L("Remove all keys from this iPhone?", "Alle Schlüssel von diesem iPhone entfernen?"),
                                isPresented: $confirmRemove, titleVisibility: .visible) {
                Button(L("Remove", "Entfernen"), role: .destructive) {
                    // With the lock or Face ID on, whoever holds an unlocked phone must not strip the protection or the keys (IDEEN-12 C38).
                    Task {
                        var allowed = !(lockOnOpen || biometricsOnly)
                        if !allowed { allowed = await store.authenticate(L("Remove all keys from this iPhone", "Alle Schlüssel von diesem iPhone entfernen")) }
                        if allowed { store.removeAllKeys(); loadFields() }
                    }
                }
                Button(L("Cancel", "Abbrechen"), role: .cancel) {}
            }
        }
    }

    /// A switch that protects: turning it ON is free, turning it OFF asks for Face ID, Touch ID or the code first.
    private func guarded(_ b: Binding<Bool>, _ reason: String) -> Binding<Bool> {
        Binding(get: { b.wrappedValue }, set: { on in
            if on { b.wrappedValue = true; return }
            Task { if await store.authenticate(reason) { b.wrappedValue = false } }
        })
    }

    private func loadFields() {
        var f: [Key: String] = [:]
        for k in Key.allCases { f[k] = store.ownToken(k) ?? "" }
        fields = f; saved = f
    }

    private var backgroundProblem: String? {
        if UIApplication.shared.backgroundRefreshStatus != .available || ProcessInfo.processInfo.isLowPowerModeEnabled {
            return L("Background App Refresh is off for Deploy Center or Low Power Mode is on: no checks run in the background.",
                     "Hintergrundaktualisierung ist für Deploy Center aus oder der Stromsparmodus ist an: im Hintergrund wird nichts geprüft.")
        }
        return Background.scheduleError
    }

    private func checkNotes() async {
        notesDenied = await UNUserNotificationCenter.current().notificationSettings().authorizationStatus == .denied
    }

    private func openSettings() {
        if let u = URL(string: UIApplication.openSettingsURLString) { openURL(u) }
    }

    /// A cheap read per key (the typed one, else the Mac's): who it belongs to, or why it fails.
    private func test() async {
        testing = true; defer { testing = false }
        testResults = []
        func pick(_ k: Key) -> String? {
            let typed = (fields[k] ?? "").trimmingCharacters(in: .whitespacesAndNewlines)
            return typed.isEmpty ? store.linkedToken(k) : typed
        }
        let v = pick(.vercel), t = pick(.vercelTeam), r = pick(.render), g = pick(.github)
        if let v {
            testResults.append("Vercel: " + (await result {
                // No team typed: the one team the token sees, as the list does; with several, say so.
                var team = t, note = ""
                if team == nil {
                    let r = try await Vercel.resolveTeam(token: v)
                    team = r.id
                    if r.teams > 1 { note = L(" · personal account (\(r.teams) teams: enter a team id)", " · persönliches Konto (\(r.teams) Teams: Team-ID eintragen)") }
                }
                return try await Vercel(token: v, team: team).whoami() + note
            }))
        }
        if let r { testResults.append("Render: " + (await result { try await Render(key: r).whoami() })) }
        if let g { testResults.append("GitHub: " + (await result { try await GitHub(token: g).whoami() })) }
        if testResults.isEmpty { testResults = [L("No key to test.", "Kein Schlüssel zum Testen.")] }
        AccessibilityNotification.Announcement(testResults.joined(separator: ". ")).post()
    }
    private func result(_ f: () async throws -> String) async -> String {
        do { return try await f() } catch { return explain(error) }
    }

    private func save() -> Bool {
        guard dirty else { return true }
        for k in Key.allCases where (fields[k] ?? "") != (saved[k] ?? "") && k != .vercelTeam {
            if let why = TokenShape.problem(fields[k] ?? "", render: k == .render) { badKey = why; return false }
        }
        // Only what was changed: a key that could not be read (locked keychain) shows as an empty field,
        // and writing that field back would delete it.
        let ok = Key.allCases.filter { (fields[$0] ?? "") != (saved[$0] ?? "") }
            .map { store.setOwnToken($0, fields[$0] ?? "") }.allSatisfy { $0 }
        Background.schedule()
        Task { await store.reload() }
        if !ok { saveFailed = true; return false }
        // A token pasted into a field must not wait on the clipboard (Universal Clipboard, clipboard managers) (IDEEN-12 C39).
        if let c = UIPasteboard.general.string, !c.isEmpty, Key.allCases.contains(where: { fields[$0] == c }) { UIPasteboard.general.items = [] }
        saved = fields
        return true
    }
}


extension Color {
    /// Orange for small text: the system orange is about 2.3:1 on white; this one reaches 4.5:1 in light mode and is the system orange in dark mode.
    static let warningText = Color(UIColor { $0.userInterfaceStyle == .dark ? .systemOrange : UIColor(red: 0.62, green: 0.30, blue: 0, alpha: 1) })
}
