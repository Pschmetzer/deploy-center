// Deploy Center — The journal: every deploy that ended, kept on this Mac, for the history and a CSV.

import SwiftUI
import AppKit
import UniformTypeIdentifiers

struct JournalEntry: Codable, Identifiable {
    /// Stable across loads, so a list does not redraw every row when it is read again.
    var id: String { "\(at.timeIntervalSince1970)|\(platform)|\(name)|\(result)" }
    let at: Date
    let platform: String
    let name: String
    let result: String        // see Kind: live, preview, rollback, forced, failed, skipped, cancelled (other: older apps)
    let seconds: Double?
    let detail: String?
    /// The person's own comment, added later in the history (FEA-048). The script leaves it alone.
    var note: String? = nil
    init(at: Date = Date(), platform: String, name: String, result: String, seconds: Double?, detail: String?) {
        self.at = at; self.platform = platform; self.name = name; self.result = result; self.seconds = seconds; self.detail = detail
    }
}

enum Journal {
    /// In Application Support: macOS may empty the Caches folder at any time.
    static var dir: URL {
        FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
            .appendingPathComponent("app.deploycenter.mac", isDirectory: true)
    }
    static var url: URL { dir.appendingPathComponent("journal.jsonl") }
    private static var oldURL: URL { Store.cacheDir.appendingPathComponent("journal.jsonl") }
    private static let maxEntries = 500
    /// Lines in the file, counted once; trimmed only past a margin, so an entry does not
    /// read and decode the whole file.
    private static var lines: Int?
    private static let lock = NSLock()

    /// The journal of older versions, moved once out of the Caches folder.
    static func migrate() {
        let fm = FileManager.default
        guard fm.fileExists(atPath: oldURL.path), !fm.fileExists(atPath: url.path) else { return }
        try? fm.createDirectory(at: dir, withIntermediateDirectories: true)
        try? fm.moveItem(at: oldURL, to: url)
    }

    /// Posted after an entry was written, so an open history shows it.
    static let didAppend = Notification.Name("JournalDidAppend")

    /// Called on the main thread when a deploy ends; the file work (and the trim, which reads it
    /// all) runs on a queue of its own.
    private static let writer = DispatchQueue(label: "app.deploycenter.journal", qos: .utility)
    static func append(_ e: JournalEntry) {
        writer.async { appendNow(e) }
    }
    /// Waits for entries still being written (tests, and before reading right after a write).
    static func flush() { writer.sync {} }

    /// "<journal>.lock", a folder, as the script takes it (deploys journal_add): waited for two
    /// seconds at most, and a stale lock never costs a line.
    static func withFileLock<T>(_ body: () -> T) -> T {
        let l = url.path + ".lock"
        try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        var locked = false
        for _ in 0..<20 {
            if mkdir(l, 0o700) == 0 { locked = true; break }
            Thread.sleep(forTimeInterval: 0.1)
        }
        defer { if locked { rmdir(l) } }
        return body()
    }

    private static func appendNow(_ e: JournalEntry) {
        lock.lock(); defer { lock.unlock() }
        withFileLock { appendLocked(e) }
    }
    private static func appendLocked(_ e: JournalEntry) {
        migrate()
        let enc = JSONEncoder(); enc.dateEncodingStrategy = .iso8601
        guard let data = try? enc.encode(e) else { return }
        try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        let line = data + Data("\n".utf8)
        // The throwing calls: the old seekToEndOfFile/write raise an Objective-C exception on a full
        // disk, which no catch stops.
        do {
            if FileManager.default.fileExists(atPath: url.path) {
                let h = try FileHandle(forWritingTo: url)
                defer { try? h.close() }
                try h.seekToEnd(); try h.write(contentsOf: line)
            } else {
                try line.write(to: url)
                private600(url)
            }
        } catch {
            Log.write("journal: could not write (\(error.localizedDescription))")
            return
        }
        let n = (lines ?? countLines()) + (lines == nil ? 0 : 1)
        lines = n
        // Kept small: past 500 lines (and a margin) the oldest go.
        if n > maxEntries + 50 {
            let all = load(limit: .max)
            rewrite(Array(all.suffix(maxEntries)))
            lines = min(all.count, maxEntries)
        }
        DispatchQueue.main.async { NotificationCenter.default.post(name: didAppend, object: nil) }
    }

