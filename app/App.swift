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
    @State private var loginError: String?

    var body: some View {
        Form {
            Picker(L("Reload the lists every", "Listen neu laden alle"), selection: $refreshMinutes) {
                ForEach([5, 15, 30, 60], id: \.self) { Text(L("\($0) minutes", "\($0) Minuten")).tag($0) }
            }
            Picker(L("Builds at the same time", "Builds gleichzeitig"), selection: $maxParallel) {
                ForEach([1, 2, 3, 5, 10], id: \.self) { Text("\($0)").tag($0) }
            }
            Toggle(L("Show in the menu bar", "In der Menüleiste zeigen"), isOn: $showMenuBar)
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
                }
            if let loginError { Text(loginError).font(.caption).foregroundStyle(.red) }
            Picker(L("Wait before a deploy starts", "Warten, bevor ein Deploy startet"), selection: $undoSeconds) {
                Text(L("No wait", "Nicht warten")).tag(0)
                ForEach([5, 8, 15], id: \.self) { Text(L("\($0) seconds (cancel possible)", "\($0) Sekunden (Abbrechen möglich)")).tag($0) }
            }
            HStack {
                Text(L("Monthly build budget (USD, 0 = off)", "Monatliches Build-Budget (USD, 0 = aus)"))
                TextField("0", value: $monthlyBudget, format: .number).frame(width: 70).multilineTextAlignment(.trailing)
            }
            Picker(L("Warn when commits wait longer than", "Warnen, wenn Commits länger warten als"), selection: $staleDays) {
                Text(L("Off", "Aus")).tag(0)
                ForEach([2, 3, 5, 7], id: \.self) { Text(L("\($0) days", "\($0) Tage")).tag($0) }
            }
            Toggle(L("Notify when a deploy ends", "Mitteilung, wenn ein Deploy fertig ist"), isOn: $notifications)
            Picker(L("Daily reminder to deploy", "Tägliche Erinnerung zum Deployen"), selection: $reminderHour) {
                Text(L("Off", "Aus")).tag(0)
                ForEach(7...20, id: \.self) { Text(L("at \($0):00", "um \($0):00 Uhr")).tag($0) }
            }
            .onChange(of: reminderHour) { _, h in if h > 0 { Notify.ask() } }
            .help(L("Only a reminder, and only when something waits. Nothing is deployed by itself.",
                    "Nur eine Erinnerung, und nur wenn etwas wartet. Es wird nichts von selbst deployt."))
            Toggle(L("Demo mode (hide project names, for screenshots)", "Demo-Modus (Projektnamen verbergen, für Screenshots)"), isOn: $demoMode)
            Toggle(L("Look for a new version once a day", "Einmal am Tag nach einer neuen Version sehen"), isOn: $checkUpdates)
            Button(L("Open the error log", "Fehlerprotokoll öffnen")) {
                if !FileManager.default.fileExists(atPath: Log.url.path) { Log.write("log started") }
                NSWorkspace.shared.open(Log.url)
            }
            if !store.hidden.isEmpty {
                DisclosureGroup(L("\(store.hidden.count) hidden projects", "\(store.hidden.count) ausgeblendete Projekte")) {
                    ForEach(store.hidden.sorted(), id: \.self) { k in
                        HStack {
                            Text(Demo.mask(String(k.split(separator: "/", maxSplits: 1).last ?? Substring(k))))
                            Spacer()
                            Button(L("Show", "Zeigen")) { store.unhide(k) }
                        }
                    }
                }
            }
            Button(L("Copy diagnostics", "Diagnose kopieren")) {
                let d = store.doctor
                let info = ["Deploy Center \(Bundle.main.infoDictionary?["CFBundleShortVersionString"] as? String ?? "?")",
                            ProcessInfo.processInfo.operatingSystemVersionString,
                            "jq \(d?.jq ?? false), vercel \(d?.vercelCli ?? false)/api \(d?.vercelApi ?? false)/login \(d?.vercelLoggedIn ?? false)",
                            "gh \(d?.githubCli ?? false)/login \(d?.githubLoggedIn ?? false), render key \(d?.renderKey ?? false)",
                            "Vercel \(store.items[.vercel]?.count ?? 0), Render \(store.items[.render]?.count ?? 0) projects"]
                NSPasteboard.general.clearContents(); NSPasteboard.general.setString(info.joined(separator: "\n"), forType: .string)
            }
            .help(L("Versions and what is connected; no names, no keys", "Versionen und was verbunden ist; keine Namen, keine Schlüssel"))
            Text(L("Version ", "Version ") + (Bundle.main.infoDictionary?["CFBundleShortVersionString"] as? String ?? "?")
                 + L(" · no telemetry; GitHub, Vercel and Render are asked with your own logins", " · keine Telemetrie; GitHub, Vercel und Render werden mit deinen eigenen Anmeldungen gefragt"))
                .font(.caption).foregroundStyle(.secondary)
        }
        .formStyle(.grouped)
        .frame(width: 460)
    }
}

@main
struct DeployCenterApp: App {
    /// One store for the window and the menu bar, so both show the same counts.
    @StateObject private var store = Store()
    @AppStorage("showMenuBar") private var showMenuBar = true

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
        Settings { SettingsView(store: store) }
        MenuBarExtra(isInserted: $showMenuBar) {
            MenuBarContent(store: store)
        } label: {
            let n = store.waiting.prs > 0 ? store.waiting.prs : store.waiting.projects
            let all = Array(store.items.values.joined())
            let icon = all.contains { $0.state.isActive } ? "paperplane.fill"
                : (all.contains { if case .failed = $0.state { return true } else { return false } } ? "exclamationmark.triangle.fill" : "paperplane")
            Image(systemName: icon).task { store.boot() }
            if n > 0 { Text("\(n)") }
        }
    }
}

/// The menu bar: what waits to go live, and a way to the window. Deploying stays in the window,
/// where the confirmation is.
struct MenuBarContent: View {
    @ObservedObject var store: Store
    @Environment(\.openWindow) private var openWindow

    var body: some View {
        let w = store.waiting
        let changed = Array(store.items.values.joined()).filter { $0.hasNewCommits && $0.deployable && $0.state == .idle }
            .sorted { ($0.pendingCommits ?? 0) > ($1.pendingCommits ?? 0) }
        if w.projects == 0 {
            Text(L("Everything merged is live", "Alles Gemergte ist live"))
        } else {
            Text(L("\(w.prs) PRs, \(w.commits) commits waiting", "\(w.prs) PRs, \(w.commits) Commits warten"))
            Divider()
            ForEach(changed.prefix(12)) { i in
                Button("\(Demo.mask(i.name))  –  \(Row.waitingText(i))") {
                    store.pendingSearch = i.name
                    openWindow(id: "main"); NSApp.activate(ignoringOtherApps: true)
                }
            }
            if changed.count > 12 { Text(L("and \(changed.count - 12) more", "und \(changed.count - 12) weitere")) }
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
        Button(L("Reload", "Neu laden")) { Task { await store.autoRefresh() } }
        Divider()
        Button(L("Quit", "Beenden")) { NSApp.terminate(nil) }.keyboardShortcut("q")
    }
}
