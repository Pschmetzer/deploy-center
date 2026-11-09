# Deploy Center – Ideen, Runde 3

Gelesen: `deploys`, alle Dateien in `app/`, `build.sh`, `release.sh`, Tests, README, `IDEEN.md`, `IDEEN-2.md`.
Nur was dort noch nicht steht. ★ = zuerst. Stellen im Code in Klammern.
Hinweis: Das sind ~150 geprüfte Punkte, keine 1000. Mehr wäre Füllmaterial; die Liste ist aus dem Code und dem Screenshot abgeleitet.

## A. Echte Fehler (beim Lesen aufgefallen)

1. ✅ ★ **Rollback macht die Zeile „aktuell“, obwohl Live älter ist.** `rollback()` setzt `.done` mit `countsAsLive: true` → `set()` schreibt `lastSha = headSha`, `changed = false`. Nach einem Rollback zeigt die App „alles live“, obwohl der alte Stand läuft. (`Store.swift` rollback/set)
2. ✅ ★ **Gleiche Repo-Änderung wird doppelt gezählt.** `waiting` summiert Commits/PRs pro Projekt; teilen Frontend und Backend ein Repo (Screenshot: perchreel), zählt derselbe PR zweimal. „10 PRs warten“ ist zu hoch, `history` und Menüleiste erben den Fehler. Offene PRs sind dagegen pro Repo dedupliziert. (`Store.waiting`)
3. ✅ ★ **Banner gilt für beide Plattformen, Liste nur für den Tab.** Im Render-Tab steht „10 PRs in 6 Projekten“, die Liste zeigt 3. Entweder auf den Tab einschränken oder „davon hier: 3“ ergänzen.
4. ✅ ★ **`follow()` schluckt Fehler 40 Minuten lang.** `try? Tool.json` bei jedem Status-Abruf: ist das Netz oder die Vercel-Anmeldung weg, dreht der Spinner bis Timeout, ohne Hinweis. Nach 5 Fehlern in Folge „Status nicht abrufbar“ zeigen.
5. ✅ ★ **`checkSite` meldet falsche Alarme.** Vercel-Projekte mit Deployment Protection antworten 401/403, frisch gestartete Render-Dienste kurz 502/503. Retry (3× mit Pause) und 401/403 als „geschützt“ statt „kaputt“ werten. Nur die Startseite wird geprüft. (`Store.checkSite`)
6. ✅ **`deploy-changed --yes` kennt die Start-Sperre nicht** (Render-Zweig ruft `render_call POST` direkt, ohne `start_lock`). App und Terminal gleichzeitig = doppelter Build. Auch Reihenfolge Backend→Frontend gilt dort nicht.
7. **`ignore` (CLI) und „Ausblenden“ (App) sind zwei getrennte Listen.** Ein ignoriertes Projekt taucht in der App weiter als „Änderungen“ auf. Eine Quelle in `~/.config/deploys/` für beides.
8. ✅ **`triggers` fragt Render-Dienste nacheinander** (`for id in …`). Bei 20 Diensten spürbar; mit `xargs -P` parallel.
9. **`costs` startet pro Tag ein `vercel api` (node).** 14 Tage = 14 Node-Starts, danach 5 Seiten sequenziell. Direkt per `curl` mit Token oder einen breiteren Zeitraum pro Aufruf.
10. ✅ **`stat -f`, `date -v`, `base64 -D` sind BSD-only.** Skript läuft nur auf macOS; auf Linux/CI bricht es still. Kleine Kompat-Funktionen.
11. ✅ **Erinnerung (`remindIfDue`) feuert nur in der Refresh-Schleife.** Bei 60-Min-Intervall kann „9 Uhr“ erst um 9:59 kommen; nach dem Aufwachen aus dem Ruhezustand wird gewartet statt sofort geprüft. `NSWorkspace.didWakeNotification` nutzen.
12. ✅ **Nach dem Aufwachen/Netzwechsel kein Neuladen.** Liste kann Stunden alt sein, bis der Timer zuschlägt. Wake- und Netzwerk-Events (`NWPathMonitor`) auslösen.
13. **Notizen, Pins, Ausgeblendet, Dauer-Statistik liegen unter `platform/name` in UserDefaults.** Umbenennung = alles weg, Backup/Umzug auf neuen Mac unmöglich. Auf stabile ID umstellen, Export/Import.
14. ✅ **`visible`-Sortierung hat doppelten, widersprüchlichen Kommentar** und sortiert „Alle“ anders als die Einzeltabs (Änderungen nach Commits, Rest nach Name nur in „Alle“). Vereinheitlichen.
15. ✅ **`cancel()` bei `.starting` tut nichts** (kein `deployId`, `guard` kehrt still zurück). Klick wirkt kaputt; zumindest „startet noch, gleich nochmal“ melden.
16. **`Row.onTapGesture` + Button für dasselbe Ziel**: Doppeltes Auslösen bei Shift-Klick-Bereichen möglich (`tick` über `NSEvent.modifierFlags` statt Ereignis).
17. ✅ **Cache-Versionierung steht nur im Dateinamen (`-v2`).** Alte Dateien bleiben liegen; beim Start löschen.
18. ✅ **CostBar nur im Vercel-Tab.** In „Alle“ fehlen die Kosten, obwohl die Kosten das Kernversprechen der App sind.
19. ✅ **Kein CI.** Es gibt kein `.github/`: Tests (`tests/*.sh`), shellcheck und ein Build-Test laufen nur lokal.
20. **Tests sehr dünn:** `app-tests.swift` 81 Zeilen, `script-tests.sh` 67. `merge`, `waiting`, Rollback-Zustand, Queue-Reihenfolge (`waitsFor`) und `follow()`-Zustandsmapping haben keine Tests.

