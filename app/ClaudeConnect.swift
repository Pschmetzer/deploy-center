// Deploy Center — Settings > Claude: connect Claude Desktop and Claude Code to the Deploy Center
// MCP server (integrations/mcp), show Autofix, and one dismissible line in the main window when
// Claude is found but not connected. No network: only local files and the local `claude` CLI.
//
// Paths can be overridden for tests and development (all optional, e.g. `defaults write
// app.deploycenter.mac claudeDesktopConfigPath /tmp/copy.json`, or `--args -claudeCLIPath /x`):
//   claudeDesktopConfigPath  Claude Desktop's claude_desktop_config.json
//   claudeCodeConfigPath     Claude Code's ~/.claude.json (only read)
//   claudeCLIPath            the `claude` CLI
//   claudeNodePath           node, for both
//   claudeMCPServerPath      integrations/mcp/server.mjs

import SwiftUI
import AppKit

// MARK: - Config edits (pure, tested in tests/app-tests.swift)

enum ClaudeConfig {
    static let serverName = "deploy-center"
    static let allowKey = "DEPLOYS_MCP_ALLOW_DEPLOY"

    enum Problem: Error, Equatable { case invalidJSON, notAnObject, serversNotAnObject }

    /// The file as an object. Missing or empty is an empty object; anything that is not a JSON
    /// object (or has a `mcpServers` that is not one) is refused, so nothing gets clobbered.
    static func parse(_ data: Data?) throws -> [String: Any] {
        guard let data, !String(decoding: data, as: UTF8.self).trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else { return [:] }
        guard let obj = try? JSONSerialization.jsonObject(with: data, options: [.fragmentsAllowed]) else { throw Problem.invalidJSON }
        guard let root = obj as? [String: Any] else { throw Problem.notAnObject }
        if let s = root["mcpServers"], !(s is [String: Any]) { throw Problem.serversNotAnObject }
        return root
    }

    static func encode(_ root: [String: Any]) throws -> Data {
        // Sorted: the same file gives the same text, so connecting twice does not reshuffle it.
        var d = try JSONSerialization.data(withJSONObject: root, options: [.prettyPrinted, .withoutEscapingSlashes, .sortedKeys])
        d.append(0x0A)
        return d
    }

    /// Adds or replaces only `mcpServers[name]`; every other key and entry stays as it was.
    static func merge(_ data: Data?, name: String = serverName, entry: [String: Any]) throws -> Data {
        var root = try parse(data)
        var servers = root["mcpServers"] as? [String: Any] ?? [:]
        servers[name] = entry
        root["mcpServers"] = servers
        let out = try encode(root)
        _ = try parse(out)   // what is written must read back
        return out
    }

    /// Removes only `mcpServers[name]` (and `mcpServers` when that leaves it empty). nil: it was not there, nothing to write.
    static func unmerge(_ data: Data?, name: String = serverName) throws -> Data? {
        var root = try parse(data)
        guard var servers = root["mcpServers"] as? [String: Any], servers[name] != nil else { return nil }
        servers.removeValue(forKey: name)
        // Ours was the only one: leave no empty object behind (a file without it was valid before).
        root["mcpServers"] = servers.isEmpty ? nil : servers
        let out = try encode(root)
        _ = try parse(out)
        return out
    }

    static func entry(_ data: Data?, name: String = serverName) -> [String: Any]? {
        ((try? parse(data))?["mcpServers"] as? [String: Any])?[name] as? [String: Any]
    }

    static func allowsDeploy(_ entry: [String: Any]?) -> Bool {
        (entry?["env"] as? [String: Any])?[allowKey] as? String == "1"
    }

    /// Claude Desktop starts servers without the shell's PATH: absolute node, server and deploys.
    static func desktopEntry(node: String, server: String, deploys: String, allowDeploy: Bool) -> [String: Any] {
        var env = ["DEPLOYS_BIN": deploys]
        if allowDeploy { env[allowKey] = "1" }
        return ["command": node, "args": [server], "env": env]
    }

    /// `claude mcp add [options] <name> -- <command> [args...]` (code.claude.com/docs/en/mcp).
    /// `--env` takes several values, so a flag sits between it and the name.
    static func codeAddArgs(node: String, server: String, deploys: String, allowDeploy: Bool) -> [String] {
        var a = ["mcp", "add", "-e", "DEPLOYS_BIN=\(deploys)"]
        if allowDeploy { a += ["-e", "\(allowKey)=1"] }
        return a + ["--transport", "stdio", "--scope", "user", serverName, "--", node, server]
    }

