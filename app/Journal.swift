// Deploy Center — The journal: every deploy that ended, kept on this Mac, for the history and a CSV.

import SwiftUI
import AppKit

struct JournalEntry: Codable, Identifiable {
    var id = UUID()
    let at: Date
    let platform: String
    let name: String
    let result: String        // live, other (preview, rollback), failed, skipped
    let seconds: Double?
    let detail: String?
    enum CodingKeys: String, CodingKey { case at, platform, name, result, seconds, detail }
    init(at: Date = Date(), platform: String, name: String, result: String, seconds: Double?, detail: String?) {
        self.at = at; self.platform = platform; self.name = name; self.result = result; self.seconds = seconds; self.detail = detail
    }
}

enum Journal {
    static var url: URL { Store.cacheDir.appendingPathComponent("journal.jsonl") }
    private static let maxEntries = 500

    static func append(_ e: JournalEntry) {
        let enc = JSONEncoder(); enc.dateEncodingStrategy = .iso8601
        guard let data = try? enc.encode(e) else { return }
        try? FileManager.default.createDirectory(at: Store.cacheDir, withIntermediateDirectories: true)
        let line = data + Data("\n".utf8)
        if let h = try? FileHandle(forWritingTo: url) { h.seekToEndOfFile(); h.write(line); try? h.close() }
        else { try? line.write(to: url) }
        // Kept small: past 500 lines the oldest go.
        let all = load(limit: .max)
        if all.count > maxEntries { rewrite(Array(all.suffix(maxEntries))) }
    }

    private static func rewrite(_ list: [JournalEntry]) {
        let enc = JSONEncoder(); enc.dateEncodingStrategy = .iso8601
        let text = list.compactMap { try? enc.encode($0) }.map { String(decoding: $0, as: UTF8.self) }.joined(separator: "\n") + "\n"
        try? Data(text.utf8).write(to: url, options: .atomic)
    }

    /// Oldest first.
    static func load(limit: Int) -> [JournalEntry] {
        guard let text = try? String(contentsOf: url, encoding: .utf8) else { return [] }
        let dec = JSONDecoder(); dec.dateDecodingStrategy = .iso8601
        let all = text.split(separator: "\n").compactMap { try? dec.decode(JournalEntry.self, from: Data($0.utf8)) }
        return limit == .max ? all : Array(all.suffix(limit))
    }

    static func csv(_ list: [JournalEntry]) -> String {
        func q(_ s: String) -> String { "\"" + s.replacingOccurrences(of: "\"", with: "\"\"") + "\"" }
        return (["time,platform,project,result,seconds,detail"] + list.map {
            [$0.at.formatted(.iso8601), $0.platform, q($0.name), $0.result, $0.seconds.map { String(Int($0)) } ?? "", q($0.detail ?? "")].joined(separator: ",")
        }).joined(separator: "\n")
    }

    /// Of the last `window` ended deploys of a project: how many failed.
    static func failures(of name: String, in list: [JournalEntry], window: Int = 10) -> (failed: Int, total: Int) {
        let mine = list.filter { $0.name == name && ["live", "failed"].contains($0.result) }.suffix(window)
        return (mine.filter { $0.result == "failed" }.count, mine.count)
    }
}

struct JournalView: View {
    @Environment(\.dismiss) private var dismiss
    @State private var entries: [JournalEntry] = []

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
                        Image(systemName: e.result == "failed" ? "xmark.octagon.fill" : (e.result == "skipped" ? "forward.circle.fill" : "checkmark.circle.fill"))
                            .foregroundStyle(e.result == "failed" ? .red : (e.result == "skipped" ? .secondary : .green))
                        Text(Demo.mask(e.name)).font(.body.weight(.medium))
                        Text(e.platform).font(.caption).foregroundStyle(.secondary)
                        let f = Journal.failures(of: e.name, in: entries)
                        if f.failed > 0 {
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
        .task { entries = Journal.load(limit: 200) }
    }
}
