# Deploy Center – Ideen, Runde 6

Stand: origin/main aa128e9 (0.9.1), Branch `feat/settings-tabs`. Durchgesehen wurden alle getrackten Dateien in `app/`, `ios/`, `widgets/`, `shared/`, `deploys`, `lib/`, `providers/`, `integrations/`, `examples/`, `tests/`, `scripts/`, `.github/`, `build.sh`, `release.sh`, `site/`, README, `docs/` und SECURITY. Alles ist mit IDEEN 1–5, CHANGELOG und git log abgeglichen, hier steht nur Neues.
961 Punkte, mit den Runden 1–5 zusammen weit über 1000. Stichproben aus den Bug-Meldungen (Store, Model, iOS, deploys, Provider, Paketierung, Site) wurden am Code nachgeprüft und stimmen. Mit „(Vermutung)“ markierte Punkte sind nicht am Code oder live geprüft. Tags: Bug, UX, Perf, Security, A11y, Feature, Code, Test, CI, Text, SEO, Growth, Store, Pro, Fun.

## Stand der Umsetzung

In den Abschnitten 1–7: ✅ = gebaut, ◐ = teilweise (Branch `fix/welle-2`). Ohne Zeichen = offen oder bewusst übersprungen (schon erledigt, falsch, braucht Entscheidung).

## 0. Zuerst angehen

✅ = gebaut, ◐ = teilweise, in Branch `fix/welle-1` gebaut (Welle 1, 10.11.2026). Ausnahme: Datenschutz-Absätze sind Entwurf, rechtlich prüfen.

1. ✅ **Fünf neue Provider halten den Provider-Vertrag nicht ein** (Netlify, Cloudflare, Coolify, DigitalOcean, Amplify).
   - `_has` gibt keine ID aus.
   - `_status` und `_latest` liefern JSON statt `id<TAB>phase<TAB>state`. Deshalb laufen `watch`, `deploy --wait`, Gruppen-Deploys und `verify` ins Leere.
   - Die Vertragstests laufen für diese fünf gar nicht (`tests/fixtures/<p>/env` fehlt).
   - Fundstellen: providers/netlify.sh:169, deploys:244, tests/providers/contract.sh:71.
2. ◐ (teilweise: wirkt erst ab dem nächsten Release; harter Abbruch ohne lib/ fehlt noch) **CLI-Tarball und Homebrew-Formel liefern `lib/` nicht mit.** Team-Datei, Zwei-Personen-Regel, Observer-Liste, GitLab, `simulate` und `ledger` fallen bei Installation per install.sh oder brew still weg. (scripts/package-cli.sh:46/58, scripts/homebrew-formula.sh:60)
3. ✅ **Ausgeblendete Projekte werden mitdeployt.** `selectChanged` prüft `isHidden` nicht. Das betrifft ⌘A und „Alles mit Änderungen deployen“. (app/Store.swift:492)
4. ✅ **⌘A ignoriert Suche und Filter.** (app/MainWindow.swift:936)
5. ✅ **Das Deploy-Fenster und „Nur wenn grün“ lassen sich umgehen.** In der App gilt das für Einzel-Deploys aus Zeilenmenü, Palette, Wiederholen und Details. In der CLI gilt es für `deploys deploy <p>` und Gruppen (kein `freeze_check`). (MainWindow.swift:586, deploys:1374)
6. ✅ **Der Observer-Modus lässt sich umgehen.** `deploy-changed --when-green --yes` umgeht ihn, weil `--yes` nur als erstes Argument geprüft wird. `autodeploy allow/revoke` sind gar nicht geschützt. (deploys:1306)
7. ✅ **`--when-green` übergibt `--sha` an Provider, die keinen bestimmten Commit deployen können.** Cloudflare, Netlify, DigitalOcean und Coolify brechen dann ab. (deploys:633)
8. ✅ **Builds über 40 Minuten gelten als fehlgeschlagen.** Danach ist der Knopf wieder frei, und ein zweiter, bezahlter Build ist möglich. (app/Store.swift:923)
9. ✅ **Der Auto-Rollback prüft nicht, ob inzwischen ein neuer Fix-Deploy läuft.** (app/Store.swift:1031)
10. ✅ **Das Warten auf grüne CI belegt einen Build-Platz bis zu 30 Minuten und lässt sich nicht abbrechen.** (app/Store.swift:765/874)
11. ✅ **Erlaubnisse für „alle“ zeigen kein Abzeichen.** `covers` vergleicht Plattform und Projekt exakt und kennt `all` und `*` nicht. (app/Model.swift:422)
12. ✅ **iOS: Ein zweiter Tipp startet einen zweiten Deploy**, weil `running` erst nach Face ID und dem POST gesetzt wird. (ios/App/PhoneStore.swift:124)
13. ✅ **iOS: Der Demo-Deploy verlangt einen Gerätecode.** Das ist ein Review-Risiko nach Guideline 2.1. (ios/App/PhoneStore.swift:117)
14. ✅ **iOS: Der Vercel-Rollback kann den falschen Deploy treffen** (`firstIndex ?? 0`). (ios/App/Clients.swift:154)
15. ✅ **iOS: Die QR-Übernahme überschreibt eigene Schlüssel mit leeren Feldern.** (ios/App/PhoneStore.swift:44)
16. ✅ **Projekte ohne Git-Repo gelten bei jedem Lauf als „state unknown“.** `changed` endet dann immer mit Exit 1, und ein Cron bleibt dauerhaft rot. (deploys:463)
17. ◐ (teilweise: andere Opt-in-Provider melden bei gesperrtem Schlüsselbund noch „no token“) **`render_last_of` hat kein curl-Timeout. Ein gesperrter Schlüsselbund unter launchd führt zu „Nothing to deploy“ mit Exit 0.** (providers/render.sh:149, deploys:219)
18. ✅ **Der MCP-Server gibt Build-Logs ungefiltert an den Agenten weiter**, prüft die Argumente nicht und schneidet JSON mitten drin ab. (integrations/mcp/server.mjs:221/341/113)
19. ✅ **Die Action deployt mit `deploy: true` jedes geänderte Projekt im ganzen Konto.** (integrations/action/action.yml:130)
20. ◐ (teilweise: Entwurf, rechtlich prüfen) **Die Datenschutzerklärung und SECURITY.md sind veraltet.** Claude/Anthropic, GitLab, Webhooks und Opt-in-Hosts fehlen. (site/datenschutz.html:51, SECURITY.md:52)
21. ✅ **README und FAQ nennen fertige Funktionen „fehlt noch“** (MCP, Netlify, GitLab, „no undo“), und die Website zeigt Version 0.9.0. (README.md:105/140, site/index.html:34)
22. ◐ (teilweise: nur main()/trap; Herkunftsprüfung offen, es gibt noch keinen Signaturschlüssel) **install.sh prüft nur die Prüfsumme, nicht die Herkunft.** Außerdem fehlt ein `main()`-Schutz gegen halb geladene Skripte. (site/install.sh:124)
23. ✅ **Demo-Modus: Die Details zeigen das echte Favicon.** (app/DetailViews.swift:165)
24. ✅ **„Kopieren“ im Build-Log maskiert keine Geheimnisse.** (app/DetailViews.swift:48)
25. ✅ **`integrations/tests/run.sh` läuft nie in CI. Übersprungene Tests zählen als bestanden.**

## 1. macOS-App: Oberfläche (Hauptfenster, Details, Palette, Einstellungen) (134)
### Teil 1: Oberfläche (MainWindow, DetailViews, CommandPalette, Einstellungen)


### Fehler: Auswahl und Deploy

1. ✅ [Bug] **Ausgeblendete Projekte werden mit angehakt und deployt.** `selectChanged` prüft `isHidden` nicht, und `deploySelected` filtert auch nicht, also landen ausgeblendete Projekte über ⌘A, „Alles mit Änderungen deployen …“ (Menüleiste, Palette) im Deploy; beim Anhaken `!isHidden` prüfen. (Store.swift:492; MainWindow.swift:283, 939)
2. ✅ [Bug] **⌘A ignoriert Suche und Filter.** „Alle mit Änderungen anhaken“ hakt jedes geänderte Projekt der Plattform an, auch die von der Suche weggefilterten, die man nicht sieht; nur die Einträge aus `visible` anhaken. (MainWindow.swift:936–940)
3. ✅ [Bug] **Zähler enthalten ausgeblendete Projekte.** „Nur mit Änderungen (9)“ und der Tab „35 · 9“ nutzen `changedCount`, das ausgeblendete mitzählt, während `waiting` und die Liste sie weglassen; die Zahlen passen dann nicht zur Liste. (Store.swift:481; MainWindow.swift:130, 397)
4. ✅ [Bug] **Leerer Grund bei „Warum jetzt deployen?“ tut stillschweigend nichts.** Der `guard` springt zurück, der Dialog schließt trotzdem, und es kommt keine Meldung; den Deploy-Knopf deaktivieren, solange das Feld leer ist. (MainWindow.swift:351–359)
5. ✅ [Bug] **Einzel-Deploys umgehen die Prüfung des Deploy-Fensters.** Nur `startDeploy` fragt `deploys window` und bietet „Trotzdem deployen …“ an; Zeilenmenü, Wiederholen, Palette und „Bis zu diesem Commit deployen“ rufen direkt `deployOne` auf, das Skript lehnt ohne `--force` ab, und man sieht einen rohen Fehler statt des Dialogs. (MainWindow.swift:586–594, 890; CommandPalette.swift:475; DetailViews.swift:198)
6. ✅ [Bug] **„Nur wenn die Checks grün sind“ gilt nur für die Sammelbestätigung.** Die Einstellung wird gemerkt, aber Zeilenmenü, Palette, Wiederholen und Commit-Deploy schicken nie `whenGreen` mit; sie sollte überall gelten oder dort sichtbar „ohne CI-Prüfung“ heißen. (MainWindow.swift:57, 870; Store.swift:661)
7. ✅ [Bug] **Rollback im Menü ohne Prüfung, ob die Plattform das kann.** Das Zeilenmenü prüft `caps.preview`, aber nicht `caps.rollback`, und die Palette bietet „zurückrollen“ für jedes deploybare Projekt an. (MainWindow.swift:884, 911; CommandPalette.swift:126)
8. ✅ [Bug] **„Build-Log“ wird auch ohne `caps.logs` angeboten.** Bei einem Provider ohne Logs führt der Eintrag zu einem Fehler im Sheet; ausblenden oder deaktivieren. (MainWindow.swift:895; CommandPalette.swift:129)
9. ✅ [Bug] **„Alles mit Änderungen deployen“ hakt auch auf abgeschalteten Plattformen an.** `pendingDeployAll` läuft über `Platform.allCases`, die Bestätigung zeigt nur `scopes`, und die unsichtbare Auswahl bleibt liegen. (MainWindow.swift:283–284)
10. ✅ [Bug] **„+2 auf Render“ in der Fußzeile zählt auch abgeschaltete Plattformen.** Ein Klick wechselt zu einem Tab, den es nicht gibt, und `resolve` fällt still auf den ersten zurück. (MainWindow.swift:956–958)
11. ✅ [Bug] **Doppeltes ⌘A.** Der versteckte Knopf und der Eintrag im Mehr-Menü tragen dieselbe Tastenkombination; welche greift, hängt von SwiftUI ab (Vermutung: im offenen Menü zweimal). (MainWindow.swift:985–996)
12. ✅ [Bug] **Kommentar und Code von `deploycenter://select` widersprechen sich.** Laut Kommentar „zeigt und hakt an“, der Code setzt aber nur die Suche. (App.swift:307–313)


### Fehler: Demo-Modus und Sicherheit

13. ✅ [Bug] **Demo-Modus zeigt in den Details das echte Logo.** `ProjectDetail` gibt `item.domain` an `Logo`, die Zeile im Demo-Modus `nil`, und das Favicon verrät das Projekt im Screenshot. (DetailViews.swift:165; MainWindow.swift:1328)
14. ✅ [Security] **„Kopieren“ im Build-Log kopiert den Rohtext ungefiltert.** Nur „Für Claude kopieren“ maskiert Tokens; ein normaler Kopier-Klick legt `ghp_…`/`Bearer …` in die Zwischenablage. Gleiche Maskierung anwenden, Rohtext nur per Wahltaste. (DetailViews.swift:48)
15. ✅ [Bug] **„Fehler kopieren“ nimmt im Demo-Modus den echten Namen und die ungefilterte Meldung.** (MainWindow.swift:1606)
16. ✅ [Bug] **Release-Notes und „Für Claude kopieren“ nehmen im Demo-Modus den echten Namen.** Für Vorführungen sollte dort der Platzhalter stehen, oder ein Hinweis „enthält echte Namen“. (DetailViews.swift:53, 174)


### Fehler: Zustände und Texte

17. ✅ [Bug] **Abgebrochene Deploys sehen aus wie Fehler.** `lastDeploy` zeigt bei „canceled“ einen roten Punkt und den Log-Knopf, `keyFigure` zählt es nicht als Fehler, und „cancelled“ mit Doppel-l wird gar nicht erkannt; einheitlich grau „abgebrochen“. (MainWindow.swift:1409, 1524)
18. ✅ [Bug] **Plural bei unvollständigen Zahlen fehlt.** „1 Commits, mindestens 1 PRs warten“: Der Zweig `pendingPartial` kennt keine Einzahl. (MainWindow.swift:1475)
19. ✅ [Bug] **GitLab-Projekte bekommen GitHub-Links und GitHub-Texte.** PR-Links werden fest als `github.com/…/pull/N` gebaut, dazu „Auf GitHub“, „Frage GitHub …“, „Der neueste Stand von GitHub geht live“ und „Wartende Commits auf GitHub ansehen“; seit 0.8 gibt es GitLab als Quelle. (DetailViews.swift:190, 319, 338; MainWindow.swift:334, 914; CommandPalette.swift:478)
20. ✅ [Bug] **Der Monorepo-Hinweis zählt Projekte über alle Plattformen.** Ein Vercel-Frontend mit Render-Backend im selben Repo bekommt den Tipp „Ignored Build Step“, obwohl es nur ein Vercel-Projekt gibt; nur Vercel-Projekte zählen. (DetailViews.swift:270–271)
21. ✅ [Bug] **Der empfohlene Ignored-Build-Step vergleicht nur den letzten Commit.** `git diff HEAD^ HEAD` kann bei einem Handdeploy über mehrere Commits einen nötigen Build überspringen, wenn der letzte Commit einen anderen Ordner betraf (Vermutung zu Vercels Verhalten); `$VERCEL_GIT_PREVIOUS_SHA` nehmen und darauf hinweisen. (DetailViews.swift:278)
22. ✅ [Bug] **Details nehmen `main` an, wenn kein Branch bekannt ist.** Repos mit `master` oder `develop` bekommen falsche Zahlen (Vermutung: wann `ref` nil ist). (DetailViews.swift:209)
23. ✅ [Bug] **Ein fehlgeschlagenes Nachladen im Build-Log und in den Details bleibt unsichtbar.** Ist schon Text da, wird der Fehler verschluckt; dazu eine Zeile „Stand von 14:02 – Neuladen fehlgeschlagen, nochmal“. (DetailViews.swift:87, 211)
24. ✅ [Bug] **Build-Log ruft `logs <id>` ohne Plattform auf.** Bei gleichem Namen auf zwei Plattformen ist das mehrdeutig (Vermutung). (DetailViews.swift:82)
25. ✅ [Bug] **Die Suche trifft Domain und Quelle, markiert aber nur den Namen.** Treffer wirken grundlos; außerdem filtert `localizedCaseInsensitiveContains` anders als `range(options: .caseInsensitive)`, und bei Umlauten kann die Markierung fehlen. (MainWindow.swift:178–180, 1303–1307)
26. ✅ [Bug] **„≈ im Monat bei diesem Tempo“ ist zu niedrig.** Der Schnitt teilt durch sieben Tage einschließlich des angebrochenen heutigen (UTC); nur ganze Tage rechnen. (MainWindow.swift:1053–1054, 1077)
27. ✅ [Bug] **„Kopiert ✓“ im Teilen-Popover bleibt für immer stehen.** `copied` wird nie zurückgesetzt (CopyButton macht es nach 1,5 s). (MainWindow.swift:1149–1150)
28. ✅ [Bug] **„Als PNG sichern“ scheitert still.** `try? png.write` verschluckt Schreibfehler, zum Beispiel bei fehlenden Rechten. (MainWindow.swift:1169)
29. ✅ [Bug] **Die Projektliste der Palette-Kosten ist toter Code.** `PaletteCosts` wird nur gezeigt, wenn `store.costs == nil`, die Rangliste darin aber nur, wenn es Kosten gibt; also nie. Die Rangliste in `CostsSheet` übernehmen. (CommandPalette.swift:304–319, 399)
30. ✅ [Bug] **Das Schließen der Störungsmeldung hält nur bis zum Neustart.** `closedIssues` ist `@State`, und der Array-Vergleich holt das Banner zurück, sobald sich nur die Reihenfolge ändert. (MainWindow.swift:83, 468, 563)
31. ✅ [Bug] **Ein Klick auf ein Projekt in der Menüleiste zeigt manchmal mehrere.** `pendingSearch` setzt den Namen als Suche, „app“ trifft auch „app-backend“; das Projekt besser genau ansteuern und markieren. (MainWindow.swift:305–308; App.swift:397)


### Fehler: Befehlspalette

32. ✅ [Bug] **Der Tastenmonitor der Palette wirkt in der ganzen App.** Solange die Palette offen ist, schluckt er ↑, ↓ und Esc auch im Einstellungsfenster; `e.window` prüfen. (CommandPalette.swift:219–223)
33. ✅ [Bug] **Ein belegter Hotkey scheitert still.** Wenn `RegisterEventHotKey` scheitert (⌥⌘K von einer anderen App belegt), wird das nur geloggt, und der Schalter bleibt an; Fehler unter dem Schalter zeigen und den Schalter zurückstellen. (CommandPalette.swift:527–532, 542)
34. ✅ [Bug] **Der Hotkey öffnet die Palette in jedem Hauptfenster.** Alle Hosts reagieren auf `requests`, und `WindowGroup` erlaubt mehrere Fenster (Vermutung). (CommandPalette.swift:404; App.swift:304)
35. ✅ [Bug] **`summon()` holt womöglich das falsche Fenster nach vorn.** Gewählt wird das erste sichtbare Fenster, das Hauptfenster werden kann, und das kann das Einstellungsfenster sein (Vermutung); gezielt das Fenster „main“ nehmen. (CommandPalette.swift:350)
36. ✅ [Bug] **Die Palette listet Projekte abgeschalteter Plattformen.** Sie läuft über `Platform.allCases` statt über die eingeschalteten Provider (Vermutung: es liegen alte Daten im Speicher). (CommandPalette.swift:117)
37. ✅ [Bug] **Die Palette zeigt höchstens 60 Treffer, ohne Hinweis.** Bei vielen Projekten (6 Verben × N) fehlen Einträge ohne Hinweis; „weitere … tippen, um einzugrenzen“ anzeigen. (CommandPalette.swift:166)


### Fehler: Einstellungen (auf den Tabs aufbauend)

38. ✅ [Bug] **Verweise auf die Einstellungen öffnen nicht den passenden Tab.** „Einstellungen → Ausgeblendete Projekte“ liegt jetzt unter Plattformen, aber `SettingsLink` öffnet den zuletzt genutzten Tab; vorher `settingsTab = "platforms"` setzen. (MainWindow.swift:816, 833, 836)
39. ✅ [Bug] **Plattformen lassen sich einschalten, die das Fenster nicht anzeigen kann.** Was das Skript meldet (z. B. AWS Amplify), aber `Platform` nicht kennt, wird ein Tab „kommt bald“; die Zeile in den Einstellungen sollte „nur in der Kommandozeile“ sagen oder den Schalter sperren. (App.swift:136–153; MainWindow.swift:125, 771)
40. ✅ [Bug] **Der Autofix-Hinweis öffnet den Claude-Tab, aber nicht bei Autofix.** Dafür nutzt er den privaten Selektor `showSettingsWindow:` (Vermutung: nicht stabil über alle macOS-Versionen); `openSettings` mit einem Anker verwenden. (Store.swift:209–211)
41. ✅ [Bug] **Hinweise zu Mitteilungen und Anmeldeobjekten veralten.** `notificationsDenied`, `openAtLogin` und `loginNeedsApproval` werden nur beim Öffnen gelesen, also nach einer Änderung in den Systemeinstellungen bei `didBecomeActive` neu lesen. (App.swift:29–30, 68–79)
42. ✅ [Bug] **„Beim Anmelden öffnen“ kann im Fehlerfall zweimal registrieren.** Setzt `onChange` nach einem Fehler `openAtLogin` zurück, läuft `onChange` noch einmal (Vermutung). (App.swift:99–102)
43. ✅ [Bug] **Auswahllisten bleiben bei unbekannten Werten leer.** Steht in `refreshMinutes`, `maxParallel`, `undoSeconds` oder `staleDays` ein Wert, der nicht in der Liste ist (älteres Build, `defaults write`), zeigt die Liste nichts; Wert auf den nächsten erlaubten setzen. (App.swift:84–86, 167–177)
44. ✅ [Bug] **„Diagnose kopieren“ kennt nur Vercel und Render.** Weitere Provider, GitLab und Autofix fehlen; die Zeilen aus `deploys providers --json` bauen. (App.swift:258–265)
45. ✅ [Bug] **Der Text im Hilfe-Abschnitt ist veraltet.** Er nennt nur „GitHub, Vercel und Render“, obwohl es GitLab und weitere Provider gibt. (App.swift:268–269)
46. [Bug] **System-Texte bleiben auf Englisch.** Im Screenshot stehen bei deutscher Oberfläche „File Edit View Window Help“ und „Deploy Center Settings“; vermutlich fehlen `de.lproj` bzw. `CFBundleLocalizations` im Bundle (Vermutung). (build.sh)


### Einstellungen: Aufbau der Tabs

47. ✅ [UX] **Tab-IDs als Enum mit einer Hilfsfunktion.** `SettingsTab` statt Strings, und `openSettings(tab:anchor:)` für Toast, Leerzustand, Beobachter-Hinweis und Ausgeblendete; Tippfehler fallen sonst still auf „Allgemein“ zurück. (App.swift:37; Store.swift:209)
48. ✅ [UX] **„Erweitert“ (Hotkey) gehört nicht unter Team.** In Allgemein oder einen eigenen Tab „Erweitert“ verschieben; der Kommentar „Settings → Advanced“ stimmt nicht mehr. (App.swift:61; CommandPalette.swift:504, 541)
49. ✅ [UX] **Kosten bekommen einen eigenen Tab.** Budget und Ersparnis sind kein Deploy-Thema; ein Tab „Kosten“ hat Platz für Budget, Ersparnis-Methode und später die Währung. (App.swift:51, 181–192)
50. ✅ [UX] **Die iPhone-Verbindung ist keine Plattform.** `PhoneLinkSettings` in Allgemein oder einen eigenen Tab „iPhone“ verschieben, damit Plattformen nur Hosting-Anbieter zeigt. (App.swift:49)
51. ✅ [UX] **Ein Tab „Projekte“ statt Ausgeblendete unter Plattformen.** Ausgeblendete, angeheftete, Notizen, Prüfseiten, „Zurückrollen bei Fehler“ und ignorierte Build-Auslöser an einem Ort, jeweils mit Zurücksetzen. (App.swift:234–250)
52. ✅ [UX] **Fensterhöhe je Tab.** Statt der festen 420–820 pt soll sich das Fenster der Höhe des Tabs anpassen (Hilfe ist fast leer, Claude lang); `windowResizability(.contentSize)` und Inhalt in natürlicher Höhe. (App.swift:66–67)
53. ✅ [UX] **„Kommt bald“-Plattformen abgesetzt zeigen.** Im Screenshot wirken sie wie kaputte Schalter; in einen ausklappbaren Bereich „Geplant“ ohne Schalter legen. (App.swift:143–150)
54. ✅ [UX] **Gesperrten Schalter erklären.** Ist nur noch eine Plattform an, wird ihr Schalter grau ohne Grund; `.help` „Mindestens eine Plattform bleibt an“. (App.swift:153)
55. ✅ [UX] **„Kein Dock-Symbol“ ausgegraut ohne Grund.** Ist die Menüleiste aus, fehlt der Hinweis „Braucht das Menüleisten-Symbol“. (App.swift:92–93)
56. ✅ [UX] **Budget-Feld mit Währung und Wirkung.** Mit einem Währungsformat, einem Stepper und dem Satz „Warnung ab 80 % des Tempos, also ab … $ heute“ versteht man das Feld ohne Doku. (App.swift:183–189)
57. ◐ [UX] **Das Einstellungsfenster überdeckt das Hauptfenster.** Im Screenshot verdeckt es das rote Banner „Etwas anderes startet noch Builds“; Position merken (Frame-Autosave) oder neben dem Hauptfenster öffnen. (App.swift:335)
58. ✅ [UX] **Plattform-Schalter mit Fortschritt und Ergebnis.** Nach dem Umschalten „Vercel: eingeschaltet, 35 Projekte geladen“ statt nur Spinner, Fehler mit „Nochmal“. (App.swift:139–161)
59. ◐ [Feature] **Verbindungsstatus pro Plattform in den Einstellungen.** Angemeldet, Key vorhanden oder CLI zu alt, dazu „Verbinden …“, „Key ändern“, „Key entfernen“; heute geht der Render-Key nur über den Einrichtungsbildschirm im Hauptfenster und lässt sich danach nicht ändern. (App.swift:133; MainWindow.swift:1250)
60. [Feature] **Hinweis-Punkte an den Tabs.** Ein roter Punkt an „Plattformen“, wenn eine nicht verbunden ist, an „Claude“, wenn Autofix halb eingerichtet ist, an „Allgemein“, wenn Mitteilungen gesperrt sind. (App.swift:46–64)
61. [Feature] **Suchfeld in den Einstellungen.** Bei sechs Tabs und über 30 Optionen findet man „Budget“ oder „Hotkey“ schneller per Suche, die Tab und Abschnitt hervorhebt. (App.swift:46)
62. ✅ [Feature] **Tastenkürzel-Übersicht im Hilfe-Tab.** ⌘K, ⌥⌘K, ⌘A, ⌘↩, ⌘R, ⌘1–4, Esc und ⇧-Klick an einer Stelle; der Hilfe-Tab hat heute nur drei Zeilen. (App.swift:252–272)
63. ✅ [Feature] **„Auf Standard zurücksetzen“ je Tab.** Zurücksetzen mit Bestätigung, ohne Keys und ohne Projektdaten anzufassen. (App.swift:46–64)
64. ✅ [Feature] **Deeplink in die Einstellungen.** `deploycenter://settings/claude` öffnet den Tab, damit Doku, CLI (`deploys doctor`) und Toasts direkt dorthin verlinken. (App.swift:309–313)
65. [Feature] **Reihenfolge der Plattform-Tabs per Ziehen.** Damit bestimmt man auch ⌘1–⌘4; heute stehen Vercel und Render fest vorn. (App.swift:136; Providers.swift:76)
66. ✅ [Feature] **Rückfrage bei Einzel-Deploys einstellbar.** „Bei Einzel-Deploys immer fragen / nie fragen“ (Deploy-Tab) beendet den Unterschied zwischen Zeilenmenü (fragt nicht) und Palette (fragt). (App.swift:165–178)
67. ✅ [Feature] **Demo-Modus per Menü und Tastenkürzel.** Ein Eintrag im Darstellen-Menü (z. B. ⌥⌘D) schaltet ihn um, ohne die Einstellungen zu öffnen; dazu ein sichtbares „DEMO“-Abzeichen im Fenster, damit man ihn nicht vergisst. (App.swift:113)


### Hauptfenster: Bestätigungen und Hinweise

68. ✅ [UX] **Eine Bestätigung für alle Wege.** Fenster und Palette haben getrennte Dialoge mit unterschiedlichem Inhalt (die Palette ohne „schon aktuell“, ohne „Nur wenn grün“); eine gemeinsame Komponente nehmen. (MainWindow.swift:326–338; CommandPalette.swift:473–479)
69. ✅ [UX] **„Live deployen“ im Zeilenmenü fragt nicht.** Die Palette fragt beim selben Befehl; bei 0 s Wartezeit startet ein Fehlklick sofort einen bezahlten Build. (MainWindow.swift:890–893)
70. ✅ [UX] **Riskante Projekte in der Bestätigung kennzeichnen.** Ein „⚠︎ riskant (Migration, Env)“ hinter dem Namen, wenn `risk.isRed`, denn der Dialog ist der letzte Moment vor dem Live-Gang. (MainWindow.swift:331–332)
71. ✅ [UX] **Plattform in der Sammelbestätigung nennen.** Unter „Alle“ ist ein Name auf Vercel und Render sonst nicht zu unterscheiden. (MainWindow.swift:331)
72. ✅ [Code] **„Nur wenn grün“ hängt am Unterdrücken-Schalter des Dialogs.** `dialogSuppressionToggle` meint „nicht mehr fragen“, und VoiceOver bzw. künftige macOS-Versionen können ihn so behandeln (Vermutung); ein Sheet mit echter Checkbox nehmen. (MainWindow.swift:338)
73. ✅ [UX] **„Alles abbrechen“ fragt nicht.** Ein Klick bricht alle laufenden und wartenden Deploys ab; kurze Rückfrage mit Anzahl, oder Rückgängig während der Wartezeit. (MainWindow.swift:964)
74. ✅ [UX] **„Ignorieren“ bei Build-Auslösern ist endgültig.** Ohne Rückgängig-Toast und ohne Liste in den Einstellungen bleibt ein versehentlich ignorierter Workflow für immer unsichtbar. (MainWindow.swift:82, 538)
75. ✅ [UX] **Die eingeklappte Hinweiszeile sagt zu wenig.** „1 weitere: Clau…“ (Screenshot) zeigt nur Wörter; ein Symbol und eine Farbe je Hinweis (rot, orange, grau) zeigen die Dringlichkeit ohne Aufklappen. (MainWindow.swift:509–519)
76. ✅ [UX] **Ladefehler-Banner mit „Details“ und „Kopieren“.** Die Meldung ist auf zwei Zeilen gekürzt, der Rest geht verloren. (MainWindow.swift:716)
77. ✅ [UX] **GitHub-Kontingent-Banner mit Restzeit.** „Zahlen kommen in 12 Min zurück“ und danach automatisch neu laden, statt nur eine Uhrzeit. (MainWindow.swift:614–623)
78. ✅ [UX] **Statusseiten aus den Provider-Daten.** Die Links gibt es fest für Vercel, Render und GitHub; Amplify, GitLab und künftige Provider fehlen, die URL gehört in `ProviderInfo`. (MainWindow.swift:571–572)
79. ✅ [UX] **Ein Klick auf die Übersichtszeile wechselt ungefragt den Tab.** Ist man auf „Render“, springt die App auf „Alle“; besser den Filter setzen und die Zahl auf den aktuellen Tab beziehen. (MainWindow.swift:636)


### Hauptfenster: Zeilen, Menüs, Liste

80. ✅ [UX] **Fehlermeldung in der Zeile lesbar machen.** Bei „Fehler“ steht die Meldung nur im Tooltip; die erste Zeile gekürzt in Grau darunter spart den Weg ins Log. (MainWindow.swift:1601–1605)
81. ✅ [UX] **Zwei Notizen sehen gleich aus.** Die eigene Notiz (kursiv, Symbol) und `item.note` vom Skript (Kapsel) sind kaum zu unterscheiden; die Kapsel mit Quelle beschriften („Vercel:“) oder anders gestalten. (MainWindow.swift:1347, 1363–1368)
82. ✅ [UX] **Vercel-Dashboard fehlt im Zeilenmenü.** Die Palette öffnet es über `deploys open --dashboard`, das Zeilenmenü kennt nur Render. (MainWindow.swift:916–918; CommandPalette.swift:443–450)
83. [Feature] **Kopieren-Untermenü in der Zeile.** Domain, Repo, Projekt-ID, Live-SHA und Vorschau-URL kopieren, praktisch für Tickets und Chat. (MainWindow.swift:900)
84. [Feature] **Repo-Überschrift mit Aktionen.** Ein Klick auf die Überschrift hakt alle Projekte des Repos an, ein Rechtsklick öffnet das Repo oder den Vergleich. (MainWindow.swift:848–851)
85. ✅ [UX] **Repo-Überschrift mit Zahl.** „org/repo · 3 Projekte · 12 Commits warten“ erspart den Blick in jede Zeile. (MainWindow.swift:849)
86. ✅ [UX] **Mehr-Menü: Meldungen anklickbar.** Die letzten Meldungen zeigen nur Text; ein Klick auf eine Fehlermeldung sollte das Log des Projekts öffnen, dazu „Leeren“. (MainWindow.swift:1014–1025)
87. ✅ [A11y] **⌘K und ⌘A in die Menüleiste.** Beide sind versteckte Knöpfe mit Deckkraft 0; als `Commands` im Menü „Darstellung“ bzw. „Bearbeiten“ findet man sie und sieht das Kürzel. (MainWindow.swift:984–988; CommandPalette.swift:385–391)
88. ✅ [A11y] **„Erhöhter Kontrast“ nicht überall.** Störungs-, GitHub- und Freigabe-Banner nutzen feste `opacity(0.08)` statt `ground()`. (MainWindow.swift:567, 613, 623, 1713)
89. ✅ [A11y] **„Bewegung reduzieren“ beachten.** Der Toast fliegt von unten ein, die Hinweise klappen animiert auf; bei `accessibilityReduceMotion` nur überblenden. (MainWindow.swift:255, 270, 509)
90. ✅ [A11y] **Fehlerzeilen im Log nicht nur rot.** Bei „Ohne Farbe unterscheiden“ ein „✖“ oder fette Schrift vor die Fehlerzeilen setzen. (DetailViews.swift:127)
91. ✅ [A11y] **Das Log-Textfeld hat keinen Namen.** Das `NSTextView` braucht ein Accessibility-Label „Build-Log von …“, sonst sagt VoiceOver nur „Text“. (DetailViews.swift:104–111)
92. ✅ [A11y] **PR- und Commit-Knöpfe ohne Zusammenhang.** VoiceOver liest „#123“ bzw. den SHA; als Label „Pull Request 123 öffnen: Titel“ setzen. (DetailViews.swift:339, 341, 381)
93. [A11y] **Paletten-Zeilen ohne Hinweis auf die Tastatur.** Mit VoiceOver landet man in den Knöpfen statt in der Liste; die Liste als `List` mit Auswahl anlegen, nicht als `LazyVStack` aus Knöpfen. (CommandPalette.swift:193–201)


### Leistung

94. ✅ [Perf] **Die Palette rechnet pro Tastendruck mehrfach alles neu.** `PaletteCommands.all` (6 Einträge je Projekt) und die Fuzzy-Sortierung laufen in `results`, `recentCount`, `move` und `onChange` getrennt; einmal pro Abfrage berechnen und zwischenspeichern. (CommandPalette.swift:162–172, 226, 276)
95. ✅ [Perf] **Die Palette rechnet bei jedem Store-Poll neu.** Solange sie offen ist, baut jede Store-Änderung die Liste neu; den Projekt-Index beim Öffnen einfrieren und nur den Status nachziehen. (CommandPalette.swift:153, 175)
96. ✅ [Perf] **Details: `scrub` baut pro Zeile die Liste aller Projekte.** Jeder Commit-Text ruft `Platform.allCases.flatMap` auf; die Liste einmal pro Render bilden. (DetailViews.swift:159, 343)
97. ✅ [Perf] **Build-Log maskiert im Demo-Modus bei jedem Render 2000 Zeilen.** Das Ergebnis pro Laden zwischenspeichern. (DetailViews.swift:69)
98. ✅ [Perf] **Der Neu-laden-Knopf lädt Plattformen nacheinander.** Unter „Alle“ wartet Render auf Vercel; mit `TaskGroup` parallel laden. (MainWindow.swift:405)
99. ✅ [Perf] **`ImageRenderer` bei jedem Body.** `SavingShare.image` ist berechnet und rendert die Karte bei jedem Neuzeichnen; einmal in `onAppear` erzeugen. (MainWindow.swift:1138–1141, 1153)
100. [Perf] **`autofixState` zweimal pro Zeile.** Für Zeile und Hintergrund getrennt abgefragt; einmal lesen und weiterreichen. (MainWindow.swift:872, 876)


### Code

