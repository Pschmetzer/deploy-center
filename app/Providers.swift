// Deploy Center — Which platforms the window shows, and how its tabs are laid out.
// The list comes from `deploys providers --json`; a script without that command means Vercel and Render.
// Everything here is plain data and pure functions, so the tests can check it without a window.

import Foundation

/// What a provider can do, as `deploys providers --json` says. A missing field counts as "no".
struct ProviderCaps: Decodable, Equatable, Sendable {
    var off = false, sha = false, cancel = false, rollback = false, logs = false, preview = false

    init(off: Bool = false, sha: Bool = false, cancel: Bool = false, rollback: Bool = false, logs: Bool = false, preview: Bool = false) {
        self.off = off; self.sha = sha; self.cancel = cancel; self.rollback = rollback; self.logs = logs; self.preview = preview
    }
    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        func flag(_ k: CodingKeys) -> Bool { ((try? c.decodeIfPresent(Bool.self, forKey: k)) ?? nil) ?? false }
        off = flag(.off); sha = flag(.sha); cancel = flag(.cancel); rollback = flag(.rollback); logs = flag(.logs); preview = flag(.preview)
    }
    private enum CodingKeys: String, CodingKey { case off, sha, cancel, rollback, logs, preview }
}

/// One platform as the window knows it: enough for a tab and a switch in Settings.
/// Vercel and Render also have a `Platform`, which loads and deploys; a later provider only needs this.
struct ProviderInfo: Decodable, Identifiable, Equatable, Sendable {
    let id: String          // the script's name: "vercel", "render", …
    let label: String       // what the tab says: "Vercel"
    var enabled: Bool
    var caps: ProviderCaps
    /// The provider's status page as the script reports it (`statusPage`); see `statusURL`.
    var statusPage: String?