    static func codeRemoveArgs() -> [String] { ["mcp", "remove", serverName, "--scope", "user"] }

    /// Plugins are installed inside Claude Code; the app only copies these.
    static let pluginCommands = ["/plugin marketplace add Pschmetzer/deploy-center", "/plugin install deploy-center@deploy-center"]
}

// MARK: - Files: backup, atomic write, same permissions

enum ClaudeFiles {
    static func read(_ path: String) -> Data? { FileManager.default.contents(atPath: path) }

    static func stamp(_ date: Date = Date()) -> String {
        let f = DateFormatter(); f.locale = Locale(identifier: "en_US_POSIX"); f.dateFormat = "yyyyMMdd-HHmmss"
        return f.string(from: date)
    }

    /// Only the newest `keep` backups of a file stay: each may hold other servers and their keys.
    static func pruneBackups(of real: String, keep: Int) {
        let fm = FileManager.default
        let dir = (real as NSString).deletingLastPathComponent, prefix = (real as NSString).lastPathComponent + ".bak-"
        guard let names = try? fm.contentsOfDirectory(atPath: dir) else { return }
        let baks = names.filter { $0.hasPrefix(prefix) }.map { (dir as NSString).appendingPathComponent($0) }
        func made(_ p: String) -> Date { ((try? fm.attributesOfItem(atPath: p))?[.modificationDate] as? Date) ?? .distantPast }
        // Newest first by time, then by name (the stamp), for backups within one second.
        let sorted = baks.sorted { let a = made($0), b = made($1); return a != b ? a > b : $0 > $1 }
        for old in sorted.dropFirst(keep) { try? fm.removeItem(atPath: old) }
    }

    /// Writes through a temp file in the same folder and a rename, so the file is never half
    /// written. A symlink is followed (the link stays), the mode is kept (600 for a new file), and
    /// an existing file is first copied to `<file>.bak-<time>`. Returns the backup's path.
    @discardableResult
    static func write(_ data: Data, to path: String) throws -> String? {
        let fm = FileManager.default
        let real = (path as NSString).resolvingSymlinksInPath
        let dir = (real as NSString).deletingLastPathComponent
        var mode = 0o600
        var backup: String?
        if fm.fileExists(atPath: real) {
            if let m = (try? fm.attributesOfItem(atPath: real))?[.posixPermissions] as? NSNumber { mode = m.intValue }
            var bak = real + ".bak-" + stamp()
            var n = 1
            while fm.fileExists(atPath: bak) { n += 1; bak = real + ".bak-" + stamp() + "-\(n)" }
            try fm.copyItem(atPath: real, toPath: bak)
            try fm.setAttributes([.posixPermissions: mode], ofItemAtPath: bak)
            backup = bak
            pruneBackups(of: real, keep: 5)
        } else {
            try fm.createDirectory(atPath: dir, withIntermediateDirectories: true)
        }
        let tmp = (dir as NSString).appendingPathComponent(".\((real as NSString).lastPathComponent).\(UUID().uuidString).tmp")
        guard fm.createFile(atPath: tmp, contents: data, attributes: [.posixPermissions: mode]) else {
            throw CocoaError(.fileWriteUnknown, userInfo: [NSFilePathErrorKey: tmp])
        }
        if rename(tmp, real) != 0 {
            let err = errno
            try? fm.removeItem(atPath: tmp)
            throw POSIXError(POSIXErrorCode(rawValue: err) ?? .EIO)
        }
        return backup
    }
}

// MARK: - Where things are on this Mac

enum ClaudeEnv {
    static let desktopBundleId = "com.anthropic.claudefordesktop"

    static func override(_ key: String) -> String? {
        guard let v = UserDefaults.standard.string(forKey: key), !v.isEmpty else { return nil }
        return (v as NSString).expandingTildeInPath
    }

    static var home: String { NSHomeDirectory() }
    static var desktopConfig: String {
        override("claudeDesktopConfigPath") ?? home + "/Library/Application Support/Claude/claude_desktop_config.json"
    }
    static var codeConfig: String { override("claudeCodeConfigPath") ?? home + "/.claude.json" }
    static var desktopApp: URL? { NSWorkspace.shared.urlForApplication(withBundleIdentifier: desktopBundleId) }

