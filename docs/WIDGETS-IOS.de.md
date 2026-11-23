# Widgets und die iOS-App: die Entscheidungen

Die deutsche Fassung von [WIDGETS-IOS.md](WIDGETS-IOS.md). Verlinkte Seiten ohne eigene deutsche Fassung sind englisch.

Stand:
- **Mac-Widget:** baut und wird lokal signiert. Klein, mittel und groß.
- **iOS-App:** Liste, Details, Deploy, Abbrechen und Rollback mit Face ID, Hinweise im Hintergrund, Widgets auf
  dem Home-Bildschirm (klein bis extragroß) und dem Sperrbildschirm. Verbindet sich mit der Mac-App über iCloud-
  Schlüsselbund oder einen QR-Code. In TestFlight; der QR-Code wurde auf einem echten iPhone getestet (siehe „Was geprüft wurde“).

Die iPhone-App und ihre Widgets zeigen **nur Vercel- und Render**-Projekte; die anderen Hosts gibt es auf dem Mac und in der CLI.

Das Mac-Widget ist Entscheidung 1; alles danach betrifft die iOS-App.

Schritte im Apple-Developer-Konto des Inhabers stehen am Ende und in `docs/APP-STORE.md`.

## Entscheidung 1: wie das Mac-Widget in die App kommt

**Gewählt: die Erweiterung mit `swiftc` in `build.sh` bauen, optional mit `--widgets`.**

| | swiftc in build.sh (gewählt) | XcodeGen für die Erweiterung | Der ganze Mac-Build als Xcode-Projekt |
|---|---|---|---|
| Neue Werkzeuge | keine | XcodeGen auf jedem Build-Mac | keine, aber ein `.xcodeproj` |
| Normaler Build | unverändert, kein Xcode nötig | unverändert | braucht Xcode; alles ändert sich |
| Signieren | in unserem Skript, sichtbar | Xcodes automatische Signatur | die von Xcode |
| Risiko | Schritte, die später nur Xcode kann (App-Intents-Metadaten für konfigurierbare oder interaktive Widgets) | ein zweites Build-System | die größte Änderung |

- `./build.sh` ohne das Flag baut, was es vorher gebaut hat. Es gibt keinen `PlugIns`-Ordner.
- `./build.sh --widgets` kompiliert `widgets/*.swift` und `shared/*.swift` zu
  `Contents/PlugIns/DeployCenterWidgets.appex`. Signiert wird in dieser Reihenfolge:
  1. die Erweiterung, mit Sandbox und App Group;
  2. die App, mit der App Group, ohne `--deep`.
- Eine WidgetKit-Erweiterung braucht nichts, was nur Xcode kann:
  - `-application-extension`;
  - ein normales `@main` (`LC_MAIN`, wie bei Apples eigenen Widgets);
  - `CFBundlePackageType = XPC!`;
  - `NSExtensionPointIdentifier = com.apple.widgetkit-extension`.

### Woher das Mac-Widget seine Daten hat

Nach jedem Neuladen der Listen oder der Kosten schreibt die App `snapshot.json` in den Container der
App Group. Die Datei ist ein paar KB groß; ihr Format steht in `shared/DeploySnapshot.swift`. Danach bittet die App
WidgetKit um ein Neuladen, und nur, wenn sich etwas geändert hat.

- **App Group:** `<TEAMID>.app.deploycenter`. Unter macOS braucht eine Gruppe mit der Team-ID als Präfix kein
  Provisioning-Profil.
  - `build.sh` nimmt die Team-ID aus der Signatur-Identität.
  - Es schreibt die Team-ID in die Entitlements und in einen Info.plist-Schlüssel (`DCAppGroup`).
  - Keine Team-ID steht im Repo.
- **Ad-hoc-Build** (`DEVELOPER_ID=-`): es gibt keine Gruppe, also wird nichts geschrieben. Die Galerie-Vorschau
  zeigt Beispielzahlen.
