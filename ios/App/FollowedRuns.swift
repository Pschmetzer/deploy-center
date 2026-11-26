// Deploy Center for iPhone — The deploys followed right now, kept across a kill of the app.

import Foundation

/// The deploys the app follows right now, kept so that a killed app can follow them again at the next launch
/// (and keep their Live Activity). Only ids and keys: no names, no keys of accounts.
enum FollowedRuns {
    static let defaultsKey = "followedRuns"
    struct Run: Codable, Equatable { var key: String; var id: String; var started: Date }
    /// A run is followed for 20 minutes at most (the limit of `follow`).
    static let maxAge: TimeInterval = 20 * 60

    private static func all() -> [Run] {
        guard let d = UserDefaults.standard.data(forKey: defaultsKey) else { return [] }
        return (try? JSONDecoder().decode([Run].self, from: d)) ?? []
    }
    private static func save(_ r: [Run]) {
        if r.isEmpty { UserDefaults.standard.removeObject(forKey: defaultsKey) }
        else if let d = try? JSONEncoder().encode(r) { UserDefaults.standard.set(d, forKey: defaultsKey) }
    }
    static func fresh(now: Date = Date()) -> [Run] { all().filter { now.timeIntervalSince($0.started) < maxAge } }
    /// The same deploy keeps the time it was first followed (a restart must not reset the 20 minutes);
    /// a new deploy of the project starts afresh.
    static func add(key: String, id: String, now: Date = Date()) {
        let old = all().first { $0.key == key && $0.id == id }
        save(all().filter { $0.key != key } + [Run(key: key, id: id, started: old?.started ?? now)])
    }
    static func remove(_ key: String) { save(all().filter { $0.key != key }) }
}
