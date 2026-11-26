// Settings: keys, the Mac link, alerts and privacy.

import CoreSpotlight
import SwiftUI
import UniformTypeIdentifiers
import UserNotifications

struct SettingsView: View {
    @ObservedObject var store: PhoneStore
    @Environment(\.dismiss) private var dismiss
    @Environment(\.openURL) private var openURL
    typealias Key = PhoneStore.TokenKey
    @State private var fields: [Key: String] = [:]
    @State private var saved: [Key: String] = [:]
    @AppStorage("notify") private var notify = false
    @AppStorage("lockOnOpen") private var lockOnOpen = false
    @AppStorage("biometricsOnly") private var biometricsOnly = false
    @AppStorage("noSpotlight") private var noSpotlight = false
    @State private var connect = false
    @State private var notesDenied = false
    @State private var testResults: [String] = []
    @State private var saveFailed = false
    @State private var badKey: String?
    @State private var confirmRemove = false
    @State private var confirmDemo = false
    @State private var githubScopes: [String]?
    @State private var testing = false

    /// Typed but not saved: swiping the sheet away must not throw it away silently.
    private var dirty: Bool { Key.allCases.contains { (fields[$0] ?? "") != (saved[$0] ?? "") } }
    /// Scopes that can change repos: more than the phone needs (it only reads GitHub).
    private var writeScopes: [String] { (githubScopes ?? []).filter { ["repo", "workflow", "write:packages", "delete_repo", "admin:org"].contains($0) } }

    private func field(_ k: Key) -> Binding<String> { Binding(get: { fields[k] ?? "" }, set: { fields[k] = $0 }) }
    /// The placeholder says when the Mac's key is in use for an empty field.
    private func prompt(_ k: Key, _ en: String, _ de: String) -> String {
        store.linkedToken(k) != nil && (fields[k] ?? "").isEmpty ? L(en, de) + L(" (from the Mac)", " (vom Mac)") : L(en, de)
    }

