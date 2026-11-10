// Deploy Center — turn off auto-deploy on Vercel and Render, then deploy by hand from one window.
// All the work is done by the `deploys` script bundled with the app; the app only calls it.
// Built by build.sh (swiftc over app/*.swift, Swift 5 mode, no Xcode project needed).
// This file: Settings, the app, and the menu bar.

import SwiftUI
import AppKit
import Charts
import UserNotifications
import ServiceManagement

// MARK: - Settings (⌘,)

struct SettingsView: View {
    @ObservedObject var store: Store
    @AppStorage("refreshMinutes") private var refreshMinutes = 15
    @AppStorage("maxParallel") private var maxParallel = 3
    @AppStorage("reminderHour") private var reminderHour = 0
    @AppStorage("showMenuBar") private var showMenuBar = true
    @AppStorage("hideDock") private var hideDock = false
    @AppStorage("notifications") private var notifications = true
    @AppStorage("checkUpdates") private var checkUpdates = true
    @AppStorage("demoMode") private var demoMode = false
    @AppStorage("undoSeconds") private var undoSeconds = 8
    @AppStorage("staleDays") private var staleDays = 0
    @AppStorage("monthlyBudget") private var monthlyBudget = 0.0
    @State private var openAtLogin = SMAppService.mainApp.status == .enabled
    @State private var loginNeedsApproval = SMAppService.mainApp.status == .requiresApproval
    @State private var loginError: String?
    @State private var notificationsDenied = false

    private var version: String { Bundle.main.infoDictionary?["CFBundleShortVersionString"] as? String ?? "?" }

    var body: some View {
        Form {
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
                if let loginError { Text(loginError).font(.caption).foregroundStyle(.red) }
                Toggle(L("Demo mode (hide project names, for screenshots)", "Demo-Modus (Projektnamen verbergen, für Screenshots)"), isOn: $demoMode)
            }

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
            }

            Section(L("Costs", "Kosten")) {
                HStack {
                    Text(L("Monthly build budget (USD, 0 = off)", "Monatliches Build-Budget (USD, 0 = aus)"))
                    Spacer()
                    TextField("0", value: $monthlyBudget, format: .number).frame(width: 80).multilineTextAlignment(.trailing)
                        // A budget below zero means nothing; it becomes "off".
                        .onChange(of: monthlyBudget) { _, v in if v < 0 || !v.isFinite { monthlyBudget = 0 } }
                }
            }

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

            Section(L("Updates", "Updates")) {
                Toggle(L("Check for updates daily", "Täglich nach Updates suchen"), isOn: $checkUpdates)
                HStack {
                    Button(L("Check now", "Jetzt suchen")) { Task { await store.checkForUpdate(force: true) } }
                    if store.newVersion != nil {
                        Button(store.updating ? L("Updating …", "Aktualisiere …") : L("Update now", "Jetzt aktualisieren")) { Task { await store.installUpdate() } }
                            .disabled(store.updating)
                        Button(L("Download", "Herunterladen")) {
                            NSWorkspace.shared.open(URL(string: "https://github.com/\(Updater.repo)/releases/latest")!)
                        }
                    }
                    Spacer()
                    // The result next to the button, with the versions it is about.
                    Group {
                        if let v = store.newVersion { Text(L("Version \(v) is out (you have \(version))", "Version \(v) ist da (du hast \(version))")) }
                        else if let st = store.updateStatus { Text(st) }
                        else { Text(L("You have \(version)", "Du hast \(version)")) }
                    }
                    .font(.caption).foregroundStyle(.secondary)
                }
            }

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

