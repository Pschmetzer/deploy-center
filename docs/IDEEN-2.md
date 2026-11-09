# Deploy Center – Ideen, Runde 2 (Stand 0.4.0)

Gelesen: `deploys`, `app/DeployCenter.swift`, `build.sh`, README, die erste Liste (`IDEEN.md`).
Hier steht nur, was dort noch nicht steht oder sich durch 0.4.0 geändert hat.
★ = zuerst (echter Fehler oder großer Nutzen). Jeder Punkt nennt die Stelle im Code.

## A. Fehler, die beim Lesen aufgefallen sind

1. ✅ ★ **Render: ein gescheiterter Deploy versteckt die Änderungen.** `render_last_of` liest `deploys?limit=1`. Ist der neueste Deploy gescheitert, wird sein Commit zu `lastSha`, und das Projekt gilt als „ohne Änderungen“, obwohl live noch der alte Stand läuft. `lastSha` muss vom letzten *live* Deploy kommen, der Status vom neuesten Versuch.
2. ✅ ★ **Ein Deploy, der gerade woanders baut, wird nochmal angehakt.** `CHANGED_RULE` schließt laufende Deploys aus, liest bei Vercel aber nur `targets.production` (das ist immer der fertige Stand). Ein per CLI oder Dashboard gestarteter Build ist unsichtbar, und „Alle mit Änderungen anhaken“ startet ihn ein zweites Mal. Den neuesten Deploy (`/v6/deployments?projectId=…&limit=1`) dazu lesen.
3. ✅ ★ **Die Menüleiste wird nicht mehr aktuell, wenn das Fenster zu ist.** Die 15-Minuten-Schleife hängt an `.task` von `ContentView`; schließt man das Fenster, endet sie. Die Schleife gehört in den `Store` oder die App.
4. ✅ ★ **Startet die App ohne Fenster, lädt sie nie.** `store.start()` wird nur vom Fenster aufgerufen. „Neu laden“ in der Menüleiste ruft `autoRefresh`, das ohne `doctor` sofort zurückkehrt.
5. ✅ **„Alle mit Änderungen anhaken“ bleibt grau, wenn das Laden scheitert.** `fromCache` wird nur bei Erfolg gelöscht; nach einem Netzfehler bleibt der Knopf für immer aus.
6. ✅ **`vercel deploy` baut auch ohne Änderung.** Weder Skript noch App prüfen `changed` vor einem einzelnen Deploy. Ein Klick auf ein Projekt ohne neuen Commit kostet einen Build für nichts. Hinweis „Nichts Neues – trotzdem bauen?“.
7. ✅ **Vercel-Rollback nimmt `deployments[1]`**, den zweitneuesten fertigen Production-Deploy. Wurde vorher schon zurückgerollt oder ein älterer Deploy befördert, ist das nicht „der davor“. Die Alias-Zuordnung (`/v2/aliases`) oder `isRollbackCandidate` lesen.
8. ✅ (in release.sh) **`build.sh` bricht bei einem Netz-Aussetzer während `notarytool --wait` ab** (passiert am ersten Tag). Die Einreichung läuft bei Apple weiter, aber das Skript vergisst die ID. ID merken und `notarytool wait <id>` wiederholen, danach heften (staple).
9. ✅ **Der Pfad der GUI kennt kein nvm/volta/fnm.** `Tool.run` setzt PATH fest auf Homebrew und `~/.local/bin`. Wer `vercel` über nvm installiert hat, sieht „Vercel-CLI fehlt“. Einmal `zsh -lc 'echo $PATH'` lesen und übernehmen.
10. ✅ **`doctor` prüft nicht, ob `gh` angemeldet ist.** Ohne `gh auth` fehlen alle Zahlen still. Ein Feld `githubLoggedIn` und ein Hinweis in der App.
11. ✅ **GitHub-Grenze:** Pro Neuladen gehen etwa 3 Aufrufe pro Projekt an GitHub (Kopf, Vergleich, offene PRs). Bei 50 Projekten und alle 15 Minuten sind das rund 600 pro Stunde von 5000. Bei Überschreitung kommt `403` und die Zahlen verschwinden ohne Meldung. Rest-Kontingent lesen und anzeigen; mit ETag / `If-None-Match` abfragen (zählt bei 304 nicht).
12. ✅ **Offene PRs zählen Entwürfe und Bot-PRs mit** (`pulls?state=open`). Dependabot treibt die Zahl hoch. Getrennt zählen: „5 offen, davon 3 Entwürfe, 2 Bots“.
13. ✅ **Mehr als 250 Commits Abstand:** `pendingPRs` liest nur die 250 Commits, die GitHub listet; die Zahl ist dann zu klein. Als „mindestens“ kennzeichnen.
14. ✅ **Merge-Commits ohne PR-Nummer** (Rebase-Merges) werden nicht als PR gezählt. Über `commits/{sha}/pulls` zuordnen, wenn die Nachricht keine Nummer hat.
15. ✅ **`changed_json` ruft das Skript zweimal rekursiv** (`"$0" vercel json`, `"$0" render json`) nacheinander. Parallel starten spart etwa 10 Sekunden bei `deploys changed`.
16. ✅ **`deploy-changed --yes` startet alles auf einmal ohne Pause** und meldet Fehler nur auf stderr. Am Ende eine Zusammenfassung „8 gestartet, 1 Fehler“ und Exit-Code ≠ 0 bei Fehlern.
17. ✅ **Der Zwischenspeicher hat keine Version.** Ändert sich das JSON-Format, liest eine neue App einen alten Cache vielleicht falsch oder gar nicht. Version in den Dateinamen.
18. ✅ **Logos werden nach Domain gespeichert, nie gelöscht.** Domains, die es nicht mehr gibt, bleiben ewig liegen. Beim Start alles älter als 30 Tage löschen.
19. ✅ **Mitteilungen kommen nur, wenn die App nicht vorne ist** (`NSApp.isActive`). Wer im Fenster bleibt, aber in einem anderen Tab (Render statt Vercel) ist, sieht das Ende eines Deploys nicht. Ein kurzer Hinweis im Fenster selbst („my-site ist live“) fehlt.
20. ✅ **`pending_of` nutzt den Live-Commit als Basis.** Wurde der Branch neu geschrieben (Force-Push), gibt es den Commit nicht mehr; der Vergleich scheitert still, und es steht nur „Neue Änderungen“ ohne Zahl. Hinweis „Branch wurde umgeschrieben“.

