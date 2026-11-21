# Deploy Center – Ideen, Runde 13: neue Nutzer-Features (Stand 0.11.0)

Gegen IDEEN.md bis IDEEN-12.md abgeglichen: nichts hier steht dort. Alles ist **lesend** (Journal, `window.json`), startet nichts
und braucht kein Netz. Neue Dateien statt Umbauten, damit parallele Arbeit nicht kollidiert. Status: ✅ umgesetzt, ⬜ offen.

## A. Journal-Sichten (CLI, `lib/insights.sh`)

1. ✅ **Zeitleiste** `deploys timeline [--days 3] [--project p] [--limit 50] [--json]` – was geschah, neuester Tag zuerst (Deploys, Fehlschläge, Rollbacks, erzwungene Starts).
2. ✅ **Erholungszeit** `deploys recovery [--days 30] [--project p]` – Zeit vom ersten Fehlschlag bis zum nächsten Deploy desselben Projekts; mehrere Fehlschläge hintereinander sind ein Ausfall; „offen“, wenn kein Deploy folgte.
3. ✅ **Wann scheitert es?** `deploys when [--by weekday|hour]` – Fehlerquote je Wochentag oder Stunde (UTC); ein Fach braucht fünf Versuche, sonst „zu wenig“. Ein Hinweis aus der eigenen Historie, keine Regel.

## B. Weitere CLI-Kommandos (offen)

4. ⬜ **Zwei Deploys vergleichen** `deploys compare <projekt> <a> <b>` – Commits, Dateien (Migrationen, Lockfiles) und Zeitabstand zwischen zwei Deploys; nur lesen.
5. ⬜ **Status teilen** `deploys share [--project p]` – ein maskierter Textblock (Markdown) „was ist live, was wartet, was ist rot“ für Chat oder Ticket; Tokens maskiert, Namen auf Wunsch (`--demo`) ersetzt.
6. ⬜ **Ruhige Zeiten** `deploys quiet` – aus `when` und der Zeitleiste die Stunden ohne Deploys vorschlagen und als `freeze add`-Befehl ausgeben (nur anzeigen, nie setzen).
7. ✅ **Serie ohne Fehlschlag** `deploys streak` – Deploys in Folge ohne Fehlschlag je Projekt, längste Serie; als Zahl für Badges.
8. ⬜ **Kostenwarnung pro Projekt** `deploys budget --project` – Warnschwelle je Projekt statt nur gesamt, Ausgabe wie `budget`, Exit 1 bei Überschreitung.
9. ✅ **Notiz am Deploy** `deploys note <projekt> "Text"` – eine Zeile ins Journal (Ergebnis `note`), erscheint in `timeline`; Geheimnisse werden abgelehnt.

## C. Mac-App und iPhone (offen)

10. ⬜ **Zeitleiste im Verlauf** – dieselbe Sicht wie `deploys timeline` als Seite im Verlaufsfenster, Filter je Projekt.
11. ⬜ **Erholungszeit-Karte** im Wochenbericht („typisch 1 h 20 m, 1 offen“).
12. ⬜ **Shortcuts/Intents** „Status teilen“ und „Was wartet?“ (nur lesen; ein Deploy bleibt ein Klick mit Bestätigung).
13. ⬜ **Tastaturkürzel-Blatt** (⌘/) mit allen Kürzeln der App, je Fenster.
14. ⬜ **Widget „Offene Ausfälle“** – Projekte mit Fehlschlag ohne späteren Deploy, seit wann.

## D. Integrationen (offen)

15. ⬜ MCP-Tools `deploys_timeline`, `deploys_recovery` (lesend).
16. ⬜ Raycast/Alfred: „Zeitleiste“.
