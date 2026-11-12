// Deploy Center for iPhone — Checks for the parts without UIKit: the "waiting" rule, PR numbers,
// rollback targets, ETags, error texts and dates. Answers come from made-up JSON, never a network.
// Run with ios/test.sh (compiled for macOS together with ios/App/Project.swift, Clients.swift and shared/).

import Foundation

var failures = 0
func check(_ ok: Bool, _ what: String, line: Int = #line) {
    if ok { print("ok   \(what)") } else { failures += 1; print("FAIL \(what) (line \(line))") }
}

// MARK: Recorded answers

/// Answers by path (with query); every request is noted.
final class Stub: URLProtocol {
    nonisolated(unsafe) static var routes: [String: (status: Int, headers: [String: String], body: String)] = [:]
    nonisolated(unsafe) static var seen: [URLRequest] = []
    /// Called before the routes: lets a test answer by header (If-None-Match).
    nonisolated(unsafe) static var special: ((URLRequest) -> (Int, [String: String], String)?)?

    override class func canInit(with request: URLRequest) -> Bool { true }
    override class func canonicalRequest(for request: URLRequest) -> URLRequest { request }
    override func startLoading() {
        Self.seen.append(request)
        let url = request.url!
        let key = url.path + (url.query.map { "?" + $0 } ?? "")
        let r = Self.special?(request).map { (status: $0.0, headers: $0.1, body: $0.2) }
            ?? Self.routes[key] ?? (404, [:], #"{"message":"Not Found"}"#)
        let resp = HTTPURLResponse(url: url, statusCode: r.status, httpVersion: "HTTP/1.1", headerFields: r.headers)!
        client?.urlProtocol(self, didReceive: resp, cacheStoragePolicy: .notAllowed)
        client?.urlProtocol(self, didLoad: Data(r.body.utf8))
        client?.urlProtocolDidFinishLoading(self)
    }
    override func stopLoading() {}

    static func reset() { routes = [:]; seen = []; special = nil; ETags.shared.removeAll() }
    static let session: URLSession = {
        let c = URLSessionConfiguration.ephemeral
        c.protocolClasses = [Stub.self]
        return URLSession(configuration: c)
    }()
}

// MARK: The rule

check(DeployRule.building(live: "READY", latest: "BUILDING"), "a building attempt counts as building")
check(!DeployRule.building(live: "READY", latest: "ERROR"), "an error is not building")
check(DeployRule.failed(latest: "ERROR", building: false), "an error is failed")
check(!DeployRule.failed(latest: "CANCELED", building: false), "a canceled attempt is not failed")
check(!DeployRule.failed(latest: "ERROR", building: true), "nothing is failed while it builds")
check(DeployRule.changed(deployable: true, paused: false, building: false, readError: false, compareStatus: "ahead",
                         liveSha: "a", headSha: "b", liveAt: nil, headAt: nil), "another head commit waits")
check(!DeployRule.changed(deployable: true, paused: false, building: false, readError: false, compareStatus: "behind",
                          liveSha: "a", headSha: "b", liveAt: nil, headAt: nil), "a branch behind the live commit does not wait")
check(!DeployRule.changed(deployable: true, paused: false, building: false, readError: true, compareStatus: nil,
                          liveSha: "a", headSha: "b", liveAt: nil, headAt: nil), "a read error does not count as waiting")
check(DeployRule.changed(deployable: true, paused: false, building: false, readError: false, compareStatus: nil,
                         liveSha: nil, headSha: "b", liveAt: Date(timeIntervalSince1970: 1), headAt: Date(timeIntervalSince1970: 2)),
      "without a live commit, a newer head time waits")
check(!DeployRule.changed(deployable: true, paused: true, building: false, readError: false, compareStatus: nil,
                          liveSha: "a", headSha: "b", liveAt: nil, headAt: nil), "a paused service does not wait")

var p = PhoneProject(provider: .vercel, id: "prj_1", name: "alpha")
p.deployable = true; p.liveSha = "a"; p.headSha = "a"; p.latestState = "READY"
check(p.upToDate && !p.changed, "same live and head commit is up to date")
p.headSha = "b"
check(p.changed && !p.upToDate && p.group == .waiting, "a new head commit waits")

// MARK: PR numbers and merging

check(GitHub.prNumber("Fix the header (#12)") == 12, "squash merge title gives the PR number")
check(GitHub.prNumber("Merge pull request #7 from someone/branch") == 7, "merge commit gives the PR number")
check(GitHub.prNumber("Plain commit") == nil, "a plain commit has no PR number")

var filled = PhoneProject(provider: .vercel, id: "other", name: "other")
filled.headSha = "h"; filled.pendingCommits = 3; filled.pendingPRs = 2; filled.fetchError = nil
var own = PhoneProject(provider: .render, id: "srv-1", name: "beta"); own.liveSha = "l"
let merged = PhoneProject.merging(own, filled)
check(merged.id == "srv-1" && merged.liveSha == "l" && merged.headSha == "h" && merged.pendingPRs == 2,
      "merging keeps deploy facts and takes repo facts")

// MARK: Dates and errors

check(isoDate("2026-01-02T03:04:05Z") != nil, "plain ISO date")
check(isoDate("2026-01-02T03:04:05.123Z") != nil, "ISO date with milliseconds")
check(isoDate("nonsense") == nil, "no date from nonsense")

check(APIError(status: 401, message: "x").isAuth, "401 is a key problem")
check(!APIError(status: 403, message: "x", rateLimited: true).isAuth, "a rate limit is no key problem")
check(APIError(status: 401, message: "x").errorDescription?.contains("401") == true, "the 401 text keeps the status")

// MARK: Rollback targets (made-up answers)

Stub.reset()
Stub.routes["/v9/projects/prj_1"] = (200, [:], #"{"targets":{"production":{"id":"dpl_live"}}}"#)
Stub.routes["/v6/deployments?projectId=prj_1&target=production&state=READY&limit=100"] = (200, [:], #"""
{"deployments":[
 {"uid":"dpl_new","created":4000,"meta":{"githubCommitSha":"ccc","githubCommitMessage":"Newer"}},
 {"uid":"dpl_live","created":3000,"meta":{"githubCommitSha":"bbb","githubCommitMessage":"Live"}},
 {"uid":"dpl_again","created":2000,"meta":{"githubCommitSha":"bbb","githubCommitMessage":"Live, again"}},
 {"uid":"dpl_old","created":1000,"meta":{"githubCommitSha":"aaa","githubCommitMessage":"Older\nbody"}}]}
"""#)
let vercel = Vercel(token: "t", team: nil, session: Stub.session)
let vp = PhoneProject(provider: .vercel, id: "prj_1", name: "alpha")
do {
    let t = try await vercel.rollbackTarget(vp)
    check(t?.id == "dpl_old" && t?.sha == "aaa" && t?.title == "Older" && t?.at == Date(timeIntervalSince1970: 1),
          "Vercel: the deploy before the live one, of another commit, with its first line and time")
} catch { check(false, "Vercel rollback target: \(error)") }

Stub.routes["/v9/projects/prj_1"] = (200, [:], #"{"targets":{"production":{"id":"dpl_gone"}}}"#)
do { _ = try await vercel.rollbackTarget(vp); check(false, "Vercel: an unknown live deploy must not guess") }
catch { check(true, "Vercel: an unknown live deploy is an error, not a guess") }

Stub.reset()
Stub.routes["/v1/services/srv-1/deploys?limit=50"] = (200, [:], #"""
[{"deploy":{"id":"dep-4","status":"build_failed","commit":{"id":"ddd"}}},
 {"deploy":{"id":"dep-3","status":"live","commit":{"id":"ccc"}}},
 {"deploy":{"id":"dep-2","status":"deactivated","commit":{"id":"ccc"}}},
 {"deploy":{"id":"dep-1","status":"deactivated","commit":{"id":"bbb","message":"Before"},"finishedAt":"2026-01-02T03:04:05.123456Z"}}]
"""#)
let render = Render(key: "k", session: Stub.session)
do {
    let t = try await render.rollbackTarget(PhoneProject(provider: .render, id: "srv-1", name: "beta"))
    check(t?.id == "dep-1" && t?.sha == "bbb" && t?.title == "Before" && t?.at != nil,
          "Render: the deactivated deploy of another commit before the live one")
} catch { check(false, "Render rollback target: \(error)") }

// MARK: GitHub: ETags, private repos, rewritten history

Stub.reset()
Stub.special = { r in
    guard r.url?.path == "/repos/o/r/commits/main" else { return nil }
    if r.value(forHTTPHeaderField: "If-None-Match") == "\"v1\"" { return (304, ["ETag": "\"v1\""], "") }
    return (200, ["ETag": "\"v1\""], #"{"sha":"head1","commit":{"message":"Head","committer":{"date":"2026-01-02T03:04:05Z"}}}"#)
}
let gh = GitHub(token: "g", session: Stub.session)
var gp = PhoneProject(provider: .vercel, id: "prj_2", name: "gamma"); gp.repo = "o/r"; gp.branch = "main"
await gh.fill(&gp)
check(gp.headSha == "head1", "GitHub: the head is read")
var gp2 = PhoneProject(provider: .vercel, id: "prj_2", name: "gamma"); gp2.repo = "o/r"; gp2.branch = "main"
await gh.fill(&gp2)
let conditional = Stub.seen.filter { $0.url?.path == "/repos/o/r/commits/main" }.last?.value(forHTTPHeaderField: "If-None-Match")
check(conditional == "\"v1\"" && gp2.headSha == "head1", "GitHub: the second read asks with the ETag and reuses the answer on 304")

Stub.reset()
var priv = PhoneProject(provider: .vercel, id: "prj_3", name: "delta"); priv.repo = "o/private"; priv.branch = "main"
await GitHub(token: nil, session: Stub.session).fill(&priv)
check(priv.fetchError?.contains("GitHub") == true, "GitHub: 404 without a token asks for a token")

Stub.reset()
Stub.routes["/repos/o/r/commits/main"] = (200, [:], #"{"sha":"new","commit":{"message":"x","committer":{"date":"2026-01-02T03:04:05Z"}}}"#)
Stub.routes["/repos/o/r/compare/old...main"] = (404, [:], #"{"message":"No common ancestor"}"#)
var rw = PhoneProject(provider: .vercel, id: "prj_4", name: "epsilon"); rw.repo = "o/r"; rw.branch = "main"; rw.liveSha = "old"
await GitHub(token: "g", session: Stub.session).fill(&rw)
check(rw.rewritten && rw.fetchError == nil && rw.pendingCommits == nil, "GitHub: a failed compare after a force push is rewritten history")

// MARK: Snapshot texts

check(DeploySnapshot.localized("de-DE", "en", "de") == "de" && DeploySnapshot.localized("en", "en", "de") == "en", "language pick")
var later = DeploySnapshot.sample
later = DeploySnapshot(at: Date().addingTimeInterval(60), demo: later.demo, waitingProjects: later.waitingProjects,
                       waitingCommits: later.waitingCommits, waitingPRs: later.waitingPRs, building: later.building,
                       failed: later.failed, saving: later.saving, projects: later.projects, language: later.language)
check(later.sameShown(as: DeploySnapshot.sample), "a snapshot that differs only in time shows the same")

print(failures == 0 ? "All checks passed." : "\(failures) check(s) failed.")
exit(failures == 0 ? 0 : 1)
