// Deploy Center — Settings > Tasks: `deploys tasks` without a terminal.
// Prompt blocks of your own go to a Claude Code routine in the cloud for the repos you pick, once, hourly, daily or
// weekly, to the routine of the Claude account signed in now. The routine opens pull requests; nothing is deployed.
// All the work is in lib/x-tasks.sh; this view reads `deploys tasks status --json` and writes the whole file through
// `deploys tasks save`, which checks it first. (Not named `Task`: that is Swift's own `Task { … }`.)

import SwiftUI

struct TaskBlock: Codable, Identifiable, Hashable {
    var id: String
    var name: String
    var text: String
}

struct TaskSchedule: Codable, Hashable {
    var kind: String            // once | hourly | daily | weekly
    var at: String?
    var date: String?
    var minute: Int?
    var days: [Int]?
}

struct TaskFire: Codable, Hashable {
    let status: String
    let slot: String?
    let session: String?
    let error: String?
}

struct ScheduledTask: Codable, Identifiable, Hashable {
    var id: String
    var name: String?
    var repo: String
    var blocks: [String]
    var schedule: TaskSchedule
    var model: String?
    var on: Bool?
    var account: String?
    var last: TaskFire?

    /// What goes into tasks.json: everything but the last send (that lives in tasks-state.json).
    var saved: ScheduledTask { var t = self; t.last = nil; return t }
}

struct TaskAccount: Decodable, Identifiable, Hashable {
    let id: String
    let label: String?
    let routines: [String: String]
    let tokens: [String]
    var title: String { label ?? String(id.prefix(8)) }
}

struct TasksStatus: Decodable {
    let perDay: Int?
    let perTask: Int?
    let blocks: [TaskBlock]
    let tasks: [ScheduledTask]
    let scheduled: Bool
    let active: String?
    let accounts: [TaskAccount]
    let needsSetup: [String]
}

private struct TasksFile: Encodable {
    let version = 1
    let perDay: Int?
    let perTask: Int?
    let blocks: [TaskBlock]
    let tasks: [ScheduledTask]
}

struct TasksSettings: View {
    @State private var status: TasksStatus?
    @State private var readError: String?
    @State private var busy = false
    @State private var message: String?
    @State private var failed = false
    @State private var editTask: ScheduledTask?
    @State private var editBlock: TaskBlock?
    @State private var sendNow: ScheduledTask?
    @State private var setupAccount = ""
    @State private var setupLabel = ""
    @State private var setupModel = "sonnet"
    @State private var routineId = ""
    @State private var token = ""
    @State private var repos: [String] = []

    static let models = ["sonnet", "haiku", "opus"]

    /// Accounts that a task wanted, or the one signed in, that have no routine yet ("none": nobody signed in).
    private var missing: [String] {
        let have = Set(status?.accounts.filter { !$0.routines.isEmpty }.map(\.id) ?? [])
        var out = (status?.needsSetup ?? []).filter { !have.contains($0) }
        if let a = status?.active, !have.contains(a), !out.contains(a) { out.insert(a, at: 0) }
        return out
    }

