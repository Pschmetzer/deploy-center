// Deploy Center — Settings > Daily tasks: `deploys daily` without a terminal.
// Prompt blocks of your own go to a Claude Code routine in the cloud for the repos, times and weekdays you pick.
// The routine opens pull requests; nothing is deployed. All the work is in lib/x-daily.sh; this view reads
// `deploys daily status --json` and writes the whole file through `deploys daily save`, which checks it first.

import SwiftUI

struct DailyBlock: Codable, Identifiable, Hashable {
    var id: String
    var name: String
    var text: String
}

struct DailyFire: Codable, Hashable {
    let status: String
    let date: String?
    let session: String?
    let error: String?
}

struct DailyTask: Codable, Identifiable, Hashable {
    var id: String
    var name: String?
    var repo: String
    var blocks: [String]
    var at: String
    var days: [Int]
    var model: String?
    var on: Bool?
    var routine: String?
    var last: DailyFire?

    /// What goes into daily.json: everything but the last send (that lives in daily-state.json).
    var saved: DailyTask { var t = self; t.last = nil; return t }
}

struct DailyStatus: Decodable {
    let perDay: Int?
    let blocks: [DailyBlock]
    let tasks: [DailyTask]
    let scheduled: Bool
    let routines: [String: String]
    let tokens: [String]
}

private struct DailyFile: Encodable {
    let version = 1
    let perDay: Int?
    let blocks: [DailyBlock]
    let tasks: [DailyTask]
}

struct DailyTasksSettings: View {
    @State private var status: DailyStatus?
    @State private var readError: String?
    @State private var busy = false
    @State private var message: String?
    @State private var failed = false
    @State private var editTask: DailyTask?
    @State private var editBlock: DailyBlock?
    @State private var sendNow: DailyTask?
    @State private var routineId = ""
    @State private var token = ""
    @State private var repos: [String] = []

    static let models = ["sonnet", "haiku", "opus"]