- **Demo-Modus** verdeckt Namen und Commit-Nachrichten im Snapshot.
- **Ein Tipp** öffnet `deploycenter://`.
- **Kleines Widget:** wartende PRs, Projekte, im Bau und fehlgeschlagen. **Mittleres:** dasselbe, dazu die obersten 3
  Projekte und die Ersparnis im Monat.

## Entscheidung 2: woher die iOS-App ihre Daten hat und wie sie deployt

Das Ziel: unterwegs sehen, was wartet, deployen, zurückrollen und Hinweise bekommen, auch wenn der Mac schläft.
Es gibt keinen Server von uns.

| | **A: das Handy spricht mit den APIs (gewählt)** | B: eine Befehlswarteschlange in iCloud, der Mac führt sie aus |
|---|---|---|
| Geht bei schlafendem oder ausgeschaltetem Mac | ja | nein, wartet auf den Mac |
| Tokens auf dem Handy | ja, im Schlüsselbund, nur dieses Gerät | nein |
| Schritte im Apple-Konto | keine über die App-ID hinaus | iCloud-Container + Developer-ID-Profil für die Mac-App |
| Dieselbe „wartet“-Regel wie am Mac | aus `deploys` übernommen | die des Macs selbst |
| Deploy-Sicherheit | Face ID auf dem Handy, dann die API des Anbieters | der Mac müsste bestätigen (Fernausführung) |

**Gewählt: A.** Die App ruft `api.vercel.com`, `api.render.com` und `api.github.com` mit den
eigenen Tokens der Person auf. Das sind die Endpunkte, die auch die `deploys`-CLI nutzt:

- **Vercel**
  - Listen: `/v10/projects`, und `/v6/deployments?target=production` für den neuesten Versuch.
  - Deploy: `POST /v13/deployments` mit `gitSource {type: github, ref, repoId}`.
  - Status: `GET /v13/deployments/{id}`.
  - Rollback: `POST /v1/projects/{id}/rollback/{deployment}`. Das Ziel ist der vorherige READY-
    Produktions-Deploy mit einem anderen Commit.
  - Auto-Deploy auszuschalten entfernt die Git-Verbindung. Das Repo kommt dann aus
    `meta.githubCommit*` des Live-Deploys.
- **Render**
  - Listen: `/services` und `/services/{id}/deploys`.
  - Deploy: `POST /services/{id}/deploys`.
  - Rollback: `POST /services/{id}/rollback`. Das Ziel ist der neueste deaktivierte Deploy mit
    einem anderen Commit.
  - POSTs werden nie wiederholt.
- **GitHub**
  - Der Branch-Kopf, und `compare/{live}...{branch}` für die wartenden Commits.
  - PR-Nummern aus den Commit-Nachrichten: `(#12)` oder `Merge pull request #12`.
  - Für bis zu zehn Commits ohne Nummer: `commits/{sha}/pulls`.
- **„Wartet“** nutzt die Regel aus `deploys`. Ein Projekt wartet, wenn alles davon zutrifft:
  - es ist deploybar und nicht pausiert;
  - es baut nicht;
  - sein Kopf ist bekannt und es gab keinen Lesefehler;
  - es liegt nicht zurück;
  - der Live-Commit weicht vom Kopf ab.

Auch erwogen und nicht gewählt: ein GitHub-Workflow (`integrations/action` mit `deploy: true`),
gestartet per `workflow_dispatch`.
- Er braucht in jedem Repo eine Workflow-Datei.
- Er braucht ein Token mit `actions:write`.
- Er deployt jedes geänderte Projekt, nicht das angetippte.

**B bleibt optional** und ist nicht gebaut. Es hilft nur Leuten, die keine Tokens auf dem Handy wollen,
und braucht die Schritte im iCloud-Konto.

### Hinweise bei geschlossener App

Ohne Server geht das nur nach bestem Bemühen.
- **Hintergrundaktualisierung:** eine `BGAppRefreshTask` liest die Listen und zeigt eine lokale Mitteilung für
  alles, was neu wartet oder fehlschlug. iOS entscheidet, wann sie läuft, meist höchstens ein paar Mal pro Stunde. Die
  Einstellungen sagen das.
