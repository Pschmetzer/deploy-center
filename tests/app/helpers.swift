// Shared by the app test files: the counter, expect() and the item() builder.
import AppKit

var fails = 0
func expect(_ name: String, _ got: Any, _ want: Any) {
    if "\(got)" == "\(want)" { print("ok   \(name)") } else { print("FAIL \(name): expected [\(want)], got [\(got)]"); fails += 1 }
}
func item(_ p: Platform = .vercel, changed: Bool? = nil, last: String? = "a", head: String? = "b",
          commits: Int? = nil, prs: Int? = nil, partial: Bool = false, rewritten: Bool = false,
          repo: String? = "me/app", kind: String? = nil) -> Item {
    var i = Item(id: p == .render ? "srv-1" : "app", name: "app", detail: "", platform: p, deployable: true, auto: false, note: nil, link: nil)
    i.changed = changed; i.lastSha = last; i.headSha = head; i.pendingCommits = commits; i.pendingPRs = prs
    i.pendingPartial = partial; i.rewritten = rewritten; i.repo = repo; i.ref = "main"; i.kind = kind
    return i
}


// Runs an async call to its end from the synchronous test code.
final class Box<T>: @unchecked Sendable { var value: T?; init() {} }
func waitFor<T>(_ f: @escaping @Sendable () async -> T) -> T {
    let sem = DispatchSemaphore(value: 0), box = Box<T>()
    Task.detached { box.value = await f(); sem.signal() }
    sem.wait()
    return box.value!
}

// Shared by several topic files (they were one script before, with these at the top level).
func fire(_ json: String) -> AutofixReport { try! JSONDecoder().decode(AutofixReport.self, from: Data(json.utf8)) }
func failedItem(_ p: Platform = .vercel) -> Item { var i = item(p, changed: false, last: "aaaaaaa1", head: "aaaaaaa1"); i.lastState = p == .vercel ? "ERROR" : "build_failed"; return i }
typealias F = AutofixReport.Fire
let soon = Date(timeIntervalSince1970: 1 + 60), late = Date(timeIntervalSince1970: 1 + RowAutofix.stalledAfter + 1)
var green: Item = { var g = failedItem(); g.lastState = "READY"; return g }()
let offCosts = try! JSONDecoder().decode(Costs.self, from: Data("""
{"days":[{"day":"2026-11-01","total":10,"build":10},{"day":"2026-11-02","total":10,"build":10},{"day":"2026-11-03","total":4,"build":4},
         {"day":"2026-11-04","total":1,"build":1},{"day":"2026-11-05","total":3,"build":3},{"day":"2026-11-06","total":9,"build":9}],
 "projects":[],"offDay":"2026-11-03","buildsComplete":true}
""".utf8))
