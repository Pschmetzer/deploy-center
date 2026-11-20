# Deploy Center – Ideen, Runde 12 (Stand 0.11.0)

Aus dem Code gelesen, gegen IDEEN-2 bis 11 abgeglichen. „(prüfen)“ = nur gelesen, nicht nachgestellt. Vor dem Umsetzen den Punkt im Code verifizieren; ist er schon behoben, überspringen.

# A. Mac-App: Einstellungen, Mitteilungen, Fenster (app/*, widgets/)

1. [Bug] FirstStart.swift:64 – „\(autoOn.count) projects“ ohne Einzahl; `plural()` aus Controls.swift:86 nutzen.
2. [Bug] FirstStart.swift:96/:43 – nur „Überspringen“/„Fertig“ setzen `done`; Esc/Schließen nicht, Erste Schritte erscheint erneut (prüfen).
3. [A11y] FirstStart.swift:29/45-46 – Schrittwechsel per `AccessibilityNotification.Announcement` ansagen, Titel `.isHeader`.
4. [UX] FirstStart.swift:53 – „Ausschalten“ ohne Rückmeldung/Undo; Picker springt still zurück.
5. [Bug] WeekGoals.swift:24/60 – `Demo.mask` auf zusammengesetzten Schlüssel „platform/name“, Demo zeigt echte Namen (prüfen).
6. [Bug] WeekGoals.swift:21-27 – „Seit 90 Tagen kein Deploy“ nennt gelöschte/umbenannte Projekte; gegen `store.allItems` abgleichen.
7. [Perf] WeekGoals.swift:64 – `Journal.load(limit: .max)` synchron auf dem Main-Actor; detached laden und cachen.
8. [A11y] WeekGoals.swift:46 – `Color.red/.orange` für Text statt `Color.warningText`.
9. [UX] WeekGoals.swift:58-61 – 90 Tage fest, nur 8 Zeilen ohne „+N weitere“; Schwelle einstellbar, Zeile anklickbar.
10. [Bug] HealthCard.swift:130-133 – `TokenAge.update` nur bei Änderung von `vercelLoggedIn`; später hinzugefügter Render-Key wird nie erfasst (prüfen).
11. [UX] HealthCard.swift:124 – „Erneut prüfen“ schluckt Fehler (`try?`); `doctorError` zeigen.
12. [A11y] HealthCard.swift:108-118 – pro Zeile vier VoiceOver-Elemente; `.accessibilityElement(children: .combine)`, Ergebnis ansagen.
13. [Feature] HealthCard.swift:114 – Fix-Befehle nur selektierbar; „Kopieren“ und „Im Terminal öffnen“ (nie automatisch ausführen).
14. [Bug] HealthCard.swift:34/38 – Hinweis „brew install perl/curl“ für mitgelieferte Tools irreführend (prüfen).
15. [Bug] CostInsights.swift:49-52 – `Currency(code:"USD")` nutzt System-Locale statt App-Sprache; `.locale(uiLocale)`, gleiches in widgets/DeployWidget.swift:68.
16. [Test] CostInsights.swift:24 – `onceADaySaving` nimmt feste 7 Tage an (prüfen).
17. [Bug] CostInsights.swift:56 – `|` im Projektnamen zerstört die Markdown-Tabelle; maskieren.
18. [Bug] LogSearch.swift:120-124 – Logs sequenziell, Fehler `try?` verschluckt; TaskGroup (max. 4) und „n Logs nicht lesbar“.
19. [Perf] LogSearch.swift:88/101 – Gruppierung/Suche im `body` je Tastendruck; cachen und entprellen.
20. [UX] LogSearch.swift:76/41 – Suchfeld ohne Fokus, 20-Treffer-Grenze ohne Hinweis, Treffer nicht anklickbar.
21. [Feature] LogSearch.swift:92-99 – Fehlergruppe: „Mit Claude beheben“, „Signatur kopieren“, „Nur diese Projekte zeigen“.
22. [Feature] LogSearch.swift:118-126 – kein „Neu laden“, kein Lesezeitpunkt.
23. [Bug] Notify.swift:73-77 – 30-Min-Wiederholung umgeht die Ruhezeit; gegen `quiet(...)` prüfen.
24. [Bug] Notify.swift:53 – Hauptschalter blockt auch `failed`/`rollBack`; Option „Live kaputt immer melden“ oder dokumentieren.
25. [UX] Notify.swift:35-44 – bei `.denied` kein Hinweis plus Knopf zu den Systemeinstellungen (prüfen).
26. [Bug] Notify.swift:188-201 – `didReceive` bei Kaltstart evtl. vor `onAction`/`onOpen`; letzte Antwort puffern (prüfen).
27. [Feature] Notify.swift:136 – `threadIdentifier` je Plattform, `summaryArgument` Projektname.
28. [UX] QuietDigest.swift:28-37 – Sammelmeldung ohne Aktion/Kategorie; „Journal zeigen“, Fehlschläge zuerst.
29. [Bug] QuietDigest.swift:12-16 – geplante Sammelmeldung nicht neu geplant, wenn `quietTo` geändert wird.
30. [Security] Team.swift:100-105 – fremde deploy-center.json wird ohne Bestätigung übernommen; Diff zeigen, einmal bestätigen.
31. [Bug] Team.swift:51 – `fromFile` parst Menschentext; strukturiertes Feld `source:"file"` vom Skript verlangen.
32. [UX] Team.swift:105 – „Neu lesen“ ohne Zeitpunkt/Ergebnis; Kopie-Hinweis mit Warnsymbol.
33. [A11y] Team.swift:67-69/83-85 – `⚠︎` als Zeichen; `Label` mit Symbol und `.accessibilityLabel`.
34. [Security] Autofix.swift:86 – „Jetzt ausführen“ schickt Build-Logs an eine Cloud-Routine ohne Rückfrage; einmalige Bestätigung mit Projektliste.
35. [Bug] Autofix.swift:111 – PR-Link im Demo-Modus ausgeblendet, Sitzungs-Link nicht (prüfen).
36. [UX] Autofix.swift:62-66 – Token-Feld erzwingt `sk-ant-` hart; Hinweis statt Sperre (prüfen).
37. [Perf] Autofix.swift:99-117 – Übergabenliste unbegrenzt; letzte 10, relative Zeit.
38. [A11y] Controls.swift:89-96 – `ErrorText` ohne VoiceOver-Ansage.
39. [Bug] Controls.swift:71 – `CopyButton`-Timer setzt vorzeitig zurück; Task merken/abbrechen (auch CostsSheet.swift:159/301).
40. [UX] Controls.swift:37 – `SafeLink.open` bei unzulässigem Link ohne Rückmeldung.
41. [Bug] Controls.swift:54 – `onChange(windowRequest)` kann zweites Hauptfenster öffnen (prüfen).
42. [UX] Confirm.swift:16-35 – jede Prüfung fragt neu nach Touch ID; `touchIDAuthenticationAllowableReuseDuration` ~30 s.
43. [A11y] Confirm.swift:43-86 – `runModal` blockiert Main-Thread; als Sheet, Hinweis welches Wort zu tippen ist.
44. [Security] Confirm.swift:74-83 – Name-Check per Einfügen ohne Hinschauen bestätigbar (Abwägung).
45. [Bug] CommandPalette.swift:557/563 – feste `asyncAfter(0.3)` nach Mitteilungsaktion kollidiert mit offenem Alert/Sheet (prüfen).
46. [UX] CommandPalette.swift `runChosen` – `guard … return` ohne Rückmeldung (läuft bereits, Beobachtermodus, kein Link).
47. [UX] CommandPalette.swift `.showAll` – setzt nur `true`; Umschalter wie die Nachbarn.
48. [Bug] CommandPalette.swift `.reload` – `autoRefresh()` kann stumm nichts tun (prüfen).
49. [Code] mehrfach `NSApp.activate(ignoringOtherApps:)` veraltet (prüfen Deployment-Target).
50. [UX] CommandPalette.swift PaletteHotKey – Registrierungsfehler (Kürzel belegt) unsichtbar (prüfen).
51. [Perf] DetailViews.swift:183 – Log-Poll pollt in 1-s-Schleife bei inaktiver App; `didBecomeActive` abwarten.
52. [UX] DetailViews.swift – Fehler-Navigationsknöpfe verdecken letzte Logzeilen; in Leiste unter dem Log.
53. [Security] Snapshot.swift:45 – Widget-Snapshot enthält `message` (Commit-Zeile), die kein Layout zeigt; Datensparsamkeit.
54. [Perf] Snapshot.swift:27 – `reloadAllTimelines()`; `reloadTimelines(ofKind:)`.
55. [Bug] Spotlight.swift:36-39 – kein `expirationDate`; `.distantFuture` (prüfen).
56. [Feature] Spotlight.swift:33-37 – keine `keywords`, kein Logo; versteckte Projekte nicht indizieren (prüfen).
57. [A11y] widgets/DeployWidget.swift:185-187 – Zeilen ohne Hint/Zustand im Label; `.isLink`.
58. [UX] widgets/DeployWidget.swift:209/202 – „+N weitere“ und „Nichts wartet.“ als Link zur App.
59. [Bug] widgets/DeployWidget.swift:568 – `ControlWidget` liest Sprache beim Aufbau von `body` (prüfen).
60. [UX] widgets/DeployWidget.swift:84-96 – „veraltet“-Hinweis nur auf iOS; App-Heartbeat im Snapshot, auch auf dem Mac nach 3 h markieren.
61. [Feature] WaitingControl – zweite Control „Fehlgeschlagene zeigen“ (`deploycenter://failed`).
62. [UX] SetupViews.swift:24 – nach `didBecomeActive` automatisch neu prüfen.
63. [Feature] SetupViews.swift:43/44 – Render-Key aus Zwischenablage anbieten, Feldbreite nicht fest, Speichern ansagen.
64. [UX] Tips.swift:10-21 – nur 10 Tipps, keine zu Guard/Team/Autofix/Claude/Wochenziel; anklickbar, „nicht wieder zeigen“.
65. [Test] Notify/QuietDigest – Ruhezeit über Mitternacht, Sommerzeit, `quietFrom==quietTo`; `Team.ownerRepo` mit `.git/`, SSH-Form, Unicode.
66. [A11y] DetailViews/LogSearch – Rotor „Fehler“, Aktion „Im Log zeigen“.

