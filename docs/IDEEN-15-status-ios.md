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
| 45 | ✅ | `Contrast` + `errorText`/`successText`/`activeText`, Test 4,5:1 |
| 46 | ✅ | Ersparnis im `spoken(w)` des Widgets (kein Test: die Funktion liegt in der Widget-Datei) |
| 48 | ✅ | Health-Karte nennt "gut / beobachten / schlecht" |
| 50 | ✅ | Abbrechen im Scanner mindestens 44 pt |
| 19 | ✅ | `HistoryCache` hält den Cache im Speicher (ein Decode), Test zählt |
| 20 | ✅ | `HistoryCache.save` schreibt UserDefaults auf einer Hintergrund-Queue (Datei im Application Support bewusst nicht: UserDefaults bleibt Quelle der Wahrheit) |
| 88 | ✅ | Test `decodeCount` |
| 66 | ✅ | `OpenProjectIntent` und `PrepareDeployIntent` mit Siri-Phrasen (en/de) |
| 67 | ✅ | "Nichts gelesen" wirft einen Fehler statt -1 |
| 89 | ✅ | `scripts/check-shortcuts.py`, läuft in `tests/ios-rule-tests.sh` |