- **Einem Deploy folgen:** die App fragt den Deploy ab, den sie gestartet hat. Geht sie in den Hintergrund, kauft eine
  Hintergrundaufgabe etwa eine halbe Minute, und unter iOS 26 läuft eine fortgesetzte Verarbeitungsaufgabe weiter, mit einem
  Fortschritt im System, bis der Deploy endet oder iOS sie stoppt. Das Ende kommt als Mitteilung.
- **Live Activity:** ein in der App gestarteter Deploy oder Rollback erscheint auf dem Sperrbildschirm und in der
  Dynamic Island (IOS-122, unten). Ohne Server wird sie nur aktualisiert, solange die App läuft; eine, die
  bei geschlossener App aktualisiert, bräuchte Push von einem Server (APNs).

### Tokens und Face ID

- Auf dem Handy getippte Tokens werden mit `kSecAttrAccessibleAfterFirstUnlockThisDeviceOnly` gespeichert:
  - nie synchronisiert und nicht in Backups;
  - nach dem ersten Entsperren von der Hintergrundaktualisierung lesbar.
- Tokens vom Mac kommen über den iCloud-Schlüsselbund (Entscheidung 4). Ein auf dem Handy getipptes Token gewinnt.
- Jeder Deploy, Abbruch und Rollback fragt zweimal:
  1. eine Bestätigung, die nennt, was live geht (der neueste Commit, wie viele Commits und PRs);
  2. `LAContext` mit `.deviceOwnerAuthentication`: Face ID, Touch ID oder der Code.
- Was Face ID ehrlich schützt: einen Deploy, der durch einen Fingerrutscher startet oder von jemandem, der das
  entsperrte Handy kurz in der Hand hat. Es ist eine Prüfung in der App, kein Schloss an den Schlüsseln: wer das
  entsperrte Gerät kontrolliert (oder ein Jailbreak-Gerät), kann die Schlüsselbund-Einträge der App ohne sie lesen.
- Die App folgt der Sprache, die iOS für sie wählt (Einstellungen → Deploy Center → Sprache), Englisch oder
  Deutsch; die Widgets folgen der App.

## Entscheidung 3: wie die iOS-App gebaut wird

**Gewählt: ein kleines, von Hand geschriebenes Xcode-Projekt, `ios/DeployCenter.xcodeproj`. Kein XcodeGen.**

- Es nutzt ordnersynchronisierte Gruppen ab Xcode 16. Die Projektdatei nennt drei Ordner und keine
  einzelne Datei:
  - `ios/App`;
  - `widgets` (derselbe Widget-Code wie am Mac);
  - `shared`.
- Ein App-Store-Build braucht ohnehin ein Projekt: Archiv, Export, Provisioning.
- Das frühere `swiftc`-Skript für den Simulator ist weg. `ios/build.sh` ruft jetzt `xcodebuild` auf.
- Zwei Info.plist-Einträge lassen sich nicht aus Build-Einstellungen erzeugen. Sie liegen in `ios/Config/`:
  - die Schlüssel der Hintergrundaktualisierung, in `Info.plist`;
  - das `NSExtension` des Widgets, in `Widgets-Info.plist`.

```bash
ios/build.sh --run
```

```bash
ios/build.sh --archive
```

Was `--archive` tut:
- es nimmt die Team-ID beim Bauen aus der Signatur-Identität;
- es exportiert eine `.ipa` und lädt nichts hoch;
- es nutzt `-allowProvisioningUpdates`, was die App-IDs und Profile im Konto registrieren kann.
  Darum läuft es erst, wenn der Inhaber zustimmt.

Mehr zum iOS-Build:
- **iOS-App-Group:** `group.app.deploycenter`. Keine Team-ID im Namen. Sie muss
  einmal registriert werden.
