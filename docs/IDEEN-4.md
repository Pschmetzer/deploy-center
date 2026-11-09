# Deploy Center – Ideen, Runde 4

Gelesen: `deploys` (741 Z.), alle Dateien in `app/`, Tests, CI, `build.sh`, CHANGELOG, die drei alten Listen (~450 Punkte) und der Screenshot.
Nur was dort noch nicht steht. ★ = zuerst. Stelle im Code in Klammern.
Ehrlich: ~170 Punkte, nicht 1000. Die alten Listen decken das Naheliegende ab; was hier steht, ist neu gefunden (A, B, D) oder neu gedacht (F, G).
Keine Projektnamen aus dem Screenshot, weil das Repo öffentlich ist.

## A. Neue Fehler in der App (beim Lesen aufgefallen)

1. ✅ ★ **Die Menüleisten-App bleibt tagelang bei alten Kosten.** `loadExtras()` läuft nur in `start()`. `autoRefresh()` lädt nur die Listen. `costs`, `triggers`, `providerIssues`, `githubBudget` und damit Budget-Alarm und Kostenleiste sind nach dem Start eingefroren. (`Store.start/autoRefresh`)
2. ✅ ★ **Die Störungs-Anzeige (Vercel/Render/GitHub) wird nie aktualisiert.** `checkProviders()` läuft einmal beim Start. Eine Störung, die um 14 Uhr beginnt, zeigt die App nicht; eine, die vorbei ist, bleibt als Banner stehen. Bei jedem Reload prüfen, die drei Abfragen parallel (heute nacheinander, je bis 10 s).
3. ✅ ★ **`checkSite` hält den Build-Platz fest.** Der Aufruf steckt in `follow()`, das in `deploy()` awaited wird. Bis zu ~70 s (3 × 20 s Timeout + 2 × 6 s Pause) bleibt `running` belegt, die Warteschlange stockt, ein Frontend wartet unnötig. Prüfung als eigene `Task` abkoppeln. (`Store.follow/checkSite`)
4. ✅ ★ **Nach einem Sammel-Deploy wird nicht neu geladen.** `set(.done)` schreibt `lastSha = headSha` aus dem Speicher. Kam inzwischen ein neuer Commit, zeigt die Zeile „aktuell“, bis der Timer nach bis zu 15 Min zuschlägt. Am Ende von `summarize()` einmal `load` für die betroffenen Plattformen.
5. ✅ **`autoRefresh` pausiert bei jedem laufenden Deploy komplett,** auch für die andere Plattform und auch bei einem Cron-Job, der 40 Min „läuft“. Dann bleibt die ganze Liste so lange alt. Nur die Plattform aussetzen, deren Zeile aktiv ist.
6. ✅ **Ein Rollback meldet „… ist live“.** `set(.done)` löst `say("… ist live")` aus, auch bei `countsAsLive: false` (Rollback, Vorschau). Das Journal sagt „other“, die Mitteilung sagt „live“. Eigene Texte: „zurückgerollt“, „Vorschau fertig“. (`Store.set`)
7. **Rollback geht an Warteschlange, Sperre und Bestätigung vorbei.** `rollback()` startet sofort, ohne `start_lock`, ohne Wartezeit, ohne Journal-Eintrag „rollback“ (nur „other“). Zwei Klicks = zwei Rollbacks nacheinander, der zweite geht auf den vorvorigen Stand.
8. ✅ (ungetestet: startet echte Builds) **Eine zweite Auswahl verlängert die Wartezeit der ersten.** `enqueue` setzt `holdUntil` neu. Wer 8 s nach dem ersten Klick noch ein Projekt startet, schiebt den ersten Deploy um weitere 8 s. Pro Job eigene Startzeit.
9. **Während der Wartezeit zeigt die Zeile „queued“ ohne Zähler.** Die Toast-Zeile verschwindet nach 5 s, die Wartezeit dauert womöglich länger (Einstellung). Zeile: „startet in 6 s“ als Countdown.
10. **`Task.sleep` in `follow` wirft bei Abbruch,** der `catch` in `deploy()` macht daraus „fehlgeschlagen“, obwohl nur die Aufgabe beendet wurde (App-Ende, Fenster zu bei manchen Pfaden). Abbruch getrennt behandeln, sonst schreibt das Journal falsche „failed“.
11. **Dauer-Statistik zählt nur Erfolge** (`recordDuration` nur bei `.done`). Ein Projekt, das meist nach 40 s scheitert, zeigt „dauert etwa 3 Min“ vom letzten Erfolg. Fehlschläge getrennt führen, „scheitert meist früh“ anzeigen.
12. **`building` kommt bei Vercel aus den neuesten 100 Production-Deploys aller Projekte** (`vercel json`, `limit=100`). Ein Projekt mit vielen Builds verdrängt die anderen; deren laufender Build fehlt, die Zeile wirkt „deploybar“, Doppelstart möglich. Pro Projekt `limit=1`, parallel, oder `since=` der letzten Stunde.
13. ✅ **Die Start-Sperre ist nicht atomar** (`start_lock`: erst prüfen, dann `touch`). App und Skript im selben Moment starten beide. `mkdir`/`set -C` als echte Sperre.
14. **Die Sperre gilt 60 s, ein Render-Cache-Build dauert Minuten.** Nach 61 s lässt sich dasselbe Projekt wieder starten, obwohl der erste Build läuft. Die Sperre gegen `building` prüfen statt gegen die Uhr.
15. **Zwei Listen für „nicht anzeigen“ mit Namen ohne Plattform** (`ignored.json` hat nur `name`). Ein Vercel-Projekt und ein Render-Dienst mit demselben Namen (üblich: `x-web`/`x-api` ist selten, `x` auf beiden dagegen oft) werden zusammen ignoriert.
16. **`remindIfDue` kennt Stunde 0 nicht** (`reminderHour` 0 = aus). Eine Erinnerung um Mitternacht ist nicht wählbar; außerdem feuert sie bis Tagesende, auch um 23:50 für den ganzen Tag. Fenster „zwischen 9 und 12 Uhr“.
17. **`checkBudget` vergleicht nur Build-Kosten mit dem Budget,** nicht die Gesamtrechnung (`days.map(\.build)`). Wer „Monatsbudget 50 $“ meint, meint meist alles. Umschalter „nur Builds / alles“.
18. **Die Hochrechnung nimmt 7 Tage × 30.** Ein Montag nach einem ruhigen Wochenende oder ein Release-Tag verzerren stark. Median statt Mittel, Wochentage getrennt, oder Monat-bis-heute plus Rest.
19. **Updateprüfung ohne Prüfung der Datei.** `checkForUpdate` liest nur `tag_name`; die App verlinkt zum Download ohne Hash-Anzeige. SHA-256 aus dem Release anzeigen (steht schon im Release-Text von `release.sh`).
20. **`Tool.searchPath` startet bei jedem App-Start eine Login-Shell** mit bis zu 3 s Wartezeit, noch bevor die Liste lädt. Ergebnis 24 h zwischenspeichern, Shell asynchron lesen.
21. **`Tool.run` nutzt `readDataToEndOfFile` im Haupt-Hintergrund-Thread pro Aufruf,** bei vielen parallelen Aufrufen (Status-Abfragen alle 6 s × N Deploys) entstehen viele Prozesse. Ein gemeinsamer Statusabruf (`deploys status --json`) für alle laufenden Deploys statt je einer.
22. **`Row`: `onTapGesture` auf der ganzen Zeile + Button im Inneren.** Ein Klick auf Kommentar-/Notiz-Text hakt versehentlich an. Nur die Checkbox und die Namenszeile klickbar machen.

