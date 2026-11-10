// Deploy Center — The main window: list, banners, costs, setup screens, one row.

import SwiftUI
import AppKit
import Charts
import UserNotifications
import ServiceManagement

// MARK: - Window

extension Color {
    /// Orange for small warning text: darker in light mode, so 10-pt text stays readable (≈ 4.5:1).
    static let warningText = Color(nsColor: NSColor(name: nil) { a in
        a.bestMatch(from: [.darkAqua, .vibrantDark, .accessibilityHighContrastDarkAqua]) != nil
            ? .systemOrange : NSColor(red: 0.70, green: 0.33, blue: 0.0, alpha: 1)
    })
}

/// Commands of the main window, in the View menu: they show ⌘1, ⌘2 … and ⌘F where people look for them.
struct WindowActions {
    /// One per tab in the header, with its digit (see `ProviderTab.shortcuts`).
    struct TabCommand { let title: String; let digit: Int; let run: () -> Void }
    var tabs: [TabCommand]
    var search: () -> Void
    /// The Deploy menu: what otherwise hides under "More" in the footer. Nil = not possible now.
    var history: (() -> Void)? = nil
    var costs: (() -> Void)? = nil
    var messages: (() -> Void)? = nil
    var selectChanged: (() -> Void)? = nil
    var clearSelection: (() -> Void)? = nil
    var reload: (() -> Void)? = nil
    var speak: (() -> Void)? = nil
}
struct WindowActionsKey: FocusedValueKey { typealias Value = WindowActions }
extension FocusedValues {
    var windowActions: WindowActions? {
        get { self[WindowActionsKey.self] }
        set { self[WindowActionsKey.self] = newValue }
    }
}

struct WindowCommands: Commands {
    @FocusedValue(\.windowActions) private var actions
    var body: some Commands {
        CommandGroup(before: .toolbar) {
            // Built from the enabled providers; with only one there is no tab and no command.
            ForEach(actions?.tabs ?? [], id: \.digit) { t in
                Button(t.title, action: t.run).keyboardShortcut(KeyEquivalent(Character(String(t.digit))))
            }
            Button(L("Search", "Suchen")) { actions?.search() }.keyboardShortcut("f").disabled(actions == nil)
            Divider()
        }
        CommandMenu(L("Deploy", "Deploy")) {
            Button(L("Deploy history …", "Deploy-Verlauf …")) { actions?.history?() }
                .keyboardShortcut("y").disabled(actions?.history == nil)
            Button(L("Costs …", "Kosten …")) { actions?.costs?() }.disabled(actions?.costs == nil)
            Button(L("Latest messages …", "Letzte Meldungen …")) { actions?.messages?() }.disabled(actions?.messages == nil)
            Divider()
            // ⌘A and ⌘R stay with the window (⌘A selects text in the search field); here without a key.
            Button(L("Select all changed", "Alle mit Änderungen anhaken")) { actions?.selectChanged?() }.disabled(actions?.selectChanged == nil)
            Button(L("Clear the selection", "Auswahl leeren")) { actions?.clearSelection?() }.disabled(actions?.clearSelection == nil)
            Divider()
            Button(L("Reload", "Neu laden")) { actions?.reload?() }.disabled(actions?.reload == nil)
            Button(L("Read the summary aloud", "Zusammenfassung vorlesen")) { actions?.speak?() }
                .keyboardShortcut("u", modifiers: [.command, .shift]).disabled(actions?.speak == nil)
        }
    }
}

struct ContentView: View {
    @ObservedObject var store: Store
    // The tab and the filter are remembered between launches. The tab is a provider id ("vercel");
    // older versions kept "Vercel", which reads the same lowercased.
    @AppStorage("lastPlatform") private var platformRaw = "vercel"
    @State private var search = ""
    @State private var confirming = false
    @State private var confirmingOff = false
    @State private var confirmingStop = false
    /// The checkbox in the deploy confirmation: only commits whose CI passed go out. Remembered.
    @AppStorage("onlyWhenGreen") private var onlyGreen = false
    /// The deploy window's rule while it is closed, the platforms waiting for "Deploy anyway…", and why.
    @State private var freezeReason: String?
    @State private var frozenScopes: [Platform] = []
    @State private var askingWhy = false
    @State private var whyMissing = false
    @State private var forceText = ""
    /// The platform whose auto-deploy banner was clicked (on "All" both can have one).
    @State private var offPlatform = Platform.vercel
    @AppStorage("onlyChanged") private var savedOnlyChanged = false
    /// Set by the palette, the menu bar or the summary for this session only: the remembered
    /// filter and tab stay what the person chose (a click on the filter or a tab takes over again).
    @State private var onlyChangedNow: Bool?
    @State private var showAllNow: Bool?
    private var onlyChanged: Bool {
        get { onlyChangedNow ?? savedOnlyChanged }
        nonmutating set { savedOnlyChanged = newValue; onlyChangedNow = nil }
    }
    private var showAll: Bool {
        get { showAllNow ?? savedShowAll }
        nonmutating set { savedShowAll = newValue; showAllNow = nil }
    }
    @State private var rollbackItem: Item?
    @FocusState private var searchFocused: Bool
    @State private var unchangedItem: Item?
    @State private var detailItem: Item?
    @AppStorage("showAll") private var savedShowAll = false
    @State private var showCosts = false
    @State private var pathItem: Item?
    @State private var budgetItem: Item?
    @State private var budgetText = ""
    @State private var showMessages = false
    @State private var showJournal = false
    @State private var showFirstStart = false
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @AppStorage(FirstStart.key) private var firstStartDone = false
    @State private var pathText = ""
    @State private var siteText = ""
    @State private var noteItem: Item?
    @State private var noteText = ""
    @State private var logItem: Item?
    @Environment(\.colorSchemeContrast) private var contrast
    @Environment(\.openSettings) private var openSettings
    /// The palette flips the filter that is on screen (through this counter), not only the stored one.
    @ObservedObject private var palette = PaletteCenter.shared
    /// Triggers the person chose to ignore (kept), provider problems closed until they change,
    /// and an update skipped until the next version.
    @AppStorage("ignoredTriggers") private var ignoredTriggers = ""
    @State private var closedIssues: [String] = []
    private var activeTriggers: [Trigger] {
        let ignored = Set(ignoredTriggers.split(separator: "\n").map(String.init))
        return store.triggers.filter { !ignored.contains($0.id) }
    }
    /// A failed deploy's line stays until it is closed; the store clears every line after 5 s.
    @State private var stickyError: Store.Toast?
    /// Banner ground: stronger with "Increase contrast".
    private func ground(_ c: Color, _ o: Double) -> Color { c.opacity(contrast == .increased ? min(1, o * 2.5) : o) }

    /// Read so the window redraws at once when demo mode is switched.
    @AppStorage("demoMode") private var demoMode = false

    /// A project name as the screen may show it.
    private func shown(_ name: String?) -> String { Demo.mask(name ?? "") }
    private var allItems: [Item] { Platform.allCases.flatMap { store.items[$0] ?? [] } }

    // MARK: Tabs, from the enabled providers

    private var providers: [ProviderInfo] { store.enabledProviders }
    private var tabLayout: TabLayout { TabLayout.decide(providers.count) }
    private var tabs: [ProviderTab] { ProviderTab.tabs(providers) }
    /// The tab on screen: the remembered one while it exists, else the first provider.
    private var currentTab: ProviderTab {
        ProviderTab.resolve(showAll ? .all : .provider(platformRaw.lowercased()), in: tabs)
    }
    private func select(_ t: ProviderTab) {
        switch t {
        case .all: showAll = true
        case .provider(let id): showAll = false; platformRaw = id
        }
    }
    private var tabBinding: Binding<ProviderTab> { Binding(get: { currentTab }, set: { select($0) }) }
    /// "All" is on screen (never with a single provider: it has no tabs).
    private var showsAll: Bool { currentTab == .all }
    /// The provider of the tab, or under "All" the one chosen last: its setup screen and errors show.
    private var currentId: String {
        if case .provider(let id) = currentTab { return id }
        let last = platformRaw.lowercased()
        return providers.contains { $0.id == last } ? last : (providers.first?.id ?? "vercel")
    }
    /// The app's loader for that provider; nil for one the app cannot list yet.
    private var platform: Platform? { Platform.allCases.first { $0.cli == currentId } }
    private var currentLabel: String { providers.first { $0.id == currentId }?.label ?? currentId }

    /// "35" projects, or "35 · 9" when 9 of them have changes waiting.
    private static func tabCount(_ store: Store, _ p: Platform) -> String {
        let n = store.items[p]?.count ?? 0, c = store.changedCount(p)
        return c > 0 ? "\(n) · \(c)" : "\(n)"
    }

    /// "All", or the provider's name.
    private func tabName(_ t: ProviderTab) -> String {
        guard case .provider(let id) = t else { return L("All", "Alle") }
        return providers.first { $0.id == id }?.label ?? id
    }

    /// The name with its counts, for the header.
    private func tabTitle(_ t: ProviderTab) -> String {
        guard case .provider(let id) = t, let p = Platform.allCases.first(where: { $0.cli == id }) else { return tabName(t) }
        return tabName(t) + "  " + Self.tabCount(store, p)
    }

    private func tabSpoken(_ t: ProviderTab) -> String {
        guard case .provider(let id) = t, let p = Platform.allCases.first(where: { $0.cli == id }) else { return tabTitle(t) }
        return Self.tabLabel(store, p)
    }

    private var tabCommands: [WindowActions.TabCommand] {
        let keys = ProviderTab.shortcuts(tabs)
        var out: [WindowActions.TabCommand] = []
        for t in tabs {
            if let d = keys[t] { out.append(WindowActions.TabCommand(title: tabName(t), digit: d, run: { select(t) })) }
        }
        return out
    }

    private var waitingSubtitle: String {
        let n = store.waiting.projects
        return n == 0 ? "" : L("\(n) \(n == 1 ? "project waits" : "projects wait")", "\(n) \(n == 1 ? "Projekt wartet" : "Projekte warten")")
    }

    private static func tabLabel(_ store: Store, _ p: Platform) -> String {
        let n = store.items[p]?.count ?? 0, c = store.changedCount(p)
        return L("\(p.rawValue), \(n) projects, \(c) with changes", "\(p.rawValue), \(n) Projekte, \(c) mit Änderungen")
    }

    /// The platforms the list shows: the tab's, or every enabled one under "All".
    private var scopes: [Platform] { showsAll ? providers.compactMap(\.platform) : (platform.map { [$0] } ?? []) }

    private var visible: [Item] {
        var all = scopes.flatMap { store.items[$0] ?? [] }.filter { !store.isHidden($0) }
        if onlyChanged { all = all.filter { $0.hasNewCommits } }
        if !search.isEmpty {
            // In demo mode only the stand-in counts: typing a real name must not find the project.
            all = all.filter { Demo.on ? Demo.mask($0.name).localizedCaseInsensitiveContains(search)
                : $0.name.localizedCaseInsensitiveContains(search) || $0.detail.localizedCaseInsensitiveContains(search)
                || ($0.domain ?? "").localizedCaseInsensitiveContains(search) }
        }
        // Pinned first, then what waits to go live (most commits first), then the rest by name.
        let pins = all.filter { store.isPinned($0) }
        let rest = all.filter { !store.isPinned($0) }
        let byName: (Item, Item) -> Bool = { $0.name.localizedCaseInsensitiveCompare($1.name) == .orderedAscending }
        switch sortOrder {
        case "name": return pins + rest.sorted(by: byName)
        case "recent":
            return pins + rest.sorted { a, b in
                if a.lastAt != b.lastAt { return (a.lastAt ?? .distantPast) > (b.lastAt ?? .distantPast) }
                return byName(a, b)
            }
        case "cost":
            let cost = Dictionary((store.costs?.projects ?? []).map { ($0.name, $0.build) }, uniquingKeysWith: { a, _ in a })
            let c: (Item) -> Double = { $0.platform == .vercel ? (cost[$0.name] ?? 0) : 0 }
            return pins + rest.sorted { a, b in c(a) != c(b) ? c(a) > c(b) : byName(a, b) }
        default: break
        }
        let changed = rest.filter { $0.hasNewCommits && $0.deployable }
            .sorted {
                let a = $0.pendingCommits ?? 0, b = $1.pendingCommits ?? 0
                if a != b { return a > b }
                if ($0.repo ?? "") != ($1.repo ?? "") { return ($0.repo ?? "") < ($1.repo ?? "") }
                return $0.name.localizedCaseInsensitiveCompare($1.name) == .orderedAscending
            }
        let others = rest.filter { !($0.hasNewCommits && $0.deployable) }
        // Projects of one repo stay together, so they can sit under one repo header.
        let usual = pins + RepoGroup.cluster(changed)
            + RepoGroup.cluster(showsAll ? others.sorted(by: byName) : others)
        guard sortOrder == "failed" else { return usual }
        // Failed last deploys first, otherwise as usual.
        let failed = usual.filter { Row.keyFigure($0) == .failed }
        return failed + usual.filter { Row.keyFigure($0) != .failed }
    }

    /// How the list is sorted, remembered. "waiting" is the usual order.
    @AppStorage("sortOrder") private var sortOrder = "waiting"

    private var sortMenu: some View {
        Picker(selection: $sortOrder) {
            Text(L("Waiting first", "Wartende zuerst")).tag("waiting")
            Text(L("Failed first", "Fehler zuerst")).tag("failed")
            Text(L("Last deployed", "Zuletzt deployt")).tag("recent")
            Text(L("Build costs (Vercel)", "Build-Kosten (Vercel)")).tag("cost")
            Text(L("Name", "Name")).tag("name")
        } label: {
            Image(systemName: "arrow.up.arrow.down")
        }
        .pickerStyle(.menu).fixedSize()
        .help(L("Sort the list (pinned stay on top)", "Liste sortieren (Angeheftete bleiben oben)"))
        .accessibilityLabel(L("Sort", "Sortieren"))
    }

    private var selectedAll: [Item] { scopes.flatMap { store.selected($0) } }

    /// A tick; with Shift held, everything between the last tick and this one (as the list shows it).
    @State private var lastTicked: String?
    private func tick(_ item: Item) {
        let key = Store.key(item)
        if NSEvent.modifierFlags.contains(.shift), let last = lastTicked,
           let a = visible.firstIndex(where: { Store.key($0) == last }), let b = visible.firstIndex(where: { Store.key($0) == key }) {
            for i in visible[min(a, b)...max(a, b)] where i.deployable && !i.state.isActive && !i.selected {
                store.toggle(i.platform, i.id)
            }
        } else {
            store.toggle(item.platform, item.id)
        }
        lastTicked = key
    }

    // Split in three: one long chain of modifiers is too much for the type checker of older Xcodes.
    var body: some View { dialogs.commandPalette(store: store) }

