// Deploy Center for iPhone — The last deploy history of each project, so the list reads offline.

import Foundation

/// The last history of each project, metadata only (no log text), so the list reads offline.
/// Kept in UserDefaults; at most 40 projects, oldest dropped. Read from UserDefaults once and then held in memory:
/// the health card asks for every project at every redraw, and each of those asks must not decode the whole dictionary.
/// Writes go to UserDefaults on a background queue, in order.
enum HistoryCache {
    private static let key = "historyCache.v1"
    private struct Entry: Codable { var at: Date; var records: [DeployRecord] }

    private static let lock = NSLock()
    nonisolated(unsafe) private static var memory: [String: Entry]?
    private static let writer = DispatchQueue(label: "deploycenter.historycache", qos: .utility)
    /// How often the whole cache was decoded from UserDefaults (a test holds this to 1).
    nonisolated(unsafe) private(set) static var decodeCount = 0

    private static func all() -> [String: Entry] {
        if let m = memory { return m }
        decodeCount += 1
        let m: [String: Entry]
        if let d = UserDefaults.standard.data(forKey: key) { m = (try? JSONDecoder().decode([String: Entry].self, from: d)) ?? [:] } else { m = [:] }
        memory = m
        return m
    }
    static func save(_ r: [DeployRecord], for project: String) {
        lock.lock(); defer { lock.unlock() }
        var a = all()
        a[project] = Entry(at: Date(), records: r)
        if a.count > 40 { for k in a.sorted(by: { $0.value.at < $1.value.at }).prefix(a.count - 40).map(\.key) { a[k] = nil } }
        memory = a
        let snapshot = a
        writer.async { if let d = try? JSONEncoder().encode(snapshot) { UserDefaults.standard.set(d, forKey: key) } }
    }
    static func load(_ project: String) -> [DeployRecord]? { lock.lock(); defer { lock.unlock() }; return all()[project]?.records }
    static func clear() {
        lock.lock(); defer { lock.unlock() }
        memory = [:]
        writer.async { UserDefaults.standard.removeObject(forKey: key) }
    }
}
