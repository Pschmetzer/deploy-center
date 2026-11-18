# Deploy Center – Ideen, Runde 9

Neue Ideen aus einer Durchsicht des Repos (Runde 8 abgeschlossen). Nichts davon steht schon in `IDEEN-2` bis `IDEEN-6`.
Erledigte Punkte stehen unter „Stand“.

## Stand

- 67 Kleineres Docker-Image: `WITH_VERCEL=0` lässt die Vercel-CLI weg (567 MB statt 1,09 GB, gemessen).
- 41 Zeitraum 7/14 Tage im Kostendiagramm ist umgesetzt; 53 (Störungen) gibt es schon im Store.
- 66 Plan als PR-Kommentar ist umgesetzt (`examples/plan-pr-comment.yml`, kommentiert beim Merge; Kostenschätzung, nichts wird deployt).
- 65 VS-Code-Statusleiste „N Commits warten“ ist umgesetzt.
- 64 Raycast und Alfred zeigen die Kosten des nächsten Deploys (Schätzung aus `deploys plan --json`) sind umgesetzt.
- 14 „Nur Fehlgeschlagene anhaken“ pro Repo-Gruppe und 16 klappbare Gruppenköpfe (merkt sich den Zustand) sind umgesetzt. 18 „Alle Fixes anhaken“ (Sammelaktion, nur Haken) ist umgesetzt. 15 Kosten in der unteren Leiste ist umgesetzt. 21 Suchfilter `repo:`, `host:` und `is:waiting` sind umgesetzt. 45 Vorschau des neuesten Commits in der Bestätigung ist umgesetzt. 22 Gespeicherte Ansichten (als gespeicherte Suchen) sind umgesetzt.
- 68 (Erststart-Rundgang als Doc `FIRST-START.md`, beschreibt den echten Ablauf) und 70 (`SETTINGS.md` mit Beispiel je Einstellung) sind als Seiten umgesetzt, auch auf Deutsch.
- 25 Sparkline, 36 Budget pro Projekt mit Ampel, 37 Was-wäre-wenn (ein Build pro Tag) und 38 Monatsbericht (Markdown) sind in der Kostenansicht umgesetzt.
- 61 Widget „Nächster geplanter Deploy“ ist da (Snapshot-Feld `nextScheduled`, Widget in `widgets/`); die Mac-App muss das Feld noch befüllen.
- 27 (Verlauf als CSV: `deploys journal export`) und 38 (Monatsbericht als Markdown: `deploys journal report`) sind umgesetzt.
- 14 „Nur Fehlgeschlagene anhaken“ pro Repo-Gruppe und 16 klappbare Gruppenköpfe (merkt sich den Zustand) sind umgesetzt. 21 Suchfilter `repo:`, `host:` und `is:waiting` sind umgesetzt.
- 63 Deploy per Face ID aus der Benachrichtigung ist umgesetzt (Aktion „Mit Face ID deployen“, prüft, dass das Projekt noch wartet; Face ID wie bei jedem Deploy).
- 62 Komplikation für die Apple Watch: nicht umgesetzt. Es gibt kein watchOS-Target; die Lock-Screen-Widgets der iPhone-App erscheinen ab watchOS 11 schon im Smart Stack der Uhr. Ein eigenes Target wäre ein größerer Eingriff ins Xcode-Projekt und braucht Apple-Konto-Schritte.
- Barrierefreiheit und Dynamic Type der iPhone-App und der Widgets geprüft: Beschriftungen, `@ScaledMetric` und Skalierung sind vorhanden, Leer- und Veraltet-Zustände gibt es in allen Widgets.

## Wartung und Repo

1. Lokale Agent-Worktrees (`.claude/worktrees/`) können Gigabytes belegen: regelmäßig mit `git worktree prune` und Entfernen sauberer Worktrees aufräumen.
2. `deploys` ist ein Skript mit über 4000 Zeilen: Befehle in `lib/*.sh` auslagern (autofix, scan, guard, ai, allow).
3. `Store.swift` und `MainWindow.swift` weiter aufteilen (Zustände „wartend“, „läuft“, „fertig“ als eigene Typen).
4. CI-Prüfung für Dateilänge von `deploys` und Swift-Dateien.
5. Eine gemeinsame Funktion `atomic_write` statt der wiederholten `mktemp`-und-`mv`-Muster.
6. `trap`-Aufräumen ohne `eval` (Array von Funktionsnamen).
7. UI-Tests (XCUITest) für Layout, Kontrast und Fokusreihenfolge.
8. Snapshot-Tests für die Zeilen im Hauptfenster (hell/dunkel, de/en).
9. Lokalisierungs-Katalog (`.xcstrings`) statt Texten im Code.
10. Stabile Fehlercodes im Skript, damit `CLIText.swift` nicht per Regex übersetzen muss.
11. Journal und Bilanz in SQLite statt JSON-Dateien.
12. `deploys doctor --json` als einzige Quelle für „offline“ oder „abgemeldet“.