    var body: some View {
        Section {
            Text(L("Your own prompts go to a Claude Code routine in the cloud, for the repos you pick, once, every hour, every day or every week. The routine works in the repo and opens a few pull requests. Nothing is deployed, nothing is force-pushed.",
                   "Deine eigenen Prompts gehen an eine Claude-Code-Routine in der Cloud, für die Repos, die du wählst: einmal, stündlich, täglich oder wöchentlich. Die Routine arbeitet im Repo und öffnet wenige Pull Requests. Es wird nichts deployt und nichts force-gepusht."))
                .font(.caption).foregroundStyle(.secondary)
            if let e = readError {
                Text(L("Could not read the tasks: ", "Aufgaben nicht lesbar: ") + LogTools.maskSecrets(e)).font(.caption).foregroundStyle(.red)
            }
            ForEach(missing, id: \.self) { a in
                Label(a == "none" ? L("No Claude account is signed in on this Mac, so tasks are not sent.", "Auf diesem Mac ist kein Claude-Konto angemeldet, daher gehen keine Aufgaben raus.")
                                  : L("Set up tasks for the Claude account \(a.prefix(8)): nothing is sent to it until it has a routine.",
                                      "Aufgaben für das Claude-Konto \(a.prefix(8)) einrichten: Bis es eine Routine hat, geht nichts raus."),
                      systemImage: "exclamationmark.triangle")
                    .font(.caption).foregroundStyle(.orange)
                if a != "none" {
                    Button(L("Set up this account …", "Dieses Konto einrichten …")) { setupAccount = a }.disabled(busy)
                }
            }
            Toggle(L("Send by themselves at their times", "Zu ihren Zeiten selbst senden"), isOn: Binding(
                get: { status?.scheduled ?? false },
                set: { on in Task {
                    if on, !(await OwnerCheck.confirm(L("let the tasks that are switched on go to Claude by themselves", "die eingeschalteten Aufgaben selbst an Claude senden lassen"))) { return }
                    await run(["tasks", "schedule", on ? "on" : "off"]) } }))
                .disabled(busy || status == nil)
            Text(L("Checked every 10 minutes while this Mac is awake; each time a task is meant to run goes out once. A Mac that sleeps at the time sends it when it wakes, on the same day (hourly tasks up to 50 minutes late, the others up to 6 hours).",
                   "Wird alle 10 Minuten geprüft, solange der Mac wach ist; jeder vorgesehene Termin geht einmal raus. Schläft der Mac, geht er beim Aufwachen am selben Tag raus (stündliche Aufgaben bis 50 Minuten später, die anderen bis 6 Stunden)."))
                .font(.caption).foregroundStyle(.secondary)
            if let s = status {
                if s.tasks.isEmpty {
                    Text(L("No tasks yet.", "Noch keine Aufgaben.")).foregroundStyle(.secondary)
                }
                ForEach(s.tasks) { t in row(t, blocks: s.blocks, accounts: s.accounts) }
                Button(L("Add task …", "Aufgabe hinzufügen …")) {
                    editTask = ScheduledTask(id: "", name: nil, repo: "", blocks: s.blocks.first.map { [$0.id] } ?? [],
                                             schedule: TaskSchedule(kind: "daily", at: "02:00", date: nil, minute: nil, days: Array(1...7)),
                                             model: "sonnet", on: false, account: nil, last: nil)
                }
                .disabled(busy || s.blocks.isEmpty)
            }
            if let m = message {
                Text(m).font(.caption).foregroundStyle(failed ? .red : .secondary).textSelection(.enabled)
            }
        } header: {
            Text(L("Tasks", "Aufgaben"))
        }
        .task { await reload() }
        .sheet(item: $editTask) { t in
            TaskEditor(task: t, blocks: status?.blocks ?? [], repos: repos, accounts: status?.accounts ?? []) { saved in
                editTask = nil
                if let saved { Task { await saveTask(saved) } }
            }
            .task { if repos.isEmpty { repos = (try? await Tool.json(["tasks", "repos", "--json"], as: [String].self, timeout: 60)) ?? [] } }
        }
        .sheet(item: $editBlock) { b in
            TaskBlockEditor(block: b) { saved in
                editBlock = nil
                if let saved { Task { await saveBlock(saved) } }
            }
        }
        .confirmationDialog(L("Send “\(sendNow?.name ?? sendNow?.id ?? "")” to Claude now?", "„\(sendNow?.name ?? sendNow?.id ?? "")“ jetzt an Claude senden?"),
                            isPresented: Binding(get: { sendNow != nil }, set: { if !$0 { sendNow = nil } }), titleVisibility: .visible) {
            Button(L("Send now", "Jetzt senden")) { if let t = sendNow { Task { await run(["tasks", "run", t.id, "--yes"], timeout: 90) } }; sendNow = nil }
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
            Button(L("Add block …", "Baustein hinzufügen …")) { editBlock = TaskBlock(id: "", name: "", text: "") }.disabled(busy || status == nil)
        } header: {
            Text(L("Prompt blocks", "Prompt-Bausteine"))
        } footer: {
            Text(L("Every send also carries the fixed rules: only this repo, check gh pr list and origin/main first, a few PRs, never deploy, never force-push, no secrets.",
                   "Jeder Versand enthält zusätzlich die festen Regeln: nur dieses Repo, vorher gh pr list und origin/main prüfen, wenige PRs, nie deployen, nie force-pushen, keine Secrets."))
        }

        accountsSection.id("accounts")
    }

