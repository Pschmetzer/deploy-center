// Deploy Center for iPhone — The three REST APIs, called directly with the person's own tokens.
// The calls follow the `deploys` CLI of the Mac app, so both decide "waiting" the same way.

import Foundation

typealias JSON = [String: Any]

struct APIError: LocalizedError {
    let status: Int
    let message: String
    /// GitHub answers a spent rate limit with 403 and X-RateLimit-Remaining: 0, others with 429.
    var rateLimited = false

    /// What to do about it, not only the HTTP code.
    var errorDescription: String? {
        if rateLimited || status == 429 { return L("Rate limit reached. Try again later.", "Limit erreicht. Versuch es später noch einmal.") }
        switch status {
        case 0: return message
        case 401: return L("Key refused (HTTP 401). Check it in Settings.", "Schlüssel abgelehnt (HTTP 401). Prüfe ihn in den Einstellungen.")
        case 403: return L("No access (HTTP 403): \(message)", "Kein Zugriff (HTTP 403): \(message)")
        case 404: return L("Not found (HTTP 404): \(message)", "Nicht gefunden (HTTP 404): \(message)")
        case 500...: return L("The service has a problem (HTTP \(status)). Try again later.",
                              "Der Dienst hat ein Problem (HTTP \(status)). Versuch es später noch einmal.")
        default: return "HTTP \(status): \(message)"
        }
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
        default: break
        }
    }
    return error.localizedDescription
}

/// One small HTTP helper: Bearer token, JSON in and out. GETs are retried twice on 5xx, 429 and a
/// dropped connection; a POST never, it may already have started a build.
struct HTTP {
    let base: String
    let token: String
    var extraHeaders: [String: String] = [:]

    /// Waits for a connection instead of failing at once, and keeps a small cache so GitHub can answer
    /// "not modified" (ETag), which does not count against its rate limit.
    static let session: URLSession = {
        let c = URLSessionConfiguration.default
        c.waitsForConnectivity = true
        c.timeoutIntervalForRequest = 30
        c.timeoutIntervalForResource = 60
        c.urlCache = URLCache(memoryCapacity: 4 << 20, diskCapacity: 16 << 20)
        c.requestCachePolicy = .useProtocolCachePolicy
        let v = Bundle.main.object(forInfoDictionaryKey: "CFBundleShortVersionString") as? String ?? "1"
        c.httpAdditionalHeaders = ["User-Agent": "DeployCenter-iOS/\(v)"]
        return URLSession(configuration: c)
    }()
    private static let retryable: Set<URLError.Code> = [.timedOut, .networkConnectionLost, .cannotConnectToHost, .dnsLookupFailed]

    func request(_ method: String, _ path: String, body: Any? = nil) async throws -> Any {
        guard let url = URL(string: base + path) else { throw APIError(status: 0, message: "bad URL") }
        var r = URLRequest(url: url, timeoutInterval: 30)
        r.httpMethod = method
        // No header at all without a token: GitHub answers an empty "Bearer " with 401.
        if !token.isEmpty { r.setValue("Bearer \(token)", forHTTPHeaderField: "Authorization") }
        r.setValue("application/json", forHTTPHeaderField: "Accept")
        for (k, v) in extraHeaders { r.setValue(v, forHTTPHeaderField: k) }
        if let body {
            r.setValue("application/json", forHTTPHeaderField: "Content-Type")
            r.httpBody = try JSONSerialization.data(withJSONObject: body)
        }
        var attempt = 0
        while true {
            attempt += 1
            let data: Data, resp: URLResponse
            do { (data, resp) = try await Self.session.data(for: r) }
            catch let e as URLError where method == "GET" && attempt < 3 && Self.retryable.contains(e.code) {
                try await Task.sleep(for: .seconds(2 * attempt)); continue
            }
            let h = resp as? HTTPURLResponse
            let code = h?.statusCode ?? 0
            if method == "GET", attempt < 3, code == 429 || code >= 500 {
                try await Task.sleep(for: .seconds(Self.wait(h, attempt: attempt))); continue
            }
            guard (200..<300).contains(code) else {
                let obj = try? JSONSerialization.jsonObject(with: data) as? JSON
                let msg = ((obj?["error"] as? JSON)?["message"] as? String) ?? (obj?["message"] as? String)
                    ?? String(data: data.prefix(200), encoding: .utf8) ?? ""
                let limited = code == 429 || (code == 403 && h?.value(forHTTPHeaderField: "X-RateLimit-Remaining") == "0")
                throw APIError(status: code, message: msg, rateLimited: limited)
            }
            if data.isEmpty { return JSON() }
            return try JSONSerialization.jsonObject(with: data)
        }
    }
    func get(_ path: String) async throws -> Any { try await request("GET", path) }