## B. Deploy-Ablauf und Sicherheit

21. ✅ ★ **Rückgängig-Fenster („Deployt in 10 s – Abbrechen“)** vor dem Start, wie bei Mail „Senden rückgängig“.
22. ★ **Automatischer Rollback bei kaputter Seite** (Idee 5): Nach `checkSite` fehlgeschlagen → Knopf „Zurückrollen?“ in der Mitteilung.
23. ★ **Smoke-Tests pro Projekt:** Liste von Pfaden + erwarteter Text/Status (`/health`, `/api/ping`), im Projekt-Detail pflegbar.
24. ★ **Sammel-Vorschau vor „Deployen“:** Summe der erwarteten Dauer und Kosten, Reihenfolge, riskante Dateien aller Projekte in einem Dialog.
25. **Deploy-Fenster / Freeze:** „Freitag ab 15 Uhr nicht deployen“ als Warnung mit Override.
26. **Geplanter Deploy** („heute 18:00, nur Projekte mit grünem CI“) in der App, mit Vorab-Mitteilung und Abbruch.
27. **Canary-Ablauf bei Vercel:** erst Vorschau, Smoke-Test, dann „Promote“ per Knopf (Vorschau-ID ist schon gespeichert, `previewId`).
28. **CI rot = Deploy sperren** (Warnschloss, Override mit Grund). Status liegt in `details`, nicht in der Liste.
29. **Zwei-Personen-Regel** für kritische Projekte (Markierung „Prod“, zusätzliche Bestätigung durch Texteingabe des Namens).
30. **Mit Commit/Branch deployen aus der Zeile:** `--sha` existiert; Branch-Auswahl fehlt.
31. **„Nur Backend“ / „Nur Frontend“-Schnellwahl** pro Repo-Paar.
32. **Bestätigung zeigt Commit-Nachrichten statt nur Anzahl** (nur das neueste `headMsg` ist da).
33. **Deploy für Cron-Jobs/Worker anders benennen:** Render `cron_job` „Jetzt ausführen“ statt „deployen“.
34. **Render „Dienst fortsetzen“** für pausierte Dienste direkt aus der Zeile (aktuell nur „pausiert“ + ausgegraut).
35. **Render „Neu starten“ ohne Build** (kostet keine Build-Minuten).
36. **Erneut versuchen** soll bei Build-Fehler „mit leerem Cache“ anbieten (Render hat `--clear-cache`).
37. **Doppelstart-Schutz sichtbar machen:** Wenn die 60-s-Sperre greift, Mitteilung erklären statt nur Fehler.
38. ✅ **Queue-Anzeige:** „Platz 3 von 7“, geschätzte Wartezeit aus `usualMinutes`.
39. **Queue pausieren/fortsetzen** (z. B. Mittagspause), Reihenfolge per Ziehen ändern.
40. **Deploy-Abhängigkeiten selbst definieren** statt nur „gleiches Repo“ (Frontend A braucht Backend B in anderem Repo).
41. ✅ **Notbremse:** Ein Knopf „Alles Laufende abbrechen“.
42. **Dry-Run-Modus** in der App, der nur zeigt, was passieren würde.

## C. Nach dem Deploy: Fehleranalyse

