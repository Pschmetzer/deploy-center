// Deploy Center for iPhone and iPad — List, details, settings. System fonts and colours only:
// Dynamic Type, dark mode and VoiceOver come with them.

import SwiftUI

struct RootView: View {
    @ObservedObject var store: PhoneStore
    @Environment(\.scenePhase) private var phase
    @State private var selection: String?
    @State private var settings = false
    @State private var connect = false

    var body: some View {
        NavigationSplitView {
            Group {
                if !store.demo && !store.hasAccount { Welcome(store: store, settings: $settings, connect: $connect) }
                else { ProjectList(store: store, selection: $selection) }
            }
            .navigationTitle("Deploy Center")
            .toolbar {
                ToolbarItem(placement: .topBarTrailing) {
                    Button { settings = true } label: { Image(systemName: "gearshape") }
                        .accessibilityLabel(L("Settings", "Einstellungen"))
                }
            }
        } detail: {
            if let key = selection, let p = store.projects.first(where: { $0.key == key }) {
                ProjectDetail(store: store, project: p)
            } else {
                ContentUnavailableView(L("Choose a project", "Wähle ein Projekt"), systemImage: "square.stack.3d.up")
            }
        }
        .sheet(isPresented: $settings) { SettingsView(store: store) }
        .sheet(isPresented: $connect) { ConnectMacView(store: store) }
        .onChange(of: phase) { _, p in
            if p == .active && !store.demo { let had = store.linked; store.refreshLink(); if store.linked != had { Task { await store.reload() } } }
        }
        .task {
            await store.reload()
            // For screenshots: -open <name> selects a project, -settings shows the settings.
            let args = ProcessInfo.processInfo.arguments
            if let i = args.firstIndex(of: "-open"), i + 1 < args.count {
                selection = store.projects.first { $0.name == args[i + 1] }?.key
            }
            if args.contains("-settings") { try? await Task.sleep(for: .seconds(1)); settings = true }
        }
        .overlay(alignment: .bottom) {
            if let m = store.message {
                Text(m).font(.callout).padding(.horizontal, 16).padding(.vertical, 10)
                    .background(.regularMaterial, in: Capsule()).padding(.bottom, 12)
                    .onTapGesture { store.message = nil }
                    .task(id: m) { try? await Task.sleep(for: .seconds(4)); if store.message == m { store.message = nil } }
                    .accessibilityAddTraits(.isStaticText)
            }
        }
    }
}

struct Welcome: View {
    @ObservedObject var store: PhoneStore
    @Binding var settings: Bool
    @Binding var connect: Bool
    var body: some View {
        ContentUnavailableView {
            Label(L("Your deploys, on the go", "Deine Deploys, unterwegs"), systemImage: "paperplane.fill")
        } description: {
            Text(L("Connect to Deploy Center on your Mac, or add a Vercel token or a Render API key. Keys go only to Vercel, Render and GitHub.",
                   "Verbinde dich mit Deploy Center auf deinem Mac, oder füge ein Vercel-Token oder einen Render-API-Key hinzu. Schlüssel gehen nur an Vercel, Render und GitHub."))
        } actions: {
            Button(L("Connect to the Mac", "Mit dem Mac verbinden")) { connect = true }.buttonStyle(.borderedProminent)
            Button(L("Enter a token", "Token eingeben")) { settings = true }
            Button(L("Try the demo", "Demo ausprobieren")) { store.demo = true }
        }
    }
}

struct ProjectList: View {
    @ObservedObject var store: PhoneStore
    @Binding var selection: String?
    var body: some View {
        List(selection: $selection) {
            Section {
                Summary(store: store)
            } footer: {
                VStack(alignment: .leading, spacing: 4) {
                    if let at = store.loadedAt {
                        Text((store.demo ? L("Demo data · ", "Demodaten · ") : "") + L("Updated ", "Stand ") + at.formatted(.relative(presentation: .named)))
                    }
                    ForEach(store.errors, id: \.self) { Text($0).foregroundStyle(.red) }
                }
            }
            ForEach(PhoneProject.Group.allCases, id: \.self) { g in
                let rows = store.projects.filter { $0.group == g }
                if !rows.isEmpty {
                    Section(g.title) {
                        ForEach(rows) { p in Row(p: p, running: store.running[p.key]).tag(p.key) }
                    }
                }
            }
        }
        .refreshable { await store.reload() }
        .overlay { if store.loading && store.projects.isEmpty { ProgressView() } }
    }
}

