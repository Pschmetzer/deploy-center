# Kommandozeile: `deploys` (Kurzfassung, Deutsch)

Eine kurze deutsche Übersicht der wichtigsten Befehle. Vollständig und maßgeblich ist die englische [CLI.md](CLI.md); `deploys --help` zeigt jeden Befehl, und `deploys <befehl> --help` die Zeile zu einem Befehl.

Die App ist ein Fenster über einem bash-Skript, `deploys`. Du kannst es auch allein benutzen. Es steckt in der App unter `Deploy Center.app/Contents/Resources/deploys`; wie du nur die CLI installierst, steht in [README-CLI.md](../README-CLI.md).

Ein Projekt heißt überall gleich: mit seinem Namen, oder als `<plattform>:<name>`, wenn zwei Plattformen eines dieses Namens haben (`render:api`). Namen, die einen API-Pfad ändern würden (`/ ? # & %`), werden abgelehnt, bevor etwas gefragt wird.

`deploy-changed` zeigt ohne `--yes` nur die Liste und startet nichts.

## Alltag

```bash
deploys doctor                          # was verbunden ist (JSON)
deploys secrets my-project              # hinzugefügte Zeilen, die wie ein Schlüssel oder Token aussehen; Exit 1, wenn es welche gibt (ein Tor)
deploys <vercel|netlify|cloudflare> previews <project>   # neueste Vorschau je Pull Request mit URL (JSON, nur lesend)
deploys certs [--days 14] [--json]      # TLS-Zertifikat der Adresse jedes Projekts (auch der Anbieter-Domain); Exit 1, wenn eines innerhalb von N Tagen abläuft. Ein nicht erreichbarer Host ist „unknown“, kein Fehler.
deploys creds [--max-age 90] [--json]   # je Plattform: woher der Schlüssel kommt (Umgebung, Schlüsselbund, Login), ob er geht, wie alt ein Schlüsselbund-Schlüssel ist. Nur lesend; zeigt nie einen Schlüssel.
deploys doctor --text                   # eine Zeile je Prüfung (ok oder das Problem), mit der Lösung
deploys doctor --fix [--json]           # was bei jedem Problem zu tun ist, als Befehle zum Selbsttippen; zeigt nur an, führt nichts aus und ändert nichts
deploys morning [--hours 24] [--json] [--no-notify] [--no-file] [--offline]   # über Nacht: was deployt wurde, gescheitert ist, gemergt wurde (deploys prs), an Autofix ging und noch wartet; schreibt ~/.config/deploys/morning/<Datum>.txt (die neuesten 30 bleiben) und schickt eine Mitteilung (auch an DEPLOYS_NOTIFY_CMD). Startet nichts
deploys morning schedule on [08:00] | off | status [--json]   # dasselbe jeden Morgen (launchd; aus, bis du es einschaltest)
deploys digest [--days 7] [--json] [--no-savings]   # die letzte Woche aus dem Journal: Deploys, Fehler, Rollbacks, aktivster Tag, Projekte und die Ersparnis aus `ledger` (eine Schätzung; --no-savings lässt sie weg, sie braucht das Netz)
deploys list --format tsv               # Plattform, Projekt, auto oder manuell, letzter Stand: Tabs, ohne Kopfzeile, für Skripte ohne jq
deploys idle [--days 90] [--json]       # Projekte ohne Deploy seit N Tagen: Kandidaten zum Pausieren (nur lesend)
deploys changed                         # was auf GitHub gemergt und nicht live ist: Commits und PRs je Projekt
deploys deploy-changed                  # das tägliche Deploy: zeigt die Liste; mit --yes startet es
deploys deploy-changed --when-green --yes  # nur Commits, deren CI bestanden hat (wartet auf laufende Checks)
deploys deploy-json my-project --no-cache --yes   # Build ohne den Cache des Anbieters (Render, Netlify, DigitalOcean, Coolify; andere Anbieter lehnen es ab)
deploys deploy mein-projekt             # ein Projekt nach Produktion, auf welcher Plattform auch immer
deploys deploy-changed --skip-failed      # lässt ein Projekt aus, dessen neuester Build am Commit scheiterte, der jetzt rausginge; ein neuerer Commit (ein Fix) geht trotzdem
deploys deploy-changed --between 03:00-05:00 --yes  # außerhalb dieser Ortszeiten startet --yes nichts und endet mit Exit 0
deploys plan [--when-green] [--skip-failed] [--since 1d]  # dieselbe Liste mit Schätzung je Build und Summe (startet nichts); --since: nur was sich in dieser Zeit geändert hat
deploys status                          # was gerade baut und was zuletzt fehlschlug
deploys watch mein-projekt [--timeout 30m]  # dem neuesten Deploy folgen, bis es live oder fehlgeschlagen ist
deploys logs mein-projekt               # das Ende des neuesten Build-Logs, Schlüssel und Tokens immer maskiert
deploys logs mein-projekt 200 --id <deploy>   # das Log dieses Deploys statt des neuesten, 200 Zeilen
deploys open mein-projekt [--dashboard] [--print]   # die Seite oder ihre Seite bei der Plattform; --print schreibt nur die Adresse
deploys ignore mein-projekt             # aus changed / deploy-changed herauslassen
deploys list                            # jedes Projekt jeder eingeschalteten Plattform
deploys list --platform render --manual   # eingrenzen: eine Plattform; --auto (ein Push baut von selbst) oder --manual
```

