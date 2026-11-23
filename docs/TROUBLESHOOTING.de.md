# Fehlerbehebung (Deutsch)

Die deutsche Fassung von [TROUBLESHOOTING.md](TROUBLESHOOTING.md). Die Überschriften sind die Meldungen, die App und `deploys` zeigen, **wörtlich und auf Englisch**: Suche auf dieser Seite nach dem Text, den du siehst. Verlinkte Seiten ohne eigene deutsche Fassung sind englisch.

In der App hat ein Fehler im Log- oder Detailfenster einen **Hilfe**-Knopf, der den passenden Abschnitt hier öffnet.

`deploys creds` zeigt, woher der Schlüssel jeder Plattform kommt, ob er angenommen wird und wie alt ein Schlüsselbund-Schlüssel ist. `deploys certs` zeigt, welche TLS-Zertifikate bald ablaufen. Wo der Schlüsselbund nicht infrage kommt (CI, SSH, gesperrter Login-Schlüsselbund), hilft `<NAME>_CMD`, ein Befehl, der den Schlüssel ausgibt: `RENDER_API_KEY_CMD='op read op://tresor/render/key'` (1Password, pass, Vault); er wird nach der Variablen und vor dem Schlüsselbund gefragt ([CLI.md](CLI.md#environment-variables), englisch).

`deploys hooks install` (ein Git-`pre-push`-Hook in einem Repo) und der Ordner `hooks.d` (Skripte rund um einen Deploy, [CLI.md](CLI.md#hooks-scripts-around-a-start-hooksd), englisch) haben nichts miteinander zu tun. Läuft ein pre-deploy-Skript nicht, steht in der Zeile `hooks.d: <Datei> … was not run`, warum: Eine Datei, die Gruppe oder andere beschreiben dürfen oder die nicht Ihnen gehört, wird übersprungen (`chmod go-w`).

Unter **Einstellungen → Plattformen → Health** bekommt eine Vercel- oder Render-Anmeldung, die seit 90 Tagen in Gebrauch ist, den Hinweis, sie zu erneuern. Das Alter zählt ab dem Tag, an dem die App die Anmeldung zuerst sah; es ist ein Anstoß, keine Aussage über das Token.

Erste Schritte bei jedem Problem:

- `deploys doctor` gibt als JSON aus, was verbunden ist: `jq`, `jqVersion`, `bashVersion`, `githubCli`, `githubLoggedIn`, `gitlabCli`, `gitlabLoggedIn`, `readonly` und die Felder jeder eingeschalteten Plattform (Vercel: `vercelCli`, `vercelApi`, `vercelLoggedIn`; Render: `renderKey`, `renderKeySource`; Deploy-Hooks: `hookReady`, `hooks`). Für Netlify, Cloudflare, Amplify, DigitalOcean und Coolify frag die Plattform selbst, zum Beispiel `deploys netlify doctor`: ihre Antworten teilen sich Feldnamen (`provider`, und `key`, `tokenOk`, `error` bei dreien), und in der gemeinsamen Antwort bleibt von jedem nur das letzte übrig.
- In der App zeigt **Einstellungen → Plattformen → Zustand** dasselbe je Plattform als Checkliste, mit dem, was bei jedem Problem zu tun ist.
- In der App kopiert **Einstellungen → Hilfe → Diagnose kopieren** Versionen und den Stand der Verbindungen, ohne Projektnamen und Schlüssel. Füge es in ein Issue ein.
- **Einstellungen → Hilfe → Fehlerprotokoll öffnen** öffnet `~/Library/Logs/DeployCenter.log`: jeder fehlgeschlagene Aufruf von `deploys` und was er sagte.
- Eine Umgebungsvariable kann ändern, was `deploys` tut (`DEPLOYS_READONLY`, `DEPLOYS_NO_GITHUB`, `DEPLOYS_CONFIG`, …). [CLI.md](CLI.md) listet sie alle auf.

Die App führt das Skript `deploys` aus, das in ihr steckt (`Deploy Center.app/Contents/Resources/deploys`). Jeder Fehler unten lässt sich also im Terminal mit demselben Befehl nachstellen.

## Installieren

### Homebrew asks you to trust the tap

Homebrew 6 fragt einmal, bevor es aus einem Tap von Dritten installiert. Vertraue ihm, dann installiere:

```bash
brew tap pschmetzer/tap && brew trust pschmetzer/tap && brew install --cask deploy-center
```

### Keine Admin-Rechte

`/Applications` verlangt ein Admin-Passwort. Installiere stattdessen in deinen eigenen Programme-Ordner:

```bash
brew install --cask deploy-center --appdir="$HOME/Applications"
```

Von Hand: Release entpacken und **Deploy Center** nach `~/Applications` ziehen. Der eingebaute Updater (Sparkle) ersetzt die App an Ort und Stelle, auch Updates brauchen also keine Admin-Rechte.

### macOS says the app cannot be opened (Gatekeeper)

Releases sind mit einer Developer ID signiert und von Apple notarisiert, sie öffnen sich also ohne Warnung. Verweigert macOS es trotzdem:

1. Lade das Zip noch einmal vom [neuesten Release](https://github.com/Pschmetzer/deploy-center/releases/latest). Ein kaputter oder unvollständiger Download ist die häufigste Ursache.
2. Prüfe, was Gatekeeper sagt:
   ```bash
   spctl -a -vv "/Applications/Deploy Center.app"
   ```
   `accepted` und `source=Notarized Developer ID` ist die erwartete Antwort.
3. Sagt es `rejected`, öffne bitte ein Issue mit dieser Ausgabe. Schalte Gatekeeper dafür nicht aus.

Eine App, die du selbst mit `./build.sh` gebaut hast, ist nicht notarisiert. Öffne sie beim ersten Mal per Rechtsklick → **Öffnen**.

### Die CLI unter Linux oder WSL mit install.sh installieren

Das Skript nennt nach der Installation, was fehlt, mit dem Befehl für deinen Paketmanager.
Meldungen, die es zeigen kann:

- **"install.sh: curl is needed to download the release (see below for jq, which deploys needs too)"** oder **"install.sh: tar is needed to unpack the release"**: installiere sie mit deinem Paketmanager und führe das Skript erneut aus.
- **"install.sh: SHA-256 mismatch for … Nothing was installed."**: Der Download ist kaputt oder wurde unterwegs verändert. Führe es noch einmal aus; wiederholt es sich, öffne ein Issue und installiere nicht von Hand.
- **"install.sh: … is not writable and sudo is missing."**: Nimm das Standardverzeichnis (`~/.local`), gib `--prefix "$HOME/.local"` mit oder führe es als root aus.
- **"install.sh: …/deploys exists and was not installed by this script (Homebrew or by hand?)"**: Entferne diese Datei, wähle ein anderes `--prefix` oder gib `--force` mit.
- **"install.sh: DEPLOYS_INSTALL_BASE is set: downloading from … instead of the GitHub releases."**: Etwas hat diese Variable gesetzt (ein CI-Job, dein Shell-Profil). Setze sie zurück, außer du hast sie mit Absicht gesetzt.
- **"… is not on your PATH. Add it, then open a new terminal"**: Füge die Zeile, die das Skript ausgibt, zu `~/.bashrc` oder `~/.zshrc` hinzu.
- **"install.sh: deploys is installed, but needs the required tools above before it can run."**: Installiere `bash`, `jq` und `curl` mit den Befehlen darüber. Unter WSL installierst du sie in der Linux-Distribution, nicht in Windows.

## Vercel

### Connect Vercel – "Install the Vercel CLI, then log in once in Terminal."

Die App hat den Befehl `vercel` nicht gefunden. Installiere ihn und melde dich an:

```bash
npm i -g vercel
vercel login
```

Drücke dann **Fertig – nochmal prüfen**.

### `vercel` ist installiert (nvm, volta, fnm), aber die App findet es nicht

Eine Mac-App bekommt nicht den `PATH` deines Terminals. Die App sucht in `/opt/homebrew/bin`, `/usr/local/bin` und `~/.local/bin`, dazu im `PATH` deiner **Login-Shell**, den sie einmal am Tag liest.

Eine Login-Shell, die die App startet (`zsh -l`), liest `~/.zshrc` nicht. Ist nvm nur in `~/.zshrc` eingerichtet, werden weder `vercel` noch `node` gefunden. Prüfe, was die App sieht:

```bash
zsh -lc 'command -v vercel node'
```

Gibt das nichts aus, wähle eins:

- Verschiebe die Zeilen, die nvm (oder volta, fnm) einrichten, von `~/.zshrc` nach `~/.zprofile`.
- Oder installiere Node mit Homebrew (`brew install node`), dann `npm i -g vercel`. Beides landet in `/opt/homebrew/bin`.

Die App behält den gelesenen `PATH` einen Tag lang. Um ihn jetzt neu zu lesen, beende die App, führe die Zeile unten aus und öffne sie wieder:

```bash
defaults delete app.deploycenter.mac searchPath
```

### Connect Vercel – "Log in once in Terminal. The app uses that login."

`vercel` ist da, aber nicht angemeldet. Führe `vercel login` aus. Im Terminal lautet derselbe Fall:

> Error: The vercel CLI is not logged in. Run: vercel login

### Update the Vercel CLI – "Your Vercel CLI is too old (it has no `vercel api`)."

```bash
npm i -g vercel@latest
```

### "Several Vercel teams. Choose one: deploys vercel team <id>"

Dein Login gehört zu mehr als einem Team. Der Fehler listet jede Team-ID und jeden Namen auf. Wähle eins:

```bash
deploys vercel team team_abc123
```

Die Wahl wird in `~/.config/deploys/vercel-team` gespeichert. In CI setze stattdessen `DEPLOYS_VERCEL_TEAM`. Die Beispiel-Workflows lesen sie aus der Repository-Variable `DEPLOYS_VERCEL_TEAM` (`vars.DEPLOYS_VERCEL_TEAM`). Einige ältere Beispiele lesen `vars.VERCEL_TEAM`: Hast du eines davon kopiert, benenne die Variable unter Settings → Secrets and variables → Actions → Variables um oder behalte den alten Namen in deiner Kopie.

### "Vercel could not be loaded" (oder "Render could not be loaded")

Das letzte Lesen der Liste ist fehlgeschlagen. Das Banner sagt, von wann die Liste auf dem Bildschirm ist, und die Zeile darunter ist das, was `deploys` gemeldet hat. Drücke zuerst **Nochmal versuchen**: Ein Netzwackler ist die übliche Ursache. Vercel-Lesezugriffe werden von selbst wiederholt, Render liest bis zu dreimal. Eine Meldung, die bleibt, heißt also: Das Problem besteht noch.

- `fetch failed`, `ETIMEDOUT`, `ENOTFOUND`, `ECONNRESET` oder `no answer from Render (network or timeout)`: Der Mac konnte die Plattform nicht erreichen. Prüfe Netz, VPN oder Proxy.
- `no answer within … s`: Die Vercel-CLI hing. Probiere `vercel whoami` im Terminal: Hängt das auch, liegt das Problem an der CLI oder am Netz, nicht an Deploy Center.
- Ein 401 oder 403 in der Meldung: Login oder Schlüssel sind falsch oder abgelaufen. Vercel: `vercel login`. Render: siehe unten.

Konnten nur die neuesten Builds nicht gelesen werden, kommt die Liste trotzdem. Die Zeile bekommt ein kleines ⓘ, dessen Tooltip sagt *The newest builds could not be read: a build under way may not show*. Das ist ein Hinweis, kein Fehler: Das nächste Neuladen füllt es auf.

### "<project> has no remembered repo. Turn its auto-deploy off with this tool, add it to …/vercel-repos.json, or map it: deploys vercel map <project> <owner/repo> [branch]"

Deploy Center lernt das Repo eines Projekts, wenn es dessen Auto-Deploy abschaltet. Ein Projekt, das auf anderem Weg getrennt wurde, hat kein gespeichertes Repo. Sag es ihm:

```bash
deploys vercel map my-project me/my-repo main
```

In der App steht in so einer Zeile **Repo unbekannt**.

### "Skipped or canceled by Vercel (Ignored Build Step?)"

Vercel hat den Build abgebrochen, meist weil der **Ignored Build Step** des Projekts entschieden hat, dass sich nichts geändert hat. Das ist kein Fehler. Siehe [GLOSSARY.md](GLOSSARY.md#ignored-build-step).

## GitHub

### "GitHub CLI is not logged in, so the waiting commits and PRs cannot be counted. In Terminal: gh auth login"

Die GitHub-CLI ist optional. Ohne sie funktioniert das Deployen, aber die App sieht nicht, was auf GitHub wartet: keine **Neuen Änderungen**, keine Zähler, und **Alle mit Änderungen anhaken** findet nichts zum Anhaken.

```bash
brew install gh
gh auth login
```

`deploys explain my-project` sagt im Terminal dasselbe:

> unknown: the branch head is not known (gh missing or not logged in?)

### "GitHub's hourly budget is nearly spent …"

GitHub erlaubt für deinen Login eine feste Zahl API-Aufrufe pro Stunde. Bleiben unter 300 übrig, liest Deploy Center nur den neuesten Commit jedes Branches und überspringt die Zähler. Sie kommen zurück, wenn die Stunde zurückgesetzt wird. `deploys github-budget` zeigt, was übrig ist.

## GitLab

### "gitlab: HTTP 401: …"

GitLab hat den Token abgelehnt, oder glab ist an diesem Host nicht angemeldet. Führe `deploys doctor` aus: `gitlabLoggedIn` muss true sein. Melde dich neu an mit `glab auth login` (selbst gehostet: `--hostname git.example.com`) oder erstelle einen neuen Personal Access Token mit dem Scope `read_api` und lege ihn in `GITLAB_TOKEN`. Siehe [GITLAB.md](GITLAB.md#set-up).

### Repos auf einem selbst gehosteten GitLab zeigen keine Zahlen

Der Token geht nur an `GITLAB_HOST`, ohne Angabe gitlab.com. Setze `GITLAB_HOST=git.example.com`. Die App startet `deploys` aus launchd, und das liest dein Shell-Profil nicht: Lege die Variablen in `~/.zprofile` ab oder nimm glab, das seinen eigenen Login behält.

## Render

### Connect Render

Erstelle einen API-Key unter dashboard.render.com → Account Settings → API Keys und füge ihn in die App ein. Er wird in deinem macOS-Schlüsselbund gespeichert. Im Terminal:

```bash
pbpaste | deploys render set-key
```

Zugehörige Meldungen:

- `Error: No Render API key. Create one at dashboard.render.com > Account Settings > API Keys, then: deploys render set-key`
- `Error: Pipe the key in: pbpaste | deploys render set-key` (über stdin kam nichts an)
- `Error: That does not look like a Render API key` (er enthält ein Leerzeichen oder ein Anführungszeichen; kopiere ihn noch einmal)

### "… -> HTTP 401 (the Render key is wrong or expired: deploys render set-key)"

Render hat den Schlüssel abgelehnt (401 oder 403). Er wurde widerrufen, ist abgelaufen oder falsch kopiert. Erstelle einen neuen und speichere ihn mit `pbpaste | deploys render set-key`. Der neue ersetzt den alten.

### "… -> HTTP 429 (rate limit: try again in a minute)"

Render begrenzt, wie schnell seine API aufgerufen werden darf. Deploy Center wartet schon und versucht es zweimal erneut. Probiere es in einer Minute noch einmal.

### "… -> HTTP 404 (not found: renamed or deleted?)"

Der Service wurde bei Render umbenannt oder gelöscht. Lade die Liste neu.

### Auto-Deploy schaltet sich wieder ein

Ein Render-**Blueprint** mit Auto-Sync kann `render.yaml` bei einem Push erneut anwenden. Trage `autoDeployTrigger: off` bei den Services in `render.yaml` ein. `deploys triggers` listet Blueprints mit eingeschaltetem Auto-Sync.

## Zuschaltbare Hosts

### "Netlify is off. Turn it on: deploys providers enable netlify"

Netlify, Cloudflare Pages, AWS Amplify, DigitalOcean, Coolify, Fly.io, Railway, Heroku, Firebase Hosting, GitHub Pages und Deploy-Hooks sind aus, bis du sie einschaltest, damit kein Befehl aus Versehen mit ihnen spricht. Führe den Befehl aus der Meldung aus (der Name unterscheidet sich je Host) und setze dann seinen Schlüssel. `deploys providers` listet, welche an sind.

### "No Cloudflare API token. …" / "No Coolify token. …"

Der Host ist an, aber es ist kein Schlüssel für ihn gespeichert. Die Meldung sagt, wo du einen erstellst. Dann `pbpaste | deploys <host> set-key` (AWS Amplify nimmt stattdessen einen Profilnamen: `echo my-profile | deploys amplify set-key`). Die Seite jedes Hosts hat die Details: [Netlify](providers/netlify.md), [Cloudflare Pages](providers/cloudflare.md), [AWS Amplify](providers/amplify.md), [DigitalOcean](providers/digitalocean.md), [Coolify](providers/coolify.md), [Fly.io](providers/fly.md), [Railway](providers/railway.md), [Heroku](providers/heroku.md), [Firebase Hosting](providers/firebase.md), [GitHub Pages](providers/ghpages.md), [Deploy-Hooks](providers/hook.md).

### "… has no build hook yet. Run: deploys netlify autodeploy-off …"

Netlify deployt von Hand über einen Build-Hook, den `autodeploy-off` anlegt. Führe es einmal für diese Site aus.

### AWS Amplify: keine Apps oder die falschen

Amplify wird über die `aws`-CLI erreicht, also muss zuerst `aws sts get-caller-identity --profile <name>` funktionieren (`aws configure sso` oder `aws configure`). Gelistet werden nur Apps in einer Region: `AWS_REGION`, sonst die Region des Profils. Setze `AWS_REGION` auf die Region der App, die du erwartest. Die Identität braucht die `amplify:`-Berechtigungen, die auf [der Amplify-Seite](providers/amplify.md) stehen. Welches Profil gilt: `DEPLOYS_AMPLIFY_PROFILE`, dann `AWS_PROFILE`, dann der Schlüsselbund.

### DigitalOcean: HTTP 401 oder eine App, die bei Push noch deployt

401 heißt: Der Token ist falsch oder abgelaufen: `pbpaste | deploys digitalocean set-key`. Der Token braucht Lese- und Schreib-Scope für Apps. Deployt eine Komponente nach `autodeploy-off` weiter bei Push, nennt die Meldung sie; die vorherige Spec bleibt in `~/.config/deploys/do-specs/<app-id>.json` erhalten. Siehe [die DigitalOcean-Seite](providers/digitalocean.md).

### Coolify: 403 "API is disabled" oder 403 bei jeder Anwendung

Schalte in Coolify den API-Zugriff unter Settings > Advanced ein. Ein Token, der auf einige Projekte beschränkt ist, kann `/applications` gar nicht nutzen: Erstelle einen mit teamweitem Scope und den Rechten `read`, `write` und `deploy`. Eine reine `http://`-Instanz, die nicht dieser Rechner ist, wird abgelehnt, außer du setzt `DEPLOYS_COOLIFY_ALLOW_HTTP=1`. Siehe [die Coolify-Seite](providers/coolify.md).

### Cloudflare Pages: "unverified" oder ein übersprungenes Deployment

Cloudflare dokumentiert nicht, ob ein Deployment, das du anlegst, baut, solange Push-Deploys aus sind. Führe einmal `deploys cloudflare selftest <project> --yes` aus (es verbraucht einen Build); `deploys cloudflare doctor` sagt dann `verified` oder `failed`. Siehe [die Cloudflare-Seite](providers/cloudflare.md).

### Deploy-Hook: "triggered" und nichts weiter

Ein Deploy-Hook hat keine Status-API, deshalb zählt eine 2xx-Antwort als bereit. Die URL ist ein Geheimnis und liegt im Schlüsselbund (unter Linux in einer 0600-Datei); `deploys hook set-key <name>` ersetzt sie. Siehe [die Hook-Seite](providers/hook.md).

## Claude, MCP und Scans

### Der Agent sagt, Deploys seien nicht erlaubt

Der MCP-Server ist standardmäßig nur lesend. Deployen muss in der Umgebung des Servers mit `DEPLOYS_MCP_ALLOW_DEPLOY=1` eingeschaltet werden, und dann fragt er dich trotzdem vor jedem Deploy. Siehe [integrations/mcp](../integrations/mcp/README.md).

### Der MCP-Server oder das Claude-Code-Plugin findet `deploys` nicht

Er sucht in dieser Reihenfolge: `DEPLOYS_BIN`, die Kopie in `Deploy Center.app` (in `/Applications` oder `~/Applications`), dann `PATH`. Setze `DEPLOYS_BIN` auf die Datei, die du meinst, und prüfe, dass `deploys --version` im Terminal läuft.

### "Find bugs with Claude" does nothing, or says it is not set up

Der Bug-Scan führt die Claude-Code-CLI auf diesem Mac aus. Installiere sie und melde dich einmal an (`npm i -g @anthropic-ai/claude-code`, dann `claude login`) und melde `gh` an, weil es klont und den Pull Request öffnet. `deploys scan status --json` zeigt, was fehlt. Ein zweiter Scan eines Repos wird abgelehnt, solange einer läuft oder sein Scan-PR offen ist, und höchstens 4 Scans laufen pro 24 Stunden (`DEPLOYS_SCAN_PER_DAY`). Ein Scan, dessen Prozess weg ist (Neustart, Ruhezustand), wird als fehlgeschlagen markiert: Halte den Mac 10 bis 30 Minuten wach. Siehe [SCAN.md](SCAN.md).

### Der Sicherheits-Check zeigt ein Werkzeug als fehlend

`deploys check` braucht `osv-scanner`, `gitleaks` und `semgrep` (`brew install osv-scanner gitleaks semgrep`). Ein fehlendes Werkzeug wird als fehlend angezeigt, die anderen laufen weiter. Gefundene Geheimnisse werden nie an Claude geschickt: Tausche sie aus.

### Rollback did not do what I expected

Ein Rollback geht auf das Deploy vor dem aktuellen zurück, bei jedem Host außer einem einfachen Deploy-Hook. Ist Auto-Deploy an, deployt der nächste Push wieder, schalte es also ab oder behebe den Fehler nach vorn. Er macht keine Datenbank-Migrationen und keine Änderungen an Umgebungsvariablen rückgängig. `deploys verify <project>` rollt bei einem 5xx von selbst zurück; `--no-rollback` meldet nur. Siehe [SAFE-DEPLOY.md](SAFE-DEPLOY.md).

## Ein Deploy wurde abgelehnt

### "deploy window closed"

Eine Regel in `window.json` (oder der geteilten `deploy-center.json`) sagt, dass jetzt keine Deploys erlaubt sind. `deploys window` zeigt, warum, und endet mit Exit 1, solange es geschlossen ist. Im Notfall geht `--force "why"` durch, und der Grund wird ins Journal geschrieben. Siehe [SAFE-DEPLOY.md](SAFE-DEPLOY.md).

### Nothing can be changed (observer mode)

Ist `DEPLOYS_READONLY` gesetzt (jeder Wert außer `0`, `false`, `no`, `off`) oder der Beobachter-Modus eingeschaltet, liest `deploys` nur. Schalte ihn ab mit `deploys readonly off` oder setze die Variable zurück. Siehe [TEAM.md](TEAM.md).

### `deploys` sagt, jq (oder curl oder bash) fehle

`jq`, `curl` und `bash` sind Pflicht, `perl` ist optional. `install.sh` nennt, was fehlt und wie du es auf deinem System installierst; `deploys doctor` prüft noch einmal.

## Auto-Deploy-Wächter

### Der Wächter hat Auto-Deploy wieder abgeschaltet, ich wollte es aber an

Das ist seine Aufgabe: Was ohne laufende Erlaubnis an ist, wird abgeschaltet. Erlaube es stattdessen für eine Weile, zum Beispiel `deploys autodeploy allow vercel my-project 4` (4 Stunden) oder in **Einstellungen → Auto-Deploy-Wächter → Auto-Deploy erlauben …**. `deploys guard schedule off` hält den Wächter an. Details: [GUARD.md](GUARD.md).

### Der Wächter hat beim ersten Lauf nichts getan

Der erste Lauf nach `deploys guard schedule on` meldet nur, was er abschalten würde; ab dem nächsten Lauf handelt er. `deploys guard status` zeigt den letzten Lauf; das Protokoll liegt in `~/Library/Logs/DeployCenter-guard.log`.

## Team-Modus

### "Observer mode (…): "deploys …" changes something and is refused."

Dieser Mac ist ein Beobachter: Du stehst in der Liste `observers` der `deploy-center.json` des Repos, oder der Beobachter-Modus ist hier an. Beobachter können nachsehen, nicht deployen. Die Meldung endet damit, was zu tun ist: `deploys readonly off`, `DEPLOYS_READONLY` zurücksetzen oder bitten, von der Liste genommen zu werden. Siehe [TEAM.md](TEAM.md).

## Claude und Autofix

### "No Anthropic API key. Run: pbpaste | deploys ai set-key (or set ANTHROPIC_API_KEY)"

Claude in der App braucht deinen eigenen Anthropic-API-Key. Trage ihn in **Einstellungen → Claude** ein oder kopiere ihn und führe `pbpaste | deploys ai set-key` aus. Siehe [CLAUDE-IN-APP.md](CLAUDE-IN-APP.md#turning-it-on).

### "Anthropic refused the key (401). Check it in Settings > Claude in the app, or: deploys ai verify"

Der Schlüssel wurde gelöscht oder falsch eingetippt. `deploys ai verify` testet ihn. Erstelle einen neuen unter console.anthropic.com und speichere ihn erneut.

### "This month's Claude cap is reached (… of … tokens). Raise it in Settings > Claude in the app, or: deploys ai cap <tokens>"

Deploy Center ruft Claude nicht mehr auf, sobald dein Monatslimit verbraucht ist. Es geht im nächsten Monat weiter oder sofort, wenn du das Limit erhöhst.

### "That does not look like a routine token (sk-ant-...)"

`deploys autofix set-token` nimmt den Token der Claude-Code-Routine, der mit `sk-ant-` beginnt. Kopiere ihn noch einmal aus der Routine unter claude.ai → Code → Routines, dann `pbpaste | deploys autofix set-token`. Siehe [AUTOFIX.md](AUTOFIX.md#setup-once).

### "autofix is running already"

Ein anderer Autofix-Lauf hält die Sperre, oft der geplante. Warte darauf. Ein Lauf, der gestorben ist, hinterlässt die Sperre; sie wird nach 30 Minuten übernommen.

### "The config file is not valid JSON. Nothing was changed."

**Verbinden** neben Claude Desktop (Einstellungen → Claude) bearbeitet `~/Library/Application Support/Claude/claude_desktop_config.json` nur, wenn sie gültiges JSON ist. Repariere oder entferne die kaputte Datei und verbinde dann erneut.

## iPhone

### "This build cannot use iCloud Keychain. Use the QR code."

Eine selbst gebaute (ad hoc signierte) App hat keine Schlüsselbund-Gruppe, die sie mit dem iPhone teilen kann. Nimm **QR-Code fürs iPhone zeigen …** unter Einstellungen → iPhone oder installiere ein Release.

### "Could not write to iCloud Keychain (error …)"

Der Schlüsselbund des Macs hat den Eintrag abgelehnt. Die Zahl ist der Fehlercode des Schlüsselbunds (`security error <number>` im Terminal erklärt sie); dieselbe Zeile steht im Fehlerprotokoll. Prüfe, ob der iCloud-Schlüsselbund an ist (Systemeinstellungen → dein Name → iCloud → Passwörter) oder nimm stattdessen den QR-Code.

## Deployen

### "<project> is being started already (wait a minute)"

Dasselbe Projekt wurde vor weniger als einer Minute gestartet, aus der App oder aus dem Terminal. Die Sperre verhindert zwei Builds durch zwei schnelle Klicks. Sie läuft nach einer Minute ab, und sofort, wenn der Start fehlgeschlagen ist.

### "No answer after 120 seconds – try again."

Ein Aufruf an Vercel, Render oder GitHub hing. Prüfe dein Netz und versuche es noch einmal.

### "no result after 40 min – still asking, check the dashboard"

(In der deutschen App: „nach 40 Min. kein Ergebnis – fragt weiter, im Dashboard nachsehen“.) Ein Deploy hat seit 40 Minuten kein Ergebnis. Die App fragt alle 30 Sekunden weiter und die Zeile bleibt gesperrt, damit nicht aus Versehen ein zweiter kostenpflichtiger Build startet. Du bekommst außerdem eine Mitteilung („my-project hat nach 40 Minuten kein Ergebnis“). Das Deploy kann noch laufen: Sieh im Vercel- oder Render-Dashboard nach oder führe `deploys watch my-project` aus.

### "No result after 12 hours – check the dashboard"

(In der deutschen App: „Kein Ergebnis nach 12 Stunden – im Dashboard nachsehen“.) Die App hat aufgehört, einem Deploy zu folgen, nach 12 Stunden. Die Zeile ist wieder frei, aber ein neuer Start desselben Projekts wird sofort gehalten, bis du nachgesehen hast. Sieh im Dashboard nach, was aus dem Deploy geworden ist.

### "Not started: the backend of the same repo failed"

Deployen ein Vercel-Frontend und ein Render-Backend im selben Lauf aus demselben Repo, wartet das Frontend auf das Backend. Das Backend ist fehlgeschlagen, also wurde das Frontend nicht gestartet. Behebe zuerst das Backend.

### Ein Build lief, obwohl Auto-Deploy aus ist

Etwas anderes hat ihn gestartet: ein GitHub-Workflow, ein Deploy-Hook oder ein Render-Blueprint. Liste, was in den letzten 24 Stunden Builds gestartet hat und welche Workflows von selbst deployen:

```bash
deploys triggers
```

## Aktualisieren

### An update does not install

**Nach Updates suchen …** (im App-Menü) und die tägliche Prüfung nutzen Sparkle: Es liest `deploycenter.app/appcast.xml`, lädt die neue Version von GitHub und prüft ihre EdDSA-Signatur, bevor es die App ersetzt. Laufen Deploys, wartet es und installiert, sobald sie fertig sind. Schlägt eine Prüfung oder der Download fehl, bleibt die App, wie sie war, und das Fehlerprotokoll hat eine Zeile, die mit `update failed:` beginnt. Installiere von Hand vom [neuesten Release](https://github.com/Pschmetzer/deploy-center/releases/latest) oder mit `brew upgrade --cask --greedy deploy-center`.

## Das Widget fehlt in der Widget-Galerie

Sieh in die App-Liste links in der Galerie (die Suche findet dort nichts). Steht dort gar keine App von außerhalb Apples, hat macOS Widgets von Drittanbietern noch nicht geladen: Starte den Mac neu und suche dann nach **Deploy Center**. Fehlt nur Deploy Center, hat die installierte Kopie womöglich kein Widget: `ls ~/Applications/"Deploy Center.app"/Contents/PlugIns` muss `DeployCenterWidgets.appex` zeigen. Installiere neu vom Release oder baue mit `./build.sh --widgets --install`.

## Immer noch nicht gelöst?

Öffne ein [Issue](https://github.com/Pschmetzer/deploy-center/issues) mit der Ausgabe von **Diagnose kopieren** und den passenden Zeilen des Fehlerprotokolls. Issues sind öffentlich: Entferne vorher Projektnamen und Domains. Füge nie einen Schlüssel ein.