    @ViewBuilder private func row(_ t: ScheduledTask, blocks: [TaskBlock], accounts: [TaskAccount]) -> some View {
        VStack(alignment: .leading, spacing: 4) {
            HStack {
                Toggle(isOn: Binding(get: { t.on ?? false }, set: { on in Task { await run(["tasks", on ? "enable" : "disable", t.id]) } })) {
                    Text(Demo.on ? Demo.mask(t.repo) : t.repo).bold()
                }
                .disabled(busy)
                Spacer()
                Button(L("Send now", "Jetzt senden")) { sendNow = t }.disabled(busy)
                Button(L("Edit", "Bearbeiten")) { editTask = t }.buttonStyle(.link).disabled(busy)
                Button(L("Delete", "Löschen")) { Task { await run(["tasks", "remove", t.id]) } }.buttonStyle(.link).disabled(busy)
            }
            Text([Self.scheduleText(t.schedule), (t.model ?? "sonnet").capitalized,
                  t.account.map { a in accounts.first { $0.id == a }?.title ?? String(a.prefix(8)) } ?? L("account signed in", "angemeldetes Konto"),
                  t.blocks.map { id in blocks.first { $0.id == id }?.name ?? id }.joined(separator: ", ")].joined(separator: " · "))
                .font(.caption).foregroundStyle(.secondary)
            if let l = t.last {
                HStack(spacing: 6) {
                    Text(Self.statusText(l)).font(.caption).foregroundStyle(l.status == "failed" || l.status == "needs-setup" ? .orange : .secondary)
                    if let s = l.session, let u = URL(string: s), s.hasPrefix("https://") {
                        Link(L("Open session", "Sitzung öffnen"), destination: u).font(.caption)
                    }
                }
            }
        }
    }

