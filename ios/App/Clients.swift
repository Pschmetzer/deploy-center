// Deploy Center for iPhone — The three REST APIs, called directly with the person's own tokens.
// The calls follow the `deploys` CLI of the Mac app, so both decide "waiting" the same way.

import Foundation

typealias JSON = [String: Any]

struct APIError: LocalizedError {
    let status: Int
    let message: String
    /// GitHub answers a spent rate limit with 403 and X-RateLimit-Remaining: 0, others with 429.
    /// The status stays as it came: callers decide by it.
    var rateLimited = false
    /// When the limit is free again, if the answer said so (`Retry-After`, `x-ratelimit-reset`).
    var retryAt: Date? = nil

    /// What to do about it, not only the HTTP code.
    var errorDescription: String? {
        // Thrown with the time it is free again (HTTP.limitText).
        if rateLimited && !message.isEmpty { return message }
        if rateLimited || status == 429 { return L("Rate limit reached. Try again later.", "Limit erreicht. Versuch es später noch einmal.") }
        switch status {
        case 0: return message
        case 401: return L("The key was refused: wrong or expired (HTTP 401). Check it in Settings.",
                           "Der Schlüssel wurde abgelehnt: falsch oder abgelaufen (HTTP 401). In den Einstellungen prüfen.")
        case 403: return L("The key lacks the rights for this (HTTP 403): \(message)",
                           "Dem Schlüssel fehlen die Rechte dafür (HTTP 403): \(message)")
        case 404: return L("Not found (HTTP 404): \(message)", "Nicht gefunden (HTTP 404): \(message)")
        case 500...: return L("The service has a problem (HTTP \(status)). Try again later.",
                              "Der Dienst hat ein Problem (HTTP \(status)). Versuch es später noch einmal.")
        default: return "HTTP \(status): \(message)"
        }
    }
    /// A key problem the person can fix in Settings.
    var isAuth: Bool { !rateLimited && (status == 401 || status == 403) }
}

/// A POST that failed without a clear "no": the request may have arrived and started a build anyway.
/// A lost connection, a timeout and a 5xx from the service or a gateway (502, 504) all qualify.
func deployMayHaveStarted(_ error: Error) -> Bool {
    if let u = error as? URLError { return u.code != .cancelled }
    if let e = error as? APIError { return e.status >= 500 && !e.rateLimited }
    return false
}

/// What `follow` does with a failed poll.
enum PollFailure: Equatable {
    case stop                 // a refused key or a deploy that is gone: polling will not help
    case wait(TimeInterval)   // rate limited until then
    case retry                // a transient error: the next poll tries again
    /// A 404 right after the start can still be the provider catching up: the first 15 s do not count.
    static func decide(_ error: Error, elapsed: TimeInterval, now: Date = Date()) -> PollFailure {
        guard let e = error as? APIError else { return .retry }
        if e.rateLimited { return .wait(max(1, e.retryAt.map { $0.timeIntervalSince(now) } ?? 0)) }
        if e.isAuth || e.status == 401 { return .stop }
        if e.status == 404 && elapsed > 15 { return .stop }
        return .retry
    }
}

/// A network error in words; everything else as it describes itself.
func explain(_ error: Error) -> String {
    if let u = error as? URLError {
        switch u.code {
        case .notConnectedToInternet, .networkConnectionLost, .dataNotAllowed:
            return L("No connection to the internet.", "Keine Verbindung zum Internet.")
        case .timedOut: return L("No answer in time. Try again.", "Keine Antwort in der Zeit. Versuch es noch einmal.")
        case .cannotFindHost, .cannotConnectToHost, .dnsLookupFailed:
            return L("The service cannot be reached.", "Der Dienst ist nicht erreichbar.")
        case .secureConnectionFailed, .serverCertificateUntrusted, .serverCertificateHasBadDate, .serverCertificateNotYetValid, .clientCertificateRejected:
            return L("The secure connection failed. A network with a login page or a proxy can cause this.",
                     "Die sichere Verbindung ist fehlgeschlagen. Ein Netz mit Anmeldeseite oder ein Proxy kann der Grund sein.")
        case .cancelled: return L("Canceled.", "Abgebrochen.")
        case .cannotParseResponse, .badServerResponse:
            return L("The answer could not be read. Try again.", "Die Antwort konnte nicht gelesen werden. Versuch es noch einmal.")
        case .internationalRoamingOff:
            return L("Data roaming is off, so there is no connection.", "Datenroaming ist aus, daher gibt es keine Verbindung.")
        case .callIsActive:
            return L("A phone call is active and blocks the data connection. Try again after it.", "Ein Anruf blockiert die Datenverbindung. Versuch es danach noch einmal.")
        default: break
        }
    }
    // HTML from a login page or a proxy instead of JSON.
    if error is DecodingError || (error as NSError).domain == NSCocoaErrorDomain && (error as NSError).code == 3840 {
        return L("The answer is not JSON. Is this network asking for a login?", "Die Antwort ist kein JSON. Verlangt dieses Netz eine Anmeldung?")
    }
    return error.localizedDescription
}

/// One small HTTP helper: Bearer token, JSON in and out. GETs are retried twice on 5xx, 429 and a
/// dropped connection; a POST never, it may already have started a build.
struct HTTP {
    let base: String
    let token: String
    var extraHeaders: [String: String] = [:]
    /// Ask with `If-None-Match` and reuse the answer on 304 (GitHub: with a token, a 304 does not count against the limit).
    var conditional = false
    /// Tests pass a session that answers from recorded JSON.
    var session: URLSession = HTTP.defaultSession