    static func isExec(_ p: String) -> Bool {
        var dir: ObjCBool = false
        return FileManager.default.fileExists(atPath: p, isDirectory: &dir) && !dir.boolValue && FileManager.default.isExecutableFile(atPath: p)
    }

    /// Apps started from the Dock do not get the shell's PATH: known places first, then a login
    /// shell (3 s at most). Never Claude Desktop's own internal copy of Claude Code.
    static func find(_ name: String, overrideKey: String, candidates: [String]) async -> String? {
        if let o = override(overrideKey) { return isExec(o) ? o : nil }
        if let hit = candidates.first(where: isExec) { return hit }
        let shell = ProcessInfo.processInfo.environment["SHELL"].flatMap { isExec($0) ? $0 : nil } ?? "/bin/zsh"
        let r = await ClaudeRun.run(shell, ["-lc", "command -v \(name)"], timeout: 3)
        let p = r.out.split(separator: "\n").last.map { String($0).trimmingCharacters(in: .whitespaces) } ?? ""
        return r.ok && p.hasPrefix("/") && isExec(p) && !p.contains("/Application Support/Claude/") ? p : nil
    }

    static func node() async -> String? {
        await find("node", overrideKey: "claudeNodePath",
                   candidates: ["/opt/homebrew/bin/node", "/usr/local/bin/node", home + "/.volta/bin/node", home + "/.local/bin/node"])
    }

    static func cli() async -> String? {
        await find("claude", overrideKey: "claudeCLIPath",
                   candidates: [home + "/.local/bin/claude", home + "/.claude/local/claude", "/opt/homebrew/bin/claude",
                                "/usr/local/bin/claude", home + "/.npm-global/bin/claude"])
    }

    /// Folders the app may sit in during development: next to it, and up to four levels up, but
    /// only a checkout of this repo (.git and VERSION). A stray integrations/ folder in Downloads
    /// must not end up in Claude's config or be installed as an extension.
    private static var nearBundle: [String] {
        var out: [String] = []
        var dir = (Bundle.main.bundlePath as NSString).deletingLastPathComponent
        let fm = FileManager.default
        for _ in 0..<4 where dir.count > 1 {
            if fm.fileExists(atPath: dir + "/.git"), fm.fileExists(atPath: dir + "/VERSION") { out.append(dir) }
            dir = (dir as NSString).deletingLastPathComponent
        }
        return out
    }

    /// The MCP server: inside the app (build.sh copies it when its packages are installed), else
    /// the repo the app was built from (development).
    static func server() -> (path: String?, problem: String?) {
        if Bundle.main.bundlePath.contains("/AppTranslocation/") {
            return (nil, L("Move Deploy Center to the Applications folder first; macOS runs it from a temporary place.",
                           "Verschiebe Deploy Center zuerst in den Programme-Ordner; macOS startet es von einem temporären Ort."))
        }
        var candidates: [String] = []
        if let o = override("claudeMCPServerPath") { candidates.append(o) }
        if let r = Bundle.main.resourcePath { candidates.append(r + "/mcp/server.mjs") }
        candidates += nearBundle.map { $0 + "/integrations/mcp/server.mjs" }
        guard let server = candidates.first(where: { FileManager.default.fileExists(atPath: $0) }) else {
            return (nil, L("This build has no MCP server (integrations/mcp).", "Dieser Build hat keinen MCP-Server (integrations/mcp)."))
        }
        let deps = (server as NSString).deletingLastPathComponent + "/node_modules/@modelcontextprotocol"
        guard FileManager.default.fileExists(atPath: deps) else {
            return (nil, L("The MCP server's packages are missing: run npm ci in integrations/mcp.",
                           "Die Pakete des MCP-Servers fehlen: npm ci in integrations/mcp ausführen."))
        }
        return (server, nil)
    }

    /// The one-click Claude Desktop extension, only when a build ships one.
    static func extensionBundle() -> URL? {
        var paths: [String] = []
        if let r = Bundle.main.resourcePath { paths.append(r + "/deploy-center.mcpb") }
        for d in nearBundle { paths += [d + "/integrations/mcp/deploy-center.mcpb", d + "/integrations/claude-desktop/deploy-center.mcpb"] }
        return paths.first(where: { FileManager.default.fileExists(atPath: $0) }).map { URL(fileURLWithPath: $0) }
    }
}