`freeze` schreibt nur die `deny`-Liste von `window.json` (`tz` und andere Schlüssel bleiben) und startet nichts; im Beobachter-Modus ist es erlaubt, weil es nur Zeiten sperrt. Eine `window.json`, die nicht lesbar ist, wird nie überschrieben.
`--json` gibt es bei jedem Befehl, der etwas auflistet: `list`, `idle`, `certs`, `creds`, `plan`, `history`, `providers`, `window`, `freeze`, `digest`, `doctor --fix`, `ignore --list`, `team list`, `scan list` und `autofix list`.

## Sicher deployen ([SAFE-DEPLOY.md](SAFE-DEPLOY.md), englisch)

```bash
deploys verify mein-projekt [--path /health] [--no-rollback]   # die Seite fragen; bei 5xx zurückrollen
deploys risk mein-projekt               # grün/gelb/rot für das, was wartet
deploys ci owner/repo [<ref>] [--wait 30m]   # das CI-Urteil eines Commits
deploys window                          # ist das Deploy-Fenster (window.json) jetzt offen?
deploys freeze                          # die gesperrten Zeiten aus window.json, nummeriert, und ob Deploys jetzt gesperrt sind (auch --json)
deploys freeze add fri 15:00            # freitags ab 15 Uhr sperren (<Tage>: fri, fri,sat, mon-fri, weekend, weekdays, daily; <bis> ist 24:00, wenn es fehlt)
deploys freeze add sat,sun 0 --reason "Wochenende"   # ein Grund steht in der Absage
deploys freeze remove 2 | clear         # Regel 2 entfernen (die Nummern zeigt `freeze`), oder alle
deploys deploy mein-projekt --force "hotfix"   # im geschlossenen Fenster; der Grund kommt ins Journal
```

## Plattformen

Vercel und Render sind standardmäßig an; Netlify, Cloudflare Pages, AWS Amplify, DigitalOcean App Platform, Coolify, Fly.io, Railway, Heroku, Firebase Hosting, GitHub Pages und Deploy-Hooks sind aus, bis `deploys providers enable <p>` sie einschaltet ([PROVIDERS.md](PROVIDERS.md), und je eine Seite in [providers/](providers/), englisch).

```bash
deploys providers [--json]              # jede Plattform: an oder aus, eingerichtet oder nicht
deploys providers enable netlify        # an; nennt den nächsten Schritt, wenn sie noch nicht eingerichtet ist
deploys <p> list                        # ihre Projekte
deploys <p> autodeploy-off <name>|--all # Pushes bauen nicht mehr
deploys <p> autodeploy-on <name>        # wieder an
deploys <p> deploy <name> [--preview]   # ein Deploy starten
deploys <p> rollback <name>
deploys <p> set-key                     # Schlüssel im Schlüsselbund speichern (liest stdin)
```

## Team ([TEAM.md](TEAM.md), englisch)

```bash
deploys config [--json] [--refresh]     # die gültige Konfiguration und woher jeder Wert kommt
deploys team add|remove owner/repo | list | refresh | journal
deploys readonly [on|off]               # Beobachter-Modus: jeder ändernde Befehl wird abgelehnt
```

## Mehr

