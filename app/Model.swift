// Deploy Center — What the script answers, and one project as the window keeps it.

import SwiftUI
import AppKit
import UserNotifications

// MARK: - Data

enum Platform: String, CaseIterable, Identifiable {
    case vercel = "Vercel", render = "Render"
    var id: String { rawValue }
    var cli: String { rawValue.lowercased() }
}

struct Doctor: Decodable {
    let jq: Bool; let vercelCli: Bool; let vercelApi: Bool; let vercelLoggedIn: Bool; let githubCli: Bool; let githubLoggedIn: Bool?; let renderKey: Bool
    /// Observer mode (DEPLOYS_READONLY or ~/.config/deploys/readonly): the script refuses every deploy.
    let readonly: Bool
    /// perl masks secrets before `ai`/`autofix` send a log; curl does every API call. Nil: an older
    /// script that does not say (not "missing").
    let perl: Bool?; let curl: Bool?
    /// A field the script does not send (older or newer script) counts as "no", instead of the
    /// whole answer failing and the app showing nothing.
    /// Scheduled jobs whose PATH no longer finds a tool ("autofix:gh"); newer scripts only.
    let jobsMissing: [String]
    /// The flags of a provider, under "providers":{"vercel":{…}} in newer scripts.
    private struct Flags: Decodable {
        let values: [String: Bool]
        init(from decoder: Decoder) throws {
            let c = try decoder.container(keyedBy: AnyKey.self)
            var v: [String: Bool] = [:]
            for k in c.allKeys { if let b = (try? c.decodeIfPresent(Bool.self, forKey: k)) ?? nil { v[k.stringValue] = b } }
            values = v
        }
    }
    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        // A provider's own field is read under "providers":{"<p>":{…}} (newer scripts send it there and,
        // for now, at the top too); at the top for older scripts.
        let nested = ((try? c.decodeIfPresent([String: Flags].self, forKey: .providers)) ?? nil) ?? [:]
        func flag(_ k: CodingKeys, of provider: String? = nil) -> Bool {
            if let provider, let v = nested[provider]?.values[k.stringValue] { return v }
            return ((try? c.decodeIfPresent(Bool.self, forKey: k)) ?? nil) ?? nested.values.lazy.compactMap { $0.values[k.stringValue] }.first ?? false
        }
        jobsMissing = ((try? c.decodeIfPresent([String].self, forKey: .jobsMissing)) ?? nil) ?? []
        jq = flag(.jq)
        vercelCli = flag(.vercelCli, of: "vercel"); vercelApi = flag(.vercelApi, of: "vercel"); vercelLoggedIn = flag(.vercelLoggedIn, of: "vercel")
        githubCli = flag(.githubCli); renderKey = flag(.renderKey, of: "render"); readonly = flag(.readonly)
        githubLoggedIn = (try? c.decodeIfPresent(Bool.self, forKey: .githubLoggedIn)) ?? nil
        perl = (try? c.decodeIfPresent(Bool.self, forKey: .perl)) ?? nil
        curl = (try? c.decodeIfPresent(Bool.self, forKey: .curl)) ?? nil
    }
    /// Tools the script needs that this Mac lacks (only what the script reported as missing).
    var missingTools: [String] { [perl == false ? "perl" : nil, curl == false ? "curl" : nil].compactMap { $0 } }
    private enum CodingKeys: String, CodingKey { case jq, vercelCli, vercelApi, vercelLoggedIn, githubCli, githubLoggedIn, renderKey, readonly, perl, curl, jobsMissing, providers }
}

