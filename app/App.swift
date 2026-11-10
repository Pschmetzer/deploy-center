// Deploy Center — turn off auto-deploy on Vercel and Render, then deploy by hand from one window.
// All the work is done by the `deploys` script bundled with the app; the app only calls it.
// Built by build.sh (swiftc over app/*.swift, Swift 5 mode, no Xcode project needed).
// This file: Settings, the app, and the menu bar.

import SwiftUI
import AppKit
import Charts
import UserNotifications
import ServiceManagement
import Combine

// MARK: - Settings (⌘,)

struct SettingsView: View {
    @ObservedObject var store: Store
    @AppStorage("refreshMinutes") private var refreshMinutes = 15
    @State private var language = AppLanguage.chosen
    @AppStorage("maxParallel") private var maxParallel = 3
    @AppStorage("reminderHour") private var reminderHour = 0
    @AppStorage("showMenuBar") private var showMenuBar = true
    @AppStorage("hideDock") private var hideDock = false
    @AppStorage("notifications") private var notifications = true
    @AppStorage("checkUpdates") private var checkUpdates = true
    @ObservedObject private var updates = SoftwareUpdate.shared
    @AppStorage("demoMode") private var demoMode = false
    @AppStorage("loadLogos") private var loadLogos = true
    @AppStorage("undoSeconds") private var undoSeconds = 8
    @AppStorage("staleDays") private var staleDays = 0
    @AppStorage("monthlyBudget") private var monthlyBudget = 0.0
    /// The checkbox of the deploy confirmation, here too, so the remembered state can be seen.
    @AppStorage("onlyWhenGreen") private var onlyWhenGreen = false
    @State private var openAtLogin = SMAppService.mainApp.status == .enabled
    @State private var loginNeedsApproval = SMAppService.mainApp.status == .requiresApproval
    @State private var loginError: String?
    @State private var notificationsDenied = false
    @State private var providerError: String?
    @State private var switching: String?

    private var version: String { Bundle.main.infoDictionary?["CFBundleShortVersionString"] as? String ?? "?" }

    /// The tab on screen, remembered.
    @AppStorage("settingsTab") private var settingsTab = "general"

    /// Six tabs instead of one long roll of fourteen sections.
    var body: some View {
        TabView(selection: $settingsTab) {
            Form {
                generalSection
                notificationsSection
                updatesSection
                hiddenSection
            }
            .formStyle(.grouped)
            .tabItem { Label(L("General", "Allgemein"), systemImage: "gearshape") }.tag("general")

            Form {
                platformsSection
                PhoneLinkSettings()
            }
            .formStyle(.grouped)
            .tabItem { Label(L("Platforms", "Plattformen"), systemImage: "server.rack") }.tag("platforms")

            Form {
                deploySection
                GuardSettings(store: store)
                costsSection
            }
            .formStyle(.grouped)
            .tabItem { Label(L("Deploy & guard", "Deploy & Wächter"), systemImage: "paperplane") }.tag("deploy")

            ScrollViewReader { proxy in Form {
                ClaudeSettings { withAnimation { proxy.scrollTo("autofix", anchor: .top) } }
                ClaudeAISettings().id("claudeAI")
                AutofixSettings(store: store).id("autofix")
            } }
            .formStyle(.grouped)
            .tabItem { Label("Claude", systemImage: "sparkles") }.tag("claude")

            Form { TeamSettings(store: store) }
                .formStyle(.grouped)
                .tabItem { Label(L("Team", "Team"), systemImage: "person.2") }.tag("team")

            Form {
                CommandPaletteSettings()
                helpSection
            }
            .formStyle(.grouped)
            .tabItem { Label(L("Advanced", "Erweitert"), systemImage: "wrench.and.screwdriver") }.tag("advanced")
        }
        .frame(width: 600)
        .frame(minHeight: 460, idealHeight: 620, maxHeight: 820)
        .task {
            // Fresh switches; a script without `deploys providers` was asked at start already.
            if store.providersFromScript { await store.loadProviders() }
            let st = await UNUserNotificationCenter.current().notificationSettings()
            notificationsDenied = notifications && st.authorizationStatus == .denied
        }
        .onChange(of: notifications) { _, on in
            Task {
                let st = await UNUserNotificationCenter.current().notificationSettings()
                notificationsDenied = on && st.authorizationStatus == .denied
            }
        }
    }

