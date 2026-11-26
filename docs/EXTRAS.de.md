# Zusatzbefehle

Kleine Befehle neben den großen. Jeder liegt in einer eigenen Datei, `lib/x-<name>.sh`, damit `deploys` selbst klein bleibt.
`deploys more` listet sie mit je einer Zeile, `deploys more <Befehl>` zeigt die Anwendung eines Befehls. Keiner startet einen
Build, einen Deploy oder einen Rollback; die, die etwas schreiben (eine Sicherungsdatei, eine Kalenderdatei), sagen es und
schreiben nur dorthin, wohin du zeigst.

English: [EXTRAS.md](EXTRAS.md)

```bash
deploys more                # alle Zusatzbefehle, je eine Zeile
deploys more heatmap        # die Anwendung eines Befehls
deploys more --json         # für Skripte
```

## heatmap und trend: das Journal als Bild

```bash
deploys heatmap                      # 12 Wochen, Montag oben: · keine, ░ wenige, ▒ einige, ▓ viele, █ am meisten, ! ein Fehlschlag an dem Tag
deploys heatmap --weeks 26 --project web
deploys trend                        # je Projekt eine Sparkline: Deploys pro Tag der letzten 30 Tage, Fehlschläge darunter
deploys trend web --days 14 --json
```

Gezählt wie bei [`deploys digest`](CLI.md), in UTC. Gelesen wird nur das Journal.

## handover und flaky

```bash
deploys handover                     # für die nächste Schicht: was scheitert gerade, Notizen, Zahlen, ist das Deploy-Fenster zu
deploys handover --hours 48 --json
deploys flaky                        # Projekte mit 2 oder mehr Fehlschlägen, die binnen 30 Minuten wieder liefen (30 Tage)
deploys flaky --within 2h --min 1
```

`handover` fragt keine Plattform und kein GitHub: gelesen werden das Journal (und `window.json`). „Scheitert gerade" heißt: der
neueste Start oder Fehlschlag des Projekts ist ein Fehlschlag. Eine Notiz mit `deploys note <Projekt> "Text"` erscheint in der
Übergabe. `flaky` ist ein Hinweis, dass ein erneuter Versuch half, kein Urteil.

## besttime und slo

```bash
deploys besttime                     # die Zeitfenster (Wochentag und Stunde, UTC) mit den besten Deploys, die mit den meisten Fehlschlägen, das nächste gute
deploys besttime --next              # nur das: "Wed 11:00 (2026-12-02T11:00:00Z)"
deploys slo set 95                   # ein Ziel: 95 % der Deploys jedes Projekts klappen (slo.json im Konfigurationsordner)
deploys slo --days 30                # jedes Projekt dagegen; Exit 1, wenn eines darunter liegt (für Cron und CI)
deploys slo off
```

`besttime` liest nur dein eigenes Journal und kennt das Deploy-Fenster nicht: schau mit `deploys freeze` nach, bevor du auf ein
Fenster planst. Ein Zeitfenster zählt ab `--min` (5) Starts und Fehlschlägen. `slo` zählt wie `deploys digest`: Starts gegen Starts plus Fehlschläge.

## calendar: die Sperrzeiten im Kalender

```bash
deploys calendar                       # die Sperrzeiten der nächsten 30 Tage als .ics im Terminal
deploys calendar --days 90 --out sperren.ics
```

Ein Termin „Deploys closed" je gesperrter Zeit der „deny"-Regeln von `window.json` (der Grund, oder „closed by the deploy window",
steht im Text). Die Zeiten sind die lokalen Zeiten des Fensters, mit seiner `tz` als Zeitzone des Kalenders, wenn es eine hat.
[`deploys freeze import`](SAFE-DEPLOY.md) liest eine Kalenderdatei in die andere Richtung. Geschrieben werden nur die Sperren, nicht die geplanten Läufe.

## backup und restore: Einstellungen mitnehmen

```bash
deploys backup --out settings.json     # die Einstellungsdateien des Konfigurationsordners in einer Datei (Modus 600)
deploys restore settings.json          # zeigt je Datei neu / geändert / gleich; schreibt nichts
deploys restore settings.json --yes    # schreibt; ersetzte Dateien liegen vorher in restore-backup-<Zeit>/
```

Enthalten: window, rules, budget, prices, ignored, groups, guard, providers, clean, nightly, prepare, Autofix-Grenzen, slo,
checklists und sessions (`.json`). Nie enthalten: das Journal, Caches, Schlüssel (Schlüsselbund oder Umgebung), Auto-Deploy-Freigaben
(sie enden mit Absicht, ein Zurückspielen schaltete eine Sicherung ab) und Zeitpläne (sie gehören zu einem Rechner). Eine Datei, die kein gültiges JSON ist
oder nach einem Geheimnis aussieht, bleibt draußen und wird genannt. `restore` lehnt jeden Dateinamen ab, der nicht auf der Liste steht,
und `--yes` ist im Beobachtermodus verweigert.

## checklist und lint: eigene Punkte, eigene Dateien

```bash
deploys checklist add web "Migration als Trockenlauf geprüft"
deploys checklist add '*' "Support vor einem Freitags-Deploy informieren"    # * = jedes Projekt
deploys checklist web                                                       # die Punkte für web, dann die für alle
deploys checklist remove web 1
deploys lint                                                                # window, budget, slo, checklists und der Rest: gültig, mit den richtigen Feldern?
```

Eine Checkliste ist eine Erinnerung: nichts wartet auf einen Haken und kein Deploy-Befehl liest sie, sie hält also keinen Deploy
zurück und lässt keinen durch (dafür gibt es [Regeln und das Deploy-Fenster](SAFE-DEPLOY.md)). `add` und `remove` ändern
`checklists.json` und sind im Beobachtermodus verweigert; ein Punkt, der nach einem Geheimnis aussieht, wird abgelehnt. `deploys lint` nennt Datei, Regel und
Problem (`rule 2: "from" must be HH:MM`) und endet mit 1; `deploys doctor` prüft Werkzeuge und Zugang, `lint` deine Dateien.

## changelog: Release-Notizen nach Art

```bash
deploys changelog web                  # Markdown: Breaking changes, Features, Fixes, Performance, Documentation, ...
deploys changelog web --authors --format text
deploys changelog web --json
```

Liest dieselben Commits wie `deploys notes web --json` (gemergt, aber nicht live) und sortiert sie nach dem Conventional-Commit-Präfix
des Titels (`feat:`, `fix(scope):`, `docs:` …). Ein `!` hinter der Art oder „BREAKING CHANGE" im Titel stellt einen Commit unter „Breaking
changes". Ein Titel ohne Präfix kommt unter „Other"; Commits von Abhängigkeits-Bots stehen für sich. Autoren fehlen, solange du sie nicht
verlangst. Es wird nichts geschrieben oder deployt.

## Einen neuen hinzufügen

`lib/x-<name>.sh` neben `deploys` legen. Die Datei definiert `x_<name>_main` (Bindestriche im Namen werden zu Unterstrichen)
und sagt in einer Kopfzeile, was sie ist: `# x-command: <name> | <was er tut> | <Anwendung>`. Die Tests kommen nach
`tests/x/<name>.sh`; `tests/x-tests.sh` führt alle aus.