43. ✅ ★ **„Für Claude kopieren“:** Fehler + letzte 80 Log-Zeilen + Repo/Commit als fertiger Prompt in die Zwischenablage.
44. ✅ ★ **Build-Log springt zur ersten Fehlerzeile**, markiert `error`/`ERR!`/`failed`, filtert Rauschen.
45. **Fehler-Klassifikation** (Abhängigkeit fehlt, Node-Version, Speicher, Zeitlimit, Umgebungsvariable) mit Tipp.
46. **Build-Dauer-Verlauf pro Projekt** (nur die letzten 5 werden gespeichert) als Mini-Diagramm; Warnung bei plötzlich doppelter Zeit.
47. **Fehlerquote pro Projekt** („3 der letzten 10 Deploys schlugen fehl“).
48. **Runtime-Fehler nach dem Deploy** (Vercel Runtime Logs/Render Logs) 5 Minuten beobachten und bei Anstieg warnen.
49. **Letzten erfolgreichen Stand merken** und im Fehlerfall „Zurück auf Abc123“ anbieten.
50. **Deploy-Protokoll (Journal):** wer/wann/was/Ergebnis/Dauer, lokal als JSONL, durchsuchbar, Export CSV.
51. **Mitteilungen mit Aktionen** (Seite öffnen, Log, Zurückrollen) statt nur Text.
52. ✅ **Zusammenfassung nach einem Sammel-Deploy:** „7 live, 1 Fehler, 1 übersprungen, 14 Min, ≈ 2,10 $“.

## D. Was wartet – Inhalte besser nutzbar machen