# B. CLI und Provider (deploys, lib/, providers/, scripts/)

1. [Security] providers/hook.sh:92-103 – `https://evil.com@127.0.0.1/x` umgeht die Private-Host-Sperre; Userinfo bei https ablehnen (prüfen).
2. [Security] providers/hook.sh:78-100 – Sperre rein textuell (nip.io, DNS-Rebinding); auflösen, `--resolve` pinnen.
3. [Security] lib/http.sh:47 – `header = "%s"` ohne Escaping; gemeinsamen `curl_cfg_quote` (wie `hook_cq`).
4. [Security] providers/amplify.sh:439-440 – signierte Log-URL in argv; per `-K -` auf stdin, `--proto =https`.
5. [Security] providers/digitalocean.sh:134 – dasselbe, plus `-L`; `--max-redirs 2`.
6. [Security] providers/coolify.sh:119 – Fallback übergibt Body per `--data` in argv.
7. [Security] scripts/check-public.sh:36-44 – nur 7 Token-Muster vs. Masker deploys:1505-1540; gemeinsame Quelle.
8. [Test] jedes Masker-Präfix durch `check-public.sh` laufen lassen.
9. [Security] deploys:224,178 – `export -f` legt BASH_FUNC_* in alle Kindprozesse; Wrapper-Skript.
10. [Security] deploys:178 – `trap_add` mit `eval`; Test mit Pfad `a b'c` (prüfen).
11. [Security] release.sh:~66 – `.release.env` ohne Rechteprüfung gesourct.
12. [Bug] deploys:~456 – `--force` schluckt nächstes Argument als Begründung.
13. [Bug] deploys:3411-3415 – `watch a --and b`: Kinder werden bei Ctrl-C nicht beendet (prüfen).
14. [Bug] deploys:3409 – `mktemp -d` wird bei Ctrl-C nicht entfernt.
15. [Perf] deploys:3411 – `watch --and` unbegrenzt parallel; `-P 6`.
16. [UX] deploys:3427-3449 – `watch` verwirft stderr; 401/403 sofort Exit 3.
17. [Feature] deploys:3457-3461 – `failed`/`canceled` beide Exit 1; eigener Code oder `--json phase`.
18. [Feature] deploys:3386ff – `watch` ohne `--json`/`--interval`/`--quiet`, kein Backoff nach 429.
19. [Perf] deploys:3427 – Poll ohne Jitter.
20. [UX] deploys:4018 – Rollback-Countdown schreibt `\r` auch in Nicht-TTY.
21. [UX] deploys:3984 – `verify` wirft curl-Exit weg; DNS/Connect/Timeout/TLS unterscheiden.
22. [Perf] deploys:3980 – `verify` prüft Pfade nacheinander; parallel.
23. [Feature] deploys:3984 – `verify` ohne Body-Match, Header-Check, TLS-Ablauf.
24. [Feature] deploys:3984 – `--warmup 30s`, `--retry-connrefused`.
25. [Bug] deploys:3920 – `die()` global auf Exit 3 umdefiniert (prüfen).
26. [Bug] deploys:3603 – Completion liest Kommandos per `sed` aus `$SELF`; eingebaute Rückfallliste.
27. [UX] deploys:3600-3690 – Flags der Provider-Verben fehlen in der Completion.
28. [Bug] deploys:3640-3660 – Completion prüft `words[2]` fest; greift nach `--json` nicht (prüfen).
29. [UX] deploys:3655-3660 – Verben von `ai`/`gitlab`/`providers` dreifach hartkodiert; `subs_table`.
30. [Bug] deploys:3598 – `"completion "*)` verlangt Leerzeichen (prüfen).
31. [Test] tests/cli12-unit.sh:192-198 – `zsh -n`, `bash -n`, `fish --no-execute` auf Completion-Ausgabe.
32. [UX] deploys:3664 – `$CONFIG_DIR` in zsh-Completion unquotiert/zu locker; `%q`.
33. [Bug] deploys:196 – `mtime` probiert `stat -c` zuerst; BusyBox (prüfen).
34. [Bug] deploys:2543,3088,4525 – `mktemp` ohne trap; alte Temp-Dateien beim Start aufräumen.
35. [Bug] lib/http.sh:39-56 – `bodyf`/`err` bleiben bei Ctrl-C liegen (kann Secret enthalten).
36. [Provider] lib/http.sh:51 – POST bei curl-Exit 6/7 wiederholen.
37. [Provider] lib/http.sh:50 – `Retry-After` nur als Zahl; Datumsform; >60 s abbrechen mit Hinweis (prüfen).
38. [Provider] lib/http.sh – kein Gesamtbudget für Retries; `HTTP_DEADLINE`.
39. [Perf] providers/coolify|cloudflare|digitalocean|netlify|render – 5 Kopien der Retry-Schleife; auf `http_call` vereinheitlichen.
40. [Bug] providers/render.sh:227 – `$1` ungeprüft in der URL (prüfen).
41. [Bug] lib/team.sh:38-40 – `gh api contents` >1 MB ohne `content`; Raw-Media-Type.
42. [UX] lib/team.sh:44-53 – Fehlerart (Rate-Limit, kein Zugriff, gelöscht) im Cache.
43. [Perf] deploys:817-836 – `xargs -P 8` ohne Rate-Limit-Budget; GraphQL-Batch.
44. [Bug] deploys:821, lib/githost.sh:238 – `jq --argjson` mit großen Werten, „Argument list too long“; `--slurpfile`.
45. [Bug] lib/githost.sh:266 – Pagination O(n²); `jq -s add` danach.
46. [Bug] providers/cloudflare.sh:238-241 – Abbruch bei Seite `<10`; `result_info.total_pages` (prüfen).
47. [Provider] providers/cloudflare.sh:217 – `per_page=10` → viele Aufrufe; API-Maximum prüfen.
48. [Feature] providers/hook.sh – optionales `statusUrl` je Hook.
49. [Bug] providers/hook.sh:282 – `start_lock` bleibt nach fehlgeschlagenem Trigger 60 s liegen.
50. [Feature] lib/http.sh – `DEPLOYS_HTTP_TRACE` (Methode, Pfad, Code, Dauer, ohne Header/Body).
51. [Feature] deploys:3060-3095 – `deploycenter_up` und `…_scrape_timestamp_seconds` in `metrics`.
52. [UX] deploys:3086 – `grep -v '^$'` Exit 1 bei leerer Liste (prüfen).
53. [Bug] release.sh:285,321 – `notes`-Temp-Datei nicht gelöscht; Cleanup-Array.
54. [Bug] release.sh:292 – `--clobber` auf veröffentlichtes Release; abbrechen außer `--force-republish` (prüfen).
55. [Bug] release.sh:5-6 und scripts/package-cli.sh – `usage()` mit festen Zeilen.
56. [UX] release.sh – `--dry-run` + `--check-addons` stumm ignoriert; Exit 2.
57. [Bug] release.sh:76 – `notes_of` kennt `## v0.7.0` nicht (prüfen).
58. [Test] CI – `/bin/bash` 3.2 auf macOS-Runner (kein `${x,,}`, `mapfile`, `declare -A`).
59. [Test] tests/script-tests.sh – curl-Stub um 429+Retry-After(Datum), Teilantwort, HTML, Exit 6/60.
60. [Test] Secrets nicht in argv (fake-curl.sh grep).
61. [Test] scripts/lint.sh – Obergrenze für `# shellcheck disable`.
62. [UX] scripts/check-size.sh:6 – Grenze 4800 bei 4739 Zeilen; `hook_run` und Risiko-Regeln nach lib/ auslagern.
63. [Security] lib/hooks.sh – `hooks install` in globalem `core.hooksPath` warnen/bestätigen.
64. [UX] lib/hooks.sh – nicht ausführbare `pre-push.local` melden.
65. [Feature] lib/hooks.sh – `--hook pre-commit` (`secrets --stdin`).
66. [Feature] `deploys config export|import` (ohne Schlüssel).
67. [UX] lib/http.sh:60-66 – 404-Meldung nennt Pfadtyp.
68. [UX] lib/http.sh:68 – Fehler-Body nicht maskiert; `af_mask`.
69. [Provider] amplify.sh:243, coolify.sh:253, digitalocean.sh:266 – gemeinsame `parallel_limit`.
70. [Feature] globales `--quiet` und `--debug` (maskierter Trace).
71. [Security] deploys:1552-1560 – bei `set -x` Token im Trace; lokal `set +x`.
72. [Bug] lib/http.sh:47 – ungültiger Key mit Zeilenumbruch erzeugt Config-Fehler mit Keyfragment (prüfen).
73. [Feature] Exitcode-Tabelle in README-CLI.md/`man`, `deploys exit-codes`.
74. [UX] `die` kennt nur Exit 1; `die_usage` mit Exit 2.
75. [Perf] deploys:1348 – ein `jq` je Schlüssel; bündeln (prüfen).
76. [Feature] digest/savings `--format markdown`.
77. [Test] lib/freeze.sh:57-66 – `TZ=Pacific/Auckland`, DST für `freeze`/`window`.
78. [Bug] deploys:829 – `date -r "$reset"` auf GNU date; `date -d "@…"` zuerst.

