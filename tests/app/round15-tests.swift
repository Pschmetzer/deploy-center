// App tests, round 15: Accounts, sessions news, Nightly texts, log groups, deploy window dates, filters.
// Called from tests/app/main.swift.

import AppKit

/// A keychain stand-in: a dictionary.
final class FakeSecrets: SecretStore {
    var store: [String: String] = [:]
    func read(service: String, account: String) -> String? { store[service + "|" + account] }
    func write(_ secret: String, service: String, account: String) -> Bool { store[service + "|" + account] = secret; return true }
    func delete(service: String, account: String) { store[service + "|" + account] = nil }
}

@MainActor func suite_round15_tests() {
    // Accounts
    let d = UserDefaults(suiteName: "dc-r15-accounts-\(UUID().uuidString)")!
    let fake = FakeSecrets()
    expect("label: plain", Accounts.cleanLabel("  Work ") ?? "nil", "Work")
    expect("label: a key as a name is refused", Accounts.cleanLabel("sk-ant-abc/def") == nil, true)
    expect("label: too long", Accounts.cleanLabel(String(repeating: "a", count: 41)) == nil, true)
    expect("key: spaces refused", Accounts.cleanKey("a b") == nil, true)
    expect("key: quote refused", Accounts.cleanKey("a'b") == nil, true)
    expect("add: first account", Accounts.add(host: "render", label: "Work", key: "rnd_1", secrets: fake, d), true)
    expect("add: same label refused", Accounts.add(host: "render", label: "Work", key: "rnd_2", secrets: fake, d), false)
    expect("add: key reaches the store only", fake.store.values.contains("rnd_1") && !(d.dictionaryRepresentation().description.contains("rnd_1")), true)
    expect("names", Accounts.names("render", d), ["Work"])
    expect("key read back", Accounts.key(host: "render", label: "Work", secrets: fake) ?? "nil", "rnd_1")
    Accounts.markActive(host: "render", label: "Work", d)
    expect("active", Accounts.active("render", d) ?? "nil", "Work")
    Accounts.markActive(host: "render", label: "Nobody", d)
    expect("active: an unknown label is ignored", Accounts.active("render", d) ?? "nil", "Work")
    Accounts.remove(host: "render", label: "Work", secrets: fake, d)
    expect("remove: gone from names, store and active", Accounts.names("render", d).isEmpty && fake.store.isEmpty && Accounts.active("render", d) == nil, true)

    // Sessions news
    func row(_ branch: String, _ state: String, repo: String = "me/app", title: String? = nil, pr: Int? = nil) -> SessionsReport.Row {
        SessionsReport.Row(repo: repo, branch: branch, state: state, title: title, pr: pr, url: nil, session: nil, began: nil, ended: nil, minutes: nil, idleMinutes: nil)
    }
    let rows = [row("claude/a", "merged"), row("claude/b", "open"), row("claude/c", "waiting", pr: 7), row("claude/d", "stuck")]
    expect("news: told states only", SessionsNews.fresh(rows, seen: []).map(\.branch), ["claude/a", "claude/c", "claude/d"])
    expect("news: a seen key is not news", SessionsNews.fresh(rows, seen: [SessionsNews.key(rows[0])]).map(\.branch), ["claude/c", "claude/d"])
    expect("news: a new state of a seen branch is news", SessionsNews.fresh([row("claude/c", "merged")], seen: [SessionsNews.key(rows[2])]).count, 1)
    let notes = SessionsNews.notes(SessionsNews.fresh(rows, seen: []), hold: 30)
    expect("news: finished ones are one note, the others one each", notes.count, 3)
    let two = SessionsNews.notes([row("claude/x", "merged"), row("claude/y", "closed")], hold: 30)
    expect("news: two done is one note with a plural", two.count == 1 && two[0].title.contains("2"), true)
    let one = SessionsNews.notes([row("claude/x", "merged")], hold: 30)
    expect("news: one done has no number", one[0].title.contains("1"), false)

    // Nightly
    expect("nightly: weekday", NightlySettings.weekday(1), L("Monday", "Montag"))
    expect("nightly: weekday is clamped", NightlySettings.weekday(99), L("Sunday", "Sonntag"))
    expect("nightly: the minutes stay", NightlySettings.timeText(hour: 4, keeping: "03:30"), "04:30")
    expect("nightly: no old time", NightlySettings.timeText(hour: 4, keeping: nil), "04:00")
    expect("nightly: junk minutes", NightlySettings.timeText(hour: 4, keeping: "03:99"), "04:00")

    // Log groups
    expect("signature: numbers, paths and hashes go", LogGroups.signature("Error at /src/a.ts:12 in abcdef1234"), LogGroups.signature("Error at /lib/b.ts:99 in 0123456789ab"))
    let logs: [(project: String, text: String)] = [("a", "ok\nError: cannot find module 'x' at /a/1\n"), ("b", "Error: cannot find module 'x' at /b/2"), ("c", "all fine")]
    let groups = LogGroups.group(logs)
    expect("groups: same failure is one group of two", groups.count == 1 && groups[0].projects == ["a", "b"], true)
    let many = (1...30).map { "line \($0) timeout" }.joined(separator: "\n")
    expect("search: at most 20 hits per project", LogGroups.search("timeout", in: [("a", many)]).count, 20)
    expect("search: every word", LogGroups.search("line timeout", in: [("a", "line 1 timeout\nline 2")]).count, 1)
    expect("search: empty query", LogGroups.search("  ", in: [("a", "x")]).count, 0)

    // Deploy window dates
    expect("window date: valid", DeployWindowConfig.validDate("2026-12-24"), true)
    expect("window date: no such day", DeployWindowConfig.validDate("2026-02-30"), false)
    expect("window date: not padded", DeployWindowConfig.validDate("2026-1-5"), false)
    expect("window date: text", DeployWindowConfig.validDate("tomorrow"), false)
    var bad = DeployWindowConfig(); bad.deny = [.init(dates: ["24.12.2026"])]
    expect("window: a bad date is a problem", bad.problem != nil, true)
    var good = DeployWindowConfig(); good.deny = [.init(dates: ["2026-12-24"], from: "22:00", to: "06:00")]
    expect("window: a night window with a date is fine", good.problem == nil, true)
}