    private var chrome: some View {
        VStack(spacing: 0) {
            header
            Divider()
            noticeArea
            summaryBar
            SavingsEntry(store: store)
            content
                // Over the list, not above it: the list does not jump when the line comes and goes.
                .overlay(alignment: .top) {
                    if let msg = store.busyMessage {
                        HStack { ProgressView().controlSize(.small); Text(msg).font(.callout) }
                            .padding(.horizontal, 12).padding(.vertical, 6)
                            .background(Capsule().fill(.regularMaterial))
                            .padding(.top, 8)
                            .transition(.opacity)
                    }
                }
            Divider()
            footer
        }
        .frame(minWidth: 680, minHeight: 540)
        .overlay(alignment: .bottom) {
            if let t = store.toast ?? stickyError {
                HStack(spacing: 10) {
                    Label(Demo.scrub(t.text, items: allItems), systemImage: t.ok ? "checkmark.circle.fill" : "xmark.octagon.fill")
                    if let label = t.undoLabel, let undo = t.undo {
                        Button(label) { undo(); store.toast = nil }.buttonStyle(.link)
                    }
                    Button { store.toast = nil; stickyError = nil } label: { Image(systemName: "xmark") }
                        .buttonStyle(.borderless).help(L("Close", "Schließen")).accessibilityLabel(L("Close", "Schließen"))
                }
                    .font(.callout.weight(.medium))
                    .padding(.horizontal, 14).padding(.vertical, 8)
                    .background(Capsule().fill(.regularMaterial))
                    .overlay(Capsule().stroke(t.ok ? Color.green.opacity(0.5) : Color.red.opacity(0.5)))
                    // The pointer on it holds it, so a long message can be read to the end.
                    .onHover { store.holdToast($0) }
                    .padding(.bottom, 72)
                    .transition(.move(edge: .bottom).combined(with: .opacity))
                    // Esc closes it, like any passing message.
                    .background {
                        Button("") { store.toast = nil; stickyError = nil }
                            .keyboardShortcut(.cancelAction)
                            .opacity(0).frame(width: 0, height: 0).accessibilityHidden(true)
                    }
            }
        }
        .onChange(of: store.toast) { _, t in
            guard let t else { return }
            // Said out loud once, instead of a region that "updates frequently".
            AccessibilityNotification.Announcement(Demo.scrub(t.text, items: allItems)).post()
            stickyError = t.ok ? nil : t
        }
        // Mission Control and the window title say what waits; the Dock badge is set by the app
        // delegate, so it stays current with the window closed.
        .navigationSubtitle(waitingSubtitle)
        // Not while a sheet is open: there ⌘F belongs to the build log's find bar.
        .focusedSceneValue(\.windowActions, logItem != nil || detailItem != nil || showJournal || showCosts ? nil
                           : WindowActions(tabs: tabCommands, search: { searchFocused = true },
                                           history: { showJournal = true },
                                           costs: store.costs == nil ? nil : { showCosts = true },
                                           messages: store.messages.isEmpty ? nil : { showMessages = true },
                                           selectChanged: waitsForFreshList ? nil : { selectAllCommand() },
                                           clearSelection: selectedAll.isEmpty ? nil : { scopes.forEach { store.clearSelection($0) } },
                                           reload: { reloadNow() }, speak: { Speech.say(store.spokenSummary) }))
        .animation(reduceMotion ? nil : .easeOut(duration: 0.2), value: store.toast)
    }

    private var withSheets: some View {
        chrome
        .sheet(item: $logItem) { item in BuildLog(store: store, item: item) }
        .sheet(isPresented: $showJournal) { JournalView(costs: store.costs) }
        .sheet(isPresented: $showFirstStart) { FirstStartView(store: store) }
        // Someone who used the app before this version has a history: no first start for them.
        .onAppear { if !firstStartDone, UserDefaults.standard.object(forKey: "firstStartChecked") == nil {
            UserDefaults.standard.set(true, forKey: "firstStartChecked")
            if !Journal.load(limit: 1).isEmpty || UserDefaults.standard.object(forKey: "lastPlatform") != nil { firstStartDone = true }
        } }
        .onChange(of: Platform.allCases.map { store.autoOn($0).count }.reduce(0, +) + (firstStartDone ? 0 : 1_000_000)) { _, _ in
            if FirstStart.due(done: firstStartDone, autoOn: Platform.allCases.map { store.autoOn($0).count }.reduce(0, +)), !Demo.on { showFirstStart = true }
        }
        .sheet(isPresented: $showCosts) {
            if let c = store.costs { CostsSheet(costs: c) }
            else {
                // The costs went away while the sheet opened (a reload failed): say so, never an empty sheet.
                VStack(spacing: 12) {
                    Text(L("No cost data right now", "Gerade keine Kostendaten")).font(.headline)
                    Text(L("Vercel's billing could not be read. Reload and try again.", "Vercels Abrechnung war nicht lesbar. Neu laden und nochmal versuchen."))
                        .font(.caption).foregroundStyle(.secondary)
                    Button(L("Done", "Fertig")) { showCosts = false }.keyboardShortcut(.defaultAction)
                }
                .padding(24).frame(width: 360)
            }
        }
        .sheet(item: $detailItem) { item in ProjectDetail(store: store, item: item, deployCommit: store.observer ? nil : { sha in store.deployOne(item, preview: false, sha: sha) },
                                                         // After the detail sheet is gone, so the log can take its place.
                                                         openLog: { DispatchQueue.main.asyncAfter(deadline: .now() + 0.35) { logItem = item } })
                // The open project can be continued on the iPhone (Handoff); not in demo mode, which hides names.
                .userActivity(Handoff.type, isActive: !Demo.on) { a in
                    a.title = item.name; a.userInfo = ["project": Handoff.key(item)]
                    a.isEligibleForHandoff = true; a.isEligibleForSearch = false
                }
        }
        .onChange(of: store.pendingDeployAll) { _, go in
            guard go else { return }
            store.pendingDeployAll = false
            showAllNow = true; onlyChangedNow = true
            // Hidden projects stay out, as in the list.
            for i in allItems where i.deployable && i.hasNewCommits && !i.state.isActive && !i.selected && !store.isHidden(i) {
                store.toggle(i.platform, i.id)
            }
            if !selectedAll.isEmpty { confirming = true }
        }
    }

    private var dialogs: some View {
        withSheets
        .alert(L("Check after deploy", "Prüfung nach dem Deploy"), isPresented: Binding(get: { pathItem != nil }, set: { if !$0 { pathItem = nil } })) {
            TextField("/health, /api/ping", text: $pathText)
            TextField(L("Text the page must show (optional)", "Text, den die Seite zeigen muss (optional)"), text: $siteText)
            Button(L("Cancel", "Abbrechen"), role: .cancel) { pathItem = nil }
            Button(L("Save", "Speichern")) { if let i = pathItem { store.setHealthPath(i, pathText); store.setSiteText(i, siteText) }; pathItem = nil }
        } message: {
            Text(L("These paths (comma-separated, up to five) are asked once \(shown(pathItem?.name)) is live, instead of the front page. Empty = front page. A missing text only warns.",
                   "Diese Pfade (mit Komma getrennt, bis zu fünf) werden abgefragt, sobald \(shown(pathItem?.name)) live ist, statt der Startseite. Leer = Startseite. Fehlt der Text, gibt es nur eine Warnung."))
        }
        .alert(L("Monthly budget", "Monatsbudget"), isPresented: Binding(get: { budgetItem != nil }, set: { if !$0 { budgetItem = nil } })) {
            TextField("USD", text: $budgetText)
            Button(L("Cancel", "Abbrechen"), role: .cancel) { budgetItem = nil }
            Button(L("Save", "Speichern")) {
                if let i = budgetItem { store.setProjectBudget(i, Double(budgetText.replacingOccurrences(of: ",", with: "."))) }
                budgetItem = nil
            }
        } message: {
            Text(L("USD a month for the builds of \(shown(budgetItem?.name)); a warning comes at 80 % of it, at the week's pace. Empty = none.",
                   "USD im Monat für die Builds von \(shown(budgetItem?.name)); eine Warnung kommt bei 80 % davon, beim Tempo der Woche. Leer = keins."))
        }
        .alert(L("Note", "Notiz"), isPresented: Binding(get: { noteItem != nil }, set: { if !$0 { noteItem = nil } })) {
            TextField(L("e.g. only after the release mail", "z. B. erst nach der Release-Mail"), text: $noteText)
            Button(L("Cancel", "Abbrechen"), role: .cancel) { noteItem = nil }
            Button(L("Save", "Speichern")) { if let i = noteItem { store.setNote(i, noteText) }; noteItem = nil }
        } message: {
            Text(L("Shown under \(shown(noteItem?.name)). Kept on this Mac only.", "Steht unter \(shown(noteItem?.name)). Bleibt nur auf diesem Mac."))
        }
        // A write to the remembered filter or tab from elsewhere (the menu bar) wins over a
        // session-only setting; the palette's toggle flips what is shown.
        .onChange(of: savedOnlyChanged) { _, _ in onlyChangedNow = nil }
        .onChange(of: savedShowAll) { _, _ in showAllNow = nil }
        .onChange(of: palette.filterToggles) { _, _ in onlyChanged.toggle() }
        .onChange(of: store.pendingSearch) { _, name in
            guard let name else { return }
            showAllNow = true; onlyChangedNow = false; search = Demo.mask(name); store.pendingSearch = nil
        }
        .alert(L("Nothing new to deploy", "Nichts Neues zu deployen"),
               isPresented: Binding(get: { unchangedItem != nil }, set: { if !$0 { unchangedItem = nil } })) {
            Button(L("Cancel", "Abbrechen"), role: .cancel) { unchangedItem = nil }
            Button(L("Build anyway", "Trotzdem bauen")) { if let i = unchangedItem { store.deployOne(i, preview: false) }; unchangedItem = nil }
        } message: {
            Text(L("\(shown(unchangedItem?.name)) is already on the newest commit. A build costs build minutes and changes nothing.",
                   "\(shown(unchangedItem?.name)) ist schon auf dem neuesten Stand. Ein Build kostet Build-Minuten und ändert nichts."))
        }
        .task {
            store.boot()
            // The search field would take the keyboard (and the space bar) at once; ⌘F still gets there.
            try? await Task.sleep(nanoseconds: 200_000_000)
            if search.isEmpty { NSApp.keyWindow?.makeFirstResponder(nil) }
        }
        // On a view of its own: the checkbox below belongs to this alert only, not to the others here.
        .background {
            Color.clear
                .alert(L("Put this live now?", "Jetzt live schalten?"), isPresented: $confirming) {
                    Button(L("Cancel", "Abbrechen"), role: .cancel) {}
                    Button(L("Deploy", "Deployen")) { startDeploy() }
                } message: {
                    // At most 12 lines, so the dialog does not grow past the screen.
                    // Under "All" the same name can be on two platforms: say which.
                    Text(selectedAll.prefix(12).map { i in
                            Demo.mask(i.name) + (showsAll ? " (\(i.platform.rawValue))" : "")
                            + ((i.pendingCommits ?? 0) > 0 ? " – " + Row.waitingText(i) : "") }.joined(separator: "\n")
                         + (selectedAll.count > 12 ? "\n" + L("and \(selectedAll.count - 12) more", "und \(selectedAll.count - 12) weitere") : "")
                         + "\n\n" + L("The newest commit on GitHub goes live.",
                                       "Der neueste Stand von GitHub geht live.")
                         + unchangedNote
                         + Store.costNote(perBuild: selectedAll.map { $0.platform == .vercel ? store.costs?.perBuild($0.name) : nil },
                                          month: store.monthPace, budget: UserDefaults.standard.double(forKey: "monthlyBudget")))
                }
                .dialogSuppressionToggle(LocalizedStringKey(L("Only when checks are green", "Nur wenn die Checks grün sind")), isSuppressed: $onlyGreen)
        }
        .alert(L("The deploy window is closed", "Das Deploy-Fenster ist zu"),
               isPresented: Binding(get: { freezeReason != nil }, set: { if !$0 { freezeReason = nil } })) {
            Button(L("Cancel", "Abbrechen"), role: .cancel) { freezeReason = nil }
            Button(L("Deploy anyway…", "Trotzdem deployen …")) {
                freezeReason = nil; forceText = ""; whyMissing = false
                DispatchQueue.main.async { askingWhy = true }   // one alert after the other
            }
        } message: {
            Text(L("No deploys now: \(freezeReason ?? ""). The times are in Settings → Deploy & guard → Deploy window.",
                   "Gerade keine Deploys: \(freezeReason ?? ""). Die Zeiten stehen unter Einstellungen → Deploy & Wächter → Deploy-Fenster."))
        }
        .alert(L("Why deploy now?", "Warum jetzt deployen?"), isPresented: $askingWhy) {
            TextField(L("e.g. hotfix for the login page", "z. B. Hotfix für die Login-Seite"), text: $forceText)
            Button(L("Cancel", "Abbrechen"), role: .cancel) {}
            Button(L("Deploy", "Deployen")) {
                // The script takes a reason starting with "-" for an option.
                let why = String(forceText.trimmingCharacters(in: .whitespacesAndNewlines).drop { $0 == "-" || $0 == " " })
                // An empty reason is not dropped silently: the question comes back, with a hint.
                guard !why.isEmpty else { whyMissing = true; DispatchQueue.main.async { askingWhy = true }; return }
                whyMissing = false
                frozenScopes.forEach { store.deploySelected($0, whenGreen: onlyGreen, force: why) }
            }
        } message: {
            Text((whyMissing ? L("A reason is needed to deploy now. ", "Ohne Grund kein Deploy. ") : "")
                 + L("The reason is written to the deploy history.", "Der Grund steht danach im Deploy-Verlauf."))
        }
        .alert(L("Roll back production?", "Live zurückrollen?"),
               isPresented: Binding(get: { rollbackItem != nil }, set: { if !$0 { rollbackItem = nil } })) {
            Button(L("Cancel", "Abbrechen"), role: .cancel) { rollbackItem = nil }
            Button(L("Roll back", "Zurückrollen"), role: .destructive) { if let i = rollbackItem { store.rollback(i) }; rollbackItem = nil }
        } message: {
            Text(L("\(shown(rollbackItem?.name)) goes back to the deploy that was live before this one.",
                   "\(shown(rollbackItem?.name)) geht zurück auf den Stand, der davor live war."))
        }
        .alert(stopTitle, isPresented: $confirmingStop) {
            Button(L("Keep running", "Weiterlaufen lassen"), role: .cancel) {}
            Button(L("Stop all", "Alles abbrechen"), role: .destructive) { store.cancelAll() }
        } message: {
            Text(L("Running builds are cancelled at the platform, queued ones do not start.",
                   "Laufende Builds werden beim Anbieter abgebrochen, wartende starten nicht."))
        }
        .alert(L("Turn off auto-deploy?", "Auto-Deploy ausschalten?"), isPresented: $confirmingOff) {
            Button(L("Cancel", "Abbrechen"), role: .cancel) {}
            Button(L("Turn off", "Ausschalten")) { Task { await store.turnOffAutoDeploy(offPlatform) } }
        } message: {
            Text(store.autoOn(offPlatform).prefix(12).map { Demo.mask($0.name) }.joined(separator: "\n")
                 + (store.autoOn(offPlatform).count > 12 ? "\n" + L("and \(store.autoOn(offPlatform).count - 12) more", "und \(store.autoOn(offPlatform).count - 12) weitere") : "")
                 + "\n\n"
                 + (offPlatform == .vercel
                    ? L("The Git connection is removed (the repo is remembered here). A push will no longer build. Reconnect any time in the Vercel dashboard.",
                        "Die Git-Verbindung wird getrennt (das Repo merkt sich die App). Ein Push baut nichts mehr. Wieder verbinden geht jederzeit im Vercel-Dashboard.")
                    : L("Auto-deploy is set to Off. A push will no longer build.",
                        "Auto-Deploy wird auf Off gestellt. Ein Push baut nichts mehr.")))
        }
    }

