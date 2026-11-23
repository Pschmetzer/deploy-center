// Deploy Center — "Why is this waiting?": one short line per row that says what stands between a
// merged change and production (a closed time, a rule, the queue, a missing key).

import Foundation

enum WaitReason {
    struct Context {
        /// The platform's key or login is missing: the app cannot deploy there.
        var keyMissing = false
        /// Observer mode: this Mac only watches.
        var observer = false
        /// Closed deploy times are on now; the reason may be empty.
        var freezeClosed = false
        var freezeReason: String? = nil
        /// "place 2 of 3" or "waits for X" (Store.queueText).
        var queue: String? = nil
        /// A rule that holds this project back, if one is set.
        var holdRule: String? = nil
    }

    /// The most decisive reason first; nil when nothing known stands in the way (the row then
    /// simply waits for a click, which needs no line).
    static func text(_ c: Context) -> String? {
        if c.keyMissing { return L("Waiting: the key for this host is missing (Settings → Access)", "Wartet: der Schlüssel für diesen Host fehlt (Einstellungen → Zugang)") }
        if c.observer { return L("Waiting: this Mac only watches (observer mode)", "Wartet: dieser Mac schaut nur zu (Beobachter-Modus)") }
        if c.freezeClosed {
            let why = (c.freezeReason ?? "").trimmingCharacters(in: .whitespaces)
            return why.isEmpty ? L("Waiting: deploys are closed right now", "Wartet: Deploys sind gerade gesperrt")
                               : L("Waiting: deploys are closed (\(why))", "Wartet: Deploys sind gesperrt (\(why))")
        }
        if let r = c.holdRule { return L("Waiting: the rule “\(r)” may hold it back", "Wartet: die Regel „\(r)“ hält es womöglich zurück") }
        if let q = c.queue { return L("Waiting: \(q)", "Wartet: \(q)") }
        return nil
    }

    /// The name of the first enabled "hold" rule that names this project, or that names none (every project).
    static func holdRule(project: String, platform: Platform, in rules: RulesConfig) -> String? {
        let key = "\(platform.cli)/\(project)"
        return rules.rules.first { r in
            r.enabled && r.then == .hold && r.rawThen == nil && (r.projects.isEmpty || r.projects.contains(key))
        }.map { $0.name.isEmpty ? L("unnamed", "ohne Namen") : $0.name }
    }
}