    /// No disk cache: GitHub sends `max-age=60`, so a cached branch head could hide a fresh push,
    /// and answers with commit texts would otherwise lie on the disk. ETags are kept in memory only.
    /// Waits for a connection instead of failing at once.
    static let defaultSession: URLSession = {
        let c = URLSessionConfiguration.ephemeral
        c.requestCachePolicy = .reloadIgnoringLocalCacheData
        c.urlCache = nil
        c.waitsForConnectivity = true
        c.timeoutIntervalForRequest = 30
        c.timeoutIntervalForResource = 60
        let v = Bundle.main.object(forInfoDictionaryKey: "CFBundleShortVersionString") as? String ?? "1"
        c.httpAdditionalHeaders = ["User-Agent": "DeployCenter-iOS/\(v)"]
        return URLSession(configuration: c)
    }()
    /// For what must not wait for a network: writes (a deploy that starts a minute later is a surprise) and
    /// the background refresh (about 30 s in all).
    static let noWaitSession: URLSession = {
        let c = URLSessionConfiguration.ephemeral
        c.requestCachePolicy = .reloadIgnoringLocalCacheData
        c.urlCache = nil
        c.waitsForConnectivity = false
        c.timeoutIntervalForRequest = 30
        c.timeoutIntervalForResource = 60
        let v = Bundle.main.object(forInfoDictionaryKey: "CFBundleShortVersionString") as? String ?? "1"
        c.httpAdditionalHeaders = ["User-Agent": "DeployCenter-iOS/\(v)"]
        return URLSession(configuration: c)
    }()
    /// Set for the background refresh (about 30 s in all): shorter waits, so one slow call cannot use it up.
    @TaskLocal static var inBackground = false
    /// Longer waits than this are not slept through: the call fails with the time.
    static var longestWait: Double { inBackground ? 2 : 8 }
    static var timeout: TimeInterval { inBackground ? 10 : 30 }
    /// A dropped connection is tried again (GETs only).
    private static let retryable: Set<URLError.Code> = [.timedOut, .networkConnectionLost, .cannotConnectToHost, .dnsLookupFailed]

    func request(_ method: String, _ path: String, body: Any? = nil) async throws -> Any {
        try await send(method, path, body: body).json
    }

    func send(_ method: String, _ path: String, body: Any? = nil) async throws -> (json: Any, response: HTTPURLResponse?) {
        guard let url = URL(string: base + path) else { throw APIError(status: 0, message: "bad URL") }
        var r = URLRequest(url: url, timeoutInterval: Self.timeout)
        r.httpMethod = method
        // No header at all without a token: GitHub answers an empty "Bearer " with 401.
        if !token.isEmpty { r.setValue("Bearer \(token)", forHTTPHeaderField: "Authorization") }
        r.setValue("application/json", forHTTPHeaderField: "Accept")
        for (k, v) in extraHeaders { r.setValue(v, forHTTPHeaderField: k) }
        if let body {
            r.setValue("application/json", forHTTPHeaderField: "Content-Type")
            r.httpBody = try JSONSerialization.data(withJSONObject: body)
        }
        // Tests pass their own session: only the default one is swapped.
        let via = session === HTTP.defaultSession && (method != "GET" || Self.inBackground) ? HTTP.noWaitSession : session
        let tag = conditional && method == "GET" ? ETags.shared.key(url, token) : nil
        let cached = tag.flatMap { ETags.shared.get($0) }
        if let cached { r.setValue(cached.etag, forHTTPHeaderField: "If-None-Match") }
        var attempt = 0
        while true {
            attempt += 1
            let fresh: Data, resp: URLResponse
            do { (fresh, resp) = try await via.data(for: r) }
            catch let e as URLError where method == "GET" && attempt < 3 && Self.retryable.contains(e.code) {
                try await Task.sleep(for: .seconds(min(Double(2 * attempt), Self.longestWait))); continue
            }
            let http = resp as? HTTPURLResponse
            var code = http?.statusCode ?? 0
            var data = fresh
            // Unchanged since the last read: the answer kept in memory.
            if code == 304, let cached { code = 200; data = cached.data }
            let limited = code == 429 || Self.rateLimited(http)
            // Never retry a POST: it may already have started a build.
            if method == "GET", attempt < 3, limited || code >= 500 {
                let wait = Self.retryAfter(http) ?? Double(3 * attempt)
                if wait <= Self.longestWait { try await Task.sleep(for: .seconds(max(1, wait))); continue }
            }
            guard (200..<300).contains(code) else {
                if limited {
                    throw APIError(status: code, message: Self.limitText(http), rateLimited: true,
                                   retryAt: Self.retryAfter(http).map { Date().addingTimeInterval($0) })
                }
                let obj = try? JSONSerialization.jsonObject(with: data) as? JSON
                let raw = ((obj?["error"] as? JSON)?["message"] as? String) ?? (obj?["message"] as? String)
                    ?? Self.plainBody(data)
                // An error text can echo a token or a header: it goes through the log masking before a toast shows it (IDEEN-12 C18).
                let msg = LogMask.mask(String(raw.prefix(300))) ?? ""
                throw APIError(status: code, message: msg, rateLimited: limited)
            }
            if let tag, http?.statusCode == 200, let etag = http?.value(forHTTPHeaderField: "etag") {
                ETags.shared.set(tag, etag: etag, data: data)
            }
            if data.isEmpty { return (JSON(), http) }
            return (try JSONSerialization.jsonObject(with: data), http)
        }
    }

    /// GitHub's primary limit comes as 403 (or 429) with `x-ratelimit-remaining: 0`.
    /// The start of a plain-text error body. An HTML page (a proxy or CDN error) says nothing: empty then.
    static func plainBody(_ data: Data) -> String {
        let t = (String(data: data.prefix(200), encoding: .utf8) ?? "").trimmingCharacters(in: .whitespacesAndNewlines)
        return t.hasPrefix("<") ? "" : t
    }
    static func rateLimited(_ r: HTTPURLResponse?) -> Bool {
        guard let r, r.statusCode == 403 || r.statusCode == 429 else { return false }
        return r.value(forHTTPHeaderField: "x-ratelimit-remaining") == "0" || r.value(forHTTPHeaderField: "retry-after") != nil
    }
    /// Seconds to wait: `Retry-After` (seconds or a date), else GitHub's `x-ratelimit-reset` (epoch seconds).
    static func retryAfter(_ r: HTTPURLResponse?) -> Double? {
        guard let r else { return nil }
        if let v = r.value(forHTTPHeaderField: "retry-after") {
            if let s = Double(v.trimmingCharacters(in: .whitespaces)) { return max(0, s) }
            let f = DateFormatter(); f.locale = Locale(identifier: "en_US_POSIX"); f.dateFormat = "EEE, dd MMM yyyy HH:mm:ss zzz"
            if let d = f.date(from: v) { return max(0, d.timeIntervalSinceNow) }
        }
        if r.value(forHTTPHeaderField: "x-ratelimit-remaining") == "0",
           let reset = r.value(forHTTPHeaderField: "x-ratelimit-reset").flatMap(Double.init) {
            return max(0, reset - Date().timeIntervalSince1970)
        }
        return nil
    }
    static func limitText(_ r: HTTPURLResponse?) -> String {
        guard let wait = retryAfter(r) else { return L("Rate limit reached. Try again later.", "Abruflimit erreicht. Später erneut versuchen.") }
        let at = Date().addingTimeInterval(wait).formatted(Date.FormatStyle(date: .omitted, time: .shortened).locale(appLocale))
        return L("Rate limit reached, free again at \(at).", "Abruflimit erreicht, wieder frei um \(at).")
    }
    func get(_ path: String) async throws -> Any { try await request("GET", path) }
}

