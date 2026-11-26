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

// MARK: Round 12 (iOS)

// Spoken: the age is said only for a state older than 15 minutes
let sNow = Date()
check(Spoken.age(sNow.addingTimeInterval(-60), now: sNow) == "", "spoken: a fresh state says no age")
check(Spoken.age(sNow.addingTimeInterval(-20 * 60), now: sNow) != "", "spoken: an old state says its age")
check(Spoken.age(nil, now: sNow) == "", "spoken: no time, no age")
check(Spoken.failures([], hideNames: true) == L("Nothing failed.", "Nichts ist fehlgeschlagen."), "spoken: nothing failed")
let sFailed: PhoneProject = { var p = PhoneProject(provider: .vercel, id: "p1", name: "alpha"); p.latestState = "ERROR"; p.liveState = "READY"; return p }()
check(Spoken.failures([sFailed]).contains("alpha"), "spoken: failures name the project")
check(!Spoken.failures([sFailed], hideNames: true).contains("alpha"), "spoken: with the lock on no name is said")

// The remembered GitHub limit
RateGate.clear()
check(RateGate.until == nil, "rate gate: none at first")
RateGate.note(APIError(status: 403, message: "x", rateLimited: true, retryAt: sNow.addingTimeInterval(600)), now: sNow)
check(RateGate.until != nil, "rate gate: a spent limit is remembered")
RateGate.clear()
RateGate.note(APIError(status: 403, message: "x", rateLimited: true, retryAt: sNow.addingTimeInterval(86400)), now: sNow)
check((RateGate.until?.timeIntervalSince(sNow) ?? 9e9) <= 3601, "rate gate: at most an hour ahead")
RateGate.clear()
RateGate.note(APIError(status: 500, message: "x"), now: sNow)
check(RateGate.until == nil, "rate gate: another error sets nothing")
RateGate.note(APIError(status: 403, message: "x", rateLimited: true, retryAt: sNow.addingTimeInterval(-5)), now: sNow)
check(RateGate.until == nil, "rate gate: a limit that has passed is no limit")

// Render: the last good deploys stand in for a failed read, for ten minutes
RenderDeps.shared.removeAll()
RenderDeps.shared.set("srv-1", [["status": "live"]])
check(RenderDeps.shared.recent("srv-1") != nil, "render deps: kept")
check(RenderDeps.shared.recent("srv-1", now: Date().addingTimeInterval(700)) == nil, "render deps: not after ten minutes")
check(RenderDeps.shared.recent("srv-2") == nil, "render deps: unknown service")

// History cache
HistoryCache.clear()
check(HistoryCache.load("Vercel/a") == nil, "history cache: empty at first")
HistoryCache.save([DeployRecord(id: "d1", state: "READY", at: sNow, sha: "abc1234", title: "Fix")], for: "Vercel/a")
check(HistoryCache.load("Vercel/a")?.first?.id == "d1" && HistoryCache.load("Vercel/a")?.first?.title == "Fix", "history cache: round trip")
for i in 0..<45 { HistoryCache.save([], for: "k\(i)") }
check(HistoryCache.load("Vercel/a") == nil, "history cache: the oldest are dropped past 40")
HistoryCache.clear()
check(HistoryCache.load("k44") == nil, "history cache: clear")

// Followed runs
UserDefaults.standard.removeObject(forKey: FollowedRuns.defaultsKey)
FollowedRuns.add(key: "Vercel/a", id: "d1", now: sNow)
FollowedRuns.add(key: "Vercel/a", id: "d2", now: sNow)
check(FollowedRuns.fresh(now: sNow).count == 1 && FollowedRuns.fresh(now: sNow).first?.id == "d2", "followed runs: one per project, the newest id")
check(FollowedRuns.fresh(now: sNow.addingTimeInterval(21 * 60)).isEmpty, "followed runs: none after 20 minutes")
FollowedRuns.remove("Vercel/a")
check(FollowedRuns.fresh(now: sNow).isEmpty, "followed runs: removed at the end")