/// What the script prints instead of a list when a command fails with `--json`.
struct ScriptFailure: Decodable { let error: String }
/// A list where a broken element is skipped and named, not the reason the whole list is gone.
/// With `maxBadShare`, a list where more than that share broke is an error, not a short list:
/// a changed format must not be taken (and cached) as "most projects are gone".
func decodeLossy<T: Decodable>(_ type: T.Type, from data: Data, label: String, maxBadShare: Double = 1) throws -> [T] {
    let all: [Lossy<T>]
    do { all = try JSONDecoder().decode([Lossy<T>].self, from: data) }
    catch {
        // `{"error": "…"}` instead of a list: the script's own words, not "the data couldn't be read".
        if let f = try? JSONDecoder().decode(ScriptFailure.self, from: data), !f.error.isEmpty { throw ToolError(message: Tool.shorten(f.error)) }
        Log.write("\(label): not a list (\(error)); it began: \(String(decoding: data.prefix(300), as: UTF8.self))")
        throw ToolError(message: L("Unexpected answer from \(label) – details in the log.", "Unerwartete Antwort von \(label) – Details im Log."))
    }
    let bad = all.enumerated().filter { $0.element.value == nil }
    if let first = bad.first {
        Log.write("\(label): skipped \(bad.count) of \(all.count) entries; first at \(first.offset): \(first.element.error ?? "")")
        if all.count >= 3, Double(bad.count) / Double(all.count) > maxBadShare {
            throw ToolError(message: L("Unexpected answer: \(bad.count) of \(all.count) entries unreadable – details in the log.",
                                       "Unerwartete Antwort: \(bad.count) von \(all.count) Einträgen unlesbar – Details im Log."))
        }
    }
    return all.compactMap(\.value)
}

struct VercelProject: Decodable {
    let name: String; let auto: Bool; let repo: String?; let ref: String?; let deployable: Bool
    let domain: String?; let lastAt: Double?; let lastState: String?; let headAt: Double?; let headMsg: String?
    let lastSha: String?; let headSha: String?
    let changed: Bool?; let pendingCommits: Int?; let pendingPRs: Int?; let openPRs: Int?
    let building: Bool?; let pendingPartial: Bool?; let oldestPendingAt: Double?; let rewritten: Bool?
    let openDrafts: Int?; let openBots: Int?
    let lastMsg: String?
    let risk: Risk?
    /// The newest attempt (any outcome); `lastState` is what production serves.
    let latestState: String?; let latestId: String?; let latestSha: String?
    /// Newer scripts: open PRs capped at 100, GitHub's budget nearly spent, the newest builds not read.
    let openPRsPartial: Bool?; let budgetLow: Bool?; let partial: Bool?
    /// A provider's note that part of the entry could not be read (Amplify: the domains).
    let fetchWarn: String?
    /// Deploy hooks: the branch head when the hook fired, not a commit seen live; `phase` says
    /// "queued" for a while after a trigger.
    let triggeredSha: String?; let phase: String?
}
struct RenderService: Decodable {
    let id: String; let name: String; let type: String; let paused: Bool; let auto: Bool; let deployable: Bool
    let url: String?; let domain: String?; let repo: String?; let ref: String?
    let lastAt: Double?; let lastState: String?; let headAt: Double?; let headMsg: String?
    let lastSha: String?; let headSha: String?
    let changed: Bool?; let pendingCommits: Int?; let pendingPRs: Int?; let openPRs: Int?
    let building: Bool?; let pendingPartial: Bool?; let oldestPendingAt: Double?; let rewritten: Bool?
    let openDrafts: Int?; let openBots: Int?
    let lastMsg: String?
    let risk: Risk?
    let latestId: String?; let latestSha: String?
    let openPRsPartial: Bool?; let budgetLow: Bool?; let partial: Bool?
    let fetchWarn: String?
    let triggeredSha: String?; let phase: String?
}
/// What every platform's list says of a project the same way; the row is built once from it,
/// so a new column is added here and in the two field lists only.
protocol ProjectRow {
    var name: String { get }; var auto: Bool { get }; var deployable: Bool { get }
    var repo: String? { get }; var ref: String? { get }; var domain: String? { get }
    var lastAt: Double? { get }; var lastState: String? { get }; var headAt: Double? { get }; var headMsg: String? { get }
    var lastSha: String? { get }; var headSha: String? { get }
    var changed: Bool? { get }; var pendingCommits: Int? { get }; var pendingPRs: Int? { get }; var openPRs: Int? { get }
    var building: Bool? { get }; var pendingPartial: Bool? { get }; var oldestPendingAt: Double? { get }; var rewritten: Bool? { get }
    var openDrafts: Int? { get }; var openBots: Int? { get }; var lastMsg: String? { get }; var risk: Risk? { get }
    var latestId: String? { get }; var latestSha: String? { get }
    var openPRsPartial: Bool? { get }; var budgetLow: Bool? { get }; var partial: Bool? { get }
    var fetchWarn: String? { get }
    var triggeredSha: String? { get }; var phase: String? { get }
}
extension VercelProject: ProjectRow {}
extension RenderService: ProjectRow {}
extension ProjectRow {
    /// The row; what differs per platform comes in as arguments.
    func item(id: String, platform: Platform, detail: String, note: String?, link: String?, latestState: String?) -> Item {
        Item(id: id, name: name, detail: detail, platform: platform, deployable: deployable, auto: auto, note: note, link: link,
             domain: domain, lastAt: date(lastAt), lastState: phase?.lowercased() == "queued" && triggeredSha != nil ? "queued" : lastState,
             headAt: date(headAt), headMsg: headMsg, lastSha: lastSha, headSha: headSha,
             repo: repo, ref: ref, changed: changed, pendingCommits: pendingCommits,
             pendingPRs: pendingPRs, openPRs: openPRs, lastMsg: lastMsg, openDrafts: openDrafts, openBots: openBots,
             building: building ?? false, pendingPartial: pendingPartial ?? false,
             oldestPendingAt: date(oldestPendingAt), rewritten: rewritten ?? false, risk: risk,
             latestState: latestState, latestId: latestId, latestSha: latestSha,
             openPRsPartial: openPRsPartial ?? false, budgetLow: budgetLow ?? false, partial: partial ?? false,
             fetchWarn: fetchWarn.flatMap { $0.isEmpty ? nil : $0 },
             triggered: triggeredSha.map { !$0.isEmpty } ?? false)
    }
}