53. ✅ ★ **Release-Notes aus wartenden PRs** erzeugen (Markdown, Slack, Deutsch/Englisch), Knopf „Kopieren“.
54. ★ **PRs mergen aus der App** (grüne CI, Bestätigung), danach „und deployen“. (offen aus IDEEN-2 #24)
55. **CI-Ampel in der Zeile** (grün/rot/läuft) für den Kopf-Commit.
56. **Risiko-Punktzahl pro Projekt:** Migrationen, Lockfile, `.env`, Größe des Diffs, Alter; sortierbar.
57. **„Nur Abhängigkeits-Updates“-Abzeichen** in der Zeile und Option „solche Projekte nicht anhaken“.
58. **Autoren-Filter:** „nur wenn ich Autor bin“ / „von Kollegen“.
59. ✅ **Wartezeit-Alarm:** Commit wartet > N Tage → Mitteilung (Schwelle einstellbar; heute nur Farbe bei 3 Tagen).
60. **Verlauf je Projekt**, nicht nur Gesamtzahl: welches Projekt staut sich.
61. **PR-Details im Hover** direkt in der Liste, ohne Detail-Fenster.
62. **Commits seit Live nach Dateipfad filtern** (Monorepo: betrifft mich der Ordner `apps/web`?).
63. **Monorepo-Support:** Projekt ↔ Unterordner zuordnen; „geändert“ nur, wenn der Ordner betroffen ist (sonst Fehlalarm, Build-Minuten).
64. **Tags/Releases:** „Deploy dieses Tags“ statt Branch-Kopf.
65. **Vergleich Live ↔ Vorschau** (Diff-Größe, Dateien) vor dem Promote.

## E. Kosten (Kernversprechen ausbauen)

66. ★ **Kostenübersicht auch für Render** (Dienstpläne, Bandbreite, Build-Minuten soweit die API es liefert).
67. ✅ ★ **Budget-Grenze:** „Monatsbudget 50 $“, Mitteilung bei 80 %, Anzeige „Rest bis Limit“.
68. **„Was hätte Auto-Deploy gekostet?“:** Pushes × Preis pro Build gegen tatsächliche Builds, als Ersparnis-Zahl groß im Fenster.
69. **Teuerste Projekte** als Rangliste (heute nur kleine Zahl in der Zeile).
70. **Kosten pro Deploy in der Bestätigung** (steht in IDEEN-2 #46 als erledigt – für Sammel-Deploy als Summe fehlt sie).
71. **Zeitraum wählbar** (7/14/30/90 Tage), Monatsvergleich.
72. **CSV/PDF-Export** für Buchhaltung.
73. **Ersparnis-Karte teilen** (Bild mit Zahlen, ohne Projektnamen) für README/Posts.
74. **Warnung bei Projekten mit sehr vielen Builds pro Tag** (Bot-Schleifen, Dependabot).
75. **Ignored-Build-Step-Vorschlag direkt anwenden** (IDEEN-2 #50 nennt nur den Vorschlag).
76. **Kosten je Branch/Vorschau trennen**, soweit Vercels Daten es hergeben (heute ✗, evtl. über Deployment-Liste schätzen).

## F. Oberfläche

77. ✅ ★ **Demo-/Maskier-Modus:** Projektnamen und Repos unkenntlich oder durch Beispieldaten ersetzen – für Screenshots, Videos, README (das Repo ist öffentlich, der Screenshot zeigt echte Namen).
78. ✅ ★ **Tab, Filter, Sortierung, Fenstergröße merken** (alte #50, nie umgesetzt).
79. **Gruppen/Etiketten** („Kunde A“, „intern“) mit Farbe; Filter und Sammel-Auswahl pro Etikett.
80. **Gespeicherte Ansichten** („Nur Prod + Änderungen“).
81. **Pins per Ziehen sortieren.**
82. **Spalten-Tabelle** (alte #55) mit Sortierung nach Commits, Alter, Kosten, Dauer.
83. **Kompakte Zeile** (eine Zeile, Details beim Hover) für 50+ Projekte.
84. **Tastatur-Navigation komplett:** ↑↓, Leertaste anhaken, Return Details, ⌘A, ⌘⏎ deployen (teilweise da).
85. ✅ **Rückgängig für „Ausblenden“** (Toast mit „Rückgängig“).
86. ✅ **Ausgeblendete einzeln wieder zeigen**, nicht nur alle.
87. **Statusfarben nicht nur durch Farbe** (Form/Text zusätzlich; Rot/Grün-Schwäche).
88. **Dunkel/Hell prüfen** (alte #66): blaue/orange Balken mit `opacity` sehen auf Dunkel anders aus.
89. **Dynamic Type/große Schrift** testen; Zeilen haben feste `caption2`-Größen.
90. **Mehrzeilige Zeilen kürzen:** zu viele Abzeichen (Kosten, Commits, ältester, offen) → „Mehr…“-Aufklappen.
91. **Leerer Zustand mit Anleitung**, wenn das Konto 0 Projekte hat.
92. **Ladezustand je Zeile** (Skeleton) statt Gesamtspinner.
93. ✅ **Letzte Aktualisierung pro Plattform getrennt** im Kopf, nicht nur für den aktiven Tab.
94. ✅ **Menüleiste:** Spinner/Punkt bei laufenden Deploys, roter Punkt bei Fehler, Zahl getrennt nach Plattform.
95. **Menüleiste: direkt deployen** mit Bestätigung im Menü, ohne Fenster.
96. **Rechtsklick-Menü der Menüleisten-Einträge** (Seite öffnen, Log).
97. **Dock-Menü** mit „Alles deployen …“ und Liste der Projekte mit Änderungen.
98. **Globaler Tastenkürzel** für ein kleines Schnellfenster (Spotlight-artig: Projekt tippen → Return).
99. **Schnellsuche mit Befehlen** („deploy perch…“, „log …“).
100. **Mehrere Fenster** (eins pro Plattform) / Split-View.
101. **Fortschrittsbalken** mit echter Schätzung aus `usualMinutes` (heute nur Text).
102. ✅ **Toast-Stapel** statt einem Toast: bei Sammel-Deploys überschreibt jeder den vorigen nach 5 s.
103. ✅ **Toast-Verlauf** („Letzte Meldungen“ im Fenster).
104. **Onboarding-Rundgang** (Vercel/Render/GitHub verbinden, Ersparnis zeigen).
105. **Tooltips auf Deutsch/Englisch prüfen:** manche Hilfetexte sind nur ein Satz lang und tragen die ganze Erklärung.
106. **Zeilen-Doppelklick** öffnet Details.
107. **Drag & Drop eines Repo-URL ins Fenster** → „Projekt zuordnen“ (Behebt „Repo unbekannt“ ohne Terminal).
108. **„Repo unbekannt“ in der App reparieren** (Formular statt `deploys vercel map`).

## G. Automatisierung und Integration

109. ✅ ★ **URL-Schema `deploycenter://deploy?project=x&preview=1`** für Alfred/Raycast/Shortcuts.
110. ★ **App Intents / Kurzbefehle:** „Wartende PRs zählen“, „Projekt deployen“, „Alles Geänderte deployen“, Siri-fähig.
111. **Widget** (WidgetKit): Zahl wartender PRs, Mini-Verlauf.
112. **MCP-Server** über `deploys` (alte #94/#80, nie gebaut) – für Claude-Sitzungen.
113. **`deploys` als Homebrew-Formel** und Cask für die App.
114. **Slack/Discord/Teams-Webhook** nach Sammel-Deploy mit Release-Notes (Idee 53).
115. **E-Mail-/Push-Zusammenfassung am Abend** („heute 6 live, 2 offen“).
116. **launchd-Vorlage** für `deploys deploy-changed --yes` mit Log-Datei.
117. **GitHub-Action-Vorlage:** Deploy nach Merge mit Label `deploy` – ersetzt Auto-Deploy ohne Dauerbuilds.
118. **`deploys status --watch`** als Live-Ansicht im Terminal (Tabelle aktualisiert sich).
119. ✅ **`deploys diff <projekt>`** zeigt Commits/Dateien im Terminal.
120. ✅ **`deploys notes`** erzeugt Release-Notes (Idee 53) im Terminal.
121. **`deploys doctor --fix`**: bietet an, `jq`/`gh` zu installieren, Version zu aktualisieren.
122. **Exit-Codes dokumentieren** (0/1 heute; „nichts zu tun“ vs. „Fehler“).
123. **`--quiet`/`--verbose`** und konsistentes Protokollformat (JSON Lines) für Skripte.

## H. Plattformen und Konten

124. **Mehrere Vercel-Teams** nebeneinander statt `vercel team` umschalten.
125. **Mehrere GitHub-Orgs/Konten**; Ratenlimit je Konto.
126. **Netlify, Railway, Fly.io, Cloudflare Pages** über Anbieter-Module (alte #63/#85, weiterhin offen).
127. **GitLab/Bitbucket** (alte #64).
128. **Render-Blueprints/Umgebungsgruppen** anzeigen und Auto-Sync gezielt abschalten.
129. **Domain- und Zertifikats-Ablauf-Warnung** aus den Vercel/Render-Domains.
130. **Vercel-Cron-Jobs** und Render-Cron im Blick (letzter Lauf, Fehler).
131. **Umgebungsvariablen-Vergleich** zwischen Production und Vorschau (nur Namen, nie Werte).
132. **Fehlende Variable nach Deploy melden** (Namen aus `.env.example` im Repo gegen Plattform).
133. **Statusseiten von Vercel/Render/GitHub** einlesen und bei Störung warnen („Render hat gerade ein Problem“ statt eigener Fehlersuche).

## I. Qualität, Veröffentlichung, Pflege

134. ★ **GitHub Actions:** `build.sh`, `tests/*.sh`, shellcheck bei jedem Push (öffentliches Repo, kostenlos).
135. ★ **Tests für Zustandsmaschine:** `follow()` mit gefälschtem `Tool` (Protokoll `ToolRunning` einführen, damit testbar).
136. **Tool-Aufruf abstrahieren** (`Tool` ist ein `enum` mit statischen Funktionen; schwer zu mocken).
137. **Bats-Tests** gegen aufgezeichnete API-Antworten (Fixtures) für `pending_of`, `CHANGED_RULE`, Rollback-Wahl.
138. **`Store.swift` (532 Z.) aufteilen:** Queue, Cache, Marks (Pins/Notizen), Updater.
139. **`MainWindow.swift` (785 Z.)**: Banner in eigene Dateien/Views.
140. **Sparkle oder eigener Updater mit SHA-256-Prüfung** statt nur „Herunterladen“-Link.
141. **Swift 6 / strikte Nebenläufigkeit** stufenweise (Kommentar in `build.sh`: Swift 5-Modus).
142. **Lokalisierung in Tabelle** (`.strings`) statt `L(en, de)` im Code; danach Spanisch/Französisch möglich.
143. ✅ **Crash-/Fehlerprotokoll rotieren** (Größe begrenzen), Knopf „Diagnose kopieren“ (Version, macOS, Tool-Versionen, ohne Tokens).
144. **Rate-Limit-Backoff** für GitHub (nicht nur Pause unter 300 Resten).
145. **Offline-Banner** und Wiederholung mit Backoff statt Fehlerseite.
146. **Token-Sicherheit:** Render-Key mit eigener Schlüsselbund-Zugriffssteuerung; Hinweis, einen eigenen Key nur für die App anzulegen (alte #91).
147. **SBOM/Lizenzliste** und `SECURITY.md` (öffentliches Repo).
148. **README mit Screenshot** (mit Demo-Modus aus Idee 77 erzeugt) und GIF des Ablaufs.
149. **Landingpage + Kostenrechner** (alte #93).
150. **Issue-/PR-Vorlagen, CONTRIBUTING**.

## Empfohlene Reihenfolge

1. Fehler 1–5 (falsche Zahlen und falsche Alarme zerstören das Vertrauen in die App).
2. 43/44 (Claude-Prompt, Log-Sprung) – schnell gebaut, im Alltag sehr nützlich.
3. 77 (Demo-Modus) vor jedem weiteren Screenshot/Veröffentlichung.
4. 21/22/23 (Deploy-Sicherheit).
5. 134/135 (CI und testbare Zustandsmaschine), bevor weiter umgebaut wird.