- **iOS-Widget:** der Code des Mac-Widgets, für iOS gebaut. Die App schreibt den Snapshot nach jedem
  Neuladen. Im Simulator wird das Widget mit der App installiert; auf einem Gerät muss die App Group
  registriert sein.

## Entscheidung 4: die iPhone-App verbindet sich mit der Mac-App

**Gewählt: die Apple-ID ist das Konto. Der Mac gibt seine Schlüssel über den iCloud-Schlüsselbund weiter, oder als
QR-Code. Kein Konto und kein Server von uns.**

Ein eigenes Konto mit Server würde die Deploy-Tokens aller Nutzer halten: eine große Last, und das Ende
von „Daten werden nicht erhoben“.

- **iCloud-Schlüsselbund** (`shared/PhoneLink.swift`): Mac-App → Einstellungen → iPhone → „Mit der iPhone-App
  verbinden“. Sie schreibt einen synchronisierbaren Schlüsselbund-Eintrag in die Schlüsselbundgruppe des Teams
  `<TEAMID>.app.deploycenter.shared`: das für das Handy erstellte Vercel-Token, die Vercel-Team-ID, den
  Render-Schlüssel und das GitHub-Token der gh-CLI. Der iCloud-Schlüsselbund trägt ihn, Ende-zu-Ende-verschlüsselt, zu den
  Geräten mit derselben Apple-ID. Den Schalter auszuschalten entfernt ihn überall.
  - Das Handy liest GitHub nur, aber das Token der gh-CLI hat meist die Rechte `repo` und `workflow`.
    Die Einstellungen des Handys zeigen die Scopes eines klassischen Tokens (`X-OAuth-Scopes`) und schlagen, wenn es
    schreiben kann, ein fein granulares Token mit reinem Lesezugriff auf Inhalte und Pull Requests vor, auf dem
    Handy getippt (ein dort getippter Schlüssel gewinnt gegen den des Macs).
  - Die eigene Anmeldung der vercel-CLI ist kurzlebig (sie hat `expiresAt`), darum bekommt das Handy ein eigenes,
    langlebiges Vercel-Token, gespeichert in der Mac-App.
  - macOS erlaubt die Schlüsselbundgruppe nur mit eingebettetem Provisioning-Profil: dem Developer-ID-
    Profil von `app.deploycenter.mac`. `build.sh` bettet es aus `DC_MAC_PROFILE` oder
    `~/.config/deploys/mac-developer-id.provisionprofile` ein (nie im Repo, es nennt das Team).
    Ohne es baut die Mac-App ohne die iCloud-Verbindung.
  - iOS: `keychain-access-groups` in `ios/Config/DeployCenter.entitlements`; der Gruppenname kommt aus
    dem Info.plist-Schlüssel `DCKeychainGroup` (`$(DEVELOPMENT_TEAM)`), darum haben Simulator-Builds ohne
    Team keine Verbindung. `ios/build.sh --archive` setzt `$(AppIdentifierPrefix)` vor seiner Ad-hoc-
    Signatur ein.
- **QR-Code**: der Mac zeigt auf Wunsch dieselben Schlüssel 60 Sekunden lang als QR-Code. Die iPhone-App
  scannt ihn unter „Mit dem Mac verbinden“ (Kamera in der App; oder „Einsetzen“ für den Text des Codes), zeigt, was
  der Code enthält, und behält die Schlüssel erst nach „Verbinden“, und nur auf dem Handy.

### Der QR-Code: was er enthält und wer ihn lesen kann

- **Was drin ist:** das für das Handy erstellte Vercel-Token, die Vercel-Team-ID, der Render-Schlüssel, das GitHub-Token
  der gh-CLI und der Zeitpunkt der Erstellung. Base64-JSON hinter `deploycenter-link:1:`. Nicht
  verschlüsselt: wer den Code lesen kann, hat die Schlüssel.
- **Wer ihn lesen kann:** jede Kamera, die den Bildschirm des Macs sieht, solange er angezeigt wird (60 Sekunden): jemand
  hinter dir, ein Videoanruf mit Bildschirmfreigabe, eine Bildschirmaufnahme. Der Mac sagt „zeig ihn niemandem“.
