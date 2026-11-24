// App tests: UX polish (menu bar summary, Claude hint). Called from tests/app/main.swift.

import AppKit

@MainActor func suite_ux() {
    expect("menu bar: both", MenuBarSummary.text(waiting: 5, failed: 2) ?? "", L("5 waiting, 2 failed", "5 warten, 2 fehlgeschlagen"))
    expect("menu bar: only failed", MenuBarSummary.text(waiting: 0, failed: 1) ?? "", L("1 failed", "1 fehlgeschlagen"))
    expect("menu bar: nothing", MenuBarSummary.text(waiting: 0, failed: 0) == nil, true)
    var bad = Item(id: "f", name: "f", detail: "", platform: .vercel, deployable: true, auto: false, note: nil, link: nil)
    bad.lastAt = Date(); bad.lastState = "ERROR"
    var ok = bad; ok = Item(id: "o", name: "o", detail: "", platform: .vercel, deployable: true, auto: false, note: nil, link: nil)
    expect("menu bar: failed rows", MenuBarSummary.failed([bad, ok], hidden: { _ in false }).map(\.id), ["f"])
    expect("menu bar: a hidden one is left out", MenuBarSummary.failed([bad], hidden: { _ in true }).isEmpty, true)
    expect("claude hint: shown when wanted", ClaudeNudge.visible(wanted: true, dismissed: false), true)
    expect("claude hint: never after the X", ClaudeNudge.visible(wanted: true, dismissed: true), false)
    expect("claude hint: not when nothing to connect", ClaudeNudge.visible(wanted: false, dismissed: false), false)
    expect("claude hint: says what connecting gives", ClaudeNudge.message.contains(L("build logs", "Build-Logs")), true)
}
