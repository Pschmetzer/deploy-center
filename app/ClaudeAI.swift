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

    /// Answers of the last 30 minutes, so switching the language back or opening the sheet again
    /// costs no tokens. Keyed by question (with its language) and project.
    private static let answers = AnswerCache()
    final class AnswerCache: @unchecked Sendable {
        private let lock = NSLock(); private var kept: [String: (at: Date, answer: ClaudeAnswer)] = [:]
        func get(_ k: String) -> ClaudeAnswer? {
            lock.lock(); defer { lock.unlock() }
            guard let e = kept[k], Date().timeIntervalSince(e.at) < 1800 else { return nil }
            return e.answer
        }
        func set(_ k: String, _ a: ClaudeAnswer) { lock.lock(); kept[k] = (Date(), a); lock.unlock() }
    }

    /// Always asks anew: without the build it is about, a kept answer could be about another one.
    static func ask(_ what: Ask, project: String) async throws -> ClaudeAnswer {
        try await askNow(what, project: project)
    }
    /// Kept per question, project and `version` (the commit of the failed build, or the branch
    /// head for release notes): asking again about the same thing costs no tokens.
    static func ask(_ what: Ask, project: String, version: String) async throws -> ClaudeAnswer {
        let key = what.id + "|" + project + "@" + version
        if let a = answers.get(key) { return a }
        let a = try await askNow(what, project: project)
        answers.set(key, a)
        return a
    }

    private static func askNow(_ what: Ask, project: String) async throws -> ClaudeAnswer {
        try await Tool.json(what.args(project: project), as: ClaudeAnswer.self, timeout: 180)
    }

    /// "claude-opus-5-5" → "Claude Opus 5.5", also for models this app does not know yet
    /// ("claude-sonnet-6-0-20270101" → "Claude Sonnet 6.0"). Anything else stays as it came.
    static func modelName(_ id: String) -> String {
        let parts = id.split(separator: "-").map(String.init)
        guard parts.count >= 3, parts[0] == "claude", parts[1].allSatisfy(\.isLetter) else { return id }
        let nums = parts.dropFirst(2).prefix { $0.count <= 2 && $0.allSatisfy(\.isNumber) }
        guard !nums.isEmpty else { return id }
        return "Claude " + parts[1].prefix(1).uppercased() + parts[1].dropFirst() + " " + nums.joined(separator: ".")
    }

    /// A build that ended in an error on the platform, or a deploy started here that failed.
    /// Broader than `Item.lastFailed` (what autofix can fix): runtime failures can be explained too.
    static func isFailed(_ item: Item) -> Bool {
        if case .failed = item.state { return true }
        return item.anyFailure
    }
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
    @ObservedObject var store: Store
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
                .sheet(item: $asking) { a in
                    // "Fix with Claude" as in the row: the same caps, setup offer and toast.
                    ClaudeAnswerSheet(item: item, ask: a,
                                      onAutofix: store.canFixWithClaude(item) ? { Task { await store.fixWithClaude(item) } } : nil)
                }
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
    /// Hands this failed build to Autofix (`Store.fixWithClaude`); nil when Autofix cannot take it.
    let onAutofix: (() -> Void)?
    /// `answer` is given only by tests and screenshots.
    init(item: Item, ask: ClaudeAI.Ask, onAutofix: (() -> Void)? = nil, answer: ClaudeAnswer? = nil) {
        self.item = item; self.onAutofix = onAutofix; _ask = State(initialValue: ask)
        _answer = State(initialValue: answer); preset = answer != nil
    }
    private let preset: Bool

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
            HStack {
                if let answer {
                    CopyButton(title: L("Copy", "Kopieren")) { answer.text }
                    if case .notes = ask {
                        ShareLink(item: answer.text) { Label(L("Share", "Teilen"), systemImage: "square.and.arrow.up") }
                    }
                    if ask == .explain, let onAutofix {
                        Button(L("Fix with Claude", "Mit Claude beheben")) { onAutofix(); dismiss() }
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
        }
    }
}
