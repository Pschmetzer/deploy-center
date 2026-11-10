// Deploy Center — Updating itself: asking GitHub for the newest release, checking the download, swapping the app.
// Nothing here runs on the main actor; the Store only shows what it says.

import Foundation
import Security

enum Updater {
    static let repo = "Pschmetzer/deploy-center"
    static let bundleID = "app.deploycenter.mac"
    static let appName = "Deploy Center.app"
    static var runningVersion: String { Bundle.main.infoDictionary?["CFBundleShortVersionString"] as? String ?? "0" }

    struct Failure: LocalizedError {
        let message: String
        var errorDescription: String? { message }
    }

    struct Release: Sendable { let version: String; let zip: URL? }

    enum Check: Sendable {
        case found(Release)
        case rateLimited(until: Date?)
        case failed(String)
    }

    /// "0.10.0" is newer than "0.9.1".
    static func isNewer(_ a: String, than b: String) -> Bool { a.compare(b, options: .numeric) == .orderedDescending }

    // MARK: Asking GitHub

    static func latest() async -> Check {
        guard let url = URL(string: "https://api.github.com/repos/\(repo)/releases/latest") else { return .failed("bad URL") }
        var req = URLRequest(url: url, timeoutInterval: 20)
        req.setValue("application/vnd.github+json", forHTTPHeaderField: "Accept")
        req.setValue("DeployCenter", forHTTPHeaderField: "User-Agent")
        let data: Data, resp: URLResponse
        do { (data, resp) = try await URLSession.shared.data(for: req) } catch { return .failed(error.localizedDescription) }
        guard let http = resp as? HTTPURLResponse else { return .failed("no HTTP answer") }
        if let limited = rateLimit(status: http.statusCode, remaining: http.value(forHTTPHeaderField: "X-RateLimit-Remaining"),
                                   reset: http.value(forHTTPHeaderField: "X-RateLimit-Reset")) { return limited }
        guard http.statusCode == 200 else { return .failed("HTTP \(http.statusCode)") }
        guard let obj = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              let tag = obj["tag_name"] as? String else { return .failed("unexpected answer") }
        let assets = obj["assets"] as? [[String: Any]] ?? []
        let zip = assets.compactMap { $0["browser_download_url"] as? String }.first { $0.hasSuffix(".zip") }.flatMap(URL.init(string:))
        return .found(Release(version: tag.trimmingCharacters(in: CharacterSet(charactersIn: "v")), zip: zip))
    }

    /// 429, or 403 with no requests left, is GitHub's limit, not a broken network.
    static func rateLimit(status: Int, remaining: String?, reset: String?) -> Check? {
        guard status == 429 || (status == 403 && remaining == "0") else { return nil }
        return .rateLimited(until: reset.flatMap(Double.init).map { Date(timeIntervalSince1970: $0) })
    }

    /// Only downloads from this repository's releases, over https.
    static func trustedAsset(_ url: URL) -> Bool {
        url.scheme == "https" && url.host?.lowercased() == "github.com" && url.path.hasPrefix("/\(repo)/releases/download/")
    }

    // MARK: Where the app lives

    /// Why the app cannot replace itself where it is, or nil when it can.
    static func locationProblem(_ app: URL) -> String? {
        let path = app.path
        if path.contains("/AppTranslocation/") {
            return L("macOS runs this copy from a temporary place. Move the app to Applications and open it again, or use Download.",
                     "macOS startet diese Kopie von einem temporären Ort. Schieb die App in „Programme“ und öffne sie neu, oder nutze „Herunterladen“.")
        }
        if (try? app.resourceValues(forKeys: [.volumeIsReadOnlyKey]))?.volumeIsReadOnly == true {
            return L("The app runs from a read-only disk (a disk image?). Copy it to Applications first, or use Download.",
                     "Die App läuft von einem schreibgeschützten Laufwerk (Disk-Image?). Kopier sie erst nach „Programme“, oder nutze „Herunterladen“.")
        }
        let parent = app.deletingLastPathComponent().path
        if access(parent, W_OK) != 0 || access(path, W_OK) != 0 {
            return L("No permission to replace the app in \(parent). Use Download and replace it yourself.",
                     "Keine Berechtigung, die App in \(parent) zu ersetzen. Nutze „Herunterladen“ und ersetze sie selbst.")
        }
        return nil
    }

