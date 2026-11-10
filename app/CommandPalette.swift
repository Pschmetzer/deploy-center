// Deploy Center — The command palette (⌘K): every action and project in one search field.
// Nothing here starts a deploy or a rollback by itself: both end in the same question the window
// asks, and a deploy then takes the usual wait before it starts (Settings → Deploy).

import SwiftUI
import AppKit
import Carbon.HIToolbox

// MARK: - Fuzzy matching (pure, tested in tests/app-tests.swift)

/// Lower case and without accents, so "Über" is found with "uber" and "ub".
func paletteFold(_ s: String) -> String {
    s.folding(options: [.caseInsensitive, .diacriticInsensitive, .widthInsensitive], locale: nil).lowercased()
}

/// How well `query` matches `text`: nil when not every letter of the query is in the text in order.
/// Higher is better. Spaces in the query only separate words; each word found as a whole counts extra,
/// and letters at the start of a word or right after the previous match count more than letters
/// somewhere in the middle. Shorter texts win a tie.
func fuzzyScore(_ query: String, _ text: String) -> Int? {
    let words = paletteFold(query).split(whereSeparator: { $0.isWhitespace }).map(String.init)
    let q = Array(words.joined())
    guard !q.isEmpty else { return 0 }
    let t = Array(paletteFold(text))
    var score = 0, qi = 0, prev = -2
    for (ti, c) in t.enumerated() where qi < q.count && c == q[qi] {
        var s = 1
        if ti == prev + 1 { s += 5 }                                                   // one run
        if ti == 0 { s += 10 } else if !t[ti - 1].isLetter && !t[ti - 1].isNumber { s += 7 }   // a word starts
        score += s; prev = ti; qi += 1
    }
    guard qi == q.count else { return nil }
    let folded = String(t)
    for w in words where folded.contains(w) { score += 4 * w.count }
    if folded.hasPrefix(words.joined(separator: " ")) { score += 15 }
    return score * 10 - min(t.count, 99)
}

/// The order of the palette's lines, as ids. Without a query: the recent ones first (newest first),
/// then the rest as given. With a query: only what matches, best first, recent ones a little ahead.
/// `texts` are what an entry may be found by (its title, the other language).
func paletteOrder(query: String, entries: [(id: String, texts: [String])], recent: [String]) -> [String] {
    let known = Set(entries.map(\.id))
    let trimmed = query.trimmingCharacters(in: .whitespaces)
    if trimmed.isEmpty {
        let first = recent.filter { known.contains($0) }
        let firstSet = Set(first)
        var seen = Set<String>()
        return first.filter { seen.insert($0).inserted } + entries.map(\.id).filter { !firstSet.contains($0) }
    }
    var scored: [(id: String, score: Int, index: Int)] = []
    for (n, e) in entries.enumerated() {
        guard let best = e.texts.compactMap({ fuzzyScore(trimmed, $0) }).max() else { continue }
        let bonus = recent.firstIndex(of: e.id).map { max(0, 8 - $0) * 15 } ?? 0
        scored.append((e.id, best + bonus, n))
    }
    return scored.sorted { $0.score != $1.score ? $0.score > $1.score : $0.index < $1.index }.map(\.id)
}

// MARK: - Commands

enum PaletteAction: String, CaseIterable {
    case deployChanged, reload, stopAll, journal, settings, costs
}
enum PaletteVerb: String, CaseIterable {
    case deploy, log, open, dashboard, rollback, notes
    /// What the person may type, in both languages: an English verb also works on a German Mac.
    var words: (en: String, de: String) {
        switch self {
        case .deploy: return ("deploy", "deployen")
        case .log: return ("log", "Log")
        case .open: return ("open", "öffnen")
        case .dashboard: return ("dashboard", "Dashboard")
        case .rollback: return ("rollback", "zurückrollen")
        case .notes: return ("notes", "Notiz")
        }
    }
    /// Asks first, in the same words as the window.
    var asks: Bool { self == .deploy || self == .rollback }
}

struct PaletteCommand: Identifiable {
    enum Kind { case action(PaletteAction), project(PaletteVerb, Item) }
    let id: String
    let title: String
    let detail: String?
    let symbol: String
    let texts: [String]
    let kind: Kind
}