    private var header: some View {
        HStack(spacing: 12) {
            tabPicker

            if demoMode {
                // Stand-in names look real: the badge says they are not, and a click ends it.
                Button { demoMode = false } label: {
                    Text("Demo").font(.caption.weight(.bold)).padding(.horizontal, 7).padding(.vertical, 2)
                        .background(Capsule().fill(Color.purple.opacity(0.2)))
                }
                .buttonStyle(.plain)
                .help(L("Demo mode: names are stand-ins. Click to turn it off.", "Demo-Modus: Namen sind Platzhalter. Klick schaltet ihn aus."))
                .accessibilityLabel(L("Demo mode on, turn off", "Demo-Modus an, ausschalten"))
            }

            TextField(L("Search", "Suchen"), text: $search).textFieldStyle(.roundedBorder)
                .frame(minWidth: 110)
                .layoutPriority(1)
                .focused($searchFocused)
                .onExitCommand { search = ""; searchFocused = false }

            Toggle(isOn: Binding(get: { onlyChanged }, set: { onlyChanged = $0 })) {
                Text(L("Changed only", "Nur mit Änderungen") + " (\(scopes.map { store.changedCount($0) }.reduce(0, +)))")
            }
            .toggleStyle(.button)
            .fixedSize()
            .help(L("Only projects with a commit on GitHub that is not live yet",
                    "Nur Projekte mit einem Commit auf GitHub, der noch nicht live ist"))

            sortMenu

            let busy = scopes.contains { store.loading.contains($0) }
            Button { reloadNow() } label: {
                if busy { ProgressView().controlSize(.small) }
                else { Image(systemName: "arrow.clockwise") }
            }
            .accessibilityLabel(L("Reload", "Neu laden"))
            .accessibilityValue(reloadStamps)
            // When the lists were read: here, and not as text in the header.
            .help(L("Reload (⌘R)", "Neu laden (⌘R)") + (reloadStamps.isEmpty ? "" : "\n" + reloadStamps))
            .keyboardShortcut("r")
            .disabled(busy)
        }
        .padding(12)
    }

    /// The platforms at the same time, not one after the other; then the extras.
    private func reloadNow() {
        let chosen = scopes
        guard !chosen.contains(where: { store.loading.contains($0) }) else { return }
        Task {
            await withTaskGroup(of: Void.self) { g in for p in chosen { g.addTask { await store.load(p) } } }
            await store.loadExtras()
        }
    }

    /// "Updated 14:05", per platform under "All", and whether it is a saved copy.
    private var reloadStamps: String {
        scopes.compactMap { p in
            store.loadedAt[p].map {
                (showsAll ? p.rawValue + ": " : "") + L("updated ", "aktualisiert ") + $0.formatted(date: .omitted, time: .shortened)
                    + (store.fromCache.contains(p) ? L(" (saved copy, not current)", " (gespeicherte Kopie, nicht aktuell)") : "")
            }
        }.joined(separator: "\n")
    }

    /// No tabs for one provider, a segmented control for two or three, a menu from four on.
    @ViewBuilder private var tabPicker: some View {
        let keys = ProviderTab.shortcuts(tabs).values.sorted()
        let hint = L("Projects · of them with changes waiting", "Projekte · davon mit wartenden Änderungen")
            + (keys.isEmpty ? "" : " (" + keys.map { "⌘\($0)" }.joined(separator: ", ") + ")")
        switch tabLayout {
        case .hidden:
            EmptyView()
        case .segmented:
            Picker(L("Platform", "Plattform"), selection: tabBinding) {
                ForEach(tabs, id: \.self) { t in Text(tabTitle(t)).tag(t).accessibilityLabel(tabSpoken(t)) }
            }
            .pickerStyle(.segmented).labelsHidden().fixedSize()
            .help(hint)
        case .menu:
            Picker(L("Platform", "Plattform"), selection: tabBinding) {
                ForEach(tabs, id: \.self) { t in Text(tabTitle(t)).tag(t).accessibilityLabel(tabSpoken(t)) }
            }
            .pickerStyle(.menu).labelsHidden().fixedSize()
            .help(hint)
        }
    }

    /// Problems and offers above the list, most important first. Only the first is always shown;
    /// the others fold away, so the list keeps its room.
    enum Notice: Hashable { case trigger, loadFailed(Platform), setup(Platform), auto(Platform), allowance, github, tools, provider, claude }
    @AppStorage("noticesExpanded") private var noticesExpanded = false
    @AppStorage(ClaudeNudge.wantedKey) private var claudeNudge = false
    @AppStorage(ClaudeNudge.dismissedKey) private var claudeNudgeDismissed = false

    private var notices: [Notice] {
        var out: [Notice] = []
        if !activeTriggers.isEmpty { out.append(.trigger) }
        // Per platform, so on "All" a Vercel problem does not hide Render's list (and the other way round).
        for p in scopes where store.lastLoadError[p] != nil && !errorFillsWindow(p) { out.append(.loadFailed(p)) }
        if showsAll { for p in scopes where setupNeeded(p) != nil { out.append(.setup(p)) } }
        for p in scopes where !store.autoOn(p).isEmpty { out.append(.auto(p)) }
        if !store.activeAllowances.isEmpty { out.append(.allowance) }
        if store.doctor.map({ $0.githubCli && $0.githubLoggedIn == false }) == true || (store.githubBudget?.remaining ?? .max) < 300 { out.append(.github) }
        if !(store.doctor?.missingTools.isEmpty ?? true) { out.append(.tools) }
        if !store.providerIssues.isEmpty && store.providerIssues != closedIssues { out.append(.provider) }
        if claudeNudge && !claudeNudgeDismissed { out.append(.claude) }
        return out
    }

    /// 2 = an alarm, 1 = a warning, 0 = information.
    private func noticeWeight(_ n: Notice) -> Int {
        switch n {
        case .trigger: return 2
        case .loadFailed, .auto, .github, .tools, .provider, .allowance: return 1
        case .setup, .claude: return 0
        }
    }

    private func noticeTitle(_ n: Notice) -> String {
        switch n {
        case .trigger: return L("other build triggers", "andere Build-Auslöser")
        case .loadFailed(let p): return L("\(p.rawValue) not loaded", "\(p.rawValue) nicht geladen")
        case .setup(let p): return L("\(p.rawValue) not connected", "\(p.rawValue) nicht verbunden")
        case .auto(let p): return L("auto-deploy on (\(p.rawValue))", "Auto-Deploy an (\(p.rawValue))")
        case .allowance: return L("auto-deploy allowed for a while", "Auto-Deploy vorübergehend erlaubt")
        case .github: return "GitHub"
        case .tools: return L("tools missing", "Werkzeuge fehlen")
        case .provider: return L("provider problem", "Störung beim Anbieter")
        case .claude: return "Claude"
        }
    }

    @ViewBuilder private func notice(_ n: Notice) -> some View {
        switch n {
        case .trigger: triggerBanner
        case .loadFailed(let p): loadFailedBanner(p)
        case .setup(let p): setupBanner(p)
        case .auto(let p): autoBanner(p)
        case .allowance: AllowanceBanner(store: store, allItems: allItems)
        case .github: githubBanner
        case .tools: toolsBanner
        case .provider: providerBanner
        case .claude: ClaudeNudgeLine()
        }
    }

    @ViewBuilder private var noticeArea: some View {
        let all = notices
        if let first = all.first {
            VStack(spacing: 0) {
                notice(first)
                if all.count > 1 {
                    if noticesExpanded {
                        ForEach(all.dropFirst(), id: \.self) { n in Divider(); notice(n) }
                    }
                    Divider()
                    Button { withAnimation(reduceMotion ? nil : .easeOut(duration: 0.15)) { noticesExpanded.toggle() } } label: {
                        HStack(spacing: 6) {
                            Image(systemName: noticesExpanded ? "chevron.up" : "chevron.down")
                            // Folded away, an alarm still looks like one: the worst hidden notice sets the symbol.
                            if !noticesExpanded {
                                let worst = all.dropFirst().map(noticeWeight).max() ?? 0
                                if worst > 0 {
                                    Image(systemName: worst > 1 ? "exclamationmark.triangle.fill" : "exclamationmark.circle.fill")
                                        .foregroundStyle(worst > 1 ? Color.red : Color.orange)
                                }
                                Text("\(all.count - 1)").font(.caption2.weight(.bold).monospacedDigit())
                                    .padding(.horizontal, 5).background(Capsule().fill(Color.secondary.opacity(0.2)))
                            }
                            Text(noticesExpanded ? L("Show fewer notices", "Weniger Hinweise zeigen")
                                 : L("\(all.count - 1) more: ", "\(all.count - 1) weitere: ") + all.dropFirst().map(noticeTitle).joined(separator: " · "))
                                .lineLimit(1)
                            Spacer()
                        }
                        .font(.caption).foregroundStyle(.secondary)
                        .padding(.horizontal, 12).padding(.vertical, 5).contentShape(Rectangle())
                    }
                    .buttonStyle(.plain)
                    .accessibilityHint(L("Shows or hides the other notices", "Zeigt oder verbirgt die anderen Hinweise"))
                }
            }
        }
    }

    @ViewBuilder private var triggerBanner: some View {
        let triggers = activeTriggers
        if !triggers.isEmpty {
            HStack(alignment: .top, spacing: 10) {
                Image(systemName: "exclamationmark.triangle.fill").font(.title2).foregroundStyle(.red)
                VStack(alignment: .leading, spacing: 3) {
                    Text(L("Something else still starts builds", "Etwas anderes startet noch Builds")).font(.headline)
                    ForEach(triggers.prefix(6)) { tr in
                        HStack(spacing: 6) {
                            Text("• \(Self.triggerName(tr.kind)): " + Demo.scrub("\(tr.where) – \(tr.detail)", items: allItems)).font(.caption).textSelection(.enabled)
                            // Known and wanted (a nightly workflow, say): it stops being an alarm.
                            Button(L("Ignore", "Ignorieren")) { ignoredTriggers += (ignoredTriggers.isEmpty ? "" : "\n") + tr.id }
                                .buttonStyle(.link).font(.caption)
                        }
                    }
                    if triggers.count > 6 {
                        Text(L("and \(triggers.count - 6) more", "und \(triggers.count - 6) weitere")).font(.caption).foregroundStyle(.secondary)
                    }
                }
                Spacer()
            }
            .padding(12).background(ground(.red, 0.1))
        }
    }

    /// A status page of Vercel, Render or GitHub reports a problem.
    @ViewBuilder private var providerBanner: some View {
        if !store.providerIssues.isEmpty {
            HStack(spacing: 10) {
                Image(systemName: "bolt.horizontal.circle.fill").foregroundStyle(.orange)
                Text(L("Problem at the provider: ", "Störung beim Anbieter: ") + store.providerIssues.joined(separator: " · "))
                    .font(.caption).textSelection(.enabled)
                Spacer()
                ForEach(Self.statusPages.filter { p in store.providerIssues.contains { $0.hasPrefix(p.0) } }, id: \.0) { p in
                    Button(L("\(p.0) status", "Status \(p.0)")) { NSWorkspace.shared.open(URL(string: p.1)!) }.buttonStyle(.link).font(.caption)
                }
                Button { closedIssues = store.providerIssues } label: { Image(systemName: "xmark") }
                    .buttonStyle(.borderless).help(L("Close until it changes", "Schließen, bis sich etwas ändert"))
                    .accessibilityLabel(L("Close", "Schließen"))
            }
            .padding(.horizontal, 12).padding(.vertical, 6).background(ground(.orange, 0.08))
        }
    }

    static let statusPages = [("Vercel", "https://www.vercel-status.com"), ("Render", "https://status.render.com"),
                              ("GitHub", "https://www.githubstatus.com")]

    static func triggerName(_ k: String) -> String {
        switch k {
        case "workflow": return L("GitHub workflow deploys", "GitHub-Workflow deployt")
        case "vercel-build": return L("Vercel build from Git", "Vercel-Build von Git")
        case "render-build": return L("Render build from push", "Render-Build durch Push")
        case "render-blueprint": return L("Render Blueprint auto-sync", "Render-Blueprint Auto-Sync")
        default: return unknownCode(k, L("build trigger", "Build-Auslöser"))
        }
    }

    /// Ticked projects that are already on their newest commit: building them costs and changes nothing.
    /// What the confirmation's Deploy does: inside a closed deploy window it asks first.
    private func startDeploy() {
        let chosen = scopes, green = onlyGreen, count = selectedAll.count
        Task {
            if OwnerCheck.needed(projects: count),
               !(await OwnerCheck.confirm(L("put \(count) projects live", "\(count) Projekte live schalten"))) { return }
            if let w = await store.deployWindow(), w.denied {
                frozenScopes = chosen; freezeReason = w.reason ?? ""; return
            }
            chosen.forEach { store.deploySelected($0, whenGreen: green) }
        }
    }

    private var stopTitle: String {
        let n = allItems.filter { $0.state.isActive }.count
        return L("Stop \(plural(n, "deploy", "deploys"))?", "\(plural(n, "Deploy", "Deploys")) abbrechen?")
    }

    private var unchangedNote: String {
        let same = selectedAll.filter { !$0.hasNewCommits && $0.headSha != nil }.map { Demo.mask($0.name) }
        guard !same.isEmpty else { return "" }
        return "\n\n" + L("Already up to date, builds anyway: ", "Schon aktuell, baut trotzdem: ") + same.joined(separator: ", ")
    }

    /// `deploys doctor` says perl or curl is missing: without perl no log goes to Claude (it cannot
    /// be masked), without curl no platform answers.
    @ViewBuilder private var toolsBanner: some View {
        let missing = store.doctor?.missingTools ?? []
        if !missing.isEmpty {
            HStack(spacing: 10) {
                Image(systemName: "wrench.and.screwdriver").foregroundStyle(.orange)
                Text(missing.contains("curl")
                     ? L("curl is missing on this Mac, so deploys cannot reach the platforms. Install it (Xcode Command Line Tools or Homebrew).",
                         "curl fehlt auf diesem Mac, darum erreicht deploys die Plattformen nicht. Installiere es (Xcode Command Line Tools oder Homebrew).")
                     : L("perl is missing on this Mac, so Claude and autofix send nothing: secrets in logs cannot be masked.",
                         "perl fehlt auf diesem Mac, darum senden Claude und Autofix nichts: Geheimnisse in Logs lassen sich nicht maskieren."))
                    .font(.caption).fixedSize(horizontal: false, vertical: true)
                Spacer()
            }
            .padding(.horizontal, 12).padding(.vertical, 6).background(ground(.orange, 0.08))
        }
    }

    /// Without a GitHub login, or with its hourly budget spent, the counts are missing. Say why.
    @ViewBuilder private var githubBanner: some View {
        if let d = store.doctor, d.githubCli, d.githubLoggedIn == false {
            HStack(spacing: 10) {
                Image(systemName: "person.crop.circle.badge.exclamationmark").foregroundStyle(.orange)
                Text(L("GitHub CLI is not logged in, so the waiting commits and PRs cannot be counted. In Terminal: gh auth login",
                       "Die GitHub-CLI ist nicht angemeldet, darum fehlen die Zahlen wartender Commits und PRs. Im Terminal: gh auth login"))
                    .font(.caption).textSelection(.enabled)
                Spacer()
                CopyButton(title: L("Copy gh auth login", "gh auth login kopieren")) { "gh auth login" }.controlSize(.small)
            }
            .padding(.horizontal, 12).padding(.vertical, 6).background(ground(.orange, 0.08))
        } else if let b = store.githubBudget, b.remaining < 300 {
            HStack(spacing: 10) {
                Image(systemName: "gauge.with.dots.needle.0percent").foregroundStyle(.orange)
                Text(L("GitHub's hourly budget is nearly spent (\(b.remaining) of \(b.limit) left). Counts pause until ",
                       "GitHubs Stunden-Kontingent ist fast aufgebraucht (\(b.remaining) von \(b.limit) übrig). Die Zahlen pausieren bis ")
                     + Date(timeIntervalSince1970: b.reset).formatted(date: .omitted, time: .shortened) + ".")
                    .font(.caption)
                Spacer()
            }
            .padding(.horizontal, 12).padding(.vertical, 6).background(ground(.orange, 0.08))
        }
    }