    /// Project names and error texts: readable by this user only, like the log.
    private static func private600(_ u: URL) {
        try? FileManager.default.setAttributes([.posixPermissions: 0o600], ofItemAtPath: u.path)
    }

    private static func countLines() -> Int {
        guard let data = try? Data(contentsOf: url) else { return 0 }
        return data.reduce(0) { $1 == 10 ? $0 + 1 : $0 }
    }

    private static func rewrite(_ list: [JournalEntry]) {
        let enc = JSONEncoder(); enc.dateEncodingStrategy = .iso8601
        let text = list.compactMap { try? enc.encode($0) }.map { String(decoding: $0, as: UTF8.self) }.joined(separator: "\n") + "\n"
        do { try Data(text.utf8).write(to: url, options: .atomic); private600(url) }
        catch { Log.write("journal: could not trim (\(error.localizedDescription))") }
    }

    /// Sets (or with an empty text removes) the comment of one entry, by its id.
    static func setNote(_ id: String, _ text: String) {
        let t = text.trimmingCharacters(in: .whitespacesAndNewlines)
        writer.async {
            lock.lock(); defer { lock.unlock() }
            withFileLock {
                var all = load(limit: .max)
                guard let i = all.firstIndex(where: { $0.id == id }) else { return }
                all[i].note = t.isEmpty ? nil : String(t.prefix(500))
                rewrite(all)
            }
            DispatchQueue.main.async { NotificationCenter.default.post(name: didAppend, object: nil) }
        }
    }

    /// Oldest first.
    static func load(limit: Int) -> [JournalEntry] {
        migrate()
        guard let text = try? String(contentsOf: url, encoding: .utf8) else { return [] }
        let dec = JSONDecoder(); dec.dateDecodingStrategy = .iso8601
        let all = text.split(separator: "\n").compactMap { try? dec.decode(JournalEntry.self, from: Data($0.utf8)) }
        return limit == .max ? all : Array(all.suffix(limit))
    }

    static func csv(_ list: [JournalEntry]) -> String {
        // Quoted, and a cell that a spreadsheet would read as a formula starts with ' instead.
        func q(_ s: String) -> String {
            let safe = s.first.map { "=+-@\t\r".contains($0) } == true ? "'" + s : s
            return "\"" + safe.replacingOccurrences(of: "\"", with: "\"\"") + "\""
        }
        return (["time,platform,project,result,seconds,detail,note"] + list.map {
            [$0.at.formatted(.iso8601), $0.platform, q($0.name), $0.result, $0.seconds.map { String(Int($0)) } ?? "", q($0.detail ?? ""), q($0.note ?? "")].joined(separator: ",")
        }).joined(separator: "\n")
    }

    /// Of the last `window` ended deploys of a project: how many failed. A frontend and a backend
    /// of the same name are two projects.
    static func failures(of name: String, platform: String? = nil, in list: [JournalEntry], window: Int = 10) -> (failed: Int, total: Int) {
        let mine = list.filter { $0.name == name && (platform == nil || $0.platform == platform) && ["live", "failed"].contains($0.result) }.suffix(window)
        return (mine.filter { $0.result == "failed" }.count, mine.count)
    }

    /// The same count for every project at once, keyed "platform/name": one pass instead of one per row.
    static func failureTable(_ list: [JournalEntry], window: Int = 10) -> [String: (failed: Int, total: Int)] {
        var recent: [String: [Bool]] = [:]
        for e in list where ["live", "failed"].contains(e.result) { recent["\(e.platform)/\(e.name)", default: []].append(e.result == "failed") }
        return recent.mapValues { r in let w = r.suffix(window); return (w.filter { $0 }.count, w.count) }
    }

    /// Entries that match a search (project, platform or detail) and a kind; nil kind is all.
    static func filter(_ list: [JournalEntry], text: String, kind: JournalEntry.Kind?) -> [JournalEntry] {
        let t = text.trimmingCharacters(in: .whitespaces)
        return list.filter { e in
            (kind == nil || e.kind == kind)
                && (t.isEmpty || e.name.localizedCaseInsensitiveContains(t) || e.platform.localizedCaseInsensitiveContains(t)
                    || (e.detail?.localizedCaseInsensitiveContains(t) ?? false) || (e.note?.localizedCaseInsensitiveContains(t) ?? false))
        }
    }

    /// Newest day first, each day's entries newest first.
    static func byDay(_ list: [JournalEntry]) -> [(day: String, entries: [JournalEntry])] {
        let groups = Dictionary(grouping: list) { localDay($0.at) }
        return groups.keys.sorted(by: >).map { k in (k, groups[k]!.sorted { $0.at > $1.at }) }
    }
}