    var body: some View {
        NavigationStack {
            Form {
                // The toast lies under this sheet: an error is shown here as text, not only said to VoiceOver (IDEEN-12 C11).
                if let m = store.message, store.messageIsError {
                    Section {
                        Label(m, systemImage: "exclamationmark.triangle.fill").foregroundStyle(Color.errorText)
                        Button(L("Dismiss", "Ausblenden")) { store.message = nil }
                    }
                }
                Section {
                    if store.linked != nil && !store.ignoreLink {
                        Label(L("Connected to the Mac (iCloud Keychain)", "Mit dem Mac verbunden (iCloud-Schlüsselbund)"), systemImage: "checkmark.circle.fill")
                            .foregroundStyle(Color.successText)
                    }
                    Button(store.linked == nil || store.ignoreLink ? L("Connect to the Mac …", "Mit dem Mac verbinden …") : L("Connection details …", "Verbindung …")) { connect = true }
                } header: { Text("Mac") } footer: {
                    Text(L("Keys from the Mac are used when a field below is empty. A key typed here wins.",
                           "Schlüssel vom Mac gelten, wenn ein Feld unten leer ist. Ein hier eingetragener Schlüssel hat Vorrang."))
                }
                Section {
                    // No password content type: iOS would offer to save the tokens in iCloud Passwords, against "never synced".
                    SecureField(prompt(.vercel, "Vercel token", "Vercel-Token"), text: field(.vercel)).textContentType(nil).privacySensitive()
                    TextField(prompt(.vercelTeam, "Vercel team id (optional)", "Vercel-Team-ID (optional)"), text: field(.vercelTeam))
                        .textInputAutocapitalization(.never).autocorrectionDisabled()
                    SecureField(prompt(.render, "Render API key", "Render-API-Key"), text: field(.render)).textContentType(nil).privacySensitive()
                    SecureField(prompt(.github, "GitHub token (optional, for private repos)", "GitHub-Token (optional, für private Repos)"), text: field(.github))
                        .textContentType(nil).privacySensitive()
                    if !writeScopes.isEmpty {
                        Label(L("This GitHub token can also write (\(writeScopes.joined(separator: ", "))). The phone only reads: a fine-grained token with read-only access to contents and pull requests is enough.",
                                "Dieses GitHub-Token darf auch schreiben (\(writeScopes.joined(separator: ", "))). Das iPhone liest nur: Ein fein granulares Token mit Nur-Lese-Zugriff auf Inhalte und Pull Requests genügt."),
                              systemImage: "exclamationmark.shield").font(.footnote).foregroundStyle(Color.warningText)
                    }
                    Button { Task { await test() } } label: {
                        HStack { Text(L("Test the keys", "Schlüssel testen")); if testing { Spacer(); ProgressView() } }
                    }
                    .disabled(testing)
                    ForEach(testResults, id: \.self) { Text($0).font(.footnote) }
                } header: { Text(L("Accounts", "Konten")) } footer: {
                    Text(L("Keys typed here stay in this device's keychain, never synced. Sent only to api.vercel.com, api.render.com and api.github.com. Use the smallest scope and a short lifetime: a Vercel token for one team that expires, a read-only GitHub token.",
                           "Hier eingetragene Schlüssel bleiben im Schlüsselbund dieses Geräts, nie synchronisiert. Gesendet nur an api.vercel.com, api.render.com und api.github.com. Nimm den kleinsten Bereich und eine kurze Laufzeit: ein Vercel-Token für ein Team, das abläuft, ein Nur-Lese-GitHub-Token."))
                }
                Section {
                    Toggle(L("Unlock on open", "Beim Öffnen entsperren"), isOn: guarded($lockOnOpen, L("Turn off the lock", "Sperre ausschalten")))
                        .onChange(of: lockOnOpen) { _, _ in
                            Spotlight.index(store.projects, demo: store.demo); QuickActions.update(store.projects)
                        }
                    Toggle(L("Face ID or Touch ID only (no passcode) to deploy", "Zum Deployen nur Face ID oder Touch ID (kein Code)"), isOn: guarded($biometricsOnly, L("Allow the passcode to deploy", "Code zum Deployen erlauben")))
                    Toggle(L("Keep projects out of Spotlight", "Projekte nicht in Spotlight zeigen"), isOn: $noSpotlight)
                        .onChange(of: noSpotlight) { _, _ in Spotlight.index(store.projects, demo: store.demo) }
                } footer: {
                    Text(L("Asks for \(store.unlockName) when Deploy Center opens, and hides the list in the app switcher.",
                           "Fragt beim Öffnen nach \(store.unlockName) und verdeckt die Liste im App-Umschalter."))
                }
                Section {
                    // Turning it on replaces the real list with made-up projects: with keys in place, ask first.
                    Toggle(L("Demo mode (made-up projects)", "Demo-Modus (erfundene Projekte)"),
                           isOn: Binding(get: { store.demo }, set: { on in
                               if on && store.hasAccount { confirmDemo = true } else { store.demo = on }
                           }))
                    Toggle(L("Notify when something waits or fails", "Melden, wenn etwas wartet oder fehlschlägt"), isOn: $notify)
                        .onChange(of: notify) { _, on in
                            // Switched back off when iOS says no; the system settings can change that later.
                            Task {
                                if on, !(await Background.requestPermission()) {
                                    notify = false
                                    store.fail(L("Notifications are off for Deploy Center in the iOS Settings.",
                                                 "Mitteilungen sind für Deploy Center in den iOS-Einstellungen aus."))
                                }
                                await checkNotes(); await store.updateBadge(); Background.schedule()
                            }
                        }
                    if notesDenied {
                        Button(L("Notifications are off for Deploy Center. Open Settings …", "Mitteilungen sind für Deploy Center aus. Einstellungen öffnen …")) {
                            openSettings()
                        }
                    }
                } footer: {
                    VStack(alignment: .leading, spacing: 4) {
                        Text(L("Checks run in the background only when iOS allows it, which can be rarely or, in Low Power Mode, not at all. There is no server, so a note can come late or not at all.",
                               "Geprüft wird im Hintergrund nur, wenn iOS es erlaubt: manchmal selten, im Stromsparmodus gar nicht. Es gibt keinen Server, ein Hinweis kann also spät oder gar nicht kommen."))
                        if notify, let e = backgroundProblem { Text(e).foregroundStyle(Color.warningText) }
                        if notify {
                            // The last time iOS let the background check run (IDEEN-12 C19).
                            if let at = Background.lastRun {
                                Text(L("Last background check: ", "Letzte Prüfung im Hintergrund: ") + relative(at))
                            } else {
                                Text(L("No background check has run yet.", "Im Hintergrund wurde noch nichts geprüft."))
                            }
                        }
                    }
                }
                Section {
                    Button(L("Language …", "Sprache …")) { openSettings() }
                } footer: {
                    Text(L("The app follows your iPhone's language. To pick another one for this app only: Settings → Deploy Center → Language.",
                           "Die App folgt der Sprache deines iPhones. Eine andere nur für diese App: Einstellungen → Deploy Center → Sprache."))
                }
                Section {
                    Button(L("Remove all keys from this iPhone …", "Alle Schlüssel von diesem iPhone entfernen …"), role: .destructive) {
                        confirmRemove = true
                    }
                } footer: {
                    Text(L("Deletes the keys typed or scanned here and stops using the Mac's keys on this iPhone. The Mac keeps its keys.",
                           "Löscht die hier eingetragenen oder gescannten Schlüssel und nutzt die Schlüssel vom Mac auf diesem iPhone nicht mehr. Der Mac behält seine."))
                }
                Section {
                    Link(L("Privacy policy", "Datenschutz"), destination: URL(string: "https://deploycenter.app/datenschutz.html")!)
                    Link(L("Website and help", "Website und Hilfe"), destination: URL(string: "https://deploycenter.app")!)
                    LabeledContent(L("Version", "Version"), value: store.versionText)
                    // The report holds the version, the system and what is connected, never a key or a project name (IDEEN-12 C55).
                    if let u = store.reportURL { Link(L("Report a problem …", "Fehler melden …"), destination: u) }
                } footer: {
                    Text(L("Deploy Center is not affiliated with Vercel, Render or GitHub.",
                           "Deploy Center ist nicht mit Vercel, Render oder GitHub verbunden."))
                }
            }
            .navigationTitle(L("Settings", "Einstellungen"))
            .toolbar {
                ToolbarItem(placement: .confirmationAction) {
                    Button(L("Done", "Fertig")) { if save() { dismiss() } }
                }
                if dirty {
                    ToolbarItem(placement: .cancellationAction) { Button(L("Cancel", "Abbrechen")) { dismiss() } }
                }
            }
            // Swiping the sheet down would drop typed keys without a word.
            .interactiveDismissDisabled(dirty)
            .alert(L("This key looks wrong", "Dieser Schlüssel sieht falsch aus"), isPresented: Binding(get: { badKey != nil }, set: { if !$0 { badKey = nil } })) {
                Button("OK", role: .cancel) {}
            } message: { Text(badKey ?? "") }
            .alert(L("Could not save every key", "Konnte nicht jeden Schlüssel sichern"), isPresented: $saveFailed) {
                Button("OK", role: .cancel) {}
            } message: {
                Text(L("The device's keychain refused it. The keys that were there before are kept.",
                       "Der Schlüsselbund des Geräts hat abgelehnt. Die vorherigen Schlüssel bleiben erhalten."))
            }
            .onAppear(perform: loadFields)
            .task { await checkNotes() }
            .task(id: store.token(.github)) { githubScopes = await GitHub(token: store.token(.github)).scopes() }
            // A QR code scanned from here writes the keychain: read it again, or "Done" would save the old fields over it.
            .sheet(isPresented: $connect, onDismiss: loadFields) { ConnectMacView(store: store) }
            .confirmationDialog(L("Switch to demo data?", "Zu Demodaten wechseln?"), isPresented: $confirmDemo, titleVisibility: .visible) {
                Button(L("Show demo projects", "Demo-Projekte zeigen")) { store.demo = true }
                Button(L("Cancel", "Abbrechen"), role: .cancel) {}
            } message: {
                Text(L("The list shows made-up projects until you switch it off. Your keys stay.",
                       "Die Liste zeigt erfundene Projekte, bis du es ausschaltest. Deine Schlüssel bleiben."))
            }
            .confirmationDialog(L("Remove all keys from this iPhone?", "Alle Schlüssel von diesem iPhone entfernen?"),
                                isPresented: $confirmRemove, titleVisibility: .visible) {
                Button(L("Remove", "Entfernen"), role: .destructive) {
                    // With the lock or Face ID on, whoever holds an unlocked phone must not strip the protection or the keys (IDEEN-12 C38).
                    Task {
                        var allowed = !(lockOnOpen || biometricsOnly)
                        if !allowed { allowed = await store.authenticate(L("Remove all keys from this iPhone", "Alle Schlüssel von diesem iPhone entfernen")) }
                        if allowed { store.removeAllKeys(); loadFields() }
                    }
                }
                Button(L("Cancel", "Abbrechen"), role: .cancel) {}
            }
        }
    }