    var body: some View {
        Section {
            Text(L("Your own prompts go to a Claude Code routine in the cloud, for the repos and times you pick. The routine works in the repo and opens a few pull requests. Nothing is deployed, nothing is force-pushed. Each task goes out at most once a day.",
                   "Deine eigenen Prompts gehen an eine Claude-Code-Routine in der Cloud, für die Repos und Zeiten, die du wählst. Die Routine arbeitet im Repo und öffnet wenige Pull Requests. Es wird nichts deployt und nichts force-gepusht. Jede Aufgabe geht höchstens einmal am Tag raus."))
                .font(.caption).foregroundStyle(.secondary)
            if let e = readError {
                Text(L("Could not read the daily tasks: ", "Daily-Aufgaben nicht lesbar: ") + LogTools.maskSecrets(e)).font(.caption).foregroundStyle(.red)
            }
            Toggle(L("Send by themselves at their times", "Zu ihren Zeiten selbst senden"), isOn: Binding(
                get: { status?.scheduled ?? false },
                set: { on in Task {
                    if on, !(await OwnerCheck.confirm(L("let the daily tasks that are switched on go to Claude by themselves", "die eingeschalteten Daily-Aufgaben selbst an Claude senden lassen"))) { return }
                    await run(["daily", "schedule", on ? "on" : "off"]) } }))
                .disabled(busy || status == nil)
            Text(L("Checked every 10 minutes while this Mac is awake. A Mac that sleeps at the time sends it when it wakes, up to 6 hours late.",
                   "Wird alle 10 Minuten geprüft, solange der Mac wach ist. Schläft er zur Zeit, geht sie beim Aufwachen raus, höchstens 6 Stunden später."))
                .font(.caption).foregroundStyle(.secondary)
            if let s = status {
                if s.tasks.isEmpty {
                    Text(L("No daily tasks yet.", "Noch keine Daily-Aufgaben.")).foregroundStyle(.secondary)
                }
                ForEach(s.tasks) { t in row(t, blocks: s.blocks) }
                Button(L("Add task …", "Aufgabe hinzufügen …")) {
                    editTask = DailyTask(id: "", name: nil, repo: "", blocks: s.blocks.first.map { [$0.id] } ?? [], at: "02:00",
                                         days: Array(1...7), model: "sonnet", on: false, routine: nil, last: nil)
                }
                .disabled(busy || s.blocks.isEmpty)
            }
            if let m = message {
                Text(m).font(.caption).foregroundStyle(failed ? .red : .secondary).textSelection(.enabled)
            }
        } header: {
            Text(L("Daily tasks", "Daily-Aufgaben"))
        }
        .task { await reload() }
        .sheet(item: $editTask) { t in
            DailyTaskEditor(task: t, blocks: status?.blocks ?? [], repos: repos) { saved in
                editTask = nil
                if let saved { Task { await saveTask(saved) } }
            }
            .task { if repos.isEmpty { repos = (try? await Tool.json(["daily", "repos", "--json"], as: [String].self, timeout: 60)) ?? [] } }
        }
        .sheet(item: $editBlock) { b in
            DailyBlockEditor(block: b) { saved in
                editBlock = nil
                if let saved { Task { await saveBlock(saved) } }
            }
        }
        .confirmationDialog(L("Send “\(sendNow?.name ?? sendNow?.id ?? "")” to Claude now?", "„\(sendNow?.name ?? sendNow?.id ?? "")“ jetzt an Claude senden?"),
                            isPresented: Binding(get: { sendNow != nil }, set: { if !$0 { sendNow = nil } }), titleVisibility: .visible) {
            Button(L("Send now", "Jetzt senden")) { if let t = sendNow { Task { await run(["daily", "run", t.id, "--yes"], timeout: 90) } }; sendNow = nil }
            Button(L("Cancel", "Abbrechen"), role: .cancel) { sendNow = nil }
        } message: {
            Text(L("A Claude session starts in the cloud and opens pull requests in \(sendNow?.repo ?? "").", "In der Cloud startet eine Claude-Sitzung und öffnet Pull Requests in \(sendNow?.repo ?? "")."))
        }

        Section {
            ForEach(status?.blocks ?? []) { b in
                HStack {
                    VStack(alignment: .leading) {
                        Text(b.name)
                        Text(b.text).font(.caption).foregroundStyle(.secondary).lineLimit(2)
                    }
                    Spacer()
                    Button(L("Edit", "Bearbeiten")) { editBlock = b }.buttonStyle(.link).disabled(busy)
                    Button(L("Delete", "Löschen")) { Task { await deleteBlock(b) } }.buttonStyle(.link)
                        .disabled(busy || (status?.tasks.contains { $0.blocks.contains(b.id) } ?? false))
                        .help(L("A block that a task uses cannot be deleted.", "Ein Baustein, den eine Aufgabe nutzt, lässt sich nicht löschen."))
                }
            }
            Button(L("Add block …", "Baustein hinzufügen …")) { editBlock = DailyBlock(id: "", name: "", text: "") }.disabled(busy || status == nil)
        } header: {
            Text(L("Prompt blocks", "Prompt-Bausteine"))
        } footer: {
            Text(L("Every send also carries the fixed rules: only this repo, check gh pr list and origin/main first, a few PRs, never deploy, never force-push, no secrets.",
                   "Jeder Versand enthält zusätzlich die festen Regeln: nur dieses Repo, vorher gh pr list und origin/main prüfen, wenige PRs, nie deployen, nie force-pushen, keine Secrets."))
        }

        routineSection
    }

    @ViewBuilder private func row(_ t: DailyTask, blocks: [DailyBlock]) -> some View {
        VStack(alignment: .leading, spacing: 4) {
            HStack {
                Toggle(isOn: Binding(get: { t.on ?? false }, set: { on in Task { await run(["daily", on ? "enable" : "disable", t.id]) } })) {
                    Text(Demo.on ? Demo.mask(t.repo) : t.repo).bold()
                }
                .disabled(busy)
                Spacer()
                Button(L("Send now", "Jetzt senden")) { sendNow = t }.disabled(busy)
                Button(L("Edit", "Bearbeiten")) { editTask = t }.buttonStyle(.link).disabled(busy)
                Button(L("Delete", "Löschen")) { Task { await run(["daily", "remove", t.id]) } }.buttonStyle(.link).disabled(busy)
            }
            Text("\(t.at) · \(Self.daysText(t.days)) · \((t.model ?? "sonnet").capitalized) · "
                 + t.blocks.map { id in blocks.first { $0.id == id }?.name ?? id }.joined(separator: ", "))
                .font(.caption).foregroundStyle(.secondary)
            if let l = t.last {
                HStack(spacing: 6) {
                    Text(Self.statusText(l)).font(.caption).foregroundStyle(l.status == "failed" ? .red : .secondary)
                    if let s = l.session, let u = URL(string: s), s.hasPrefix("https://") {
                        Link(L("Open session", "Sitzung öffnen"), destination: u).font(.caption)
                    }
                }
            }
        }
    }