## Hauptfenster

13. Den Hinweis „Claude gefunden“ mit „Nie wieder fragen“.
14. „Nur Fehlgeschlagene anhaken“ pro Repo-Gruppe.
15. Kosten des Deploys in der unteren Leiste, bevor man „Live deployen“ drückt.
16. Gruppenköpfe klappbar, Zustand merken.
17. Commits und PRs in einer Zahl, wenn beide gleich sind.
18. „Alle Fixes deployen“ als Sammelaktion.
19. Tooltip am roten Punkt („Domain nicht erreichbar“ / „letzter Build fehlgeschlagen“).
20. Gemeinsamer Deploy mit fester Reihenfolge für zwei Projekte desselben Repos (API vor Web).
21. Suchfilter wie `repo:`, `host:`, `rot`.
22. Gespeicherte Ansichten.
23. Sortierung „Zuletzt deployt“ und „Teuerste Builds zuerst“.
24. „Gespart“-Summe erklärbar: Klick zeigt die Rechnung pro Projekt.
25. Mini-Verlauf (Sparkline) für die Build-Kosten der letzten 7 Tage.

## Sicherheit und Zuverlässigkeit

26. Vor dem Deploy warnen, wenn der Branch hinter `origin/main` liegt.
27. Deploy-Verlauf („wer hat wann was gestartet“) als CSV exportieren.
28. Automatischer Rollback-Vorschlag, wenn die Site-Überwachung nach dem Live-Gehen einen Fehler sieht.
29. Zwei-Personen-Freigabe auch in der App.
30. Warnung, wenn ein Token älter als 90 Tage ist.
31. „Zugangsdaten prüfen“ mit Rechten pro Anbieter.
32. Geheimnis-Scanner im Diff als Sperre vor dem Deploy.
33. Offline-Warteschlange für Deploys ohne Netz, mit Rückfrage nachholen.
34. Zertifikatswarnung auch für die Standard-Domains der Anbieter.
35. Rate-Limit-Anzeige der GitHub-API in der Statusleiste.

## Kosten

36. Budget pro Projekt und Monat mit Ampel.
37. „Was-wäre-wenn“: nur noch einmal am Tag deployen.
38. Monatsbericht als PDF oder Markdown.
39. Vergleich zweier Anbieter pro Projekt (Build-Minuten und Preis).
40. Projekte ohne Deploy seit 90 Tagen erkennen und Pausieren vorschlagen.
41. Kosten-Zeitraum frei wählbar.
42. Hinweis, wenn derselbe Commit auf zwei Anbietern gebaut wird.

## Neue Funktionen

43. Deploy-Fenster mit Kalender (Feiertage, Freeze-Zeiten).
44. Git-Tag oder Release-Notiz beim Deploy.
45. Changelog-Vorschau in der Bestätigung.
46. Gesundheitsprüfung pro Projekt in der App bedienbar (`verify` gibt es im CLI).
47. Abhängigkeits-Reihenfolge in `deploy-center.json`.
48. Stiller Modus nachts, Benachrichtigungen bündeln.
49. Zähler der wartenden Projekte im Menüleisten-Symbol.
50. Tastenkürzel pro Projekt.
51. Link `deploycenter://deploy/<projekt>` zum Teilen (mit Rückfrage).
52. Freigabe per Chat-Nachricht.
53. Anbieter-Störungen oben anzeigen.
54. Canary-Deploy per Klick.
55. Preview-URLs offener PRs in der Detailansicht.
56. Fehlgeschlagenen Deploy mit anderen Einstellungen neu starten (ohne Cache).
57. Log-Suche über alle Projekte.
58. Gleiche Build-Fehler mehrerer Projekte gruppieren.
59. Wochenrückblick in der App.
60. Wochenziele („höchstens N Deploys“).

## iPhone, Widgets, Integrationen

61. Widget „Nächster geplanter Deploy“.
62. Komplikation für die Apple Watch.
63. Deploy per Face ID aus der Benachrichtigung.
64. Raycast und Alfred zeigen die Kosten des nächsten Deploys.
65. VS-Code-Statusleiste „N Commits warten“.
66. GitHub Action, die den Plan als PR-Kommentar postet.
67. Kleineres Docker-Image prüfen.

## Texte und Hilfe

68. Erststart-Rundgang mit echten Daten statt Demo.
69. Fehlermeldungen mit Link zu `TROUBLESHOOTING.md`.
70. Jede Einstellung mit einem kurzen Beispiel.