    /// One line over the list: what waits to go live (and the saving, when known), and the build costs
    /// as one number that opens the chart.
    @ViewBuilder private var summaryBar: some View {
        // The tab's own count; under "All" the sum of its platforms.
        let w = store.waiting(for: scopes)
        // On a tab: what waits on the other platforms, so "everything is live" is never said wrongly.
        let elsewhere = showsAll ? 0 : store.waiting.projects - w.projects
        let costs = scopes.contains(.vercel) ? store.costs : nil
        let saved = costs?.saved(today: CostsSheet.today())
        let line = waitingSummary(w, saved: saved, elsewhere: elsewhere, here: platform?.rawValue)
        if w.projects > 0 || elsewhere > 0 || w.openPRs > 0 || costs != nil {
            HStack(spacing: 8) {
                if w.projects > 0 || elsewhere > 0 {
                    // The tab stays when it has changes of its own; else "All" shows where they are.
                    Button {
                        onlyChangedNow = true; search = ""
                        if scopes.allSatisfy({ store.changedCount($0) == 0 }) { showAllNow = true }
                    } label: {
                        // The chevron says it is a button, like the costs on the right.
                        HStack(spacing: 4) {
                            Text(line).font(.callout.weight(.medium))
                            Image(systemName: "chevron.right").font(.caption2).foregroundStyle(.secondary)
                        }
                        .contentShape(Rectangle())
                    }
                    .buttonStyle(.plain)
                    .help(summaryHelp(w))
                    .accessibilityHint(L("Shows the projects with changes", "Zeigt die Projekte mit Änderungen"))
                } else {
                    Text(line).font(.callout.weight(.medium)).foregroundStyle(.secondary)
                        .help(summaryHelp(w))
                }
                Spacer()
                if let c = costs {
                    Button { showCosts = true } label: {
                        HStack(spacing: 4) {
                            Text(L("Builds, 7 days", "Builds, 7 Tage")).foregroundStyle(.secondary)
                            Text(c.week, format: .currency(code: "USD")).monospacedDigit()
                            Image(systemName: "chevron.right").font(.caption2).foregroundStyle(.secondary)
                        }
                        .contentShape(Rectangle())
                    }
                    .buttonStyle(.plain).font(.callout)
                    .help(L("Vercel build costs of the last 7 days. Click for the chart.", "Vercel-Build-Kosten der letzten 7 Tage. Klick zeigt das Diagramm."))
                    .accessibilityLabel(L("Vercel builds, last 7 days: ", "Vercel-Builds, letzte 7 Tage: ") + c.week.formatted(.currency(code: "USD")))
                    .accessibilityHint(L("Opens the costs", "Öffnet die Kosten"))
                }
            }
            .padding(.horizontal, 12).padding(.vertical, 7)
            .background(ground(.secondary, 0.06))
        }
    }

    /// The rest of what the old banner said, for the tooltip.
    private func summaryHelp(_ w: Store.Waiting) -> String {
        var lines: [String] = []
        if w.projects > 0 {
            lines.append(L("\(w.commits) \(w.commits == 1 ? "commit" : "commits") in \(w.projects) \(w.projects == 1 ? "project" : "projects"), merged on GitHub and not live",
                           "\(w.commits) \(w.commits == 1 ? "Commit" : "Commits") in \(w.projects) \(w.projects == 1 ? "Projekt" : "Projekten"), auf GitHub gemergt und nicht live"))
            let all = store.waiting.projects
            if !showsAll, let p = platform, all != w.projects {
                lines.append(L("On \(p.rawValue); \(all) over all platforms", "Auf \(p.rawValue); \(all) über alle Plattformen"))
            }
        }
        if w.openPRs > 0 {
            lines.append(L("\(w.openPRs) more \(w.openPRs == 1 ? "PR is" : "PRs are") still open (not merged)",
                           "\(w.openPRs) weitere \(w.openPRs == 1 ? "PR ist" : "PRs sind") noch offen (nicht gemergt)"))
        }
        if store.costs?.saved(today: CostsSheet.today()) != nil {
            lines.append(L("Saved: build costs on the whole days since auto-deploy was turned off, against the days before",
                           "Gespart: Build-Kosten der ganzen Tage, seit Auto-Deploy aus ist, gegenüber den Tagen davor"))
        } else if store.costs?.saving(today: CostsSheet.today()) != nil {
            // Measured, but under 50 cents or more than before: said, not left out.
            lines.append(L("Since auto-deploy was turned off: no saving in build costs yet",
                           "Seit Auto-Deploy aus ist: noch keine Ersparnis bei den Build-Kosten"))
        }
        if w.projects > 0 { lines.append(L("Click to show them", "Klicken zeigt sie")) }
        return lines.joined(separator: "\n")
    }

    /// What a platform still needs before its list can be read; nil when it is ready.
    private func setupNeeded(_ p: Platform) -> String? {
        guard let d = store.doctor, d.jq else { return nil }
        switch p {
        case .vercel:
            if d.vercelCli && !d.vercelApi { return L("The Vercel CLI is too old.", "Die Vercel-CLI ist zu alt.") }
            if !d.vercelLoggedIn { return L("Vercel is not connected.", "Vercel ist nicht verbunden.") }
        case .render:
            if !d.renderKey { return L("Render is not connected (no API key).", "Render ist nicht verbunden (kein API-Key).") }
        }
        return nil
    }

    /// A failed read takes the whole window only on its own tab and with nothing to show;
    /// otherwise the last good list stays and the error is a notice above it.
    private func errorFillsWindow(_ p: Platform) -> Bool {
        !showsAll && p == platform && (store.items[p] ?? []).isEmpty
    }

    /// A script error in words a person can act on; nil when it is not a known kind.
    static func friendlyError(_ raw: String, _ platform: String) -> String? {
        let m = raw.lowercased()
        if m.contains("invalid json") || m.contains("jq: error") || m.contains("parse error") {
            return L("\(platform)'s answer could not be read. Try again in a moment.", "Die Antwort von \(platform) war nicht lesbar. Gleich nochmal versuchen.")
        }
        if m.contains("timed out") || m.contains("timeout") {
            return L("\(platform) did not answer in time.", "\(platform) hat nicht rechtzeitig geantwortet.")
        }
        if m.contains("could not resolve host") || m.contains("network is unreachable") || m.contains("offline") || m.contains("connection refused") {
            return L("No connection to \(platform). Is the Mac online?", "Keine Verbindung zu \(platform). Ist der Mac online?")
        }
        // Status codes as words around them, so "4013" in some id is not taken for a 401.
        let code = { (n: String) in m.contains("http \(n)") || m.contains("status \(n)") || m.contains("code \(n)") || m.contains(" \(n) ") || m.hasPrefix("\(n) ") }
        if code("401") || code("403") || m.contains("unauthorized") || m.contains("forbidden") || m.contains("not logged in") {
            return L("\(platform) refused the login. Connect it again.", "\(platform) lehnt die Anmeldung ab. Bitte neu verbinden.")
        }
        if code("429") || m.contains("rate limit") {
            return L("\(platform) asks to slow down (rate limit). Try again later.", "\(platform) bremst (Rate-Limit). Später nochmal versuchen.")
        }
        return nil
    }

    @ViewBuilder private func loadFailedBanner(_ p: Platform) -> some View {
        if let f = store.lastLoadError[p] {
            let raw = Demo.scrub(f.message, items: allItems)
            HStack(alignment: .top, spacing: 10) {
                Image(systemName: "exclamationmark.triangle.fill").foregroundStyle(.orange)
                VStack(alignment: .leading, spacing: 2) {
                    Text(L("\(p.rawValue) could not be loaded", "\(p.rawValue) konnte nicht geladen werden")
                         + " (" + f.at.formatted(date: .omitted, time: .shortened) + ")"
                         + (store.loadedAt[p].map { L(" – showing the list from ", " – zu sehen ist der Stand von ") + $0.formatted(date: .omitted, time: .shortened) } ?? ""))
                        .font(.callout.weight(.medium))
                    if let nice = Self.friendlyError(f.message, p.rawValue) {
                        Text(nice).font(.caption).foregroundStyle(.secondary)
                    }
                    // The script's own words, for a bug report: folded away, copyable, next to the log.
                    DisclosureGroup(L("Details", "Details")) {
                        VStack(alignment: .leading, spacing: 4) {
                            Text(raw).font(.caption.monospaced()).foregroundStyle(.secondary).textSelection(.enabled)
                                .fixedSize(horizontal: false, vertical: true)
                            HStack {
                                CopyButton(title: L("Copy the error", "Fehler kopieren")) { f.message }
                                Button(L("Open the error log", "Fehlerprotokoll öffnen")) {
                                    if !FileManager.default.fileExists(atPath: Log.url.path) { Log.write("log started") }
                                    NSWorkspace.shared.open(Log.url)
                                }
                            }
                            .controlSize(.small)
                        }
                    }
                    .font(.caption)
                }
                Spacer()
                if store.loading.contains(p) { ProgressView().controlSize(.small) }
                else { Button(L("Try again", "Nochmal versuchen")) { Task { await store.load(p) } } }
            }
            .padding(.horizontal, 12).padding(.vertical, 8).background(ground(.orange, 0.08))
        }
    }

    @ViewBuilder private func setupBanner(_ p: Platform) -> some View {
        if let why = setupNeeded(p) {
            HStack(spacing: 10) {
                Image(systemName: "link.circle").foregroundStyle(.secondary)
                Text(why).font(.callout)
                Spacer()
                Button(L("Set up", "Einrichten")) { select(.provider(p.cli)) }
            }
            .padding(.horizontal, 12).padding(.vertical, 6).background(ground(.secondary, 0.08))
        }
    }

    @ViewBuilder private func autoBanner(_ p: Platform) -> some View {
        let on = store.autoOn(p)
        if !on.isEmpty {
            HStack(spacing: 10) {
                Image(systemName: "dollarsign.circle.fill").font(.title2).foregroundStyle(.orange)
                VStack(alignment: .leading, spacing: 2) {
                    Text((on.count == 1 ? L("1 project builds on every push", "1 Projekt baut bei jedem Push") : L("\(on.count) projects build on every push", "\(on.count) Projekte bauen bei jedem Push"))
                         + (showsAll ? " (\(p.rawValue))" : ""))
                        .font(.headline)
                    Text(L("Every push costs build minutes. Turn it off and deploy here when you want.",
                           "Jeder Push kostet Build-Minuten. Ausschalten und hier deployen, wann du willst."))
                        .font(.caption).foregroundStyle(.secondary)
                }
                Spacer()
                Button(L("Turn off auto-deploy", "Auto-Deploy ausschalten")) { offPlatform = p; confirmingOff = true }
                    .buttonStyle(.borderedProminent).tint(.orange)
            }
            .padding(12)
            .background(ground(.orange, 0.1))
        }
    }

    @ViewBuilder private var content: some View {
        // Filtered and sorted once per render; the list and the empty states both use it.
        let visible = self.visible
        if let err = store.doctorError {
            Setup(title: L("Something is missing", "Etwas fehlt"), text: err, commands: []) { Task { await store.start() } }
        } else if store.doctor == nil && scopes.allSatisfy({ (store.items[$0] ?? []).isEmpty }) {
            ProgressView(L("Checking access …", "Prüfe Zugang …")).frame(maxWidth: .infinity, maxHeight: .infinity)
        } else if let d = store.doctor, !d.jq {
            Setup(title: L("jq is missing", "jq fehlt"),
                  text: L("Deploy Center needs the small tool jq. Install it with Homebrew:", "Deploy Center braucht das kleine Werkzeug jq. Installieren mit Homebrew:"),
                  commands: ["brew install jq"]) { Task { await store.start() } }
        } else if !showsAll && platform == nil {
            // Switched on in Settings, but this version of the app cannot list it yet.
            VStack(spacing: 8) {
                Image(systemName: "hourglass").font(.system(size: 34)).foregroundStyle(.secondary)
                Text(L("\(currentLabel) is coming soon", "\(currentLabel) kommt bald")).font(.headline)
                Text(L("This version of Deploy Center cannot list \(currentLabel) projects yet.",
                       "Diese Version von Deploy Center kann \(currentLabel)-Projekte noch nicht anzeigen."))
                    .font(.caption).foregroundStyle(.secondary)
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity)
        } else if !showsAll, platform == .vercel, let d = store.doctor, d.vercelCli, !d.vercelApi {
            Setup(title: L("Update the Vercel CLI", "Vercel-CLI aktualisieren"),
                  text: L("Your Vercel CLI is too old (it has no `vercel api`).", "Deine Vercel-CLI ist zu alt (ihr fehlt `vercel api`)."),
                  commands: ["npm i -g vercel@latest"]) { Task { await store.start() } }
        } else if !showsAll, platform == .vercel, let d = store.doctor, !d.vercelLoggedIn {
            Setup(title: L("Connect Vercel", "Vercel verbinden"),
                  text: d.vercelCli
                    ? L("Log in once in Terminal. The app uses that login.", "Einmal im Terminal anmelden. Die App nutzt diese Anmeldung.")
                    : L("Install the Vercel CLI, then log in once in Terminal.", "Vercel-CLI installieren und einmal im Terminal anmelden."),
                  commands: d.vercelCli ? ["vercel login"] : ["npm i -g vercel", "vercel login"]) {
                Task { await store.start() }
            }
        } else if !showsAll, platform == .render, let d = store.doctor, !d.renderKey {
            RenderKeySetup(store: store)
        } else if let p = platform, errorFillsWindow(p), let err = store.lastLoadError[p]?.message ?? store.loadError[p] {
            VStack(spacing: 10) {
                Image(systemName: "exclamationmark.triangle").font(.largeTitle).foregroundStyle(.orange)
                Text(L("Could not load \(p.rawValue)", "\(p.rawValue) konnte nicht geladen werden")).font(.headline)
                Text(Demo.scrub(err, items: allItems)).font(.callout).foregroundStyle(.secondary).multilineTextAlignment(.center).textSelection(.enabled)
                if store.loading.contains(p) { ProgressView().controlSize(.small) }
                else { Button(L("Try again", "Nochmal versuchen")) { Task { await store.load(p) } } }
            }
            .padding(30).frame(maxWidth: .infinity, maxHeight: .infinity)
        } else if scopes.contains(where: { store.loading.contains($0) }) && scopes.allSatisfy({ (store.items[$0] ?? []).isEmpty }) {
            ProgressView(L("Loading \(scopes.map(\.rawValue).joined(separator: ", ")) …", "Lade \(scopes.map(\.rawValue).joined(separator: ", ")) …")).frame(maxWidth: .infinity, maxHeight: .infinity)
        } else if visible.isEmpty && (onlyChanged || !search.isEmpty) {
            let inScope = scopes.flatMap { store.items[$0] ?? [] }
            // Nothing waits here, but maybe on another tab: say where, instead of "everything is live".
            let elsewhere = search.isEmpty ? providers.compactMap(\.platform).filter { !scopes.contains($0) && store.changedCount($0) > 0 } : []
            let hiddenHits = search.isEmpty ? 0 : inScope.filter { store.isHidden($0)
                && (Demo.on ? Demo.mask($0.name) : $0.name).localizedCaseInsensitiveContains(search) }.count
            VStack(spacing: 8) {
                Image(systemName: !search.isEmpty ? "magnifyingglass" : elsewhere.isEmpty ? "checkmark.seal.fill" : "checkmark.circle").font(.system(size: 34))
                    .foregroundStyle(search.isEmpty && elsewhere.isEmpty ? .green : .secondary)
                Text(!search.isEmpty ? L("Nothing matches “\(search)”", "Nichts passt zu „\(search)“")
                     : elsewhere.isEmpty ? L("Everything is live", "Alles ist live")
                     : L("Nothing waits on \(currentLabel)", "Bei \(currentLabel) wartet nichts"))
                    .font(.headline)
                ForEach(elsewhere, id: \.self) { p in
                    let n = store.changedCount(p)
                    Button(L("\(plural(n, "project waits", "projects wait")) on \(p.rawValue)", "Bei \(p.rawValue) \(n == 1 ? "wartet" : "warten") \(plural(n, "Projekt", "Projekte"))")) {
                        select(.provider(p.cli))
                    }
                    .buttonStyle(.link)
                }
                if hiddenHits > 0 {
                    Text(L("\(hiddenHits) hidden \(hiddenHits == 1 ? "project matches" : "projects match") (Settings → Hidden projects)",
                           "\(hiddenHits) \(hiddenHits == 1 ? "ausgeblendetes Projekt passt" : "ausgeblendete Projekte passen") (Einstellungen → Ausgeblendete Projekte)"))
                        .font(.caption).foregroundStyle(.secondary)
                }
                HStack {
                    if !search.isEmpty { Button(L("Clear the search", "Suche leeren")) { search = "" } }
                    if onlyChanged { Button(L("Show all projects", "Alle Projekte zeigen")) { onlyChanged = false } }
                }
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity)
        } else if visible.isEmpty {
            let hiddenHere = scopes.flatMap { store.items[$0] ?? [] }.filter { store.isHidden($0) }.count
            VStack(spacing: 8) {
                Image(systemName: hiddenHere > 0 ? "eye.slash" : "tray").font(.system(size: 34)).foregroundStyle(.secondary)
                Text(hiddenHere > 0 ? L("All projects here are hidden", "Alle Projekte hier sind ausgeblendet") : L("No projects here", "Keine Projekte hier"))
                    .font(.headline)
                Text(hiddenHere > 0
                     ? L("\(hiddenHere) hidden. Show them again in Settings → Hidden projects.", "\(hiddenHere) ausgeblendet. Wieder zeigen unter Einstellungen → Ausgeblendete Projekte.")
                     : L("This account has no projects on \(scopes.map(\.rawValue).joined(separator: " or ")).", "Dieses Konto hat keine Projekte bei \(scopes.map(\.rawValue).joined(separator: " oder "))."))
                    .font(.caption).foregroundStyle(.secondary)
                if hiddenHere > 0 {
                    // The hidden projects are on the General tab; open Settings there, whatever tab was last.
                    Button(L("Open Settings", "Einstellungen öffnen")) {
                        UserDefaults.standard.set("general", forKey: "settingsTab"); openSettings()
                    }
                }
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity)
        } else {
            // One lookup table per render instead of a search through all projects per row.
            let costRows = Dictionary((store.costs?.projects ?? []).map { ($0.name, $0) }, uniquingKeysWith: { a, _ in a })
            let complete = store.costs?.buildsComplete == true
            // One timer for the whole list: "3 minutes ago" in every row moves on once a minute.
            TimelineView(.everyMinute) { _ in
            List {
                ForEach(RepoGroup.groups(visible)) { g in
                    if g.showsHeader, let repo = g.repo {
                        Section {
                            ForEach(g.items) { item in row(item, costRows, complete) }
                    } header: {
                            repoHeader(repo, g.items)
                        }
                    } else {
                        ForEach(g.items) { item in row(item, costRows, complete) }
                    }
                }
            }
            .listStyle(.inset)
            }
        }
    }

