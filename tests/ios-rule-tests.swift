// The iPhone app's "waiting" rule (ios/App/Project.swift, PhoneProject.changed) against the shared
// cases in tests/fixtures/changed-rule/cases.json, which tests/ios-rule-tests.sh also runs through
// the script's CHANGED_RULE. Compiled for macOS with Project.swift and shared/, no simulator.

import Foundation

struct Case: Decodable {
    let name: String
    let deployable: Bool
    var paused: Bool?
    var building: Bool?
    var fetchError: String?
    var compareStatus: String?
    var liveSha: String?
    var headSha: String?
    var liveAt: Double?
    var headAt: Double?
    let want: Bool
    var known: String?
}

let path = CommandLine.arguments.dropFirst().first ?? "tests/fixtures/changed-rule/cases.json"
let cases = try! JSONDecoder().decode([Case].self, from: FileManager.default.contents(atPath: path)!)
var fails = 0, known = 0
for c in cases {
    var p = PhoneProject(provider: .vercel, id: "x", name: "x")
    p.deployable = c.deployable
    p.paused = c.paused ?? false
    p.liveState = c.building == true ? "building" : "ready"
    p.fetchError = c.fetchError
    p.compareStatus = c.compareStatus
    p.liveSha = c.liveSha
    p.headSha = c.headSha
    p.liveAt = c.liveAt.map { Date(timeIntervalSince1970: $0) }
    p.headAt = c.headAt.map { Date(timeIntervalSince1970: $0) }
    let got = p.changed
    if got == c.want { print("ok   \(c.name)") }
    else if let k = c.known, k.hasPrefix("ios:") { print("KNOWN \(c.name): iPhone says \(got), the script \(c.want) (\(k))"); known += 1 }
    else { print("FAIL \(c.name): expected [\(c.want)], got [\(got)]"); fails += 1 }
}
print("")
if fails == 0 { print("All iPhone rule tests passed (\(known) known difference(s)).") } else { print("\(fails) failed."); exit(1) }