struct Costs: Decodable {
    struct Day: Decodable, Identifiable { let day: String; let total: Double; let build: Double; var id: String { day } }
    struct Project: Decodable { let name: String; let build: Double; let builds: Int? }
    let days: [Day]; let projects: [Project]; let offDay: String?; let buildsComplete: Bool?
    /// The cost per day before auto-deploy went off, kept on this Mac (see `Store.loadExtras`):
    /// two weeks after `offDay` the window of `costs 14` no longer holds a day before it.
    struct Baseline: Codable, Equatable { let offDay: String; let perDay: Double; let days: Int }
    var baseline: Baseline? = nil
    private enum CodingKeys: String, CodingKey { case days, projects, offDay, buildsComplete }

    /// What one build of a project cost on average, only when every build of the week was counted.
    func perBuild(_ name: String) -> Double? {
        guard buildsComplete == true, let p = projects.first(where: { $0.name == name }), let n = p.builds, n > 0 else { return nil }
        return p.build / Double(n)
    }
}
struct Trigger: Decodable, Identifiable {
    let kind: String; let `where`: String; let detail: String
    var id: String { kind + `where` + detail }
}
/// One repo in detail, read when the details are opened (`deploys details`).
struct Details: Decodable {
    struct Commit: Decodable, Identifiable {
        let sha: String; let full: String?; let url: String?; let msg: String; let author: String?; let bot: Bool?; let at: Double; let pr: Int?
        var id: String { sha }
    }
    struct Checks: Decodable { let total: Int; let failed: Int; let running: Int }
    struct OpenPR: Decodable, Identifiable {
        let number: Int; let title: String; let author: String?; let bot: Bool?; let draft: Bool; let updatedAt: String; let url: String; let ci: String
        var id: Int { number }
    }
    let commits: [Commit]; let files: Int; let additions: Int; let deletions: Int; let risky: [String]
    let onlyBots: Bool; let compareUrl: String?; let checks: Checks?; let open: [OpenPR]
}

/// What waits to go live, scored by the script (`deploys risk`): green, yellow or red, and why.
struct Risk: Decodable, Equatable {
    struct Reason: Decodable, Equatable { let kind: String; let level: String; let files: [String]?; let text: String }
    let level: String; let reasons: [Reason]; let files: Int?; let lines: Int?
    var isRed: Bool { level == "red" }

    /// One reason in the app's language; the script's English text for a kind it does not know.
    func text(_ r: Reason) -> String {
        let f = (r.files ?? []).prefix(3).joined(separator: ", ") + ((r.files?.count ?? 0) > 3 ? " …" : "")
        switch r.kind {
        case "migrations": return L("Database migrations: ", "Datenbank-Migrationen: ") + f
        case "lockfile": return L("Dependencies changed: ", "Abhängigkeiten geändert: ") + f
        case "env": return L("Environment files: ", "Umgebungsdateien: ") + f
        case "config": return L("Build or platform config: ", "Build- oder Plattform-Konfiguration: ") + f
        case "size":
            let n = files ?? 0, l = lines ?? 0
            return r.level == "red" ? L("A very large diff: \(n) files, \(l) lines", "Ein sehr großer Diff: \(n) Dateien, \(l) Zeilen")
                                    : L("A large diff: \(n) files, \(l) lines", "Ein großer Diff: \(n) Dateien, \(l) Zeilen")
        default: return r.text
        }
    }
}
/// `deploys ci … --json`: the CI verdict of one commit.
struct CIReply: Decodable { let state: String; let reason: String }
/// `deploys window --json`: whether the deploy window is closed now, and by which rule.
struct WindowReply: Decodable { let denied: Bool; let reason: String? }