    @ViewBuilder private var generalSection: some View {
        Section(L("General", "Allgemein")) {
            Picker(L("Reload the lists every", "Listen neu laden alle"), selection: $refreshMinutes) {
                ForEach([5, 15, 30, 60], id: \.self) { Text(L("\($0) minutes", "\($0) Minuten")).tag($0) }
            }
            Toggle(L("Show in the menu bar", "In der Menüleiste zeigen"), isOn: $showMenuBar)
                // Without the menu bar the Dock icon is the only way back in: it comes back.
                .onChange(of: showMenuBar) { _, on in
                    if !on && hideDock { hideDock = false }
                }
            Toggle(L("No Dock icon (menu bar only)", "Kein Dock-Symbol (nur Menüleiste)"), isOn: $hideDock)
                .disabled(!showMenuBar)
                .onChange(of: hideDock) { _, on in
                    NSApp.setActivationPolicy(on ? .accessory : .regular)
                    if !on { NSApp.activate(ignoringOtherApps: true) }
                }
            Toggle(L("Open at login", "Beim Anmelden öffnen"), isOn: $openAtLogin)
                .onChange(of: openAtLogin) { _, on in
                    do { if on { try SMAppService.mainApp.register() } else { try SMAppService.mainApp.unregister() }; loginError = nil }
                    catch { loginError = error.localizedDescription; openAtLogin = SMAppService.mainApp.status == .enabled }
                    loginNeedsApproval = SMAppService.mainApp.status == .requiresApproval
                }
            if loginNeedsApproval {
                HStack {
                    Text(L("macOS still has to allow this under Login Items.", "macOS muss das unter Anmeldeobjekte noch erlauben."))
                        .font(.caption).foregroundStyle(.secondary)
                    Spacer()
                    Button(L("Open Login Items", "Anmeldeobjekte öffnen")) { SMAppService.openSystemSettingsLoginItems() }
                }
            }
            if let loginError { ErrorText(loginError) }
            Toggle(L("Demo mode (hide project names, for screenshots)", "Demo-Modus (Projektnamen verbergen, für Screenshots)"), isOn: $demoMode)
            Toggle(L("Load logos from the project sites", "Logos von den Projektseiten laden"), isOn: $loadLogos)
                .help(L("Off: no request goes to your sites; a letter stands in for the logo.",
                        "Aus: keine Anfrage geht an deine Seiten; ein Buchstabe ersetzt das Logo."))
            Picker(L("Language", "Sprache") + (isGerman ? " · Language" : " · Sprache"), selection: $language) {
                ForEach(AppLanguage.allCases) { Text($0.title).tag($0) }
            }
            .onChange(of: language) { _, l in l.save() }
            if language.resolved != AppLanguage.running {
                HStack {
                    Text(L("Takes effect after a restart.", "Gilt nach einem Neustart."))
                        .font(.caption).foregroundStyle(.secondary)
                    Spacer()
                    Button(L("Restart now", "Jetzt neu starten")) {
                        // relaunchApp asks itself; the quit check must not ask a second time.
                        AppDelegate.confirmed = true
                        relaunchApp(running: store.items.values.joined().filter { $0.state.isActive }.count)
                        AppDelegate.confirmed = false
                    }
                }
            }
        }
    }

