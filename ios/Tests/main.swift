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

let t0 = Date(timeIntervalSince1970: 1000)
func rec(_ sec: Double, _ st: String = "READY") -> DeployRecord { DeployRecord(id: "x", state: st, at: t0, finishedAt: t0.addingTimeInterval(sec)) }
check(BuildTime.typical([rec(30), rec(40), rec(50), rec(900, "ERROR")]) == 40, "median of finished builds, failed ones left out")
check(BuildTime.typical([rec(30), rec(40)]) == nil, "fewer than three builds: no typical time")
check(BuildTime.fraction(elapsed: 15, typical: 30) == 0.5, "progress follows the usual time")
check(BuildTime.fraction(elapsed: 900, typical: 30) == 0.95, "progress stops below full")
check(TokenShape.problem("rnd_abc\ndef", render: true) != nil, "a key with a line break inside is refused")
check(TokenShape.problem("  rnd_abcdef\n", render: true) == nil, "spaces around a key are fine")
check(TokenShape.problem("abcdef", render: true) != nil, "a Render key needs rnd_")
check(TokenShape.problem("abcdef", render: false) == nil, "another key has no fixed prefix")
check(HTTP.plainBody(Data("<html><body>Bad gateway</body></html>".utf8)) == "", "an HTML error page says nothing")
check(HTTP.plainBody(Data("  slow down ".utf8)) == "slow down", "a plain error body is kept")
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

// MARK: Round 10: the confirmed commit is pinned, PR counts that are minimums, one waiting rule

var dp = PhoneProject(provider: .vercel, id: "prj_9", name: "zeta"); dp.repo = "o/r"; dp.repoId = 77; dp.branch = "main"; dp.headSha = "abc123"
let vbody = (try? Vercel.deployBody(dp)) ?? [:]
let vgit = vbody["gitSource"] as? JSON
check(vgit?["sha"] as? String == "abc123" && vgit?["ref"] as? String == "main" && vgit?["repoId"] as? Int == 77,
      "Vercel deploy: the commit the person saw is pinned by sha")
dp.headSha = nil
check((try? Vercel.deployBody(dp))?["gitSource"].flatMap { $0 as? JSON }?["sha"] == nil, "Vercel deploy: no known head, no sha")
var rp = PhoneProject(provider: .render, id: "srv-9", name: "eta"); rp.headSha = "def456"
check(Render.deployBody(rp)["commitId"] as? String == "def456", "Render deploy: the seen commit is pinned by commitId")
rp.otherHost = "GitLab"
check(Render.deployBody(rp).isEmpty, "Render deploy: a repo outside GitHub has no pinned commit")