    /// Seconds before the next try: Retry-After or X-RateLimit-Reset when given, at most 10.
    static func wait(_ h: HTTPURLResponse?, attempt: Int, now: Date = Date()) -> Int {
        if let s = h?.value(forHTTPHeaderField: "Retry-After").flatMap(Int.init) { return min(max(s, 1), 10) }
        if let t = h?.value(forHTTPHeaderField: "X-RateLimit-Reset").flatMap(Double.init) {
            return min(max(Int(t - now.timeIntervalSince1970), 1), 10)
        }
        return 3 * attempt
    }
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

func isoDate(_ s: String?) -> Date? {
    guard let s else { return nil }
    let f = ISO8601DateFormatter(); f.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
    if let d = f.date(from: s) { return d }
    f.formatOptions = [.withInternetDateTime]
    return f.date(from: s)
}

func firstLine(_ s: String?) -> String? { s.map { String($0.split(separator: "\n").first ?? "") } }

/// A repo URL or "owner/name": the "owner/name" on GitHub, or the host it lives on instead.
enum RepoRef {
    static func parse(_ s: String) -> (github: String?, otherHost: String?) {
        var t = s.trimmingCharacters(in: .whitespaces)
        if t.hasSuffix(".git") { t.removeLast(4) }
        if t.hasSuffix("/") { t.removeLast() }
        guard t.contains("://") || t.hasPrefix("git@") else { return (t.isEmpty ? nil : t, nil) }
        // https://host/owner/name or git@host:owner/name
        let rest = t.hasPrefix("git@") ? String(t.dropFirst(4)) : String(t[t.range(of: "://")!.upperBound...])
        let host = String(rest.prefix { $0 != "/" && $0 != ":" })
        let path = String(rest.dropFirst(host.count + 1))
        let h = host.lowercased().replacingOccurrences(of: "www.", with: "")
        if h == "github.com" { return (path.isEmpty ? nil : path, nil) }
        let name = h.contains("gitlab") ? "GitLab" : h.contains("bitbucket") ? "Bitbucket" : host
        return (nil, name)
    }
}

/// The deploy a rollback goes back to.
struct RollbackTarget {
    let id: String
    let sha: String?
    let title: String?
    let at: Date?
}

/// One deploy in a project's history (newest first in lists).
struct DeployRecord: Identifiable, Equatable {
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
    init(token: String, team: String?) {
        http = HTTP(base: "https://api.vercel.com", token: token)
        self.team = (team?.isEmpty ?? true) ? nil : team
    }
    private func t(_ path: String) -> String {
        guard let team else { return path }
        return path + (path.contains("?") ? "&" : "?") + "teamId=" + (team.addingPercentEncoding(withAllowedCharacters: .urlQueryAllowed) ?? team)
    }

