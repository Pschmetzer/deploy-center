# Deploy Center – Ideen und Korrekturen

Durchgesehen: `deploys` (Skript), `app/DeployCenter.swift`, `build.sh`, README.
★ = zuerst machen (echter Fehler oder großer Nutzen).

## A. Fehler und Schwachstellen im Code

1. ★ **Möglicher Hänger in `Tool.run`:** Die App liest stdout ganz, bevor sie stderr liest. Schreibt ein Befehl mehr als ~64 KB auf stderr (z. B. eine lange Vercel-Warnung), wartet beides aufeinander und die App hängt. Beide Pipes gleichzeitig lesen.
2. ★ **Kein Zeitlimit für Befehle:** Bleibt die `vercel`-CLI hängen (Netz, Login-Abfrage), dreht die App für immer. Timeout pro Aufruf mit Abbruch.
3. ★ **„Neue Änderungen" vergleicht Zeiten statt Commits:** Ein alter Commit, der später gemergt wird, zählt nicht. Besser: Commit-SHA des Live-Deploys (Vercel `meta.githubCommitSha`, Render `deploy.commit.id`) mit dem SHA auf GitHub vergleichen.
4. ★ **Zeilen sind für VoiceOver und Tastatur nicht bedienbar:** Das Anhaken läuft über `onTapGesture` auf einem Bild. Als echten Toggle/Button bauen.
5. **„Zuletzt deployt" bei Vercel zeigt den aktuellen Production-Stand, nicht den letzten Versuch:** Ein gescheiterter Deploy danach erscheint nicht. Den neuesten Deploy dazu holen.
6. **Vom Ignored Build Step übersprungen** erscheint als rotes „Fehler". Grau als „übersprungen" anzeigen (Status `CANCELED`).
7. **Paging der Vercel-Projekte** nutzt `until=`. Ob die v10-API das so erwartet (oder `from=`), ist nicht geprüft. Ab 100 Projekten könnten welche fehlen.
8. **Der Render-Key wird bis zu 20× parallel aus dem Schlüsselbund gelesen** (`render_last_of`). Das kann mehrere macOS-Abfragen auslösen. Einmal lesen und weitergeben.
9. **Jeder Status-Abruf startet bash und node (`vercel api`)**, alle 6 s pro Deploy. Bei 10 parallelen Deploys ist das spürbar. Direkt per HTTPS abfragen.
10. **Vercel-Projekte sind über den Namen identifiziert.** Eine Umbenennung trennt sie von ihrer Repo-Zuordnung. Die Projekt-ID speichern.
11. **`start()` lädt Vercel und Render nacheinander.** Parallel laden spart etwa 5 Sekunden.
12. **Fehlermeldungen des Skripts sind englisch**, die Oberfläche deutsch. Die häufigsten Meldungen in der App übersetzen.
13. **Der Link zu den Render-API-Keys** (`/u/settings#api-keys`) ist geraten, nicht geprüft.
14. **„Alle mit Änderungen anhaken"** hakt auch Projekte an, die gerade deployen.
15. **Ein Deploy-Fehler zeigt den Grund nur als Tooltip.** Sichtbar machen und kopierbar anbieten.
16. **Logos werden bei jedem Start neu geladen.** Auf der Platte zwischenspeichern.
17. **Logos mit transparentem dunklem Motiv** sind auf dem weißen Hintergrund manchmal schlecht zu sehen. Den Hintergrund an das Bild anpassen.
18. **`--dangerously-skip-permissions` beim Trennen** hängt an einem CLI-Schalter, den Vercel ändern kann. Als Ausweg den REST-Aufruf direkt einbauen.
19. **Die App lädt jedes Mal die volle Liste (8 s).** Den letzten Stand sofort zeigen und im Hintergrund auffrischen.
20. **Projekte mit „Repo unbekannt"** lassen sich nur über die JSON-Datei reparieren. Ein Formular in der App wäre besser.

## B. Deployen