enum ClaudeRun {
    /// Runs a program with a plain PATH (plus `pathDirs`), stdout and stderr together.
    static func run(_ exe: String, _ args: [String], pathDirs: [String] = [], timeout: Double = 30) async -> (ok: Bool, out: String) {
        await withCheckedContinuation { cont in
            DispatchQueue.global().async {
                let p = Process()
                p.executableURL = URL(fileURLWithPath: exe)
                p.arguments = args
                p.currentDirectoryURL = URL(fileURLWithPath: NSHomeDirectory())
                var env = ProcessInfo.processInfo.environment
                env["PATH"] = (pathDirs + ["/usr/bin", "/bin", "/usr/sbin", "/sbin"]).joined(separator: ":")
                p.environment = env
                let pipe = Pipe()
                p.standardOutput = pipe; p.standardError = pipe; p.standardInput = FileHandle.nullDevice
                do { try p.run() } catch { cont.resume(returning: (false, error.localizedDescription)); return }
                // The whole tree: a grandchild (shell start files, claude) holding the pipe would
                // keep the read below waiting after the parent ended.
                let timer = DispatchWorkItem { if p.isRunning { Tool.killTree(p.processIdentifier) } }
                DispatchQueue.global().asyncAfter(deadline: .now() + timeout, execute: timer)
                let data = pipe.fileHandleForReading.readDataToEndOfFile()
                p.waitUntilExit()
                timer.cancel()
                cont.resume(returning: (p.terminationStatus == 0, String(decoding: data, as: UTF8.self)))
            }
        }
    }
}

// MARK: - State

@MainActor
final class ClaudeLink: ObservableObject {
    enum Status: Equatable { case connected, notConnected, notFound, problem(String) }

    @Published var desktop: Status = .notFound
    @Published var desktopAllows = false
    @Published var code: Status = .notFound
    @Published var codeAllows = false
    @Published var cli: String?
    @Published var node: String?
    @Published var server: String?
    @Published var serverProblem: String?
    @Published var autofix: AutofixStatus?
    @Published var busy = false
    @Published var message: String?
    @Published var failed = false
    @Published var restartHint = false
    @Published var extensionURL: URL?

    /// The major version of `node`, when it could be read.
    @Published var nodeMajor: Int?
    var canConnect: Bool { node != nil && server != nil && (nodeMajor ?? 18) >= 18 }
    var missing: String? {
        if let serverProblem { return serverProblem }
        if node == nil { return L("Node.js 18 or newer is needed (brew install node).", "Node.js 18 oder neuer wird gebraucht (brew install node).") }
        if let m = nodeMajor, m < 18 {
            return L("Node.js \(m) is too old: 18 or newer is needed (brew upgrade node).", "Node.js \(m) ist zu alt: 18 oder neuer wird gebraucht (brew upgrade node).")
        }
        return nil
    }
    /// "v20.11.1" → 20.
    nonisolated static func majorVersion(_ version: String) -> Int? {
        Int(version.trimmingCharacters(in: .whitespacesAndNewlines).drop { $0 == "v" }.split(separator: ".").first ?? "")
    }

