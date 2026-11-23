// App tests: palette-settings. Called from tests/app/main.swift.

import AppKit

@MainActor func suite_palette_settings() {
    // The command palette's fuzzy search.
    expect("fuzzy: letters in order", fuzzyScore("dpl", "deploy app") != nil, true)
    expect("fuzzy: letters missing", fuzzyScore("xyz", "deploy app") == nil, true)
    expect("fuzzy: wrong order", fuzzyScore("ba", "abc") == nil, true)
    expect("fuzzy: empty query matches", fuzzyScore("  ", "anything") ?? -1, 0)
    expect("fuzzy: case and accents", fuzzyScore("UBER zuruck", "Über – zurückrollen") != nil, true)
    expect("fuzzy: word starts beat the middle", (fuzzyScore("sa", "shop-api") ?? 0) > (fuzzyScore("sa", "visa") ?? 0), true)
    expect("fuzzy: a whole word beats scattered letters",
           (fuzzyScore("log", "log shop") ?? 0) > (fuzzyScore("log", "lots of good") ?? 0), true)
    expect("fuzzy: shorter wins a tie", (fuzzyScore("open", "open a") ?? 0) > (fuzzyScore("open", "open abc") ?? 0), true)
    let paletteEntries: [(id: String, texts: [String])] = [
        ("reload", ["Reload", "Neu laden"]), ("deploy|a", ["deploy alpha"]), ("deploy|b", ["deploy bravo"]), ("log|a", ["log alpha"])]
    expect("palette: recent first without a query",
           paletteOrder(query: "", entries: paletteEntries, recent: ["log|a", "gone", "deploy|b", "log|a"]),
           ["log|a", "deploy|b", "reload", "deploy|a"])
    expect("palette: only matches", paletteOrder(query: "alp", entries: paletteEntries, recent: []), ["log|a", "deploy|a"])
    expect("palette: the other language", paletteOrder(query: "neu", entries: paletteEntries, recent: []), ["reload"])
    expect("palette: a recent one ahead of an equal match",
           paletteOrder(query: "deploy", entries: paletteEntries, recent: ["deploy|b"]).prefix(2).joined(separator: ","), "deploy|b,deploy|a")
    expect("palette: best match first", paletteOrder(query: "log", entries: paletteEntries, recent: []).first ?? "", "log|a")

    // Settings > Claude: config merge and unmerge never touch other entries.
    do {
        func js(_ s: String) -> Data { Data(s.utf8) }
        func obj(_ d: Data?) -> NSDictionary { (try? JSONSerialization.jsonObject(with: d ?? Data())) as? NSDictionary ?? [:] }
        let entry = ClaudeConfig.desktopEntry(node: "/opt/n/node", server: "/A B/server.mjs", deploys: "/A B/deploys", allowDeploy: false)
        let fixture = js(#"{"mcpServers":{"other":{"command":"x","args":["a/b"],"env":{"K":"v"}}},"preferences":{"on":true,"off":false,"n":null,"f":1.5,"i":3,"u":"Grüße ✓","url":"https://a/b"}}"#)

        let merged = try ClaudeConfig.merge(fixture, entry: entry)
        let m = obj(merged)
        expect("merge keeps other entry", (m["mcpServers"] as? NSDictionary)?["other"] as? NSDictionary == (obj(fixture)["mcpServers"] as? NSDictionary)?["other"] as? NSDictionary, true)
        expect("merge keeps other keys", m["preferences"] as? NSDictionary == obj(fixture)["preferences"] as? NSDictionary, true)
        expect("merge adds entry", ClaudeConfig.entry(merged)?["command"] as? String ?? "", "/opt/n/node")
        expect("merge sets DEPLOYS_BIN", (ClaudeConfig.entry(merged)?["env"] as? [String: Any])?["DEPLOYS_BIN"] as? String ?? "", "/A B/deploys")
        expect("deploy off by default", ClaudeConfig.allowsDeploy(ClaudeConfig.entry(merged)), false)
        expect("slashes not escaped", String(decoding: merged, as: UTF8.self).contains(#"https://a/b"#), true)
        let again = try ClaudeConfig.merge(merged, entry: ClaudeConfig.desktopEntry(node: "/n", server: "/s", deploys: "/d", allowDeploy: true))
        expect("merge replaces, not duplicates", ((obj(again)["mcpServers"] as? NSDictionary)?.count ?? 0), 2)
        expect("allow deploy written", ClaudeConfig.allowsDeploy(ClaudeConfig.entry(again)), true)

        // IDEEN-11 188: hand-added env variables and args survive a reconnect; the allow switch follows the new entry.
        let custom = js(#"{"mcpServers":{"deploy-center":{"command":"/o","args":["/s","--x"],"env":{"DEPLOYS_BIN":"/o","DEPLOYS_CONFIG":"/c","DEPLOYS_MCP_ALLOW_DEPLOY":"1"},"type":"stdio"}}}"#)
        let keep = ClaudeConfig.entry(try ClaudeConfig.merge(custom, entry: entry))
        expect("merge keeps a custom env variable", (keep?["env"] as? [String: Any])?["DEPLOYS_CONFIG"] as? String ?? "", "/c")
        expect("merge keeps more args", keep?["args"] as? [String] ?? [], ["/A B/server.mjs", "--x"])
        expect("merge keeps other keys", keep?["type"] as? String ?? "", "stdio")
        expect("merge drops the allow switch when off", ClaudeConfig.allowsDeploy(keep), false)
        let back = try ClaudeConfig.unmerge(merged)
        expect("unmerge restores the original", obj(back) == obj(fixture), true)
        let alone = try ClaudeConfig.merge(js(#"{"a":[1,true]}"#), entry: entry)
        expect("unmerge of the only entry leaves no empty mcpServers", obj(try ClaudeConfig.unmerge(alone)) == obj(js(#"{"a":[1,true]}"#)), true)
        expect("unmerge of absent entry writes nothing", try ClaudeConfig.unmerge(fixture) == nil, true)
        expect("unmerge of missing file writes nothing", try ClaudeConfig.unmerge(nil) == nil, true)

        expect("missing file gets mcpServers", (obj(try ClaudeConfig.merge(nil, entry: entry))["mcpServers"] as? NSDictionary)?.allKeys.count ?? 0, 1)
        expect("empty file gets mcpServers", ClaudeConfig.entry(try ClaudeConfig.merge(js("  \n"), entry: entry)) != nil, true)
        expect("file without mcpServers", ClaudeConfig.entry(try ClaudeConfig.merge(js(#"{"a":1}"#), entry: entry)) != nil, true)
        func refuses(_ s: String) -> String {
            do { _ = try ClaudeConfig.merge(js(s), entry: entry); return "wrote" } catch { return "\(error)" }
        }
        expect("invalid JSON is refused", refuses(#"{"mcpServers": {"#), "invalidJSON")
        expect("array top level is refused", refuses("[1,2]"), "notAnObject")
        expect("mcpServers not an object is refused", refuses(#"{"mcpServers":[1]}"#), "serversNotAnObject")
        expect("unmerge refuses invalid JSON", (try? ClaudeConfig.unmerge(js("{nope"))) == nil, true)

        expect("claude mcp add", ClaudeConfig.codeAddArgs(node: "/n", server: "/s", deploys: "/d", allowDeploy: false).joined(separator: " "),
               "mcp add -e DEPLOYS_BIN=/d --transport stdio --scope user deploy-center -- /n /s")
        expect("claude mcp add with deploy", ClaudeConfig.codeAddArgs(node: "/n", server: "/s", deploys: "/d", allowDeploy: true).joined(separator: " "),
               "mcp add -e DEPLOYS_BIN=/d -e DEPLOYS_MCP_ALLOW_DEPLOY=1 --transport stdio --scope user deploy-center -- /n /s")
        expect("claude mcp remove", ClaudeConfig.codeRemoveArgs().joined(separator: " "), "mcp remove deploy-center --scope user")

        // Files: backup, same mode, symlink kept, new file 600.
        let dir = FileManager.default.temporaryDirectory.appendingPathComponent("dc-claude-\(UUID().uuidString)").path
        try FileManager.default.createDirectory(atPath: dir, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(atPath: dir) }
        let file = dir + "/c.json", link = dir + "/link.json"
        FileManager.default.createFile(atPath: file, contents: fixture, attributes: [.posixPermissions: 0o640])
        try FileManager.default.createSymbolicLink(atPath: link, withDestinationPath: file)
        let bak = try ClaudeFiles.write(merged, to: link)
        func mode(_ p: String) -> Int { ((try? FileManager.default.attributesOfItem(atPath: p))?[.posixPermissions] as? NSNumber)?.intValue ?? -1 }
        expect("write keeps the mode", mode(file), 0o640)
        expect("backup has the old content", bak.map { FileManager.default.contents(atPath: $0) == fixture } ?? false, true)
        expect("backup is private (600), whatever the original mode (IDEEN-11 209)", bak.map(mode) ?? -1, 0o600)
        expect("symlink stays a symlink", (try? FileManager.default.destinationOfSymbolicLink(atPath: link)) == file, true)
        expect("written through the link", FileManager.default.contents(atPath: file) == merged, true)
        expect("no temp file left", (try FileManager.default.contentsOfDirectory(atPath: dir)).filter { $0.hasSuffix(".tmp") }.count, 0)
        let fresh = dir + "/new/c.json"
        expect("new file has no backup", try ClaudeFiles.write(merged, to: fresh) == nil, true)
        expect("new file is 600", mode(fresh), 0o600)
    } catch { expect("claude config tests ran", "\(error)", "no error") }

    // The palette in observer mode: like the window, nothing that deploys or rolls back.
    MainActor.assumeIsolated {
        let st = Store()
        st.items[.vercel] = [item(changed: true, commits: 1)]
        let normal = PaletteCommands.all(st).map(\.id)
        expect("palette offers deploy, rollback and deploy all",
               normal.contains("deploy|vercel/app") && normal.contains("rollback|vercel/app") && normal.contains("action.deployChanged"), true)
        st.teamObserver = true
        let looking = PaletteCommands.all(st).map(\.id)
        expect("observer: no deploy or rollback in the palette",
               looking.contains { $0.hasPrefix("deploy|") || $0.hasPrefix("rollback|") || $0 == "action.deployChanged" }, false)
        expect("observer: the log is still there", looking.contains("log|vercel/app"), true)
    }


}