    /// With no team set: one team is used, none means the personal account.
    static func resolveTeam(token: String) async throws -> String? {
        let r = try await HTTP(base: "https://api.vercel.com", token: token).get("/v2/teams") as? JSON
        let teams = (r?["teams"] as? [JSON]) ?? []
        return teams.count == 1 ? teams[0].str("id") : nil
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

    func projects() async throws -> [PhoneProject] {
        var all: [JSON] = [], until: Int? = nil
        repeat {
            let r = try await http.get(t("/v10/projects?limit=100" + (until.map { "&until=\($0)" } ?? ""))) as? JSON
            all += (r?["projects"] as? [JSON]) ?? []
            until = r?.int("pagination.next")
        } while until != nil && all.count < 1000
        // The newest production attempt per project shows a build the project's target does not show yet.
        let deps = ((try? await http.get(t("/v6/deployments?limit=100&target=production")) as? JSON)?["deployments"] as? [JSON]) ?? []
        var latest: [String: JSON] = [:]
        for d in deps {
            guard let n = d.str("name") else { continue }
            if (latest[n]?.int("created") ?? -1) < (d.int("created") ?? 0) { latest[n] = d }
        }
        return all.compactMap { p in
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
            if let l = latest[name] { x.latestState = l.str("state"); x.latestId = l.str("uid") }
            // Big teams have more than 100 production deploys in the list: the project's own newest one then.
            else if let l = (p["latestDeployments"] as? [JSON])?.first(where: { $0.str("target") == "production" }) {
                x.latestState = l.str("readyState"); x.latestId = l.str("id") ?? l.str("uid")
            }
            x.deployable = x.repo != nil && x.branch != nil
            return x
        }
    }

    func deploy(_ p: PhoneProject) async throws -> String {
        guard let repo = p.repo, let branch = p.branch else { throw APIError(status: 0, message: L("No repository is known for \(p.name).", "Für \(p.name) ist kein Repository bekannt.")) }
        var git: JSON = ["type": "github", "ref": branch]
        if let id = p.repoId { git["repoId"] = id } else {
            let parts = repo.split(separator: "/"); git["org"] = String(parts[0]); git["repo"] = String(parts[1])
        }
        let r = try await http.request("POST", t("/v13/deployments"),
                                       body: ["name": p.name, "project": p.name, "target": "production", "gitSource": git]) as? JSON
        guard let id = r?.str("id") else { throw APIError(status: 0, message: "Vercel returned no deployment id.") }
        return id
    }

    /// A production deploy of this project created after `since`: the one a POST that timed out may have started.
    func recentDeploy(_ p: PhoneProject, since: Date) async throws -> String? {
        let list = ((try await http.get(t("/v6/deployments?projectId=\(p.id)&target=production&limit=3")) as? JSON)?["deployments"] as? [JSON]) ?? []
        let ms = Int(since.timeIntervalSince1970 * 1000) - 5000
        return list.first { ($0.int("created") ?? 0) >= ms }?.str("uid")
    }

    func status(_ id: String) async throws -> String {
        let r = try await http.get(t("/v13/deployments/\(id)")) as? JSON
        return r?.str("readyState") ?? r?.str("status") ?? "UNKNOWN"
    }

    func cancel(_ id: String) async throws {
        _ = try await http.request("PATCH", t("/v12/deployments/\(id)/cancel"))
    }

    /// The previous READY production deploy of a different commit (redeploys of the same commit are skipped).
    func rollbackTarget(_ p: PhoneProject) async throws -> RollbackTarget? {
        let cur = try await productionId(p)
        let list = ((try await http.get(t("/v6/deployments?projectId=\(p.id)&target=production&state=READY&limit=20")) as? JSON)?["deployments"] as? [JSON]) ?? []
        let i = list.firstIndex { $0.str("uid") == cur } ?? 0
        guard i < list.count else { return nil }
        let curSha = list[i].str("meta.githubCommitSha")
        guard let prev = list[(i + 1)...].first(where: { $0.str("meta.githubCommitSha") != curSha }), let id = prev.str("uid") else { return nil }
        return RollbackTarget(id: id, sha: prev.str("meta.githubCommitSha"), title: firstLine(prev.str("meta.githubCommitMessage")),
                              at: prev.int("created").map { Date(timeIntervalSince1970: Double($0) / 1000) })
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

struct Render {
    let http: HTTP
    init(key: String) { http = HTTP(base: "https://api.render.com/v1", token: key) }

    func whoami() async throws -> String {
        let owners = ((try await http.get("/owners?limit=20")) as? [JSON] ?? []).compactMap { $0.str("owner.name") ?? $0.str("owner.email") }
        return L("Workspaces: ", "Workspaces: ") + (owners.isEmpty ? "–" : owners.joined(separator: ", "))
    }

    func projects() async throws -> [PhoneProject] {
        var all: [JSON] = [], cursor: String? = nil
        repeat {
            let c = cursor.map { "&cursor=" + ($0.addingPercentEncoding(withAllowedCharacters: .alphanumerics) ?? $0) } ?? ""
            let page = (try await http.get("/services?limit=100" + c) as? [JSON]) ?? []
            all += page.compactMap { $0["service"] as? JSON }
            cursor = page.count == 100 ? page.last?.str("cursor") : nil
        } while cursor != nil && all.count < 1000
        return try await withThrowingTaskGroup(of: PhoneProject?.self) { g in
            var out: [PhoneProject] = [], running = 0
            for s in all {
                if running >= 4, let r = try await g.next() { if let r { out.append(r) }; running -= 1 }
                g.addTask { await self.service(s) }; running += 1
            }
            for try await r in g { if let r { out.append(r) } }
            return out
        }
    }

    private func service(_ s: JSON) async -> PhoneProject? {
        guard let id = s.str("id"), let name = s.str("name") else { return nil }
        var x = PhoneProject(provider: .render, id: id, name: name)
        if let r = s.str("repo") { let ref = RepoRef.parse(r); x.repo = ref.github; x.otherHost = ref.otherHost }
        x.branch = s.str("branch")
        x.owner = s.str("ownerId")
        x.paused = s.str("suspended") == "suspended"
        x.autoDeploy = (s.str("autoDeployTrigger").map { $0 != "off" }) ?? (s.str("autoDeploy") == "yes")
        x.domain = s.str("serviceDetails.url").map { $0.replacingOccurrences(of: "https://", with: "") }
        // Render builds from its own Git connection, so GitLab and Bitbucket services deploy too.
        x.deployable = !x.paused
        do {
            let deps = ((try await http.get("/services/\(id)/deploys?limit=10")) as? [JSON] ?? []).compactMap { $0["deploy"] as? JSON }
            if let n = deps.first {
                x.latestState = n.str("status"); x.latestId = n.str("id")
                x.liveAt = isoDate(n.str("finishedAt") ?? n.str("createdAt"))
            }
            if let live = deps.first(where: { $0.str("status") == "live" }) {
                x.liveId = live.str("id"); x.liveSha = live.str("commit.id")
                x.liveMsg = firstLine(live.str("commit.message"))
            }
            x.liveState = deps.first?.str("status")
        } catch { x.fetchError = explain(error) }
        return x
    }

    func deploy(_ p: PhoneProject) async throws -> String {
        let r = try await http.request("POST", "/services/\(p.id)/deploys", body: JSON()) as? JSON
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
        let deps = ((try await http.get("/services/\(p.id)/deploys?limit=20")) as? [JSON] ?? []).compactMap { $0["deploy"] as? JSON }
        let cur = deps.first { $0.str("status") == "live" }?.str("commit.id")
        guard let prev = deps.first(where: { $0.str("status") == "deactivated" && $0.str("commit.id") != cur }), let id = prev.str("id") else { return nil }
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
        var path = "/logs?ownerId=\(q(owner))&resource=\(q(p.id))&type=build&limit=200&direction=backward"
        let iso = ISO8601DateFormatter()
        if let a = d.at { path += "&startTime=" + q(iso.string(from: a.addingTimeInterval(-5))) }
        if let b = d.finishedAt { path += "&endTime=" + q(iso.string(from: b.addingTimeInterval(5))) }
        return LogMask.renderLines(try await http.get(path))
    }
    /// The rollback is a new deploy on Render: its id, to follow it.
    func rollback(_ p: PhoneProject, to deploy: String) async throws -> String? {
        (try await http.request("POST", "/services/\(p.id)/rollback", body: ["deployId": deploy]) as? JSON)?.str("id")
    }
}

// MARK: - GitHub

struct GitHub {
    let http: HTTP
    init(token: String?) {
        // Without a token public repos still work (60 requests an hour).
        http = HTTP(base: "https://api.github.com", token: token ?? "",
                    extraHeaders: ["X-GitHub-Api-Version": "2022-11-28"])
    }

    func whoami() async throws -> String {
        let u = try await http.get("/user") as? JSON
        return L("Signed in as \(u?.str("login") ?? "?")", "Angemeldet als \(u?.str("login") ?? "?")")
    }

    /// Head of the branch, and what waits between the live commit and it. `openPRs`: the count for this
    /// repo when it is already known (projects of one repo share it).
    func fill(_ p: inout PhoneProject, openPRs known: (Int, Bool)? = nil) async {
        guard let repo = p.repo, let branch = p.branch else { return }
        let ref = branch.addingPercentEncoding(withAllowedCharacters: .urlPathAllowed) ?? branch
        do {
            let head = try await http.get("/repos/\(repo)/commits/\(ref)") as? JSON
            p.headSha = head?.str("sha")
            p.headAt = isoDate(head?.str("commit.committer.date"))
            p.headMsg = firstLine(head?.str("commit.message"))
        } catch { p.fetchError = explain(error); return }
        if let known { p.openPRs = known.0; p.openPRsCapped = known.1 }
        else if let open = try? await http.get("/repos/\(repo)/pulls?state=open&per_page=100") as? [JSON] {
            p.openPRs = open.count; p.openPRsCapped = open.count == 100
        }
        guard let live = p.liveSha, let head = p.headSha else { return }
        if live == head { p.pendingCommits = 0; p.pendingPRs = 0; p.pendingTitles = []; return }
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
            if !without.isEmpty && without.count <= 10 {
                for s in without {
                    if let prs = try? await http.get("/repos/\(repo)/commits/\(s)/pulls") as? [JSON] {
                        prs.compactMap { $0.int("number") }.forEach { extra.insert($0) }
                    }
                }
            }
            p.pendingPRs = numbers.count + extra.count
        } catch let e as APIError where e.status == 404 || e.message.contains("No common ancestor") {
            p.rewritten = true
        } catch {
            // A rate limit or an outage: say "state unknown", never "0 commits waiting".
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

/// What the log screen shows: masked lines around the first error, or why there are none.
struct BuildLog {
    var lines: [String] = []
    var errorAt: Int? = nil
    /// The whole masked log (at most the last 60 000 characters), for "Copy".
    var full = ""
    var problem: String? = nil
}