    /// Always from the files: Claude Desktop may rewrite its config while it runs.
    func refresh() async {
        let s = ClaudeEnv.server()
        server = s.path; serverProblem = s.problem
        extensionURL = ClaudeEnv.extensionBundle()
        async let n = ClaudeEnv.node()
        async let c = ClaudeEnv.cli()
        node = await n; cli = await c
        if let node { nodeMajor = Self.majorVersion(await ClaudeRun.run(node, ["--version"], timeout: 5).out) } else { nodeMajor = nil }

        let dData = ClaudeFiles.read(ClaudeEnv.desktopConfig)
        let dFound = ClaudeEnv.desktopApp != nil || dData != nil
        if !dFound { desktop = .notFound }
        else if (try? ClaudeConfig.parse(dData)) == nil {
            desktop = .problem(L("Its config file is not valid JSON. Nothing is changed.", "Seine Konfigurationsdatei ist kein gültiges JSON. Es wird nichts geändert."))
        }
        else if let e = ClaudeConfig.entry(dData) { desktop = .connected; desktopAllows = ClaudeConfig.allowsDeploy(e) }
        else { desktop = .notConnected; desktopAllows = false }

        let cData = await Task.detached { ClaudeFiles.read(ClaudeEnv.codeConfig) }.value
        if let e = ClaudeConfig.entry(cData) { code = .connected; codeAllows = ClaudeConfig.allowsDeploy(e) }
        else { code = cli == nil ? .notFound : .notConnected; codeAllows = false }
        // The switch shows what Claude's files say, not a preference that may be older (a reset,
        // or a connection made by the plugin or the CLI).
        // Both connected: "on" only when both allow, so a later reconnect never widens what one of them may do.
        // A node that moved (nvm, volta update): the entry still points at the old path, and
        // Claude fails to start the server without a word here. Connecting again writes the new one.
        let gone = [dData, cData].compactMap { ClaudeConfig.entry($0)?["command"] as? String }
            .filter { $0.hasPrefix("/") && !FileManager.default.isExecutableFile(atPath: $0) }
        if let g = gone.first {
            say(L("Claude's config points at \(g), which is gone (Node was updated?). Connect again.",
                  "Claudes Konfiguration zeigt auf \(g), das es nicht mehr gibt (Node aktualisiert?). Neu verbinden."), failed: true)
        }
        if desktop == .connected || code == .connected {
            let allows = (desktop != .connected || desktopAllows) && (code != .connected || codeAllows)
            UserDefaults.standard.set(allows, forKey: "claudeAllowDeploy")
        }

        autofix = try? await Tool.json(["autofix", "status"], as: AutofixStatus.self, timeout: 20)
        ClaudeNudge.store(wanted: desktop == .notConnected || code == .notConnected)
    }

    private func say(_ text: String, failed: Bool = false) { message = text; self.failed = failed }

    // Claude Desktop

    func connectDesktop(allowDeploy: Bool) async {
        guard let node, let server else { say(missing ?? "", failed: true); return }
        busy = true; defer { busy = false }
        let path = ClaudeEnv.desktopConfig
        do {
            let entry = ClaudeConfig.desktopEntry(node: node, server: server, deploys: Tool.path, allowDeploy: allowDeploy)
            let out = try ClaudeConfig.merge(ClaudeFiles.read(path), entry: entry)
            let bak = try ClaudeFiles.write(out, to: path)
            restartHint = true
            say(L("Connected. Restart Claude Desktop to load it.", "Verbunden. Starte Claude Desktop neu, damit es geladen wird.")
                + (bak.map { L(" Backup: ", " Sicherung: ") + ($0 as NSString).lastPathComponent } ?? ""))
        } catch { say(describe(error), failed: true) }
        await refresh()
    }

    func disconnectDesktop() async {
        busy = true; defer { busy = false }
        let path = ClaudeEnv.desktopConfig
        do {
            if let out = try ClaudeConfig.unmerge(ClaudeFiles.read(path)) {
                try ClaudeFiles.write(out, to: path)
                restartHint = true
                say(L("Disconnected. Restart Claude Desktop to apply it.", "Getrennt. Starte Claude Desktop neu, damit es wirkt."))
            }
        } catch { say(describe(error), failed: true) }
        await refresh()
    }

    func installExtension() {
        guard let url = extensionURL else { return }
        if let app = ClaudeEnv.desktopApp {
            NSWorkspace.shared.open([url], withApplicationAt: app, configuration: NSWorkspace.OpenConfiguration())
        } else { NSWorkspace.shared.open(url) }
    }

    /// Quits Claude Desktop, waits for it to end (10 s at most) and opens it again.
    func restartDesktop() async {
        guard let app = ClaudeEnv.desktopApp else { return }
        let running = { NSRunningApplication.runningApplications(withBundleIdentifier: ClaudeEnv.desktopBundleId) }
        for r in running() { r.terminate() }
        for _ in 0..<40 where !running().isEmpty { try? await Task.sleep(nanoseconds: 250_000_000) }
        // Still running (a quit dialog left open, say): the hint stays, nothing is opened twice.
        guard running().isEmpty else {
            say(L("Claude Desktop did not quit. Quit it yourself, then open it again.", "Claude Desktop wurde nicht beendet. Selbst beenden und wieder öffnen."), failed: true)
            return
        }
        let cfg = NSWorkspace.OpenConfiguration(); cfg.activates = true
        _ = try? await NSWorkspace.shared.openApplication(at: app, configuration: cfg)
        restartHint = false
    }