    @ViewBuilder private var accountsSection: some View {
        Section {
            ForEach(status?.accounts ?? []) { a in
                VStack(alignment: .leading, spacing: 2) {
                    HStack {
                        Text(a.title).bold()
                        if a.id == status?.active { Text(L("signed in", "angemeldet")).font(.caption).foregroundStyle(.green) }
                        Spacer()
                        Button(L("Change …", "Ändern …")) { setupAccount = a.id; setupLabel = a.label ?? "" }.buttonStyle(.link).disabled(busy)
                    }
                    ForEach(Self.models, id: \.self) { m in
                        if let r = a.routines[m] {
                            Label("\(m.capitalized): \(r)", systemImage: a.tokens.contains(m) ? "checkmark.circle.fill" : "exclamationmark.triangle")
                                .font(.caption.monospaced()).foregroundStyle(a.tokens.contains(m) ? Color.secondary : Color.orange)
                                .help(a.tokens.contains(m) ? L("Token saved", "Token gespeichert") : L("No token for this routine", "Kein Token für diese Routine"))
                        }
                    }
                }
            }
            Text(L("Once per Claude account: at claude.ai/code, Routines › New, attach every repo a task should work in, pick Sonnet (recommended), paste the prompt. Then Trigger › + › API › Generate token, and enter the routine id and the token here. Haiku or Opus tasks go to that account's Sonnet routine unless it has one of their own.",
                   "Einmal je Claude-Konto: auf claude.ai/code Routines › New, alle Repos anhängen, in denen Aufgaben arbeiten sollen, Sonnet wählen (empfohlen), Prompt einfügen. Dann Trigger › + › API › Generate token und Routinen-ID und Token hier eintragen. Haiku- oder Opus-Aufgaben gehen an die Sonnet-Routine des Kontos, außer es hat eine eigene."))
                .font(.caption).foregroundStyle(.secondary)
            Button(L("Copy the routine prompt", "Routine-Prompt kopieren")) {
                Task { if let d = try? await Tool.run(["tasks", "prompt"], timeout: 10) { Pasteboard.copy(String(decoding: d, as: UTF8.self)); message = L("Prompt copied.", "Prompt kopiert."); failed = false } }
            }
            Picker(L("Account", "Konto"), selection: $setupAccount) {
                Text(L("Signed in now", "Gerade angemeldet")).tag("")
                ForEach(Array(Set((status?.accounts.map(\.id) ?? []) + missing.filter { $0 != "none" })).sorted(), id: \.self) { a in
                    Text(status?.accounts.first { $0.id == a }?.title ?? String(a.prefix(8))).tag(a)
                }
            }
            TextField(L("Name for this account (optional, e.g. Work)", "Name für das Konto (optional, z. B. Arbeit)"), text: $setupLabel).textFieldStyle(.roundedBorder)
            Picker(L("Model of the routine", "Modell der Routine"), selection: $setupModel) {
                Text(L("Sonnet (recommended)", "Sonnet (empfohlen)")).tag("sonnet"); Text("Haiku").tag("haiku"); Text("Opus").tag("opus")
            }
            TextField(L("Routine id (trig_…)", "Routinen-ID (trig_…)"), text: $routineId).textFieldStyle(.roundedBorder)
            SecureField(L("Token of this routine", "Token dieser Routine"), text: $token).textFieldStyle(.roundedBorder)
            Button(L("Save routine", "Routine speichern")) { Task { await saveRoutine() } }
                .disabled(busy || routineId.trimmingCharacters(in: .whitespaces).isEmpty)
        } header: {
            Text(L("Claude accounts and routines", "Claude-Konten und Routinen"))
        } footer: {
            Text(L("Each routine's token is kept in the keychain (deploy-center-tasks) and goes to curl on stdin only. Only the id of the signed-in account is read, never its email.",
                   "Der Token jeder Routine liegt im Schlüsselbund (deploy-center-tasks) und geht nur über stdin an curl. Gelesen wird nur die ID des angemeldeten Kontos, nie seine E-Mail."))
        }
    }

    static func daysText(_ d: [Int]) -> String {
        if Set(d) == Set(1...7) { return L("every day", "täglich") }
        if Set(d) == Set(1...5) { return L("Monday to Friday", "Montag bis Freitag") }
        return d.sorted().map { String(NightlySettings.weekday($0).prefix(2)) }.joined(separator: ", ")
    }

    static func scheduleText(_ s: TaskSchedule) -> String {
        let at = s.at ?? "?", mm = String(format: "%02d", s.minute ?? 0), days = daysText(s.days ?? [])
        switch s.kind {
        case "once": return L("once on \(s.date ?? "?") at \(at)", "einmal am \(s.date ?? "?") um \(at)")
        case "hourly": return L("hourly at :\(mm), \(days)", "stündlich um :\(mm), \(days)")
        case "weekly":
            let day = NightlySettings.weekday(s.days?.first ?? 1)
            return L("weekly on \(day) at \(at)", "wöchentlich am \(day) um \(at)")
        default: return L("daily at \(at), \(days)", "täglich um \(at), \(days)")
        }
    }

    static func statusText(_ f: TaskFire) -> String {
        let when = f.slot.map { " (\($0.replacingOccurrences(of: "T", with: " ").replacingOccurrences(of: "-now", with: "")))" } ?? ""
        switch f.status {
        case "fired": return L("sent, a session works on it", "gesendet, eine Sitzung arbeitet daran") + when
        case "pending": return L("sending", "wird gesendet") + when
        case "ratelimited": return L("waiting (rate limit), tried again", "wartet (Rate-Limit), neuer Versuch") + when
        case "needs-setup": return L("not sent: the Claude account has no routine yet", "nicht gesendet: das Claude-Konto hat noch keine Routine") + when
        case "failed": return L("could not send: ", "Senden fehlgeschlagen: ") + LogTools.maskSecrets(f.error ?? "") + when
        default: return f.status + when
        }
    }

