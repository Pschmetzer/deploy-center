// Deploy Center — The main window: list, banners, costs, setup screens, one row.

import SwiftUI
import AppKit
import Charts
import UserNotifications
import ServiceManagement

// MARK: - Window

struct ContentView: View {
    @ObservedObject var store: Store
    // The tab and the filter are remembered between launches.
    @AppStorage("lastPlatform") private var platformRaw = Platform.vercel.rawValue
    private var platform: Platform { get { Platform(rawValue: platformRaw) ?? .vercel } nonmutating set { platformRaw = newValue.rawValue } }
    @State private var search = ""
    @State private var confirming = false
    @State private var confirmingOff = false
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

    /// The platforms the list shows: one tab, or both under "All".
    /// "35" projects, or "35 · 9" when 9 of them have changes waiting.
    private static func tabCount(_ store: Store, _ p: Platform) -> String {
        let n = store.items[p]?.count ?? 0, c = store.changedCount(p)
        return c > 0 ? "\(n) · \(c)" : "\(n)"
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
            all = all.filter { $0.name.localizedCaseInsensitiveContains(search) || $0.detail.localizedCaseInsensitiveContains(search)
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
    private var sameRepoAsAbove: Set<String> {
        var out = Set<String>(); var prev: Item?
        for i in visible {
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

    var body: some View {
        VStack(spacing: 0) {
            header
            Divider()
            if let msg = store.busyMessage {
                HStack { ProgressView().controlSize(.small); Text(msg) }.padding(8)
            }
            if let v = store.newVersion {
                HStack {
                    Image(systemName: "arrow.down.circle.fill").foregroundStyle(.blue)
                    Text(L("Version \(v) is out.", "Version \(v) ist da.")).font(.callout)
                    Button(L("Download", "Herunterladen")) {
                        NSWorkspace.shared.open(URL(string: "https://github.com/Pschmetzer/deploy-center/releases/latest")!)
                    }.buttonStyle(.link)
                    Spacer()
                    Button { store.newVersion = nil } label: { Image(systemName: "xmark") }.buttonStyle(.borderless)
                        .help(L("Not now", "Nicht jetzt"))
                }
                .padding(.horizontal, 12).padding(.vertical, 6).background(Color.blue.opacity(0.06))
            }
            triggerBanner
            providerBanner
            autoBanner
            waitingBar
            githubBanner
            if showAll || platform == .vercel, let c = store.costs { CostBar(costs: c) }
            content
            Divider()
            footer
        }
        .frame(minWidth: 680, minHeight: 540)
        .overlay(alignment: .bottom) {
            if let t = store.toast {
                HStack(spacing: 10) {
                    Label(t.text, systemImage: t.ok ? "checkmark.circle.fill" : "xmark.octagon.fill")
                    if let label = t.undoLabel, let undo = t.undo {
                        Button(label) { undo(); store.toast = nil }.buttonStyle(.link)
                    }
                }
                    .font(.callout.weight(.medium))
                    .padding(.horizontal, 14).padding(.vertical, 8)
                    .background(Capsule().fill(.regularMaterial))
                    .overlay(Capsule().stroke(t.ok ? Color.green.opacity(0.5) : Color.red.opacity(0.5)))
                    .padding(.bottom, 72)
                    .transition(.move(edge: .bottom).combined(with: .opacity))
                    .accessibilityAddTraits(.updatesFrequently)
            }
        }
        .animation(.easeOut(duration: 0.2), value: store.toast)
        .sheet(item: $logItem) { item in BuildLog(item: item) }
        .sheet(isPresented: $showJournal) { JournalView() }
        .sheet(item: $detailItem) { item in ProjectDetail(item: item) { sha in store.deployOne(item, preview: false, sha: sha) } }
        .onChange(of: store.pendingDeployAll) { _, go in
            guard go else { return }
            store.pendingDeployAll = false
            showAll = true; onlyChanged = true
            Platform.allCases.forEach { store.selectChanged($0) }
            if !selectedAll.isEmpty { confirming = true }
        }
        .alert(L("Check after deploy", "Prüfung nach dem Deploy"), isPresented: Binding(get: { pathItem != nil }, set: { if !$0 { pathItem = nil } })) {
            TextField("/health", text: $pathText)
            Button(L("Cancel", "Abbrechen"), role: .cancel) { pathItem = nil }
            Button(L("Save", "Speichern")) { if let i = pathItem { store.setHealthPath(i, pathText) }; pathItem = nil }
        } message: {
            Text(L("This path is asked once \(pathItem?.name ?? "") is live, instead of the front page. Empty = front page.",
                   "Dieser Pfad wird abgefragt, sobald \(pathItem?.name ?? "") live ist, statt der Startseite. Leer = Startseite."))
        }
        .alert(L("Note", "Notiz"), isPresented: Binding(get: { noteItem != nil }, set: { if !$0 { noteItem = nil } })) {
            TextField(L("e.g. only after the release mail", "z. B. erst nach der Release-Mail"), text: $noteText)
            Button(L("Cancel", "Abbrechen"), role: .cancel) { noteItem = nil }
            Button(L("Save", "Speichern")) { if let i = noteItem { store.setNote(i, noteText) }; noteItem = nil }
        } message: {
            Text(L("Shown under \(noteItem?.name ?? ""). Kept on this Mac only.", "Steht unter \(noteItem?.name ?? ""). Bleibt nur auf diesem Mac."))
        }
        .onChange(of: store.pendingSearch) { _, name in
            guard let name else { return }
            showAll = true; onlyChanged = false; search = name; store.pendingSearch = nil
        }
        .alert(L("Nothing new to deploy", "Nichts Neues zu deployen"),
               isPresented: Binding(get: { unchangedItem != nil }, set: { if !$0 { unchangedItem = nil } })) {
            Button(L("Cancel", "Abbrechen"), role: .cancel) { unchangedItem = nil }
            Button(L("Build anyway", "Trotzdem bauen")) { if let i = unchangedItem { store.deployOne(i, preview: false) }; unchangedItem = nil }
        } message: {
            Text(L("\(unchangedItem?.name ?? "") is already on the newest commit. A build costs build minutes and changes nothing.",
                   "\(unchangedItem?.name ?? "") ist schon auf dem neuesten Stand. Ein Build kostet Build-Minuten und ändert nichts."))
        }
        .task {
            store.boot()
            // The search field would take the keyboard (and the space bar) at once; ⌘F still gets there.
            try? await Task.sleep(nanoseconds: 200_000_000)
            if search.isEmpty { NSApp.keyWindow?.makeFirstResponder(nil) }
        }
        .alert(L("Deploy to production?", "Live deployen?"), isPresented: $confirming) {
            Button(L("Cancel", "Abbrechen"), role: .cancel) {}
            Button(L("Deploy", "Deployen")) { scopes.forEach { store.deploySelected($0) } }
        } message: {
            Text(selectedAll.map { i in
                    i.name + ((i.pendingCommits ?? 0) > 0 ? " – " + Row.waitingText(i) : "") }.joined(separator: "\n")
                 + "\n\n" + L("The newest commit on GitHub goes live.",
                               "Der neueste Stand von GitHub geht live.")
                 + unchangedNote)
        }
        .alert(L("Roll back production?", "Live zurückrollen?"),
               isPresented: Binding(get: { rollbackItem != nil }, set: { if !$0 { rollbackItem = nil } })) {
            Button(L("Cancel", "Abbrechen"), role: .cancel) { rollbackItem = nil }
            Button(L("Roll back", "Zurückrollen"), role: .destructive) { if let i = rollbackItem { store.rollback(i) }; rollbackItem = nil }
        } message: {
            Text(L("\(rollbackItem?.name ?? "") goes back to the deploy that was live before this one.",
                   "\(rollbackItem?.name ?? "") geht zurück auf den Stand, der davor live war."))
        }
        .alert(L("Turn off auto-deploy?", "Auto-Deploy ausschalten?"), isPresented: $confirmingOff) {
            Button(L("Cancel", "Abbrechen"), role: .cancel) {}
            Button(L("Turn off", "Ausschalten")) { Task { await store.turnOffAutoDeploy(platform) } }
        } message: {
            Text(store.autoOn(platform).map(\.name).joined(separator: "\n") + "\n\n"
                 + (platform == .vercel
                    ? L("The Git connection is removed (the repo is remembered here). A push will no longer build. Reconnect any time in the Vercel dashboard.",
                        "Die Git-Verbindung wird getrennt (das Repo merkt sich die App). Ein Push baut nichts mehr. Wieder verbinden geht jederzeit im Vercel-Dashboard.")
                    : L("Auto-deploy is set to Off. A push will no longer build.",
                        "Auto-Deploy wird auf Off gestellt. Ein Push baut nichts mehr.")))
        }
    }

    private var header: some View {
        HStack(spacing: 12) {
            Picker("", selection: tab) {
                Text(L("All", "Alle")).tag(Tab.all)
                Text("Vercel  " + Self.tabCount(store, .vercel)).tag(Tab.vercel)
                Text("Render  " + Self.tabCount(store, .render)).tag(Tab.render)
            }
            .pickerStyle(.segmented).labelsHidden().frame(width: 290)

            TextField(L("Search", "Suchen"), text: $search).textFieldStyle(.roundedBorder)
                .focused($searchFocused)
                .onExitCommand { search = ""; searchFocused = false }
                .background {
                    // Keyboard only: ⌘F to the search, ⌘1 and ⌘2 to the tabs.
                    Group {
                        Button("") { searchFocused = true }.keyboardShortcut("f")
                        Button("") { showAll = false; platform = .vercel }.keyboardShortcut("1")
                        Button("") { showAll = false; platform = .render }.keyboardShortcut("2")
                        Button("") { showAll = true }.keyboardShortcut("3")
                    }
                    .opacity(0).frame(width: 0, height: 0).accessibilityHidden(true)
                }

            Toggle(isOn: $onlyChanged) {
                Text(L("Changed only", "Nur mit Änderungen") + " (\(scopes.map { store.changedCount($0) }.reduce(0, +)))")
            }
            .toggleStyle(.button)
            .help(L("Only projects with a commit on GitHub that is not live yet",
                    "Nur Projekte mit einem Commit auf GitHub, der noch nicht live ist"))

            let stamps = scopes.compactMap { p in store.loadedAt[p].map { (showAll ? p.rawValue + " " : "") + $0.formatted(date: .omitted, time: .shortened) } }
            if !stamps.isEmpty {
                Text((scopes.contains { store.fromCache.contains($0) } ? L("saved ", "gespeichert ") : L("updated ", "Aktualisiert "))
                     + stamps.joined(separator: " · "))
                    .font(.caption2).foregroundStyle(.secondary).fixedSize()
            }
            Button { Task { for p in scopes { await store.load(p) }; await store.loadExtras() } } label: {
                if store.loading.contains(platform) { ProgressView().controlSize(.small) }
                else { Image(systemName: "arrow.clockwise") }
            }
            .help(L("Reload (⌘R)", "Neu laden (⌘R)") + (store.loadedAt[platform].map {
                "\n" + L("Updated ", "Aktualisiert ") + $0.formatted(date: .omitted, time: .shortened)
                    + (store.fromCache.contains(platform) ? L(" (saved copy)", " (gespeicherte Kopie)") : "") } ?? ""))
            .keyboardShortcut("r")
            .disabled(store.loading.contains(platform))
        }
        .padding(12)
    }

    @ViewBuilder private var triggerBanner: some View {
        if !store.triggers.isEmpty {
            HStack(alignment: .top, spacing: 10) {
                Image(systemName: "exclamationmark.triangle.fill").font(.title2).foregroundStyle(.red)
                VStack(alignment: .leading, spacing: 3) {
                    Text(L("Something else still starts builds", "Etwas anderes startet noch Builds")).font(.headline)
                    ForEach(store.triggers.prefix(6)) { tr in
                        Text("• \(Self.triggerName(tr.kind)): \(tr.where) – \(tr.detail)").font(.caption).textSelection(.enabled)
                    }
                    if store.triggers.count > 6 {
                        Text(L("and \(store.triggers.count - 6) more", "und \(store.triggers.count - 6) weitere")).font(.caption).foregroundStyle(.secondary)
                    }
                }
                Spacer()
            }
            .padding(12).background(Color.red.opacity(0.1))
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
            }
            .padding(.horizontal, 12).padding(.vertical, 6).background(Color.orange.opacity(0.08))
        }
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
        let same = selectedAll.filter { !$0.hasNewCommits && $0.headSha != nil }.map(\.name)
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
                    .accessibilityLabel(L("PRs waiting per day", "Wartende PRs pro Tag"))
                }
                if w.projects > 0 {
                    Button(L("Show them", "Anzeigen")) { onlyChanged = true; showAll = true }
                }
            }
            .padding(12).background(Color.blue.opacity(0.08))
        }
    }

