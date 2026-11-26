# Ideen 15, Block E (iPhone/iPad): Status

Nummern wie in `docs/IDEEN-15.md`, Abschnitt "E. iPhone/iPad-App". ✅ = gebaut und gemergt, ⏭ = bewusst nicht (mit Grund).

| Nr | Status | PR / Anmerkung |
| --- | --- | --- |
| 1 | ✅ | follow-Neustart behält Startzeit (`FollowedRuns.add`, `follow(since:)`) |
| 2 | ✅ | 502/504 beim POST suchen den gestarteten Deploy (`deployMayHaveStarted`) |
| 3 | ✅ | 403 stoppt, Rate-Limit wartet bis `retryAt` (`PollFailure`) |
| 5 | ✅ | Fremd abgebrochener Build ist neutral, nicht rot |
| 6 | ✅ | `DeployRule.neverDeployed`, Gruppe "Wartet", "noch nie deployt" |
| 17 | ✅ | `reload(inBackground:)`: Hintergrundlauf behält kurze Timeouts, auch wenn ein Vordergrund-Laden lief |
| 36 | ✅ | Live Activity: `.privacySensitive()`, neutraler Titel mit "Beim Öffnen entsperren" |
