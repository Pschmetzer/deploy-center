// Deploy Center — Calling the bundled `deploys` script, the language, the error log.

import SwiftUI
import AppKit
import Charts
import UserNotifications
import ServiceManagement

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

/// Quits after asking when deploys run, and opens the app again. No `open -n`: if the quit is
/// cancelled, `open` only brings the running copy forward, so there are never two.
@MainActor func relaunchApp(running deploys: Int) {
    if deploys > 0 {
        NSApp.activate(ignoringOtherApps: true)
        let a = NSAlert()
        a.messageText = L("\(deploys) \(deploys == 1 ? "deploy is" : "deploys are") still running", "\(deploys) \(deploys == 1 ? "Deploy läuft" : "Deploys laufen") noch")
        a.informativeText = L("Builds that already started go on at Vercel or Render, but Deploy Center stops following them and queued ones do not start.",
                              "Gestartete Builds laufen bei Vercel oder Render weiter, aber Deploy Center verfolgt sie nicht mehr, und wartende starten nicht.")
        a.addButton(withTitle: L("Keep running", "Weiterlaufen lassen"))
        a.addButton(withTitle: L("Restart anyway", "Trotzdem neu starten"))
        guard a.runModal() == .alertSecondButtonReturn else { return }
    }
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
        if let bundled = Bundle.main.path(forResource: "deploys", ofType: nil) { return bundled }
        noteFallback()
        return NSHomeDirectory() + "/bin/deploys"
    }
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
        // A saved PATH with a folder that is gone (nvm, fnm or volta moved to another node) is read anew.
        if let saved = d.string(forKey: "searchPath"), Date().timeIntervalSince1970 - d.double(forKey: "searchPathAt") < 86400,
           pathFoldersExist(saved) { return saved }
        let (result, complete) = computeSearchPath()
        if complete { d.set(result, forKey: "searchPath"); d.set(Date().timeIntervalSince1970, forKey: "searchPathAt") }
        return result
    }()

    /// Every folder of a PATH below the home folder still exists (system folders are not checked).
    static func pathFoldersExist(_ path: String) -> Bool {
        let home = FileManager.default.homeDirectoryForCurrentUser.path
        return path.split(separator: ":").map(String.init).filter { $0.hasPrefix(home) }
            .allSatisfy { FileManager.default.fileExists(atPath: $0) }
    }

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

    private static func runProcess(_ args: [String], stdin: String?, timeout: Double, running: Running) async throws -> Data {
        try await withCheckedThrowingContinuation { cont in
            DispatchQueue.global(qos: .userInitiated).async {
                let p = Process()
                p.executableURL = URL(fileURLWithPath: "/bin/bash")
                p.arguments = [path] + args
                var env = ProcessInfo.processInfo.environment
                env["PATH"] = searchPath
                p.environment = env
                let out = Pipe(), err = Pipe()
                p.standardOutput = out
                p.standardError = err
                if let stdin {
                    let inPipe = Pipe()
                    p.standardInput = inPipe
                    inPipe.fileHandleForWriting.write(Data((stdin + "\n").utf8))
                    try? inPipe.fileHandleForWriting.close()
                }
                // Cancelled before it started: nothing is started at all.
                if running.isCancelled { cont.resume(throwing: CancellationError()); return }
                do { try p.run() } catch { cont.resume(throwing: error); return }
                if !running.started(p.processIdentifier) { killTree(p.processIdentifier) }
                // Pipes, the timeout and the answer meet here from several queues; the lock keeps
                // them apart, and the answer is given exactly once.
                let lock = NSLock()
                var outData = Data(), errData = Data(), timedOut = false, answered = false
                func answer(_ r: Result<Data, Error>) {
                    lock.lock(); defer { lock.unlock() }
                    guard !answered else { return }
                    answered = true
                    if running.isCancelled { cont.resume(throwing: CancellationError()); return }
                    if case .failure(let e as ToolError) = r, e.timedOut {
                        Log.write("deploys \(args.joined(separator: " ")): no answer after \(Int(timeout)) s, ended")
                    }
                    cont.resume(with: r)
                }
                func timeoutError() -> ToolError {
                    ToolError(message: L("No answer after \(Int(timeout)) seconds – try again.",
                                                "Keine Antwort nach \(Int(timeout)) Sekunden – nochmal versuchen."), timedOut: true)
                }
                let read = DispatchGroup()
                read.enter(); read.enter()
                DispatchQueue.global().async { let d = out.fileHandleForReading.readDataToEndOfFile(); lock.lock(); outData = d; lock.unlock(); read.leave() }
                DispatchQueue.global().async { let d = err.fileHandleForReading.readDataToEndOfFile(); lock.lock(); errData = d; lock.unlock(); read.leave() }
                // Ending bash alone is not enough: `vercel`, node or curl under it keep the pipes open.
                // Whatever still holds them three seconds later, the caller gets its answer.
                let killer = DispatchWorkItem {
                    guard p.isRunning else { return }
                    lock.lock(); timedOut = true; lock.unlock()
                    killTree(p.processIdentifier)
                    DispatchQueue.global().asyncAfter(deadline: .now() + 3) { answer(.failure(timeoutError())) }
                }
                DispatchQueue.global().asyncAfter(deadline: .now() + timeout, execute: killer)
                read.wait()
                p.waitUntilExit()
                running.finished()
                killer.cancel()
                lock.lock(); let late = timedOut, data = outData, errText = errData; lock.unlock()
                if late {
                    answer(.failure(timeoutError()))
                } else if p.terminationStatus == 0 {
                    answer(.success(data))
                } else {
                    let msg = String(data: errText, encoding: .utf8)?
                        .trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
                    let text = msg.isEmpty ? "Exit code \(p.terminationStatus)" : msg
                    Log.write("deploys \(args.joined(separator: " ")): \(text)")
                    // The whole text is in the log; a toast or a row gets the end, where the cause usually is.
                    answer(.failure(ToolError(message: shorten(text), exitCode: p.terminationStatus)))
                }
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
    /// The script's exit code, when it ended by itself with one other than 0.
    var exitCode: Int32? = nil
    var errorDescription: String? { message }
}

/// Errors go to ~/Library/Logs/DeployCenter.log, so one can be attached to an issue.
/// Only what the script said and when; no keys ever reach the script's output.
enum Log {
    static let url = FileManager.default.homeDirectoryForCurrentUser.appendingPathComponent("Library/Logs/DeployCenter.log")
    private static let lock = NSLock()
    /// A log from an older version may be readable by others; once per run it is made private.
    private static let privateOnce: Void = { try? FileManager.default.setAttributes([.posixPermissions: 0o600], ofItemAtPath: url.path) }()
    /// From any thread; the file is readable by this user only. Past 1 MB the older half goes,
    /// cut at a line, so no character is split.
    static func write(_ line: String) {
        lock.lock(); defer { lock.unlock() }
        _ = privateOnce
        // Further lines of a message are indented, so each entry still starts with its time.
        let text = "\(Date().formatted(.iso8601))  \(line.replacingOccurrences(of: "\n", with: "\n    "))\n"
        let fm = FileManager.default
        // The throwing calls: the old seekToEndOfFile/write raise an exception on a full disk.
        if let h = try? FileHandle(forWritingTo: url) {
            do { try h.seekToEnd(); try h.write(contentsOf: Data(text.utf8)) } catch {}
            try? h.close()
        }
        else { fm.createFile(atPath: url.path, contents: Data(text.utf8), attributes: [.posixPermissions: 0o600]) }
        if let size = try? fm.attributesOfItem(atPath: url.path)[.size] as? Int, size > 1_000_000,
           let data = try? Data(contentsOf: url) {
            var tail = data.suffix(500_000)
            if let nl = tail.firstIndex(of: 10) { tail = tail[(nl + 1)...] }
            try? Data(tail).write(to: url, options: .atomic)
            try? fm.setAttributes([.posixPermissions: 0o600], ofItemAtPath: url.path)
        }
    }
}
