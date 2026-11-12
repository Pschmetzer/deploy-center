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
import CoreSpotlight

// MARK: - Settings (⌘,)

struct SettingsView: View {
    @ObservedObject var store: Store
    @AppStorage("refreshMinutes") private var refreshMinutes = 15
    @State private var language = AppLanguage.chosen
    @AppStorage("maxParallel") private var maxParallel = 3
    @AppStorage("reminderHour") private var reminderHour = 0
    @AppStorage("summaryHour") private var summaryHour = 0
    @AppStorage("weeklySummary") private var weeklySummary = false
    @AppStorage(Speech.resultsKey) private var speakResults = false
    @AppStorage("quietFrom") private var quietFrom = 0
    @AppStorage("quietTo") private var quietTo = 0
    @AppStorage("remindFailures") private var remindFailures = false
    @AppStorage("showMenuBar") private var showMenuBar = true
    @AppStorage("hideDock") private var hideDock = false
    @AppStorage("notifications") private var notifications = true
    @AppStorage("checkUpdates") private var checkUpdates = true
    @ObservedObject private var updates = SoftwareUpdate.shared
    @AppStorage("demoMode") private var demoMode = false
    @AppStorage(Color.colorBlindKey) private var colorBlind = false
    @AppStorage("compactRows") private var compactRows = false
    @AppStorage(Tips.key) private var tipOn = true
    @AppStorage(Spotlight.key) private var spotlight = false
    @AppStorage(Notify.soundsKey) private var resultSounds = false
    @AppStorage("loadLogos") private var loadLogos = true
    @AppStorage("undoSeconds") private var undoSeconds = 8
    @AppStorage("staleDays") private var staleDays = 0
    @AppStorage("monthlyBudget") private var monthlyBudget = 0.0
    /// The checkbox of the deploy confirmation, here too, so the remembered state can be seen.
    @AppStorage("onlyWhenGreen") private var onlyWhenGreen = false
    @AppStorage(OwnerCheck.key) private var ownerCheck = false
    @AppStorage("watchMinutes") private var watchMinutes = 0
    @AppStorage(MigrationCheck.key) private var migrationCheck = true
    @AppStorage("confirmSingleDeploy") private var confirmSingle = true
    @AppStorage("ignoredTriggers") private var ignoredTriggers = ""
    @State private var openAtLogin = SMAppService.mainApp.status == .enabled
    @State private var loginNeedsApproval = SMAppService.mainApp.status == .requiresApproval
    @State private var loginError: String?
    @State private var notificationsDenied = false
    @State private var providerError: String?
    /// The last switch that failed, for "Try again".
    @State private var failedSwitch: (id: String, on: Bool)?
    @State private var switchResult: String?
    @State private var switching: String?
    @State private var resetTab: SettingsTab?
    @State private var clearMarks: ProjectMarks?

    /// Last opened tab; others (the autofix toast, a link) set it and an anchor before opening Settings.
    @AppStorage(SettingsNav.tabKey) private var tabRaw = SettingsTab.general.rawValue
    @AppStorage(SettingsNav.anchorKey) private var anchor = ""
    private var tab: Binding<SettingsTab> {
        Binding(get: { SettingsTab.resolve(tabRaw) }, set: { tabRaw = $0.rawValue })
    }

    private var version: String { Bundle.main.infoDictionary?["CFBundleShortVersionString"] as? String ?? "?" }

    /// One tab: a form that scrolls to the anchor it was opened with, and "Reset to defaults" under it.
    private func page<C: View>(_ t: SettingsTab, @ViewBuilder _ content: @escaping (ScrollViewProxy) -> C) -> some View {
        ScrollViewReader { proxy in
            Form {
                content(proxy)
                if !t.defaultsKeys.isEmpty {
                    Section {
                        Button(L("Reset to defaults …", "Auf Standard zurücksetzen …")) { resetTab = t }
                    } footer: {
                        Text(L("Only the options on this tab; keys and project data stay.",
                               "Nur die Optionen auf diesem Tab; Schlüssel und Projektdaten bleiben."))
                    }
                }
            }
            .formStyle(.grouped)
            .onAppear { scroll(proxy, on: t) }
            .onChange(of: anchor) { _, _ in scroll(proxy, on: t) }
        }
        .tabItem { Label(t.title, systemImage: t.symbol) }.tag(t)
    }
    private func scroll(_ proxy: ScrollViewProxy, on t: SettingsTab) {
        guard !anchor.isEmpty, SettingsTab.resolve(tabRaw) == t else { return }
        let a = anchor
        DispatchQueue.main.async { withAnimation { proxy.scrollTo(a, anchor: .top) }; anchor = "" }
    }

