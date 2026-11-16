# Round 7: Integrationen und iOS, Stand

Branch `feat/integrations-round-7`, drei Commits auf origin/main (80db425).
Tests: `integrations/tests/run.sh` grün (1 Skip: Plugin-Hook-Test, weil die App hier installiert ist),
`npm test` in vscode 63/63, `ios/test.sh` und `ios/Tests/run.sh` grün.

## Umgesetzt (Nummern aus dem Report)

- Sicherheit: 1, 2 (Maskierung linear, Zeilenlimit; MCP, VS Code, Raycast, iOS), 4 (JSON-Antworten
  maskiert und von Steuerzeichen befreit, nicht gerahmt), 5, 6 (Rückfragen: eine saubere Zeile,
  Rollback nennt die neuesten Deploys), 7 (Umgebung als Allowlist), 10, 129 (Schlüsselmuster,
  git@host bleibt, Passwort mit @), 26, 27, 28, 29, 31 (Slack-Escape, Link-Entschärfung,
  ntfy-Header, Retry ohne --retry-all-errors, HMAC-Signatur), 42 (Vercel-Install ohne Token),
  18 (ship-reviewer nur mit seinen Befehlen), 143, 141, 142 (Telegram-Bot).
- Bugs: 9 (Preview nur wo `caps.preview`), 49 (gleichnamige Projekte in `states`), 51
  (Kindprozesse bei Fristende), 76, 77 (Badge-Kontrast, Groß/Klein-Kollision), 141, 142.
- CI/Doku: 16, 19, 20, 21, 25, 44 (Environment-Gate), 45, 46, 66, 67 (CODEOWNERS), 68, 69, 70.
- Tests: Laufzeit- und Muster-Tests für Maskierer (VS Code, iOS), Env-Allowlist (MCP).

## Offen oder an andere Forks

- Maskierer in `app/LogTools.swift` und `deploys` (`af_mask`): gleiche Änderung nötig (Fund 1, 2, 10, 129),
  Fixture `ios/Tests/fixtures/mask-out.txt` hängt an `af_mask`.
- Widget-/Snapshot-Funde (101–107, 134) liegen in `widgets/` und `shared/`.
- Nicht umgesetzt, weil Netz oder Plattformwissen nötig: 54, 55, 56 (Docker-Digest für Node 24, Keyring-Fingerabdruck),
  43 (Aktion auf Release-Tag pinnen, Tag fehlt noch), 62, 64.
- Nicht umgesetzt, weil Standardverhalten sich ändern würde: 71 (hideMessages standardmäßig an), 72 (CSP ohne Inline-Skript).
- Nicht umgesetzt (Umfang): 3, 8, 11–15, 17, 22, 23, 30–41, 47, 48, 50, 52, 53, 57–65, 73–75, 78–100, 108–128,
  130–140, 144–156. Größere Features (Streamable HTTP, Live-Activity-Push, AppIntents, iPhone-Parität)
  brauchen eigene Entwürfe.