    /// An id the script takes: a-z, 0-9 and -, starting with a letter or digit, 32 at most.
    static func slug(_ s: String, or fallback: String) -> String {
        let raw = s.lowercased().map { $0.isASCII && ($0.isLetter || $0.isNumber) ? String($0) : "-" }.joined()
        let parts = raw.split(separator: "-").joined(separator: "-")
        let cut = String(parts.prefix(32)).trimmingCharacters(in: CharacterSet(charactersIn: "-"))
        return cut.isEmpty ? fallback : cut
    }

    // MARK: - writing

    private func save(blocks: [TaskBlock], tasks: [ScheduledTask]) async {
        let file = TasksFile(perDay: status?.perDay, perTask: status?.perTask, blocks: blocks, tasks: tasks.map(\.saved))
        guard let data = try? JSONEncoder().encode(file), let text = String(data: data, encoding: .utf8) else { return }
        await run(["tasks", "save"], stdin: text)
    }

    private func saveTask(_ t: ScheduledTask) async {
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

    private func saveBlock(_ b: TaskBlock) async {
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

    private func deleteBlock(_ b: TaskBlock) async {
        guard let s = status else { return }
        await save(blocks: s.blocks.filter { $0.id != b.id }, tasks: s.tasks)
    }

    private func saveRoutine() async {
        let id = routineId.trimmingCharacters(in: .whitespaces)
        var args = ["tasks", "routine", id, "--model", setupModel, "--account", setupAccount.isEmpty ? "current" : setupAccount]
        let label = setupLabel.trimmingCharacters(in: .whitespaces)
        if !label.isEmpty { args += ["--label", label] }
        await run(args)
        if !failed, !token.isEmpty {
            busy = true; defer { busy = false }
            do {
                _ = try await Tool.run(["tasks", "set-token", "--routine", id], stdin: token.trimmingCharacters(in: .whitespacesAndNewlines), timeout: 20)
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
            status = try await Tool.json(["tasks", "status", "--json"], as: TasksStatus.self, timeout: 20)
            readError = nil
        } catch { readError = error.localizedDescription }
    }
}

/// One task: the repo, its blocks, the schedule, the model, the account.
struct TaskEditor: View {
    @State var task: ScheduledTask
    let blocks: [TaskBlock]
    let repos: [String]
    let accounts: [TaskAccount]
    let done: (ScheduledTask?) -> Void

    private static let day: DateFormatter = {
        let f = DateFormatter(); f.dateFormat = "yyyy-MM-dd"; f.locale = Locale(identifier: "en_US_POSIX"); return f
    }()

    private var hour: Binding<Int> { Binding(get: { Int((task.schedule.at ?? "02:00").prefix(2)) ?? 2 },
                                             set: { task.schedule.at = String(format: "%02d:%02d", $0, minute.wrappedValue) }) }
    private var minute: Binding<Int> { Binding(get: { Int((task.schedule.at ?? "02:00").suffix(2)) ?? 0 },
                                               set: { task.schedule.at = String(format: "%02d:%02d", hour.wrappedValue, $0) }) }
    private var date: Binding<Date> {
        Binding(get: { task.schedule.date.flatMap { Self.day.date(from: $0) } ?? Date() }, set: { task.schedule.date = Self.day.string(from: $0) })
    }
    private var kind: Binding<String> {
        Binding(get: { task.schedule.kind }, set: { k in
            var s = task.schedule; s.kind = k
            let all = (s.days?.isEmpty ?? true) ? Array(1...7) : (s.days ?? [])
            switch k {
            case "once": s.at = s.at ?? "09:00"; s.minute = nil; s.days = nil; s.date = s.date ?? Self.day.string(from: Date())
            case "hourly": s.minute = s.minute ?? 0; s.at = nil; s.date = nil; s.days = all
            case "weekly": s.at = s.at ?? "02:00"; s.date = nil; s.minute = nil; s.days = [s.days?.first ?? 1]
            default: s.at = s.at ?? "02:00"; s.date = nil; s.minute = nil; s.days = all
            }
            task.schedule = s
        })
    }
    private var valid: Bool {
        let s = task.schedule
        let whenOK: Bool
        switch s.kind {
        case "once": whenOK = s.date != nil && s.at != nil
        case "weekly": whenOK = (s.days ?? []).count == 1
        default: whenOK = !(s.days ?? []).isEmpty
        }
        return task.repo.range(of: "^[A-Za-z0-9_.-]+/[A-Za-z0-9_.-]+$", options: .regularExpression) != nil && !task.blocks.isEmpty && whenOK
    }

    private var timePickers: some View {
        HStack {
            Picker(L("At", "Um"), selection: hour) { ForEach(0..<24, id: \.self) { Text(String(format: "%02d", $0)).tag($0) } }.fixedSize()
            Picker(":", selection: minute) { ForEach(Array(stride(from: 0, to: 60, by: 5)), id: \.self) { Text(String(format: "%02d", $0)).tag($0) } }.fixedSize()
            Text(L("local time", "Ortszeit")).font(.caption).foregroundStyle(.secondary)
        }
    }
    private var dayToggles: some View {
        HStack {
            ForEach(1...7, id: \.self) { d in
                Toggle(String(NightlySettings.weekday(d).prefix(2)), isOn: Binding(
                    get: { (task.schedule.days ?? []).contains(d) },
                    set: { on in var ds = task.schedule.days ?? []; ds.removeAll { $0 == d }; if on { ds.append(d); ds.sort() }; task.schedule.days = ds }))
                    .toggleStyle(.button)
            }
        }
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            Text(task.id.isEmpty ? L("New task", "Neue Aufgabe") : L("Task", "Aufgabe")).font(.headline)
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
                Picker(L("Schedule", "Zeitplan"), selection: kind) {
                    Text(L("Once", "Einmalig")).tag("once"); Text(L("Hourly", "Stündlich")).tag("hourly")
                    Text(L("Daily", "Täglich")).tag("daily"); Text(L("Weekly", "Wöchentlich")).tag("weekly")
                }
                switch task.schedule.kind {
                case "once":
                    DatePicker(L("On", "Am"), selection: date, displayedComponents: .date)
                    timePickers
                case "hourly":
                    Picker(L("Minutes past the hour", "Minuten nach der vollen Stunde"), selection: Binding(get: { task.schedule.minute ?? 0 }, set: { task.schedule.minute = $0 })) {
                        ForEach(Array(stride(from: 0, to: 60, by: 5)), id: \.self) { Text(String(format: ":%02d", $0)).tag($0) }
                    }
                    dayToggles
                case "weekly":
                    Picker(L("Day", "Tag"), selection: Binding(get: { task.schedule.days?.first ?? 1 }, set: { task.schedule.days = [$0] })) {
                        ForEach(1...7, id: \.self) { Text(NightlySettings.weekday($0)).tag($0) }
                    }
                    timePickers
                default:
                    timePickers
                    dayToggles
                }
                Picker(L("Model", "Modell"), selection: Binding(get: { task.model ?? "sonnet" }, set: { task.model = $0 })) {
                    Text(L("Sonnet (recommended)", "Sonnet (empfohlen)")).tag("sonnet"); Text("Haiku").tag("haiku"); Text("Opus").tag("opus")
                }
                Picker(L("Claude account", "Claude-Konto"), selection: Binding(get: { task.account ?? "" }, set: { task.account = $0.isEmpty ? nil : $0 })) {
                    Text(L("The one signed in at the time", "Das zur Zeit angemeldete")).tag("")
                    ForEach(accounts) { a in Text(a.title).tag(a.id) }
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
        .frame(width: 540)
    }
}

/// One prompt block: a name and its text.
struct TaskBlockEditor: View {
    @State var block: TaskBlock
    let done: (TaskBlock?) -> Void

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