    @ViewBuilder private var routineSection: some View {
        Section {
            let r = status?.routines ?? [:]
            ForEach(Self.models, id: \.self) { m in
                HStack {
                    Text(m.capitalized)
                    Spacer()
                    Text(r[m] ?? (m == "sonnet" ? L("not set", "nicht gesetzt") : L("uses Sonnet's", "nutzt die von Sonnet")))
                        .font(.caption.monospaced()).foregroundStyle(.secondary)
                    if r[m] != nil {
                        Image(systemName: status?.tokens.contains(m) == true ? "checkmark.circle.fill" : "exclamationmark.triangle")
                            .foregroundStyle(status?.tokens.contains(m) == true ? .green : .orange)
                            .help(status?.tokens.contains(m) == true ? L("Token saved", "Token gespeichert") : L("No token for this routine", "Kein Token für diese Routine"))
                    }
                }
            }
            Text(L("1. At claude.ai/code: Routines › New, name it “daily-tasks”, attach every repo a task should work in, pick the model, paste the prompt. 2. Trigger › + › API › Generate token. 3. Enter both here. For Haiku or Opus tasks make one routine per model; without one they go to Sonnet's.",
                   "1. Auf claude.ai/code: Routines › New, Name „daily-tasks“, alle Repos anhängen, in denen Aufgaben arbeiten sollen, Modell wählen, Prompt einfügen. 2. Trigger › + › API › Generate token. 3. Beides hier eintragen. Für Haiku- oder Opus-Aufgaben je Modell eine Routine; ohne eigene gehen sie an die von Sonnet."))
                .font(.caption).foregroundStyle(.secondary)
            Button(L("Copy the routine prompt", "Routine-Prompt kopieren")) {
                Task { if let d = try? await Tool.run(["daily", "prompt"], timeout: 10) { Pasteboard.copy(String(decoding: d, as: UTF8.self)); message = L("Prompt copied.", "Prompt kopiert."); failed = false } }
            }
            HStack {
                TextField(L("Routine id (trig_…)", "Routinen-ID (trig_…)"), text: $routineId).textFieldStyle(.roundedBorder)
                SecureField(L("Token", "Token"), text: $token).textFieldStyle(.roundedBorder)
            }
            HStack {
                ForEach(Self.models, id: \.self) { m in
                    Button(L("Save for \(m.capitalized)", "Für \(m.capitalized) speichern")) { Task { await saveRoutine(m) } }
                        .disabled(busy || routineId.trimmingCharacters(in: .whitespaces).isEmpty)
                }
            }
        } header: {
            Text(L("Routine", "Routine"))
        } footer: {
            Text(L("The token is kept in the keychain (deploy-center-daily) and goes to curl on stdin only.",
                   "Der Token liegt im Schlüsselbund (deploy-center-daily) und geht nur über stdin an curl."))
        }
    }

    /// An id the script takes: a-z, 0-9 and -, starting with a letter or digit, 32 at most.
    static func slug(_ s: String, or fallback: String) -> String {
        let raw = s.lowercased().map { $0.isASCII && ($0.isLetter || $0.isNumber) ? String($0) : "-" }.joined()
        let parts = raw.split(separator: "-").joined(separator: "-")
        let cut = String(parts.prefix(32)).trimmingCharacters(in: CharacterSet(charactersIn: "-"))
        return cut.isEmpty ? fallback : cut
    }

    static func daysText(_ d: [Int]) -> String {
        if Set(d) == Set(1...7) { return L("every day", "täglich") }
        if Set(d) == Set(1...5) { return L("Monday to Friday", "Montag bis Freitag") }
        return d.sorted().map { String(NightlySettings.weekday($0).prefix(2)) }.joined(separator: ", ")
    }