struct Started: Decodable { let id: String; let url: String?; let state: String? }
struct StatusReply: Decodable { let id: String; let url: String?; let state: String?; let error: String? }

enum RunState: Equatable {
    case idle, queued, starting, running(String), done(String?), failed(String), skipped(String)
    var isActive: Bool { switch self { case .queued, .starting, .running: return true; default: return false } }
}

struct Item: Identifiable {
    let id: String          // Vercel: project name, Render: service id
    let name: String
    let detail: String
    let platform: Platform
    let deployable: Bool
    let auto: Bool
    let note: String?
    let link: String?
    var domain: String? = nil
    var lastAt: Date? = nil
    var lastState: String? = nil
    var headAt: Date? = nil
    var headMsg: String? = nil
    var lastSha: String? = nil
    var headSha: String? = nil
    var repo: String? = nil
    var ref: String? = nil
    var kind: String? = nil        // Render service type, for the dashboard link
    /// Decided by the script (`changed`), so the app and `deploys changed` never disagree.
    var changed: Bool? = nil
    var pendingCommits: Int? = nil
    var pendingPRs: Int? = nil
    var openPRs: Int? = nil
    var lastMsg: String? = nil
    var openDrafts: Int? = nil
    var openBots: Int? = nil
    var building = false
    var pendingPartial = false
    var oldestPendingAt: Date? = nil
    var rewritten = false
    var risk: Risk? = nil
    /// The newest deploy attempt, which may have failed while production still serves an older one
    /// (Vercel). Autofix decides by it, so the row must too.
    var latestState: String? = nil
    var latestId: String? = nil
    var latestSha: String? = nil
    /// The open PRs stop at 100 (the script reads one page): "at least".
    var openPRsPartial = false
    /// GitHub's hourly budget was nearly spent: waiting commits and PRs were not counted this time.
    var budgetLow = false
    /// The platform answered only in part (Vercel: the newest builds could not be read), so a
    /// build under way may not show. A hint on the row, not an error banner.
    var partial = false
    /// The provider's own note on what it could not read (`fetchWarn`), shown like `partial`.
    var fetchWarn: String? = nil
    /// A deploy hook: `lastSha`/`lastMsg` are what was asked for when it fired, not what is live.
    var triggered = false
    var selected = false
    var state: RunState = .idle
    var startedAt: Date? = nil
    var deployId: String? = nil      // the deploy being followed, for cancelling
    var previewId: String? = nil     // a finished preview, for promoting it

    /// GitHub's page of the commits between what is live and the branch.
    var compareURL: URL? {
        guard let repo, let live = lastSha, !live.isEmpty, hasNewCommits else { return nil }
        // A branch may hold characters a URL cannot (#, %, spaces); "/" stays as GitHub expects it.
        let branch = ref ?? headSha ?? "main"
        let safe = branch.addingPercentEncoding(withAllowedCharacters: .urlPathAllowed.subtracting(CharacterSet(charactersIn: "#?"))) ?? branch
        // A GitHub repo is "owner/name"; any other host comes with it ("gitlab.com/group/name").
        let first = repo.split(separator: "/").first.map(String.init) ?? ""
        guard first.contains(".") else { return URL(string: "https://github.com/\(repo)/compare/\(live)...\(safe)") }
        if first == "github.com" { return URL(string: "https://\(repo)/compare/\(live)...\(safe)") }
        // GitLab (gitlab.com or a self-hosted one); the script only reads those two kinds of host.
        return URL(string: "https://\(repo)/-/compare/\(live)...\(safe)")
    }

    /// The service's page on Render; Vercel's address needs the team's slug, which the list does not carry.
    var dashboardURL: URL? {
        guard platform == .render else { return nil }
        let section = ["static_site": "static", "cron_job": "cron", "background_worker": "worker"][kind ?? ""] ?? "web"
        return URL(string: "https://dashboard.render.com/\(section)/\(id)")
    }