struct Summary: View {
    @ObservedObject var store: PhoneStore
    @Environment(\.dynamicTypeSize) private var size
    var body: some View {
        let prs = Stat(value: store.waitingPRs, label: L("PRs waiting", "PRs warten"), tint: .accentColor)
        let projects = Stat(value: store.waiting.count, label: L("projects", "Projekte"), tint: .primary)
        let building = Stat(value: store.projects.filter(\.building).count, label: L("building", "bauen"), tint: .blue)
        let failed = Stat(value: store.projects.filter(\.failed).count, label: L("failed", "Fehler"), tint: .red)
        Group {
            // Four in a row get too tight with the largest text sizes: two rows of two then.
            if size.isAccessibilitySize {
                Grid(verticalSpacing: 12) { GridRow { prs; projects }; GridRow { building; failed } }
            } else {
                HStack(spacing: 0) { prs; projects; building; failed }
            }
        }
        .padding(.vertical, 4)
        .accessibilityElement(children: .combine)
    }
}

struct Stat: View {
    let value: Int, label: String, tint: Color
    var body: some View {
        VStack(spacing: 2) {
            Text("\(value)").font(.title2.weight(.bold).monospacedDigit()).foregroundStyle(tint)
            Text(label).font(.caption2).foregroundStyle(.secondary).lineLimit(1).minimumScaleFactor(0.7)
        }
        .frame(maxWidth: .infinity)
    }
}

extension PhoneProject {
    var icon: String {
        building ? "hammer.fill" : failed ? "xmark.octagon.fill" : changed ? "arrow.up.circle.fill" : "checkmark.circle.fill"
    }
    var tint: Color { building ? .blue : failed ? .red : changed ? .accentColor : .green }
    var stateText: String {
        if building { return L("building", "baut") }
        if failed { return L("failed", "fehlgeschlagen") }
        // Before `changed`: after a force push the compare fails and the count is unknown, not 0.
        if rewritten && changed { return L("history rewritten · count unknown", "Verlauf neu geschrieben · Anzahl unbekannt") }
        if changed {
            let pr = pendingPRs ?? 0
            let prs = pr == 1 ? L("1 PR · ", "1 PR · ") : pr > 1 ? L("\(pr) PRs · ", "\(pr) PRs · ") : ""
            guard let n = pendingCommits else { return prs + L("waiting, count unknown", "wartet, Anzahl unbekannt") }
            return prs + (n == 1 ? L("1 commit waiting", "1 Commit wartet") : L("\(n) commits waiting", "\(n) Commits warten"))
        }
        if paused { return L("paused", "pausiert") }
        if rewritten { return L("history rewritten", "Verlauf neu geschrieben") }
        if unknown { return L("state unknown", "Stand unbekannt") }
        return L("up to date", "aktuell")
    }
}

struct Row: View {
    let p: PhoneProject
    let running: String?
    @ScaledMetric(relativeTo: .title3) private var iconWidth = 24.0
    var body: some View {
        HStack(spacing: 12) {
            if running != nil { ProgressView().frame(width: iconWidth) }
            else { Image(systemName: p.icon).foregroundStyle(p.tint).font(.title3).frame(width: iconWidth).accessibilityHidden(true) }
            VStack(alignment: .leading, spacing: 2) {
                Text(p.name).font(.body.weight(.semibold))
                Text((running.map { L("deploying: ", "deployt: ") + $0 } ?? p.stateText) + " · " + p.provider.rawValue)
                    .font(.caption).foregroundStyle(.secondary)
            }
        }
        .accessibilityElement(children: .combine)
    }
}

struct ProjectDetail: View {
    @ObservedObject var store: PhoneStore
    let project: PhoneProject
    @State private var confirmDeploy = false
    @State private var rollbackTo: (id: String, sha: String?)?
    @State private var confirmRollback = false
    @State private var findingRollback = false

