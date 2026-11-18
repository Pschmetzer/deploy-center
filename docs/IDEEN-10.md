# Deploy Center – Ideen, Runde 10

Neue Ideen nach Runde 9. Erledigte Punkte stehen unter „Stand“.

## Stand

- 21 (`deploys plan --since 1d`) ist umgesetzt.
- 22 (Exit-Codes: stehen in `CLI.md`, einige jetzt getestet) ist umgesetzt.
- 15 „Liste kopieren“ in der Bestätigung ist umgesetzt.
- 1 Rechtsklick „Nur dieses Repo zeigen“ am Gruppenkopf ist umgesetzt.
- 6 Gespeicherte Suchen in der Befehlspalette (und „Nur Fehlgeschlagene“) sind umgesetzt.
- 3 Tastenkürzel ⌥⌘F ist umgesetzt.
- 2 Trefferzahl der Suche und 8 rote Projekte im Gruppenkopf sind umgesetzt. 12 Warnung bei altem Commit und 14 „gerade erst deployt“ in der Bestätigung sind umgesetzt.
- 17 Budget-Hinweis im Menüleistensymbol und 18 teuerstes Projekt der Woche (in der Kostenansicht) sind umgesetzt.
- 19 (`deploys list --format tsv`) und 20 (`doctor` prüft den Einstellungsordner) sind umgesetzt.
- 2 Trefferzahl der Suche und 8 rote Projekte im Gruppenkopf sind umgesetzt.

## Hauptfenster

1. Rechtsklick auf einen Gruppenkopf: „Nur diese Gruppe zeigen“.
2. Anzahl gefilterter Zeilen in der Suchleiste („3 von 41“).
3. Tastenkürzel ⌥⌘F für „Nur Fehlgeschlagene“.
4. Zeilen mit offenem Fix-PR bekommen eine eigene Markierung in der Sortierung „Wartende zuerst“.
5. „Zuletzt angesehen“-Liste in der Befehlspalette.
6. Gespeicherte Suchen auch in der Befehlspalette.
7. Hinweis, wenn die Suche nur durch einen versteckten Anbieter-Tab leer bleibt.
8. Gruppenkopf zeigt, wie viele Projekte rot sind.
9. Zeile: Tooltip am „fehlgeschlagen“-Text mit dem Fehler in einem Satz.
10. „Alle Gruppen“-Zustand pro Anbieter-Tab getrennt merken.

## Bestätigung und Sicherheit

11. Bestätigung nennt die Zahl der Dateien der wartenden Commits.
12. Bestätigung warnt, wenn der neueste Commit älter als 30 Tage ist.
13. Bestätigung zeigt, wer den neuesten Commit geschrieben hat (nur Vorname, abschaltbar).
14. Letzter Deploy desselben Projekts vor weniger als 5 Minuten: Hinweis „gerade erst deployt“.
15. Liste der wartenden Projekte als Anhang in der Bestätigung kopierbar.

## Kosten

16. Kosten der Auswahl in der Bestätigung mit Bandbreite (min/max der letzten 7 Tage).
17. Monatsbudget-Ampel auch in der Menüleiste.
18. „Teuerstes Projekt der Woche“ in der Bilanz.

## CLI

19. `deploys list --format tsv` für Skripte ohne jq.
20. `deploys doctor` prüft zusätzlich Schreibrechte in `~/.config/deploys`.
21. `deploys plan --since 1d`.
22. Exit-Codes dokumentieren und testen.

## Texte und Hilfe

23. Jede Menüzeile unter „Mehr“ mit Kurzbeschreibung in der Hilfe.
24. Glossar um „Gruppe“, „Gespeicherte Suche“ und „Gemergter Fix“ ergänzen.
