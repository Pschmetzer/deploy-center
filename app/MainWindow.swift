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

/// Commands of the main window, in the View menu: they show ⌘1–3 and ⌘F where people look for them.
struct WindowActions {
    var tab: (Int) -> Void
    var search: () -> Void
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
            Button(L("All", "Alle")) { actions?.tab(0) }.keyboardShortcut("3").disabled(actions == nil)
            Button("Vercel") { actions?.tab(1) }.keyboardShortcut("1").disabled(actions == nil)
            Button("Render") { actions?.tab(2) }.keyboardShortcut("2").disabled(actions == nil)
            Button(L("Search", "Suchen")) { actions?.search() }.keyboardShortcut("f").disabled(actions == nil)
            Divider()
        }
    }
}

struct ContentView: View {
    @ObservedObject var store: Store
    // The tab and the filter are remembered between launches.
    @AppStorage("lastPlatform") private var platformRaw = Platform.vercel.rawValue
    private var platform: Platform { get { Platform(rawValue: platformRaw) ?? .vercel } nonmutating set { platformRaw = newValue.rawValue } }
    @State private var search = ""
    @State private var confirming = false
    @State private var confirmingOff = false
    /// The platform whose auto-deploy banner was clicked (on "All" both can have one).
    @State private var offPlatform = Platform.vercel
    @AppStorage("onlyChanged") private var onlyChanged = false
    @State private var rollbackItem: Item?
    @FocusState private var searchFocused: Bool
    @State private var unchangedItem: Item?
    @State private var detailItem: Item?
    @AppStorage("showAll") private var showAll = false
    @State private var pathItem: Item?
    @State private var showMessages = false
    @State private var showJournal = false
    @State private var pathText = ""
    @State private var noteItem: Item?
    @State private var noteText = ""
    @State private var logItem: Item?
    @Environment(\.colorSchemeContrast) private var contrast
    /// Triggers the person chose to ignore (kept), provider problems closed until they change,
    /// and an update skipped until the next version.
    @AppStorage("ignoredTriggers") private var ignoredTriggers = ""
    @State private var closedIssues: [String] = []
    @AppStorage("skippedVersion") private var skippedVersion = ""
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

    /// The platforms the list shows: one tab, or both under "All".
    /// "35" projects, or "35 · 9" when 9 of them have changes waiting.
    private static func tabCount(_ store: Store, _ p: Platform) -> String {
        let n = store.items[p]?.count ?? 0, c = store.changedCount(p)
        return c > 0 ? "\(n) · \(c)" : "\(n)"
    }

    private var waitingSubtitle: String {
        let n = store.waiting.projects
        return n == 0 ? "" : L("\(n) \(n == 1 ? "project waits" : "projects wait")", "\(n) \(n == 1 ? "Projekt wartet" : "Projekte warten")")
    }

    private static func tabLabel(_ store: Store, _ p: Platform) -> String {
        let n = store.items[p]?.count ?? 0, c = store.changedCount(p)
        return L("\(p.rawValue), \(n) projects, \(c) with changes", "\(p.rawValue), \(n) Projekte, \(c) mit Änderungen")
    }

    private var scopes: [Platform] { showAll ? Platform.allCases : [platform] }