    var body: some View {
        let p = project
        List {
            Section {
                LabeledContent(L("Status", "Status")) {
                    HStack(spacing: 6) { Image(systemName: p.icon); Text(p.stateText) }.foregroundStyle(p.tint)
                }
                LabeledContent(L("Platform", "Plattform"), value: p.provider.rawValue)
                if let r = p.repo { LabeledContent(L("Repository", "Repository"), value: r + (p.branch.map { " · \($0)" } ?? "")) }
                if let d = p.domain { LabeledContent(L("Domain", "Domain"), value: d) }
                if let n = p.openPRs { LabeledContent(L("Open pull requests", "Offene Pull Requests"), value: "\(n)") }
                if let e = p.fetchError {
                    LabeledContent(L("Read error", "Lesefehler")) { Text(e).foregroundStyle(.red) }
                }
                if let d = p.oldestPendingAt, p.changed {
                    LabeledContent(L("Waiting since", "Wartet seit"), value: d.formatted(.relative(presentation: .named)))
                }
            }
            Section(L("Commits", "Commits")) {
                if let m = p.headMsg { LabeledContent(L("Newest", "Neuester"), value: m) }
                if let m = p.liveMsg { LabeledContent(L("Live", "Live"), value: m) }
                if let s = p.liveSha { LabeledContent("SHA", value: String(s.prefix(7))).font(.body.monospaced()) }
            }
            Section {
                Button {
                    confirmDeploy = true
                } label: {
                    Label(p.failed ? L("Deploy again …", "Erneut deployen …") : L("Deploy the newest commit …", "Neuesten Commit deployen …"),
                          systemImage: "paperplane")
                }
                .disabled(!p.deployable || p.building || store.running[p.key] != nil)
                Button(role: .destructive) {
                    guard !findingRollback else { return }
                    findingRollback = true
                    Task {
                        defer { findingRollback = false }
                        store.message = nil
                        rollbackTo = await store.rollbackTarget(p); confirmRollback = rollbackTo != nil
                        if rollbackTo == nil && store.message == nil { store.message = L("Nothing to roll back to.", "Nichts zum Zurückrollen.") }
                    }
                } label: {
                    HStack {
                        Label(L("Roll back …", "Zurückrollen …"), systemImage: "arrow.uturn.backward")
                        if findingRollback { Spacer(); ProgressView() }
                    }
                }
                .disabled(findingRollback || p.paused || p.building || store.running[p.key] != nil)
            } footer: {
                Text(L("Each deploy and rollback asks for Face ID. It goes straight from this device to \(p.provider.rawValue).",
                       "Jeder Deploy und jedes Zurückrollen fragt nach Face ID. Es geht direkt von diesem Gerät an \(p.provider.rawValue)."))
            }
        }
        .navigationTitle(p.name)
        .confirmationDialog(L("Deploy \(p.name)?", "\(p.name) deployen?"), isPresented: $confirmDeploy, titleVisibility: .visible) {
            Button(L("Deploy", "Deployen")) { Task { await store.deploy(p) } }
            Button(L("Cancel", "Abbrechen"), role: .cancel) {}
        } message: {
            Text(L("The newest commit of \(p.branch ?? "the branch") goes live on \(p.provider.rawValue). This can cost build minutes.",
                   "Der neueste Commit von \(p.branch ?? "dem Branch") geht auf \(p.provider.rawValue) live. Das kann Build-Minuten kosten."))
        }
        .confirmationDialog(L("Roll back \(p.name)?", "\(p.name) zurückrollen?"), isPresented: $confirmRollback, titleVisibility: .visible) {
            Button(L("Roll back", "Zurückrollen"), role: .destructive) {
                if let t = rollbackTo { Task { await store.rollback(p, to: t.id) } }
            }
            Button(L("Cancel", "Abbrechen"), role: .cancel) {}
        } message: {
            // Without a commit SHA the deploy id names it.
            let what = rollbackTo.map { String(($0.sha ?? $0.id).prefix($0.sha == nil ? 24 : 7)) } ?? ""
            Text(L("The previous deploy (\(what)) goes live again.", "Der vorige Deploy (\(what)) geht wieder live."))
        }
    }
}

struct SettingsView: View {
    @ObservedObject var store: PhoneStore
    @Environment(\.dismiss) private var dismiss
    @State private var vercel = ""
    @State private var team = ""
    @State private var render = ""
    @State private var github = ""
    @AppStorage("notify") private var notify = false
    @State private var connect = false