extension JournalEntry {
    /// The result as a known kind; a word from a newer script or app is `.other`.
    enum Kind: String, CaseIterable {
        case live, preview, rollback, forced, failed, skipped, cancelled, other
        var title: String {
            switch self {
            case .live: return L("Live", "Live")
            case .preview: return L("Preview", "Vorschau")
            case .rollback: return L("Rolled back", "Zurückgerollt")
            case .forced: return L("Forced", "Erzwungen")
            case .failed: return L("Failed", "Fehlgeschlagen")
            case .skipped: return L("Skipped", "Übersprungen")
            case .cancelled: return L("Cancelled", "Abgebrochen")
            case .other: return L("Other", "Anderes")
            }
        }
        var symbol: String {
            switch self {
            case .live: return "checkmark.circle.fill"
            case .preview: return "eye.circle.fill"
            case .rollback: return "arrow.uturn.backward.circle.fill"
            case .forced: return "exclamationmark.shield.fill"
            case .failed: return "xmark.octagon.fill"
            case .skipped: return "forward.circle.fill"
            case .cancelled: return "stop.circle.fill"
            case .other: return "circle.fill"
            }
        }
        var color: Color {
            switch self {
            case .live: return .green
            case .preview, .rollback: return .blue
            case .forced: return .orange
            case .failed: return .red
            case .skipped, .cancelled, .other: return .secondary
            }
        }
    }
    var kind: Kind { Kind(rawValue: result) ?? .other }
}

struct JournalView: View {
    /// For "costliest failures" (an average build's price); nil leaves that part out.
    var costs: Costs? = nil
    @Environment(\.dismiss) private var dismiss
    @State private var stats = false
    @State private var noteFor: JournalEntry?
    @State private var noteText = ""
    @State private var entries: [JournalEntry] = []
    @State private var failed: [String: (failed: Int, total: Int)] = [:]
    @State private var search = ""
    @State private var kind: JournalEntry.Kind?
    @State private var limit = 200

