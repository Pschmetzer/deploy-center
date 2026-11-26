// App tests, round 15: deep links, status pages. Called from tests/app/main.swift.

import AppKit

@MainActor func suite_round15_features() {
    func act(_ s: String) -> String { DeepLink.action(URL(string: s)!).map { "\($0.kind) \($0.project)" } ?? "none" }
    expect("deep link: select", act("deploycenter://select?project=shop"), "select shop")
    expect("deep link: log with a platform", act("deploycenter://log?project=render:shop"), "log render:shop")
    expect("deep link: nothing that starts a build", act("deploycenter://deploy?project=shop"), "none")
    expect("deep link: no project", act("deploycenter://log"), "none")
    expect("deep link: other scheme", act("https://log?project=shop"), "none")
    expect("deep link: empty project", act("deploycenter://log?project=%20"), "none")

    let two = ProviderInfo.watchedGitHosts(repos: ["acme/shop", nil]).map(\.label)
    expect("status: GitHub only without GitLab repos", two, ["GitHub"])
    expect("status: GitLab with a gitlab.com repo", ProviderInfo.watchedGitHosts(repos: ["gitlab.com/team/shop"]).map(\.label), ["GitHub", "GitLab"])
}