21. ★ **Vorschau-Deploy per Knopf** (das Skript kann `--preview` schon).
22. ★ **Rollback-Knopf:** Vercel stuft den vorherigen Deploy wieder hoch, bei Render gibt es Rollback per API.
23. **Deploy abbrechen**, solange er baut.
24. **Build-Log** und Link zum Deploy im Dashboard direkt in der Zeile.
25. **Commits zwischen Live und GitHub auflisten**, mit Link auf den Vergleich bei GitHub.
26. **Branch oder Commit wählen** statt immer den neuesten.
27. **Gruppen:** Frontend (Vercel) und Backend (Render) desselben Produkts als ein Paket deployen.
28. **Reihenfolge innerhalb einer Gruppe:** erst das Backend, dann das Frontend.
29. **Warteschlange:** Nicht alles gleichzeitig starten, damit Vercels Limit für parallele Builds nicht greift.
30. **Bestätigungsdialog mit den Commit-Nachrichten**, nicht nur den Namen.
31. **Option „Nicht mehr fragen"** für Vorschau-Deploys.
32. **Verlauf:** Liste der Deploys, die aus der App gestartet wurden, mit Dauer und Ergebnis.
33. **Benachrichtigung** des Macs, wenn ein Deploy fertig ist oder fehlschlägt.
34. **Täglicher Deploy zur festen Uhrzeit** (launchd), nur für Projekte mit Änderungen.
35. **„Nach dem Deploy prüfen":** Die Seite einmal aufrufen und HTTP 200 bestätigen.

## C. Kosten (der eigentliche Zweck)