    /// A commit on GitHub that is not live yet.
    var hasNewCommits: Bool {
        if let changed { return changed }
        // An older script without `changed`: compare commits, times only as a fallback.
        if let live = lastSha, let head = headSha, !live.isEmpty, !head.isEmpty { return live != head }
        guard let h = headAt else { return false }
        guard let l = lastAt else { return true }
        return h > l.addingTimeInterval(60)
    }
}

/// The calendar day on this Mac ("2026-11-10"), for "once a day" and the daily history.
/// Not UTC: a day must not end at 1 or 2 a.m. local time.
/// Always the Gregorian calendar, so a Mac set to another calendar keeps the same keys.
func localDay(_ d: Date = Date(), timeZone: TimeZone = .current) -> String {
    var cal = Calendar(identifier: .gregorian); cal.timeZone = timeZone
    let c = cal.dateComponents([.year, .month, .day], from: d)
    return String(format: "%04d-%02d-%02d", c.year ?? 0, c.month ?? 0, c.day ?? 0)
}

/// Seconds since 1970; a value past 1e12 is milliseconds (some platforms answer in those).
func date(_ secs: Double?) -> Date? { secs.flatMap { $0 > 0 ? Date(timeIntervalSince1970: $0 > 1e12 ? $0 / 1000 : $0) : nil } }

// MARK: - Autofix and auto-deploy allowances, as the rows show them

extension Item {
    /// Any failure the platform reports for the newest deploy: a build failure (`lastFailed`) or one
    /// at runtime (Render update_failed, pre_deploy_failed). For explaining, not for autofix.
    var anyFailure: Bool {
        if lastFailed { return true }
        return ["error", "build_failed", "update_failed", "pre_deploy_failed"].contains((lastState ?? "").lowercased())
    }

    /// The newest build failed: what autofix would hand to Claude. The same rule as the script's
    /// AUTOFIX_FAILED: Vercel's newest attempt is ERROR (production may still be READY), Render's
    /// newest deploy is build_failed. Runtime failures (update_failed, pre_deploy_failed) are not
    /// build failures; the script leaves them to the person.
    var lastFailed: Bool {
        switch platform {
        case .vercel: return (latestState ?? lastState ?? "").lowercased() == "error"
        case .render: return (lastState ?? "").lowercased() == "build_failed"
        }
    }
    /// Failed, by either source: a deploy started here that failed, or the platform's last build.
    /// The one rule for the widget, the menu bar and Claude's "why did it fail".
    var failed: Bool {
        if case .failed = state { return true }
        return anyFailure
    }
}

/// `deploys scan status --json`: is the Claude Code CLI there and logged in, and the newest bug scans.
struct ScanReport: Decodable, Sendable {
    struct Run: Decodable, Sendable, Identifiable {
        let id: String
        let repo: String
        let at: Double
        let status: String          // running | clean | pr | failed
        let step: String?
        let prUrl: String?
        let fixes: Int?
        let error: String?
        var running: Bool { status == "running" }
    }
    /// A security check (`deploys check`): counts of vulnerable packages, secrets, code findings.
    struct Check: Decodable, Sendable, Identifiable {
        let id: String
        let repo: String
        let at: Double
        let status: String          // running | done | failed
        let osv: Int?
        let gitleaks: Int?
        let semgrep: Int?
        let tools: [String: String]?   // osv|gitleaks|semgrep -> clean|found|error|missing
        let error: String?
        var running: Bool { status == "running" }
        /// What a bug scan can work on: vulnerable packages and code findings, never secrets.
        var fixable: Int { (osv ?? 0) + (semgrep ?? 0) }
    }
    struct Tools: Decodable, Sendable { let osv: Bool; let gitleaks: Bool; let semgrep: Bool
        var any: Bool { osv || gitleaks || semgrep } }
    let installed: Bool
    let loggedIn: Bool
    let runs: [Run]
    let checks: [Check]?
    let tools: Tools?
    func newestCheck(repo: String?) -> Check? {
        guard let repo else { return nil }
        return (checks ?? []).filter { $0.repo.caseInsensitiveCompare(repo) == .orderedSame }.max { $0.at < $1.at }
    }
    /// The newest scan of a repo (owner/name).
    func newest(repo: String?) -> Run? {
        guard let repo else { return nil }
        return runs.filter { $0.repo.caseInsensitiveCompare(repo) == .orderedSame }.max { $0.at < $1.at }
    }
    var anyRunning: Bool { runs.contains(where: \.running) || (checks ?? []).contains(where: \.running) }
}