    /// Which platforms the main window shows. Vercel and Render are on; others are switched on here,
    /// once the `deploys` script knows them.
    @ViewBuilder private var platformsSection: some View {
        Section(L("Platforms", "Plattformen")) {
            let on = store.enabledProviders.count
            ForEach(ProviderInfo.settingsRows(store.providers)) { row in
                let info = row.info
                let isOn = row.available && store.enabledProviders.contains { $0.id == info.id }
                Toggle(isOn: Binding(get: { isOn }, set: { want in
                    switching = info.id; providerError = nil
                    Task { providerError = await store.setProvider(info.id, on: want); switching = nil }
                })) {
                    HStack(spacing: 6) {
                        Text(info.label)
                        if !row.available {
                            Text(L("coming soon", "kommt bald")).font(.caption).foregroundStyle(.secondary)
                        } else if switching == info.id {
                            ProgressView().controlSize(.small)
                        }
                    }
                }
                // Switches need `deploys providers`; the last platform that is on stays on.
                .disabled(!row.available || !store.providersFromScript || switching != nil || (isOn && on <= 1))
                .accessibilityHint(row.available ? "" : L("Not available yet", "Noch nicht verfügbar"))
            }
            if !store.providersFromScript {
                Text(L("This version of the deploys script always shows Vercel and Render.",
                       "Diese Version des deploys-Skripts zeigt immer Vercel und Render."))
                    .font(.caption).foregroundStyle(.secondary)
            }
            if let providerError { ErrorText(providerError) }
        }
    }

    @ViewBuilder private var deploySection: some View {
        Section(L("Deploy", "Deploy")) {
            Picker(L("Builds at the same time", "Builds gleichzeitig"), selection: $maxParallel) {
                ForEach([1, 2, 3, 5, 10], id: \.self) { Text("\($0)").tag($0) }
            }
            Picker(L("Wait before a deploy starts", "Warten, bevor ein Deploy startet"), selection: $undoSeconds) {
                Text(L("No wait", "Nicht warten")).tag(0)
                ForEach([5, 8, 15], id: \.self) { Text(L("\($0) seconds (cancel possible)", "\($0) Sekunden (Abbrechen möglich)")).tag($0) }
            }
            Picker(L("Warn when commits wait longer than", "Warnen, wenn Commits länger warten als"), selection: $staleDays) {
                Text(L("Off", "Aus")).tag(0)
                ForEach([2, 3, 5, 7], id: \.self) { Text(L("\($0) days", "\($0) Tage")).tag($0) }
            }
            Toggle(L("Deploy only when the checks are green", "Nur deployen, wenn die Checks grün sind"), isOn: $onlyWhenGreen)
                .help(L("The same switch as in the deploy confirmation: commits whose CI did not pass stay back.",
                        "Derselbe Schalter wie in der Deploy-Rückfrage: Commits, deren CI nicht durchlief, bleiben zurück."))
        }
    }

    @ViewBuilder private var costsSection: some View {
        Section(L("Costs", "Kosten")) {
            HStack {
                Text(L("Monthly build budget (USD, 0 = off)", "Monatliches Build-Budget (USD, 0 = aus)"))
                Spacer()
                TextField(L("Monthly build budget", "Monatliches Build-Budget"), value: $monthlyBudget, format: .number, prompt: Text("0"))
                    .labelsHidden().frame(width: 80).multilineTextAlignment(.trailing)
                    // A budget below zero means nothing; it becomes "off".
                    .onChange(of: monthlyBudget) { _, v in if v < 0 || !v.isFinite { monthlyBudget = 0 } }
            }
            SavingsLink()
        }
    }

    @ViewBuilder private var notificationsSection: some View {
        Section(L("Notifications", "Mitteilungen")) {
            Toggle(L("Notify when a deploy ends", "Mitteilung, wenn ein Deploy fertig ist"), isOn: $notifications)
            Picker(L("Daily reminder to deploy", "Tägliche Erinnerung zum Deployen"), selection: $reminderHour) {
                Text(L("Off", "Aus")).tag(0)
                ForEach(1...23, id: \.self) { Text(L("from \($0):00", "ab \($0):00 Uhr")).tag($0) }
            }
            .onChange(of: reminderHour) { _, h in if h > 0 { Notify.ask() } }
            .help(L("Only a reminder, and only when something waits. Nothing is deployed by itself.",
                    "Nur eine Erinnerung, und nur wenn etwas wartet. Es wird nichts von selbst deployt."))
            if notificationsDenied {
                HStack {
                    Text(L("Notifications are turned off for Deploy Center in System Settings.",
                           "Mitteilungen sind für Deploy Center in den Systemeinstellungen aus."))
                        .font(.caption).foregroundStyle(Color.warningText)
                    Spacer()
                    Button(L("Open System Settings", "Systemeinstellungen öffnen")) {
                        NSWorkspace.shared.open(URL(string: "x-apple.systempreferences:com.apple.Notifications-Settings.extension")!)
                    }
                }
            }
        }
    }