101. ◐ [Code] **MainWindow.swift ist zu groß (1716 Zeilen).** `CostsSheet`/`SavingShare`/`SavingCard`, `Row`/`AgentChips`, `Setup`/`RenderKeySetup` und die Hinweise in eigene Dateien; der Typprüfer braucht heute Tricks („in drei Teile geteilt“). (MainWindow.swift:215, 1043–1716)
102. [Code] **Die Einrichtung ist fest auf Vercel und Render verdrahtet.** `setupNeeded` und die Einrichtungs-Bildschirme kennen nur zwei Plattformen; die Prüfung sollte aus `deploys doctor` je Provider kommen, damit neue Provider ohne App-Änderung erscheinen. (MainWindow.swift:690–700, 781–794)
103. [Code] **`Platform` mit zwei Fällen blockiert neue Provider.** Das Fenster nutzt zugleich Provider-IDs (Strings) und `Platform`; solange `Platform` nur Vercel und Render kennt, bleibt jeder weitere Provider „kommt bald“. (Model.swift:11–15; MainWindow.swift:125)
104. ◐ [Code] **Pfade zu den Einstellungen stehen als freier Text.** „Einstellungen → Team“ und „→ Ausgeblendete Projekte“ sind an fünf Stellen verteilt; aus dem Tab-Enum erzeugen, dann bleiben sie beim Umbau richtig. (MainWindow.swift:816, 833, 968–971; Store.swift:675)
105. ✅ [Code] **Test für die Verweise auf Tabs.** Ein kleiner Test prüft, dass jeder `settingsTab`-Wert, der irgendwo gesetzt wird, ein existierender Tab ist. (App.swift:37; Store.swift:209)
106. [Code] **„Fokus weg“ per `makeFirstResponder(nil)` nach 200 ms.** Mit `.defaultFocus` bzw. `@FocusState` beim Start ohne Wartezeit lösen. (MainWindow.swift:319–321)


### Details und Build-Log

107. [Feature] **Im Log von Fehler zu Fehler springen.** „Nächster/voriger Fehler“ (⌘G / ⇧⌘G) statt nur „Zum ersten Fehler“; Build-Logs haben oft die eigentliche Ursache beim dritten Treffer. (DetailViews.swift:72–75, 136–139)
108. [Feature] **Dateipfade im Log anklickbar.** `src/app/page.tsx:42` erkennen und die Datei beim Live-Commit im Repo öffnen. (DetailViews.swift:109, 124–132)
109. [Feature] **Log sichern oder im Editor öffnen.** „Als Datei sichern …“ bzw. „In Konsole/Editor öffnen“ für lange Logs, die man durchsuchen oder anhängen will. (DetailViews.swift:48)
110. [Feature] **Agent- und Mensch-Commits in den Details.** Die Co-Authored-By-Trailer liegen in `details`; ein kleines „Agent“-Abzeichen an Commits zeigt, was ein Coding-Agent geliefert hat. (DetailViews.swift:337–351)
111. [Feature] **Offene PRs als „merge-bereit“ markieren.** CI grün, freigegeben, kein Entwurf: eine kleine Markierung, damit man vor dem Deploy noch mergen kann. (DetailViews.swift:379–391)
112. ✅ [UX] **Die Commit-Liste ist bei vielen Commits endlos.** Ab ca. 30 wartenden Commits gruppieren oder „weitere 80 zeigen“, damit die Risiko-Hinweise oben bleiben. (DetailViews.swift:336)
113. ✅ [UX] **„Bis zu diesem Commit deployen“ am neuesten Commit.** Dort ist es ein normaler Deploy; den Knopf am obersten Commit weglassen oder „= alles“ sagen. (DetailViews.swift:347–350)
114. ✅ [UX] **Das Log-Sheet kann breiter sein als das Fenster.** Die Mindestbreite 760 liegt über der Mindestbreite des Fensters (680); bei schmalem Fenster ragt das Sheet hinaus. (DetailViews.swift:79; MainWindow.swift:239)


### Befehlspalette: Ausbau

115. [Feature] **Einstellungs-Tabs in der Palette.** „Einstellungen: Claude“, „Einstellungen: Plattformen“ öffnen direkt den Tab. (CommandPalette.swift:114, 428)
116. [Feature] **Umschalter in der Palette.** „Nur mit Änderungen“, „Demo-Modus“, Tab wechseln, „Anheften/Ausblenden <Projekt>“; alles, was sonst ein Rechtsklick ist. (CommandPalette.swift:62–80)
117. [Feature] **Gruppen und Repos als Ziel.** „deploy <Gruppe>“ nutzt `deploys deploy <group>` (in Reihenfolge, wartet auf live), „deploy repo X“ alle Projekte eines Repos. (CommandPalette.swift:117–145)
118. [Feature] **⇧↩ in der Palette für einen Vorschau-Deploy.** Eine zweite Aktion je Eintrag ohne neue Verben; der Fußtext nennt sie. (CommandPalette.swift:184, 209)
119. [Feature] **Tastenkürzel neben den Aktionen.** „Neu laden ⌘R“, „Kosten“, „Journal“ mit ihren Kürzeln, damit man sie nebenbei lernt. (CommandPalette.swift:235–257)
120. [Feature] **Eine PR- oder Commit-URL einfügen.** Ein eingefügter GitHub-/GitLab-Link (PR oder Commit) findet das Projekt und sagt „wartet“ oder „ist seit 14:02 live“; beantwortet die häufigste Frage im Team. (CommandPalette.swift:181)
121. [Feature] **Verlauf der Palette löschen.** Ein Eintrag „Zuletzt-Liste leeren“, z. B. vor Bildschirmfreigaben. (CommandPalette.swift:94–98)
122. [Feature] **Hotkey frei wählbar.** ⌥⌘K kollidiert mit anderen Apps; ein Rekorder-Feld im Tab „Erweitert“. (CommandPalette.swift:531, 542)


### Kosten-Sheet

123. ✅ [UX] **Kosten-Sheet mit „Budget“.** Ist ein Monatsbudget gesetzt, eine Linie im Diagramm und „noch … $ bis Monatsende“. (MainWindow.swift:1097–1130)
124. ✅ [UX] **Den angebrochenen Tag im Diagramm kennzeichnen.** Den heutigen Balken heller und als „bisher“ markieren, damit er nicht wie ein billiger Tag aussieht. (MainWindow.swift:1099–1102)


### Neue Ideen für die Oberfläche (kreativ)

125. [Feature] **„Bereit-Ansicht“ beim Öffnen.** Kommt man nach Stunden zurück, oben eine Karte „Seit gestern 18 Uhr: 3 live, 1 Fehler, 5 neu wartend“ mit einem Klick zu jeder Gruppe. (MainWindow.swift:218–238)
126. [Feature] **Leerer Zustand „Alles ist live“ mit Bilanz.** Statt nur Häkchen: „Letzter Deploy vor 2 Std · heute 0 Builds außer deinen · Ersparnis diese Woche …“. (MainWindow.swift:810–814)
127. [Feature] **Zeile zeigt, wer wartet.** Ein kleines Avatar-Paar der Autoren wartender Commits (mit Demo-Platzhaltern), damit man sieht, wessen Arbeit noch nicht live ist. (MainWindow.swift:1349–1355)
128. [Feature] **„Seit dem letzten Öffnen neu“-Markierung.** Ein Punkt an Zeilen, deren wartende Commits seit dem letzten Fensterbesuch dazukamen, wie ungelesen in Mail. (MainWindow.swift:1333–1346)
129. [Feature] **Schnellvorschau beim Drüberfahren über die Zahl.** Ein Popover auf „3 Commits · 2 PRs warten“ zeigt die PR-Titel, ohne das Detail-Sheet zu öffnen. (MainWindow.swift:1416–1418)
130. [Feature] **Deploy-Fenster sichtbar machen.** Ist laut `window.json` gerade zu, zeigt die Fußzeile „Deploy-Fenster zu bis Mo 8:00“, bevor man klickt, nicht erst im Dialog. (MainWindow.swift:947–981)
131. [Feature] **Fortschritt der Sammelauswahl in der Fußzeile.** Während eines Sammel-Deploys „3 von 7 live · 1 Fehler“ mit Mini-Balken; heute muss man die Zeilen absuchen. (MainWindow.swift:947–953)
132. [Feature] **Notiz mit Ablaufdatum direkt im Notiz-Dialog.** „Gilt bis …“-Datum im bestehenden Alert, danach verschwindet die Notiz von selbst. (MainWindow.swift:298–304)
133. [Feature] **Prüfseite testen.** Im Dialog „Seite für die Prüfung nach dem Deploy“ ein Knopf „Jetzt prüfen“, der die Seite einmal abruft und Status und Zeit zeigt. (MainWindow.swift:290–297)
134. [Feature] **Teilen-Karte mit Zeitraum und hellem Design.** Wahl zwischen dunkler und heller Karte sowie „letzte 30 Tage“, für Posts mit hellem Hintergrund. (MainWindow.swift:1174–1207)

## 2. macOS-App: Logik (Store, Model, Tool, Savings, Claude) (106)
Gelesen gegen den Arbeitsstand von `feat/settings-tabs` (auf `origin/main` aa128e9). Zeilen beziehen sich auf diesen Stand. Alles, was in IDEEN 1–5, CHANGELOG oder git log schon steht, ist weggelassen.


### Bugs: Zustand, Auswahl, Zählung

135. ✅ [Bug] **„Alle mit Änderungen anhaken“ hakt ausgeblendete Projekte an.** `selectChanged` prüft `isHidden` nicht; ⌘A und „Alles mit Änderungen deployen …“ aus der Menüleiste deployen damit auch Projekte, die man bewusst versteckt hat. `&& !isHidden(item)` ergänzen. (app/Store.swift:492)
136. ✅ [Bug] **Menüleisten-Liste zeigt ausgeblendete Projekte.** `changed` filtert nicht nach `isHidden`, die Zahl darüber (`waiting`) schon; Liste und Zahl passen nicht zusammen. (app/App.swift:369)
137. ✅ [Bug] **Zwei Projekte eines Repos auf verschiedenen Branches werden zusammengelegt.** `waiting` gruppiert nur nach `repo` und nimmt das Maximum; ein Staging-Projekt auf `develop` und Production auf `main` haben verschiedene wartende Commits. Schlüssel `repo + ref`. (app/Store.swift:451–457)
138. ✅ [Bug] **Fehler beim Abschalten von Auto-Deploy wird sofort gelöscht.** `turnOffAutoDeploy` schreibt `loadError[p]` und ruft direkt `load(p)`, das `loadError[p] = nil` setzt; der Fehler ist nie zu sehen. Fehler als Toast/`lastLoadError` melden. (app/Store.swift:501–503)
139. ✅ [Bug] **Render-Key speichern kann den Doctor löschen.** `doctor = try? await Tool.json(["doctor"])` setzt bei einem Fehler `doctor = nil`; die App fällt in den „nicht eingerichtet“-Zustand und startet bei der nächsten Runde komplett neu. Nur bei Erfolg zuweisen. (app/Store.swift:509)
140. ✅ [Bug] **Ein langsamer `providers --json`-Aufruf schaltet abgeschaltete Plattformen wieder ein.** `loadProviders` fällt bei jedem Fehler (Timeout 20 s) auf `builtIn` zurück: Render erscheint wieder, Settings sagt „diese Skript-Version zeigt immer Vercel und Render“. Bei Fehler die letzte Liste behalten. (app/Providers.swift:230–233)
141. ✅ [Bug] **Ein Fehler bei `guard status` löscht alle Erlaubnis-Abzeichen.** `else { allowances = [] }` widerspricht der Regel „Fehler behalten alte Werte“; nach einem Aussetzer verschwindet die Warnung „Auto-Deploy erlaubt“. (app/Store.swift:141)
142. ✅ [Bug] **Der Wächter-Knopf lädt auch abgeschaltete Plattformen.** `GuardSettings.run` ruft `store.load` fest für Vercel und Render, ohne `isEnabled`; die Zeilen einer abgeschalteten Plattform kommen zurück. Außerdem nacheinander statt parallel. (app/Guard.swift:88)
143. ✅ [Bug] **`autoRefresh` lädt Vercel ohne `vercelApi`, `start()` nur mit.** Unterschiedliche Bedingung, damit Fehlerzeilen bei fehlendem API-Zugang alle 15 Minuten. Eine gemeinsame `canLoad(p)`-Funktion. (app/Store.swift:312 und 434)
144. ✅ [Bug] **Beobachter-Modus verliert die Auswahl.** `deploySelected` leert die Auswahl, bevor `enqueue` im Beobachter-Modus ablehnt; die Haken sind weg, ohne dass etwas passiert. Erst prüfen, dann leeren. (app/Store.swift:650–653)
145. ✅ [Bug] **Gemergte Fixes werden auch im Beobachter-Modus angehakt.** `preselectMergedFixes` prüft `observer` nicht; außerdem vergisst die Liste nach 100 Einträgen alte Schlüssel und hakt dieselbe Zeile erneut an. (app/Store.swift:162–175)
146. ✅ [Bug] **Budget-Hochrechnung zählt den angefangenen Tag mit.** `checkBudget` nimmt `days.suffix(7)` inklusive heute; morgens ist der Tag fast leer und drückt den Schnitt. `Costs.saving` schließt heute aus, das Budget nicht. (app/Store.swift:82)
147. ✅ [Bug] **`extrasFailedAt` wird nie angezeigt.** Der Kommentar verspricht „alte Werte zählen als veraltet“, aber keine Ansicht liest das Feld; Kosten von vor drei Tagen sehen aus wie aktuelle. „Stand von …“ an Kosten und Triggern zeigen. (app/Store.swift:31–33)
148. ✅ [Bug] **Erlaubnisse für „alle“ zeigen an keiner Zeile ein Abzeichen.** `covers` vergleicht Plattform und Namen exakt, das Skript liefert für Platzhalter aber `platform: "all"` bzw. `project: "*"`; gerade im Notfall „Auto-Deploy für alles an“ fehlt die Kostenwarnung in den Zeilen. Platzhalter in `covers` behandeln. (app/Model.swift:422)
149. ✅ [Bug] **Die tägliche Erinnerung geht verloren, wenn die App vorne ist.** `NotifyRouter.willPresent` gibt außer für den Rollback-Countdown `[]` zurück, obwohl `Notify.remind` „egal ob das Fenster vorne ist“ verspricht; `lastReminder` ist dann schon gesetzt. Kategorie für die Erinnerung mit `.banner`. (app/Model.swift:211–214 und 261–264, app/Store.swift:797)
150. ✅ [Bug] **Zusammenfassung eines Sammel-Deploys vergisst übersprungene Zeilen.** `summarize()` zählt nur `.done` und `.failed`; drei wegen roter CI übersprungene Projekte ergeben „5 live, 0 fehlgeschlagen“. `.skipped` mitzählen. (app/Store.swift:703–715)
151. ✅ [Bug] **Ein Rückgängig-Toast verdrängt den anderen.** `show()` reiht nur ein, wenn der neue Toast kein „Rückgängig“ hat; zwei Rollback-Countdowns im selben Lauf: der zweite ersetzt den ersten, dessen „Abbrechen“ bleibt nur in der Mitteilung. Undo-Toasts immer einreihen. (app/Store.swift:565–572)
152. ✅ [Bug] **Nie gestartete Frontends zählen im Journal als Fehlschlag.** „Nicht gestartet: das Backend … ist fehlgeschlagen“ läuft über `set(.failed)` und erscheint als `failed`, was „n der letzten 10 fehlgeschlagen“ aufbläht. Als `skipped` führen. (app/Store.swift:735 und 536)
153. ✅ [Bug] **Stale-Alarm zählt nicht deploybare Projekte.** `checkStale` fehlt die `deployable`-Bedingung, die `waiting` hat; „Repo unbekannt“-Projekte lösen den Alarm aus. (app/Store.swift:62–65)
154. ✅ [Bug] **Der Cache füllt abgeschaltete Plattformen.** `readCache` lädt alle Plattformen, bevor `loadProviders` weiß, welche aus sind; bis dahin zählen deren Zeilen in Menüleiste und Widget. Erst nach `loadProviders` oder nur `isEnabled`. (app/Store.swift:248–255 und 302)
155. ✅ [Bug] **Das Team-Beobachter-Flag wird nur beim Start gelesen.** `teamObserver` kommt aus einem einmaligen `config --json`; kommt man später in die `observers`-Liste eines Repos, zeigt die App weiter Deploy-Knöpfe, bis Settings → Team geöffnet wird. Mit `loadExtras` stündlich neu lesen. (app/Store.swift:309)


### Bugs: Deploy-Ablauf, Warteschlange, Abbruch

156. ✅ [Bug] **Ein Deploy, der auf grüne Checks wartet, lässt sich 30 Minuten nicht abbrechen.** Im Zustand `.running("waiting for checks")` gibt es keine `deployId`; `cancel` sagt „startet noch – gleich nochmal“, und `ci --wait 30m` läuft weiter. Den CI-Task speichern und bei Abbruch canceln (Tool.run beendet den Prozess bei Task-Abbruch schon). (app/Store.swift:765 und 879–880)
157. ✅ [Bug] **Warten auf CI belegt einen Build-Platz.** Der `ci --wait`-Aufruf läuft in `deploy()` nach `running += 1`; drei Projekte mit laufenden Checks blockieren bei `maxParallel = 3` alle anderen Deploys bis zu 30 Minuten. CI-Warten vor `pump()` oder als eigener Zustand ohne Platz. (app/Store.swift:723–726 und 874–889)
158. ✅ [Bug] **Builds über 40 Minuten gelten als fehlgeschlagen.** Die feste Deadline in `follow` meldet „Kein Ergebnis nach 40 Minuten“ als `.failed`, schreibt „failed“ ins Journal und gibt den Knopf frei; ein neuer Klick startet einen zweiten Build, obwohl der erste läuft. Deadline aus `usualMinutes` × 2 und danach „läuft noch“ statt Fehler. (app/Store.swift:923 und 969)
159. ✅ [Bug] **Auto-Rollback läuft auch, wenn inzwischen neu deployt wird.** Der Countdown ruft nach 10 s `rollback(itemNow)` ohne zu prüfen, ob die Zeile gerade wieder aktiv ist; ein schneller Fix-Deploy würde zurückgerollt. `guard !itemNow.state.isActive`. (app/Store.swift:1031–1036)
160. ✅ [Bug] **Render-Status `succeeded` überspringt Dauer, Live-Check und `markBehind`.** Der Zweig setzt nur `.done(nil)`; ein Rollback mit diesem Ende hinterlässt die Zeile als „aktuell“, Cron-Jobs bekommen nie eine Dauer-Schätzung. Wie `live` behandeln. (app/Store.swift:953–954)
161. ✅ [Bug] **`maxParallel` erhöhen startet nichts.** Nach dem Ändern in den Einstellungen bleibt die Schlange stehen, bis ein laufender Deploy endet; `pump()` bei Änderung von `maxParallel` aufrufen. (app/Store.swift:648, app/App.swift:167)
162. ✅ [Bug] **Neues Neulade-Intervall gilt erst nach dem alten.** Die Schleife schläft mit dem Wert von vorher; von 60 auf 5 Minuten wirkt erst nach bis zu einer Stunde. Schlaf in kurze Stücke teilen oder bei Änderung neu starten. (app/Store.swift:287–291)
163. ✅ [Bug] **`rollback()` prüft den Beobachter-Modus nicht.** `enqueue` lehnt ab, `rollback` (auch der Auto-Rollback-Countdown) nicht; das Skript verweigert zwar, aber die Zeile zeigt erst „startet“ und dann einen rohen Fehler. Gleiche Prüfung wie in `enqueue`. (app/Store.swift:837)
164. ✅ [Bug] **„Autofix nicht eingerichtet“ wird am Text erkannt.** `fixWithClaude` erkennt „Autofix nicht eingerichtet“ an einem englischen Teilstring der Skriptausgabe; ändert sich der Text, kommt ein roher Fehler-Toast. Exit-Code oder JSON-Feld. (app/Store.swift:190)


### Bugs: Prozesse, Nebenläufigkeit, Abstürze

165. ✅ [Bug] **Hängende Enkelprozesse lassen GCD-Threads für immer blockieren.** Nach dem Timeout bekommt der Aufrufer seine Antwort, aber der Runner-Thread wartet weiter in `read.wait()`, solange ein abgekoppelter Prozess (z. B. ein node-Daemon, nach launchd umgehängt) die Pipe offen hält; `killTree` findet ihn nicht mehr. Pipes nach dem Timeout schließen. (app/Tool.swift:208–216)
166. ✅ [Bug] **`ClaudeRun.run` hat das alte Hänger-Problem.** Timeout ruft nur `p.terminate()` auf den direkten Prozess, `readDataToEndOfFile` wartet weiter, wenn `claude` einen node-Kindprozess hat; Settings → Claude hängt. `Tool.killTree` wiederverwenden. (app/ClaudeConnect.swift:234–237)
167. ✅ [Bug] **`PhoneLinkModel.collect` blockiert den Swift-Thread-Pool ohne Zeitlimit.** `security` und `gh auth token` laufen mit `waitUntilExit` direkt in einer `async`-Funktion; fragt `gh` nach dem Schlüsselbund, hängt ein Thread des kooperativen Pools, beim Start jedes Mal. Auf eigene Queue, mit Timeout. (app/PhoneLinkMac.swift:45–72)
168. ✅ [Bug] **Log und Journal können bei voller Platte abstürzen.** `FileHandle.write(_:)`/`seekToEndOfFile()` werfen bei Fehlern eine Objective-C-Ausnahme, die Swift nicht fängt. `try h.seekToEnd(); try h.write(contentsOf:)`. (app/Tool.swift:298, app/Journal.swift:49)
169. ✅ [Bug] **„Einstellungen öffnen“ im Autofix-Toast tut auf macOS 14+ nichts.** `NSApp.sendAction(Selector(("showSettingsWindow:")))` wird ab Sonoma ignoriert („use SettingsLink“); die Menüleiste nutzt schon `openSettings`. Über eine `@Published`-Anfrage an eine View mit `openSettings` lösen. (app/Store.swift:211)


### Bugs: Daten, Dekodierung, Links

170. ✅ [Bug] **Vergleichslink zeigt bei GitLab-Repos auf github.com.** `compareURL` ist fest `https://github.com/…`, seit 0.8.0 kann die Quelle GitLab sein. Host aus dem Skript (`repoHost`/`compareUrl`) mitliefern. (app/Model.swift:180)
171. ✅ [Bug] **„Claude fragen“ übergibt bei Render die Service-ID ohne Plattform.** `ClaudeAI.ask(…, project: item.id)` schickt `srv-…` bzw. bei Vercel den Namen ohne Präfix; ein Name auf zwei Plattformen ist mehrdeutig. `platform:name` wie bei anderen Befehlen. (Vermutung zur Skriptseite) (app/ClaudeAI.swift:278)
172. ✅ [Bug] **Fehler-JSON des Skripts wird zu „data couldn't be read“.** Antwortet `vercel json` mit einem Objekt statt einer Liste (z. B. `{"error":…}`), scheitert `decodeLossy` mit der englischen Systemmeldung, die so in der Zeile steht. Objekt mit `error` erkennen und dessen Text zeigen. (app/Model.swift:42, app/Store.swift:333)
173. ✅ [Bug] **Widget rechnet „heute“ in UTC, das Fenster lokal.** `snapshotSaving` nutzt einen UTC-`DateFormatter`, `Costs.saving` bekommt den lokalen Tag; um Mitternacht zeigen Widget und Fenster verschiedene Ersparnisse. `costs.saving(today: localDay())` wiederverwenden statt Kopie. (app/Snapshot.swift:67–77)
174. ✅ [Bug] **Strenge Dekodierung in Settings-Bereichen.** `AutofixStatus` (`scheduled`), `GuardStatus` und `TeamConfig` (`readonly`, `sources`) verlangen Felder; fehlt eins (ältere/neuere Skriptversion), zeigt der Bereich „nicht eingerichtet“ bzw. nichts, und `teamObserver` wird nie gesetzt. Tolerant wie `Doctor`. (app/Autofix.swift:22–25, app/Guard.swift:23–27, app/Team.swift:22–27)
175. ✅ [Bug] **Deutsche Schätzmethode ist fest eingebaut.** `EstimateFooter` zeigt auf Englisch die Methode aus dem Skript, auf Deutsch immer denselben festen Text; ändert das Skript seine Methode, steht im deutschen Fenster etwas Falsches. Skript-Text in beiden Sprachen zeigen oder `method_de` liefern. (app/Savings.swift:406–407)
176. ✅ [Bug] **„Kopieren des Prompts“ scheitert still.** `copyPrompt` kehrt bei einem Fehler ohne Meldung zurück; der Knopf wirkt kaputt. Fehler in `message`. (app/Autofix.swift:133)
177. ✅ [Bug] **„Claude Code verbinden“ kann die bestehende Verbindung entfernen und keine neue anlegen.** Ist `code == .connected`, wird erst `mcp remove` ausgeführt; scheitert das folgende `mcp add`, ist Claude Code getrennt. Erst hinzufügen unter neuem Namen oder bei Fehler die alte Konfiguration wiederherstellen. (app/ClaudeConnect.swift:356–359)


### Bugs: Demo-Modus und Lokalisierung

178. ✅ [Bug] **Mac-Mitteilungen zeigen im Demo-Modus echte Namen.** `say()` reicht `name` roh an `Notify.post`, ebenso Erinnerung, Stale-Alarm und Rollback-Countdown; bei einer Bildschirmaufnahme erscheinen sie oben rechts. Vor `Notify` durch `Demo.mask`/`scrub`. (app/Store.swift:68–69, 542–547, 576–577, 1027)
179. ✅ [Bug] **Autofix-Ausgabe wird im Demo-Modus nicht maskiert.** `AutofixSettings.run` zeigt die Skriptausgabe roh (Projektnamen, Repos); `GuardSettings` maskiert schon mit `Demo.mask`. `Demo.scrub` wie im Store. (app/Autofix.swift:155, ebenso app/Team.swift:120 und app/ClaudeAI.swift:165)
180. ✅ [Bug] **Der QR-Code mit allen Schlüsseln erscheint auch im Demo-Modus.** Gerade dann wird aufgenommen. Im Demo-Modus Knopf sperren oder Code verpixeln. (app/PhoneLinkMac.swift:123 und 159–163)
181. ✅ [Bug] **Plural-Reste.** „1 projects wait …“, „1 PRs in 1 projects“, „1 PRs, 1 commits waiting“, „1 PRs still open“ (EN und DE). Gleiche Hilfsfunktion wie in `summaryLine`. (app/Store.swift:68 und 799, app/App.swift:394 und 410)
182. ✅ [Bug] **Plattformnamen per `capitalized`.** „Digitalocean“, „Cloudflare“ statt „DigitalOcean“, „Cloudflare Pages“ in Simulator, Bilanz und Wächter. `ProviderInfo.label` nutzen. (app/Savings.swift:509 und 670, app/Guard.swift:105 und 168)
183. ✅ [UX] **Render-Diensttypen und rohe Status bleiben englisch.** `typeName` („Web Service“, „Worker“) und `"Status: \(state)"` sind nicht übersetzt. In `L()` ziehen. (app/Store.swift:469–477 und 961)


### Sicherheit

184. ✅ [Security] **Das Fehlerprotokoll speichert stderr ungefiltert.** `Log.write("deploys …: \(text)")` schreibt rohe Skriptfehler (curl-/CLI-Ausgaben können Tokens enthalten), und das Log wird zum Anhängen an öffentliche Issues angeboten. `LogTools.maskSecrets` in `Log.write`. (app/Tool.swift:228 und 293)
185. ✅ [Security] **Der Maskierer der App ist schwächer als der des Skripts.** Laut CHANGELOG maskiert das Skript Stripe (`sk_live_`), GitLab (`glpat-`), npm (`npm_`), Google (`AIza…`), AWS-Secret-Keys und `-----BEGIN … PRIVATE KEY-----`; `LogTools.secrets` kennt davon fast nichts, „Für Claude kopieren“ lässt sie durch. Eine gemeinsame Musterliste (Datei im Bundle), die Skript und App lesen, plus Test pro Muster. (app/LogTools.swift:26–37)
186. ✅ [Security] **QR-Code-Fenster ist in Screenshots und Bildschirmfreigaben sichtbar.** Für das Sheet `NSWindow.sharingType = .none` setzen, dann fehlt es in Aufnahmen, Zoom/Meet-Freigaben und `screencapture`. (app/PhoneLinkMac.swift:137–166)
187. [Security] **QR-Code enthält die Schlüssel im Klartext.** Wer den Code 60 s sieht oder fotografiert, hat Render-Key und GitHub-Token. Inhalt mit einem einmaligen Code verschlüsseln, den man am iPhone eintippt (6 Ziffern). (app/PhoneLinkMac.swift:162)
188. [Security] **Das volle `gh`-Token wird per iCloud auf alle Geräte verteilt.** `gh auth token` hat meist `repo`, `workflow`, oft `admin:org`. Hinweis plus Feld für ein eigenes, nur lesendes Fine-grained-Token fürs iPhone, wie beim Vercel-Token. (app/PhoneLinkMac.swift:52)
189. ✅ [Security] **Backups der Claude-Konfiguration häufen sich und enthalten fremde Tokens.** Jeder Verbinden-/Trennen-/Erlauben-Klick legt `claude_desktop_config.json.bak-…` an; darin stehen die `env`-Tokens anderer MCP-Server. Nur die letzten 3 behalten. (app/ClaudeConnect.swift:114–119)
190. ✅ [Security] **MCP-Eintrag zeigt nach Umzug der App ins Leere.** `DEPLOYS_BIN` und `server.mjs` stehen als absolute Pfade ins App-Bundle in der Claude-Konfiguration; nach Verschieben der App (Downloads → Programme) ist Claude still ohne Werkzeuge, Settings sagt weiter „verbunden“. Pfade im Eintrag prüfen und „veraltet – neu verbinden“ zeigen. (app/ClaudeConnect.swift:288 und 308)


### Leistung und Energie

191. [Feature] **Statusseiten auch für die eingeschalteten Anbieter.** `checkProviders` fragt fest Vercel, Render und GitHub; mit GitLab-Quelle oder Netlify/Cloudflare fehlt deren Störung. Feed-URL aus `deploys providers --json`. (app/Store.swift:95–97)
192. [Perf] **Refresh mit `NSBackgroundActivityScheduler`.** Die 15-Minuten-Schleife weckt die App punktgenau; der Scheduler bündelt mit anderen Aufgaben, pausiert bei Last und spart Akku. (app/Store.swift:285–292)
193. ✅ [Perf] **Stromsparmodus und teures Netz beachten.** Bei `ProcessInfo.isLowPowerModeEnabled` oder `NWPath.isExpensive` (Hotspot) das Intervall verdoppeln und Kosten/Trigger auslassen. (app/Store.swift:296–299)
194. ✅ [Perf] **Kein Neuladen bei schlafendem Bildschirm.** Bei gesperrtem Bildschirm (`screensDidSleepNotification`) Runden aussetzen und beim Aufwachen des Bildschirms einmal laden; heute gibt es nur das Aufwachen des ganzen Systems. (app/Store.swift:279–284)
195. ✅ [Perf] **Status-Abfragen mit Backoff.** `follow` startet alle 6 s bash+node, auch bei einem 20-Minuten-Build; erste 2 Minuten alle 6 s, danach 15–30 s, ab `usualMinutes` wieder dichter. (app/Store.swift:925)
196. ✅ [Perf] **App Nap während laufender Deploys verhindern.** Im Hintergrund kann macOS `Task.sleep` stark strecken, dann kommt „ist live“ Minuten zu spät. `ProcessInfo.beginActivity(.userInitiated)` solange `deploysBusy`. (app/Store.swift:1047)
197. ✅ [Perf] **Ruhezustand während einer Deploy-Schlange verzögern.** Schläft der Mac mitten im Lauf, startet die Schlange nicht weiter und `follow` läuft in die Deadline. `.idleSystemSleepDisabled` mit Grund, solange `queue` nicht leer ist. (app/Store.swift:722)
198. ✅ [Perf] **`Tool.run` belegt drei blockierte GCD-Threads pro Aufruf.** Bei vielen Status-Abfragen und Ladevorgängen gleichzeitig droht die GCD-Thread-Grenze (64). `terminationHandler` plus `readabilityHandler` statt `read.wait()`/`waitUntilExit()`. (app/Tool.swift:164–233)
199. ◐ [Perf] **Log- und Journal-Schreiben auf dem Hauptthread.** `Log.write` öffnet, sucht, schreibt und `stat`et die Datei synchron, aufgerufen vom `@MainActor`-Store; `Journal.append` ebenso. Eigene serielle Queue. (app/Tool.swift:293–307, app/Journal.swift:42–59)
200. ✅ [Perf] **Savings-Berichte als JSON-Blob in UserDefaults.** `savingsSimulation`/`savingsLedger` (mit allen übersprungenen Pushes) landen in der Preferences-plist und werden beim ersten Zugriff auf dem Hauptthread dekodiert. Datei in Application Support, Dekodierung im Hintergrund. (app/Savings.swift:192–199 und 208)
201. ✅ [Perf] **`DateFormatter` pro Aufruf in `SavingsFormat.day`.** Die Bilanz ruft das für jeden übersprungenen Push. Statisch halten. (app/Savings.swift:270)
202. ✅ [Perf] **`Demo.scrub` baut bei jedem Aufruf einen Regex über alle Namen.** `makeSnapshot` ruft es pro Zeile, `tell` pro Toast. Regex zwischenspeichern, solange sich `items` nicht ändert. (app/DemoText.swift:9–34, app/Snapshot.swift:51)
203. ✅ [Perf] **Logo-Abruf lädt die ganze Startseite.** `get(base)` liest das komplette HTML (bei manchen Seiten MBs) nur für `<link rel=icon>`. Nach 64 KB abbrechen (`bytes(for:)`) oder nur `<head>` lesen. (app/Logos.swift:114)
204. ✅ [Perf] **Login-Shell bei jedem Öffnen von Settings → Claude und jedem Fenster.** `ClaudeEnv.find` startet für node und claude je eine Login-Shell, `ClaudeNudge.refresh` bei jedem `ContentView.task`. Den schon gecachten `Tool.searchPath` durchsuchen. (app/ClaudeConnect.swift:160–167 und 557–564)
205. ✅ [Perf] **iCloud-Schlüsselbund wird bei jedem Start beschrieben.** `pushIfOn` schreibt mit neuem `updated`-Datum, auch wenn sich kein Schlüssel geändert hat; das erzeugt Sync-Verkehr auf allen Geräten. Nur bei Änderung schreiben. (app/PhoneLinkMac.swift:21–37)
206. ✅ [Perf] **Doppelte Ladevorgänge nach dem Aufwachen.** Wake-Handler und Schleife können gleichzeitig `autoRefresh` starten; `guard loading.isEmpty` greift erst, nachdem `load` `loading` setzt (nach dem Doctor-`await`). Ein `refreshInFlight`-Flag. (app/Store.swift:279–290 und 424–426)


### Fehlerbehandlung und Rückmeldung

207. ◐ [UX] **Nach einem Ladefehler den Doctor neu fragen.** Läuft eine Anmeldung ab, die beim Start gültig war, kommt nur „HTTP 401“ in der Zeile; die Einrichtungsansicht erscheint nie, weil `autoRefresh` den Doctor nur bei fehlenden Feldern neu fragt. Bei 401/403 im Ladefehler sofort `doctor`. (app/Store.swift:428–432 und 352–356)
208. ✅ [UX] **`autofix sync`-Fehler werden verschluckt.** `try?` ohne Log; „Claude behebt es“ hängt dann wieder ohne Hinweis. Ins Log und in `extrasFailedAt`. (app/Store.swift:135)
209. ✅ [UX] **Gerade erst übergebene Ergebnisse aus `messages` überleben keinen Neustart.** Die Glocke ist nach einem Update oder Sprachwechsel leer; die letzten 30 Meldungen in Application Support sichern. (app/Store.swift:575–581)
210. ✅ [UX] **Antworten von Claude als Markdown darstellen.** `Text(answer.text)` zeigt `**`, `-` und `#` roh. `AttributedString(markdown:)` mit `.inlineOnlyPreservingWhitespace`. (app/ClaudeAI.swift:244)


### Persistenz und Neustart