// The filtered widget picture
let fSnap = DeploySnapshot(at: sNow, demo: false, waitingProjects: 2, waitingCommits: 3, waitingPRs: 2, building: 1, failed: 1,
                           byPlatform: nil, saving: nil, projects: [
    .init(name: "a", platform: "Vercel", status: .failed, commits: 1, prs: 0, since: sNow, message: nil),
    .init(name: "b", platform: "Render", status: .waiting, commits: 2, prs: 2, since: sNow, message: nil),
    .init(name: "c", platform: "Vercel", status: .building, commits: 0, prs: 0, since: sNow, message: nil),
    .init(name: "d", platform: "Vercel", status: .waiting, commits: 1, prs: 0, since: sNow, message: nil)])
var fWithSplit = fSnap
fWithSplit.byPlatform = DeploySnapshot.platformCounts(fSnap.projects)
check(fWithSplit.byPlatform?.first { $0.platform == "Render" }?.prs == 2, "platform counts: PRs of Render")
check(fWithSplit.filtered(platform: "Vercel", onlyFailed: false).projects.map(\.name) == ["a", "c", "d"], "filtered: one platform's rows")
check(fWithSplit.filtered(platform: "Vercel", onlyFailed: false).failed == 1 && fWithSplit.filtered(platform: "Vercel", onlyFailed: false).waitingPRs == 0, "filtered: one platform's numbers")
check(fWithSplit.filtered(platform: nil, onlyFailed: true).projects.map(\.name) == ["a"], "filtered: only failed rows")
check(fWithSplit.filtered(platform: nil, onlyFailed: true).waitingProjects == 0 && fWithSplit.filtered(platform: nil, onlyFailed: true).failed == 1, "filtered: only failed numbers")
check(fSnap.filtered(platform: nil, onlyFailed: false) == fSnap, "filtered: nothing asked, nothing changed")

// An error body is masked before it reaches a toast
check(!(LogMask.mask("vercel deploy --token abcdefSECRET123456 --prod") ?? "").contains("abcdefSECRET123456"), "error body: a token is masked")

// A saved Mac figure: the snapshot's saving is the monthly figure
check(DeploySnapshot.Saving(before: 120.0 / 30, after: 0).month == 120, "saving: a month's figure round-trips")

// MARK: Keychain logic against a fake (IDEEN-12 C58)

final class FakeKeychain: KeychainBackend {
    var items: [String: Data] = [:]            // "group|key"
    var missingEntitlement: Set<String> = []   // groups that are "not in the signature"
    var lockedDevice = false
    private func id(_ k: String, _ g: String?) -> String { (g ?? "-") + "|" + k }
    func copy(_ key: String, group: String?) -> (status: OSStatus, data: Data?) {
        if lockedDevice { return (errSecInteractionNotAllowed, nil) }
        if let g = group, missingEntitlement.contains(g) { return (errSecMissingEntitlement, nil) }
        guard let d = items[id(key, group)] else { return (errSecItemNotFound, nil) }
        return (errSecSuccess, d)
    }
    func write(_ key: String, _ value: Data, group: String?) -> OSStatus {
        if let g = group, missingEntitlement.contains(g) { return errSecMissingEntitlement }
        items[id(key, group)] = value; return errSecSuccess
    }
    func delete(_ key: String, group: String?) -> OSStatus {
        if let g = group, missingEntitlement.contains(g) { return errSecMissingEntitlement }
        return items.removeValue(forKey: id(key, group)) == nil ? errSecItemNotFound : errSecSuccess
    }
}
let fk = FakeKeychain()
Keychain.backend = fk; Keychain.ownGroup = "TEAM.app.test"; Keychain.sharedGroup = "TEAM.app.deploycenter.shared"
check(Keychain.lookup("vercel") == .missing, "keychain: nothing at first")
check(Keychain.set("vercel", "  tok123  ") && Keychain.get("vercel") == "tok123", "keychain: set trims and reads back")
check(fk.items["TEAM.app.test|vercel"] != nil, "keychain: written into the app's own group")
fk.items = [:]
fk.items["-|render"] = Data("old-key".utf8)
check(Keychain.lookup("render") == .found("old-key"), "keychain: an old item outside the own group is found")
check(fk.items["TEAM.app.test|render"] != nil, "keychain: ... and moved into the own group")
fk.items = ["TEAM.app.deploycenter.shared|render": Data("team-key".utf8)]
// the migration reads with no group: the fake keeps the team item apart, so it stays missing; a delete of both places works
check(Keychain.set("render", ""), "keychain: an empty value deletes (own and team group)")
check(fk.items.isEmpty, "keychain: nothing is left after the delete")
fk.missingEntitlement = ["TEAM.app.test"]
check(Keychain.set("github", "ghp-abc") && fk.items["-|github"] != nil, "keychain: own group not in the signature: writes without a group")
check(Keychain.get("github") == "ghp-abc", "keychain: ... and reads it back the same way")
fk.missingEntitlement = []
fk.lockedDevice = true
check(Keychain.lookup("github") == .failed, "keychain: a locked device is 'failed', not 'missing'")
fk.lockedDevice = false
Keychain.backend = SystemKeychain()