    init(id: String, label: String, enabled: Bool, caps: ProviderCaps = ProviderCaps(), statusPage: String? = nil) {
        self.id = id; self.label = label; self.enabled = enabled; self.caps = caps; self.statusPage = statusPage
    }
    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        let id = try c.decode(String.self, forKey: .id).lowercased()
        self.id = id
        let l = ((try? c.decodeIfPresent(String.self, forKey: .label)) ?? nil) ?? ""
        let fromId = id.prefix(1).uppercased() + String(id.dropFirst())
        label = l.isEmpty ? fromId : l
        enabled = ((try? c.decodeIfPresent(Bool.self, forKey: .enabled)) ?? nil) ?? false
        caps = ((try? c.decodeIfPresent(ProviderCaps.self, forKey: .caps)) ?? nil) ?? ProviderCaps()
        let page = ((try? c.decodeIfPresent(String.self, forKey: .statusPage)) ?? nil) ?? ""
        statusPage = page.hasPrefix("https://") ? page : nil
    }
    private enum CodingKeys: String, CodingKey { case id, label, enabled, caps, statusPage }

    /// The status page: the script's (https only), else the one the app knows for this provider.
    var statusURL: URL? { (statusPage ?? Self.knownStatusPages[id]).flatMap(URL.init(string:)) }
    /// The machine-readable status (Atlassian Statuspage, `/api/v2/status.json`); only for the known
    /// pages that have one, so a page of the script is linked but never fetched.
    var statusFeed: URL? { Self.statuspageHosted.contains(id) ? Self.knownStatusPages[id].flatMap { URL(string: $0 + "/api/v2/status.json") } : nil }
    static let knownStatusPages = ["vercel": "https://www.vercel-status.com", "render": "https://status.render.com",
                                   "netlify": "https://www.netlifystatus.com", "cloudflare": "https://www.cloudflarestatus.com",
                                   "digitalocean": "https://status.digitalocean.com", "amplify": "https://health.aws.amazon.com/health/status",
                                   "railway": "https://status.railway.com", "fly": "https://status.flyio.net"]
    private static let statuspageHosted: Set<String> = ["vercel", "render", "netlify", "cloudflare", "digitalocean"]
    /// The source hosts the status banner also watches, next to the platforms.
    static let gitHosts: [(label: String, page: String, feed: String)] = [
        ("GitHub", "https://www.githubstatus.com", "https://www.githubstatus.com/api/v2/status.json")]

    /// The app's own loader for this provider, if it has one.
    var platform: Platform? { Platform.allCases.first { $0.cli == id } }

    /// What an older script (without `deploys providers`) has: Vercel and Render, both on.
    static let builtIn: [ProviderInfo] = [
        ProviderInfo(id: "vercel", label: "Vercel", enabled: true,
                     caps: ProviderCaps(off: true, sha: true, cancel: true, rollback: true, logs: true, preview: true)),
        ProviderInfo(id: "render", label: "Render", enabled: true,
                     caps: ProviderCaps(off: true, sha: true, cancel: true, rollback: true, logs: true, preview: false)),
    ]

    /// What a platform is called ("DigitalOcean App Platform", not "Digitalocean"): the script's label
    /// when it reported one, then the providers it ships with, then the id with a capital.
    static func label(for id: String) -> String {
        let key = id.lowercased()
        labelLock.lock(); let seen = seenLabels[key]; labelLock.unlock()
        if let seen { return seen }
        if let k = known[key] { return k }
        return key.prefix(1).uppercased() + String(key.dropFirst())
    }
    static func remember(_ list: [ProviderInfo]) {
        labelLock.lock(); for p in list { seenLabels[p.id] = p.label }; labelLock.unlock()
    }
    private static let known = ["vercel": "Vercel", "render": "Render", "netlify": "Netlify", "cloudflare": "Cloudflare Pages",
                                "coolify": "Coolify", "digitalocean": "DigitalOcean App Platform", "amplify": "AWS Amplify Hosting"]
    private static let labelLock = NSLock()
    nonisolated(unsafe) private static var seenLabels: [String: String] = [:]

    /// Shown in Settings as "coming soon" until the script reports them.
    static let comingSoon: [ProviderInfo] = [
        ProviderInfo(id: "netlify", label: "Netlify", enabled: false),
        ProviderInfo(id: "cloudflare", label: "Cloudflare Pages", enabled: false),
        ProviderInfo(id: "railway", label: "Railway", enabled: false),
        ProviderInfo(id: "fly", label: "Fly.io", enabled: false),
    ]

    /// The answer of `deploys providers --json`, or the built-in two when there is none or it cannot be read.
    /// Returns whether the list came from the script, so Settings knows if switches can work.
    static func parse(_ data: Data?) -> (list: [ProviderInfo], fromScript: Bool) {
        guard let data, let all = try? JSONDecoder().decode([Lossy<ProviderInfo>].self, from: data) else { return (builtIn, false) }
        var seen = Set<String>()
        let list = all.compactMap(\.value).filter { !$0.id.isEmpty && seen.insert($0.id).inserted }
        return list.isEmpty ? (builtIn, false) : (ordered(list), true)
    }

    /// Vercel and Render first, as the window always had them (⌘1 Vercel, ⌘2 Render); the others
    /// after them in the script's order (it lists them alphabetically).
    static func ordered(_ list: [ProviderInfo]) -> [ProviderInfo] {
        let first = builtIn.map(\.id)
        func rank(_ p: ProviderInfo) -> Int { first.firstIndex(of: p.id) ?? first.count }
        return list.enumerated().sorted { a, b in
            rank(a.element) != rank(b.element) ? rank(a.element) < rank(b.element) : a.offset < b.offset
        }.map(\.element)
    }

    /// The providers the window shows. None switched on would leave an empty window: then the built-in two.
    static func enabled(_ all: [ProviderInfo]) -> [ProviderInfo] {
        let on = all.filter(\.enabled)
        return on.isEmpty ? builtIn : on
    }

    /// One row of Settings → Platforms.
    struct SettingsRow: Identifiable {
        let info: ProviderInfo
        /// Reported by the script (or built in): it can be switched. Otherwise "coming soon".
        let available: Bool
        var id: String { info.id }
    }

    /// The rows of Settings → Platforms: what the script reports, then the ones still to come.
    static func settingsRows(_ reported: [ProviderInfo]) -> [SettingsRow] {
        let ids = Set(reported.map(\.id))
        let soon = comingSoon.filter { !ids.contains($0.id) }
        return reported.map { SettingsRow(info: $0, available: true) } + soon.map { SettingsRow(info: $0, available: false) }
    }
}

