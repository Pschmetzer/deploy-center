// Deploy Center for iPhone and iPad — List, details, settings. System fonts and colours only:
// Dynamic Type, dark mode and VoiceOver come with them.

import SwiftUI

/// The questions before a deploy or a rollback, asked in one place for the list, the details,
/// VoiceOver actions, the context menu and the keyboard.
@MainActor
final class Asks: ObservableObject {
    @Published var deploy: PhoneProject?
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
    func canDeploy(_ p: PhoneProject, _ store: PhoneStore) -> Bool { p.deployable && !p.building && store.running[p.key] == nil }
    func canRollBack(_ p: PhoneProject, _ store: PhoneStore) -> Bool {
        finding == nil && !p.paused && !p.building && store.running[p.key] == nil
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

    private var selected: PhoneProject? { selection.flatMap { key in store.projects.first { $0.key == key } } }

    var body: some View {
        NavigationSplitView {
            Group {
                if !store.demo && !store.hasAccount { Welcome(store: store, settings: $settings, connect: $connect) }
                else { ProjectList(store: store, asks: asks, selection: $selection, openSettings: { settings = true }) }
            }
            .navigationTitle("Deploy Center")
            .toolbar {
                ToolbarItem(placement: .topBarTrailing) {
                    Button { settings = true } label: { Image(systemName: "gearshape") }
                        .accessibilityLabel(L("Settings", "Einstellungen"))
                }
            }
        } detail: {
            if let p = selected {
                ProjectDetail(store: store, asks: asks, project: p)
            } else {
                ContentUnavailableView(L("Choose a project", "Wähle ein Projekt"), systemImage: "square.stack.3d.up")
            }
        }
        .focusedSceneValue(\.deployActions, DeployActions(
            reload: { Task { await store.reload() } },
            settings: { settings = true },
            deploy: selected.flatMap { p in asks.canDeploy(p, store) ? { asks.deploy = p } : nil }))
        .deployQuestions(store: store, asks: asks)
        .sensoryFeedback(trigger: store.outcome) { _, _ in store.outcomeOK ? .success : .error }
        .sheet(isPresented: $settings) { SettingsView(store: store) }
        .sheet(isPresented: $connect) { ConnectMacView(store: store) }
        .onChange(of: phase) { _, p in
            guard p == .active, !store.demo else { return }
            store.forgetKeptTokens()
            let had = store.linked
            store.refreshLink()
            // A new link, or data older than five minutes: read again.
            let old = store.loadedAt.map { Date().timeIntervalSince($0) > 5 * 60 } ?? false
            if store.linked != had || old { Task { await store.reload() } }
        }
        .task {
            // The last list at once, then the fresh one.
            store.showLast()
            await store.reload()
            // For screenshots: -open <name> selects a project, -settings shows the settings.
            let args = ProcessInfo.processInfo.arguments
            if let i = args.firstIndex(of: "-open"), i + 1 < args.count {
                selection = store.projects.first { $0.name == args[i + 1] }?.key
            }
            // Wide screens: an empty detail column helps nobody. The window's own choice stays.
            if sizeClass == .regular && selected == nil {
                selection = (store.projects.first { $0.group == .attention } ?? store.projects.first { $0.group == .waiting })?.key
            }
            if args.contains("-settings") { try? await Task.sleep(for: .seconds(1)); settings = true }
        }
        .overlay(alignment: .bottom) {
            if let m = store.message { Toast(store: store, text: m) }
        }
        // App lock (optional) and the cover in the app switcher: nothing of the list shows.
        .overlay {
            if store.locked || (PhoneStore.lockOnOpen && !store.demo && phase != .active) {
                LockCover(store: store)
            }
        }
        .onChange(of: phase) { _, p in if p == .active && store.locked { Task { await store.unlock() } } }
        // Sheets lie above the cover: close them when locking (the settings sheet takes its own QR sheet along).
        .onChange(of: store.locked) { _, on in if on { settings = false; connect = false } }
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
                    Text(L("The newest commit of \(p.branch ?? "the branch") goes live on \(p.provider.rawValue). This can cost build minutes.",
                           "Der neueste Commit von \(p.branch ?? "dem Branch") geht auf \(p.provider.rawValue) live. Das kann Build-Minuten kosten."))
                }
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
        if let m = t.message, !m.isEmpty { what += " “\(m)”" }
        if let d = t.at { what += L(", from ", ", vom ") + d.formatted(Date.FormatStyle(date: .abbreviated, time: .shortened).locale(appLocale)) }
        return L("The previous deploy goes live again: \(what).", "Der vorige Deploy geht wieder live: \(what).")
    }
}