    // MARK: Who signed it

    static func validTeam(_ t: String) -> Bool { t.count == 10 && t.allSatisfy { $0.isASCII && ($0.isUppercase || $0.isNumber) } }

    /// The Team ID the running app is signed with; nil for ad hoc builds.
    static func ownTeamID() -> String? {
        var code: SecCode?
        guard SecCodeCopySelf([], &code) == errSecSuccess, let code else { return nil }
        var stat: SecStaticCode?
        guard SecCodeCopyStaticCode(code, [], &stat) == errSecSuccess, let stat else { return nil }
        var info: CFDictionary?
        guard SecCodeCopySigningInformation(stat, SecCSFlags(rawValue: kSecCSSigningInformation), &info) == errSecSuccess,
              let dict = info as? [String: Any], let team = dict[kSecCodeInfoTeamIdentifier as String] as? String,
              validTeam(team) else { return nil }
        return team
    }

    /// Developer ID, this bundle ID and the same team as the running app.
    static func requirement(team: String) -> String {
        "anchor apple generic and identifier \"\(bundleID)\""
            + " and certificate 1[field.1.2.840.113635.100.6.2.6] exists"
            + " and certificate leaf[field.1.2.840.113635.100.6.1.13] exists"
            + " and certificate leaf[subject.OU] = \"\(team)\""
    }

    // MARK: Swapping

    /// Waits for the app to quit, moves the old app aside, puts the new one in place, rolls back on failure,
    /// starts whichever is there. Paths come in as arguments, never as text in the script:
    /// $1 pid, $2 installed app, $3 new app, $4 temp folder, $5 command that starts the app.
    static let swapScript = """
        pid=$1; target=$2; new=$3; tmp=$4; opener=$5
        i=0
        while kill -0 "$pid" 2>/dev/null; do
          i=$((i + 1)); if [ "$i" -gt 200 ]; then rm -rf "$tmp"; exit 1; fi
          sleep 0.3
        done
        rm -rf "$target.old"
        if mv "$target" "$target.old"; then
          if mv "$new" "$target"; then
            rm -rf "$target.old"
          else
            rm -rf "$target"; mv "$target.old" "$target"
          fi
        fi
        rm -rf "$tmp"
        "$opener" "$target"
        """

    static func swapArguments(pid: Int32, target: String, new: String, tmp: String, opener: String = "/usr/bin/open") -> [String] {
        ["-c", swapScript, "deploycenter-update", String(pid), target, new, tmp, opener]
    }

    /// A checked download, ready to swap in. `launch()` hands it to the script; `discard()` removes it.
    struct Prepared: Sendable {
        let dir: URL, app: URL, version: String
        func launch(target: URL) throws {
            let sh = Process(); sh.executableURL = URL(fileURLWithPath: "/bin/sh")
            sh.arguments = Updater.swapArguments(pid: ProcessInfo.processInfo.processIdentifier, target: target.path, new: app.path, tmp: dir.path)
            try sh.run()
        }
        func discard() { try? FileManager.default.removeItem(at: dir) }
    }