    private func isMerged(_ a: RowAutofix?) -> Bool { if case .merged = a { return true } else { return false } }

    /// The repo above its projects; its menu ticks all of them that can go live.
    private func repoHeader(_ repo: String, _ items: [Item]) -> some View {
        let tickable = items.filter { $0.deployable && $0.hasNewCommits && !$0.state.isActive && !$0.selected }
        return HStack {
            Text(Demo.mask(repo)).font(.caption.weight(.semibold)).foregroundStyle(.secondary)
            Spacer()
            if !tickable.isEmpty && !store.observer {
                Button(L("Tick all \(tickable.count)", "Alle \(tickable.count) anhaken")) {
                    tickable.forEach { store.toggle($0.platform, $0.id) }
                }
                .buttonStyle(.link).font(.caption)
                .help(L("Ticks every project of this repo with changes waiting", "Hakt alle Projekte dieses Repos mit wartenden Änderungen an"))
            }
        }
        .accessibilityElement(children: .contain)
        .accessibilityLabel(L("Repository \(Demo.mask(repo)), ", "Repository \(Demo.mask(repo)), ")
                            + L(plural(items.count, "project", "projects"), plural(items.count, "Projekt", "Projekte")))
    }

    private func row(_ item: Item, _ costRows: [String: Costs.Project], _ complete: Bool) -> some View {
        let c = item.platform == .vercel ? costRows[item.name] : nil
        // Worked out once per row; the row and its background both need it.
        let fix = store.autofixState(item)
        return Row(item: item, showPlatform: showsAll, cost: c?.build,
            perBuild: complete ? c.flatMap { p in p.builds.flatMap { $0 > 0 ? p.build / Double($0) : nil } } : nil,
            pinned: store.isPinned(item), note: store.note(item),
            showDetails: item.repo == nil ? nil : { detailItem = item },
            showLog: { logItem = item },
            onCancel: { store.cancel(item) },
            onRetry: item.deployable && !store.observer ? { store.deployOne(item, preview: false) } : nil,
            usualMinutes: store.usualMinutes(item), queueText: store.queueText(item), search: search,
            autofix: fix, allowedUntil: store.allowance(item)?.expiresAt,
            autofixBusy: store.autofixBusy(item),
            onAutofix: store.canFixWithClaude(item) ? { Task { await store.fixWithClaude(item) } } : nil,
            onDeployMerged: item.deployable && !store.observer && !item.state.isActive ? {
                if !item.selected { store.toggle(item.platform, item.id) }
                confirming = true
            } : nil,
            onDismissAutofix: AgentChips.dismissable(fix) ? { store.dismissAutofix(item) } : nil) { tick(item) }
            // A merged fix waits for a click: the row stands out until it is live.
            .listRowBackground(isMerged(fix) ? ground(.green, 0.12) : nil)
            .contextMenu { rowMenu(item) }
    }

    /// Deploy, Log, Open site; the rest under More.
    @ViewBuilder private func rowMenu(_ item: Item) -> some View {
        let canDeploy = item.deployable && !item.state.isActive && !store.observer
        let caps = store.provider(item.platform)?.caps ?? ProviderCaps()
        if store.canFixWithClaude(item) {
            Button(L("Fix with Claude", "Mit Claude beheben")) { Task { await store.fixWithClaude(item) } }
                .disabled(store.autofixBusy(item))
        }
        if item.repo != nil, !store.observer {
            Button(store.scanRun(item)?.running == true ? L("Claude is looking for bugs …", "Claude sucht nach Bugs …")
                                                        : L("Find bugs with Claude", "Mit Claude nach Bugs suchen")) {
                Task { await store.scanForBugs(item) }
            }
            .disabled(!store.canScan(item))
        }
        if item.repo != nil, store.scan?.tools?.any == true {
            Button(store.checkRun(item)?.running == true ? L("Security check running …", "Sicherheits-Check läuft …")
                                                         : L("Security check", "Sicherheits-Check")) {
                Task { await store.securityCheck(item) }
            }
            .disabled(!store.canCheck(item))
        }
        if canDeploy {
            Button(L("Deploy to production", "Live deployen")) {
                if item.hasNewCommits || item.headSha == nil { store.deployOne(item, preview: false) }
                else { unchangedItem = item }
            }
        }
        Button(L("Build log …", "Build-Log …")) { logItem = item }
        if let a = store.autofixState(item), let u = AgentChips.link(a), !Demo.on {
            Button(L("Open the fix on GitHub / claude.ai", "Fix auf GitHub / claude.ai öffnen")) { NSWorkspace.shared.open(u) }
        }
        if let l = item.link, let u = URL(string: l) {
            Button(L("Open site", "Seite öffnen")) { NSWorkspace.shared.open(u) }
        }
        Divider()
        Menu(L("More", "Mehr")) {
            if item.repo != nil {
                Button(L("Details …", "Details …")) { detailItem = item }
            }
            if canDeploy {
                if caps.preview {
                    Button(L("Preview deploy (not live)", "Vorschau-Deploy (nicht live)")) { store.deployOne(item, preview: true) }
                }
                if item.platform == .render {
                    Button(L("Deploy with a cleared build cache", "Mit geleertem Build-Cache deployen")) { store.deployOne(item, preview: false, clearCache: true) }
                }
                Button(L("Roll back production …", "Live zurückrollen …")) { rollbackItem = item }
            }
            if let u = item.compareURL {
                Button(L("Show the waiting commits on GitHub", "Wartende Commits auf GitHub ansehen")) { NSWorkspace.shared.open(u) }
            }
            if let u = item.dashboardURL {
                Button(L("Open in the Render dashboard", "Im Render-Dashboard öffnen")) { NSWorkspace.shared.open(u) }
            }
            Divider()
            Button(store.isPinned(item) ? L("Unpin", "Nicht mehr anheften") : L("Pin to the top", "Oben anheften")) { store.togglePin(item) }
            Button(store.note(item) == nil ? L("Add a note …", "Notiz hinzufügen …") : L("Edit the note …", "Notiz ändern …")) {
                noteText = store.note(item) ?? ""; noteItem = item
            }
            Button(L("Pages to check after deploy …", "Seiten für die Prüfung nach dem Deploy …")) {
                pathText = store.healthPath(item); siteText = store.siteText(item); pathItem = item
            }
            if item.platform == .vercel {
                Button(L("Monthly budget …", "Monatsbudget …")) {
                    budgetText = store.projectBudget(item).map { String(format: "%.0f", $0) } ?? ""; budgetItem = item
                }
            }
            Toggle(L("Critical: type the name to go live", "Kritisch: zum Live-Schalten Namen tippen"),
                   isOn: Binding(get: { store.isCritical(item) }, set: { _ in store.toggleCritical(item) }))
            Button(L("Hide", "Ausblenden")) {
                // A hidden project must not go out with the next deploy.
                if item.selected { store.toggle(item.platform, item.id) }
                store.hideWithUndo(item)
            }
        }
    }

    /// The saved copy may be hours old; tick from what is true now. If reading it again failed,
    /// the error is on screen and the copy is all there is.
    private var waitsForFreshList: Bool { scopes.contains { store.fromCache.contains($0) && store.loadError[$0] == nil } }

    /// ⌘A: in the search field it selects the text, as everywhere; otherwise it ticks what changed.
    private func selectAllCommand() {
        if searchFocused { NSApp.sendAction(#selector(NSText.selectAll(_:)), to: nil, from: nil); return }
        guard !waitsForFreshList else { return }
        // Only what the list shows: not hidden, not filtered away by the search (one rule, Store.isWaiting).
        let keys = Set(visible.map(Store.key))
        for p in scopes { store.selectChanged(p, among: keys) }
    }

    /// Ticked projects on platforms that can build a preview.
    private var previewScopes: [Platform] {
        scopes.filter { store.provider($0)?.caps.preview == true && !store.selected($0).isEmpty }
    }

    private var footer: some View {
        let count = selectedAll.count
        let changedHere = scopes.map { store.changedCount($0) }.reduce(0, +)
        return HStack {
            Text(count == 0 ? L("Tick the projects that should go live", "Projekte anhaken, die live gehen sollen")
                            : L("\(count) selected", "\(count) ausgewählt"))
                .foregroundStyle(.secondary)
                .help(L("Shift-click ticks everything between the last tick and this one", "Mit ⇧-Klick wird alles zwischen dem letzten Haken und diesem angehakt"))
            // Ticks on another tab still count there: say they exist.
            let elsewhere = Platform.allCases.filter { !scopes.contains($0) }.map { p in (p, store.selected(p).count) }.filter { $0.1 > 0 }
            ForEach(elsewhere, id: \.0) { p, n in
                Button(L("+\(n) on \(p.rawValue)", "+\(n) auf \(p.rawValue)")) { select(.provider(p.cli)) }
                    .buttonStyle(.link).font(.caption)
                    .help(L("Ticked on another tab", "Auf einem anderen Tab angehakt"))
            }
            Spacer()
            if scopes.contains(where: { p in (store.items[p] ?? []).contains { $0.state.isActive } }) {
                Button(L("Stop all …", "Alles abbrechen …"), role: .destructive) { confirmingStop = true }
            }
            moreMenu(count: count, changedHere: changedHere)
            if store.observer {
                // Observer mode (Settings → Team): the deploy buttons are gone, and the script refuses anyway.
                Label(L("Observer", "Beobachter"), systemImage: "eye")
                    .foregroundStyle(.secondary).padding(.horizontal, 6)
                    .help(L("This Mac only looks. Turn it off in Settings → Team.", "Dieser Mac schaut nur zu. Abschalten unter Einstellungen → Team."))
            } else {
                Button { confirming = true } label: {
                    Label(count > 1 ? L("Deploy \(count) live", "\(count) live deployen") : L("Deploy live", "Live deployen"),
                          systemImage: "paperplane.fill").padding(.horizontal, 6)
                }
                .buttonStyle(.borderedProminent).controlSize(.large)
                .keyboardShortcut(.return, modifiers: .command)
                .disabled(count == 0)
                .help(count == 0 ? L("Tick the projects first", "Zuerst Projekte anhaken")
                                 : L("Puts the ticked projects live, after a confirmation (⌘↩)", "Schaltet die angehakten Projekte live, nach einer Rückfrage (⌘↩)"))
            }
        }
        .padding(12)
        // ⌘A works with the menu closed too; the menu item shows the shortcut.
        .background {
            Button(L("Select all changed", "Alle mit Änderungen anhaken")) { selectAllCommand() }
                .keyboardShortcut("a")
                .opacity(0).frame(width: 0, height: 0).accessibilityHidden(true)
        }
    }

    private func moreMenu(count: Int, changedHere: Int) -> some View {
        Menu {
            Button(waitsForFreshList ? L("Select all changed (waits for the fresh list)", "Alle mit Änderungen anhaken (wartet auf die frische Liste)")
                                     : L("Select all changed", "Alle mit Änderungen anhaken")) { selectAllCommand() }
                .keyboardShortcut("a")
                .disabled(changedHere == 0 || waitsForFreshList)
            if count > 0 {
                Button(L("Clear the selection", "Auswahl leeren")) { scopes.forEach { store.clearSelection($0) } }
            }
            Button(L("Preview deploy of the selection (not live)", "Vorschau-Deploy der Auswahl (nicht live)")) {
                previewScopes.forEach { store.deploySelected($0, preview: true) }
            }
            .disabled(previewScopes.isEmpty || store.observer)
            Divider()
            Button(L("Deploy history …", "Deploy-Verlauf …")) { showJournal = true }
            Button(L("Latest messages …", "Letzte Meldungen …")) { showMessages = true }
                .disabled(store.messages.isEmpty)
        } label: {
            Text(L("More", "Mehr"))
        }
        .fixedSize()
        .help(L("Select all changed, preview deploy, deploy history, messages", "Alle mit Änderungen anhaken, Vorschau-Deploy, Deploy-Verlauf, Meldungen"))
        .accessibilityLabel(L("More actions", "Weitere Aktionen"))
        .popover(isPresented: $showMessages) {
            VStack(alignment: .leading, spacing: 6) {
                ForEach(store.messages.prefix(15)) { m in
                    HStack(alignment: .top, spacing: 6) {
                        Image(systemName: m.ok ? "checkmark.circle.fill" : "xmark.octagon.fill").foregroundStyle(m.ok ? .green : .red)
                        Text(m.date.formatted(date: .omitted, time: .shortened)).font(.caption.monospacedDigit()).foregroundStyle(.secondary)
                        Text(Demo.scrub(m.text, items: allItems)).font(.caption).textSelection(.enabled)
                    }
                }
            }
            .padding(12).frame(width: 420, alignment: .leading)
        }
    }
}

/// What VoiceOver's chart reader (Audio Graphs) gets: one value per day.
struct CostChartDescriptor: AXChartDescriptorRepresentable {
    let days: [Costs.Day]
    func makeChartDescriptor() -> AXChartDescriptor {
        let x = AXCategoricalDataAxisDescriptor(title: L("Day", "Tag"), categoryOrder: days.map(\.day))
        let top = max(1, days.map(\.build).max() ?? 1)
        let y = AXNumericDataAxisDescriptor(title: "USD", range: 0...top, gridlinePositions: []) { $0.formatted(.currency(code: "USD")) }
        let series = AXDataSeriesDescriptor(name: L("Build costs", "Build-Kosten"), isContinuous: false,
                                            dataPoints: days.map { .init(x: $0.day, y: $0.build) })
        return AXChartDescriptor(title: L("Vercel build costs per day", "Vercel-Build-Kosten pro Tag"),
                                 summary: nil, xAxis: x, yAxis: y, additionalAxes: [], series: [series])
    }
}

struct CostsSheet: View {
    let costs: Costs
    @Environment(\.dismiss) private var dismiss
    @State private var hovered: String?
    @State private var sharing = false
    private static let dayFormat: DateFormatter = {
        let f = DateFormatter(); f.dateFormat = "yyyy-MM-dd"; f.timeZone = TimeZone(identifier: "UTC"); return f
    }()
    /// Today as the billing data names days (UTC).
    static func today() -> String { dayFormat.string(from: Date()) }
    private var last7: [Costs.Day] { Array(costs.days.suffix(7)) }

    /// "2026-11-01" → "Nov 1" on a month's first day (and for the first bar), else "2".
    static func axisLabel(_ day: String, first: Bool) -> String {
        guard let d = dayFormat.date(from: day) else { return String(day.suffix(2)) }
        var cal = Calendar(identifier: .gregorian); cal.timeZone = TimeZone(identifier: "UTC")!
        let n = cal.component(.day, from: d)
        guard first || n == 1 else { return "\(n)" }
        var style = Date.FormatStyle(date: .omitted, time: .omitted).month(.abbreviated).day()
        style.timeZone = cal.timeZone
        style.locale = Locale(identifier: isGerman ? "de_DE" : "en_US")
        return d.formatted(style)
    }
    private var average: Double { last7.isEmpty ? 0 : costs.week / Double(last7.count) }

    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            Text(L("Costs", "Kosten")).font(.title2.weight(.semibold)).accessibilityAddTraits(.isHeader)
            summary
            chart
            topProjects
            Text(L("From Vercel's billing data. Total incl. other usage, 7 days: ", "Aus Vercels Abrechnung. Gesamt inkl. sonstiger Nutzung, 7 Tage: ")
                 + last7.map(\.total).reduce(0, +).formatted(.currency(code: "USD")))
                .font(.caption).foregroundStyle(.secondary)
            HStack {
                Spacer()
                Button(L("Done", "Fertig")) { dismiss() }.keyboardShortcut(.defaultAction)
            }
        }
        .padding(20)
        .frame(width: 520)
    }

