// Deploy Center — Calling the bundled `deploys` script, the language, the error log.

import SwiftUI
import AppKit

// MARK: - Language (Settings → General → Language; by default German if the Mac prefers it)

/// The choice is the app's own `AppleLanguages` (["en"] or ["de"]), which macOS reads at launch,
/// so `Locale.preferredLanguages` and the system texts follow it. No key: the Mac's language.
let isGerman = (Locale.preferredLanguages.first ?? "en").hasPrefix("de")
func L(_ en: String, _ de: String) -> String { isGerman ? de : en }

enum AppLanguage: String, CaseIterable, Identifiable {
    case system, en, de
    var id: String { rawValue }
    /// English and Deutsch stay untranslated, so someone stuck in the wrong one still finds theirs.
    var title: String {
        switch self {
        case .system: return L("Same as the Mac", "Wie der Mac")
        case .en: return "English"
        case .de: return "Deutsch"
        }
    }
    static var chosen: AppLanguage {
        guard let list = UserDefaults.standard.persistentDomain(forName: Bundle.main.bundleIdentifier ?? "")?["AppleLanguages"] as? [String],
              let first = list.first else { return .system }
        return first.hasPrefix("de") ? .de : first.hasPrefix("en") ? .en : .system
    }
    /// Takes effect at the next launch (the texts are fixed when the views are built).
    func save() {
        if self == .system { UserDefaults.standard.removeObject(forKey: "AppleLanguages") }
        else { UserDefaults.standard.set([rawValue], forKey: "AppleLanguages") }
    }
    /// The language this choice shows after a restart.
    var resolved: AppLanguage {
        guard self == .system else { return self }
        let mac = UserDefaults.standard.persistentDomain(forName: UserDefaults.globalDomain)?["AppleLanguages"] as? [String]
        return (mac?.first ?? "en").hasPrefix("de") ? .de : .en
    }
    /// What the app shows now, which may differ from `chosen` until it restarts.
    static var running: AppLanguage { isGerman ? .de : .en }
}

/// Asks before quitting (or restarting) while deploys run; true when the app may go. No question
/// when nothing runs. The menu bar's Quit and `relaunchApp` share it.
@MainActor func confirmQuit(running: Int, restart: Bool = false) -> Bool {
    guard running > 0 else { return true }
    NSApp.activate(ignoringOtherApps: true)
    let a = NSAlert()
    a.messageText = L("\(running) \(running == 1 ? "deploy is" : "deploys are") still running", "\(running) \(running == 1 ? "Deploy läuft" : "Deploys laufen") noch")
    a.informativeText = L("Builds that already started go on at Vercel or Render, but Deploy Center stops following them and queued ones do not start.",
                          "Gestartete Builds laufen bei Vercel oder Render weiter, aber Deploy Center verfolgt sie nicht mehr, und wartende starten nicht.")
    a.addButton(withTitle: L("Keep running", "Weiterlaufen lassen"))
    a.addButton(withTitle: restart ? L("Restart anyway", "Trotzdem neu starten") : L("Quit anyway", "Trotzdem beenden"))
    return a.runModal() == .alertSecondButtonReturn
}

/// Quits after asking when deploys run, and opens the app again. No `open -n`: if the quit is
/// cancelled, `open` only brings the running copy forward, so there are never two.
@MainActor func relaunchApp(running deploys: Int) {
    guard confirmQuit(running: deploys, restart: true) else { return }
    let p = Process()
    p.executableURL = URL(fileURLWithPath: "/bin/sh")
    // Waits until this copy is gone (at most 10 s), then opens the bundle again.
    p.arguments = ["-c", "while kill -0 \"$1\" 2>/dev/null && [ $((i+=1)) -le 50 ]; do sleep 0.2; done; /usr/bin/open \"$2\"",
                   "relaunch", String(ProcessInfo.processInfo.processIdentifier), Bundle.main.bundlePath]
    do { try p.run() } catch { Log.write("relaunch: \(error.localizedDescription)"); return }
    NSApp.terminate(nil)
}

// MARK: - Calling the script

enum Tool {
    /// The script ships inside the app, so a download needs nothing but the app.
    static var path: String {
        if let testPath { return testPath }
        if let bundled = Bundle.main.path(forResource: "deploys", ofType: nil) { return bundled }
        noteFallback()
        return NSHomeDirectory() + "/bin/deploys"
    }
    /// Tests only: a stand-in script instead of the real one, so nothing reaches an account.
    nonisolated(unsafe) static var testPath: String?
    /// A build without the script inside (tests, a bare `swiftc`) uses ~/bin/deploys, which may be
    /// another version with other JSON. Said once in the log, with that script's version.
    private static let fallbackNoted: Void = {
        // Only the fact: asking that script for its version here could hang every call.
        let mine = Bundle.main.infoDictionary?["CFBundleShortVersionString"] as? String ?? "?"
        Log.write("no bundled deploys: using ~/bin/deploys (its JSON may differ), app \(mine) – check with `deploys --version`")
    }()
    private static func noteFallback() { _ = fallbackNoted }