211. [Feature] **Laufende Deploys nach Neustart weiter verfolgen.** Nach Update, Sprachwechsel oder Absturz sind `queue`, `deployId` und `unsureStarts` weg; die Zeile zeigt nur noch „building“ aus der Liste. `latestId`/`latestSha` (liefert das Skript seit 0.8, `VercelProject`/`RenderService` dekodieren es nicht) nutzen, um gebaute Zeilen beim Start wieder an `follow` zu hängen, und `unsureStarts` kurz sichern. (app/Model.swift:50–70, app/Store.swift:670)
212. [Feature] **Journal mit Commit, Deploy-ID und Auslöser.** Ein Eintrag sagt nicht, welcher Stand live ging; Felder `sha`, `deployId` und `trigger` (Klick, Menüleiste, Palette, Auto-Rollback, `whenGreen`). (app/Store.swift:535–537, app/Journal.swift:6–17)
213. [Feature] **Deploys aus dem Terminal im Verlauf zeigen.** Das App-Journal kennt nur App-Deploys, `JournalView` behandelt `forced`, das die App nie schreibt. `deploys history --json` einlesen und mit Quelle „CLI/App“ zusammenführen. (app/Journal.swift:130–134)


### Code-Struktur

214. [Code] **Andere Plattformen über `deploys list --json` laden statt über das `Platform`-Enum.** Netlify, Cloudflare, Coolify, DigitalOcean, Amplify und Hook kann man in Settings einschalten, ihr Tab sagt aber nur „kann diese Projekte noch nicht auflisten“, weil nur `Platform.vercel/.render` einen Lader hat. Ein generisches `Item` aus `list --json` mit `phase`, Fähigkeiten aus `ProviderCaps`. (app/Model.swift:11–15, app/Providers.swift:46, app/Store.swift:385–419)
215. ✅ [Code] **`decode()` mappt Vercel und Render fast identisch.** 30 Zeilen doppelt; ein gemeinsames Protokoll `ScriptProject` mit den gleichen Feldern und eine Abbildung. (app/Store.swift:385–419)
216. [Code] **Zwei Typen für `autofix status`.** `AutofixStatus` (Autofix.swift) und `AutofixReport` (Model.swift) lesen dasselbe Kommando unterschiedlich tolerant. Einer reicht. (app/Autofix.swift:8–26, app/Model.swift:296–347)
217. ✅ [Code] **Dreimal die Regel „fehlgeschlagen“.** `Item.lastFailed`, `ClaudeAI.isFailed` und `makeSnapshot` prüfen verschiedene Listen von Statuswörtern. Eine Eigenschaft am `Item`. (app/Model.swift:288–291, app/ClaudeAI.swift:70–73, app/Snapshot.swift:41–45)
218. ✅ [Code] **Gleicher Beenden-Dialog zweimal.** Menüleiste „Beenden“ und `relaunchApp` haben denselben NSAlert-Text kopiert. Eine Funktion `confirmQuit(running:)`. (app/App.swift:445–456, app/Tool.swift:49–59)
219. [Code] **Settings-Bereiche wiederholen `busy/message/failed/run()`.** Autofix, Guard, Team, ClaudeAI haben je eine eigene Kopie. Ein kleines `ScriptAction`-ObservableObject. (app/Autofix.swift:150–159, app/Guard.swift:79–89, app/Team.swift:115–125, app/ClaudeAI.swift:161–168)
220. ✅ [Code] **Tote Funktion `buildCost`.** Wird nirgends aufgerufen (und würde Render-Dienste mit Vercel-Kosten gleichen Namens versehen). Entfernen. (app/Store.swift:215–217)
221. ✅ [Code] **Unnötige Imports.** Model, Tool, Logos, Store importieren `Charts`, `UserNotifications`, `ServiceManagement`, ohne sie alle zu brauchen; das verlangsamt `swiftc` über alle Dateien. Pro Datei nur das Nötige. (app/Model.swift:3–7, app/Tool.swift:3–7, app/Logos.swift:3–7)
222. [Code] **Magische Statuswörter.** `"READY"`, `"live"`, `"canceled"`, `"build_failed"` stehen verstreut als Strings; ein Enum pro Plattform (oder das `phase` des Skripts) verhindert Tippfehler. (app/Store.swift:528 und 935–961)
223. ✅ [Code] **Claude-Konfiguration verliert die Schlüsselreihenfolge.** `JSONSerialization` schreibt die Datei des Nutzers in beliebiger Reihenfolge zurück; bei Hand-Pflege sieht jede Änderung wie ein Komplettumbau aus. Mindestens `.sortedKeys` für stabile Diffs. (app/ClaudeConnect.swift:35)
224. ◐ [Code] **Feste Plattformliste in Guard, Savings und Diagnose.** `[Platform.vercel, .render]` bzw. nur zwei Zähler in „Diagnose kopieren“; mit weiteren Anbietern fehlen sie. `enabledProviders` nutzen und Skriptversion (`deploys --version`) in die Diagnose. (app/Guard.swift:88 und 188, app/App.swift:259–264)


### Tests

225. [Test] **Tests in beiden Sprachen laufen lassen.** `isGerman` wird einmal beim Start festgelegt; `app-tests.sh` testet also nur die Sprache des Macs. Zweiter Lauf mit `-AppleLanguages '(de)'` bzw. `(en)`. (tests/app-tests.sh:13, app/Tool.swift:13)
226. ✅ [Test] **Test: `selectChanged` lässt Ausgeblendete und laufende Zeilen aus.** Fängt den Fehler oben und den Menüleisten-Pfad. (app/Store.swift:492)
227. ✅ [Test] **Test: `waiting` mit zwei Branches eines Repos.** Zwei Projekte, gleiches Repo, verschiedene `ref`. (app/Store.swift:447)
228. ✅ [Test] **Test: `loadProviders` behält die Liste bei Fehler.** Mit einem Fake-Skript, das beim zweiten Aufruf nichts liefert. (app/Providers.swift:229)
229. ✅ [Test] **Test: `Tool.run`-Timeout und Abbruch.** Ein Skript mit `sleep 30`: Timeout liefert `timedOut`, ein gecancelter Task liefert `CancellationError`, keiner hängt (killTree ist getestet, die Antwortpfade nicht). (app/Tool.swift:143–233)
230. ✅ [Test] **Test: `makeSnapshot`.** Reihenfolge building → failed → waiting, Demo-Maskierung, ausgeblendete fehlen, `sameContent` ignoriert nur `at`. (app/Snapshot.swift:37–65)
231. ✅ [Test] **Test: `AutoDeployAllowance` mit Millisekunden und ISO mit Bruchteilen.** Beide Pfade des Dekoders sind ungetestet. (app/Model.swift:403–418)
232. [Test] **Test: `cancel` während des CI-Wartens und `follow`-Deadline.** Mit einer Uhr, die man vorstellen kann (Idee „Clock injizierbar“ ist bekannt; hier die zwei konkreten Fälle). (app/Store.swift:761–784 und 918–970)
233. [Test] **Test: Maskierer gegen die Muster des Skripts.** Je ein Beispiel für Stripe, GitLab, npm, Google, Private-Key-Block; gleiche Fixtures für `tests/script-tests.sh`. (app/LogTools.swift:26)
234. ✅ [Test] **Tests schreiben nicht in die echte Application-Support-Ablage.** `Journal.dir` und `Store.cacheDir` sind fest `app.deploycenter.mac`; ein Test, der `Journal.append` oder `writeCache` erreicht, schreibt in die Daten des echten Nutzers. Ordner per Umgebungsvariable umlenkbar machen. (app/Journal.swift:22–26, app/Store.swift:242–245)
235. [Test] **`swiftc -strict-concurrency=complete` im Testlauf.** Zeigt die Datenrennen (statische Vars, `NSImage` über Actor-Grenzen, `NotifyRouter.onCancel`) als Warnungen, ohne den App-Build auf Swift 6 umzustellen. (tests/app-tests.sh:12)


### Features (Logik)

236. [Feature] **Eigene Grenze pro Plattform.** `maxParallel` gilt für alle zusammen; Vercel-Tarif erlaubt z. B. 1 gleichzeitigen Build, Render mehrere. Grenze je Anbieter in Settings → Deploy. (app/Store.swift:648 und 723)
237. [Feature] **Live-Check auch für Vorschauen.** Nach `ready` einer Vorschau wird nichts geprüft; dieselbe `checkSite`-Prüfung (ohne Rollback) auf die Vorschau-URL. (app/Store.swift:940–943)
238. [Feature] **Antworten von „Claude fragen“ zwischenspeichern.** Jedes Öffnen und jeder Sprachwechsel kostet neue Tokens; pro (Frage, Projekt, Kopf-SHA, Sprache) eine Antwort merken, „Neu fragen“ als Knopf. (app/ClaudeAI.swift:275–279)
239. [Feature] **iPhone nach Schlüsselwechsel sofort aktualisieren.** `saveRenderKey` und `ai set-key` stoßen kein `PhoneLinkModel.pushIfOn()` an; das iPhone hat bis zum nächsten Start den alten Key. (app/Store.swift:506–513)
240. [Feature] **Erlaubnis-Ende als Mitteilung.** `AutoDeployAllowance.expiresAt` ist bekannt; 10 Minuten vorher „Auto-Deploy für X endet um 14:30 – verlängern?“. (app/Store.swift:145–148)

## 3. CLI `deploys` und Provider (154)
Stand: origin/main aa128e9. Bereits bekannte Ideen (IDEEN 1–5, CHANGELOG) sind weggelassen.


### Provider-Vertrag (betrifft netlify, cloudflare, coolify, digitalocean, amplify)