/// GitHub's ETags and the answers they belong to, in memory only (gone when the app quits).
/// Keyed by token and URL, so an answer read with one token never serves another.
final class ETags: @unchecked Sendable {
    static let shared = ETags()
    private let lock = NSLock()
    private var items: [String: (etag: String, data: Data)] = [:]
    private var order: [String] = []
    private let limit = 500
    /// A `compare` answer can hold 250 commits: the count alone does not bound the memory.
    private let byteLimit = 4_000_000
    private var bytes = 0

    func key(_ url: URL, _ token: String) -> String { String(token.hashValue) + " " + url.absoluteString }
    func get(_ k: String) -> (etag: String, data: Data)? { lock.lock(); defer { lock.unlock() }; return items[k] }
    func set(_ k: String, etag: String, data: Data) {
        lock.lock(); defer { lock.unlock() }
        if let old = items[k] { bytes -= old.data.count } else { order.append(k) }
        items[k] = (etag, data); bytes += data.count
        while order.count > limit || (bytes > byteLimit && order.count > 1) {
            let gone = order.removeFirst()
            if let o = items.removeValue(forKey: gone) { bytes -= o.data.count }
        }
    }
    func removeAll() { lock.lock(); items = [:]; order = []; bytes = 0; lock.unlock() }
}

extension Dictionary where Key == String, Value == Any {
    subscript(path p: String) -> Any? {
        var cur: Any? = self
        for k in p.split(separator: ".") { cur = (cur as? JSON)?[String(k)] }
        return cur
    }
    func str(_ p: String) -> String? { self[path: p] as? String }
    func int(_ p: String) -> Int? { (self[path: p] as? NSNumber)?.intValue }
}

/// Made once: a load reads hundreds of dates. ISO8601DateFormatter is safe to share between threads.
private let isoFractional: ISO8601DateFormatter = {
    let f = ISO8601DateFormatter(); f.formatOptions = [.withInternetDateTime, .withFractionalSeconds]; return f
}()
private let isoPlain: ISO8601DateFormatter = {
    let f = ISO8601DateFormatter(); f.formatOptions = [.withInternetDateTime]; return f
}()

func isoDate(_ s: String?) -> Date? {
    guard let s else { return nil }
    return isoFractional.date(from: s) ?? isoPlain.date(from: s)
}

func firstLine(_ s: String?) -> String? { s.map { String($0.split(separator: "\n").first ?? "") } }

/// A repo URL or "owner/name": the "owner/name" on GitHub, or the host it lives on instead.
enum RepoRef {
    static func parse(_ s: String) -> (github: String?, otherHost: String?) {
        var t = s.trimmingCharacters(in: .whitespaces)
        if t.hasSuffix(".git") { t.removeLast(4) }
        if t.hasSuffix("/") { t.removeLast() }
        // user@host:owner/name (scp style), or scheme://[user[:password]@]host[:port]/owner/name
        let scheme = t.range(of: "://")
        let scp = scheme == nil && t.contains("@") && t.contains(":")
        guard scheme != nil || scp else { return (t.isEmpty ? nil : t, nil) }
        let authority: String, path: String
        if let r = scheme {
            let rest = String(t[r.upperBound...])
            authority = String(rest.prefix { $0 != "/" })
            path = String(rest.dropFirst(authority.count + 1))
        } else {
            authority = String(t.prefix { $0 != ":" })
            path = String(t.dropFirst(authority.count + 1))
        }
        // The host alone: no user or password in front, no port behind.
        var host = String(authority.split(separator: "@", omittingEmptySubsequences: false).last ?? "")
        if !scp, let c = host.firstIndex(of: ":") { host = String(host[..<c]) }
        let h = host.lowercased().replacingOccurrences(of: "www.", with: "")
        if h == "github.com" { return (path.isEmpty ? nil : path, nil) }
        let name = h.contains("gitlab") ? "GitLab" : h.contains("bitbucket") ? "Bitbucket" : host
        return (nil, name)
    }
}

/// The deploy a rollback goes back to, for the question before it: commit, first line of its message, time.
struct RollbackTarget: Equatable {
    let id: String
    let sha: String?
    var title: String? = nil
    var at: Date? = nil
}

/// One deploy in a project's history (newest first in lists).
/// How often a followed deploy is asked for: every 6 s at first (short builds end soon), every 15 s after two
/// minutes, every 30 s after ten. Fewer than 100 asks in 20 minutes instead of 200: kinder to the battery
/// and to the provider's rate limit.
enum PollEvery {
    static func seconds(elapsed: TimeInterval) -> Double { elapsed < 120 ? 6 : elapsed < 600 ? 15 : 30 }
}

/// How long this project's builds usually take: the median of the finished ones in the history. Nil with
/// fewer than three (then the progress shows the old five-minute guess).
enum BuildTime {
    static func typical(_ records: [DeployRecord]) -> TimeInterval? {
        let d = records.compactMap { r -> TimeInterval? in
            guard !r.failed, let a = r.at, let b = r.finishedAt else { return nil }
            let t = b.timeIntervalSince(a)
            return t >= 5 && t <= 3600 ? t : nil
        }.sorted()
        return d.count >= 3 ? d[d.count / 2] : nil
    }
    /// Progress for the system bar: never full before the end, and not stuck at 95 % for a slow build.
    static func fraction(elapsed: TimeInterval, typical: TimeInterval?) -> Double {
        let t = max(typical ?? 300, 10)
        return min(elapsed / t, 0.95)
    }
}