    // Claude Code

    func connectCode(allowDeploy: Bool) async {
        guard let cli else { return }
        guard let node, let server else { say(missing ?? "", failed: true); return }
        busy = true; defer { busy = false }
        let dirs = [(node as NSString).deletingLastPathComponent, (cli as NSString).deletingLastPathComponent]
        let had = code == .connected, hadAllow = codeAllows
        if had { _ = await ClaudeRun.run(cli, ClaudeConfig.codeRemoveArgs(), pathDirs: dirs) }
        let r = await ClaudeRun.run(cli, ClaudeConfig.codeAddArgs(node: node, server: server, deploys: Tool.path, allowDeploy: allowDeploy), pathDirs: dirs)
        if r.ok { say(L("Connected. New Claude Code sessions see Deploy Center.", "Verbunden. Neue Claude-Code-Sitzungen sehen Deploy Center.")) }
        else {
            // Removed, then not added: put the connection back as it was instead of leaving none.
            if had { _ = await ClaudeRun.run(cli, ClaudeConfig.codeAddArgs(node: node, server: server, deploys: Tool.path, allowDeploy: hadAllow), pathDirs: dirs) }
            say(Tool.shorten(r.out.trimmingCharacters(in: .whitespacesAndNewlines)), failed: true)
        }
        await refresh()
    }

    func disconnectCode() async {
        guard let cli else { say(L("The claude CLI was not found.", "Die claude-CLI wurde nicht gefunden."), failed: true); return }
        busy = true; defer { busy = false }
        let r = await ClaudeRun.run(cli, ClaudeConfig.codeRemoveArgs(), pathDirs: [(cli as NSString).deletingLastPathComponent])
        if r.ok { say(L("Disconnected from Claude Code.", "Von Claude Code getrennt.")) }
        else { say(Tool.shorten(r.out.trimmingCharacters(in: .whitespacesAndNewlines)), failed: true) }
        await refresh()
    }

    /// The switch, written into whatever is connected.
    func applyAllowDeploy(_ on: Bool) async {
        if desktop == .connected && desktopAllows != on { await connectDesktop(allowDeploy: on) }
        if code == .connected && codeAllows != on && cli != nil { await connectCode(allowDeploy: on) }
    }

    private func describe(_ error: Error) -> String {
        switch error as? ClaudeConfig.Problem {
        case .invalidJSON?: return L("The config file is not valid JSON. Nothing was changed.", "Die Konfigurationsdatei ist kein gültiges JSON. Es wurde nichts geändert.")
        case .notAnObject?: return L("The config file is not a JSON object. Nothing was changed.", "Die Konfigurationsdatei ist kein JSON-Objekt. Es wurde nichts geändert.")
        case .serversNotAnObject?: return L("\"mcpServers\" in the config file is not an object. Nothing was changed.", "\"mcpServers\" in der Konfigurationsdatei ist kein Objekt. Es wurde nichts geändert.")
        case nil: return error.localizedDescription
        }
    }
}

// MARK: - Settings > Claude

struct ClaudeSettings: View {
    /// Scrolls the Settings form to the Autofix section.
    var showAutofix: () -> Void = {}
    @StateObject private var link = ClaudeLink()
    @AppStorage("claudeAllowDeploy") private var allowDeploy = false
    @State private var askAllow = false
    @State private var askRestart = false

