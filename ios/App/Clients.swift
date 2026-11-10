// Deploy Center for iPhone — The three REST APIs, called directly with the person's own tokens.
// The calls follow the `deploys` CLI of the Mac app, so both decide "waiting" the same way.

import Foundation

typealias JSON = [String: Any]

struct APIError: LocalizedError {
    let status: Int
    let message: String
    var errorDescription: String? { status > 0 ? "HTTP \(status): \(message)" : message }
}

/// One small HTTP helper: Bearer token, JSON in and out, GETs retried once on 5xx or 429.
struct HTTP {
    let base: String
    let token: String
    var extraHeaders: [String: String] = [:]

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
            let (data, resp) = try await URLSession.shared.data(for: r)
            let code = (resp as? HTTPURLResponse)?.statusCode ?? 0
            // Never retry a POST: it may already have started a build.
            if method == "GET", attempt < 3, code == 429 || code >= 500 {
                try await Task.sleep(for: .seconds(3 * attempt)); continue
            }
            guard (200..<300).contains(code) else {
                let obj = try? JSONSerialization.jsonObject(with: data) as? JSON
                let msg = ((obj?["error"] as? JSON)?["message"] as? String) ?? (obj?["message"] as? String)
                    ?? String(data: data.prefix(200), encoding: .utf8) ?? ""
                throw APIError(status: code, message: msg)
            }
            if data.isEmpty { return JSON() }
            return try JSONSerialization.jsonObject(with: data)
        }
    }
    func get(_ path: String) async throws -> Any { try await request("GET", path) }
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
            // Turning auto-deploy off removes the Git link; the last deploy's meta still names the repo.
            let org = p.str("link.org") ?? meta?.str("githubCommitOrg") ?? meta?.str("githubOrg")
            let repo = p.str("link.repo") ?? meta?.str("githubCommitRepo") ?? meta?.str("githubRepo")
            let repoId = p.int("link.repoId") ?? (meta?.str("githubCommitRepoId")).flatMap(Int.init) ?? meta?.int("githubCommitRepoId")
            let branch = p.str("link.productionBranch") ?? meta?.str("githubCommitRef")
            var x = PhoneProject(provider: .vercel, id: id, name: name)
            x.repo = (org != nil && repo != nil) ? "\(org!)/\(repo!)" : nil
            x.repoId = repoId
            x.branch = branch
            x.autoDeploy = p[path: "link"] != nil
            x.liveId = prod?.str("id")
            x.liveSha = meta?.str("githubCommitSha")
            x.liveMsg = meta?.str("githubCommitMessage").map { String($0.split(separator: "\n").first ?? "") }
            x.liveAt = prod?.int("createdAt").map { Date(timeIntervalSince1970: Double($0) / 1000) }
            x.liveState = prod?.str("readyState")
            x.domain = (prod?["alias"] as? [String])?.first { !$0.hasSuffix(".vercel.app") }
            if let l = latest[name] { x.latestState = l.str("state"); x.latestId = l.str("uid") }
            x.deployable = x.repo != nil && x.branch != nil
            return x
        }
    }

    func deploy(_ p: PhoneProject) async throws -> String {
        guard let repo = p.repo, let branch = p.branch else { throw APIError(status: 0, message: "No repository is known for \(p.name).") }
        var git: JSON = ["type": "github", "ref": branch]
        if let id = p.repoId { git["repoId"] = id } else {
            let parts = repo.split(separator: "/"); git["org"] = String(parts[0]); git["repo"] = String(parts[1])
        }
        let r = try await http.request("POST", t("/v13/deployments"),
                                       body: ["name": p.name, "project": p.name, "target": "production", "gitSource": git]) as? JSON
        guard let id = r?.str("id") else { throw APIError(status: 0, message: "Vercel returned no deployment id.") }
        return id
    }

    func status(_ id: String) async throws -> String {
        let r = try await http.get(t("/v13/deployments/\(id)")) as? JSON
        return r?.str("readyState") ?? r?.str("status") ?? "UNKNOWN"
    }

    /// The previous READY production deploy of a different commit (redeploys of the same commit are skipped).
    /// Throws when the live deploy is unknown or not among the recent ones: guessing could roll back to the wrong one.
    func rollbackTarget(_ p: PhoneProject) async throws -> (id: String, sha: String?)? {
        guard let cur = (try await http.get(t("/v9/projects/\(p.id)")) as? JSON)?.str("targets.production.id") else {
            throw APIError(status: 0, message: L("Vercel names no live deploy for \(p.name).", "Vercel nennt keinen Live-Deploy für \(p.name)."))
        }
        let list = ((try await http.get(t("/v6/deployments?projectId=\(p.id)&target=production&state=READY&limit=100")) as? JSON)?["deployments"] as? [JSON]) ?? []
        guard let i = list.firstIndex(where: { $0.str("uid") == cur }) else {
            throw APIError(status: 0, message: L("The live deploy of \(p.name) is not among the last \(list.count) ready deploys. Roll back in the Vercel dashboard.",
                                                 "Der Live-Deploy von \(p.name) ist nicht unter den letzten \(list.count) fertigen Deploys. Bitte im Vercel-Dashboard zurückrollen."))
        }
        let curSha = list[i].str("meta.githubCommitSha")
        guard let prev = list[(i + 1)...].first(where: { $0.str("meta.githubCommitSha") != curSha }), let id = prev.str("uid") else { return nil }
        return (id, prev.str("meta.githubCommitSha"))
    }
    func rollback(_ p: PhoneProject, to deployment: String) async throws {
        _ = try await http.request("POST", t("/v1/projects/\(p.id)/rollback/\(deployment)"))
    }
}

