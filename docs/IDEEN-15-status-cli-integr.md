# IDEEN-15: Stand Block B (CLI/Provider) und Block C (Integrationen)

Nummern wie in [IDEEN-15.md](IDEEN-15.md): Block B "A. Bugs" bis "G. Funktionen", Block C "A. MCP" bis "H. Übergreifend".
Jeder Punkt wurde vor dem Bauen im Code geprüft; was nicht mehr zutraf, steht unter "Schon erledigt oder nicht zutreffend".
Alle PRs gegen `main`, je Thema ein Branch, jeder mit Tests, `CHANGELOG.md` (`## Unreleased`) und, wo nötig, Doku, man-Seite und Completion.

## Umgesetzt

### Block B: CLI und Provider

| Punkte | Was | PR |
| --- | --- | --- |
| B1, B2, B99 | `LC_ALL=C` für Zertifikats- und `Retry-After`-Daten (scheiterten unter `de_DE`) | [#397](https://github.com/Pschmetzer/deploy-center/pull/397) |
| B3, B3a, B100 | Team-Fenster über Mitternacht (Vortag), eine Zeitzone je Fenster; Code nach `lib/team.sh` | #397 |
| B4, B101 | `ghpages`: nur `workflow_dispatch`-Läufe zählen als der eigene Lauf | #397 |
| B6, B42 | `team list` ohne Repos Exit 0; `.` und `..` in Repo-Namen abgelehnt | #397 |
| B9, B11 | `creds`: "not set up" (Exit 0) statt "NOT accepted"; `<unbekannt> --help` Exit 2 | #397 |
| B35 | Journal-Details werden beim Schreiben maskiert | [#410](https://github.com/Pschmetzer/deploy-center/pull/410) |
| B36 bis B40, B102 | `af_mask`: Google OAuth, Shopify, PyPI, Docker, Twilio, Mailgun, 1Password, `curl -u`, Passwort mit Leerzeichen, maskierte Anführungszeichen, `/` im DB-Passwort | #410 |
| B34 | `hook_private_host`: jede Schreibweise einer privaten IPv6-Adresse (`0:0:0:0:0:ffff:7f00:1`, `::127.0.0.1`, ...) | #410 |
| B41 | API-Basis von Heroku, Netlify, Cloudflare nur `https://` | #410 |
| B5, B8, B13, B14, B15, B16, B24, B26, B27, B29, B33 | `perf clean` KILL an die Gruppe; Export 90 Tage sagt es; riesiges `--days` ohne rohe bash-Meldung; `mktemp`-Meldung; Tippfehler-Hinweis; `status --watch` ohne `clear` in Pipes; Hook-Install mit Rollback; DigitalOcean/Netlify Seiten einmal verbunden und "keine Liste" als Fehler; `.sql` nicht mehr pauschal rot; `budget set 0` abgelehnt | [#422](https://github.com/Pschmetzer/deploy-center/pull/422) |
| B20, B18, B43, B75 | `<NAME>_CMD` nennt die letzte stderr-Zeile (maskiert); GitLab-curl nennt den Grund bei HTTP 000; Branch im Hook URL-kodiert; Completion-Flags für `ai`, `autofix`, `ci`, `changed`, `notes`, `diff`, `costs`, `scan`, `check`, `journal search`, `nightly` | [#423](https://github.com/Pschmetzer/deploy-center/pull/423) |
| B94, B95, B148 | 30 weitere `DEPLOYS_*` in `docs/CLI.md` und man-Seite; `deploys help <befehl>` | [#424](https://github.com/Pschmetzer/deploy-center/pull/424) |
| B127, B28, B97, B98 | `deploys lock` / `unlock` (neues `lib/locks.sh`); Gruppenmitglied `*` nicht mehr geglobbt; Tests für `selfupdate_newer`, `http_notfound_hint` und die Reihenfolge in `perfdocker_act` | [#425](https://github.com/Pschmetzer/deploy-center/pull/425) |

### Block C: Integrationen

| Punkte | Was | PR |
| --- | --- | --- |
| C25 bis C34, C36, C39 | Claude-Code-Gate liest Wrapper, Optionswerte, Unterschalen, Schleifen und `$D deploy`; zweite Frage vor dem Abschalten einer Sicherung (`autodeploy allow`, `prepare run --yes`, `cancel`, `ignore`, `freeze clear`, `guard schedule off`, Schreiben auf `window.json` und Co.); neuer Edit/Write-Hook; Skill pinnt `--sha`; perf-gate (Ausnahme nur für `deploys perf gate|wait`, Wrapper, mehr schwere Befehle, `DEPLOYS_PERF_HEAVY_EXTRA`, `heavy.txt`); tabellengetriebene Tests | [#411](https://github.com/Pschmetzer/deploy-center/pull/411) |
| C51, C52, C53, C60, C61, C62 | Docker-Scheduler: nur lesend (`DEPLOYS_READONLY=1`, Flags und Unterbefehle geprüft), TERM sofort (143), Herzschlag aus eigenem Ticker, `DEPLOYS_PING_URL`, README-Tabelle | [#412](https://github.com/Pschmetzer/deploy-center/pull/412) |
| C1 bis C4, C13, C24, C40 bis C44, C50, C105 | MCP: `deploys_ci`/`deploys_sessions` nur für Repos der eigenen Projekte (`DEPLOYS_MCP_ALLOW_REPOS`), `ToolError`, `maxLength`/`enum` erzwungen, Teilfehler mit `warnings`; Action: Repo-Filter auch für Zählung, Risiko, `fail-on-risk`, `max-cost` und Plan, Tippfehler bei `deploy:` warnt, `pull_request_target`/`workflow_run`/`issue_comment` verweigert (`allow-untrusted-event`), PR-Kommentar nach Autor gefunden | [#421](https://github.com/Pschmetzer/deploy-center/pull/421) |
| C63, C65, C67, C68, C70, C71, C72, C74, C75, C77, C82 | Notify/Post: abgelehnter Post nennt die Antwort, `--link` nur https, unbekannte Zone abgelehnt, Temp-Datei bei Signalen entfernt, GNU-`stat` zuerst, `DEPLOYS_NOTIFY_ALLOW_HTTP_HOSTS`, ntfy `Click`; Statusseite: Linux-Journal, User-Agent, README | #423 |
| C15, C16, C18, C94 | MCP: Instruktionen nennen alle Untrusted-Werkzeuge (aus dem Code erzeugt), `offset` für die Journalsuche, Spalten nach Kopfzeile, Server-Titel | [#426](https://github.com/Pschmetzer/deploy-center/pull/426) |

## Schon erledigt oder nicht zutreffend

- B88 (Hook-Provider ohne `caps`): `hook_meta` hat ein `caps`-Objekt.
- B96 (`check-env-docs`): `scripts/check-cli-docs.py` prüft schon, dass jede `DEPLOYS_*`-Variable in einer Doku-Seite steht; die Lücken standen in `docs/CLI.md`, nicht in der Prüfung (B94, B95).
- B55 (`CLICOLOR_FORCE`): wird gelesen (`--color=always`).
- B22 (Schlüssel mit `"`): bewusst streng gelassen; `curl_cfg_quote` bleibt die zweite Sicherung.

## Nicht gebaut, mit Grund

- B80 bis B87, B91, B92 (Provider-Fähigkeiten, neue Anbieter): jede braucht die echte API zum Prüfen (die Punkte sagen "API prüfen"); ohne Konto und Netz wären es Vermutungen in Fixtures. Cloudflare Pages nennt in `cloudflare_cancel` ausdrücklich, dass es keinen dokumentierten Weg gibt.
- B44 bis B48, B17, B19, B21, B23, B25, B30 bis B32, B49 bis B74, B89, B103 bis B113, B114 bis B150 (außer B127, B148): Features und größere Umbauten, jeweils eigene Entwürfe; `deploys` steht nah an seiner Zeilengrenze (`scripts/check-size.sh`), neue Befehle gehören in `lib/`.
- C5 bis C12, C14, C17, C19 bis C23, C26 (Rest), C37, C38, C45 bis C49, C54 bis C59, C64, C66, C69, C73, C76 bis C81, C83 bis C104: nicht in dieser Runde; keine Abhängigkeit zu den umgesetzten Punkten.

## Zur CI

Die macOS-Jobs (`test`, `ios`) liefen bei den PRs dieser Runde nicht an: die Warteschlange der macOS-Runner war mit den PRs der anderen Sessions voll, und jeder neue Push bricht den wartenden Lauf ab. Gemergt wurde nach grünen Linux-Jobs (`linux-cli`, `integrations`, `lint`, `docs`, `docker`, `cli-install`, `vscode`, `raycast`, `changelog`, `public-commits`). `scripts/check-bash32.sh` (in `lint`) prüft die Bash-3.2-Kompatibilität.