- **Wie lange er gilt:** die iPhone-App lehnt einen Code ab, der vor mehr als fünf Minuten erstellt wurde (damit
  leicht abweichende Uhren nicht stören). Ein Foto des Bildschirms ist danach für diese App nutzlos. Die Schlüssel
  darin bleiben gültig, solange der Anbieter sie behält.
- **Wie du widerrufst:** lösche das Token bei Vercel (Account → Tokens), den Schlüssel bei Render (Account
  Settings → API Keys) oder das GitHub-Token. Auf dem Handy entfernt „Schlüssel auf diesem iPhone löschen“
  die Kopien dort.
- **Nicht gemacht:** den Code mit einer kurzen, am Handy getippten Zahl zu verschlüsseln. Das würde jeden einen
  Schritt kosten; die Fünf-Minuten-Grenze deckt den Foto-Fall ab.

### Wenn der iCloud-Schlüsselbund nichts bringt

| Was du siehst | Übliche Ursache | Lösung |
|---|---|---|
| „Nicht verfügbar in dieser Version“ | der Build hat keine Team-ID (Simulator, ein Build aus dem Quelltext) | den QR-Code nutzen |
| „Noch nichts angekommen“ über Minuten | der iCloud-Schlüsselbund (Passwörter) ist am Mac oder am iPhone aus | Systemeinstellungen / Einstellungen → Apple-Account → iCloud → Passwörter |
| Dasselbe, bei eingeschalteten Passwörtern | Mac und iPhone nutzen verschiedene Apple-Accounts | mit demselben anmelden, oder den QR-Code nutzen |
| Der Mac meldet, er konnte nicht schreiben (Fehler −34018) | die Mac-App wurde ohne ihr Developer-ID-Profil gebaut | die veröffentlichte App installieren, oder den QR-Code nutzen |
| „Der Schlüssel vom Mac wurde abgelehnt“ | das Token des Macs wurde gelöscht oder ist abgelaufen | in der Mac-App ein neues erstellen (Einstellungen → iPhone) |

### Was die iPhone-App sonst noch kann (nur lesend, außer wo Face ID steht)

- **Build-Log (IOS-118).** Ein fehlgeschlagenes Projekt und jeder Deploy in seinem Verlauf zeigt das Build-Log ab
  kurz vor der ersten Fehlerzeile (sonst die letzten Zeilen). Vercel: die Ereignisse des Deployments, Render:
  die Build-Logs im Zeitfenster des Deploys, dieselben Aufrufe wie `deploys logs`. Geheimnisse werden von
  `ios/App/LogMask.swift` maskiert, einer Portierung von `af_mask` in `deploys` mit denselben Regeln in derselben Reihenfolge.
  Das ganze Log wird maskiert, bevor irgendetwas gekürzt, behalten, gezeigt oder kopiert wird; lässt sich ein Muster nicht
  kompilieren, wird nichts gezeigt. „Kopieren“ legt das maskierte Log nur auf die Zwischenablage dieses Geräts, für zehn
  Minuten. Tests: `ios/Tests/run.sh` (swiftc, kein Simulator) vergleicht die Portierung Zeile für Zeile mit der
  eigenen Ausgabe von `af_mask` für denselben Text (`ios/Tests/fixtures/mask-out.txt`). Ändert sich
  `af_mask`, erzeuge diese Datei damit neu und halte die Portierung im Gleichschritt.
- **Verlauf (IOS-120).** Die letzten 15 Produktions-Deploys; ein gebauter kann wieder live gehen (ein Rollback
  darauf, mit Face ID).
