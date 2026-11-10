// Deploy Center — The journal: every deploy that ended, kept on this Mac, for the history and a CSV.

import SwiftUI
import AppKit

struct JournalEntry: Codable, Identifiable {
    /// Stable across loads, so a list does not redraw every row when it is read again.
    var id: String { "\(at.timeIntervalSince1970)|\(platform)|\(name)|\(result)" }
    let at: Date
    let platform: String
    let name: String
    let result: String        // live, other (preview, rollback), failed, skipped, cancelled
    let seconds: Double?
    let detail: String?
    init(at: Date = Date(), platform: String, name: String, result: String, seconds: Double?, detail: String?) {
        self.at = at; self.platform = platform; self.name = name; self.result = result; self.seconds = seconds; self.detail = detail
    }
}

enum Journal {
    /// In Application Support: macOS may empty the Caches folder at any time.
    static var dir: URL { AppDirs.support }
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

    static func append(_ e: JournalEntry) {
        lock.lock(); defer { lock.unlock() }
        migrate()
        let enc = JSONEncoder(); enc.dateEncodingStrategy = .iso8601
        guard let data = try? enc.encode(e) else { return }
        try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        let line = data + Data("\n".utf8)
        // The throwing calls: the old ones raise an Objective-C exception on a full disk, and the app ends.
        if let h = try? FileHandle(forWritingTo: url) { _ = try? h.seekToEnd(); try? h.write(contentsOf: line); try? h.close() }
        else { try? line.write(to: url) }
        let n = (lines ?? countLines()) + (lines == nil ? 0 : 1)
        lines = n
        // Kept small: past 500 lines (and a margin) the oldest go.
        if n > maxEntries + 50 {
            let all = load(limit: .max)
            rewrite(Array(all.suffix(maxEntries)))
            lines = min(all.count, maxEntries)
        }
    }

    private static func countLines() -> Int {
        guard let data = try? Data(contentsOf: url) else { return 0 }
        return data.reduce(0) { $1 == 10 ? $0 + 1 : $0 }
    }

    private static func rewrite(_ list: [JournalEntry]) {
        let enc = JSONEncoder(); enc.dateEncodingStrategy = .iso8601
        let text = list.compactMap { try? enc.encode($0) }.map { String(decoding: $0, as: UTF8.self) }.joined(separator: "\n") + "\n"
        try? Data(text.utf8).write(to: url, options: .atomic)
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
        return (["time,platform,project,result,seconds,detail"] + list.map {
            [$0.at.formatted(.iso8601), $0.platform, q($0.name), $0.result, $0.seconds.map { String(Int($0)) } ?? "", q($0.detail ?? "")].joined(separator: ",")
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
}

struct JournalView: View {
    @Environment(\.dismiss) private var dismiss
    @State private var entries: [JournalEntry] = []
    @State private var failed: [String: (failed: Int, total: Int)] = [:]

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            HStack {
                Text(L("Deploy history", "Deploy-Verlauf")).font(.headline)
                Spacer()
                Button(L("Copy as CSV", "Als CSV kopieren")) {
                    NSPasteboard.general.clearContents(); NSPasteboard.general.setString(Journal.csv(entries), forType: .string)
                }.disabled(entries.isEmpty)
                Button(L("Close", "Schließen")) { dismiss() }.keyboardShortcut(.cancelAction)
            }.padding(12)
            Divider()
            if entries.isEmpty {
                Text(L("Nothing yet. Deploys that end are listed here.", "Noch nichts. Beendete Deploys stehen hier."))
                    .foregroundStyle(.secondary).padding(16)
            } else {
                List(entries.reversed()) { e in
                    HStack(spacing: 8) {
                        // "forced": started inside a closed deploy window, with the reason in the detail.
                        Image(systemName: e.result == "failed" ? "xmark.octagon.fill"
                              : (e.result == "skipped" ? "forward.circle.fill" : (e.result == "cancelled" ? "stop.circle.fill"
                              : (e.result == "forced" ? "exclamationmark.shield.fill" : "checkmark.circle.fill"))))
                            .foregroundStyle(e.result == "failed" ? .red : (["skipped", "cancelled"].contains(e.result) ? .secondary
                                             : (e.result == "forced" ? .orange : .green)))
                        Text(Demo.mask(e.name)).font(.body.weight(.medium))
                        Text(e.platform).font(.caption).foregroundStyle(.secondary)
                        if let f = failed["\(e.platform)/\(e.name)"], f.failed > 0 {
                            Text(L("\(f.failed) of last \(f.total) failed", "\(f.failed) der letzten \(f.total) fehlgeschlagen"))
                                .font(.caption2).foregroundStyle(.orange)
                        }
                        Spacer()
                        if let s = e.seconds { Text("\(Int(s) / 60):\(String(format: "%02d", Int(s) % 60))").font(.caption.monospacedDigit()).foregroundStyle(.secondary) }
                        Text(e.at.formatted(date: .abbreviated, time: .shortened)).font(.caption).foregroundStyle(.secondary)
                    }
                    .help(e.detail ?? "")
                }
            }
        }
        .frame(width: 640, height: 460)
        .task { entries = Journal.load(limit: 200); failed = Journal.failureTable(entries) }
    }
}