    @ViewBuilder private var updatesSection: some View {
        Section(L("Updates", "Updates")) {
            Toggle(L("Check for updates automatically", "Automatisch nach Updates suchen"), isOn: $checkUpdates)
                .onChange(of: checkUpdates) { _, on in SoftwareUpdate.shared.setAutomatic(on) }
            HStack {
                Button(L("Check now …", "Jetzt suchen …")) { SoftwareUpdate.shared.check() }
                    .disabled(!updates.canCheck)
                Spacer()
                Text(L("You have \(version)", "Du hast \(version)")).font(.caption).foregroundStyle(.secondary)
            }
            Text(L("Updates come from deploycenter.app and GitHub, signed (EdDSA) and notarized; they install when no deploy is running.",
                   "Updates kommen von deploycenter.app und GitHub, signiert (EdDSA) und notarisiert; sie werden installiert, wenn kein Deploy läuft."))
                .font(.caption).foregroundStyle(.secondary)
        }
    }

    @ViewBuilder private var hiddenSection: some View {
        if !store.hidden.isEmpty {
            Section(L("Hidden projects", "Ausgeblendete Projekte")) {
                DisclosureGroup(L("\(store.hidden.count) hidden", "\(store.hidden.count) ausgeblendet")) {
                    ForEach(store.hidden.sorted(), id: \.self) { k in
                        HStack {
                            Text(Demo.mask(hiddenName(k)))
                            Text(hiddenPlatform(k)).font(.caption).foregroundStyle(.secondary)
                            Spacer()
                            Button(L("Show", "Zeigen")) { store.unhide(k) }
                        }
                    }
                }
                Button(L("Show all", "Alle zeigen")) { store.hidden.sorted().forEach { store.unhide($0) } }
            }
        }
    }

    @ViewBuilder private var helpSection: some View {
        Section(L("Help", "Hilfe")) {
            Button(L("Open the error log", "Fehlerprotokoll öffnen")) {
                if !FileManager.default.fileExists(atPath: Log.url.path) { Log.write("log started") }
                NSWorkspace.shared.open(Log.url)
            }
            CopyButton(title: L("Copy diagnostics", "Diagnose kopieren")) {
                let d = store.doctor
                let on = store.enabledProviders
                // Counts and times only: no project names, no error texts (they can hold names).
                let failures = Platform.allCases.compactMap { p in
                    store.lastLoadError[p].map { "\(p.cli) failed \($0.at.formatted(date: .numeric, time: .shortened))" }
                }
                return ["Deploy Center \(version), language \(AppLanguage.running.rawValue)",
                        ProcessInfo.processInfo.operatingSystemVersionString,
                        "jq \(d?.jq ?? false), vercel \(d?.vercelCli ?? false)/api \(d?.vercelApi ?? false)/login \(d?.vercelLoggedIn ?? false)",
                        "gh \(d?.githubCli ?? false)/login \(d?.githubLoggedIn ?? false), render key \(d?.renderKey ?? false), observer \(store.observer)",
                        "perl \(d?.perl.map(String.init) ?? "?"), curl \(d?.curl.map(String.init) ?? "?")",
                        "providers on: " + on.map(\.id).joined(separator: ", "),
                        on.compactMap(\.platform).map { "\($0.cli) \(store.items[$0]?.count ?? 0)" }.joined(separator: ", ") + " projects",
                        "last load error: " + (failures.isEmpty ? "none" : failures.joined(separator: "; "))].joined(separator: "\n")
            }
            Text(L("Diagnostics: versions and what is connected; no names, no keys.", "Diagnose: Versionen und was verbunden ist; keine Namen, keine Schlüssel."))
                .font(.caption).foregroundStyle(.secondary)
            Text(L("Version ", "Version ") + version
                 + L(" · no telemetry; GitHub, Vercel and Render are asked with your own logins", " · keine Telemetrie; GitHub, Vercel und Render werden mit deinen eigenen Anmeldungen gefragt"))
                .font(.caption).foregroundStyle(.secondary)
        }
    }

