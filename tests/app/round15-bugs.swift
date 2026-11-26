// App tests, round 15: small fixes found by reading. Called from tests/app/main.swift.

import AppKit

@MainActor func suite_round15_bugs() {
    expect("speech: one project waits", Speech.summary(waiting: 1, failed: 0, running: 0), L("1 project waits.", "1 Projekt wartet."))
    expect("speech: one running", Speech.summary(waiting: 0, failed: 0, running: 1), L("1 running.", "1 läuft."))
    expect("speech: two", Speech.summary(waiting: 2, failed: 1, running: 2), L("2 projects wait, 1 failed, 2 running.", "2 Projekte warten, 1 fehlgeschlagen, 2 laufen."))

    expect("paths: a comma in a query stays", Store.cleanPaths("/search?q=a,b"), ["/search?q=a,b"])
    expect("paths: comma and slash separates", Store.cleanPaths("/health,/ping"), ["/health", "/ping"])
    expect("paths: one per line", Store.cleanPaths("/a\n/b"), ["/a", "/b"])
    expect("paths: more than five are cut to five", Store.cleanPaths("/1, /2, /3, /4, /5, /6").count, 5)
    expect("links: a link with a path and query", Store.checkLinks("https://x.app/de?x=1", ["/health"]), ["https://x.app/health"])
    expect("links: a fragment", Store.checkLinks("https://x.app/#top", ["/health"]), ["https://x.app/health"])
    expect("links: no paths keeps the link", Store.checkLinks("https://x.app/de?x=1", []), ["https://x.app/de?x=1"])

    expect("search: a tab separates operators", SearchQuery.has("shop\tfailed", "failed"), true)
    expect("search: a no-break space separates operators", SearchQuery.has("shop\u{00A0}failed", "failed"), true)
    expect("search: toggled off with a tab", SearchQuery.toggled("shop\tfailed", "failed"), "shop")

    expect("journal: NaN does not trap", Journal.safeInt(.nan), 0)
    expect("journal: huge value is capped", Journal.safeInt(1e300) > 0, true)
    expect("journal: negative is floored", Journal.safeInt(-5), 0)

    let rows = Spotlight.entries([(key: "a/x", name: "one\ttwo", platform: "vercel")])
    expect("spotlight: a tab in a name keeps three fields", rows[0].split(separator: "\t", omittingEmptySubsequences: false).count, 3)

    expect("causes: key has the platform", FailureCauses.key(platform: "render", name: "shop"), "render/shop")
    expect("causes: name of a key", FailureCauses.name(of: "render/shop"), "shop")
    let d = UserDefaults(suiteName: "dc-r15-causes-\(UUID().uuidString)")!
    let now = Date()
    FailureCauses.record(project: "vercel/shop", cause: "lockfile", now: now, d)
    FailureCauses.record(project: "render/shop", cause: "memory", now: now, d)
    expect("causes: same name on two hosts stays two", FailureCauses.current(failed: ["vercel/shop", "render/shop"], d, now: now).count, 2)

    var noRef = item(); noRef.ref = nil; noRef.headSha = nil; noRef.changed = true
    expect("compare link: no ref and no head, no link", noRef.compareURL == nil, true)
    var priv = item(.render, kind: "private_service")
    priv = Item(id: "srv-1", name: "api", detail: "", platform: .render, deployable: true, auto: false, note: nil, link: nil); priv.kind = "private_service"
    expect("dashboard: a private service has its own section", priv.dashboardURL?.absoluteString ?? "", "https://dashboard.render.com/pserv/srv-1")
}
