// Deploy Center — The main window: list, banners, footer and its questions.
// The costs sheet, the setup screens and one row are in CostsSheet.swift, SetupViews.swift and Row.swift.

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
    /// "Live", "merged", a clean deploy: green, or blue in Settings → General → "Colour-blind
    /// friendly" (FEA-128), so it never hangs on telling red from green. Red stays red; the
    /// symbols (checkmark, octagon) differ as well.
    static var good: Color { UserDefaults.standard.bool(forKey: colorBlindKey) ? Color(red: 0.0, green: 0.45, blue: 0.70) : .green }
    static let colorBlindKey = "colorBlind"
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
    /// ⌘K: the command palette in this window.
    var palette: () -> Void = {}
}

/// What "Put this live now?" says, the same from the footer, a row and the palette.
enum DeployConfirm {
    /// The branch's newest commit, wherever the repo lives.
    static var newest: String { L("The newest commit of the branch goes live.", "Der neueste Stand des Branches geht live.") }

    /// Name, what waits, the platform when two can carry the same name, and a mark when it is risky.
    static func line(_ i: Item, platform: Bool) -> String {
        Demo.mask(i.name)
            + (platform ? " (\(i.platform.rawValue))" : "")
            + ((i.pendingCommits ?? 0) > 0 ? " – " + Row.waitingText(i) : "")
            + (i.hasNewCommits && i.risk?.isRed == true ? "  ⚠︎ " + L("risky", "riskant") : "")
    }

    /// At most 12 lines, so the dialog does not grow past the screen.
    static func message(_ items: [Item], platforms: Bool) -> String {
        items.prefix(12).map { line($0, platform: platforms) }.joined(separator: "\n")
            + (items.count > 12 ? "\n" + L("and \(items.count - 12) more", "und \(items.count - 12) weitere") : "")
            + "\n\n" + newest
    }

    /// The ticked ones already on their newest commit: building them costs and changes nothing.
    static func unchangedNote(_ items: [Item]) -> String {
        let same = items.filter { !$0.hasNewCommits && $0.headSha != nil }.map { Demo.mask($0.name) }
        guard !same.isEmpty else { return "" }
        return "\n\n" + L("Already up to date, builds anyway: ", "Schon aktuell, baut trotzdem: ") + same.joined(separator: ", ")
    }
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
            Button(L("Command Palette …", "Befehlspalette …")) { actions?.palette() }.keyboardShortcut("k").disabled(actions == nil)
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
    @Environment(\.openWindow) private var openWindow
    // The tab and the filter are remembered between launches. The tab is a provider id ("vercel");
    // older versions kept "Vercel", which reads the same lowercased.
    @AppStorage("lastPlatform") private var platformRaw = "vercel"
    // Read by Color.good; here so the list draws again when it is switched.
    @AppStorage(Color.colorBlindKey) private var colorBlind = false
    @State private var search = ""
    @State private var confirming = false
    @State private var confirmingOff = false
    /// The checkbox in the deploy confirmation: only commits whose CI passed go out. Remembered.
    @AppStorage("onlyWhenGreen") private var onlyGreen = false
    /// The deploy window's rule while it is closed, the platforms waiting for "Deploy anyway…", and why.
    @State private var freezeReason: String?
    /// What "Deploy anyway" starts, with the reason, once the deploy window was found closed.
    @State private var frozenRun: ((String) -> Void)?
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
    @Environment(\.openSettings) private var openSettings
    @Environment(\.colorSchemeContrast) private var contrast
    /// A single deploy from the row menu, asked first like from the palette.
    @State private var askDeployItem: Item?
    /// Deploy was clicked in the question: started once its sheet is gone.
    @State private var confirmedItem: Item?
    @State private var confirmedAll = false
    @AppStorage("confirmSingleDeploy") private var confirmSingle = true
    @State private var confirmingStop = false
    /// The project a menu-bar click or a link asked for: the list shows exactly that one (by its
    /// `Store.key`, so "app" on Vercel is not shown with "app" on Render), or every one of that name.
    @State private var exactName: String?
    @State private var exactKey: String?
    /// Load errors shown in full (the banner shows two lines first).
    @State private var expandedErrors: Set<Platform> = []
    /// Triggers the person chose to ignore (kept), provider problems closed until they change,
    /// and an update skipped until the next version.
    @AppStorage("ignoredTriggers") private var ignoredTriggers = ""
    /// Kept across launches; the same problems in another order are still the closed ones.
    @AppStorage("closedProviderIssues") private var closedIssuesRaw = ""
    static func issuesKey(_ issues: [String]) -> String { Set(issues).sorted().joined(separator: "\n") }
    private var providerIssuesClosed: Bool { !closedIssuesRaw.isEmpty && Self.issuesKey(store.providerIssues) == closedIssuesRaw }
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
    /// The project a message is about, while it is still in the list and has a build log.
    private func messageItem(_ m: Store.Message) -> Item? {
        guard let k = m.project, let i = allItems.first(where: { Store.key($0) == k }),
              store.provider(i.platform)?.caps.logs != false else { return nil }
        return i
    }

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