    /// A switch that protects: turning it ON is free, turning it OFF asks for Face ID, Touch ID or the code first.
    private func guarded(_ b: Binding<Bool>, _ reason: String) -> Binding<Bool> {
        Binding(get: { b.wrappedValue }, set: { on in
            if on { b.wrappedValue = true; return }
            Task { if await store.authenticate(reason) { b.wrappedValue = false } }
        })
    }

    private func loadFields() {
        var f: [Key: String] = [:]
        for k in Key.allCases { f[k] = store.ownToken(k) ?? "" }
        fields = f; saved = f
    }

    private var backgroundProblem: String? {
        if UIApplication.shared.backgroundRefreshStatus != .available || ProcessInfo.processInfo.isLowPowerModeEnabled {
            return L("Background App Refresh is off for Deploy Center or Low Power Mode is on: no checks run in the background.",
                     "Hintergrundaktualisierung ist für Deploy Center aus oder der Stromsparmodus ist an: im Hintergrund wird nichts geprüft.")
        }
        return Background.scheduleError
    }

    private func checkNotes() async {
        notesDenied = await UNUserNotificationCenter.current().notificationSettings().authorizationStatus == .denied
    }

    private func openSettings() {
        if let u = URL(string: UIApplication.openSettingsURLString) { openURL(u) }
    }