/// `deploys check show <id>`: the secrets part, for "rotate this key" (no values are ever in it).
struct CheckDetails: Decodable, Sendable {
    struct Leak: Decodable, Sendable, Hashable { let rule: String; let file: String; let line: Int?; let commit: String? }
    struct Part: Decodable, Sendable { let items: [Leak]? }
    struct Code: Decodable, Sendable { let secrets: [Leak]? }
    let gitleaks: Part?
    let semgrep: Code?
    /// gitleaks and Semgrep's secret rules, together.
    var leaks: [Leak] { (gitleaks?.items ?? []) + (semgrep?.secrets ?? []) }
}

/// `deploys autofix status --json`. Older scripts send `pr` and no PR state; newer ones
/// `prNumber`, `prState`, `prUrl`. A missing field is nil, a broken fire is skipped.
/// The one reader of this command: the rows, Settings > Autofix and the Claude connection.
struct AutofixReport: Decodable {
    struct Fire: Decodable, Identifiable {
        var id: String { "\(project)-\(at)" }
        /// Why a start failed or was skipped.
        var error: String? = nil
        let at: Double
        let project: String
        let platform: String?
        let status: String
        let session: String?
        let prNumber: Int?
        let prState: String?
        let prUrl: String?
        let mergedSha: String?
        let redeployedSha: String?
        /// The commit of the failed build that was handed over.
        let sha: String?
        /// Green again: the script stopped watching it.
        var done = false
        init(at: Double, project: String, platform: String?, status: String, session: String? = nil, prNumber: Int? = nil,
             prState: String? = nil, prUrl: String? = nil, mergedSha: String? = nil, redeployedSha: String? = nil, sha: String? = nil) {
            self.at = at; self.project = project; self.platform = platform; self.status = status; self.session = session
            self.prNumber = prNumber; self.prState = prState; self.prUrl = prUrl; self.mergedSha = mergedSha; self.redeployedSha = redeployedSha
            self.sha = sha
        }
        init(from decoder: Decoder) throws {
            let c = try decoder.container(keyedBy: K.self)
            func s(_ k: K) -> String? { ((try? c.decodeIfPresent(String.self, forKey: k)) ?? nil).flatMap { $0.isEmpty ? nil : $0 } }
            func n(_ k: K) -> Int? { (try? c.decodeIfPresent(Int.self, forKey: k)) ?? nil }
            at = try c.decode(Double.self, forKey: .at)
            project = try c.decode(String.self, forKey: .project)
            status = try c.decode(String.self, forKey: .status)
            platform = s(.platform); session = s(.session); prState = s(.prState)?.lowercased(); prUrl = s(.prUrl)
            prNumber = n(.prNumber) ?? n(.pr); mergedSha = s(.mergedSha); redeployedSha = s(.redeployedSha)
            // "unsupported" fires say why in `reason` (a GitLab repo, say).
            sha = s(.sha); error = s(.error) ?? s(.reason)
            done = ((try? c.decodeIfPresent(Bool.self, forKey: .done)) ?? nil) ?? false
        }
        private enum K: String, CodingKey { case at, project, platform, status, session, prNumber, pr, prState, prUrl, mergedSha, redeployedSha, sha, error, reason, done }
    }
    let routine: String?
    let token: Bool
    let fires: [Fire]
    /// The scheduled job is on (Settings > Autofix).
    let scheduled: Bool
    /// Tools the scheduled job no longer finds on its PATH (newer scripts).
    let pathMissing: [String]
    /// A routine and its token are set: `deploys autofix --only` can hand a build over.
    var ready: Bool { routine != nil && token }
    init(routine: String?, token: Bool, fires: [Fire], scheduled: Bool = false, pathMissing: [String] = []) {
        self.routine = routine; self.token = token; self.fires = fires; self.scheduled = scheduled; self.pathMissing = pathMissing
    }
    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: K.self)
        routine = ((try? c.decodeIfPresent(String.self, forKey: .routine)) ?? nil).flatMap { $0.isEmpty ? nil : $0 }
        token = ((try? c.decodeIfPresent(Bool.self, forKey: .token)) ?? nil) ?? false
        fires = (((try? c.decodeIfPresent([Lossy<Fire>].self, forKey: .fires)) ?? nil) ?? []).compactMap(\.value)
        scheduled = ((try? c.decodeIfPresent(Bool.self, forKey: .scheduled)) ?? nil) ?? false
        pathMissing = ((try? c.decodeIfPresent([String].self, forKey: .pathMissing)) ?? nil) ?? []
    }
    private enum K: String, CodingKey { case routine, token, fires, scheduled, pathMissing }

    /// The newest hand-over of this row. Fires name the project (a Render service by its name, not its id).
    func newest(for i: Item) -> Fire? {
        fires.filter { $0.project == i.name && ($0.platform?.lowercased() ?? i.platform.cli) == i.platform.cli }
            .max { $0.at < $1.at }
    }
}