// MARK: Widget words (IDEEN-12 C59)
check(Words(german: false)("Live", "Live!") == "Live" && Words(german: true)("Live", "Live!") == "Live!", "words: picks the language")
check(Words(german: false).n(1, ("PR waiting", "PR wartet"), ("PRs waiting", "PRs warten")) == "1 PR waiting", "words: one")
check(Words(german: true).n(3, ("PR waiting", "PR wartet"), ("PRs waiting", "PRs warten")) == "3 PRs warten", "words: many")
check(Words(german: false).n(0, ("project", "Projekt"), ("projects", "Projekte")) == "0 projects", "words: zero is plural")
check(Words(DeploySnapshot.sample).german == (DeploySnapshot.localized(DeploySnapshot.sample.language, "en", "de") == "de"), "words: follows the snapshot's language")
check(Words.staleAfter == 3 * 3600, "words: a snapshot is old after three hours")

// MARK: Failure hint

check(FailureHint.hint(for: "") == nil && FailureHint.hint(for: "   ") == nil, "hint: an empty text has none")
check(FailureHint.hint(for: "Deploy window closed until 09:00")?.anchor == "deploy-window-closed", "hint: a documented topic links its section")
check(FailureHint.hint(for: "FATAL ERROR: Reached heap limit - JavaScript heap out of memory")?.anchor == nil
      && FailureHint.hint(for: "FATAL ERROR: JavaScript heap out of memory")?.en.contains("memory") == true, "hint: out of memory")
check(FailureHint.hint(for: "Error: Cannot find module 'left-pad'")?.en.contains("missing") == true, "hint: a missing module")
check(FailureHint.hint(for: "npm ERR! code ERESOLVE")?.en.contains("versions") == true, "hint: a dependency conflict")
check(FailureHint.hint(for: "sh: 1: next: command not found")?.de.contains("Befehl") == true, "hint: a missing command, in German")
check(FailureHint.hint(for: "Compiled successfully") == nil, "hint: a good line has none")
check(FailureHint.hint(for: "ERROR: ignored build step")?.anchor == "skipped-or-canceled-by-vercel-ignored-build-step", "hint: ErrorHelp's phrase")
let hintLog = ["npm warn deprecated x", "Error: ENOSPC: no space left on device", "Error: Cannot find module 'a'"]
check(FailureHint.hint(lines: hintLog, errorAt: 2)?.en.contains("missing") == true, "hint: the error line decides")
check(FailureHint.hint(lines: hintLog, errorAt: nil)?.en.contains("disk") == true, "hint: no error line, the first match in order")
check(FailureHint.hint(lines: hintLog, errorAt: 9)?.en.contains("disk") == true, "hint: an error index out of range falls back")
check(FailureHint.hint(lines: [], errorAt: 0) == nil, "hint: an empty log has none")
let anchored = FailureHint.hint(for: "deploy window closed")!
check(FailureHint.url(for: anchored, german: true)?.absoluteString.hasSuffix("TROUBLESHOOTING.de.md#deploy-window-closed") == true
      && FailureHint.url(for: anchored, german: false)?.absoluteString.contains("TROUBLESHOOTING.md#") == true, "hint: the link follows the language")
check(FailureHint.url(for: FailureHint.hint(for: "ENOSPC")!, german: false) == nil, "hint: a cause without a topic has no link")
check(FailureHint.causes.allSatisfy { !$0.needles.isEmpty && $0.needles.allSatisfy { $0 == $0.lowercased() } && !$0.en.isEmpty && !$0.de.isEmpty },
      "hint: every cause has lowercase phrases and both texts")

// MARK: Note plan