## B. Skript (`deploys`)

23. ✅ ★ **`render_call` meldet bei HTTP 429 nur „HTTP 429“.** Retry mit `Retry-After`, sonst bricht die ganze Liste bei Rate-Limit ab. Dasselbe für Vercel (`vercel api` gibt den Header nicht zurück: Fehlertext auswerten).
24. **`render_services` und `vercel_projects` laden bei jedem Befehl neu.** `changed`, `status`, `completion` und die App rufen sie je mehrfach pro Minute. 60-Sekunden-Zwischenspeicher mit `mtime`, abschaltbar per `--fresh`.
25. **`platform_of` fragt erst Vercel, dann Render** (zwei Netzaufrufe für ein `watch`). Den Namen aus `names` (Cache) nehmen, falls schon bekannt, mit Plattform dazu: `vercel:name`.
26. **`names.tmp` wird nie aufgeräumt** und wächst; `sort -u` liest bei jedem Aufruf alles. Direkt `sort -u` mit Ersetzen, und Plattform-Präfix speichern (siehe 25).
27. **`doctor` schreibt `jq`-freies JSON mit `printf`,** aber `github-budget` und `changed` brauchen `jq`. Ohne `jq` zeigt `doctor` korrekt, `changed` stirbt mit kryptischer Meldung. Beim Start prüfen und klar sagen: „jq fehlt: brew install jq“.
28. **`vercel_deploy_json` bricht mit „no remembered repo“, wenn `auto` noch an ist** und kein Eintrag existiert. Besser: aus `link` lesen und merken (die Daten stehen im selben Projektaufruf).
29. **`vercel rollback` nimmt „READY“ Production ohne Prüfung,** ob dieser Deploy einen anderen Stand ausliefert. Ein Rollback auf einen gleichen Stand (nach einem Redeploy ohne Änderung) tut nichts. Beim Auswählen den `githubCommitSha` überspringen, der dem aktuellen gleicht.
30. **`render rollback` nimmt den ersten `deactivated`,** das kann ein fehlgeschlagener oder ein Vorschau-Deploy sein. Nur mit `commit.id` ≠ aktuell und `status` einmal `live` gewesen.
31. **`diff`/`notes` rufen `"$0" "$plat" json` auf,** das lädt alle 55 Projekte, nur um eines zu lesen. Ein `--only <name>` im JSON-Befehl.
32. **`triggers` zählt Render-Deploys mit `deploy_hook` als „fremd“,** obwohl der Nutzer selbst einen Hook (Siri-Kurzbefehl, Cron) angelegt haben kann. Eigene Hooks als „bekannt“ markierbar.
33. **`costs` rechnet Tage in UTC,** die App zeigt sie als lokale Tage. Nach Mitternacht (Berlin) stimmen „heute“ und „gestern“ nicht. Zeitzone mitgeben oder beschriften.
34. **`workflow_hits` liest Workflows ohne Seitenwechsel und ohne Unterordner** (`contents/.github/workflows` listet bis 1000, ok; aber `grep` auf Kommentarzeilen ignoriert Kommentarzeilen nur mit `#` am Zeilenanfang, nicht am Zeilenende). Vermutung, nicht getestet: kann Treffer in auskommentierten Zeilen melden.
35. **`completion` verlangt `eval` im Profil,** `compadd` ohne Beschreibungen. `deploys completion --install` schreibt die Datei nach `~/.zsh/completions`.
36. **`die` in `$(…)` beendet nur die Unterschale.** Es klappt heute, weil `set -e` auf der reinen Zuweisung (`id="$(render_id_of …)"`) greift. Sobald jemand `local x="$(…)"` oder `echo "$(…)"` schreibt, schluckt das den Fehler (so ein Muster gibt es im Skript noch nicht, geprüft per grep). Regel in CONTRIBUTING und `shellcheck`-Warnstufe (SC2155) als Schutz.
37. **Fehlermeldungen sind englisch und kommen roh in die App** (`HTTP 401: {…}` als JSON-Text). Die App kennt keine Fehlernummern. Klartext-Mapping: 401 → „Anmeldung abgelaufen“, 404 → „gibt es nicht mehr“, 429 → „Limit erreicht, gleich nochmal“.
38. **`DEPLOYS_CONFIG` ist nur eine Umgebungsvariable.** Für Tests praktisch, für zwei Konten (Privat/Firma) wäre `--profile work` bequemer; je Profil eigener Schlüsselbund-Eintrag und eigene Vercel-Team-ID.
39. **`deploys changed --since 6h`** und **`--platform render`** als Filter, damit Skripte nicht jq-Gymnastik brauchen.
40. **`deploys json` für alles** (ein Aufruf für beide Plattformen, wie die App ihn bräuchte statt zweier getrennter Prozesse mit doppelter GitHub-Last).
41. **`deploys explain <projekt>`** sagt in einem Satz, warum ein Projekt „changed“ ist oder nicht („Live-Stand abc123, Branch def456, 4 Commits, Build läuft nicht“). Spart beim Debuggen der CHANGED_RULE jede Menge Zeit.
42. **Selbsttest `deploys doctor --deep`:** schreibt nichts, startet nichts, prüft aber einmal Token-Rechte (Vercel `/v2/teams`, Render `/services?limit=1`, GitHub `rate_limit`) und meldet pro Zugang „ok / abgelaufen / zu wenig Rechte“.

