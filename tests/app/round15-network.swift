// App tests, round 15: the environment handed to scripts, and which redirects the app follows.
// Called from tests/app/main.swift.

import AppKit

@MainActor func suite_round15_network() {
    let env = Tool.childEnvironment(["PATH": "/usr/bin", "HOME": "/h", "LANG": "en_US.UTF-8", "LC_ALL": "C", "DEPLOYS_CONFIG": "/c", "VERCEL_TOKEN": "t",
                                     "RENDER_API_KEY": "k", "GH_TOKEN": "g", "ANTHROPIC_API_KEY": "a", "GITHUB_TOKEN": "x", "AWS_SECRET_ACCESS_KEY": "s",
                                     "AWS_PROFILE": "p", "OPENAI_API_KEY": "o", "NPM_TOKEN": "n"])
    expect("env: kept", env.keys.sorted(), ["PATH", "HOME", "LANG", "LC_ALL", "DEPLOYS_CONFIG", "VERCEL_TOKEN", "RENDER_API_KEY", "GH_TOKEN", "AWS_PROFILE"].sorted())
    for k in ["ANTHROPIC_API_KEY", "GITHUB_TOKEN", "AWS_SECRET_ACCESS_KEY", "OPENAI_API_KEY", "NPM_TOKEN"] { expect("env: \(k) dropped", env[k] == nil, true) }

    func ok(_ s: String) -> Bool { PublicRedirect.allows(URL(string: s)) }
    expect("redirect: http refused", ok("http://example.com/"), false)
    expect("redirect: localhost refused", ok("https://localhost/x"), false)
    expect("redirect: metadata address refused", ok("https://169.254.169.254/latest"), false)
    expect("redirect: CGNAT refused", ok("https://100.64.0.1/"), false)
    expect("redirect: 0.0.0.0/8 refused", ok("https://0.1.2.3/"), false)
    expect("redirect: IPv6 literal refused", ok("https://[fd00::1]/"), false)
    expect("redirect: file refused", ok("file:///etc/passwd"), false)
    expect("redirect: nil refused", PublicRedirect.allows(nil), false)
}