do {
    let f = NotePlan.make(id: "failed:site", project: "site", projectName: "Site", hideNames: false)
    check(f.thread == "deploy-center-site" && f.relevance == 1.0 && f.level == .active && !f.waiting && f.summaryArgument == "Site", "note plan: a failure is one thread per project, urgent, named")
    let w = NotePlan.make(id: "waiting:site", project: "site", projectName: "Site", hideNames: false)
    check(w.waiting && w.relevance == 0.3 && w.level == .passive, "note plan: waiting is quiet and offers the deploy action")
    check(NotePlan.make(id: "recovered:a", project: "a", hideNames: false).relevance == 0.5
          && NotePlan.make(id: "live:a", project: "a", hideNames: false).relevance == 0.5, "note plan: good news ranks in the middle")
    check(NotePlan.make(id: "deploy-a-123", project: "a", hideNames: false).relevance == 0.7, "note plan: a deploy's end ranks above news")
    let s = NotePlan.make(id: "summary", project: nil, hideNames: false)
    check(s.thread == "deploy-center" && s.summaryArgument == nil && s.level == .passive, "note plan: the summary has its own thread and no name")
    check(NotePlan.make(id: "failed:site", project: "site", projectName: "Site", hideNames: true).summaryArgument == nil, "note plan: no project name with Unlock on open")
    check(NotePlan.make(id: nil, project: "a", projectName: "", hideNames: false).summaryArgument == nil, "note plan: an empty name is none")
    check(NotePlan.identifier(id: "failed:a", project: "a") == "failed:a" && NotePlan.identifier(id: nil, project: "a") == "deploy-a"
          && NotePlan.identifier(id: nil, project: nil) == "deploy-", "note plan: the same news has the same identifier")
}

// MARK: Timeline

do {
    var cal = Calendar(identifier: .gregorian); cal.timeZone = TimeZone(identifier: "UTC")!
    let now = Date(timeIntervalSince1970: 1_800_000_000)             // a fixed moment
    let day: TimeInterval = 86400
    let startToday = cal.startOfDay(for: now)
    func rec(_ id: String, _ state: String, _ at: Date?) -> DeployRecord { DeployRecord(id: id, state: state, at: at) }
    let a = DeployTimeline.Source(key: "vercel/a", name: "Alpha", records: [
        rec("1", "READY", now.addingTimeInterval(-3600)), rec("2", "ERROR", startToday.addingTimeInterval(-3600)),
        rec("3", "READY", startToday.addingTimeInterval(-day * 3)), rec("old", "READY", startToday.addingTimeInterval(-day * 9)),
        rec("none", "READY", nil)])
    let b = DeployTimeline.Source(key: "render/b", name: "Beta", records: [
        rec("1", "live", now.addingTimeInterval(-60)), rec("fut", "live", now.addingTimeInterval(7200))])
    let days = DeployTimeline.build([a, b], now: now, calendar: cal)
    check(days.count == 3, "timeline: three days with deploys")
    check(days.first?.label == .today && days.first?.items.count == 3, "timeline: today first, a future time counts as today")
    check(days.first?.items.map(\.id).first == "render/b/fut" || days.first?.items.first?.projectName == "Beta", "timeline: newest first")
    check(days.dropFirst().first?.label == .yesterday && days.dropFirst().first?.failures == 1, "timeline: yesterday, with its failure counted")
    if case .date(let d)? = days.last?.label { check(d == startToday.addingTimeInterval(-day * 3), "timeline: an older day carries its date") }
    else { check(false, "timeline: an older day carries its date") }
    let ids = days.flatMap(\.items).map(\.id)
    check(!ids.contains("vercel/a/old") && !ids.contains("vercel/a/none"), "timeline: older than the window and undated are left out")
    check(Set(ids).count == ids.count && ids.contains("vercel/a/1") && ids.contains("render/b/1"), "timeline: the same deploy id in two projects stays two items")
    check(DeployTimeline.build([a, b], now: now, calendar: cal, days: 7, limit: 2).flatMap(\.items).count == 2, "timeline: the limit keeps the newest")
    check(DeployTimeline.build([a, b], now: now, calendar: cal, days: 1).count == 1, "timeline: one day is today only")
    check(DeployTimeline.build([], now: now, calendar: cal).isEmpty && DeployTimeline.build([a], now: now, calendar: cal, days: 0).isEmpty, "timeline: nothing in, nothing out")
    let tie = DeployTimeline.build([DeployTimeline.Source(key: "x", name: "X", records: [rec("b", "READY", now), rec("a", "READY", now)])], now: now, calendar: cal)
    check(tie.first?.items.map(\.id) == ["x/a", "x/b"], "timeline: the same time sorts by id, so the order is stable")
}