struct DeployRecord: Identifiable, Equatable, Codable {
    let id: String
    let state: String
    let at: Date?
    var finishedAt: Date? = nil
    var sha: String? = nil
    var title: String? = nil
    /// What is live now: not offered as "make live again".
    var current = false
    var failed: Bool { PhoneProject.failedStates.contains(state.lowercased()) && state.lowercased() != "canceled" }
    /// Built and once live: can go live again (a rollback to it).
    var reusable: Bool { ["ready", "live", "deactivated"].contains(state.lowercased()) && !current }
    var target: RollbackTarget { RollbackTarget(id: id, sha: sha, title: title, at: at) }
}

// MARK: - Vercel

struct Vercel {
    let http: HTTP
    let team: String?
    init(token: String, team: String?, session: URLSession = HTTP.defaultSession) {
        http = HTTP(base: "https://api.vercel.com", token: token, session: session)
        self.team = (team?.isEmpty ?? true) ? nil : team
    }
    /// A team id is letters, digits, _ and -: anything else (& or =, from a pasted value) is encoded, so it cannot add a parameter.
    static let idCharacters = CharacterSet(charactersIn: "abcdefghijklmnopqrstuvwxyzABCDEFGHIJKLMNOPQRSTUVWXYZ0123456789_-")
    private func t(_ path: String) -> String {
        guard let team else { return path }
        return path + (path.contains("?") ? "&" : "?") + "teamId=" + (team.addingPercentEncoding(withAllowedCharacters: Vercel.idCharacters) ?? team)
    }

    /// With no team set: one team is used, none means the personal account.
    /// `teams` is how many there are: with more than one, nobody can guess which is meant.
    static func resolveTeam(token: String, session: URLSession = HTTP.defaultSession) async throws -> (id: String?, teams: Int) {
        let r = try await HTTP(base: "https://api.vercel.com", token: token, session: session).get("/v2/teams") as? JSON
        let teams = (r?["teams"] as? [JSON]) ?? []
        return (teams.count == 1 ? teams[0].str("id") : nil, teams.count)
    }

    /// For "Test": who the token belongs to, and how many projects it sees.
    func whoami() async throws -> String {
        let u = try await http.get("/v2/user") as? JSON
        let n = ((try? await http.get(t("/v10/projects?limit=100")) as? JSON)?["projects"] as? [JSON])?.count
        let who = u?.str("user.username") ?? u?.str("user.email") ?? "?"
        return n.map { L("Signed in as \(who) · \(plural($0, ("project", "Projekt"), ("projects", "Projekte"), atLeast: $0 == 100))",
                         "Angemeldet als \(who) · \(plural($0, ("project", "Projekt"), ("projects", "Projekte"), atLeast: $0 == 100))") }
            ?? L("Signed in as \(who)", "Angemeldet als \(who)")
    }

    /// The projects, and notes on what could not be read completely.
    func projects() async throws -> (list: [PhoneProject], notes: [String]) {
        var all: [JSON] = [], until: Int? = nil, notes: [String] = []
        repeat {
            let r = try await http.get(t("/v10/projects?limit=100" + (until.map { "&until=\($0)" } ?? ""))) as? JSON
            all += (r?["projects"] as? [JSON]) ?? []
            until = r?.int("pagination.next")
        } while until != nil && all.count < 1000
        if until != nil { notes.append(L("Only the first \(all.count) projects are shown.", "Nur die ersten \(all.count) Projekte werden gezeigt.")) }
        // The newest production attempt per project shows a build the project's target does not show yet.
        var deps: [JSON] = []
        do { deps = ((try await http.get(t("/v6/deployments?limit=100&target=production")) as? JSON)?["deployments"] as? [JSON]) ?? [] }
        catch { notes.append(L("Running builds unknown: \(error.localizedDescription)", "Laufende Builds unbekannt: \(error.localizedDescription)")) }
        var latest: [String: JSON] = [:]
        for d in deps {
            guard let n = d.str("name") else { continue }
            if (latest[n]?.int("created") ?? -1) < (d.int("created") ?? 0) { latest[n] = d }
        }
        let list: [PhoneProject] = all.compactMap { p in
            guard let name = p.str("name"), let id = p.str("id") else { return nil }
            let prod = p[path: "targets.production"] as? JSON
            let meta = prod?["meta"] as? JSON
            var x = PhoneProject(provider: .vercel, id: id, name: name)
            // GitLab and Bitbucket projects: this app reads only GitHub, and deploys with a GitHub source.
            if let type = p.str("link.type"), type != "github" {
                x.otherHost = type == "gitlab" ? "GitLab" : type == "bitbucket" ? "Bitbucket" : type
            } else {
                // Turning auto-deploy off removes the Git link; the last deploy's meta still names the repo.
                let org = p.str("link.org") ?? meta?.str("githubCommitOrg") ?? meta?.str("githubOrg")
                let repo = p.str("link.repo") ?? meta?.str("githubCommitRepo") ?? meta?.str("githubRepo")
                x.repo = (org != nil && repo != nil) ? "\(org!)/\(repo!)" : nil
                x.repoId = p.int("link.repoId") ?? (meta?.str("githubCommitRepoId")).flatMap(Int.init) ?? meta?.int("githubCommitRepoId")
                x.branch = p.str("link.productionBranch") ?? meta?.str("githubCommitRef")
            }
            x.autoDeploy = p[path: "link"] != nil
            x.liveId = prod?.str("id")
            x.liveSha = meta?.str("githubCommitSha")
            x.liveMsg = firstLine(meta?.str("githubCommitMessage"))
            x.liveAt = prod?.int("createdAt").map { Date(timeIntervalSince1970: Double($0) / 1000) }
            x.liveState = prod?.str("readyState")
            x.domain = (prod?["alias"] as? [String])?.first { !$0.hasSuffix(".vercel.app") }
            if let l = latest[name] {
                x.latestState = l.str("state"); x.latestId = l.str("uid")
                x.latestAt = l.int("created").map { Date(timeIntervalSince1970: Double($0) / 1000) }
            }
            // Big teams have more than 100 production deploys in the list: the project's own newest one then.
            else if let l = (p["latestDeployments"] as? [JSON])?.first(where: { $0.str("target") == "production" }) {
                x.latestState = l.str("readyState"); x.latestId = l.str("id") ?? l.str("uid")
                x.latestAt = (l.int("createdAt") ?? l.int("created")).map { Date(timeIntervalSince1970: Double($0) / 1000) }
            }
            x.deployable = x.repo != nil && x.branch != nil
            return x
        }
        return (list, notes)
    }