    /// Where the money goes: the dearest projects of the 7 days.
    @ViewBuilder private var topProjects: some View {
        let top = costs.projects.filter { $0.build >= 0.01 }.sorted { $0.build > $1.build }.prefix(8)
        if !top.isEmpty {
            VStack(alignment: .leading, spacing: 3) {
                Text(L("Most expensive projects, 7 days", "Teuerste Projekte, 7 Tage")).font(.caption.weight(.semibold)).foregroundStyle(.secondary)
                ForEach(Array(top), id: \.name) { p in
                    HStack {
                        Text(Demo.mask(p.name)).lineLimit(1)
                        Spacer()
                        if let n = p.builds { Text(L(plural(n, "build", "builds"), plural(n, "Build", "Builds"))).foregroundStyle(.secondary) }
                        Text(p.build, format: .currency(code: "USD")).monospacedDigit().frame(minWidth: 64, alignment: .trailing)
                    }
                    .font(.callout)
                    .accessibilityElement(children: .combine)
                }
            }
        }
    }

    private var summary: some View {
        VStack(alignment: .leading, spacing: 2) {
            Text(L("Vercel builds, last 7 days", "Vercel-Builds, letzte 7 Tage")).font(.caption).foregroundStyle(.secondary)
            Text(costs.week, format: .currency(code: "USD")).font(.title3.weight(.semibold).monospacedDigit())
            Text(L("≈ ", "≈ ") + (average * 30).formatted(.currency(code: "USD")) + L(" a month at this pace", " im Monat bei diesem Tempo"))
                .font(.caption).foregroundStyle(.secondary)
            if let s = costs.saving(today: Self.today()) {
                Text(L("per day: ", "pro Tag: ") + s.before.formatted(.currency(code: "USD")) + L(" before, ", " vorher, ")
                     + s.after.formatted(.currency(code: "USD")) + L(" since", " seitdem"))
                    .font(.caption.weight(.medium)).foregroundStyle(s.after < s.before ? .green : .orange)
                if s.after < s.before {
                    Button(L("Share the saving …", "Ersparnis teilen …")) { sharing = true }
                        .buttonStyle(.link).font(.caption)
                        .popover(isPresented: $sharing) { SavingShare(before: s.before, after: s.after) }
                        .help(L("Copies a picture and a sentence with your saving, without project names",
                                "Kopiert ein Bild und einen Satz mit deiner Ersparnis, ohne Projektnamen"))
                }
            } else if let off = costs.offDay {
                Text(L("Auto-deploy off since \(off); the saving shows after a full day", "Auto-Deploy aus seit \(off); die Ersparnis zeigt sich nach einem ganzen Tag"))
                    .font(.caption).foregroundStyle(.secondary)
            }
        }
    }

    private var chart: some View {
        VStack(alignment: .leading, spacing: 4) {
            Chart(costs.days) { d in
                // A day over twice the average stands out.
                BarMark(x: .value("Day", d.day), y: .value("USD", d.build))
                    .foregroundStyle(d.build > 2 * average && average > 0 ? Color.orange.gradient : Color.accentColor.gradient)
                    // The dearest day carries its value, without hovering.
                    .annotation(position: .top) {
                        if d.day == costs.days.max(by: { $0.build < $1.build })?.day, d.build > 0 {
                            Text(usd0(d.build)).font(.caption2.monospacedDigit()).foregroundStyle(.secondary)
                        }
                    }
                if let off = costs.offDay, d.day == off {
                    RuleMark(x: .value("Day", d.day)).foregroundStyle(.green).lineStyle(StrokeStyle(lineWidth: 1, dash: [3]))
                }
            }
            .chartYAxis { AxisMarks(position: .leading) { _ in AxisValueLabel() } }
            // "Nov 1" on the first day of a month and the first bar, else the day: the month change is seen.
            .chartXAxis {
                AxisMarks { v in
                    AxisValueLabel { Text(v.as(String.self).map { Self.axisLabel($0, first: $0 == costs.days.first?.day) } ?? "") }
                }
            }
            .chartXSelection(value: $hovered)
            .overlay(alignment: .topTrailing) {
                // The value of the day under the pointer, with its full date.
                if let h = hovered, let d = costs.days.first(where: { $0.day == h }) {
                    Text(d.day + ": " + d.build.formatted(.currency(code: "USD")))
                        .font(.caption2.monospacedDigit()).padding(.horizontal, 5).padding(.vertical, 2)
                        .background(RoundedRectangle(cornerRadius: 4).fill(.regularMaterial))
                }
            }
            .frame(height: 140)
            .accessibilityChartDescriptor(CostChartDescriptor(days: costs.days))
            // What the chart spans (14 days, the total above is 7), and what its colours mean.
            HStack(spacing: 10) {
                Text(L("last \(costs.days.count) days", "letzte \(costs.days.count) Tage"))
                HStack(spacing: 3) { RoundedRectangle(cornerRadius: 1).fill(Color.orange).frame(width: 7, height: 7); Text(L("over 2× the average", "über 2× Schnitt")) }
                if costs.offDay != nil {
                    HStack(spacing: 3) { Rectangle().fill(Color.green).frame(width: 7, height: 1.5); Text(L("auto-deploy off", "Auto-Deploy aus")) }
                }
            }
            .font(.caption2).foregroundStyle(.secondary)
        }
    }
}

/// The picture before it goes anywhere: copy it, save it as PNG, or hand it to the share menu.
struct SavingShare: View {
    let before: Double, after: Double
    @State private var copied = false
    /// Rendered once when the popover opens, not on every redraw ("Copied ✓").
    @State private var image: NSImage?
    @State private var saveError: String?

    private func render() -> NSImage? {
        let r = ImageRenderer(content: SavingCard(before: before, after: after)); r.scale = 2
        return r.nsImage
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            SavingCard(before: before, after: after).scaleEffect(0.7).frame(width: 364, height: 200)
            Text(SavingCard.text(before: before, after: after)).font(.caption).foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true).frame(width: 364, alignment: .leading)
            HStack {
                Button(copied ? L("Copied ✓", "Kopiert ✓") : L("Copy picture and text", "Bild und Text kopieren")) {
                    SavingCard.copy(before: before, after: after); copied = true
                }
                Button(L("Save as PNG …", "Als PNG sichern …")) { save() }
                if let img = image {
                    ShareLink(item: Image(nsImage: img), subject: Text("Deploy Center"),
                              message: Text(SavingCard.text(before: before, after: after)),
                              preview: SharePreview(L("Build cost saving", "Build-Ersparnis"), image: Image(nsImage: img)))
                }
            }
            if let saveError { ErrorText(saveError) }
        }
        .padding(16)
        .task { if image == nil { image = render() } }
    }

    private func save() {
        saveError = nil
        guard let img = image ?? render(), let tiff = img.tiffRepresentation, let rep = NSBitmapImageRep(data: tiff),
              let png = rep.representation(using: .png, properties: [:]) else {
            saveError = L("The picture could not be made.", "Das Bild ließ sich nicht erzeugen."); return
        }
        let panel = NSSavePanel()
        panel.allowedContentTypes = [.png]
        panel.nameFieldStringValue = L("deploy-center-saving.png", "deploy-center-ersparnis.png")
        guard panel.runModal() == .OK, let url = panel.url else { return }
        do { try png.write(to: url) }
        catch { saveError = L("Not saved: ", "Nicht gesichert: ") + error.localizedDescription }
    }
}

/// A picture of the saving to post somewhere: two numbers and the app's name, nothing about the projects.
struct SavingCard: View {
    let before: Double, after: Double
    private var month: Double { max(0, before - after) * 30 }

    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            HStack(spacing: 8) {
                Image(systemName: "paperplane.fill").foregroundStyle(.white)
                    .padding(7).background(RoundedRectangle(cornerRadius: 8).fill(Color.accentColor))
                Text("Deploy Center").font(.headline).foregroundStyle(.white)
            }
            Text(L("My build bill since I turned off auto-deploy", "Meine Build-Kosten, seit Auto-Deploy aus ist"))
                .font(.title3.weight(.semibold)).foregroundStyle(.white)
            HStack(alignment: .firstTextBaseline, spacing: 24) {
                VStack(alignment: .leading) {
                    Text(L("before", "vorher")).font(.caption).foregroundStyle(.white.opacity(0.6))
                    Text(before, format: .currency(code: "USD")).font(.title.weight(.bold).monospacedDigit()).foregroundStyle(.red.opacity(0.9))
                    Text(L("a day", "pro Tag")).font(.caption).foregroundStyle(.white.opacity(0.6))
                }
                Image(systemName: "arrow.right").foregroundStyle(.white.opacity(0.5))
                VStack(alignment: .leading) {
                    Text(L("now", "jetzt")).font(.caption).foregroundStyle(.white.opacity(0.6))
                    Text(after, format: .currency(code: "USD")).font(.title.weight(.bold).monospacedDigit()).foregroundStyle(.green)
                    Text(L("a day", "pro Tag")).font(.caption).foregroundStyle(.white.opacity(0.6))
                }
            }
            Text(L("≈ ", "≈ ") + month.formatted(.currency(code: "USD").precision(.fractionLength(0))) + L(" a month saved", " im Monat gespart"))
                .font(.title2.weight(.bold)).foregroundStyle(.white)
            Text("github.com/\(Updater.repo)").font(.caption).foregroundStyle(.white.opacity(0.6))
        }
        .padding(28).frame(width: 520, alignment: .leading)
        .background(LinearGradient(colors: [Color(red: 0.07, green: 0.09, blue: 0.16), Color(red: 0.18, green: 0.11, blue: 0.32)],
                                   startPoint: .topLeading, endPoint: .bottomTrailing))
    }

    /// The sentence that goes with the picture.
    static func text(before: Double, after: Double) -> String {
        let m = (max(0, before - after) * 30).formatted(.currency(code: "USD").precision(.fractionLength(0)))
        return L("I turned off auto-deploy and now deploy by hand: builds went from \(before.formatted(.currency(code: "USD"))) to \(after.formatted(.currency(code: "USD"))) a day, about \(m) a month saved. https://github.com/\(Updater.repo)",
                 "Ich habe Auto-Deploy ausgeschaltet und deploye jetzt von Hand: Builds von \(before.formatted(.currency(code: "USD"))) auf \(after.formatted(.currency(code: "USD"))) am Tag, etwa \(m) im Monat gespart. https://github.com/\(Updater.repo)")
    }

    /// Picture and sentence on the clipboard at once; a chat or post takes whichever it can.
    @MainActor static func copy(before: Double, after: Double) {
        let r = ImageRenderer(content: SavingCard(before: before, after: after)); r.scale = 2
        let pb = NSPasteboard.general; pb.clearContents()
        var items: [NSPasteboardWriting] = [text(before: before, after: after) as NSString]
        if let img = r.nsImage { items.insert(img, at: 0) }
        pb.writeObjects(items)
    }
}

struct Setup: View {
    let title: String
    let text: String
    let commands: [String]
    let retry: () -> Void

    var body: some View {
        VStack(spacing: 14) {
            Image(systemName: "link.circle").font(.system(size: 40)).foregroundStyle(.secondary)
            Text(title).font(.title2.weight(.semibold))
            Text(text).foregroundStyle(.secondary).multilineTextAlignment(.center)
            ForEach(commands, id: \.self) { c in
                HStack {
                    Text(c).font(.system(.body, design: .monospaced)).textSelection(.enabled)
                    CopyButton(title: L("Copy \(c)", "\(c) kopieren"), systemImage: "doc.on.doc") { c }.buttonStyle(.borderless)
                }
                .padding(8).background(RoundedRectangle(cornerRadius: 6).fill(Color.secondary.opacity(0.12)))
            }
            Button(L("Done – check again", "Fertig – nochmal prüfen"), action: retry).buttonStyle(.borderedProminent)
        }
        .padding(30).frame(maxWidth: 460).frame(maxWidth: .infinity, maxHeight: .infinity)
    }
}

struct RenderKeySetup: View {
    @ObservedObject var store: Store
    @State private var key = ""
    @State private var error: String?
    @State private var saving = false