/// What a row says about autofix. The status has no "done" flag, so each case ends by itself
/// when the row moves on (the build is green again, the merged fix is live).
enum RowAutofix: Equatable {
    case fixing(session: URL?)
    case prOpen(number: Int, url: URL?)
    case merged(sha: String, pr: Int?, url: URL?)
    /// A hand-over that is not running: waiting for a rate limit, or a start not confirmed yet.
    case waiting(Wait)
    case handedBack(HandBack)
    /// Autofix cannot work on this project (GitHub repos only); the reason comes from the script.
    case unsupported(reason: String?)
    /// Handed over long ago and still no PR: the session most likely ended without one (a cause
    /// outside the code, say). Its report is in the session, so the chip links there.
    case noPR(session: URL?)

    enum Wait: Equatable {
        case rateLimit
        /// "pending": the start is under way.
        case starting
        /// "pending" for longer than `unclearAfter`: the run most likely died; `autofix --only` tries again.
        case unclear
    }
    enum HandBack: Equatable {
        /// The session could not start (token, API): worth another try.
        case startFailed
        /// The fix itself did not build, or the PR was closed: over to the person.
        case fixFailed
    }

    /// A "pending" fire older than this most likely lost its run (the script retries it then).
    static let unclearAfter: TimeInterval = 15 * 60

    /// After this long without a PR a hand-over no longer counts as "fixing".
    static let stalledAfter: TimeInterval = 90 * 60

    /// A `done` fire (green again) with a PR still open shows that PR this long, then nothing:
    /// the script no longer syncs it, so "open" may be stale.
    static let doneOpenFor: TimeInterval = 24 * 3600

    static func of(_ i: Item, _ f: AutofixReport.Fire?, now: Date = Date()) -> RowAutofix? {
        guard let f else { return nil }
        let pr = f.prUrl.flatMap(URL.init(string:))
        if let m = f.mergedSha {
            if f.redeployedSha != nil { return nil }
            // The newest build failed again. On the fix's own commit: the fix did not work. On a
            // commit that is neither the fix nor the failure handed over: the branch broke anew
            // after the merge, so "deploy the fix" would only repeat that failure; say nothing
            // and let the new failure be handed over in its own right.
            if i.lastFailed, let cur = i.latestSha, !cur.isEmpty {
                func same(_ a: String, _ b: String) -> Bool { a.hasPrefix(b) || b.hasPrefix(a) }
                if same(cur, m) { return .handedBack(.fixFailed) }
                if let fs = f.sha, !fs.isEmpty, !same(cur, fs) { return nil }
            }
            // Live already, or nothing on the branch left to deploy.
            if !i.triggered, let live = i.lastSha, !live.isEmpty, live.hasPrefix(m) || m.hasPrefix(live) { return nil }
            return i.hasNewCommits ? .merged(sha: m, pr: f.prNumber, url: pr) : nil
        }
        if f.prState == "open", let n = f.prNumber {
            if f.done && now.timeIntervalSince1970 - f.at > doneOpenFor { return nil }
            return .prOpen(number: n, url: pr)
        }
        guard i.lastFailed else { return nil }   // green again: nothing to say
        // A failure now that is not the one handed over: an old fire (green since, or another
        // build) says nothing about it, and must not block handing this one over.
        if f.done { return nil }
        if let fs = f.sha, !fs.isEmpty, let cur = i.latestSha, !cur.isEmpty, !(fs.hasPrefix(cur) || cur.hasPrefix(fs)) { return nil }
        if f.prState == "closed" || f.prState == "merged" { return .handedBack(.fixFailed) }
        switch f.status {
        case "fired":
            let session = f.session.flatMap(URL.init(string:))
            if f.prState == nil, now.timeIntervalSince1970 - f.at > stalledAfter { return .noPR(session: session) }
            return .fixing(session: session)
        case "ratelimited": return .waiting(.rateLimit)
        case "pending": return .waiting(now.timeIntervalSince1970 - f.at > unclearAfter ? .unclear : .starting)
        case "failed": return .handedBack(.startFailed)
        case "skipped": return .handedBack(.fixFailed)
        case "unsupported": return .unsupported(reason: f.error)
        default: return nil
        }
    }

