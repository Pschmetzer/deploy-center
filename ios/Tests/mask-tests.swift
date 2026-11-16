// Tests for ios/App/LogMask.swift: the same masking as af_mask in the deploys CLI.
// Run: ios/Tests/run.sh. fixtures/mask-out.txt is af_mask's own output for fixtures/mask-in.txt.

import Foundation

var fails = 0
func expect(_ name: String, _ got: Any, _ want: Any) {
    if "\(got)" == "\(want)" { print("ok   \(name)") } else { print("FAIL \(name): expected [\(want)], got [\(got)]"); fails += 1 }
}
let dir = URL(fileURLWithPath: CommandLine.arguments[1])
func fixture(_ name: String) -> String { (try? String(contentsOf: dir.appendingPathComponent(name), encoding: .utf8)) ?? "" }
func json(_ name: String) -> Any? { try? JSONSerialization.jsonObject(with: Data(fixture(name).utf8)) }
func trimmed(_ s: String) -> String { s.hasSuffix("\n") ? String(s.dropLast()) : s }

// Every pattern compiles; without that nothing is shown at all.
expect("mask: all patterns compile", LogMask.works, true)

// Line for line what af_mask makes of the same text.
let input = LogMask.lines(trimmed(fixture("mask-in.txt")))
let want = LogMask.lines(trimmed(fixture("mask-out.txt")))
let got = LogMask.mask(input) ?? []
expect("mask: same number of lines as af_mask", got.count, want.count)
for (i, (g, w)) in zip(got, want).enumerated() where g != w { expect("mask: line \(i + 1) as af_mask", g, w) }
expect("mask: no secret of any listed format survives",
       got.filter { $0.replacingOccurrences(of: "SECRET_KEY=", with: "S_K=").contains("SECRET") }.count, 0)
expect("mask: the header name and scheme stay readable", got.contains("Authorization: Bearer [masked]"), true)
expect("mask: a private key block becomes one line", got.filter { $0.contains("masked private key") }.count, 3)
let plain = "npm ERR! ./src/author.ts:12 Type error: keyboard: 3 tokens: 12 of 40"
expect("mask: an ordinary build line is left as it is", LogMask.mask(plain) ?? "", plain)
expect("mask: an unfinished key block hides the rest", LogMask.mask(["ok", "-----BEGIN PRIVATE KEY-----", "abc", "def"]) ?? [], ["ok", "[masked private key]"])

// The excerpt is cut from masked lines: a key block cut in half cannot show its body.
let long = (1...100).map { "line \($0)" } + ["-----BEGIN PRIVATE KEY-----", "bodySECRET", "-----END PRIVATE KEY-----", "Error: boom"] + (1...80).map { "after \($0)" }
let ex = LogMask.excerpt(LogMask.mask(long) ?? [], before: 1, after: 2)
expect("excerpt: around the first error", ex.lines, ["[masked private key]", "Error: boom", "after 1", "after 2"])
expect("excerpt: the error line is marked", ex.errorAt ?? -1, 1)
let quiet = LogMask.excerpt((1...100).map { "step \($0)" }, tail: 3)
expect("excerpt: no error, the last lines", quiet.lines, ["step 98", "step 99", "step 100"])
expect("excerpt: no error, nothing marked", quiet.errorAt == nil, true)
expect("excerpt: '0 errors' is not an error", LogMask.excerpt(["Compiled, 0 errors", "done"]).errorAt == nil, true)

// Round 7: platform tokens, webhooks, the clone URL of git, and a huge line.
let extra = LogMask.mask(["git@github.com:me/app.git denied; mail me@example.com; dop_v1_" + String(repeating: "a", count: 20) + " postgres://u:p@ss@host/db https://hooks.slack.com/services/T1/B2/xyz"])?.first ?? ""
expect("mask: git@host stays, so the clone error reads", extra.contains("git@github.com:me/app.git"), true)
expect("mask: an email goes", extra.contains("me@example.com"), false)
expect("mask: a DigitalOcean token goes", extra.contains("dop_v1_"), false)
expect("mask: a password with an @ goes whole", extra.contains("p@ss"), false)
expect("mask: a webhook URL goes", extra.contains("hooks.slack.com"), false)
let huge = LogMask.mask([String(repeating: "a.", count: 40000)])?.first ?? ""
expect("mask: a huge line is cut and says so", huge.contains("not scanned") && huge.count < 5000, true)

// Provider formats.
let v = LogMask.vercelLines(json("vercel-events.json"))
expect("vercel: oldest first, blank dropped", v.count, 3)
expect("vercel: colours removed", v.last ?? "", #"Error: Command "npm run build" exited with 1"#)
expect("vercel: masked after reading", LogMask.mask(v)?[1] ?? "", "Running build with VERCEL_TOKEN=[masked]")
let r = LogMask.renderLines(json("render-logs.json"))
expect("render: reversed to oldest first", r.first ?? "", "==> Running build command 'npm run build'")
expect("render: colours removed", r[1], "npm ERR! missing script: build")
expect("render: the first error line", LogMask.excerpt(r).errorAt ?? -1, 1)
expect("render: not JSON is no lines", LogMask.renderLines("nope").count, 0)

print(fails == 0 ? "all mask tests passed" : "\(fails) failed")
exit(fails == 0 ? 0 : 1)