@MainActor
enum PaletteCommands {
    static let recentKey = "paletteRecent"
    static var recent: [String] { UserDefaults.standard.stringArray(forKey: recentKey) ?? [] }
    static func remember(_ id: String) {
        UserDefaults.standard.set(Array(([id] + recent.filter { $0 != id }).prefix(8)), forKey: recentKey)
    }

    static func all(_ store: Store) -> [PaletteCommand] {
        var out: [PaletteCommand] = []
        func add(_ a: PaletteAction, _ en: String, _ de: String, _ symbol: String, detail: String? = nil) {
            out.append(PaletteCommand(id: "action." + a.rawValue, title: L(en, de), detail: detail, symbol: symbol, texts: [en, de], kind: .action(a)))
        }
        let w = store.waiting
        add(.deployChanged, "Deploy all changed …", "Alles mit Änderungen deployen …", "paperplane.fill",
            detail: w.projects > 0 ? L("\(w.projects) waiting", "\(w.projects) warten") : L("nothing waits", "nichts wartet"))
        add(.reload, "Reload", "Neu laden", "arrow.clockwise")
        let active = store.items.values.joined().filter { $0.state.isActive }.count
        if active > 0 { add(.stopAll, "Stop all", "Alles abbrechen", "stop.circle", detail: L("\(active) running", "\(active) laufen")) }
        add(.journal, "Open journal (deploy history)", "Journal öffnen (Deploy-Verlauf)", "clock.arrow.circlepath")
        add(.settings, "Settings", "Einstellungen", "gear")
        add(.costs, "Costs", "Kosten", "dollarsign.circle")

        let projects = Platform.allCases.flatMap { store.items[$0] ?? [] }.filter { !store.isHidden($0) }
            .sorted { $0.name.localizedStandardCompare($1.name) == .orderedAscending }
        for i in projects {
            // In demo mode only the stand-in is searchable: typing a real name must not reveal it.
            let name = Demo.mask(i.name)
            let waiting = i.hasNewCommits && i.deployable ? Row.waitingText(i) : nil
            let detail = [i.platform.rawValue, waiting].compactMap { $0 }.joined(separator: " · ")
            for v in PaletteVerb.allCases {
                switch v {
                case .deploy, .rollback: guard i.deployable && !i.state.isActive else { continue }
                case .open: guard i.link.flatMap({ URL(string: $0) }) != nil else { continue }
                case .dashboard: guard i.platform == .vercel || i.dashboardURL != nil else { continue }
                case .log, .notes: break
                }
                let words = v.words
                let symbol: String
                switch v {
                case .deploy: symbol = "paperplane"
                case .log: symbol = "doc.text"
                case .open: symbol = "safari"
                case .dashboard: symbol = "rectangle.on.rectangle"
                case .rollback: symbol = "arrow.uturn.backward"
                case .notes: symbol = "note.text"
                }
                out.append(PaletteCommand(id: v.rawValue + "|" + Store.key(i), title: L(words.en, words.de) + " " + name,
                                          detail: detail, symbol: symbol,
                                          texts: ["\(words.en) \(name)", "\(words.de) \(name)"], kind: .project(v, i)))
            }
        }
        return out
    }
}

// MARK: - The panel

struct CommandPalette: View {
    @ObservedObject var store: Store
    let choose: (PaletteCommand) -> Void
    @Environment(\.dismiss) private var dismiss
    @AppStorage("demoMode") private var demoMode = false
    @State private var query = ""
    @State private var selection: String?
    @State private var monitor: Any?
    @FocusState private var focused: Bool

    private var results: [PaletteCommand] {
        let all = PaletteCommands.all(store)
        let byId = Dictionary(all.map { ($0.id, $0) }, uniquingKeysWith: { a, _ in a })
        let order = paletteOrder(query: query, entries: all.map { ($0.id, $0.texts) }, recent: PaletteCommands.recent)
        return order.prefix(60).compactMap { byId[$0] }
    }
    private var recentCount: Int {
        guard query.trimmingCharacters(in: .whitespaces).isEmpty else { return 0 }
        let ids = Set(PaletteCommands.all(store).map(\.id))
        return Set(PaletteCommands.recent.filter { ids.contains($0) }).count
    }