    var body: some View {
        TabView(selection: tab) {
            page(.general) { _ in generalSection; notificationsSection; updatesSection; CommandPaletteSettings() }
            page(.platforms) { _ in platformsSection; HealthCard(store: store) }
            page(.projects) { _ in projectsSection }
            page(.deploy) { _ in deploySection; DeployWindowSettings(); RulesSettings(); GuardSettings(store: store) }
            page(.costs) { _ in costsSection }
            page(.claude) { proxy in
                ClaudeSettings { withAnimation { proxy.scrollTo("autofix", anchor: .top) } }
                ClaudeAISettings(items: allItems).id("claudeAI")
                PromptTemplateSettings()
                AutofixSettings(store: store).id("autofix")
            }
            page(.iphone) { _ in PhoneLinkSettings() }
            page(.team) { _ in TeamSettings(store: store) }
            page(.help) { _ in helpSection; shortcutsSection }
        }
        .frame(width: 560, height: SettingsTab.resolve(tabRaw).height)
        // The window keeps its place (it covered the main window's banners when it always opened on top of it).
        .background(WindowAccessor { $0.setFrameAutosaveName("DeployCenterSettings") })
        .task {
            SettingsChoice.snapAll()
            // Fresh switches; a script without `deploys providers` was asked at start already.
            if store.providersFromScript { await store.loadProviders() }
            await readSystemState()
        }
        // Changed in System Settings while this window was open: read again on coming back.
        .onReceive(NotificationCenter.default.publisher(for: NSApplication.didBecomeActiveNotification)) { _ in
            Task { await readSystemState() }
        }
        .onChange(of: notifications) { _, _ in Task { await readSystemState() } }
        .confirmationDialog(L("Reset “\(resetTab?.title ?? "")” to the defaults?", "„\(resetTab?.title ?? "")“ auf Standard zurücksetzen?"),
                            isPresented: Binding(get: { resetTab != nil }, set: { if !$0 { resetTab = nil } })) {
            Button(L("Reset", "Zurücksetzen"), role: .destructive) { if let t = resetTab { reset(t) }; resetTab = nil }
            Button(L("Cancel", "Abbrechen"), role: .cancel) { resetTab = nil }
        } message: {
            Text(L("Keys, logins and project data are not touched.", "Schlüssel, Anmeldungen und Projektdaten bleiben unberührt."))
        }
        .confirmationDialog(clearMarks?.question ?? "", isPresented: Binding(get: { clearMarks != nil }, set: { if !$0 { clearMarks = nil } })) {
            Button(L("Reset", "Zurücksetzen"), role: .destructive) { if let m = clearMarks { clear(m) }; clearMarks = nil }
            Button(L("Cancel", "Abbrechen"), role: .cancel) { clearMarks = nil }
        } message: {
            Text(L("Only on this Mac. It cannot be undone.", "Nur auf diesem Mac. Das lässt sich nicht rückgängig machen."))
        }
    }

    private var allItems: [Item] { Platform.allCases.flatMap { store.items[$0] ?? [] } }

    private func readSystemState() async {
        let st = await UNUserNotificationCenter.current().notificationSettings()
        notificationsDenied = notifications && st.authorizationStatus == .denied
        openAtLogin = SMAppService.mainApp.status == .enabled || SMAppService.mainApp.status == .requiresApproval
        loginNeedsApproval = SMAppService.mainApp.status == .requiresApproval
    }

    private func reset(_ t: SettingsTab) {
        let d = UserDefaults.standard
        t.defaultsKeys.forEach { d.removeObject(forKey: $0) }
        if t == .general {
            NSApp.setActivationPolicy(.regular)
            SoftwareUpdate.shared.setAutomatic(true)
            _ = PaletteHotKey.update()
        }
    }