- **Render-Dienste (IOS-132).** Pausieren, fortsetzen, neu starten, jeweils mit Face ID.
- **Live Activity (IOS-122).** Ein in der App gestarteter Deploy oder Rollback erscheint auf dem Sperrbildschirm und
  in der Dynamic Island, mit seinem Zustand und einer laufenden Uhr. Es gibt keinen Push-Server: sie wird nur
  aktualisiert, solange die App läuft; nach 90 Sekunden ohne Update sagt sie, wie alt sie ist und dass du die
  App öffnen sollst. `ios/Common/DeployActivity.swift` wird in die App und die Erweiterung gebaut.
- **Siri und Kurzbefehle (IOS-123).** „Was wartet in Deploy Center“, „Fehlgeschlagene Deploys in Deploy Center“:
  beantwortet aus dem zuletzt gespeicherten Stand der App, mit seinem Alter. Kein Deploy per Sprache: ein Deploy fragt
  in der App nach Face ID.
- **Schnellaktionen, Spotlight, Handoff (IOS-133, IOS-129).** Das Menü des App-Symbols hat Aktualisieren und die
  Projekte, die einen Blick brauchen. Projekte erscheinen in Spotlight (nicht im Demo-Modus). Ein offenes Projekt geht auf
  einem anderen iPhone oder iPad weiter; die Mac-App übernimmt es noch nicht.
- **Mitteilungsaktionen (IOS-124).** Öffnen und Heute stumm (nur Neuigkeiten der Hintergrundaktualisierung;
  das Ende eines in der App gestarteten Deploys kommt weiterhin).