/// How the header lets the person pick a platform.
enum TabLayout: Equatable {
    /// One platform: nothing to pick, no tabs.
    case hidden
    /// Two or three: a segmented control with "All" in front.
    case segmented
    /// Four and more: a menu, which stays one control wide.
    case menu

    static func decide(_ count: Int) -> TabLayout { count <= 1 ? .hidden : count <= 3 ? .segmented : .menu }
}

/// One choice in the header.
enum ProviderTab: Hashable {
    case all
    case provider(String)

    /// The choices for these providers, in order: "All" first when there is more than one.
    static func tabs(_ providers: [ProviderInfo]) -> [ProviderTab] {
        let each = providers.map { ProviderTab.provider($0.id) }
        return TabLayout.decide(providers.count) == .hidden ? each : [.all] + each
    }

    /// ⌘1, ⌘2 … for the providers in order, the next digit for "All" (⌘3 with Vercel and Render,
    /// as before). Only digits 1–9; a choice past them has none.
    static func shortcuts(_ tabs: [ProviderTab]) -> [ProviderTab: Int] {
        let providers = tabs.filter { $0 != .all }
        var out: [ProviderTab: Int] = [:]
        for (n, t) in providers.enumerated() where n < 9 { out[t] = n + 1 }
        if tabs.contains(.all), providers.count < 9 { out[.all] = providers.count + 1 }
        return out
    }

    /// The tab to show: the remembered one when it still exists, else the first provider.
    static func resolve(_ remembered: ProviderTab, in tabs: [ProviderTab]) -> ProviderTab {
        if tabs.contains(remembered) { return remembered }
        return tabs.first { $0 != .all } ?? .all
    }
}

/// Rows of one repo, shown under a small header when there are several.
struct RepoGroup: Identifiable {
    let id: String
    let repo: String?
    let items: [Item]
    /// A header for one row would only repeat the row.
    var showsHeader: Bool { repo != nil && items.count > 1 }

    /// Moves every row of a repo up to the first row of that repo, keeping the order otherwise.
    static func cluster(_ rows: [Item]) -> [Item] {
        var order: [String] = [], byKey: [String: [Item]] = [:]
        for (n, i) in rows.enumerated() {
            let k = i.repo.map { "repo:" + $0 } ?? "row:\(n)"
            if byKey[k] == nil { order.append(k) }
            byKey[k, default: []].append(i)
        }
        return order.flatMap { byKey[$0] ?? [] }
    }

    /// Next rows of the same repo, one group each; rows without a repo stand alone.
    static func groups(_ rows: [Item]) -> [RepoGroup] {
        var out: [RepoGroup] = []
        var current: [Item] = []
        func close() {
            guard let first = current.first else { return }
            out.append(RepoGroup(id: "\(first.platform.cli)/\(first.id)", repo: first.repo, items: current))
            current = []
        }
        for i in rows {
            if let last = current.last, let r = i.repo, r == last.repo { current.append(i) } else { close(); current = [i] }
        }
        close()
        return out
    }
}