    @ViewBuilder private var autoBanner: some View {
        let on = store.autoOn(platform)
        if !on.isEmpty {
            HStack(spacing: 10) {
                Image(systemName: "dollarsign.circle.fill").font(.title2).foregroundStyle(.orange)
                VStack(alignment: .leading, spacing: 2) {
                    Text(on.count == 1 ? L("1 project builds on every push", "1 Projekt baut bei jedem Push") : L("\(on.count) projects build on every push", "\(on.count) Projekte bauen bei jedem Push"))
                        .font(.headline)
                    Text(L("Every push costs build minutes. Turn it off and deploy here when you want.",
                           "Jeder Push kostet Build-Minuten. Ausschalten und hier deployen, wann du willst."))
                        .font(.caption).foregroundStyle(.secondary)
                }
                Spacer()
                Button(L("Turn off auto-deploy", "Auto-Deploy ausschalten")) { confirmingOff = true }
                    .buttonStyle(.borderedProminent).tint(.orange)
            }
            .padding(12)
            .background(Color.orange.opacity(0.1))
        }
    }

    @ViewBuilder private var content: some View {
        if let err = store.doctorError {
            Setup(title: L("Something is missing", "Etwas fehlt"), text: err, commands: []) { Task { await store.start() } }
        } else if store.doctor == nil && (store.items[platform] ?? []).isEmpty {
            ProgressView(L("Checking access …", "Prüfe Zugang …")).frame(maxWidth: .infinity, maxHeight: .infinity)
        } else if let d = store.doctor, !d.jq {
            Setup(title: L("jq is missing", "jq fehlt"),
                  text: L("Deploy Center needs the small tool jq. Install it with Homebrew:", "Deploy Center braucht das kleine Werkzeug jq. Installieren mit Homebrew:"),
                  commands: ["brew install jq"]) { Task { await store.start() } }
        } else if platform == .vercel, let d = store.doctor, d.vercelCli, !d.vercelApi {
            Setup(title: L("Update the Vercel CLI", "Vercel-CLI aktualisieren"),
                  text: L("Your Vercel CLI is too old (it has no `vercel api`).", "Deine Vercel-CLI ist zu alt (ihr fehlt `vercel api`)."),
                  commands: ["npm i -g vercel@latest"]) { Task { await store.start() } }
        } else if platform == .vercel, let d = store.doctor, !d.vercelLoggedIn {
            Setup(title: L("Connect Vercel", "Vercel verbinden"),
                  text: d.vercelCli
                    ? L("Log in once in Terminal. The app uses that login.", "Einmal im Terminal anmelden. Die App nutzt diese Anmeldung.")
                    : L("Install the Vercel CLI, then log in once in Terminal.", "Vercel-CLI installieren und einmal im Terminal anmelden."),
                  commands: d.vercelCli ? ["vercel login"] : ["npm i -g vercel", "vercel login"]) {
                Task { await store.start() }
            }
        } else if platform == .render, let d = store.doctor, !d.renderKey {
            RenderKeySetup(store: store)
        } else if let err = store.loadError[platform] {
            VStack(spacing: 10) {
                Image(systemName: "exclamationmark.triangle").font(.largeTitle).foregroundStyle(.orange)
                Text(L("Could not load \(platform.rawValue)", "\(platform.rawValue) konnte nicht geladen werden")).font(.headline)
                Text(err).font(.callout).foregroundStyle(.secondary).multilineTextAlignment(.center).textSelection(.enabled)
                Button(L("Try again", "Nochmal versuchen")) { Task { await store.load(platform) } }
            }
            .padding(30).frame(maxWidth: .infinity, maxHeight: .infinity)
        } else if store.loading.contains(platform) && (store.items[platform] ?? []).isEmpty {
            ProgressView(L("Loading \(platform.rawValue) …", "Lade \(platform.rawValue) …")).frame(maxWidth: .infinity, maxHeight: .infinity)
        } else if visible.isEmpty && (onlyChanged || !search.isEmpty) {
            VStack(spacing: 8) {
                Image(systemName: onlyChanged ? "checkmark.seal.fill" : "magnifyingglass").font(.system(size: 34))
                    .foregroundStyle(onlyChanged ? .green : .secondary)
                Text(onlyChanged ? L("Everything is live", "Alles ist live") : L("Nothing matches “\(search)”", "Nichts passt zu „\(search)“"))
                    .font(.headline)
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity)
        } else if visible.isEmpty {
            VStack(spacing: 8) {
                Image(systemName: "tray").font(.system(size: 34)).foregroundStyle(.secondary)
                Text(L("No projects here", "Keine Projekte hier")).font(.headline)
                Text(L("This account has none on \(platform.rawValue), or all are hidden.", "Dieses Konto hat hier keine bei \(platform.rawValue), oder alle sind ausgeblendet."))
                    .font(.caption).foregroundStyle(.secondary)
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity)
        } else {
            let dupes = sameRepoAsAbove
            List(visible) { item in
                Row(item: item, sameRepoAsAbove: dupes.contains(Store.key(item)), cost: item.platform == .vercel ? store.buildCost(item.name) : nil,
                    perBuild: item.platform == .vercel ? store.costs?.perBuild(item.name) : nil,
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
            Spacer()
            Button { showJournal = true } label: { Image(systemName: "clock.arrow.circlepath") }
                .buttonStyle(.borderless).help(L("Deploy history", "Deploy-Verlauf"))
            if !store.messages.isEmpty {
                Button { showMessages.toggle() } label: { Image(systemName: "bell") }
                    .buttonStyle(.borderless).help(L("Latest messages", "Letzte Meldungen"))
                    .popover(isPresented: $showMessages) {
                        VStack(alignment: .leading, spacing: 6) {
                            ForEach(store.messages.prefix(15)) { m in
                                HStack(alignment: .top, spacing: 6) {
                                    Image(systemName: m.ok ? "checkmark.circle.fill" : "xmark.octagon.fill").foregroundStyle(m.ok ? .green : .red)
                                    Text(m.date.formatted(date: .omitted, time: .shortened)).font(.caption.monospacedDigit()).foregroundStyle(.secondary)
                                    Text(m.text).font(.caption).textSelection(.enabled)
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

struct CostBar: View {
    let costs: Costs
    private var last7: [Costs.Day] { Array(costs.days.suffix(7)) }
    private var week: Double { last7.map(\.build).reduce(0, +) }
    private var average: Double { last7.isEmpty ? 0 : week / Double(last7.count) }

    /// Average build cost per day before auto-deploy was turned off and since, whole days only.
    private var saving: (before: Double, after: Double)? {
        guard let off = costs.offDay else { return nil }
        // Today is not over yet: a half day would make "since" look cheaper than it is.
        let f = DateFormatter(); f.dateFormat = "yyyy-MM-dd"; f.timeZone = TimeZone(identifier: "UTC")
        let today = f.string(from: Date())
        let before = costs.days.filter { $0.day < off }, after = costs.days.filter { $0.day > off && $0.day < today }
        guard !before.isEmpty, !after.isEmpty else { return nil }
        return (before.map(\.build).reduce(0, +) / Double(before.count), after.map(\.build).reduce(0, +) / Double(after.count))
    }

    var body: some View {
        HStack(spacing: 16) {
            VStack(alignment: .leading, spacing: 2) {
                Text(L("Vercel builds, last 7 days", "Vercel-Builds, letzte 7 Tage")).font(.caption).foregroundStyle(.secondary)
                Text(week, format: .currency(code: "USD")).font(.title3.weight(.semibold).monospacedDigit())
                Text(L("≈ ", "≈ ") + (average * 30).formatted(.currency(code: "USD")) + L(" a month at this pace", " im Monat bei diesem Tempo"))
                    .font(.caption2).foregroundStyle(.secondary)
                if let s = saving {
                    Text(L("per day: ", "pro Tag: ") + s.before.formatted(.currency(code: "USD")) + L(" before, ", " vorher, ")
                         + s.after.formatted(.currency(code: "USD")) + L(" since", " seitdem"))
                        .font(.caption2.weight(.medium)).foregroundStyle(s.after < s.before ? .green : .orange)
                    if s.after < s.before {
                        Button(L("Share the saving", "Ersparnis teilen")) { SavingCard.copy(before: s.before, after: s.after) }
                            .buttonStyle(.link).font(.caption2)
                            .help(L("Copies a picture and a sentence with your saving, without project names",
                                    "Kopiert ein Bild und einen Satz mit deiner Ersparnis, ohne Projektnamen"))
                    }
                } else if let off = costs.offDay {
                    Text(L("Auto-deploy off since \(off); the saving shows after a full day", "Auto-Deploy aus seit \(off); die Ersparnis zeigt sich nach einem ganzen Tag"))
                        .font(.caption2).foregroundStyle(.secondary)
                }
            }
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
            .frame(height: 64)
            .accessibilityLabel(L("Build costs per day", "Build-Kosten pro Tag"))
        }
        .padding(.horizontal, 12).padding(.vertical, 8)
        .background(Color.secondary.opacity(0.06))
        .help(L("Build costs from Vercel's billing data; orange: over twice the average; green line: auto-deploy turned off. Total incl. other usage: ",
                "Build-Kosten aus Vercels Abrechnung; orange: mehr als doppelt so viel wie im Schnitt; grüne Linie: Auto-Deploy ausgeschaltet. Gesamt inkl. sonstiger Nutzung: ")
              + last7.map(\.total).reduce(0, +).formatted(.currency(code: "USD")))
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
                    Button { NSPasteboard.general.clearContents(); NSPasteboard.general.setString(c, forType: .string) }
                        label: { Image(systemName: "doc.on.doc") }.buttonStyle(.borderless).help(L("Copy", "Kopieren"))
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

    /// The part of the name that matches the search, marked.
    private func highlighted(_ text: String) -> AttributedString {
        var a = AttributedString(text)
        guard !search.isEmpty, let r = a.range(of: search, options: .caseInsensitive) else { return a }
        a[r].backgroundColor = .yellow.opacity(0.35)
        return a
    }

    var body: some View {
        HStack(spacing: 12) {
            Button(action: toggle) {
                Image(systemName: item.selected ? "checkmark.circle.fill" : "circle")
                    .font(.title3)
                    .foregroundStyle(item.selected ? Color.accentColor : .secondary)
                    .opacity(item.deployable ? 1 : 0.3)
            }
            .buttonStyle(.plain)
            .disabled(!item.deployable || item.state.isActive)
            .accessibilityLabel(item.name)
            .accessibilityValue(item.selected ? L("selected", "ausgewählt") : L("not selected", "nicht ausgewählt"))

            Logo(domain: Demo.on ? nil : item.domain, name: Demo.mask(item.name))

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
                if let note { Text(note).font(.caption.italic()).foregroundStyle(.orange) }
                HStack(spacing: 8) {
                    lastDeploy
                    if let cost, cost >= 0.01 {
                        Text(L("builds 7 days: ", "Builds 7 Tage: ") + cost.formatted(.currency(code: "USD")))
                            .font(.caption2).foregroundStyle(cost >= 5 ? .orange : .secondary)
                            .help(perBuild.map { L("About ", "Etwa ") + $0.formatted(.currency(code: "USD")) + L(" per build", " pro Build") } ?? "")
                    }
                    if item.hasNewCommits && sameRepoAsAbove {
                        Label(L("same changes as the row above (same repo)", "gleiche Änderungen wie die Zeile darüber (gleiches Repo)"), systemImage: "arrow.up.circle")
                            .font(.caption2).foregroundStyle(.secondary)
                    } else if item.hasNewCommits {
                        Label(Self.waitingText(item), systemImage: "arrow.up.circle.fill")
                            .font(.caption2.weight(.semibold)).foregroundStyle(.blue)
                            .help(item.headMsg.map { L("Newest commit: ", "Neuester Commit: ") + $0
                                + (item.headAt.map { " (\(Self.ago($0)))" } ?? "") } ?? "")
                    }
                    if item.hasNewCommits, !sameRepoAsAbove, let since = item.oldestPendingAt {
                        Text(L("oldest waiting commit ", "ältester wartender Commit ") + Self.ago(since))
                            .font(.caption2).foregroundStyle(Date().timeIntervalSince(since) > 3 * 86400 ? .orange : .secondary)
                            .help(L("The oldest commit that is not live", "Der älteste Commit, der noch nicht live ist"))
                    }
                    if !sameRepoAsAbove, let o = item.openPRs, o > 0 {
                        Text(Self.openText(item, o))
                            .font(.caption2).foregroundStyle(.secondary)
                            .help(L("Pull requests on the repo that are not merged yet", "Pull Requests im Repo, die noch nicht gemergt sind"))
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
                    .accessibilityLabel(L("Details for \(item.name)", "Details zu \(item.name)"))
            }
        }
        .padding(.vertical, 4)
        .contentShape(Rectangle())
        .opacity(item.deployable ? 1 : 0.55)
        .onTapGesture { if !item.state.isActive { toggle() } }
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

    static func ago(_ d: Date) -> String {
        let f = RelativeDateTimeFormatter()
        f.locale = Locale(identifier: isGerman ? "de_DE" : "en_US")
        f.unitsStyle = .full
        return f.localizedString(for: d, relativeTo: Date())
    }

    @ViewBuilder private var lastDeploy: some View {
        if let at = item.lastAt {
            let s = (item.lastState ?? "").lowercased()
            let ok = ["ready", "live", "succeeded"].contains(s)
            let failed = s.contains("fail") || s == "error" || s == "canceled"
            HStack(spacing: 4) {
                Circle().fill(ok ? Color.green : (failed ? Color.red : Color.orange)).frame(width: 7, height: 7)
                Text(L("Last deploy ", "Zuletzt deployt ") + Self.ago(at) + (ok ? "" : " · \(s)"))
                    .font(.caption2).foregroundStyle(.secondary)
            }
            .help(at.formatted(date: .complete, time: .shortened) + (item.lastMsg.map { "\n" + L("Live: ", "Live: ") + $0 } ?? ""))
        } else {
            Text(L("Never deployed", "Noch nie deployt")).font(.caption2).foregroundStyle(.secondary)
        }
    }

    @ViewBuilder private var cancelButton: some View {
        if let onCancel {
            Button(action: onCancel) { Image(systemName: "stop.circle") }
                .buttonStyle(.borderless).help(L("Cancel", "Abbrechen"))
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
                            .foregroundStyle(usualMinutes.map { secs > 120 * $0 } == true ? Color.orange : Color.primary)
                    }
                } else { Text(s).font(.caption) }
                cancelButton
            }
        case .done(let url):
            HStack(spacing: 6) {
                Label("Live", systemImage: "checkmark.circle.fill").foregroundStyle(.green).font(.caption.weight(.semibold))
                if let url, let u = URL(string: url) {
                    Button { NSWorkspace.shared.open(u) } label: { Image(systemName: "arrow.up.right.square") }
                        .buttonStyle(.borderless).help(url)
                    if item.previewId != nil {
                        Button { NSPasteboard.general.clearContents(); NSPasteboard.general.setString(url, forType: .string) }
                            label: { Image(systemName: "link") }
                            .buttonStyle(.borderless).help(L("Copy the preview link", "Vorschau-Link kopieren"))
                    }
                }
            }
        case .skipped(let msg):
            Label(L("Skipped", "Übersprungen"), systemImage: "forward.circle.fill")
                .foregroundStyle(.secondary).font(.caption.weight(.semibold))
                .help(msg)
        case .failed(let msg):
            HStack(spacing: 4) {
                Label(L("Failed", "Fehler"), systemImage: "xmark.octagon.fill")
                    .foregroundStyle(.red).font(.caption.weight(.semibold))
                    .help(msg)
                Button { NSPasteboard.general.clearContents(); NSPasteboard.general.setString("\(item.name): \(msg)", forType: .string) }
                    label: { Image(systemName: "doc.on.doc") }
                    .buttonStyle(.borderless).help(L("Copy the error", "Fehler kopieren"))
                if let showLog {
                    Button(action: showLog) { Image(systemName: "text.alignleft") }
                        .buttonStyle(.borderless).help(L("Build log", "Build-Log"))
                }
                if let onRetry {
                    Button(action: onRetry) { Image(systemName: "arrow.clockwise") }
                        .buttonStyle(.borderless).help(L("Try again", "Erneut versuchen"))
                }
            }
        }
    }
}
