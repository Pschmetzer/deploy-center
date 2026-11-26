// App tests, round 15 (security): safety switches survive "Reset to defaults", the owner check guards loosening.
// Called from tests/app/main.swift.

import AppKit

@MainActor func suite_round15_security() {
    let reset = Set(SettingsTab.allCases.flatMap(\.defaultsKeys))
    for k in SettingsTab.protectedKeys { expect("reset keeps \(k)", reset.contains(k), false) }
    expect("reset: owner check key is protected", SettingsTab.protectedKeys.contains(OwnerCheck.key), true)

    typealias W = DeployWindowConfig
    let fri = W.Rule(days: ["fri"], from: "15:00"), sat = W.Rule(days: ["sat"])
    expect("window: adding a block does not loosen", W.loosens(from: W(deny: [fri]), to: W(deny: [fri, sat])), false)
    expect("window: removing a block loosens", W.loosens(from: W(deny: [fri, sat]), to: W(deny: [fri])), true)
    expect("window: emptying loosens", W.loosens(from: W(deny: [fri]), to: W()), true)
    expect("window: no change does not loosen", W.loosens(from: W(deny: [fri]), to: W(deny: [fri])), false)

    typealias R = RulesConfig
    let notify = R.Rule(name: "n", then: .notify), ship = R.Rule(name: "s", then: .deploy)
    var off = ship; off.enabled = false
    expect("rules: a new deploy rule asks", R.addsDeploy(from: R(rules: [notify]), to: R(rules: [notify, ship])), true)
    expect("rules: a disabled deploy rule does not", R.addsDeploy(from: R(), to: R(rules: [off])), false)
    expect("rules: an unchanged deploy rule does not", R.addsDeploy(from: R(rules: [ship]), to: R(rules: [ship])), false)
    expect("rules: a notify rule does not", R.addsDeploy(from: R(), to: R(rules: [notify])), false)
}