            Section(L("Help", "Hilfe")) {
                Button(L("Open the error log", "Fehlerprotokoll öffnen")) {
                    if !FileManager.default.fileExists(atPath: Log.url.path) { Log.write("log started") }
                    NSWorkspace.shared.open(Log.url)
                }
                CopyButton(title: L("Copy diagnostics", "Diagnose kopieren")) {
                    let d = store.doctor
                    return ["Deploy Center \(version)",
                            ProcessInfo.processInfo.operatingSystemVersionString,
                            "jq \(d?.jq ?? false), vercel \(d?.vercelCli ?? false)/api \(d?.vercelApi ?? false)/login \(d?.vercelLoggedIn ?? false)",
                            "gh \(d?.githubCli ?? false)/login \(d?.githubLoggedIn ?? false), render key \(d?.renderKey ?? false)",
                            "Vercel \(store.items[.vercel]?.count ?? 0), Render \(store.items[.render]?.count ?? 0) projects"].joined(separator: "\n")
                }
                Text(L("Diagnostics: versions and what is connected; no names, no keys.", "Diagnose: Versionen und was verbunden ist; keine Namen, keine Schlüssel."))
                    .font(.caption).foregroundStyle(.secondary)
                Text(L("Version ", "Version ") + version
                     + L(" · no telemetry; GitHub, Vercel and Render are asked with your own logins", " · keine Telemetrie; GitHub, Vercel und Render werden mit deinen eigenen Anmeldungen gefragt"))
                    .font(.caption).foregroundStyle(.secondary)
            }
        }
        .formStyle(.grouped)
        .frame(width: 560)
        .frame(minHeight: 480, idealHeight: 680, maxHeight: 820)
        .task {
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

@main
struct DeployCenterApp: App {
    /// One store for the window and the menu bar, so both show the same counts.
    @StateObject private var store = Store()
    @AppStorage("showMenuBar") private var showMenuBar = true

    init() {
        // No menu bar and no Dock icon would leave the app without any way in.
        let d = UserDefaults.standard
        if d.object(forKey: "showMenuBar") as? Bool == false && d.bool(forKey: "hideDock") { d.set(false, forKey: "hideDock") }
    }

    var body: some Scene {
        WindowGroup("Deploy Center", id: "main") {
            ContentView(store: store)
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
            CommandGroup(after: .appInfo) {
                Button(L("Check for Updates …", "Nach Updates suchen …")) { Task { await store.checkForUpdate(force: true) } }
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
            let n = w.prs > 0 ? w.prs : w.projects
            // No array of all items: this label is built on every change of the store.
            let active = store.items.values.contains { $0.contains { $0.state.isActive } }
            let failed = !active && store.items.values.contains { $0.contains { if case .failed = $0.state { return true } else { return false } } }
            Image(systemName: active ? "paperplane.fill" : (failed ? "exclamationmark.triangle.fill" : "paperplane"))
                .task { store.boot() }
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
        let changed = Array(store.items.values.joined()).filter { $0.hasNewCommits && $0.deployable && $0.state == .idle }
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
        ForEach(failed, id: \.self) { p in
            Label(L("\(p.rawValue) could not be loaded", "\(p.rawValue) konnte nicht geladen werden"), systemImage: "exclamationmark.triangle")
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
            Text(L("\(w.prs) PRs, \(w.commits) commits waiting", "\(w.prs) PRs, \(w.commits) Commits warten"))
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
            Text(L("\(w.openPRs) PRs still open", "\(w.openPRs) PRs noch offen"))
        }
        let auto = Platform.allCases.reduce(0) { $0 + store.autoOn($1).count }
        if auto > 0 {
            Text(L("Auto-deploy is still on for \(auto) \(auto == 1 ? "project" : "projects") (costs build minutes)",
                   "Auto-Deploy ist noch an bei \(auto) \(auto == 1 ? "Projekt" : "Projekten") (kostet Build-Minuten)"))
        }
        ForEach(store.providerIssues, id: \.self) { Text("⚠︎ " + $0) }
        Divider()
        Button(L("Open Deploy Center", "Deploy Center öffnen")) {
            openWindow(id: "main"); NSApp.activate(ignoringOtherApps: true)
        }
        .keyboardShortcut("o")
        if w.projects > 0 {
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
        Button(L("Quit", "Beenden")) { NSApp.terminate(nil) }.keyboardShortcut("q")
    }
}