    var body: some View {
        let shown = results
        let current = shown.first { $0.id == selection } ?? shown.first
        let recent = recentCount
        VStack(spacing: 0) {
            HStack(spacing: 8) {
                Image(systemName: "magnifyingglass").foregroundStyle(.secondary).accessibilityHidden(true)
                TextField(L("Type a command or a project", "Befehl oder Projekt eingeben"), text: $query)
                    .textFieldStyle(.plain).font(.title3)
                    .focused($focused)
                    .onSubmit { if let current { run(current) } }
                    .accessibilityLabel(L("Command palette search", "Suche in der Befehlspalette"))
                    .accessibilityHint(L("Up and down arrows choose, Return runs, Escape closes",
                                         "Pfeil hoch und runter wählt, Return führt aus, Escape schließt"))
            }
            .padding(12)
            Divider()
            ScrollViewReader { proxy in
                ScrollView {
                    LazyVStack(alignment: .leading, spacing: 0) {
                        if shown.isEmpty {
                            Text(L("Nothing found", "Nichts gefunden")).foregroundStyle(.secondary).padding(12)
                        }
                        ForEach(Array(shown.enumerated()), id: \.element.id) { n, cmd in
                            if n == 0 && recent > 0 { header(L("Recent", "Zuletzt")) }
                            if n == recent && recent > 0 { header(L("All", "Alle")) }
                            row(cmd, selected: cmd.id == current?.id).id(cmd.id)
                        }
                    }
                    .padding(.vertical, 4)
                }
                .onChange(of: selection) { _, id in if let id { proxy.scrollTo(id) } }
            }
            .frame(height: 340)
            Divider()
            Text(L("↑ ↓ choose · ↩ run · esc close", "↑ ↓ wählen · ↩ ausführen · esc schließen"))
                .font(.caption).foregroundStyle(.secondary)
                .frame(maxWidth: .infinity, alignment: .leading).padding(.horizontal, 12).padding(.vertical, 6)
                .accessibilityHidden(true)
        }
        .frame(width: 540)
        .accessibilityElement(children: .contain)
        .accessibilityLabel(L("Command palette", "Befehlspalette"))
        .onAppear {
            focused = true
            monitor = NSEvent.addLocalMonitorForEvents(matching: .keyDown) { e in
                let code = e.keyCode
                let handled = MainActor.assumeIsolated { key(code) }
                return handled ? nil : e
            }
        }
        .onDisappear { if let monitor { NSEvent.removeMonitor(monitor) }; monitor = nil }
        .onChange(of: query) { _, _ in selection = results.first?.id }
    }

    private func header(_ s: String) -> some View {
        Text(s).font(.caption.weight(.semibold)).foregroundStyle(.secondary)
            .padding(.horizontal, 12).padding(.top, 6).padding(.bottom, 2)
            .accessibilityAddTraits(.isHeader)
    }