    private var shown: [JournalEntry] { Journal.filter(entries, text: search, kind: kind) }
    /// Names in the details are scrubbed in demo mode, like everywhere on screen.
    private var names: [Item] {
        Set(entries.map(\.name)).map { Item(id: $0, name: $0, detail: "", platform: .vercel, deployable: false, auto: false, note: nil, link: nil) }
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            HStack {
                Text(L("Deploy history", "Deploy-Verlauf")).font(.headline)
                Spacer()
                Button(L("Copy as CSV", "Als CSV kopieren")) {
                    NSPasteboard.general.clearContents(); NSPasteboard.general.setString(Journal.csv(shown), forType: .string)
                }.disabled(shown.isEmpty)
                Button(L("Save as CSV …", "Als CSV sichern …")) { save() }.disabled(shown.isEmpty)
                Menu(L("Markdown", "Markdown")) {
                    Button(L("Copy the list as a table", "Liste als Tabelle kopieren")) { copy(JournalStats.markdown(shown, mask: Demo.mask)) }
                    Button(L("Copy this month's report", "Bericht dieses Monats kopieren")) { copy(JournalStats.monthReport(entries, mask: Demo.mask)) }
                }.fixedSize().disabled(entries.isEmpty)
                Toggle(L("Figures", "Zahlen"), isOn: $stats).toggleStyle(.button).disabled(entries.isEmpty)
                Button(L("Close", "Schließen")) { dismiss() }.keyboardShortcut(.cancelAction)
            }.padding(12)
            HStack {
                TextField(L("Search project or reason", "Projekt oder Grund suchen"), text: $search).textFieldStyle(.roundedBorder)
                Picker(L("Result", "Ergebnis"), selection: $kind) {
                    Text(L("All", "Alle")).tag(JournalEntry.Kind?.none)
                    ForEach(JournalEntry.Kind.allCases, id: \.self) { k in Text(k.title).tag(JournalEntry.Kind?.some(k)) }
                }.fixedSize()
            }.padding(.horizontal, 12).padding(.bottom, 8)
            Divider()
            if stats && !entries.isEmpty {
                JournalStatsView(entries: entries, costs: costs)
            } else if entries.isEmpty {
                Text(L("Nothing yet. Deploys that end are listed here.", "Noch nichts. Beendete Deploys stehen hier."))
                    .foregroundStyle(.secondary).padding(16)
            } else if shown.isEmpty {
                Text(L("Nothing matches.", "Nichts gefunden.")).foregroundStyle(.secondary).padding(16)
            } else {
                List {
                    ForEach(Journal.byDay(shown), id: \.day) { group in
                        Section(SavingsFormat.day(group.day)) {
                            ForEach(group.entries) { e in row(e) }
                        }
                    }
                    if entries.count >= limit {
                        Button(L("Load older entries", "Ältere Einträge laden")) { limit = .max; reload() }.buttonStyle(.link)
                    }
                }
            }
        }
        .frame(minWidth: 560, idealWidth: 680, minHeight: 360, idealHeight: 520)
        .task { reload() }
        .alert(L("Comment", "Kommentar"), isPresented: Binding(get: { noteFor != nil }, set: { if !$0 { noteFor = nil } })) {
            TextField(L("Why it went out, what to watch", "Warum es raus ging, worauf achten"), text: $noteText)
            Button(L("Cancel", "Abbrechen"), role: .cancel) { noteFor = nil }
            Button(L("Save", "Speichern")) { if let e = noteFor { Journal.setNote(e.id, noteText) }; noteFor = nil }
        } message: {
            Text(L("Kept in this Mac's history.", "Bleibt im Verlauf dieses Macs."))
        }
        .onReceive(NotificationCenter.default.publisher(for: Journal.didAppend)) { _ in reload() }
    }

    private func row(_ e: JournalEntry) -> some View {
        let k = e.kind, detail = e.detail.map { Demo.on ? Demo.scrub($0, items: names) : $0 }
        let took = e.seconds.map { "\(Int($0) / 60):\(String(format: "%02d", Int($0) % 60))" }
        return VStack(alignment: .leading, spacing: 2) {
            HStack(spacing: 8) {
                Image(systemName: k.symbol).foregroundStyle(k.color).accessibilityHidden(true)
                Text(Demo.mask(e.name)).font(.body.weight(.medium))
                Text(k.title).font(.caption).foregroundStyle(k.color == .secondary ? Color.secondary : k.color)
                Text(e.platform).font(.caption).foregroundStyle(.secondary)
                if let f = failed["\(e.platform)/\(e.name)"], f.failed > 0 {
                    Text(L("\(f.failed) of last \(f.total) failed", "\(f.failed) der letzten \(f.total) fehlgeschlagen"))
                        .font(.caption2).foregroundStyle(.orange)
                }
                Spacer()
                if let took { Text(took).font(.caption.monospacedDigit()).foregroundStyle(.secondary) }
                Text(e.at.formatted(date: .omitted, time: .shortened)).font(.caption).foregroundStyle(.secondary)
            }
            if let detail, !detail.isEmpty {
                Text(detail).font(.caption).foregroundStyle(.secondary).lineLimit(2).padding(.leading, 26)
            }
            if let n = e.note {
                Label(n, systemImage: "text.bubble").font(.caption).lineLimit(2).padding(.leading, 26)
            }
        }
        .help(detail ?? "")
        .accessibilityElement(children: .combine)
        .contextMenu {
            if k == .failed || k == .rollback {
                Button(L("Copy a postmortem template", "Postmortem-Vorlage kopieren")) { copy(JournalStats.postmortem(e, mask: Demo.mask)) }
            }
            Button(e.note == nil ? L("Add a comment …", "Kommentar hinzufügen …") : L("Edit the comment …", "Kommentar ändern …")) {
                noteText = e.note ?? ""; noteFor = e
            }
            Button(L("Copy as Markdown", "Als Markdown kopieren")) { copy(JournalStats.markdown([e], mask: Demo.mask)) }
        }
    }

    private func copy(_ s: String) { NSPasteboard.general.clearContents(); NSPasteboard.general.setString(s, forType: .string) }

    private func reload() {
        entries = Journal.load(limit: limit); failed = Journal.failureTable(entries)
    }

    private func save() {
        let panel = NSSavePanel()
        panel.nameFieldStringValue = "deploy-history.csv"
        panel.allowedContentTypes = [.commaSeparatedText]
        guard panel.runModal() == .OK, let u = panel.url else { return }
        do { try Data(Journal.csv(shown).utf8).write(to: u, options: .atomic) }
        catch { Log.write("journal: CSV not saved (\(error.localizedDescription))") }
    }
}