// MARK: Adaptive layout

do {
    typealias S = AdaptiveLayout.TextScale
    check(AdaptiveLayout.summary(.large) == .row && AdaptiveLayout.summary(.xxLarge) == .row, "layout: the standard sizes show four in a row")
    check(AdaptiveLayout.summary(.xxxLarge) == .grid, "layout: the largest standard size shows two by two")
    check(S.allCases.filter { $0.isAccessibility }.allSatisfy { AdaptiveLayout.summary($0) == .column }, "layout: every accessibility size shows one column")
    check(zip(S.allCases, S.allCases.dropFirst()).allSatisfy { AdaptiveLayout.summary($0) <= AdaptiveLayout.summary($1) },
          "layout: a larger text never gets the tighter summary")
    check(S.allCases.count == 12 && S.allCases.first == .xSmall && S.allCases.last == .accessibility5, "layout: twelve sizes, in order")
    check(AdaptiveLayout.timeBesideName(.xxxLarge) && !AdaptiveLayout.timeBesideName(.accessibility1), "layout: the time goes under the name from the first accessibility size")
    check(AdaptiveLayout.titleLines(.large) == 1 && AdaptiveLayout.titleLines(.xxxLarge) == 2 && AdaptiveLayout.titleLines(.accessibility3) == nil,
          "layout: titles get more lines as the text grows, none cut at accessibility sizes")
}

// Health score and open outages.
do {
    let now = Date()
    func rec(_ id: String, _ state: String, _ daysAgo: Double) -> DeployRecord { DeployRecord(id: id, state: state, at: now.addingTimeInterval(-daysAgo * 86400)) }
    let clean = PhoneHealth.score([rec("1", "READY", 1), rec("2", "READY", 2)], now: now)
    check(clean.score == 100, "health: a clean project scores 100")
    let open = PhoneHealth.score([rec("1", "READY", 5), rec("2", "ERROR", 2)], now: now)
    check(open.openOutage && open.openSince != nil, "health: a failure with no good deploy after it is open")
    check(PhoneHealth.score([rec("1", "CANCELED", 1)], now: now).score == nil, "health: canceled counts for nothing")
    let healed = PhoneHealth.score([rec("1", "ERROR", 3), rec("2", "READY", 2.99)], now: now)
    check(!healed.openOutage, "health: a good deploy after a failure ends the outage")
    check(HealthFormula.lerp(0.25, best: 0, worst: 0.5, max: 40) == 20, "formula: linear between best and worst")
    var broken = PhoneProject(provider: .vercel, id: "p1", name: "shop")
    broken.latestState = "ERROR"
    var fine = PhoneProject(provider: .vercel, id: "p2", name: "blog")
    fine.latestState = "READY"
    let out = PhoneHealth.outages([broken, fine], history: { _ in [rec("1", "READY", 4), rec("2", "ERROR", 1)] }, now: now)
    check(out.map(\.name) == ["shop"], "outages: only the project whose newest deploy failed")
    check(PhoneHealth.average([fine], history: { _ in nil }, now: now) == nil, "average: nothing cached, nothing said")
    check(PhoneHealth.average([fine], history: { _ in [rec("1", "READY", 1)] }, now: now)?.score == 100, "average: one clean project")
}

// MARK: Widget refresh

do {
    let now = Date(timeIntervalSince1970: 1_800_000_000)
    func ago(_ s: TimeInterval) -> Date { now.addingTimeInterval(-s) }
    check(WidgetRefresh.interval(snapshotAt: ago(60), building: 0, now: now) == 30 * 60, "refresh: nothing moves, every 30 minutes")
    check(WidgetRefresh.interval(snapshotAt: ago(60), building: 2, now: now) == 5 * 60, "refresh: a build runs, every 5 minutes")
    check(WidgetRefresh.interval(snapshotAt: ago(Words.staleAfter + 1), building: 2, now: now) == 60 * 60, "refresh: an out-of-date snapshot waits longer, even with a build in it")
    check(WidgetRefresh.interval(snapshotAt: ago(Words.staleAfter), building: 1, now: now) == 5 * 60, "refresh: exactly three hours old is not yet out of date")
    check(WidgetRefresh.interval(snapshotAt: nil, building: 0, now: now) == 30 * 60, "refresh: no snapshot, every 30 minutes")
    check(WidgetRefresh.nextReload(snapshotAt: ago(60), building: 1, now: now) == now.addingTimeInterval(300), "refresh: the next reload is now plus the interval")
    check(WidgetRefresh.staleEntryDate(snapshotAt: ago(3600), now: now) == ago(3600).addingTimeInterval(Words.staleAfter), "refresh: the out-of-date entry sits three hours after the snapshot")
    check(WidgetRefresh.staleEntryDate(snapshotAt: ago(Words.staleAfter), now: now) == nil && WidgetRefresh.staleEntryDate(snapshotAt: nil, now: now) == nil,
          "refresh: no out-of-date entry when it is already past or there is no snapshot")
}