    private func row(_ cmd: PaletteCommand, selected: Bool) -> some View {
        Button { run(cmd) } label: {
            HStack(spacing: 10) {
                Image(systemName: cmd.symbol).frame(width: 18).foregroundStyle(selected ? Color.white : Color.secondary)
                Text(cmd.title).lineLimit(1)
                if case .project(let v, _) = cmd.kind, v.asks {
                    Text(L("asks first", "fragt vorher")).font(.caption2)
                        .foregroundStyle(selected ? Color.white.opacity(0.85) : Color.secondary)
                }
                Spacer()
                if let d = cmd.detail { Text(d).font(.caption).foregroundStyle(selected ? Color.white.opacity(0.85) : Color.secondary).lineLimit(1) }
            }
            .foregroundStyle(selected ? Color.white : Color.primary)
            .padding(.horizontal, 10).padding(.vertical, 6)
            .background(RoundedRectangle(cornerRadius: 6).fill(selected ? Color.accentColor : Color.clear))
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .padding(.horizontal, 6)
        .accessibilityLabel(cmd.title + (cmd.detail.map { ", " + $0 } ?? ""))
        .accessibilityHint(isAsking(cmd) ? L("Asks before anything starts", "Fragt, bevor etwas startet") : "")
        .accessibilityAddTraits(selected ? .isSelected : [])
    }

    private func isAsking(_ cmd: PaletteCommand) -> Bool {
        if case .project(let v, _) = cmd.kind { return v.asks }
        if case .action(.deployChanged) = cmd.kind { return true }
        return false
    }

    /// ↑ ↓ move the selection, Esc closes; everything else goes to the search field.
    private func key(_ code: UInt16) -> Bool {
        switch Int(code) {
        case kVK_DownArrow: move(1); return true
        case kVK_UpArrow: move(-1); return true
        case kVK_Escape: dismiss(); return true
        default: return false
        }
    }

    private func move(_ by: Int) {
        let shown = results
        guard !shown.isEmpty else { return }
        let at = shown.firstIndex { $0.id == selection } ?? 0
        let next = shown[max(0, min(shown.count - 1, at + by))]
        selection = next.id
        AccessibilityNotification.Announcement(next.title).post()
    }

    private func run(_ cmd: PaletteCommand) {
        PaletteCommands.remember(cmd.id)
        choose(cmd)
    }
}

/// The costs that the window shows in its bar, in a sheet of their own, with the projects by cost.
struct PaletteCosts: View {
    @ObservedObject var store: Store
    @Environment(\.dismiss) private var dismiss
    @AppStorage("demoMode") private var demoMode = false

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            HStack {
                Text(L("Costs", "Kosten")).font(.headline)
                Spacer()
                Button(L("Close", "Schließen")) { dismiss() }.keyboardShortcut(.cancelAction)
            }.padding(12)
            Divider()
            if let c = store.costs {
                Text(L("Vercel builds, last 7 days: ", "Vercel-Builds, letzte 7 Tage: ") + c.week.formatted(.currency(code: "USD")))
                    .font(.callout).padding(.horizontal, 12).padding(.vertical, 8)
                let top = c.projects.filter { $0.build > 0 }.sorted { $0.build > $1.build }.prefix(12)
                if !top.isEmpty {
                    List(Array(top), id: \.name) { p in
                        HStack {
                            Text(Demo.mask(p.name))
                            Spacer()
                            if let n = p.builds { Text(L("\(n) builds", "\(n) Builds")).foregroundStyle(.secondary) }
                            Text(p.build, format: .currency(code: "USD")).monospacedDigit()
                        }
                        .accessibilityElement(children: .combine)
                    }
                    .listStyle(.inset)
                }
            } else {
                Text(L("No cost data yet. Costs come from Vercel's billing data and are read once an hour.",
                       "Noch keine Kostendaten. Die Kosten kommen aus Vercels Abrechnung und werden stündlich gelesen."))
                    .foregroundStyle(.secondary).padding(16)
            }
        }
        .frame(width: 560, height: 420)
    }
}

// MARK: - The hook in the main window

extension View {
    /// ⌘K and everything the palette leads to (its own sheets and questions).
    func commandPalette(store: Store) -> some View { modifier(CommandPaletteHost(store: store)) }
}

/// Asks the open window to show the palette; used by the global hot key.
@MainActor
final class PaletteCenter: ObservableObject {
    static let shared = PaletteCenter()
    @Published var requests = 0
    /// Main windows on screen that can show the palette.
    var hosts = 0
    /// Set when there was no window: the next one to appear opens the palette.
    var pendingOpen = false

    func summon() {
        NSApp.activate(ignoringOtherApps: true)
        if hosts > 0 {
            if let w = NSApp.windows.first(where: { $0.canBecomeMain && ($0.isVisible || $0.isMiniaturized) }) {
                if w.isMiniaturized { w.deminiaturize(nil) }
                w.makeKeyAndOrderFront(nil)
            }
            requests += 1
        } else if let u = URL(string: "deploycenter://palette") {
            // Opening the app's own link makes SwiftUI open a window; it never starts anything.
            pendingOpen = true
            NSWorkspace.shared.open(u)
        }
    }
}

struct CommandPaletteHost: ViewModifier {
    @ObservedObject var store: Store
    @ObservedObject private var center = PaletteCenter.shared
    @Environment(\.openSettings) private var openSettings
    @State private var showing = false
    @State private var chosen: PaletteCommand?
    @State private var sheet: PaletteSheet?
    @State private var deployItem: Item?
    @State private var unchangedItem: Item?
    @State private var rollbackItem: Item?
    @State private var noteItem: Item?
    @State private var noteText = ""

    enum PaletteSheet: Identifiable {
        case log(Item), journal, costs
        var id: String {
            switch self { case .log(let i): return "log|\(i.platform.cli)/\(i.id)"; case .journal: return "journal"; case .costs: return "costs" }
        }
    }