    /// The name of a hidden project: from the list when it is there (Render keys hold the service id).
    private func hiddenName(_ k: String) -> String {
        if let i = Platform.allCases.flatMap({ store.items[$0] ?? [] }).first(where: { Store.key($0) == k }) { return i.name }
        return String(k.split(separator: "/", maxSplits: 1).last ?? Substring(k))
    }
    private func hiddenPlatform(_ k: String) -> String {
        let cli = String(k.split(separator: "/").first ?? "")
        return Platform.allCases.first { $0.cli == cli }?.rawValue ?? cli
    }
}

private func open(_ s: String) { if let u = URL(string: s) { NSWorkspace.shared.open(u) } }

/// Every way out (⌘Q, the Dock's Quit, the menu bar, logging out) asks first while deploys run,
/// and the Dock badge follows the store even with the window closed.
@MainActor final class AppDelegate: NSObject, NSApplicationDelegate {
    weak var store: Store?
    /// Set once the person already said yes (the restart in Settings asks itself).
    static var confirmed = false
    private var badge: AnyCancellable?

    func attach(_ s: Store) {
        guard store !== s else { return }
        store = s
        // After the change, not before it (objectWillChange fires first).
        badge = s.objectWillChange.receive(on: RunLoop.main).sink { [weak s] _ in
            guard let s else { return }
            let n = s.waiting.projects
            let label = n > 0 ? "\(n)" : nil
            if NSApp.dockTile.badgeLabel != label { NSApp.dockTile.badgeLabel = label }
        }
    }

    private var running: Int { store.map { $0.items.values.joined().filter { $0.state.isActive }.count } ?? 0 }

    /// Asks while deploys run; true when it may go on.
    func confirmLeaving(restart: Bool = false) -> Bool {
        let n = running
        guard n > 0 else { return true }
        NSApp.activate(ignoringOtherApps: true)
        let a = NSAlert()
        a.messageText = L("\(n) \(n == 1 ? "deploy is" : "deploys are") still running", "\(n) \(n == 1 ? "Deploy läuft" : "Deploys laufen") noch")
        a.informativeText = L("Builds that already started go on at Vercel or Render, but Deploy Center stops following them and queued ones do not start.",
                              "Gestartete Builds laufen bei Vercel oder Render weiter, aber Deploy Center verfolgt sie nicht mehr, und wartende starten nicht.")
        a.addButton(withTitle: L("Keep running", "Weiterlaufen lassen"))
        a.addButton(withTitle: restart ? L("Restart anyway", "Trotzdem neu starten") : L("Quit anyway", "Trotzdem beenden"))
        return a.runModal() == .alertSecondButtonReturn
    }

    func applicationShouldTerminate(_ sender: NSApplication) -> NSApplication.TerminateReply {
        if Self.confirmed { return .terminateNow }
        return confirmLeaving() ? .terminateNow : .terminateCancel
    }
}

@main
struct DeployCenterApp: App {
    /// One store for the window and the menu bar, so both show the same counts.
    @StateObject private var store: Store
    @NSApplicationDelegateAdaptor(AppDelegate.self) private var appDelegate
    @ObservedObject private var updates = SoftwareUpdate.shared
    @AppStorage("showMenuBar") private var showMenuBar = true

    init() {
        let store = Store()
        _store = StateObject(wrappedValue: store)
        SoftwareUpdate.shared.isBusy = { [weak store] in store?.deploysBusy ?? false }
        // No menu bar and no Dock icon would leave the app without any way in.
        let d = UserDefaults.standard
        if d.object(forKey: "showMenuBar") as? Bool == false && d.bool(forKey: "hideDock") { d.set(false, forKey: "hideDock") }
    }

