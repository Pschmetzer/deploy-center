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
        // Observer mode (Settings → Team): like the window, nothing that deploys or rolls back.
        let looksOnly = store.observer
        if !looksOnly { add(.deployChanged, "Deploy all changed …", "Alles mit Änderungen deployen …", "paperplane.fill",
            detail: w.projects > 0 ? L("\(w.projects) waiting", "\(w.projects) warten") : L("nothing waits", "nichts wartet")) }
        add(.reload, "Reload", "Neu laden", "arrow.clockwise")
        let active = store.items.values.joined().filter { $0.state.isActive }.count
        if active > 0 { add(.stopAll, "Stop all", "Alles abbrechen", "stop.circle", detail: L("\(active) running", "\(active) laufen")) }
        add(.journal, "Open journal (deploy history)", "Journal öffnen (Deploy-Verlauf)", "clock.arrow.circlepath")
        add(.settings, "Settings", "Einstellungen", "gear")
        add(.costs, "Costs", "Kosten", "dollarsign.circle")

        // Only platforms with a tab: a switched-off one may still have its old list in memory.
        let projects = store.enabledProviders.compactMap(\.platform).flatMap { store.items[$0] ?? [] }.filter { !store.isHidden($0) }
            .sorted { $0.name.localizedStandardCompare($1.name) == .orderedAscending }
        for i in projects {
            // In demo mode only the stand-in is searchable: typing a real name must not reveal it.
            let name = Demo.mask(i.name)
            let waiting = i.hasNewCommits && i.deployable ? Row.waitingText(i) : nil
            let detail = [i.platform.rawValue, waiting].compactMap { $0 }.joined(separator: " · ")
            let info = store.provider(i.platform)   // unknown platform info: offered, as before
            for v in PaletteVerb.allCases {
                switch v {
                case .deploy: guard i.deployable && !i.state.isActive && !looksOnly else { continue }
                case .rollback: guard (info?.caps.rollback ?? true) && i.deployable && !i.state.isActive && !looksOnly else { continue }
                case .open: guard i.link.flatMap({ URL(string: $0) }) != nil else { continue }
                case .dashboard: guard i.platform == .vercel || i.dashboardURL != nil else { continue }
                case .log: guard info?.caps.logs ?? true else { continue }
                case .notes: break
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
    /// Not observed: a store poll while the palette is open must not rebuild every line. The lines are
    /// read once on opening (and again when demo mode switches); `runChosen` reads the row as it is
    /// then and checks again whether it may deploy.
    let store: Store
    let choose: (PaletteCommand) -> Void
    @Environment(\.dismiss) private var dismiss
    @AppStorage("demoMode") private var demoMode = false
    @State private var query = ""
    @State private var selection: String?
    @State private var monitor: Any?
    @FocusState private var focused: Bool
    /// Every line, built once; and what the query makes of it, built once per query.
    @State private var commands: [PaletteCommand] = []
    @State private var ordered: (shown: [PaletteCommand], total: Int, recent: Int) = ([], 0, 0)

    /// The window the palette sits in: its arrow keys and Esc are taken there only.
    @State private var home = WindowBox()
    /// Lines shown at most; the rest is found by typing more.
    static let limit = 60

    /// The lines for a query, and how many of them are recent ones (only without a query).
    static func order(_ all: [PaletteCommand], query: String, recent: [String]) -> (shown: [PaletteCommand], total: Int, recent: Int) {
        let byId = Dictionary(all.map { ($0.id, $0) }, uniquingKeysWith: { a, _ in a })
        let order = paletteOrder(query: query, entries: all.map { ($0.id, $0.texts) }, recent: recent)
        var recentCount = 0
        if query.trimmingCharacters(in: .whitespaces).isEmpty {
            recentCount = Set(recent.filter { byId[$0] != nil }).count
        }
        return (order.prefix(limit).compactMap { byId[$0] }, order.count, recentCount)
    }
    private var results: [PaletteCommand] { ordered.shown }

    private func rebuild() {
        commands = PaletteCommands.all(store)
        reorder()
    }
    private func reorder() { ordered = Self.order(commands, query: query, recent: PaletteCommands.recent) }

    var body: some View {
        let o = ordered
        let shown = o.shown, more = o.total - o.shown.count
        let current = shown.first { $0.id == selection } ?? shown.first
        let recent = o.recent
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
                        // Not before the lines are read (the first frame): there is always something.
                        if shown.isEmpty && !commands.isEmpty {
                            Text(L("Nothing found", "Nichts gefunden")).foregroundStyle(.secondary).padding(12)
                        }
                        ForEach(Array(shown.enumerated()), id: \.element.id) { n, cmd in
                            if n == 0 && recent > 0 { header(L("Recent", "Zuletzt")) }
                            if n == recent && recent > 0 { header(L("All", "Alle")) }
                            row(cmd, selected: cmd.id == current?.id).id(cmd.id)
                        }
                        if more > 0 {
                            Text(L("\(more) more – type to narrow down", "\(more) weitere – tippen, um einzugrenzen"))
                                .font(.caption).foregroundStyle(.secondary).padding(.horizontal, 12).padding(.vertical, 6)
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
        .background(WindowReader { home.window = $0 })
        .accessibilityElement(children: .contain)
        .accessibilityLabel(L("Command palette", "Befehlspalette"))
        .onAppear {
            rebuild()
            focused = true
            let home = self.home
            monitor = NSEvent.addLocalMonitorForEvents(matching: .keyDown) { e in
                // Keys in another window (Settings, say) are not the palette's.
                guard let w = home.window, e.window === w else { return e }
                let code = e.keyCode
                let handled = MainActor.assumeIsolated { key(code) }
                return handled ? nil : e
            }
        }
        .onDisappear { if let monitor { NSEvent.removeMonitor(monitor) }; monitor = nil }
        .onChange(of: query) { _, _ in reorder(); selection = results.first?.id }
        // Demo mode switched while open (⇧⌘D): real names must not stay on screen or be searchable.
        .onChange(of: demoMode) { _, _ in rebuild() }
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

/// "Costs" from the palette before any cost data was read; with data the palette opens `CostsSheet`,
/// which also ranks the projects.
struct PaletteCosts: View {
    @Environment(\.dismiss) private var dismiss

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            HStack {
                Text(L("Costs", "Kosten")).font(.headline)
                Spacer()
                Button(L("Close", "Schließen")) { dismiss() }.keyboardShortcut(.cancelAction)
            }.padding(12)
            Divider()
            Text(L("No cost data yet. Costs come from Vercel's billing data and are read once an hour.",
                   "Noch keine Kostendaten. Die Kosten kommen aus Vercels Abrechnung und werden stündlich gelesen."))
                .foregroundStyle(.secondary).padding(16)
        }
        .frame(width: 560)
    }
}

/// A weak hold on a window, for closures that must not keep it alive.
final class WindowBox { weak var window: NSWindow? }

/// Hands over the window a view sits in, once it has one.
struct WindowReader: NSViewRepresentable {
    let found: (NSWindow?) -> Void
    final class Probe: NSView {
        var found: ((NSWindow?) -> Void)?
        override func viewDidMoveToWindow() { super.viewDidMoveToWindow(); found?(window) }
    }
    func makeNSView(context: Context) -> NSView { let p = Probe(); p.found = found; return p }
    func updateNSView(_ v: NSView, context: Context) {}
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
    /// The main windows (each host adds its own), and the one a request is for: only that one opens it.
    private var windows: [WindowBox] = []
    private(set) weak var target: NSWindow?

    func register(_ w: NSWindow?) {
        windows.removeAll { $0.window == nil }
        guard let w, !windows.contains(where: { $0.window === w }) else { return }
        let b = WindowBox(); b.window = w; windows.append(b)
    }

    /// ⌘K in the menu: the palette in the window in front.
    func open(in w: NSWindow?) { target = w; requests += 1 }

    func summon() {
        NSApp.activate(ignoringOtherApps: true)
        if hosts > 0 {
            // A main window (never Settings): the one in front, else any on screen or in the Dock.
            let mains = windows.compactMap(\.window)
            let w = mains.first { $0.isKeyWindow } ?? mains.first { $0.isMainWindow }
                ?? mains.first { $0.isVisible || $0.isMiniaturized }
            if let w {
                if w.isMiniaturized { w.deminiaturize(nil) }
                w.makeKeyAndOrderFront(nil)
            }
            target = w
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
    /// Settings → Deploy: ask before one project goes live (on by default).
    @AppStorage("confirmSingleDeploy") private var confirmSingle = true
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

    /// This host's window, so a request for another main window leaves this one alone.
    @State private var home = WindowBox()
    /// One of the palette's own sheets or questions is up: a second sheet would not show.
    private var busy: Bool { showing || sheet != nil || deployItem != nil || unchangedItem != nil || rollbackItem != nil || noteItem != nil }

    func body(content: Content) -> some View {
        content
            // ⌘K is in the View menu (`WindowCommands`), which asks `PaletteCenter.open(in:)`.
            .background(WindowReader { w in home.window = w; center.register(w) })
            .sheet(isPresented: $showing, onDismiss: runChosen) {
                CommandPalette(store: store) { cmd in chosen = cmd; showing = false }
            }
            .sheet(item: $sheet) { s in
                switch s {
                case .log(let i): BuildLog(store: store, item: i)
                case .journal: JournalView()
                case .costs: if let c = store.costs { CostsSheet(costs: c) } else { PaletteCosts() }
                }
            }
            .modifier(PaletteQuestions(store: store, deployItem: $deployItem, unchangedItem: $unchangedItem,
                                       rollbackItem: $rollbackItem, noteItem: $noteItem, noteText: $noteText))
            .onChange(of: center.requests) { _, _ in
                guard !busy, center.target == nil || center.target === home.window else { return }
                showing = true
            }
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
                guard !store.observer else { return }
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
                guard i.deployable && !i.state.isActive && !store.observer else { return }
                if i.hasNewCommits || i.headSha == nil { if confirmSingle { deployItem = i } else { store.pendingDeploy = i } }
                else { unchangedItem = i }
            case .rollback:
                guard i.deployable && !i.state.isActive && !store.observer else { return }
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
/// asked exactly like one from a row. A deploy goes through the window (deploy window, "only when
/// green", see `Store.pendingDeploy`) and then takes the usual wait before it starts.
private struct PaletteQuestions: ViewModifier {
    @ObservedObject var store: Store
    @Binding var deployItem: Item?
    @Binding var unchangedItem: Item?
    @Binding var rollbackItem: Item?
    @Binding var noteItem: Item?
    @Binding var noteText: String
    /// Deploy was clicked: handed to the window once the question is gone.
    @State private var confirmed: Item?

    private func shown(_ i: Item?) -> String { Demo.mask(i?.name ?? "") }
    private func binding(_ b: Binding<Item?>) -> Binding<Bool> { Binding(get: { b.wrappedValue != nil }, set: { if !$0 { b.wrappedValue = nil } }) }

    func body(content: Content) -> some View {
        content
            // The window's own question, checkbox included; the window deploys once the sheet is gone.
            .sheet(item: $deployItem, onDismiss: {
                if let i = confirmed { confirmed = nil; store.pendingDeploy = i }
            }) { i in DeployConfirmSheet(items: [i], platforms: false) { confirmed = i } }
            .alert(L("Nothing new to deploy", "Nichts Neues zu deployen"), isPresented: binding($unchangedItem)) {
                Button(L("Cancel", "Abbrechen"), role: .cancel) { unchangedItem = nil }
                Button(L("Build anyway", "Trotzdem bauen")) { if let i = unchangedItem { store.pendingDeploy = i }; unchangedItem = nil }
            } message: {
                Text(L("\(shown(unchangedItem)) is already on the newest commit. A build costs build minutes and changes nothing.",
                       "\(shown(unchangedItem)) ist schon auf dem neuesten Stand. Ein Build kostet Build-Minuten und ändert nichts."))
            }
            .alert(L("Roll back production?", "Live zurückrollen?"), isPresented: binding($rollbackItem)) {
                Button(L("Cancel", "Abbrechen"), role: .cancel) { rollbackItem = nil }
                Button(L("Roll back", "Zurückrollen"), role: .destructive) { if let i = rollbackItem, !store.observer { store.rollback(i) }; rollbackItem = nil }
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

// MARK: - Global hot key (Settings → General, off by default)

/// ⌥⌘K from any app brings Deploy Center forward with the palette open. A Carbon hot key:
/// it needs no accessibility permission and sees only this one key combination.
@MainActor
enum PaletteHotKey {
    static let defaultsKey = "paletteHotKey"
    private static var ref: EventHotKeyRef?
    private static var handler: EventHandlerRef?

    /// The last attempt to take ⌥⌘K failed (another app holds it, say).
    private(set) static var failed = false

    /// Takes or frees the key as the setting says. False when it is wanted but could not be taken.
    @discardableResult static func update() -> Bool {
        let on = UserDefaults.standard.bool(forKey: defaultsKey)
        if on && ref == nil { failed = !register() }
        else if !on { if let r = ref { UnregisterEventHotKey(r); ref = nil }; failed = false }
        return !failed
    }

    private static func register() -> Bool {
        if handler == nil {
            var spec = EventTypeSpec(eventClass: OSType(kEventClassKeyboard), eventKind: UInt32(kEventHotKeyPressed))
            let status = InstallEventHandler(GetApplicationEventTarget(), { _, _, _ in
                Task { @MainActor in PaletteCenter.shared.summon() }
                return noErr
            }, 1, &spec, nil, &handler)
            guard status == noErr else { Log.write("palette hot key: handler \(status)"); return false }
        }
        var r: EventHotKeyRef?
        let id = EventHotKeyID(signature: OSType(0x4443_4B50), id: 1)   // "DCKP"
        let status = RegisterEventHotKey(UInt32(kVK_ANSI_K), UInt32(cmdKey | optionKey), id, GetApplicationEventTarget(), 0, &r)
        if status == noErr { ref = r; return true }
        Log.write("palette hot key: register \(status)")
        return false
    }
}

/// The section in Settings.
struct CommandPaletteSettings: View {
    @AppStorage(PaletteHotKey.defaultsKey) private var hotKey = false
    @State private var failed = PaletteHotKey.failed

    var body: some View {
        Section(L("Command palette", "Befehlspalette")) {
            Toggle(L("⌥⌘K opens the command palette from any app", "⌥⌘K öffnet die Befehlspalette aus jeder App"), isOn: $hotKey)
                .onChange(of: hotKey) { _, on in
                    // Taken by another app: the switch goes back, and the reason stays below it.
                    if PaletteHotKey.update() { if on { failed = false } } else { failed = true; hotKey = false }
                }
            if failed {
                Text(L("⌥⌘K is taken by another app, so it could not be switched on.",
                       "⌥⌘K ist schon von einer anderen App belegt und ließ sich nicht einschalten."))
                    .font(.caption).foregroundStyle(.red)
            }
            Text(L("In the window, ⌘K always opens it. Deploys and rollbacks from the palette still ask first.",
                   "Im Fenster öffnet ⌘K sie immer. Deploys und Rollbacks aus der Palette fragen trotzdem vorher."))
                .font(.caption).foregroundStyle(.secondary)
        }
    }
}
