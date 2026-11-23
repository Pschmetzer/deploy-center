// Deploy Center — Remembers which projects were ticked, per platform tab, between launches.

import Foundation

/// The ticks of one platform as a list of row ids. Pure helpers; `Store` reads and writes the defaults.
enum SelectionMemory {
    static func key(_ p: Platform) -> String { "selection.\(p.cli)" }

    static func load(_ p: Platform, defaults: UserDefaults = .standard) -> Set<String> {
        Set(defaults.stringArray(forKey: key(p)) ?? [])
    }

    /// Only a list that was read counts: before the first load the rows are empty, and writing
    /// that would erase what the last run remembered.
    static func save(_ p: Platform, rows: [Item], defaults: UserDefaults = .standard) {
        guard !rows.isEmpty else { return }
        let ids = rows.filter(\.selected).map(\.id).sorted()
        if (defaults.stringArray(forKey: key(p)) ?? []) != ids { defaults.set(ids, forKey: key(p)) }
    }

    /// The fresh rows with the remembered ticks applied (only deployable ones, never a running one).
    static func restore(_ fresh: [Item], remembered: Set<String>) -> [Item] {
        guard !remembered.isEmpty else { return fresh }
        return fresh.map { i in
            var i = i
            if remembered.contains(i.id), i.deployable, !i.state.isActive { i.selected = true }
            return i
        }
    }
}