    /// Downloads the release, unpacks it and checks bundle ID, version and signature. The temp folder is gone on every failure.
    static func prepare(_ rel: Release, current: String, team: String, progress: @escaping @Sendable (String) async -> Void) async throws -> Prepared {
        guard let zip = rel.zip else { throw Failure(message: L("No download found in the release.", "Im Release ist kein Download.")) }
        guard trustedAsset(zip) else { throw Failure(message: L("The download is not on GitHub.", "Der Download liegt nicht auf GitHub.") + " (\(zip.host ?? "?"))") }
        guard isNewer(rel.version, than: current) else {
            throw Failure(message: L("You have the newest version (\(current)).", "Du hast die neueste Version (\(current)).")) }
        let fm = FileManager.default
        let dir = fm.temporaryDirectory.appendingPathComponent("deploycenter-update-\(UUID().uuidString)")
        try fm.createDirectory(at: dir, withIntermediateDirectories: true)
        do {
            await progress(L("Downloading …", "Lade herunter …"))
            var req = URLRequest(url: zip, timeoutInterval: 120)
            req.setValue("DeployCenter", forHTTPHeaderField: "User-Agent")
            let (tmpZip, resp) = try await URLSession.shared.download(for: req)
            let zipFile = dir.appendingPathComponent("release.zip")
            try fm.moveItem(at: tmpZip, to: zipFile)
            guard let http = resp as? HTTPURLResponse, http.statusCode == 200 else {
                throw Failure(message: L("Download failed", "Download fehlgeschlagen") + " (HTTP \((resp as? HTTPURLResponse)?.statusCode ?? 0))")
            }
            let out = dir.appendingPathComponent("unpacked")
            try await run("/usr/bin/ditto", ["-x", "-k", zipFile.path, out.path])
            try? fm.removeItem(at: zipFile)
            let app = out.appendingPathComponent(appName)
            var isDir: ObjCBool = false
            guard fm.fileExists(atPath: app.path, isDirectory: &isDir), isDir.boolValue,
                  (try? app.resourceValues(forKeys: [.isSymbolicLinkKey]))?.isSymbolicLink != true else {
                throw Failure(message: L("Unexpected download.", "Unerwarteter Download."))
            }
            try checkBundle(app, expected: rel.version, current: current)
            await progress(L("Checking the signature …", "Prüfe die Signatur …"))
            try await run("/usr/bin/codesign", ["--verify", "--deep", "--strict", "-R", "=" + requirement(team: team), app.path])
            try await run("/usr/sbin/spctl", ["-a", "-t", "exec", "-vv", app.path])
            return Prepared(dir: dir, app: app, version: rel.version)
        } catch {
            try? fm.removeItem(at: dir)
            throw error
        }
    }

    /// Same bundle ID, the version the release names, and newer than what runs.
    static func checkBundle(_ app: URL, expected: String, current: String) throws {
        guard let data = try? Data(contentsOf: app.appendingPathComponent("Contents/Info.plist")),
              let plist = try? PropertyListSerialization.propertyList(from: data, format: nil) as? [String: Any] else {
            throw Failure(message: L("The download has no Info.plist.", "Der Download hat keine Info.plist."))
        }
        let id = plist["CFBundleIdentifier"] as? String ?? "", v = plist["CFBundleShortVersionString"] as? String ?? ""
        guard id == bundleID else { throw Failure(message: L("The download is a different app (\(id)).", "Der Download ist eine andere App (\(id)).")) }
        guard v == expected else { throw Failure(message: L("The download says version \(v), the release \(expected).", "Der Download sagt Version \(v), das Release \(expected).")) }
        guard isNewer(v, than: current) else { throw Failure(message: L("The download (\(v)) is not newer than \(current).", "Der Download (\(v)) ist nicht neuer als \(current).")) }
    }

    /// Runs a tool off the main actor; what it says goes to the log, the first line into the error.
    static func run(_ exe: String, _ args: [String]) async throws {
        let (status, text) = try await Task.detached { () throws -> (Int32, String) in
            let p = Process(); p.executableURL = URL(fileURLWithPath: exe); p.arguments = args
            let pipe = Pipe(); p.standardOutput = pipe; p.standardError = pipe
            try p.run()
            let data = pipe.fileHandleForReading.readDataToEndOfFile()
            p.waitUntilExit()
            return (p.terminationStatus, String(decoding: data, as: UTF8.self).trimmingCharacters(in: .whitespacesAndNewlines))
        }.value
        let name = (exe as NSString).lastPathComponent
        if !text.isEmpty { Log.write("update \(name): \(text)") }
        guard status == 0 else {
            let first = text.split(separator: "\n").first.map(String.init) ?? ""
            throw Failure(message: "\(name) \(status)" + (first.isEmpty ? "" : ": \(first)"))
        }
    }
}
