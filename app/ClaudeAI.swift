// Deploy Center — Claude in the app: explain a failed build, plain release notes, "is this safe to ship?".
// Opt-in and off by default. Every request goes through `deploys ai …`, so the app and the CLI share
// one key (the keychain item `deploy-center-anthropic`, written by the script), one masker (the
// one autofix uses) and one monthly cap. No server of ours, no telemetry: the user's own key,
// straight to the Anthropic API, and only masked text.

import SwiftUI
import AppKit

struct ClaudeAIStatus: Decodable {
    let key: Bool
    let source: String
    let model: String
    let models: [String]
    let cap: Int
    let used: Int
    let month: String
}

struct ClaudeAnswer: Decodable {
    let text: String
    let model: String
    let tokens: Int
    let used: Int
    let cap: Int
}

enum ClaudeAI {
    static let enabledKey = "claudeInApp"
    static var enabled: Bool { UserDefaults.standard.bool(forKey: enabledKey) }

    static func status() async -> ClaudeAIStatus? {
        try? await Tool.json(["ai", "status"], as: ClaudeAIStatus.self, timeout: 15)
    }

    enum Ask: Identifiable, Equatable {
        case explain, notes(String), ship
        var id: String { switch self { case .explain: return "explain"; case .notes(let l): return "notes-\(l)"; case .ship: return "ship" } }
        var title: String {
            switch self {
            case .explain: return L("Explain this failure", "Diesen Fehler erklären")
            case .notes: return L("Release notes for humans", "Release-Notes für Menschen")
            case .ship: return L("Is this safe to ship?", "Kann das live gehen?")
            }
        }
        /// The script call, without the project: `deploys ai <what> <project> --json …`.
        func args(project: String) -> [String] {
            switch self {
            case .explain: return ["ai", "explain", project, "--json"]
            case .notes(let lang): return ["ai", "notes", project, "--json", "--lang", lang]
            case .ship: return ["ai", "ship", project, "--json"]
            }
        }
    }

    static func ask(_ what: Ask, project: String) async throws -> ClaudeAnswer {
        try await Tool.json(what.args(project: project), as: ClaudeAnswer.self, timeout: 180)
    }

    static func modelName(_ id: String) -> String {
        switch id {
        case "claude-opus-5-5": return "Claude Opus 5.5"
        case "claude-sonnet-5-5": return "Claude Sonnet 5.5"
        case "claude-haiku-5-5": return "Claude Haiku 5.5"
        default: return id
        }
    }

    /// A build that ended in an error on the platform, or a deploy started here that failed.
    static func isFailed(_ item: Item) -> Bool {
        if case .failed = item.state { return true }
        return ["ERROR", "build_failed", "update_failed", "pre_deploy_failed"].contains(item.lastState ?? "")
    }

    /// Only a build that failed can be fixed from its log: Autofix takes Vercel ERROR and Render build_failed.
    static func autofixCanTake(_ item: Item) -> Bool { ["ERROR", "build_failed"].contains(item.lastState ?? "") }
}

// MARK: - Settings > Claude in the app

struct ClaudeAISettings: View {
    @AppStorage(ClaudeAI.enabledKey) private var enabled = false
    @State private var status: ClaudeAIStatus?
    init(status: ClaudeAIStatus? = nil) { _status = State(initialValue: status) }
    @State private var key = ""
    @State private var cap = ""
    @State private var busy = false
    @State private var message: String?
    @State private var failed = false