    var body: some View {
        NavigationStack {
            Form {
                Section {
                    if store.linked != nil {
                        Label(L("Connected to the Mac (iCloud Keychain)", "Mit dem Mac verbunden (iCloud-Schlüsselbund)"), systemImage: "checkmark.circle.fill")
                            .foregroundStyle(.green)
                    }
                    Button(store.linked == nil ? L("Connect to the Mac …", "Mit dem Mac verbinden …") : L("Connection details …", "Verbindung …")) { connect = true }
                } header: { Text("Mac") } footer: {
                    Text(L("Keys from the Mac are used when a field below is empty. A key typed here wins.",
                           "Schlüssel vom Mac gelten, wenn ein Feld unten leer ist. Ein hier eingetragener Schlüssel hat Vorrang."))
                }
                Section {
                    SecureField(L("Vercel token", "Vercel-Token"), text: $vercel).textContentType(.password)
                    TextField(L("Vercel team id (optional)", "Vercel-Team-ID (optional)"), text: $team)
                        .textInputAutocapitalization(.never).autocorrectionDisabled()
                    SecureField(L("Render API key", "Render-API-Key"), text: $render).textContentType(.password)
                    SecureField(L("GitHub token (optional, for private repos)", "GitHub-Token (optional, für private Repos)"), text: $github)
                        .textContentType(.password)
                } header: { Text(L("Accounts", "Konten")) } footer: {
                    Text(L("Keys typed here stay in this device's keychain, never synced. Sent only to api.vercel.com, api.render.com and api.github.com.",
                           "Hier eingetragene Schlüssel bleiben im Schlüsselbund dieses Geräts, nie synchronisiert. Gesendet nur an api.vercel.com, api.render.com und api.github.com."))
                }
                Section {
                    Toggle(L("Demo mode (made-up projects)", "Demo-Modus (erfundene Projekte)"), isOn: $store.demo)
                    Toggle(L("Notify when something waits or fails", "Melden, wenn etwas wartet oder fehlschlägt"), isOn: $notify)
                        .onChange(of: notify) { _, on in
                            // Switched back off when iOS says no; the system settings can change that later.
                            if on { Task { if !(await Background.requestPermission()) { notify = false
                                store.message = L("Notifications are off for Deploy Center in the iOS Settings.",
                                                  "Mitteilungen sind für Deploy Center in den iOS-Einstellungen aus.") } } }
                        }
                } footer: {
                    Text(L("Checks run in the background when iOS allows it, usually a few times an hour. There is no server, so a note can come late.",
                           "Geprüft wird im Hintergrund, wenn iOS es erlaubt, meist ein paar Mal pro Stunde. Es gibt keinen Server, ein Hinweis kann also später kommen."))
                }
                Section {
                    Link(L("Privacy policy", "Datenschutz"), destination: URL(string: "https://deploycenter.app/datenschutz.html")!)
                    Link(L("Website and help", "Website und Hilfe"), destination: URL(string: "https://deploycenter.app")!)
                } footer: {
                    Text(L("Deploy Center is not affiliated with Vercel, Render or GitHub.",
                           "Deploy Center ist nicht mit Vercel, Render oder GitHub verbunden."))
                }
            }
            .navigationTitle(L("Settings", "Einstellungen"))
            .toolbar {
                ToolbarItem(placement: .confirmationAction) {
                    Button(L("Done", "Fertig")) { save(); dismiss() }
                }
            }
            .onAppear(perform: loadFields)
            // A QR code scanned from here writes the keychain: read it again, or "Done" would save the old fields over it.
            .sheet(isPresented: $connect, onDismiss: loadFields) { ConnectMacView(store: store) }
        }
    }

    private func loadFields() {
        vercel = store.ownToken(.vercel) ?? ""; team = store.ownToken(.vercelTeam) ?? ""
        render = store.ownToken(.render) ?? ""; github = store.ownToken(.github) ?? ""
    }

    private func save() {
        Keychain.set(PhoneStore.TokenKey.vercel.rawValue, vercel)
        Keychain.set(PhoneStore.TokenKey.vercelTeam.rawValue, team)
        Keychain.set(PhoneStore.TokenKey.render.rawValue, render)
        Keychain.set(PhoneStore.TokenKey.github.rawValue, github)
        Task { await store.reload() }
    }
}