36. ★ **Kosten-Anzeige:** Build-Minuten und Dollar pro Tag aus der Vercel-Billing-API, vorher und nachher.
37. **„Gespart seit dem Abschalten"** als Zahl oben im Fenster.
38. **Bauzeit pro Deploy** und geschätzte Kosten pro Projekt.
39. **Warnung**, wenn trotzdem Git-Builds auftauchen (Quelle `git` nach dem Abschalten).
40. ★ **Andere Auslöser finden:** GitHub-Actions mit `vercel --prod`, Deploy-Hooks bei Vercel und Render, Blueprint-Auto-Sync. Alles, was weiter Builds startet, anzeigen.
41. **Render-Blueprints mit Auto-Sync** erkennen und ein Abschalten anbieten.
42. **Previews bei Vercel behalten, nur Production abschalten:** als zweiter Modus über `git.deploymentEnabled` oder den Ignored Build Step, statt die Verbindung zu trennen.
43. **Ausnahmen:** einzelne Projekte bewusst auf Auto-Deploy lassen (z. B. sehr billige).
44. **Auto-Deploy wieder einschalten** per Knopf (Repo wieder verbinden, Render auf „On Commit").

## D. Oberfläche

45. **Menüleisten-Symbol** mit der Zahl der Projekte mit Änderungen.
46. **Sortieren** nach Name, letztem Deploy oder Änderungen zuerst.
47. **Abschnitte:** „Mit Änderungen" oben, „Pausiert/unbekannt" eingeklappt unten.
48. **Tastenkürzel:** ⌘F Suche, ⌘R Neu laden, Leertaste anhaken, ⌘A alle mit Änderungen.
49. **Esc leert die Suche.**
50. **Tab, Filter und Fenstergröße merken.**
51. **„Zuletzt aktualisiert vor x Min."** anzeigen und automatisch alle N Minuten neu laden.
52. **Leerer Zustand**, wenn ein Konto keine Projekte hat.
53. **Ansicht „Alles"**, die Vercel und Render in einer Liste zeigt.
54. **Kompakte Ansicht** mit einer Zeile pro Projekt.
55. **Projekt-Detailseite:** Domains, Repo, Branch, letzte 10 Deploys, Umgebung.
56. **Fehler kopieren** per Knopf, um sie an Claude oder ein Issue zu geben.
57. **Einführung beim ersten Start** mit einer Spar-Rechnung („Du pushst X-mal am Tag …").
58. **Logos als Fallback** über den GitHub-Avatar der Organisation.
59. **Hell/Dunkel sauber testen.** Die Farben der Abzeichen sind nur auf dunkel geprüft.
60. **Weitere Sprachen** (Spanisch, Französisch), wenn die Texte in einer Tabelle liegen.

## E. Konten und Plattformen

61. **Mehrere Vercel-Teams** in der App umschalten (das Skript kann nur eines gleichzeitig).
62. **Mehrere Render-Workspaces** nach Inhaber getrennt anzeigen.
63. **Netlify, Railway, Fly.io, Cloudflare Pages** als weitere Plattformen, mit einem kleinen Anbieter-Modul pro Plattform.
64. **GitLab und Bitbucket** als Quelle (bisher nur GitHub).
65. **`RENDER_API_KEY` und `VERCEL_TOKEN` als Umgebungsvariablen** für CI und Server.
66. **Linux-Unterstützung des Skripts:** `secret-tool` statt Schlüsselbund, Umgebungsvariable als Rückfall.
67. **Gemeinsame Team-Konfiguration** (Zuordnungen in einem Repo statt pro Mac).

## F. Kommandozeile

68. **`deploys changed`** listet alles mit neuen Commits.
69. **`deploys deploy-changed --yes`** für den täglichen Lauf per Cron oder durch Claude.
70. **Einheitliches `--json`** statt eigener `…-json`-Befehle.
71. **`deploys vercel autodeploy-on <p>`** und **`deploys render autodeploy-on <s>`.**
72. **`deploys vercel map <projekt> <org/repo> [branch]`** schreibt die Zuordnung ohne JSON-Bearbeitung.
73. **`deploys logs <projekt>`** zeigt das Build-Log des letzten Deploys.
74. **`deploys rollback <projekt>`.**
75. **Shell-Vervollständigung** für zsh und bash.
76. **Homebrew-Formel** für das Skript allein.

## G. Qualität und Veröffentlichung

77. ★ **Universal-Binary** (Apple Silicon und Intel), heute nur arm64.
78. ★ **Notarisierung** mit Apple-Entwickler-Konto, dann entfällt „Trotzdem öffnen".
79. **Homebrew-Cask** (`brew install --cask deploy-center`).
80. **Automatische Updates** (Sparkle) oder ein Hinweis auf neue Versionen über die GitHub-Releases-API.
81. **GitHub Action**, die beim Versions-Tag baut und den Release anlegt.
82. **shellcheck** über `deploys` in CI.
83. **Tests für das Skript** (bats) mit nachgebauten API-Antworten.
84. **Swift-Code aufteilen:** Swift-Paket mit Dateien für Modell, Ansichten, Logos, Werkzeug.
85. **Unit-Tests** für `hasNewCommits`, `iconLinks` und das Zustands-Mapping.
86. **Swift-6-Modus** mit strikter Nebenläufigkeit, sobald der Code aufgeteilt ist.
87. **README mit Screenshot oder GIF.**
88. **CONTRIBUTING, Issue-Vorlagen, CHANGELOG.**
89. **Namen prüfen:** Gibt es „Deploy Center" schon als Produkt oder Marke?
90. **Datenschutz-Absatz:** keine Telemetrie; Logos werden direkt von den eigenen Seiten geladen.
91. **Sicherheitshinweis zum Render-Key** (Vollzugriff) und Empfehlung, einen eigenen Key nur für die App anzulegen.
92. **Launch:** Show HN, Product Hunt, Posts in der Vercel- und Render-Community.
93. **Kleine Landingpage** mit Kostenrechner.

## H. Für Claude und Automatisierung

94. **MCP-Server**, der `deploys` für jede Claude-Sitzung als Werkzeug anbietet.
95. **Raycast- oder Alfred-Erweiterung:** „deploy my-site".
96. **Kurzbefehle-Aktion** (Apple Shortcuts) „Alles mit Änderungen deployen".
