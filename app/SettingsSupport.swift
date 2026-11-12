// Deploy Center — what Settings (App.swift) needs that can be tested: the tabs, the allowed values,
// the diagnostics, the defaults a tab resets, and the way other parts of the app open a tab.

import Foundation

/// The tabs of Settings. The raw value is stored under `settingsTab`; one the app no longer has
/// (an older or newer build) opens General instead of an empty window.
enum SettingsTab: String, CaseIterable, Identifiable {
    case general, platforms, projects, deploy, costs, claude, iphone, team, help
    var id: String { rawValue }

    static func resolve(_ raw: String?) -> SettingsTab { raw.flatMap(SettingsTab.init(rawValue:)) ?? .general }

    var title: String {
        switch self {
        case .general: return L("General", "Allgemein")
        case .platforms: return L("Platforms", "Plattformen")
        case .projects: return L("Projects", "Projekte")
        case .deploy: return L("Deploy", "Deploy")
        case .costs: return L("Costs", "Kosten")
        case .claude: return "Claude"
        case .iphone: return "iPhone"
        case .team: return L("Team", "Team")
        case .help: return L("Help", "Hilfe")
        }
    }
    var symbol: String {
        switch self {
        case .general: return "gearshape"
        case .platforms: return "server.rack"
        case .projects: return "folder"
        case .deploy: return "paperplane"
        case .costs: return "dollarsign.circle"
        case .claude: return "sparkles"
        case .iphone: return "iphone"
        case .team: return "person.2"
        case .help: return "questionmark.circle"
        }
    }

    /// How tall the window is on this tab: Help is short, Claude is long (the window still scrolls).
    var height: Double {
        switch self {
        case .help: return 460
        case .costs, .iphone, .projects: return 440
        case .general, .platforms, .deploy, .team: return 600
        case .claude: return 760
        }
    }

    /// The preferences "Reset to defaults" removes on this tab. Never keys, tokens or project data
    /// (pinned, hidden, notes): those have their own buttons on the Projects tab.
    var defaultsKeys: [String] {
        switch self {
        case .general: return ["refreshMinutes", "showMenuBar", "hideDock", "notifications", "reminderHour", "checkUpdates", "demoMode", "paletteHotKey",
                               "spotlightProjects", "tipOfTheDay", "compactRows", "colorBlind", "loadLogos", "quietFrom", "quietTo"]
        case .deploy: return ["maxParallel", "undoSeconds", "staleDays", "onlyWhenGreen", "confirmSingleDeploy",
                              "watchMinutes", MigrationCheck.key, OwnerCheck.key]
        case .costs: return ["monthlyBudget", "savingsDays"]
        case .platforms, .projects, .claude, .iphone, .team, .help: return []
        }
    }
}

/// Where Settings opens and which part it scrolls to. Set before opening the window.
enum SettingsNav {
    static let tabKey = "settingsTab", anchorKey = "settingsAnchor"

    static func prepare(_ tab: SettingsTab, anchor: String? = nil, defaults: UserDefaults = .standard) {
        defaults.set(tab.rawValue, forKey: tabKey)
        defaults.set(anchor ?? "", forKey: anchorKey)
    }

    /// `deploycenter://settings/claude` (or `…/settings?tab=claude`): the tab it names. Nil for any
    /// other link; an unknown tab opens General.
    static func tab(from url: URL) -> SettingsTab? {
        guard url.scheme == "deploycenter", url.host == "settings" else { return nil }
        let path = url.pathComponents.filter { $0 != "/" }.first
        let query = URLComponents(url: url, resolvingAgainstBaseURL: false)?.queryItems?.first { $0.name == "tab" }?.value
        return SettingsTab.resolve((path ?? query)?.lowercased())
    }
}

/// The values the pickers offer. A stored value that is not one of them (an older build,
/// `defaults write`) would leave a picker blank: it becomes the nearest one offered.
enum SettingsChoice {
    static let refreshMinutes = [5, 15, 30, 60]
    static let maxParallel = [1, 2, 3, 5, 10]
    static let undoSeconds = [0, 5, 8, 15]
    static let staleDays = [0, 2, 3, 5, 7]
    static let reminderHour = Array(0...23)

    /// The nearest allowed value; on a tie the smaller one (fewer builds, shorter waits).
    static func snap(_ v: Int, to allowed: [Int]) -> Int {
        guard !allowed.isEmpty, !allowed.contains(v) else { return v }
        return allowed.min { abs($0 - v) != abs($1 - v) ? abs($0 - v) < abs($1 - v) : $0 < $1 } ?? v
    }

    /// Each picker's key and its values, for snapping all of them at once.
    static let pickers: [(key: String, allowed: [Int], fallback: Int)] = [
        ("refreshMinutes", refreshMinutes, 15), ("maxParallel", maxParallel, 3), ("undoSeconds", undoSeconds, 8),
        ("staleDays", staleDays, 0), ("reminderHour", reminderHour, 0),
    ]
    static func snapAll(_ d: UserDefaults = .standard) {
        for p in pickers where d.object(forKey: p.key) != nil {
            let v = d.integer(forKey: p.key), s = snap(v, to: p.allowed)
            if s != v { d.set(s, forKey: p.key) }
        }
    }
}