- **Nächster geplanter Deploy (IDEEN-9 #61).** Ein drittes Widget zeigt das Projekt, das ein Zeitplan als Nächstes deployt, und einen live laufenden Countdown (`Text(date, style: .relative)`); klein und mittel, nur am Mac (der Zeitplan lebt am Mac; der iPhone-Snapshot enthält ihn nie, ein Widget dort würde also immer „Kein Deploy geplant“ sagen). Es liest das optionale `nextScheduled` des Snapshots; ohne es, oder wenn die Zeit vorbei ist, sagt es „Kein Deploy geplant“ (oder „Veraltet“ bei einem alten Snapshot). Die Mac-App füllt das Feld aus `deploys schedule daily`; es ist nur lesend und startet nie einen Deploy.
- **Deploy aus einer Mitteilung (IDEEN-9 #63).** Die „wartet“-Mitteilung hat die Aktion „Mit Face ID deployen“ (braucht das entsperrte Gerät, öffnet die App). Die App lädt bei Bedarf neu, deployt nur, wenn das Projekt noch wartet, und durchläuft denselben Face-ID-Schritt wie ein Tipp in der Liste.
- **Widgets.** Ein zweites Widget, „Fehlgeschlagene Deploys“, listet nur, was fehlschlug oder baut (Mac und iPhone).
  Unter iOS 18 zeigt ein Steuerelement für das Kontrollzentrum, den Sperrbildschirm und die Aktionstaste die wartenden PRs
  und öffnet die App; es liest nur den Snapshot, die Erweiterung hält keine Schlüssel.

### Privacy-Manifest (IOS-114)

`ios/App/PrivacyInfo.xcprivacy` erklärt die APIs mit Pflichtgrund, die die App nutzt: `UserDefaults`
(CA92.1, die eigenen Einstellungen der App) und Dateizeitstempel (C617.1: das Änderungsdatum der eigenen
`last-projects.json` der App, für „Stand“). Die Widget-Erweiterung hat kein eigenes Manifest, weil sie keine
dieser APIs nutzt: sie liest den Inhalt der Snapshot-Datei, nicht ihre Daten, und kein `UserDefaults`. Prüfe
erneut, wenn die Erweiterung oder `shared/` anfangen, `UserDefaults`, Dateidaten, Speicherplatz oder Laufzeit zu nutzen.

## Was geprüft wurde und was nicht

Auf diesem Mac geprüft:
- **Normaler Build:** `./build.sh --fast` baut ohne `PlugIns`. App-Tests laufen durch; shellcheck ist sauber.
- **Widget-Build:** `./build.sh --fast --widgets` mit der Developer ID.
  - Die App trägt die App Group.
  - Die Erweiterung trägt Sandbox und App Group.
  - `codesign --verify --strict --deep` läuft durch.
  - `pluginkit` listet die Erweiterung.
- **Echte Konten, nur lesend:** der API-Code der App (`ios/App/Clients.swift`, `Project.swift`),
  für macOS kompiliert, las die Vercel-, Render- und GitHub-Konten des Inhabers nur mit GET-Anfragen:
  - er fand dieselben wartenden Projekte wie `deploys changed --json`;
  - er fand für jedes dieselben Commit- und PR-Zahlen;
  - er hatte keine Lesefehler.
  Deploy und Rollback wurden nicht an echten Konten versucht.
- **iOS:** die App und ihre Widget-Erweiterung bauen mit `xcodebuild` für den Simulator. Sie laufen im
  Demo-Modus auf einem iPhone 17 Pro Max und einem iPad-Pro-Simulator (13 Zoll). Die Screenshots liegen in
  `ios/AppStore/screenshots/`.

- **Mac-Verbindung:** die Mac-App, mit dem Developer-ID-Profil signiert, startet und schreibt und liest
  den synchronisierbaren Eintrag in der gemeinsamen Schlüsselbundgruppe.
- **Neu in dieser Runde (nur Simulator):** alles oben baut für den Simulator und das Mac-Widget
  baut weiter mit `./build.sh --widgets`. Das Build-Log mit seiner Maskierung wurde im Demo-Modus gesehen. Die Live Activity, das Steuerelement, die Schnellaktionen, Siri und die Mitteilungsaktionen wurden nicht
  auf einem Gerät ausprobiert, und das Log, der Verlauf und die Render-Aufrufe nicht an echten Konten.
- **QR-Code:** TestFlight-Build 2 auf dem iPhone des Inhabers verband sich mit der Mac-App, indem er
  ihren Code scannte.

### Testplan für echte Deploys (Inhaber, mit einem Wegwerfprojekt)

Nimm ein Vercel-Projekt und einen Render-Dienst, die dafür angelegt wurden, mit ausgeschaltetem Auto-Deploy.
1. **Deploy:** einen Commit pushen, auf „wartet“ warten, vom Handy deployen. Erwartet: „ist live“ und die Zeile
   wieder unter „Aktuell“.
2. **Abbrechen:** noch einmal deployen, während des Baus „Build abbrechen“ tippen. Erwartet: „abgebrochen“, und der alte
   Deploy bleibt live.
3. **Rollback:** zurückrollen. Erwartet: der vorherige Commit ist live (Vercel: die Domain zeigt darauf; Render:
   ein neuer Deploy des alten Commits).
4. **Hintergrund:** einen Deploy starten und das Handy sperren. Erwartet: eine Mitteilung am Ende (iOS 26), oder
   der richtige Zustand, wenn die App wieder aufgeht.
5. **Verlorene Antwort:** einen Deploy im Flugmodus starten, direkt nach dem Tippen auf „Deployen“ (schwer zu
   timen): die App sollte den laufenden Deploy finden, statt Fehlschlag zu melden.
6. **Zeitlimit:** ein Build, der länger als 20 Minuten dauert, endet mit „kein Endzustand“, nicht mit Schweigen.

Nicht geprüft:
- **iCloud-Schlüsselbund zwischen Mac und iPhone:** braucht TestFlight-Build 2 auf einem echten iPhone.
- **Die Widget-Galerie:** das Mac-Widget wurde dort nicht geöffnet. Das braucht den Bildschirm, und diese
  Sitzung hatte keinen Zugriff darauf. Zum Prüfen: Rechtsklick auf den Schreibtisch → Widgets bearbeiten → „Deploy“ suchen.
- **Echte Deploys:** Deploy, Abbruch, Rollback und die Statusabfrage liefen nie an echten Konten
  (Testplan oben). `ios/test.sh` prüft die Rollback-Ziele, die Regel und die GitHub-Lesezugriffe nur gegen
  ausgedachte Antworten. Die fortgesetzte Verarbeitungsaufgabe (iOS 26) baut, wurde aber nicht auf einem Gerät ausprobiert.
- **Vercel-Teams:** bei mehreren Teams und ohne gesetzte Team-ID liest die App das persönliche Konto.
  Die Einstellungen haben ein Feld für die Team-ID.
- **Simulator:** Face ID, die Hintergrundaktualisierung, Mitteilungen, die Sperrbildschirm-Widgets und das iOS-
  Widget auf dem Home-Bildschirm wurden nicht ausprobiert. Um die Hintergrundaktualisierung im Debugger zu starten: die
  App anhalten und
  `e -l objc -- (void)[[BGTaskScheduler sharedScheduler] _simulateLaunchForTaskWithIdentifier:@"app.deploycenter.ios.refresh"]`
  ausführen, dann fortsetzen. VoiceOver wurde ebenfalls nicht ausprobiert. Große Schrift (Bedienungshilfen-Größen) wurde
  geprüft: die Zusammenfassung wechselt auf zwei Zeilen.
- **Gerät und Store:** kein Geräte-Build von hier. Archive werden ad hoc signiert (siehe `ios/build.sh`) und hochgeladen; Stand: `docs/APP-STORE.md`.

### Testliste vor der nächsten Version

Mit einem Wegwerfprojekt bei Vercel und einem bei Render (nichts, worauf sich jemand verlässt), auf einem echten iPhone:

- [ ] Aus der Liste (Kontextmenü) und aus den Details deployen; Face ID fragt einmal, die Zeile folgt dem
      Build bis „live“, und das Handy gibt ein Erfolgs-Tippen.
- [ ] Ein Projekt deployen, das aktuell ist: die Frage sagt „Nichts Neues zu deployen“.
- [ ] Bei Vercel zurückrollen: die Frage nennt den Commit und sein Datum; das Handy sagt, dass es wieder auf
      der vorherigen Version ist, sobald die Domain darauf zeigt.
- [ ] Bei Render zurückrollen: dasselbe, sobald der neue Deploy des alten Commits live ist.
- [ ] Ein falsches Token: die Liste sagt, der Schlüssel wurde abgelehnt, und bietet die Einstellungen an; „Schlüssel testen“
      zeigt dasselbe.
- [ ] Flugmodus: die Liste sagt „Offline“ mit der Zeit der Daten und lädt neu, wenn das Netz zurück ist.
- [ ] iCloud-Schlüsselbund: am Mac „Mit der iPhone-App verbinden“ einschalten; das Handy zeigt „Mit dem Mac
      verbunden“ innerhalb weniger Minuten.
- [ ] Widget auf dem Home-Bildschirm: die Zahlen passen zur App; nach drei Stunden ohne die App wird seine Zeit orange (nur iPhone).
- [ ] Ein Hinweis im Hintergrund: bei eingeschalteten Mitteilungen erscheint ein fehlgeschlagener Build als Hinweis.

## Schritte, die nur der Inhaber tun kann (Apple-Developer-Konto)

1. **Mac-App-Group.** Entscheiden, ob ein Mac-Release die App Group tragen darf
   (`<TEAMID>.app.deploycenter`). Dann einen notarisierten Test-Build mit `--widgets` laufen lassen.
2. **iOS-App-IDs.** Die App-IDs `app.deploycenter.ios` und `app.deploycenter.ios.widgets`
   und die App Group `group.app.deploycenter` registrieren. `ios/build.sh --archive` kann das auch erledigen, über
   `-allowProvisioningUpdates`.
3. **App Store Connect.** Den Eintrag anlegen (kostenlos, Entwicklerwerkzeuge). Ausfüllen:
   - die Texte aus `ios/AppStore/`;
   - die Datenschutzangaben („Daten werden nicht erhoben“);
   - die Hinweise für das Review.
4. **Release.** Den Build hochladen, in TestFlight testen, dann einreichen. Details: `docs/APP-STORE.md`.