## B. Was wartet (die neue Hauptfunktion ausbauen)

21. ✅ ★ **Liste der wartenden PRs pro Projekt** zum Aufklappen: Nummer, Titel, Autor, gemergt vor x Stunden, Link.
22. ✅ ★ **Ältester wartender Commit:** „wartet seit 3 Tagen“. Hilft zu sehen, was dringend live muss.
23. ✅ **Offene PRs pro Repo aufklappen**, mit CI-Status (grün/rot) und „bereit zum Mergen“.
24. **Mergen aus der App** für grüne PRs, mit Bestätigung. Danach direkt deployen.
25. ✅ **„Was ändert sich?“ vor dem Deploy:** geänderte Dateien und Zeilen (+/−) aus dem Vergleich in der Bestätigung.
26. ✅ **Hinweis auf riskante Änderungen:** Migrationen (`migrations/`, `prisma/`), `.env.example`, `package.json`-Abhängigkeiten im Vergleich → gelbes Schild.
27. ✅ (als Reihenfolge beim Deploy) **Gruppieren nach Repo:** ein Repo mit Vercel-Frontend und Render-Backend als ein Eintrag mit beiden Zielen.
28. ✅ **Verlauf der Zahl:** wie viele PRs am Tag gewartet haben, als kleine Linie. Zeigt, ob der tägliche Deploy reicht.
29. ✅ **CI-Status des Kopf-Commits** (Checks API) in der Zeile: nicht deployen, was auf GitHub rot ist.
30. ✅ **Kennzeichnung „nur Abhängigkeiten“:** wenn alle wartenden Commits von Dependabot/Renovate sind, kann das warten.

## C. Deployen