// MARK: - Render

struct Render {
    let http: HTTP
    init(key: String) { http = HTTP(base: "https://api.render.com/v1", token: key) }

    func projects() async throws -> [PhoneProject] {
        var all: [JSON] = [], cursor: String? = nil
        repeat {
            let page = (try await http.get("/services?limit=100" + (cursor.map { "&cursor=\($0)" } ?? "")) as? [JSON]) ?? []
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
        x.repo = s.str("repo").flatMap(Self.githubRepo)
        x.branch = s.str("branch")
        x.paused = s.str("suspended") == "suspended"
        x.autoDeploy = (s.str("autoDeployTrigger").map { $0 != "off" }) ?? (s.str("autoDeploy") == "yes")
        x.domain = s.str("serviceDetails.url").map { $0.replacingOccurrences(of: "https://", with: "") }
        x.deployable = !x.paused
        do {
            let deps = ((try await http.get("/services/\(id)/deploys?limit=50")) as? [JSON] ?? []).compactMap { $0["deploy"] as? JSON }
            if let n = deps.first {
                x.latestState = n.str("status"); x.latestId = n.str("id")
            }
            // The time of what is live, not of the newest attempt (that one may have failed).
            if let live = deps.first(where: { $0.str("status") == "live" }) {
                x.liveId = live.str("id"); x.liveSha = live.str("commit.id")
                x.liveAt = isoDate(live.str("finishedAt") ?? live.str("createdAt"))
                x.liveMsg = live.str("commit.message").map { String($0.split(separator: "\n").first ?? "") }
            }
            x.liveState = deps.first?.str("status")
        } catch { x.fetchError = error.localizedDescription }
        return x
    }

    /// "owner/name" from a GitHub URL; other hosts give nil (only GitHub is compared).
    static func githubRepo(_ url: String) -> String? {
        let prefix = "https://github.com/"
        guard url.hasPrefix(prefix) else { return nil }
        var r = String(url.dropFirst(prefix.count))
        if r.hasSuffix("/") { r.removeLast() }
        if r.hasSuffix(".git") { r.removeLast(4) }
        return r.isEmpty ? nil : r
    }

    func deploy(_ p: PhoneProject) async throws -> String {
        let r = try await http.request("POST", "/services/\(p.id)/deploys", body: JSON()) as? JSON
        guard let id = r?.str("id") else { throw APIError(status: 0, message: "Render returned no deploy id.") }
        return id
    }
    func status(_ p: PhoneProject, _ id: String) async throws -> String {
        ((try await http.get("/services/\(p.id)/deploys/\(id)")) as? JSON)?.str("status") ?? "unknown"
    }
    func rollbackTarget(_ p: PhoneProject) async throws -> (id: String, sha: String?)? {
        let deps = ((try await http.get("/services/\(p.id)/deploys?limit=50")) as? [JSON] ?? []).compactMap { $0["deploy"] as? JSON }
        guard let i = deps.firstIndex(where: { $0.str("status") == "live" }) else {
            throw APIError(status: 0, message: L("No live deploy of \(p.name) among the last \(deps.count). Roll back in the Render dashboard.",
                                                 "Kein Live-Deploy von \(p.name) unter den letzten \(deps.count). Bitte im Render-Dashboard zurückrollen."))
        }
        let cur = deps[i].str("commit.id")
        // Only deploys older than the live one.
        guard let prev = deps[(i + 1)...].first(where: { $0.str("status") == "deactivated" && $0.str("commit.id") != cur }), let id = prev.str("id") else { return nil }
        return (id, prev.str("commit.id"))
    }
    func rollback(_ p: PhoneProject, to deploy: String) async throws {
        _ = try await http.request("POST", "/services/\(p.id)/rollback", body: ["deployId": deploy])
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

    /// Head of the branch, and what waits between the live commit and it.
    func fill(_ p: inout PhoneProject) async {
        guard let repo = p.repo, let branch = p.branch else { return }
        let ref = branch.addingPercentEncoding(withAllowedCharacters: .urlPathAllowed) ?? branch
        do {
            let head = try await http.get("/repos/\(repo)/commits/\(ref)") as? JSON
            p.headSha = head?.str("sha")
            p.headAt = isoDate(head?.str("commit.committer.date"))
            p.headMsg = head?.str("commit.message").map { String($0.split(separator: "\n").first ?? "") }
        } catch { p.fetchError = error.localizedDescription; return }
        if let open = try? await http.get("/repos/\(repo)/pulls?state=open&per_page=100") as? [JSON] { p.openPRs = open.count }
        guard let live = p.liveSha, let head = p.headSha else { return }
        if live == head { p.pendingCommits = 0; p.pendingPRs = 0; return }
        do {
            let c = try await http.get("/repos/\(repo)/compare/\(live)...\(ref)") as? JSON
            p.pendingCommits = c?.int("ahead_by")
            p.compareStatus = c?.str("status")
            let commits = (c?["commits"] as? [JSON]) ?? []
            p.oldestPendingAt = isoDate(commits.first?.str("commit.committer.date"))
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
            // Rate limit, 5xx or network: say so instead of showing "0 commits waiting".
            p.fetchError = error.localizedDescription
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