    var body: some View {
        Section {
            Text(L("Lets Claude see what is waiting to go live and read release notes and build logs. Read only, unless you turn on deploying below.",
                   "Damit sieht Claude, was auf den Livegang wartet, und liest Release Notes und Build-Logs. Nur lesend, außer du schaltest unten das Deployen ein."))
                .font(.caption).foregroundStyle(.secondary)

            desktopRow
            codeRow
            autofixRow

            Toggle(L("Let Claude deploy (asks you first)", "Claude deployen lassen (fragt vorher)"), isOn: Binding(
                get: { allowDeploy },
                set: { on in if on { askAllow = true } else { allowDeploy = false; Task { await link.applyAllowDeploy(false) } } }))
                .disabled(link.busy)
            if allowDeploy {
                Label(L("Claude can start a production deploy or a rollback of one project. It asks you before each one; a deploy uses build minutes and changes what is live.",
                        "Claude kann ein Produktions-Deploy oder einen Rollback eines Projekts starten. Es fragt vor jedem; ein Deploy kostet Build-Minuten und ändert, was live ist."),
                      systemImage: "exclamationmark.triangle.fill")
                    .font(.caption).foregroundStyle(.orange)
            }

            if let m = link.message {
                Text(m).font(.caption).textSelection(.enabled).foregroundStyle(link.failed ? .red : .secondary)
            }
        } header: {
            HStack {
                Text("Claude")
                if link.busy { ProgressView().controlSize(.small) }
            }
        }
        .task { await link.refresh() }
        .alert(L("Let Claude deploy?", "Claude deployen lassen?"), isPresented: $askAllow) {
            Button(L("Allow", "Erlauben"), role: .destructive) { allowDeploy = true; Task { await link.applyAllowDeploy(true) } }
            Button(L("Cancel", "Abbrechen"), role: .cancel) {}
        } message: {
            Text(L("Claude Desktop and Claude Code get two more tools: deploy one project and roll one back. Claude asks you before it uses them. Auto-deploy stays off.",
                   "Claude Desktop und Claude Code bekommen zwei Werkzeuge mehr: ein Projekt deployen und eines zurückrollen. Claude fragt dich, bevor es sie nutzt. Auto-Deploy bleibt aus."))
        }
        .alert(L("Restart Claude Desktop?", "Claude Desktop neu starten?"), isPresented: $askRestart) {
            Button(L("Restart", "Neu starten")) { Task { await link.restartDesktop() } }
            Button(L("Cancel", "Abbrechen"), role: .cancel) {}
        } message: {
            Text(L("Claude quits and opens again. Answers in progress and Claude Code sessions running in the Claude app are interrupted.",
                   "Claude wird beendet und neu geöffnet. Laufende Antworten und Claude-Code-Sitzungen in der Claude-App werden unterbrochen."))
        }
    }

    private func status(_ s: ClaudeLink.Status) -> some View {
        let (text, color): (String, Color) = {
            switch s {
            case .connected: return (L("connected", "verbunden"), .green)
            case .notConnected: return (L("not connected", "nicht verbunden"), .secondary)
            case .notFound: return (L("not found", "nicht gefunden"), .secondary)
            case .problem: return (L("problem", "Problem"), .orange)
            }
        }()
        return HStack(spacing: 4) {
            Image(systemName: s == .connected ? "checkmark.circle.fill" : (s == .notFound ? "circle.dashed" : "circle"))
            Text(text)
        }
        .font(.caption).foregroundStyle(color)
        .accessibilityElement(children: .combine)
    }

    @ViewBuilder private var desktopRow: some View {
        LabeledContent {
            HStack {
                status(link.desktop)
                switch link.desktop {
                case .connected:
                    Button(L("Disconnect", "Trennen")) { Task { await link.disconnectDesktop() } }.disabled(link.busy)
                case .notConnected:
                    Button(L("Connect", "Verbinden")) { Task { await link.connectDesktop(allowDeploy: allowDeploy) } }
                        .disabled(link.busy || !link.canConnect)
                default: EmptyView()
                }
            }
        } label: {
            Text("Claude Desktop")
            if case .problem(let p) = link.desktop { Text(p) }
            else if link.desktop == .notConnected, let m = link.missing { Text(m) }
        }
        if link.restartHint && ClaudeEnv.desktopApp != nil {
            HStack {
                Text(L("Claude Desktop loads it after a restart.", "Claude Desktop lädt es nach einem Neustart."))
                    .font(.caption).foregroundStyle(.secondary)
                Spacer()
                Button(L("Restart Claude …", "Claude neu starten …")) { askRestart = true }
            }
        }
        if link.extensionURL != nil && link.desktop == .notConnected {
            HStack {
                Text(L("Or install it as a Claude Desktop extension.", "Oder als Erweiterung in Claude Desktop installieren."))
                    .font(.caption).foregroundStyle(.secondary)
                Spacer()
                Button(L("Install extension", "Erweiterung installieren")) { link.installExtension() }
            }
        }
    }

