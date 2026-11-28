// The "Today" widget's part of the snapshot: what it counts, what it leaves unknown, the day it belongs to.
import Foundation

func suite_today() {
    let dec = JSONDecoder()
    var cal = Calendar(identifier: .gregorian); cal.timeZone = TimeZone(identifier: "Europe/Berlin")!
    let noon = cal.date(from: DateComponents(year: 2026, month: 11, day: 28, hour: 12))!
    let yesterday = noon.addingTimeInterval(-86_400)

    // Old snapshots (no "today") still decode; one with it survives a round trip; the gallery sample has one.
    let old = #"{"version":1,"at":"2026-11-28T10:00:00Z","demo":false,"waitingProjects":0,"waitingCommits":0,"waitingPRs":0,"building":0,"failed":0,"projects":[]}"#
    let oldSnap = try? DeploySnapshot.decoder.decode(DeploySnapshot.self, from: Data(old.utf8))
    expect("today: an old snapshot decodes", oldSnap != nil, true)
    expect("today: an old snapshot has no today", oldSnap?.today == nil, true)
    let sample = DeploySnapshot.sample
    expect("today: the sample has today", sample.today != nil, true)
    let data = (try? DeploySnapshot.encoder.encode(sample)) ?? Data()
    expect("today: round trip", (try? DeploySnapshot.decoder.decode(DeploySnapshot.self, from: data))?.today == sample.today, true)

    // sameContent ignores the time but sees a change of today's numbers (the old copy dropped new fields).
    var later = sample; later.at = sample.at.addingTimeInterval(60)
    expect("today: same content apart from the time", sample.sameContent(as: later), true)
    later.today?.mac = .init(level: "red", freeGB: 2)
    expect("today: a new Mac level is new content", sample.sameContent(as: later), false)

    // The journal of today: live, rollback and forced count as live; failed as failed; other days and previews not.
    func entry(_ at: Date, _ result: String) -> JournalEntry { JournalEntry(at: at, platform: "Vercel", name: "app", result: result, seconds: 30, detail: nil) }
    let journal = [entry(noon, "live"), entry(noon, "rollback"), entry(noon, "forced"), entry(noon, "failed"),
                   entry(noon, "preview"), entry(noon, "skipped"), entry(yesterday, "live"), entry(yesterday, "failed")]
    let d = TodaySummary.deploys(journal, now: noon, calendar: cal)
    expect("today: deploys live today", d.live, 3)
    expect("today: deploys failed today", d.failed, 1)

    // The sources: desktop sessions (all accounts), cloud sessions, PRs, the load guard.
    let desktop = try! dec.decode(DesktopSessionsSnapshot.self, from: Data("""
    {"totals":{"accounts":2,"open":9,"done":3,"waiting":2,"running":4,"stopped":1,"accountsWithDone":1},
     "accounts":[{"id":"a1","label":"Work","active":true,"open":5,"done":2,"waiting":1,"running":2,"stopped":1,"sessions":[
        {"id":"s1","title":"Fix login","folder":"app","state":"waiting","idleHours":1,"prs":[],"stopReason":null,"stopKey":null,"stopNote":null,"openUrl":"claude://x"},
        {"id":"s2","title":"","folder":"site","state":"stopped","idleHours":1,"prs":[],"stopReason":"limit","stopKey":"k","stopNote":null,"openUrl":"claude://y"},
        {"id":"s3","title":"Busy","folder":"api","state":"running","idleHours":0,"prs":[],"stopReason":null,"stopKey":null,"stopNote":null,"openUrl":"claude://z"}]},
      {"id":"a2","label":"Home","active":false,"open":4,"done":1,"waiting":1,"running":2,"stopped":0,"sessions":[]}]}
    """.utf8))
    let cloud = try! dec.decode(SessionsReport.self, from: Data("""
    {"settings":{"prefix":"claude/","wait":30,"idle":45,"hours":24},"repos":["me/app"],"errors":[],
     "summary":{"merged":2,"mergedLastHour":1,"open":5,"waiting":1,"stuck":1,"closed":0},
     "sessions":[{"repo":"me/app","branch":"claude/x","state":"stuck","title":"Slow job","idleMinutes":50}]}
    """.utf8))
    let prs = try! dec.decode(PRsReport.self, from: Data("""
    {"summary":{"open":4,"conflicts":1,"mergedToday":7},"conflicts":[{"repo":"me/app","pr":42,"title":"New page","state":"conflict"}],"errors":[]}
    """.utf8))
    let failed = [DeploySnapshot.Project(name: "web", platform: "Render", status: .failed, commits: 1, prs: 0, since: nil, message: nil)]
    let mem = try! dec.decode(TodaySummary.Memory.self, from: Data(#"{"time":1,"memory":{"totalMB":49152,"freePct":43}}"#.utf8))
    expect("today: free memory in whole GB", mem.freeGB ?? -1, 21)

    let t = TodaySummary.make(now: noon, calendar: cal, desktop: desktop, cloud: cloud, prs: prs, level: "red", memory: mem,
                              journal: journal, failed: failed, demo: false, mask: { $0 })
    expect("today: the day is the start of today", t.day == cal.startOfDay(for: noon), true)
    expect("today: sessions summed over all accounts", [t.sessions?.running ?? -1, t.sessions?.waiting ?? -1, t.sessions?.done ?? -1, t.sessions?.stopped ?? -1], [4, 2, 3, 1])
    expect("today: cloud sessions", [t.sessions?.cloudOpen ?? -1, t.sessions?.cloudStuck ?? -1], [5, 1])
    expect("today: PRs merged today and in conflict", [t.prs?.mergedToday ?? -1, t.prs?.conflicts ?? -1], [7, 1])
    expect("today: the Mac", "\(t.mac?.level ?? "")/\(t.mac?.freeGB ?? -1)", "red/21")
    expect("today: attention, most urgent first", t.attention.map(\.kind.rawValue), ["failed", "mac", "conflict", "waiting", "stopped", "stuck"])
    expect("today: a session without a title shows its folder", t.attention.first { $0.kind == .stopped }?.title ?? "", "site")
    expect("today: the conflict names repo and PR", t.attention.first { $0.kind == .conflict }?.title ?? "", "me/app#42")

    // Nothing known is not zero: switched-off sources stay nil; an unknown level is no Mac at all.
    let none = TodaySummary.make(now: noon, calendar: cal, desktop: nil, cloud: nil, prs: nil, level: "unknown", memory: nil,
                                 journal: [], failed: [], demo: false, mask: { $0 })
    expect("today: no sources, no sessions", none.sessions == nil, true)
    expect("today: no sources, no PRs", none.prs == nil, true)
    expect("today: an unknown level is not shown", none.mac == nil, true)
    expect("today: an empty journal is zero deploys", "\(none.deploys?.live ?? -1)/\(none.deploys?.failed ?? -1)", "0/0")
    let broken = try! dec.decode(PRsReport.self, from: Data(#"{"summary":{"mergedToday":3},"errors":[{"error":"gh"}]}"#.utf8))
    expect("today: a PR report with errors is unknown", TodaySummary.make(now: noon, calendar: cal, desktop: nil, cloud: nil, prs: broken, level: nil,
                                                                         memory: nil, journal: [], failed: [], demo: false).prs == nil, true)

    // Demo mode: account labels and PR titles do not leave.
    let demo = TodaySummary.make(now: noon, calendar: cal, desktop: desktop, cloud: nil, prs: prs, level: "green", memory: nil,
                                 journal: [], failed: [], demo: true, mask: { "X-" + $0 })
    expect("today: demo hides the account label", demo.attention.contains { $0.detail.contains("Work") }, false)
    expect("today: demo hides the PR title", demo.attention.contains { $0.detail.contains("New page") }, false)
    expect("today: demo masks the names", demo.attention.first { $0.kind == .waiting }?.title ?? "", "X-Fix login")

    // At most eight items; and the numbers end at midnight.
    let many = (0..<12).map { DeploySnapshot.Today.Item(kind: .waiting, title: "s\($0)", detail: "") }
    expect("today: at most eight items", DeploySnapshot.Today.sorted(many).count, 8)
    expect("today: today's numbers count today", t.current(at: noon, calendar: cal) != nil, true)
    expect("today: yesterday's numbers are unknown", t.current(at: noon.addingTimeInterval(86_400), calendar: cal) == nil, true)
    let midnight = WidgetRefresh.nextMidnight(after: noon, calendar: cal)
    expect("today: next midnight", midnight == cal.startOfDay(for: noon.addingTimeInterval(86_400)), true)
    expect("today: just before midnight", WidgetRefresh.nextMidnight(after: midnight.addingTimeInterval(-1), calendar: cal) == midnight, true)
}