    var body: some View {
        Section {
            Toggle(L("Ask Claude with my own API key", "Claude mit meinem eigenen API-Schlüssel fragen"), isOn: $enabled)
            Text(L("Explain a failed build, write plain release notes and check what is about to ship, with your own Anthropic API key. Only masked text is sent (log excerpts, commit titles, file names), straight to Anthropic. Off by default.",
                   "Fehlgeschlagene Builds erklären, verständliche Release-Notes schreiben und prüfen, was live gehen soll, mit deinem eigenen Anthropic-API-Schlüssel. Gesendet wird nur maskierter Text (Log-Auszüge, Commit-Titel, Dateinamen), direkt an Anthropic. Standardmäßig aus."))
                .font(.caption).foregroundStyle(.secondary)
            if enabled {
                HStack {
                    SecureField(L("API key", "API-Schlüssel"), text: $key, prompt: Text("sk-ant-…"))
                    Button(L("Save", "Speichern")) { Task { await saveKey() } }
                        .disabled(!key.hasPrefix("sk-ant-") || busy)
                    Image(systemName: status?.key == true ? "checkmark.circle.fill" : "circle")
                        .foregroundStyle(status?.key == true ? .green : .secondary)
                        .accessibilityLabel(status?.key == true ? L("Key saved", "Schlüssel gespeichert") : L("No key", "Kein Schlüssel"))
                }
                if status?.source == "env" {
                    Text(L("ANTHROPIC_API_KEY is set in the environment and is used instead.", "ANTHROPIC_API_KEY ist in der Umgebung gesetzt und wird stattdessen benutzt."))
                        .font(.caption).foregroundStyle(.secondary)
                }
                HStack {
                    Button(L("Verify", "Prüfen")) { Task { await run(["ai", "verify"], show: true) } }
                        .disabled(status?.key != true || busy)
                        .help(L("Looks up the chosen model with the key; costs nothing", "Fragt mit dem Schlüssel das gewählte Modell ab; kostet nichts"))
                    Button(L("Get a key", "Schlüssel holen")) { NSWorkspace.shared.open(URL(string: "https://console.anthropic.com/settings/keys")!) }
                    Spacer()
                    if busy { ProgressView().controlSize(.small) }
                    if status?.source == "keychain" {
                        Button(L("Forget key", "Schlüssel löschen"), role: .destructive) { Task { await run(["ai", "forget-key"]) } }
                    }
                }
                if let s = status {
                    Picker(L("Model", "Modell"), selection: Binding(get: { s.model }, set: { m in Task { await run(["ai", "model", m]) } })) {
                        ForEach(s.models, id: \.self) { Text(ClaudeAI.modelName($0)).tag($0) }
                    }
                    HStack {
                        TextField(L("Monthly cap (tokens)", "Monatslimit (Tokens)"), text: $cap, prompt: Text("\(s.cap)"))
                            .onSubmit { Task { await saveCap() } }
                        Button(L("Set", "Setzen")) { Task { await saveCap() } }.disabled(Int(cap) == nil || busy)
                    }
                    VStack(alignment: .leading, spacing: 4) {
                        ProgressView(value: Double(min(s.used, s.cap)), total: Double(max(s.cap, 1)))
                            .tint(s.used >= s.cap ? .red : .accentColor)
                        Text(L("\(s.used.formatted()) of \(s.cap.formatted()) tokens this month (counted on this Mac)",
                               "\(s.used.formatted()) von \(s.cap.formatted()) Tokens diesen Monat (auf diesem Mac gezählt)"))
                            .font(.caption).foregroundStyle(.secondary)
                    }
                }
                if let message {
                    Text(message).font(.caption).textSelection(.enabled).foregroundStyle(failed ? .red : .secondary)
                }
            }
        } header: {
            Text(L("Claude in the app", "Claude in der App"))
        }
        .task(id: enabled) { if enabled { await reload() } }
    }

    private func reload() async { status = await ClaudeAI.status() }

    private func saveKey() async {
        busy = true; defer { busy = false }
        do {
            _ = try await Tool.run(["ai", "set-key"], stdin: key.trimmingCharacters(in: .whitespacesAndNewlines), timeout: 20)
            key = ""; message = L("Key saved in the keychain.", "Schlüssel im Schlüsselbund gespeichert."); failed = false
        } catch { message = error.localizedDescription; failed = true }
        await reload()
    }

    private func saveCap() async {
        guard let n = Int(cap.trimmingCharacters(in: .whitespaces)), n > 0 else { return }
        await run(["ai", "cap", "\(n)"]); cap = ""
    }

    private func run(_ args: [String], show: Bool = false) async {
        busy = true; defer { busy = false }
        do {
            let out = String(data: try await Tool.run(args, timeout: 30), encoding: .utf8)?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
            message = show ? out : nil; failed = false
        } catch { message = error.localizedDescription; failed = true }
        await reload()
    }
}

// MARK: - "Ask Claude" in the detail sheet and the build log

/// One menu, shown only when Claude in the app is on and a key is there. The answer opens in a sheet.
struct ClaudeMenu: View {
    let item: Item
    /// Release notes and the ship check need waiting commits (the detail sheet); the build log offers only the failure.
    var waiting = true
    @AppStorage(ClaudeAI.enabledKey) private var enabled = false
    @State private var hasKey = false
    @State private var asking: ClaudeAI.Ask?