    @ViewBuilder private var codeRow: some View {
        LabeledContent {
            HStack {
                status(link.code)
                switch link.code {
                case .connected:
                    Button(L("Disconnect", "Trennen")) { Task { await link.disconnectCode() } }.disabled(link.busy || link.cli == nil)
                case .notConnected:
                    Button(L("Connect", "Verbinden")) { Task { await link.connectCode(allowDeploy: allowDeploy) } }
                        .disabled(link.busy || !link.canConnect)
                default: EmptyView()
                }
            }
        } label: {
            Text("Claude Code")
            if link.code == .notFound { Text(L("The claude CLI was not found.", "Die claude-CLI wurde nicht gefunden.")) }
            else if link.code == .notConnected, let m = link.missing { Text(m) }
        }
        if link.code != .notFound {
            HStack {
                Text(L("Plugin (skill and commands): paste both into Claude Code.", "Plugin (Skill und Befehle): beides in Claude Code einfügen."))
                    .font(.caption).foregroundStyle(.secondary)
                Spacer()
                CopyButton(title: L("Copy commands", "Befehle kopieren")) { ClaudeConfig.pluginCommands.joined(separator: "\n") }
            }
        }
    }

    @ViewBuilder private var autofixRow: some View {
        let a = link.autofix
        let ready = a?.routine != nil && a?.token == true
        LabeledContent {
            HStack {
                HStack(spacing: 4) {
                    Image(systemName: ready ? "checkmark.circle.fill" : "circle")
                    Text(ready ? (a?.scheduled == true ? L("on", "an") : L("set up, not scheduled", "eingerichtet, nicht geplant"))
                         : L("not set up", "nicht eingerichtet"))
                }
                .font(.caption).foregroundStyle(ready ? .green : .secondary)
                Button(ready ? L("Show", "Zeigen") : L("Set up …", "Einrichten …"), action: showAutofix)
            }
        } label: {
            Text(L("Autofix (Claude routine)", "Autofix (Claude-Routine)"))
            Text(L("A failed build goes to Claude, which opens a fix PR.", "Ein fehlgeschlagener Build geht an Claude, das einen Fix-PR öffnet."))
        }
    }
}

// MARK: - The one line in the main window

enum ClaudeNudge {
    static let wantedKey = "claudeNudgeWanted"
    static let dismissedKey = "claudeNudgeDismissed"

    static func store(wanted: Bool) {
        if UserDefaults.standard.bool(forKey: wantedKey) != wanted { UserDefaults.standard.set(wanted, forKey: wantedKey) }
    }

    /// Once per run, off the main thread: Claude found but not connected? The window calls this
    /// each time it is built; a login shell (up to 3 s) once is enough.
    private static let ran = OnceFlag()
    final class OnceFlag: @unchecked Sendable {
        private let lock = NSLock(); private var done = false
        /// True the first time only.
        func first() -> Bool { lock.lock(); defer { lock.unlock() }; if done { return false }; done = true; return true }
    }
    static func refresh() async {
        if UserDefaults.standard.bool(forKey: dismissedKey) { return }
        guard ran.first() else { return }
        let desktopData = await Task.detached { ClaudeFiles.read(ClaudeEnv.desktopConfig) }.value
        let desktop = ClaudeEnv.desktopApp != nil && (try? ClaudeConfig.parse(desktopData)) != nil && ClaudeConfig.entry(desktopData) == nil
        let codeData = await Task.detached { ClaudeFiles.read(ClaudeEnv.codeConfig) }.value
        let code = ClaudeConfig.entry(codeData) == nil ? (await ClaudeEnv.cli()) != nil : false
        await MainActor.run { store(wanted: desktop || code) }
    }
}

struct ClaudeNudgeLine: View {
    @AppStorage(ClaudeNudge.dismissedKey) private var dismissed = false

    var body: some View {
        HStack {
            Image(systemName: "sparkles").foregroundStyle(.purple)
            Text(L("Claude found. Connect it so Claude can see what's waiting.", "Claude gefunden. Verbinde es, damit Claude sieht, was wartet."))
                .font(.callout)
            SettingsLink { Text(L("Connect …", "Verbinden …")) }.buttonStyle(.link)
            Spacer()
            Button { dismissed = true } label: { Image(systemName: "xmark") }.buttonStyle(.borderless)
                .help(L("Don't show again", "Nicht mehr zeigen")).accessibilityLabel(L("Don't show again", "Nicht mehr zeigen"))
        }
        .padding(.horizontal, 12).padding(.vertical, 6)
    }
}