    var body: some Scene {
        WindowGroup("Deploy Center", id: "main") {
            ContentView(store: store)
                .modifier(OpensSettingsOnRequest(store: store))
                .task { appDelegate.attach(store); await ClaudeNudge.refresh() }
                // deploycenter://select?project=name shows and ticks a project. It never starts a build:
                // any web page could open such a link.
                .onOpenURL { url in
                    guard url.scheme == "deploycenter",
                          let name = URLComponents(url: url, resolvingAgainstBaseURL: false)?.queryItems?.first(where: { $0.name == "project" })?.value else { return }
                    store.pendingSearch = name
                }
        }
            .windowResizability(.contentMinSize)
        .commands {
            WindowCommands()
            // Edit → Find (⌘F): the build log's find bar. In the main window ⌘F still goes to the search.
            TextEditingCommands()
            CommandGroup(after: .appInfo) {
                Button(L("Check for Updates …", "Nach Updates suchen …")) { SoftwareUpdate.shared.check() }
                    .disabled(!updates.canCheck)
            }
            CommandGroup(replacing: .help) {
                Button(L("Deploy Center on GitHub", "Deploy Center auf GitHub")) { open("https://github.com/\(Updater.repo)#readme") }
                Button(L("What's new", "Was ist neu")) { open("https://github.com/\(Updater.repo)/releases") }
                Button(L("Report a problem …", "Problem melden …")) { open("https://github.com/\(Updater.repo)/issues/new/choose") }
                Divider()
                Button(L("Open the error log", "Fehlerprotokoll öffnen")) {
                    if !FileManager.default.fileExists(atPath: Log.url.path) { Log.write("log started") }
                    NSWorkspace.shared.open(Log.url)
                }
            }
        }
        Settings { SettingsView(store: store) }
        MenuBarExtra(isInserted: $showMenuBar) {
            MenuBarContent(store: store)
        } label: {
            let w = store.waiting
            // Projects, as on the Dock badge and in the window's title.
            let n = w.projects
            // No array of all items: this label is built on every change of the store.
            let active = store.items.values.contains { $0.contains { $0.state.isActive } }
            let failed = !active && store.items.values.contains { $0.contains { if case .failed = $0.state { return true } else { return false } } }
            Image(systemName: active ? "paperplane.fill" : (failed ? "exclamationmark.triangle.fill" : "paperplane"))
                .task { appDelegate.attach(store); store.boot() }
                .modifier(OpensSettingsOnRequest(store: store))
                .accessibilityLabel("Deploy Center")
                .accessibilityValue(active ? L("deploying", "deployt gerade")
                    : failed ? L("a deploy failed", "ein Deploy ist fehlgeschlagen")
                    : n > 0 ? L("\(n) waiting", "\(n) warten") : L("everything is live", "alles ist live"))
            if n > 0 { Text("\(n)") }
        }
    }
}

/// The menu bar: what waits to go live, and a way to the window. Deploying stays in the window,
/// where the confirmation is.
struct MenuBarContent: View {
    @ObservedObject var store: Store
    @Environment(\.openWindow) private var openWindow
    @Environment(\.openSettings) private var openSettings
    @AppStorage("demoMode") private var demoMode = false
    @AppStorage("onlyChanged") private var onlyChanged = false
    @AppStorage("showAll") private var showAll = false

    private func openMain() { openWindow(id: "main"); NSApp.activate(ignoringOtherApps: true) }