    /// Projects with changes on a platform, without the hidden ones: the list leaves them out too.
    static func changedShown(_ store: Store, _ p: Platform) -> Int { store.changedCount(p) }

    /// Under a repo header: "3 projects · 12 commits waiting". The commits are the branch's, so the
    /// largest count of one project, not the sum (they share the commits).
    static func repoSummary(_ items: [Item]) -> String {
        let n = items.count
        let waiting = items.filter { $0.hasNewCommits }.compactMap(\.pendingCommits).max() ?? 0
        let projects = L("\(n) \(n == 1 ? "project" : "projects")", "\(n) \(n == 1 ? "Projekt" : "Projekte")")
        guard waiting > 0 else { return projects }
        return projects + " · " + L("\(waiting) \(waiting == 1 ? "commit waits" : "commits waiting")",
                                    "\(waiting) \(waiting == 1 ? "Commit wartet" : "Commits warten")")
    }

    /// "35" projects, or "35 · 9" when 9 of them have changes waiting.
    private static func tabCount(_ store: Store, _ p: Platform) -> String {
        let n = store.items[p]?.count ?? 0, c = Self.changedShown(store, p)
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
        let n = store.items[p]?.count ?? 0, c = Self.changedShown(store, p)
        return L("\(p.rawValue), \(n) projects, \(c) with changes", "\(p.rawValue), \(n) Projekte, \(c) mit Änderungen")
    }

    /// The platforms the list shows: the tab's, or every enabled one under "All".
    private var scopes: [Platform] { showsAll ? providers.compactMap(\.platform) : (platform.map { [$0] } ?? []) }