31. ✅ ★ **Warteschlange mit Grenze:** höchstens N Builds gleichzeitig (Vercel-Tarif-Grenze), der Rest wartet sichtbar „in der Schlange“.
32. ✅ ★ **Reihenfolge in Gruppen:** Backend (Render) zuerst, erst wenn es live ist, das Frontend (Vercel).
33. ✅ **Täglicher Deploy zur festen Zeit**, nur wenn ein Häkchen gesetzt ist und nur Projekte mit grünem CI. Mit Mitteilung und Bestätigung per Klick statt ganz automatisch.
34. ✅ **Deploy abbrechen**, solange er baut (Vercel `PATCH …/cancel`, Render `POST …/cancel`).
35. ✅ **Build-Log in der App** (letzte 200 Zeilen) beim Fehler, statt nur der Fehlermeldung.
36. ✅ **„Erneut versuchen“** direkt am gescheiterten Projekt.
37. ✅ **Nach dem Deploy prüfen:** die Seite aufrufen und HTTP 200 sowie die erwartete Commit-Kennung (falls ausgeliefert) bestätigen.
38. ✅ **Bestimmten Commit deployen** (Rechtsklick → Liste der letzten 10 Commits).
39. ✅ **Vercel-Vorschau als Link zum Teilen** kopieren, sobald fertig.
40. ✅ **Production-Beförderung:** eine fertige Vorschau per Klick live schalten (`promote`), statt neu zu bauen. Spart einen Build.
41. ✅ **Render: „Cache leeren und deployen“** als Option (`clearCache: clear`).
42. ✅ **Sperre gegen Doppelklick über Prozesse hinweg:** App und Skript schreiben eine kleine Sperrdatei pro Projekt, solange ein Deploy startet.
43. ✅ **Dauer pro Deploy merken** und beim nächsten Mal eine Schätzung zeigen („dauert meist 3 Min“).

## D. Kosten

44. ✅ ★ **„Gespart seit dem Abschalten“:** Builds pro Tag vor `offAt` gegen danach, in Dollar.
45. **Render-Kosten** (Bandbreite/Build-Minuten über die Render-API, soweit verfügbar) neben Vercel.
46. ✅ **Kosten pro Deploy schätzen** aus Dauer × Preis pro Minute, in der Bestätigung: „etwa 0,40 $“.
47. ✅ **Monatsprognose** aus den letzten 7 Tagen.
48. ✅ **Warnung bei Ausreißern:** ein Tag mehr als doppelt so teuer wie der Schnitt.
49. ✗ (Vercels Abrechnung trennt Vorschau und Live nicht) **Kosten auch für Vorschau-Deploys getrennt** zeigen.
50. ✅ **Ignored Build Step vorschlagen:** für Monorepos ein Befehl, der nur baut, wenn sich der eigene Ordner geändert hat.

## E. Oberfläche

51. ✅ ★ **Fenster schließen = App bleibt in der Menüleiste**, ohne Dock-Symbol (Einstellung).
52. ✅ ★ **Beim Anmelden starten** (`SMAppService`), Einstellung.
53. ✅ **Einstellungsfenster** (⌘,): Auto-Refresh-Intervall, Mitteilungen, Menüleiste ein/aus, Sprache.
54. ✅ **Ansicht „Alles“** mit Vercel und Render in einer Liste (bei „Nur mit Änderungen“ besonders nützlich).
55. **Spalten-Ansicht** (Table) mit sortierbaren Spalten: Name, Commits, PRs, letzter Deploy, Kosten.
56. ✅ **Fortschrittsbalken** für laufende Deploys statt nur Text.
57. ✅ **Leerer Zustand** bei „Nur mit Änderungen“ und null Treffern: „Alles ist live ✓“.
58. ✅ **Suchtreffer hervorheben.**
59. ✅ **Mehrfachauswahl mit Shift-Klick.**
60. ✅ **Projekt ausblenden** (Rechtsklick), z. B. alte Projekte; Liste der Ausgeblendeten in den Einstellungen.
61. ✅ **Favoriten** oben anheften.
62. ✅ **Eigene Notiz pro Projekt** („erst nach Absprache deployen“).
63. ✗ (die Listen kennen keine Umgebung, nur Production) **Farbe nach Umgebung:** Production rot umrandet, Staging grün.
64. ✅ **Menüleiste: Klick auf ein Projekt** öffnet das Fenster gefiltert auf dieses Projekt.
65. ✅ **Menüleiste: „Alles mit Änderungen deployen …“** mit eigener Bestätigung.
66. **Dunkel/Hell prüfen**, besonders der blaue Balken und die Logos auf Weiß.
67. ✅ **Logos mit transparentem Rand** passend hinterlegen (Bildhelligkeit messen).
68. ✅ **Zeilen-Tooltip mit Commit-Nachricht des Live-Stands** neben der neuesten.
69. ✅ **„Zuletzt aktualisiert vor x Min“ sichtbar** statt nur im Tooltip des Knopfs.
70. ✅ **Schrift- und Kontrast-Prüfung mit VoiceOver**: der Balken oben braucht eine Überschrift-Rolle.