// Error texts (ideas E81)
check(APIError(status: 403, message: "no scope").errorDescription?.contains("403") == true && APIError(status: 403, message: "no scope").errorDescription?.contains("no scope") == true, "error text: 403 names the status and the message")
check(APIError(status: 404, message: "gone").errorDescription?.contains("404") == true, "error text: 404")
check(APIError(status: 500, message: "").errorDescription?.contains("500") == true, "error text: 5xx")
check(APIError(status: 429, message: "").errorDescription?.isEmpty == false, "error text: 429 without a message still says something")
check(APIError(status: 403, message: "Try again after 14:05", rateLimited: true).errorDescription == "Try again after 14:05", "error text: a rate limit with its time shows the time")
check(!APIError(status: 403, message: "", rateLimited: true).isAuth && APIError(status: 403, message: "").isAuth && APIError(status: 401, message: "").isAuth, "error text: only a 403 without a limit is a key problem")
check(explain(URLError(.notConnectedToInternet)).contains("internet"), "explain: offline")
check(explain(URLError(.timedOut)).contains("No answer"), "explain: timeout")
check(explain(URLError(.cannotFindHost)).contains("cannot be reached"), "explain: host not found")
check(explain(URLError(.secureConnectionFailed)).contains("secure connection"), "explain: TLS")
check(explain(URLError(.cancelled)) == "Canceled.", "explain: canceled")
check(explain(NSError(domain: NSCocoaErrorDomain, code: 3840)).contains("not JSON"), "explain: an HTML answer instead of JSON")

// The rule for states (ideas E84)
check(!DeployRule.failed(latest: "canceled", building: false), "rule: canceled is neutral")
check(DeployRule.failed(latest: "build_failed", building: false) && DeployRule.failed(latest: "update_failed", building: false), "rule: Render failures count")
check(!DeployRule.building(live: "deactivated", latest: "deactivated"), "rule: a replaced Render deploy is not building")
check(DeployRule.building(live: nil, latest: "build_in_progress"), "rule: Render build_in_progress is building")

// The snapshot file is read across versions (ideas E86)
func fixture(_ name: String) -> URL { URL(fileURLWithPath: #filePath).deletingLastPathComponent().appendingPathComponent("fixtures/" + name) }
let oldSnap = DeploySnapshot.read(fixture("snapshot-v1.json"))
check(oldSnap?.waitingPRs == 2 && oldSnap?.projects.count == 2 && oldSnap?.projects.first?.id == "Vercel/atlas" && oldSnap?.saving?.month == 60, "snapshot: a file of the first app still decodes")
check(oldSnap?.byPlatform == nil && oldSnap?.language == nil && oldSnap?.connected == nil, "snapshot: fields that came later are nil")
let futureSnap = DeploySnapshot.read(fixture("snapshot-future.json"))
check(futureSnap?.demo == true && futureSnap?.failed == 1 && futureSnap?.projects.first?.key == "Vercel/prj_1" && futureSnap?.language == "de", "snapshot: unknown fields are ignored, known ones kept")

// The demo data stands on its own (ideas E87)
let demoProjects = DemoData.projects()
check(!demoProjects.isEmpty && Set(demoProjects.map(\.key)).count == demoProjects.count, "demo: projects exist and their keys are unique")
check(demoProjects.contains { $0.group == .waiting } && demoProjects.contains { $0.group == .attention }, "demo: waiting and failing projects are shown")

print(failures == 0 ? "All checks passed." : "\(failures) check(s) failed.")
exit(failures == 0 ? 0 : 1)