# C. iOS (ios/, widgets/, shared/, app/PhoneLinkMac.swift)

1. [Bug] PhoneLinkMac.swift:308 + shared/PhoneLink.swift:114 – „Um eine Minute verlängern“ setzt nur `left = 60`; `updated` bleibt, iPhone lehnt nach 90 s ab. Neuen Code erzeugen.
2. [Bug] PhoneLinkMac.swift:322-325 – „Code kopieren“ lässt den Code in der Zwischenablage; nach `qrMaxAge` löschen.
3. [Bug] ios/App/ConnectMac.swift:41-42 – `UsedCodes.mark` vor `store.adopt`; erst nach Erfolg markieren.
4. [Bug] PhoneLinkMac.swift:208/222 – Feld wird auch bei `keychainFailed` geleert; nur bei Erfolg.
5. [Bug] ios/App/LiveDeploy.swift:36-40 – `Activity.update` bei jedem Poll; nur bei Änderung oder ~60 s.
6. [Bug] ios/App/PhoneStore.swift:669/612 – `history(p)` im `follow` zeigt roten Toast beim Deploystart; stille Variante.
7. [Bug] ios/App/Views.swift:337 – EmptyState nur bei `loadedAt != nil`; offline beim ersten Start leere Liste (prüfen).
8. [Bug] ios/App/Views.swift:189 – `LockCover` an `phase != .active`; Face-ID-Sheet/Kontrollzentrum lösen es aus (prüfen).
9. [UX] ios/App/Views.swift:589/585 – Detail zeigt `stateText`, nicht `running[p.key]`; ProgressView.
10. [UX] ios/App/Views.swift:180-182 – Toast als `.overlay` verdeckt Zeile; `safeAreaInset`, Fehlertoasts schließbar.
11. [UX] Views.swift:180/968, PhoneStore.swift:152 – Fehler in Einstellungen/Verbinden-Sheet nur für VoiceOver; Inline-Meldung.
12. [UX] PhoneStore.swift:673 – `Notes.askOnce()` mitten im ersten Deploy; vorher erklärend fragen.
13. [UX] Views.swift:223-244 – `confirmationDialog` am Wurzel-View, iPad-Popover ohne Anker (prüfen).
14. [UX] Views.swift:361-366 – Offline-Banner mit `wifi.slash`, Deploy/Rollback deaktiviert mit Grund.
15. [Feature] Clients.swift:79/92, Views.swift:777 – Verlauf offline lesbar (Metadaten cachen).
16. [Perf] Clients.swift:546-554 – pro Render-Service ein `deploys?limit=10`; nur bei neuem `updatedAt`, Teilergebnisse behalten (prüfen).
17. [Bug] Clients.swift:696-756 + DeployCenterApp.swift:111 – ohne GitHub-Token Limit nach 20 min verbraucht; `x-ratelimit-reset` persistieren (prüfen).
18. [Security] Clients.swift:154-155 – Fehlerbody ungefiltert in Toast; `LogMask.mask` (prüfen).
19. [UX] DeployCenterApp.swift:111-117 + Views.swift:983 – `Background.lastRun` in Einstellungen zeigen.
20. [Feature] PhoneStore.swift:660 – „Build verfolgen“ für per Push gestartete Builds.
21. [Feature] DeployCenterApp.swift:37 + LiveDeploy.swift:28-30 – nach Kaltstart Activity wieder anschließen statt beenden.
22. [Feature] PhoneStore.swift:814-821 – Übergang „Build lief → live“ melden.
23. [Security] PhoneStore.swift:870-880 + DeployCenterApp.swift:50-52 – Projektnamen auf Sperrbildschirm; `hiddenPreviewsBodyPlaceholder` bzw. neutral bei lockOnOpen.
24. [Feature] PhoneStore.swift:870-880 – `interruptionLevel`/`SetFocusFilterIntent`.
25. [Feature] ios/Common/DeployActivity.swift + widgets/DeployWidget.swift:583-600 – Fortschritt `ProgressView(timerInterval:)`, Link „Domain öffnen“.
26. [A11y] widgets/DeployWidget.swift:629-631 – Timer-Label doppelt (prüfen).
27. [Feature] LiveDeploy.swift:17 – Stale-Text sachlicher („Stand 14:03“).
28. [Feature] ios/App/Intents.swift:70-76 – `ProjectEntity`/`EntityQuery`, `OpenIntent`, `IndexedEntity`.
29. [Feature] Intents.swift:47-66 – `ReturnsValue<Int>`, `ShowsSnippetView`.
30. [UX] Intents.swift:29-33 – `age()`-Zusatz nur wenn älter als ~15 min.
31. [Feature] „Deploy vorbereiten“-`OpenIntent` (nur Bestätigung öffnen, Face ID Pflicht).
32. [Feature] widgets/DeployWidget.swift:554-573 – Control „Jetzt aktualisieren“.
33. [Feature] widgets/DeployWidget.swift:364/383/491 – `AppIntentConfiguration`-Widget (ein Projekt / nur Fehler / nur Vercel).
34. [Feature] Views.swift:145-154 – `deploycenter://deploy?key=…` (nur Bestätigung), `settings`, `reload`.
35. [Feature] Views.swift:685-688 – Handoff `webpageURL`.
36. [Feature] Intents.swift:108-112 – Spotlight `keywords`, `domainIdentifier`.
37. [Feature] PhoneStore.swift:768-772 – `saving: nil`; `savingPerMonth` nutzen oder Feld entfernen.
38. [Security] Views.swift:945-993 – lockOnOpen/biometricsOnly/Schlüssel entfernen ohne neue Auth; Face ID vorher.
39. [Security] Views.swift:924-929 – Token nach „Fertig“ aus Zwischenablage löschen, wenn gleich.
40. [Security] Keychain.swift:96-110 – Hinweis auf minimalen Scope/kurze Laufzeit; getrennter Deploy-Token mit `.userPresence` (prüfen).
41. [Security] Views.swift:187-192 – bei `isCaptured` Namen verdecken (prüfen).
42. [Security] site/datenschutz.html:69-70, ios/AppStore/en.md – englische Datenschutzseite; iOS-Absatz vollständig (Spotlight, Handoff, Live Activities, Kamera).
43. [Security] PrivacyInfo.xcprivacy:20-27 vs docs/APP-STORE.md – Manifest-Abgleich beider Targets (prüfen).
44. [A11y] Views.swift:839-845 – „Kopiert“ zurücksetzen und ansagen.
45. [A11y] Views.swift:815-819 – „Fehler:“-Präfix, Zeilen gruppieren, Sprungaktion.
46. [A11y] Views.swift:485-489 – einspaltig ab AX-Größen (prüfen).
47. [A11y] ConnectMac.swift:251-275 – Taschenlampe `accessibilityValue`, 44 pt (prüfen).
48. [A11y] Views.swift:280 – Toast-Dauer bei Switch Control verlängern.
49. [A11y] docs/APP-STORE.md – Rotor-Test in „Before each release“.
50. [UX] Views.swift:810-811 – „Kein Log“: Erneut versuchen, Pull-to-Refresh, Live-Tail, `ShareLink`.
51. [UX] Views.swift:816 – horizontales Scrollen, `.searchable` im Log, „Weiter oberhalb laden“.
52. [UX] Views.swift:378-381 – Abschnitt „Aktuell“ einklappbar bei >15.
53. [UX] Views.swift:405 – Suche mit Scopes/Tokens.
54. [Feature] Views.swift:382-399 – Mehrfach-Deploy mit einem Face-ID-Dialog.
55. [Feature] Views.swift:877-1006 – „Über“-Zeile und „Fehler melden“ mit Diagnose (ohne Schlüssel).
56. [UX] DeployCenterApp.swift:20 / pbxproj – `UIApplicationSupportsMultipleScenes` prüfen.
57. [Test] ios/test.sh:8-10 – `Spoken.*`, `PhoneStore.sorted`, `notifyChanges`, `Background.listAge`, `QuickActions` testbar machen.
58. [Test] Keychain-Migration und `errSecMissingEntitlement`-Rückfall hinter Protokoll testen.
59. [Test] widgets/DeployWidget.swift:32-39, 560-563 – Timeline/Control/`Words.n`; `ImageRenderer`-Snapshots.
60. [Test] ci.yml:120-139 – Smoke-Test `-demo -open …` iPhone/iPad, Standard und AX5.
61. [Doku] ios/AppStore/en.md+de.md – Beschreibung nennt Live Activities, Shortcuts, Spotlight, Handoff, Control Center nicht.
62. [Doku] ios/AppStore/*.md – Schlüsselwörter ohne Dubletten zum Titel.
63. [Doku] docs/APP-STORE.md – deutsche Screenshots, Screenshots 4-6.
64. [Doku] docs/APP-STORE.md – App-Vorschau als Release-Schritt.

# D. Mac-App Kern (Store/Model/Row/MainWindow/Savings/Journal)

Bericht ausstehend; wird als Anhang ergänzt.

# E. Integrationen, Site, Tests, CI, Docs, Nutzer-Features

Bericht ausstehend; wird als Anhang ergänzt.