## F. Kommandozeile und Automatisierung

71. ✅ ★ **`--json` bei jedem Befehl** einheitlich (heute `…-json`-Befehle und `changed --json` gemischt).
72. ✅ **`deploys status`** – eine Zeile pro Projekt mit laufenden Deploys.
73. ✅ **`deploys watch <projekt>`** – folgt einem Deploy im Terminal bis live/Fehler.
74. ✅ **`deploys logs <projekt>`** – Build-Log des letzten Deploys.
75. ✅ **`deploys open <projekt>`** – Seite oder Dashboard im Browser.
76. ✅ **`deploys cancel <projekt>`.**
77. ✅ **`deploys ignore <projekt>`** – aus `changed` und `deploy-changed` herausnehmen.
78. ✅ **Shell-Vervollständigung** (zsh, bash) mit Projektnamen aus dem Cache.
79. ✅ **Farbige Ausgabe** im Terminal (nur wenn `-t 1`).
80. **MCP-Server**, damit jede Claude-Sitzung `changed` und `deploy-changed` als Werkzeug hat.
81. **Kurzbefehle-Aktion** (Apple Shortcuts) „Wartende PRs zählen“ und „Alles deployen“.
82. **Raycast-Erweiterung** mit derselben Liste.
83. **Webhook/Slack-Nachricht** nach dem täglichen Deploy: was live ging.

## G. Konten und Plattformen

84. **Mehrere Vercel-Teams** in einer Liste (heute eines, `vercel team`).
85. **Netlify, Railway, Fly.io, Cloudflare Pages** über ein Anbieter-Modul im Skript.
86. **GitLab/Bitbucket** für Kopf, Vergleich und PRs.
87. **Linux:** `secret-tool` statt Schlüsselbund, `date -d` statt `date -v`, damit das Skript auf Servern läuft.
88. ✅ **Umgebungsvariablen `RENDER_API_KEY`/`VERCEL_TOKEN`** als Alternative zum Schlüsselbund (CI).

## H. Qualität, Veröffentlichung, Pflege

89. ✅ ★ **`release.sh`:** baut, notarisiert, heftet, legt das GitHub-Release mit Zip und SHA-256 an – ein Befehl.
90. ✅ ★ **Update-Hinweis in der App** über die GitHub-Releases-API (einmal am Tag, abschaltbar).
91. **Homebrew-Cask** im eigenen Tap.
92. ✅ **Tests für das Skript** (bats) mit nachgebauten API-Antworten; besonders `CHANGED_RULE` und `pending_of`.
93. ✅ **Unit-Tests für `waiting`, `merge`, `waitingText`, `compareURL`.**
94. **shellcheck in CI** (GitHub Actions, nur Lint, kein Deploy).
95. ✅ **Swift-Datei aufteilen** (1100 Zeilen): Tool, Modell, Store, Ansichten, Logos.
96. ◐ (kompiliert in Swift 6 ohne Fehler; Umstellung erst nach Laufzeit-Test, weil Swift 6 bei falscher Thread-Zuordnung zur Laufzeit abstürzt) **Swift-6-Modus**, die eine Warnung (`cacheDir`) war der Anfang.
97. **README mit Screenshot und kurzem GIF** der Menüleiste.
98. ✅ **CHANGELOG.md** und Versionsnummer im Fenster (Über-Dialog).
99. ✅ **Datenschutz-Absatz:** keine Telemetrie; Logos direkt von den eigenen Seiten; GitHub nur über die eigene `gh`-Anmeldung.
100. ✅ **Absturzbericht lokal** (letzter Fehler in `~/Library/Logs/DeployCenter.log`), zum Anhängen an ein Issue.