    var body: some View {
        VStack(spacing: 14) {
            Image(systemName: "key.fill").font(.system(size: 36)).foregroundStyle(.secondary)
            Text(L("Connect Render", "Render verbinden")).font(.title2.weight(.semibold))
            Text(L("Create an API key at dashboard.render.com → Account Settings → API Keys and paste it here. It is stored in your macOS keychain, nowhere else.",
                   "Erstelle einen API-Key unter dashboard.render.com → Account Settings → API Keys und füge ihn hier ein. Er wird nur im macOS-Schlüsselbund gespeichert."))
                .foregroundStyle(.secondary).multilineTextAlignment(.center)
            SecureField(L("Render API key", "Render-API-Key"), text: $key, prompt: Text("rnd_…"))
                .textFieldStyle(.roundedBorder).frame(width: 320)
                .onSubmit { if canSave { save() } }
            if !key.isEmpty && !looksRight {
                Text(L("A Render API key starts with rnd_.", "Ein Render-API-Key beginnt mit rnd_."))
                    .font(.caption).foregroundStyle(Color.warningText)
            }
            if let error { ErrorText(error).multilineTextAlignment(.center) }
            HStack {
                Button(L("Open Render", "Render öffnen")) {
                    NSWorkspace.shared.open(URL(string: "https://dashboard.render.com/u/settings#api-keys")!)
                }
                Button(saving ? L("Saving …", "Speichere …") : L("Save key", "Key speichern")) { save() }
                    .buttonStyle(.borderedProminent).disabled(!canSave)
            }
        }
        .padding(30).frame(maxWidth: 480).frame(maxWidth: .infinity, maxHeight: .infinity)
    }

    private var trimmed: String { key.trimmingCharacters(in: .whitespacesAndNewlines) }
    private var looksRight: Bool { trimmed.hasPrefix("rnd_") && trimmed.count >= 10 }
    private var canSave: Bool { looksRight && !saving }
    private func save() {
        saving = true
        Task { error = await store.saveRenderKey(key); saving = false; if error == nil { key = "" } }
    }
}

struct Row: View {
    let item: Item
    /// Under "All": a small platform name after the key figure.
    var showPlatform = false
    var cost: Double? = nil
    var perBuild: Double? = nil
    var pinned = false
    var note: String? = nil
    var showDetails: (() -> Void)? = nil
    var showLog: (() -> Void)? = nil
    var onCancel: (() -> Void)? = nil
    var onRetry: (() -> Void)? = nil
    var usualMinutes: Int? = nil
    var queueText: String? = nil
    var search = ""
    var autofix: RowAutofix? = nil
    var allowedUntil: Date? = nil
    var autofixBusy = false
    var onAutofix: (() -> Void)? = nil
    var onDeployMerged: (() -> Void)? = nil
    var onDismissAutofix: (() -> Void)? = nil
    let toggle: () -> Void
    @Environment(\.accessibilityDifferentiateWithoutColor) private var noColour

    /// The part of the name that matches the search, marked.
    private func highlighted(_ text: String) -> AttributedString {
        var a = AttributedString(text)
        guard !search.isEmpty, let r = a.range(of: search, options: .caseInsensitive) else { return a }
        a[r].backgroundColor = .yellow.opacity(0.35)
        return a
    }

    var body: some View { forVoiceOver(layout) }

    private var layout: some View {
        HStack(spacing: 12) {
            Button(action: toggle) {
                Image(systemName: item.selected ? "checkmark.circle.fill" : "circle")
                    .font(.title3)
                    .foregroundStyle(item.selected ? Color.accentColor : .secondary)
                    .opacity(item.deployable ? 1 : 0.3)
            }
            .buttonStyle(.plain)
            .disabled(!item.deployable || item.state.isActive)
            .help(!item.deployable ? L("Deploy Center cannot deploy this project (no Git source it can build from)",
                                       "Deploy Center kann dieses Projekt nicht deployen (keine Git-Quelle, aus der es bauen kann)")
                  : item.state.isActive ? L("A deploy is running", "Ein Deploy läuft gerade") : "")
            .accessibilityLabel(Demo.mask(item.name))
            .accessibilityValue(item.selected ? L("selected", "ausgewählt") : L("not selected", "nicht ausgewählt"))

            Logo(domain: Demo.on ? nil : item.domain, name: Demo.mask(item.name))

            // "3 minutes ago" is kept fresh by one timer around the whole list, not one per row.
            VStack(alignment: .leading, spacing: 3) {
                HStack(spacing: 6) {
                    if pinned { Image(systemName: "pin.fill").font(.caption2).foregroundStyle(.secondary) }
                    Text(Demo.on ? AttributedString(Demo.mask(item.name)) : highlighted(item.name)).font(.body.weight(.medium))
                    // Only red is shown in the row; yellow and the reasons are in the details.
                    if item.hasNewCommits, let r = item.risk, r.isRed {
                        // With "Differentiate without colour" a shape, not only a red dot.
                        Group {
                            if noColour { Image(systemName: "exclamationmark.triangle.fill").font(.caption2).foregroundStyle(.red) }
                            else { Circle().fill(Color.red).frame(width: 7, height: 7) }
                        }
                            .help(L("Risky to ship: ", "Riskant zum Ausliefern: ") + r.reasons.filter { $0.level == "red" }.map(r.text).joined(separator: "; "))
                            .accessibilityHidden(true)   // said in `spoken`
                    }
                    if let d = item.domain, let u = item.link.flatMap(URL.init(string:)) {
                        Button { NSWorkspace.shared.open(u) } label: { Text(Demo.mask(d)).font(.caption) }
                            .buttonStyle(.link).help(L("Open site", "Seite öffnen"))
                    }
                }
                if let note { Label(note, systemImage: "note.text").font(.caption.italic()).foregroundStyle(.secondary) }
                // One figure per row; the rest is in the tooltip and for VoiceOver.
                HStack(spacing: 6) {
                    keyFigure
                    AgentChips(autofix: autofix, allowedUntil: allowedUntil, busy: autofixBusy, onFix: onAutofix, onDeployMerged: onDeployMerged,
                               onDismiss: onDismissAutofix)
                    // A list read only in part: a quiet mark, the reason in its tooltip.
                    let gaps = Self.gapTexts(item)
                    if !gaps.isEmpty {
                        Image(systemName: "info.circle").font(.caption2).foregroundStyle(.secondary)
                            .help(gaps.joined(separator: "\n"))
                            .accessibilityLabel(gaps.joined(separator: ". "))
                    }
                    if showPlatform {
                        Text("· " + item.platform.rawValue).font(.caption2).foregroundStyle(.secondary)
                    }
                }
                .help(moreText)
                reasonLine
            }

            Spacer()

            if let note = item.note, item.state == .idle {
                Text(note)
                    .font(.caption)
                    .padding(.horizontal, 7).padding(.vertical, 2)
                    .background(Capsule().fill(item.auto ? Color.orange.opacity(0.2) : Color.secondary.opacity(0.15)))
            }
            status
            if let showDetails {
                Button(action: showDetails) { Image(systemName: "info.circle") }
                    .buttonStyle(.borderless)
                    .help(L("Details: waiting commits, files, CI, open PRs", "Details: wartende Commits, Dateien, CI, offene PRs"))
                    .accessibilityLabel(L("Details for \(Demo.mask(item.name))", "Details zu \(Demo.mask(item.name))"))
            } else {
                Image(systemName: "info.circle").foregroundStyle(.tertiary)
                    .help(L("No details: no GitHub repo is linked to this project", "Keine Details: mit diesem Projekt ist kein GitHub-Repo verknüpft"))
                    .accessibilityHidden(true)
            }
        }
        .padding(.vertical, 4)
        .contentShape(Rectangle())
        // Not dimmed as a whole (the text would fall under 3:1): the tick is faint and a line says why.
        .onTapGesture { if !item.state.isActive { toggle() } }
    }

    /// Why a deploy failed or was skipped, and why a project cannot be ticked: on screen, not only
    /// in a tooltip, so the keyboard and the trackpad-less get it too. The first line only.
    @ViewBuilder private var reasonLine: some View {
        switch item.state {
        case .failed(let m) where !m.isEmpty:
            Text(Self.firstLine(Demo.scrub(m, items: [item]))).font(.caption).foregroundStyle(.red).lineLimit(1)
                .help(Demo.scrub(m, items: [item]))
        case .skipped(let m) where !m.isEmpty:
            Text(Self.firstLine(Demo.scrub(m, items: [item]))).font(.caption).foregroundStyle(.secondary).lineLimit(1)
                .help(Demo.scrub(m, items: [item]))
        default:
            if !item.deployable {
                Text(L("Cannot be deployed here (no Git source to build from)", "Hier nicht deploybar (keine Git-Quelle zum Bauen)"))
                    .font(.caption).foregroundStyle(.secondary).lineLimit(1)
            }
        }
    }

    static func firstLine(_ s: String) -> String {
        String(s.split(whereSeparator: \.isNewline).first ?? Substring(s)).trimmingCharacters(in: .whitespaces)
    }

    /// One reading of a platform's deploy state for every place that colours it.
    enum Phase { case ok, failed, cancelled, other }
    static func phase(_ raw: String) -> Phase {
        let s = raw.lowercased()
        if ["ready", "live", "succeeded"].contains(s) { return .ok }
        if s == "canceled" || s == "cancelled" { return .cancelled }
        if s.contains("fail") || s == "error" { return .failed }
        return .other
    }

    private func forVoiceOver(_ v: some View) -> some View {
        v
        // VoiceOver: one stop per project, its buttons as actions (VO-Command-Space).
        .accessibilityElement(children: .ignore)
        .accessibilityLabel(spoken)
        .accessibilityValue(item.deployable ? (item.selected ? L("selected", "ausgewählt") : L("not selected", "nicht ausgewählt")) : L("cannot be deployed here", "hier nicht deploybar"))
        .accessibilityAddTraits(item.deployable ? .isButton : [])
        .accessibilityAction { if item.deployable && !item.state.isActive { toggle() } }
        .accessibilityActions {
            if let showDetails { Button(L("Details", "Details"), action: showDetails) }
            if let showLog { Button(L("Build log", "Build-Log"), action: showLog) }
            if case .failed = item.state, let onRetry { Button(L("Try again", "Nochmal versuchen"), action: onRetry) }
            if let onAutofix, !autofixBusy { Button(L("Fix with Claude", "Mit Claude beheben"), action: onAutofix) }
            if item.state.isActive, let onCancel { Button(L("Cancel the deploy", "Deploy abbrechen"), action: onCancel) }
            if let u = item.link.flatMap(URL.init(string:)) { Button(L("Open site", "Seite öffnen")) { NSWorkspace.shared.open(u) } }
        }
    }

    /// What the row's one line shows: a failed last deploy first, then what waits, then the last deploy.
    enum KeyFigure: Equatable { case failed, waiting, lastDeploy, never }
    static func keyFigure(_ i: Item) -> KeyFigure {
        if i.lastAt != nil, phase(i.lastState ?? "") == .failed { return .failed }
        if i.hasNewCommits { return .waiting }
        return i.lastAt == nil ? .never : .lastDeploy
    }

    @ViewBuilder private var keyFigure: some View {
        switch Self.keyFigure(item) {
        case .waiting:
            Label(Self.waitingText(item), systemImage: "arrow.up.circle.fill")
                .font(.caption.weight(.semibold)).foregroundStyle(.blue)
        case .failed, .lastDeploy, .never:
            lastDeploy
        }
    }

    /// Everything the row no longer shows as text: source, last deploy, newest commit, costs, open PRs.
    private var moreText: String {
        var lines = [Demo.on ? item.platform.rawValue : item.detail]
        if Self.keyFigure(item) != .waiting, item.hasNewCommits { lines.append(Self.waitingText(item)) }
        if let at = item.lastAt, Self.keyFigure(item) == .waiting {
            lines.append(L("Last deploy ", "Zuletzt deployt ") + Self.ago(at) + " (" + Self.stateText(item.lastState ?? "") + ")")
        }
        if item.hasNewCommits, let m = item.headMsg {
            lines.append(L("Newest commit: ", "Neuester Commit: ") + (Demo.on ? "…" : m) + (item.headAt.map { " (\(Self.ago($0)))" } ?? ""))
        }
        if item.hasNewCommits, let since = item.oldestPendingAt {
            lines.append(L("Oldest waiting commit ", "Ältester wartender Commit ") + Self.ago(since))
        }
        if let o = item.openPRs, o > 0 { lines.append(Self.openText(item, o)) }
        lines.append(contentsOf: Self.gapTexts(item))
        if let cost, cost >= 0.01 {
            lines.append(L("Builds 7 days: ", "Builds 7 Tage: ") + cost.formatted(.currency(code: "USD"))
                         + (perBuild.map { L(", about ", ", etwa ") + $0.formatted(.currency(code: "USD")) + L(" per build", " pro Build") } ?? ""))
        }
        return lines.filter { !$0.isEmpty }.joined(separator: "\n")
    }

    /// What VoiceOver says for the row: name, what waits, the last deploy and what runs now.
    private var spoken: String {
        var parts = [Demo.mask(item.name), Demo.on ? item.platform.rawValue : item.detail]
        if pinned { parts.append(L("pinned", "angeheftet")) }
        if item.hasNewCommits { parts.append(Self.waitingText(item)) }
        if item.hasNewCommits, item.risk?.isRed == true { parts.append(L("risky to ship", "riskant zum Ausliefern")) }
        if let at = item.lastAt {
            let s = item.lastState ?? ""
            parts.append(L("last deploy ", "zuletzt deployt ") + Self.ago(at) + (Self.phase(s) == .ok ? "" : ", " + Self.stateText(s)))
        }
        switch item.state {
        case .queued: parts.append(queueText ?? L("queued", "in der Schlange"))
        case .starting: parts.append(L("starting", "startet"))
        case .running(let s): parts.append(s)
        case .done: parts.append(item.previewId != nil ? L("preview ready", "Vorschau fertig") : L("live", "live"))
        case .failed(let m): parts.append(L("failed: ", "fehlgeschlagen: ") + Demo.scrub(m, items: [item]))
        case .skipped: parts.append(L("skipped", "übersprungen"))
        case .idle: break
        }
        if let autofix { parts.append(AgentChips.text(autofix)) }
        if let allowedUntil { parts.append(AgentChips.allowedText(allowedUntil)) }
        if let note { parts.append(L("note: ", "Notiz: ") + note) }
        return parts.filter { !$0.isEmpty }.joined(separator: ", ")
    }

    static func waitingText(_ i: Item) -> String {
        if i.rewritten { return L("New changes (branch was rewritten)", "Neue Änderungen (Branch wurde umgeschrieben)") }
        guard let c = i.pendingCommits, c > 0 else { return L("New changes", "Neue Änderungen") }
        let prs = i.pendingPRs ?? 0
        if i.pendingPartial {
            return L("\(c) commits, at least \(prs) \(prs == 1 ? "PR" : "PRs") waiting", "\(c) Commits, mindestens \(prs) \(prs == 1 ? "PR wartet" : "PRs warten")")
        }
        let commits = L("\(c) \(c == 1 ? "commit" : "commits")", "\(c) \(c == 1 ? "Commit" : "Commits")")
        return prs > 0 ? commits + " · " + L("\(prs) \(prs == 1 ? "PR" : "PRs") waiting", "\(prs) \(prs == 1 ? "PR wartet" : "PRs warten")")
                       : commits + L(" waiting", " warten")
    }

    /// What the list could not read this time, in words: shown quietly, it is no error.
    static func gapTexts(_ i: Item) -> [String] {
        var out: [String] = []
        if i.partial {
            out.append(L("The newest builds could not be read: a build under way may not show",
                         "Die neuesten Builds waren nicht lesbar: ein laufender Build fehlt vielleicht"))
        }
        if let w = i.fetchWarn { out.append(CLIText.shown(w)) }
        if i.budgetLow {
            out.append(L("GitHub's hourly budget was nearly spent: waiting commits were not counted this time",
                         "GitHubs Stundenbudget war fast aufgebraucht: wartende Commits wurden diesmal nicht gezählt"))
        }
        return out
    }