    static func statusText(_ f: DailyFire) -> String {
        let day = f.date.map { " (\($0))" } ?? ""
        switch f.status {
        case "fired": return L("sent, a session works on it", "gesendet, eine Sitzung arbeitet daran") + day
        case "pending": return L("sending", "wird gesendet") + day
        case "ratelimited": return L("waiting (rate limit), tried again", "wartet (Rate-Limit), neuer Versuch") + day
        case "failed": return L("could not send: ", "Senden fehlgeschlagen: ") + LogTools.maskSecrets(f.error ?? "") + day
        default: return f.status + day
        }
    }

    // MARK: - writing

    private func save(blocks: [DailyBlock], tasks: [DailyTask]) async {
        let file = DailyFile(perDay: status?.perDay, blocks: blocks, tasks: tasks.map(\.saved))
        guard let data = try? JSONEncoder().encode(file), let text = String(data: data, encoding: .utf8) else { return }
        await run(["daily", "save"], stdin: text)
    }

    private func saveTask(_ t: DailyTask) async {
        guard let s = status else { return }
        var t = t, tasks = s.tasks
        if t.id.isEmpty {
            let base = Self.slug(String(t.repo.split(separator: "/").last ?? ""), or: "task")
            var id = base, k = 2
            while tasks.contains(where: { $0.id == id }) { id = "\(base)-\(k)"; k += 1 }
            t.id = id
            tasks.append(t)
        } else if let i = tasks.firstIndex(where: { $0.id == t.id }) { tasks[i] = t }
        await save(blocks: s.blocks, tasks: tasks)
    }

    private func saveBlock(_ b: DailyBlock) async {
        guard let s = status else { return }
        var b = b, blocks = s.blocks
        if b.id.isEmpty {
            let base = Self.slug(b.name, or: "block")
            var id = base, k = 2
            while blocks.contains(where: { $0.id == id }) { id = "\(base)-\(k)"; k += 1 }
            b.id = id
            blocks.append(b)
        } else if let i = blocks.firstIndex(where: { $0.id == b.id }) { blocks[i] = b }
        await save(blocks: blocks, tasks: s.tasks)
    }

    private func deleteBlock(_ b: DailyBlock) async {
        guard let s = status else { return }
        await save(blocks: s.blocks.filter { $0.id != b.id }, tasks: s.tasks)
    }

    private func saveRoutine(_ model: String) async {
        let id = routineId.trimmingCharacters(in: .whitespaces)
        await run(["daily", "routine", id, "--model", model])
        if !failed, !token.isEmpty {
            busy = true; defer { busy = false }
            do {
                _ = try await Tool.run(["daily", "set-token", "--routine", id], stdin: token.trimmingCharacters(in: .whitespacesAndNewlines), timeout: 20)
                token = ""; message = L("Routine and token saved.", "Routine und Token gespeichert."); failed = false
            } catch { message = LogTools.maskSecrets(error.localizedDescription); failed = true }
            await reload()
        }
        if !failed { routineId = "" }
    }

    private func run(_ args: [String], stdin: String? = nil, timeout: Double = 60) async {
        busy = true; defer { busy = false }
        do {
            let out = String(data: try await Tool.run(args, stdin: stdin, timeout: timeout), encoding: .utf8)?
                .trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
            let safe = LogTools.maskSecrets(out)
            message = safe.isEmpty ? nil : safe; failed = false
        } catch { message = LogTools.maskSecrets(error.localizedDescription); failed = true }
        await reload()
    }

    private func reload() async {
        do {
            status = try await Tool.json(["daily", "status", "--json"], as: DailyStatus.self, timeout: 20)
            readError = nil
        } catch { readError = error.localizedDescription }
    }
}

/// One task: the repo, its blocks, the time, the weekdays, the model.
struct DailyTaskEditor: View {
    @State var task: DailyTask
    let blocks: [DailyBlock]
    let repos: [String]
    let done: (DailyTask?) -> Void