Stub.reset()
let manyCommits = (1...12).map { #"{"sha":"s\#($0)","commit":{"message":"plain \#($0)","committer":{"date":"2026-01-02T03:04:05Z"}}}"# }.joined(separator: ",")
Stub.routes["/repos/o/r/commits/main"] = (200, [:], #"{"sha":"new","commit":{"message":"x","committer":{"date":"2026-01-02T03:04:05Z"}}}"#)
Stub.routes["/repos/o/r/compare/old...main"] = (200, [:], #"{"ahead_by":12,"status":"ahead","commits":["# + manyCommits + "]}")
Stub.routes["/repos/o/r/pulls?state=open&per_page=100"] = (200, [:], "[]")
var many = PhoneProject(provider: .vercel, id: "prj_5", name: "theta"); many.repo = "o/r"; many.branch = "main"; many.liveSha = "old"
await GitHub(token: "g", session: Stub.session).fill(&many)
check(many.pendingPRs == 0 && many.pendingPRsAtLeast && many.prsAtLeast, "GitHub: commits whose PRs are not looked up make the PR count a minimum")

var w1 = PhoneProject(provider: .vercel, id: "a", name: "a"); w1.deployable = true; w1.repo = "o/r"; w1.liveSha = "1"; w1.headSha = "2"; w1.pendingPRs = 3
var w2 = w1; w2.latestState = "ERROR"      // failed: not "waiting"
var w3 = PhoneProject(provider: .render, id: "b", name: "b"); w3.deployable = true; w3.repo = "o/r"; w3.liveSha = "1"; w3.headSha = "2"; w3.pendingPRs = 2
check([w1, w2, w3].waitingOnly.count == 2 && [w1, w2, w3].waitingPRCount == 3,
      "Siri and the app count the same: failed ones do not wait, projects of one repo count their PRs once")

// MARK: Snapshot compatibility and the schedule
do {
    let old = Data(#"{"version":1,"at":"2026-01-01T00:00:00Z","demo":false,"waitingProjects":1,"waitingCommits":2,"waitingPRs":3,"building":0,"failed":0,"saving":null,"projects":[]}"#.utf8)
    let snap = try? DeploySnapshot.decoder.decode(DeploySnapshot.self, from: old)
    check(snap != nil && snap?.nextScheduled == nil && snap?.language == nil && snap?.connected == nil,
          "a snapshot from an older app (no language, connected or nextScheduled) still reads")
    var cal = Calendar(identifier: .gregorian); cal.timeZone = TimeZone(identifier: "UTC")!
    let sat = ISO8601DateFormatter().date(from: "2026-11-21T10:00:00Z")!
    let mon = ISO8601DateFormatter().date(from: "2026-11-23T08:00:00Z")!
    check(DeploySnapshot.nextDaily(at: "08:00", weekdaysOnly: true, after: sat, calendar: cal) == mon, "weekday schedule: Saturday waits for Monday")
    check(DeploySnapshot.nextDaily(at: "8", weekdaysOnly: false, after: sat, calendar: cal) == nil && DeploySnapshot.nextDaily(at: "", weekdaysOnly: false, after: sat, calendar: cal) == nil,
          "a schedule time that is not HH:MM is none")
}

// MARK: Snapshot texts

check(DeploySnapshot.localized("de-DE", "en", "de") == "de" && DeploySnapshot.localized("en", "en", "de") == "en", "language pick")
check(DeploySnapshot.systemLanguage(["fr-FR", "de-DE", "en"]) == "de-DE", "language list: the first one the apps speak, not the first one")
check(DeploySnapshot.systemLanguage(["fr", "es"]) == "en" && DeploySnapshot.systemLanguage([]) == "en", "language list: none known gives English")
check(DeploySnapshot.systemLanguage(["en-GB", "de"]) == "en-GB", "language list: English first stays English")
// An older writer: only the fields it knew. A newer reader still decodes it, and says so by `nil`s.
let oldJSON = #"{"version":1,"at":"2026-01-01T00:00:00Z","demo":false,"waitingProjects":2,"waitingCommits":4,"waitingPRs":1,"building":0,"failed":0,"projects":[]}"#
let oldSnap = try? DeploySnapshot.decoder.decode(DeploySnapshot.self, from: Data(oldJSON.utf8))
check(oldSnap?.waitingProjects == 2 && oldSnap?.language == nil && oldSnap?.connected == nil && oldSnap?.saving == nil, "an old snapshot without the newer fields still decodes")
var later = DeploySnapshot.sample
later = DeploySnapshot(at: Date().addingTimeInterval(60), demo: later.demo, waitingProjects: later.waitingProjects,
                       waitingCommits: later.waitingCommits, waitingPRs: later.waitingPRs, building: later.building,
                       failed: later.failed, saving: later.saving, projects: later.projects, language: later.language)
check(later.sameShown(as: DeploySnapshot.sample), "a snapshot that differs only in time shows the same")

// The QR code: the Mac shows it for 60 s; a photo of it is good for 90 s, a code from the future for 30 s of clock difference.
func qrAt(_ updated: Date) -> String { var k = LinkedKeys(); k.vercel = "tok"; k.updated = updated; return PhoneLink.qrText(k) ?? "" }
let qrNow = Date()
func qrIs(_ t: TimeInterval, _ want: PhoneLink.QRResult) -> Bool { PhoneLink.read(qr: qrAt(qrNow.addingTimeInterval(-t)), now: qrNow) == want }
check(qrIs(30, .keys({ var k = LinkedKeys(); k.vercel = "tok"; k.updated = qrNow.addingTimeInterval(-30); return k }())), "qr: 30 s old is taken")
check(qrIs(200, .expired), "qr: 200 s old is too old (was 5 minutes)")
check(qrIs(-10, .keys({ var k = LinkedKeys(); k.vercel = "tok"; k.updated = qrNow.addingTimeInterval(10); return k }())), "qr: a few seconds ahead (clock) is taken")
check(qrIs(-120, .expired), "qr: two minutes in the future is refused")
var kA = LinkedKeys(); kA.vercel = "t"; kA.savingPerMonth = 12.341
var kB = kA; kB.savingPerMonth = 12.3449
check(kA.sameContent(as: kB), "same content: a saving that differs below the cent is the same")
kB.savingPerMonth = 12.36
check(!kA.sameContent(as: kB), "same content: a different cent is not")

// MARK: Repo addresses, deep links, polling, the snapshot file (IDEEN-12)

func gh(_ s: String) -> String? { RepoRef.parse(s).github }
check(gh("https://github.com/o/n.git") == "o/n" && gh("git@github.com:o/n.git") == "o/n" && gh("o/n") == "o/n", "repo: the usual forms")
check(gh("ssh://git@github.com/o/n") == "o/n", "repo: ssh:// with a user is GitHub")
check(gh("https://user@github.com/o/n") == "o/n" && gh("https://user:tok@github.com/o/n.git") == "o/n", "repo: a user (and password) in front of the host is dropped")
check(gh("https://github.com:443/o/n") == "o/n" && gh("ssh://git@github.com:22/o/n") == "o/n", "repo: a port is not part of the path")
check(RepoRef.parse("git@gitlab.com:g/n.git").otherHost == "GitLab" && RepoRef.parse("ssh://git@git.example.test:2222/g/n").otherHost == "git.example.test",
      "repo: another host is named without user and port")
let pl = DeepLink.target(project: "vercel:web", platform: nil)
check(pl.name == "web" && pl.platform == "vercel", "deep link: platform:name is split")
check(DeepLink.target(project: "Render:api", platform: nil).name == "api", "deep link: the platform may be any case")
check(DeepLink.target(project: "team:web", platform: nil).name == "team:web", "deep link: a colon that is no platform stays in the name")
check(DeepLink.target(project: "web", platform: "Vercel").platform == "Vercel", "deep link: a platform parameter is kept")
check(DeepLink.samePlatform("Vercel", "vercel") && DeepLink.samePlatform("Render", nil) && !DeepLink.samePlatform("Render", "vercel"), "deep link: platforms compare without case")
check(PollEvery.seconds(elapsed: 10) == 6 && PollEvery.seconds(elapsed: 300) == 15 && PollEvery.seconds(elapsed: 900) == 30, "polling slows down for long builds")
var pollAsks = 0.0, pollT = 0.0
while pollT < 20 * 60 { pollT += PollEvery.seconds(elapsed: pollT); pollAsks += 1 }
check(pollAsks < 100, "polling: fewer than 100 asks in 20 minutes")

// stateWord
check(PhoneProject.stateWord("BUILD_FAILED") == L("build failed", "Build fehlgeschlagen") && PhoneProject.stateWord("canceled") == L("canceled", "abgebrochen"), "stateWord: known states")
check(PhoneProject.stateWord("some_new_state") == "some new state", "stateWord: an unknown state reads as words")

// The snapshot file: missing, unreadable, from a newer app, fine
let tdir = FileManager.default.temporaryDirectory.appendingPathComponent("dc-snap-\(UUID().uuidString)")
try? FileManager.default.createDirectory(at: tdir, withIntermediateDirectories: true)
let tfile = tdir.appendingPathComponent("snap.json")
check(DeploySnapshot.readOutcome(tfile).problem == .missing, "snapshot file: none yet is 'missing'")
try? Data("not json".utf8).write(to: tfile)
check(DeploySnapshot.readOutcome(tfile).problem == .unreadable, "snapshot file: garbage is 'unreadable'")
try? Data(#"{"version":99,"at":"2026-01-01T00:00:00Z","somethingNew":{"x":1}}"#.utf8).write(to: tfile)
check(DeploySnapshot.readOutcome(tfile).problem == .appNewer, "snapshot file: a newer app's file says the widget is old")
try? DeploySnapshot.encoder.encode(DeploySnapshot.sample).write(to: tfile)
check(DeploySnapshot.readOutcome(tfile).snapshot != nil && DeploySnapshot.readOutcome(tfile).problem == nil && DeploySnapshot.read(tfile) != nil, "snapshot file: a good file reads")
try? FileManager.default.removeItem(at: tdir)

// The Smart Stack: failures first, then a long build, then an old wait
let rnow = Date()
func mkProj(_ s: DeploySnapshot.Project.Status, _ ago: TimeInterval) -> DeploySnapshot.Project {
    .init(name: "x", platform: "Vercel", status: s, commits: 1, prs: 0, since: rnow.addingTimeInterval(-ago), message: nil)
}
func mkSnap(_ ps: [DeploySnapshot.Project]) -> DeploySnapshot {
    DeploySnapshot(at: rnow, demo: false, waitingProjects: 0, waitingCommits: 0, waitingPRs: 0,
                   building: ps.filter { $0.status == .building }.count, failed: ps.filter { $0.status == .failed }.count,
                   saving: nil, projects: ps)
}
check(mkSnap([mkProj(.failed, 60)]).relevanceScore(at: rnow) == 10, "relevance: a failure is 10")
check(mkSnap([mkProj(.building, 60)]).relevanceScore(at: rnow) == nil, "relevance: a fresh build is not raised")
check(mkSnap([mkProj(.building, 20 * 60)]).relevanceScore(at: rnow) == 6, "relevance: a build over 15 minutes is 6")
check(mkSnap([mkProj(.waiting, 30 * 3600)]).relevanceScore(at: rnow) == 3, "relevance: a project waiting over a day is 3")
check(mkSnap([mkProj(.waiting, 3600)]).relevanceScore(at: rnow) == nil, "relevance: a short wait is not raised")

print(failures == 0 ? "All checks passed." : "\(failures) check(s) failed.")
exit(failures == 0 ? 0 : 1)