    private enum Tab: Hashable { case all, vercel, render }
    private var tab: Binding<Tab> {
        Binding(get: { showAll ? .all : (platform == .vercel ? .vercel : .render) },
                set: { t in showAll = t == .all; if t == .vercel { platform = .vercel } else if t == .render { platform = .render } })
    }

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
        let changed = rest.filter { $0.hasNewCommits && $0.deployable }
            .sorted {
                let a = $0.pendingCommits ?? 0, b = $1.pendingCommits ?? 0
                if a != b { return a > b }
                // Projects of one repo stay together, so the rows can say "same as above".
                if ($0.repo ?? "") != ($1.repo ?? "") { return ($0.repo ?? "") < ($1.repo ?? "") }
                return $0.name.localizedCaseInsensitiveCompare($1.name) == .orderedAscending
            }
        let others = rest.filter { !($0.hasNewCommits && $0.deployable) }
        return pins + changed + (showAll ? others.sorted { $0.name.localizedCaseInsensitiveCompare($1.name) == .orderedAscending } : others)
    }

    /// Rows whose waiting changes are those of the row above (same repo): they need not repeat them.
    private func sameRepoAsAbove(_ rows: [Item]) -> Set<String> {
        var out = Set<String>(); var prev: Item?
        for i in rows {
            if let p = prev, let r = i.repo, r == p.repo, i.hasNewCommits, p.hasNewCommits { out.insert(Store.key(i)) }
            prev = i
        }
        return out
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
    var body: some View { dialogs }

    private var chrome: some View {
        VStack(spacing: 0) {
            header
            Divider()
            noticeArea
            waitingBar
            if showAll || platform == .vercel, let c = store.costs { CostBar(costs: c) }
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
                    .padding(.bottom, 72)
                    .transition(.move(edge: .bottom).combined(with: .opacity))
            }
        }
        .onChange(of: store.toast) { _, t in
            guard let t else { return }
            // Said out loud once, instead of a region that "updates frequently".
            AccessibilityNotification.Announcement(Demo.scrub(t.text, items: allItems)).post()
            stickyError = t.ok ? nil : t
        }
        // Mission Control and the window title say what waits; the Dock icon carries the number.
        .navigationSubtitle(waitingSubtitle)
        .onChange(of: store.waiting.projects, initial: true) { _, n in NSApp.dockTile.badgeLabel = n > 0 ? "\(n)" : nil }
        // Not while a sheet is open: there ⌘F belongs to the build log's find bar.
        .focusedSceneValue(\.windowActions, logItem != nil || detailItem != nil || showJournal ? nil : WindowActions(
            tab: { n in showAll = n == 0; if n == 1 { platform = .vercel } else if n == 2 { platform = .render } },
            search: { searchFocused = true }))
        .animation(.easeOut(duration: 0.2), value: store.toast)
    }

    private var withSheets: some View {
        chrome
        .sheet(item: $logItem) { item in BuildLog(store: store, item: item) }
        .sheet(isPresented: $showJournal) { JournalView() }
        .sheet(item: $detailItem) { item in ProjectDetail(store: store, item: item) { sha in store.deployOne(item, preview: false, sha: sha) } }
        .onChange(of: store.pendingDeployAll) { _, go in
            guard go else { return }
            store.pendingDeployAll = false
            showAll = true; onlyChanged = true
            Platform.allCases.forEach { store.selectChanged($0) }
            if !selectedAll.isEmpty { confirming = true }
        }
    }

    private var dialogs: some View {
        withSheets
        .alert(L("Check after deploy", "Prüfung nach dem Deploy"), isPresented: Binding(get: { pathItem != nil }, set: { if !$0 { pathItem = nil } })) {
            TextField("/health", text: $pathText)
            Button(L("Cancel", "Abbrechen"), role: .cancel) { pathItem = nil }
            Button(L("Save", "Speichern")) { if let i = pathItem { store.setHealthPath(i, pathText) }; pathItem = nil }
        } message: {
            Text(L("This path is asked once \(shown(pathItem?.name)) is live, instead of the front page. Empty = front page.",
                   "Dieser Pfad wird abgefragt, sobald \(shown(pathItem?.name)) live ist, statt der Startseite. Leer = Startseite."))
        }
        .alert(L("Note", "Notiz"), isPresented: Binding(get: { noteItem != nil }, set: { if !$0 { noteItem = nil } })) {
            TextField(L("e.g. only after the release mail", "z. B. erst nach der Release-Mail"), text: $noteText)
            Button(L("Cancel", "Abbrechen"), role: .cancel) { noteItem = nil }
            Button(L("Save", "Speichern")) { if let i = noteItem { store.setNote(i, noteText) }; noteItem = nil }
        } message: {
            Text(L("Shown under \(shown(noteItem?.name)). Kept on this Mac only.", "Steht unter \(shown(noteItem?.name)). Bleibt nur auf diesem Mac."))
        }
        .onChange(of: store.pendingSearch) { _, name in
            guard let name else { return }
            showAll = true; onlyChanged = false; search = Demo.mask(name); store.pendingSearch = nil
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
        .alert(L("Put this live now?", "Jetzt live schalten?"), isPresented: $confirming) {
            Button(L("Cancel", "Abbrechen"), role: .cancel) {}
            Button(L("Deploy", "Deployen")) { scopes.forEach { store.deploySelected($0) } }
        } message: {
            // At most 12 lines, so the dialog does not grow past the screen.
            Text(selectedAll.prefix(12).map { i in
                    Demo.mask(i.name) + ((i.pendingCommits ?? 0) > 0 ? " – " + Row.waitingText(i) : "") }.joined(separator: "\n")
                 + (selectedAll.count > 12 ? "\n" + L("and \(selectedAll.count - 12) more", "und \(selectedAll.count - 12) weitere") : "")
                 + "\n\n" + L("The newest commit on GitHub goes live.",
                               "Der neueste Stand von GitHub geht live.")
                 + unchangedNote)
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
            Picker(L("Platform", "Plattform"), selection: tab) {
                Text(L("All", "Alle")).tag(Tab.all)
                Text("Vercel  " + Self.tabCount(store, .vercel)).tag(Tab.vercel).accessibilityLabel(Self.tabLabel(store, .vercel))
                Text("Render  " + Self.tabCount(store, .render)).tag(Tab.render).accessibilityLabel(Self.tabLabel(store, .render))
            }
            .pickerStyle(.segmented).labelsHidden().frame(width: 290)
            .help(L("Projects · of them with changes waiting (⌘1, ⌘2, ⌘3)", "Projekte · davon mit wartenden Änderungen (⌘1, ⌘2, ⌘3)"))

            TextField(L("Search", "Suchen"), text: $search).textFieldStyle(.roundedBorder)
                .frame(minWidth: 110)
                .layoutPriority(1)
                .focused($searchFocused)
                .onExitCommand { search = ""; searchFocused = false }

            Toggle(isOn: $onlyChanged) {
                Text(L("Changed only", "Nur mit Änderungen") + " (\(scopes.map { store.changedCount($0) }.reduce(0, +)))")
            }
            .toggleStyle(.button)
            .fixedSize()
            .help(L("Only projects with a commit on GitHub that is not live yet",
                    "Nur Projekte mit einem Commit auf GitHub, der noch nicht live ist"))

            let stamps = scopes.compactMap { p in store.loadedAt[p].map { (showAll ? p.rawValue + " " : "") + $0.formatted(date: .omitted, time: .shortened) } }
            if !stamps.isEmpty {
                // Dropped first when the window is narrow; the reload button's tooltip still has it.
                ViewThatFits(in: .horizontal) {
                    Text(scopes.contains { store.fromCache.contains($0) }
                         ? L("As of ", "Stand von ") + stamps.joined(separator: " · ") + L(" (not current)", " (nicht aktuell)")
                         : L("updated ", "Aktualisiert ") + stamps.joined(separator: " · "))
                        .font(.caption2).foregroundStyle(.secondary).fixedSize()
                    Color.clear.frame(width: 0, height: 0)
                }
            }
            Button { Task { for p in scopes { await store.load(p) }; await store.loadExtras() } } label: {
                if scopes.contains(where: { store.loading.contains($0) }) { ProgressView().controlSize(.small) }
                else { Image(systemName: "arrow.clockwise") }
            }
            .accessibilityLabel(L("Reload", "Neu laden"))
            .help(L("Reload (⌘R)", "Neu laden (⌘R)") + (store.loadedAt[platform].map {
                "\n" + L("Updated ", "Aktualisiert ") + $0.formatted(date: .omitted, time: .shortened)
                    + (store.fromCache.contains(platform) ? L(" (saved copy)", " (gespeicherte Kopie)") : "") } ?? ""))
            .keyboardShortcut("r")
            .disabled(scopes.contains { store.loading.contains($0) })
        }
        .padding(12)
    }

    /// Problems and offers above the list, most important first. Only the first is always shown;
    /// the others fold away, so the list keeps its room.
    enum Notice: Hashable { case trigger, loadFailed(Platform), setup(Platform), auto(Platform), github, provider, update }
    @AppStorage("noticesExpanded") private var noticesExpanded = false

    private var notices: [Notice] {
        var out: [Notice] = []
        if !activeTriggers.isEmpty { out.append(.trigger) }
        // Per platform, so on "All" a Vercel problem does not hide Render's list (and the other way round).
        for p in scopes where store.lastLoadError[p] != nil && !errorFillsWindow(p) { out.append(.loadFailed(p)) }
        if showAll { for p in scopes where setupNeeded(p) != nil { out.append(.setup(p)) } }
        for p in scopes where !store.autoOn(p).isEmpty { out.append(.auto(p)) }
        if store.doctor.map({ $0.githubCli && $0.githubLoggedIn == false }) == true || (store.githubBudget?.remaining ?? .max) < 300 { out.append(.github) }
        if !store.providerIssues.isEmpty && store.providerIssues != closedIssues { out.append(.provider) }
        if let v = store.newVersion, v != skippedVersion { out.append(.update) }
        return out
    }

    private func noticeTitle(_ n: Notice) -> String {
        switch n {
        case .trigger: return L("other build triggers", "andere Build-Auslöser")
        case .loadFailed(let p): return L("\(p.rawValue) not loaded", "\(p.rawValue) nicht geladen")
        case .setup(let p): return L("\(p.rawValue) not connected", "\(p.rawValue) nicht verbunden")
        case .auto(let p): return L("auto-deploy on (\(p.rawValue))", "Auto-Deploy an (\(p.rawValue))")
        case .github: return "GitHub"
        case .provider: return L("provider problem", "Störung beim Anbieter")
        case .update: return L("new version", "neue Version")
        }
    }

    @ViewBuilder private func notice(_ n: Notice) -> some View {
        switch n {
        case .trigger: triggerBanner
        case .loadFailed(let p): loadFailedBanner(p)
        case .setup(let p): setupBanner(p)
        case .auto(let p): autoBanner(p)
        case .github: githubBanner
        case .provider: providerBanner
        case .update: updateBanner
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
                    Button { withAnimation(.easeOut(duration: 0.15)) { noticesExpanded.toggle() } } label: {
                        HStack(spacing: 6) {
                            Image(systemName: noticesExpanded ? "chevron.up" : "chevron.down")
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

    @ViewBuilder private var updateBanner: some View {
        if let v = store.newVersion {
            HStack {
                Image(systemName: "arrow.down.circle.fill").foregroundStyle(.blue)
                Text(L("Version \(v) is out.", "Version \(v) ist da.")).font(.callout)
                Button(L("What's new", "Was ist neu")) {
                    NSWorkspace.shared.open(URL(string: "https://github.com/\(Updater.repo)/releases/latest")!)
                }.buttonStyle(.link)
                Button(store.updating ? L("Updating …", "Aktualisiere …") : L("Update now", "Jetzt aktualisieren")) {
                    Task { await store.installUpdate() }
                }.buttonStyle(.link).disabled(store.updating)
                Button(L("Download", "Herunterladen")) {
                    NSWorkspace.shared.open(URL(string: "https://github.com/\(Updater.repo)/releases/latest")!)
                }.buttonStyle(.link)
                if let st = store.updateStatus { Text(st).font(.caption).foregroundStyle(.secondary) }
                Spacer()
                // Remembered for this version: the next one is shown again.
                Button(L("Skip this version", "Diese Version überspringen")) { skippedVersion = v }.buttonStyle(.link).font(.caption)
                Button { store.newVersion = nil } label: { Image(systemName: "xmark") }.buttonStyle(.borderless)
                    .help(L("Not now", "Nicht jetzt")).accessibilityLabel(L("Not now", "Nicht jetzt"))
            }
            .padding(.horizontal, 12).padding(.vertical, 6).background(ground(.blue, 0.06))
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
            .padding(.horizontal, 12).padding(.vertical, 6).background(Color.orange.opacity(0.08))
        }
    }

    static let statusPages = [("Vercel", "https://www.vercel-status.com"), ("Render", "https://status.render.com"),
                              ("GitHub", "https://www.githubstatus.com")]

    static func sparkValue(_ v: [Int]) -> String {
        guard let last = v.last, let lo = v.min(), let hi = v.max() else { return "" }
        return L("today \(last), lowest \(lo), highest \(hi)", "heute \(last), niedrigster \(lo), höchster \(hi)")
    }

    static func triggerName(_ k: String) -> String {
        switch k {
        case "workflow": return L("GitHub workflow deploys", "GitHub-Workflow deployt")
        case "vercel-build": return L("Vercel build from Git", "Vercel-Build von Git")
        case "render-build": return L("Render build from push", "Render-Build durch Push")
        case "render-blueprint": return L("Render Blueprint auto-sync", "Render-Blueprint Auto-Sync")
        default: return k
        }
    }

    /// Ticked projects that are already on their newest commit: building them costs and changes nothing.
    private var unchangedNote: String {
        let same = selectedAll.filter { !$0.hasNewCommits && $0.headSha != nil }.map { Demo.mask($0.name) }
        guard !same.isEmpty else { return "" }
        return "\n\n" + L("Already up to date, builds anyway: ", "Schon aktuell, baut trotzdem: ") + same.joined(separator: ", ")
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
            .padding(.horizontal, 12).padding(.vertical, 6).background(Color.orange.opacity(0.08))
        } else if let b = store.githubBudget, b.remaining < 300 {
            HStack(spacing: 10) {
                Image(systemName: "gauge.with.dots.needle.0percent").foregroundStyle(.orange)
                Text(L("GitHub's hourly budget is nearly spent (\(b.remaining) of \(b.limit) left). Counts pause until ",
                       "GitHubs Stunden-Kontingent ist fast aufgebraucht (\(b.remaining) von \(b.limit) übrig). Die Zahlen pausieren bis ")
                     + Date(timeIntervalSince1970: b.reset).formatted(date: .omitted, time: .shortened) + ".")
                    .font(.caption)
                Spacer()
            }
            .padding(.horizontal, 12).padding(.vertical, 6).background(Color.orange.opacity(0.08))
        }
    }

    /// What GitHub has that is not live, over Vercel and Render together.
    @ViewBuilder private var waitingBar: some View {
        let w = store.waiting
        if w.projects > 0 || w.openPRs > 0 {
            HStack(spacing: 10) {
                Image(systemName: "shippingbox.fill").font(.title2).foregroundStyle(.blue)
                VStack(alignment: .leading, spacing: 2) {
                    if w.projects > 0 {
                        Text(L("\(w.prs) \(w.prs == 1 ? "PR" : "PRs") waiting to deploy",
                               "\(w.prs) \(w.prs == 1 ? "PR wartet" : "PRs warten") auf Deploy"))
                            .font(.headline).accessibilityAddTraits(.isHeader)
                        Text(L("\(w.commits) \(w.commits == 1 ? "commit" : "commits") in \(w.projects) \(w.projects == 1 ? "project" : "projects"), merged on GitHub and not live",
                               "\(w.commits) \(w.commits == 1 ? "Commit" : "Commits") in \(w.projects) \(w.projects == 1 ? "Projekt" : "Projekten"), auf GitHub gemergt und nicht live"))
                            .font(.caption).foregroundStyle(.secondary)
                    } else {
                        Text(L("Everything merged is live", "Alles Gemergte ist live")).font(.headline)
                    }
                    if !showAll, w.projects > 0, store.changedCount(platform) != w.projects {
                        Text(L("\(store.changedCount(platform)) of them on \(platform.rawValue)", "davon \(store.changedCount(platform)) auf \(platform.rawValue)"))
                            .font(.caption).foregroundStyle(.secondary)
                    }
                    if w.openPRs > 0 {
                        Text(L("\(w.openPRs) more \(w.openPRs == 1 ? "PR is" : "PRs are") still open (not merged)",
                               "\(w.openPRs) weitere \(w.openPRs == 1 ? "PR ist" : "PRs sind") noch offen (nicht gemergt)"))
                            .font(.caption).foregroundStyle(.secondary)
                    }
                }
                Spacer()
                if store.history.count >= 2 {
                    // PRs waiting per day: does the daily deploy keep up?
                    let days = store.history.keys.sorted().suffix(14)
                    Chart(Array(days), id: \.self) { d in
                        LineMark(x: .value("Day", d), y: .value("PRs", store.history[d] ?? 0))
                        AreaMark(x: .value("Day", d), y: .value("PRs", store.history[d] ?? 0)).foregroundStyle(Color.blue.opacity(0.15))
                    }
                    .chartXAxis(.hidden).chartYAxis(.hidden)
                    .frame(width: 90, height: 30)
                    .help(L("PRs waiting per day, last 14 days", "Wartende PRs pro Tag, letzte 14 Tage"))
                    .accessibilityElement()
                    .accessibilityLabel(L("PRs waiting per day, last \(days.count) days", "Wartende PRs pro Tag, letzte \(days.count) Tage"))
                    .accessibilityValue(Self.sparkValue(days.map { store.history[$0] ?? 0 }))
                }
                if w.projects > 0 {
                    Button(L("Show them", "Anzeigen")) { onlyChanged = true; showAll = true; search = "" }
                }
            }
            .padding(12).background(ground(.blue, 0.08))
        }
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
        !showAll && p == platform && (store.items[p] ?? []).isEmpty
    }

    @ViewBuilder private func loadFailedBanner(_ p: Platform) -> some View {
        if let f = store.lastLoadError[p] {
            HStack(spacing: 10) {
                Image(systemName: "exclamationmark.triangle.fill").foregroundStyle(.orange)
                VStack(alignment: .leading, spacing: 2) {
                    Text(L("\(p.rawValue) could not be loaded", "\(p.rawValue) konnte nicht geladen werden")
                         + (store.loadedAt[p].map { L(" – showing the list from ", " – zu sehen ist der Stand von ") + $0.formatted(date: .omitted, time: .shortened) } ?? ""))
                        .font(.callout.weight(.medium))
                    Text(Demo.scrub(f.message, items: allItems)).font(.caption).foregroundStyle(.secondary).lineLimit(2).textSelection(.enabled)
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
                Button(L("Set up", "Einrichten")) { showAll = false; platform = p }
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
                         + (showAll ? " (\(p.rawValue))" : ""))
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
        // Filtered and sorted once per render; the list, the empty states and "same repo" all use it.
        let visible = self.visible
        if let err = store.doctorError {
            Setup(title: L("Something is missing", "Etwas fehlt"), text: err, commands: []) { Task { await store.start() } }
        } else if store.doctor == nil && scopes.allSatisfy({ (store.items[$0] ?? []).isEmpty }) {
            ProgressView(L("Checking access …", "Prüfe Zugang …")).frame(maxWidth: .infinity, maxHeight: .infinity)
        } else if let d = store.doctor, !d.jq {
            Setup(title: L("jq is missing", "jq fehlt"),
                  text: L("Deploy Center needs the small tool jq. Install it with Homebrew:", "Deploy Center braucht das kleine Werkzeug jq. Installieren mit Homebrew:"),
                  commands: ["brew install jq"]) { Task { await store.start() } }
        } else if !showAll, platform == .vercel, let d = store.doctor, d.vercelCli, !d.vercelApi {
            Setup(title: L("Update the Vercel CLI", "Vercel-CLI aktualisieren"),
                  text: L("Your Vercel CLI is too old (it has no `vercel api`).", "Deine Vercel-CLI ist zu alt (ihr fehlt `vercel api`)."),
                  commands: ["npm i -g vercel@latest"]) { Task { await store.start() } }
        } else if !showAll, platform == .vercel, let d = store.doctor, !d.vercelLoggedIn {
            Setup(title: L("Connect Vercel", "Vercel verbinden"),
                  text: d.vercelCli
                    ? L("Log in once in Terminal. The app uses that login.", "Einmal im Terminal anmelden. Die App nutzt diese Anmeldung.")
                    : L("Install the Vercel CLI, then log in once in Terminal.", "Vercel-CLI installieren und einmal im Terminal anmelden."),
                  commands: d.vercelCli ? ["vercel login"] : ["npm i -g vercel", "vercel login"]) {
                Task { await store.start() }
            }
        } else if !showAll, platform == .render, let d = store.doctor, !d.renderKey {
            RenderKeySetup(store: store)
        } else if errorFillsWindow(platform), let err = store.lastLoadError[platform]?.message ?? store.loadError[platform] {
            VStack(spacing: 10) {
                Image(systemName: "exclamationmark.triangle").font(.largeTitle).foregroundStyle(.orange)
                Text(L("Could not load \(platform.rawValue)", "\(platform.rawValue) konnte nicht geladen werden")).font(.headline)
                Text(Demo.scrub(err, items: allItems)).font(.callout).foregroundStyle(.secondary).multilineTextAlignment(.center).textSelection(.enabled)
                if store.loading.contains(platform) { ProgressView().controlSize(.small) }
                else { Button(L("Try again", "Nochmal versuchen")) { Task { await store.load(platform) } } }
            }
            .padding(30).frame(maxWidth: .infinity, maxHeight: .infinity)
        } else if scopes.contains(where: { store.loading.contains($0) }) && scopes.allSatisfy({ (store.items[$0] ?? []).isEmpty }) {
            ProgressView(L("Loading \(scopes.map(\.rawValue).joined(separator: ", ")) …", "Lade \(scopes.map(\.rawValue).joined(separator: ", ")) …")).frame(maxWidth: .infinity, maxHeight: .infinity)
        } else if visible.isEmpty && (onlyChanged || !search.isEmpty) {
            let inScope = scopes.flatMap { store.items[$0] ?? [] }
            let hiddenHits = search.isEmpty ? 0 : inScope.filter { store.isHidden($0)
                && (Demo.on ? Demo.mask($0.name) : $0.name).localizedCaseInsensitiveContains(search) }.count
            VStack(spacing: 8) {
                Image(systemName: search.isEmpty ? "checkmark.seal.fill" : "magnifyingglass").font(.system(size: 34))
                    .foregroundStyle(search.isEmpty ? .green : .secondary)
                Text(search.isEmpty ? L("Everything is live", "Alles ist live") : L("Nothing matches “\(search)”", "Nichts passt zu „\(search)“"))
                    .font(.headline)
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
                if hiddenHere > 0 { SettingsLink { Text(L("Open Settings", "Einstellungen öffnen")) } }
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity)
        } else {
            let dupes = sameRepoAsAbove(visible)
            // One lookup table per render instead of a search through all projects per row.
            let costRows = Dictionary((store.costs?.projects ?? []).map { ($0.name, $0) }, uniquingKeysWith: { a, _ in a })
            let complete = store.costs?.buildsComplete == true
            List(visible) { item in
                let c = item.platform == .vercel ? costRows[item.name] : nil
                Row(item: item, sameRepoAsAbove: dupes.contains(Store.key(item)), cost: c?.build,
                    perBuild: complete ? c.flatMap { p in p.builds.flatMap { $0 > 0 ? p.build / Double($0) : nil } } : nil,
                    pinned: store.isPinned(item), note: store.note(item),
                    showDetails: item.repo == nil ? nil : { detailItem = item },
                    showLog: { logItem = item },
                    onCancel: { store.cancel(item) },
                    onRetry: item.deployable ? { store.deployOne(item, preview: false) } : nil,
                    usualMinutes: store.usualMinutes(item), queueText: store.queueText(item), search: search) { tick(item) }
                    .contextMenu {
                        if item.repo != nil {
                            Button(L("Details …", "Details …")) { detailItem = item }
                            Divider()
                        }
                        if item.deployable && !item.state.isActive {
                            Button(L("Deploy to production", "Live deployen")) {
                                if item.hasNewCommits || item.headSha == nil { store.deployOne(item, preview: false) }
                                else { unchangedItem = item }
                            }
                            if item.platform == .render {
                                Button(L("Deploy with a cleared build cache", "Mit geleertem Build-Cache deployen")) { store.deployOne(item, preview: false, clearCache: true) }
                            }
                            if item.platform == .vercel {
                                Button(L("Preview deploy (not live)", "Vorschau-Deploy (nicht live)")) { store.deployOne(item, preview: true) }
                            }
                            Divider()
                            Button(L("Roll back production …", "Live zurückrollen …")) { rollbackItem = item }
                        }
                        if let l = item.link, let u = URL(string: l) {
                            Button(L("Open site", "Seite öffnen")) { NSWorkspace.shared.open(u) }
                        }
                        Button(L("Last build log …", "Letztes Build-Log …")) { logItem = item }
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
                        Button(L("Page to check after deploy …", "Seite für die Prüfung nach dem Deploy …")) {
                            pathText = store.healthPath(item); pathItem = item
                        }
                        Button(L("Hide", "Ausblenden")) { store.hideWithUndo(item) }
                    }
            }
            .listStyle(.inset)
        }
    }

    private var footer: some View {
        let count = selectedAll.count
        let changedHere = scopes.map { store.changedCount($0) }.reduce(0, +)
        return HStack {
            Text(count == 0 ? L("Tick the projects that should go live", "Projekte anhaken, die live gehen sollen")
                            : L("\(count) selected", "\(count) ausgewählt"))
                .foregroundStyle(.secondary)
                .help(L("Shift-click ticks everything between the last tick and this one", "Mit ⇧-Klick wird alles zwischen dem letzten Haken und diesem angehakt"))
            // Ticks on the other tab still count there: say they exist.
            let elsewhere = Platform.allCases.filter { !scopes.contains($0) }.map { p in (p, store.selected(p).count) }.filter { $0.1 > 0 }
            ForEach(elsewhere, id: \.0) { p, n in
                Button(L("+\(n) on \(p.rawValue)", "+\(n) auf \(p.rawValue)")) { showAll = false; platform = p }
                    .buttonStyle(.link).font(.caption)
                    .help(L("Ticked on the other tab", "Auf dem anderen Tab angehakt"))
            }
            Spacer()
            Button { showJournal = true } label: { Image(systemName: "clock.arrow.circlepath") }
                .buttonStyle(.borderless).help(L("Deploy history", "Deploy-Verlauf")).accessibilityLabel(L("Deploy history", "Deploy-Verlauf"))
            if !store.messages.isEmpty {
                Button { showMessages.toggle() } label: { Image(systemName: "bell") }
                    .buttonStyle(.borderless).help(L("Latest messages", "Letzte Meldungen")).accessibilityLabel(L("Latest messages", "Letzte Meldungen"))
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
            if scopes.contains(where: { p in (store.items[p] ?? []).contains { $0.state.isActive } }) {
                Button(L("Stop all", "Alles abbrechen"), role: .destructive) { store.cancelAll() }
            }
            if count > 0 {
                Button(L("Clear", "Auswahl leeren")) { scopes.forEach { store.clearSelection($0) } }
            } else if changedHere > 0 {
                Button(L("Select all changed", "Alle mit Änderungen anhaken")) { scopes.forEach { store.selectChanged($0) } }
                    // The saved copy may be hours old; tick from what is true now. If reading it
                    // again failed, the error is on screen and the copy is all there is.
                    .disabled(scopes.contains { store.fromCache.contains($0) && store.loadError[$0] == nil })
                    .help(scopes.contains { store.fromCache.contains($0) && store.loadError[$0] == nil }
                          ? L("Waits for the fresh list: the saved copy may be hours old", "Wartet auf die frische Liste: die gespeicherte Kopie kann Stunden alt sein")
                          : L("Ticks every project with commits that are not live", "Hakt jedes Projekt mit Commits an, die nicht live sind"))
            }
            if !showAll && platform == .vercel {
                Button(L("Preview", "Vorschau")) { store.deploySelected(platform, preview: true) }
                    .disabled(count == 0)
                    .help(L("Build a preview deployment. Production stays as it is.", "Baut einen Vorschau-Deploy. Live bleibt unverändert."))
            }
            Button { confirming = true } label: {
                Label(count > 1 ? L("Deploy \(count)", "\(count) deployen") : L("Deploy", "Deployen"),
                      systemImage: "paperplane.fill").padding(.horizontal, 6)
            }
            .buttonStyle(.borderedProminent).controlSize(.large)
            .keyboardShortcut(.return, modifiers: .command)
            .disabled(count == 0)
        }
        .padding(12)
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

struct CostBar: View {
    let costs: Costs
    @State private var hovered: String?
    @AppStorage("costBarCollapsed") private var collapsed = false
    @State private var sharing = false
    private static let dayFormat: DateFormatter = {
        let f = DateFormatter(); f.dateFormat = "yyyy-MM-dd"; f.timeZone = TimeZone(identifier: "UTC"); return f
    }()
    private var last7: [Costs.Day] { Array(costs.days.suffix(7)) }
    private var week: Double { last7.map(\.build).reduce(0, +) }
    private var average: Double { last7.isEmpty ? 0 : week / Double(last7.count) }

    /// Average build cost per day before auto-deploy was turned off and since, whole days only.
    private var saving: (before: Double, after: Double)? {
        guard let off = costs.offDay else { return nil }
        // Today is not over yet: a half day would make "since" look cheaper than it is.
        let today = Self.dayFormat.string(from: Date())
        let before = costs.days.filter { $0.day < off }, after = costs.days.filter { $0.day > off && $0.day < today }
        guard !before.isEmpty, !after.isEmpty else { return nil }
        return (before.map(\.build).reduce(0, +) / Double(before.count), after.map(\.build).reduce(0, +) / Double(after.count))
    }

    var body: some View {
        if collapsed {
            Button { collapsed = false } label: {
                HStack(spacing: 6) {
                    Image(systemName: "chevron.down")
                    Text(L("Vercel builds, last 7 days: ", "Vercel-Builds, letzte 7 Tage: ") + week.formatted(.currency(code: "USD")))
                    Spacer()
                }
                .font(.caption).foregroundStyle(.secondary)
                .padding(.horizontal, 12).padding(.vertical, 5).contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            .background(Color.secondary.opacity(0.06))
            .accessibilityHint(L("Shows the cost chart", "Zeigt das Kostendiagramm"))
        } else {
            expanded
        }
    }

    private var expanded: some View {
        HStack(spacing: 16) {
            VStack(alignment: .leading, spacing: 2) {
                HStack(spacing: 4) {
                    Text(L("Vercel builds, last 7 days", "Vercel-Builds, letzte 7 Tage")).font(.caption).foregroundStyle(.secondary)
                    Button { collapsed = true } label: { Image(systemName: "chevron.up").font(.caption2) }
                        .buttonStyle(.borderless).help(L("Fold away", "Einklappen")).accessibilityLabel(L("Fold away the costs", "Kosten einklappen"))
                }
                Text(week, format: .currency(code: "USD")).font(.title3.weight(.semibold).monospacedDigit())
                Text(L("≈ ", "≈ ") + (average * 30).formatted(.currency(code: "USD")) + L(" a month at this pace", " im Monat bei diesem Tempo"))
                    .font(.caption2).foregroundStyle(.secondary)
                if let s = saving {
                    Text(L("per day: ", "pro Tag: ") + s.before.formatted(.currency(code: "USD")) + L(" before, ", " vorher, ")
                         + s.after.formatted(.currency(code: "USD")) + L(" since", " seitdem"))
                        .font(.caption2.weight(.medium)).foregroundStyle(s.after < s.before ? .green : .orange)
                    if s.after < s.before {
                        Button(L("Share the saving …", "Ersparnis teilen …")) { sharing = true }
                            .buttonStyle(.link).font(.caption2)
                            .popover(isPresented: $sharing) { SavingShare(before: s.before, after: s.after) }
                            .help(L("Copies a picture and a sentence with your saving, without project names",
                                    "Kopiert ein Bild und einen Satz mit deiner Ersparnis, ohne Projektnamen"))
                    }
                } else if let off = costs.offDay {
                    Text(L("Auto-deploy off since \(off); the saving shows after a full day", "Auto-Deploy aus seit \(off); die Ersparnis zeigt sich nach einem ganzen Tag"))
                        .font(.caption2).foregroundStyle(.secondary)
                }
            }
            VStack(alignment: .leading, spacing: 2) {
            Chart(costs.days) { d in
                // A day over twice the average stands out.
                BarMark(x: .value("Day", String(d.day.suffix(2))), y: .value("USD", d.build))
                    .foregroundStyle(d.build > 2 * average && average > 0 ? Color.orange.gradient : Color.accentColor.gradient)
                if let off = costs.offDay, d.day == off {
                    RuleMark(x: .value("Day", String(d.day.suffix(2)))).foregroundStyle(.green).lineStyle(StrokeStyle(lineWidth: 1, dash: [3]))
                }
            }
            .chartYAxis { AxisMarks(position: .leading) { _ in AxisValueLabel() } }
            .chartXAxis { AxisMarks { _ in AxisValueLabel() } }
            .chartXSelection(value: $hovered)
            .overlay(alignment: .topTrailing) {
                // The value of the day under the pointer, with its full date.
                if let h = hovered, let d = costs.days.first(where: { String($0.day.suffix(2)) == h }) {
                    Text(d.day + ": " + d.build.formatted(.currency(code: "USD")))
                        .font(.caption2.monospacedDigit()).padding(.horizontal, 5).padding(.vertical, 2)
                        .background(RoundedRectangle(cornerRadius: 4).fill(.regularMaterial))
                }
            }
            .frame(height: 64)
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
        .padding(.horizontal, 12).padding(.vertical, 8)
        .background(Color.secondary.opacity(0.06))
        .help(L("Build costs from Vercel's billing data; orange: over twice the average; green line: auto-deploy turned off. Total incl. other usage: ",
                "Build-Kosten aus Vercels Abrechnung; orange: mehr als doppelt so viel wie im Schnitt; grüne Linie: Auto-Deploy ausgeschaltet. Gesamt inkl. sonstiger Nutzung: ")
              + last7.map(\.total).reduce(0, +).formatted(.currency(code: "USD")))
    }
}

/// The picture before it goes anywhere: copy it, save it as PNG, or hand it to the share menu.
struct SavingShare: View {
    let before: Double, after: Double
    @State private var copied = false

    private var image: NSImage? {
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
        }
        .padding(16)
    }

    private func save() {
        guard let img = image, let tiff = img.tiffRepresentation, let rep = NSBitmapImageRep(data: tiff),
              let png = rep.representation(using: .png, properties: [:]) else { return }
        let panel = NSSavePanel()
        panel.allowedContentTypes = [.png]
        panel.nameFieldStringValue = L("deploy-center-saving.png", "deploy-center-ersparnis.png")
        if panel.runModal() == .OK, let url = panel.url { try? png.write(to: url) }
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
            Text("github.com/Pschmetzer/deploy-center").font(.caption).foregroundStyle(.white.opacity(0.6))
        }
        .padding(28).frame(width: 520, alignment: .leading)
        .background(LinearGradient(colors: [Color(red: 0.07, green: 0.09, blue: 0.16), Color(red: 0.18, green: 0.11, blue: 0.32)],
                                   startPoint: .topLeading, endPoint: .bottomTrailing))
    }

    /// The sentence that goes with the picture.
    static func text(before: Double, after: Double) -> String {
        let m = (max(0, before - after) * 30).formatted(.currency(code: "USD").precision(.fractionLength(0)))
        return L("I turned off auto-deploy and now deploy by hand: builds went from \(before.formatted(.currency(code: "USD"))) to \(after.formatted(.currency(code: "USD"))) a day, about \(m) a month saved. https://github.com/Pschmetzer/deploy-center",
                 "Ich habe Auto-Deploy ausgeschaltet und deploye jetzt von Hand: Builds von \(before.formatted(.currency(code: "USD"))) auf \(after.formatted(.currency(code: "USD"))) am Tag, etwa \(m) im Monat gespart. https://github.com/Pschmetzer/deploy-center")
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
            SecureField("rnd_…", text: $key).textFieldStyle(.roundedBorder).frame(width: 320)
            if let error { Text(error).font(.caption).foregroundStyle(.red).multilineTextAlignment(.center) }
            HStack {
                Button(L("Open Render", "Render öffnen")) {
                    NSWorkspace.shared.open(URL(string: "https://dashboard.render.com/u/settings#api-keys")!)
                }
                Button(saving ? L("Saving …", "Speichere …") : L("Save key", "Key speichern")) {
                    saving = true
                    Task { error = await store.saveRenderKey(key); saving = false; if error == nil { key = "" } }
                }
                .buttonStyle(.borderedProminent).disabled(key.count < 10 || saving)
            }
        }
        .padding(30).frame(maxWidth: 480).frame(maxWidth: .infinity, maxHeight: .infinity)
    }
}

struct Row: View {
    let item: Item
    var sameRepoAsAbove = false
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

            // Redrawn once a minute, so "3 minutes ago" does not stand still between two loads.
            TimelineView(.everyMinute) { _ in
            VStack(alignment: .leading, spacing: 3) {
                HStack(spacing: 6) {
                    if pinned { Image(systemName: "pin.fill").font(.caption2).foregroundStyle(.secondary) }
                    Text(Demo.on ? AttributedString(Demo.mask(item.name)) : highlighted(item.name)).font(.body.weight(.medium))
                    if let d = item.domain, let u = item.link.flatMap(URL.init(string:)) {
                        Button { NSWorkspace.shared.open(u) } label: { Text(Demo.mask(d)).font(.caption) }
                            .buttonStyle(.link).help(L("Open site", "Seite öffnen"))
                    }
                }
                Text(Demo.on ? item.platform.rawValue : item.detail).font(.caption).foregroundStyle(.secondary)
                if let note { Label(note, systemImage: "note.text").font(.caption.italic()).foregroundStyle(.secondary) }
                // One line when there is room, otherwise one chip under the other.
                ViewThatFits(in: .horizontal) {
                    HStack(spacing: 8) { chips }
                    VStack(alignment: .leading, spacing: 2) { chips }
                }
            }

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
        .opacity(item.deployable ? 1 : 0.55)
        .onTapGesture { if !item.state.isActive { toggle() } }
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
            if case .failed = item.state, let onRetry { Button(L("Try again", "Erneut versuchen"), action: onRetry) }
            if item.state.isActive, let onCancel { Button(L("Cancel the deploy", "Deploy abbrechen"), action: onCancel) }
            if let u = item.link.flatMap(URL.init(string:)) { Button(L("Open site", "Seite öffnen")) { NSWorkspace.shared.open(u) } }
        }
    }

    @ViewBuilder private var chips: some View {
                lastDeploy
                if let cost, cost >= 0.01 {
                    Text(L("builds 7 days: ", "Builds 7 Tage: ") + cost.formatted(.currency(code: "USD")))
                        .font(.caption2).foregroundStyle(cost >= 5 ? Color.warningText : .secondary)
                        .help(perBuild.map { L("About ", "Etwa ") + $0.formatted(.currency(code: "USD")) + L(" per build", " pro Build") } ?? "")
                }
                if item.hasNewCommits && sameRepoAsAbove {
                    Label(L("same as above (same repo)", "wie oben (gleiches Repo)"), systemImage: "arrow.up.circle")
                        .font(.caption2).foregroundStyle(.secondary)
                } else if item.hasNewCommits {
                    Label(Self.waitingText(item), systemImage: "arrow.up.circle.fill")
                        .font(.caption2.weight(.semibold)).foregroundStyle(.blue)
                        .help(item.headMsg.map { L("Newest commit: ", "Neuester Commit: ") + (Demo.on ? "…" : $0)
                            + (item.headAt.map { " (\(Self.ago($0)))" } ?? "") } ?? "")
                }
                if item.hasNewCommits, !sameRepoAsAbove, let since = item.oldestPendingAt {
                    Text(L("oldest waiting commit ", "ältester wartender Commit ") + Self.ago(since))
                        .font(.caption2).foregroundStyle(Date().timeIntervalSince(since) > 3 * 86400 ? Color.warningText : .secondary)
                        .help(L("The oldest commit that is not live", "Der älteste Commit, der noch nicht live ist"))
                }
                if !sameRepoAsAbove, let o = item.openPRs, o > 0 {
                    Text(Self.openText(item, o))
                        .font(.caption2).foregroundStyle(.secondary)
                        .help(L("Pull requests on the repo that are not merged yet", "Pull Requests im Repo, die noch nicht gemergt sind"))
                }
    }

    /// What VoiceOver says for the row: name, what waits, the last deploy and what runs now.
    private var spoken: String {
        var parts = [Demo.mask(item.name), Demo.on ? item.platform.rawValue : item.detail]
        if pinned { parts.append(L("pinned", "angeheftet")) }
        if item.hasNewCommits { parts.append(sameRepoAsAbove ? L("same changes as above", "gleiche Änderungen wie oben") : Self.waitingText(item)) }
        if let at = item.lastAt {
            let s = item.lastState ?? ""
            parts.append(L("last deploy ", "zuletzt deployt ") + Self.ago(at) + (["ready", "live", "succeeded"].contains(s.lowercased()) ? "" : ", " + Self.stateText(s)))
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
        if let note { parts.append(L("note: ", "Notiz: ") + note) }
        return parts.filter { !$0.isEmpty }.joined(separator: ", ")
    }

    static func waitingText(_ i: Item) -> String {
        if i.rewritten { return L("New changes (branch was rewritten)", "Neue Änderungen (Branch wurde umgeschrieben)") }
        guard let c = i.pendingCommits, c > 0 else { return L("New changes", "Neue Änderungen") }
        let prs = i.pendingPRs ?? 0
        if i.pendingPartial {
            return L("\(c) commits, at least \(prs) PRs waiting", "\(c) Commits, mindestens \(prs) PRs warten")
        }
        let commits = L("\(c) \(c == 1 ? "commit" : "commits")", "\(c) \(c == 1 ? "Commit" : "Commits")")
        return prs > 0 ? commits + " · " + L("\(prs) \(prs == 1 ? "PR" : "PRs") waiting", "\(prs) \(prs == 1 ? "PR wartet" : "PRs warten")")
                       : commits + L(" waiting", " warten")
    }

    static func openText(_ i: Item, _ o: Int) -> String {
        var parts: [String] = []
        if let d = i.openDrafts, d > 0 { parts.append(L("\(d) \(d == 1 ? "draft" : "drafts")", "\(d) \(d == 1 ? "Entwurf" : "Entwürfe")")) }
        if let b = i.openBots, b > 0 { parts.append(L("\(b) \(b == 1 ? "bot" : "bots")", "\(b) \(b == 1 ? "Bot" : "Bots")")) }
        let base = L("\(o) open \(o == 1 ? "PR" : "PRs")", "\(o) \(o == 1 ? "offener PR" : "offene PRs")")
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
        case "initializing": return L("starting", "startet")
        default: return raw.replacingOccurrences(of: "_", with: " ")
        }
    }

    @ViewBuilder private var lastDeploy: some View {
        if let at = item.lastAt {
            let s = (item.lastState ?? "").lowercased()
            let ok = ["ready", "live", "succeeded"].contains(s)
            let failed = s.contains("fail") || s == "error" || s == "canceled"
            HStack(spacing: 4) {
                if noColour {
                    Image(systemName: ok ? "checkmark.circle" : (failed ? "xmark.circle" : "clock")).font(.caption2)
                } else {
                    Circle().fill(ok ? Color.green : (failed ? Color.red : Color.orange)).frame(width: 7, height: 7)
                }
                Text(L("Last deploy ", "Zuletzt deployt ") + Self.ago(at) + (ok ? "" : " · " + Self.stateText(s)))
                    .font(.caption2).foregroundStyle(.secondary)
                if failed, let showLog {
                    Button(action: showLog) { Image(systemName: "text.alignleft").font(.caption2) }
                        .buttonStyle(.borderless).help(L("Show the build log of the failed deploy", "Build-Log des fehlgeschlagenen Deploys zeigen"))
                        .accessibilityLabel(L("Build log", "Build-Log"))
                }
            }
            .help(at.formatted(date: .complete, time: .shortened) + (item.lastMsg.map { "\nLive: " + (Demo.on ? "…" : $0) } ?? ""))
        } else {
            Text(L("Never deployed", "Noch nie deployt")).font(.caption2).foregroundStyle(.secondary)
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
                        let secs = Int(ctx.date.timeIntervalSince(start))
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
                        .buttonStyle(.borderless).help(L("Try again", "Erneut versuchen")).accessibilityLabel(L("Try again", "Erneut versuchen"))
                }
            }
        }
    }
}
