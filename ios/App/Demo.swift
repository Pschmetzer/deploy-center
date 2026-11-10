// Deploy Center for iPhone — Made-up projects for the demo mode (App Review, screenshots, trying it out).

import Foundation

enum DemoData {
    static func projects(now: Date = Date()) -> [PhoneProject] {
        func p(_ k: ProviderKind, _ name: String, repo: String, commits: Int, prs: Int, live: String?, latest: String?,
               age: Double, msg: String, liveMsg: String, domain: String) -> PhoneProject {
            var x = PhoneProject(provider: k, id: name, name: name)
            x.repo = repo; x.branch = "main"; x.deployable = true; x.domain = domain
            x.liveSha = "a1b2c3d" + name; x.headSha = commits > 0 ? "f9e8d7c" + name : x.liveSha
            x.liveAt = now.addingTimeInterval(-age - 3600); x.headAt = now.addingTimeInterval(-age)
            x.liveState = live; x.latestState = latest; x.headMsg = msg; x.liveMsg = liveMsg
            x.pendingCommits = commits; x.pendingPRs = prs; x.openPRs = prs + 1
            x.oldestPendingAt = commits > 0 ? now.addingTimeInterval(-age) : nil
            x.compareStatus = commits > 0 ? "ahead" : "identical"
            return x
        }
        return [
            p(.vercel, "Atlas-214", repo: "example/atlas", commits: 2, prs: 1, live: "READY", latest: "BUILDING", age: 95,
              msg: "Fix the checkout total", liveMsg: "Faster image loading", domain: "atlas.example.com"),
            p(.render, "Cedar-551", repo: "example/cedar", commits: 1, prs: 0, live: "build_failed", latest: "build_failed", age: 3600,
              msg: "Bump the worker image", liveMsg: "Retry failed jobs", domain: "cedar.example.com"),
            p(.vercel, "Harbor-307", repo: "example/harbor", commits: 5, prs: 3, live: "READY", latest: "READY", age: 86400 * 2,
              msg: "New pricing page", liveMsg: "Footer links", domain: "harbor.example.com"),
            p(.vercel, "Nova-820", repo: "example/nova", commits: 3, prs: 2, live: "READY", latest: "READY", age: 7200,
              msg: "Dark mode for the docs", liveMsg: "Search in the docs", domain: "docs.example.com"),
            p(.render, "Quartz-145", repo: "example/quartz", commits: 1, prs: 0, live: "live", latest: "live", age: 600,
              msg: "Log less on start", liveMsg: "Health check path", domain: "api.example.com"),
            p(.vercel, "Willow-662", repo: "example/willow", commits: 0, prs: 0, live: "READY", latest: "READY", age: 86400 * 5,
              msg: "Update the readme", liveMsg: "Update the readme", domain: "willow.example.com"),
        ]
    }
}