    /// The request body of a production deploy. The commit the person saw (`headSha`) is pinned, so a push that
    /// landed after the confirmation is not deployed unseen. Nil when the repo is not readable here.
    static func deployBody(_ p: PhoneProject) throws -> JSON {
        guard let repo = p.repo, let branch = p.branch else { throw APIError(status: 0, message: L("No repository is known for \(p.name).", "Für \(p.name) ist kein Repository bekannt.")) }
        var git: JSON = ["type": "github", "ref": branch]
        if let id = p.repoId { git["repoId"] = id } else {
            let parts = repo.split(separator: "/")
            guard parts.count >= 2 else { throw APIError(status: 0, message: L("The repository \"\(repo)\" of \(p.name) is not in the form owner/name.", "Das Repository \"\(repo)\" von \(p.name) hat nicht die Form owner/name.")) }
            git["org"] = String(parts[0]); git["repo"] = String(parts[1])
        }
        if let sha = p.headSha, !p.foreignRepo, !sha.isEmpty { git["sha"] = sha }
        return ["name": p.name, "project": p.name, "target": "production", "gitSource": git]
    }

    func deploy(_ p: PhoneProject) async throws -> String {
        let r = try await http.request("POST", t("/v13/deployments"), body: try Self.deployBody(p)) as? JSON
        guard let id = r?.str("id") else { throw APIError(status: 0, message: "Vercel returned no deployment id.") }
        return id
    }

    /// A production deploy of this project created after `since`: the one a POST that timed out may have started.
    func recentDeploy(_ p: PhoneProject, since: Date) async throws -> String? {
        let list = ((try await http.get(t("/v6/deployments?projectId=\(p.id)&target=production&limit=3")) as? JSON)?["deployments"] as? [JSON]) ?? []
        let ms = Int(since.timeIntervalSince1970 * 1000) - 5000
        return list.first { ($0.int("created") ?? 0) >= ms }?.str("uid")
    }

    /// After an Instant Rollback Vercel stops giving new production deploys the domains until one is promoted.
    /// `readySubstate` of a READY deploy: STAGED (never had production traffic), ROLLING or PROMOTED; nil from older answers.
    func readySubstate(_ id: String) async throws -> String? {
        (try await http.get(t("/v13/deployments/\(id)")) as? JSON)?.str("readySubstate")
    }

    func status(_ id: String) async throws -> String {
        let r = try await http.get(t("/v13/deployments/\(id)")) as? JSON
        return r?.str("readyState") ?? r?.str("status") ?? "UNKNOWN"
    }

    func cancel(_ id: String) async throws {
        _ = try await http.request("PATCH", t("/v12/deployments/\(id)/cancel"))
    }

    /// The previous READY production deploy of a different commit (redeploys of the same commit are skipped).
    /// Throws when the live deploy is unknown or not among the recent ones: guessing could roll back to the wrong one.
    func rollbackTarget(_ p: PhoneProject) async throws -> RollbackTarget? {
        guard let cur = try await productionId(p) else {
            throw APIError(status: 0, message: L("Vercel names no live deploy for \(p.name).", "Vercel nennt keinen Live-Deploy für \(p.name)."))
        }
        let list = ((try await http.get(t("/v6/deployments?projectId=\(p.id)&target=production&state=READY&limit=100")) as? JSON)?["deployments"] as? [JSON]) ?? []
        guard let i = list.firstIndex(where: { $0.str("uid") == cur }) else {
            throw APIError(status: 0, message: L("The live deploy of \(p.name) is not among the last \(list.count) ready deploys. Roll back in the Vercel dashboard.",
                                                 "Der Live-Deploy von \(p.name) ist nicht unter den letzten \(list.count) fertigen Deploys. Bitte im Vercel-Dashboard zurückrollen."))
        }
        let curSha = list[i].str("meta.githubCommitSha")
        guard let prev = list[(i + 1)...].first(where: { $0.str("meta.githubCommitSha") != curSha }), let id = prev.str("uid") else { return nil }
        return RollbackTarget(id: id, sha: prev.str("meta.githubCommitSha"), title: firstLine(prev.str("meta.githubCommitMessage")),
                              at: (prev.int("created") ?? prev.int("createdAt")).map { Date(timeIntervalSince1970: Double($0) / 1000) })
    }
    /// The newest production deploys, newest first.
    func history(_ p: PhoneProject, limit: Int = 15) async throws -> [DeployRecord] {
        let cur = try? await productionId(p)
        let list = ((try await http.get(t("/v6/deployments?projectId=\(p.id)&target=production&limit=\(limit)")) as? JSON)?["deployments"] as? [JSON]) ?? []
        return list.compactMap { d in
            guard let id = d.str("uid") else { return nil }
            func ms(_ k: String) -> Date? { d.int(k).map { Date(timeIntervalSince1970: Double($0) / 1000) } }
            return DeployRecord(id: id, state: d.str("state") ?? d.str("readyState") ?? "UNKNOWN", at: ms("created"), finishedAt: ms("ready"),
                                sha: d.str("meta.githubCommitSha"), title: firstLine(d.str("meta.githubCommitMessage")), current: id == cur)
        }
    }
    /// The build output of one deploy, oldest line first (the same call as `deploys logs`). Not masked yet.
    func buildLog(_ id: String) async throws -> [String] {
        LogMask.vercelLines(try await http.get(t("/v3/deployments/\(id)/events?builds=1&direction=backward&limit=2000")))
    }
    /// The deploy that has the production domains now.
    func productionId(_ p: PhoneProject) async throws -> String? {
        (try await http.get(t("/v9/projects/\(p.id)")) as? JSON)?.str("targets.production.id")
    }
    func rollback(_ p: PhoneProject, to deployment: String) async throws {
        do { _ = try await http.request("POST", t("/v1/projects/\(p.id)/rollback/\(deployment)")) }
        catch let e as APIError where e.status == 402 || (e.status == 403 && e.message.localizedCaseInsensitiveContains("plan")) {
            // The Hobby plan can only go back to the deploy right before the current one.
            throw APIError(status: 0, message: L("Vercel's Hobby plan allows rolling back only to the deploy right before. Vercel said: \(e.message)",
                                                 "Der Hobby-Plan von Vercel erlaubt nur das Zurückrollen auf den direkt vorigen Deploy. Vercel sagt: \(e.message)"))
        }
    }
}