```bash
deploys explain mein-projekt            # warum ein Projekt (nicht) als geändert zählt
deploys diff mein-projekt               # Commits und Dateien zwischen live und Branch
deploys notes mein-projekt              # dasselbe als Release-Notes (Markdown)
deploys history mein-projekt [n]        # die letzten n Deploys
deploys costs [tage]                    # Vercel-Kosten pro Tag (nur Vercel)
deploys simulate [--days 30]            # Schätzung: Auto-Deploy einen Monat vs. einmal am Tag (siehe ERSPARNIS.md)
deploys ledger                          # Schätzung: gesparte Builds und Geld seit Auto-Deploy aus ist
deploys budget set 50 [--strict]        # deploy-changed --yes stoppt, bevor es 50 $ im Monat überschreitet
deploys triggers                        # Builds, die niemand von hier gestartet hat, deployende Workflows, Blueprints
deploys where                           # Konfigurationsordner, Version, Schlüsselquelle, Logins
deploys autofix [--dry-run]             # siehe AUTOFIX.md
deploys guard [--dry-run] | status | schedule on|off   # Auto-Deploy wieder aus, wo es zurückkam
deploys schedule daily 09:00 [--when-green] [--by-rules]   # deploy-changed --yes einmal am Tag (launchd oder Cron-Zeile)
deploys schedule daily 03:00 --when-green --skip-failed --between 03:00-05:00   # nachts gesammelt: was am selben Commit gescheitert ist, wartet; ein Lauf, den launchd zu spät startet (Mac schlief), startet nichts
deploys hooks install [<repo>]          # vor jedem Push: welche Builds er starten würde (ein Git-Hook, nicht hooks.d)
deploys logs mein-projekt --follow      # Build-Log laufend lesen (DEPLOYS_FOLLOW_EVERY Sekunden)
deploys rollback mein-projekt | cancel mein-projekt   # zurück auf den Deploy davor, oder einen laufenden Build stoppen
deploys metrics --out datei.prom        # wartende Commits, Alter, Fehler als Prometheus-Text (Grafana)
eval "$(deploys completion zsh)"        # Tab-Vervollständigung (auch bash; fish: deploys completion fish | source)
```

## Hooks rund um einen Start (`hooks.d`)

Ausführbare Dateien `pre-deploy*` und `post-deploy*` in `~/.config/deploys/hooks.d` laufen vor und nach jedem Start aus dem Terminal (`DEPLOYS_PLATFORM`, `DEPLOYS_PROJECT`, `DEPLOYS_SHA`, danach `DEPLOYS_STATE`). Ein `pre-deploy`-Skript mit Exit-Code ungleich null stoppt diesen Start. Läuft es länger als `DEPLOYS_HOOK_TIMEOUT` Sekunden (Standard 300), wird es beendet. Dateien, die Gruppe oder andere beschreiben dürfen oder die einem anderen Konto gehören, laufen nie. Beispiele und Regeln: [CLI.md](CLI.md#hooks-scripts-around-a-start-hooksd). Nicht zu verwechseln mit `deploys hooks install` (ein Git-Hook im Repo).

Schlüssel aus einem Passwortmanager: `RENDER_API_KEY_CMD='op read op://tresor/render/key'` (jede `<NAME>_CMD` wird nach der Variablen und vor dem Schlüsselbund gefragt). Eigene Mitteilung statt macOS: `DEPLOYS_NOTIFY_CMD` (Text in `DEPLOYS_MESSAGE`).

## JSON und Exit-Codes

`--json` liefert die maschinenlesbare Antwort der meisten Befehle (`changed`, `deploy-changed`, `status`, `list`, `providers`, `config`, `plan`, `verify` und weitere, die volle Liste steht in [CLI.md](CLI.md#json)). `watch`, `logs`, `explain` und `diff` sind nur Text. Mit `--json` geht ein Fehler trotzdem als Text nach stderr, mit einem Exit-Code ungleich null; stdout enthält nur, was davor schon getan wurde.

Die Exit-Codes und alle Umgebungsvariablen (`DEPLOYS_READONLY`, `DEPLOYS_NO_GITHUB`, `DEPLOYS_CONFIG`, …) stehen in [CLI.md](CLI.md). Fehlermeldungen: [TROUBLESHOOTING.de.md](TROUBLESHOOTING.de.md).
