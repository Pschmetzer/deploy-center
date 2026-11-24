// App tests: repo links and the hover on a waiting row. Called from tests/app/main.swift.

import AppKit

@MainActor func suite_ux2() {
    expect("repo link: short", RepoLink.normalize("acme/shop") ?? "", "acme/shop")
    expect("repo link: url", RepoLink.normalize("https://github.com/acme/shop.git/") ?? "", "acme/shop")
    expect("repo link: ssh", RepoLink.normalize("git@github.com:acme/shop.git") ?? "", "acme/shop")
    expect("repo link: other host", RepoLink.normalize("https://gitlab.com/team/sub/shop") ?? "", "gitlab.com/team/sub/shop")
    expect("repo link: junk", RepoLink.normalize("hello world") == nil && RepoLink.normalize("shop") == nil && RepoLink.normalize("") == nil, true)
    expect("repo link: github needs owner and name", RepoLink.normalize("github.com/acme") == nil, true)
    let c = Details.Commit(sha: "a", full: nil, url: nil, msg: "m", author: "Ann", bot: nil, at: 1_700_000_000, pr: nil)
    let c2 = Details.Commit(sha: "b", full: nil, url: nil, msg: "m", author: "Ann", bot: nil, at: 1_700_000_100, pr: nil)
    let d = Details(commits: [c, c2], files: 3, additions: 10, deletions: 2, risky: [], onlyBots: false, compareUrl: nil, checks: nil, open: [])
    let hl = WaitingHover.lines(d)
    expect("hover: three lines", hl.count, 3)
    expect("hover: authors once", hl[0].contains("Ann") && !hl[0].contains("Ann, Ann"), true)
    expect("hover: files", hl[2].contains("+10"), true)

    let ledger = """
    {"since":"2026-11-01","days":10,"method":"x","total":{"skipped":7,"pushes":9,"builds":2,"usd":4.2,"builtUsd":1,"vercelMinutes":30,"renderMinutes":0,"usdComplete":false},
     "projects":[{"name":"a","platform":"vercel","skipped":4},{"name":"b","platform":"vercel","skipped":3},{"name":"c","platform":"vercel","skipped":0}]}
    """
    if let l = try? JSONDecoder().decode(LedgerReport.self, from: Data(ledger.utf8)) {
        let amount = SavingsDetail.amountLines(l)
        expect("savings popover: platform minutes and price", amount.count, 3)
        expect("savings popover: says which projects were skipped", SavingsDetail.skippedLines(l).count, 2)
        expect("savings popover: biggest first", SavingsDetail.skippedLines(l)[0].hasPrefix("a:"), true)
        expect("savings popover: incomplete price is said", amount[1].contains(L("no price", "Preis")), true)
    } else { expect("savings popover: ledger decodes", false, true) }
}