enum SettingsText {
    /// The diagnostics to paste into an issue: versions and what is connected, per platform the
    /// script reports, without project names and without keys.
    static func diagnostics(version: String, os: String, doctor: Doctor?, providers: [ProviderInfo],
                            counts: [String: Int], gitlabRepos: Int, autofix: AutofixReport?) -> String {
        let d = doctor
        var lines = ["Deploy Center \(version)", os,
                     "jq \(d?.jq ?? false), gh \(d?.githubCli ?? false)/login \(d.map { $0.githubLoggedIn.map(String.init) ?? "?" } ?? "false")"]
        for p in providers {
            var line = "\(p.label): " + (p.enabled ? "on" : "off")
            switch p.id {
            case "vercel": line += ", cli \(d?.vercelCli ?? false)/api \(d?.vercelApi ?? false)/login \(d?.vercelLoggedIn ?? false)"
            case "render": line += ", key \(d?.renderKey ?? false)"
            default: break
            }
            if let n = counts[p.id] { line += ", \(n) projects" }
            lines.append(line)
        }
        if gitlabRepos > 0 { lines.append("GitLab: \(gitlabRepos) repos") }
        lines.append("Autofix: " + (autofix.map { $0.ready ? "ready" : "not set up" } ?? "unknown"))
        return lines.joined(separator: "\n")
    }

    /// Under the budget: when the warning comes, and where the pace is now.
    static func budgetHint(budget: Double, pace: Double?) -> String {
        guard budget > 0 else { return L("No warning while the budget is 0.", "Keine Warnung, solange das Budget 0 ist.") }
        let at = (budget * 0.8).formatted(.currency(code: "USD"))
        let warn = L("A warning comes once the pace of the last 7 days passes 80 %, that is \(at) a month.",
                     "Eine Warnung kommt, sobald das Tempo der letzten 7 Tage 80 % übersteigt, also \(at) im Monat.")
        guard let pace else { return warn }
        return warn + " " + L("Now ≈ \(pace.formatted(.currency(code: "USD"))) a month.", "Jetzt ≈ \(pace.formatted(.currency(code: "USD"))) im Monat.")
    }

    /// What Settings → Platforms says next to a platform: is it connected? Nil when the app cannot tell.
    static func connection(_ id: String, doctor: Doctor?) -> (text: String, ok: Bool)? {
        guard let d = doctor else { return nil }
        switch id {
        case "vercel":
            if !d.vercelCli { return (L("Vercel CLI missing", "Vercel-CLI fehlt"), false) }
            return d.vercelLoggedIn && d.vercelApi ? (L("signed in", "angemeldet"), true) : (L("not signed in", "nicht angemeldet"), false)
        case "render":
            return d.renderKey ? (L("key saved", "Key gespeichert"), true) : (L("no API key", "kein API-Key"), false)
        default: return nil
        }
    }

    /// The keyboard shortcuts of the window, for the Help tab.
    static var shortcuts: [(keys: String, what: String)] {
        [("⌘K", L("Command palette", "Befehlspalette")),
         ("⌥⌘K", L("Command palette from any app (Settings → General)", "Befehlspalette aus jeder App (Einstellungen → Allgemein)")),
         ("⌘F", L("Search", "Suchen")),
         ("⌘R", L("Reload", "Neu laden")),
         ("⌘A", L("Tick everything with changes", "Alles mit Änderungen anhaken")),
         ("⌘↩", L("Deploy the ticked projects (asks first)", "Angehakte Projekte deployen (fragt vorher)")),
         ("⌘1 …", L("Switch platform", "Plattform wechseln")),
         ("⇧⌘D", L("Demo mode on or off", "Demo-Modus an oder aus")),
         ("⇧-" + L("click", "Klick"), L("Tick a range of rows", "Mehrere Zeilen am Stück anhaken")),
         ("Esc", L("Close a sheet", "Ein Fenster schließen"))]
    }
}

/// The marks on projects that Settings → Projects can reset.
enum ProjectMarks: String, CaseIterable, Identifiable {
    case pinned, notes, checkPaths, autoRollback, ignoredTriggers
    var id: String { rawValue }
    var title: String {
        switch self {
        case .pinned: return L("Pinned", "Angeheftet")
        case .notes: return L("Notes", "Notizen")
        case .checkPaths: return L("Check paths after going live", "Prüfpfade nach dem Live-Gang")
        case .autoRollback: return L("Roll back when the check fails", "Zurückrollen bei Fehler")
        case .ignoredTriggers: return L("Ignored build triggers", "Ignorierte Build-Auslöser")
        }
    }
    var question: String { L("Reset “\(title)” for every project?", "„\(title)“ bei allen Projekten zurücksetzen?") }
    @MainActor func count(_ store: Store, ignoredTriggers: String) -> Int {
        switch self {
        case .pinned: return store.pinned.count
        case .notes: return store.notes.count
        case .checkPaths: return store.healthPathCount
        case .autoRollback: return store.autoRollback.count
        case .ignoredTriggers: return ignoredTriggers.split(separator: "\n").count
        }
    }
}