    private var hour: Binding<Int> { Binding(get: { Int(task.at.prefix(2)) ?? 2 }, set: { task.at = String(format: "%02d:%02d", $0, minute.wrappedValue) }) }
    private var minute: Binding<Int> { Binding(get: { Int(task.at.suffix(2)) ?? 0 }, set: { task.at = String(format: "%02d:%02d", hour.wrappedValue, $0) }) }
    private var valid: Bool {
        task.repo.range(of: "^[A-Za-z0-9_.-]+/[A-Za-z0-9_.-]+$", options: .regularExpression) != nil && !task.blocks.isEmpty && !task.days.isEmpty
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            Text(task.id.isEmpty ? L("New daily task", "Neue Daily-Aufgabe") : L("Daily task", "Daily-Aufgabe")).font(.headline)
            Form {
                HStack {
                    TextField(L("Repo (owner/name)", "Repo (owner/name)"), text: $task.repo).textFieldStyle(.roundedBorder)
                    if !repos.isEmpty {
                        Menu(L("Pick", "Wählen")) { ForEach(repos, id: \.self) { r in Button(r) { task.repo = r } } }.fixedSize()
                    }
                }
                TextField(L("Name (optional)", "Name (optional)"), text: Binding(get: { task.name ?? "" }, set: { task.name = $0.isEmpty ? nil : $0 }))
                    .textFieldStyle(.roundedBorder)
                VStack(alignment: .leading) {
                    Text(L("Blocks", "Bausteine")).font(.caption).foregroundStyle(.secondary)
                    ForEach(blocks) { b in
                        Toggle(b.name, isOn: Binding(get: { task.blocks.contains(b.id) },
                                                     set: { on in task.blocks.removeAll { $0 == b.id }; if on { task.blocks.append(b.id) } }))
                    }
                }
                HStack {
                    Picker(L("At", "Um"), selection: hour) { ForEach(0..<24, id: \.self) { Text(String(format: "%02d", $0)).tag($0) } }.fixedSize()
                    Picker(":", selection: minute) { ForEach(Array(stride(from: 0, to: 60, by: 5)), id: \.self) { Text(String(format: "%02d", $0)).tag($0) } }.fixedSize()
                    Text(L("local time", "Ortszeit")).font(.caption).foregroundStyle(.secondary)
                }
                HStack {
                    ForEach(1...7, id: \.self) { d in
                        Toggle(String(NightlySettings.weekday(d).prefix(2)), isOn: Binding(
                            get: { task.days.contains(d) },
                            set: { on in task.days.removeAll { $0 == d }; if on { task.days.append(d); task.days.sort() } }))
                            .toggleStyle(.button)
                    }
                }
                Picker(L("Model", "Modell"), selection: Binding(get: { task.model ?? "sonnet" }, set: { task.model = $0 })) {
                    Text("Sonnet").tag("sonnet"); Text("Haiku").tag("haiku"); Text("Opus").tag("opus")
                }
                Toggle(L("On", "An"), isOn: Binding(get: { task.on ?? false }, set: { task.on = $0 }))
            }
            .formStyle(.grouped)
            HStack {
                Spacer()
                Button(L("Cancel", "Abbrechen"), role: .cancel) { done(nil) }.keyboardShortcut(.cancelAction)
                Button(L("Save", "Sichern")) { done(task) }.keyboardShortcut(.defaultAction).disabled(!valid)
            }
        }
        .padding()
        .frame(width: 520)
    }
}

/// One prompt block: a name and its text.
struct DailyBlockEditor: View {
    @State var block: DailyBlock
    let done: (DailyBlock?) -> Void

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            Text(block.id.isEmpty ? L("New prompt block", "Neuer Prompt-Baustein") : L("Prompt block", "Prompt-Baustein")).font(.headline)
            TextField(L("Name", "Name"), text: $block.name).textFieldStyle(.roundedBorder)
            TextEditor(text: $block.text).font(.body).frame(minHeight: 220)
                .overlay(RoundedRectangle(cornerRadius: 6).stroke(.quaternary))
            HStack {
                Spacer()
                Button(L("Cancel", "Abbrechen"), role: .cancel) { done(nil) }.keyboardShortcut(.cancelAction)
                Button(L("Save", "Sichern")) { done(block) }.keyboardShortcut(.defaultAction)
                    .disabled(block.name.trimmingCharacters(in: .whitespaces).isEmpty || block.text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
            }
        }
        .padding()
        .frame(width: 560)
    }
}