    var body: some View {
        let w = store.waiting
        // The same rule as the count (Store.isWaiting): hidden projects stay out.
        let changed = Array(store.items.values.joined()).filter { store.isWaiting($0) }
            .sorted { ($0.pendingCommits ?? 0) > ($1.pendingCommits ?? 0) }
        let connected = Platform.allCases.filter { p in
            guard let d = store.doctor else { return false }
            return p == .vercel ? d.vercelLoggedIn : d.renderKey
        }
        let failed = connected.filter { store.lastLoadError[$0] != nil }
        let unread = connected.filter { store.listState($0) == .notLoaded }
        if store.doctor == nil {
            Text(L("Checking access …", "Prüfe Zugang …"))
        } else if connected.isEmpty {
            Text(L("Nothing connected yet", "Noch nichts verbunden"))
        }
        // The reason is in the window, with "Try again": the item opens it there.
        ForEach(failed, id: \.self) { p in
            Button {
                showAll = false; UserDefaults.standard.set(p.cli, forKey: "lastPlatform"); openMain()
            } label: {
                Label(L("\(p.rawValue) could not be loaded – show why …", "\(p.rawValue) konnte nicht geladen werden – Grund zeigen …"), systemImage: "exclamationmark.triangle")
            }
        }
        if !unread.isEmpty && failed.isEmpty {
            Text(L("Not loaded yet: ", "Noch nicht geladen: ") + unread.map(\.rawValue).joined(separator: ", "))
        }
        if w.projects == 0 {
            // Only said when it is known: every connected list was read and none failed.
            if !connected.isEmpty && failed.isEmpty && unread.isEmpty {
                Label(L("Everything merged is live", "Alles Gemergte ist live"), systemImage: "checkmark.circle")
            }
        } else {
            Text(L(plural(w.projects, "project", "projects") + " · " + plural(w.prs, "PR", "PRs") + " waiting",
                   plural(w.projects, "Projekt", "Projekte") + " · " + plural(w.prs, "PR", "PRs") + (w.projects == 1 ? " wartet" : " warten")))
            Divider()
            ForEach(changed.prefix(12)) { i in
                Button("\(Demo.mask(i.name))  –  \(Row.waitingText(i))") {
                    store.pendingSearch = i.name
                    openWindow(id: "main"); NSApp.activate(ignoringOtherApps: true)
                }
            }
            if changed.count > 12 {
                // Opens the window with everything that waits, not only the first twelve.
                Button(L("and \(changed.count - 12) more …", "und \(changed.count - 12) weitere …")) {
                    showAll = true; onlyChanged = true; openMain()
                }
            }
        }
        if w.openPRs > 0 {
            Text(L(plural(w.openPRs, "PR", "PRs") + " still open", plural(w.openPRs, "PR", "PRs") + " noch offen"))
        }
        let auto = Platform.allCases.reduce(0) { $0 + store.autoOn($1).count }
        if auto > 0 {
            Text(L("Auto-deploy is still on for \(auto) \(auto == 1 ? "project" : "projects") (costs build minutes)",
                   "Auto-Deploy ist noch an bei \(auto) \(auto == 1 ? "Projekt" : "Projekten") (kostet Build-Minuten)"))
        }
        if store.fixingCount > 0 {
            Text(L("Claude is fixing \(store.fixingCount) failed \(store.fixingCount == 1 ? "build" : "builds")",
                   "Claude behebt \(store.fixingCount) \(store.fixingCount == 1 ? "fehlgeschlagenen Build" : "fehlgeschlagene Builds")"))
        }
        ForEach(store.providerIssues, id: \.self) { Text("⚠︎ " + $0) }
        Divider()
        Button(L("Open Deploy Center", "Deploy Center öffnen")) {
            openWindow(id: "main"); NSApp.activate(ignoringOtherApps: true)
        }
        .keyboardShortcut("o")
        if w.projects > 0 && !store.observer {
            Button(L("Deploy everything with changes …", "Alles mit Änderungen deployen …")) {
                openWindow(id: "main"); NSApp.activate(ignoringOtherApps: true)
                store.pendingDeployAll = true
            }
        }
        Button(store.loading.isEmpty ? L("Reload", "Neu laden") : L("Loading …", "Lädt …")) { Task { await store.autoRefresh() } }
            .disabled(!store.loading.isEmpty)
        if let at = store.loadedAt.values.min() {
            Text(L("As of ", "Stand ") + at.formatted(date: .omitted, time: .shortened)
                 + (store.fromCache.isEmpty ? "" : L(" (saved copy)", " (gespeicherte Kopie)")))
        }
        Button(L("Settings …", "Einstellungen …")) {
            // Menu bar only: without activating, the window opens behind the other apps.
            NSApp.activate(ignoringOtherApps: true); openSettings()
        }
        .keyboardShortcut(",")
        Divider()
        // The app delegate asks while deploys run, as for ⌘Q and the Dock.
        Button(L("Quit", "Beenden")) { NSApp.terminate(nil) }
        .keyboardShortcut("q")
    }
}
