// App tests, round 15: config writes that notice a concurrent change, the "Let Claude deploy" switch.
// Called from tests/app/main.swift.

import AppKit

@MainActor func suite_round15_races() {
    let dir = FileManager.default.temporaryDirectory.appendingPathComponent("dc-r15-\(UUID().uuidString)").path
    try? FileManager.default.createDirectory(atPath: dir, withIntermediateDirectories: true)
    defer { try? FileManager.default.removeItem(atPath: dir) }
    let file = dir + "/c.json"
    let old = Data("{\"a\":1}".utf8), mine = Data("{\"a\":2}".utf8), theirs = Data("{\"b\":3}".utf8)
    FileManager.default.createFile(atPath: file, contents: old)
    expect("write if unchanged: same bytes writes", (try? ClaudeFiles.writeIfUnchanged(mine, to: file, from: old)) != nil && FileManager.default.contents(atPath: file) == mine, true)
    FileManager.default.createFile(atPath: file, contents: theirs)
    var threw = false
    do { try ClaudeFiles.writeIfUnchanged(mine, to: file, from: old) } catch is ClaudeFiles.Changed { threw = true } catch {}
    expect("write if unchanged: a change in between throws", threw, true)
    expect("write if unchanged: their content stays", FileManager.default.contents(atPath: file) == theirs, true)
    expect("write if unchanged: a new file from nil", (try? ClaudeFiles.writeIfUnchanged(mine, to: dir + "/n/c.json", from: nil)) != nil, true)

    expect("allow switch: stays on after a failed write", ClaudeLink.stillAllows(failed: true, desktopConnected: false, desktopAllows: false, codeConnected: false, codeAllows: false), true)
    expect("allow switch: stays on while the config allows", ClaudeLink.stillAllows(failed: false, desktopConnected: true, desktopAllows: true, codeConnected: false, codeAllows: false), true)
    expect("allow switch: off when nothing allows", ClaudeLink.stillAllows(failed: false, desktopConnected: true, desktopAllows: false, codeConnected: true, codeAllows: false), false)
    expect("allow switch: a stale flag of a disconnected side is ignored", ClaudeLink.stillAllows(failed: false, desktopConnected: false, desktopAllows: true, codeConnected: false, codeAllows: true), false)
}