    /// The PATH of the person's login shell, read once, so `vercel` installed through nvm, volta or
    /// fnm is found too. The usual places come first in case the shell says nothing in time.
    static let searchPath: String = {
        // Reading it starts a login shell (up to 3 s); once a day is enough. A shell that did not
        // answer in time is not saved, so the next start tries again instead of a day without it.
        let d = UserDefaults.standard
        if let saved = d.string(forKey: "searchPath"), Date().timeIntervalSince1970 - d.double(forKey: "searchPathAt") < 86400 { return saved }
        let (result, complete) = computeSearchPath()
        if complete { d.set(result, forKey: "searchPath"); d.set(Date().timeIntervalSince1970, forKey: "searchPathAt") }
        return result
    }()

    /// The fixed places plus the shell's PATH. zsh is started interactive as well (`-i`), because
    /// nvm and fnm are usually set up in ~/.zshrc, which a login shell alone does not read.
    private static func computeSearchPath() -> (String, complete: Bool) {
        let fixed = "/opt/homebrew/bin:/usr/local/bin:" + NSHomeDirectory() + "/.local/bin:/usr/bin:/bin:/usr/sbin:/sbin"
        let shellPath = ProcessInfo.processInfo.environment["SHELL"] ?? "/bin/zsh"
        let p = Process()
        p.executableURL = URL(fileURLWithPath: shellPath)
        // Markers, so whatever an interactive shell prints on its own is not taken for the PATH.
        p.arguments = [shellPath.hasSuffix("zsh") ? "-ilc" : "-lc", "printf '__DC_PATH__%s__DC_END__' \"$PATH\""]
        let out = Pipe(); p.standardOutput = out; p.standardError = FileHandle.nullDevice
        p.standardInput = FileHandle.nullDevice
        guard (try? p.run()) != nil else { return (fixed, false) }
        let lock = NSLock(); var late = false
        let killer = DispatchWorkItem {
            guard p.isRunning else { return }
            lock.lock(); late = true; lock.unlock()
            killTree(p.processIdentifier)
        }
        DispatchQueue.global().asyncAfter(deadline: .now() + 3, execute: killer)
        // Read on its own queue and waited for 4 s at most: something ~/.zshrc started (tmux, an
        // agent) may hold the pipe open long after the shell is gone.
        var data = Data()
        let done = DispatchSemaphore(value: 0)
        DispatchQueue.global().async {
            let d = out.fileHandleForReading.readDataToEndOfFile()
            lock.lock(); data = d; lock.unlock(); done.signal()
        }
        let finished = done.wait(timeout: .now() + 4) == .success
        killer.cancel()
        if finished { p.waitUntilExit() } else { killTree(p.processIdentifier) }
        lock.lock(); let timedOut = late || !finished; let got = data; lock.unlock()
        let text = String(decoding: got, as: UTF8.self)
        guard let open = text.range(of: "__DC_PATH__", options: .backwards),
              let close = text.range(of: "__DC_END__", range: open.upperBound..<text.endIndex) else {
            if timedOut { Log.write("login shell gave no PATH within 3 s; using the usual places") }
            return (fixed, false)
        }
        let shell = String(text[open.upperBound..<close.lowerBound]).trimmingCharacters(in: .whitespacesAndNewlines)
        return (shell.isEmpty ? fixed : fixed + ":" + shell, !timedOut)
    }

    /// Runs off the main thread. A GUI app does not get the shell's PATH, and `vercel` needs node.
    /// stdout and stderr are read at the same time (reading one to the end first can deadlock
    /// once the other fills its pipe), and a command that hangs is ended after `timeout` seconds.
    static func run(_ args: [String], stdin: String? = nil, timeout: Double = 120) async throws -> Data {
        // A cancelled Swift task ends the process too, instead of letting it run to its timeout.
        let running = Running()
        return try await withTaskCancellationHandler {
            try await runProcess(args, stdin: stdin, timeout: timeout, running: running)
        } onCancel: { running.cancel() }
    }