extension Costs {
    /// Average build cost per day before auto-deploy was turned off and since, whole days only.
    /// `today` is not over yet: a half day would make "since" look cheaper than it is.
    func saving(today: String) -> (before: Double, after: Double, days: Int)? {
        guard let off = offDay else { return nil }
        let before = days.filter { $0.day < off }, after = days.filter { $0.day > off && $0.day < today }
        guard !before.isEmpty, !after.isEmpty else { return nil }
        return (before.map(\.build).reduce(0, +) / Double(before.count), after.map(\.build).reduce(0, +) / Double(after.count), after.count)
    }

    /// What the whole days since auto-deploy went off cost less than before; nil when unknown or none.
    func saved(today: String) -> Double? {
        guard let s = saving(today: today) else { return nil }
        let v = (s.before - s.after) * Double(s.days)
        return v >= 0.5 ? v : nil
    }

    /// Build costs of the last 7 days.
    var week: Double { days.suffix(7).map(\.build).reduce(0, +) }
}

/// "1 project", "3 projects": the number with the word that fits it.
func plural(_ n: Int, _ one: String, _ many: String) -> String { "\(n) \(n == 1 ? one : many)" }

/// "12 PRs waiting · $41 saved": what waits, and the saving when it is known.
func summaryLine(_ w: Store.Waiting, saved: Double?) -> String {
    let waiting: String
    if w.projects == 0 {
        waiting = L("Everything merged is live", "Alles Gemergte ist live")
    } else if w.prs > 0 {
        waiting = L("\(w.prs) \(w.prs == 1 ? "PR" : "PRs") waiting", "\(w.prs) \(w.prs == 1 ? "PR wartet" : "PRs warten")")
    } else {
        waiting = L("\(w.projects) \(w.projects == 1 ? "project" : "projects") waiting", "\(w.projects) \(w.projects == 1 ? "Projekt wartet" : "Projekte warten")")
    }
    guard let saved else { return waiting }
    return waiting + " · " + L("\(usd0(saved)) saved", "\(usd0(saved)) gespart")
}

/// Whole dollars, as a person says it: "$41".
func usd0(_ v: Double) -> String { v.formatted(.currency(code: "USD").precision(.fractionLength(0))) }

// MARK: - The store's side

extension Store {
    /// The providers the window shows, in the script's order.
    var enabledProviders: [ProviderInfo] { ProviderInfo.enabled(providers) }
    func isEnabled(_ p: Platform) -> Bool { enabledProviders.contains { $0.id == p.cli } }
    func provider(_ p: Platform) -> ProviderInfo? { providers.first { $0.id == p.cli } }

    /// Asks the script which providers exist and which are on. An older script has no such
    /// command: then it is Vercel and Render, as before.
    func loadProviders() async {
        let data = try? await Tool.run(["providers", "--json"], timeout: 20)
        // A slow or failed answer after a good one keeps that list: falling back to Vercel and
        // Render would switch a platform the person turned off back on.
        if data == nil, providersFromScript { return }
        let r = ProviderInfo.parse(data)
        ProviderInfo.remember(r.list)
        // Remembered for the next start, so the saved lists of a switched-off platform are not shown first.
        UserDefaults.standard.set(r.list.filter { !$0.enabled }.map(\.id), forKey: "disabledProviders")
        if providers != r.list { providers = r.list }
        providersFromScript = r.fromScript
        // A platform switched off keeps no rows: it would still count as waiting.
        for p in Platform.allCases where !isEnabled(p) && !(items[p] ?? []).isEmpty { items[p] = [] }
    }

    /// Switches a provider on or off with `deploys providers enable|disable`; an error text when it failed.
    func setProvider(_ id: String, on: Bool) async -> String? {
        do { _ = try await Tool.run(["providers", on ? "enable" : "disable", id], timeout: 30) }
        catch { return error.localizedDescription }
        await loadProviders()
        // Read again with the checks of a start, so a missing login shows its setup screen.
        if on, Platform.allCases.contains(where: { $0.cli == id }) { await start() }
        return nil
    }
}