// MARK: - Render

enum RenderAction: String, CaseIterable {
    case suspend, resume, restart
    var title: String {
        switch self {
        case .suspend: L("Pause the service …", "Dienst pausieren …")
        case .resume: L("Resume the service …", "Dienst fortsetzen …")
        case .restart: L("Restart the service …", "Dienst neu starten …")
        }
    }
    var icon: String { switch self { case .suspend: "pause.circle"; case .resume: "play.circle"; case .restart: "arrow.clockwise.circle" } }
    var done: String {
        switch self {
        case .suspend: L("paused", "pausiert")
        case .resume: L("resumed", "fortgesetzt")
        case .restart: L("restarting", "startet neu")
        }
    }
}

struct Render {
    let http: HTTP
    init(key: String, session: URLSession = HTTP.defaultSession) {
        http = HTTP(base: "https://api.render.com/v1", token: key, session: session)
    }

    func whoami() async throws -> String {
        let owners = ((try await http.get("/owners?limit=20")) as? [JSON] ?? []).compactMap { $0.str("owner.name") ?? $0.str("owner.email") }
        return L("Workspaces: ", "Workspaces: ") + (owners.isEmpty ? "–" : owners.joined(separator: ", "))
    }

    /// The services, and notes on what could not be read completely.
    func projects() async throws -> (list: [PhoneProject], notes: [String]) {
        var all: [JSON] = [], cursor: String? = nil
        repeat {
            let c = cursor.map { "&cursor=" + ($0.addingPercentEncoding(withAllowedCharacters: .alphanumerics) ?? $0) } ?? ""
            let page = (try await http.get("/services?limit=100" + c) as? [JSON]) ?? []
            all += page.compactMap { $0["service"] as? JSON }
            cursor = page.count == 100 ? page.last?.str("cursor") : nil
        } while cursor != nil && all.count < 1000
        let notes = cursor != nil ? [L("Only the first \(all.count) services are shown.", "Nur die ersten \(all.count) Dienste werden gezeigt.")] : []
        let list = try await withThrowingTaskGroup(of: PhoneProject?.self) { g in
            var out: [PhoneProject] = [], running = 0
            for s in all {
                if running >= 4, let r = try await g.next() { if let r { out.append(r) }; running -= 1 }
                g.addTask { await self.service(s) }; running += 1
            }
            for try await r in g { if let r { out.append(r) } }
            return out
        }
        return (list, notes)
    }

    private func service(_ s: JSON) async -> PhoneProject? {
        guard let id = s.str("id"), let name = s.str("name") else { return nil }
        var x = PhoneProject(provider: .render, id: id, name: name)
        if let r = s.str("repo") { let ref = RepoRef.parse(r); x.repo = ref.github; x.otherHost = ref.otherHost }
        x.branch = s.str("branch")
        x.kind = s.str("type")
        x.owner = s.str("ownerId")
        x.paused = s.str("suspended") == "suspended"
        x.autoDeploy = (s.str("autoDeployTrigger").map { $0 != "off" }) ?? (s.str("autoDeploy") == "yes")
        x.domain = s.str("serviceDetails.url").map { $0.replacingOccurrences(of: "https://", with: "") }
        // Render builds from its own Git connection, so GitLab and Bitbucket services deploy too.
        x.deployable = !x.paused
        // A paused service builds nothing: no read for it. Ten deploys hold the live one and the newest attempt.
        if x.paused { return x }
        // One read of the newest deploys per service. When it fails (a limit, a drop in the connection) the last good answer of
        // the last ten minutes stands in, so one bad call does not blank a row that was fine (IDEEN-12 C16).
        let deps: [JSON]
        do {
            deps = ((try await http.get("/services/\(id)/deploys?limit=10")) as? [JSON] ?? []).compactMap { $0["deploy"] as? JSON }
            RenderDeps.shared.set(id, deps)
        } catch {
            // The last good deploys keep the row useful, but the failed read is still said (the row is not "freshly read").
            x.fetchError = explain(error)
            guard let old = RenderDeps.shared.recent(id) else { return x }
            deps = old
        }
        if let n = deps.first {
            x.latestState = n.str("status"); x.latestId = n.str("id")
            x.latestAt = isoDate(n.str("createdAt"))
        }
        // The time of what is live, not of the newest attempt (that one may have failed).
        if let live = deps.first(where: { $0.str("status") == "live" }) {
            x.liveId = live.str("id"); x.liveSha = live.str("commit.id")
            x.liveAt = isoDate(live.str("finishedAt") ?? live.str("createdAt"))
            x.liveMsg = firstLine(live.str("commit.message"))
        }
        x.liveState = deps.first?.str("status")
        return x
    }