    var body: some View {
        Group {
            if enabled && hasKey && (waiting || ClaudeAI.isFailed(item)) {
                Menu {
                    if ClaudeAI.isFailed(item) {
                        Button(ClaudeAI.Ask.explain.title) { asking = .explain }
                    }
                    if waiting {
                        Button(ClaudeAI.Ask.notes(isGerman ? "de" : "en").title) { asking = .notes(isGerman ? "de" : "en") }
                        Button(ClaudeAI.Ask.ship.title) { asking = .ship }
                    }
                } label: {
                    Label(L("Ask Claude", "Claude fragen"), systemImage: "sparkles")
                }
                .fixedSize()
                .help(L("Sends masked text to Anthropic with your own key", "Sendet maskierten Text mit deinem eigenen Schlüssel an Anthropic"))
                .sheet(item: $asking) { a in ClaudeAnswerSheet(item: item, ask: a) }
            }
        }
        .task(id: enabled) { if enabled { hasKey = await ClaudeAI.status()?.key ?? false } }
    }
}

struct ClaudeAnswerSheet: View {
    let item: Item
    @State var ask: ClaudeAI.Ask
    @Environment(\.dismiss) private var dismiss
    @State private var answer: ClaudeAnswer?
    @State private var error: String?
    @State private var autofixReady = false
    /// `answer` and `autofixReady` are given only by tests and screenshots.
    init(item: Item, ask: ClaudeAI.Ask, answer: ClaudeAnswer? = nil, autofixReady: Bool = false) {
        self.item = item; _ask = State(initialValue: ask)
        _answer = State(initialValue: answer); _autofixReady = State(initialValue: autofixReady); preset = answer != nil
    }
    private let preset: Bool
    @State private var handed: String?

    private var lang: String { if case .notes(let l) = ask { return l }; return "en" }

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            HStack {
                Image(systemName: "sparkles").foregroundStyle(.orange)
                Text(ask.title + " · " + Demo.mask(item.name)).font(.headline)
                Spacer()
                if case .notes = ask {
                    Picker("", selection: Binding(get: { lang }, set: { ask = .notes($0) })) {
                        Text("EN").tag("en"); Text("DE").tag("de")
                    }
                    .pickerStyle(.segmented).fixedSize().labelsHidden()
                    .accessibilityLabel(L("Language", "Sprache"))
                }
            }
            Group {
                if let answer {
                    ScrollView {
                        Text(answer.text).textSelection(.enabled).frame(maxWidth: .infinity, alignment: .leading)
                    }
                } else if let error {
                    Text(error).foregroundStyle(.red).textSelection(.enabled)
                } else {
                    ProgressView(L("Asking Claude …", "Frage Claude …")).frame(maxWidth: .infinity, maxHeight: .infinity)
                }
            }
            .frame(minHeight: 120, maxHeight: .infinity, alignment: .topLeading)
            if let answer {
                Text(L("\(ClaudeAI.modelName(answer.model)) · \(answer.tokens.formatted()) tokens · \(answer.used.formatted()) of \(answer.cap.formatted()) this month",
                       "\(ClaudeAI.modelName(answer.model)) · \(answer.tokens.formatted()) Tokens · \(answer.used.formatted()) von \(answer.cap.formatted()) diesen Monat"))
                    .font(.caption).foregroundStyle(.secondary)
            }
            if let handed { Text(handed).font(.caption).foregroundStyle(.secondary).textSelection(.enabled) }
            HStack {
                if let answer {
                    CopyButton(title: L("Copy", "Kopieren")) { answer.text }
                    if case .notes = ask {
                        ShareLink(item: answer.text) { Label(L("Share", "Teilen"), systemImage: "square.and.arrow.up") }
                    }
                    if ask == .explain && autofixReady && ClaudeAI.autofixCanTake(item) {
                        Button(L("Hand to Autofix", "An Autofix übergeben")) { Task { await handToAutofix() } }
                            .help(L("A Claude Code session fixes this build and opens a pull request", "Eine Claude-Code-Sitzung behebt diesen Build und öffnet einen Pull Request"))
                    }
                }
                Spacer()
                Button(L("Close", "Schließen")) { dismiss() }.keyboardShortcut(.cancelAction)
            }
        }
        .padding(16)
        .frame(minWidth: 460, idealWidth: 540, minHeight: 260, idealHeight: 340)
        .task(id: ask.id) {
            if preset { return }
            answer = nil; error = nil
            do { answer = try await ClaudeAI.ask(ask, project: item.id) } catch { self.error = error.localizedDescription }
            if ask == .explain, let st = try? await Tool.json(["autofix", "status"], as: AutofixStatus.self, timeout: 20) {
                autofixReady = st.routine != nil && st.token
            }
        }
    }

    private func handToAutofix() async {
        do {
            let out = try await Tool.run(["autofix", "--only", item.platform.cli, item.name], timeout: 300)
            handed = String(data: out, encoding: .utf8)?.trimmingCharacters(in: .whitespacesAndNewlines)
        } catch { handed = error.localizedDescription }
    }
}
