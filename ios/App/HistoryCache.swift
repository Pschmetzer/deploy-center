// Deploy Center for iPhone — The last deploy history of each project, so the list reads offline.

import Foundation

/// The last history of each project, metadata only (no log text), so the list reads offline.
/// Kept in UserDefaults; at most 40 projects, oldest dropped.
enum HistoryCache {
    private static let key = "historyCache.v1"
    private struct Entry: Codable { var at: Date; var records: [DeployRecord] }

    private static func all() -> [String: Entry] {
        guard let d = UserDefaults.standard.data(forKey: key) else { return [:] }
        return (try? JSONDecoder().decode([String: Entry].self, from: d)) ?? [:]
    }
    static func save(_ r: [DeployRecord], for project: String) {
        var a = all()
        a[project] = Entry(at: Date(), records: r)
        if a.count > 40 { for k in a.sorted(by: { $0.value.at < $1.value.at }).prefix(a.count - 40).map(\.key) { a[k] = nil } }
        if let d = try? JSONEncoder().encode(a) { UserDefaults.standard.set(d, forKey: key) }
    }
    static func load(_ project: String) -> [DeployRecord]? { all()[project]?.records }
    static func clear() { UserDefaults.standard.removeObject(forKey: key) }
}