    /// The commit the person saw is pinned (`commitId`); without a known head Render builds the branch head.
    static func deployBody(_ p: PhoneProject) -> JSON {
        var b = JSON()
        if let sha = p.headSha, !p.foreignRepo, !sha.isEmpty { b["commitId"] = sha }
        return b
    }
    func deploy(_ p: PhoneProject) async throws -> String {
        let r = try await http.request("POST", "/services/\(p.id)/deploys", body: Self.deployBody(p)) as? JSON
        guard let id = r?.str("id") else { throw APIError(status: 0, message: "Render returned no deploy id.") }
        return id
    }
    func recentDeploy(_ p: PhoneProject, since: Date) async throws -> String? {
        let deps = ((try await http.get("/services/\(p.id)/deploys?limit=3")) as? [JSON] ?? []).compactMap { $0["deploy"] as? JSON }
        return deps.first { (isoDate($0.str("createdAt")) ?? .distantPast) >= since.addingTimeInterval(-5) }?.str("id")
    }
    func status(_ p: PhoneProject, _ id: String) async throws -> String {
        ((try await http.get("/services/\(p.id)/deploys/\(id)")) as? JSON)?.str("status") ?? "unknown"
    }
    func cancel(_ p: PhoneProject, _ id: String) async throws {
        _ = try await http.request("POST", "/services/\(p.id)/deploys/\(id)/cancel", body: JSON())
    }
    func rollbackTarget(_ p: PhoneProject) async throws -> RollbackTarget? {
        let deps = ((try await http.get("/services/\(p.id)/deploys?limit=50")) as? [JSON] ?? []).compactMap { $0["deploy"] as? JSON }
        guard let i = deps.firstIndex(where: { $0.str("status") == "live" }) else {
            throw APIError(status: 0, message: L("No live deploy of \(p.name) among the last \(deps.count). Roll back in the Render dashboard.",
                                                 "Kein Live-Deploy von \(p.name) unter den letzten \(deps.count). Bitte im Render-Dashboard zurückrollen."))
        }
        let cur = deps[i].str("commit.id")
        // Only deploys older than the live one.
        guard let prev = deps[(i + 1)...].first(where: { $0.str("status") == "deactivated" && $0.str("commit.id") != cur }), let id = prev.str("id") else { return nil }
        return RollbackTarget(id: id, sha: prev.str("commit.id"), title: firstLine(prev.str("commit.message")),
                              at: isoDate(prev.str("finishedAt") ?? prev.str("createdAt")))
    }
    func history(_ p: PhoneProject, limit: Int = 15) async throws -> [DeployRecord] {
        let deps = ((try await http.get("/services/\(p.id)/deploys?limit=\(limit)")) as? [JSON] ?? []).compactMap { $0["deploy"] as? JSON }
        return deps.compactMap { d in
            guard let id = d.str("id") else { return nil }
            let state = d.str("status") ?? "unknown"
            return DeployRecord(id: id, state: state, at: isoDate(d.str("createdAt")), finishedAt: isoDate(d.str("finishedAt")),
                                sha: d.str("commit.id"), title: firstLine(d.str("commit.message")), current: state == "live")
        }
    }
    /// The build output of one deploy, oldest line first. Render's logs have no deploy filter: the deploy's
    /// own time window stands in for it (as in `deploys logs`). Not masked yet.
    func buildLog(_ p: PhoneProject, _ d: DeployRecord) async throws -> [String] {
        var owner = p.owner
        if owner == nil { owner = (try await http.get("/services/\(p.id)") as? JSON)?.str("ownerId") }
        guard let owner else { throw APIError(status: 0, message: L("Render did not name the workspace of \(p.name).", "Render hat den Workspace von \(p.name) nicht genannt.")) }
        func q(_ s: String) -> String { s.addingPercentEncoding(withAllowedCharacters: .alphanumerics) ?? s }
        let base = "/logs?ownerId=\(q(owner))&resource=\(q(p.id))&type=build&limit=200&direction=backward"
        let iso = ISO8601DateFormatter()
        var start = ""
        if let a = d.at { start = "&startTime=" + q(iso.string(from: a.addingTimeInterval(-5))) }
        var end = d.finishedAt.map { iso.string(from: $0.addingTimeInterval(5)) }
        // The newest 200 lines come first. A long build has its first error before them, and the tail then
        // shows only a later consequence: older pages are read (at most five) until a line says error.
        var lines: [String] = []
        for _ in 0..<5 {
            let json = try await http.get(base + start + (end.map { "&endTime=" + q($0) } ?? ""))
            lines = LogMask.renderLines(json) + lines
            guard let page = json as? JSON, page["hasMore"] as? Bool == true, let next = page["nextEndTime"] as? String, next != end else { break }
            if LogMask.hasErrorLine(lines) { break }
            end = next
        }
        return lines
    }
    /// Render's "Auto-Deploy": "off", or "commit" (On Commit) again. The same two values `deploys render off|on` sets.
    static func autoDeployBody(on: Bool) -> JSON { ["autoDeployTrigger": on ? "commit" : "off"] }
    func setAutoDeploy(_ p: PhoneProject, on: Bool) async throws {
        _ = try await http.request("PATCH", "/services/\(p.id)", body: Self.autoDeployBody(on: on))
    }
    /// Pause, resume or restart a service (Render's suspend, resume, restart).
    func service(_ p: PhoneProject, _ action: RenderAction) async throws {
        _ = try await http.request("POST", "/services/\(p.id)/\(action.rawValue)", body: JSON())
    }
    /// The rollback is a new deploy on Render: its id, to follow it.
    func rollback(_ p: PhoneProject, to deploy: String) async throws -> String? {
        (try await http.request("POST", "/services/\(p.id)/rollback", body: ["deployId": deploy]) as? JSON)?.str("id")
    }
    /// The commit of the deploy that is live now (a rollback builds a new deploy of an old commit).
    func liveCommit(_ p: PhoneProject) async throws -> String? {
        let deps = ((try await http.get("/services/\(p.id)/deploys?limit=10")) as? [JSON] ?? []).compactMap { $0["deploy"] as? JSON }
        return deps.first(where: { $0.str("status") == "live" })?.str("commit.id")
    }
}

// MARK: - GitHub

struct GitHub {
    let http: HTTP
    init(token: String?, session: URLSession = HTTP.defaultSession) {
        // Without a token public repos still work (60 requests an hour); ETags save most of them.
        http = HTTP(base: "https://api.github.com", token: token ?? "",
                    extraHeaders: ["X-GitHub-Api-Version": "2022-11-28"], conditional: true, session: session)
    }

    /// For "Test connection": the login of the token's account.
    func whoami() async throws -> String {
        let u = try await http.get("/user") as? JSON
        return L("Signed in as \(u?.str("login") ?? "?")", "Angemeldet als \(u?.str("login") ?? "?")")
    }

    /// The scopes of a classic token (`X-OAuth-Scopes`); nil for fine-grained tokens, which send none.
    /// `/rate_limit` does not count against the limit.
    func scopes() async -> [String]? {
        guard let r = try? await http.send("GET", "/rate_limit").response,
              let v = r.value(forHTTPHeaderField: "x-oauth-scopes") else { return nil }
        return v.split(separator: ",").map { $0.trimmingCharacters(in: .whitespaces) }.filter { !$0.isEmpty }
    }