241. ✅ [Bug] **`_has` gibt keine ID aus.** `netlify_has`, `cloudflare_has`, `coolify_has`, `digitalocean_has` und `amplify_has` leiten alles nach /dev/null um; `lookup` bekommt so bei `netlify:site` eine leere PID und ohne `names.json`-Treffer „No project named …“. Die ID ausgeben wie `vercel_has`/`render_has`. (providers/netlify.sh:169, cloudflare.sh:157, coolify.sh:168, digitalocean.sh:189, amplify.sh:165; deploys:244, deploys:257)
242. ✅ [Bug] **`_status`/`_latest` liefern JSON statt `id<TAB>phase<TAB>state`.** `watch` liest die erste Zeile („{“) als ID, die Phase bleibt leer, und die Schleife läuft endlos weiter; davon hängen auch `deploy --wait`, Gruppen-Deploys und `verify`. TSV ausgeben wie im Vertrag, das JSON nur in `_cli_status`. (providers/netlify.sh:294/301, cloudflare.sh:296, coolify.sh:287/295, digitalocean.sh:282/290, amplify.sh:293/301; deploys:1544)
243. ✅ [Bug] **`_deploy_json` mit Positionsargumenten statt `--sha/--preview`.** Netlify, Coolify und DigitalOcean lesen `$2` als „preview“; `deploys deploy x --sha abc` stirbt deshalb mit der Preview-Meldung, und bei Coolify ist `--sha` über `deploys` nie erreichbar. Flags parsen wie bei Vercel. (providers/netlify.sh:264, coolify.sh:250, digitalocean.sh:265)
244. ✅ [Bug] **`deploy-changed --when-green` scheitert bei jedem Provider ohne `sha`-Fähigkeit.** `deploy_one` gibt immer `--sha` mit; Cloudflare stirbt damit („cannot deploy a given commit“), Netlify und DigitalOcean ebenso. Vorher `caps.sha` prüfen und dann ohne SHA starten (mit einer Warnung, dass ein neuerer Push mitkommen kann) oder sauber überspringen. (deploys:633, deploys:1975; providers/cloudflare.sh:255)
245. [Test] **Vertragstests laufen für fünf Provider gar nicht.** `tests/fixtures/<p>/env` fehlt bei netlify, cloudflare, coolify, digitalocean und amplify; `contract.sh` überspringt sie, deshalb sind die drei Fehler oben unbemerkt. `env` anlegen und fehlende Fixtures im CI als Fehler werten statt als „skip“. (tests/providers/contract.sh:71)
246. ✅ [Bug] **`doctor` erzeugt doppelte JSON-Schlüssel.** Netlify, Coolify und DigitalOcean liefern alle `provider`, `key`, `tokenOk` und `error`; `doctor` klebt die Objekte zusammen, also gewinnt still der letzte Provider. Schlüssel mit Präfix versehen (`netlifyTokenOk`) wie bei Vercel und Render, oder je Provider ein verschachteltes Objekt. (deploys:1485–1495; providers/netlify.sh:380, coolify.sh:405, digitalocean.sh:396)
247. [Code] **`_meta`/`_doctor` brauchen jq, obwohl der Vertrag printf verlangt.** Netlify, Cloudflare, Amplify und Coolify bauen beides mit `jq -n`; ohne jq ist der Provider dann still „aus“, und `doctor` verliert genau dort seine Felder. (providers/netlify.sh:159/368, cloudflare.sh:147, amplify.sh:153; docs/PROVIDERS.md:48/61)
248. [Code] **Übrige Standalone-Teile in den neuen Providern.** Kommentare zu „A1 provider PR“ und „while the dispatcher does not route here yet“, eigene `die`/`mtime`/`CONFIG_DIR`/`USER`-Ersatzdefinitionen und `*_cmd`-Dispatcher sind jetzt toter Code; entfernen spart Abweichungen. (providers/cloudflare.sh:4–9/27–34, amplify.sh:4–9/26–33, netlify.sh:10/28–34)
249. [Code] **Fünf Kopien desselben HTTP-Clients.** `render_call`, `netlify_call`, `cf_call`, `coolify_call` und `digitalocean_call` wiederholen Retry, Timeout, `-K -` und Fehlerhinweise; eine `lib/http.sh` mit `http_call <label> <keyfn> …` macht Korrekturen (z. B. `Retry-After`) an einer Stelle möglich. (providers/render.sh:27, netlify.sh:61, cloudflare.sh:67, coolify.sh:66)
250. [Code] **`meta_flag`/`meta_str` lesen `_meta` mit grep.** `"defaultOn": true` mit Leerzeichen wird schon nicht mehr erkannt; der Test prüft nur „eine Zeile“. Den Test auf genau `"key":value` ohne Leerzeichen erweitern oder mit jq lesen, wenn es da ist. (deploys:206/224/230)


### Kern `deploys`: Bugs

251. ✅ [Bug] **`deploys deploy <p>` umgeht das Deploy-Fenster.** Der Befehl ruft `${plat}_deploy_json` direkt auf, ohne `freeze_check` und `journal_forced`; nur `<p> deploy` und `deploy-changed` prüfen `window.json`. Dasselbe gilt für Gruppen. (deploys:1374–1416, vgl. deploys:1358)
252. [Security] **Observer-Modus durch die Reihenfolge der Flags umgehbar.** `require_write` greift bei `deploy-changed` nur, wenn `--yes` das erste Argument ist; `deploy-changed --when-green --yes` startet Deploys bei allen Providern ohne `team_gate`, also überall außer Vercel/Render bzw. überall ohne lib/team.sh. `--yes` an beliebiger Stelle prüfen. (deploys:1306, deploys:1918)
253. [Security] **`autodeploy allow` und `revoke` sind im Observer-Modus erlaubt.** Beide schalten Auto-Deploy über `ad_on`/`guard_run` an oder aus und stehen nicht in der `require_write`-Liste. (deploys:1302–1311, deploys:1994–1998)
254. [Security] **`safe_arg` fehlt bei `deploy`, `verify`, `risk`, `ai` und `autofix --only`.** Ein Name mit `?teamId=…` geht so ungeprüft über `lookup` → `vercel_has` in einen API-Pfad; SECURITY.md verspricht, dass solche Namen vor jedem Aufruf abgelehnt werden. (deploys:1327–1339)
255. ✅ [Bug] **Das gemeinsame `window` und `health` aus deploy-center.json wirken in der CLI nicht.** `freeze_check` liest nur das lokale `window.json` (eine Deny-Liste); das Team-Format ist ein Erlaubt-Fenster mit `tz`, und `verify` liest `health` nicht. TEAM.md sagt aber, die Safe-Deploy-Prüfungen nutzen beides. (deploys:555–574, deploys:1828; lib/team.sh:110; docs/TEAM.md:50)
256. ✅ [Bug] **Projekte ohne Git-Repo zählen immer als „state unknown“.** Render-Dienste aus einem Image (Repo null, aber `deployable`) und Bitbucket-Repos (`githost_of` → unknown) bekommen nie einen Head; `UNKNOWN_RULE` meldet sie bei jedem Lauf, und `changed`/`deploy-changed` enden immer mit Exit 1, was einen Cron dauerhaft rot macht. Ohne Repo `deployable` mit dem Grund „kein Repo“ führen und nicht als unbekannt zählen. (deploys:463, providers/render.sh:171, lib/githost.sh:48)
257. ✅ [Bug] **`verify`, `risk` und `ai` brechen bei `p:name`.** `risk` filtert mit `.name == "vercel:web"` und findet nichts; `verify` gibt den Namen mit Präfix an `"$0" "$plat" rollback` und `site_url_of`. Wie `explain` erst `resolve` aufrufen und `PNAME`/`PID` nutzen. (deploys:1840/1843/1882, deploys:1893–1894, deploys:1211)
258. ✅ [Bug] **Exit 1 von `verify` bedeutet zweierlei.** Laut Doku heißt 1 „fehlgeschlagen und zurückgerollt“, aber jedes `die` (nicht live, keine Adresse, Lookup-Fehler) endet ebenfalls mit 1, und ein Skript rollt dann gedanklich falsch. Fehler mit 2 oder einem eigenen Code beenden. (deploys:1827/1842/1844)
259. ✅ [Bug] **`deploy --wait` verschluckt Exit 3 von `watch`.** „Plattform nicht erreichbar“ wird zu `die` mit 1 und der Meldung „did not go live“. Den Code von `watch` durchreichen. (deploys:1413–1414)
260. ✅ [Bug] **`ci_of` sieht höchstens 100 Check-Runs.** Bei Monorepo-Matrix-Builds kann ein roter Check auf Seite 2 liegen; `--when-green` deployt dann „grün“. `--paginate` nutzen oder `total_count` gegen die Länge prüfen und sonst „pending“ melden. (deploys:513)
261. ✅ [Bug] **`--when-green` wartet bei GitLab-Repos sinnlos 30 Minuten.** `ci_of` fragt `gh api repos/gitlab.com/…`, beide Aufrufe scheitern, „unknown“ zählt als pending bis zum Timeout. GitLab-Pipelines über `/projects/:id/repository/commits/:sha/statuses` lesen oder sofort mit „CI für GitLab unbekannt“ überspringen. (deploys:510–521, deploys:1973)
262. ✅ [Bug] **`risk` und `pending.risk` fehlen für GitLab.** `gitlab_pending_of` berechnet kein `risk`, und `deploys risk` stirbt mit „GitHub could not compare“. `RISK_DEF` auf die `diffs` von GitLab anwenden. (lib/githost.sh:156; deploys:1901)
263. ✅ [Bug] **Vercel-Projekte aus GitLab oder Bitbucket haben kein `lastSha`.** `vercel_json`, `rollback`, `history` und savings lesen nur `meta.githubCommitSha`; bei GitLab heißt das Feld `gitlabCommitSha`, und die Änderungserkennung fällt auf den Zeitvergleich zurück. Alle drei Felder lesen. (providers/vercel.sh:181/195/234/289; lib/savings.sh:60)
264. ✅ [Bug] **`vercel_off_one` trennt Bitbucket-Projekte, ohne das Repo zu merken.** Für `type:"bitbucket"` sind `org`/`repo` null, `remember_repo` verwirft den Eintrag, und der Link wird trotzdem gelöscht; das Projekt ist danach weder deploybar noch wieder verbindbar. Erst prüfen, ob die Zuordnung gespeichert wurde, sonst abbrechen. (providers/vercel.sh:82–87)
265. ✅ [Bug] **`vercel autodeploy-on` geht bei GitLab-Zuordnungen nicht.** `vercel_on_one` verlangt `.org` und sendet immer `type:"github"`; bei einem mit `vercel map gitlab.com/…` angelegten Eintrag kommt die irreführende Meldung „repo is not known“. (providers/vercel.sh:110–113)
266. ✅ [Bug] **`vercel deploy --wait` hängt bei Dauerfehlern.** Die Schleife druckt bei jedem Fehler „?“ und versucht es ewig, ohne den Fünf-Fehlversuche-Ausstieg von `watch`. `watch` wiederverwenden. (providers/vercel.sh:326–331)
267. ✅ [Bug] **Unbekannte Optionen von `deploy-json` werden still ignoriert.** `vercel_deploy_json` und `render_deploy_json` übergehen z. B. `--sah abc` und deployen den neuesten Commit statt des gewünschten. Unbekannte Flags mit `die` ablehnen. (providers/vercel.sh:172, providers/render.sh:190)
268. ✅ [Bug] **`render_last_of` hat kein curl-Timeout.** Anders als `render_call` fehlen `--connect-timeout` und `--max-time`; eine hängende Verbindung blockiert `render json` und damit `changed` und die App ohne Ende. (providers/render.sh:148–149)
269. ✅ [Bug] **Unlesbarer Schlüsselbund sieht aus wie „nicht eingerichtet“.** Unter launchd oder SSH ist der Schlüsselbund oft gesperrt, `render_ready` scheitert, und `active_providers` lässt Render still weg; `changed` meldet dann „Nothing to deploy“ mit Exit 0. Den Exit-Code von `security` (Item fehlt vs. gesperrt/verweigert) unterscheiden und eine Sperre als Fehler melden. (deploys:219–222, providers/render.sh:24)
270. ✅ [Bug] **Ohne aktiven Provider meldet `changed` „alles aktuell“.** Ist kein Provider eingeschaltet und bereit, liefert `all_json` `[]` mit rc 0, und `changed` sagt „every project is on its newest commit“. In diesem Fall mit Hinweis auf `deploys providers` abbrechen. (deploys:445–459, deploys:1785–1787)
271. ✅ [Bug] **`guard schedule`/`status` zeigen „an“, auch wenn launchd den Job verloren hat.** `guard_scheduled` prüft nur die plist-Datei; bei autofix ist genau das mit `launchctl print` schon behoben (CHANGELOG Unreleased). Gleich lösen, mit `guard_reload`. (deploys:1030 vs. deploys:796–801)
272. ✅ [Bug] **`ignore` gilt plattformübergreifend.** `ignored.json` speichert nur den Namen, also verschwinden `vercel:api` und `render:api` beide. `p:name`-Einträge erlauben und beim Filtern auswerten. (deploys:475, deploys:1574–1585)
273. ✅ [Bug] **Mehrdeutigkeit auf derselben Plattform führt im Kreis.** Stehen zwei IDs desselben Providers in `names.json`, schlägt `lookup` `render:name` vor, das wieder mehrdeutig ist. Dann die IDs nennen („nutze srv-…“). (deploys:252)
274. [Bug] **Veraltetes `names.json` führt auf gelöschte IDs.** Ein gelöschtes und gleichnamig neu angelegtes Projekt (neue `srv-`-ID) wird aus dem Cache mit der alten ID aufgelöst und endet in 404. Bei 404 den Cache-Eintrag verwerfen und den Provider neu fragen. (deploys:248–255)
275. ✅ [Bug] **Der Namens-Cache wird nie kleiner.** `remember_names` behält alte Namen für immer (Kommentar „Old names stay“); gelöschte Projekte bleiben in der Vervollständigung, und `ignore` nimmt sie als gültig an. Beim vollständigen Lesen eines Providers dessen Namen ersetzen. (deploys:418–426)
276. ✅ [Bug] **GNU-`xargs` startet bei leerer Eingabe einmal.** Unter Linux läuft `githost_head_of`/`open_prs_of`/`team_fetch_one` ohne Projekte einmal mit leeren Argumenten (`gh api repos//pulls`). `xargs -r` nutzen, wo verfügbar, oder vorher auf leere Eingabe prüfen. (deploys:388/396/397/1721/1771; lib/team.sh:75) (Vermutung zum Effekt bei gitlab)
277. ✅ [Bug] **`column` fehlt, und die Tabellen sterben.** Die README nennt `column` optional, aber jede Tabelle pipt hart in `column -t`; unter pipefail endet z. B. `changed` mit 127 und ohne Ausgabe. Einen Rückfall (`cat` oder ein awk-Padding) einbauen, wenn `column` fehlt. (deploys:1434/1519/1790/2003; README-CLI.md:63)
278. ✅ [Bug] **`journal_add` schreibt neue Provider klein.** Nur `vercel`/`render` werden zu „Vercel“/„Render“; „netlify“ landet roh im Journal, und die App zeigt zwei Schreibweisen. `meta_str "$1" label` nutzen. (deploys:589)
279. ✅ [Bug] **`ai set-key` prüft den Schlüssel kaum.** Anders als `autofix set-token` werden Leerzeichen, Anführungszeichen und `\r` nicht abgelehnt; ein aus Windows kopierter Schlüssel mit CR landet so im Schlüsselbund und gibt dann 401, und Leerzeichen zerlegen die `security -i`-Zeile. Trimmen und dieselbe Prüfung wie bei autofix. (deploys:2035–2038; ähnlich render.sh:251, netlify.sh:359)
280. ✅ [Bug] **`job_on` maskiert Pfade nicht für XML.** `$self` und `$log` kommen roh in die plist; ein `&` oder `<` im Pfad (z. B. ein Ordner „R&D“) bricht `launchctl bootstrap`. Wie PATH escapen. (deploys:770–782)
281. ✅ [Bug] **`vercel logs <p> 0` gibt das ganze Log aus.** `.[-0:]` ist in jq das ganze Array. `n` ab 1 verlangen. (providers/vercel.sh:251, deploys:1560)
282. ✅ [Bug] **`history n` ohne Obergrenze.** Vercel und Render erlauben höchstens 100 pro Seite; `history web 500` endet in einem API-Fehler. Begrenzen oder Seiten holen. (deploys:1474–1478; providers/vercel.sh:287, render.sh:279)
283. [Bug] **Render-Logs mit mehr als 100 Zeilen.** autofix fordert 200, `ai explain` 300 Zeilen an; die Logs-API von Render begrenzt `limit` vermutlich auf 100, dann kommt ein Fehler oder ein abgeschnittenes Log. Über `nextStartTime` paginieren. (Vermutung) (providers/render.sh:237; deploys:699/1213)
284. ✅ [Bug] **Bei `changed --platform` wird der Wert nicht geprüft.** `--platform vercle` liefert eine leere Liste und „Nothing to deploy“. Gegen `PROVIDERS` prüfen. (deploys:1781–1783)
285. ✅ [Bug] **`verify` zählt 404 auf einem expliziten `--path` als gesund.** Nur 000 und 5xx gelten als Fehler, und Weiterleitungen werden nicht verfolgt; ein fehlender `/health`-Endpunkt besteht so den Check. Bei gesetztem `--path` 404 als Fehler werten und `-L` nutzen (die Domain bleibt dabei im Log). (deploys:1849–1852)
286. ✅ [Bug] **`netlify deploy` gibt `id:null` an `watch` weiter.** Taucht der Build nicht in 30 s auf, liefert `netlify_deploy_json` `id:null`; `deploy --wait` ruft dann `watch p null` auf und endet nach fünf Fehlversuchen mit „unreachable“. Ohne ID auf `latest` zurückfallen. (providers/netlify.sh:290; deploys:1413)
287. ✅ [Bug] **Unterbrochenes SHA-Pinning bei Coolify.** Zwischen dem PATCH von `git_commit_sha` und dem Zurücksetzen fehlt ein `trap`; Ctrl-C oder ein Absturz lässt die App für immer auf den Commit gepinnt, auch für spätere Auto-Deploys. Ein `trap` stellt den Wert zurück. (providers/coolify.sh:263–270)
288. ✅ [Bug] **savings behandelt jeden Nicht-Vercel-Provider als Render.** `sv_builds` ruft im `else` `render_call /services/<netlify-id>/deploys` auf, und `offAt` kommt für alle aus render-off.json; Netlify, Cloudflare und Co. sind in simulate/ledger so falsch oder leer. Je Provider ein optionales `<p>_builds` oder ausdrücklich „nicht unterstützt“. (lib/savings.sh:56–68, lib/savings.sh:28)
289. ✅ [Bug] **Der Fehlertext bei unbekanntem Zustand passt oft nicht.** „branch head unknown (is gh installed and logged in?)“ erscheint auch bei GitHub-Rate-Limit, Bitbucket, Image-Diensten und fehlendem Repo-Zugriff. Den Grund aus `head_of` (403 secondary limit, 404, kein Host) durchreichen. (deploys:476, deploys:286–291)
290. ✅ [Bug] **`team_approvals` deutet einen GitHub-Fehler als „keine Freigaben“.** Fällt `gh api` aus, heißt die Meldung „Found none. Your own reviews do not count“, statt zu sagen, dass GitHub nicht lesbar war. (lib/team.sh:201–212, 263–270)
291. ✅ [Bug] **Projekt- und Gruppenname kollidieren.** Heißt eine Gruppe wie ein Projekt, gewinnt in `deploys deploy` immer die Gruppe; das einzelne Projekt ist nicht mehr allein deploybar. Ein Präfix `group:` oder eine Warnung. (deploys:1393–1397; lib/team.sh:185)
292. ✅ [Bug] **GitLab mit Port wird falsch angesprochen.** `githost_split` schneidet `:8443` vom Host ab, also gehen die Aufrufe an `https://host/api/v4` auf Port 443. Den Port behalten. (lib/githost.sh:31)
293. ✅ [Bug] **`open` reicht ein drittes Argument ungeprüft weiter.** `deploys open web foo` übergibt „foo“ an `<p>_url`; nur `--dashboard` erlauben. (deploys:1567)
294. [Bug] **`vercel_json.recent` sieht nur die 100 neuesten Production-Deploys.** Bei vielen Projekten fehlen bei älteren `latestState`/`latestId`, und autofix übersieht deren Fehlschläge. Fehlende Projekte einzeln nachfragen oder seitenweise holen. (providers/vercel.sh:180–181)
295. ✅ [Bug] **`open_prs_of` zählt höchstens 100 offene PRs.** Danach ist die Zahl eine Untergrenze ohne Kennzeichnung (wie es bei `partial` gelöst ist). `total_count` aus der Search-API nehmen oder `partial` setzen. (deploys:337; lib/githost.sh:177)


### Kern: Fehlerbehandlung, Timeouts, Rate-Limits

296. [UX] **`vercel_call` ohne Retry.** Render, Netlify, Cloudflare und Coolify wiederholen GETs bei 429/5xx; `vercel api` wird nur einmal versucht, und ein 429 bricht `vercel json` ganz ab. Dieselbe Schleife für GETs ergänzen. (providers/vercel.sh:50–55)
297. [UX] **gh, glab und die vercel-CLI ohne Zeitlimit.** Ein hängendes `gh api` (Proxy, VPN) blockiert `changed` und die App ohne Ende. Einen portablen Timeout-Wrapper (`timeout`/`gtimeout`, sonst Hintergrundprozess mit kill) um alle CLI-Aufrufe legen. (deploys:288/301/337; lib/githost.sh:90; providers/vercel.sh:52)
298. [UX] **`vercel_team` hält jeden Fehler für „nicht eingeloggt“.** Netzfehler und 5xx heißen „Run: vercel login“. Die stderr-Zeile wie bei `vercel_call` zeigen. (providers/vercel.sh:33)
299. [UX] **Ein GitHub-Rate-Limit klar benennen.** `with_heads` spart Budget unter 300, sagt das aber nicht; `changed` sollte „GitHub-Limit erreicht, Reset um 14:05“ ausgeben (aus `github_budget.reset`). (deploys:391–393)
300. [UX] **Anthropic 429/529 ohne Wiederholung.** `ai_ask` stirbt sofort; ein bis zwei Wiederholungen mit `retry-after` ersparen dem Nutzer den zweiten Klick. (deploys:1183–1184)
301. [UX] **`costs` ohne Vercel.** Ist Vercel aus oder nicht eingeloggt, endet `costs` mit „vercel CLI is not logged in“. Vorher `provider_on vercel` prüfen und „costs gibt es nur für Vercel“ sagen. (deploys:1718)


### Kern: Exit-Codes und JSON-Ausgabe

302. [UX] **`deploy --json` für Gruppen gibt NDJSON aus.** Alle anderen Befehle liefern ein Array oder ein Objekt; bei Gruppen kommt eine Zeile je Mitglied. Ein Array (oder ausdrücklich dokumentiertes NDJSON) ausgeben. (deploys:1408)
303. [UX] **Fehler mit `--json` als JSON.** Heute kommt dann Klartext auf stderr und nichts auf stdout; `{"error":{"code":"auth","message":…}}` würde App, MCP und Skripte vereinfachen. (deploys:104)
304. [Feature] **`--json` für `history`, `watch`, `costs`-Tabelle, `logs`.** `history` ist nur eine Tabelle, `watch` nur Text; `watch --json` als NDJSON-Strom (eine Zeile je Statuswechsel) eignet sich für Editor-Integrationen. (providers/vercel.sh:286, render.sh:278; deploys:1524)
305. [UX] **`costs`, `triggers`, `details` und `github-budget` drucken immer JSON.** Für Menschen fehlt eine Tabelle; mit `--json` das JSON, sonst eine kurze Übersicht wie bei `changed`. (deploys:1713–1775)
306. [Feature] **JSON-Schemas für `changed`, `status`, `list` und `deploy`.** docs/deploy-center.schema.json gibt es nur für die Team-Datei; ein `schemaVersion` im JSON und Schemas in docs/ schützen App, VS-Code-Erweiterung und MCP vor stillen Feldänderungen.
307. [UX] **`window` endet bei kaputter Datei mit 1, wie „geschlossen“.** `die` und „geschlossen“ teilen sich Exit 1. Für Lesefehler einen anderen Code. (deploys:1813–1820)
308. [UX] **Die Exit-Codes sind unvollständig dokumentiert.** docs/CLI.md und der Hilfekopf nennen nur 0/1/3; `ci` (2), `verify` (1/2), `autofix --only` (2–6) und `window` (1) fehlen. Eine Tabelle je Befehl. (docs/CLI.md:72–76; deploys:76–78)


### Kern: Hilfe, UX, Vervollständigung

309. [UX] **Unbekannter Befehl ohne Hinweis.** Bei einem Tippfehler (`deploys chaged`) kommt die ganze Hilfe mit Exit 1, aber keine Zeile „Unknown command chaged; did you mean changed?“. (deploys:2184, deploys:1355)
310. [UX] **Doppelte und ungeordnete Hilfe.** `vercel deploy` steht zweimal (Zeile 34 und 38), `deploy` auch (17 und 60), `render list`/`render deploy` stehen hinter `--help`. Nach Themen gruppieren (Alltag, Plattformen, Sicherheit, Team, Claude). (deploys:12–74)
311. [Feature] **`deploys help <befehl>` und `<befehl> --help`.** `deploys deploy --help` endet heute mit „Unknown option --help“. Pro Befehl die Usage-Zeile aus `usage_if_short` wiederverwenden. (deploys:1386)
312. [UX] **Die Hilfe kennt die neuen Provider nicht.** Eigene Verben wie `cloudflare selftest/account`, `coolify set-url`, `netlify autodeploy-off --rule-added` und `amplify on` stehen nirgends; aus `declare -F <p>_cli_*` die Hilfe der eingeschalteten Provider erzeugen.
313. [UX] **`watch` ohne Gesamt-Timeout, Dauer und Adresse.** Ein Deploy, der ewig „queued“ ist, lässt `watch` endlos laufen; `--timeout 30m`, eine Laufzeitanzeige und am Ende die URL. (deploys:1535–1554)
314. [UX] **`deploy` ohne `--wait` sagt nicht, wie man folgt.** Nach „started“ die Zeile `deploys watch <p> <id>` ausgeben. (deploys:1409)
315. [UX] **`providers enable` ohne nächsten Schritt.** Nach dem Einschalten `<p>_ready` prüfen und „Jetzt: pbpaste | deploys netlify set-key“ ausgeben. (deploys:2145–2152)
316. [UX] **`vercel team <id>` und `vercel map` prüfen nichts.** Ein Tippfehler bei der Team-ID oder dem Projektnamen wird gespeichert; mit `/v2/teams/<id>` bzw. `/v9/projects/<p>` prüfen (und offline mit `--no-check` speichern). (providers/vercel.sh:342–366)
317. [UX] **`render status` verlangt die srv-ID.** Andere Befehle nehmen den Namen; `render_cli_status` sollte `render_id_of` nutzen. (providers/render.sh:300)
318. [UX] **Amplify-IDs mit `/` werden von `safe_arg` abgelehnt.** Die Doku sagt „commands take the id“ (`<appId>/<branch>`), aber `deploys amplify deploy app/main` scheitert an „no /“. Für amplify `/` genau einmal erlauben. (providers/amplify.sh:21; deploys:1323)
319. [Feature] **Vervollständigung für Flags und `p:name`.** `--preview`, `--sha`, `--wait`, `--json`, `--platform <p>` und Namen mit Plattformpräfix (aus names.json) fehlen; außerdem fish. (deploys:1629–1670)
320. [UX] **`deploy-changed` beachtet die Reihenfolge Backend vor Frontend nicht.** Die App startet das Backend eines Repos zuerst; die CLI startet in Namensreihenfolge. Dieselbe Regel (oder Team-`groups`) anwenden. (deploys:1962–1964)


### Kern: Performance

321. [Perf] **`team_effective` läuft mehrmals pro Befehl.** `repos_json`, `team_ignored`, `team_observer_from`, `team_group` und `team_gate` rechnen jeweils `team_sources` plus die große jq-Zusammenführung neu. Das Ergebnis pro Prozess in einer Variablen merken. (lib/team.sh:148–185)
322. [Perf] **`is_enabled` startet jq bei jedem Aufruf.** In `lookup` passiert das je Treffer, in `completion` je Provider; `enabled_providers` einmal pro Prozess cachen. (deploys:207–216)
323. [Perf] **Netlify, DigitalOcean und Coolify lesen die Deploys je Site nacheinander.** Bei 30 Sites sind das 30 serielle Aufrufe plus O(n²) `jq '. + [$s]'`. Parallel wie `render_last_of` (xargs -P) und am Ende einmal `jq -s`. (providers/netlify.sh:186–194, digitalocean.sh:195–203, coolify.sh:170)
324. [Perf] **`*_id_of` liest bei jedem Aufruf die ganze Liste.** `netlify_latest`, `coolify_latest` und `digitalocean_status` lösen den Namen jedes Mal über alle Sites auf, auch wenn schon eine ID kommt; `watch` macht das alle 6 s. Eine ID direkt durchlassen (Muster erkennen wie `srv-`). (providers/netlify.sh:110/303, coolify.sh:119, digitalocean.sh:285)
325. [Perf] **Amplify löst Projekte bei jedem Aufruf auf.** `amp_resolve` ruft `list-apps` und `list-branches` auf (je ein Start der Python-CLI, etwa 1 s); `watch` zahlt das alle 6 s. Die Auflösung in names.json bzw. im Prozess merken. (providers/amplify.sh:136–160)
326. [Perf] **`vercel_rollback` liest das Projekt zweimal.** `/v9/projects/$p` für `targets.production.id` und dann für `.id`; ein Aufruf reicht. (providers/vercel.sh:231/240)
327. [Perf] **`vercel_doctor` startet die vercel-CLI dreimal.** `command -v`, `vercel api --help` und `vercel whoami` sind jeweils ein Node-Start; `whoami` allein beantwortet beides. (providers/vercel.sh:271–276)
328. [Perf] **`all_json` startet sich selbst je Provider neu.** `"$0" "$p" json` lädt alle Provider und lib/team.sh erneut und bricht bei `bash ./deploys` ohne x-Bit; eine Subshell mit `provider_json` reicht. (deploys:448)
329. [Perf] **Autofix fragt jq je Feld einzeln.** In `af_sync_fires`/`autofix_run` laufen pro Eintrag 5–8 Aufrufe `echo | jq -r`; einmal `jq -r '[…] | @tsv'` und `read` sind deutlich schneller. (deploys:823–827, 883–885)
330. [Perf] **`render_logs` liest den Dienst für `ownerId` bei jedem Aufruf.** Die Owner-ID ändert sich nie und lässt sich in render-off.json oder names.json merken. (providers/render.sh:234)


### Kern: Sicherheit

331. [Security] **Observer-Erkennung ist „fail open“.** Ist `gh` nicht eingeloggt (oder ein anderes GH_TOKEN gesetzt), ist `me` leer und die Observer-Liste greift nie; mit nicht leerer `observers`-Liste und unbekanntem Nutzer sollte das als Observer gelten (oder eine deutliche Warnung). (lib/team.sh:132, lib/team.sh:87–95)
332. [Security] **Freigaben auf veralteten Reviews.** `team_approvals` zählt ein APPROVED-Review, auch wenn danach neue Commits in den PR kamen (ohne „dismiss stale reviews“). `review.commit_id` gegen den letzten Head des PRs vor dem Merge prüfen. (lib/team.sh:205–208)
333. [Security] **Der Coolify-Token geht auch über http://.** `coolify_base` nimmt `http://`, und der Bearer-Token geht dann im Klartext; wie bei hook nur localhost erlauben oder ausdrücklich bestätigen lassen. (providers/coolify.sh:43–52)
334. [Security] **`hook_check_url` erlaubt `http://localhost.example.com`.** Der Präfixtest `http://localhost*` lässt jede Domain durch, die mit „localhost“ beginnt; den Host genau vergleichen. (providers/hook.sh:72)
335. [Security] **Der Netlify-Token geht mit an die Build-Hook-URL.** `netlify_call POST <hook-url>` setzt den Bearer-Header, obwohl der Hook keinen braucht; stammt die URL aus einer manipulierten netlify-hooks.json, geht der Token mit. Ohne Authorization posten und den Host api.netlify.com prüfen. (providers/netlify.sh:279)
336. [Security] **`open` öffnet jede URL, die eine API liefert.** Ein `file://`- oder Custom-Scheme-Wert aus einem Platform-Feld würde mit `open` gestartet; nur `https://` zulassen. (deploys:1570)


### Kern: Code-Qualität

337. [Code] **`deploys_dir` ist zweimal definiert, dazu `script_dir` und `readlink -f`.** Drei Wege, den eigenen Ordner zu finden (deploys:128, :346, :156, :2177); `readlink -f` fehlt auf macOS vor 12.3, und dann findet `simulate` lib/savings.sh über einen Symlink nicht. Eine Funktion, einmal berechnet.
338. [Code] **Toter `--force`-Zweig in `deploy`.** `--force` wird schon oben global entfernt; die Schleife in `deploy` erreicht ihn nie. (deploys:1385)
339. [Code] **`act()` und `stop_group()` sind Funktionen in Funktionen.** Sie werden global definiert und überschreiben sich bei weiteren Aufrufen; als normale Hilfsfunktionen anlegen. (deploys:992, deploys:1400)
340. [Code] **Das Skript hat 2184 Zeilen.** Autofix, ai, guard/allow und Savings in `lib/autofix.sh`, `lib/ai.sh`, `lib/guard.sh` auslagern (wie team/githost), damit Reviews und shellcheck-Ausnahmen kleiner werden.
341. [Code] **Drei Regeln für „fehlgeschlagener Check“.** `CI_RULE` (deploys:497), `details.checks` (deploys:1686, ohne `action_required`/`startup_failure`) und die PR-`statusCheckRollup`-Auswertung (deploys:1691) urteilen verschieden; einmal als jq-def ablegen.
342. [Code] **Zwei Listen für riskante Dateien.** `RISK_DEF` (deploys:603–606) und `details.risky`/`gitlab_details.risky` (deploys:1707, lib/githost.sh:218) weichen ab (z. B. `bun.lockb`, `uv.lock`, `.gitlab-ci.yml`); eine gemeinsame Regex.
343. [Code] **Die `--json`/`--force`-Erkennung schluckt auch Werte.** `deploys hook add x - --body --json` verliert `--json` als Wert; das globale Parsen nach `--` beenden und Werte von Optionen auslassen. (deploys:180–188)


### Guard, Autofix, Trigger: Abdeckung neuer Provider

344. ✅ [Bug] **`guard` und `autodeploy allow` kennen nur Vercel und Render.** Netlify, Cloudflare, Coolify, DigitalOcean und Amplify haben alle ein `_off`, aber der Wächter prüft sie nie; wer dort im Dashboard Auto-Deploy wieder einschaltet, wird nicht bemerkt. Für jeden Provider mit `caps.off` ein `_auto`-Feld aus `_json` nutzen und `_off` aufrufen. (deploys:974–984, deploys:1059)
345. [Feature] **Autofix für alle Provider.** `AUTOFIX_FAILED` und `--only` sind auf vercel|render beschränkt; mit `phase == "failed"` und `caps.logs` ginge es allgemein. (deploys:680–682, deploys:2129)
346. ✅ [Bug] **`triggers` übersieht Workflows der neuen Provider.** Die Regex kennt `netlify deploy`, `wrangler pages deploy`, `doctl apps create-deployment`, `aws amplify start-job` und Coolify-Webhooks nicht, und nur Repos aus Vercel/Render werden geprüft. (deploys:659, deploys:1769–1770)
347. [Feature] **`triggers` für GitLab.** Eine `.gitlab-ci.yml` mit Deploy-Jobs hebt das Abschalten genauso auf; dieselbe Suche über die GitLab-API. (deploys:654–662)
348. [Feature] **Savings für GitLab-Repos.** `sv_pushes` liest nur GitHub-Activity; GitLab hat `/projects/:id/events?action=pushed`. Und das harte `gh`-Pflicht-`die` nur, wenn GitHub-Repos dabei sind. (lib/savings.sh:34–53, 226)


### Vercel

349. [Feature] **Vercel Custom Environments (z. B. staging).** `vercel_start` kennt nur production und preview; `customEnvironmentSlugOrId` in `/v13/deployments` erlauben, `--env staging`. (providers/vercel.sh:156–160)
350. [Feature] **`dashboardUrl` in `vercel_json` füllen.** Es ist immer null; aus Team-Slug und Projektname einmal pro Lauf berechnen, wie es `vercel_url --dashboard` schon tut. (providers/vercel.sh:192)
351. [Feature] **Vercel-Rollback mit Ziel.** `deploys vercel rollback <p> --to <id|sha>` statt immer „der vorige“. (providers/vercel.sh:227–243)


### Render

352. [Feature] **Render-Preview-Environments und Pull-Request-Previews.** `caps.preview` ist false; Render hat Preview-Instanzen per PR, die man listen und abschalten könnte (sie kosten ebenfalls).
353. [Feature] **Render-Cron-Jobs und Hintergrund-Worker kennzeichnen.** `type` steht schon im JSON; `changed` könnte z. B. „cron_job: deploy wirkt erst beim nächsten Lauf“ sagen. (providers/render.sh:170)


### Netlify

354. [Feature] **Prüfung der ignore-Regel auch für GitLab.** `netlify_rule_in_repo` liest nur über `gh`; GitLab-Repos brauchen immer `--rule-added`. Über `gitlab_api …/repository/files` lesen. (providers/netlify.sh:140–153)
355. [UX] **Die Regel wird nur auf dem Hauptbranch geprüft.** Ein `[context.production]`, das `ignore` überschreibt, oder ein falscher `base` wird nicht erkannt; die Doku-Zeile sollte das nennen.
356. [Feature] **Netlify-Deploy-Previews ehrlich zählen.** Die ignore-Regel überspringt Previews ebenfalls; ein Hinweis bei `autodeploy-off`, wie man Previews für bestimmte Branches zulässt.


### Cloudflare, Coolify, DigitalOcean, Amplify, Hook

357. [UX] **`cloudflare_deploy_json` meldet `state:` die Phase.** Der Vertrag will dort den rohen Zustand (`latest_stage.status`); die App zeigt sonst „building“ statt „initialize/build“. (providers/cloudflare.sh:293)
358. [Feature] **Mehrere Coolify-Instanzen.** Heute geht nur eine pro Setup (`coolify.json url`); viele betreiben getrennte Server für Staging und Produktion. Eine Liste `instances[]` mit Namenspräfix. (providers/coolify.sh:14)
359. [Feature] **Hook mit Status-URL.** `hook add … --status-url <url> --status-jq '.state'` würde aus „triggered“ einen echten Status machen (viele CI-Dispatches liefern eine Run-ID).
360. [UX] **Ein Hook bleibt nach 2xx für immer „ready“.** Für `changed` heißt das, er gilt als live, auch wenn der Build danach scheitert. Phase `queued` mit Hinweis „Status unbekannt“ wäre ehrlicher (der Vermerk steht nur in `meta.note`). (providers/hook.sh:223–229)


### Neue Provider (je ein Modul nach PROVIDERS.md)

361. [Feature] **Heroku.** Die GitHub-Integration („Automatic deploys“) lässt sich per Platform-API abschalten, und ein Deploy geht per `POST /apps/:app/builds` mit Tarball-URL des Commits (mit `--sha`).
362. [Feature] **Koyeb.** Auto-Deploy auf Push ist ein Dienst-Flag (`git.no_deploy_on_push`); Redeploy per API mit Commit.
363. [Feature] **Dokploy.** Self-hosted wie Coolify, mit eigener API (`application.update autoDeploy`, `application.deploy`); hook.sh erwähnt Dokploy schon.
364. [Feature] **Google Cloud Build/Cloud Run.** Trigger lassen sich über `gcloud builds triggers update --disabled` abschalten und mit `triggers run --sha` gezielt starten; Kosten pro Build-Minute.
365. [Feature] **Azure Static Web Apps.** Sie bauen über einen GitHub-Workflow; ein Provider könnte den Workflow-Trigger (`on: push`) erkennen und per `workflow_dispatch` starten.
366. [Feature] **GitHub Pages (Workflow-Builds).** `build_type: workflow` baut bei jedem Push und verbraucht Actions-Minuten; abschalten über die Pages-API bzw. den Workflow, starten per `workflow_dispatch`.
367. [Feature] **Deno Deploy.** Projekte mit GitHub-Link bauen bei jedem Push; Deployments per API mit Commit.
368. [Feature] **Northflank.** Build-Regeln je Branch per API abschaltbar, Builds mit SHA per API startbar.
369. [Feature] **Kinsta/Sevalla Application Hosting.** Automatic deployment ist ein App-Schalter; manueller Deploy per API mit Branch/Commit.
370. [Feature] **`deploys providers new <id>`.** Erzeugt `providers/<id>.sh` mit allen Vertragsfunktionen als `die "… cannot …"` und `tests/fixtures/<id>/env`, damit neue Module nicht wieder ohne Vertragstest landen.
371. [Feature] **`deploys providers test <p>`.** Ein nur lesender Live-Selbsttest gegen das echte Konto: `_has` gibt eine ID, `_latest` gibt TSV, `_json` hat alle Felder; das hätte die Vertragsfehler oben sofort gezeigt.


### Neue CLI-Funktionen

372. [Feature] **`deploy-changed --wait` mit Abschlussbericht.** Heute bedeutet Exit 0 nur „gestartet“; mit `--wait` allen gestarteten Deploys folgen (parallel) und „8 live, 1 failed“ mit passendem Exit-Code melden, optional `--verify`.
373. [Feature] **Globales `--dry-run`.** Jeder schreibende Befehl zeigt, welchen API-Aufruf er senden würde (Methode, Pfad, Body ohne Geheimnisse), ohne ihn zu senden; das hilft bei neuen Providern und Team-Freigaben.
374. [Feature] **`DEPLOYS_DEBUG=1`.** Jeden HTTP-/CLI-Aufruf mit Dauer und Statuscode (Token maskiert) auf stderr loggen; heute muss man zur Fehlersuche Code lesen.
375. [Feature] **`deploys backup` und `restore`.** vercel-repos.json ist laut Doku „the only record“ der getrennten Repos; ein Export aller lokalen Dateien (ohne Schlüssel) als ein JSON, optional in ein privates Repo oder Gist.
376. [Feature] **Linux-Zeitplan für guard und autofix.** `job_on` kennt nur launchd; unter Linux eine systemd-User-Timer-Unit oder eine crontab-Zeile schreiben. (deploys:767–792)
377. [Feature] **Benachrichtigungen unter Linux.** `af_notify` nutzt nur osascript; `notify-send`, falls vorhanden, sonst nur stdout. (deploys:692–696)
378. [Feature] **`deploys self-update` für reine CLI-Installationen.** Prüft die neueste Release-Version mit dem SHA-256-Abgleich von install.sh und tauscht die Dateien in `<prefix>/lib/deploys`.
379. [Feature] **`doctor` prüft alle Werkzeuge.** perl (für die Maskierung bei autofix/ai), curl, column, security bzw. secret-tool, aws, glab und die Bash-Version gegenüber 3.2-Fallen; dazu „bereit“ je eingeschaltetem Provider. (deploys:1480–1495)
380. [Feature] **`ci` und `--when-green` für GitLab-Pipelines.** Siehe Bug oben; als echte Funktion mit `glab ci status` oder der Pipelines-API.


### Doku (README-CLI.md, docs/CLI.md, docs/PROVIDERS.md)

381. [UX] **Das CI-Beispiel deployt für Vercel vermutlich nichts.** Es setzt kein `DEPLOYS_CONFIG` und speichert keine vercel-repos.json zwischen den Läufen; ohne Zuordnung ist kein Vercel-Projekt `deployable`, und ohne vercel-CLI im Runner ist Vercel nicht „ready“ und fällt still weg. Den Cache-Schritt, `npm i -g vercel` und `DEPLOYS_CONFIG` ins Beispiel aufnehmen. (README-CLI.md:84–92)
382. [UX] **Die Anforderungstabelle ist unvollständig.** perl (autofix/ai), `security` (macOS) bzw. Env-Variablen unter Linux, glab/GITLAB_TOKEN, aws-CLI (Amplify) und column als „ohne: keine Tabellen“ (heute ein Absturz) fehlen. (README-CLI.md:55–63)
383. [UX] **„Add --json to any command“ stimmt nicht.** `watch`, `logs`, `history`, `explain`, `diff` und `notes` haben kein JSON; die Liste der Befehle mit JSON nennen. (docs/CLI.md:70)
384. [UX] **docs/CLI.md kennt nur Vercel und Render.** `deploy`, `verify`, `risk`, `ci`, `window`, `team`, `readonly`, `providers`, `list` und die fünf neuen Provider fehlen; auch README-CLI.md beginnt mit „on Vercel and Render“. (docs/CLI.md, README-CLI.md:3)
385. [UX] **PROVIDERS.md ist veraltet.** Zeile 3–4 nennt nur vercel, render und hook; der printf-Zwang für `_meta`/`_doctor` wird von vier Providern verletzt, und die Pflicht, dass `_has` die ID druckt bzw. `_status` TSV liefert, sollte mit einem Beispiel und dem Hinweis auf `contract.sh` hervorgehoben werden. (docs/PROVIDERS.md:3–4, 48–61)
386. [UX] **Umgebungsvariablen sammeln.** `DEPLOYS_NO_GITHUB`, `DEPLOYS_READONLY`, `NO_COLOR`, `DEPLOYS_NOTIFY`, `DEPLOYS_JOURNAL`, `DEPLOYS_TEAM_TTL`, `DEPLOYS_GITLAB_HOSTS`, `DEPLOYS_CLOUDFLARE_TOGGLE`, `DEPLOYS_NETLIFY_POLLS` und `DEPLOYS_AUTOFIX_PER_*` stehen verstreut im Code; eine Tabelle in docs/CLI.md.


### Tests

387. [Test] **Tabellentest für den Observer-Modus.** Für jeden schreibenden Befehl in jeder Flag-Reihenfolge prüfen, dass `DEPLOYS_READONLY=1` ihn ablehnt; das hätte `deploy-changed --when-green --yes` und `autodeploy allow` gefunden.
388. [Test] **Tabellentest für `safe_arg`.** Jeder Befehl, der einen Namen nimmt, bekommt `a/b`, `a?x` und `a%2F` und darf keinen API-Aufruf in `$CALLS` hinterlassen.
389. [Test] **Deploy-Fenster für alle Startwege.** `deploy`, `deploy <gruppe>`, `<p> deploy`, `deploy-changed --yes` und autofix-Redeploys mit `DEPLOYS_NOW` in einem geschlossenen Fenster.
390. [Test] **`doctor` auf eindeutige Schlüssel prüfen.** `jq` sieht doppelte Schlüssel nicht; mit `jq --stream` oder python `object_pairs_hook` testen, dass kein Schlüssel doppelt ist.
391. [Test] **Linux-Lauf ohne `column`, `security` und mit GNU-xargs.** Ein CI-Job in einem schlanken Container (debian-slim) mit nur bash, curl, jq und gh fängt die Portabilitätsfehler oben.
392. [Test] **Hilfe gegen die case-Zweige prüfen.** Ein Test, der jeden `case`-Befehl in deploys sucht und verlangt, dass er in `--help` und in der Vervollständigung steht.
393. [Test] **`--when-green` mit einem Provider ohne `caps.sha`.** Erwartung: kein `--sha` an `_deploy_json`, eine verständliche Meldung, kein Abbruch der anderen.
394. [Test] **Projekte ohne Repo.** Ein Render-Image-Dienst und ein Bitbucket-Vercel-Projekt in den Fixtures dürfen `changed` nicht auf Exit 1 setzen.

## 4. iOS-App, Widgets, shared (128)
### Bugs: Deploy, Rollback, Status

395. ✅ [Bug] **Demo scheitert auf Geräten ohne Code.** `authenticate` läuft vor der Demo-Prüfung; ein Review-Gerät ohne Passcode bekommt „Lege einen Code fest“ und kann den Demo-Deploy nicht zeigen (App-Review-Risiko 2.1, App ist gerade in Review). Im Demo-Modus ohne Code durchlassen. (ios/App/PhoneStore.swift:117–126)
396. ✅ [Bug] **Vercel-Rollback kann auf den falschen Deploy zielen.** Steht der aktuelle Production-Deploy nicht unter den letzten 20 READY-Deploys (z. B. nach Promote eines alten Deploys), wird `firstIndex ?? 0` der neueste READY-Deploy statt des Live-Deploys, und „der davor“ kann der Live-Stand selbst oder ein beliebiger sein; ohne Treffer `nil` zurückgeben und den Live-Deploy direkt per ID laden. (ios/App/Clients.swift:154)
397. ✅ [Bug] **Doppelter Deploy durch zweites Tippen.** `running[p.key]` wird erst nach Face ID und erfolgreichem POST gesetzt (in `follow`), bis dahin bleibt „Deployen“ aktiv; ein zweiter Tipp startet einen zweiten bezahlten Build. Zustand „startet“ vor `authenticate` setzen. (ios/App/PhoneStore.swift:124–134, Views.swift:210)
398. ✅ [Bug] **Neu geschriebener Verlauf zeigt „0 Commits warten“.** Scheitert `compare` (404/„No common ancestor“ oder anderer Fehler), bleibt `pendingCommits` nil, `changed` ist aber true (live ≠ head), also erscheint „0 Commits warten“ und der Zweig `rewritten` in `stateText` wird nie erreicht. `rewritten` vor `changed` prüfen und „Anzahl unbekannt“ zeigen. (ios/App/Views.swift:146–152, Clients.swift:274–276)
399. ✅ [Bug] **Andere compare-Fehler werden verschluckt.** `catch {}` lässt Rate-Limit, 5xx oder Netzfehler unsichtbar: kein `fetchError`, das Projekt gilt als wartend mit 0 Commits. `fetchError` setzen. (ios/App/Clients.swift:276)
400. ✅ [Bug] **Render: `liveAt` kommt vom neuesten Versuch, nicht vom Live-Deploy.** Bei einem gescheiterten letzten Deploy wird dessen `finishedAt` zur Live-Zeit; die Regel `headAt > liveAt` und das „seit“ im Widget stimmen dann nicht (gleicher Fehler wie Mac-Idee 1, hier im iOS-Port). (ios/App/Clients.swift:202)
401. ✅ [Bug] **Render: Repo-Name wird zerschnitten.** `replacingOccurrences(of: ".git", with: "")` ersetzt überall, ein Repo wie `org/my.gitops` wird zu `org/myops`; nur ein Suffix `.git` entfernen. (ios/App/Clients.swift:192)
402. ✅ [Bug] **Render: Nicht-GitHub-Repos laufen gegen die GitHub-API.** GitLab/Bitbucket-URLs bleiben als volle URL in `repo` und erzeugen „HTTP 404“ als `fetchError`; Host prüfen und „nur GitHub wird verglichen“ zeigen. (ios/App/Clients.swift:192)
403. ✅ [Bug] **Render: Live-Deploy außerhalb der letzten 10 fehlt.** Mit vielen fehlgeschlagenen Versuchen liegt der Live-Deploy nicht in `limit=10`, `liveSha` bleibt nil und der Vergleich fällt auf Zeiten zurück; gezielt `status=live` abfragen oder Limit erhöhen. (ios/App/Clients.swift:199–207)
404. ✅ [Bug] **Team wird bei jedem Status-Poll neu aufgelöst.** `vercel()` ruft ohne gespeicherte Team-ID alle 6 s zusätzlich `/v2/teams` auf; einmal beim Laden auflösen und merken. (ios/App/PhoneStore.swift:162–166, 179)
405. ✅ [Bug] **Mehrere Vercel-Teams: stilles Ergebnis „keine Projekte“.** `resolveTeam` gibt bei mehr als einem Team nil zurück, dann wird das persönliche Konto gelesen, ohne Hinweis; bei >1 Team eine Meldung „Team wählen“ zeigen. (ios/App/Clients.swift:87–91)
406. ✅ [Bug] **Nach dem Deploy fehlt manchmal das Neuladen.** Läuft gerade ein anderes Laden, kehrt das `reload()` am Ende von `follow` (`guard !loading`) sofort zurück; die Liste zeigt dann den alten Stand. Ein „nochmal laden“-Flag statt Abbruch. (ios/App/PhoneStore.swift:64, 191)
407. ✅ [Bug] **Demo-Schalter während des Ladens wirkt nicht.** `demo.didSet` startet `reload()`, das bei `loading` abbricht; man sieht echte Daten im Demo-Modus oder umgekehrt. (ios/App/PhoneStore.swift:17, 64)
408. ✅ [Bug] **Polling-Fehler laufen 20 Minuten still weiter.** Jeder Fehler in `follow` führt zu `continue`, ohne Meldung; nach Ablauf kommt auch keine Meldung „Status unbekannt, bitte prüfen“. (ios/App/PhoneStore.swift:174–190)
409. ✅ [Bug] **Vercel: Deploy nach einem Rollback geht nicht live (Vermutung).** Nach einem Instant Rollback weist Vercel neue Production-Deploys nicht automatisch der Domain zu; die App meldet „ist live“, sobald READY. Nach dem Rollback-Status fragen und ggf. befördern oder warnen. (ios/App/PhoneStore.swift:184, Clients.swift:139)
410. ✅ [Bug] **Rollback-Knopf startet mehrere Suchen.** Während `rollbackTarget` lädt, gibt es keinen Ladezustand; mehrfaches Tippen öffnet mehrere Dialoge nacheinander. (ios/App/Views.swift:211–217)
411. ✅ [Bug] **Rollback-Dialog zeigt „()“.** Ohne SHA lautet der Text „Der vorige Deploy () geht wieder live“; dann Datum oder Deploy-ID zeigen. (ios/App/Views.swift:237)
412. ✅ [Bug] **Rollback-Knopf auch für pausierte oder nicht deploybare Dienste aktiv.** Die Sperre prüft nur `building`/`running`, nicht `paused`/`deployable`. (ios/App/Views.swift:217)
413. ✅ [Bug] **Building/failed-„seit“ im Snapshot ist bei Vercel die Live-Zeit.** `since` nimmt für nicht wartende Projekte `liveAt`, das bei Vercel der fertige Production-Deploy ist, nicht der Start des laufenden oder gescheiterten. (ios/App/PhoneStore.swift:212)


### Bugs: Netzwerk und Hintergrund

414. ✅ [Bug] **GitHub-Rate-Limit (403) wird nicht erkannt.** GitHub meldet das primäre Limit mit 403 und `x-ratelimit-remaining: 0`; die App versucht nur 429 erneut und zeigt „HTTP 403“. Header auswerten, Reset-Zeit nennen. (ios/App/Clients.swift:38–45)
415. ✅ [Bug] **`Retry-After` wird ignoriert.** Feste 3/6 s statt der vom Server genannten Zeit; bei Render-429 schlägt die ganze Liste oft trotzdem fehl. (ios/App/Clients.swift:38–40)
416. ✅ [Bug] **`URLSession.shared` cacht API-Antworten (Vermutung).** GitHub sendet `Cache-Control: private, max-age=60`; direkt nach einem Deploy kann der alte Branch-Stand aus dem Cache kommen, und Antworten liegen auf der Platte. Eigene `ephemeral`-Session mit `reloadIgnoringLocalCacheData`. (ios/App/Clients.swift:35)
417. ✅ [Bug] **Hintergrund-Refresh überschreitet das Zeitfenster (Vermutung).** BGAppRefresh hat etwa 30 s; Laden mit vielen Repos, sequentieller Zweitschleife und Retry-Pausen bis 9 s pro Aufruf dauert länger, iOS bricht ab, Widget und Hinweise bleiben alt. Zeitbudget und `expirationHandler`, im Hintergrund nur das Nötigste lesen. (ios/App/DeployCenterApp.swift:31–39)
418. ✅ [Bug] **Hintergrundlauf arbeitet mit einem zweiten Store.** `Background.run` erzeugt eine neue `PhoneStore`; die sichtbare Instanz bekommt die neuen Daten nicht und zeigt beim Zurückkehren den alten Stand. Die App-Instanz teilen. (ios/App/DeployCenterApp.swift:33)
419. ✅ [Bug] **Hinweis-Flut nach geleertem Cache.** `last-projects.json` liegt in `Caches`; löscht iOS es, ist `before` leer und jedes wartende Projekt gilt als „neu wartend“. Datei in `Application Support` und leeres `before` als „nicht melden“ behandeln. (ios/App/DeployCenterApp.swift:35, 41–43)
420. ✅ [Bug] **Erlaubnis für Mitteilungen abgelehnt, Schalter bleibt an.** `requestPermission` ignoriert das Ergebnis; Schalter zurücksetzen und auf iOS-Einstellungen verweisen. (ios/App/DeployCenterApp.swift:45–47, Views.swift:280)
421. ✅ [Bug] **Vercel-Deployments-Fehler wird verschluckt.** `try?` bei `/v6/deployments` lässt `latestState` leer; laufende Builds sind dann unsichtbar, ohne Fehlermeldung. (ios/App/Clients.swift:101)
422. ✅ [Bug] **Abruf stoppt still bei 1000 Projekten/Diensten.** Kein Hinweis, dass die Liste abgeschnitten ist. (ios/App/Clients.swift:99, 177)


### Bugs: Oberfläche, Texte, QR

423. ✅ [Bug] **Lesefehler werden nirgends gezeigt.** `fetchError` wird gesetzt, aber keine View zeigt ihn; man sieht nur „Stand unbekannt“. In der Detailansicht ausgeben. (ios/App/Views.swift:153, Project.swift:34)
424. ✅ [Bug] **„Stand vor …“ tickt nicht.** `at.formatted(.relative)` ist ein fester String; nach Minuten steht noch „vor 0 Sek.“. `Text(at, style: .relative)` oder `TimelineView`. (ios/App/Views.swift:87, 195)
425. ✅ [Bug] **Einzahl/Mehrzahl falsch.** „3 PR · …“ in der Zeile, „1 projects“ und „1 commits“ im Widget. (ios/App/Views.swift:147, widgets/DeployWidget.swift:42, 115)
426. ✅ [Bug] **Rohe Plattform-Zustände in der Oberfläche.** „deployt: build_in_progress“ und „Name: build_failed“ erscheinen unübersetzt; die Mac-App übersetzt sie bereits. (ios/App/Views.swift:168, PhoneStore.swift:188)
427. ✅ [Bug] **Sprache der Texte und der Datumsangaben passen nicht zusammen.** `L()` nimmt `Locale.preferredLanguages.first` statt `Bundle.main.preferredLocalizations`, Datum/Relativzeit folgen dem Region-Locale; „Updated vor 5 Minuten“ ist möglich (Vermutung). Beide aus derselben Sprache ableiten. (ios/App/Project.swift:75–77, Views.swift:87)
428. ✅ [Bug] **Berechtigungstexte nur auf Englisch.** `NSCameraUsageDescription` und `NSFaceIDUsageDescription` stehen nur als Build-Setting; deutsche Nutzer sehen englische Systemdialoge. `InfoPlist.xcstrings` anlegen. (ios/DeployCenter.xcodeproj/project.pbxproj:219–220)
429. ✅ [Bug] **QR-Vorschau bekommt die falsche Größe.** `layer.frame = view.bounds` wird einmal in `viewDidLoad`/nach der Freigabe gesetzt; bei Drehung, iPad-Split-View oder Stage Manager bleibt die Kamera falsch zugeschnitten. In `viewDidLayoutSubviews` nachführen. (ios/App/ConnectMac.swift:127)
430. ✅ [Bug] **QR-Übernahme löscht eigene Schlüssel.** `adopt` schreibt alle vier Felder, leere löschen den Eintrag; ein auf dem iPhone eingetragenes GitHub-Token verschwindet, wenn der Mac keins hat, ohne Rückfrage. Leere Felder nicht überschreiben oder vorher fragen. (ios/App/PhoneStore.swift:44–51)
431. ✅ [Bug] **Einstellungen gehen beim Wegwischen verloren.** Gespeichert wird nur über „Fertig“; Herunterwischen verwirft eingetippte Tokens kommentarlos. `interactiveDismissDisabled` bei Änderungen oder beim Schließen speichern. (ios/App/Views.swift:296, 307–313)
432. ✅ [Bug] **Keychain: Löschen vor Hinzufügen.** Schlägt `SecItemAdd` fehl, ist das alte Token weg, und das Ergebnis wird ignoriert; `SecItemUpdate` mit Rückfall auf Add und Fehler in der Oberfläche melden. (ios/App/Keychain.swift:24–30, Views.swift:308–311)
433. ✅ [Bug] **Doppelte Widget-IDs möglich.** `Project.id = platform + "/" + name`; zwei gleichnamige Projekte (z. B. in zwei Vercel-Teams) erzeugen doppelte `ForEach`-IDs. Die Provider-ID mitgeben. (shared/DeploySnapshot.swift:21)


### Security und Datenschutz

434. ✅ [Security] **Token-Felder lösen „Passwort sichern?“ aus.** `textContentType(.password)` lädt iOS zum Speichern in Passwörter/iCloud-Schlüsselbund ein, was dem Versprechen „nie synchronisiert“ widerspricht. Content-Type entfernen und `.privacySensitive()` setzen. (ios/App/Views.swift:267, 270, 272)
435. ✅ [Security] **QR-Code ohne Ablauf.** `parse(qr:)` prüft `updated` nicht; ein altes Foto oder Bildschirmfoto des Codes funktioniert für immer. Codes älter als zwei Minuten ablehnen. (shared/PhoneLink.swift:87–91)
436. [Security] **QR-Code enthält Schlüssel im Klartext.** Base64-JSON ist für jede Kamera lesbar; optional mit einem auf dem Mac angezeigten Kurzcode verschlüsseln (z. B. 6 Ziffern, HKDF + AES-GCM). (shared/PhoneLink.swift:82–85)
437. [Security] **Eigene Tokens landen in der geteilten Schlüsselbund-Gruppe (Vermutung).** Ohne `kSecAttrAccessGroup` nimmt iOS die erste Gruppe aus `keychain-access-groups`, also die Team-Gruppe, die alle Apps des Teams lesen können. Die App-eigene Gruppe explizit setzen. (ios/App/Keychain.swift:22, ios/Config/DeployCenter.entitlements:9–12)
438. ✅ [Security] **Volles gh-CLI-Token geht aufs iPhone.** Das Telefon liest GitHub nur; ein gh-Token mit `repo`/`workflow`-Rechten ist mehr als nötig. In der App die Scopes (`X-OAuth-Scopes`) anzeigen und zu einem fein granularen Nur-Lese-Token raten. (docs/WIDGETS-IOS.md:164–165)
439. ✅ [Security] **App-Umschalter zeigt Projekte und Domains.** Beim Wechsel in den Hintergrund einen Sichtschutz legen (optional), wie viele Admin-Apps es tun. (ios/App/DeployCenterApp.swift:17)
440. ✅ [Security] **Optionale App-Sperre beim Öffnen.** Face ID schützt nur Deploy/Rollback; Liste, Domains und Commit-Texte sind offen. Schalter „Beim Öffnen entsperren“. (ios/App/PhoneStore.swift:113)
441. ✅ [Security] **Widget auf Sperrbildschirm/StandBy zeigt Projektnamen.** `.privacySensitive()` für Namen, damit iOS sie im gesperrten Zustand ausblendet. (widgets/DeployWidget.swift:98)
442. ✅ [Security] **Commit-Texte unnötig im App-Group-Container.** `message` wird geschrieben, aber von keinem Widget gezeigt; weglassen, bis es gebraucht wird. (ios/App/PhoneStore.swift:212, shared/DeploySnapshot.swift:20)
443. ✅ [Security] **„Alle Schlüssel von diesem iPhone entfernen“.** Es gibt keinen Weg, per QR übernommene Schlüssel auf einmal zu löschen oder die Mac-Verbindung auf dem iPhone zu ignorieren. (ios/App/ConnectMac.swift:23–26)


### Performance

444. ✅ [Perf] **Schlüsselbund bei jedem Neuzeichnen.** `hasAccount` und `token()` lesen bei jedem Aufruf per `SecItemCopyMatching`; einmal laden und im Store halten. (ios/App/PhoneStore.swift:29–32, Views.swift:16)
445. ✅ [Perf] **Zweiter GitHub-Durchlauf läuft seriell.** Projekte mit abweichendem Live-Commit werden nacheinander verglichen; in dieselbe Task-Gruppe nehmen. (ios/App/PhoneStore.swift:96–102)
446. ✅ [Perf] **ETags für GitHub.** Bedingte Anfragen (`If-None-Match`) liefern 304 und zählen nicht gegen das Limit; wichtig ohne Token (60/h) und für den Hintergrund. (ios/App/Clients.swift:247–257)
447. ✅ [Perf] **Widget-L liest die Datei bei jedem Text.** `L()` im Widget dekodiert `snapshot.json` pro Aufruf; Sprache einmal aus dem Entry übergeben. (widgets/DeployWidget.swift:26–29)
448. ✅ [Perf] **Widget wird auch ohne Änderung neu geladen.** `reloadAllTimelines()` nach jedem Laden verbraucht das Widget-Budget; nur bei geändertem Snapshot (Mac macht das schon). (ios/App/PhoneStore.swift:222–227)
449. ✅ [Perf] **`ISO8601DateFormatter` pro Aufruf.** Bei hunderten Daten pro Laden einmal statisch anlegen. (ios/App/Clients.swift:64–70)
450. ✅ [Perf] **Sofortstart aus dem letzten Stand.** `last-projects.json` existiert schon; beim Start zuerst anzeigen, dann im Hintergrund laden, statt leerer Liste mit Spinner. (ios/App/Views.swift:102, PhoneStore.swift:108)
451. ✅ [Perf] **Bis zu zehn sequentielle `commits/{sha}/pulls`-Aufrufe.** Parallel (begrenzt) oder per GraphQL in einem Aufruf. (ios/App/Clients.swift:266–272)


### Barrierefreiheit

452. ✅ [A11y] **Meldungen werden VoiceOver nicht angesagt.** Das Toast-Overlay erscheint still; `AccessibilityNotification.Announcement` senden. (ios/App/Views.swift:47–55)
453. ✅ [A11y] **Fehler verschwinden nach 4 Sekunden.** Für Fehler und bei aktivem VoiceOver länger oder bis zum Antippen stehen lassen; Schließen als echter Button. (ios/App/Views.swift:51–52)
454. ✅ [A11y] **Zeilen ohne Aktionen.** VoiceOver-Aktionen „Deployen“, „Zurückrollen“, „Domain öffnen“ per `accessibilityActions` (wie in der Mac-App). (ios/App/Views.swift:158–173)
455. ✅ [A11y] **Symbolname im Status vorgelesen.** Das Icon in der Detailansicht ist nicht versteckt; VoiceOver liest „Hammer, baut“. `accessibilityHidden(true)`. (ios/App/Views.swift:188)
456. ✅ [A11y] **Fußzeile nennt immer Face ID.** Auf Touch-ID-Geräten oder nur mit Code ist der Text falsch; `LAContext.biometryType` auswerten. (ios/App/Views.swift:219–220)
457. ✅ [A11y] **QR-Scanner ohne Anleitung.** Nur „Abbrechen“ auf schwarzem Grund; Text „Auf den Code am Mac richten“ und VoiceOver-Hinweis, gefunden/nicht gefunden mit Haptik. (ios/App/ConnectMac.swift:90–113)
458. ✅ [A11y] **Widget als ein VoiceOver-Element.** Große Zahl und Beschriftung werden getrennt gelesen; `accessibilityElement(children: .combine)` und Label „5 PRs warten, 1 baut“. (widgets/DeployWidget.swift:35–45)
459. ✅ [A11y] **Widget mit festen Schriftgrößen und fester Breite.** `size: 44/36` und `frame(width: 104)` schneiden bei großer Schrift ab; skalierte Größen und `minimumScaleFactor`. (widgets/DeployWidget.swift:38, 67, 75)
460. ✅ [A11y] **„projects“ in der Übersicht mehrdeutig.** Für VoiceOver und Leser „Projekte warten“ statt nur „Projekte“. (ios/App/Views.swift:111)
461. [A11y] **VoiceOver-Durchgang vor der Einreichung.** APP-STORE.md sagt „VoiceOver not yet checked“; Accessibility-Inspector-Audit im Simulator und Ergebnis dokumentieren. (docs/APP-STORE.md:20)


### iPad

462. ✅ [UX] **Tastaturkürzel auf dem iPad.** ⌘R neu laden, ⌘, Einstellungen, ⌘D deployen der Auswahl, Pfeiltasten in der Liste. (ios/App/Views.swift:14–34)
463. ✅ [UX] **Leere Detailspalte beim Start.** Auf breiten Displays das erste Projekt der Gruppe „Achtung“ oder „Wartet“ vorwählen. (ios/App/Views.swift:29–31)
464. ◐ [UX] **Kontextmenü auf Zeilen.** Langes Drücken/Rechtsklick: Deployen, Domain öffnen, SHA kopieren, im Dashboard öffnen. (ios/App/Views.swift:96)
465. ✅ [UX] **Mehrere Fenster nebeneinander.** Mit Stage Manager je Fenster eine eigene Auswahl (`@SceneStorage`) statt `@State`. (ios/App/Views.swift:9)


### UX und Gleichstand mit der Mac-App

466. ✅ [UX] **„Nichts Neues – trotzdem bauen?“ fehlt auf iOS.** Der Deploy-Knopf ist auch bei aktuellem Stand aktiv und kostet einen Build; die Mac-App fragt bereits nach. (ios/App/Views.swift:204–210)
467. ✅ [UX] **Auto-Deploy-Warnung fehlt.** `autoDeploy` wird geladen, aber nie gezeigt; der Kern der App (Projekte, die bei jedem Push bauen) ist auf dem iPhone unsichtbar. Abzeichen und Banner wie auf dem Mac. (ios/App/Project.swift:15)
468. ✅ [UX] **401/403 verständlich machen.** „HTTP 401: …“ als „Token ungültig oder abgelaufen“ mit Knopf zu den Einstellungen; 404 bei privatem Repo als „GitHub-Token fehlt“. (ios/App/Clients.swift:41–45, Views.swift:89)
469. ✅ [UX] **Leere Liste erklären.** Hat das Konto keine Projekte (oft: falsches Team), steht nur die Übersicht mit Nullen; `ContentUnavailableView` mit Hinweis auf die Team-ID. (ios/App/Views.swift:81–100)
470. ✅ [UX] **„Verbindung testen“ in den Einstellungen.** Nach dem Speichern Kontoname, Team und Anzahl Projekte pro Anbieter zeigen, statt erst in der Liste zu scheitern. (ios/App/Views.swift:307–313)
471. ✅ [UX] **Herkunft des Schlüssels im Feld zeigen.** Leeres Feld mit Platzhalter „vom Mac“, wenn ein verknüpfter Schlüssel greift. (ios/App/Views.swift:267–272)
472. ✅ [UX] **Neu laden beim Zurückkehren.** Beim Aktivwerden nur bei geänderter Verknüpfung; bei Daten älter als z. B. 5 Minuten automatisch laden. (ios/App/Views.swift:35–37)
473. ✅ [UX] **Offline-Zustand.** Mit `NWPathMonitor` „Offline – Stand von 10:42“ zeigen, statt dreimal 30 s auf Zeitüberschreitung zu warten. (ios/App/Clients.swift:22)
474. ✅ [UX] **Rollback ohne Verfolgung.** Nach einem Rollback 4 s warten und neu laden; wie beim Deploy bis „live“ verfolgen. (ios/App/PhoneStore.swift:156–158)
475. ✅ [UX] **Rollback-Dialog zu knapp.** Commit-Nachricht und Datum des Ziels zeigen, nicht nur 7 Zeichen SHA. (ios/App/Views.swift:236–239)
476. ✅ [UX] **„SHA“ ist mehrdeutig.** Nur der Live-SHA erscheint; Live und Neuester beide anzeigen und kopierbar machen. (ios/App/Views.swift:201)
477. ✅ [UX] **Haptik bei Ergebnis.** Erfolg/Fehler eines Deploys mit `sensoryFeedback`, besonders wenn man nebenbei wartet. (ios/App/PhoneStore.swift:184–189)
478. ✅ [UX] **Meldung zusammenfassen statt abschneiden.** Mitteilung nimmt nur vier Zeilen und verschweigt den Rest; „+2 weitere“ anhängen. (ios/App/PhoneStore.swift:241)
479. ✅ [UX] **Mitteilungen ersetzen statt stapeln.** Feste `identifier` pro Projekt/Ereignis und `threadIdentifier`, damit sich Hinweise nicht häufen. (ios/App/PhoneStore.swift:242)
480. ✅ [UX] **Hinweis bei ausgeschalteter Hintergrundaktualisierung.** `UIApplication.backgroundRefreshStatus` prüfen und bei „aus“ oder Stromsparmodus im Schalter-Fußtext sagen, dass keine Hinweise kommen. (ios/App/Views.swift:279–284)
481. ✅ [UX] **Widget kennzeichnet Demo-Daten nicht.** `snap.demo` wird nicht ausgewertet; ein kleines „Demo“ im Widget verhindert Verwechslung. (widgets/DeployWidget.swift:32–45)
482. ✅ [UX] **Widget zeigt nicht, wie alt die Daten sind.** Ohne Hintergrundlauf steht tagelang derselbe Stand da; `Text(snap.at, style: .relative)` und ab z. B. 6 Stunden grau. (widgets/DeployWidget.swift:32–90)
483. ✅ [UX] **Scanner bleibt bei falschem Code nicht offen.** Ein fremder QR-Code schließt die Kamera; weiter scannen und den Hinweis einblenden. (ios/App/ConnectMac.swift:60–63)
484. ✅ [UX] **Welcome erklärt Tokens nicht.** Links „Vercel-Token anlegen“ / „Render-API-Key anlegen“ mit nötigen Rechten direkt im Willkommensbildschirm. (ios/App/Views.swift:64–73)


### Code und Teilung über shared/

485. ◐ [Code] **Die „Wartet“-Regel in shared/ legen.** `changed`/`building`/`failed` sind ein Port von `CHANGED_RULE`; als gemeinsame, getestete Swift-Datei verhindert das Abweichungen zwischen Mac und iPhone. (ios/App/Project.swift:38–57)
486. ◐ [Code] **Kein Testziel im iOS-Projekt.** Unit-Tests für `prNumber`, `changed`, `merging`, Render-/Vercel-Rollback-Ziel mit aufgezeichneten JSON-Antworten. (ios/DeployCenter.xcodeproj/project.pbxproj)
487. ◐ [Code] **`L()` doppelt.** Einmal in Project.swift, einmal privat im Widget mit anderer Logik; eine Funktion mit Sprachparameter in shared/. (ios/App/Project.swift:75, widgets/DeployWidget.swift:26)
488. [Code] **Codable statt `[String: Any]`.** Kleine Decodable-Typen für Vercel/Render/GitHub machen Pfadfehler (`"targets.production.id"`) zu Compile-Fehlern. (ios/App/Clients.swift:6, 54–62)
489. ✅ [Code] **HTTP injizierbar machen.** `URLSession` als Parameter, damit Tests ohne Netz laufen und der Hintergrund eine eigene Session nutzen kann. (ios/App/Clients.swift:15–35)
490. ✅ [Code] **Feld-Zuordnung viermal von Hand.** `TokenKey` ↔ `LinkedKeys` steht in `adopt`, `linkedToken`, `save`, `onAppear`; ein KeyPath-Mapping. (ios/App/PhoneStore.swift:33–51, Views.swift:299–311)
491. ✅ [Code] **iOS-Snapshot ohne Sprache.** `language` bleibt nil; die App-Sprache mitschreiben, damit Widget und App gleich sprechen. (ios/App/PhoneStore.swift:216)
492. ✅ [Code] **Build-Nummer automatisch.** `CURRENT_PROJECT_VERSION` wird von Hand erhöht; in `ios/build.sh --archive` aus Datum oder `git rev-list --count` setzen. (ios/DeployCenter.xcodeproj/project.pbxproj:176, ios/build.sh:49)
493. ✅ [Code] **`--run` ohne gebooteten Simulator.** `simctl install booted` scheitert kryptisch; vorher prüfen und einen Simulator vorschlagen/starten. (ios/build.sh:21–24)
494. [Code] **iOS-Ziel in den bestehenden CI-Workflow.** Einen Schritt `xcodebuild -sdk iphonesimulator` (macOS-Runner) ergänzen; er fängt kaputte Builds der geteilten Dateien (shared/, widgets/), die die Mac-Änderungen sonst still brechen. (ios/build.sh:17)


### App Store und Doku

495. ◐ [Store] **Verfügbarkeit auf Apple-Silicon-Macs abschalten.** Sonst erscheint die iPad-App im Mac App Store neben der echten Mac-App; in App Store Connect „iPhone- und iPad-Apps auf Mac“ (und visionOS) deaktivieren. (docs/APP-STORE.md:46–67)
496. ◐ [Store] **Deutsche Screenshots.** Die deutsche Seite nutzt englische Bilder; mit `-AppleLanguages (de)` und `-demo` erzeugen. (docs/APP-STORE.md:56)
497. [Store] **Accessibility-Angaben in App Store Connect.** Die neuen Barrierefreiheits-Labels (VoiceOver, größerer Text, Dunkelmodus …) erst nach geprüftem VoiceOver-Durchgang ausfüllen. (docs/APP-STORE.md:20)
498. ✅ [Store] **Build-Nummern in der Doku widersprechen sich.** „Build 1.0 (1) is uploaded“ und Einreichung „1.0 (2)“; Status-Abschnitt aktualisieren. (docs/APP-STORE.md:52, 145)
499. ◐ [Store] **Doku nennt nicht geprüfte Pfade.** Echte Deploys, Rollback und iCloud-Verknüpfung sind laut Doku nie gelaufen; vor der nächsten Version eine kurze Testliste mit einem Wegwerf-Projekt abhaken. (docs/WIDGETS-IOS.md:205–212)


### Features

500. [Feature] **Sperrbildschirm-Widgets.** `accessoryCircular` (Zahl PRs), `accessoryRectangular` (Top-Projekt), `accessoryInline`; Daten sind schon im Snapshot. (widgets/DeployWidget.swift:152)
501. [Feature] **Großes Widget.** `systemLarge` mit bis zu zehn Projekten, die der Snapshot ohnehin enthält. (widgets/DeployWidget.swift:152)
502. [Feature] **Getönte Home-Screen-Darstellung.** `widgetAccentable()` und `widgetRenderingMode` für iOS-18-„Getönt“, sonst wird die große Zahl flach grau. (widgets/DeployWidget.swift:38)
503. [Feature] **Widget-Zeilen als Deep Link.** Jede Zeile im mittleren Widget per `Link` direkt zum Projekt; dafür URL-Schema registrieren und `onOpenURL` im iOS-Root (heute ist `deploycenter://` auf iOS nicht registriert). (widgets/DeployWidget.swift:142, ios/Config/Info.plist)
504. [Feature] **Interaktiver Neu-laden-Knopf im Widget.** `Button(intent:)` (iOS 17+) holt frische Daten, ohne die App zu öffnen. (widgets/DeployWidget.swift:146–154)
505. [Feature] **Steuerelement im Kontrollzentrum.** iOS-18-`ControlWidget` „Deploy Center öffnen“ mit Zahl wartender PRs. (widgets/DeployWidget.swift:156–159)
506. [Feature] **Mitteilung mit Aktion „Deployen“.** `UNNotificationAction` mit `.authenticationRequired` öffnet direkt den bestätigten Deploy des Projekts. (ios/App/PhoneStore.swift:240–242)
507. [Feature] **Tippen auf Mitteilung öffnet das Projekt.** `userInfo` mit Projekt-Schlüssel und Auswahl in `RootView`. (ios/App/PhoneStore.swift:240)
508. [Feature] **Mitteilung, wenn der eigene Deploy fertig ist.** Ist die App beim Ende von `follow` nicht aktiv, eine lokale Mitteilung „live“/„fehlgeschlagen“. (ios/App/PhoneStore.swift:184–189)
509. [Feature] **App-Badge mit wartenden PRs.** `setBadgeCount` nach jedem Laden; die Erlaubnis `.badge` wird schon angefragt, aber nie genutzt. (ios/App/DeployCenterApp.swift:46)
510. [Feature] **Wartende Commits und PRs in der Detailansicht.** Die `compare`-Antwort enthält die Liste schon; Titel, Autor, Link zu GitHub anzeigen statt nur der Zahl. (ios/App/Clients.swift:259–273)
511. [Feature] **Links: Domain, Dashboard, GitHub-Vergleich.** In der Detailansicht Domain öffnen, Projekt bei Vercel/Render öffnen, `compare/live...head` auf GitHub. (ios/App/Views.swift:191–193)
512. [Feature] **Build-Log bei Fehlern.** Letzte Zeilen über die Vercel-Events- bzw. Render-Logs-API, wie im Mac-Detailfenster. (ios/App/Views.swift:176–222)
513. [Feature] **Laufenden Deploy abbrechen (Gleichstand, Mac kann es).** Vercel `PATCH /v12/deployments/{id}/cancel`, Render `POST /deploys/{id}/cancel`; nach Face ID. (ios/App/PhoneStore.swift:170)
514. [Feature] **Mehrere auf einmal deployen.** Auswahlmodus „Alle wartenden“ wie das Anhaken auf dem Mac, eine Face-ID-Abfrage für alle. (ios/App/Views.swift:81)
515. [Feature] **Suche und Filter.** `.searchable` über Namen/Repo und Filter nach Plattform. (ios/App/Views.swift:81–103)
516. [Feature] **Ausblenden und Anheften vom Mac übernehmen.** `hidden`/`pinned` der Mac-App über die bestehende Verknüpfung oder iCloud-KVS mitgeben. (shared/PhoneLink.swift:12–20)
517. [Feature] **Swipe-Aktionen.** Nach links „Deployen“, nach rechts „Domain öffnen“. (ios/App/Views.swift:96)
518. [Feature] **Render-Deploy mit Cache leeren.** Option `clearCache: "clear"` im Bestätigungsdialog für hängende Builds. (ios/App/Clients.swift:213–217)
519. [Feature] **Handoff Mac ↔ iPhone.** `NSUserActivity` für das ausgewählte Projekt, damit man auf dem anderen Gerät dort weitermacht. (ios/App/Views.swift:27–28)
520. [Feature] **Apple-Watch-Komplikation.** Ein watchOS-Widget mit der PR-Zahl aus demselben Snapshot-Format (shared/). (shared/DeploySnapshot.swift)
521. [Feature] **Ersparnis auch auf dem iPhone.** `saving` ist im iOS-Snapshot immer nil; den Wert der Mac-App über die Verknüpfung mitliefern, damit das mittlere Widget ihn zeigt. (ios/App/PhoneStore.swift:219)
522. [Feature] **Verlauf der letzten Deploys.** Pro Projekt die letzten 5 Production-Deploys mit Status und Dauer, Grundlage für einen gezielten Rollback auf einen bestimmten Stand. (ios/App/Clients.swift:153, 222)

## 5. Integrationen, Tests, CI, Release (147)
Stand: origin/main (aa128e9). Bereits Bekanntes aus IDEEN 1–5, CHANGELOG und git log ist weggelassen.


### Bugs – CLI-Paket, Release, Build

523. ✅ [Bug] **CLI-Tarball ohne `lib/`.** `package-cli.sh` packt nur deploys, VERSION, LICENSE, README und providers/. Damit fehlen bei install.sh- und Homebrew-Nutzern `lib/savings.sh`, `lib/team.sh` und `lib/githost.sh`: `simulate`/`ledger` brechen mit „lib/savings.sh is missing“ ab, GitLab wird nicht gelesen. `lib/` gehört in `paths` und in den Staging-Zweig. (scripts/package-cli.sh:43-46, :57-58; deploys:2177)
524. ✅ [Security] **Zwei-Personen-Regel fällt bei CLI-Installationen still weg.** Ohne `lib/team.sh` „still deploys, without the shared config and the two-person rule“. Ein Teammitglied mit brew/install.sh umgeht so `approvals` und die `observers`-Liste der Team-Datei, ohne es zu merken. Fehlt `lib/` und gibt es eine Team-Datei, sollte deploys hart abbrechen. (docs/TEAM.md:351; scripts/package-cli.sh:43)
525. ✅ [Bug] **Homebrew-Formel installiert `lib/` nicht.** Nur `deploys`, `VERSION` und `providers` landen in libexec. Selbst wenn der Tarball lib/ enthielte, fehlte es nach `brew install`. (scripts/homebrew-formula.sh:60-61)
526. ✅ [Bug] **`release.sh` prüft nur getrackte Änderungen.** `--untracked-files=no` lässt neue, nicht eingecheckte `app/*.swift`, `providers/*.sh` oder `lib/*.sh` zu, und `build.sh` übernimmt sie per Glob ins Release. Ein Release kann so Code enthalten, der in keinem Commit steht. (release.sh:95; build.sh:56, :87, :89)
527. ✅ [Bug] **MCP-Server im App-Bundle hängt vom lokalen Zustand ab.** `build.sh` kopiert `node_modules` nur, wenn sie zufällig da sind, und eine `.mcpb`-Datei, die kein Skript im Repo baut. Zwei Builds desselben Commits liefern so verschiedene Apps. (build.sh:93-100)
528. ✅ [Bug] **Signier-Zweige uneinheitlich.** Ohne `--widgets` werden `providers/*.sh` einzeln signiert, mit `--widgets` (dem Release-Weg) nicht, `lib/*.sh` nie. Einheitlich machen; Skripte unter Resources deckt ohnehin das Siegel des Bundles ab. (build.sh:209 gegenüber :222)
529. ✅ [Bug] **`--install` löscht erst und kopiert dann.** Scheitert `cp -R` (Platte voll, Rechte), ist die App weg. Besser in einen Temp-Ordner daneben kopieren und dann mit `mv` tauschen. (build.sh:249-250)
530. ✅ [Bug] **GitHub-Release ist öffentlich, bevor die Prüfsumme stimmt.** `gh release create` veröffentlicht sofort, erst danach kommt der SHA-Vergleich. Als `--draft` anlegen, prüfen, dann mit `gh release edit --draft=false` freigeben. (release.sh:181-192)
531. ✅ [Bug] **Mindest-macOS doppelt gepflegt.** `appcast.py` hat `--min-os 15.0` als Default, `build.sh` setzt `LSMinimumSystemVersion` selbst, und `release.sh` gibt den Wert nicht weiter. Hebt man das Minimum an, bietet Sparkle das Update Macs an, auf denen es nicht startet. (scripts/appcast.py:42; build.sh:145; release.sh:200)
532. ✅ [Bug] **`bump.sh` lässt Integrations-Versionen stehen.** MCP `VERSION`/package.json, plugin.json sowie die vscode- und raycast-Versionen bleiben bei jedem Release gleich. Die `sed`-Ersetzungen in site/index.html laufen außerdem ohne Treffer still durch. (scripts/bump.sh:30-35; integrations/mcp/server.mjs:23; integrations/claude-code/.claude-plugin/plugin.json:4)


### Bugs – MCP-Server

533. ✅ [Bug] **`keep: "tail"` liefert nicht das Log-Ende.** Ab `cap` (~145k Zeichen) wird nicht mehr gesammelt. `trim(..., "tail")` schneidet dann das Ende des *Anfangs* ab, bei großen Logs fehlt der echte Fehler. Für Logs einen Ringpuffer nutzen. (integrations/mcp/server.mjs:75-78, :98-99)
534. ✅ [Bug] **Abgeschnittenes JSON an den Agenten.** `deploys_changed`/`deploys_status` werden nach 20 000 Zeichen mitten im JSON gekappt, der Agent bekommt kaputtes JSON. Besser die Liste kompakt machen (Felder streichen) oder ganze Einträge weglassen und `truncated: n` anhängen. (integrations/mcp/server.mjs:113, :186, :193)
535. ✅ [Bug] **Unbekannte Argumente werden still ignoriert.** Das Low-Level-`Server` prüft das `inputSchema` nicht. `deploys_deploy {project, sha:"abc"}` deployt den neuesten Commit, und der Agent hält es für den gewünschten Stand; der Test „ledger passes no arguments on“ bestätigt das Verhalten. Unbekannte Schlüssel sollten ein Fehler sein. (integrations/mcp/server.mjs:341; integrations/tests/mcp.test.mjs:114-115)
536. ✅ [Security] **Build-Logs gehen ungefiltert an das Modell.** `deploys logs` maskiert nicht (anders als App, VS Code und Autofix), `deploys_logs` gibt den Text roh an den Agenten bzw. den LLM-Anbieter. Die Maskierung sollte im CLI liegen (`logs --masked`, Default bei Nicht-TTY) oder im MCP-Server. (integrations/mcp/server.mjs:221; deploys:1556-1562)
537. ✅ [Bug] **Deploy-Timeout klingt nach „nicht gestartet“.** Läuft `deploy-json` in den Timeout, steht im Text nur „was stopped“, der Build kann aber schon laufen. Ein Agent versucht es erneut und löst einen zweiten Build aus. Der Text sollte warnen, und der Server sollte vor einem neuen Versuch `status` lesen. (integrations/mcp/server.mjs:80, :104, :285)
538. ✅ [Bug] **`platform:name` geht beim Deploy nicht.** `NAME_RE` erlaubt `:`, aber `platformOf` vergleicht mit `p.name`. Ein Name auf zwei Plattformen lässt sich so nie deployen; die Meldung schickt in die App. `vercel:web` sollte die Plattform festlegen. (integrations/mcp/server.mjs:155-171)
539. ✅ [Bug] **Nur Vercel und Render deploybar.** Netlify, Cloudflare, Amplify, DigitalOcean, Coolify und Hook werden abgelehnt, obwohl `deploys deploy <p>` alle kann (samt Gruppen, Fenster und Freigaben). (integrations/mcp/server.mjs:283-284, :304)
540. ✅ [Bug] **Waisen beim Beenden.** Kinder laufen `detached` in eigener Prozessgruppe. Beendet der Client den Server, laufen `vercel`/`gh` weiter. Ein `SIGTERM`/`exit`-Handler sollte die laufenden Gruppen beenden. (integrations/mcp/server.mjs:74)
541. ✅ [Code] **`checkDays` und `checkLines` prüfen verschieden.** `lines: "80"` (String) wird angenommen, `days: "7"` abgelehnt. Eine Funktion für beide. (integrations/mcp/server.mjs:139-151)


### Bugs – Claude-Code-Plugin

542. ✅ [Bug] **Push-Hinweis zur falschen Zeit oder zum falschen Repo.** `*"git "*" push"*` trifft auch `git stash push`. Bei `git push --dry-run` und einem abgelehnten Push erscheint der Hinweis trotzdem. Bei `cd other && git push` und `git -C dir push` wird das Repo aus `cwd` gelesen. (integrations/claude-code/scripts/after-push.sh:26, :42)
543. ✅ [Bug] **GitLab-Repos bleiben stumm.** Die Regex kennt nur github.com, und `*/*/*` beendet sofort. GitLab wird laut GITLAB.md aber unterstützt (`.repo` = `gitlab.com/group/name`). (integrations/claude-code/scripts/after-push.sh:55-56)
544. ✅ [Bug] **`if: Bash(git push *)` trifft ein nacktes `git push` womöglich nicht.** Dann bliebe der häufigste Fall still. Testen oder zusätzlich `Bash(git push)` eintragen. (Vermutung) (integrations/claude-code/hooks/hooks.json:10)
545. ◐ [Bug] **MCP-Pfad zeigt aus dem Plugin heraus.** `deploys.mcp.json` nennt `/path/to/...`, und `server.mjs` liegt außerhalb von `integrations/claude-code`. Der Plugin-Cache enthält ihn nicht, ein Plugin-Nutzer hat so nie MCP. Gebündelt (esbuild, eine Datei) unter `${CLAUDE_PLUGIN_ROOT}` ausliefern. (integrations/claude-code/mcp/deploys.mcp.json:5)
546. ✅ [Bug] **Skills kennen nur Vercel und Render.** `deploys-ship` und `deploy-center` sagen `deploys vercel deploy`/`render deploy`; für Netlify und die anderen fehlt der Weg. `deploys deploy <project> --wait` nimmt alle Plattformen und prüft Fenster und Freigaben. (integrations/claude-code/skills/deploys-ship/SKILL.md:19-20; skills/deploy-center/SKILL.md:66-67)
547. ✅ [Bug] **„Nicht in der Liste“ heißt nicht „schon live“.** `changed --json` mit Exit 1 lässt unlesbare Projekte weg, `deploys-ship` meldet dann „already live“. Exit-Code und stderr prüfen. (integrations/claude-code/skills/deploys-ship/SKILL.md:12-13)
548. ✅ [Security] **Rule 1 nennt `deploys deploy <p>` und `--force` nicht.** Ausdrücklich verbieten: `deploys deploy`, `--force "…"` (öffnet ein geschlossenes Fenster und umgeht Freigaben), `autodeploy allow`, `guard`, `autofix --only`. (integrations/claude-code/skills/deploy-center/SKILL.md:19-21)


### Bugs – VS Code und Raycast

549. ✅ [Bug] **Timeout trifft nur den direkten Kindprozess.** `execFile` mit `killSignal` beendet bash, nicht `vercel`/`gh`/`curl` dahinter. Der MCP-Server hat das mit Prozessgruppen schon gelöst; dasselbe hier übernehmen. (integrations/vscode/src/cli.ts:72; integrations/raycast/src/lib/deploys.ts:173-178)
550. ✅ [Bug] **VS Code maskiert weniger als App und CLI.** Es fehlen GitLab (`glpat-`), Stripe (`sk_live_`/`rk_live_`, das `sk-`-Muster trifft sie nicht), Google (`AIza`), npm (`npm_`), Anthropic (`sk-ant-` nur zufällig), private Schlüsselblöcke und `--token x`, die AUTOFIX.md für die Maskierung nennt. (integrations/vscode/src/log.ts:21-31)
551. ✅ [Bug] **Raycast kennt nur zwei Plattformen.** `platform: "vercel" | "render"`, Icon und Tag fallen für alles andere auf Render-Lila bzw. das rohe Wort zurück. `deploy-json` wird mit dem rohen Plattformnamen aufgerufen. VS Code ist auf 0.2.0 schon umgestellt. (integrations/raycast/src/lib/deploys.ts:10, :27, :255; src/lib/ui.tsx:87-95)
552. ✅ [Bug] **Raycast nutzt den nackten Namen für notes/open/Deploy Center.** Ist der Name auf zwei Plattformen, trifft es das falsche Projekt; VS Code nimmt `platform:name`. (integrations/raycast/src/lib/ui.tsx:103, :116, :189)
553. ◐ [Bug] **Sammel-Deploy ohne Reihenfolge.** Raycast „Deploy All“ und VS Code „Deploy … of this repo“ starten der Reihe nach, ohne „Backend vor Frontend“, ohne Gruppen und ohne `--when-green`. `deploys deploy-changed --yes --json` (bzw. mit Namensfilter) nutzen. (integrations/raycast/src/deploy-all-changed.tsx:16-25; integrations/vscode/src/extension.ts:246)
554. ✅ [Bug] **Raycast lädt nach „Deploy All“ nicht neu.** Die Liste bleibt, „Deploy All“ bleibt aktiv. Ein zweiter Druck nach über 60 s (Ende der Start-Sperre) startet alles noch einmal. (integrations/raycast/src/deploy-all-changed.tsx:47-54)
555. ✅ [Bug] **Raycast hält „#401“ in einem Commit für einen Login-Fehler.** `failure()` klassifiziert `stderr + stdout`, und `\b(401|403)\b` trifft auch Commit-Texte und Projektnamen. Nur stderr prüfen und nach „HTTP 401“ suchen. (integrations/raycast/src/lib/deploys.ts:153, :211)
556. ✅ [Bug] **VS Code verliert eine Aktualisierung nach Einstellungsänderung.** Läuft `refresh()` gerade, gibt ein neuer Aufruf das alte Promise zurück, und die neue Einstellung (scope, cliPath) wirkt erst beim nächsten Takt. (integrations/vscode/src/extension.ts:82-85, :328-333)
557. ✅ [Bug] **VS Code „Show log“ löscht den Ausgabekanal.** `output.clear()` wirft frühere Warnungen und Deploy-Ergebnisse weg. Das Log besser als eigenes, schreibgeschütztes Dokument öffnen. (integrations/vscode/src/extension.ts:267)
558. ✅ [Bug] **`repoSlug` kennt keinen Host.** `github.com/me/app` und `gitlab.com/x/me/app` gelten als gleich, GitLab-Untergruppen werden auf zwei Teile gekürzt. Der Kommentar „the CLI only knows GitHub“ ist seit GitLab-Support falsch. (integrations/vscode/src/repo.ts:20-21)


### Bugs – Action, Beispiele, Digest, Hooks, Badge

559. ✅ [Bug] **`examples/daily-deploy.yml` lädt nur die Datei `deploys`.** Seit providers/ (und lib/) bricht das Skript ohne diese Ordner sofort ab; das Beispiel geht nur, weil es auf v0.7.0 festhängt. Besser `install.sh --version` bzw. den Release-Tarball mit `sha256sum -c` nutzen. (examples/daily-deploy.yml:35, :42)
560. ✅ [Bug] **`daily-deploy.yml` ohne `permissions:`, mit `vercel@latest` und `${{ }}` im Skript.** Ungepinnte CLI, Standardrechte für das Token, Ausdrücke direkt in `run:`, obwohl das Projekt das sonst verbietet. (examples/daily-deploy.yml:25-52)
561. ✅ [Bug] **Der Action-Deploy-Schritt deployt das ganze Konto.** `deploy-changed --yes` startet jedes geänderte Projekt aller Repos, und ein `[deploy]`-Commit in Repo A deployt auch B bis Z. Ein Eingang `projects`/`repo` (Filter) fehlt. (integrations/action/action.yml:130; integrations/action/examples/deploy-on-marker.yml:30)
562. ✅ [Bug] **Action zerlegt Klartext statt JSON.** `grep '^[0-9]+ started'` bricht bei jeder Textänderung; `deploy-changed --json` gibt es. (integrations/action/action.yml:132-133)
563. ✅ [Bug] **`deploy-on-marker.yml` ohne `concurrency`.** Zwei schnelle Pushes mit `[deploy]` starten zwei `deploy-changed --yes` gleichzeitig. (integrations/action/examples/deploy-on-marker.yml:21-24)
564. ✅ [Bug] **Digest lässt eine alte Freigabe offen.** Ist heute nichts mehr offen (`names_csv` leer), wird das Tages-Issue weder aktualisiert noch geschlossen. Ein später gesetztes `deploy-approved` deployt dann die Liste von heute früh mit inzwischen neuen Commits. (integrations/digest/digest.sh:154)
565. ✅ [Security] **Freigabeliste steht im bearbeitbaren Issue-Text.** `approve-deploy.yml` liest `<!-- deploys-approve: … -->` aus dem Body. Wer Schreibrechte hat, kann ihn zwischen Digest und Label auf `all` ändern, und der Freigebende sieht das nicht. Body-Hash im Digest-Kommentar speichern oder die Liste aus einem Kommentar des Bots lesen. (integrations/digest/examples/approve-deploy.yml:53)
566. ✅ [Bug] **`approve-deploy` verweigert `platform:name`.** Die Regex lässt kein `:` zu. Gleichnamige Projekte auf zwei Plattformen werden beide deployt (Ignore arbeitet nur mit Namen) oder lassen sich nicht einzeln freigeben. (integrations/digest/examples/approve-deploy.yml:60, :87-90)
567. ✅ [Bug] **pre-push liest nur Vercel und Render.** Netlify, Cloudflare und andere mit eingeschaltetem Auto-Build werden nie gewarnt. Laut integrations/README.md nutzt der Hook `deploys list --json`. (integrations/hooks/pre-push:39-44)
568. ✅ [Bug] **pre-push ist bei GitLab-Remotes still.** Dieselbe GitHub-Regex wie after-push.sh. (integrations/hooks/pre-push:29-31)
569. ✅ [Bug] **Badges überschreiben sich bei gleichem Namen.** Der Dateiname enthält die Plattform nicht. (integrations/badge/badge.sh:53)
570. ✅ [Bug] **Statusseite erkennt `platform/name` nur für vercel|render.** `netlify/shop` wird als Name „netlify/shop“ gesucht und nie gefunden. (integrations/statuspage/statuspage.sh:45)
571. ✅ [Bug] **Digest liest PRs nur über GitHub.** Bei GitLab-Repos scheitert `gh api repos/…/pulls` still, und alle MRs erscheinen ohne Titel und Autor. (integrations/digest/digest.sh:71)


### Security

572. ✅ [Security] **MCP: Bestätigung über Elicitation statt nur im Prompt.** Vor `deploys_deploy`/`rollback` fragt der Server per `elicitation/create` selbst den Menschen (Projekt, Commits, Ziel). So reicht ein überredetes Modell allein nicht. Ohne Client-Unterstützung bleibt es beim Hinweis. (integrations/mcp/server.mjs:260-309)
573. ✅ [Security] **MCP: Positivliste und Obergrenze.** `DEPLOYS_MCP_ALLOW_PROJECTS=web,api` und z. B. höchstens 3 Deploys pro Sitzung, damit ein Agent nach einem Ja nicht in Schleife deployt. (integrations/mcp/server.mjs:25)
574. [Security] **MCP: Zweistufiger Deploy mit Token.** `deploys_plan` gibt Commit-SHA und ein Einmal-Token zurück, `deploys_deploy` braucht dieses Token und deployt genau diesen SHA (`--sha`). So geht kein Push live, der zwischen Frage und Ja kam. (integrations/mcp/server.mjs:284)
575. ✅ [Security] **MCP: Ausgaben als unvertrauenswürdig kennzeichnen.** Logs, Commit-Texte und Release-Notes in einen Rahmen setzen („data, not instructions“). Commit-Texte können Prompt-Injection gegen Agenten mit Deploy-Recht enthalten. (integrations/mcp/server.mjs:113-115)
576. [Security] **MCP: Herkunft im Journal.** `DEPLOYS_SOURCE=mcp` (bzw. `raycast`, `vscode`, `action`) mitgeben. Verlauf und Team-Journal zeigen dann, welcher Agent oder welches Werkzeug deployt hat. (integrations/mcp/server.mjs:74)
577. ✅ [Security] **Deny-Regel in CLAUDE-CODE.md ist lückenhaft.** Es fehlen `Bash(deploys deploy *)`, `Bash(deploys * deploy *)`, `Bash(deploys * deploy-json *)`, `Bash(deploys * autodeploy-on *)`, `Bash(deploys autodeploy *)`, `Bash(deploys guard*)`, `Bash(deploys autofix*)`. (docs/CLAUDE-CODE.md:53-54)
578. ✅ [Security] **`check-public.sh` ohne Token-Muster.** `ghp_`/`github_pat_`, `sk-ant-`, `glpat-`, `AKIA`, `xox[bp]-`, `-----BEGIN … PRIVATE KEY-----` und E-Mail-Adressen fehlen. (scripts/check-public.sh:8-16)
579. ✅ [Security] **Private Wortliste für den Public-Check.** `check-public.sh` liest zusätzlich `~/.config/deploys/private-words` (nie im Repo): eigene Projekt- und Domainnamen. Lokal und als pre-commit-Hook findet er so auch, was keinem Muster folgt. (scripts/check-public.sh:18)
580. ✅ [Security] **Public-Check auch für Commit-Texte.** Im PR `git log BASE..HEAD --format=%B` prüfen: Namen und Pfade landen oft in Commit-Nachrichten, nicht in Dateien. (.github/workflows/ci.yml:25-26)
581. ✅ [Security] **`pages.yml` mit Tag statt SHA und ohne `persist-credentials: false`.** ci.yml pinnt per SHA, die Website-Pipeline mit `pages: write`/`id-token: write` nicht. (.github/workflows/pages.yml:37, :44-49)
582. ✅ [Security] **Beispiele mit `actions/checkout@v4` und ohne `persist-credentials: false`.** In der Ship-Check-Vorlage hat Claude Bash-Zugriff, das Checkout-Token liegt dann in `.git/config`. (examples/claude-pr-ship-check.yml:41; examples/daily-deploy.yml:37)
583. ✅ [Security] **`GITLAB_TOKEN` im Schlüsselbund statt in `~/.zprofile`.** Wie `render set-key` gehört ein `deploys gitlab set-token` dazu; die Doku rät heute zu einem Klartext-Token im Shell-Profil. (docs/GITLAB.md:30-46)
584. ✅ [Security] **Raycast-Publish mit `npx @raycast/api@latest`.** Ungepinnt, die Version aus devDependencies nutzen. (integrations/raycast/package.json:465)
585. ✅ [Security] **Docker-Basis nicht per Digest gepinnt, `gh` aus Debian veraltet.** `node:22-bookworm-slim@sha256:…` und `gh` aus dem offiziellen Apt-Repo. (integrations/docker/Dockerfile:6, :12)
586. ✅ [Security] **`webhook_send` nimmt `http://` an.** Die Meldung sagt „must start with https://“, das `case` erlaubt aber `http://*`; Telegram-Tokens gingen so im Klartext raus. Nur für localhost erlauben. (integrations/lib/post.sh:48)


### CI

587. [CI] **`integrations/tests/run.sh` läuft nie in CI.** MCP-Tests, `tests/claude-code.sh`, Action-Schritte, Digest und Hooks sind nur lokal getestet. Ein Job mit node und `npm ci` in `integrations/mcp` fehlt. (.github/workflows/ci.yml:33-40)
588. [CI] **Übersprungene Tests zählen als bestanden.** `run.sh` schreibt „skip mcp“/„skip vscode“ und meldet „All passed.“. In CI sollte `REQUIRE_ALL=1` ein Skip zum Fehler machen. (integrations/tests/run.sh:252-257, :309-315)
589. ◐ [CI] **Raycast ohne CI.** `npm ci`, `tsc --noEmit`, `ray lint` und `ray build` in einem Job; Typfehler fallen heute erst beim Store-Einreichen auf. (.github/workflows/ci.yml:67-85)
590. ✅ [CI] **shellcheck lässt `integrations/**` aus.** Nicht geprüft: after-push.sh, `hooks/pre-push`, digest.sh, classify.sh, notify.sh, badge.sh, statuspage.sh, `lib/post.sh`, `integrations/tests/run.sh`. (.github/workflows/ci.yml:31)
591. ◐ [CI] **actionlint ohne die Beispiele.** `examples/*.yml`, `integrations/*/examples/*.yml` und (per `action-validator`) `integrations/action/action.yml` werden nicht geprüft. Genau die kopieren Nutzer. (.github/workflows/ci.yml:28)
592. ◐ [CI] **Widgets werden in CI nie gebaut.** `./build.sh` läuft ohne `--widgets`, das Release aber immer mit. Ein Fehler in `widgets/*.swift` fällt erst beim Release auf. (.github/workflows/ci.yml:42; release.sh:121)
593. [CI] **Skript-Tests nur auf macOS.** Laut Changelog läuft das CLI auch unter Linux, die Ubuntu-Jobs prüfen aber nur install.sh. `tests/script-tests.sh` und `team-tests.sh` gehören auch auf ubuntu-latest. (.github/workflows/ci.yml:49-65)
594. ✅ [CI] **Changelog-Pflicht ignoriert providers/, lib/, integrations/.** Das Muster ist nur `^(deploys|app/)`. (.github/workflows/ci.yml:118)
595. ✅ [CI] **`check-site.py` läuft nirgends.** JSON-LD-, Meta- und Sitemap-Prüfung im docs-Job ergänzen oder mit check-links zusammenlegen. (scripts/check-site.py:1-8; .github/workflows/ci.yml:87-100)
596. ✅ [CI] **Brew ohne Cache und mit Auto-Update.** `HOMEBREW_NO_AUTO_UPDATE=1` und `HOMEBREW_NO_INSTALL_CLEANUP=1` sparen pro Lauf eine bis zwei Minuten macOS-Zeit, die zehnfach berechnet wird. (.github/workflows/ci.yml:23-24)
597. ✅ [CI] **setup-node ohne npm-Cache.** `cache: npm` mit `cache-dependency-path`. (.github/workflows/ci.yml:79-82)
598. ✅ [CI] **Xcode-Version nicht festgelegt.** `macos-15` wechselt das Standard-Xcode. Ein `xcode-select -s /Applications/Xcode_16.x.app` macht Typprüfer-Timeouts und Swift-Warnungen reproduzierbar. (.github/workflows/ci.yml:17)
599. ✅ [CI] **Docker-Image wird nie gebaut.** Ein `docker build` plus `docker run … --version` im Ubuntu-Job hätte z. B. einen falschen `COPY`-Pfad erkannt. (integrations/docker/Dockerfile)
600. ✅ [CI] **Python-Skripte ohne Lint.** `ruff check scripts/*.py` (build-docs.py hat 700 Zeilen). (scripts/build-docs.py)
601. ✅ [CI] **Dependabot nur für Actions.** npm in `integrations/mcp`, `integrations/vscode` und `integrations/raycast` fehlt, ebenso Docker. Das MCP-SDK ist exakt gepinnt und wird nie angehoben. (.github/dependabot.yml:4)
602. ✅ [CI] **Abhängigkeiten der Integrationen auditieren.** `npm audit --omit=dev --audit-level=high` für mcp (es wird mit `node_modules` in die App gebündelt). (integrations/mcp/package.json:12-14)
603. ✅ [CI] **pages.yml ohne `timeout-minutes`.** Der IndexNow-Schritt hat eines, der Job nicht. (.github/workflows/pages.yml:31-36)


### Tests

604. ✅ [Test] **Tarball-Inhalt vollständig prüfen.** install-tests.sh prüft nur providers/. Ein Test „jede Datei, die deploys per `deploys_dir`/`DEPLOYS_DIR` sourct, ist im Tarball und in der Formel“ hätte den lib/-Fehler gefunden. (tests/install-tests.sh:28-31)
605. ✅ [Test] **MCP: fehlende Fälle.** Unbekannte Argumente, Name auf zwei Plattformen, `platform:name`, Rollback eines unbekannten Projekts, Timeout während `deploy-json`, Tail bei Ausgaben über `cap`, JSON-Kürzung. (integrations/tests/mcp.test.mjs:164-196)
606. [Test] **after-push: fehlende Fälle.** `git stash push`, `git push --dry-run`, `cd x && git push`, `git -C dir push`, GitLab-Remote. (integrations/tests/run.sh:271-307)
607. [Test] **Gemeinsame Secret-Fixture für alle Maskierer.** Eine Datei `tests/fixtures/secrets.txt` mit Erwartung, gegen die Swift (LogTools), TypeScript (vscode/log.ts) und bash (`af_mask`) laufen. So driften die drei Listen nicht auseinander. (integrations/vscode/src/log.ts:21; deploys:704)
608. ✅ [Test] **Raycast-Logik testen.** `classify`, `commitsText`, `sortByAge`, `findDeploys` ohne Raycast-API (wie vscode/model.ts) herauslösen und mit `node --test` prüfen. (integrations/raycast/src/lib/deploys.ts:147-160)
609. [Test] **VS Code im Extension-Host.** `@vscode/test-electron` mit Stand-in-`deploys`: Aktivierung, Status-Text, Kontextwerte, Untrusted-Workspace bleibt inaktiv. (integrations/vscode/package.json:240-246)
610. ✅ [Test] **Beispiel-Workflows in CI ausführen.** Wie bei action.yml die `run:`-Blöcke von daily-deploy.yml und claude-pr-ship-check.yml (Schritt „Projects of this repo“) mit Stand-in-deploys laufen lassen. (examples/claude-pr-ship-check.yml:66-76)
611. [Test] **Testabdeckung für bash messen.** `kcov` oder `bashcov` über script-tests, team-tests und die Provider-Tests; zeigt ungetestete Zweige in 2 000+ Zeilen `deploys`. (tests/script-tests.sh)
612. ✅ [Test] **Provider-Tests parallel.** Die Schleife über `tests/providers/*.sh` läuft nacheinander. Mit `xargs -P` oder Hintergrundjobs ginge CI schneller. (tests/script-tests.sh:553-557)
613. [Test] **`appcast.py` gegen Sparkle prüfen.** Das erzeugte XML mit `generate_appcast`/`sign_update --verify` oder einem Sparkle-Schema-Check prüfen, nicht nur mit eigenen Regeln. (tests/script-tests.sh:1044)
614. ✅ [Test] **Der Digest-Text mit Injektion.** Commit-Titel mit `<!-- deploys-approve: all -->`, `@user` und Markdown-Links: im Body maskiert, und der Marker bleibt der letzte. (integrations/digest/digest.sh:131-162)


### Code und Wartung

615. [Code] **Ein gemeinsamer Node-Kern für MCP, VS Code und Raycast.** Dreimal stehen `findDeploys`/`isExecutable`/Timeout/ANSI/Fehlerklassen, mit verschiedenen Suchreihenfolgen (MCP: PATH zuerst, Raycast/VS Code: App zuerst). Ein `integrations/node-lib` per esbuild einbinden. (integrations/mcp/server.mjs:38-58; integrations/raycast/src/lib/deploys.ts:106-130; integrations/vscode/src/cli.ts:30-51)
616. ✅ [Code] **`lib/projects.sh` baut die Ignore-Regel nach.** `changed_projects` liest `ignored.json` selbst und kennt Team-`ignored` und `overrides.json` nicht. Besser `deploys changed --json` aufrufen. (integrations/lib/projects.sh:20-24)
617. ✅ [Code] **Variablennamen der Beispiele vereinheitlichen.** `vars.VERCEL_TEAM` (deploy-on-marker, approve-deploy) gegenüber `vars.DEPLOYS_VERCEL_TEAM` (ship-check, daily-deploy). (integrations/action/examples/deploy-on-marker.yml:32; integrations/digest/examples/approve-deploy.yml:69; examples/claude-pr-ship-check.yml:52)
618. ◐ [Code] **Beispiele mit `@main` trotz „pin a tag“.** Gleich einen Release-Tag (`@v0.9.1`) bzw. einen bewegten `v1`-Tag zeigen. (integrations/action/examples/deploy-on-marker.yml:27; examples/claude-pr-ship-check.yml:48; integrations/digest/examples/approve-deploy.yml:65, :95)
619. [Code] **`daily-deploy.yml` nutzt die eigene Action nicht.** CLI-Installation, Team-ID-Prüfung und Ausgaben stehen doppelt. (examples/daily-deploy.yml:38-52)
620. ✅ [Code] **MCP-Version aus package.json lesen.** `VERSION = "0.1.0"` ist hart codiert. (integrations/mcp/server.mjs:23)
621. [Code] **MCP-Server mit esbuild in eine Datei bündeln.** Statt `node_modules` (Hunderte Dateien) ins App-Bundle zu kopieren: weniger Signier- und Notarisierungsaufwand, kleinerer Download, reproduzierbar. (build.sh:93-97)
622. [Code] **`.mcpb` im Repo bauen.** Ein `scripts/build-mcpb.sh` mit `manifest.json`, damit build.sh die Datei nicht nur zufällig findet. (build.sh:98-100)
623. ◐ [Code] **Ein Werkzeug für alle Versionen.** `scripts/bump.sh` setzt auch package.json (mcp, vscode, raycast), plugin.json, marketplace.json und `VERSION` im MCP; ein CI-Check meldet, wenn sie auseinanderlaufen. (scripts/bump.sh:30)
624. ✅ [Code] **Kosten-Hinweis im Ship-Check: kleineres Modell.** Für einen 15-Zeilen-Kommentar reicht ein Sonnet- oder Haiku-Modell. Ausgerechnet ein Kosten-Spar-Werkzeug sollte nicht standardmäßig das teuerste Modell nehmen. (examples/claude-pr-ship-check.yml:99)
625. ✅ [Code] **`timeout-minutes` in den Beispielen.** ship-check und daily-deploy haben keins; ein hängendes `deploys` läuft sonst bis zu sechs Stunden (Default-Limit) auf Kosten des Nutzers. (examples/claude-pr-ship-check.yml:37-40; examples/daily-deploy.yml:26-28)
626. [Code] **Action: Vercel-CLI cachen.** `npm install -g vercel@…` läuft bei jedem Lauf; ein `actions/cache` auf das npm-Prefix spart 20–40 s pro Lauf. (integrations/action/action.yml:89-92)


### UX und Doku

627. ✅ [UX] **Doku-Widerspruch zu Autofix.** SAFE-DEPLOY.md spricht von „An autofix redeploy runs deploy-json“, und die plist-Vorlage sagt „and deploy a merged fix“. Laut AUTOFIX.md deployt Autofix nie. (docs/SAFE-DEPLOY.md:130; scripts/autofix.plist.example:2)
628. ✅ [UX] **CLAUDE.md-Block nur für Vercel/Render.** `deploys deploy <project> --wait` nennen, das für alle Anbieter gilt und Fenster, CI und Freigaben prüft. (docs/CLAUDE-CODE.md:42-43)
629. ✅ [UX] **Plattform-Wunsch-Vorlage listet Vorhandenes.** Netlify, Cloudflare Pages, Amplify und Deploy-Hook gibt es schon. Ersetzen durch Fly.io, Railway, Heroku, Firebase Hosting, Azure Static Web Apps, Kamal. (.github/ISSUE_TEMPLATE/platform-request.yml:16-21)
630. ✅ [UX] **Bug-Vorlage ohne Integrationen.** Unter „Where“ fehlen VS Code, Raycast, MCP, Claude-Code-Plugin, GitHub Action, Widgets und iPhone. (.github/ISSUE_TEMPLATE/bug.yml:28-32)
631. ✅ [UX] **PR-Vorlage nennt nur zwei Testskripte.** Ergänzen: `integrations/tests/run.sh`, `tests/team-tests.sh`, `scripts/check-public.sh`, `npm test` in vscode. (.github/PULL_REQUEST_TEMPLATE.md:7)
632. ✅ [UX] **Hinweis zum hängenden Render-Key prüfen.** integrations/README sagt, `render list --json` „currently does not come back“ bei falschem Key. Laut #42 ist die Endlosschleife behoben; den Satz prüfen und entfernen oder belegen. (Vermutung) (integrations/README.md:30-31)
633. ✅ [UX] **Guard und Autofix nur für Vercel und Render.** Netlify, Cloudflare und Amplify können Auto-Build ebenfalls wieder einschalten, und ihre Fehlbuilds fehlen in Autofix. Die Doku sagt es nur nebenbei; entweder dokumentieren oder ausbauen. (docs/GUARD.md:59-60; docs/AUTOFIX.md:14)
634. ✅ [UX] **VS Code bietet „Deploy…“ ohne Änderungen an.** Statt nur einer Warnung im Dialog den Eintrag ausgrauen bzw. ans Ende setzen; ein Fehlklick kostet sonst einen Build. (integrations/vscode/src/extension.ts:195, :220)
635. ✅ [UX] **Raycast ohne Zwischenspeicher.** `usePromise` lässt beim Öffnen bis zu zwei Minuten leer. `useCachedPromise` zeigt die letzte Liste sofort und lädt im Hintergrund. (integrations/raycast/src/waiting-deploys.tsx:8; src/deploy-status.tsx:34)
636. ✅ [UX] **Raycast „Deploy Status“ ohne Build-Log.** Bei fehlgeschlagenen Builds fehlt „Show Log“ bzw. „Copy for AI“ (beides kann VS Code). (integrations/raycast/src/deploy-status.tsx:24-28)
637. ✅ [UX] **Digest-Issue pingt Leute.** `@login` in Commit-Titeln und PR-Titeln erzeugt Benachrichtigungen im Tages-Issue. `@` durch `@​` oder Backticks entschärfen. (integrations/digest/digest.sh:131-133)
638. ✅ [UX] **notify und digest nur in UTC.** `DEPLOYS_TZ` (oder `TZ`) für „heute“ und die Überschrift. (integrations/notify/notify.sh:15, :35; integrations/digest/digest.sh:55)


### Features – bestehende Integrationen ausbauen

639. [Feature] **MCP: weitere Lese-Werkzeuge.** `deploys_risk`, `deploys_window`, `deploys_ci`, `deploys_history`, `deploys_details`. Damit kann der Agent vor der Frage „Deploy?“ Risiko, Fenster und CI nennen. (integrations/mcp/server.mjs:179-258)
640. [Feature] **MCP: `deploys_wait`.** Wartet auf einen gestarteten Deploy (id) bis live oder fehlgeschlagen, mit MCP-Progress-Meldungen. Heute muss der Agent pollen. (integrations/mcp/server.mjs:286-290)
641. [Feature] **MCP: Resources und Prompts.** `deploys://changed` und `deploys://status` als Ressourcen, die der Client abonnieren kann, und ein Prompt `ship <project>`, der den Ablauf Notes → Frage → Deploy vorgibt. (integrations/mcp/server.mjs:317)
642. [Feature] **MCP: Fortschritt für simulate/ledger.** Bei Läufen über eine Minute `notifications/progress` senden, damit Clients nicht abbrechen. (integrations/mcp/server.mjs:245, :256)
643. [Feature] **Action: Eingänge `projects`, `when-green`, `wait`.** Durchreichen an `deploy-changed --when-green --wait`, dazu eine Tabelle in `GITHUB_STEP_SUMMARY` mit `started|skipped|failed` je Projekt aus `--json`. (integrations/action/action.yml:10-42)
644. [Feature] **Action: `repo-only: true`.** Nur Projekte, deren `.repo == github.repository`. Das passt zur Erwartung „dieser Push deployt dieses Repo“. (integrations/action/action.yml:104)
645. [Feature] **GitLab-CI-Vorlage.** `.gitlab-ci.yml` mit dem Docker-Image: geplanter Deploy und manueller Job mit `when: manual` als Freigabe. Seit GitLab Quelle ist, fehlt das Gegenstück zur Action. (docs/GITLAB.md)
646. [Feature] **Guard und Autofix als GitHub-Actions-Vorlage.** Beide laufen nur, „while this Mac is awake“. Eine Cron-Vorlage mit dem Docker-Image macht sie unabhängig vom Laptop. (docs/GUARD.md:54; docs/AUTOFIX.md:105)
647. [Feature] **Digest mit GitLab-MRs.** `pr_facts` über `githost` statt fest `gh api`. (integrations/digest/digest.sh:67-75)
648. [Feature] **Freigabe auf SHA festnageln.** Der Digest schreibt pro Projekt den Kopf-SHA in den Marker, und `approve-deploy` deployt mit `--sha`. Dann geht nur live, was der Freigebende gesehen hat, nicht der Stand bei Freigabe. (integrations/digest/examples/approve-deploy.yml:8; integrations/digest/digest.sh:162)
649. [Feature] **Badge als shields.io-Endpoint.** Zusätzlich eine `<name>.json` im Endpoint-Format; dann lassen sich Stil, Logo und Cache über shields.io steuern. (integrations/badge/badge.sh:53-69)
650. [Feature] **Raycast: Menüleisten-Befehl.** `mode: "menu-bar"` mit der Zahl wartender Projekte und Schnell-Deploy nach Bestätigung, als Alternative für Leute ohne die App im Hintergrund. (integrations/raycast/package.json:406-428)
651. [Feature] **Raycast: AI-Tools.** `tools` im Manifest (`get-waiting`, `get-status`, `deploy` mit `confirmation`), damit Raycast AI „was wartet?“ beantworten kann und vor dem Deploy die Raycast-Bestätigung erzwingt. (integrations/raycast/package.json)
652. [Feature] **VS Code: Language-Model-Tools.** `vscode.lm.registerTool` für „waiting“, „status“ und „logs“, damit Copilot-Agent und Cursor ohne extra MCP-Konfiguration Zugriff haben; Deploy nur mit `prepareInvocation`-Bestätigung. (integrations/vscode/src/extension.ts:311)
653. [Feature] **VS Code: Log als Dokument mit Fehlersprung.** Ein virtuelles Dokument `deploycenter-log:` mit Syntax-Hervorhebung und „Go to first error“, gleiche Regel wie `firstErrorBlock`. (integrations/vscode/src/log.ts:48)
654. [Feature] **Claude-Code-Plugin: Statuszeile.** Ein `statusLine`-Schnipsel (`deploys changed --json` mit Cache) zeigt „⏳ 3 waiting“ dauerhaft in der Sitzung. (integrations/claude-code/README.md)
655. [Feature] **Plugin: Hook vor gefährlichen Befehlen.** Ein `PreToolUse`-Hook fragt bei `deploys … deploy|rollback|--force|autodeploy` immer nach (`permissionDecision: "ask"`), auch wenn der Nutzer Bash pauschal erlaubt hat. (integrations/claude-code/hooks/hooks.json)
656. [Feature] **MCP-Server als npm-Paket.** `npx -y deploys-mcp` statt `/path/to/…/server.mjs`; die Einrichtung in Claude Code, Cursor und Desktop wird ein Einzeiler. (integrations/mcp/package.json:6; integrations/mcp/README.md:34)
657. [Feature] **Docker-Image auf GHCR, multi-arch.** Beim Release `linux/amd64,arm64` bauen und taggen; die Beispiele nutzen dann `container:` statt Downloads. (integrations/docker/README.md)
658. [Feature] **Release automatisiert auch die Integrationen.** VS Code (`vsce publish`, `ovsx publish`) und Raycast als manueller Workflow mit Secrets, ausgelöst durch einen Tag `vscode-v*`. (integrations/vscode/PUBLISHING.md; integrations/raycast/PUBLISHING.md)
659. [Feature] **Sparkle-Beta-Kanal.** `sparkle:channel` für Vorabversionen, damit Neues erst bei Freiwilligen landet. (scripts/appcast.py:70-85)
660. [Feature] **Statusseite für alle Anbieter.** `platform/name` für jeden Provider (Liste aus `deploys list --json`) und das Plattform-Label im HTML. (integrations/statuspage/statuspage.sh:45)


### Features – neue Integrationen

661. [Feature] **GitHub App mit Check-Run „Waiting to deploy“.** Am Merge-Commit ein neutraler Check „nicht live, 3 Commits warten“, der grün wird, sobald der Stand live ist. Sichtbar direkt im PR, ohne die App.
662. [Feature] **`gh`-Erweiterung `gh deploys`.** Ein dünner Wrapper (`gh extension install …`) zeigt `changed`/`notes` fürs aktuelle Repo, für Leute, die eh in `gh` arbeiten.
663. [Feature] **Stream-Deck-Plugin.** Eine Taste zeigt die Zahl wartender Projekte und den Build-Status (rot/gelb/grün); Lang-Drücken deployt die Gruppe nach Bestätigung auf dem Mac.
664. [Feature] **JetBrains-Plugin.** Statusleisten-Widget und Tool-Window wie bei VS Code (dieselben CLI-Aufrufe); IntelliJ, WebStorm und PyCharm decken viele Backend-Teams ab.
665. [Feature] **Zed-Erweiterung.** Zed bindet MCP-Server als „context server“ ein; eine Erweiterung, die den gebündelten MCP-Server startet, bringt Deploy Center in den Zed-Agenten.
666. [Feature] **Linear/Jira: „deployed“ markieren.** Issues, die in den gerade live gegangenen Commits stehen (`ABC-123`, `Fixes #12`), bekommen einen Kommentar bzw. einen Status „Released“. Dann sehen auch Kunden-Teams, was live ist.
667. [Feature] **GitHub Deployments API.** Nach jedem Deploy aus Deploy Center ein `deployment` und einen `deployment_status` am Commit anlegen. Die GitHub-Oberfläche („Environments“) zeigt dann, was live ist, wie bei Auto-Deploy.
668. [Feature] **Cursor-/Windsurf-Regeldatei.** Analog zum CLAUDE.md-Block eine `.cursor/rules/deploys.mdc` bzw. AGENTS.md-Vorlage mit denselben Sicherheitsregeln. (docs/CLAUDE-CODE.md:22-43)
669. [Feature] **SwiftBar-/xbar-Skript.** Für Nutzer, die nur das CLI ohne App haben, ein Menüleisten-Plugin aus `deploys changed --json` (eine Datei in integrations/).

## 6. Website, Doku, README, Datenschutz (140)
Geprüft: `site/`, `README.md`, `README.de.md`, `README-CLI.md`, `CONTRIBUTING.md`, `SECURITY.md`, `CODE_OF_CONDUCT.md`, `docs/*.md` (ohne IDEEN*), `docs/providers/*.md`, `scripts/build-docs.py`. `marketing/` ist per `.gitignore` ausgeschlossen (0 getrackte Dateien), deshalb nicht geprüft. Bekanntes aus IDEEN 1–5, CHANGELOG und git log ist weggelassen.


### Fehler: Texte widersprechen dem Stand der App

670. ✅ [Bug] **Die README-Roadmap führt Gebautes als offen.** Netlify, Cloudflare Pages, AWS Amplify, Deploy-Hook, MCP-Server, Raycast, Linux-Paket (install.sh, Formel) und Team-Sync sind laut CHANGELOG fertig. Abhaken oder durch echte nächste Schritte ersetzen. (README.md:140-147, README.de.md:118-125)
671. ✅ [Bug] **„Coming: an MCP server … and a digest“ ist veraltet.** `integrations/mcp/` und `integrations/digest/` sind getrackt. Den Satz streichen und die beiden verlinken. (README.md:105, README.de.md:82)
672. ✅ [Bug] **GitLab gilt als „Not yet“.** GitLab ist seit `lib/githost.sh` und docs/GITLAB.md eine Quelle. Die FAQ-Antworten neu schreiben. (README.md:175, README.de.md:153, docs/FAQ.md:25-26)
673. ✅ [Bug] **„Most wanted: GitLab“ im Mitmachen-Abschnitt.** GitLab ist gebaut. Ersetzen, z. B. durch Bitbucket, Gitea oder Tests der Provider-Dateien. (README.md:184, README.de.md:162)
674. ✅ [Bug] **„There is no undo command“ ist falsch.** `deploys vercel|render autodeploy-on <p>|--all` gibt es (deploys:33, 68; docs/AUTO-DEPLOY.md:22-23), und die Startseiten-FAQ nennt die Befehle sogar. Weil build-docs.py diesen README-Abschnitt in „Getting started“ übernimmt, steht der Fehler auch auf der Website. (README.md:116, README.de.md:93, docs/FAQ.md:14)
675. [Bug] **Der Update-Kanal ist falsch beschrieben.** DE-README und FAQ sagen „GitHubs Release-Seite“, die App liest aber über Sparkle `deploycenter.app/appcast.xml` (EN-README:173 stimmt). Angleichen. (README.de.md:151, docs/FAQ.md:20)
676. ✅ [Bug] **Der Update-Hinweis im DE-README ist veraltet.** DE nennt „Jetzt aktualisieren in den Einstellungen“ und `brew upgrade` ohne `--greedy`, EN nennt „Check for Updates …“ und `--greedy`. (README.de.md:33 vs. README.md:54)
677. ✅ [Bug] **Der Rechner-Link führt ins Leere.** `deploycenter.app/#calc` gibt es nicht mehr (kein `id="calc"` in index.html), der Rechner liegt unter `/vercel-build-cost-calculator/`. `check-links.py` prüft keine absoluten URLs, deshalb fiel es nicht auf. (README.md:72, README.de.md:51)
678. [Bug] **Die Startseite zeigt die alte Version 0.9.0.** VERSION und appcast.xml sagen 0.9.1. `softwareVersion` im JSON-LD und „Version 0.9.0“ beim Download beim Build aus VERSION einsetzen, damit es nicht wieder passiert. (site/index.html:34, :298)
679. ✅ [Bug] **Der Netlify-Guide sagt, Netlify werde nicht unterstützt.** „supports Vercel and Render today. Netlify support is coming“ und „Not yet“, dabei ist Netlify ein Opt-in-Provider (docs/providers/netlify.md). Den Abschnitt auf `deploys providers enable netlify` umschreiben. (site/guides/netlify-stop-builds/index.html:186, :192, :196)
680. ✅ [Bug] **„Agent digest … Coming soon“ auf der Claude-Code-Seite.** Die Startseite verlinkt den Digest schon als vorhanden (`integrations/digest/` ist getrackt). Tag und Text anpassen. (site/claude-code/index.html:171-172 vs. site/index.html:373)
681. ✅ [Bug] **Die Claude-Code-Seite erwähnt das Plugin nicht.** Die Startseite schickt Plugin-Interessierte mit „Add the plugin“ und „Claude Code plugin … More“ genau dorthin, `grep plugin` findet dort aber 0 Treffer. `/plugin marketplace add …` und `/plugin install …` aus docs/CLAUDE-CODE.md:12-17 übernehmen. (site/claude-code/index.html, Verweise: site/index.html:372, :521)
682. ✅ [Bug] **Die MCP-Einrichtung auf der Claude-Code-Seite ist unnötig umständlich.** Die Seite verlangt Klon, `npm ci` und Pfad, die Startseite verspricht „Settings → Claude connects … in one click“. Den Ein-Klick-Weg und das Plugin (bringt `mcp/deploys.mcp.json` mit) zuerst zeigen. (site/claude-code/index.html:161-168 vs. site/index.html:371)
683. ✅ [Bug] **Unterschiedliche Kostenzeiträume.** Der Alt-Text sagt Kosten „of the last 14 days“, Liste, Guides und README sagen 7 Tage. Den echten Wert aus der App nehmen und überall gleich schreiben. (site/index.html:304 vs. :339, site/guides/reduce-vercel-costs/index.html:175, README.md:16 vs. :24)
684. ◐ [Bug] **docs/FAQ.md ist veraltet und erscheint so auf der Website.** „Windows or Linux?“ nennt weder WSL noch install.sh, „What does it cost?“ nur Vercel und Render. Beides wird als /docs/faq/ veröffentlicht und widerspricht der Startseiten-FAQ. Abgleichen oder die Startseiten-FAQ als Quelle nehmen. (docs/FAQ.md:4, :28-29)
685. ✅ [Bug] **GOOD-FIRST-ISSUES enthält erledigte Aufgaben.** Nr. 6 sagt, CI laufe mit `--severity=error`, ci.yml:31 nutzt aber schon `warning`. Nr. 8 (Link-Check) läuft schon als `scripts/check-links.py` (ci.yml:99-100). Beide streichen, Fish und Teams bleiben offen. (docs/GOOD-FIRST-ISSUES.md:23-24, :29-31)
686. ✅ [Bug] **Der shellcheck-Befehl in CONTRIBUTING weicht von CI ab.** Es fehlt `lib/*.sh` (ci.yml:31), lokal grün kann also in CI rot werden. (CONTRIBUTING.md:51)
687. ✅ [Text] **CONTRIBUTING nennt nur zwei Provider.** „(`vercel.sh`, `render.sh`)“, inzwischen sind es sieben Dateien. Allgemein formulieren. (CONTRIBUTING.md:33-34)
688. ✅ [Text] **Der Release-Ablauf in CONTRIBUTING ist unvollständig.** Es fehlen EdDSA-Signatur und appcast.xml, das CLI-Tarball mit checksums.txt, Formel und Cask und die Versionsnummer auf der Site. (CONTRIBUTING.md:62-78)
689. ✅ [Text] **Der Funktionsumfang wirkt zu klein.** README-Tagline, Features und Lizenzzeile nennen nur Vercel und Render. Es fehlen Opt-in-Hosts, GitLab, Claude in der App, Widgets, Guard, sichere Deploys und Team-Modus. (README.md:5, :86-96, :196 und DE entsprechend)
690. ✅ [Text] **„Preview deploys (Vercel)“ ist zu eng.** Laut Startseite gibt es Vorschau und Rollback „on the hosts that support them“. (README.md:92, README.de.md:69)
691. ✅ [Text] **README-CLI beschreibt nur Vercel und Render.** Die Voraussetzungen und die CI-Tabelle kennen weder `glab`/`GITLAB_TOKEN`/`GITLAB_HOST` noch die Tokens der Opt-in-Provider (Netlify, Cloudflare, AWS, DigitalOcean, Coolify). (README-CLI.md:3, :53-61, :80-87)
692. ✅ [Text] **Die Startseiten-CTA der Guides sagt „Vercel and Render“.** Der CTA-Kasten auf allen Guides und im Rechner nennt nur zwei Hosts, die Startseite sieben. Eine gemeinsame Textbaustein-Quelle verhindert das Auseinanderlaufen. (z. B. site/guides/disable-vercel-auto-deploy/index.html:221, site/vercel-build-cost-calculator/index.html:203-204)
693. ✅ [Text] **Der Markenhinweis ist auf jeder Seite anders.** Guides, Rechner und 404 sagen „not affiliated with Vercel, Render or Netlify“, die Startseite nennt zehn Firmen, das Impressum zwei. Die Claude-Seiten (Autofix-Guide, Blog) haben keinen Anthropic-Hinweis im Footer. (site/guides/*/index.html Footer „fine“, site/impressum.html:48)
694. ✅ [Text] **docs/README.md: der Sprachsatz ist veraltet.** „The app … follows the language the Mac prefers“, seit 0.9.1 gibt es aber einen Sprachschalter (appcast 0.9.1). (docs/README.md:28)
695. ✅ [Text] **Der Doku-Index ist unvollständig.** Es fehlen docs/GITLAB.md, docs/providers/*.md, WIDGETS-IOS.md und README-CLI.md. (docs/README.md:3-22)
696. ✅ [Text] **NUMBERS/ZAHLEN erklären nur GitHub.** GitLab zählt ohne 250er-Grenze, kennt kein Stundenbudget und gibt Open-MR ohne CI-Status (docs/GITLAB.md:85-95). Einen Absatz in beiden Sprachen ergänzen. (docs/NUMBERS.md:7, :12, docs/ZAHLEN.md:5, :10)
697. ✅ [Text] **SAVINGS sagt „Vercel and Render only“, nennt aber keinen Zeitplan und keine Alternative.** Die Opt-in-Hosts sollten zumindest die Zahl der Builds ohne Preis zeigen, oder die Seite sagt klar warum nicht. (docs/SAVINGS.md:98, docs/ERSPARNIS.md:100)
698. ✅ [Text] **Der Blog-Artikel hängt in der Guides-Breadcrumb.** Er läuft unter Home › Guides, ohne /blog/-Übersicht. Entweder eine Blog-Übersicht anlegen oder den Artikel unter /guides/ führen. (site/blog/ai-coding-agents-build-bill/index.html:136)
699. ✅ [Text] **„Everyone codes with Claude now“ ist eine Übertreibung.** Das passt nicht zum sonst nüchternen, ehrlichen Ton und ist angreifbar. Sachlich formulieren. (site/claude-code/index.html:135)
700. [Text] **Die README-Alternativen nennen Status-Apps ohne Namen.** Ohne Namen ist der Vergleich nicht nachprüfbar. Zwei oder drei Beispiele mit Link machen ihn fair und vertrauenswürdig. (README.md:158-159, site/index.html:481)
701. [Text] **APP-STORE.md enthält einen internen Betriebsstand.** Abschnitt „Steps only the owner can do“ mit Kontostatus, TestFlight-Gruppe und „account holder is invited“ gehört nicht ins öffentliche Repo. Den Stand in ein privates Issue oder eine Notiz verschieben, die Checkliste allgemein lassen. (docs/APP-STORE.md:45-70)


### Datenschutz und Recht

702. [Security] **Die Datenschutzerklärung erwähnt Anthropic nicht.** „Claude in der App“ (API-Key, maskierter Text an api.anthropic.com) und Autofix (Build-Log an eine Claude-Code-Routine) fehlen ganz. `grep anthropic|claude|routine` in datenschutz.html findet 0 Treffer. Mit Rechtsgrundlage, Drittlandübermittlung und Opt-in-Hinweis ergänzen. (site/datenschutz.html:51-53)
703. [Security] **Die Datenschutzerklärung nennt nur Vercel, Render und GitHub.** Es fehlen GitLab (inkl. self-managed), die Opt-in-Hosts (Netlify, Cloudflare, AWS, DigitalOcean, Coolify, Hooks), Webhook-Ziele des Tagesberichts (Slack, Discord, Telegram, ntfy) und Downloads über install.sh und Homebrew. (site/datenschutz.html:51-53)
704. [Security] **Der Satz „Nothing else leaves the Mac“ stimmt nicht mehr.** Der Threat-Model-Tabelle fehlen Claude in der App (api.anthropic.com mit eigenem Key), GitLab, die Opt-in-Hosts, die iCloud-Schlüsselbund-Kopplung und der QR-Weg zum iPhone. (SECURITY.md:52-62)
705. ✅ [Security] **Die Schlüsselliste in SECURITY.md ist unvollständig.** Es fehlen `deploy-center-anthropic` (UNINSTALL.md:41 nennt ihn), die Tokens der Opt-in-Provider und der iCloud-Sync. (SECURITY.md:66-70)
706. [Security] **Der Klarname steht maschinenlesbar auf etwa 12 Seiten.** Im JSON-LD-`author` jeder Guide-, Blog- und Rechnerseite. Für das Impressum ist er Pflicht, für JSON-LD nicht. Abwägen, ob „Deploy Center“ als Organization reicht (das schützt auch vor Scraping). (site/guides/*/index.html:46, site/claude-code/index.html:46, site/blog/ai-coding-agents-build-bill/index.html:46, site/vercel-build-cost-calculator/index.html:46, :134)
707. [Security] **Die Telefonnummer im Impressum und in der Datenschutzerklärung.** Nach DDG § 5 reicht meist eine zweite schnelle Kontaktmöglichkeit wie ein Kontaktformular, die Nummer ist dann nicht nötig (rechtlich prüfen). In einem öffentlichen Repo wird sie dauerhaft gecrawlt. (site/impressum.html:39, site/datenschutz.html:37)
708. [Text] **Der Markenhinweis im Impressum ist veraltet.** Nur „Vercel und Render“, es fehlen GitHub, GitLab, Netlify, Cloudflare, AWS, DigitalOcean, Coolify und Anthropic/Claude. (site/impressum.html:48)
709. [Text] **Die Rechtsseiten sind vom Design abgekoppelt.** Sie haben eigenes Inline-CSS, nutzen relative `img/icon.png` und haben keine Navigation zu Docs oder Guides. Auf `site.css` umstellen, dann wirken sie nicht wie eine fremde Seite. (site/datenschutz.html:9-12, site/impressum.html)
710. [Text] **Die Datenschutzerklärung erwähnt den Rechner-Link nicht.** Er hält die Werte in der URL und wird beim Teilen an X übergeben. Ein Satz dazu (Werte in der URL, nicht personenbezogen) schafft Klarheit. (site/datenschutz.html:48-49)
711. ✅ [Text] **Im CODE_OF_CONDUCT fehlt eine zweite Meldestelle.** Meldungen gehen nur an den Maintainer, betrifft eine Beschwerde ihn selbst, gibt es keinen Weg. Eine externe Stelle oder den GitHub-Support nennen. (CODE_OF_CONDUCT.md:9-12)


### Sicherheit von install.sh

712. [Security] **Die Prüfsumme belegt nur Unversehrtheit, nicht die Herkunft.** `checksums.txt` kommt aus demselben Release wie das Tarball. Wer das Release ändern kann, ändert beide. Eine Signatur mit fest eingebautem öffentlichem Schlüssel prüfen (minisign oder cosign) oder `gh attestation verify`, wenn `gh` da ist. (site/install.sh:124-148)
713. [Security] **Ein abgebrochener Download kann ein halbes Skript ausführen.** Bei `curl | sh` läuft schon an, was angekommen ist. Den ganzen Ablauf in `main() { … }` legen und erst in der letzten Zeile `main "$@"` aufrufen. (site/install.sh:17-270)
714. [Bug] **Strg-C bricht die Installation nicht ab.** `trap 'rm -rf "$tmp"' EXIT INT TERM` fängt INT ab, räumt auf und lässt das Skript danach weiterlaufen. Für INT und TERM `…; exit 130` ergänzen. (site/install.sh:121)
715. ✅ [Security] **Mit der Umgebungsvariable lassen sich Quelle und Prüfsumme gemeinsam austauschen.** `DEPLOYS_INSTALL_BASE` kommt aus der Umgebung und gilt auch für checksums.txt. In CI oder einer fremden Shell kann eine gesetzte Variable unbemerkt einen Spiegel nutzen. Beim Überschreiben deutlich warnen, mit einer Signatur aus dem vorigen Punkt wäre es egal. (site/install.sh:22)
716. ✅ [Security] **`tar` übernimmt als root die Eigentümer aus dem Archiv.** Läuft das Skript als root (z. B. im Docker-Build), behält `tar -xzf` die Eigentümer aus dem Archiv. `--no-same-owner` ergänzen. (site/install.sh:151)
717. [Bug] **Der Austausch des lib-Ordners ist nicht atomar.** Erst `rm -rf "$libdir"`, dann `mv`: scheitert `mv`, ist nichts mehr installiert. Zuerst nach `.old` verschieben und bei einem Fehler zurückholen. (site/install.sh:170-171)
718. [Bug] **glab fehlt in der Abhängigkeitsprüfung.** `report` nennt `gh`, aber nicht `glab`, obwohl GitLab als Quelle unterstützt wird. `glab` (oder `GITLAB_TOKEN`) als optional ergänzen. (site/install.sh:249-256)
719. [Text] **Der Doku-Link am Ende zeigt auf GitHub.** Er verweist auf README-CLI auf GitHub, nicht auf `https://deploycenter.app/docs/cli/`. (site/install.sh:268)
720. [Feature] **`--dry-run` für install.sh.** Es zeigt Quelle, Prüfsumme, Zielpfade und ob sudo nötig wäre, ohne etwas zu schreiben. Das ist hilfreich für vorsichtige Nutzer und CI-Reviews. (site/install.sh:7-12)
721. ✅ [Security] **In CI ist die Version nicht festgelegt.** Das CI-Beispiel installiert „latest“. Für reproduzierbare Läufe und gegen ein kompromittiertes neues Release `--version x.y.z` empfehlen. (README-CLI.md:90)
722. ✅ [Text] **Die Prüfanleitung „von Hand“ fehlt für macOS.** `sha256sum -c` gibt es nicht auf jedem macOS. `shasum -a 256 -c checksums.txt --ignore-missing` als zweite Zeile nennen. (README-CLI.md:49)
723. [Feature] **`.well-known/security.txt`.** RFC 9116 mit Link auf die GitHub-Advisories und SECURITY.md, damit Forscher die Meldestelle ohne Suchen finden. (site/)


### Onboarding und Doku-Lücken

724. [Bug] **UNINSTALL vergisst alles, was im Hintergrund läuft.** Es fehlen der Autofix-launchd-Job (`deploys autofix schedule off`), der Guard-Job, der Schlüssel `deploy-center-routine`, Widget- und App-Group-Daten, die iCloud-Schlüsselbund-Einträge für das iPhone, `claude mcp remove deploys`, das Claude-Code-Plugin, die VS-Code-Erweiterung und `install.sh --uninstall`. `grep autofix|guard|routine|widget|icloud` findet 0 Treffer. (docs/UNINSTALL.md:5-14, :36-46)
725. ✅ [Text] **TROUBLESHOOTING deckt nur Vercel, GitHub und Render ab.** Es fehlen Abschnitte zu GitLab (glab, Token, Host), Autofix (Token, Routine, Caps), Claude in der App (Key, Cap erreicht), Guard, Widgets, Opt-in-Hosts und install.sh unter Linux. (docs/TROUBLESHOOTING.md)
726. ✅ [SEO] **Wichtige Doku fehlt auf der Website.** `PAGES` enthält weder SAFE-DEPLOY, TEAM, GUARD, CLAUDE, CLAUDE-CODE, SAVINGS, GITLAB, PROVIDERS noch providers/*.md oder README-CLI. Deshalb verlinken Startseite und llms.txt diese Inhalte als GitHub-Blobs, das kostet internen Linkfluss und Verweildauer. Aufnehmen und die Links umstellen. (scripts/build-docs.py:33-61; Verweise site/index.html:342, :370-374, :405, :442; site/llms.txt:43-50)
727. ✅ [Bug] **Digest und Claude-Code-Plugin fehlen in der Sitemap.** Sie stehen nicht im committeten Docs-Block, obwohl build-docs.py jeden `integrations/*/README.md` aufnehmen soll. Prüfen, ob die committete sitemap.xml veraltet ist oder die Ordner übersprungen werden. (Vermutung) (site/sitemap.xml:13-37, scripts/build-docs.py:63-74)
728. ✅ [Text] **Die Label-Liste der Integrationen ist unvollständig.** `INTEGRATIONS` und `INTEGRATION_ORDER` kennen weder raycast noch digest noch claude-code, diese erscheinen nur mit ihrer H1 und ohne Beschreibung. Damit fehlt auch die Meta-Description. (scripts/build-docs.py:65-74)
729. ✅ [Bug] **Die Datumsformatierung in build-docs ist nicht portabel.** `strftime("%B %-d, %Y")`: `%-d` gibt es unter Windows nicht (ValueError). Für Beiträger unter Windows bricht der Build. `f"{d:%B} {d.day}, {d.year}"` nutzen. (scripts/build-docs.py:549)
730. ✅ [Text] **Für die Website gibt es keine Beiträger-Anleitung.** Es fehlt, wie man `site/` lokal ansieht (`python3 -m http.server -d site`), `build-docs.py` und `check-links.py` ausführt und neue Guides in sitemap, llms.txt und Footer einträgt. In CONTRIBUTING ergänzen. (CONTRIBUTING.md)
731. ◐ [Text] **Der Pflegeaufwand neuer Guides ist hoch.** Die Footer-Liste der Guides steht von Hand auf 12 Seiten, der Related-Block je Guide auch. Ein kleines Skript (wie build-docs) oder ein Partial würde Lücken verhindern. (site/guides/*/index.html Footer, site/404.html)
732. [Feature] **Der SAFE-START-Weg zeigt die Ersparnis nicht zuerst.** Vor dem Abschalten `deploys simulate` als ersten Lesebefehl zeigen: so sieht man die Ersparnis vorher, und es ändert nichts. (docs/SAFE-START.md:9-18)
733. ✅ [Text] **Der Abschnitt „Getting started“ übernimmt Veraltetes aus der README.** Der Abschnitt „What it changes, and how to undo it“ wandert samt Fehler auf die Website. Entweder die README fixen oder eine eigene docs-Quelle nehmen. (scripts/build-docs.py:82-84)
734. ✅ [Text] **Die Docs-Seiten haben keinen Weg zum Download.** Die Kopfleiste (build-docs) hat nur Docs, Suche und GitHub. Ein „Download“-Knopf und ein Link zu Guides und Rechner fehlen, wer aus der Suche kommt, sackt hier ab. (scripts/build-docs.py:578-590)
735. ✅ [Text] **Den Guide-Seiten fehlt die Doku in der Navigation.** Die Kopfleiste zeigt Guides, Calculator und GitHub, aber weder Docs noch Download. (site/guides/*/index.html:143, site/vercel-build-cost-calculator/index.html:143)
736. ✅ [Text] **Der Netlify-Guide verweist nicht auf die Provider-Doku.** Sobald der Abschnitt „not yet“ ersetzt ist, den Link auf /docs/… oder docs/providers/netlify.md setzen. Dort steht auch, welche `ignore`-Zeile Deploy Center akzeptiert. (site/guides/netlify-stop-builds/index.html:185-187)
737. ✅ [Text] **Der Render-Guide verschweigt die Paginierung.** `?limit=100` liefert höchstens 100 Services, bei mehr braucht es `cursor`. Ein Halbsatz verhindert falsche „alle sind aus“-Annahmen. (site/guides/render-auto-deploy-off/index.html:163-165)
738. ✅ [Text] **Für Vercel-Deploy-Hooks fehlt ein Verweis.** Der Guide sagt richtig, dass Hooks mit der Git-Verbindung verschwinden, nennt aber nicht `deploys triggers` zum Prüfen. (site/guides/disable-vercel-auto-deploy/index.html:171)
739. ✅ [Text] **„Only the newest commit of a push is checked“ fehlt beim Skip-Beispiel im Ignored-Build-Step-Guide.** Im Guide „stop building“ steht der Hinweis, im Ignored-Build-Step-Guide beim selben Beispiel nicht. (site/guides/vercel-ignored-build-step/index.html:156-157)


### SEO und GEO

740. ✅ [SEO] **Eine Faktenquelle für llms.txt und Startseite.** llms.txt verlinkt fünf von acht „Optional“-Einträgen auf GitHub statt auf Website-Seiten und nennt keine Version. Nach der Aufnahme in build-docs auf `/docs/…` zeigen und „Version 0.9.1“ oben ergänzen. (site/llms.txt:43-50)
741. ✅ [SEO] **`llms-full.txt`.** build-docs.py hat schon alles als Klartext (Suchindex). Eine `llms-full.txt` mit dem Text aller Docs und Guides hilft KI-Assistenten bei korrekten Antworten zu Befehlen. (scripts/build-docs.py:637-653)
742. ✅ [SEO] **Die Docs-Seiten haben unvollständige Social-Tags.** Es fehlen `twitter:image`, `twitter:title`, `og:image:alt`, `og:locale` und Bildmaße, ohne `twitter:image` zeigt X oft keine Karte. (scripts/build-docs.py:562-569)
743. [SEO] **Der Autor ist nicht einheitlich ausgezeichnet.** Docs-Seiten nennen eine Organization als Autor, Guides eine Person mit Repo-URL als `url`. Einheitlich machen (siehe Datenschutz-Punkt), sonst schwächt es die E-E-A-T-Signale. (scripts/build-docs.py:508, site/guides/*/index.html:44-48)
744. ✅ [SEO] **`softwareVersion` und `dateModified` sind von Hand gepflegt.** Beides beim Pages-Build aus VERSION und git log einsetzen, dazu `lastmod` der Hand-Einträge in sitemap.xml (alle stehen auf demselben Tag). (site/index.html:34, site/sitemap.xml:3-14)
745. ✅ [SEO] **Die Seite hat kein `WebSite`- und `Organization`-Schema.** Ein `WebSite` mit `SearchAction` auf die Docs-Suche und eine `Organization` mit Logo und `sameAs` (GitHub, Homebrew-Tap) gehören auf die Startseite. (site/index.html:33-47)
746. ✅ [SEO] **Das Schema der Startseite ist veraltet.** Der `HowTo`-Block bringt bei Google seit 2023 keine Rich Results mehr. Für GEO ist er harmlos, dient aber nur noch als Textquelle; nicht weiter ausbauen und stattdessen `SoftwareApplication` vollständig machen (`fileSize`, `softwareRequirements`, `downloadUrl` mit Versionspfad). (site/index.html:35)
747. [SEO] **Gleiches OG-Bild auf allen Guides.** Jede Guide-Seite teilt `og.png` mit dem Startseiten-Alt-Text. Pro Guide ein einfaches Titelbild (Text auf Markenfarbe, beim Build erzeugt) erhöht die Klickrate in Social und Slack. (site/guides/*/index.html:18-21)
748. [SEO] **Der Rechner-Titel spricht nur Vercel an.** Die Seite rechnet auch für Render. Eigene Landingpages „Render build minutes calculator“ und „Netlify build credits calculator“ mit voreingestellten Werten fangen diese Suchen ab. (site/vercel-build-cost-calculator/index.html:6)
749. ✅ [SEO] **Die Rechner-URL ändert sich beim Schieben nicht.** Der Teilen-Link wird gebaut, die Adresszeile bleibt aber leer. `history.replaceState` mit den Werten macht jede kopierte URL teilbar und ist kanonisch harmlos. (site/vercel-build-cost-calculator/index.html:251-259)
750. [SEO] **Kanonische URLs der Rechtsseiten.** `impressum.html` und `datenschutz.html` sind `noindex`, haben aber `canonical`. Das ist nicht falsch, doch für die Rechtsseiten wären saubere Pfade wie `/impressum/` und ein Eintrag auf allen Seiten ohne `.html` einheitlicher. (Abwägung) (site/datenschutz.html:7-8)
751. [SEO] **Keine `hreflang`-Paare für die deutschen Rechtsseiten.** Die Rechtsseiten sind deutsch, ohne englische Fassung; zumindest `lang="de"` stimmt. Zusammen mit dem bekannten /de/-Plan die Paare setzen. (site/impressum.html, site/datenschutz.html)
752. [SEO] **IndexNow meldet jedes Mal alle URLs.** pages.yml schickt die ganze Sitemap. Nur geänderte URLs (aus `git diff`) senden, sonst stuft Bing die Meldungen ab. (Vermutung zur Bewertung) (site/4747785d1fcf908f9504c58a9a66de5a.txt, Ablauf in pages.yml:56-61)
753. ✅ [SEO] **Keine Seite für „Vercel deploy hooks“.** Das ist ein häufiges Suchthema, und docs/providers/hook.md hat den Inhalt schon. Als Guide „Deploy any host with a deploy hook“ veröffentlichen. (docs/providers/hook.md)
754. ✅ [SEO] **FAQ-Antworten mit Befehlen sind schlecht zitierbar.** Im JSON-LD stehen Befehle als Fließtext ohne Codeauszeichnung („deploys vercel autodeploy-on and deploys render …“). Für Zitate durch KI-Assistenten den Befehl in Anführungszeichen oder als eigene Frage setzen. (site/index.html:42)


### Barrierefreiheit

755. ✅ [A11y] **Schlechter Kontrast im Hellmodus der Unterseiten.** site.css überschreibt im Hellmodus `--accent`, `--green`, `--red` und `--orange` nicht. Links (#4f7cff auf Weiß, etwa 3,6:1) und die grüne Rechner-Zahl (#34c759 auf Weiß, etwa 2,2:1) fallen durch. Die Werte aus index.html:54 übernehmen. (site/css/site.css:8-10)
756. ✅ [A11y] **Die Themenwahl gilt nur auf der Startseite.** site.css kennt kein `:root[data-theme]`, und die Unterseiten laden kein Skript. Wer auf der Startseite „hell“ wählt, bekommt auf Guides dunkel. Den kleinen Theme-Block teilen. (site/css/site.css:8, site/index.html:573-595)
757. ✅ [A11y] **Unterseiten ohne Skip-Link und ohne Fokusstil.** site.css hat kein `:focus-visible` und die Guides keinen „Skip to content“, beides hat die Startseite. (site/css/site.css, site/guides/*/index.html:141)
758. ✅ [A11y] **Der Rechner liest zu viel vor.** `aria-live="polite"` liegt auf der ganzen Ergebniskarte, jede Reglerbewegung liest Überschrift, drei Beträge und den Knopf vor. Nur die Ersparnis live machen und bei `change` statt `input` aktualisieren. (site/vercel-build-cost-calculator/index.html:160)
759. ✅ [A11y] **Das Label der Rechner-Regler wiederholt den Wert.** `<output>` steckt im `<label>`, der Screenreader liest den Wert doppelt (Name plus Wert). Das `output` aus dem Label nehmen und per `aria-describedby` verbinden. (site/vercel-build-cost-calculator/index.html:155-158)
760. ✅ [A11y] **Dem Pausenknopf fehlt ein stabiler Name.** Der Knopf ändert Text („Pause“/„Play“) und `aria-pressed` gleichzeitig, der Screenreader sagt dann „Play animation, gedrückt“. Entweder fester Text mit `aria-pressed` oder wechselnder Text ohne. (site/index.html:331, :652)
761. ✅ [A11y] **Der Themenknopf zeigt den Zustand nicht an.** Beide Knöpfe heißen „Switch between light and dark mode“, ohne `aria-pressed` und ohne den aktuellen Modus im Namen. (site/index.html:247, :251)
762. ✅ [A11y] **Das mobile Menü schließt nicht mit Escape.** `<details class="menu">` bleibt bei Escape und Klick außerhalb offen und liegt über dem Inhalt. (site/index.html:252-266, :618)
763. ✅ [A11y] **Die Tabellen der Guides haben keine Zeilenköpfe.** Die erste Spalte ist `<td>` statt `<th scope="row">`, im Netlify-Guide ist der erste Kopf leer. Ein `<caption>` hilft zusätzlich. (site/guides/disable-vercel-auto-deploy/index.html:151-156, site/guides/netlify-stop-builds/index.html:142)
764. ✅ [A11y] **Der Flow im Autofix-Guide liest Pfeile vor.** Die `→` per `::before` liest VoiceOver als „rechter Pfeil“. Als `<ol>` reicht die Reihenfolge, den Pfeil mit `content: "→" / ""` (Alt-Text leer) stumm schalten. (site/css/site.css:121)
765. ✅ [A11y] **Der Fallback des Kopierknopfs ist irreführend.** Bei Fehler steht „Select to copy“, der Text im `<pre>` wird aber nicht markiert. Bei Fehler den Bereich per Range selektieren. (site/index.html:599-604)
766. ✅ [A11y] **Der GitHub-Link hat ein Sternchen im Namen.** „GitHub ★“ steht auch in den Docs-Seiten, der Screenreader sagt „GitHub schwarzer Stern“. Den Stern `aria-hidden` setzen (für index.html bekannt, in build-docs nicht). (scripts/build-docs.py:587)


### Leistung

767. ✅ [Perf] **Das Theme blitzt beim Laden.** Das Theme-Skript steht am Ende von `<body>`, wer „hell“ gespeichert hat, sieht erst die dunkle Seite. Die drei Zeilen für `data-theme` in den `<head>` ziehen. (site/index.html:575-578)
768. ✅ [Perf] **Preload und Bild passen nicht zusammen.** Der Preload nutzt `imagesizes="(max-width: 1040px) 100vw, 1000px"`, das `<source>` aber `sizes="(max-width: 960px) 100vw, 920px"`. Der Browser lädt dann eventuell zweimal. Gleich setzen. (site/index.html:32 vs. :303)
769. ✅ [Perf] **Ein 29-KB-Icon für 24 px.** Startseite und Docs-Seiten nutzen `img/icon.png` (29 KB) in der Kopfleiste, die Guides `icon-64.png` (4,7 KB). Überall icon-64 nehmen. (site/index.html:238, scripts/build-docs.py:579)
770. ✅ [Perf] **Toter Ballast: `site/img/app.png` (324 KB).** Keine Seite verweist darauf. Löschen, das verkleinert auch das Pages-Artefakt. (site/img/app.png)
771. ◐ [Perf] **Das Manifest-Icon ist 142 KB groß.** `icon-512.png` lässt sich verlustfrei (oxipng) oder als WebP stark verkleinern, und ein `maskable`-Icon fehlt. (site/site.webmanifest:9-12)
772. [Perf] **Etwa 180 Zeilen Inline-CSS auf der Startseite.** Sie werden bei jedem Besuch neu geladen, `site.css` dagegen gecacht. Die gemeinsamen Teile (Variablen, Nav, Footer, Buttons) auslagern. (Leftover zu bekannter Idee 300) (site/index.html:48-233)
773. ✅ [Perf] **Die Startseite lädt Bilder für das falsche Theme.** `swapImages` entfernt bei manuell gewähltem Theme die `<source>`-Elemente und setzt `src`, nachdem das System-Bild schon geladen war. Mit der Theme-Wahl im `<head>` (oben) kann das Skript vor dem Laden greifen. (site/index.html:580-588)
774. ✅ [Perf] **Unnötige Versionsparameter für Docs-Assets.** `?v=VERSION-sha` ändert sich bei jedem Commit, auch ohne CSS-Änderung. Den Hash des Datei-Inhalts nehmen, dann bleibt der Cache länger gültig. (scripts/build-docs.py:572, :682-683)


### Rechner: Inhalt

775. [Feature] **Weniger als ein Deploy pro Tag ist nicht möglich.** Der Regler „Deploys by hand per project per day“ beginnt bei 1. Wer wöchentlich deployt, kann das nicht eingeben. Zusätzlich „pro Woche“ anbieten. (site/vercel-build-cost-calculator/index.html:158)
776. [Feature] **Die Arbeitstage stehen fest auf 22.** Wochenend-Pushes (laut Text „add to the first line“) werden nicht gerechnet. Ein Regler „Tage mit Pushes pro Monat“ macht es ehrlich. (site/vercel-build-cost-calculator/index.html:176, :254)
777. [Feature] **Eingabe über Build-Minuten.** Vercel und Render rechnen nach Minuten. „Build dauert X min × Preis pro Minute je Maschine“ als zweiter Eingabeweg ist genauer als ein geschätzter Preis pro Build. (site/vercel-build-cost-calculator/index.html:157)
778. ✅ [Bug] **Kleine Beträge werden zu $0.** `Math.round` schneidet alles unter $0,50 auf „$0“. Unter $10 mit zwei Nachkommastellen zeigen. (site/vercel-build-cost-calculator/index.html:249)
779. [Feature] **Den Rechner mit der App verbinden.** Ein Knopf „Use my real numbers“ erklärt `deploys simulate --json` und füllt die Regler per Einfügen, ohne Server, nur im Browser. (site/vercel-build-cost-calculator/index.html:183-187)


### Neue Inhalte und Landingpages

780. [Feature] **Guides für jeden Opt-in-Host.** Für Cloudflare Pages (Build-Limit 500/Monat), AWS Amplify, DigitalOcean App Platform und Coolify gibt es Provider-Doku, aber keine Suchseite „turn off auto-deploy on X“. Aus docs/providers/*.md je einen Guide machen. (docs/providers/*.md)
781. [Feature] **Guide „Turn off GitLab-triggered Vercel builds“.** GitLab-Nutzer haben andere Schritte (gitSource gitlab, `deploys vercel map`). Das ist eine kleine, unbesetzte Suchnische. (docs/GITLAB.md:98-110)
782. [Feature] **Seiten pro KI-Agent.** Der Blog nennt Cursor, Codex, Lovable und v0. Je eine kurze Seite „Lovable/v0 auf Vercel: Builds pro Änderung stoppen“ greift die Suchen dieser Nutzer ab, besonders für App-Builder, die direkt auf main pushen. (site/blog/ai-coding-agents-build-bill/index.html:138, :165, :173)
783. [Feature] **Guide „Monorepo: one push, many builds“.** Turborepo, Nx und pnpm-Workspaces mit konkreten Zahlen. Bisher steht das nur verstreut in zwei Guides. (site/guides/stop-vercel-building-every-push/index.html:151-157)
784. [Feature] **Guide „Dependabot and Renovate without a build bill“.** Gruppieren, Zeitplan und Ignored Build Step. Ein häufiger Kostentreiber, aber nur ein Einzeiler im Guide. (site/guides/vercel-ignored-build-step/index.html:154-155)
785. [Feature] **Guide „Safe deploys: deploy only when CI is green“.** Aus docs/SAFE-DEPLOY.md, mit dem Render-`checksPass`-Vergleich. Das Thema hat Suchvolumen und wird bisher nur auf GitHub erklärt. (docs/SAFE-DEPLOY.md)
786. [Feature] **Seite „Deploy Center for teams“.** Team-Modus, Beobachter, Vier-Augen-Regel, ohne Server. Für Agenturen und kleine Teams ist das der Kaufgrund (auch wenn gratis), heute steckt es in einem Unterabschnitt. (site/index.html:399-405, docs/TEAM.md)
787. [Feature] **Seite „iPhone and iPad“ zum Launch vorbereiten.** Mit Screenshots aus `ios/AppStore/screenshots/`, App-Store-Badge und `apple-itunes-app`-Meta, sobald die App live ist. (site/index.html:415, :506)
788. [Feature] **Changelog auf der eigenen Seite.** `/changelog/` mit Atom-Feed aus CHANGELOG.md (build-docs kann das). Die Startseite verlinkt heute „What's new“ nur auf GitHub, ein Feed macht Updates abonnierbar. (site/index.html:272, :298)
789. [Feature] **Seite „Security and privacy“.** Aus SECURITY.md eine verständliche Fassung: was wohin geht, Schlüssel, Signaturen. Die Startseite verlinkt „Threat model“ auf GitHub. (site/index.html:442)
790. [Feature] **Seite „How the numbers are counted“ auf Deutsch.** ZAHLEN.md und ERSPARNIS.md sind deutsche Originale, auf der Website aber nicht vorhanden. Als /de/docs/numbers/ veröffentlichen, ein Anfang für /de/. (docs/ZAHLEN.md, docs/ERSPARNIS.md)
791. [Feature] **Ein Glossar mit eigenen URLs pro Begriff.** „What is Vercel Ignored Build Step“ oder „Render Blueprint auto-sync“ sind Fragen, die KI-Assistenten zitieren. Die Anker gibt es schon, `DefinedTerm`-Schema dazu macht sie maschinenlesbar. (docs/GLOSSARY.md, scripts/build-docs.py:506-534)
792. [Feature] **Eine Seite „Verify a release“ mit Signatur.** Steht der Signaturweg für install.sh, eine Seite zum Kopieren der Prüfbefehle (App: spctl/codesign, CLI: minisign/cosign). (site/index.html:298)


### Vertrauen

793. [Growth] **Der Download-Knopf zeigt keine Eckdaten.** „Download for Mac“ führt zur GitHub-Release-Seite. Version, Größe (13 MB laut appcast) und Datum direkt am Knopf schaffen Vertrauen und sparen einen Klick. (site/index.html:276-278)
794. [Growth] **Die Download-Zahl als Beleg nutzen.** Den Zähler einmal am Tag beim Pages-Build aus der GitHub-API holen und statisch einsetzen, ohne Tracking. (Ergänzt die bekannte Idee 283, hier konkret: Build-Schritt statt Handpflege) (site/index.html:283)
795. [Growth] **Ein CI-Status-Badge in der README.** Ein grünes CI-Abzeichen neben Release und Lizenz zeigt Pflege. (README.md:9-14)
796. [Growth] **„Last updated“ auf der Startseite.** Die Guides zeigen ein Datum, die Startseite nicht. Mit Version und Datum („0.9.1 · 10 Nov 2026“) sieht man, dass das Projekt lebt. (site/index.html:298)
797. [Growth] **Die Rechtsseiten sagen nichts über die Website-Skripte.** Die Datenschutzerklärung betont keine fremden Skripte, das ist ein Verkaufsargument. Einen Satz „no cookies, no trackers, no third-party scripts“ auch auf die Startseite in die Datenschutz-FAQ. (site/index.html:498)
798. [Growth] **Ehrliche Grenzen auf der Startseite.** Die Guides haben „Honest limits“, die Startseite nicht. Zwei Zeilen „Wann Deploy Center nichts bringt“ (wenige Pushes, schnelle Builds, Previews als Review-Werkzeug) erhöhen die Glaubwürdigkeit. (site/index.html:477-491)


### Wachstum und Community

799. [Growth] **Vergleichsseiten mit Namen.** „Deploy Center vs. Vercel Ignored Build Step“, „vs. Disconnect Git“ und „vs. a GitHub Action that deploys on schedule“ als eigene URLs fangen „X vs Y“-Suchen ab. Die Tabelle der Startseite ist der Kern. (site/index.html:477-491)
800. [Growth] **Good first issues als echte, gelabelte Issues anlegen.** Die Datei sagt „The owner can turn each one into an issue“, das ist nicht passiert. Ohne Label findet goodfirstissue.dev oder GitHubs Explore das Projekt nicht. (docs/GOOD-FIRST-ISSUES.md:3-4)
801. [Growth] **Neue Good first issues aus diesem Audit.** Kleine, klare Aufgaben aus dieser Liste: Footer-Markenhinweis vereinheitlichen, Netlify-Guide aktualisieren, Tabellen mit `th scope`, glab in install.sh. (docs/GOOD-FIRST-ISSUES.md)
802. [Growth] **Showcase „Wer spart wie viel“.** Eine Seite mit anonymisierten Sparkarten („Share the saving“-Bild) von Nutzern, eingereicht per Issue-Vorlage. Das ist echter Social Proof ohne Tracking. (site/index.html:340)
803. [Growth] **Kurzlinks für Erwähnungen.** `deploycenter.app/calc`, `/claude`, `/install` als Weiterleitungen (meta refresh oder 404-Trick bei Pages). Sie lassen sich in Videos, Talks und Posts gut sagen. (site/)
804. [Growth] **Ein „Edit this page“-Link auf den Guides.** Die Docs haben „Edit on GitHub“, die Guides nicht. Korrekturen von Lesern (z. B. bei Änderungen in den Vercel-Menüs) kommen so schneller. (site/guides/*/index.html:139)
805. [Growth] **Eine Beitragsvorlage für Gast-Guides.** Eine Vorlage `site/guides/_template/` und eine Anleitung in CONTRIBUTING, z. B. „Turn off auto-deploy on <Host>“ von Nutzern anderer Hosts. Das ist eine Wachstumsschleife für Inhalte und Backlinks. (CONTRIBUTING.md)
806. [Growth] **Ein „Used with Claude Code“-Abzeichen für fremde READMEs.** Analog zu den Status-Badges: wer Deploy Center nutzt, kann es zeigen, jeder Badge ist ein Backlink. (integrations/badge, site/claude-code/index.html)
807. [Growth] **Ein Raycast-Store-Eintrag.** Die Startseite nennt Raycast, ein Eintrag im Raycast Store ist ein eigener Entdeckungskanal mit Link zurück. (Vermutung, dass er noch fehlt) (site/index.html:453)
808. [Growth] **Den Claude-Code-Plugin-Marktplatz nennen.** Wenn es ein offizielles Plugin-Verzeichnis gibt, dort einreichen und auf der Claude-Code-Seite verlinken. (Vermutung zur Verfügbarkeit) (docs/CLAUDE-CODE.md:10-17)
809. [Growth] **Eine Newsletter-freie Update-Möglichkeit.** „Watch the repo“ ist der einzige Weg, vom iPhone-Launch zu erfahren. Der Atom-Feed aus dem Changelog-Punkt plus ein Link „Releases only“ (GitHub Custom Watch) erklärt, wie das geht. (site/index.html:506)

## 7. Neue Features und kreative Ideen (152)
Gegen IDEEN 1–5, CHANGELOG und git log abgeglichen; nur Neues. ★ = die 15 stärksten.


### Kostenkontrolle

810. [Feature] **★ Kosten fehlgeschlagener Builds.** Zeigt „Fehlgeschlagene Builds kosteten diese Woche ≈ 4 $“ pro Projekt und gesamt, damit man sieht, wo rote Builds echtes Geld verbrennen; Dauer der gescheiterten Builds × Preis pro Minute aus `costs`.
811. [Feature] **Laufzeitkosten-Sprung nach Deploy.** Vergleicht Funktionsaufrufe, Bandbreite und Laufzeit-Dollar der Vercel-Abrechnung in den 24 h vor und nach einem Deploy und meldet „seit dem Deploy von shop-web +60 % Funktionskosten“.
812. [Feature] **★ GitHub-Actions-Minuten mitzählen.** Agenten-Pushes kosten nicht nur Plattform-Builds, sondern auch CI-Minuten; die App liest die Actions-Abrechnung per `gh api` und zeigt sie neben den Build-Kosten in derselben Bilanz.
813. [Feature] **Harte Budgetgrenze für Sammel-Deploys.** Ist das Monatsbudget erreicht, sperrt die App „Alles Geänderte deployen“ und lässt nur noch Einzel-Deploys mit Begründung zu, statt nur zu warnen.
814. [Feature] **Budget pro Projekt oder Kunde.** Eigene Monatsgrenzen je Projekt oder Etikett („Kunde A: 15 $“) mit Warnung bei 80 %, damit ein teurer Kunde nicht im Gesamtbudget untergeht.
815. [Feature] **Build-Maschinen-Berater.** Rechnet aus gemessenen Build-Dauern vor, ob eine kleinere oder größere Vercel-Build-Maschine pro Projekt billiger wäre (schneller × teurer gegen langsamer × billiger).
816. [Feature] **Kosten je ausgeliefertem PR.** Teilt die Kosten eines Deploys auf die enthaltenen PRs auf und zeigt im Journal „PR #42 ≈ 0,12 $“, damit Teams sehen, was kleine Einzel-Deploys gegenüber Bündeln kosten.
817. [Feature] **Kosten nach Urheber (Agent/Mensch).** Trennt die Build-Kosten nach Commits mit und ohne `Co-Authored-By`-Agentenkennung, damit man sieht, welchen Anteil KI-Agenten an der Rechnung haben.
818. [Feature] **Vorschau-Kontingent pro Tag.** Eine einstellbare Zahl Vorschau-Deploys pro Projekt und Tag; darüber fragt die App nach, weil Vorschauen bei vielen Agenten-Branches leise mitkosten.
819. [Feature] **Kosten in Landeswährung.** Rechnet die USD-Beträge mit dem Tageskurs der EZB in Euro (oder eine andere Währung) um und kennzeichnet den Kurs, damit Buchhaltung und Budget in der eigenen Währung stimmen.
820. [Feature] **Rechnungsabgleich am Monatsende.** Legt man die Vercel-Rechnung (CSV/PDF) in die App, vergleicht sie sie mit den gemessenen Builds und markiert Abweichungen, etwa Builds, die nicht aus der App kamen.
821. [Feature] **Build-Zeit-Aufschlüsselung.** Liest aus den Zeitstempeln des Build-Logs, welche Schritte (Install, Build, Upload) wie lange dauern, und zeigt den teuersten Schritt pro Projekt als Balken.
822. [Feature] **Nur-Doku-Änderungen erkennen.** Betreffen alle wartenden Commits nur `*.md`, `docs/` oder Kommentare, kennzeichnet die App das Projekt als „nur Doku“ und schlägt vor, den Build zu sparen.
823. [Feature] **Dienstgröße passend machen.** Liest CPU- und Speicherauslastung von Render-Diensten über die Metriken-API und schlägt einen kleineren Plan vor, wenn ein Dienst dauerhaft unter 20 % läuft.
824. [Feature] **Anbieter-Kostenvergleich.** Rechnet die gemessenen Build-Minuten und Builds pro Monat auf die Preise anderer unterstützter Anbieter um („auf Cloudflare Pages ≈ 0 $, auf Netlify ≈ 7 $“), als Entscheidungshilfe für einen Umzug.
825. [Fun] **CO₂-Schätzung der gesparten Builds.** Rechnet gesparte Build-Minuten grob in Energie und CO₂ um und zeigt es klein neben dem gesparten Geld, mit offengelegter Methode.


### Planung und Zeitfenster

826. [Feature] **★ Deploy-Rhythmus-Berater.** Spielt mit den echten Daten der letzten 30 Tage durch, was täglich, alle zwei Tage oder zweimal pro Woche deployen gekostet hätte und wie lange PRs dann gewartet hätten, und empfiehlt den besten Rhythmus pro Projekt.
827. [Feature] **Ruhigste Stunde vorschlagen.** Liest die Besucherkurve (Vercel Web Analytics) und schlägt für jedes Projekt die verkehrsärmste Stunde als Deploy-Zeit vor.
828. [Feature] **Release-Zug mit Annahmeschluss.** Ein fester Wochentermin („Donnerstag 14 Uhr“) mit Annahmeschluss; alles bis dahin Gemergte fährt mit, Späteres steht sichtbar als „nächster Zug“.
829. [Feature] **Sammelfenster nach dem ersten Merge.** Nach dem ersten wartenden Merge wartet die App eine einstellbare Zeit auf weitere Merges und schlägt dann einen gebündelten Deploy vor, statt sofort zu erinnern.
830. [Feature] **Kalender-Rücksicht.** Liest (mit Erlaubnis) den eigenen Kalender und rät von Deploys kurz vor langen Terminen oder vor dem Urlaub ab, damit niemand ein Problem live stellt und dann weg ist.
831. [Feature] **Urlaubsmodus.** Für einen Zeitraum schaltet die App auf Beobachten, verschiebt Erinnerungen und zeigt Kollegen per geteilter Konfiguration, wer stattdessen deployt.
832. [Feature] **Wochenendbündel für Bot-Updates.** Projekte, in denen nur Dependabot/Renovate-Commits warten, werden gesammelt und einmal pro Woche zu einer festen Zeit zur Bestätigung vorgeschlagen.
833. [Feature] **PR mit Live-Termin.** Ein Label wie `ship:2026-12-01` lässt einen PR bis zu diesem Tag aus der Auswahl heraus und erinnert am Tag selbst, etwa für Kampagnen oder abgesprochene Starts.
834. [Feature] **Wartungsankündigung auf der Statusseite.** Ein geplanter Deploy schreibt vorab „Heute 18 Uhr kurze Aktualisierung“ auf die vorhandene öffentliche Statusseite und räumt den Hinweis danach auf.
835. [Feature] **Countdown bis zum Fensterende.** Die Menüleiste zeigt „Deploy-Fenster schließt in 40 Min“, damit man den Sammel-Deploy nicht knapp verpasst.


### Sicherheit vor dem Deploy

836. [Feature] **★ Lokaler Probe-Build.** Vor dem bezahlten Build läuft auf Wunsch `npm run build` (oder der Build-Befehl des Projekts) lokal auf dem wartenden Stand; scheitert er, wird gar nicht erst bezahlt gebaut.
837. [Feature] **★ Secret-Scan des wartenden Diffs.** Prüft den Diff zwischen Live und Branch-Kopf auf Schlüssel und Tokens (gitleaks-Muster) und blockiert den Deploy mit gelbem Schild, bevor ein versehentlich eingecheckter Schlüssel live geht.
838. [Feature] **★ Branch-Schutz-Falle vor dem Abschalten.** Prüft vor „Auto-Deploy ausschalten“, ob der Vercel- oder Render-Check als Pflicht-Status im Branch-Schutz steht, denn nach dem Trennen kommt dieser Check nie mehr und kein PR lässt sich mergen.
839. [Feature] **Offene Sicherheitswarnungen zeigen.** Liest die Dependabot- und Code-Scanning-Warnungen des Repos und zeigt vor dem Deploy „2 kritische Warnungen offen“ in der Bestätigung.
840. [Feature] **Neue Pakete im Diff.** Listet neu hinzugekommene Abhängigkeiten mit Lizenz und Größe und warnt, wenn sich das Lockfile ohne passende `package.json`-Änderung ändert.
841. [Feature] **Destruktive Migrationen erkennen.** Sucht in wartenden Migrationen nach `DROP`, `TRUNCATE`, Spaltenumbenennungen und `NOT NULL` ohne Standardwert und verlangt dafür eine ausdrückliche Bestätigung.
842. [Feature] **Datenbank-Sicherung vor Migration.** Enthält der Diff Migrationen, bietet die App vor dem Deploy an, ein Backup der Render-Datenbank auszulösen, und wartet, bis es fertig ist.
843. [Feature] **Laufzeit-Version prüfen.** Vergleicht `engines`/`.nvmrc`/`.python-version` im Diff mit der auf der Plattform eingestellten Version und warnt vor einem Build, der an der falschen Node-Version scheitern würde.
844. [Feature] **Neuer Auslöser im Diff.** Fügt ein wartender Commit einen Workflow mit `vercel --prod` oder einen Deploy-Hook-Aufruf hinzu, warnt die App vor dem Deploy, weil das Auto-Deploy durch die Hintertür zurückbringt.
845. [Feature] **Nur signierte Commits.** Pro Projekt einstellbar: Deploy nur, wenn alle wartenden Commits laut GitHub verifiziert signiert sind; sonst nennt die App die unsignierten.
846. [Feature] **Revert-Erkennung.** Enthält der wartende Stapel einen Revert eines Commits, der gerade live ist, sagt die App das ausdrücklich („nimmt die Änderung von gestern zurück“).
847. [Feature] **Vorschau-Pflicht bei Rot.** Bei roter Risiko-Ampel startet die App zuerst eine Vorschau mit Prüfung und gibt Production erst danach frei.
848. [Feature] **Leistungsbudget auf der Vorschau.** Lässt Lighthouse gegen die Vorschau-URL laufen und hält den Production-Deploy an, wenn Performance- oder Barrierefreiheitswert unter ein Budget fällt.
849. [Feature] **Touch ID für Production-Deploys.** Auf dem Mac verlangt ein Production-Deploy (auch über MCP oder URL-Schema ausgelöst) optional Touch ID, damit kein Agent oder Fehlklick allein live schaltet.


### Beobachtung nach dem Deploy

850. [Feature] **★ SEO-Wächter nach dem Deploy.** Prüft nach dem Deploy `robots.txt`, `noindex`-Meta, Sitemap, Titel und OG-Bild der wichtigsten Seiten und schlägt Alarm, wenn etwa ein Staging-`noindex` live gegangen ist.
851. [Feature] **Weiße-Seite-Erkennung.** Vergleicht Titel, Textmenge und HTML-Größe der Startseite vor und nach dem Deploy und meldet „Seite antwortet 200, ist aber fast leer“.
852. [Feature] **JavaScript-Fehler auf der Startseite.** Lädt die Seite nach dem Deploy in einem Headless-Browser und meldet neue Konsolenfehler, die ein reiner HTTP-Check nicht sieht.
853. [Feature] **Klickpfad-Test.** Ein kurzes Playwright-Skript pro Projekt (Login, Warenkorb, Formular) läuft nach dem Deploy und löst bei Fehler die vorhandene Rollback-Abfrage aus.
854. [Feature] **Web-Vitals vorher und nachher.** Zeigt LCP, CLS und INP aus Speed Insights für die Tage vor und nach einem Deploy, damit Leistungsverluste einem Deploy zugeordnet werden.
855. [Feature] **Besucher-Einbruch-Alarm.** Fallen Seitenaufrufe oder ein gewähltes Ereignis (Kauf, Anmeldung) nach dem Deploy deutlich unter den gleichen Wochentag, meldet die App den Verdacht mit Link zum Deploy.
856. [Feature] **Ressourcen-Sprung bei Render.** Liest Speicher und CPU eines Render-Dienstes in der Stunde nach dem Deploy und warnt bei Speicherlecks oder Neustart-Schleifen.
857. [Feature] **Schnittstellen-Bruch erkennen.** Vergleicht nach einem Backend-Deploy das OpenAPI-Dokument mit dem vorigen und warnt, wenn ein Endpunkt fehlt, den das noch nicht deployte Frontend nutzt.
858. [Feature] **Linkprüfer.** Läuft nach dem Deploy über die Sitemap und meldet neue 404-Links und kaputte Weiterleitungen.
859. [Feature] **Sicherheits-Header-Check.** Prüft nach dem Deploy CSP, HSTS, `X-Frame-Options` und gemischte Inhalte und meldet, wenn ein Header verschwunden ist.
860. [Feature] **Log-Vergleich grün gegen rot.** Stellt das Build-Log des letzten erfolgreichen und des fehlgeschlagenen Builds nebeneinander und hebt nur die Zeilen hervor, die neu sind.
861. [Fun] **Seitenvorschau-Kachel.** Nach jedem Deploy ein kleines Bildschirmfoto der Startseite als Kachel in der Zeile, damit man auf einen Blick sieht, was gerade live ist.


### KI-Hilfe

862. [Feature] **★ Fehler-Gedächtnis.** Die App merkt sich lokal Fehlermuster und was danach geholfen hat (Fix-Commit, Autofix-PR) und sagt beim nächsten Mal „Dieser Fehler kam am 3. März schon, damals half ein Lockfile-Update“.
863. [Feature] **KI direkt auf dem Gerät.** Wahlweise erklärt Apples On-Device-Modell (oder ein lokales Modell über Ollama) Build-Fehler und schreibt Release-Notes, ganz ohne API-Schlüssel und ohne dass Logs den Mac verlassen.
864. [Feature] **Fragen an das Journal.** Ein Eingabefeld für Fragen in eigenen Worten wie „Was ging letzte Woche für Kunde A live?“ oder „Wann ist shop-api zuletzt gescheitert?“, beantwortet aus Journal und Git-Verlauf.
865. [Feature] **Deploy-Plan von Claude.** Claude ordnet alle wartenden Projekte in vorgeschlagene Bündel (sicher jetzt, mit Vorschau, lieber morgen) samt Begründung, statt nur ein Projekt einzeln zu prüfen.
866. [Feature] **Rollback oder Vorwärts-Fix.** Scheitert die Prüfung nach dem Deploy, schätzt Claude aus Diff und Fehler, ob ein Rollback oder ein kleiner Fix schneller und sicherer ist, und sagt warum.
867. [Feature] **Smoke-Tests aus dem Code ableiten.** Claude liest die Routen des Repos und schlägt passende Prüfpfade und erwartete Texte für die Prüfung nach dem Deploy vor.
868. [Feature] **Build-Optimierung als PR.** Claude analysiert Build-Log und Konfiguration auf überflüssige Schritte und fehlendes Caching und öffnet einen PR mit den Änderungen, die Minuten pro Build sparen.
869. [Feature] **Fix-PR als Vorschau bauen.** Ein Klick am Autofix-PR baut eine Vorschau dieses Branches, damit man den Fix vor dem Mergen sieht, ohne dass Autofix je selbst deployt.
870. [Feature] **Autofix für Laufzeitfehler.** Für Render `update_failed` und `pre_deploy_failed` nimmt Autofix auf Wunsch die Laufzeit-Logs der ersten Minuten mit, statt nur zu melden.
871. [Feature] **Autofix-Bilanz.** Zeigt pro Projekt, wie viele Übergaben zu einem gemergten Fix führten, wie lange das dauerte und welche Fehlerarten Claude zuverlässig löst.
872. [Feature] **Veraltete Fix-PRs aufräumen.** Ist ein Build inzwischen durch einen anderen Commit grün, schlägt die App vor, den offenen Autofix-PR mit Hinweis zu schließen.
873. [Fun] **Release-Titel von Claude.** Claude gibt jedem Sammel-Deploy einen kurzen Namen aus den PR-Titeln („Neue Suche und schnellerer Checkout“), der in Journal und Release-Notes erscheint.


### Team und Freigaben

874. [Feature] **★ GitHub-Deployments als gemeinsames Journal.** Jeder Deploy aus App oder CLI wird als GitHub-Deployment mit Status am Commit eingetragen, sodass das ganze Team im Repo sieht, was wann von wem live ging, ohne eigenen Server.
875. [Feature] **Team-Deploy-Sperre.** „Ich deploye gerade shop“ setzt über GitHub (Deployment-Status oder Label) eine sichtbare Sperre, die bei Kollegen die Deploy-Knöpfe für dieses Projekt mit Namen ausgraut.
876. [Feature] **Projekt-Verantwortliche.** In `deploy-center.json` je Projekt eine Liste `owners`; nur sie deployen ohne Rückfrage, alle anderen brauchen deren Freigabe.
877. [Feature] **Deploy-Dienstplan.** Eine Wochenrotation in der geteilten Konfiguration legt fest, wer den täglichen Deploy macht; nur diese Person bekommt die Erinnerung.
878. [Feature] **Übergabe-Notiz.** Vor Feierabend oder Urlaub erzeugt die App eine kurze Notiz „was wartet, was rot ist, was offen ist“ als Issue oder Kommentar für die Vertretung.
879. [Feature] **Freigabe-Erinnerung.** Wartet ein Deploy länger als N Stunden auf die Zwei-Personen-Freigabe, erinnert die App die Freigebenden gezielt.
880. [Feature] **Freigabe mit Ablauf.** Eine Freigabe gilt nur einen einstellbaren Zeitraum; danach muss neu freigegeben werden, damit kein alter Haken einen viel späteren Deploy deckt.
881. [Feature] **Team-Budget in der geteilten Konfiguration.** Ein Feld `budget` in `deploy-center.json` gibt allen Macs dieselbe Grenze und dieselbe Warnschwelle.
882. [Feature] **Live-Abo für Projekte.** Teammitglieder abonnieren ein Projekt und bekommen eine Mitteilung, sobald es live geht, ohne selbst zu deployen.
883. [Fun] **Danke-Knopf.** Nach einem erfolgreichen Deploy mit Freigabe kann man dem Freigebenden mit einem Klick ein „Danke“ als PR-Reaktion schicken.


### Benachrichtigungen

884. [Feature] **Eskalationskette.** Wird ein Ausfall nach dem Deploy nicht binnen 30 Minuten quittiert, geht die Meldung zusätzlich ans iPhone und dann an eine zweite Person.
885. [Feature] **Zeitkritische Mitteilungen nur für Ausfälle.** Nur „Production ist down“ kommt als zeitkritische Mitteilung durch den Fokus, alles andere bleibt leise.
886. [Feature] **Mitteilungsregeln pro Projekt.** Je Projekt wählbar: alles, nur Fehler oder stumm bis zu einem Datum, statt einer globalen Einstellung für alle.
887. [Feature] **Zusammenfassung zurückgehaltener Meldungen.** Was nachts oder im Fokus stumm blieb, kommt morgens als eine geordnete Mitteilung statt als Stapel einzelner.


### Mobil

888. [Feature] **★ Apple Watch: Zahl und Freigabe.** Eine Komplikation zeigt wartende PRs und rote Builds, und eine Freigabe oder ein Rollback geht mit Bestätigung direkt am Handgelenk.
889. [Feature] **Freigabe per Push mit Face ID.** Die Zwei-Personen-Freigabe kommt als Mitteilung aufs iPhone und wird nach Face ID als Review oder Label auf GitHub gesetzt.
890. [Feature] **Handoff zwischen Mac und iPhone.** Das gerade geöffnete Projekt oder Build-Log springt per Handoff vom Mac aufs iPhone und zurück.
891. [Feature] **iPad mit Tastatur und Stage Manager.** Tastenkürzel wie am Mac, Liste und Details nebeneinander und mehrere Fenster in Stage Manager.
892. [Feature] **Build-Log auf dem iPhone.** Das Log eines gescheiterten Builds mit „Zur ersten Fehlerzeile“ und „Für Claude kopieren“ auch unterwegs.
893. [Feature] **Fix mit Claude vom iPhone.** Der Knopf „Fix mit Claude“ an roten Projekten auch in der iOS-App, mit denselben Grenzen wie am Mac.
894. [Feature] **Teilen-Erweiterung „Ist das live?“.** Einen PR- oder Commit-Link aus Safari oder GitHub teilen, und die App sagt, ob und seit wann er live ist.
895. [Feature] **Steuerelement im Kontrollzentrum.** Ein iOS-Steuerelement zeigt die Zahl wartender Projekte und öffnet mit einem Tipp die Bestätigung „Alles Geänderte deployen“.
896. [Feature] **Ersparnis-Widget für den Sperrbildschirm.** Ein kleines Widget mit „≈ 41 $ gespart seit …“, auch auf dem iPhone und nicht nur am Mac.
897. [Feature] **Deploy-Wunsch bei schlechtem Netz.** Ohne Verbindung wird ein Deploy-Wunsch vorgemerkt und beim nächsten Netz noch einmal zur Bestätigung gezeigt, statt still zu scheitern.


### Gamification und Motivation

898. [Fun] **Erfolge.** Kleine Abzeichen wie „erster gesparter Dollar“, „100 Builds gespart“, „ein Monat ohne Fehlschlag“, abschaltbar und nur lokal.
899. [Fun] **Deploy-Jahresrückblick.** Im Dezember eine teilbare Karte mit gesparten Builds, längster grüner Serie, schnellstem Deploy und meistdeployter Wochentag, ohne Projektnamen.
900. [Fun] **Ersparnis in echten Dingen.** Die Ersparnis wahlweise als „≈ 14 Kaffee“ oder „eine Jahresdomain“ ausgedrückt.
901. [Fun] **Grüne Serie pro Projekt.** Zählt aufeinanderfolgende erfolgreiche Deploys je Projekt und feiert runde Zahlen dezent.
902. [Fun] **Sparschwein in der Menüleiste.** Bei jedem Meilenstein der Ersparnis eine kurze Animation des Menüleisten-Symbols, bei „Bewegung reduzieren“ aus.
903. [Fun] **Team-Sparliga.** In Team-Konfigurationen eine freiwillige Rangliste, welche Repos am meisten Builds gespart haben, nicht welche Person.
904. [Fun] **Alles-live-Moment.** Ist abends nichts mehr wartend und alles grün, zeigt die App einmal ein kleines „Feierabend“-Bild statt einer leeren Liste.
905. [Feature] **Setup-Reifegrad.** Eine Punktzahl pro Projekt, wie gut es abgesichert ist (Prüfpfad, Rollback bei Fehler, Fenster, Budget, Freigabe), mit dem nächsten sinnvollen Schritt.


### Berichte für Kunden

906. [Pro] **★ Kunden-Abnahme der Vorschau.** Der Kunde bekommt einen Vorschau-Link mit „Freigeben“-Knopf (über GitHub-Label oder signierten Link), und erst danach wird der Production-Deploy freigeschaltet.
907. [Pro] **Kosten-Weiterberechnung mit Aufschlag.** Build- und Laufzeitkosten je Kunde mit frei wählbarem Aufschlag als Rechnungsposten, für Agenturen, die Hosting weiterberechnen.
908. [Pro] **Rechnungsposten exportieren.** Die Kosten je Kunde als Position für gängige Rechnungsprogramme (CSV-Formate von Lexoffice, sevDesk, Stripe-Rechnungen).
909. [Pro] **Wartungsnachweis.** Ein Monatsbericht pro Kunde mit Deploys, Verfügbarkeit, Fehlern und Reaktionszeit, als Beleg für Wartungsverträge.
910. [Pro] **Deploy-Kontingent pro Kunde.** Im Vertrag enthaltene Deploys pro Monat; die App zählt mit und sagt, wann ein Kunde sein Kontingent überschreitet.
911. [Feature] **Kunden-Mail als Entwurf.** Aus den Release-Notes in einfacher Sprache entsteht ein Mail-Entwurf in Mail.app an den hinterlegten Kontakt, den man selbst prüft und sendet.
912. [Feature] **Vorher-Nachher-Bilder im Bericht.** Bildschirmfotos der Vorschau und der vorigen Live-Seite neben den Release-Notes, damit Kunden Änderungen sehen statt lesen.
913. [Feature] **Release-Notes in der Kundensprache.** Neben Deutsch und Englisch jede Sprache, die am Kunden-Etikett hinterlegt ist.


### Onboarding

914. [Feature] **★ Probezeit mit Rückweg.** Auto-Deploy wird für sieben Tage ausgeschaltet; danach zeigt die App die Bilanz und schaltet auf Wunsch alles mit `autodeploy-on` zurück, damit niemand Angst vor dem ersten Schritt hat.
915. [Feature] **Übungsprojekt.** Ein Knopf legt ein kleines Beispiel-Repo mit Vercel-Projekt an, an dem man Deploy, Rollback und Autofix gefahrlos ausprobiert.
916. [Feature] **Erste-Woche-Begleiter.** In den ersten sieben Tagen täglich ein kurzer Tipp passend zum Stand (heute: Prüfpfad setzen, morgen: Budget).
917. [Feature] **Prüfpfad-Assistent.** Die App probiert `/health`, `/api/health`, `/healthz` und `/status` und schlägt den ersten, der sinnvoll antwortet, als Prüfpfad vor.
918. [Feature] **Team-Einladung.** Erzeugt einen Text oder QR-Code mit Installationsbefehl, `deploys team add owner/repo` und dem Hinweis auf die geteilte Konfiguration für neue Kollegen.


### Import und Export

919. [Feature] **★ DORA-Kennzahlen.** Berechnet aus Journal und Git Deploy-Häufigkeit, Durchlaufzeit vom Merge bis live, Fehlerquote und Wiederherstellungszeit pro Projekt und Monat.
920. [Feature] **Geteilte Konfiguration erzeugen.** Ein Knopf schreibt aus den lokalen Einstellungen (Prüfpfade, Fenster, Gruppen, Ignorierte) ein fertiges `deploy-center.json` für das Repo.
921. [Feature] **Vorhandene Konfiguration einlesen.** Liest `vercel.json`, `render.yaml`, `netlify.toml` und Workflows und übernimmt Branch, Ignored Build Step, Prüfpfad und vorhandene Deploy-Hooks als Vorschlag.
922. [Feature] **Einstellungen über iCloud.** Notizen, Pins, Prüfpfade und Fenster gleichen sich zwischen eigenen Macs ab, Schlüssel bleiben ausgenommen.
923. [Feature] **Journal als SQLite.** Export des Journals als SQLite- oder JSON-Datei für eigene Auswertungen, etwa mit Datasette oder einer Tabellenkalkulation.
924. [Feature] **Deploy-Ereignisse als OpenTelemetry.** Sendet Start, Ende und Ergebnis jedes Deploys optional an einen eigenen OTel-Collector, damit sie in vorhandenen Dashboards erscheinen.
925. [Feature] **Umzugs-Checkliste zwischen Anbietern.** Für einen Wechsel etwa von Vercel zu Cloudflare listet die App Umgebungsvariablen-Namen, Domains, Weiterleitungen und Build-Befehl als abhakbare Liste.
926. [Feature] **Projektliste als Markdown.** Eine Tabelle aller Projekte mit Plattform, Repo, Prüfpfad und Verantwortlichen zum Einfügen ins Wiki oder README.


### Automatisierung

927. [Feature] **Wenn-dann-Regeln.** Ein kleiner Regel-Editor („wenn Label `hotfix` und CI grün, sofort zur Bestätigung vorschlagen“), der nur Vorschläge macht und nie ohne Klick deployt.
928. [Feature] **Vorschau per Label.** Ein Label `preview` an einem PR baut eine Vorschau dieses Branches und kommentiert den Link, als Ersatz für die PR-Vorschauen, die mit der Git-Verbindung wegfallen.
929. [Feature] **Nach-Live-Aktionen.** Pro Projekt Skripte, die nach erfolgreichem Deploy laufen: CDN-Cache leeren, Suchindex neu aufbauen, Sitemap an Suchmaschinen melden.
930. [Feature] **Eigene Vorab-Prüfungen.** Ein Skript pro Projekt, das vor dem Deploy läuft (etwa ein Migrationstest gegen eine Kopie) und bei Exit ≠ 0 den Deploy anhält.
931. [Feature] **Archiv-Vorschlag für tote Projekte.** Projekte ohne Commit und ohne Besucher seit 90 Tagen schlägt die App zum Ausblenden oder Pausieren vor.


### Barrierefreiheit

932. [Feature] **Namen für Sprachsteuerung.** Jeder Knopf und jede Zeile hat einen sprechbaren Namen, sodass „Klick shop-web deployen“ mit der macOS-Sprachsteuerung funktioniert.
933. [Feature] **Schaltersteuerung.** Feste, kurze Fokus-Reihenfolge und große Ziele, damit sich ein Deploy mit Schaltersteuerung in wenigen Schritten bestätigen lässt.
934. [Feature] **Bewegung reduzieren.** Fortschrittsbalken, Spinner und Animationen folgen der Systemeinstellung und werden durch Text wie „baut · 1:05 von ≈ 2:30“ ersetzt.
935. [Feature] **Gesprochene Zusammenfassung.** Ein Knopf (und ein Kurzbefehl) liest den Tagesstand in ganzen Sätzen vor, für Menschen, die Zahlenzeilen schwer erfassen.
936. [Feature] **Leichte Sprache.** Ein Modus mit kurzen Sätzen ohne Fachwörter („3 Seiten haben neue Änderungen, die noch nicht online sind“).
937. [Feature] **Haptik auf iPhone und Watch.** Unterschiedliche Vibrationen für live, Fehler und Rollback, damit man das Ergebnis ohne Hinsehen spürt.
938. [Feature] **Ein-Knopf-Modus.** Eine reduzierte Ansicht zeigt nur die eine empfohlene nächste Handlung („2 Projekte deployen“ oder „Fehler ansehen“), zur Entlastung bei vielen Projekten.
939. [Fun] **Hörbarer Status.** Ein kurzer Klang beim Öffnen der Menüleiste sagt den Gesamtstand an (alles live, wartet, rot), für blinde Nutzer und als Spielerei.


### Monetarisierung (Pro)

940. [Pro] **★ Optionaler Cloud-Runner.** Gegen Gebühr übernimmt ein gehosteter Dienst geplante Deploys, Prüfungen und Autofix, wenn der Mac schläft; die App bleibt ohne ihn voll nutzbar.
941. [Pro] **Agentur-Lizenz mit Kundenportal.** Eigenes Logo und eigene Domain für Berichte, Statusseite und Abnahme-Links, mehrere Kunden-Arbeitsbereiche in einer App.
942. [Pro] **Lange Historie und Auswertungen.** Journal, Kosten und Kennzahlen über Jahre statt Wochen, mit Vergleich zum Vorjahr.
943. [Pro] **Gehostete Autofix-Routine.** Autofix ohne eigene Routine-Einrichtung: ein Klick, ein Kontingent an Fix-Versuchen pro Monat.
944. [Pro] **Zahle, was du sparst.** Freiwilliges Modell: ein kleiner Anteil der gemessenen Ersparnis als Vorschlag für eine Unterstützung, nie mehr als die Ersparnis selbst.
945. [Pro] **Sponsoren zuerst.** Neue Funktionen erscheinen für GitHub-Sponsoren einige Wochen früher und danach für alle unter MIT.
946. [Pro] **Team-Lizenz über die GitHub-Organisation.** Plätze werden über die Mitgliedschaft in einer GitHub-Organisation vergeben, ohne eigenes Konto.
947. [Pro] **iOS Pro.** Mehrere Konten, Watch-Freigabe und Kundenberichte in der iPhone-App als einmaliger Kauf.
948. [Pro] **Einrichtungsservice.** Bezahlter Termin, bei dem Konten, Team-Konfiguration, Prüfpfade und Autofix gemeinsam eingerichtet werden.


### Ökosystem

949. [Feature] **★ Tickets gehen live.** Erkennt Linear-, Jira- und GitHub-Issue-Nummern in den wartenden PRs, zeigt „diese 5 Tickets gehen live“ und setzt sie nach dem Deploy auf Wunsch auf „Erledigt“.
950. [Feature] **Mobile Builds als Anbieter.** Expo EAS, Xcode Cloud und Codemagic als Anbieter, weil gerade Mobil-Builds teuer sind und von Agenten-Pushes genauso ausgelöst werden.
951. [Feature] **Datenbank-Branch zur Vorschau.** Bei einer Vorschau legt die App optional einen Neon- oder Supabase-Branch an und räumt ihn danach wieder ab.
952. [Feature] **Deploy-Markierung in Monitoring-Tools.** Setzt nach jedem Deploy eine Markierung bzw. einen Release in Sentry, Grafana oder Datadog, damit Kurven den Deploy zeigen.
953. [Feature] **Changelog nach Notion oder Confluence.** Die Release-Notes jedes Deploys landen auf Wunsch als neuer Eintrag in einer gewählten Seite oder Datenbank.
954. [Feature] **Zapier, Make und n8n.** Ereignisse („live“, „fehlgeschlagen“, „wartet seit 3 Tagen“) als Auslöser für eigene Abläufe in gängigen Automatisierungsdiensten.
955. [Feature] **Zeiterfassung.** Deploys und Fehlerbehebungen je Kunde als Einträge für Toggl oder Harvest, damit Agenturen den Aufwand abrechnen können.
956. [Feature] **Schlüssel aus dem Passwortmanager.** Render-Key und andere Tokens wahlweise über die 1Password- oder Bitwarden-CLI lesen statt aus dem Schlüsselbund, praktisch für Teams mit gemeinsamem Tresor.
957. [Feature] **JetBrains- und Zed-Erweiterung.** Dieselbe Statusanzeige und Bestätigung wie in der VS-Code-Erweiterung auch für IntelliJ, WebStorm und Zed.
958. [Feature] **Verzeichnis für Anbieter-Module.** Eine Liste geprüfter Community-Module in `providers/` mit Testergebnis, damit neue Plattformen ohne Release der App dazukommen.
959. [Fun] **Stream-Deck-Tasten.** Tasten mit Live-Zahl wartender Projekte, Ampel pro Projekt und „Deploy“ mit doppeltem Druck zur Bestätigung.
960. [Fun] **Home Assistant.** Ein Sensor mit dem Deploy-Stand, damit etwa eine Lampe rot leuchtet, wenn Production ausfällt.
961. [Fun] **Deploy-Tagebuch in Notizen.** Jeder Tag mit Deploys schreibt eine kurze Zeile in Obsidian oder Apple Notizen, als persönliches Arbeitsprotokoll.
