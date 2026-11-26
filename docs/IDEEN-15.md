# Deploy Center – Ideen, Runde 15 (Stand 0.14.0)

Gegen IDEEN-2 bis 14 und CHANGELOG abgeglichen. Status je Punkt wird im PR nachgeführt. Blöcke: A Mac-App, B CLI/Provider, C Integrationen, D Website/Docs/CI.

# A. Mac-App

# Deploy Center: neue Verbesserungsideen für app/ und widgets/ (Stand 0.12.x, 26.11.2026)

Geprüft gegen docs/IDEEN*.md und CHANGELOG.md (Stichwort- und Dateizeilen-Suche); Zeilennummern gelten für den aktuellen Code. Kandidaten, die dort schon standen, sind entfernt. Punkte mit „prüfen“ sind aus dem Code gelesen, aber nicht ausgeführt. Nichts im Repo wurde geändert.


## Sicherheit (19)

1. [Sicherheit] Store.swift:2059-2063, 1997 – `probeSession` (Seitencheck, `pageText`) hat keinen Redirect-Delegate: eine Weiterleitung der Seite auf `http://`, localhost oder die Cloud-Metadaten-Adresse wird gefolgt; der Status entscheidet über Warnung und Auto-Rollback. Delegate wie bei `LogoCache` (nur https, öffentlicher Host).
2. [Sicherheit] CertificateProbe.swift:19-22 – Die Private-Host-Prüfung beim Redirect ist schwächer als `LogoCache.allowed/resolvesPublic` (Logos.swift:126-165): es fehlen 100.64/10 (CGNAT), 0.0.0.0/8, IPv6 (fc00::/7, fe80::/10, ::ffff:a.b.c.d) und die DNS-Auflösung auf private Adressen. Beide Prüfungen auf eine gemeinsame Funktion legen.
3. [Sicherheit] Sessions.swift:206, 210 – Zwei Buttons nutzen `NSWorkspace.shared.open(u)` statt `SafeLink.open`: `session`- und `url`-Felder kommen aus dem Skript-JSON und könnten ein anderes Schema tragen (file:, x-apple…). Auf `SafeLink.open` umstellen.
4. [Sicherheit] ClaudeConnect.swift:~120 (`merge`/`write`) – Lesen-Ändern-Schreiben der Claude-Konfiguration ohne Prüfung, ob die Datei seit dem Lesen von Claude Desktop geändert wurde: ein gleichzeitiger Schreibzugriff geht verloren. Vor dem `rename` Änderungsdatum/Hash vergleichen.
5. [Sicherheit] LogTools.swift:30-70 (`maskSecrets`) – Pfade wie `/Users/<name>/…`, IPv4/IPv6-Adressen und Twilio-/Mailgun-/Datadog-Schlüssel (`SK…`, `key-…`) bleiben in „Für Claude kopieren" und im Journal stehen; Home-Pfad und Adressen verraten Person und Infrastruktur. Weitere Regeln plus Testfälle.
6. [Sicherheit] DetailViews.swift:~118 (Menü „Kopieren") – Mit gehaltener ⌥-Taste wird das Log mit Tokens kopiert; die Option ist nur im Menütext versteckt und lässt sich unbeabsichtigt auslösen. Zweite, benannte Menüzeile „Rohes Log (mit Tokens)" mit Rückfrage statt Modifier.
7. [Sicherheit] Accounts.swift:25-31 – Keychain-Einträge werden ohne `kSecAttrAccessible` (z. B. `AfterFirstUnlockThisDeviceOnly`) und ohne `kSecAttrSynchronizable=false` angelegt; je nach Konfiguration können sie in iCloud-Schlüsselbund wandern. Explizit setzen.
8. [Sicherheit] Nightly.swift:73-76, 88-92 – Der Schalter „Claude behebt neue Funde" und „Claude prüft die Änderungen der Woche" startet automatisch Sitzungen und PRs, hat aber (anders als der Wächter beim Ausschalten) keine `OwnerCheck`-Abfrage beim Einschalten.
9. [Sicherheit] Accounts.swift:126 – „Konto entfernen" löscht den Schlüssel aus dem Schlüsselbund ohne Rückfrage und ohne `OwnerCheck`, obwohl „Wechseln" (Z. 122) beides verlangt. Der Schlüssel ist danach nicht wiederherstellbar.
10. [Sicherheit] SetupViews.swift:47-49 – Die Zwischenablage wird bei jedem Neuzeichnen des `body` gelesen (`NSPasteboard.general.string`); ab macOS 15.4 löst das Datenschutz-Hinweise aus und liest Fremdinhalte ohne Nutzeraktion. Nur per Button lesen oder `detectPatterns` nutzen.
11. [Sicherheit] RulesSettings.swift:146, Sessions.swift:128-141 – Demo-Modus maskiert hier keine Projekt-/Repo-Namen (Regelzusammenfassung, Sessions-Liste, Repo-Fehlerzeilen): Screenshots verraten echte Namen. `Demo.mask` ergänzen; Dateien ohne `Demo.` im Code prüfen (Sessions, RulesSettings, HealthCard, SavingsDetail).
12. [Sicherheit] App.swift:473 – Die Eigentümerprüfung (Touch ID) lässt sich ohne Authentifizierung ausschalten: der Schalter `ownerCheck` ist ein einfacher `@AppStorage`-Toggle. Wer den entsperrten Mac erreicht, schaltet sie mit einem Klick ab und deployt danach frei. Das Ausschalten selbst mit `OwnerCheck.confirm` absichern.
13. [Sicherheit] SettingsSupport.swift:57-59 (`defaultsKeys` des Tabs Deploy) – „Auf Standard zurücksetzen“ im Tab Deploy entfernt auch `OwnerCheck.key`, `MigrationCheck.key` und `confirmSingleDeploy` nach einer einfachen Bestätigung ohne Touch ID; Sicherheitsschalter gehören nicht in diese Liste (oder brauchen `OwnerCheck.confirm`).
14. [Sicherheit] RulesSettings.swift:235 – „Speichern“ einer Regel mit `then: deploy` schreibt `rules.json`, die `deploys` später automatisch anwendet (praktisch Auto-Deploy für Pfad-/CI-Bedingungen), ohne `OwnerCheck`; Wächter-Erlaubnis (Guard.swift:100) und Auto-Deploy-Schalter verlangen ihn. Beim Speichern von Deploy-Regeln fragen.
15. [Sicherheit] DeployWindowSettings.swift (`save`), DeployWindowConfig.swift:79-86 – Das Deploy-Fenster (Sperrzeiten) lässt sich ohne Eigentümerprüfung lockern oder leeren; ein Freeze ist eine Sicherheitsregel wie der Wächter. Beim Entfernen/Lockern einer Sperre `OwnerCheck.confirm` verlangen.
16. [Sicherheit] Autofix.swift:88-91 – Der Schalter „Alle 10 Minuten prüfen“ (`autofix schedule on`) schickt künftig Build-Logs ohne weitere Rückfrage an die Cloud-Routine, hat aber keine `OwnerCheck`-Abfrage, während „Jetzt ausführen“ (Autofix.swift:127) sie verlangt. Beide gleich absichern.
17. [Sicherheit] Tool.swift:214-216 (`runProcess`) – Jeder Skriptaufruf erbt die gesamte Umgebung der App (`ProcessInfo.processInfo.environment`), darunter eventuell `ANTHROPIC_API_KEY`, `GITHUB_TOKEN`, `AWS_*`; der MCP-Server filtert die Umgebung dagegen (CHANGELOG Runde 7). Allowlist (`PATH`, `HOME`, `LANG`, `DEPLOYS_*`, `VERCEL_*`, `RENDER_*`, `GH_*`) für die App-Aufrufe.
18. [Sicherheit] Notify.swift:24-30 (`remind`) vs. 67-69 (`post`) – Der Schalter „Neutrale Mitteilungen“ (Sperrbildschirm ohne Namen) gilt nur für `Notify.post`; `Notify.remind` zeigt Titel und Text immer im Klartext. Die Cloud-Session-Meldungen (Sessions.swift:97) tragen PR-Titel und Branch-Namen privater Repos auf den Sperrbildschirm, ebenso Tages- und Wochenabschluss (Store.swift:1681, 1697). `neutral` in `add` für alle Pfade anwenden.
19. [Sicherheit] ClaudeConnect.swift:502 (Schalter „Claude deployen lassen“, Aus-Richtung) – Beim Ausschalten wird `allowDeploy = false` sofort gesetzt und dann erst `applyAllowDeploy(false)` versucht (Z. 465-466). Schlägt das Schreiben der Konfiguration fehl (ungültiges JSON, CLI fehlt), steht der Schalter auf „aus“, obwohl `DEPLOYS_MCP_ALLOW_DEPLOY=1` weiter in der Claude-Konfiguration steht: ein falsches Sicherheitsgefühl. Die An-Richtung ist schon korrigiert (Z. 535), die Aus-Richtung nicht; nach `applyAllowDeploy` den Zustand aus `desktopAllows/codeAllows` neu lesen.

## Bugs und Race Conditions (37)

20. [Bug] Store.swift:1450-1463 (`deployOne`) – Zwei schnelle Klicks starten zwei Deploy-Fenster-Prüfungen, bevor der Zustand `.queued` gesetzt wird; bei kritischen Projekten erscheint die Namensabfrage doppelt, und `busyMessage` wird vom ersten Task geleert, solange der zweite noch wartet. Pro Projekt eine laufende Anfrage merken.
21. [Bug] Store.swift:1748-1757 (`rollbackNow`) – Kein Guard gegen einen laufenden oder wartenden Deploy desselben Projekts (anders als `enqueue`, Z. 1490): ein Rollback überschreibt den Zustand `.running` mit `.starting`. Mit `isActive` ablehnen. (prüfen, ob alle Aufrufer vorher prüfen)
22. [Bug] Store.swift:398, 366 – Bug-Scan und Sicherheits-Check starten mit `i.ref ?? "main"`; bei Repos mit `master`/`develop` und unbekanntem `ref` scheitert der Start oder prüft den falschen Branch. Ohne Ref den Standard-Branch vom Skript auflösen lassen (Argument weglassen).
23. [Bug] Store.swift:2188 – `watch` bricht bei aktivem Deploy mit `return` ab, ohne `watches[key]` zu leeren; der Eintrag bleibt bis zum nächsten Watch stehen und `Task` bleibt referenziert.
24. [Bug] Store.swift:2115-2127 – Eine Weiterleitung auf eine Login-/Wartungsseite mit 200 gilt als „fine"; der Probe folgt Redirects und zählt nur den Endstatus. Endgültige URL mit erwartetem Host vergleichen.
25. [Bug] Store.swift:1956-1957 (`checkLinks`) – `link + path` hängt den Prüfpfad an die gesamte URL; hat der Link einen Pfad, Query oder Fragment (`https://x.app/de?x=1`), entsteht `…/de?x=1/health`. Mit `URLComponents` auf den Ursprung kürzen.
26. [Bug] Store.swift:313 – Fällt eine Statusseite aus, bleibt ihre alte Meldung stehen (`kept`), auch wenn der Ausfall seit Stunden vorbei ist; ohne Zeitstempel kann die Meldung dauerhaft haften, solange die Seite nicht lesbar ist. Alter begrenzen (z. B. 1 h) und „Stand" anzeigen.
27. [Bug] Store.swift:1873-1876, 1864 – `follow` meldet nach 80 Fehlversuchen (~20 Min.) „Status nicht abrufbar" als `.failed` mit rotem Zustand, obwohl der Deploy live gehen kann; im Journal landet ein Fehlschlag, der keiner ist. Eigener Zustand `.unknown` statt `.failed`.
28. [Bug] Model.swift:410 – `Fire.id` ist `"\(project)-\(at)"` ohne Plattform; zwei gleichnamige Projekte auf Vercel und Render mit gleichem Zeitstempel kollidieren in `ForEach`. Plattform ergänzen (wie `GuardStatus.Action.id`).
29. [Bug] Model.swift:293 – `dashboardURL` bildet für `private_service` den Abschnitt `web`; Render nutzt dafür `/pserv/`. Zuordnung `kind → Pfad` vervollständigen und testen. (prüfen)
30. [Bug] Model.swift:279 – `compareURL` fällt auf `"main"` zurück, wenn weder `ref` noch `headSha` bekannt sind; das Gegenstück in `DetailViews.swift:467` hat das schon korrigiert. Link dann ganz auslassen.
31. [Bug] Journal.swift:177, 207 – `Int(s)` / `Int($0)` auf Sekundenwerte aus JSON stürzt bei NaN oder Werten über 9,2e18 ab (Trap); eine kaputte Journalzeile kann die App beim Öffnen beenden. `Int(exactly:)` oder Begrenzen.
32. [Bug] Nightly.swift:44-47 – Die Stunden-Auswahl schreibt immer `HH:00` und verliert damit Minuten, die per CLI gesetzt wurden (z. B. 03:30); die Anzeige schneidet ebenfalls auf `prefix(2)`. Minuten erhalten oder anzeigen.
33. [Bug] DeployWindowConfig.swift:35-42 (`problem`) – Die Validierung prüft nur Zeiten und Wochentage; `dates` (YYYY-MM-DD) und `from`/`to`-Reihenfolge (Nachtfenster) werden nicht geprüft, ein Tippfehler wird gespeichert und schweigend ignoriert.
34. [Bug] QuickFilters.swift:31 – `ruleText` gibt die Tage roh („mon,tue") aus; im deutschen UI erscheinen englische Kürzel. Über `Calendar.shortWeekdaySymbols` lokalisieren.
35. [Bug] CostsSheet.swift:166 – `NSSavePanel` mit `allowedContentTypes = [.plainText]` und Dateiname `.md` hängt unter Umständen `.txt` an. Markdown-UTType (`net.daringfireball.markdown`) setzen. (prüfen)
36. [Bug] Notify.swift:159-160 – `center.add` schluckt Fehler (`catch { then?(false) }`) ohne `Log.write`; fehlgeschlagene Benachrichtigungen (Limit 64 ausstehende, Berechtigung zurückgezogen) lassen keine Spur im Log.
37. [Bug] Notify.swift:154-157 – Erfolgsmeldungen erhalten je eine `UUID` und stapeln sich, bis der Nutzer sie löscht; es gibt kein `removeDeliveredNotifications`, wenn das Fenster wieder aktiv wird. Zugestellte Meldungen beim Aktivieren aufräumen.
38. [Bug] Store.swift:2128-2131 – `networkUp()` liefert bei erstem Update `satisfied` auch hinter einem Captive Portal; ein Hotel-WLAN führt zu „Seite antwortet nicht" statt „kein Netz". Zusätzlich `isConstrained`/Captive-Portal-Probe (`captive.apple.com`) nutzen.
39. [Bug] MainWindow.swift:497-499 – Esc schließt den Toast (`cancelAction`) und damit dessen „Rückgängig"/„Abbrechen"-Knopf, auch den des Rollback-Countdowns; ein versehentliches Esc (z. B. beim Verlassen des Suchfelds) entfernt die letzte Möglichkeit in der App, das Zurückrollen zu stoppen. Toast mit Undo nur nach Klick schließen.
40. [Bug] Team.swift:137 – Nach jeder Aktion (`run`) wird `doctor` komplett neu gelesen (startet jq, vercel, gh…), nur um den Beobachter-Schalter zu aktualisieren; `config --json` liefert ihn schon (`readTeamObserver`, Store.swift:129).
41. [Bug] Store.swift:130 – `readTeamObserver` lässt bei Fehler `teamObserver` auf altem Wert; die UI zeigt den Beobachter-Modus erst nach dem ersten erfolgreichen Lesen (Standard `false`). Das Skript lehnt Deploys ab, die App zeigt aber aktive Knöpfe. Zustand „unbekannt" einführen.
42. [Bug] Speech.swift:33-35 – `summary` baut „\(waiting) projects wait“ ohne Plural/Einzahl: bei einem Projekt sagt die Stimme „1 projects wait“ und „1 Projekte warten“; `plural(...)` (wie in `summaryLine`) fehlt. (IDEEN-6 181 gilt als erledigt, der Code hier ist es nicht.)
43. [Bug] Store.swift:1300 – Die Sprachansage von Deploy-Ergebnissen (`Speech.say(title)`) ignoriert die Ruhezeiten (`Notify.quiet`), die für Meldungen gelten; nachts wird laut vorgelesen. Dieselbe Prüfung wie in `Notify.post` anwenden.
44. [Bug] ErrorPatterns.swift:~100 (`FailureCauses.record/forget`) – Die Ursachen sind nur nach Projektname geschlüsselt (`m[project]`); gleichnamige Projekte auf Vercel und Render überschreiben einander. Schlüssel `plattform/name` verwenden (wie `HealthScore.Result.id`).
45. [Bug] DetailViews.swift:~503, Controls.swift:103, App.swift:360, Autofix.swift:109, Guard.swift:158, Sessions.swift:122-125, DetailViews.swift:584/644/749, FirstStart.swift:75 – Texte mit `.red`/`.orange` statt `Color.dangerText`/`warningText`; die Systemfarben erreichen auf hellem Grund nicht 4,5:1. `ErrorText` (Controls.swift:103) ist zentral und wirkt auf viele Stellen.
46. [Bug] MainWindow.swift:1455-1461 – Wird ein Repo-Kopf eingeklappt, verschwinden dessen Zeilen, aber angehakte Projekte bleiben ausgewählt und zählen in „N ausgewählt“ und im Lauf; der Nutzer sieht nicht, was er deployt. Beim Einklappen Auswahl melden oder die Zeile „n versteckt angehakt“ zeigen.
47. [Bug] HealthScore.swift:82-102 – Die App-Karte sagt „dieselbe Formel wie `deploys health`“, lässt aber den CI-Anteil aus (`ci` bleibt leer): dasselbe Projekt hat in App und CLI verschiedene Werte. CI-Zustand aus `store` mitgeben; Zeilen auf das Projekt verlinken; nur die schlechtesten 5 sind sichtbar, „Alle zeigen“ fehlt.
48. [Bug] SettingsSupport.swift:~56 (`.general`) – „Auf Standard zurücksetzen“ im Tab Allgemein entfernt auch `demoMode`: wer gerade im Demo-Modus Screens teilt, zeigt nach einem versehentlichen Reset echte Namen. `demoMode` nicht zurücksetzen oder vorher warnen.
49. [Bug] Spotlight.swift:15-17, 32-34 – `entries` verbindet Schlüssel, Name und Plattform mit Tabulator und `update` zerlegt wieder mit `split("\t")`; ein Projektname mit Tabulator verschiebt die Felder (Titel abgeschnitten, Plattform falsch, falscher Schlüssel beim Öffnen). Struct statt String-Zeile; Test fehlt.
50. [Bug] Store.swift:1950-1952 (`cleanPaths`) – Mehrere Prüfpfade werden an Kommas getrennt; ein Pfad mit Komma in der Query (`/search?q=a,b`) wird in zwei zerlegt und der zweite Teil (`b`) als eigener Pfad geprüft. Trennung nur an Komma plus Leerzeichen/Zeilenumbruch oder Feld pro Pfad.
51. [Bug] JournalStats.swift:51-72 (`dora`) – Die DORA-Zahlen rechnen auf dem auf 500 Einträge gekürzten Journal (Journal.swift:122); bei vielen Deploys ist „Deploys pro Woche“ zu niedrig, weil `days` den gewünschten Zeitraum nennt, die Daten ihn aber nicht abdecken. Tatsächlich abgedeckten Zeitraum (ältester Eintrag) als Nenner nehmen.
52. [Bug] QuickFilters.swift:90-100 (`SearchQuery.has/toggled`) – Die Operatoren werden nur an einem Leerzeichen getrennt; ein Tabulator oder geschütztes Leerzeichen aus dem Einfügen verhindert die Erkennung, und Chip und Eingabe laufen auseinander. An `.whitespaces` trennen.
53. [Bug] Sessions.swift:99-105 – `seen` wird auf `r.sessions` zurückgeschnitten (`seen.intersection(live)`). Fällt ein Repo in `errors` aus, fehlen seine Sessions in `live`; ihre Schlüssel werden gelöscht und beim nächsten erfolgreichen Lesen als „neu“ gemeldet: eine Flut „n Cloud-Sessions fertig“. Schlüssel nur löschen, wenn alle Repos gelesen wurden.
54. [Bug] Savings.swift:~205-215 (`loadSimulation`) – `guard !loadingSimulation` prüft, bevor der erzeugte `Task` `loadingSimulation = true` setzt; zwei schnelle Aufrufe (zwei Klicks, Fenster öffnen und „Neu berechnen“) starten zwei teure Simulationen (viele API-Aufrufe) parallel, und `simulationTask` zeigt nur auf die zweite, sodass „Abbrechen“ die erste nicht stoppt. Flag vor dem `Task` setzen.
55. [Bug] MainWindow.swift:1056-1081 (`startDeploy`) – Der `Task` ist nicht gemerkt; ⌘↩ zweimal schnell hintereinander startet zwei Abläufe mit je einer Touch-ID-Abfrage und Deploy-Fenster-Prüfung (`confirmedKeys` friert nur die Auswahl ein). Ein `starting`-Flag am Fenster, das weitere Aufrufe bis zum Ende ignoriert.
56. [Bug] DemoText.swift:15 (`$0.count >= 3`) – Namen mit ein oder zwei Zeichen (`ui`, `os`, `ai`) werden im Demo-Modus nie maskiert und erscheinen in Toasts und Logs im Klartext; umgekehrt ersetzen kurze Namen (`web`, `app`) das Wort überall im Text. Mindestens für Namen als ganze Wörter maskieren und kurze Namen mit Wortgrenze zulassen.

## Performance (16)

57. [Perf] MainWindow.swift:540 / Journal.swift:182 – `Journal.load(limit: 1)` liest und dekodiert die gesamte Datei (500 JSON-Zeilen), nur um zu prüfen, ob sie nicht leer ist (`checkFirstStartOnce`). `FileManager`-Größe oder erste Zeile genügen.
58. [Perf] HealthScore.swift:97, WeekGoals.swift:69 – `.task { … Journal.load(limit: .max) }` dekodiert das Journal im Hauptakteur beim Öffnen der Tabs; auf einen Hintergrund-Task auslagern oder in einem gemeinsamen, gecachten Journal-Modell halten (Journal.swift:446 liest ein drittes Mal).
59. [Perf] LogSearch.swift:70-71 – `failed` ist eine berechnete Eigenschaft (`store.allItems.filter { $0.failed }`) und wird in `shown()` für jede angezeigte Zeile, jeden Treffer und jeden Projektnamen neu ausgewertet (bei 300 Projekten und 100 Zeilen sind das 30 000 Filterschritte je Zeichen im Suchfeld). Einmal je `load()` als `@State` halten.
60. [Perf] QuickFilters.swift:55-61 – `FreezeNote` startet jede Minute `deploys freeze --json` (bash), solange das Fenster existiert, auch bei schlafendem Bildschirm und im Energiesparmodus; Store, Sessions (Sessions.swift:75) und PerfGuard (PerfGuard.swift:100) haben je einen eigenen Takt ohne `screensAsleep`/`effectiveRefreshMinutes`. Zentralen Poll-Planer einführen.
61. [Perf] Sessions.swift:75 – `SessionsWatch` fragt jede Minute GitHub (`deploys sessions --json`) unabhängig vom GitHub-Budget und von `effectiveRefreshMinutes` (Store.swift:~724); bei niedrigem Budget verbraucht es das Restkontingent der Liste. An dasselbe Intervall koppeln.
62. [Perf] PerfGuard.swift:97-104 – `PerfMonitor.start` läuft ohne Pause alle 30 s (liest Datei, `perf docker`, `perf reap --all`) auch wenn das Menüleistensymbol aus ist (`perfIndicator` aus) oder der Mac wenig Last hat; bei ausgeschaltetem Indikator nicht starten.
63. [Perf] Store.swift:1859, 1891 – Jeder laufende Deploy startet alle 6 s ein eigenes `deploys <host> status` (bash + node); drei Deploys = ein Prozess alle 2 s. Eine gebündelte Abfrage (`status --all` oder ein Statusfeed) für alle verfolgten Deploys.
64. [Perf] Model.swift:221-273 – `Item` ist ein Struct mit ~40 Feldern in `@Published items: [Platform:[Item]]`; jeder Status-Tick eines Deploys (alle 6 s) invalidiert die gesamte Liste. Zeilenzustand in ein eigenes `ObservableObject` je Zeile auslagern.
65. [Perf] Team.swift:137, Store.swift:1595 – Nach jedem Lauf wird zusätzlich `autoRefresh` ausgelöst, auch nach vollständig abgebrochenen Läufen (`hadRun` zählt jeden Eintrag in `batch`); nach reinem Abbrechen unnötige GitHub-Aufrufe. Nur bei `done`/`failed` neu laden.
66. [Perf] Logos.swift:63 – `LogoCache.sweep()` läuft synchron beim Start im Hauptthread (`Store.boot`, Z. ~634) und liest je Logo die Dateiattribute; in einen Hintergrund-Task legen.
67. [Perf] Tool.swift:173-180 – Kein Limit für gleichzeitige `Tool.run`-Aufrufe: Listen, Extras, Status-Polls, Scan-Abfragen, FreezeNote, Sessions und PerfGuard starten parallel je einen bash-Prozess (plus node); bei 3 Deploys und offener Einstellungen sind das schnell 10+ Prozesse. Eine kleine Zählsperre (z. B. 4) mit Priorität (Status vor Extras).
68. [Perf] LogSearch.swift:40-56 / Store.swift:1595 – Nach „Neu laden“ in der Log-Suche werden alle fehlgeschlagenen Projekte erneut vollständig gelesen, auch solche, deren letzter Fehlschlag unverändert ist (`lastAt`/`latestId` gleich); ein Cache je `latestId` spart `deploys logs`-Aufrufe.
69. [Perf] Journal.swift:312-316 (`names`, `scrub`) – Im Demo-Modus baut `names` bei jedem Aufruf aus allen Einträgen eine `Set`-Liste von `Item`s; `scrub` und `row` rufen es je Zeile auf: bei 500 Journalzeilen entstehen 250 000 `Item`-Objekte je Neuzeichnung. `names` einmal beim `reload()` berechnen.
70. [Perf] MainWindow.swift:1086-1093 und Store.swift:1450-1459 – Ein Einzel-Deploy fragt das Deploy-Fenster zweimal (`MainWindow.deployOne` ruft `store.deployWindow()`, danach prüft `Store.deployOne` ohne `force` es noch einmal): zwei bash-Prozesse und rund eine Sekunde Verzögerung bis zum Toast „Startet in 8 s“. Die Prüfung nur einmal ausführen.
71. [Perf] DemoText.swift:6-27 (`Demo.scrub`) – Der Regex wird zwischengespeichert, aber bei jedem Aufruf werden Wortmenge und sortierte Liste aller Projekt-, Repo- und Domainnamen neu gebaut und je Treffer linear gesucht; der Build-Log im Demo-Modus ruft es für 2000 Zeilen einzeln auf (DetailViews.swift:~200). Die Liste einmal je Namensstand halten (Hash der Namen) und Treffer in einem Dictionary nachschlagen.
72. [Perf] LogTools.swift:156 (`Demo.on`) – `Demo.on` liest `UserDefaults` bei jedem Aufruf; `Demo.mask` und `Demo.scrub` stehen in jedem Zeilen-`body` (mehrere Aufrufe je Zeile). Ein gecachter Wert, den der KVO-Beobachter (Snapshot.swift:19) aktualisiert, genügt.

## Barrierefreiheit (17)

73. [A11y] MainWindow.swift:1842 – Das Status-Icon (`checkmark.circle.fill`/`xmark.octagon.fill`) in der Meldungsliste ist weder versteckt noch beschriftet: VoiceOver liest den Symbolnamen vor jeder Zeile. Zeile mit `.accessibilityElement(children: .combine)` und Wert „Fehler/ok".
74. [A11y] Nightly.swift:127-133 – Pro Repo gibt es „Auslassen"/„Aufnehmen" und „PR" ohne den Repo-Namen im Label; VoiceOver liest N-mal dasselbe. `.accessibilityLabel("Repo xy auslassen")` und `.combine` auf die Zeile.
75. [A11y] Sessions.swift:206-210 – Die Icon-Buttons „Claude-Session öffnen" und „#n" haben nur `.help`, kein `accessibilityLabel` (Z. 206-211); `#n` wird als „Nummer n" ohne Kontext gelesen.
76. [A11y] MainWindow.swift:775 – Der „DEMO"-Hinweis ist reiner Text; VoiceOver-Nutzer erfahren nicht, dass Namen maskiert sind. Hinweis mit Erklärung („Demo-Modus: Namen sind ersetzt") beschriften.
77. [A11y] App.swift:~125 (`SettingsView` `.frame(width: 560, …)`) – Das Einstellungsfenster hat feste Breite und tabellenspezifische Höhe und lässt sich nicht vergrößern; mit großer Systemschrift oder längeren deutschen Texten wird abgeschnitten. Größe frei lassen und `minWidth` setzen.
78. [A11y] Row.swift:164-173 – Das Hover-Popover mit den wartenden Commits (`onHover`) ist per Tastatur und VoiceOver nicht erreichbar; derselbe Inhalt steht nur in den Details. Per Tastenkürzel (z. B. Leertaste/Quick Look) oder als Accessibility-Wert der Zeile anbieten.
79. [A11y] SetupViews.swift:14-21 (`Setup`) – Der Terminal-Befehl steht als Text plus Kopieren-Knopf; ohne Gruppierung liest VoiceOver Befehl und Knopf getrennt, und der Fokus startet nicht auf dem ersten Befehl. `accessibilityElement(children: .contain)` und `defaultFocus`.
80. [A11y] ShortcutSheet.swift / MainWindow.swift:1007-1015 – Schließen-Knöpfe (xmark) tragen verschiedene Beschriftungen („Schließen" für „Banner bis zur Änderung ausblenden"); der Zweck ist nur im `.help` genannt. `accessibilityHint` ergänzen.
81. [A11y] QuickFilters.swift:100-135 – Die Filter-Chips haben ⌥⌘1–4 als Kürzel, aber keinen `.accessibilityAddTraits(.isToggle)`/Wert „an/aus"; der Zustand `on` ist nur optisch (fett).
82. [A11y] DetailViews.swift:~160 (Fehler-Navigation) – Das Springen zum nächsten/vorigen Fehler im Build-Log hat Buttons ohne Tastenkürzel (z. B. F3/⇧F3, ⌘G); Log-Navigation per Tastatur fehlt.
83. [A11y] Controls.swift:11-17, MainWindow.swift:1840-1858 – Das Meldungs-Popover hat keine Überschrift und keinen Fokus beim Öffnen; VoiceOver bleibt im Hintergrund auf der Schaltfläche. `accessibilityAddTraits(.isHeader)` und `defaultFocus` auf die erste Zeile.
84. [A11y] PerfGuard.swift:~178 – Das Menü „Prozesse“ setzt „⚠︎“ als Zeichen vor flaggte Einträge im Text; VoiceOver liest „Warnung“ nur über das Symbol, und die Farb-Punkte (`PerfMonitor.dot`) tragen nur `accessibilityDescription` am Bild, nicht am Menüeintrag. Text „hängt“/„ungenutzt“ ausschreiben.
85. [A11y] Row.swift:~436 (`TimelineView(.periodic … by: 1)`) – Der Laufzeit-Zähler läuft je aktiver Zeile im Sekundentakt und ist ein normales `Text`; VoiceOver kann bei Fokus auf der Zeile jede Sekunde neu ansagen oder den Wert nie stabil lesen. Zähler `accessibilityHidden` und Zeilenwert „läuft seit n Minuten“ minütlich aktualisieren.
86. [A11y] DetailViews.swift:~310 (`LogText`) – Fehlerzeilen nutzen `NSColor.systemRed` auf dem Fensterhintergrund (≈3,9:1 im Hellmodus); der Kontrast-Standard der App (`dangerText`) fehlt im NSTextView. Dynamische Farbe wie `Color.dangerText` übertragen.
87. [A11y] JournalStats.swift:273 – Die Heatmap-Zellen tragen als `accessibilityLabel` nur den Wochentag („Montag: 3 Deploys“), nicht den Zeitblock (0–6, 6–12 …); VoiceOver liest vier gleichlautende Zeilen je Tag. Zeitblock in das Label und die Spalten als `accessibilityRepresentation` (Tabelle).
88. [A11y] MainWindow.swift:1856 (Meldungen), Row.swift:98 – Meldungs- und Fehlertexte zeigen `Text(...)` ohne `.accessibilityLabel` mit Statuswort („Fehler:“/„Erfolg:“); nur das Symbol trägt die Information und ist bei VoiceOver unklar. Wort voranstellen.
89. [A11y] DeployConfirmSheet.swift:33-37 – Im vorsichtigen Modus (mehr als drei Projekte oder rotes Risiko) ist „Abbrechen“ `.defaultAction` und „Deployen“ ⌘D; die Esc-Taste (`.cancelAction`) ist dann an keine Schaltfläche gebunden, und ⌘D steht bei VoiceOver ohne Hinweis. Esc ausdrücklich an Abbrechen binden (zweiter versteckter Button) und das Kürzel im Label nennen. (prüfen, ob das Sheet Esc selbst abfängt)

## UX (20)

90. [UX] MainWindow.swift:1842-1845 – Die Meldungsliste zeigt nur die Uhrzeit (`uiTime`), obwohl bis zu 200 Einträge über Tage gespeichert werden (Timing.messageLimit); ältere Meldungen sind nicht datierbar. Bei anderem Tag das Datum voranstellen.
91. [UX] Accounts.swift:120-126 – „Wechseln" blockiert nicht erneut: zwei Klicks starten zwei `set-key`-Läufe parallel, die Zeile zeigt keinen Fortschritt, bis die Antwort kommt. Beim Wechsel `ProgressView` und Knöpfe deaktivieren.
92. [UX] Accounts.swift:106, 112-147 – Konten gibt es nur für Nicht-Vercel-Hosts (`$0.id != "vercel"`); für Vercel (mehrere Teams/Tokens) fehlt der Umschalter. Außerdem bleibt nach „Entfernen" des aktiven Kontos der Schlüssel im Skript aktiv, ohne dass die UI das sagt.
93. [UX] Store.swift:248 – Mit mehreren kritischen Projekten in einem Lauf erscheint eine Namensabfrage je Projekt nacheinander (`allSatisfy`); bei 10 Projekten 10 Dialoge. Ein Dialog mit Liste und Eingabe der Anzahl oder „DEPLOY" für den ganzen Lauf.
94. [UX] DetailViews.swift:~118-160 (BuildLog) – Beim Laden von mehr Zeilen springt `lineCount` direkt von 200 auf 2000, ein Zwischenschritt oder „alles" fehlt; die Kopfzeile sagt nicht, dass das Log gekürzt ist. Zeilenzahl im Titel („letzte 200 von …").
95. [UX] SetupViews.swift:60 – Der Render-Key-Dialog bietet nur Render an; Netlify, Fly, Railway u. a. (Providers.swift) brauchen ihre Schlüssel in den Einstellungen, ohne geführte Ersteinrichtung. Einrichtungs-Assistent je Provider.
96. [UX] Nightly.swift:121-134 – Die Repo-Liste („Repos (N)") hat keine Suche und keine Sortierung (Funde zuerst); bei 40 Repos muss man scrollen, um Auffälligkeiten zu finden. Nach neuen Funden sortieren.
97. [UX] Guard.swift:170, Nightly.swift:119, Autofix.swift:104 – `Date.formatted(date:time:)` ohne `.locale(uiLocale)`: Datum folgt der Systemsprache, nicht der gewählten App-Sprache (gleich in JournalStats.swift:145/164, Journal.swift:412, Savings.swift:556, PhoneLinkMac.swift:271, WeekGoals.swift:62, ClaudeAI.swift:204/415 für Zahlen). Eine Hilfsfunktion `uiDate` gibt es (Controls.swift:16).
98. [UX] Sessions.swift:126-141 – Die Sessions-Ansicht zeigt rohe Fehlertexte (`e.error`, `watch.error`) in Rot ohne `Demo.scrub` und ohne Lösungshinweis (z. B. `gh auth login`); `ErrorHelp` (ErrorHelp.swift) wird nicht genutzt.
99. [UX] Store.swift:1478-1480 – Im Beobachtermodus sind Deploy-Knöpfe sichtbar und lösen erst beim Klick eine Meldung aus; besser deaktivieren mit Erklärung.
100. [UX] SetupViews.swift:30-70 – Fehler beim Speichern des Render-Keys erscheinen als Text unter dem Feld, aber ein schon gespeicherter, ungültiger Key bleibt im Schlüsselbund; „Key testen" ohne Speichern fehlt.
101. [UX] Store.swift:1426-1433 (`deploySelected`) – Nach „Alle deployen" werden gesetzte Häkchen sofort entfernt; bricht der Nutzer in den 8 s Rückgängig-Fenster ab, sind alle Auswahlen verloren und müssen neu gesetzt werden. Auswahl bei „Alle abbrechen" wiederherstellen.
102. [UX] PerfGuard.swift:~170 (Menü „Prozesse") – „Beenden: <Prozess>" beendet den Prozessbaum direkt aus dem Menü, ohne Rückfrage; die Liste ist bis zu 120 s alt, die PID kann inzwischen neu vergeben sein. Vor `--pid` die Startzeit mitgeben/prüfen und kurz bestätigen.
103. [UX] ClaudeAI.swift:~60 (`parseCap`) – Das Suffix `t` wird als Tausend gelesen (englisch „T" = Billion, deutsch „Tsd."), `m` und `mio` als Million; „1,5t" und „2T" sind mehrdeutig. Nur `k`/`m`/`mio`/`tsd` zulassen.
104. [UX] ErrorPatterns.swift:15-60 – Nur fünf bekannte Ursachen (Lockfile, Speicher, Node-Version, Umgebungsvariable, 401/403); häufige fehlen: TypeScript-/ESLint-Fehler, „Cannot find module“/„Module not found“, `ENOSPC`, Build-Timeout, Prisma-`generate`, Python-Resolver, Rate-Limit 429, DNS (`ENOTFOUND`). Muster ergänzen und jeweils mit Beispiel-Log testen.
105. [UX] Store.swift:1952 – `cleanPaths` schneidet still auf fünf Pfade ab (`prefix(5)`); der Nutzer tippt sechs Pfade und erfährt nicht, dass der sechste nie geprüft wird. Beschränkung im Feld erklären oder Fehler zeigen.
106. [UX] DetailViews.swift:~636 (`risk`) – Das Risikoformat erscheint nur mit nichtleeren `reasons`; „kein Risiko erkannt“, „Risiko nicht gelesen“ (Budget knapp, `risk == nil`) und „grün“ sehen gleich aus (nichts). Drei Zustände ausweisen („Risiko: niedrig“, „nicht geprüft: GitHub-Budget“).
107. [UX] MainWindow.swift:513, 1840-1860 – Ein Fehler-Toast verschwindet nach 120 s (`stickyError`), und die Meldungsliste (Menü „Mehr“) hat keinen Zähler für ungelesene Einträge; wer 10 Minuten weg war, sieht nicht, dass in der Zwischenzeit etwas fehlschlug. Rote Zahl am Knopf „Meldungen“, bis die Liste geöffnet wurde.
108. [UX] Nightly.swift:44-47, 124-126 – Die Uhrzeit-Auswahl setzt den Wert erst nach `nightly schedule on` und dem Neulesen (`reload`); bis dahin springt die Auswahl auf die alte Stunde zurück und flackert. Optimistisch setzen und bei Fehler zurücknehmen.
109. [UX] WeekGoals.swift:7-10 – `thisWeek` erzwingt `firstWeekday = 2` (Montag) unabhängig von der Region; für Mac-Nutzer mit US-Kalender stimmt „Diese Woche“ nicht mit dem Kalender überein, und die Wochenzusammenfassung (Store.swift:~1690, Montag) rechnet separat. Eine Quelle für den Wochenbeginn (`Calendar.current.firstWeekday`) und die Einstellung nennen.

## Neue Features (18)

110. [Feature] Feature – Deep Link `deploycenter://log?project=…` und `deploycenter://check?project=…` (nur lesend, wie `select`, App.swift:636-650): Skripte und Benachrichtigungen öffnen direkt das Build-Log.
111. [Feature] Feature – Wiederholungs-Button „Letzten Deploy-Lauf wiederholen" (dieselben Projekte, dieselben Optionen) in Menüleiste und Palette; heute nur „Fehlgeschlagene nochmal" (Store.swift:1543).
112. [Feature] Feature (QuickFilters.swift:55) – Deploy-Fenster mit Zeitzone je Regel (`tz`); heute gelten Zeiten der Mac-Zeit, ein Reisender oder VPN verschiebt die Sperrzeit unbemerkt.
113. [Feature] Feature (Notify.swift) – Benachrichtigungston je Ereignisart (live, Fehler, Rollback-Countdown) und „Erinnerung beim Fokuswechsel": heute nur ein Schalter `resultSounds` (Notify.swift:109).
114. [Feature] Feature (LogSearch.swift) – Log-Suche über die letzten erfolgreichen Builds hinweg (Regression finden: „ab wann taucht die Warnung auf") statt nur fehlgeschlagener.
115. [Feature] Feature (Sessions.swift) – Cloud-Sessions: Benachrichtigung „Session hängt" mit Aktion „Pull Request öffnen" und „Stumm für dieses Repo" direkt in der Meldung (UNNotificationAction), nicht nur ein globaler Schalter `sessionNotifications`.
116. [Feature] Feature (Savings.swift) – Ersparnis nach Projekt ausweisen und als CSV exportieren (heute Gesamtbetrag und Karte).
117. [Feature] Feature (Guard.swift:60-110) – Wächter-Verlauf als Liste „wer hat Auto-Deploy wieder eingeschaltet" (Quelle: Dashboard, Blueprint, Teammitglied) mit Link auf das Audit-Log des Hosts.
118. [Feature] Feature – Deploy für später einplanen („heute 22:00 deployen“) direkt an der Zeile; das Zeitplan-Fenster kennt nur das tägliche Deploy (`schedule.json`, Snapshot.swift:67). Einmal-Termin mit Abbrechen-Knopf und Benachrichtigung.
119. [Feature] Feature (SettingsSupport.swift) – Einstellungen als Datei exportieren/importieren (ohne Schlüssel), um einen zweiten Mac oder eine Neuinstallation schnell einzurichten; `defaultsKeys` kennt schon die Schlüsselliste.
120. [Feature] Feature (Controls.swift SafeLink) – „Link kopieren“ statt „Öffnen“ für Seiten-, PR- und Session-Links im Kontextmenü (macOS 15 Datenschutz: nicht jeder Link soll im Standardbrowser des Nutzers landen) sowie Öffnen in einem bestimmten Browser/Profil je Projekt (z. B. Arbeitsprofil).
121. [Feature] Feature (Store.swift:~684) – Menüleisten-Befehl „Aktualisierung pausieren“ (1 h/bis morgen) für Präsentationen und Flüge: stoppt Polling, Seitenwächter und Sessions; heute gibt es nur Bildschirmschlaf und Energiesparmodus.
122. [Feature] Feature (Journal.swift) – Journal-Eintrag „warum“ beim Rollback und beim erzwungenen Deploy als Pflichtfeld mit Vorlagenliste („Hotfix“, „Kunde wartet“); `force` kennt nur Freitext (Store.swift:1419).
123. [Feature] Feature (QuickFilters.swift:20-30) – Deploy-Fenster-Hinweis mit Countdown („öffnet in 2 h 10 min“) und Vorschau der nächsten Sperre in der Fußzeile; heute nur „n Sperrzeiten, jetzt offen“.
124. [Feature] Feature (Guard.swift) – Wächter-Ausnahmen mit Begründung/Ablauf je Projekt (Allowance hat nur Stunden); ein Feld „Warum“ und eine Erinnerung vor Ablauf („Erlaubnis endet in 15 Minuten“).
125. [Feature] Providers.swift:60-62 (`gitHosts`) – Der Störungs-Banner kennt nur GitHub; für GitLab-Repos (docs/GITLAB.md) fehlt die Statusseite (status.gitlab.com), obwohl `statusLinks` mehrere Hosts vorsieht.
126. [Feature] DetailViews.swift:~655 (`d.risky`) – Die Liste „Vor dem Live-Gang ansehen“ nennt bis zu acht Dateien als reinen Text; ein Klick öffnet nicht die Datei im Vergleich (`compareURL#diff-…`) oder im Browser.
127. [Feature] Nightly.swift:121-134 – Je Repo gibt es „Auslassen/Aufnehmen“, aber kein „Dieses Repo jetzt prüfen“ (`nightly start <repo>`) und keinen eigenen Schalter „Claude behebt“ je Repo; heute gilt alles global.

## Tests (17)

128. [Test] tests/app (Accounts.swift) – `Accounts` (`cleanLabel`, `cleanKey`, `add`, `remove`, `activate` mit Fake-`SecretStore`) hat keinen Test; das Protokoll `SecretStore` ist schon dafür gebaut.
129. [Test] tests/app (Sessions.swift:30-60) – `SessionsNews.fresh/notes/key` und `SessionsReport`-Dekodierung ohne Test (neue Zustände, Duplikate, Plural bei „n fertig").
130. [Test] tests/app (Nightly.swift:160-210) – `NightlySettings.label`, `summary`, `weekday` und `NightlyReport`-Dekodierung (fehlende Felder älterer Skripte) ohne Test.
131. [Test] tests/app (LogSearch.swift:6-58) – `LogGroups.signature/group/search` (Hashes, Zeiten, Zahlen, Gruppierung, 20-Treffer-Grenze) ohne Test.
132. [Test] tests/app (PerfGuard.swift) – `PerfStatus`/`CheckRun`-Dekodierung, `PerfText.gb/top` und `PerfMonitor.refresh` (veraltete Datei >180 s) ohne Test.
133. [Test] tests/app (Store.swift:1440-1520) – Warteschlange: kein Test für „doppelter Klick", „Rollback während Deploy" und „Abbrechen in der Rückgängig-Frist" (`enqueue`, `pump`, `cancel`).
134. [Test] tests/app (Model.swift:516-556) – `RowAutofix.of` hat viele Zweige (`done`, `closed`, `merged` mit fremdem Sha); Tabellentest mit allen Kombinationen aus `status` × `prState` × `done` × `mergedSha`.
135. [Test] tests/app (DeployWindowConfig.swift:35-76) – `problem`, `parse`, `encoded(over:)` (unbekannte Felder bleiben, Reihenfolge, `dates`) nur teilweise getestet; Fall „window.json mit Kommentaren/BOM".
136. [Test] tests/app (CommandPalette.swift:20-60) – `fuzzyScore`/`paletteOrder` ohne Leistungstest (500 Projekte < 50 ms) und ohne Test für Umlaute und Bindestriche.
137. [Test] tests/app (ClaudeAI.swift:60-85) – `parseCap` (Grenzfälle „1,5m", „1.000k", Überlauf) und `modelName` ohne Test (nicht auffindbar in `tests/app`).
138. [Test] tests/app (QuickFilters.swift:90-120) – `SearchQuery.toggled/cycledPlatform` und `FreezeReply.footerText` ohne Test.
139. [Test] tests/app (ClaudeConnect.swift:150-190) – `ClaudeFiles.write` (Rechte der Sicherung, Aufräumen alter Temp-Dateien, Symlink) hat Tests, aber keine für die Rechte-Lücke zwischen `copyItem` und `setAttributes`.
140. [Test] tests/app (SettingsSupport.swift:56-60) – Kein Test, dass `defaultsKeys` keine Sicherheits- oder Datenschutzschalter (`ownerCheck`, `demoMode`) enthält; ein Vertrags-Test verhindert Regressionen.
141. [Test] tests/app (Speech.swift:30-36) – `Speech.summary` hat keinen Test mit 1/2 Projekten (EN/DE); der Plural-Fehler wäre aufgefallen.
142. [Test] tests/app (JournalStats.swift:51-72) – `JournalStats.dora` (Rollback nach Fehler, offene Fehler pro Projekt, `days == 0`) und `cause` (Normalisierung von IDs/Hashes) mit Tabellentests; aktuell nur über Aufrufer berührt.
143. [Test] tests/app (Store.swift:1950-2024) – `cleanPath`/`cleanPaths`/`checkLinks`: Query mit Komma, Pfad mit `%`, Link mit Pfad/Query, mehr als fünf Pfade.
144. [Test] tests/app (Savings.swift:205-215) – Kein Test für `SavingsModel.loadSimulation` mit gleichzeitigen Aufrufen (mit `Tool.testRunner`, Tool.swift:168): nach dem Fix muss genau ein Lauf starten und `cancelSimulation` ihn beenden.

## Code-Qualität (6)

145. [Code] Store.swift:80-95 (`loadExtras`) – Mehrere `UserDefaults`-Schlüssel mit Zusatz je Projekt (`certWarned.<key>`, `budgetAlarm/…`, `budgetOverAlarm/…`) werden nie bereinigt; für gelöschte Projekte wachsen sie unbegrenzt. Beim Start gegen vorhandene Projekte abgleichen.
146. [Code] Tool.swift:259-277 – Die beiden `readabilityHandler` für stdout und stderr sind bis auf `c.out`/`c.err` identisch; eine gemeinsame Funktion `drain(handle, into:)` verhindert Abweichungen.
147. [Code] Store.swift:1940-1953 – Persistente Dictionaries (`healthPaths`, `notes`, `autoRollback`, `criticalProjects`, `pinned`, `waitingHistory`) liegen als lose `UserDefaults`-Schlüssel, jeweils mit eigener Lade-/Speicherlogik; ein typisiertes `ProjectMarks`-Modell (Codable, versioniert) würde Migration und Reset (`clearMarks`) vereinheitlichen.
148. [Code] Row.swift:366-370 – `Row.relative` (RelativeDateTimeFormatter) setzt die Sprache einmal beim Start; Hinweis im Code fehlt, dass ein Sprachwechsel erst nach Neustart gilt, und der Test dafür (`AppLanguage.running`) fehlt.
149. [Code] SettingsSupport.swift:~176 (`SettingsText.shortcuts`) und ShortcutSheet.swift:21 – Zwei Tastenkürzel-Listen: die Hilfe-Tab-Liste (App.swift:549) ist veraltet (kein ⌥⌘1–4, kein ⌘Y, kein ⇧⌘U) und widerspricht dem Kommentar, die Liste sei an einer Stelle. `ShortcutCatalog.groups` auch im Tab Hilfe benutzen.
150. [Code] Notify.swift:26, 55, 79, 95 – Die Prüfung `quiet(hour: Calendar.current.component(.hour, …), from:, to:)` steht viermal mit den `quietFrom`/`quietTo`-Schlüsseln als Literale (auch in Store, QuietDigest, App); eine `QuietHours`-Struktur mit `isQuiet(now)` und `endsIn(now)` verhindert Abweichungen.

# B. CLI und Provider

# Neue Verbesserungen für das Bash-CLI (deploys, lib/, providers/, man/, scripts/)

Stand: Repo 0.14.0, bash 3.2. Nichts im Repo geändert.
Jeder Punkt wurde gegen `docs/IDEEN*.md` und `CHANGELOG.md` per grep geprüft (Schlüsselwörter, deutsch und englisch).

Kennzeichnung:
- **[V]** verifiziert: im Code gelesen und/oder mit dem Skript beziehungsweise `af_mask` ausgeführt (offline, Test-Config in /tmp).
- **[I]** Idee: im Code als Lücke erkennbar oder Feature; die Schlüsselwörter haben 0 bis 1 Treffer in IDEEN/CHANGELOG, nicht ausgeführt.
- **[T]** Teilweise bereits notiert: der Punkt ist enger oder anders als der genannte IDEEN-Eintrag (Nummer genannt).

---

## A. Bugs (verifiziert)

1. [Bug][V] `deploys:671` `cert_days_left`: `date -j -u -f '%b %e %T %Y %Z'` liest englische Monatsnamen mit dem Locale des Nutzers. Unter `LANG=de_DE.UTF-8` schlägt jede Umwandlung fehl (getestet: Dec, Mar, May, Oct), der Rückfall `date -d` gibt es auf macOS nicht. Folge: `deploys certs` zeigt für jeden Host "unknown", `verify --cert-days` schweigt. Fix: `LC_ALL=C date -j ...` (wie `deploys:1188`).
2. [Bug][V] `lib/http.sh:75` `http_retry_after`: Das Datumsformat `%a, %d %b %Y` wird mit demselben Locale gelesen; unter `de_DE` wird ein `Retry-After` als Datum still ignoriert und der feste Backoff 3 bis 5 s genommen. Gleicher Fix `LC_ALL=C`.
3. [Bug][V] `deploys:1227-1231` `TEAM_WINDOW_RULE`: Das geteilte Erlaubnis-Fenster mit `from > to` (22:00 bis 06:00) prüft `.days` immer gegen den heutigen Tag. Fr 03:00 gilt als offen, Sa 03:00 als zu, obwohl das Fenster "Freitagnacht" heißt. Das lokale `WINDOW_RULE` (`deploys:1171-1181`) kennt den Vortag, das Team-Fenster nicht. [T: kein IDEEN-Eintrag zu TEAM_WINDOW_RULE]
3a. [Bug][V] `deploys:1244` `team_window_denied`: Bei einer Liste von Fenstern wird nur `.[0].tz` als Zeitzone für alle genommen. Fenster mit verschiedenen `tz` werden in der Zone des ersten gerechnet, obwohl `says` jedes mit eigener Zone ausgibt.
4. [Bug][V] `providers/ghpages.sh:179` (und `:103`): Der neue Lauf wird nur über `id > $prev` auf dem Branch erkannt. Ein gleichzeitiger `push`- oder `schedule`-Lauf desselben Workflows wird als "der Dispatch" gemeldet und gewatcht. Fix: `event=workflow_dispatch` in der Abfrage und im Filter.
5. [Bug][V] `lib/perfclean.sh:106` und `:239`: Nach TERM an die Prozessgruppe (`kill -TERM -- -pid`, Regel P) geht das KILL nur an `$pid`, nicht an die Gruppe. Überlebende Renderer-Prozesse eines Test-Browsers bleiben stehen.
6. [Bug][V] `deploys:3343` `team list`: Ohne Repos gibt der Befehl nichts aus und endet mit Exit 1 (`grep -E` ohne Treffer in `team_repo_list`, `lib/team.sh:74`, unter `pipefail`). Ausgeführt. Erwartet: "No repos" und Exit 0.
7. [UX][V] `deploys:3334` `team add`: Ohne `gh`, offline oder mit `DEPLOYS_NO_GITHUB` wird das Repo gespeichert, aber es erscheint keine Zeile (das `jq` bekommt keine Zeile für das Repo). Ausgeführt: Exit 0, leere Ausgabe.
8. [Bug][V] `lib/export.sh:41`: `export --what costs --days 365` kürzt still auf 90 Tage. Das Feld `reason` nennt es nicht; bei `--what all` hat das Journal 365 Tage und die Kosten 90.
9. [Bug][V] `deploys:4531-4534` `creds`: Ein eingeschalteter Anbieter ohne Schlüssel (`source: missing`) erscheint als "NOT accepted" und setzt den Exit-Code 1. Er ist nicht abgelehnt, er ist nicht eingerichtet. Zwei Zustände trennen (`missing`/`rejected`), Exit 1 nur für abgelehnt.
10. [Bug][V] `deploys:553-559` globale Flags: `--json`, `--quiet`, `--debug` und `--force` werden überall in den Argumenten entfernt, auch als Wert einer Option (`ai ask p --question "--json"`, `freeze add ... --reason --quiet`). Nach `--` bleibt alles stehen, aber nur wenn der Nutzer es weiß. Fix: Optionen mit Wert vorher erkennen oder `--question=...` unterstützen.
11. [Bug][V] `deploys:2871` `<cmd> --help`: Ein unbekannter Befehl mit `--help` endet mit Exit 1 ("No help for"), ein unbekannter Befehl ohne `--help` mit Exit 2. Gleich behandeln (2).
12. [Bug][V] Exit-Codes bei falschen Werten: `completion elf` (`lib/completion.sh`, "zsh, bash or fish"), `freeze add xyz`, `freeze remove 0`, `export --format xml`, `idle --days x`, `price set vercel abc` enden mit 1; `freeze remove abc`, `budget set 1e3`, `readonly maybe`, `freeze import /nonexistent.ics` mit 2. `die` (`deploys:323-327`) wählt 2 nur bei den Präfixen `Usage:`/`Unknown option`/`Unknown command`. Rest von IDEEN-518 (dort nur Fehlbedienung allgemein): ein `die_usage`-Aufruf für jede Wertprüfung. [T: #518]
13. [UX][V] `lib/digest.sh:89` (ebenso `lib/export.sh`, `lib/insights.sh`): `--days 99999999999999999999` druckt zuerst die rohe bash-Meldung `[: ...: integer expression expected` auf stderr, dann den eigenen Fehler. Länge der Ziffernfolge vorher prüfen (`${#2} -le 4`).
14. [UX][V] `lib/export.sh:62-64` `export_write`: Bei einem nicht vorhandenen Ordner steht `mktemp: mkstemp failed on /nonexistent/dir/.export.N8n24Z` (rohe Meldung mit zufälligem Namen) vor "Could not write in ...". `mktemp ... 2>/dev/null` oder den Ordner vorher prüfen.
15. [UX][V] `deploys:4645` Tippfehler-Hinweis: `deploys foo` schlägt `fly, hook` vor (Abstand <= 2 bei Dreibuchstaben-Wörtern, auch für ausgeschaltete Anbieter). Abstand 2 erst ab 5 Zeichen erlauben und nur eingeschaltete Anbieter nennen.
16. [Bug][V] `deploys:3512` `status --watch`: feste 10 s, keine Option `--interval`; `clear` bei jeder Runde auch wenn stdout kein Terminal ist (`clear 2>/dev/null` schreibt dann Steuerzeichen in Pipes/Dateien). `[ -t 1 ]` prüfen.
17. [Bug][V] `lib/githost.sh:132,146`: GitLab-Aufrufe warten fest 2 s und 4 s; ein `Retry-After` wird anders als in `lib/http.sh` nicht gelesen (die `glab`-Variante sieht ihn gar nicht). Bei 429 sofort wieder zu fragen verbraucht den Versuch.
18. [UX][V] `lib/githost.sh:144`: Im curl-Zweig geht stderr nach `/dev/null`. Bei Netzfehler steht `gitlab: HTTP 000: ` ohne Grund (Zertifikat, DNS, Timeout). `err`-Datei wie im glab-Zweig verwenden.
19. [Bug][V] `deploys:301-312` `with_timeout`: Die Perl-Variante setzt `alarm` und `exec`; SIGALRM trifft nur den Prozess selbst. Kinder (`gh` startet `git`/`ssh`, ein Hook ein Subshell-Baum) bleiben als Waisen. `deploys:359-361` (`cli_limit`) tötet nur `$pid`. Mit `setsid`/Prozessgruppe und `kill -TERM -$pgid` arbeiten.
20. [UX][V] `deploys:629-633` `key_of` mit `<NAME>_CMD`: `2>/dev/null` verwirft die Fehlermeldung des Befehls (`op` gesperrt, `pass` ohne Agent). Es erscheint nur "printed no key". Letzte Zeile von stderr (maskiert) mitgeben.
21. [Perf][V] `deploys:619-640`, `:675-680` `key_of`/`key_of_env`/`key_env_names`: Jeder Aufruf startet `<p>_meta | grep | sed | grep` (4 Prozesse), und ein `*_CMD` läuft bei jedem Aufruf neu (1Password fragt dann je Aufruf nach Touch ID, auch aus `xargs`-Lesern). Ergebnis je Prozess und Anbieter in einer Variable halten; `*_CMD` höchstens einmal je Lauf.
22. [Bug][V] `deploys:625` `key_of`: Schlüssel mit `"` oder `\` werden abgelehnt, obwohl `curl_cfg_quote` (`lib/http.sh:26-30`) sie sicher maskiert. Die Prüfung ist strenger als nötig; nur Steuerzeichen ablehnen (ein Schlüssel mit `"` ist selten, aber die Fehlermeldung nennt dann keinen Weg).
23. [Bug][V] `lib/http.sh:88` `http_trace`: "ms" wird als `(Sekunden * 1000)` gerechnet, also immer ein Vielfaches von 1000, und `t0` liegt vor allen Wiederholungen (Wartezeit eingerechnet). Die Zeile `(~N ms)` ist für `--debug` irreführend. Zeit je Versuch und mit `perl -MTime::HiRes` oder `date +%s%N` wenn vorhanden.
24. [Bug][V] `lib/hooks.sh:140`: `mv ... && mv ... || die` kann nach dem ersten Erfolg beim zweiten scheitern und lässt `*.deploys` ohne den Wrapper zurück (halb installiert). Rollback des ersten `mv` im `||`-Zweig.
25. [Bug][V] `lib/freeze.sh:107-114` `freeze_ics_events`: `DTSTART;TZID=Europe/Berlin:...` wird auf `DTSTART` gekürzt, `TZID` verworfen. Ein Termin ohne `Z` gilt als Zeit der `window.json`-Zone, auch wenn der Kalender in einer anderen Zone steht. Mindestens warnen, wenn ein `TZID` von `tz` der `window.json` abweicht.
26. [Bug][V] `providers/digitalocean.sh:152`: Nach 50 Seiten (5000 Apps) bricht `digitalocean_apps` still ab; Netlify (`netlify.sh:171`) und Deno melden es. Außerdem fehlt die Prüfung `type == "array"`/`.apps` wie bei Netlify/Deno: ein HTML-Fehler als 200 ergibt eine leere Liste statt eines Fehlers (`:149`).
27. [Perf][V] `providers/digitalocean.sh:149`, `providers/netlify.sh:167`: Jede Seite führt `jq -s '.[0] + .[1]'` über das gesamte bisherige Ergebnis aus (quadratisch). Die Seiten in Dateien sammeln und einmal mit `jq -s 'add'` verbinden.
28. [Bug][V] `deploys:3074` und `:2838`: `freeze_check $members` und `printf '%s\n' $out` ohne Anführungszeichen. `safe_arg` (`deploys:2800`) lässt `*` im Namen zu; ein Gruppenmitglied `*` wird gegen das aktuelle Verzeichnis ausgeklappt. Mit `set -f` oder `while read` arbeiten.
29. [UX][V] `lib/risk.sh:11` `re_mig`: `\.sql$` macht jede `.sql`-Datei (Testdaten, Fixtures, Seeds) zu "migrations / red". Nur bekannte Ordner und Muster `^\d+_.*\.sql$` rot, übrige `.sql` gelb.
30. [Bug][V] `lib/risk.sh:54,61,64` `hook_run`: Rechte aus `ls -ld | cut -c1-10` zwischen Prüfung und Ausführung (TOCTOU) und mit ACL-Zeichen in Spalte 11 fehleranfällig. `stat -f %Sp`/`stat -c %A` (beide Varianten vorhanden) und Hash des Skripts vor dem Start.
31. [Bug][V] `lib/digest.sh:33`, `lib/insights.sh:136-137`: "Busiest day"/`when --by hour` rechnen in UTC, `freeze`/`window.json` in Ortszeit. Für Berlin verschiebt sich der Tag und die Stunde um 1 bis 2 Stunden. Option `--tz local|<Zone>`; `now_parts` (`deploys:1184`) gibt es schon.
32. [UX][V] `deploys:3346,4358,4396`, `lib/nightly.sh:45`, `providers/vercel.sh:579`, `providers/hook.sh:520`: `strftime` in jq gibt UTC ohne Kennzeichnung aus ("2026-11-26 14:05"). Nur `team journal` schreibt "(UTC)". Spalte mit `UTC` benennen oder lokal ausgeben.
33. [UX][V] `deploys budget set 0` wird angenommen ("Budget: $0 a month") und stoppt dann jedes `deploy-changed --yes`; `1e3` wird abgelehnt. 0 entweder verbieten oder als "aus" erklären; Exponentialschreibweise gleich behandeln.

## B. Sicherheit und Geheimnisse (verifiziert)

34. [Sicherheit][V] `providers/hook.sh:84` `hook_private_host`: Die IPv6-Liste kennt `::ffff:*` und `0:0:0:0:0:0:0:*`, aber nicht die ausgeschriebene Form `0:0:0:0:0:ffff:7f00:1` (und `0000:...`, `::127.0.0.1`). Diese Adressen führen zu 127.0.0.1; der Hook-URL-Test (`hook_check_url`) lässt sie durch, `hook_pin` pinnt IPv6-Literale nicht (`:117`). Kanonisieren (Gruppen mit führenden Nullen entfernen, `::` auflösen) oder jede IPv6-Adresse mit `ffff`-Gruppe ablehnen.
35. [Sicherheit][V] `lib/digest.sh:32`, `lib/insights.sh:28`, `deploys` `journal search`/`journal report`: Die Journal-`detail`-Texte gehen ohne `af_mask` an die Ausgabe (Digest als Markdown für Wiki/Chat, `--json` für Skripte). Nur `lib/export.sh` maskiert (`export_mask_details`). `journal_add` (`deploys:1303`) schreibt rohe Details (zum Beispiel einen von Hand getippten `--force "reason"`). Maskieren beim Schreiben, nicht erst beim Lesen. [T: #420/#421 betreffen `af_mask`-Muster, nicht das Journal]
36. [Sicherheit][V] `af_mask` (`deploys:1563`): Folgende Formate laufen unmaskiert durch (ausgeführt): Google-OAuth `ya29.…`, Google `GOCSPX-…`, Shopify `shpat_…` (in #420 genannt), PyPI `pypi-AgEI…`, Docker `dckr_pat_…`, Twilio `SK<32 hex>`, Mailgun `key-<32 hex>`, 1Password `ops_eyJ…`. Mindestens `ya29.` und `GOCSPX-` stehen in keinem IDEEN-Eintrag.
37. [Sicherheit][V] `af_mask`: `curl -u admin:hunter2hunter2 https://…` wird nicht erkannt (kein Namenswort, kein `--password`). Regel für `-u user:pass`/`--user` ergänzen.
38. [Sicherheit][V] `af_mask`: Die Regel "NAME=wert" maskiert nur das erste Wort. `password: my secret pass phrase` ergibt `[masked] secret pass phrase`; `client_secret=abc def` lässt `def` stehen. Bis Zeilenende maskieren, wenn der Name "passphrase|password|secret" enthält und kein Anführungszeichen folgt.
39. [Sicherheit][V] `af_mask`: Ein Wert in Anführungszeichen mit maskiertem Anführungszeichen (`token="abc\"def ghi"`) wird nach `\"` abgeschnitten: `token=[masked]def ghi"`. `"(?:[^"\\]|\\.)*"` im Muster.
40. [Sicherheit][V] `af_mask`: Datenbank-URLs mit `/` im Passwort (`postgres://user:p/ss@db/app`) bleiben zur Hälfte stehen (`user:p/[email]/app`); `(://[^/\s:@]+):[^\s/]+@` endet am ersten `/`. Besser bis zum letzten `@` vor dem nächsten Leerzeichen.
41. [Sicherheit][V] `providers/heroku.sh:19`, `providers/netlify.sh:21`, `providers/cloudflare.sh:25`: Die API-Basis ist per `HEROKU_API`, `NETLIFY_API`, `CLOUDFLARE_API_BASE` überschreibbar, und kein Aufruf (`heroku.sh:59`, `netlify.sh:126`, `cloudflare.sh:129`, `lib/http.sh:114`) setzt `--proto '=https'`. Eine versehentliche `http://`-Basis schickt den Schlüssel im Klartext (Coolify prüft das in `coolify.sh:63`, `digitalocean.sh:141` setzt `--proto` nur für Downloads). `https` erzwingen, `http://localhost` nur mit `DEPLOYS_TESTING=1`.
42. [Sicherheit][V] `deploys:3334-3353`, `lib/team.sh:74`: `team add ../x` und `./x` bestehen `team_repo_arg` und das Muster `[A-Za-z0-9_.-]+/[A-Za-z0-9_.-]+`; `gh api repos/../x/contents/...` hat dann einen Punkt-Pfad. `.` und `..` als Teile ablehnen.
43. [Sicherheit][V] `providers/hook.sh:273`: `gh api "repos/$repo/commits/$ref"` mit unkodiertem `$ref` aus der Hook-Konfiguration (`#`, `?`, `%` in Branch-Namen verändern den Pfad). Mit `jq -rn '$r|@uri'` kodieren.
44. [Sicherheit][I] `providers/hook.sh:80-110` `hook_pin`: Ist `HTTPS_PROXY`/`ALL_PROXY` gesetzt, löst der Proxy den Namen selbst auf; die `resolve =`-Zeile und die Prüfung gegen private Adressen sind dann wirkungslos. Bei gesetztem Proxy `noproxy = "*"` in die Config schreiben oder die Prüfung dem Nutzer melden.
45. [Sicherheit][I] `deploys:1613-1640` und `:2631-2645`: Die Aufrufe an die Routine-API und Anthropic setzen `--proto`/`--max-redirs` ebenfalls nicht; Aufruf mit `-K -` aber ohne `--proto =https`.
46. [Sicherheit][I] `lib/team.sh:30-35`: Die geteilte `deploy-center.json` wird vom Default-Branch ohne Commit-Pin gelesen. Jeder mit Push-Recht auf den Default-Branch ändert `approvals` und `window`. Option `team pin <repo> <sha>` (und Anzeige des Commits in `team list`).
47. [Sicherheit][I] `deploys:1303-1320` `journal_add`: Die Hash-Kette (`prevHash`) schützt nur gegen Einzelzeilen-Änderung; wer die Datei neu schreibt, schreibt auch die Kette neu. Das Ende der Kette (letzter Hash) bei jedem `journal verify` in die Keychain/eine zweite Datei legen oder per HMAC mit einem Schlüssel der Keychain verketten (HMAC: 1 Treffer in IDEEN, nur Idee ohne Umsetzung).
48. [Sicherheit][I] `lib/risk.sh:50-73` `hook_run`: Hooks bekommen die gesamte Umgebung (in #402 notiert); zusätzlich fehlt ein Hash-Pinning: `hooks.d/sha256sums` und Prüfung vor dem Start.

## C. Fehlerbehandlung, Ausgabe, Exit-Codes (Idee)

49. [Feature][I] `--fields a,b` für `--json` (Spaltenauswahl wie `gh --json`); `--jq '<filter>'` gibt es als Idee (2 Treffer), `--fields` 0.
50. [Feature][I] `deploys list --state failed|building|live`, `--sort name|age|state`, `--limit n` (`deploys:4469`; `--state` und `--sort` ohne Treffer, #-Eintrag nur zu Spalten).
51. [Feature][I] Alle Befehle mit `--json` als maschinenlesbares Schema veröffentlichen (JSON Schema je Befehl, `docs/schema/*.json`) und `tests/contract-json.sh` dagegen laufen lassen (0 Treffer für "JSON Schema").
52. [Feature][I] Ein globales `--no-header`/`--plain` für Tabellen (`table`-Funktion): TSV ohne Kopf, ohne Farben, ohne Spaltenpolsterung; heute nur `list --format tsv`.
53. [UX][I] `COLUMNS`/`tput cols`: Tabellen (`table`) kürzen nie lange Namen; auf schmalen Terminals brechen Zeilen um. `--wide`/Kürzung mit `…`.
54. [UX][I] Pager: Lange Ausgaben (`history`, `journal search`, `config`) bei Terminal-Ausgabe durch `${PAGER:-less -FRX}` leiten (PAGER: 1 Treffer, nur CLICOLOR).
55. [UX][I] `NO_COLOR` wird gelesen; `CLICOLOR_FORCE`/`FORCE_COLOR` für CI-Logs nicht.
56. [Feature][I] `DEPLOYS_RETRIES`, `DEPLOYS_HTTP_TIMEOUT` (heute nur intern `HTTP_MAX_TIME`, `HTTP_DEADLINE` in `lib/http.sh:15,98`) als dokumentierte Einstellungen und als Flags `--timeout`/`--retries`.
57. [Feature][I] Eigene CA und Proxy dokumentieren und testen: `SSL_CERT_FILE`/`CURL_CA_BUNDLE` (0 Treffer) und `--cacert` für Coolify-Instanzen mit eigener CA (`providers/coolify.sh:111-130`).
58. [Feature][I] `deploys deploy --at 17:30` (einmalig, per `at`/launchd `StartCalendarInterval` einmalig) statt nur `schedule daily`; `--at` 0 Treffer.
59. [Feature][I] `deploys schedule daily` kennt genau einen Eintrag (`schedule.json` `.daily`, `deploys:4570-4590`). Mehrere benannte Zeitpläne (`schedule add <name> <HH:MM> -- <deploy-changed args>`).
60. [Feature][I] `deploy --on-success '<cmd>'`/`--on-failure` direkt am Aufruf (neben `hooks.d`); `on-success` 0 Treffer.
61. [Feature][I] `max concurrent` (0 Treffer): globale Obergrenze gleichzeitiger Starts über alle Anbieter (`deploy-changed --max` begrenzt nur die Anzahl, nicht die Parallelität; Gruppen laufen nacheinander).
62. [Feature][I] `deploys cache clear|status`: Die Caches (`names`, `team/`, `locks/`, `.ai-usage`, Ratenlimit) gibt es nur als Dateien; ein Befehl zum Leeren und Anzeigen (0 Treffer für "cache clear").
63. [Feature][I] `DEPLOYS_LANG=de`: Das CLI ist englisch, die App zweisprachig. Mindestens `die`-Meldungen und `--help` aus einer Tabelle (`locale/de.sh`); 0 Treffer.
64. [Feature][I] Fehlermeldungen mit Fehlercode (`E-AUTH-401`, `E-RATE-429`) und `deploys explain-error <code>`; heute nur Freitext in `http_call` (`lib/http.sh:147-158`).
65. [Feature][I] Eine `--output-file <path>` für alle `--json`-Befehle, atomar mit 0600 geschrieben (nur `export` hat `--out`).
66. [Feature][I] `--since <date|duration>`/`--until` für `export`, `digest`, `timeline` statt nur `--days` (`--since` kommt in 8 Treffern für andere Befehle vor, nicht für Journal-Berichte).
67. [Feature][I] `export --format ndjson` und `--result failed|rollback`, `--platform` (`lib/export.sh:20-23` filtert nur nach `--project`).
68. [Feature][I] `export --format sarif` für `deploys check` (Sicherheits-Funde; SARIF 0 Treffer) zum Hochladen in GitHub Code Scanning.
69. [Feature][I] `journal` nach syslog/`logger` spiegeln (`DEPLOYS_JOURNAL_SYSLOG=1`); 0 Treffer für syslog.
70. [Feature][I] Unterschiedliche Konten je Anbieter (zwei Vercel-Teams, zwei Render-Konten): `profile` (8 Treffer, meist App) - im CLI: `DEPLOYS_PROFILE=work` wählt `deploy-center-<p>-<profile>` im Schlüsselbund und `vercel-team`.
71. [Feature][I] `deploys alias add api vercel:my-long-api-name` für kurze eigene Namen (0 Treffer für "deploys alias"), nützlich mit Completion.
72. [Feature][I] `deploys prompt` (Starship/PS1): eine Zeile, aus dem Cache, ohne Netz (`starship` 1 Treffer, kein Befehl).
73. [Feature][I] `fzf`-Auswahl: `deploys deploy --pick` bei fehlendem Namen (0 Treffer für fzf).
74. [Feature][I] `deploys completion powershell|nushell|elvish` (0 Treffer); und `completion --install` (steht in #35, aber nur für zsh).

## D. Completion (verifiziert)

75. [UX][V] `lib/completion.sh:63-76` `flags_table`: Es fehlen Flags für `ai` (`--question`, `--lang`, `--json`), `autofix` (`--dry-run`, `--only`, `--again`, `--preview`), `ci` (`--exit-code`), `changed`, `notes`, `diff`, `costs`, `triggers`, `scan start`/`check start` (`--findings`), `nightly` (`on`/`off`/`review`) und `journal search`. Die Zeilen stehen in der Hilfe (`deploys:55-79`), aber nicht in der Tabelle. Ein Test sollte jede `--flag` der Kopfzeilen-Hilfe in der Tabelle suchen (Drift-Test, vgl. `scripts/check-cli-docs.py`).
76. [UX][V] `lib/completion.sh:16-60` `subs_table`: Für `rollback --to <id>`, `logs --id <id>`, `watch <p> <id>`, `verify --path` gibt es keine Werte-Completion (Deploy-Ids aus `history <p> --json`, Pfade aus `health`). Nur Projektnamen.
77. [Bug][V] `lib/completion.sh:55,141`: Die Namensliste `names` wird nur von `cache_name`/`names.json` gefüllt (`deploys:969-981`) und nie neu geladen; ein neues Projekt erscheint erst nach einem `list`. `completion` sollte beim ersten Tab im Hintergrund `deploys list --format tsv` anstoßen, wenn `names` älter als 1 Tag ist.
78. [UX][I] Completion ohne Beschreibungen: zsh `_describe`, fish `-d` (0 Treffer für "descriptions"). Die Beschreibungen stehen schon im Kopfblock von `deploys:20-100`.
79. [Test][I] `zsh -n`, `bash -n` auf der Completion-Ausgabe läuft (geprüft: beide gültig); `fish --no-execute` fehlt in den Tests (fish nicht installiert, Test mit `command -v fish` überspringen).

## E. Provider: fehlende Fähigkeiten und Konsistenz

(Fähigkeiten: `caps` in `<p>_meta`. Hinweis "API prüfen": die Fähigkeit nach Dokumentation des Anbieters prüfen, nicht im Code ausprobiert.)

80. [Feature][I] `providers/cloudflare.sh:207`: `cancel:false`; die Pages-API kennt eine Abbrechen-Anfrage für laufende Deployments (API prüfen). 0 Treffer "Cloudflare" + cancel.
81. [Feature][I] `providers/koyeb.sh:59`: Alle `caps` sind `false`. Koyeb hat Redeploy, Abbrechen und Logs in der API (API prüfen). `rollback` und `cancel` wären der größte Gewinn.
82. [Feature][I] `providers/northflank.sh:84`: `cancel`, `rollback`, `logs` `false`; Northflank hat Build-Abbruch und Logs (API prüfen).
83. [Feature][I] `providers/fly.sh:79`: `logs`/`rollback` fehlen; `fly releases` und Machines-API kennen frühere Image-Versionen (API prüfen).
84. [Feature][I] `providers/heroku.sh:117`: `cancel:false`, obwohl Builds sich abbrechen lassen (API prüfen); `sha:false` (Heroku baut aus dem Slug-Quell-URL, daher nur mit GitHub-Quelle möglich).
85. [Feature][I] `providers/railway.sh:88`: `off:false`; Railway kann Auto-Deploy-Trigger über die GraphQL-API ausschalten (API prüfen). Das Kernversprechen des Tools ("Auto-Deploy aus") fehlt dort.
86. [Feature][I] `providers/netlify.sh:251`: `logs:false`, obwohl `netlify.sh` Deploys kennt; der Build-Log eines Deploys ist über die API lesbar (API prüfen).
87. [Feature][I] `providers/deno.sh:74`: nur Lesen/Starten; `logs:false`.
88. [Feature][I] `providers/hook.sh`: Kein `caps`-Objekt im Meta (nur Fließtext `note`); `doctor`/`need_cap` müssen den Anbieter dann einzeln behandeln. Im Kontrakt (`docs/PROVIDERS.md`) `caps` verlangen und `tests/providers/contract.sh` darauf prüfen.
89. [Code][I] Sechs Anbieter haben einen eigenen `*_call` mit Retry-Schleife (`render.sh:47-70`, `netlify.sh:107-135`, `cloudflare.sh:105-140`, `heroku.sh:43-70`, `digitalocean.sh:83-115`, `coolify.sh:108-135`), obwohl `lib/http.sh` das gleiche kann (PRV-130). Folge: `Retry-After` als Datum (A2), `--debug`-Trace und Fehlermaskierung gelten nur dort, wo `http_call` benutzt wird. Zusammenführen.
90. [Test][I] `tests/providers/contract.sh`: Gegen die Tabelle `CONTRACT_VERBS` (`deploys:2831`) prüfen, dass jeder Anbieter mit `caps.logs=true` auch `<p>_logs` definiert und umgekehrt.
91. [Feature][I] Neue Anbieter (0 Treffer): Cloud Run (`gcloud run services update-traffic`), Cloudflare Workers (`wrangler`/Workers-API, nicht Pages), Scalingo, Clever Cloud, Zeabur, Sevalla, Dokploy, CapRover, Dokku (SSH), Surge, Bunny. Mit `scripts/new-provider.sh` anlegen.
92. [Feature][I] Render: Cron-Jobs und Background-Worker als eigene Art von Dienst (`noun`); `deploys render list` zeigt nur Web-Dienste/Static Sites (`render.sh:83-95`; prüfen).
93. [Feature][I] Statusseite des Anbieters vor dem Deploy prüfen ("Vercel meldet eine Störung", `plan`): `status page` 8 Treffer im CHANGELOG, aber nicht für Provider-Störungen (`incident` 1 Treffer, Swift).

## F. Skripte, Doku, man

94. [Doku][V] Undokumentiert (weder `docs/*.md` noch README noch `man`): `DEPLOYS_PERF_NOTIFY_CMD` (`lib/perfclean.sh:249`, wird als ein Pfad ohne Shell aufgerufen mit zwei Argumenten), `DEPLOYS_PERF_KILL_AFTER` (`:102,236`), `DEPLOYS_PERF_DB_WAIT` (`lib/perfdocker.sh:72`), `DEPLOYS_PERF_NORECORD`, `DEPLOYS_PERF_LABEL` (`:21`), `DEPLOYS_VERCEL_NO_KEYCHAIN` (`providers/vercel.sh:79`).
95. [Doku][V] `man/deploys.1` nennt rund 40 von 90 `DEPLOYS_*`-Variablen nicht (zum Beispiel `DEPLOYS_GHPAGES_SITES`, `DEPLOYS_HOOK_STORE`, `DEPLOYS_GITLAB_TIMEOUT`, `DEPLOYS_UPDATE_BASE`, `DEPLOYS_AMPLIFY_LOG_BYTES`, `DEPLOYS_SCAN_TIMEOUT`, `DEPLOYS_RAILWAY_POLLS`, `DEPLOYS_GHPAGES_POLLS`, `DEPLOYS_NETLIFY_RULE_TTL`). Ein Abschnitt ENVIRONMENT, aus `docs/CLI.md` erzeugt (`scripts/build-man.py`).
96. [Test][V] `scripts/check-env-docs.sh` (neu): Jede `DEPLOYS_*`-Variable aus `deploys`, `lib/`, `providers/` muss in `docs/CLI.md` oder einer Ausnahmeliste stehen. Eine 6-Zeilen-Schleife findet die sechs Lücken aus 94 sofort.
97. [Test][V] Keine Tests nennen `selfupdate_newer` und `http_notfound_hint` (grep über `tests/`). Vergleich von `0.9.10` gegen `0.10.0`, `0.14.0` gegen `0.14.0`, Pfad `/v1/projects/x` und `/api/` für den Hinweis.
98. [Test][V] `lib/perfdocker.sh` (185 Zeilen) wird von keinem Test über den Dateinamen erreicht; nur ein Test nennt "perf docker". Start-/Stopp-Reihenfolge (Datenbanken zuerst, `lib/perfdocker.sh:72`) mit gefälschtem `docker` prüfen.
99. [Test][I] Test für `cert_days_left` mit `LC_ALL=de_DE.UTF-8` (A1) und gefälschtem `openssl`-Ausgabe "Dec  1 12:00:00 2026 GMT" (zwei Leerzeichen).
100. [Test][I] Test für `TEAM_WINDOW_RULE` mit Fenster über Mitternacht und Liste mit zwei Zonen (A3, A3a).
101. [Test][I] Test für ghpages: zwei Läufe (`push`, `workflow_dispatch`) nach dem Dispatch; der Test soll den Dispatch-Lauf wählen (A4).
102. [Test][I] Fuzz-Test für `af_mask` (kein Absturz, Laufzeit, nie länger als die Eingabe; IDEEN #787 nennt das für `server.mjs`, nicht für `af_mask`) plus Fixture mit den Formaten aus B36-B40.
103. [Test][I] `shellcheck -S style` läuft in CI auf Warnung; die 21 Treffer von SC2015 (`A && B || C`) und 7 von SC2086 (zum Beispiel `deploys:827,2239,2328,3238`) einmal durchsehen und in `scripts/lint.sh` `-S style` für `lib/` aktivieren (0 Treffer in IDEEN für SC2015).
104. [Test][I] Ein "Locale-Test": `tests/all.sh` einmal unter `LC_ALL=de_DE.UTF-8` laufen lassen (nur ein Zeilenabschnitt in `tests/script-tests.sh`, `LC_ALL` kommt in keinem Test-Kopf vor).
105. [Test][I] `bash 3.2`-Test ausführen (`scripts/check-bash32.sh` prüft Syntax per Muster); zusätzlich ein Lauf der Testsuite mit `/bin/bash` (3.2.57) in CI auf `macos-latest` (prüfen, ob `ci.yml` dort `/bin/bash` benutzt).
106. [Test][I] Test mit Projektnamen, die ein Leerzeichen, `*`, `+`, `=` oder Nicht-ASCII enthalten (`safe_arg` erlaubt sie, `deploys:2800-2804`): Gruppen (`:3074`), Completion-`names`, Journal, `start_lock`-Dateiname.
107. [Test][I] Test für `journal_add` bei veraltetem `journal.jsonl.lock` (Datei statt Ordner): jede Zeile wartet 5 s (`file_lock "$f" 0`, `deploys:1309`, übernimmt nie). Folge-Idee zu #427.
108. [Doku][I] `docs/CLI.md` hat 37 KB; eine Befehlsübersicht aus dem Kopfblock von `deploys:1-100` erzeugen (`scripts/check-cli-docs.py` prüft schon, ob sie übereinstimmt; erzeugen statt nur prüfen).
109. [Doku][I] `man/`: Seiten je Befehl (`deploys-deploy(1)`, `deploys-freeze(1)`) statt einer Seite mit 24 KB; `deploys <cmd> --help` zeigt heute nur die Kopfzeilen-Zeile.
110. [Feature][I] `scripts/package-cli.sh`: SBOM (`sbom.spdx.json`) und Signatur (`cosign`/`minisign`) für das Tarball; bisher nur `checksums.txt` (`lib/selfupdate.sh:52`), und die Prüfung der Signatur in `install.sh`/`self-update`. (SBOM/cosign je 2 bis 4 Treffer als Ideen, nicht umgesetzt.)
111. [Feature][I] `deploys self-update --install` mit Prüfsumme (aktuell "only checks, never installs"): lädt das Tarball, prüft SHA-256 und ersetzt per `mv`; für Brew-Installationen weiter `brew upgrade`.
112. [Feature][I] Nix-Flake/`mise`-Plugin/`asdf` für das CLI (nix/mise je 2 Treffer, sonst nichts), `oh-my-zsh`-Plugin (0 Treffer).
113. [Feature][I] GitHub-Action `deploy-center/cli` (wrapper, `action.yml` hat 20 Treffer: meist `digest/examples`); eine Composite-Action, die das CLI installiert und `deploys deploy-changed --yes --when-green` aufruft.

## G. Funktionen (Idee, ohne Treffer)

114. [Feature][I] `deploys env pull <p>`/`env push` für Variablennamen mit Werten in eine `.env`-Datei 0600 (nur `env-diff` für Namen; "env pull" 0 Treffer). Werte nie auf stdout.
115. [Feature][I] `deploys verify --security-headers` (HSTS, CSP, X-Content-Type-Options; HSTS 1 Treffer) und `--links` (kaputte Links; "broken link" 0 Treffer) als zusätzliche Gesundheitsprüfung nach dem Deploy.
116. [Feature][I] `deploys prune <p> --older-than 90d --keep 20` für alte Vorschau-Deployments (prune 3 Treffer, aber App); Vercel/Netlify/Cloudflare bieten Löschen (immer `--yes`, nie ohne Bestätigung).
117. [Feature][I] `deploys webhook-listen --port 8787` (lokaler Empfänger für Anbieter-Webhooks → `watch`/Notify; 0 Treffer "webhook receiver").
118. [Feature][I] RSS/Atom-Feed des Journals (`export --format atom`; RSS 0 Treffer) für Chat-Tools ohne Webhook.
119. [Feature][I] `watch --notify` (#429 nennt es) und zusätzlich `terminal-notifier`/`notify-send`/`ntfy` als automatische Auswahl (terminal-notifier 0 Treffer, ntfy 2).
120. [Feature][I] `deploys bundle-size`-Vergleich im `risk` (Größe des `.next`/`dist` zwischen den Deploys; 0 Treffer "bundle size").
121. [Feature][I] GitHub Deployments API: Beim Start `POST /repos/{repo}/deployments` und `statuses` setzen, damit PRs den Stand zeigen (1 Treffer; `commit status` 0 in IDEEN).
122. [Feature][I] Git-Tag nach Erfolg (`deploys deploy --tag v1.2.3` oder `release-YYYY-MM-DD`); `git tag` 2 Treffer (nur Release-Skript).
123. [Feature][I] Canary/gestaffelt: Anbieter mit Prozent-Traffic (Vercel Rolling Releases) über `deploy --rollout 10,50,100 --every 10m` (canary 2 Treffer, kein Befehl).
124. [Feature][I] DORA-Zahlen aus dem Journal: Deploy-Frequenz, Lead Time (Commit bis live), Fehlerrate, MTTR (`recovery` hat MTTR-Teile, DORA 4 Treffer als Idee): `deploys dora [--days 90]`.
125. [Feature][I] Flaky-Build-Erkennung: derselbe Commit schlägt fehl und läuft beim zweiten Start durch (`flaky` 2 Treffer, `retry`-Muster im Journal erkennbar).
126. [Feature][I] `deploys holidays DE-BY` (Feiertage als `freeze`-Regeln; "Feiertag" 2 Treffer, kein Import außer `.ics`): eingebaute Listen oder `freeze import --holidays <land>`.
127. [Feature][I] `deploys lock <p> "reason"`/`unlock <p>`: Einzelnes Projekt manuell sperren (ohne Zeitfenster) mit Pflicht-`--force "why"`; `freeze` gilt nur für Zeiten und alle Projekte.
128. [Feature][I] `deploys redeploy <p>` (gleicher Commit noch einmal, ohne neuen Push; `redeploy` 6 Treffer, aber nur Teil von `rollback`).
129. [Feature][I] `deploys promote <p> [<id>]` (Vorschau-Deploy nach Production befördern, Vercel `promote`, Netlify "publish deploy"); `promote` 6 Treffer als Idee, kein Befehl.
130. [Feature][I] Token-Ablauf auslesen: GitHub liefert `github-authentication-token-expiration` im Header; `creds` kann so das Datum zeigen (`expiration` 3 Treffer, `creds` kennt nur das Alter aus der Keychain, `deploys:621`).
131. [Feature][I] Berechtigungen (Scopes) des Schlüssels prüfen: `creds --scopes` fragt `GET /v2/tokens` bei Vercel, `X-OAuth-Scopes` bei GitHub und warnt bei zu weiten Rechten (scope 9 Treffer, aber SaaS-Text).
132. [Feature][I] Linux-Schlüsselbund: `doctor` meldet `secret-tool` (`deploys:3488`), aber `key_of` (`:640`) liest nur `security`. Entweder `secret-tool lookup service deploy-center-<p>` hinzufügen (#443 beschreibt die Lücke, aber nicht den Widerspruch in `doctor`) oder die Zeile in `doctor` streichen.
133. [UX][V] `doctor` (`deploys:3488`) schreibt "ok secret-tool"/"off secret-tool is missing: the keychain (keys fall back to the environment)", obwohl `secret-tool` nirgends benutzt wird. Siehe 132.
134. [Feature][I] `deploys changed --since <duration>` und `--watch` (Dauerlauf mit Benachrichtigung bei neuen Änderungen); `status --watch` zeigt nur Builds.
135. [Feature][I] `deploys diff <p> --stat|--files` (die Dateien des Vergleichs; `risk` nutzt sie intern, `RISK_DEF`), mit `--only risky`.
136. [Feature][I] `deploys who <p>`: wer hat den letzten Deploy gestartet (Journal `cli`/`app`, Anbieter-`creator`); "Wer hat" 0 Treffer.
137. [Feature][I] `deploys explain <p>` (MCP hat `deploys_explain`; im CLI nur `ai explain`, benötigt Schlüssel): lokale Regel-Erklärung ("warum ist `changed` gelb") ohne Modell.
138. [Feature][I] Healthchecks im `deploy --wait`: `verify` läuft nur bei `--rollback-after` o. ä. Standard-Health aus `deploy-center.json` automatisch nach `--wait`.
139. [Feature][I] `deploys groups --graph`: Reihenfolge und Abhängigkeiten als Text-Diagramm (`group list` zeigt nur die Liste).
140. [Feature][I] `deploys doctor --fix` kann `fixes.sh` Befehle nennen, führt sie aber nicht aus (`lib/fixes.sh:14`); `--fix --yes` für die ungefährlichen (`chmod go-w`, `hooks install`).
141. [Feature][I] `deploys config --diff` (lokal gegen geteilte Datei, `team_effective`) und `team validate <repo>` (die geteilte `deploy-center.json` gegen `docs/deploy-center.schema.json` prüfen; `team_fetch_one` parst nur "ist ein Objekt").
142. [Feature][I] `deploys secrets --git-history` (Schlüssel in alten Commits der Projekt-Repos; `secrets` prüft Dateien, `gitleaks` läuft in `check`).
143. [Feature][I] `deploys cost <p>` für Netlify/Render/Cloudflare (nur Vercel hat `costs`, `deploys:3744`; Render-/Netlify-Build-Minuten aus `price` schätzen: `savings.sh` kennt schon `price set <p>`).
144. [Feature][I] OpenTelemetry-Export (OTLP/HTTP-JSON) für Deploy-Ereignisse (OpenTelemetry 2 Treffer; Prometheus-Ausgabe gibt es: `deploys:3177`).
145. [Feature][I] Alerting an PagerDuty/Opsgenie bei `verify` rot (PagerDuty 1 Treffer); `DEPLOYS_NOTIFY_CMD` genügt für Eigenbau, aber ein `--notify pagerduty:<routing key>` ohne Shell.
146. [Feature][I] `hooks.d/` für weitere Ereignisse: `on-rollback`, `on-fail`, `on-freeze` (`hook_run` kennt nur `pre-deploy`/`post-deploy`, `lib/risk.sh:50`).
147. [Feature][I] `deploys report --month` als PDF/HTML-Seite mit Diagrammen (`journal report` ist Markdown): `--format html`.
148. [UX][I] `deploys help <cmd>` als Alias für `<cmd> --help` (0 Treffer "help <").
149. [UX][I] Beim ersten Start ohne Schlüssel: `deploys init` (Assistent: Anbieter wählen, Schlüssel per Pipe, `guard schedule on`). `init`/`wizard` kommen nur als Swift-Onboarding vor.
150. [UX][I] `deploys status --json` und `changed --json` mit einem Feld `stale:true`, wenn Daten aus dem Cache stammen (Offline-Betrieb, `DEPLOYS_NO_GITHUB`).

---

Zählung: 151 Punkte (1 bis 3a, 4 bis 150). Als [V] verifiziert: 1 bis 43 (ohne 44 bis 48), 75 bis 77, 94 bis 98, 133. Der Rest ist Idee/Feature mit Schlüsselwort-Prüfung, im Code nicht ausgeführt.
Nicht gefunden (bereits umgesetzt oder bekannt, daher weggelassen): Zertifikats-Parallelisierung (#506), Redis-URL in `af_mask` (#421), Completion-Installer (#35), Hook-Umgebung (#402), `journal_add`-Lock ohne Wiederholung (#427).

# C. Integrationen

# Integrationen: neue Ideen (Stand 0.14.0)

Gelesen: `integrations/` (mcp, vscode, raycast, alfred, action, badge, digest, docker, hooks, notify, statuspage, claude-code, lib, tests).
Gegen `docs/IDEEN*.md` (v. a. IDEEN-11 Punkte 652-817, IDEEN-12) und `CHANGELOG.md` abgeglichen: nichts hier steht dort.
"(verifiziert)" = ausgeführt oder am Code nachgestellt (Hook-Skripte, `scheduler.sh --check`, `notify.sh --dry-run`, GNU-`stat` im Docker-Container). "(prüfen)" = nur gelesen. Nichts im Repo geändert.
Zeilennummern: `server.mjs` Stand 0.14.0.

## A. MCP-Server (`integrations/mcp/server.mjs`)

1. [Sicherheit] `server.mjs:853-859, 758-766`: `deploys_ci` und `deploys_sessions` nehmen jedes `repo`; der Agent kann CI-, PR- und Session-Stand jedes Repos lesen, das das GitHub-Token des Nutzers sieht, auch private, die nie überwacht wurden. Auf Repos aus `list --json` und die beobachteten Repos begrenzen (`DEPLOYS_MCP_ALLOW_REPOS`).
2. [Bug] `server.mjs:762`: `throw new Error("repo must be owner/name")` statt `ToolError`; der Agent liest "Unexpected error: repo must be owner/name". Gleiche Klasse wie die anderen Prüfungen.
3. [UX] `server.mjs:442`: Die Fehlermeldung für ein verletztes `pattern` sagt immer "use letters, digits and . _ : - only", auch für `platform` (`^[a-z0-9]+$`), `month`, `since`, `result`. Das `description` des Felds oder das Pattern nennen.
4. [Bug] `server.mjs:439-452` vs `:962, :815`: `checkArgs` erzwingt weder `maxLength` (`journal_search.query`, Schema sagt 100) noch `enum` (`deploys_when.by`); das Schema verspricht mehr, als der Server prüft.
5. [Perf] `server.mjs:146-198, 1632`: Lesende Aufrufe laufen unbegrenzt parallel. Ein Agent mit zehn gleichzeitigen `deploys_health`/`deploys_ci`/`deploys_simulate` startet zehn `deploys` mit je `jq`, `gh`, `curl` (Rechnerlast). Eine Warteschlange mit 3 gleichzeitigen Läufen (`DEPLOYS_MCP_MAX_PARALLEL`).
6. [Bug] `server.mjs:1256-1268` vs `:1241-1246`: `underCap()` liest vor dem Start, `noteStart()` schreibt nach dem Start (bis 300 s später). Zwei Server-Prozesse (zwei Clients) bestehen die Stundenobergrenze beide. Den Platz unter dem Lock vor dem Start reservieren und bei Fehlschlag freigeben.
7. [Perf] `server.mjs:1284-1301`: `waitingOf` startet pro Deploy `changed --json` (alle Projekte, GitHub-Aufrufe), nur um eines zu lesen. `deploys preview <p> --json` oder `explain` nutzen, oder `cachedRun`.
8. [UX] `server.mjs:1362-1370, 1348`: `writing` bleibt bis zu 10 Minuten gesetzt, solange die Rückfrage offen ist; ein zweiter Aufruf bekommt "A deploy or rollback is already in progress", obwohl nichts läuft, nur der Mensch noch nicht geantwortet hat. Eigener Text ("waiting for the human's answer to <project>").
9. [Sicherheit] `server.mjs:1339-1347`: Die Rückfrage ist ein einzelnes Häkchen "Yes, do it". Clients mit Auto-Accept oder schneller Bestätigung machen daraus ein Reflex-Ja. Für Produktion und Rollback den Projektnamen eintippen lassen (String-Feld, muss gleich `platform:name` sein).
10. [Sicherheit] `server.mjs:1296-1299`: Der Commit-Text des Branch-Kopfs steht in der Frage an den Menschen; wer pushen darf, kann ihn formulieren ("approved by CTO"). Er gehört in einen eigenen Block "Commit text (untrusted)" mit Autor und SHA, nicht in die Überschrift der Frage.
11. [Feature] `server.mjs:1471-1493` vs `deploys:28`: Die CLI kann `rollback <p> <id>`, das Werkzeug nur "das Deploy davor". Optionales `id` (aus `deploys_rollback_preview.recent`), die Rückfrage nennt es.
12. [Feature] `deploys:29` (`deploys cancel <p> [<id>]`) hat kein Werkzeug: Nach dem Timeout-Hinweis (`server.mjs:331-335`) kann der Agent einen falsch gestarteten Build nicht stoppen. `deploys_cancel` hinter denselben Sperren (`ALLOW_DEPLOY`, Rückfrage, Positivliste).
13. [Bug] `server.mjs:341, 387`: Bei Exit 1 mit Liste (ein Projekt nicht lesbar) hängt `exitNote` an das JSON; `JSON.parse` scheitert, `structuredContent` ist nur noch der Hinweis. Ausgerechnet im Teilfehler-Fall verliert der Agent die typisierten Daten. Warnung als Feld (`{result, warnings}`) statt Anhang.
14. [API-Konsistenz] `server.mjs:620-629, 1144-1151, 1173-1198`: `deploys_cost`, `deploys_providers`, `deploys_simulate`, `deploys_ledger` liefern JSON, haben aber kein `json: true`: kein `outputSchema`, kein `structuredContent`, anders als ihre Geschwister.
15. [Sicherheit] `server.mjs:1506-1515`: Die `instructions` nennen die "untrusted"-Werkzeuge von Hand und lassen `deploys_preview`, `deploys_journal_search` und die Resource-Templates aus. Liste aus den Werkzeugen erzeugen, die `untrusted()` aufrufen; ein Test prüft die Gleichheit.
16. [Feature] `server.mjs:1502-1505`: `serverInfo` ohne `title`, `websiteUrl`, `icons` (MCP-Spec 2025-06/11); Clients zeigen nur "deploys". Titel "Deploy Center" und ein kleines Icon als Data-URI.
17. [Feature] `server.mjs:1521-1586`: Der Prompt `ship-check` nennt `deploys_freeze` und `deploys_ci` nicht, das Plugin-Skill `deploys-ship` liest beides seit Runde 8 (#22). Prompt angleichen; dazu ein Prompt `post-deploy-check` (Status, Logs, Verify).
18. [Feature] `server.mjs:968-983`: `deploys_journal_search` hat `total` und `shown`, aber kein `offset`; ältere Treffer sind nicht erreichbar. `offset` oder Cursor.
19. [Feature] `server.mjs:1505`: Keine `logging`-Capability. Blockierte Schreibaufrufe, erreichte Obergrenzen und `unsure`-Projekte gehen nur als Fehlertext an das Modell; `sendLoggingMessage` zeigt sie dem Menschen im Client.
20. [Feature] `server.mjs:1137-1142`: `deploys_doctor` sagt nicht, welche `deploys` der Server startet (Pfad, Version, ob aus App oder PATH) und welche Richtlinie gilt (ALLOW-Modus, Positivliste, Obergrenzen). Genau das fragt man, wenn ein Deploy "nicht geht".
21. [Perf] `server.mjs:527-536`: `cachedRun` deckt nur `list` und `status`; `deploys_changed`, `deploys_plan`, `deploys_preview` und `deploys_status` ohne Projekt lesen in einer Agentenrunde dieselben GitHub-Daten mehrfach. 20-s-Cache auch für diese lesenden Aufrufe.
22. [Feature] `server.mjs:1596-1603`: Resource-Templates nur für `status|notes|history`; `risk` und `logs` fehlen, obwohl beide Werkzeuge sind. Clients, die Resources anhängen, bekämen so Kontext ohne Werkzeugaufruf.
23. [Bug] `server.mjs:99-113` (und `vscode/src/cli.ts:67`, `raycast/src/lib/text.ts:114`): Die Umgebungs-Allowlist lässt `OP_*`, `SSH_AUTH_SOCK`, `VAULT_*`, `PASSWORD_STORE_*` weg. Die dokumentierte Schlüsselquelle `<NAME>_CMD='op read …'` (docs/CLI.md:315) scheitert dann im MCP-Server, in VS Code und Raycast mit "printed no key", sobald der Befehl ein Dienstkonto-Token braucht. Doku nennt es nicht; entweder `DEPLOYS_MCP_PASS_ENV=OP_SERVICE_ACCOUNT_TOKEN,…` oder ein Hinweis.
24. [UX] `mcp/README.md`: `DEPLOYS_CONFIG` (Ort von `mcp-starts.json`, `server.mjs:1215`) fehlt in der Umgebungstabelle (verifiziert per Vergleich der Namen).

## B. Claude-Code-Plugin und Hooks (`integrations/claude-code/`)

25. [Sicherheit] `scripts/deploys-call.sh:15-34` (verifiziert, `before-deploy.sh` mit Stand-in): Die Rückfrage vor einem Deploy wird umgangen von `command deploys deploy web`, `env deploys …`, `nohup`, `time`, `sudo`, `xargs`, `deploys --config x deploy web` (Option mit Wert), `D=deploys; $D deploy web`, `eval "…"`, `for/if/(…)/{ …; }`, `$(which deploys) deploy web`. Befehl in Wörter zerlegen und bei jedem Wort `deploys` oder `*/deploys` mit späterem `deploy|rollback|deploy-changed` fragen.
26. [Sicherheit] `scripts/deploys-call.sh:48-50` (verifiziert): Nur `deploy`, `deploy-changed`, `rollback` zählen. `deploys autodeploy allow …` (schaltet Auto-Deploy für Stunden ein), `prepare run --yes`, `cancel`, `ignore`, `freeze clear|remove`, `guard schedule off` laufen ohne Rückfrage. Zweite Klasse "schwächt eine Sicherung" mit eigener Frage.
27. [Sicherheit] `hooks/hooks.json:3-12`: `PreToolUse` nur für `Bash`. `Edit|Write|MultiEdit` auf `~/.config/deploys/{window,rules,ignored,overrides,vercel-repos}.json` (oder `sed -i`/`>` darauf) hebt Deploy-Fenster und Freeze auf, ohne dass irgendein Hook fragt. Pfadprüfung mit "ask".
28. [Sicherheit] `deploys:3060` + `scripts/deploys-call.sh:57-63`: `deploys deploy <gruppe>` deployt mehrere Projekte; Skill und Hook prüfen nur "ein Wort", die Rückfrage sagt "a deploy to production of <gruppe>". Gruppen auflösen und "N Projekte: a, b, c" nennen.
29. [Sicherheit] `skills/deploys-ship/SKILL.md` Schritt 4: `deploys deploy $ARGUMENTS --wait` ohne `--sha <headSha>` (die CLI kann es, `deploys:25`). Ein Push zwischen Prüfung (Schritt 2) und Start liefert einen ungeprüften Commit aus; der MCP-Server pinnt den SHA. Aus `changed --json` übernehmen.
30. [Bug] `hooks/perf-gate.sh:12` (verifiziert): `case "$cmd" in *"perf gate"*|*"perf wait"*) exit 0` gilt für den ganzen Befehl; `git commit -m "perf wait"; npm test` und `echo "perf wait"; npm run build` umgehen die Sperre. Nur ein führendes `deploys perf gate|wait` ausnehmen.
31. [Bug] `hooks/perf-gate.sh:20-23` (verifiziert, Stand-in-Bibliothek mit Exit 75): Nicht erkannt werden `bash -c "npm test"`, `env CI=1 npm test`, `caffeinate -i npm test`, `sudo xcodebuild build`, `nohup tsc &`, `xargs tsc`, `npx -y tsc`, `node_modules/.bin/tsc`, `pnpm run -r build`, `vite build`, `turbo run build`.
32. [Feature] `hooks/perf-gate.sh:20-23` (verifiziert): Schwere Befehle ohne Treffer: `cargo build|test`, `go test|build`, `pytest`, `make`, `./gradlew`, `mvn`, `npm ci`, `pnpm install`, `docker compose up --build`. Eine Zusatzliste in `~/.config/deploys/heavy.txt` oder `DEPLOYS_PERF_HEAVY_EXTRA`.
33. [Test] `tests/perf-guard-tests.sh:206-213`: Nur acht Hook-Fälle. Tabellengetriebener Test mit der Matrix aus 30 bis 32 plus Gegenproben (`echo tsc`, `grep vitest`, `git log --grep=build`).
34. [UX] `claude-code/README.md`, `hooks/hooks.json`: `hooks/perf-gate.sh` liegt im Plugin, ist nirgends eingetragen (Installation nur per Kopie nach `~/.claude/hooks/`) und im README nicht erwähnt (verifiziert per `grep`); `DEPLOYS_PERF_GATE`, `DEPLOYS_PERF_LIB`, `DEPLOYS_PERF_MAX_WAIT` fehlen ebenfalls. Als `userConfig.perf_gate` (Standard aus) eintragen oder dokumentieren.
35. [Bug] `scripts/after-failure.sh:33`: Der PostToolUse-Zweig sucht `fail|error|refused` im gesamten Output. Ein erfolgreicher `deploys deploy web --wait`, dessen Ausgabe "0 errors" oder einen Commit "fix error handling" enthält, löst den Hinweis "failed" aus. Auf "Error:"-Zeilen der CLI und `PostToolUseFailure` beschränken.
36. [UX] `agents/ship-reviewer.md:4`: `tools` erlaubt `deploys changed|deploy-changed|notes|risk|diff`, aber nicht `deploys window` und `deploys ci`; das Skill `deploys-ship` liest beides. Das Urteil "ship now" ignoriert Freeze und rote CI.
37. [Feature] Plugin: `mcp/deploys.mcp.json` ist nur ein Beispiel (App-Pfad), `plugin.json` hat kein `mcpServers` und kein `.mcp.json` im Plugin-Ordner. Wer das Plugin installiert, bekommt Hooks und Skills, aber keine MCP-Werkzeuge; in Linux-Cloud-Sitzungen gibt es die App nicht. `.mcp.json` mit `${CLAUDE_PLUGIN_ROOT}` und ein mitgeliefertes `server.mjs` (nur lesend).
38. [Feature] Plugin-Feld `monitors` (Hintergrund-Monitor, dessen Zeilen als Benachrichtigung in die Sitzung kommen, prüfen gegen die Plugin-Doku): ein Monitor auf `deploys status --json`, der "web: build failed" meldet, solange ein gestarteter Deploy läuft; ersetzt das Polling im Agentenschritt.
39. [Test] `tests/claude-code.sh`, `tests/ops.sh:256-316`: Kein Test, der die Umgehungsmatrix aus Punkt 25/26 als Tabelle prüft (erwartet "ask"); heute prüfen sie nur die erkannten Formen.

## C. GitHub-Action (`integrations/action/action.yml`)

40. [Bug] `action.yml:298-321` vs `:342-367` (Quellcode): Der Plan-Schritt (`deploy: dry-run`, `dry-run: true`) kennt den `repo`-Filter nicht. Trockenlauf und Ausgabe `plan` listen Projekte anderer Repos, die der echte Lauf auslässt; der PR-Kommentar ("Would deploy: …") zeigt dann mehr als geschieht. Denselben Filter vorher anwenden.
41. [Bug] `action.yml:274-296`: `fail-on-risk` und `max-cost` prüfen alle Projekte des Kontos (`changed`, `plan --json`), nicht die, die dieser Lauf per `repo`/`only` deployt. In einem Konto mit fremden Repos bricht ein rotes Fremdprojekt den Lauf ab.
42. [UX] `action.yml:325, 300`: `deploy` gilt nur mit exakt `true`; `True`, `yes`, `1` melden still nur (steht in der Beschreibung, aber ein Tippfehler im Workflow sieht aus wie Erfolg). `::warning::` bei unbekanntem Wert.
43. [Sicherheit] `action.yml` (ohne Prüfung): `deploy: true` läuft auch unter `pull_request_target`, `workflow_run` und `issue_comment` mit Geheimnissen. Mit diesen Ereignissen verweigern, außer `allow-untrusted-event: true`; IDEEN-11 #815 verlangt nur einen Absatz.
44. [Bug] `action.yml:467-472`: Der Kommentar wird über `startswith(marker)` und den ersten Treffer gefunden. Wer kommentieren darf, setzt vorher einen Kommentar mit dem Marker; die Action versucht ihn zu ändern (403), warnt und schreibt nie. Nach `.user.login == "github-actions[bot]"` filtern.
45. [Perf] `action.yml:314-318`: Im Trockenlauf läuft `deploy-changed` zweimal (Text und `--json`), zwei volle GitHub-Durchgänge. Die Summary aus dem JSON rendern.
46. [Bug] `action.yml:240, 286, 314, 361, 371`: Kein Zeitlimit um die `deploys`-Aufrufe (ein Composite-Schritt kennt kein `timeout-minutes`); hängt die CLI, läuft der Job bis zur Jobgrenze (6 h). Wie im Wait-Schritt von Hand begrenzen.
47. [UX] `action.yml:371-373`: Der Deploy-Schritt schreibt die gestarteten Projekte nur ins Log; `GITHUB_STEP_SUMMARY` hat nur "Projects with changes" und "Builds". Tabelle "Started" mit Link (IDEEN-11 #689 betrifft nur die Ausgaben).
48. [Sicherheit] `action.yml:323-388`: Die Startsperre der CLI ist eine lokale Datei; zwei Läufe auf zwei Runnern (zwei Pushes, `workflow_dispatch` plus Zeitplan) starten dasselbe Projekt doppelt. Vor dem Start `status --json` auf `building` prüfen (`skip-building: true`) und `concurrency:` in den Beispielen setzen.
49. [Sicherheit] `digest/examples/approve-deploy.yml:151-160`: Die Freigabe ruft die Action ohne `when-green`, `fail-on-risk`, `wait`. Wer freigibt, deployt auch rote CI und rotes Risiko, die der Digest anzeigt. Standardwerte `when-green: true`, `fail-on-risk: red`, `wait: 20m`, abschaltbar durch eine Eingabe.
50. [Test] `tests/run.sh:640-775`: Kein Fall für Trockenlauf gegen `repo`-Filter (Punkt 40), unbekannten `deploy`-Wert (42) und fremden Marker-Kommentar (44).

## D. Docker und Scheduler (`integrations/docker/`)

51. [Sicherheit] `scheduler.sh:58, 91-94` (verifiziert mit `--check`): Die Positivliste prüft nur das zweite Wort. `deploys freeze clear`, `deploys doctor --fix`, `deploys digest --post` bestehen die Prüfung; der Kopf behauptet "reads only". Pro Befehl erlaubte Unterbefehle und Flags (`freeze status`, `doctor` ohne `--fix`), oder `DEPLOYS_READONLY=1` in der Umgebung der Jobs.
52. [Bug] `scheduler.sh:159-165` + `healthcheck.sh:21`: Der Herzschlag wird einmal pro Tick geschrieben, dann laufen die Jobs inline bis `DEPLOYS_JOB_TIMEOUT` (600 s); der Healthcheck erlaubt 300 s. Ein langer `simulate`/`ledger`/`statuspage` macht den gesunden Container "unhealthy" (drei Fehlversuche à 60 s) und Swarm/Kubernetes starten ihn mitten im Job neu. Herzschlag von einem Hintergrund-Ticker schreiben oder `DEPLOYS_HEARTBEAT_MAX` auf Jobgrenze + Tick setzen.
53. [Bug] `scheduler.sh:148, 128-131`: `trap 'exit 0' TERM INT` läuft in bash erst nach dem Vordergrundbefehl. `docker stop` wartet bis zu einen Job lang, dann SIGKILL; zurück bleiben `out=…XXXXXX`-Temp-Datei und verwaiste `timeout`-Kinder, und der Exit-Code ist 0 statt 143. Job im Hintergrund starten, `wait`, bei Signal die Prozessgruppe beenden.
54. [Feature] `scheduler.sh:92-96`, `Dockerfile.cron:14-17`: Es gibt keine Jobart `notify` (die Tageszusammenfassung für Slack/ntfy) und `integrations/notify` wird nicht in das Cron-Image kopiert, obwohl `lib/post.sh` schon dort liegt. Die häufigste Integration läuft im Container nicht.
55. [Feature] `scheduler.sh:133`: Ein fehlgeschlagener Job steht nur im Log; der Healthcheck sieht nur den Herzschlag. `last-run.json` je Job (`rc`, `at`), nach N Fehlschlägen in Folge "unhealthy" und optional `on-fail=<notify>`.
56. [Feature] `scheduler.sh:15, 143-144`: `daily 07:30` ist immer UTC (Sommerzeit verschiebt die Wanduhr), während notify und digest `DEPLOYS_TZ` kennen. `daily 07:30 Europe/Berlin` oder ein globales `tz=`.
57. [UX] `scheduler.sh:105`: `--check` druckt "every 3600" und "daily 0730" roh, ohne nächste Fälligkeit. "every 1 h", "daily 07:30 UTC, next: …".
58. [Perf] `scheduler.sh:162-168`: Jobs laufen nacheinander; ein `statuspage` mit 480 s Prüfbudget verspätet jeden `every 30m`-Job. Fällige Jobs mit höchstens 2 parallel starten (je Job eine Sperre gegen Überlappung).
59. [Perf] `scheduler.sh:142`: Beim Start sind alle `every`-Jobs sofort fällig (`lasts=0`); nach einem Neustart rennen alle gleichzeitig gegen GitHub. Versatz (Jitter oder Aufteilung über den Tick).
60. [Test] `tests/ops.sh:203-238`: Keine Tests für Signalbehandlung (53), Herzschlag bei langem Job (52) und die Positivliste mit Unterbefehlen (51).
61. [UX] `docker/README.md`: `DEPLOYS_HEARTBEAT_FILE`, `DEPLOYS_HEARTBEAT_MAX`, `DEPLOYS_JOBS`, `DEPLOYS_INTEGRATIONS`, `DEPLOYS_DIR` fehlen (verifiziert per Namensvergleich), `DEPLOYS_JOB_TIMEOUT` steht nirgends in den Ideenlisten oder im README.
62. [Feature] Docker-Scheduler: Nach jedem erfolgreichen Job einen Ping an eine Dead-Man's-Switch-URL (healthchecks.io, Uptime Kuma Push, `DEPLOYS_PING_URL`). Fällt der Container oder die Verbindung aus, merkt es jemand außerhalb.

## E. Notify, Post, Digest (`integrations/notify`, `lib/post.sh`, `digest/`)

63. [UX] `lib/post.sh:260`: `curl -fsS` verwirft den Antworttext; Slack ("invalid_blocks"), Discord (JSON-Fehler) und Teams sagen nur "HTTP 400". `--fail-with-body` (curl ab 7.76, macOS liefert 8.x) und die erste Zeile maskiert ausgeben.
64. [Feature] `lib/post.sh:237-253`: Signierte Webhooks ohne Zustell-ID und Ereignisart (`X-Deploy-Center-Delivery: <uuid>`, `-Event: summary|deploy`). `curl --retry 3` kann doppelt zustellen; Empfänger können nicht entdoppeln.
65. [Bug] `lib/post.sh:202-262`: `mktemp` für den Body ohne `trap`; Strg-C oder ein `timeout`-Kill während `curl` lässt eine Datei mit dem Nachrichtentext im `$TMPDIR` liegen.
66. [UX] `notify.sh:102-105` (verifiziert, `--dry-run` mit `lastAt` von 2023): "Failed (1): web" erscheint täglich, solange der letzte Build eines Projekts fehlgeschlagen ist, auch nach Jahren. `DEPLOYS_NOTIFY_FAILED_DAYS` (Standard 7) oder "seit der letzten Meldung".
67. [Bug] `notify.sh:45-46` (verifiziert): `DEPLOYS_NOTIFY_TZ=Mars/Base` besteht die Regex, `date` fällt still auf UTC, die Kopfzeile druckt "(Mars/Base)". Zone gegen `/usr/share/zoneinfo` oder `TZ=… date +%Z` prüfen.
68. [Sicherheit] `notify.sh:52, 127` (verifiziert): `--link javascript:alert(1)` und `DEPLOYS_NOTIFY_LINK` gehen im Summary-Modus ungeprüft als "Open:"-Zeile und Button-URL; der Ereignis-Modus verlangt `https://` (`post.sh:152`). Derselbe Prüfer.
69. [Feature] `notify.sh:84-138`: Keine Entdopplung. Ein Cron alle 30 Minuten mit `--quiet-when-empty` meldet dieselbe "Waiting"-Liste jedes Mal. Hash des Texts in `$DEPLOYS_CONFIG/notify-last.json`, `--only-changes`.
70. [Feature] `lib/post.sh:207-228`: ntfy bekommt `Actions`, aber weder `Click` (Tippen öffnet den Link), `Markdown: yes` noch `Icon`. Der Standardtipp auf die Meldung tut nichts.
71. [UX] `lib/post.sh:29-30` (verifiziert in Docker): Auf GNU-`stat` druckt `stat -f %Lp` die Dateisystem-Infos und scheitert; die Prüfung klappt nur, weil `|| stat -c %a` die Ziffern dahinter hängt. Die Repo-Regel steht in `providers/*.sh:32` ("GNU first"); `stat -c %a … || stat -f %Lp`.
72. [UX] `notify/README.md`: `DEPLOYS_NOTIFY_LINK` fehlt (verifiziert per Namensvergleich).
73. [Feature] `lib/post.sh`: Kein Format für Grafana-Annotationen (`POST /api/annotations`: `text`, `tags`, Zeit). Ein Deploy als senkrechte Linie in jedem Dashboard, neben PagerDuty (#706) und OTel (#802).
74. [Feature] `lib/post.sh:196-201`: Ein ntfy- oder Matrix-Server im eigenen Netz (`http://192.168.x.x`) wird abgelehnt; nur `localhost` darf `http://`. `DEPLOYS_NOTIFY_ALLOW_HTTP_HOSTS` für benannte Hosts.

## F. Statusseite und Badges

75. [Bug] `statuspage.sh:84` (verifiziert gegen `deploys:1298-1301`): Das Journal ist fest `~/Library/Application Support/app.deploycenter.mac/journal.jsonl`; unter Linux (Docker-Cron, Runner) schreibt die CLI nach `$CONFIG_DIR/journal.jsonl`. Die Statusseite ignoriert das Journal, das derselbe Container schreibt, und fällt auf die Plattform-Historie zurück. `deploys journal path` oder dieselbe Logik.
76. [Perf] `statuspage.sh:131-160`: Standortprüfungen nacheinander, mit 2 s Pause je Wiederholung und 480-s-Budget; bei 30 Adressen werden die letzten still übersprungen. Parallel (4 Hintergrundjobs, bash 3.2 tauglich).
77. [Perf] `statuspage.sh:123-124`: `check_of` lädt per GET jede Seite vollständig nach `/dev/null` und sendet kein User-Agent. `-r 0-1023` bzw. `--max-filesize` und `-A "deploy-center-statuspage/<Version>"`, damit Betreiber den Zugriff erkennen und freigeben können.
78. [Feature] `statuspage.sh:121-135`: Nur HTTP-Code oben/unten; eine 200er-Fehlerseite zählt als "up". Je Projekt `expect: {status, contains, maxMs}` (Schlüsselwort, "degraded" bei langsamer Antwort).
79. [Feature] `statuspage.sh`: Jeder Lauf überschreibt die Ergebnisse; keine Verfügbarkeit über die Zeit. `checks.jsonl` neben der Seite anhängen, 30/90-Tage-Quote und letzter Ausfall auf der Karte und in `status.json`.
80. [Feature] `statuspage.sh`: Kein Zertifikatsablauf auf der Seite, obwohl `deploys certs --json` ihn kennt (`deploys_certs` im MCP). Optional "TLS: 41 days" je Adresse.
81. [Feature] `statuspage/`: `status.json` ohne `schemaVersion` und ohne Schema-Datei; Konfigurationsdatei `statuspage.json` ohne `$schema` (VS Code `jsonValidation`, `integrations/vscode/package.json`). Beides als `statuspage.schema.json`.
82. [UX] `statuspage/README.md`: `STATUSPAGE_RETRY_WAIT` fehlt (verifiziert per Namensvergleich).
83. [Code] `badge/badge.sh:75-98` dupliziert die SVG-Vorlage, `esc()` und `width()` aus `badge/svg.sh:5-33`; `badge.sh` ruft `write_badge` nicht auf. Zwei Vorlagen laufen auseinander (Farben, `<title>`, Barrierefreiheit).
84. [UX] `badge/badge.sh:68, svg.sh:8`: Breite = 6,5 px je Zeichen; "iiii" und "WWWW" oder CJK-Namen laufen über den Rand. Tabelle für schmale und breite Zeichen (jq), wie shields.io mit Verdana-Metrik.

## G. Editoren: VS Code, Raycast, Alfred

85. [Perf] `vscode/src/extension.ts:372-390`: `follow()` ruft alle 15 s das volle `refresh()` (`changed` + `status` + Remotes), bis zu 60-mal. `deploys watch <ref> <id>` (kennt die Action) oder `status <projekt> --json` verwenden.
86. [Sicherheit] `vscode/src/extension.ts:536` und `vscode/src/log.ts:125-132`: `copyNotes` legt `deploys notes` unmaskiert in die Zwischenablage (der MCP-Server maskiert, `server.mjs:1106`); `aiPrompt` nennt Projektname und Repo unmaskiert und sagt dem Empfänger nicht, dass der Log-Block Daten und keine Anweisung ist.
87. [Sicherheit] `vscode/src/extension.ts:368, 411, 546`: `openExternal(vscode.Uri.parse(url))` mit Adressen aus CLI-Ausgabe (`urlIn`, Deploy-JSON) ohne Schemaprüfung; nur `https:` (und `http://localhost`).
88. [UX] `vscode/src/extension.ts:51, 154, 518`: Gewöhnlicher Ausgabekanal mit Zeitstempel von Hand (`toLocaleTimeString`). `createOutputChannel(name, { log: true })` bringt Stufen, "Set Log Level" und Zeitstempel.
89. [UX] `vscode/src/extension.ts:360-361`: Der Deploy-Dialog zeigt `describe(p)`, aber weder Risiko noch Fenster noch CI, obwohl `this.freeze` schon geladen ist (`cli.ts:200`). Wie MCP-Rückfrage, Hook und Skill: "Deploy window: closed (Friday freeze)".
90. [Feature] VS Code: Ein `TaskProvider` (`deploys`-Tasks "waiting", "perf wait") und ein `problemMatcher` für `deploys logs`; ein Klick auf `src/app.ts:42` aus dem Build-Log springt in die Datei.
91. [Feature] `vscode/package.json`: `contributes.jsonValidation` für `~/.config/deploys/*.json` und `statuspage.json` (siehe 81); Eingabehilfe und Fehler beim Tippen in `window.json` und `rules.json`.
92. [Sicherheit] `raycast/src/lib/deploys.ts:407-422`: `deployChanged` vergleicht nur Namen und startet dann `deploy-changed --yes` ohne `--sha`; ein Push dazwischen liefert neuere Commits aus. VS Code und MCP deployen je Projekt mit `--sha <headSha>`; Raycast ebenso.
93. [Bug] `raycast/src/lib/deploys.ts:213-215`, `vscode/src/cli.ts:113`: Ausgabe über dem Limit (16/32 MB) beendet die CLI und liefert Code 1 mit abgeschnittenem Text; der Nutzer liest "did not print JSON" oder "failed". "Ausgabe größer als 16 MB" melden.
94. [Bug] `raycast/src/lib/deploys.ts:463`, `server.mjs:976`: Das Journal wird nur gelesen, wenn die Kopfzeile genau `at,platform,name,result,detail` lautet (Raycast) oder die Spalten per Position (MCP). Eine neue Spalte in `deploys journal export` bricht beide. Nach Spaltennamen zuordnen.
95. [Test] Die Umgebungs-Allowlist `FOR_CLI` steht dreimal (`server.mjs:99`, `vscode/src/cli.ts:67`, `raycast/src/lib/text.ts:114`). Der Test in `run.sh:777` vergleicht nur die Log-Regeln von VS Code und Raycast; Gleichheitsprüfung für alle drei Regexe.
96. [UX] `alfred/deploys-open.sh:14, 17`: Fehlt `deploys`, fällt `bin` auf `deploys`, `exec` scheitert still; Alfred zeigt nichts. `osascript -e 'display notification'` oder JSON für "Post Notification".

## H. Übergreifend

97. [Feature] CLI: `deploys capabilities --json` (Version, Befehle, Flags, Provider mit `caps`). Ersetzt die Probierketten: `platformOf` (`server.mjs:540-546`), den `risk`-Test im Digest (`digest.sh:~110`), die Rückfallliste im `pre-push` (`:62-73`), die fest eingetragenen Plattformen in VS Code (`cli.ts:221-233`), `pinsCommit` in Raycast (`deploys.ts:366`).
98. [API-Konsistenz] `hooks/pre-push:90`, `vscode/src/cli.ts:221, 228, 233`: Plattformlisten für "baut bei jedem Push" (`IN("vercel","cloudflare","amplify")`), "kann Vorschau", "kann Rollback", "kann --sha" stehen von Hand in vier Orten, während MCP `providers --json` liest. Ein neuer Provider braucht vier Änderungen; `caps` in `deploys list --json` ausgeben.
99. [API-Konsistenz] "Fehlgeschlagen" wird je Integration anders abgeleitet: `server.mjs:586` (`phase` oder Regex), `alfred/deploys-filter.sh:33` (nur `.state`), `raycast text.ts` (`isFailedState`), `vscode/src/model.ts`, zusätzlich zu den von #708 genannten. Die CLI liefert ein Feld `failed` in `status --json`.
100. [Test] Ein Vertrags-Test: Die Stand-ins von MCP (`FAKE_*`), Alfred (`alfred/test.sh`), VS Code (`vscode/test/`) und Raycast antworten aus je eigenen Fixtures; weicht die echte CLI ab, merkt es keiner. Ein gemeinsames Verzeichnis `tests/fixtures/cli-json/` plus Schema-Prüfung (zusammen mit #306).
101. [UX] `integrations/README.md:9-23`: Die Tabelle nennt bei Docker nur "for CI" (es gibt die Cron-Variante), bei Alfred drei Filter (es sind sieben), kein `lib/`, `tests/`, `perf-gate`; `VERIFY.md` deckt nur App und CLI, nicht `.vsix`, Docker-Image und die Action-Pinnung (`@<sha>`).
102. [Feature] GitHub-Umgebungen: Eine eigene "Deployment protection rule" (GitHub App), die für einen Environment-Deploy `deploys freeze`, `risk` und CI abfragt und freigibt oder ablehnt. Andere Idee als der Check-Run aus IDEEN-6 #661: Hier entscheidet Deploy Center mit.
103. [Feature] MCP-Konfigurationen für weitere Agenten: Gemini-CLI-Erweiterung (`gemini-extension.json` mit MCP-Server und Kontextdatei), `~/.codex/config.toml`-Block, Zed-`context_servers`-Eintrag und ein Docker-Aufruf `docker run -i --rm deploys-mcp` für Cloud-Sitzungen. IDEEN-11 #668/#910 betreffen nur Regeldateien.
104. [Feature] Neovim/Helix: Ein Lua-Plugin (`lualine`-Komponente und `:DeploysWaiting`) auf Basis von `deploys status --short` (#502) mit Zwischenspeicher; kein Netz im UI-Thread.
105. [Test] `tests/mcp.test.mjs`: Kein Test mit einer CLI, die Teil-JSON plus Exit 1 liefert und `structuredContent` prüft (Punkt 13), keiner für `checkArgs` mit `maxLength`/`enum` (4) und keiner für zwei Server-Prozesse gegen eine `mcp-starts.json` (6).

# D. Website, Docs, CI

# Neue Ideen: site/, marketing/, Docs, Release, CI, Tests

Stand: Repo 0.14.0 (CHANGELOG bis 0.14.0 plus Unreleased), nur gelesen, nichts geändert.
Prüfung: Jeder Punkt wurde per Regex gegen `docs/IDEEN*.md` und `CHANGELOG.md` gesucht; Treffer wurden aussortiert (u. a. cancel-in-progress, CITATION.cff, SUPPORT.md, GOVERNANCE.md, Rechner-PNG, Changelog-Feed, `/de/` noindex, Teilübersetzungen CLI.de, Glossar-URLs, Cheatsheet, SBOM/minisign, phasedRollout wurden verworfen, da schon vorhanden).
Wichtigster Befund: Die vorhandenen Ideen stammen aus dem Stand 0.11. Alles aus 0.12 bis 0.14 (acht neue Hosts, Performance-Guard, Cloud Sessions, Forecast, nächtlicher Sicherheitscheck, Health Score) ist darin nicht erfasst und fehlt auf Startseite, llms.txt, Guides, Marketing und in den Sicherheits-Dokumenten.

Tags: [Bug] [SEO] [A11y] [Perf] [Doku] [CI] [Feature] [Test]

## A. Veraltete Hostlisten und Doku-Drift (0.12 bis 0.14)

1. [Bug] `site/index.html:325` (FAQ "Which hosts are supported?"), die FAQ-JSON-LD (`:42`) und die SoftwareApplication-Beschreibung (`:40`) nennen nur 7 Hosts. Fly.io, Railway, Heroku, Firebase Hosting, GitHub Pages, Koyeb, Northflank und Deno Deploy (alle in `providers/`) fehlen; die Seite versteckt 8 von 16 Providern.
2. [Bug] `site/llms.txt:7` ("Hosts: Vercel and Render on by default; Netlify ... Coolify ... opt-in") ist dieselbe veraltete Liste; KI-Assistenten, die llms.txt lesen, verneinen Fly.io oder Railway.
3. [Bug] `site/guides/index.html:7` (Titel "guides for 7 hosts, Vercel to Coolify") und `:388` ("Push builds on four hosts") passen nicht zu 16 Providern; Titel und Beschreibung aus `providers/*.sh` zählen lassen.
4. [Doku] `README-CLI.md:3-5` nennt nur die 7 alten Hosts; `README.md` und `docs/FAQ.md` erwähnen Northflank nicht (Zeilen mit der Hostliste).
5. [Doku] `integrations/claude-code/skills/deploys-ship/SKILL.md:30`, die Skills `deploys-status` und `deploys-waiting`, `.claude-plugin/marketplace.json:12` und `integrations/raycast/README.md:3` listen 7 Hosts; die Skill-Beschreibung steuert, wann Claude Code den Skill überhaupt wählt.
6. [Doku] `site/404.html:87`, `site/llms.txt` und `scripts/build-docs.py:38` (`TRADEMARKS`) haben einen Nicht-verbunden-Hinweis nur für die alten Marken. Fly.io, Railway, Heroku, Firebase/Google, Koyeb, Northflank und Deno fehlen, obwohl sie im Produkt genannt werden.
7. [Doku] `SECURITY.md:35,77`, `docs/SECURITY-MODEL.md` und `docs/UNINSTALL.md:88-113` kennen die Keychain-Dienstnamen und Endpunkte der neuen Hosts nicht (z. B. `api.heroku.com`, `api.machines.dev`, `api.northflank.com`, `api.deno.com`). Die Datenfluss-Tabelle ist damit wieder unvollständig, und "Token widerrufen" fehlt für 8 Hosts.
8. [Doku] `.github/ISSUE_TEMPLATE/platform-request.yml:10` zählt "existing" Hosts bis Coolify auf; Fly.io, Railway, Heroku und Firebase werden dadurch erneut gewünscht.
9. [Test] Kein Drift-Test: `check-docs.py` könnte für jede `providers/<x>.sh` prüfen, dass der Host in Startseite, llms.txt, SECURITY.md, UNINSTALL.md, Skills und Marketplace-JSON vorkommt (oder auf einer Ausnahmeliste steht).
10. [Doku] Die Hostliste steht in rund 28 Dateien von Hand (README, FAQ, UNINSTALL, TROUBLESHOOTING, SAVINGS, Skills, Raycast, 404, Rechner, Blog). Eine Quelle (`docs/hosts.json` aus `providers/`) plus Platzhalter im Build beseitigt die Drift dauerhaft.
11. [Doku] `CHANGELOG.md:60` kennt 0.13.0 (2026-11-23), aber `git tag` springt von v0.12.0 auf v0.14.0 und `site/install/` hat keine `0.13.0.sh`; wer die in der Notiz genannte Version pinnt, bekommt 404. Ein Release-Gate "jede CHANGELOG-Version hat Tag und install-Kopie" fehlt.
12. [SEO] `site/install/0.11.0.sh`, `0.12.0.sh`, `0.14.0.sh` sind drei 18-KB-Textdubletten von `install.sh`; `robots.txt:1-22` sperrt sie nicht, sie können im Index landen. `Disallow: /install/` ergänzen.

## B. Fehlende Inhalte zu neuen Funktionen (nur in docs/, nicht auf Startseite, llms.txt oder Guides)

13. [Feature] Cloud Sessions (`deploys sessions`, Fenster "Cloud Sessions", Unreleased): Erklärseite oder Guide "Wissen, welche Claude-Code-Cloud-Sessions fertig sind oder hängen"; kommt auf Startseite, `claude-code/index.html` und llms.txt nicht vor.
14. [Feature] Performance-Guard (0.14-Highlight, `docs/PERF.md` 163 Zeilen): kein Guide wie "Der Mac hängt, weil drei Agenten gleichzeitig bauen"; Startseite und llms.txt erwähnen ihn nicht, auch nicht in der Claude-Code-Seite (Hook `deploys perf gate`).
15. [Feature] Guide für `deploys forecast` (Kostenprognose) mit Beispielausgabe; Funktion kommt in keiner HTML-Seite außerhalb der Docs vor.
16. [Feature] Guide für `deploys env-diff` ("Welche Variablen fehlen in Production gegenüber Preview?", nur Namen); nur in Docs und MCP-Notiz.
17. [Feature] Guide für `deploys preview` und `deploys domains` (Preview-URL aus der Konsole, Domain-/TLS-Überblick); das bestehende `tls-certificate-expiry-check` deckt `domains` nicht ab.
18. [Feature] Guide für den nächtlichen Sicherheitscheck (OSV-Scanner, gitleaks, Semgrep, 0.13): "Jede Nacht Abhängigkeiten und Geheimnisse in allen Repos prüfen, ohne Server". Nur 1 Site-Datei erwähnt "nightly".
19. [Feature] Guide "Health Score": was die Zahl misst und wie man sie verbessert (0.13); keine Treffer in Ideen oder Site.
20. [Feature] Guide "Mehrere Konten pro Host" (0.13: Agentur mit zwei Vercel-Teams); fehlt als Suchthema.
21. [Feature] Guide "Fehlermuster-Hinweise" (0.13 "error-pattern hints"): welche Meldungen die App erkennt und was sie vorschlägt; gute Long-Tail-Seite pro Meldung.
22. [Feature] Guide "Freeze-Zeiten aus einem ICS-Kalender importieren" (0.13); `deploy-freeze-friday` kennt den Import nicht.
23. [Feature] Seite zur iPhone-App mit Live Activity, Shortcuts und Dynamic Type (0.12/0.13): Die Startseite hat nur ein Bild, kein Guide beschreibt Live Activity oder Siri-Kurzbefehle.
24. [Feature] Guide `deploys streak` und `timeline` für Teams ("Wann zuletzt grün?"): `deploys-in-a-row-without-failure` und `deploy-timeline` existieren, aber ohne Querverweis auf MCP, Raycast, Alfred und Widget (0.13 "Timeline und Recovery in MCP, Raycast ...").
25. [Feature] Seite "Alle Hosts" mit Vergleichstabelle (Schalter, Rollback, Logs, Kosten, getestet seit Version) aus `providers/*.sh`; `site/docs/hosts/index.html` ist nur Liste, die Guides-Übersicht kennt nur 7 Hosts.

## C. Neue Guides, Vergleiche und Blogthemen (nicht in den Ideen)

26. [Feature] Guide Railway: Auto-Deploy / Watch Paths abschalten, per CLI deployen (Provider seit 0.12, `docs/providers/railway.md` vorhanden, in `site/guides/` nichts).
27. [Feature] Guide Fly.io: Deploy nur von Hand statt `fly deploy` im Push-Workflow.
28. [Feature] Guide Heroku: Automatic Deploys aus, Review Apps und Pipelines.
29. [Feature] Guide Firebase Hosting / App Hosting: Rollout bei Push abschalten.
30. [Feature] Guide GitHub Pages: Workflow nur per `workflow_dispatch`.
31. [Feature] Drei kurze Guides für Koyeb, Northflank und Deno Deploy (eigene Provider, keine Anleitung).
32. [Feature] Vercel-Guide um `github.autoJobCancelation` und `github.silent` in `vercel.json` ergänzen (nur `git.deploymentEnabled` ist abgedeckt, 0 Treffer in Ideen).
33. [Feature] Guide "Welche Vercel-Build-Maschine kostet wie viel?" (Standard, Enhanced, Turbo); der Rechner nimmt einen Preis pro Build an, die Maschinenstufe fehlt.
34. [Feature] Guide Vercel "On-Demand Concurrent Builds": wann sie sich lohnen und wann die Warteschlange billiger ist; ergänzt `vercel-build-minutes-and-build-queue`.
35. [Feature] Guide Rolling Releases und Skew Protection gegenüber dem Rollback-Knopf; Abgrenzung zu `roll-back-vercel-render-deployment`.
36. [Feature] Guide "Turborepo Remote Cache senkt Build-Minuten, bevor man Builds abschaltet"; ergänzt `monorepo-skip-unchanged-builds`.
37. [Feature] Guide "Vercel Spend Management: Limit setzen und was dann passiert" als Ergänzung zum Kostenrechner (1 Erwähnung auf der Site, 0 Treffer in Ideen).
38. [Feature] Guide "Commit-Nachrichten, die Builds überspringen" ([skip ci], [vercel skip], [skip netlify]) als Tabelle pro Host.
39. [Feature] Guide Netlify Branch Deploys und Deploy Previews getrennt abschalten (`netlify-stop-builds` deckt nur Stop Builds und `ignore` ab).
40. [Feature] Guide Dokploy/CapRover/Dokku: Auto-Deploy-Webhook (der Hook-Guide nennt sie nicht).
41. [Feature] Guide Azure Static Web Apps: Workflow-Trigger entfernen.
42. [Feature] Guide Bitbucket Pipelines: Deploy nur manuell (`trigger: manual`).
43. [Feature] Vergleich "Deploy Center gegen `vercel`-CLI-Skripte": `site/compare/` hat vier Ansatzvergleiche, aber keinen Produktvergleich.
44. [Feature] Vergleich "Selbst hosten (Coolify, Dokploy) gegen Managed Hosting: Build-Kosten".
45. [Feature] Vergleich "Deploy per GitHub Actions gegen Git-Integration des Hosts" (Kosten, Cache, Secrets, Rollback).
46. [Feature] Vergleich "Kosten begrenzen: Spend Management, Auto-Deploy aus, Ignored Build Step" als Entscheidungstabelle.
47. [Feature] Blog "Dependabot und Renovate lösen Preview-Builds aus: drei Wege" (Bot-Guide existiert, Zahlenbeitrag fehlt).
48. [Feature] Blog "Ein Monat ohne Auto-Deploy: Zahlen aus dem Ledger" mit anonymisierten Werten; der Blog hat 4 Beiträge, keinen Erfahrungsbericht.
49. [Feature] Blog "Warum die CLI Bash 3.2 bleibt" (Entscheidungsbeitrag für Hacker-News-Publikum; AGENTS.md nennt die Regel, die Website erklärt sie nicht).
50. [Feature] Blog "Keine Telemetrie, kein Server: wie Update-Check und Appcast ohne Tracking laufen" (Datenschutz als Verkaufsargument, Seite fehlt).
51. [Feature] Blog "Was sechs Agenten pro Tag pushen" (Cursor, Copilot, Devin, Claude Code) mit Messmethode `deploys scan`; ergänzt `ai-coding-agents-build-bill`.
52. [Feature] Blog "Performance-Guard: warum der Mac bei fünf Claude-Code-Sitzungen hängt und wie die Lastbremse es verhindert" (0.14, Alleinstellungsmerkmal, 0 Treffer in Ideen).
53. [Feature] Blog "Cloud-Sessions im Blick: Claude Code in der Cloud ohne Browser-Tabs verwalten" (Unreleased-Feature als Ankündigung).
54. [Feature] Blog "Netlify Build-Credits statt Minuten: was ein Preview-Build kostet" (Rechner und Guide sprechen nur Minuten).

## D. SEO und strukturierte Daten

55. [SEO] Autodiscovery: nur `blog/index.html:38` und `de/blog/index.html:38` tragen `<link rel="alternate" type="application/atom+xml">`; Startseite, Guides-Übersicht und Vergleichsseite fehlen, Feed-Reader finden den Feed nicht von dort.
56. [Feature] `site/blog/feed.xml:1-20`: Einträge haben nur `<summary>`, kein `<content type="html">`; Reader zeigen einen Satz und nichts vom Beitrag.
57. [SEO] 17 Seiten haben Titel über 65 Zeichen (Spitze 70, u. a. `guides/check-before-you-deploy`, `digitalocean-app-platform-deploy-on-push`, `monorepo-skip-unchanged-builds`); `check-site.py:183` meldet nur Warnungen. Kürzen und Warnung zum Fehler machen.
58. [SEO] Acht Meta-Beschreibungen sind 166 bis 170 Zeichen lang (u. a. `blog/ai-coding-agents-build-bill`, `claude-code`, `compare/ways-to-deploy-on-demand`, drei DE-Vergleiche) und werden abgeschnitten.
59. [SEO] Google zeigt seit 2023 FAQ-Rich-Results nur noch für Behörden und Gesundheitsseiten und hat HowTo-Rich-Results entfernt, die Site liefert aber 76 FAQPage- und 39 HowTo-Blöcke. Wert liegt jetzt bei KI-Antworten; Markup lohnt nur noch, wenn die Texte sichtbar identisch bleiben (check-site prüft das schon), alles Weitere (neue FAQ nur für Schema) lohnt nicht.
60. [SEO] Guides haben kein Inhaltsverzeichnis und keine anklickbaren Überschriften-Anker, obwohl jede `h2` eine `id` trägt (z. B. `disable-vercel-auto-deploy`, 11 `h2`, 931 Wörter). Ein TOC erzeugt Sprunglinks in Suchergebnissen.
61. [SEO] Die Guides enthalten außer dem 24-px-Logo kein Bild, keinen SVG-Ablauf und keinen Screenshot der Host-Oberfläche; Konkurrenzseiten haben Screenshots, die Bildersuche und Verweildauer bringen.
62. [SEO] `inLanguage`, `isPartOf` (Guide gehört zur Guides-Sammlung) und `about` fehlen in den TechArticle-Blöcken; DE-Seiten tragen kein `inLanguage: de`.
63. [SEO] Kein `speakable`/Kurzantwort-Markup: Die Seiten haben ein `.answer`-Element (z. B. `de/index.html`), das als `speakable` ausgezeichnet Sprachassistenten ein Zitat gibt.
64. [SEO] Keine sichtbaren Autor-Seiten: Guides nennen "Patrick Schmetzer, author of Deploy Center" als Text; eine `/about/`-Seite mit `Person`-Schema und `sameAs` stärkt E-E-A-T.
65. [SEO] Alle 87 Seiten nutzen dasselbe `og.png`; seitenspezifische OG-Bilder (Titel plus Hostlogo-freie Grafik, per Skript erzeugt) erhöhen die Klickrate in Social und Slack.
66. [SEO] Einzelne Fehlermeldungsseiten statt 72 Abschnitten auf `docs/troubleshooting/`: Seiten mit der exakten Meldung als Titel ("Vercel 403 on deploy hook") bedienen Suchen nach der Meldung.
67. [SEO] Programmatische Seiten "Vercel-Kosten bei N Projekten": je Szenario eine statische Seite (3/10/30 Projekte) mit vorberechneten Zahlen aus der Rechnerformel, verlinkt vom Rechner.
68. [SEO] `/de/` hat kein JSON-LD (`de/index.html` liefert `ld+json`: keines) und keine `og:image`-Tags; selbst bei `noindex` fehlen so Vorschaubilder beim Teilen.
69. [SEO] `site.webmanifest` hat `"lang": "en"` und keine lokalisierten `name`-Varianten; für DE-Besucher ein `/de/site.webmanifest` oder `lang`-Auswahl.
70. [SEO] Im Sitemap gibt es keine `xhtml:link rel="alternate" hreflang`-Einträge, nur HTML-Header; für 21 Seitenpaare wäre die Sitemap-Variante das robustere Signal, falls ein Template-Fehler die HTML-Tags entfernt.
71. [SEO] Die EN-Startseite hat keinen `hreflang`-Gegenpart (`index.html` ohne `hreflang`, 24 Seiten insgesamt ohne), und 17 EN-Guides haben keinen DE-Zwilling; gerade die Top-Suchthemen (disable-vercel-auto-deploy, render-auto-deploy-off, netlify-stop-builds, vercel-ignored-build-step, reduce-vercel-costs, deploy-hooks) fehlen auf Deutsch.
72. [SEO] Keine DE-Fassung von `claude-code/index.html` und keine DE-Version des Blogposts `ai-coding-agents-build-bill` (die anderen drei Blogposts sind übersetzt).
73. [SEO] 404-Seite führt EN-Links (Zeilen 60-70) aber keine Suche für DE und keinen Link auf `/de/`; DE-Besucher mit toter URL landen in der englischen Hilfe.

## E. Internationalisierung (DE/EN)

74. [i18n] Die DE-Fußzeile ist englisch (`site/de/blog/index.html`, `<footer class="site" lang="en">`) und verlinkt nur englische Guides; die 21 deutschen Anleitungen sind dort nicht verlinkt.
75. [A11y] Hauptnavigation auf DE-Seiten führt "Docs" englisch (`lang="en"`, `de/anleitungen/*/index.html`); mit DE-Docs (30 `.de.md`) wäre ein deutscher Link möglich.
76. [i18n] Die 30 `docs/*.de.md` erscheinen nicht auf der Website: `site/docs/` hat kein `de/` und `build-docs.py` kennt `.de.md` nicht; `docs/README.md:62` verweist DE-Leser auf GitHub. `/de/docs/<seite>/` mit hreflang erzeugen.
77. [i18n] DE-Hubseiten (`de/anleitungen/index.html`, `de/blog/index.html`) haben kein Suchfeld (`data-site-search` nur auf EN-Seiten und 404), und `search-index.json` hat 640 englische Einträge. Zweiter Index aus DE-Seiten und Docs.
78. [i18n] Für jeden EN-Guide ohne DE-Zwilling fehlt eine Ausnahmeliste: `check-site.py:202` prüft hreflang-Gegenseitigkeit, nicht Vollständigkeit.
79. [i18n] Der Appcast kennt nur `<language>en</language>` (`scripts/appcast.py:27-28`); Sparkle zeigt deutschen Nutzern englische Release-Notes. Zweite `<description xml:lang="de">`.
80. [i18n] `marketing/` ist komplett deutsch/englisch gemischt ohne Kennzeichnung (Launch-Plan deutsch, Reddit-Texte englisch); eine Spalte "Sprache der Zielcommunity" im Launch-Plan verhindert falsche Sprache bei Posts in r/de oder Heise-Foren.
81. [i18n] Keine deutschsprachigen Marketingtexte für heise.de-Forum, t3n, Golem, entwickler.de oder Reddit r/de_EDV; `marketing/newsletters.md` nennt keinen deutschen Entwickler-Newsletter.

## F. Barrierefreiheit, Dark Mode, Bedienung

82. [Bug] `<meta name="theme-color">` (`site/index.html:12-13`) folgt nur `prefers-color-scheme`; nach manuellem Themenwechsel bleibt die Browserleiste in der Systemfarbe. Meta per JS in `home.js:19-24` / `site.js:17-25` aktualisieren.
83. [UX] Themenschalter hat nur Hell/Dunkel (`site.js:17-25`, `home.js:19-24`); nach dem ersten Klick steht der Wert dauerhaft in localStorage, ein Weg zurück zu "System" fehlt.
84. [UX] Kein `storage`-Listener: Themenwechsel in einem Tab erreicht andere offene Tabs erst nach Neuladen.
85. [Perf] Theme-, Copy-Button- und Suchlogik existieren doppelt in `home.js` und `site.js` (rund 40 Zeilen identisch); ein gemeinsames `core.js` spart Wartung und ein Request-Duplikat.
86. [Bug] `home.js:41` und `site.js:44`: `setTimeout` zum Zurücksetzen von "Copied" wird nie gelöscht; zwei Klicks in 1,6 s lassen die Beschriftung zu früh zurückspringen.
87. [A11y] `site.js` (Copy-Knopf) setzt nur `textContent` des Knopfes, hat anders als `home.js:39` keine Live-Region; Screenreader hören "Copied" auf Guide-Seiten nicht.
88. [Bug] `site.js` beendet den Copy-Block mit `if (!navigator.clipboard) return;` und bietet keinen Fallback; `home.js` hat `document.execCommand`. Auf Guide-Seiten im älteren Safari oder in unsicheren Frames fehlt der Knopf ersatzlos.
89. [A11y] Keine Prüfung mit echtem Browser: `check-a11y.py` ist statisch (HTML/CSS). Axe-core über Playwright fängt Kontrast bei Hover/Fokus, Reflow bei 400 % Zoom und Textabstände (WCAG 1.4.12) ab.
90. [A11y] Tabellen der Vergleiche haben `scope`, aber keine `<caption>` (`compare/stop-push-builds-compared/index.html:157`); Screenreader nennen die Tabelle ohne Namen.
91. [Perf] `site/index.html:36` lädt `app-dark-1800.webp` per `<link rel=preload>` für alle Besucher; wer hell bevorzugt, bekommt das Hell-Bild zusätzlich (Wechsel per `data-light` in `home.js`). Preload mit `media="(prefers-color-scheme: dark)"` einschränken.

## G. Performance

92. [Perf] `site/css/site.css:3` und `site/css/home.css:2` nutzen `@import url("/css/tokens.css")`: HTML, dann CSS, dann tokens.css; zwei serielle Roundtrips vor dem ersten Rendern. Tokens beim Build einsetzen.
93. [Perf] `docs/search-index.json` (≈316 KB, 640 Einträge) wird beim ersten Fokus komplett geladen (`site.js:66`); die Guides-Suche braucht keine Docs-Volltexte. Nach Bereichen teilen oder Texte kürzen (`t` auf 120 Zeichen).
94. [Perf] Speculation Rules (`<script type="speculationrules">`) für Guides-Verlinkung fehlen; mit CSP `script-src 'self'` bräuchte es einen externen Regelsatz (`.json` mit `Content-Type: application/speculationrules+json`).
95. [Perf] `content-visibility: auto` fehlt für lange Abschnitte der Startseite (`home.css`, 0 Treffer); FAQ und Footer rendern sofort.
96. [Perf] Seitenübergänge per `@view-transition { navigation: auto; }` (2 Zeilen CSS) lassen Guides-Navigation weich wirken, ohne JS; 0 Treffer in Ideen.
97. [Perf] CSS wird nicht minimiert (`home.css` 16 KB, `site.css` 14 KB, `home.js` 7,7 KB); ein Build-Schritt in `build-docs.py` ohne Abhängigkeit (Regex-Minifier) spart 20 bis 30 % vor gzip.
98. [Perf] Kein `favicon.ico` im Wurzelordner und kein SVG-Favicon: Browser fragen `/favicon.ico` an, GitHub Pages antwortet 404 bei jedem Erstbesuch. Ein SVG-Icon mit `<link rel="icon" type="image/svg+xml">` spart den Fehler und passt sich dem Dunkelmodus an.
99. [Perf] `docs/images/` führt PNG und WebP derselben Bilder nebeneinander (z. B. `main-dark.png` 270 KB und `.webp` 98 KB); die PNG nur im Repo zu halten, aber nicht nach `site/` zu kopieren, prüft kein Skript (`check-size.sh` nur Obergrenzen).

## H. Release, Signierung, Notarisierung

100. [Doku] Es gibt keine `docs/RELEASING.md`: Zertifikat, notarytool-Profil, Sparkle-Konto, Appcast-PR und Tap-PR stehen nur im Kopf von `release.sh` und in `integrations/VERIFY.md`; Fehlerbilder (Notarisierung hängt, Sparkle-Key fehlt) sind nirgends beschrieben.
101. [Security] `release.sh:255`: `notarytool log` wird nur bei Fehlschlag ausgegeben. Bei Erfolg als `dist/notarization-<version>.json` aufbewahren (Warnungen zu unsignierten Binärdateien werden später zu Fehlern).
102. [Security] `build.sh:295`: Ad-hoc-Fallback `codesign --force --deep -s -` nutzt `--deep`, das Apple zum Signieren nicht empfiehlt; die Zeilen 283-286 signieren korrekt von innen nach außen.
103. [Security] Kein Release-Check auf Debug-Entitlements: `codesign -d --entitlements :-` gegen eine Allowlist (`com.apple.security.get-task-allow`, `disable-library-validation` dürfen im Release fehlen).
104. [Security] `release.sh:333`: Nach der Veröffentlichung prüft nur SHA-256. Ein Gatekeeper-Test der heruntergeladenen Datei (`xattr -w com.apple.quarantine`, dann `spctl -a -t exec`) erkennt ein fehlendes Ticket nach dem Hochladen.
105. [Feature] Nur Zip, kein `.dmg` mit Programme-Verknüpfung (`release.sh:156`); Zip entpackt in Downloads, wo Sparkle-Updates scheitern können, wenn die App nicht verschoben wird.
106. [Feature] Kein dSYM-Archiv pro Release (`release.sh:285-300`, 0 Treffer "dSYM"): Absturzberichte von Nutzern lassen sich nach Löschen von `build/` nicht symbolisieren.
107. [CI] Release läuft nur lokal; ein `workflow_dispatch`-Release-Workflow auf `macos-26` mit App-Store-Connect-API-Key (statt Schlüsselbund-Profil) und `environment: release` mit Reviewer-Pflicht würde den Prozess nachvollziehbar und unabhängig von einem Mac machen.
108. [Doku] `scripts/appcast.py:6` behält `--keep 10` Releases; es gibt keine Delta-Updates (Sparkle `generate_appcast`), jedes Update lädt die volle Zip (rund 16 MB laut JSON-LD `fileSize`). Hinweis in der Doku oder Deltas anbieten.

## I. CI-Härtung und Workflows

109. [CI] `.github/workflows/ci.yml:3-12`: Kein `paths`/`paths-ignore`; ein PR, der nur `site/`, `docs/` oder `marketing/` ändert, startet den macOS-15-Job (bis 45 min) und den macOS-26-iOS-Job (macOS-Minuten zählen zehnfach).
110. [CI] `.github/workflows/ci.yml:473`: `external-links` läuft nur bei `schedule`; `gh workflow run CI` startet ihn nie. `|| github.event_name == 'workflow_dispatch'` ergänzen.
111. [CI] `.github/workflows/pages.yml:5-10`: Die Website wartet auf den vollen CI-Lauf inklusive macOS-Jobs; ein Tippfehler in einem Guide braucht bis zu eine Stunde bis live. Schneller Pfad für reine `site/`-Änderungen (nur `docs`-Job als Gate).
112. [CI] Keine Vorschau pro PR für `site/`: Reviewer sehen Layout-Änderungen nicht; `actions/upload-artifact` des gebauten `site/` oder ein temporärer Pages-Preview-Deploy fehlt.
113. [CI] `ci.yml` läuft nur auf `macos-15` für die App; macOS 26 nur für iOS. Ein Matrix-Eintrag für die Mindestversion der App (macOS 15 laut README) plus die aktuelle Version fängt SDK-Unterschiede.
114. [CI] `ruff` prüft nur `E9,F` (`ci.yml`, Schritt "ruff"); `ruff format --check` und `B`-Regeln (Bugbear) fehlen, obwohl `scripts/*.py` über 20 Dateien umfassen.
115. [CI] Kein HTML-Validator (`html-validate`/`vnu.jar`) auf `site/`; doppelte IDs, falsch verschachtelte Elemente oder kaputte `<details>` fängt weder `check-site.py` noch `check-a11y.py`.
116. [CI] Kein Lighthouse- oder Gewichtsbudget im `pages.yml`-Build (die Idee zu Lighthouse-CI nennt LCP, nicht Bytes pro Seite): ein Skript, das HTML+CSS+JS pro Seite gegen 60 KB prüft, ist ohne Browser machbar.
117. [CI] `pages.yml` Smoke-Job prüft Startseite, Feed, Sitemap und llms.txt, aber keine deutsche Seite und kein `hreflang` auf der Live-Seite; eine Stichprobe `/de/anleitungen/` plus `/de/blog/feed.xml` wäre ein Einzeiler.
118. [CI] Keine automatische Prüfung der Preise im Kostenrechner (Standardwerte `c`, `u`) gegen die Vercel-Preisseite; ein monatlicher Job warnt, wenn der Stand älter als 90 Tage ist (Datum im HTML, `Last updated`).
119. [CI] `dependabot.yml` hat kein `groups:` und keinen Eintrag für `pip` (Python-Skripte nutzen nur Standardbibliothek, aber `ruff==0.16.7` ist in `ci.yml` fest verdrahtet): Ruff-Pin wird nie aktualisiert.
120. [CI] `pages.yml` hat `INDEXNOW_KEY` im Klartext (öffentlich gewollt); aber kein Ping an Google (Search Console API) und keine Prüfung, ob IndexNow `422/403` zurückgibt (nur "200/202 = accepted" wird geloggt, ein Fehler bleibt unsichtbar). Bei 4xx eine Annotation `::warning::` setzen.

## J. Tests

121. [Test] Kein Test für `site/js/calculator.js`, `site.js`, `home.js` (kein Treffer in `tests/`): Formel (`calculator.js:47-48`), URL-Parameter, Suchranking (`site.js:85-90`). `node --test` mit extrahierten Funktionen plus Paritätstest Rechner gegen `deploys simulate`.
122. [Test] Playwright-Smoke für Theme-Umschalter, Copy-Knopf, Suche (Pfeiltasten, Esc) und Tab-Leiste der Startseite (`home.js` Tabs mit Home/End); heute nur statisch geprüft.
123. [Test] `check-site.py` prüft nicht, dass die Anzahl FAQ-Fragen und HowTo-Schritte in EN und DE übereinstimmt; Übersetzungen driften unbemerkt.
124. [Test] Kein Test, dass jede `docs/*.md` mit `.de.md` ähnlichen Umfang hat (CLI.de 113 gegen CLI.md 446 Zeilen, GUARD.de 65 gegen 114, PERF.de 57 gegen 163); `check-docs.py` prüft nur Vorhandensein. Schwelle DE unter 60 Prozent warnen.
125. [Test] Kein Test, dass `site/llms.txt` die Version aus `VERSION` und die Hostliste aus `providers/` enthält (`check-release.py` prüft Startseite, Appcast, install-Kopie, man-Seite; llms.txt nicht).
126. [Test] `scripts/appcast.py` hat keine Prüfung, dass `sparkle:minimumSystemVersion` mit `LSMinimumSystemVersion` aus der Zip übereinstimmt (das macht nur `release.sh`); ein Unit-Test mit Fixture-Zip-Plist fehlt.
127. [Test] `tests/` testet die DE-Strings der Mac-App (`check-strings.py`), aber nicht die Website-Texte: Eine Prüfung, dass DE-Seiten keine großen englischen Absätze enthalten (Sprachheuristik über Stoppwörter), fängt vergessene Übersetzungen.
128. [Test] Dead-External-Link-Check läuft wöchentlich ohne Retry/Allowlist für bekannte 403-Ketten (Vercel/Cloudflare blockieren Bots); ein Fehlalarm pro Woche verwässert den Alarm. Allowlist-Datei mit Ablaufdatum.
129. [Test] `check-links.py` prüft `#anchor` in Seiten; nicht, ob `id`-Anker nach einer Überschriften-Umbenennung für ausgehende Fremdlinks (README, Marketing-Texte, Reddit-Vorlagen) noch existieren. Marketing-Links in `marketing/*.md` werden nicht geprüft.

## K. Marketing

130. [Feature] `marketing/reddit.md` hat r/vercel, r/nextjs, r/macapps, r/SwiftUI, r/SideProject, r/selfhosted; es fehlen r/ClaudeAI und r/ClaudeCode (Autofix und Cloud Sessions passen genau), r/webdev, r/devops, r/opensource (0 Treffer in Ideen).
131. [Feature] `marketing/answer-templates.md` hat 8 Vorlagen, nur zu Vercel und Render. Fehlen: "Cursor/Claude Code pusht zu oft", "Netlify-Credits aufgebraucht", "Cloudflare Pages Build-Limit", "Reicht ein Ignored Build Step?".
132. [Feature] Antwortvorlagen für die offiziellen Foren (Vercel Community, Render Community, Netlify Forums) mit Hinweis auf deren Regeln; 0 Treffer in Ideen.
133. [Feature] Ein Beitrag im Format "Ask HN/Tell HN" statt nur Show HN (`marketing/show-hn.md`): "Ask HN: Wie begrenzt ihr Build-Kosten bei KI-Agenten?" mit Link nur in Kommentaren.
134. [Feature] Cross-Post-Vorlagen für dev.to und Hashnode mit `canonical_url` auf den Guide (Backlinks ohne Duplicate-Content-Risiko); kein Eintrag in `backlinks.md`.
135. [Feature] Listings: AlternativeTo, Slant, StackShare, Console.dev, Changelog.com News; 0 Treffer in Ideen zu AlternativeTo, die `awesome-lists.md` führt nur GitHub-Listen.
136. [Feature] Kurzvideo-Formate: `video-scripts.md` hat drei Skripte (15-25 s) ohne Hochformat-Spezifikation für Reels, TikTok und YouTube Shorts (0 Treffer in Ideen); Untertitel-Datei (.srt) pro Skript.
137. [Feature] Ein Skript "Cloud Sessions im Blick" und eines "Performance-Guard in 20 Sekunden" für die neuen 0.14-Funktionen; `video-scripts.md:3` bezieht sich noch auf 0.7.0.
138. [Doku] `marketing/newsletters.md:43` "Checked on 2026-11-10": Alle Pitch-Adressen sind über zwei Wochen alt; ein Datumsfeld je Zeile und ein Skript, das Einträge über 30 Tage markiert.
139. [Feature] Ein "Pressekit" `/press/` (Logos als SVG, drei Screenshots, 100-Wörter-Beschreibung, Fakten aus `marketing/FACTS.md`, Zitierlizenz); 1 Treffer nur als Randnotiz.
140. [Feature] Launch-Checkliste je Release ("Release-Tag setzen, Appcast-PR mergen, Brew-Tap-PR, Blogpost, Reddit-Termin") als `marketing/release-checklist.md`; `launch-plan.md` ist ein einmaliger 4-Wochen-Plan für 0.7.
141. [Feature] Wiederkehrende Rubrik "Zahl der Woche" (aus `deploys digest`, anonymisiert) für X/LinkedIn; `x-thread.md` und `linkedin.md` sind einmalige Texte.
142. [Feature] Kooperationen: Gastbeitrag-Anfrage an Anbieter-nahe Blogs (z. B. Turborepo-, Next.js-Newsletter) mit Gegenleistung "Rechner einbetten" (iframe-Snippet existiert auf der Rechnerseite, wird nirgends beworben).
143. [Feature] Einbettbarer "Deploy-Ersparnis"-Badge-Generator auf der Website (SVG per URL-Parameter, wie shields.io), damit Nutzer ihre Ersparnis in READMEs zeigen; `integrations/badge` ist nur CLI.

## L. Community und Doku-Struktur

144. [Feature] Discussions-Kategorie "Show your number" (Ledger-Ersparnis, anonym) mit Vorlage; `.github/DISCUSSION_TEMPLATE/` hat ideas, q-a, show-and-tell, aber keine Kategorie mit festem Format für Zahlen, die in Guides zitiert werden können (mit Einwilligung).
145. [Feature] Monatliche "Provider-Gesundheit"-Seite: Welche Hosts hatten API-Änderungen, die Fixtures bedingten (`tests/fixtures/`); hilft Mitwirkenden bei neuen Providern und erzeugt Inhalt.
146. [Feature] `CONTRIBUTORS`-Wand oder `all-contributors`-Bot, der auch Nicht-Code (Übersetzung, Guide, Foto) würdigt; `docs/GOOD-FIRST-ISSUES.md` führt nur Code-Aufgaben.
147. [Feature] Übersetzungs-Aufruf für eine dritte Sprache (ES/FR/PT) mit `export-strings.py` als Gerüst: `scripts/export-strings.py` existiert, aber kein Hinweis in `CONTRIBUTING.md`, wie man Sprachen beisteuert.
148. [Doku] `docs/GLOSSARY.de.md` führt nur "die neuen deutschen Einträge" (laut `docs/README.md:62`); Leser sehen ein halbes Glossar. Vollständige Fassung oder Verweis je Eintrag.
149. [Doku] `CONTRIBUTING.md` nennt `bash tests/all.sh`, aber nicht `tests/all.sh --only <name>` und `--quick` im Einstieg; neue Beitragende starten sonst den ganzen macOS-Lauf.
150. [Doku] `marketing/FACTS.md:5,11` nennt 0.11.0 (Idee 826 kennt das), neu: Zahlen "16 Hosts" und "Performance-Guard" fehlen ebenso in der Tabelle "What the app does" (für 0.7 geschrieben); ein Skript, das FACTS aus `VERSION`, `providers/` und `deploys --help` erzeugt, wäre die dauerhafte Lösung.
151. [Doku] Kein Changelog-Stil-Test für `## Unreleased`: Die zwei Einträge dort (Performance-Guard-Docker, Cloud Sessions) sind lang; `check-docs.py` könnte Zeilen über 500 Zeichen warnen, damit Release-Notizen lesbar bleiben (Notizen gehen in Sparkle-Dialog und GitHub-Release).