    /// Head of the branch, and what waits between the live commit and it. `openPRs`: the count for this
    /// repo when it is already known (projects of one repo share it).
    func fill(_ p: inout PhoneProject, openPRs known: (Int, Bool)? = nil) async {
        guard let repo = p.repo, let branch = p.branch else { return }
        // A spent limit is remembered across launches and background runs: no calls until it is free (IDEEN-12 C17).
        if let until = RateGate.until {
            p.fetchError = L("GitHub's rate limit is reached, free again at \(until.formatted(Date.FormatStyle(date: .omitted, time: .shortened).locale(appLocale))). A GitHub token in Settings raises it.",
                             "Das Abruflimit von GitHub ist erreicht, wieder frei um \(until.formatted(Date.FormatStyle(date: .omitted, time: .shortened).locale(appLocale))). Ein GitHub-Token in den Einstellungen erhöht es.")
            return
        }
        let ref = branch.addingPercentEncoding(withAllowedCharacters: .urlPathAllowed) ?? branch
        do {
            let head = try await http.get("/repos/\(repo)/commits/\(ref)") as? JSON
            p.headSha = head?.str("sha")
            p.headAt = isoDate(head?.str("commit.committer.date"))
            p.headMsg = firstLine(head?.str("commit.message"))
        } catch let e as APIError where e.status == 404 && http.token.isEmpty {
            // GitHub answers a private repo without a token with 404.
            p.fetchError = L("Repository not found. If it is private, add a GitHub token in Settings.",
                             "Repository nicht gefunden. Ist es privat, ein GitHub-Token in den Einstellungen eintragen.")
            return
        } catch { RateGate.note(error); p.fetchError = explain(error); return }
        if let known { p.openPRs = known.0; p.openPRsCapped = known.1 }
        else if let open = try? await http.get("/repos/\(repo)/pulls?state=open&per_page=100") as? [JSON] {
            p.openPRs = open.count; p.openPRsCapped = open.count == 100
        }
        guard let live = p.liveSha, let head = p.headSha else { return }
        if live == head { p.pendingCommits = 0; p.pendingPRs = 0; p.pendingPRsAtLeast = false; p.pendingTitles = []; return }
        do {
            let c = try await http.get("/repos/\(repo)/compare/\(live)...\(ref)") as? JSON
            p.pendingCommits = c?.int("ahead_by")
            p.compareStatus = c?.str("status")
            let commits = (c?["commits"] as? [JSON]) ?? []
            // The compare lists at most 250 commits: PRs among older ones are not seen.
            p.pendingCapped = commits.count >= 250
            p.oldestPendingAt = isoDate(commits.first?.str("commit.committer.date"))
            p.pendingTitles = commits.suffix(20).reversed().compactMap { firstLine($0.str("commit.message")) }
            var numbers = Set<Int>(), without: [String] = []
            for m in commits {
                if let n = Self.prNumber(m.str("commit.message") ?? "") { numbers.insert(n) } else if let s = m.str("sha") { without.append(s) }
            }
            var extra = Set<Int>()
            // More than ten commits without a PR number are not looked up one by one: the count is a minimum.
            var atLeast = without.count > 10
            if !without.isEmpty && without.count <= 10 {
                // At most four at a time.
                let http = self.http
                // nil: the lookup failed (rate limit, outage), so that commit's PRs are unknown.
                await withTaskGroup(of: [Int]?.self) { g in
                    var n = 0
                    for s in without {
                        if n >= 4, let found = await g.next() { if let f = found { f.forEach { extra.insert($0) } } else { atLeast = true }; n -= 1 }
                        g.addTask {
                            ((try? await http.get("/repos/\(repo)/commits/\(s)/pulls")) as? [JSON])?.compactMap { $0.int("number") }
                        }
                        n += 1
                    }
                    for await found in g { if let f = found { f.forEach { extra.insert($0) } } else { atLeast = true } }
                }
            }
            p.pendingPRs = numbers.count + extra.count
            p.pendingPRsAtLeast = atLeast
        } catch let e as APIError where e.status == 404 || e.message.contains("No common ancestor") {
            p.rewritten = true
        } catch {
            // A rate limit or an outage: say "state unknown", never "0 commits waiting".
            RateGate.note(error)
            p.fetchError = explain(error)
        }
    }

    /// "(#12)" from a squash merge, else "Merge pull request #12".
    static func prNumber(_ message: String) -> Int? {
        for pattern in [#"\(#(\d+)\)"#, #"Merge pull request #(\d+)"#] {
            if let r = message.range(of: pattern, options: .regularExpression) {
                let digits = message[r].filter(\.isNumber)
                if let n = Int(digits) { return n }
            }
        }
        return nil
    }
}

/// The last good list of deploys per Render service, in memory only (gone when the app quits).
final class RenderDeps: @unchecked Sendable {
    static let shared = RenderDeps()
    private let lock = NSLock()
    private var items: [String: (at: Date, deps: [JSON])] = [:]
    func set(_ id: String, _ deps: [JSON]) { lock.lock(); items[id] = (Date(), deps); lock.unlock() }
    func recent(_ id: String, now: Date = Date(), within: TimeInterval = 600) -> [JSON]? {
        lock.lock(); defer { lock.unlock() }
        guard let e = items[id], now.timeIntervalSince(e.at) <= within else { return nil }
        return e.deps
    }
    func removeAll() { lock.lock(); items = [:]; lock.unlock() }
}

/// When GitHub's rate limit is free again, kept in UserDefaults (the app and the background run share it).
enum RateGate {
    static let key = "githubLimitUntil"
    /// nil when there is no limit or it has passed.
    static var until: Date? {
        guard let d = UserDefaults.standard.object(forKey: key) as? Date, d > Date() else { return nil }
        return d
    }
    /// Remembers the end of a spent limit (at most an hour ahead: a wrong header must not lock GitHub out for a day).
    static func note(_ error: Error, now: Date = Date()) {
        guard let e = error as? APIError, e.rateLimited, let at = e.retryAt else { return }
        UserDefaults.standard.set(min(at, now.addingTimeInterval(3600)), forKey: key)
    }
    static func clear() { UserDefaults.standard.removeObject(forKey: key) }
}

/// What the log screen shows: masked lines around the first error, or why there are none.
struct BuildLog {
    var lines: [String] = []
    var errorAt: Int? = nil
    /// The whole masked log (at most the last 60 000 characters), for "Copy".
    var full = ""
    var problem: String? = nil
}