## C. Deploy-Ablauf

43. ★ **Zwischenspeicher für den Live-Check nach dem Deploy: Commit-Kennung prüfen.** Die Seite antwortet 200, liefert aber noch die alte Version (CDN, Render-Umschaltung). Per `x-vercel-deployment-url`-Header bzw. `/version`-Pfad gegen den Ziel-Commit vergleichen, bis ≈ 2 Min.
44. ★ **Deploy-Reihenfolge nach Abhängigkeiten, die man selbst festlegt** (alte #40 nennt es, hier die kleinste Version): eine Textdatei `~/.config/deploys/order` mit Zeilen `render:api -> vercel:web`.
45. **„Erst alles Rote beheben“-Schutz:** wenn ein Deploy in der Sammelaktion scheitert, Rest der Warteschlange pausieren und fragen („Weiter / Stopp“), statt alle anderen blind zu starten. Bei Migrationsfehlern spart das Geld und Daten.
46. **Pro Projekt eine Standardart wählen:** „Vorschau zuerst“, „mit leerem Cache“, „nur freitags nicht“. Heute sind das Einzelschalter im Menü.
47. **Deploy mit Kommentar:** ein Textfeld „Warum?“ im Bestätigungsdialog, das ins Journal und in die Release-Notes wandert.
48. **Wiederholung bei Netzfehler beim Start:** `deploy-json` scheitert bei einem Aussetzer sofort und das Journal sagt „failed“. 2 Wiederholungen mit Pause, nur wenn nachweislich nichts gestartet wurde (Sperre liegt noch).
49. **Mehrere Branches pro Projekt:** Vorschau eines PR-Branches deployen, ohne Namen zu tippen (Liste der offenen PRs aus `details` ist da).
50. **„Deployt dieser Commit schon?“-Suche:** Commit-Hash oder PR-Nummer eintippen, die App sagt, ob und seit wann es live ist (Repo + `lastSha` + `compare`).
51. **Live-Vorschau-Vergleich:** Vorschau-URL und Production nebeneinander im Fenster (iFrame/Screenshot), bevor man produktiv geht.
52. **Geplanter Rollback-Zeitpunkt:** „wenn bis 18 Uhr Fehlerquote steigt, zurück“. Braucht Fehlermessung (Vercel Runtime Logs / Render Logs) – bisher nicht gelesen.
53. **Notbremse für Sammel-Deploys per Mitteilung:** „7 Deploys laufen – Stopp“ als Aktionsknopf in der Mac-Mitteilung (heute nur Text).
54. **Gleicher Commit zweimal:** wenn `lastSha == headSha`, das Menü „Erneut deployen“ trotzdem anbieten, aber mit Warnung „baut denselben Stand“.
55. **Deploys, die Vercel „übersprungen“ hat, als eigene Statistik:** wie oft hat der Ignored Build Step gespart? Das zeigt, wie viel das Setup bringt, und es sind echte eingesparte Minuten.
56. **Deploy-Sperre pro Branch-Schutz:** wenn GitHub am Branch „Required Checks“ hat und der Kopf rot ist, den Knopf grau machen und den Grund zeigen.
57. **„Danach öffnen“:** nach erfolgreichem Deploy die Seite im Browser öffnen (Einstellung pro Projekt), sonst klickt man immer selbst.
58. **Deploy aus der Mitteilung:** Die tägliche Erinnerung bekommt den Knopf „Jetzt deployen (7 Projekte)“, der die Bestätigung im Fenster öffnet.

## D. Oberfläche (aus dem Screenshot und dem Code)

59. ✅ ★ **„1 Projekte bauen bei jedem Push“.** Plural-Fehler im Banner (`MainWindow.swift:369`). `Projekt`/`Projekte`, `project`/`projects`. Prüfen, wo noch `\(n) PRs`, `\(n) Commits` ohne Einzahl steht.
60. ★ **Drei Projekte desselben Repos wiederholen dieselbe Zeile:** „107 Commits · 107 PRs warten · 14 offene PRs“ steht dreimal untereinander. Nach Repo gruppieren: eine Kopfzeile „owner/repo – 107 Commits“, darunter die Dienste mit eigenem Status. Spart Platz und zeigt die Bindung Frontend ↔ Backend.
61. ★ **Zu viele Abzeichen pro Zeile:** Letzter Deploy, Commits, PRs, ältester Commit, offene PRs, Kosten, Status. Bei schmalem Fenster bricht „ältester wartender Commit vor 6 Stunden“ auf zwei Zeilen. Dichte-Regler (Kompakt/Normal/Ausführlich) und feste Spalten.
62. ★ **Nur ein Wert pro Zeile hervorheben:** „wartet seit …“ oder „X PRs“, nicht beides gleich laut. Das Auge sucht „was ist dringend“.
63. ✅ **Die Suche hat beim Start den Fokus mit großem blauem Rahmen.** Das lenkt ab und fängt Tastatureingaben (Leertaste zum Anhaken geht nicht, solange der Fokus im Suchfeld ist). Fokus erst bei ⌘F.
64. **Cron-Jobs stehen in der Deploy-Liste wie Dienste** („Zuletzt deployt vor 1 Tag · 107 PRs warten“). Ein Cron-Job „deployt“ nur, damit neue Version läuft; die 107 sind nicht seine. Eigene Gruppe „Cron/Worker“ mit „nächster Lauf“, „letzter Lauf“.
65. **Tab „Alle“ ohne Plattform-Kennung am Namen** (nur kleiner Kreis-Buchstabe im Logo). Plattform als Text-Chip „Vercel“/„Render“ zeigen, wie es auch Farbenblinde brauchen.
66. **Fortschritt „baut · 1:05“ zeigt Zeit, nicht „von etwa“.** `usualMinutes` ist da: „baut · 1:05 von ≈ 2:30“ mit Balken.
67. **Banner „252 PRs warten“ ist eine riesige Zahl ohne Bezug.** Dazu „davon älter als 2 Tage: 31“, „aus Abhängigkeiten: 40“. Ein Klick auf „Anzeigen“ listet nach Projekt.
68. **„Auto-Deploy ausschalten“ ohne Vorschau, was passiert.** Der Knopf soll zuerst zeigen: „Betrifft 1 Projekt: …, Vercel-Git-Verbindung wird getrennt, Repo wird gemerkt, Rückweg: `autodeploy-on`“ (gibt es noch nicht, siehe 114).
69. **Fenster-Mindestgröße** auf das Banner-Layout abstimmen; bei 600 px Breite sind die Zeilen unlesbar.
70. **Die Statistikspalte „Stand 0:48“ (Uhrzeit)** ist missverständlich (Stand wovon?). „Aktualisiert 0:48“ oder „vor 2 Min“, Tooltip mit Quelle (Cache/Live).
71. **Bei Fehlern in einer Plattform steht nur ein roter Text im Tab.** Eigene Zeile „Render: Key abgelaufen – erneuern“ mit Knopf.
72. **Filterleiste speichert „Nur mit Änderungen“ nicht pro Tab** (nur global).
73. **Zeilen-Rechtsklickmenü ist lang** (Vorschau, Commit wählen, Cache leeren, Notiz, Pin, Ausblenden …). Gruppieren und Tastenkürzel anzeigen.
74. **Doppelklick auf eine Zeile öffnet die Details** nicht (Idee 106 offen); Leertaste = Quick-Look-Fenster mit Commits, so wie im Finder.
75. **Sortierung „Wartezeit“ (älteste zuerst)** ergänzen, die Reihenfolge „Änderungen nach Commits“ trifft nicht „was brennt“.
76. **Zähler im Tab („Vercel 35“) zeigen Gesamtzahl,** nicht die mit Änderungen. Zweiter Wert klein dahinter: „35 · 9“.
77. **Beim Anhaken nach „Deploy“ zeigt der Knopf nur „Deployen“.** „7 deployen (≈ 12 Min, ≈ 1,40 $)“ direkt auf dem Knopf, Idee 24 (alte Liste) in kleinster Form.
78. **Dunkelmodus:** der orangefarbene Banner „Jeder Push kostet Build-Minuten“ hat im Screenshot gutes Kontrastverhältnis; die graue Zeile „Projekte anhaken, die live gehen sollen“ unten ist kontrastarm. Kontrast prüfen.
79. **Sprache pro App wählbar,** nicht nur vom System. Nutzer mit englischem Mac, deutschen Projekten (und umgekehrt) wechseln sonst nur per Systemeinstellung.
80. **Zeitangaben gemischt:** „vor 1 Tag“, „vor 6 Stunden“, „1:05“. Einheitliche Relativzeiten, Tooltip mit exakter Zeit (teils schon da).
81. **Menüleistensymbol: Zahl der Projekte mit Änderungen,** zusätzlich ein Strich/Punkt wenn Auto-Deploy irgendwo noch an ist (das kostet Geld).
82. **Fenster merkt sich Scroll-Position** nach einem Neuladen; heute springt die Liste nach oben, wenn die Reihenfolge sich ändert (Sortierung nach Commits verschiebt Zeilen während man klickt). Zeilen während Interaktion nicht umsortieren.
83. **Tastatur: ↑/↓ Auswahl, Leertaste anhaken, Return Details** (Idee 84 „teilweise“): Fokusring für Zeilen sichtbar machen, VoiceOver-Rotor-Aktionen.

## E. Kosten und Zahlen

84. ★ **„Was hätte Auto-Deploy gekostet?“ aus echten Zahlen:** Anzahl Pushes (GitHub `commits` pro Tag) × durchschnittlicher Build-Preis gegen tatsächliche Builds. Das ist die Zahl, die man jemandem zeigt.
85. **Kosten je Plattform in einer Zeile** („Vercel 6,40 $ · Render 31 $/Monat“): Render-Preise stehen im Dienst (`plan`), die Rechnung nicht, aber Monatspreis × Dienste ist eine brauchbare Näherung.
86. **Pausierte Render-Dienste als Sparpotenzial:** „3 Dienste laufen, haben seit 30 Tagen keinen Deploy und keine Anfrage“ (Render-Metriken-API) – Vorschlag, anzuhalten oder zu löschen.
87. **Teuerste Deploys der Woche** als kleine Rangliste, mit Link in die Details.
88. **Kostenkurve mit Markern:** Pfeile an den Tagen, an denen Auto-Deploy abgeschaltet oder wieder angeschaltet wurde (`offAt` ist bekannt).
89. **Kostenalarm als Mitteilung mit Grund:** nicht nur „Kosten hoch“, sondern „Tag X: 14 Builds von Projekt Y“. Die Daten (`projects`) sind da.
90. **Build-Minuten statt nur Dollar** zeigen; Dollar ändern sich mit dem Tarif, Minuten nicht.
91. **Zeitzone der Kosten als Spalte „heute“** (siehe 33).
92. **CSV-Export mit den Spalten Projekt/Datum/Builds/Kosten** (Export gibt es, Spalten prüfen) und optional als Datei in einem Ordner, den Buchhaltung abholt.
93. **Selbsttest der Preise:** `costs` meldet `currency: "USD"` fest; bei Teams mit EUR-Abrechnung anzeigen, was die API liefert.
94. **Kosten-Ausreißer pro Projekt, nicht nur pro Tag:** „Projekt Y baut 5× mehr als im Schnitt“.

## F. Neue Funktionen für Nutzer (kreativ, aber im Zweck der App)

95. ★ **Tagesabschluss („Feierabend-Zusammenfassung“):** 18 Uhr eine Mitteilung „Heute live: 6 · Offen: 2 (ältester seit gestern) · Kosten heute: 1,10 $“ mit Knopf „Offene deployen“. Verbindet Erinnerung, Journal und Kosten, was heute getrennt ist.
96. ★ **„Was ist neu für Kunden?“:** aus den PR-Titeln (Release-Notes gibt es) eine zweite Ausgabe in einfacher Sprache, per Sprachmodell optional (Eigener Schlüssel, nie standardmäßig): „Bessere Suche; Fehler beim Export behoben“. Für Changelogs und Updates an Kunden.
97. **Deploy-Zeitplan als Kalenderansicht:** Wochenraster, Einträge „Frontend 14:00 – automatisch, wenn CI grün“ (Idee 26, aber als Oberfläche, nicht als Liste).
98. **Wöchentlicher Bericht als Markdown/PDF:** Deploys, Fehlerquote, Kosten, ältester Wartezustand, Vergleich zur Vorwoche. Eine Datei, die man ablegt oder an Auftraggeber schickt.
99. **„Ruhiger Modus“:** nur Fehler melden, nichts anderes (keine „ist live“-Mitteilung), dazu „nicht stören nach 20 Uhr“.
100. **Fokus-Ansichten wie in Mail:** „Heute zu deployen“ (Änderungen, CI grün), „Wartet auf jemanden“ (Notiz gesetzt), „Beobachten“ (Pin). Gespeicherte Ansichten (Idee 80) mit Vorlagen.
101. **Notiz mit Erinnerung:** „Notiz bis Freitag“ blendet die Zeile bis dahin aus der Deploy-Auswahl aus und holt sie danach wieder.
102. **Sprechblasen-Verlauf je Projekt:** was wurde wann deployed, von wem, welche Version – als Zeitleiste in den Details, nicht nur im globalen Journal.
103. **Live-Aktivitäten / Dynamic Island auf dem iPhone:** der Deploy-Fortschritt als Live Activity (braucht eine iOS-Begleit-App, daher größer; lohnt, wenn man oft unterwegs deployt).
104. **iPhone-Widget (und Mac-Widget):** Zahl wartender PRs, Knopf „Alle ansehen“. Daten kommen aus dem App-Zwischenspeicher, kein neuer Server nötig.
105. **Siri/Kurzbefehle:** „Wie viele Deploys warten?“ liest die Zahl vor (App Intents, Idee 110 alt) – hier als Sprachaufgabe formulieren.
106. **Fokus-Filter von macOS:** im Fokus „Arbeit“ die Menüleiste zeigen, im Fokus „Frei“ nichts melden.
107. **Teilen-Menü auf Zeilen:** „Release-Notes teilen“ → Mail, Nachrichten, Slack als Text. Heute nur kopieren.
108. **„Stand wie vor einer Woche“-Schalter:** Zeit zurück: zeigt, was vor 7 Tagen live war und was seitdem live ging (aus Journal + Git-Verlauf).
109. **Mini-Dashboard-Modus:** nur Ampeln pro Projekt (grün/gelb/rot) auf einem zweiten Monitor, ohne Bedienelemente, groß lesbar.
110. **Statusseite für Kunden aus dem Journal:** eine statische HTML-Seite „Zuletzt veröffentlicht: …“, die man in sein Projekt legt. Journal ist da, Veröffentlichung ist der Schritt.
111. **Gamification light:** Serie „7 Tage ohne Auto-Deploy“, „Gesparte Minuten“ als Zähler. Klein, in den Einstellungen abschaltbar, motiviert zum täglichen Deployen.
112. **Sprachausgabe/Ton bei Fehlern** (Systemton, abschaltbar), damit ein roter Deploy im Nebenfenster nicht untergeht.
113. **Menüleiste mit Mini-Fortschritt:** statt Zahl ein Ring, der sich füllt, solange Deploys laufen.
114. **`autodeploy-on` in der App** („Wieder verbinden“) für Projekte, die man doch automatisch haben will (alte #44 offen; hier als Knopf in der Zeile, ein Klick, mit Hinweis auf Kosten).
115. **Projekt-Vorlagen:** Neues Vercel-Projekt in der Liste → App fragt „Auto-Deploy gleich ausschalten?“ (neue Projekte starten mit Git-Verbindung und kosten ab dem ersten Push).
116. **Wächter für neue Projekte:** Die App merkt, wenn auf Vercel/Render ein neues Projekt mit Auto-Deploy erscheint, und meldet es („Neues Projekt `foo` baut bei jedem Push“).
117. **Einmal-Tour im Fenster („Was ist neu in 0.x“)** nach einem Update, mit den 3 wichtigsten Änderungen aus dem CHANGELOG.
118. **Befehlspalette ⌘K:** „deploy x“, „rollback y“, „öffne Log von z“, „zeige Kosten“, Fuzzy-Suche, Verlauf. Ein Eingabefeld statt vieler Menüs.
119. **Globaler Hotkey** für die Befehlspalette (Idee 98 alt, hier mit ⌘K als Ziel).
120. **Eingebaute Hilfe mit Beispielen:** Kleiner Abschnitt „Warum deployen von Hand?“ mit Rechnung, damit neue Nutzer die App verstehen, ohne das README zu lesen.
121. **Sicherer Probelauf („Trockenübung“):** alles wie echt, nur dass die Start-Aufrufe durch eine Pause ersetzt werden; zum Einüben und für Screenshots (Demo-Modus gibt es, aber ohne Ablauf).
122. **Merkzettel „nach dem Deploy“** pro Projekt: Checkliste („Cache leeren, Kunde informieren“), die nach dem Erfolg erscheint und abgehakt werden muss.
123. **Auto-Kommentar im PR:** nach dem Deploy „Live seit 14:32“ als Kommentar an die enthaltenen PRs (GitHub-API; nur mit Zustimmung, Standard aus).
124. **GitHub-Release/Tag automatisch setzen** nach erfolgreichem Production-Deploy (Version `2026-11-10.1`), mit den Release-Notes.
125. **Rollback-Vorschau:** Vor dem Zurückrollen zeigen, welche PRs dadurch „wartend“ werden und welche Datenbank-Migrationen dabei hängen könnten (riskante Dateien kennt die App).
126. **Verwandte Projekte:** App erkennt (gleiches Repo, gleiche Domain-Wurzel) „Frontend/Backend/Cron“ und baut Gruppen automatisch; manuell überschreibbar (alte #27 hatte nur das Repo).
127. **Statusfarbe der Domain:** TLS-Ablauf in Tagen, DNS erreichbar? (Idee 129 alt nennt Ablauf; hier als Ampel in der Zeile, einmal am Tag geprüft).
128. **Echte Verfügbarkeit:** Der Live-Check läuft nicht nur nach dem Deploy, sondern einmal pro Stunde als Mini-Monitor; bei Ausfall eine Mitteilung. Ersetzt für kleine Projekte einen Uptime-Dienst.
129. **Anbindung an Fehlermelder (Sentry u. ä.):** nach dem Deploy neue Fehler-Gruppen seit Release anzeigen; bei Anstieg „Zurückrollen?“ anbieten.
130. **Slack/Teams-Befehl:** `/deploy status` aus dem Chat (Server nötig; als optionales Beispiel-Skript, nicht Teil der App).
131. **Geplante Wartung:** Zeitfenster „Dienstag 3 Uhr“, in dem Deploys erlaubt sind, mit Hinweis außerhalb (Idee 25 alt als Sperre; hier als Erlaubnis-Fenster).
132. **„Wer hat zuletzt geändert?“:** pro Projekt der Autor des Kopf-Commits, damit man bei Unklarheit gezielt nachfragen kann (Daten aus `details` da).
133. **Zufriedenheits-Telemetrie lokal:** App zählt, wie oft man „Abbrechen“ in der Wartezeit drückt (Fehlklicks) und schlägt eine längere Wartezeit vor. Bleibt auf dem Mac.

## G. Plattformen, Konten, Team

134. **Mehrere Konten als Profile** (siehe 38): Privat/Firma als Reiter oben, je eigener Vercel-Login, Render-Key, GitHub-Konto.
135. **Nur lesen („Beobachter“-Modus):** Das Gerät zeigt Zahlen, startet nie etwas. Für einen Zweitrechner oder einen Kollegen mit Lesezugriff.
136. **Gemeinsame Konfiguration im Repo** (`deploy-center.json`): Zuordnung Projekt → Repo/Ordner, Reihenfolge, Gesundheitspfade, Schwellen. Teammitglieder bekommen dasselbe Verhalten (Idee 67 alt, hier mit Dateiformat).
137. **Netlify als erster zusätzlicher Anbieter** (offene Idee 63): einfachste API, Deploy-Auslösen und Status wie Vercel; Modul-Schnittstelle: `list`, `deploy`, `status`, `cancel`, `rollback`.
138. **Fly.io/Railway/Cloudflare Pages** danach; jeweils nur wenn `list/deploy/status` in einer Datei von unter 100 Zeilen geht.
139. **Deploy-Hooks als Anbieter:** jede URL, die ein Build startet (z. B. selbst gehostet), als „Dienst“ ohne Status, nur mit Auslösen und Journal.
140. **GitHub Enterprise Server:** `gh` mit Host; Basis-URL einstellbar.
141. **GitLab** (offene Idee 64): `glab`-Entsprechungen für Kopf, Vergleich, MR.
142. **Branch pro Projekt wählbar statt `main`** (Vercel-Standardbranch kommt aus `productionBranch`, das Skript hat bei `vercel json` `ref:"main"` für nicht erkannte).
143. **Monorepo-Pfad** (alte #63) in kleinster Form: pro Projekt eine Pfadliste, `compare` zählt nur Dateien darin. Entscheidet, ob ein Projekt überhaupt „Änderungen“ hat.
144. **Vercel-Teams: Team-Auswahl als Menü** in der App statt `vercel team` (Idee 61 alt, hier konkret: `/v2/teams` liefert alles).
145. **Rechteprüfung beim Verbinden:** nach Eingabe des Render-Keys prüfen, ob er nur lesen oder auch deployen kann, und das sagen („Dieser Key kann nicht deployen“).
146. **Token-Rotation-Erinnerung:** Render-Keys und gh-Tokens laufen nicht ab, aber man will sie rotieren; Erinnerung nach 90 Tagen (Datum beim Speichern merken).
147. **Anmeldung per OAuth statt CLI:** langfristig die `vercel`-CLI-Abhängigkeit loswerden (Node, Login-Zustand, CLI-Änderungen wie `--dangerously-skip-permissions`) und die REST-API direkt mit Token aufrufen. Schneller (kein Node-Start pro Aufruf, siehe 21) und weniger anfällig.

## H. Qualität, Tests, Veröffentlichung

148. ★ **Tests für die Fehler aus A/B:** `checkSite`-Wiederholungen (mit Mock-URLSession), `holdUntil`-Verhalten, `set()`-Texte bei Rollback/Vorschau, `waiting` mit gemischten Plattformen, `start_lock` unter Wettlauf (zwei Prozesse).
149. **Fixtures für `pending_of`:** aufgezeichnete GitHub-Antworten mit Squash-, Merge-, Rebase-Merge, Force-Push, 250+ Commits. Test prüft Zählung exakt.
150. **`tests/script-tests.sh` mit `shellcheck --severity=warning`** statt nur `error`; die Stellen aus 36 (`local x="$(…)"`) würden auffallen.
151. **Swift-Tests ohne `main.swift`-Trick:** ein Swift-Paket mit Testtarget (`swift test`). Heute werden Quellen und Tests per `swiftc` zusammengesetzt; Neues in `App.swift` bleibt ungetestet.
152. **Snapshot-Tests der Zeile** mit vielen Abzeichen in Hell/Dunkel/große Schrift; fängt Layout-Brüche wie im Screenshot (Umbruch „ältester Commit …“).
153. **UI-Test für das Banner-Plural** („1 Projekt“): ein Test, der alle `L(…)`-Texte mit `\(n)` auf 0/1/2 durchspielt.
154. **Lokalisierungs-Linter:** prüft, dass jeder `L(en, de)` beide Texte hat und die gleichen Platzhalter.
155. **Release: `release.sh` prüft CHANGELOG-Eintrag** und lehnt ab, wenn „Unreleased“ leer ist oder die VERSION schon getaggt ist.
156. **Reproduzierbarer Build:** `build.sh` schreibt die Compiler-Version und Commit-Hash in `Info.plist` (Über-Dialog und „Diagnose kopieren“ zeigen sie).
157. **Abstürze abfangen:** `NSSetUncaughtExceptionHandler` schreibt in `DeployCenter.log` (Log gibt es, aber nur für Skriptfehler, nicht für App-Abstürze).
158. **Datenschutz-Test:** Ein CI-Schritt, der `grep`t, dass kein Projektname, keine Team-ID und kein Pfad aus dem eigenen Konto im Repo steht (das steht meist fest, wird aber leicht vergessen; Docs wie diese hier zählen mit).
159. **Dokumentation: „Wie die App zählt“.** Eine Seite, die `CHANGED_RULE`, Gruppen pro Repo, „wartet“, „offen“ erklärt; die Zahlen sind das Vertrauenskapital der App, und sie sind aus dem Code nicht leicht abzulesen.
160. **Beispielkonfigurationen** für drei Setups (nur Vercel, nur Render, beides + Monorepo) in `docs/`, jeweils mit erwarteter Ausgabe von `changed`.
161. **Barrierefreiheits-Prüfung per `accessibilityAudit`** in einem UI-Test (Xcode 15+) für Hauptfenster und Einstellungen.
162. **Sparkle-Update mit EdDSA-Signatur** statt „Herunterladen“-Link (Idee 140 alt, hier mit Begründung: Hash-Prüfung ersetzt Vertrauen in GitHub-Zugang).
163. **Homebrew-Cask-Tap** mit automatischem Update durch die Release-Action.
164. **Issue-Vorlage „Zahl stimmt nicht“** mit Feldern: Projekt (anonymisiert), `deploys changed --json`-Ausschnitt, erwartete Zahl. Die häufigste Art Fehler dieser App.
165. **`deploys doctor --report`** erzeugt einen anonymisierten Bericht (keine Namen, keine IDs) zum Anhängen an Issues; der Knopf „Diagnose kopieren“ in der App nutzt dasselbe.
166. **Performance-Messung:** Zeit pro Befehl (`changed`, `vercel json`, `render json`) ins Log schreiben, damit „die App ist langsam“ eine Zahl hat und GitHub-Aufrufe pro Reload sichtbar werden.
167. **Fehlerbudget für GitHub:** die App zeigt bei Reload „verbraucht 38 von 5000“, nicht nur „noch 4870“; Verbrauch pro Reload ist die Zahl, an der man Optimierungen misst.
168. **Zwei-Stufen-Reload:** erst die billige Liste (Plattformen), sofort anzeigen, danach die GitHub-Zahlen nachladen und Zeilen einzeln füllen; passt zu Idee 92 alt (Skeleton) und macht die App beim Start „sofort da“.
169. **Zwischenspeicher mit Alter:** Zeilen mit GitHub-Zahlen älter als 15 Min grau darstellen („Stand 14:05“), damit man nie veralteten Zahlen traut.
170. **Wöchentlicher Selbstcheck als Mitteilung:** „Diese Woche kein Auto-Deploy-Build gefunden ✓“ (aus `triggers`), gibt Ruhe statt Alarm.

## Empfohlene Reihenfolge

1. **A1, A2, A4:** App in der Menüleiste zeigt sonst veraltete Kosten, Störungen und Stände.
2. **A3, A12, A13:** Warteschlange und Doppelstart – kostet direkt Geld.
3. **D59–D62:** Plural-Fehler, Zeilen nach Repo gruppieren, weniger Abzeichen. Sieht man sofort im Screenshot.
4. **B23, B37:** Rate-Limits und verständliche Fehler.
5. **E84 (Ersparnis) und F95 (Tagesabschluss):** das Versprechen der App sichtbar machen.
6. **H148, H149:** Tests für die Zahlen, bevor weiter umgebaut wird.