    /// The process of one `run`, so a cancel from another thread can reach it.
    final class Running: @unchecked Sendable {
        private let lock = NSLock(); private var pid: pid_t = 0; private var cancelled = false
        func started(_ p: pid_t) -> Bool { lock.lock(); defer { lock.unlock() }; pid = p; return !cancelled }
        /// Ended: a late cancel must not reach a process id that was given out again.
        func finished() { lock.lock(); pid = 0; lock.unlock() }
        var isCancelled: Bool { lock.lock(); defer { lock.unlock() }; return cancelled }
        func cancel() {
            lock.lock(); cancelled = true; let p = pid; lock.unlock()
            if p > 0 { killTree(p) }
        }
    }

    /// What one `run` collects from its process; reached from the pipe, exit and timeout handlers.
    /// The lock keeps them apart, and the answer is given exactly once.
    private final class Collect: @unchecked Sendable {
        let lock = NSLock()
        var out = Data(), err = Data(), timedOut = false, answered = false, openPipes = 2, exited = false
        let deliver: (Result<Data, Error>) -> Void
        init(_ deliver: @escaping (Result<Data, Error>) -> Void) { self.deliver = deliver }
        /// True for the one caller that may answer.
        func claim() -> Bool { lock.lock(); defer { lock.unlock() }; if answered { return false }; answered = true; return true }
    }

    private static func runProcess(_ args: [String], stdin: String?, timeout: Double, running: Running) async throws -> Data {
        try await withCheckedThrowingContinuation { cont in
            let p = Process()
            p.executableURL = URL(fileURLWithPath: "/bin/bash")
            p.arguments = [path] + args
            var env = ProcessInfo.processInfo.environment
            env["PATH"] = searchPath
            p.environment = env
            let out = Pipe(), err = Pipe()
            p.standardOutput = out
            p.standardError = err
            // No thread waits on anything: the handlers below are called by the system, so many
            // calls at once (status polls, list reads) cost no blocked threads.
            let c = Collect { r in
                // Whatever still holds the pipes (a daemon that left the process tree) is not waited for.
                out.fileHandleForReading.readabilityHandler = nil
                err.fileHandleForReading.readabilityHandler = nil
                if running.isCancelled { cont.resume(throwing: CancellationError()); return }
                if case .failure(let e as ToolError) = r, e.timedOut {
                    Log.write("deploys \(args.joined(separator: " ")): no answer after \(Int(timeout)) s, ended")
                }
                cont.resume(with: r)
            }
            let timeoutError = ToolError(message: L("No answer after \(Int(timeout)) seconds – try again.",
                                                    "Keine Antwort nach \(Int(timeout)) Sekunden – nochmal versuchen."), timedOut: true)
            /// Once the process ended and both pipes are read (or `force`: the pipes are given up on).
            let finish: @Sendable (Bool) -> Void = { force in
                c.lock.lock()
                guard c.exited, force || c.openPipes == 0 else { c.lock.unlock(); return }
                let late = c.timedOut, data = c.out, errText = c.err
                c.lock.unlock()
                guard c.claim() else { return }
                if late { c.deliver(.failure(timeoutError)); return }
                if p.terminationStatus == 0 { c.deliver(.success(data)); return }
                let msg = String(data: errText, encoding: .utf8)?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
                let text = msg.isEmpty ? "Exit code \(p.terminationStatus)" : msg
                Log.write("deploys \(args.joined(separator: " ")): \(text)")
                // The whole text is in the log; a toast or a row gets the end, where the cause usually is.
                c.deliver(.failure(ToolError(message: shorten(text), exitCode: p.terminationStatus)))
            }
            out.fileHandleForReading.readabilityHandler = { h in
                let d = h.availableData
                c.lock.lock(); if d.isEmpty { c.openPipes -= 1 } else { c.out.append(d) }; c.lock.unlock()
                if d.isEmpty { h.readabilityHandler = nil; finish(false) }
            }
            err.fileHandleForReading.readabilityHandler = { h in
                let d = h.availableData
                c.lock.lock(); if d.isEmpty { c.openPipes -= 1 } else { c.err.append(d) }; c.lock.unlock()
                if d.isEmpty { h.readabilityHandler = nil; finish(false) }
            }
            p.terminationHandler = { _ in
                running.finished()
                c.lock.lock(); c.exited = true; c.lock.unlock()
                finish(false)
                // A child that outlives bash keeps the pipes open: three seconds later the answer
                // goes with what was read.
                DispatchQueue.global().asyncAfter(deadline: .now() + 3) { finish(true) }
            }
            if let stdin {
                let inPipe = Pipe()
                p.standardInput = inPipe
                inPipe.fileHandleForWriting.write(Data((stdin + "\n").utf8))
                try? inPipe.fileHandleForWriting.close()
            }
            do { try p.run() } catch {
                out.fileHandleForReading.readabilityHandler = nil
                err.fileHandleForReading.readabilityHandler = nil
                _ = c.claim()
                cont.resume(throwing: error); return
            }
            if !running.started(p.processIdentifier) { killTree(p.processIdentifier) }
            // Ending bash alone is not enough: `vercel`, node or curl under it keep the pipes open.
            // Whatever still holds them three seconds later, the caller gets its answer.
            DispatchQueue.global().asyncAfter(deadline: .now() + timeout) {
                c.lock.lock()
                guard !c.answered else { c.lock.unlock(); return }
                c.timedOut = true
                c.lock.unlock()
                if p.isRunning { killTree(p.processIdentifier) }
                DispatchQueue.global().asyncAfter(deadline: .now() + 3) { if c.claim() { c.deliver(.failure(timeoutError)) } }
            }
        }
    }

