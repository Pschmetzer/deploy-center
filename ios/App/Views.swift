// Deploy Center for iPhone and iPad — List, details, settings. System fonts and colours only:
// Dynamic Type, dark mode and VoiceOver come with them.

import CoreSpotlight
import SwiftUI
import UniformTypeIdentifiers
import UserNotifications

struct RootView: View {
    @ObservedObject var store: PhoneStore
    @StateObject private var asks = Asks()
    @Environment(\.scenePhase) private var phase
    @Environment(\.horizontalSizeClass) private var sizeClass
    /// Per window: with Stage Manager two windows can show two projects.
    @SceneStorage("selection") private var selection: String?
    @State private var settings = false
    @State private var connect = false
    @State private var recent = false
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
                    Button { recent = true } label: { Image(systemName: "clock.arrow.circlepath") }
                        .accessibilityLabel(L("Recent deploys", "Letzte Deploys"))
                        .accessibilityInputLabels([L("Recent deploys", "Letzte Deploys"), L("Timeline", "Zeitleiste")])
                }
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
        .sheet(isPresented: $recent) { RecentDeploysView(store: store) }
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
        .onChange(of: store.locked) { _, on in if on { settings = false; connect = false; recent = false } }
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