    func body(content: Content) -> some View {
        content
            .background {
                // Only there for the shortcut; invisible and not in VoiceOver's way.
                Button(L("Command palette", "Befehlspalette")) { showing = true }
                    .keyboardShortcut("k")
                    .opacity(0).frame(width: 0, height: 0).allowsHitTesting(false)
                    .accessibilityHidden(true)
            }
            .sheet(isPresented: $showing, onDismiss: runChosen) {
                CommandPalette(store: store) { cmd in chosen = cmd; showing = false }
            }
            .sheet(item: $sheet) { s in
                switch s {
                case .log(let i): BuildLog(store: store, item: i)
                case .journal: JournalView()
                case .costs: if let c = store.costs { CostsSheet(costs: c) } else { PaletteCosts(store: store) }
                }
            }
            .modifier(PaletteQuestions(store: store, deployItem: $deployItem, unchangedItem: $unchangedItem,
                                       rollbackItem: $rollbackItem, noteItem: $noteItem, noteText: $noteText))
            .onChange(of: center.requests) { _, _ in showing = true }
            .onAppear {
                center.hosts += 1
                PaletteHotKey.update()
                if center.pendingOpen { center.pendingOpen = false; showing = true }
            }
            .onDisappear { center.hosts = max(0, center.hosts - 1) }
    }

    /// After the palette is gone, so a sheet or question can take its place.
    private func runChosen() {
        guard let cmd = chosen else { return }
        chosen = nil
        switch cmd.kind {
        case .action(let a):
            switch a {
            case .deployChanged:
                // The window ticks everything with changes and asks "Put this live now?".
                if store.waiting.projects > 0 { store.pendingDeployAll = true }
                else { store.show(Store.Toast(text: L("Everything merged is live", "Alles Gemergte ist live"), ok: true)) }
            case .reload: Task { await store.autoRefresh() }
            case .stopAll: store.cancelAll()
            case .journal: sheet = .journal
            case .settings: NSApp.activate(ignoringOtherApps: true); openSettings()
            case .costs: sheet = .costs
            }
        case .project(let v, let item):
            // The row as it is now, not as it was when the palette listed it.
            let i = store.items[item.platform]?.first { $0.id == item.id } ?? item
            switch v {
            case .deploy:
                guard i.deployable && !i.state.isActive else { return }
                if i.hasNewCommits || i.headSha == nil { deployItem = i } else { unchangedItem = i }
            case .rollback:
                guard i.deployable && !i.state.isActive else { return }
                rollbackItem = i
            case .log: sheet = .log(i)
            case .open: if let l = i.link, let u = URL(string: l) { NSWorkspace.shared.open(u) }
            case .dashboard:
                if let u = i.dashboardURL { NSWorkspace.shared.open(u) }
                else {
                    // Vercel's address needs the team's slug; the script knows it and opens the page.
                    Task {
                        do { _ = try await Tool.run(["open", i.id, "--dashboard"], timeout: 30) }
                        catch { store.show(Store.Toast(text: Tool.shorten(error.localizedDescription), ok: false)) }
                    }
                }
            case .notes: noteText = store.note(i) ?? ""; noteItem = i
            }
        }
    }
}

/// The palette's questions: the same words as the window's, so a deploy or rollback from here is
/// asked exactly like one from a row. A deploy then takes the usual wait before it starts.
private struct PaletteQuestions: ViewModifier {
    @ObservedObject var store: Store
    @Binding var deployItem: Item?
    @Binding var unchangedItem: Item?
    @Binding var rollbackItem: Item?
    @Binding var noteItem: Item?
    @Binding var noteText: String

    private func shown(_ i: Item?) -> String { Demo.mask(i?.name ?? "") }
    private func binding(_ b: Binding<Item?>) -> Binding<Bool> { Binding(get: { b.wrappedValue != nil }, set: { if !$0 { b.wrappedValue = nil } }) }