    /// Any program (not the script), without a waiting thread: stdout, with stderr in it or dropped.
    /// After `timeout` the whole process tree is ended and the answer goes with what was read;
    /// a child that outlives the program and keeps the pipe open is not waited for either.
    /// `status` is nil when it could not start or ran out of time.
    static func exec(_ exe: String, _ args: [String], env: [String: String]? = nil, cwd: URL? = nil,
                     mergeStderr: Bool = false, timeout: Double = 30) async -> (status: Int32?, out: Data) {
        await withCheckedContinuation { cont in
            let p = Process()
            p.executableURL = URL(fileURLWithPath: exe)
            p.arguments = args
            if let env { p.environment = env }
            if let cwd { p.currentDirectoryURL = cwd }
            let pipe = Pipe()
            p.standardOutput = pipe
            p.standardError = mergeStderr ? pipe : FileHandle.nullDevice
            p.standardInput = FileHandle.nullDevice
            let c = Collect { _ in }
            let done: @Sendable (Bool) -> Void = { force in
                c.lock.lock()
                guard force || (c.exited && c.openPipes <= 1) else { c.lock.unlock(); return }
                let data = c.out, late = c.timedOut || !c.exited
                c.lock.unlock()
                guard c.claim() else { return }
                pipe.fileHandleForReading.readabilityHandler = nil
                cont.resume(returning: (late ? nil : p.terminationStatus, data))
            }
            pipe.fileHandleForReading.readabilityHandler = { h in
                let d = h.availableData
                c.lock.lock(); if d.isEmpty { c.openPipes -= 1 } else { c.out.append(d) }; c.lock.unlock()
                if d.isEmpty { h.readabilityHandler = nil; done(false) }
            }
            p.terminationHandler = { _ in
                c.lock.lock(); c.exited = true; c.lock.unlock()
                done(false)
                DispatchQueue.global().asyncAfter(deadline: .now() + 3) { done(true) }
            }
            do { try p.run() } catch {
                pipe.fileHandleForReading.readabilityHandler = nil
                _ = c.claim(); cont.resume(returning: (nil, Data())); return
            }
            DispatchQueue.global().asyncAfter(deadline: .now() + timeout) {
                c.lock.lock(); let open = !c.answered; if open { c.timedOut = true }; c.lock.unlock()
                guard open else { return }
                if p.isRunning { killTree(p.processIdentifier) }
                DispatchQueue.global().asyncAfter(deadline: .now() + 3) { done(true) }
            }
        }
    }

    /// A process and everything it started: the children first collected, then all asked to end,
    /// and after two seconds whatever is left is killed.
    static func killTree(_ root: pid_t) {
        var all: [pid_t] = [], next = [root]
        while let pid = next.popLast(), all.count < 256 {
            all.append(pid)
            next += children(of: pid)
        }
        for pid in all { kill(pid, SIGTERM) }
        DispatchQueue.global().asyncAfter(deadline: .now() + 2) {
            for pid in all where kill(pid, 0) == 0 { kill(pid, SIGKILL) }
        }
    }

    private static func children(of pid: pid_t) -> [pid_t] {
        var buf = [pid_t](repeating: 0, count: 256)
        let bytes = buf.withUnsafeMutableBytes {
            proc_listpids(UInt32(PROC_PPID_ONLY), UInt32(pid), $0.baseAddress, Int32($0.count))
        }
        guard bytes > 0 else { return [] }
        return buf.prefix(Int(bytes) / MemoryLayout<pid_t>.size).filter { $0 > 0 }
    }

