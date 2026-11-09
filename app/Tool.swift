// Deploy Center — Calling the bundled `deploys` script, the language, the error log.

import SwiftUI
import AppKit
import Charts
import UserNotifications
import ServiceManagement

// MARK: - Language (German if the Mac prefers it, English otherwise)

let isGerman = (Locale.preferredLanguages.first ?? "en").hasPrefix("de")
func L(_ en: String, _ de: String) -> String { isGerman ? de : en }

// MARK: - Calling the script

enum Tool {
    /// The script ships inside the app, so a download needs nothing but the app.
    static var path: String {
        Bundle.main.path(forResource: "deploys", ofType: nil) ?? NSHomeDirectory() + "/bin/deploys"
    }

    /// The PATH of the person's login shell, read once, so `vercel` installed through nvm, volta or
    /// fnm is found too. The usual places come first in case the shell says nothing in time.
    static let searchPath: String = {
        // Reading it starts a login shell (up to 3 s); once a day is enough.
        let d = UserDefaults.standard
        if let saved = d.string(forKey: "searchPath"), Date().timeIntervalSince1970 - d.double(forKey: "searchPathAt") < 86400 { return saved }
        let result = computeSearchPath()
        d.set(result, forKey: "searchPath"); d.set(Date().timeIntervalSince1970, forKey: "searchPathAt")
        return result
    }()

    private static func computeSearchPath() -> String {
        let fixed = "/opt/homebrew/bin:/usr/local/bin:" + NSHomeDirectory() + "/.local/bin:/usr/bin:/bin:/usr/sbin:/sbin"
        let p = Process()
        p.executableURL = URL(fileURLWithPath: ProcessInfo.processInfo.environment["SHELL"] ?? "/bin/zsh")
        p.arguments = ["-lc", "printf %s \"$PATH\""]
        let out = Pipe(); p.standardOutput = out; p.standardError = FileHandle.nullDevice
        guard (try? p.run()) != nil else { return fixed }
        let killer = DispatchWorkItem { if p.isRunning { p.terminate() } }
        DispatchQueue.global().asyncAfter(deadline: .now() + 3, execute: killer)
        let data = out.fileHandleForReading.readDataToEndOfFile()
        p.waitUntilExit(); killer.cancel()
        let shell = String(data: data, encoding: .utf8)?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
        return shell.isEmpty ? fixed : fixed + ":" + shell
    }

    /// Runs off the main thread. A GUI app does not get the shell's PATH, and `vercel` needs node.
    /// stdout and stderr are read at the same time (reading one to the end first can deadlock
    /// once the other fills its pipe), and a command that hangs is ended after `timeout` seconds.
    static func run(_ args: [String], stdin: String? = nil, timeout: Double = 120) async throws -> Data {
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
                do { try p.run() } catch { cont.resume(throwing: error); return }
                var errData = Data()
                let errDone = DispatchGroup()
                errDone.enter()
                DispatchQueue.global().async { errData = err.fileHandleForReading.readDataToEndOfFile(); errDone.leave() }
                var timedOut = false
                let killer = DispatchWorkItem { if p.isRunning { timedOut = true; p.terminate() } }
                DispatchQueue.global().asyncAfter(deadline: .now() + timeout, execute: killer)
                let data = out.fileHandleForReading.readDataToEndOfFile()
                errDone.wait()
                p.waitUntilExit()
                killer.cancel()
                if timedOut {
                    cont.resume(throwing: ToolError(message: L("No answer after \(Int(timeout)) seconds – try again.",
                                                              "Keine Antwort nach \(Int(timeout)) Sekunden – nochmal versuchen.")))
                } else if p.terminationStatus == 0 {
                    cont.resume(returning: data)
                } else {
                    let msg = String(data: errData, encoding: .utf8)?
                        .trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
                    let text = msg.isEmpty ? "Exit code \(p.terminationStatus)" : msg
                    Log.write("deploys \(args.joined(separator: " ")): \(text)")
                    cont.resume(throwing: ToolError(message: text))
                }
            }
        }
    }

    static func json<T: Decodable>(_ args: [String], as type: T.Type) async throws -> T {
        try JSONDecoder().decode(T.self, from: try await run(args))
    }
}

struct ToolError: LocalizedError {
    let message: String
    var errorDescription: String? { message }
}

/// Errors go to ~/Library/Logs/DeployCenter.log, so one can be attached to an issue.
/// Only what the script said and when; no keys ever reach the script's output.
enum Log {
    static let url = FileManager.default.homeDirectoryForCurrentUser.appendingPathComponent("Library/Logs/DeployCenter.log")
    static func write(_ line: String) {
        let text = "\(Date().formatted(.iso8601))  \(line)\n"
        if let h = try? FileHandle(forWritingTo: url) { h.seekToEndOfFile(); h.write(Data(text.utf8)); try? h.close() }
        else { try? Data(text.utf8).write(to: url) }
        // Kept small: past 1 MB the older half goes.
        if let size = try? FileManager.default.attributesOfItem(atPath: url.path)[.size] as? Int, size > 1_000_000,
           let data = try? Data(contentsOf: url) { try? data.suffix(500_000).write(to: url) }
    }
}
