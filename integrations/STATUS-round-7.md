# Round 7: Integrationen und iOS, Stand

Branch `feat/integrations-round-7`, ab origin/main (80db425). Welle 1 und Welle 2 (siehe `git log`).
Tests am Ende von Welle 2: `integrations/tests/run.sh` grün (1 Skip: Plugin-Hook-Test, weil die App hier installiert ist),
`npm test` in vscode 68/68 und raycast 9/9 (eslint und prettier sauber), `ios/test.sh` und `ios/Tests/run.sh` grün,
`ios/build.sh` (Simulator, unsigniert) baut, actionlint auf Workflows und Beispielen ohne Befund.

## Umgesetzt (Nummern aus dem Report)

### Welle 1
- Sicherheit: 1, 2 (Maskierung linear, Zeilenlimit; MCP, VS Code, Raycast, iOS), 4, 5, 6, 7, 10, 129, 18, 26, 27, 28, 29, 31, 42, 141, 142, 143.
- Bugs/CI/Doku: 9, 49, 51, 76, 77, 16, 19, 20, 21, 25, 44, 45, 46, 66, 67, 68, 69, 70.

### Welle 2
- Tests: 3 und 130 (150 000-Zeichen-Zeile durch den MCP-Server, die gemeinsame Fixture `mask-in.txt` läuft jetzt auch durch den MCP-Server; VS Code und iOS hatten sie schon), 124 teilweise (Maskierer-Tests in Swift).
- Notify: 33 (Warteliste aus `deploys changed`), 34 (fehlgeschlagener Versuch zählt nicht als live), 35 (`--quiet-when-empty`), 36 (ntfy-Priorität high bei Fehlschlag), 37 (`DEPLOYS_LANG=de`).
- Digest: 39 (Zeitzone des Titels auch in `approve-deploy`, `DEPLOYS_TZ` im Digest-Beispiel durchgereicht).
- Action: 42 (schon Welle 1), 52 teilweise (`when-green`-Eingabe), 51 (Kindprozesse am Fristende).
- CI: 58 (Sparkle-Cache, Download wird weiter per SHA-256 geprüft), 60 (npm audit für VS Code und Raycast), 61 (`.node-version`), 62 (Xcode-Fallback), Hadolint-Schritt (56 teilweise).
- MCP: 11 teilweise (`deploys_providers`), 13 (Prompts `fix-failed-build`, `rollback-check`).
- VS Code: 83 (Alter rundet ab), 85 (Remote `upstream` zählt nicht), 87 (`--sha` des bestätigten Heads), 88 (Vorschau nach `caps.preview`), Tests dazu (94 teilweise).
- Raycast und Alfred: 79 (Deep-Link mit Plattform), 91 und 156 (Menüleisten-Titel mit „n ✗“ und „!“).
- Statusseite: 71 und 72 als Opt-in `strict: true` (impliziert `hideMessages`, kein Inline-Skript, CSP als Meta-Tag, noindex). Der Standard bleibt unverändert.
- iPhone: 99 (verwaiste Live Activities beim Start beenden), 110 (Spotlight ohne Lücke), 111 (Schalter „Projekte nicht in Spotlight zeigen“), 113 (Repo ohne `/` stürzt nicht mehr), 114 (Team-ID wird eng kodiert), 119 (Schalter „nur Face ID/Touch ID“), 120 (Orange-Text mit Kontrast).

## Offen oder an andere Forks

- Maskierer in `app/LogTools.swift` und `deploys` (`af_mask`): dieselben Änderungen wie 1, 2, 10, 129 nötig. Die Fixture `ios/Tests/fixtures/mask-out.txt` hängt an `af_mask`.
- Widget-/Snapshot-Funde (101–107, 116, 121, 134) liegen in `widgets/` und `shared/`.
- Brauchen Netz oder geprüfte Action-SHAs: 54, 55 (Docker-Digest für Node 24, Keyring-Fingerabdruck), 43 (Action auf Release-Tag pinnen, Tag mit `repo`-Eingabe fehlt noch), 59 (CodeQL, zizmor, dependency-review: Action-SHAs müssen geprüft werden), 64 (paths-filter), 63, 65 (iOS-Archiv braucht Signierung; `-warnings-as-errors` scheitert an bestehenden Warnungen).
- Bewusst nicht umgesetzt, mit Grund:
  - 15 (Streamable HTTP mit OAuth): kein sauberer, testbarer Umfang ohne Netz und Auth-Entwurf.
  - 98, 100, 131 (Live-Activity-Push, Relay): braucht APNs-Schlüssel und einen Server.
  - 104, 108, 109 (AppIntents, Widget-Konfiguration): nur mit Xcode-UI-Tests prüfbar; Widgets liegen in `widgets/`.
  - 112 (`timeSensitive`): braucht die Entitlement-Änderung der App.
  - 117 (Vercel und Render parallel laden): berührt die Fehlerbehandlung der ganzen Ladeschleife, ohne iOS-Tests zu riskant.
  - 3 ist erledigt (siehe oben), 8, 11–14, 17, 22, 23, 30, 32, 38, 40, 41, 47, 48, 50, 53, 57, 65, 78–82, 84, 86, 89, 90, 92, 93, 118, 122, 123, 126, 140, 144–155: nicht erreicht; sie sind klein, aber einzeln.