    static func json<T: Decodable>(_ args: [String], as type: T.Type, timeout: Double = 120) async throws -> T {
        let data = try await run(args, timeout: timeout)
        do { return try JSONDecoder().decode(T.self, from: data) }
        catch {
            // The start of the answer in the log says more than "the data couldn't be read".
            let head = String(decoding: data.prefix(300), as: UTF8.self)
            Log.write("deploys \(args.joined(separator: " ")): unexpected answer (\(error)); it began: \(head)")
            throw ToolError(message: L("Unexpected answer from deploys \(args.first ?? "") – details in the log.",
                                       "Unerwartete Antwort von deploys \(args.first ?? "") – Details im Log."))
        }
    }

    /// At most about 300 characters, keeping the end.
    static func shorten(_ text: String, max: Int = 300) -> String {
        text.count <= max ? text : "… " + String(text.suffix(max))
    }
}

struct ToolError: LocalizedError {
    let message: String
    /// The command was ended after its time ran out: it may have done its work anyway.
    var timedOut = false
    /// The script's exit code when it ended with one (not after a timeout).
    var exitCode: Int32? = nil
    var errorDescription: String? { message }
}

/// Where the app keeps its files. `DEPLOYCENTER_DATA_DIR` moves all of them to one folder; a binary
/// that is no app bundle (the test runner) gets a temporary folder, so a test never writes into
/// the person's journal, caches or log.
enum AppDirs {
    static let override: URL? = {
        if let p = ProcessInfo.processInfo.environment["DEPLOYCENTER_DATA_DIR"], !p.isEmpty { return URL(fileURLWithPath: p, isDirectory: true) }
        guard Bundle.main.bundleIdentifier == nil else { return nil }
        return FileManager.default.temporaryDirectory.appendingPathComponent("dc-data-\(ProcessInfo.processInfo.processIdentifier)", isDirectory: true)
    }()
    /// Application Support: kept (macOS may empty the Caches folder at any time).
    static var support: URL {
        override?.appendingPathComponent("support", isDirectory: true)
            ?? FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0].appendingPathComponent("app.deploycenter.mac", isDirectory: true)
    }
    static var caches: URL {
        override?.appendingPathComponent("caches", isDirectory: true)
            ?? FileManager.default.urls(for: .cachesDirectory, in: .userDomainMask)[0].appendingPathComponent("app.deploycenter.mac", isDirectory: true)
    }
    static var log: URL {
        override?.appendingPathComponent("DeployCenter.log")
            ?? FileManager.default.homeDirectoryForCurrentUser.appendingPathComponent("Library/Logs/DeployCenter.log")
    }
}

/// Errors go to ~/Library/Logs/DeployCenter.log, so one can be attached to an issue.
/// What the script said and when, with keys and tokens masked: a CLI's error can quote one.
enum Log {
    static let url = AppDirs.log
    /// Written in order on its own queue, never on the main thread.
    private static let queue = DispatchQueue(label: "app.deploycenter.log", qos: .utility)
    /// A log from an older version may be readable by others; once per run it is made private.
    private static let privateOnce: Void = { try? FileManager.default.setAttributes([.posixPermissions: 0o600], ofItemAtPath: url.path) }()
    /// From any thread; the file is readable by this user only. Past 1 MB the older half goes,
    /// cut at a line, so no character is split.
    static func write(_ line: String) {
        let text = "\(Date().formatted(.iso8601))  \(LogTools.maskSecrets(line))\n"
        queue.async { append(text) }
    }
    /// Waits until everything written so far is in the file (tests, before reading it).
    static func flush() { queue.sync {} }
    private static func append(_ text: String) {
        _ = privateOnce
        let fm = FileManager.default
        // The throwing calls: the old ones raise an Objective-C exception on a full disk, and the app ends.
        if let h = try? FileHandle(forWritingTo: url) { _ = try? h.seekToEnd(); try? h.write(contentsOf: Data(text.utf8)); try? h.close() }
        else { if AppDirs.override != nil { try? fm.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true) }
               fm.createFile(atPath: url.path, contents: Data(text.utf8), attributes: [.posixPermissions: 0o600]) }
        if let size = try? fm.attributesOfItem(atPath: url.path)[.size] as? Int, size > 1_000_000,
           let data = try? Data(contentsOf: url) {
            var tail = data.suffix(500_000)
            if let nl = tail.firstIndex(of: 10) { tail = tail[(nl + 1)...] }
            try? Data(tail).write(to: url, options: .atomic)
            try? fm.setAttributes([.posixPermissions: 0o600], ofItemAtPath: url.path)
        }
    }
}