    /// Worth an `autofix sync`: a hand-over whose PR can still appear, be merged or be closed.
    /// A stalled one (no PR long after) is left to the 10-minute job, so the app does not ask every few minutes forever.
    static func needsSync(_ f: AutofixReport.Fire, now: Date = Date()) -> Bool {
        guard f.status == "fired", !f.done, f.mergedSha == nil, f.prState != "closed" else { return false }
        return f.prState == "open" || now.timeIntervalSince1970 - f.at <= stalledAfter
    }

    /// Key for "preselected once": a person who unticks the row is not overruled by the next load.
    static func preselectKey(_ i: Item, sha: String) -> String { "\(i.platform.cli)/\(i.id)@\(sha)" }
}

/// A temporary auto-deploy allowance (`deploys guard status --json`). `expiresAt` is epoch
/// seconds or an ISO 8601 date, whichever the script sends.
struct AutoDeployAllowance: Decodable, Equatable {
    let platform: String
    let project: String
    let expiresAt: Date
    init(platform: String, project: String, expiresAt: Date) { self.platform = platform; self.project = project; self.expiresAt = expiresAt }
    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: K.self)
        platform = try c.decode(String.self, forKey: .platform).lowercased()
        project = try c.decode(String.self, forKey: .project)
        expiresAt = try Self.expiry(c, .expiresAt)
    }
    private enum K: String, CodingKey { case platform, project, expiresAt }

    /// Epoch seconds, milliseconds or an ISO 8601 date: whichever the script sends. Shared with
    /// Settings > Guard, so both read the same.
    /// Made once: a formatter per decoded allowance was a cost on every refresh.
    private static let isoPlain = ISO8601DateFormatter()
    private static let isoFraction: ISO8601DateFormatter = { let g = ISO8601DateFormatter(); g.formatOptions = [.withInternetDateTime, .withFractionalSeconds]; return g }()
    static func expiry<Key: CodingKey>(_ c: KeyedDecodingContainer<Key>, _ key: Key) throws -> Date {
        if let n = try? c.decode(Double.self, forKey: key) { return Date(timeIntervalSince1970: n > 1e12 ? n / 1000 : n) }
        let s = try c.decode(String.self, forKey: key)
        guard let d = isoPlain.date(from: s) ?? isoFraction.date(from: s) else {
            throw DecodingError.dataCorruptedError(forKey: key, in: c, debugDescription: "not a date: \(s)")
        }
        return d
    }

    /// A Render allowance may name the service by id or by name; "all" and "*" are the script's wildcards.
    func covers(_ i: Item) -> Bool {
        (platform == "all" || platform == i.platform.cli) && (project == "*" || project == i.name || project == i.id)
    }
}
struct AllowanceReport: Decodable {
    let allowances: [AutoDeployAllowance]
    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: K.self)
        allowances = (((try? c.decodeIfPresent([Lossy<AutoDeployAllowance>].self, forKey: .allowances)) ?? nil) ?? []).compactMap(\.value)
    }
    private enum K: String, CodingKey { case allowances }
}

// MARK: - Tolerant reading of the Settings parts: an older or newer script may leave a field out.

extension KeyedDecodingContainer where K == AnyKey {
    func opt<T: Decodable>(_ key: String, _ type: T.Type = T.self) -> T? { (try? decodeIfPresent(T.self, forKey: AnyKey(key))) ?? nil }
}

// GuardStatus reads itself tolerantly in Guard.swift.
extension TeamConfig {
    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: AnyKey.self)
        me = c.opt("me")
        readonly = c.opt("readonly") ?? Flag(value: false, from: "")
        sources = (c.opt("sources", [Lossy<Source>].self) ?? []).compactMap(\.value)
        projects = c.opt("projects"); groups = c.opt("groups"); observers = c.opt("observers")
    }
}