    func body(content: Content) -> some View {
        content
            .alert(L("Put this live now?", "Jetzt live schalten?"), isPresented: binding($deployItem)) {
                Button(L("Cancel", "Abbrechen"), role: .cancel) { deployItem = nil }
                Button(L("Deploy", "Deployen")) { if let i = deployItem { store.deployOne(i, preview: false) }; deployItem = nil }
            } message: {
                Text(shown(deployItem) + (deployItem.map { ($0.pendingCommits ?? 0) > 0 ? " – " + Row.waitingText($0) : "" } ?? "")
                     + "\n\n" + L("The newest commit on GitHub goes live.", "Der neueste Stand von GitHub geht live."))
            }
            .alert(L("Nothing new to deploy", "Nichts Neues zu deployen"), isPresented: binding($unchangedItem)) {
                Button(L("Cancel", "Abbrechen"), role: .cancel) { unchangedItem = nil }
                Button(L("Build anyway", "Trotzdem bauen")) { if let i = unchangedItem { store.deployOne(i, preview: false) }; unchangedItem = nil }
            } message: {
                Text(L("\(shown(unchangedItem)) is already on the newest commit. A build costs build minutes and changes nothing.",
                       "\(shown(unchangedItem)) ist schon auf dem neuesten Stand. Ein Build kostet Build-Minuten und ändert nichts."))
            }
            .alert(L("Roll back production?", "Live zurückrollen?"), isPresented: binding($rollbackItem)) {
                Button(L("Cancel", "Abbrechen"), role: .cancel) { rollbackItem = nil }
                Button(L("Roll back", "Zurückrollen"), role: .destructive) { if let i = rollbackItem { store.rollback(i) }; rollbackItem = nil }
            } message: {
                Text(L("\(shown(rollbackItem)) goes back to the deploy that was live before this one.",
                       "\(shown(rollbackItem)) geht zurück auf den Stand, der davor live war."))
            }
            .alert(L("Note", "Notiz"), isPresented: binding($noteItem)) {
                TextField(L("e.g. only after the release mail", "z. B. erst nach der Release-Mail"), text: $noteText)
                Button(L("Cancel", "Abbrechen"), role: .cancel) { noteItem = nil }
                Button(L("Save", "Speichern")) { if let i = noteItem { store.setNote(i, noteText) }; noteItem = nil }
            } message: {
                Text(L("Shown under \(shown(noteItem)). Kept on this Mac only.", "Steht unter \(shown(noteItem)). Bleibt nur auf diesem Mac."))
            }
    }
}

// MARK: - Global hot key (Settings → Advanced, off by default)

/// ⌥⌘K from any app brings Deploy Center forward with the palette open. A Carbon hot key:
/// it needs no accessibility permission and sees only this one key combination.
@MainActor
enum PaletteHotKey {
    static let defaultsKey = "paletteHotKey"
    private static var ref: EventHotKeyRef?
    private static var handler: EventHandlerRef?

    static func update() {
        let on = UserDefaults.standard.bool(forKey: defaultsKey)
        if on && ref == nil { register() }
        else if !on, let r = ref { UnregisterEventHotKey(r); ref = nil }
    }

    private static func register() {
        if handler == nil {
            var spec = EventTypeSpec(eventClass: OSType(kEventClassKeyboard), eventKind: UInt32(kEventHotKeyPressed))
            let status = InstallEventHandler(GetApplicationEventTarget(), { _, _, _ in
                Task { @MainActor in PaletteCenter.shared.summon() }
                return noErr
            }, 1, &spec, nil, &handler)
            guard status == noErr else { Log.write("palette hot key: handler \(status)"); return }
        }
        var r: EventHotKeyRef?
        let id = EventHotKeyID(signature: OSType(0x4443_4B50), id: 1)   // "DCKP"
        let status = RegisterEventHotKey(UInt32(kVK_ANSI_K), UInt32(cmdKey | optionKey), id, GetApplicationEventTarget(), 0, &r)
        if status == noErr { ref = r } else { Log.write("palette hot key: register \(status)") }
    }
}

/// The section in Settings.
struct CommandPaletteSettings: View {
    @AppStorage(PaletteHotKey.defaultsKey) private var hotKey = false

    var body: some View {
        Section(L("Advanced", "Erweitert")) {
            Toggle(L("⌥⌘K opens the command palette from any app", "⌥⌘K öffnet die Befehlspalette aus jeder App"), isOn: $hotKey)
                .onChange(of: hotKey) { _, _ in PaletteHotKey.update() }
            Text(L("In the window, ⌘K always opens it. Deploys and rollbacks from the palette still ask first.",
                   "Im Fenster öffnet ⌘K sie immer. Deploys und Rollbacks aus der Palette fragen trotzdem vorher."))
                .font(.caption).foregroundStyle(.secondary)
        }
    }
}