    /// A cheap read per key (the typed one, else the Mac's): who it belongs to, or why it fails.
    private func test() async {
        testing = true; defer { testing = false }
        testResults = []
        func pick(_ k: Key) -> String? {
            let typed = (fields[k] ?? "").trimmingCharacters(in: .whitespacesAndNewlines)
            return typed.isEmpty ? store.linkedToken(k) : typed
        }
        let v = pick(.vercel), t = pick(.vercelTeam), r = pick(.render), g = pick(.github)
        if let v {
            testResults.append("Vercel: " + (await result {
                // No team typed: the one team the token sees, as the list does; with several, say so.
                var team = t, note = ""
                if team == nil {
                    let r = try await Vercel.resolveTeam(token: v)
                    team = r.id
                    if r.teams > 1 { note = L(" · personal account (\(r.teams) teams: enter a team id)", " · persönliches Konto (\(r.teams) Teams: Team-ID eintragen)") }
                }
                return try await Vercel(token: v, team: team).whoami() + note
            }))
        }
        if let r { testResults.append("Render: " + (await result { try await Render(key: r).whoami() })) }
        if let g { testResults.append("GitHub: " + (await result { try await GitHub(token: g).whoami() })) }
        if testResults.isEmpty { testResults = [L("No key to test.", "Kein Schlüssel zum Testen.")] }
        AccessibilityNotification.Announcement(testResults.joined(separator: ". ")).post()
    }
    private func result(_ f: () async throws -> String) async -> String {
        do { return try await f() } catch { return explain(error) }
    }

    private func save() -> Bool {
        guard dirty else { return true }
        for k in Key.allCases where (fields[k] ?? "") != (saved[k] ?? "") {
            if k == .vercelTeam { if let why = TokenShape.teamProblem(fields[k] ?? "") { badKey = why; return false }; continue }
            if let why = TokenShape.problem(fields[k] ?? "", render: k == .render) { badKey = why; return false }
        }
        // Only what was changed: a key that could not be read (locked keychain) shows as an empty field,
        // and writing that field back would delete it.
        let ok = Key.allCases.filter { (fields[$0] ?? "") != (saved[$0] ?? "") }
            .map { store.setOwnToken($0, fields[$0] ?? "") }.allSatisfy { $0 }
        Background.schedule()
        Task { await store.reload() }
        if !ok { saveFailed = true; return false }
        // A token pasted into a field must not wait on the clipboard (Universal Clipboard, clipboard managers) (IDEEN-12 C39).
        if let c = UIPasteboard.general.string, !c.isEmpty, Key.allCases.contains(where: { fields[$0] == c }) { UIPasteboard.general.items = [] }
        saved = fields
        return true
    }
}


extension Color {
    /// Orange for small text: the system orange is about 2.3:1 on white; this one reaches 4.5:1 in light mode and is the system orange in dark mode.
    static let warningText = Color(UIColor { $0.userInterfaceStyle == .dark ? .systemOrange : Contrast.warning.ui })
    /// Red, green and blue for small text: the system colors are under 4.5:1 on white (see Contrast).
    static let errorText = Color(UIColor { $0.userInterfaceStyle == .dark ? .systemRed : Contrast.error.ui })
    static let successText = Color(UIColor { $0.userInterfaceStyle == .dark ? .systemGreen : Contrast.success.ui })
    static let activeText = Color(UIColor { $0.userInterfaceStyle == .dark ? .systemBlue : Contrast.active.ui })
}

extension Contrast.RGB { var ui: UIColor { UIColor(red: r, green: g, blue: b, alpha: 1) } }
