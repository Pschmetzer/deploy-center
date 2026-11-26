# Deploy Center – Ideen, Runde 16 (Stand 0.14.0)

Neue Ideen, die in keiner anderen `IDEEN-*.md` stehen und die es im CLI und in der Mac-App noch nicht gibt. Beleg je Idee:
die Suche, die nichts fand (`deploys --help`, `docs/CLI.md`, `grep -i` über `docs/IDEEN*.md`, `app/`, `lib/`). Die Zusatzbefehle
liegen in `lib/x-<name>.sh` (`deploys more`), damit die große Datei `deploys` und die Sessions von IDEEN-15 in Ruhe bleiben.
Nichts davon startet einen Build, Deploy oder Rollback; wer etwas schreibt, schreibt nur dorthin, wohin man zeigt.
Status: **PR** = umgesetzt, **offen** = Idee bleibt für eine spätere Runde, **App** = braucht Swift (nur auf dem Mac prüfbar).

## Journal lesen, anders gezeigt
1. `deploys heatmap` – Kalender-Heatmap der letzten Wochen im Terminal (ein Block je Tag, Dunkelheit = Zahl der Deploys, rot markiert = Tag mit Fehlschlag). Beleg: `digest`, `weeks`, `when` zählen, zeigen aber keine Tage; „heatmap" steht nur als App-Zeitleiste in IDEEN-4/6. Status: PR.
2. `deploys trend <p>` – eine Zeile Sparkline (`▁▂▅█`) je Projekt: Deploys je Tag, darunter Fehlschläge. Beleg: kein `spark`, `trend` in `deploys`, `docs/CLI.md`. Status: PR.
3. `deploys handover` – Schichtübergabe als Text: offene Fehlschläge (kein späteres „live"), Notizen der letzten 24 h, geschlossenes Fenster, nächste Sperre. Beleg: `timeline`, `digest` zeigen Verlauf, nicht „was ist noch offen"; „handover" 0 Treffer in `deploys`. Status: PR.
4. `deploys flaky` – Projekte, deren Build scheitert und kurz danach ohne neuen Anlass klappt (Wiederholung hilft). Beleg: `recovery` misst Dauer, nennt aber keine Wackler; „flak" nur in Test-Kontexten von IDEEN-11. Status: PR.
5. `deploys besttime` – die ruhigsten Zeitfenster für einen Deploy (wenige Fehlschläge, wenig Betrieb, nicht in einer Sperre). Beleg: `when` zeigt Wochentag und Stunde roh, ohne Empfehlung. Status: PR.
6. `deploys slo` – ein Ziel („95 % der Deploys klappen in 30 Tagen"), Bericht je Projekt, Exit 1 darunter (für Cron und CI). Beleg: `health` ist ein Wert 0–100, kein Ziel; „slo" 0 Treffer. Status: PR.
7. `deploys quiet-days` – Tage ohne jeden Deploy und ohne Fehlschlag (Urlaub, Feiertag) herausrechnen, damit `streak` und `slo` nicht verzerrt sind. Beleg: `streak` zählt Deploys in Folge. Status: offen.
8. `deploys outages` – jeder Ausfall (Fehlschlag bis „live") als Liste mit Dauer, sortiert nach Länge, mit `--csv`. Beleg: `recovery` nennt Median und Zahl, nicht die Liste. Status: offen.
9. Journal-Suche mit Zeitraum und Ergebnis: `deploys timeline --result failed --grep text`. Beleg: `timeline` kennt nur `--days`, `--project`, `--limit`. Status: offen.
10. `deploys diff-weeks` – zwei Zeiträume Projekt für Projekt gegeneinander (nicht nur gesamt). Beleg: `weeks` vergleicht die Summe. Status: offen.

## Planen und Kalender
11. `deploys calendar` – Sperrzeiten und geplante Läufe (`freeze`, `window.json`, `schedule`, `prepare`) als `.ics`-Datei für die nächsten 30 Tage, zum Abonnieren im Kalender. Beleg: `freeze status` zeigt nur „jetzt"; kein `ics` im CLI. Status: PR.
12. `deploys checklist <p>` – eine Checkliste je Projekt vor dem Deploy („Migration geprüft?", „Statusseite informiert?") in `checklists.json`; `--json` für die App; hält nichts zurück, zeigt nur. Beleg: `preview` nennt Risiko und Regeln, keine eigenen Punkte; „checklist" 0 Treffer. Status: PR.
13. `deploys snooze <p> 2d` – ein Projekt für Stunden oder Tage aus „changed" nehmen, es kommt allein zurück. Beleg: `ignore` hat kein Ablaufdatum. Status: offen (braucht Eingriff in `deploys`).
14. `deploys deploy-at <p> 18:00` – ein einmaliger, geplanter Deploy mit gespeichertem `--yes`. Beleg: `schedule daily` ist täglich. Status: offen (Einwilligung muss eigens gedacht werden).
15. Wartungsfenster-Planer: aus `besttime` und `window.json` das nächste freie Fenster nennen (`besttime --next`). Status: PR (Teil von 5).
16. Zeitzonen-Tabelle für das Team: Sperrzeit in drei Zeitzonen nebeneinander. Beleg: das Fenster hat eine Zeitzone, keine Anzeige in mehreren. Status: offen.

## Einstellungen und Betrieb
17. `deploys backup` / `deploys restore` – alle Einstellungsdateien des Konfigurationsordners (ohne Schlüssel, ohne Journal) als eine Datei sichern und zurückspielen; `restore` zeigt zuerst, was sich ändert, und schreibt nur mit `--yes`. Beleg: `export` kennt nur Journal und Kosten; „backup" 0 Treffer. Status: PR.
18. `deploys lint` – alle Einstellungsdateien auf Syntax und bekannte Felder prüfen (`window.json`, `rules.json`, `budget.json`, `ignored.json`, `checklists.json` …), mit Zeile und Hinweis. Beleg: `doctor` prüft Werkzeuge und Zugang, nicht die Dateien. Status: PR.
19. `deploys whatsnew` – die Änderungen der installierten Version aus dem CHANGELOG im Terminal. Beleg: `self-update --check` sagt nur „neu: ja/nein". Status: PR.
20. `deploys changelog <p>` – Release-Notizen nach Art gruppiert (feat, fix, docs, Rest) aus den Commit-Titeln. Beleg: `notes` ist flach, `ai notes` braucht einen Schlüssel. Status: PR.
21. `deploys tips` – ein Hinweis pro Aufruf auf einen Befehl, den man noch nie benutzt hat (aus dem Journal und der Befehlsliste). Status: offen.
22. `deploys shortcuts` – Spickzettel der Tastenkürzel der Mac-App, aus dem Quelltext gelesen, damit er nicht veraltet. Beleg: Kürzel stehen verstreut in `app/*.swift`, kein Spickzettel. Status: offen (App).
23. `deploys exit` – `deploys exit-codes` mit dem Code des letzten Laufs (`$?`) erklärt. Status: offen.

## Teams und Kosten
24. Kosten-Warnung je Team (Vercel-Team): eigene Obergrenze je Team neben dem gemeinsamen Budget. Beleg: `budget` ist ein Betrag für alles. Status: offen.
25. `deploys owners` – Besitzer je Projekt (`owners.json`) und `digest --by-owner`. Beleg: „owner" betrifft nur den Eigentümer-Check der App. Status: offen.
26. Kosten je Deploy im `timeline` mitführen (Schätzung aus `forecast`). Status: offen.
27. Budget-Brücke: Warnung im `handover`, wenn `forecast` „near" sagt. Status: offen.

## Mac-App (nur auf dem Mac prüfbar)
28. Handover als Fenster („Übergabe"): derselbe Text wie `deploys handover`, kopierbar. Status: App.
29. Heatmap im Verlauf-Fenster (der CLI-Befehl liefert `--json`). Status: App.
30. Checkliste vor dem Bestätigen: Punkte aus `checklists.json` als Häkchen im Bestätigungsblatt, ohne dass ein Haken den Deploy sperrt. Status: App.
31. Einstellungen sichern und zurückspielen im Einstellungsfenster (ruft `backup`/`restore` auf). Status: App.
32. Onboarding-Assistent für einen neuen Anbieter: Schlüssel, Prüfung (`creds`), erstes Projekt, erste Trockenübung. Beleg: `FirstStart` führt nur durch Vercel und Render. Status: App.
33. Statusseite als eine HTML-Datei (aus `list`, `history`, `health`): `integrations/statuspage` existiert, aber ohne Journal-Verlauf der letzten 30 Tage. Status: offen.
34. Spickzettel-Fenster der Tastenkürzel (⌘/). Status: App.

## Zusammenspiel mit Claude Code
35. `deploys handover --json` als schreibgeschütztes MCP-Werkzeug. Status: offen.
36. Der Ship-Skill liest `checklist` und nennt offene Punkte, bevor er `--yes` vorschlägt. Status: offen.