    private var visible: [Item] {
        var all = scopes.flatMap { store.items[$0] ?? [] }.filter { !store.isHidden($0) }
        if onlyChanged { all = all.filter { $0.hasNewCommits } }
        if let key = exactKey {
            all = all.filter { Store.key($0) == key }
        } else if let exact = exactName {
            all = all.filter { $0.name == exact }
        } else if !search.isEmpty {
            // In demo mode only the stand-in counts: typing a real name must not find the project.
            all = all.filter { Demo.on ? Row.matches(Demo.mask($0.name), search)
                : Row.matches($0.name, search) || Row.matches($0.detail, search) || Row.matches($0.domain ?? "", search) }
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
                    .overlay(Capsule().stroke(t.ok ? Color.good.opacity(0.5) : Color.red.opacity(0.5)))
                    // The pointer on it holds it, so a long message can be read to the end.
                    .onHover { store.holdToast($0) }
                    .padding(.bottom, 72)
                    // Esc closes it, like any passing message.
                    .background {
                        Button("") { store.toast = nil; stickyError = nil }
                            .keyboardShortcut(.cancelAction)
                            .opacity(0).frame(width: 0, height: 0).accessibilityHidden(true)
                    }
                    // With "Reduce motion" it only fades.
                    .transition(reduceMotion ? .opacity : .move(edge: .bottom).combined(with: .opacity))
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
                                           reload: { reloadNow() }, speak: { Speech.say(store.spokenSummary) },
                                           palette: { PaletteCenter.shared.open(in: NSApp.keyWindow) }))
        .animation(reduceMotion ? nil : .easeOut(duration: 0.2), value: store.toast)
    }

    /// Projects that still deploy by themselves, over all platforms.
    private var autoOnTotal: Int { Platform.allCases.reduce(0) { $0 + store.autoOn($1).count } }
    /// Someone who used the app before this version has a history: no first start for them.
    private func checkFirstStartOnce() {
        let d = UserDefaults.standard
        guard !firstStartDone, d.object(forKey: "firstStartChecked") == nil else { return }
        d.set(true, forKey: "firstStartChecked")
        let used: Bool = !Journal.load(limit: 1).isEmpty || d.object(forKey: "lastPlatform") != nil
        if used { firstStartDone = true }
    }

    /// The sheets in two layers: one long chain was too much for the type checker on CI.
    private var withFirstSheets: some View {
        chrome
        .sheet(item: $logItem) { item in BuildLog(store: store, item: item) }
        .sheet(isPresented: $showJournal) { JournalView(costs: store.costs) }
        .sheet(isPresented: $showFirstStart) { FirstStartView(store: store) }
        .onAppear { checkFirstStartOnce() }
        .onChange(of: autoOnTotal + (firstStartDone ? 0 : 1_000_000)) { _, _ in
            if FirstStart.due(done: firstStartDone, autoOn: autoOnTotal), !Demo.on { showFirstStart = true }
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
    }

    private var withSheets: some View {
        withFirstSheets
        .sheet(item: $detailItem) { item in ProjectDetail(store: store, item: item, deployCommit: store.observer ? nil : { sha in deployOne(item, sha: sha) },
                                                         // After the detail sheet is gone, so the log can take its place.
                                                         openLog: { DispatchQueue.main.asyncAfter(deadline: .now() + 0.35) { logItem = item } })
                // The open project can be continued on the iPhone (Handoff); not in demo mode, which hides names.
                .userActivity(Handoff.type, isActive: !Demo.on) { a in
                    a.title = item.name; a.userInfo = ["project": Handoff.key(item)]
                    a.isEligibleForHandoff = true; a.isEligibleForSearch = false
                }
        }
        .onChange(of: store.pendingDeploy?.id) { _, _ in
            guard let i = store.pendingDeploy else { return }
            store.pendingDeploy = nil
            deployOne(i)
        }
        .onChange(of: store.pendingDeployAll) { _, go in
            guard go else { return }
            store.pendingDeployAll = false
            showAllNow = true; onlyChangedNow = true
            // Only platforms with a tab: a ticked project on a switched-off one would deploy unseen.
            providers.compactMap(\.platform).forEach { store.selectChanged($0) }
            if !selectedAll.isEmpty { confirming = true }
        }
        // One question for the footer, a row and the palette; the deploy starts once the sheet is gone.
        .sheet(item: $askDeployItem, onDismiss: {
            if let i = confirmedItem { confirmedItem = nil; deployOne(i) }
        }) { i in DeployConfirmSheet(items: [i], platforms: false) { confirmedItem = i } }
        .sheet(isPresented: $confirming, onDismiss: {
            if confirmedAll { confirmedAll = false; startDeploy() }
        }) {
            DeployConfirmSheet(items: selectedAll, platforms: showsAll,
                               costNote: Store.costNote(perBuild: selectedAll.map { $0.platform == .vercel ? store.costs?.perBuild($0.name) : nil },
                                                        month: store.monthPace, budget: UserDefaults.standard.double(forKey: "monthlyBudget"))) { confirmedAll = true }
        }
        // Each on a view of its own: one long chain of alerts is too much for the type checker.
        .background {
            Color.clear.alert(stopTitle, isPresented: $confirmingStop) {
                Button(L("Keep running", "Weiterlaufen lassen"), role: .cancel) {}
                Button(L("Stop all", "Alles abbrechen"), role: .destructive) { store.cancelAll() }
            } message: {
                Text(stopAllText)
            }
        }
    }

    /// How many deploys "Stop all" ends (it ends them on every platform).
    private var stopAllText: String {
        let n = allItems.filter { $0.state.isActive }.count
        return L("\(n) running or waiting \(n == 1 ? "deploy is" : "deploys are") cancelled.",
                 "\(n) \(n == 1 ? "laufender oder wartender Deploy wird" : "laufende oder wartende Deploys werden") abgebrochen.")
    }

    private var dialogs: some View {
        withSheets
        .alert(L("Check after deploy", "Prüfung nach dem Deploy"), isPresented: Binding(get: { pathItem != nil }, set: { if !$0 { pathItem = nil } })) {
            TextField("/health, /api/ping", text: $pathText)
            TextField(L("Text the page must show (optional)", "Text, den die Seite zeigen muss (optional)"), text: $siteText)
            Button(L("Cancel", "Abbrechen"), role: .cancel) { pathItem = nil }
            Button(L("Save", "Speichern")) { if let i = pathItem { store.setHealthPath(i, pathText); store.setSiteText(i, siteText) }; pathItem = nil }
        } message: {
            Text(L("These paths (comma-separated, up to five) are asked once \(shown(pathItem?.name)) is live, instead of the front page. Empty = front page. The text is looked for on the front page; missing, it only warns.",
                   "Diese Pfade (mit Komma getrennt, bis zu fünf) werden abgefragt, sobald \(shown(pathItem?.name)) live ist, statt der Startseite. Leer = Startseite. Der Text wird auf der Startseite gesucht; fehlt er, gibt es nur eine Warnung."))
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
        // The palette flips the filter that is on screen (through this counter), not only the stored one.
        // Received, not observed: the window does not redraw for every palette request.
        .onReceive(PaletteCenter.shared.$filterToggles.dropFirst()) { _ in onlyChanged.toggle() }
        .onChange(of: store.pendingShow) { _, req in
            guard let req else { return }
            // Exactly this project: "app" as a plain search would also show "app-backend".
            showAllNow = true; onlyChangedNow = false; search = Demo.mask(req.name); exactName = req.name; exactKey = req.key
            store.pendingShow = nil
        }
        .onChange(of: search) { _, s in if let n = exactName, s != Demo.mask(n) { exactName = nil; exactKey = nil } }
        .onChange(of: store.settingsRequest) { _, tab in
            guard tab != nil else { return }
            store.settingsRequest = nil
            NSApp.activate(ignoringOtherApps: true); openSettings()
        }
        .alert(L("Nothing new to deploy", "Nichts Neues zu deployen"),
               isPresented: Binding(get: { unchangedItem != nil }, set: { if !$0 { unchangedItem = nil } })) {
            Button(L("Cancel", "Abbrechen"), role: .cancel) { unchangedItem = nil }
            Button(L("Build anyway", "Trotzdem bauen")) { if let i = unchangedItem { deployOne(i) }; unchangedItem = nil }
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
        .alert(L("The deploy window is closed", "Das Deploy-Fenster ist zu"),
               isPresented: Binding(get: { freezeReason != nil }, set: { if !$0 { freezeReason = nil } })) {
            Button(L("Cancel", "Abbrechen"), role: .cancel) { freezeReason = nil; frozenRun = nil }
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
                guard !why.isEmpty else {
                    // The dialog closes anyway; say why nothing started instead of doing nothing.
                    frozenRun = nil
                    store.show(Store.Toast(text: L("Nothing deployed: a reason is needed while the deploy window is closed.",
                                                   "Nichts deployt: Bei geschlossenem Deploy-Fenster braucht es einen Grund."), ok: false))
                    return
                }
                frozenRun?(why); frozenRun = nil
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

            // Demo mode is easy to forget (⇧⌘D): say so where the names are.
            if demoMode {
                Text("DEMO").font(.caption.weight(.bold)).foregroundStyle(.white)
                    .padding(.horizontal, 6).padding(.vertical, 2).background(Capsule().fill(Color.purple))
                    .help(L("Demo mode: names are stand-ins. ⇧⌘D turns it off.", "Demo-Modus: Namen sind Platzhalter. ⇧⌘D schaltet ihn aus."))
                    .accessibilityLabel(L("Demo mode is on", "Demo-Modus ist an"))
            }

            TextField(L("Search", "Suchen"), text: $search).textFieldStyle(.roundedBorder)
                .frame(minWidth: 110)
                .layoutPriority(1)
                .focused($searchFocused)
                .onExitCommand { search = ""; searchFocused = false }

            Toggle(isOn: Binding(get: { onlyChanged }, set: { onlyChanged = $0 })) {
                Text(L("Changed only", "Nur mit Änderungen") + " (\(scopes.map { Self.changedShown(store, $0) }.reduce(0, +)))")
            }
            .toggleStyle(.button)
            .fixedSize()
            .help(L("Only projects with a merged commit that is not live yet",
                    "Nur Projekte mit einem gemergten Commit, der noch nicht live ist"))

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
        if !store.providerIssues.isEmpty && !providerIssuesClosed { out.append(.provider) }
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

    /// Red for builds that cost money unasked, orange for what needs a look, grey for offers.
    static func noticeLook(_ n: Notice) -> (symbol: String, colour: Color) {
        switch n {
        case .trigger: return ("exclamationmark.triangle.fill", .red)
        case .loadFailed, .github, .provider, .tools: return ("exclamationmark.circle.fill", .orange)
        case .auto, .allowance: return ("dollarsign.circle.fill", .orange)
        case .setup, .claude: return ("info.circle", .secondary)
        }
    }

    /// "Ignore" on a build trigger, with a way back for a slip.
    private func ignore(_ tr: Trigger) {
        ignoredTriggers += (ignoredTriggers.isEmpty ? "" : "\n") + tr.id
        store.show(Store.Toast(text: L("Ignored: \(Self.triggerName(tr.kind))", "Ignoriert: \(Self.triggerName(tr.kind))"), ok: true,
                               undoLabel: L("Undo", "Rückgängig"), undo: {
            ignoredTriggers = ignoredTriggers.split(separator: "\n").map(String.init).filter { $0 != tr.id }.joined(separator: "\n")
        }))
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
                            if !noticesExpanded {
                                // How urgent the folded ones are, without opening them: a symbol and a colour each.
                                ForEach(Array(all.dropFirst()), id: \.self) { n in
                                    Image(systemName: Self.noticeLook(n).symbol).foregroundStyle(Self.noticeLook(n).colour)
                                        .accessibilityHidden(true)
                                }
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
                            Button(L("Ignore", "Ignorieren")) { ignore(tr) }
                                .buttonStyle(.link).font(.caption)
                        }
                    }
                    if triggers.count > 6 {
                        Text(L("and \(triggers.count - 6) more", "und \(triggers.count - 6) weitere")).font(.caption).foregroundStyle(.secondary)
                    }
                    // The last read failed: this list is an older one.
                    if let s = store.staleNote("triggers") { Text(s).font(.caption).foregroundStyle(.secondary) }
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
                ForEach(store.statusLinks.filter { p in store.providerIssues.contains { $0.hasPrefix(p.label + ":") } }, id: \.label) { p in
                    Button(L("\(p.label) status", "Status \(p.label)")) { NSWorkspace.shared.open(p.url) }.buttonStyle(.link).font(.caption)
                }
                Button { closedIssuesRaw = Self.issuesKey(store.providerIssues) } label: { Image(systemName: "xmark") }
                    .buttonStyle(.borderless).help(L("Close until it changes", "Schließen, bis sich etwas ändert"))
                    .accessibilityLabel(L("Close", "Schließen"))
            }
            .padding(.horizontal, 12).padding(.vertical, 6).background(ground(.orange, 0.08))
        }
    }

    static func triggerName(_ k: String) -> String {
        switch k {
        case "workflow": return L("GitHub workflow deploys", "GitHub-Workflow deployt")
        case "vercel-build": return L("Vercel build from Git", "Vercel-Build von Git")
        case "render-build": return L("Render build from push", "Render-Build durch Push")
        case "render-blueprint": return L("Render Blueprint auto-sync", "Render-Blueprint Auto-Sync")
        default: return unknownCode(k, L("build trigger", "Build-Auslöser"))
        }
    }

    /// What the confirmation's Deploy does: inside a closed deploy window it asks first.
    private func startDeploy() {
        let chosen = scopes, green = onlyGreen, count = selectedAll.count
        Task {
            if OwnerCheck.needed(projects: count),
               !(await OwnerCheck.confirm(L("put \(count) projects live", "\(count) Projekte live schalten"))) { return }
            if let w = await store.deployWindow(), w.denied {
                frozenRun = { why in chosen.forEach { store.deploySelected($0, whenGreen: green, force: why) } }
                freezeReason = w.reason ?? ""; return
            }
            chosen.forEach { store.deploySelected($0, whenGreen: green) }
        }
    }

    private var stopTitle: String {
        let n = allItems.filter { $0.state.isActive }.count
        return L("Stop \(plural(n, "deploy", "deploys"))?", "\(plural(n, "Deploy", "Deploys")) abbrechen?")
    }

    /// One project (row menu, retry, palette, a commit in the details): the same way as the ticked
    /// ones – a closed deploy window asks first, and "only when checks are green" holds. A preview
    /// is not live, the script lets it through the window as well.
    private func deployOne(_ item: Item, preview: Bool = false, sha: String? = nil, clearCache: Bool = false) {
        let green = onlyGreen && !preview
        guard !preview else { store.deployOne(item, preview: true); return }
        Task {
            if let w = await store.deployWindow(), w.denied {
                frozenRun = { why in store.deployOne(item, preview: false, sha: sha, clearCache: clearCache, whenGreen: green, force: why) }
                freezeReason = w.reason ?? ""; return
            }
            store.deployOne(item, preview: false, sha: sha, clearCache: clearCache, whenGreen: green)
        }
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
                // The time left, counted down once a minute, next to the clock time.
                TimelineView(.everyMinute) { ctx in
                    let reset = Date(timeIntervalSince1970: b.reset)
                    let mins = max(0, Int(ceil(reset.timeIntervalSince(ctx.date) / 60)))
                    Text(L("GitHub's hourly budget is nearly spent (\(b.remaining) of \(b.limit) left). Counts pause until ",
                           "GitHubs Stunden-Kontingent ist fast aufgebraucht (\(b.remaining) von \(b.limit) übrig). Die Zahlen pausieren bis ")
                         + reset.formatted(date: .omitted, time: .shortened)
                         + (mins > 0 ? L(" (in \(mins) min).", " (in \(mins) Min).") : L(", back at the next reload.", ", zurück beim nächsten Neuladen.")))
                        .font(.caption)
                }
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
                            // The last read failed: an older number, said as such.
                            if let s = store.staleNote("costs") { Text("· " + s).font(.caption).foregroundStyle(Color.warningText) }
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
            lines.append(L("\(w.commits) \(w.commits == 1 ? "commit" : "commits") in \(w.projects) \(w.projects == 1 ? "project" : "projects"), merged and not live",
                           "\(w.commits) \(w.commits == 1 ? "Commit" : "Commits") in \(w.projects) \(w.projects == 1 ? "Projekt" : "Projekten"), gemergt und nicht live"))
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

    /// "Vercel could not be loaded (09:12) – showing the list from 09:02": its own function, as one
    /// expression in the banner it was too long for the type checker on CI.
    private func loadFailedTitle(_ p: Platform, at: Date) -> String {
        let head: String = L("\(p.rawValue) could not be loaded", "\(p.rawValue) konnte nicht geladen werden")
        let when: String = " (" + at.formatted(date: .omitted, time: .shortened) + ")"
        guard let shown = store.loadedAt[p] else { return head + when }
        let tail: String = L(" – showing the list from ", " – zu sehen ist der Stand von ") + shown.formatted(date: .omitted, time: .shortened)
        return head + when + tail
    }

    /// The script's own words, for a bug report: folded away, copyable, next to the log.
    private func errorDetails(_ raw: String) -> some View {
        DisclosureGroup(L("Details", "Details")) {
            VStack(alignment: .leading, spacing: 4) {
                Text(raw).font(.caption.monospaced()).foregroundStyle(.secondary).textSelection(.enabled)
                    .fixedSize(horizontal: false, vertical: true)
                HStack {
                    CopyButton(title: L("Copy the error", "Fehler kopieren")) { LogTools.maskSecrets(raw) }
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

    @ViewBuilder private func loadFailedBanner(_ p: Platform) -> some View {
        if let f = store.lastLoadError[p] {
            let raw = Demo.scrub(f.message, items: allItems)
            HStack(alignment: .top, spacing: 10) {
                Image(systemName: "exclamationmark.triangle.fill").foregroundStyle(.orange)
                VStack(alignment: .leading, spacing: 2) {
                    Text(loadFailedTitle(p, at: f.at))
                        .font(.callout.weight(.medium))
                    if let nice = Self.friendlyError(f.message, p.rawValue) {
                        Text(nice).font(.caption).foregroundStyle(.secondary)
                    }
                    errorDetails(raw)
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
                && Row.matches(Demo.on ? Demo.mask($0.name) : $0.name, search) }.count
            VStack(spacing: 8) {
                Image(systemName: !search.isEmpty ? "magnifyingglass" : elsewhere.isEmpty ? "checkmark.seal.fill" : "checkmark.circle").font(.system(size: 34))
                    .foregroundStyle(search.isEmpty && elsewhere.isEmpty ? Color.good : .secondary)
                Text(!search.isEmpty ? L("Nothing matches “\(search)”", "Nichts passt zu „\(search)“")
                     : elsewhere.isEmpty ? L("Everything is live", "Alles ist live")
                     : L("Nothing waits on \(currentLabel)", "Bei \(currentLabel) wartet nichts"))
                    .font(.headline)
                ForEach(elsewhere, id: \.self) { p in
                    let n = store.changedCount(p)
                    Button(L("\(plural(n, "project waits", "projects wait")) on \(p.rawValue)", "\(plural(n, "Projekt wartet", "Projekte warten")) bei \(p.rawValue)")) {
                        select(.provider(p.cli))
                    }
                    .buttonStyle(.link)
                }
                if hiddenHits > 0 {
                    Text(L("\(hiddenHits) hidden \(hiddenHits == 1 ? "project matches" : "projects match") (\(SettingsTab.projects.path))",
                           "\(hiddenHits) \(hiddenHits == 1 ? "ausgeblendetes Projekt passt" : "ausgeblendete Projekte passen") (\(SettingsTab.projects.path))"))
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
                     ? L("\(hiddenHere) hidden. Show them again in \(SettingsTab.projects.path).", "\(hiddenHere) ausgeblendet. Wieder zeigen unter \(SettingsTab.projects.path).")
                     : L("This account has no projects on \(scopes.map(\.rawValue).joined(separator: " or ")).", "Dieses Konto hat keine Projekte bei \(scopes.map(\.rawValue).joined(separator: " oder "))."))
                    .font(.caption).foregroundStyle(.secondary)
                if hiddenHere > 0 { Button(L("Open Settings", "Einstellungen öffnen")) { store.openSettings(.projects) } }
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
            Text(Demo.mask(repo) + " · " + Self.repoSummary(items)).font(.caption.weight(.semibold)).foregroundStyle(.secondary)
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
        .accessibilityLabel(L("Repository \(Demo.mask(repo)), ", "Repository \(Demo.mask(repo)), ") + Self.repoSummary(items))
    }

    private func row(_ item: Item, _ costRows: [String: Costs.Project], _ complete: Bool) -> some View {
        let c = item.platform == .vercel ? costRows[item.name] : nil
        // Worked out once per row; the row and its background both need it.
        let fix = store.autofixState(item)
        return Row(item: item, showPlatform: showsAll, cost: c?.build,
            perBuild: complete ? c.flatMap { p in p.builds.flatMap { $0 > 0 ? p.build / Double($0) : nil } } : nil,
            pinned: store.isPinned(item), note: store.note(item),
            showDetails: item.repo == nil ? nil : { detailItem = item },
            // No log button where the platform has no build logs (Netlify, say): it would only fail.
            showLog: store.provider(item.platform)?.caps.logs == false ? nil : { logItem = item },
            onCancel: { store.cancel(item) },
            onRetry: item.deployable && !store.observer ? { deployOne(item) } : nil,
            usualMinutes: store.usualMinutes(item), queueText: store.queueText(item), search: search,
            autofix: fix, allowedUntil: store.allowance(item)?.expiresAt,
            autofixBusy: store.autofixBusy(item),
            onAutofix: store.canFixWithClaude(item) ? { Task { await store.fixWithClaude(item) } } : nil,
            onDeployMerged: item.deployable && !store.observer && !item.state.isActive ? {
                if !item.selected { store.toggle(item.platform, item.id) }
                confirming = true
            } : nil,
            onDismissAutofix: AgentChips.dismissable(fix) ? { store.dismissAutofix(item) } : nil,
            colorTag: store.projectColor(item)) { tick(item) }
            // A merged fix waits for a click: the row stands out until it is live.
            .listRowBackground(isMerged(fix) ? ground(Color.good, 0.12) : nil)
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
            // Asks first, like the palette: with no wait set, a slip of the mouse would start a paid build.
            // Settings → Deploy can turn that off for single deploys (both ways at once).
            Button(confirmSingle ? L("Deploy to production …", "Live deployen …") : L("Deploy to production", "Live deployen")) {
                if item.hasNewCommits || item.headSha == nil { if confirmSingle { askDeployItem = item } else { deployOne(item) } }
                else { unchangedItem = item }
            }
        }
        if store.provider(item.platform)?.caps.logs ?? true {   // unknown: offered, as before
            Button(L("Build log …", "Build-Log …")) { logItem = item }
        }
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
                Button(L("Open in its own window", "In eigenem Fenster öffnen")) { openWindow(id: "project", value: Store.key(item)) }
            }
            if canDeploy {
                if caps.preview {
                    Button(L("Preview deploy (not live)", "Vorschau-Deploy (nicht live)")) { deployOne(item, preview: true) }
                }
                if item.platform == .render {
                    Button(L("Deploy with a cleared build cache", "Mit geleertem Build-Cache deployen")) { deployOne(item, clearCache: true) }
                }
                if store.provider(item.platform)?.caps.rollback ?? true {
                    Button(L("Roll back production …", "Live zurückrollen …")) { rollbackItem = item }
                }
            }
            if let u = item.compareURL {
                let host = GitHost(item).name
                Button(L("Show the waiting commits on \(host)", "Wartende Commits auf \(host) ansehen")) { NSWorkspace.shared.open(u) }
            }
            if let u = item.dashboardURL {
                Button(L("Open in the Render dashboard", "Im Render-Dashboard öffnen")) { NSWorkspace.shared.open(u) }
            } else if item.platform == .vercel {
                // Vercel's address needs the team's slug; the script knows it, as in the palette.
                Button(L("Open in the Vercel dashboard", "Im Vercel-Dashboard öffnen")) {
                    Task {
                        do { _ = try await Tool.run(["open", item.id, "--dashboard"], timeout: 30) }
                        catch { store.show(Store.Toast(text: Tool.shorten(error.localizedDescription), ok: false)) }
                    }
                }
            }
            Divider()
            Button(store.isPinned(item) ? L("Unpin", "Nicht mehr anheften") : L("Pin to the top", "Oben anheften")) { store.togglePin(item) }
            Picker(L("Colour", "Farbe"), selection: Binding(get: { store.projectColor(item) ?? "" }, set: { store.setProjectColor(item, $0.isEmpty ? nil : $0) })) {
                Text(L("None", "Keine")).tag("")
                ForEach(Store.projectColorNames, id: \.self) { Text(Row.tagName($0)).tag($0) }
            }
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
        for p in scopes { store.selectChanged(p, only: keys) }
    }

    /// Ticked projects on platforms that can build a preview.
    private var previewScopes: [Platform] {
        scopes.filter { store.provider($0)?.caps.preview == true && !store.selected($0).isEmpty }
    }

    private var footer: some View {
        let count = selectedAll.count
        let changedHere = scopes.map { Self.changedShown(store, $0) }.reduce(0, +)
        return HStack {
            Text(count == 0 ? L("Tick the projects that should go live", "Projekte anhaken, die live gehen sollen")
                            : L("\(count) selected", "\(count) ausgewählt"))
                .foregroundStyle(.secondary)
                .help(L("Shift-click ticks everything between the last tick and this one", "Mit ⇧-Klick wird alles zwischen dem letzten Haken und diesem angehakt"))
            // Ticks on another tab still count there: say they exist.
            let elsewhere = providers.compactMap(\.platform).filter { !scopes.contains($0) }.map { p in (p, store.selected(p).count) }.filter { $0.1 > 0 }
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
                    .help(L("This Mac only looks. Turn it off in \(SettingsTab.team.path).", "Dieser Mac schaut nur zu. Abschalten unter \(SettingsTab.team.path)."))
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
            // ⌘A belongs to the hidden button below the footer only: two items with one shortcut could
            // both fire. The title names the key instead.
            Button(waitsForFreshList ? L("Select all changed (waits for the fresh list)", "Alle mit Änderungen anhaken (wartet auf die frische Liste)")
                                     : L("Select all changed (⌘A)", "Alle mit Änderungen anhaken (⌘A)")) { selectAllCommand() }
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
                        Image(systemName: m.ok ? "checkmark.circle.fill" : "xmark.octagon.fill").foregroundStyle(m.ok ? Color.good : .red)
                        Text(m.date.formatted(date: .omitted, time: .shortened)).font(.caption.monospacedDigit()).foregroundStyle(.secondary)
                        Text(Demo.scrub(m.text, items: allItems)).font(.caption).textSelection(.enabled)
                        Spacer(minLength: 0)
                        // A line about one project opens its build log (failed ones first of all).
                        if let item = messageItem(m) {
                            Button(L("Log", "Log")) { showMessages = false; logItem = item }
                                .buttonStyle(.link).font(.caption)
                                .accessibilityLabel(L("Open the build log of \(Demo.mask(item.name))", "Build-Log von \(Demo.mask(item.name)) öffnen"))
                        }
                    }
                }
                Divider()
                Button(L("Clear", "Leeren")) { store.messages.removeAll(); showMessages = false }
                    .buttonStyle(.link).font(.caption)
            }
            .padding(12).frame(width: 460, alignment: .leading)
        }
    }
}