/// A short note at the bottom. VoiceOver hears it; errors (and everything while VoiceOver runs)
/// stay until closed, other notes for a few seconds.
struct Toast: View {
    @ObservedObject var store: PhoneStore
    let text: String
    var body: some View {
        HStack(spacing: 10) {
            if store.messageIsError { Image(systemName: "exclamationmark.triangle.fill").foregroundStyle(.red).accessibilityHidden(true) }
            Text(text).font(.callout)
            Button { store.message = nil } label: { Image(systemName: "xmark.circle.fill").foregroundStyle(.secondary) }
                .buttonStyle(.plain)
                .accessibilityLabel(L("Close message", "Meldung schließen"))
        }
        .padding(.horizontal, 16).padding(.vertical, 10)
        .background(.regularMaterial, in: RoundedRectangle(cornerRadius: 18)).padding(.horizontal, 16).padding(.bottom, 12)
        .accessibilityElement(children: .contain)
        .task(id: text) {
            AccessibilityNotification.Announcement(store.messageIsError ? L("Error: ", "Fehler: ") + text : text).post()
            guard !store.messageIsError, !UIAccessibility.isVoiceOverRunning else { return }
            try? await Task.sleep(for: .seconds(5))
            if store.message == text { store.message = nil }
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
    let openSettings: () -> Void
    @Environment(\.openURL) private var openURL

    var body: some View {
        List(selection: $selection) {
            Section {
                Summary(store: store)
                let auto = store.projects.filter(\.autoDeploy).count
                if auto > 0 {
                    // The point of the app: these build on every push, and every build costs.
                    Label(auto == 1 ? L("1 project builds on every push (auto-deploy on).", "1 Projekt baut bei jedem Push (Auto-Deploy an).")
                                    : L("\(auto) projects build on every push (auto-deploy on).", "\(auto) Projekte bauen bei jedem Push (Auto-Deploy an)."),
                          systemImage: "bolt.fill")
                        .font(.footnote).foregroundStyle(.orange)
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
                    ForEach(store.errors, id: \.self) { Text($0).foregroundStyle(.red) }
                    if store.keyRefused {
                        Button(L("Check the keys in Settings", "Schlüssel in den Einstellungen prüfen"), action: openSettings)
                            .font(.footnote)
                    }
                }
            }
            ForEach(PhoneProject.Group.allCases, id: \.self) { g in
                let rows = store.projects.filter { $0.group == g }
                if !rows.isEmpty {
                    Section(g.title) {
                        ForEach(rows) { p in
                            Row(p: p, running: store.running[p.key]).tag(p.key)
                                .contextMenu { menu(p) }
                                // VoiceOver: the same actions as the detail view, without opening it.
                                .accessibilityAction(named: L("Deploy", "Deployen")) {
                                    if asks.canDeploy(p, store) { asks.deploy = p }
                                }
                                .accessibilityAction(named: L("Roll back", "Zurückrollen")) {
                                    if asks.canRollBack(p, store) { asks.askRollback(p, store) }
                                }
                                .accessibilityAction(named: L("Open domain", "Domain öffnen")) {
                                    if let d = p.domain, let url = URL(string: "https://" + d) { openURL(url) }
                                }
                        }
                    }
                }
            }
        }
        .refreshable { await store.reload() }
        .overlay {
            if store.loading && store.projects.isEmpty { ProgressView() }
            else if store.projects.isEmpty && store.loadedAt != nil && store.errors.isEmpty && !store.offline && !store.demo {
                // Often the wrong team: a token for one team sees none of another's projects.
                ContentUnavailableView {
                    Label(L("No projects", "Keine Projekte"), systemImage: "tray")
                } description: {
                    Text(L("These keys see no projects or services. On Vercel, a team's projects only show with that team's id in Settings.",
                           "Diese Schlüssel sehen keine Projekte oder Dienste. Bei Vercel erscheinen die Projekte eines Teams nur mit dessen Team-ID in den Einstellungen."))
                } actions: {
                    Button(L("Open Settings", "Einstellungen öffnen"), action: openSettings)
                }
            }
        }
    }

    @ViewBuilder private func menu(_ p: PhoneProject) -> some View {
        Button { asks.deploy = p } label: { Label(L("Deploy …", "Deployen …"), systemImage: "paperplane") }
            .disabled(!asks.canDeploy(p, store))
        Button(role: .destructive) { asks.askRollback(p, store) } label: { Label(L("Roll back …", "Zurückrollen …"), systemImage: "arrow.uturn.backward") }
            .disabled(!asks.canRollBack(p, store))
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
}

/// "5 minutes ago" in the app's language.
func relative(_ d: Date) -> String {
    d.formatted(Date.RelativeFormatStyle(presentation: .named, locale: appLocale))
}

struct Summary: View {
    @ObservedObject var store: PhoneStore
    @Environment(\.dynamicTypeSize) private var size
    var body: some View {
        let prs = Stat(value: store.waitingPRs, label: L("PRs waiting", "PRs warten"), tint: .accentColor)
        let projects = Stat(value: store.waiting.count, label: L("projects waiting", "Projekte warten"), tint: .primary)
        let building = Stat(value: store.projects.filter(\.building).count, label: L("building", "bauen"), tint: .blue)
        let failed = Stat(value: store.projects.filter(\.failed).count, label: L("failed", "Fehler"), tint: .red)
        Group {
            // Four in a row get too tight with the largest text sizes: two rows of two then.
            if size.isAccessibilitySize {
                Grid(verticalSpacing: 12) { GridRow { prs; projects }; GridRow { building; failed } }
            } else {
                HStack(spacing: 0) { prs; projects; building; failed }
            }
        }
        .padding(.vertical, 4)
        .accessibilityElement(children: .combine)
    }
}

struct Stat: View {
    let value: Int, label: String, tint: Color
    var body: some View {
        VStack(spacing: 2) {
            Text("\(value)").font(.title2.weight(.bold).monospacedDigit()).foregroundStyle(tint)
            Text(label).font(.caption2).foregroundStyle(.secondary).lineLimit(1).minimumScaleFactor(0.7)
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
        if failed { return L("failed", "fehlgeschlagen") }
        // Before `changed`: after a force push the compare fails and the count is unknown, not 0.
        if rewritten && changed { return L("history rewritten · count unknown", "Verlauf neu geschrieben · Anzahl unbekannt") }
        if changed {
            let pr = pendingPRs ?? 0
            let prs = pr == 1 ? L("1 PR · ", "1 PR · ") : pr > 1 ? L("\(pr) PRs · ", "\(pr) PRs · ") : ""
            guard let n = pendingCommits else { return prs + L("waiting, count unknown", "wartet, Anzahl unbekannt") }
            return prs + (n == 1 ? L("1 commit waiting", "1 Commit wartet") : L("\(n) commits waiting", "\(n) Commits warten"))
        }
        if paused { return L("paused", "pausiert") }
        if foreignRepo { return L("only GitHub repos are compared", "nur GitHub-Repos werden verglichen") }
        if rewritten { return L("history rewritten", "Verlauf neu geschrieben") }
        if unknown { return L("state unknown", "Stand unbekannt") }
        return L("up to date", "aktuell")
    }
}

struct Row: View {
    let p: PhoneProject
    let running: String?
    @ScaledMetric(relativeTo: .title3) private var iconWidth = 24.0
    var body: some View {
        HStack(spacing: 12) {
            if running != nil { ProgressView().frame(width: iconWidth) }
            else { Image(systemName: p.icon).foregroundStyle(p.tint).font(.title3).frame(width: iconWidth).accessibilityHidden(true) }
            VStack(alignment: .leading, spacing: 2) {
                Text(p.name).font(.body.weight(.semibold))
                HStack(spacing: 4) {
                    Text((running.map { L("deploying: ", "deployt: ") + PhoneProject.stateName($0) } ?? p.stateText) + " · " + p.provider.rawValue)
                    if p.autoDeploy {
                        Image(systemName: "bolt.fill").foregroundStyle(.orange)
                            .accessibilityLabel(L("auto-deploy on", "Auto-Deploy an"))
                    }
                }
                .font(.caption).foregroundStyle(.secondary)
            }
        }
        .accessibilityElement(children: .combine)
    }
}

struct ProjectDetail: View {
    @ObservedObject var store: PhoneStore
    @ObservedObject var asks: Asks
    let project: PhoneProject

    var body: some View {
        let p = project
        List {
            Section {
                LabeledContent(L("Status", "Status")) {
                    HStack(spacing: 6) { Image(systemName: p.icon).accessibilityHidden(true); Text(p.stateText) }.foregroundStyle(p.tint)
                }
                LabeledContent(L("Platform", "Plattform"), value: p.provider.rawValue)
                LabeledContent(L("Auto-deploy", "Auto-Deploy")) {
                    Text(p.autoDeploy ? L("on", "an") : L("off", "aus")).foregroundStyle(p.autoDeploy ? .orange : .secondary)
                }
                if let r = p.repo { LabeledContent(L("Repository", "Repository"), value: r + (p.branch.map { " · \($0)" } ?? "")) }
                if let d = p.domain { LabeledContent(L("Domain", "Domain"), value: d) }
                if let n = p.openPRs { LabeledContent(L("Open pull requests", "Offene Pull Requests"), value: "\(n)") }
                if let e = p.fetchError {
                    LabeledContent(L("Read error", "Lesefehler")) { Text(e).foregroundStyle(.red) }
                }
                if let d = p.oldestPendingAt, p.changed {
                    TimelineView(.periodic(from: .now, by: 30)) { _ in
                        LabeledContent(L("Waiting since", "Wartet seit"), value: relative(d))
                    }
                }
            } footer: {
                if p.autoDeploy {
                    Text(L("Every push to \(p.branch ?? "the branch") builds and goes live, and each build can cost build minutes.",
                           "Jeder Push auf \(p.branch ?? "den Branch") baut und geht live, und jeder Build kann Build-Minuten kosten."))
                }
            }
            Section(L("Commits", "Commits")) {
                if let m = p.headMsg { LabeledContent(L("Newest", "Neuester"), value: m) }
                if let m = p.liveMsg { LabeledContent(L("Live", "Live"), value: m) }
                // Both commits, so "SHA" is never ambiguous; long press copies the whole one.
                if let s = p.liveSha { ShaRow(label: L("Live commit", "Live-Commit"), sha: s) }
                if let s = p.headSha, s != p.liveSha { ShaRow(label: L("Newest commit", "Neuester Commit"), sha: s) }
            }
            Section {
                Button {
                    asks.deploy = p
                } label: {
                    Label(p.failed ? L("Deploy again …", "Erneut deployen …") : L("Deploy the newest commit …", "Neuesten Commit deployen …"),
                          systemImage: "paperplane")
                }
                .disabled(!asks.canDeploy(p, store))
                Button(role: .destructive) {
                    asks.askRollback(p, store)
                } label: {
                    HStack {
                        Label(L("Roll back …", "Zurückrollen …"), systemImage: "arrow.uturn.backward")
                        if asks.finding == p.key { Spacer(); ProgressView() }
                    }
                }
                .disabled(!asks.canRollBack(p, store))
            } footer: {
                let how = store.unlockName
                Text(L("Each deploy and rollback asks for \(how). It goes straight from this device to \(p.provider.rawValue).",
                       "Jeder Deploy und jedes Zurückrollen fragt nach \(how). Es geht direkt von diesem Gerät an \(p.provider.rawValue)."))
            }
        }
        .navigationTitle(p.name)
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
    typealias Key = PhoneStore.TokenKey
    @State private var fields: [Key: String] = [:]
    @State private var saved: [Key: String] = [:]
    @AppStorage("notify") private var notify = false
    @AppStorage("lockOnOpen") private var lockOnOpen = false
    @State private var connect = false
    @State private var confirmRemove = false
    @State private var saveFailed = false
    @State private var githubScopes: [String]?
    @State private var testing = false
    @State private var testResult: [(ok: Bool, text: String)] = []

    /// Typed but not saved: swiping the sheet away must not throw it away silently.
    private var dirty: Bool { Key.allCases.contains { (fields[$0] ?? "") != (saved[$0] ?? "") } }
    /// Scopes that can change repos: more than the phone needs (it only reads GitHub).
    private var writeScopes: [String] { (githubScopes ?? []).filter { ["repo", "workflow", "write:packages", "delete_repo", "admin:org"].contains($0) } }

    private func field(_ k: Key) -> Binding<String> { Binding(get: { fields[k] ?? "" }, set: { fields[k] = $0 }) }
    /// The placeholder says when the Mac's key is in use for an empty field.
    private func prompt(_ k: Key, _ en: String, _ de: String) -> String {
        store.linkedToken(k) != nil && (fields[k] ?? "").isEmpty ? L("\(en) (from the Mac)", "\(de) (vom Mac)") : L(en, de)
    }
    /// iOS checks in the background only with Background App Refresh on and Low Power Mode off.
    private var backgroundBlocked: Bool {
        UIApplication.shared.backgroundRefreshStatus != .available || ProcessInfo.processInfo.isLowPowerModeEnabled
    }

    var body: some View {
        NavigationStack {
            Form {
                Section {
                    if store.linked != nil {
                        Label(L("Connected to the Mac (iCloud Keychain)", "Mit dem Mac verbunden (iCloud-Schlüsselbund)"), systemImage: "checkmark.circle.fill")
                            .foregroundStyle(.green)
                    }
                    Button(store.linked == nil ? L("Connect to the Mac …", "Mit dem Mac verbinden …") : L("Connection details …", "Verbindung …")) { connect = true }
                } header: { Text("Mac") } footer: {
                    Text(L("Keys from the Mac are used when a field below is empty. A key typed here wins.",
                           "Schlüssel vom Mac gelten, wenn ein Feld unten leer ist. Ein hier eingetragener Schlüssel hat Vorrang."))
                }
                Section {
                    // No `.password` content type: iOS would offer to save the token to Passwords (iCloud), against "never synced".
                    SecureField(prompt(.vercel, "Vercel token", "Vercel-Token"), text: field(.vercel)).privacySensitive()
                    TextField(prompt(.vercelTeam, "Vercel team id (optional)", "Vercel-Team-ID (optional)"), text: field(.vercelTeam))
                        .textInputAutocapitalization(.never).autocorrectionDisabled()
                    SecureField(prompt(.render, "Render API key", "Render-API-Key"), text: field(.render)).privacySensitive()
                    SecureField(prompt(.github, "GitHub token (optional, for private repos)", "GitHub-Token (optional, für private Repos)"), text: field(.github))
                        .privacySensitive()
                    if !writeScopes.isEmpty {
                        Label(L("This GitHub token can also write (\(writeScopes.joined(separator: ", "))). The phone only reads: a fine-grained token with read-only access to contents and pull requests is enough.",
                                "Dieses GitHub-Token darf auch schreiben (\(writeScopes.joined(separator: ", "))). Das iPhone liest nur: Ein fein granulares Token mit Nur-Lese-Zugriff auf Inhalte und Pull Requests genügt."),
                              systemImage: "exclamationmark.shield").font(.footnote).foregroundStyle(.orange)
                    }
                    Button {
                        testing = true; testResult = []
                        Task {
                            testResult = await store.testConnection(vercel: fields[.vercel] ?? "", team: fields[.vercelTeam] ?? "",
                                                                    render: fields[.render] ?? "", github: fields[.github] ?? "")
                            testing = false
                        }
                    } label: {
                        HStack { Text(L("Test connection", "Verbindung testen")); if testing { Spacer(); ProgressView() } }
                    }
                    .disabled(testing)
                    ForEach(Array(testResult.enumerated()), id: \.offset) { _, r in
                        Label(r.text, systemImage: r.ok ? "checkmark.circle.fill" : "xmark.octagon.fill")
                            .font(.footnote).foregroundStyle(r.ok ? Color.green : Color.red)
                    }
                } header: { Text(L("Accounts", "Konten")) } footer: {
                    Text(L("Keys typed here stay in this device's keychain, never synced. Sent only to api.vercel.com, api.render.com and api.github.com.",
                           "Hier eingetragene Schlüssel bleiben im Schlüsselbund dieses Geräts, nie synchronisiert. Gesendet nur an api.vercel.com, api.render.com und api.github.com."))
                }
                Section {
                    Toggle(L("Unlock on open", "Beim Öffnen entsperren"), isOn: $lockOnOpen)
                } footer: {
                    Text(L("Asks for \(store.unlockName) when Deploy Center opens, and hides the list in the app switcher.",
                           "Fragt beim Öffnen nach \(store.unlockName) und verdeckt die Liste im App-Umschalter."))
                }
                Section {
                    Toggle(L("Demo mode (made-up projects)", "Demo-Modus (erfundene Projekte)"), isOn: $store.demo)
                    Toggle(L("Notify when something waits or fails", "Melden, wenn etwas wartet oder fehlschlägt"), isOn: $notify)
                        .onChange(of: notify) { _, on in
                            // Switched back off when iOS says no; the system settings can change that later.
                            if on { Task { if !(await Background.requestPermission()) { notify = false
                                store.fail(L("Notifications are off for Deploy Center in the iOS Settings.",
                                             "Mitteilungen sind für Deploy Center in den iOS-Einstellungen aus.")) } } }
                        }
                } footer: {
                    VStack(alignment: .leading, spacing: 4) {
                        Text(L("Checks run in the background when iOS allows it, usually a few times an hour. There is no server, so a note can come late.",
                               "Geprüft wird im Hintergrund, wenn iOS es erlaubt, meist ein paar Mal pro Stunde. Es gibt keinen Server, ein Hinweis kann also später kommen."))
                        if notify && backgroundBlocked {
                            Text(L("Background App Refresh is off for Deploy Center, or Low Power Mode is on: no notes come until that changes (iOS Settings).",
                                   "Hintergrundaktualisierung ist für Deploy Center aus, oder der Stromsparmodus ist an: Bis dahin kommen keine Hinweise (iOS-Einstellungen)."))
                                .foregroundStyle(.orange)
                        }
                    }
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
                    ToolbarItem(placement: .cancellationAction) {
                        Button(L("Cancel", "Abbrechen")) { dismiss() }
                    }
                }
            }
            // Changed fields: swiping down does not throw them away; "Done" saves, "Cancel" discards.
            .interactiveDismissDisabled(dirty)
            .onAppear(perform: loadFields)
            .task(id: store.token(.github)) { githubScopes = await GitHub(token: store.token(.github)).scopes() }
            // A QR code scanned from here writes the keychain: read it again, or "Done" would save the old fields over it.
            .sheet(isPresented: $connect, onDismiss: loadFields) { ConnectMacView(store: store) }
            .alert(L("The keychain did not take the keys.", "Der Schlüsselbund hat die Schlüssel nicht übernommen."), isPresented: $saveFailed) {
                Button("OK", role: .cancel) {}
            } message: {
                Text(L("Nothing was lost: the keys saved before stay. Try again, or restart the device.",
                       "Nichts ging verloren: Die vorher gesicherten Schlüssel bleiben. Erneut versuchen oder das Gerät neu starten."))
            }
            .confirmationDialog(L("Remove all keys from this iPhone?", "Alle Schlüssel von diesem iPhone entfernen?"),
                                isPresented: $confirmRemove, titleVisibility: .visible) {
                Button(L("Remove", "Entfernen"), role: .destructive) {
                    store.removeAllKeys(); loadFields()
                }
                Button(L("Cancel", "Abbrechen"), role: .cancel) {}
            }
        }
    }

    private func loadFields() {
        var f: [Key: String] = [:]
        for k in Key.allCases { f[k] = store.ownToken(k) ?? "" }
        fields = f; saved = f
    }

    /// False when the keychain refused one: the sheet stays open with the fields as typed.
    private func save() -> Bool {
        guard dirty else { return true }
        let ok = Key.allCases.map { store.setOwnToken($0, fields[$0] ?? "") }.allSatisfy { $0 }
        Task { await store.reload() }
        if !ok { saveFailed = true; return false }
        saved = fields
        return true
    }
}
