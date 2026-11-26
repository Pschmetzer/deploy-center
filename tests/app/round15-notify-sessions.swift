// App tests, round 15: neutral notification text, the sessions memory, short names in demo mode.
// Called from tests/app/main.swift.

import AppKit

@MainActor func suite_round15_notify_sessions() {
    let real = Notify.neutralText("Pull request waits: #4", "private-repo fix", failed: false, neutral: false)
    expect("neutral off keeps the text", real.title + "|" + real.body, "Pull request waits: #4|private-repo fix")
    let n = Notify.neutralText("Pull request waits: #4", "private-repo fix", failed: false, neutral: true)
    expect("neutral hides the title", n.title.contains("#4"), false)
    expect("neutral hides the body", n.body.contains("private-repo"), false)
    expect("neutral failure says a deploy needs a look", Notify.neutralText("x", "y", failed: true, neutral: true).title.isEmpty, false)

    let seen: Set<String> = ["a#1:merged", "b#2:merged"], live: Set<String> = ["a#1:merged"]
    expect("seen: pruned when all repos were read", SessionsNews.kept(seen: seen, live: live, complete: true), live)
    expect("seen: kept when a repo failed", SessionsNews.kept(seen: seen, live: live, complete: false), seen)

    let d = UserDefaults.standard, before = d.object(forKey: "demoMode")
    d.set(true, forKey: "demoMode"); defer { if let before { d.set(before, forKey: "demoMode") } else { d.removeObject(forKey: "demoMode") } }
    var ui = Item(id: "ui", name: "ui", detail: "", platform: .vercel, deployable: true, auto: false, note: nil, link: nil); ui.repo = nil
    expect("short name: whole word masked", Demo.scrub("ui failed", items: [ui]), "\(Demo.mask("ui")) failed")
    expect("short name: not cut out of other words", Demo.scrub("build quick", items: [ui]), "build quick")
}