    // MARK: General

    @ViewBuilder private var generalSection: some View {
        Section(L("General", "Allgemein")) {
            Picker(L("Reload the lists every", "Listen neu laden alle"), selection: $refreshMinutes) {
                ForEach(SettingsChoice.refreshMinutes, id: \.self) { Text(L("\($0) minutes", "\($0) Minuten")).tag($0) }
            }
            Toggle(L("Show in the menu bar", "In der Menüleiste zeigen"), isOn: $showMenuBar)
                // Without the menu bar the Dock icon is the only way back in: it comes back.
                .onChange(of: showMenuBar) { _, on in
                    if !on && hideDock { hideDock = false }
                }
            Toggle(L("No Dock icon (menu bar only)", "Kein Dock-Symbol (nur Menüleiste)"), isOn: $hideDock)
                .disabled(!showMenuBar)
                .help(showMenuBar ? "" : L("Needs the menu bar icon: without both there is no way back in.",
                                           "Braucht das Menüleisten-Symbol: ohne beides gibt es keinen Weg zurück."))
                .onChange(of: hideDock) { _, on in
                    NSApp.setActivationPolicy(on ? .accessory : .regular)
                    if !on { NSApp.activate(ignoringOtherApps: true) }
                }
            if !showMenuBar {
                Text(L("“No Dock icon” needs the menu bar icon.", "„Kein Dock-Symbol“ braucht das Menüleisten-Symbol."))
                    .font(.caption).foregroundStyle(.secondary)
            }
            Toggle(L("Open at login", "Beim Anmelden öffnen"), isOn: $openAtLogin)
                .onChange(of: openAtLogin) { _, on in
                    // Already so (also after a failed call put the switch back): nothing to register twice.
                    let st = SMAppService.mainApp.status
                    let registered = st == .enabled || st == .requiresApproval
                    guard on != registered else { loginNeedsApproval = st == .requiresApproval; return }
                    do { if on { try SMAppService.mainApp.register() } else { try SMAppService.mainApp.unregister() }; loginError = nil }
                    catch { loginError = error.localizedDescription }
                    let now = SMAppService.mainApp.status
                    loginNeedsApproval = now == .requiresApproval
                    let isOn = now == .enabled || now == .requiresApproval
                    if isOn != on { openAtLogin = isOn }
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
                .help(L("Also in the View menu: ⇧⌘D", "Auch im Menü Darstellung: ⇧⌘D"))
                .onChange(of: demoMode) { _, _ in Spotlight.update(Array(store.items.values.joined()).filter { !store.isHidden($0) }) }
            Toggle(L("Find projects in Spotlight", "Projekte in Spotlight finden"), isOn: $spotlight)
                .help(L("Only names and platforms, kept on this Mac; never in demo mode.", "Nur Namen und Plattformen, auf diesem Mac; nie im Demo-Modus."))
                .onChange(of: spotlight) { _, _ in Spotlight.update(Array(store.items.values.joined()).filter { !store.isHidden($0) }) }
            Toggle(L("Tip of the day in the menu bar", "Tipp des Tages in der Menüleiste"), isOn: $tipOn)
            Toggle(L("Compact list (less space between rows)", "Kompakte Liste (weniger Abstand zwischen den Zeilen)"), isOn: $compactRows)
            Toggle(L("Colour-blind friendly (blue instead of green)", "Farbenblind-freundlich (Blau statt Grün)"), isOn: $colorBlind)
                .help(L("Live and merged show in blue, failures stay red; the symbols differ as well.",
                        "Live und Gemergt erscheinen blau, Fehler bleiben rot; die Symbole unterscheiden sich ebenfalls."))
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
            Picker(L("Summary of the day", "Tagesabschluss"), selection: $summaryHour) {
                Text(L("Off", "Aus")).tag(0)
                ForEach(12...23, id: \.self) { Text(L("from \($0):00", "ab \($0):00 Uhr")).tag($0) }
            }
            .onChange(of: summaryHour) { _, h in if h > 0 { Notify.ask() } }
            .help(L("How many deploys ended today and how many failed, from the history. Only when something ended.",
                    "Wie viele Deploys heute fertig wurden und wie viele fehlschlugen, aus dem Verlauf. Nur wenn etwas fertig wurde."))
            Toggle(L("A sound per result (live, failed)", "Ein Klang je Ergebnis (live, fehlgeschlagen)"), isOn: $resultSounds)
                .help(L("Glass when it is live, Basso when it failed, Pop when you cancelled.",
                        "Glass bei live, Basso bei Fehler, Pop beim Abbrechen."))
            Toggle(L("Say when a deploy ends", "Ansagen, wenn ein Deploy fertig ist"), isOn: $speakResults)
                .help(L("Spoken by VoiceOver when it is on, else by the Mac's voice.", "Mit VoiceOver von VoiceOver, sonst von der Stimme des Macs."))
            Toggle(L("Week in review on Mondays", "Wochenrückblick am Montag"), isOn: $weeklySummary)
                .onChange(of: weeklySummary) { _, on in if on { Notify.ask() } }
            HStack {
                Text(L("Quiet hours", "Ruhezeit"))
                Spacer()
                Picker(L("from", "von"), selection: $quietFrom) { ForEach(0...23, id: \.self) { Text(String(format: "%02d:00", $0)).tag($0) } }
                    .labelsHidden().frame(width: 90)
                Text(L("to", "bis"))
                Picker(L("to", "bis"), selection: $quietTo) { ForEach(0...23, id: \.self) { Text(String(format: "%02d:00", $0)).tag($0) } }
                    .labelsHidden().frame(width: 90)
            }
            .help(L("Inside these hours only failures notify. The same hour twice: off. macOS Focus applies as well.",
                    "In diesen Stunden melden sich nur Fehler. Zweimal dieselbe Stunde: aus. Der macOS-Fokus gilt zusätzlich."))
            Toggle(L("Remind again after 30 minutes when a failure was not looked at", "Nach 30 Minuten noch einmal erinnern, wenn ein Fehler nicht angesehen wurde"),
                   isOn: $remindFailures)
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

    // MARK: Platforms

    /// Which platforms the main window shows. Vercel and Render are on; others are switched on here,
    /// once the `deploys` script knows them. The ones still to come are listed apart, without a switch.
    @ViewBuilder private var platformsSection: some View {
        let rows = ProviderInfo.settingsRows(store.providers)
        Section(L("Platforms", "Plattformen")) {
            let on = store.enabledProviders.count
            ForEach(rows.filter(\.available)) { row in
                let info = row.info
                let isOn = store.enabledProviders.contains { $0.id == info.id }
                // The script knows it, the window cannot list it yet: it can be switched off, not on.
                let cliOnly = info.platform == nil
                let last = isOn && on <= 1
                Toggle(isOn: Binding(get: { isOn }, set: { want in switchProvider(info, on: want) })) {
                    VStack(alignment: .leading, spacing: 1) {
                        HStack(spacing: 6) {
                            Text(info.label)
                            if switching == info.id { ProgressView().controlSize(.small) }
                        }
                        if cliOnly {
                            Text(L("Command line only (deploys); the window cannot show it yet",
                                   "Nur in der Kommandozeile (deploys); das Fenster kann es noch nicht zeigen"))
                                .font(.caption).foregroundStyle(.secondary)
                        } else if isOn, let c = SettingsText.connection(info.id, doctor: store.doctor) {
                            Label(c.text, systemImage: c.ok ? "checkmark.circle" : "exclamationmark.circle")
                                .font(.caption).foregroundStyle(c.ok ? Color.secondary : Color.warningText)
                        }
                    }
                }
                // Switches need `deploys providers`; the last platform that is on stays on.
                .disabled(!store.providersFromScript || switching != nil || last || (cliOnly && !isOn))
                .help(last ? L("At least one platform stays on.", "Mindestens eine Plattform bleibt an.") : "")
            }
            if !store.providersFromScript {
                Text(L("This version of the deploys script always shows Vercel and Render.",
                       "Diese Version des deploys-Skripts zeigt immer Vercel und Render."))
                    .font(.caption).foregroundStyle(.secondary)
            }
            if let switchResult { Text(switchResult).font(.caption).foregroundStyle(.secondary) }
            if let providerError {
                HStack(alignment: .top) {
                    Text(providerError).font(.caption).foregroundStyle(.red).textSelection(.enabled)
                    Spacer()
                    if let f = failedSwitch, let info = store.providers.first(where: { $0.id == f.id }) {
                        Button(L("Try again", "Nochmal")) { switchProvider(info, on: f.on) }.disabled(switching != nil)
                    }
                }
            }
        }
        let planned = rows.filter { !$0.available }
        if !planned.isEmpty {
            Section {
                DisclosureGroup(L("Planned (\(planned.count))", "Geplant (\(planned.count))")) {
                    ForEach(planned) { Text($0.info.label).foregroundStyle(.secondary) }
                }
            } footer: {
                Text(L("Not in the deploys script yet; they get a switch once it knows them.",
                       "Noch nicht im deploys-Skript; sie bekommen einen Schalter, sobald es sie kennt."))
            }
        }
    }

    private func switchProvider(_ info: ProviderInfo, on want: Bool) {
        switching = info.id; providerError = nil; switchResult = nil; failedSwitch = nil
        Task {
            if let e = await store.setProvider(info.id, on: want) {
                providerError = e; failedSwitch = (info.id, want)
            } else if want {
                let n = info.platform.map { store.items[$0]?.count ?? 0 }
                switchResult = n.map { L("\(info.label): on, \(plural($0, "project", "projects")) loaded", "\(info.label): eingeschaltet, \(plural($0, "Projekt", "Projekte")) geladen") }
                    ?? L("\(info.label): on", "\(info.label): eingeschaltet")
            } else {
                switchResult = L("\(info.label): off", "\(info.label): ausgeschaltet")
            }
            switching = nil
        }
    }

    // MARK: Projects

    /// What the person marked on projects, kept on this Mac; each with a way back to none.
    @ViewBuilder private var projectsSection: some View {
        Section(L("Hidden projects", "Ausgeblendete Projekte")) {
            if store.hidden.isEmpty {
                Text(L("None. Hide a project from its row menu.", "Keine. Ein Projekt blendest du über das Zeilenmenü aus."))
                    .foregroundStyle(.secondary)
            } else {
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
        Section(L("Marks", "Markierungen")) {
            ForEach(ProjectMarks.allCases) { m in
                let n = m.count(store, ignoredTriggers: ignoredTriggers)
                HStack {
                    Text(m.title)
                    Spacer()
                    Text("\(n)").monospacedDigit().foregroundStyle(.secondary)
                    Button(L("Reset …", "Zurücksetzen …")) { clearMarks = m }.disabled(n == 0)
                }
            }
        }
    }

    private func clear(_ m: ProjectMarks) {
        if m == .ignoredTriggers { ignoredTriggers = "" } else { store.clearMarks(m) }
    }

    /// The name of a hidden project: from the list when it is there (Render keys hold the service id).
    private func hiddenName(_ k: String) -> String {
        if let i = allItems.first(where: { Store.key($0) == k }) { return i.name }
        return String(k.split(separator: "/", maxSplits: 1).last ?? Substring(k))
    }
    private func hiddenPlatform(_ k: String) -> String {
        ProviderInfo.label(for: String(k.split(separator: "/").first ?? ""))
    }

    // MARK: Deploy and costs

    @ViewBuilder private var deploySection: some View {
        Section(L("Deploy", "Deploy")) {
            Picker(L("Builds at the same time", "Builds gleichzeitig"), selection: $maxParallel) {
                ForEach(SettingsChoice.maxParallel, id: \.self) { Text("\($0)").tag($0) }
            }
            Picker(L("Wait before a deploy starts", "Warten, bevor ein Deploy startet"), selection: $undoSeconds) {
                Text(L("No wait", "Nicht warten")).tag(0)
                ForEach(SettingsChoice.undoSeconds.filter { $0 > 0 }, id: \.self) { Text(L("\($0) seconds (cancel possible)", "\($0) Sekunden (Abbrechen möglich)")).tag($0) }
            }
            Toggle(L("Ask before a single deploy (row menu and palette)", "Vor einem Einzel-Deploy fragen (Zeilenmenü und Palette)"), isOn: $confirmSingle)
                .help(L("Deploying several projects always asks.", "Mehrere Projekte zu deployen fragt immer."))
            Picker(L("Warn when commits wait longer than", "Warnen, wenn Commits länger warten als"), selection: $staleDays) {
                Text(L("Off", "Aus")).tag(0)
                ForEach(SettingsChoice.staleDays.filter { $0 > 0 }, id: \.self) { Text(L("\($0) days", "\($0) Tage")).tag($0) }
            }
            Toggle(L("Deploy only when the checks are green", "Nur deployen, wenn die Checks grün sind"), isOn: $onlyWhenGreen)
                .help(L("The same switch as in the deploy confirmation: commits whose CI did not pass stay back.",
                        "Derselbe Schalter wie in der Deploy-Rückfrage: Commits, deren CI nicht durchlief, bleiben zurück."))
            Picker(L("Watch the site after going live", "Seite nach dem Live-Gang beobachten"), selection: $watchMinutes) {
                Text(L("Check once", "Einmal prüfen")).tag(0)
                ForEach([5, 15, 30], id: \.self) { Text(L("\($0) minutes, every minute", "\($0) Minuten, jede Minute")).tag($0) }
            }
            .help(L("Two failed answers in a row warn, or roll back where the project rolls back by itself (its details).",
                    "Zwei fehlgeschlagene Antworten hintereinander warnen, oder rollen zurück, wo das Projekt selbst zurückrollt (seine Details)."))
            Toggle(L("Ask for a tick before database migrations go live", "Vor dem Live-Gang von Datenbank-Migrationen ein Häkchen verlangen"), isOn: $migrationCheck)
                .help(L("When the waiting commits change migration files, every live deploy of them asks first.",
                        "Ändern die wartenden Commits Migrationsdateien, fragt jeder Live-Deploy davon erst nach."))
            Toggle(L("Ask for Touch ID or the password before risky steps", "Vor riskanten Schritten nach Touch ID oder dem Passwort fragen"), isOn: $ownerCheck)
                .help(L("Deploying several projects at once, a rollback by hand, and allowing auto-deploy. The automatic rollback after a failed check does not wait.",
                        "Mehrere Projekte auf einmal deployen, ein Rollback von Hand und Auto-Deploy erlauben. Das automatische Zurückrollen nach einem fehlgeschlagenen Check wartet nicht."))
        }
    }

    @ViewBuilder private var costsSection: some View {
        Section(L("Budget", "Budget")) {
            HStack {
                Text(L("Monthly build budget (0 = off)", "Monatliches Build-Budget (0 = aus)"))
                Spacer()
                TextField("0", value: $monthlyBudget, format: .currency(code: "USD").precision(.fractionLength(0...2)))
                    .frame(width: 90).multilineTextAlignment(.trailing)
                    // A budget below zero means nothing; it becomes "off".
                    .onChange(of: monthlyBudget) { _, v in if v < 0 || !v.isFinite { monthlyBudget = 0 } }
                Stepper("", value: $monthlyBudget, in: 0...100_000, step: 10).labelsHidden()
            }
            Text(SettingsText.budgetHint(budget: monthlyBudget, pace: store.costs.flatMap { Store.monthPace($0.days, today: CostsSheet.today()) }))
                .font(.caption).foregroundStyle(.secondary)
            if let s = store.staleNote("costs") { Text(s).font(.caption).foregroundStyle(Color.warningText) }
        }
        Section(L("Savings", "Ersparnis")) { SavingsLink() }
    }

    // MARK: Help

    @ViewBuilder private var helpSection: some View {
        Section(L("Help", "Hilfe")) {
            Button(L("Open the error log", "Fehlerprotokoll öffnen")) {
                if !FileManager.default.fileExists(atPath: Log.url.path) { Log.write("log started") }
                NSWorkspace.shared.open(Log.url)
            }
            CopyButton(title: L("Copy diagnostics", "Diagnose kopieren")) {
                let counts = Dictionary(uniqueKeysWithValues: Platform.allCases.map { ($0.cli, store.items[$0]?.count ?? 0) })
                let gitlab = Set(allItems.compactMap(\.repo).filter { GitHost(repo: $0) != .github }).count
                let d = store.doctor
                // Counts and times only: no project names, no error texts (they can hold names).
                let jobs: [String] = d?.jobsMissing ?? []
                let failures = Platform.allCases.compactMap { p in
                    store.lastLoadError[p].map { "\(p.cli) failed \($0.at.formatted(date: .numeric, time: .shortened))" }
                }
                return SettingsText.diagnostics(version: version, os: ProcessInfo.processInfo.operatingSystemVersionString,
                                                doctor: store.doctor, providers: store.providers, counts: counts,
                                                gitlabRepos: gitlab, autofix: store.autofix)
                    + "\n" + ["language \(AppLanguage.running.rawValue), observer \(store.observer)",
                              "perl \(d?.perl.map(String.init) ?? "?"), curl \(d?.curl.map(String.init) ?? "?")",
                              "last load error: " + (failures.isEmpty ? "none" : failures.joined(separator: "; ")),
                              "jobs missing tools: " + (jobs.isEmpty ? "none" : jobs.joined(separator: ", "))].joined(separator: "\n")
            }
            Button(L("Show the first-start guide again", "Erststart-Anleitung wieder zeigen")) { UserDefaults.standard.set(false, forKey: FirstStart.key) }
            Text(L("Diagnostics: versions and what is connected; no names, no keys.", "Diagnose: Versionen und was verbunden ist; keine Namen, keine Schlüssel."))
                .font(.caption).foregroundStyle(.secondary)
            Text(L("Version ", "Version ") + version
                 + L(" · no telemetry; GitHub, GitLab and every platform are asked with your own logins and keys",
                     " · keine Telemetrie; GitHub, GitLab und jede Plattform werden mit deinen eigenen Anmeldungen und Schlüsseln gefragt"))
                .font(.caption).foregroundStyle(.secondary)
        }
    }

    @ViewBuilder private var shortcutsSection: some View {
        Section(L("Keyboard shortcuts", "Tastenkürzel")) {
            ForEach(SettingsText.shortcuts, id: \.keys) { s in
                LabeledContent(s.what) { Text(s.keys).monospaced().foregroundStyle(.secondary) }
            }
        }
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

    /// The Dock icon's menu: reload, and "deploy everything with changes", which opens the window
    /// at the usual confirmation (nothing starts from the Dock).
    func applicationDockMenu(_ sender: NSApplication) -> NSMenu? {
        let m = NSMenu()
        m.addItem(withTitle: L("Reload", "Neu laden"), action: #selector(dockReload), keyEquivalent: "").target = self
        if let s = store, s.waiting.projects > 0, !s.observer {
            m.addItem(withTitle: L("Deploy everything with changes …", "Alles mit Änderungen deployen …"), action: #selector(dockDeployAll), keyEquivalent: "").target = self
        }
        return m
    }
    @objc private func dockReload() { Task { await store?.autoRefresh() } }
    @objc private func dockDeployAll() {
        guard let s = store else { return }
        NSApp.activate(ignoringOtherApps: true)
        if let w = NSApp.windows.first(where: { $0.identifier?.rawValue.hasPrefix("main") == true && $0.canBecomeMain }) { w.makeKeyAndOrderFront(nil) }
        else { s.windowRequest += 1 }
        s.pendingDeployAll = true
    }

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
    @AppStorage("demoMode") private var demoMode = false

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
                // deploycenter://select?project=name (or platform:name) shows exactly that project in the
                // window; deploycenter://settings/claude opens that tab of Settings. A link only shows:
                // it never ticks, queues or starts a build, since any web page could open one.
                .onOpenURL { url in
                    guard url.scheme == "deploycenter" else { return }
                    if let tab = SettingsNav.tab(from: url) { store.openSettings(tab); return }
                    guard url.host == "select",
                          let value = URLComponents(url: url, resolvingAgainstBaseURL: false)?.queryItems?.first(where: { $0.name == "project" })?.value,
                          let req = Store.showRequest(value, items: Array(store.items.values.joined())) else { return }
                    store.pendingShow = req
                }
                // A Spotlight hit: the project is found in the window, never deployed.
                .onContinueUserActivity(CSSearchableItemActionType) { a in
                    guard let key = a.userInfo?[CSSearchableItemActivityIdentifier] as? String,
                          let i = store.items.values.joined().first(where: { Store.key($0) == key }) else { return }
                    store.show(i)
                }
                // A project handed off from the iPhone app: shown, never deployed.
                .onContinueUserActivity(Handoff.type) { a in
                    guard let key = a.userInfo?["project"] as? String,
                          let i = Handoff.item(for: key, in: Array(store.items.values.joined())) else { return }
                    store.show(i)
                }
        }
            .windowResizability(.contentMinSize)
        .commands {
            WindowCommands()
            // Edit → Find (⌘F): the build log's find bar. In the main window ⌘F still goes to the search.
            TextEditingCommands()
            // View menu: demo mode without opening Settings (⌥⌘D is the system's Dock shortcut).
            CommandGroup(after: .toolbar) {
                Toggle(L("Demo Mode", "Demo-Modus"), isOn: $demoMode).keyboardShortcut("d", modifiers: [.command, .shift])
            }
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
        // One project in a window of its own (FEA-124), by Store.key; the main window stays as it is.
        WindowGroup(L("Project", "Projekt"), id: "project", for: String.self) { $key in
            ProjectWindow(store: store, key: key ?? "")
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
    @AppStorage(Tips.key) private var tipOn = true
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
                    store.show(i)
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
            Text(L("\(plural(w.openPRs, "PR", "PRs")) still open", "\(plural(w.openPRs, "PR", "PRs")) noch offen"))
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
        if tipOn { Text(L("Tip: ", "Tipp: ") + Tips.tip()).foregroundStyle(.secondary) }
        // Stopping needs no confirmation in the window either; it is the same cancel as the row's.
        let active = Array(store.items.values.joined()).filter { $0.state.isActive }.sorted { $0.name < $1.name }
        if !active.isEmpty {
            Divider()
            ForEach(active.prefix(8)) { i in
                Button(L("Cancel \(Demo.mask(i.name))", "\(Demo.mask(i.name)) abbrechen")) { store.cancel(i) }
            }
            if active.count > 1 {
                Button(L("Cancel all \(active.count) deploys", "Alle \(active.count) Deploys abbrechen")) { store.cancelAll() }
            }
        }
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

/// Settings → Claude: the text of "Copy for Claude" (FEA-028). Empty = the built-in prompt.
struct PromptTemplateSettings: View {
    @AppStorage(LogTools.promptTemplateKey) private var template = ""

    var body: some View {
        Section(L("“Copy for Claude” prompt", "Prompt für „Für Claude kopieren“")) {
            TextEditor(text: $template).font(.callout.monospaced()).frame(minHeight: 80)
                .accessibilityLabel(L("Prompt template", "Prompt-Vorlage"))
            Text(L("Placeholders: {name} {repo} {ref} {sha} {status} {log}. Empty = the built-in prompt. Secrets in the log stay masked.",
                   "Platzhalter: {name} {repo} {ref} {sha} {status} {log}. Leer = der eingebaute Prompt. Geheimnisse im Log bleiben maskiert."))
                .font(.caption).foregroundStyle(.secondary)
            if !template.isEmpty, !template.contains("{log}") {
                Text(L("Without {log} the prompt has no build log.", "Ohne {log} hat der Prompt kein Build-Log."))
                    .font(.caption).foregroundStyle(Color.warningText)
            }
        }
    }
}

/// The details of one project, followed live from the store. Deploying a commit goes through the
/// same checks as in the sheet; observers only look.
struct ProjectWindow: View {
    @ObservedObject var store: Store
    let key: String

    var body: some View {
        if let i = store.items.values.joined().first(where: { Store.key($0) == key }) {
            ProjectDetail(store: store, item: i, deployCommit: store.observer ? nil : { sha in store.deployOne(i, preview: false, sha: sha) })
                .navigationTitle(Demo.mask(i.name))
        } else {
            Text(L("This project is not in the loaded lists (yet).", "Dieses Projekt ist (noch) nicht in den geladenen Listen."))
                .foregroundStyle(.secondary).padding(40)
        }
    }
}