    static func openText(_ i: Item, _ o: Int) -> String {
        var parts: [String] = []
        if let d = i.openDrafts, d > 0 { parts.append(L("\(d) \(d == 1 ? "draft" : "drafts")", "\(d) \(d == 1 ? "Entwurf" : "Entwürfe")")) }
        if let b = i.openBots, b > 0 { parts.append(L("\(b) \(b == 1 ? "bot" : "bots")", "\(b) \(b == 1 ? "Bot" : "Bots")")) }
        let base = i.openPRsPartial
            ? L("at least \(o) open PRs", "mindestens \(o) offene PRs")
            : L("\(o) open \(o == 1 ? "PR" : "PRs")", "\(o) \(o == 1 ? "offener PR" : "offene PRs")")
        return parts.isEmpty ? base : base + " (" + parts.joined(separator: ", ") + ")"
    }

    /// Built once: a formatter per row and render was the most expensive part of a list update.
    private static let relative: RelativeDateTimeFormatter = {
        let f = RelativeDateTimeFormatter()
        f.locale = Locale(identifier: isGerman ? "de_DE" : "en_US")
        f.unitsStyle = .full
        return f
    }()

    static func ago(_ d: Date) -> String { relative.localizedString(for: d, relativeTo: Date()) }

    /// Vercel's and Render's deploy states in words ("build_failed" → "Build failed").
    static func stateText(_ raw: String) -> String {
        switch raw.lowercased() {
        case "": return L("unknown", "unbekannt")
        case "ready", "live", "succeeded": return L("live", "live")
        case "error": return L("failed", "fehlgeschlagen")
        case "build_failed": return L("build failed", "Build fehlgeschlagen")
        case "update_failed": return L("update failed", "Update fehlgeschlagen")
        case "pre_deploy_failed": return L("pre-deploy step failed", "Pre-Deploy-Schritt fehlgeschlagen")
        case "canceled", "cancelled": return L("cancelled", "abgebrochen")
        case "deactivated": return L("deactivated", "deaktiviert")
        case "building", "build_in_progress": return L("building", "baut")
        case "update_in_progress": return L("updating", "wird aktualisiert")
        case "pre_deploy_in_progress": return L("pre-deploy step running", "Pre-Deploy-Schritt läuft")
        case "queued", "created": return L("queued", "wartet")
        case "triggered": return L("triggered", "ausgelöst")
        case "initializing": return L("starting", "startet")
        case let s where s.hasPrefix("trigger failed"):
            return L("trigger failed", "Auslösen fehlgeschlagen") + String(raw.dropFirst("trigger failed".count))
        default: return raw.replacingOccurrences(of: "_", with: " ")
        }
    }

    @ViewBuilder private var lastDeploy: some View {
        if let at = item.lastAt {
            let s = (item.lastState ?? "").lowercased()
            let phase = Self.phase(s)
            let ok = phase == .ok, failed = phase == .failed
            HStack(spacing: 4) {
                // Cancelled is neither red nor orange: someone stopped it on purpose.
                if noColour {
                    Image(systemName: ok ? "checkmark.circle" : failed ? "xmark.circle" : phase == .cancelled ? "slash.circle" : "clock").font(.caption2)
                } else {
                    Circle().fill(ok ? Color.green : failed ? Color.red : phase == .cancelled ? Color.secondary : Color.orange).frame(width: 7, height: 7)
                }
                Text(L("Last deploy ", "Zuletzt deployt ") + Self.ago(at) + (ok ? "" : " · " + Self.stateText(s)))
                    .font(.caption).foregroundStyle(.secondary)
                if failed, let showLog {
                    Button(action: showLog) { Image(systemName: "text.alignleft").font(.caption2) }
                        .buttonStyle(.borderless).help(L("Show the build log of the failed deploy", "Build-Log des fehlgeschlagenen Deploys zeigen"))
                        .accessibilityLabel(L("Build log", "Build-Log"))
                }
            }
            .help(at.formatted(date: .complete, time: .shortened) + (item.lastMsg.map { "\n" + (item.triggered ? L("Last triggered: ", "Zuletzt ausgelöst: ") : L("Live now: ", "Jetzt live: ")) + (Demo.on ? "…" : $0) } ?? ""))
        } else {
            Text(L("Never deployed", "Noch nie deployt")).font(.caption).foregroundStyle(.secondary)
        }
    }

    @ViewBuilder private var cancelButton: some View {
        if let onCancel {
            Button(action: onCancel) { Image(systemName: "stop.circle") }
                .buttonStyle(.borderless).help(L("Cancel", "Abbrechen")).accessibilityLabel(L("Cancel the deploy", "Deploy abbrechen"))
        }
    }

    @ViewBuilder private var status: some View {
        switch item.state {
        case .idle:
            EmptyView()
        case .queued:
            HStack(spacing: 6) {
                Image(systemName: "hourglass").foregroundStyle(.secondary)
                Text(queueText ?? L("queued", "in der Schlange")).font(.caption)
                cancelButton
            }
        case .starting:
            HStack(spacing: 6) { ProgressView().controlSize(.small); Text(L("starting", "startet")).font(.caption) }
        case .running(let s):
            HStack(spacing: 6) {
                ProgressView().controlSize(.small)
                if let start = item.startedAt {
                    // Seconds since the start, so a long build is seen as long.
                    TimelineView(.periodic(from: .now, by: 1)) { ctx in
                        // A clock that is a little off must not show "-1:-1".
                        let secs = max(0, Int(ctx.date.timeIntervalSince(start)))
                        Text("\(s) · \(secs / 60):\(String(format: "%02d", secs % 60))"
                             + (usualMinutes.map { L(" (usually ~\($0) min)", " (meist ~\($0) Min)") } ?? ""))
                            .font(.caption.monospacedDigit())
                            // Twice as long as usual: something may be stuck.
                            .foregroundStyle(usualMinutes.map { secs > 120 * $0 } == true ? Color.warningText : Color.primary)
                    }
                } else { Text(s).font(.caption) }
                cancelButton
            }
        case .done(let url):
            HStack(spacing: 6) {
                // A preview is not live: it says so, in blue.
                if item.previewId != nil {
                    Label(L("Preview ready", "Vorschau fertig"), systemImage: "eye.circle.fill").foregroundStyle(.blue).font(.caption.weight(.semibold))
                } else {
                    Label("Live", systemImage: "checkmark.circle.fill").foregroundStyle(.green).font(.caption.weight(.semibold))
                }
                if let url, let u = URL(string: url) {
                    Button { NSWorkspace.shared.open(u) } label: { Image(systemName: "arrow.up.right.square") }
                        .buttonStyle(.borderless).help(url).accessibilityLabel(L("Open the deployed site", "Deployte Seite öffnen"))
                    if item.previewId != nil {
                        CopyButton(title: L("Copy the preview link", "Vorschau-Link kopieren"), systemImage: "link") { url }
                            .buttonStyle(.borderless)
                    }
                }
            }
        case .skipped(let msg):
            Label(L("Skipped", "Übersprungen"), systemImage: "forward.circle.fill")
                .foregroundStyle(.secondary).font(.caption.weight(.semibold))
                .help(Demo.scrub(msg, items: [item]))
        case .failed(let msg):
            HStack(spacing: 4) {
                Label(L("Failed", "Fehler"), systemImage: "xmark.octagon.fill")
                    .foregroundStyle(.red).font(.caption.weight(.semibold))
                    .help(Demo.scrub(msg, items: [item]))
                CopyButton(title: L("Copy the error", "Fehler kopieren"), systemImage: "doc.on.doc") { "\(item.name): \(msg)" }
                    .buttonStyle(.borderless)
                if let showLog {
                    Button(action: showLog) { Image(systemName: "text.alignleft") }
                        .buttonStyle(.borderless).help(L("Build log", "Build-Log")).accessibilityLabel(L("Build log", "Build-Log"))
                }
                if let onRetry {
                    Button(action: onRetry) { Image(systemName: "arrow.clockwise") }
                        .buttonStyle(.borderless).help(L("Try again", "Nochmal versuchen")).accessibilityLabel(L("Try again", "Nochmal versuchen"))
                }
            }
        }
    }
}

/// Autofix and a temporary auto-deploy allowance, as small chips on the row. Own view, so the
/// row's body stays short enough for the type checker of older Xcode versions.
struct AgentChips: View {
    let autofix: RowAutofix?
    let allowedUntil: Date?
    var busy = false
    var onFix: (() -> Void)? = nil
    /// A merged fix: the chip ticks the row and asks to put it live (the PR is in the row's menu).
    var onDeployMerged: (() -> Void)? = nil
    /// "Dismiss": the chip goes until a newer hand-over (Store.dismissAutofix).
    var onDismiss: (() -> Void)? = nil

    static func text(_ a: RowAutofix) -> String {
        switch a {
        case .fixing: return L("Claude is fixing it", "Claude behebt gerade")
        case .waiting(.rateLimit): return L("Autofix waits for the rate limit", "Autofix wartet auf das Rate-Limit")
        case .waiting(.starting): return L("Handing over to Claude …", "Übergabe an Claude …")
        case .waiting(.unclear): return L("Hand-over not confirmed", "Übergabe nicht bestätigt")
        case .prOpen(let n, _): return L("Fix PR #\(n) open", "Fix-PR #\(n) offen")
        case .merged: return L("Fix merged – deploy now", "Fix gemergt – jetzt deployen")
        case .handedBack(.startFailed): return L("Claude could not start", "Claude konnte nicht starten")
        case .handedBack(.fixFailed): return L("Fix failed – over to you", "Fix fehlgeschlagen – an dich übergeben")
        case .noPR: return L("Claude opened no PR", "Claude hat keinen PR geöffnet")
        case .unsupported: return L("Autofix: GitHub repos only", "Autofix: nur GitHub-Repos")
        }
    }
    /// The longer reason, for the tooltip.
    static func help(_ a: RowAutofix) -> String? {
        switch a {
        case .waiting(.rateLimit): return L("Nothing runs yet. The next hand-over comes after the rate limit; you can try by hand.",
                                            "Noch läuft nichts. Die nächste Übergabe kommt nach dem Rate-Limit; du kannst es von Hand versuchen.")
        case .waiting(.unclear): return L("The start was never confirmed. Fix with Claude tries again.",
                                          "Der Start wurde nie bestätigt. „Mit Claude beheben“ versucht es erneut.")
        case .handedBack(.startFailed): return L("The session did not start (token or API). Fix with Claude tries again.",
                                                 "Die Sitzung startete nicht (Token oder API). „Mit Claude beheben“ versucht es erneut.")
        case .unsupported(let r): return r
        default: return nil
        }
    }
    /// Chips that only report: they can be waved away.
    static func dismissable(_ a: RowAutofix?) -> Bool {
        switch a {
        case .noPR?, .handedBack?, .unsupported?, .waiting(.unclear)?: return true
        default: return false
        }
    }
    static func allowedText(_ until: Date) -> String {
        let t = until.formatted(date: Calendar.current.isDateInToday(until) ? .omitted : .abbreviated, time: .shortened)
        return L("Auto-deploy allowed until \(t)", "Auto-Deploy erlaubt bis \(t)")
    }
    /// The page a chip opens; none in demo mode, where a URL would show the repo.
    static func link(_ a: RowAutofix) -> URL? {
        switch a {
        case .fixing(let u), .noPR(let u): return u
        case .prOpen(_, let u), .merged(_, _, let u): return u
        case .handedBack, .waiting, .unsupported: return nil
        }
    }

    var body: some View {
        if let autofix { chip(autofix) }
        if let allowedUntil {
            Label(Self.allowedText(allowedUntil), systemImage: "bolt.badge.clock")
                .font(.caption2.weight(.semibold)).foregroundStyle(.orange)
                .help(L("A temporary allowance: pushes deploy by themselves until then, then auto-deploy goes off again",
                        "Vorübergehend erlaubt: Pushes deployen bis dahin von selbst, danach ist Auto-Deploy wieder aus"))
        }
        if let onFix {
            Button(action: onFix) {
                HStack(spacing: 4) {
                    if busy { ProgressView().controlSize(.mini) } else { Image(systemName: "wand.and.stars") }
                    Text(L("Fix with Claude", "Mit Claude beheben"))
                }
            }
            .buttonStyle(.link).font(.caption2.weight(.semibold)).disabled(busy)
            .help(L("Hand this failed build to your Claude Code routine now; it opens a fix PR",
                    "Diesen fehlgeschlagenen Build jetzt an deine Claude-Code-Routine übergeben; sie öffnet einen Fix-PR"))
        }
    }

    @ViewBuilder private func chip(_ a: RowAutofix) -> some View {
        let (icon, colour): (String, Color) = {
            switch a {
            case .fixing: return ("sparkles", .purple)
            case .waiting: return ("hourglass", .secondary)
            case .unsupported: return ("nosign", .secondary)
            case .prOpen: return ("arrow.triangle.pull", .blue)
            case .merged: return ("checkmark.seal.fill", .green)
            case .handedBack: return ("person.fill.questionmark", Color.warningText)
            case .noPR: return ("exclamationmark.bubble", Color.warningText)
            }
        }()
        if case .merged = a, let onDeployMerged {
            Button(action: onDeployMerged) { Label(Self.text(a), systemImage: icon) }
                .buttonStyle(.link).font(.caption2.weight(.semibold)).foregroundStyle(colour)
                .help(L("Tick it and put the fix live", "Anhaken und den Fix live schalten"))
        } else if let u = Self.link(a), !Demo.on {
            Button { NSWorkspace.shared.open(u) } label: { Label(Self.text(a), systemImage: icon) }
                .buttonStyle(.link).font(.caption2.weight(.semibold)).foregroundStyle(colour)
                .help(u.absoluteString)
        } else {
            Label(Self.text(a), systemImage: icon).font(.caption2.weight(.semibold)).foregroundStyle(colour)
                .help(Self.help(a) ?? "")
        }
        if let onDismiss {
            Button(action: onDismiss) { Image(systemName: "xmark.circle.fill") }
                .buttonStyle(.plain).font(.caption2).foregroundStyle(.secondary)
                .help(L("Dismiss until the next hand-over", "Ausblenden bis zur nächsten Übergabe"))
                .accessibilityLabel(L("Dismiss", "Verwerfen"))
        }
    }
}

/// Above the list while any project may deploy by itself for a while.
struct AllowanceBanner: View {
    @ObservedObject var store: Store
    let allItems: [Item]
    @Environment(\.colorSchemeContrast) private var contrast

    /// Its own function: as one expression in the body it was too long for the type checker on CI.
    static func text(_ on: [AutoDeployAllowance], until last: Date) -> String {
        let names: String = on.prefix(4).map { Demo.mask($0.project) }.joined(separator: ", ")
        let more: String = on.count > 4 ? L(" and \(on.count - 4) more", " und \(on.count - 4) weitere") : ""
        let style: Date.FormatStyle.DateStyle = Calendar.current.isDateInToday(last) ? .omitted : .abbreviated
        let when: String = last.formatted(date: style, time: .shortened)
        return L("Auto-deploy is allowed for a while: ", "Auto-Deploy ist vorübergehend erlaubt: ") + names + more + " · " + L("until ", "bis ") + when
    }
    var body: some View {
        let on = store.activeAllowances
        if let last = on.map(\.expiresAt).max() {
            HStack(spacing: 10) {
                Image(systemName: "bolt.badge.clock.fill").foregroundStyle(.orange)
                Text(Self.text(on, until: last)).font(.caption)
                Spacer()
            }
            .padding(.horizontal, 12).padding(.vertical, 6).background(Color.orange.opacity(contrast == .increased ? 0.2 : 0.08))
        }
    }
}
