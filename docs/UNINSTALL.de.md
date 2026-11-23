# Deinstallieren

Die deutsche Fassung von [UNINSTALL.md](UNINSTALL.md). Verlinkte Seiten ohne eigene deutsche Fassung sind englisch.

Das Deinstallieren schaltet Auto-Deploy nicht wieder ein. Deine Projekte bleiben manuell, bis du sie wieder verbindest ([AUTO-DEPLOY.de.md](AUTO-DEPLOY.de.md)). Mach das zuerst, wenn du es willst, solange `~/.config/deploys/vercel-repos.json` noch sagt, aus welchem Repo jedes Projekt kam: `deploys vercel autodeploy-on --all` und `deploys render autodeploy-on --all`.

## 1. Stoppen, was von selbst läuft

- Schalte in der App **Einstellungen → Allgemein → Beim Anmelden öffnen** aus (oder entferne Deploy Center unter Systemeinstellungen → Allgemein → Anmeldeobjekte).
- Autofix, falls du seinen Zeitplan eingeschaltet hast (launchd-Job `app.deploycenter.autofix`):
  ```bash
  deploys autofix schedule off
  ```
- Der Wächter, falls du seinen Zeitplan eingeschaltet hast (launchd-Job `app.deploycenter.guard`, siehe [GUARD.de.md](GUARD.de.md)):
  ```bash
  deploys guard schedule off
  ```
  Beide entfernen ihre Datei in `~/Library/LaunchAgents/`. Ohne `deploys` führe
  `launchctl bootout gui/$(id -u)/app.deploycenter.autofix` (oder `.guard`) aus und lösche
  `~/Library/LaunchAgents/app.deploycenter.autofix.plist` (oder `.guard.plist`).
- Für Tests oder ein Konto, das nicht in `~/Library/LaunchAgents` schreiben darf, nennt `DEPLOYS_LAUNCH_DIR` einen anderen Ordner für die Job-Dateien; nimm denselben Wert, wenn du sie entfernst.
- Das tägliche Deploy, falls du es mit `deploys schedule daily` eingerichtet hast (launchd-Job `app.deploycenter.daily`):
  ```bash
  deploys schedule off
  ```
  Falls du es von Hand nach [`scripts/daily-deploy.plist.example`](../scripts/daily-deploy.plist.example) eingerichtet hast:
  ```bash
  launchctl unload ~/Library/LaunchAgents/app.deploycenter.daily.plist
  rm ~/Library/LaunchAgents/app.deploycenter.daily.plist /tmp/deploy-center-daily.log
  ```
- Die Pre-Push-Prüfung, in jedem Repo, in dem du `deploys hooks install` ausgeführt hast:
  ```bash
  deploys hooks uninstall <repo folder>   # puts back the pre-push hook that was there before
  ```
- Die iPhone-App: Schalte in Einstellungen → iPhone **Mit der iPhone-App verbinden (iCloud-Schlüsselbund)** aus. Das entfernt
  die Schlüssel, die der Mac in deinen iCloud-Schlüsselbund gelegt hat (Eintrag `app.deploycenter.link`), sodass sie auch
  deine anderen Geräte verlassen. Ein QR-Code hinterlässt nichts auf dem Mac; lösche die iOS-App auf dem Telefon.

Beende dann die App.

## 2. Claude und die Editor-Erweiterungen trennen

Nur das, was du eingerichtet hast:

- **Claude Desktop und Claude Code** (verbunden in **Einstellungen → Claude**): Trenne sie dort,
  bevor du die App entfernst. Ohne die App:
  ```bash
  claude mcp remove deploy-center --scope user
  ```
  Für Claude Desktop lösche den Eintrag `deploy-center` unter `mcpServers` in
  `~/Library/Application Support/Claude/claude_desktop_config.json` und starte Claude Desktop neu.
  Hast du den MCP-Server von Hand unter einem anderen Namen hinzugefügt (zum Beispiel `deploys`), entferne diesen Namen.
- **Das Claude-Code-Plugin**, in einer Claude-Code-Sitzung:
  ```text
  /plugin uninstall deploy-center@deploy-center
  ```
  ```text
  /plugin marketplace remove deploy-center
  ```
- **Die VS-Code-Erweiterung** (auch Cursor, Windsurf): Deinstalliere sie in der Erweiterungen-Ansicht, oder mit
  `code --uninstall-extension deploycenter.deploy-center`.
- **Die Raycast-Erweiterung**: Entferne sie in Raycast → Settings → Extensions.
- **Widgets**: Entferne die Deploy-Center-Widgets vom Schreibtisch oder aus der Mitteilungszentrale (Mac) und
  vom Home-Bildschirm (iPhone, iPad).

## 3. Die App entfernen

Mit Homebrew installiert:

```bash
brew uninstall --cask deploy-center
```

`brew uninstall --zap --cask deploy-center` entfernt auch die Einstellungen und das Fehlerprotokoll (siehe unten). `~/.config/deploys` bleibt erhalten.

Von Hand installiert: Ziehe **Deploy Center** aus Programme (oder `~/Applications`) in den Papierkorb.

Nur die CLI, mit dem Skript installiert (nimm dasselbe `--prefix` wie bei der Installation):

```bash
curl -fsSL https://deploycenter.app/install.sh | sh -s -- --uninstall
```

Nur die CLI, mit Homebrew installiert: `brew uninstall deploys`.

## 4. Entfernen, was es auf deinem Mac behalten hat

| Was | Wo | Entfernen mit |
|---|---|---|
| Render-API-Schlüssel | Schlüsselbund, ein Passwort-Eintrag mit dem Dienstnamen `deploy-center-render` (ältere Versionen: `render-api-key`) | `security delete-generic-password -a "$USER" -s deploy-center-render` |
| Anthropic-API-Schlüssel (Claude in der App) | Schlüsselbund, Dienstname `deploy-center-anthropic` | `deploys ai forget-key`, oder `security delete-generic-password -a "$USER" -s deploy-center-anthropic` |
| Autofix-Routine-Token | Schlüsselbund, Dienstname `deploy-center-routine` | `deploys autofix forget-token`, oder `security delete-generic-password -a "$USER" -s deploy-center-routine` |
| Schlüssel der Opt-in-Hosts (Netlify, Cloudflare, DigitalOcean, Coolify; Amplify behält nur einen Profilnamen) | Schlüsselbund, Dienstnamen `deploy-center-netlify`, `deploy-center-cloudflare`, `deploy-center-digitalocean`, `deploy-center-coolify`, `deploy-center-amplify` | `security delete-generic-password -a "$USER" -s deploy-center-<name>` für jeden, den du gesetzt hast |
| Deploy-Hook-URLs | Schlüsselbund, `deploy-center-hook-<name>` (ohne Schlüsselbund: `~/.config/deploys/hook-urls/`) | `deploys hook remove <name>` (bevor du die CLI entfernst), oder `security delete-generic-password -a "$USER" -s deploy-center-hook-<name>` |
| GitLab-Token (`deploys gitlab set-token`) | Schlüsselbund, Dienstname `deploy-center-gitlab` | `deploys gitlab forget-token`, oder `security delete-generic-password -a "$USER" -s deploy-center-gitlab` |
| Das für das iPhone erzeugte Vercel-Token | Schlüsselbund, Dienstname `deploy-center-phone-vercel` | `security delete-generic-password -a "$USER" -s deploy-center-phone-vercel` |
| Dem iPhone übergebene Schlüssel | iCloud-Schlüsselbund (synchronisiert), Dienst `app.deploycenter.link` | schalte zuerst **Einstellungen → iPhone** aus (siehe oben); das entfernt sie auf allen Geräten |
| Widget-Daten (ein kleiner Schnappschuss dessen, was wartet) | `~/Library/Group Containers/<team id>.app.deploycenter/` | lösche diesen Ordner (nur Builds mit Widgets haben ihn) |
| App-Einstellungen | `~/Library/Preferences/app.deploycenter.mac.plist` | `defaults delete app.deploycenter.mac` |
| Zwischengespeicherte Listen, Deploy-Verlauf, Site-Logos | `~/Library/Caches/app.deploycenter.mac/` | `rm -rf ~/Library/Caches/app.deploycenter.mac` |
| Fehlerprotokoll | `~/Library/Logs/DeployCenter.log` | `rm ~/Library/Logs/DeployCenter.log` |
| CLI-Einstellungen: gemerkte Repos, Team, ignorierte Projekte, Claude-Modell, Limit und Verbrauch (`ai-*`), Autofix- und Wächter-Zustand, Freigaben, Netlify-Hook-URLs | `~/.config/deploys/`, oder der Ordner, den `$DEPLOYS_CONFIG` nennt | `rm -rf ~/.config/deploys`; hast du `DEPLOYS_CONFIG` gesetzt, prüfe zuerst `echo "$DEPLOYS_CONFIG"` und entferne stattdessen diesen Ordner |

Hattest du einen Schlüssel unter dem alten Namen, führe die Schlüsselbund-Zeile noch einmal mit `-s render-api-key` aus.

Tab-Vervollständigung: Entferne die Zeile `eval "$(deploys completion zsh)"` aus `~/.zshrc` (oder die Bash-Zeile aus `~/.bashrc`), falls du sie hinzugefügt hast.

## 5. Optional: Zugriff widerrufen

Deploy Center hatte nie ein eigenes Konto. Um zu widerrufen, was es benutzt hat:

- Render: Lösche den API-Schlüssel auf dashboard.render.com → Account Settings → API Keys.
- Anthropic: Lösche den API-Schlüssel auf console.anthropic.com → Settings → API keys, und die Autofix-
  Routine (samt Token) auf claude.ai → Code → Routines.
- Netlify, Cloudflare, DigitalOcean, Coolify: Lösche das Token, das du für Deploy Center gemacht hast, im jeweiligen
  Dashboard. Lösche bei Netlify außerdem den Build-Hook namens `deploy-center` und, falls du wieder Builds
  bei Push willst, die `ignore`-Zeile in `netlify.toml`.
- GitLab: `glab auth logout`, oder widerrufe das `GITLAB_TOKEN` unter GitLab → Preferences → Access tokens.
- iPhone: Die Schlüssel, die es bekam, sind die des Macs (das Vercel-Token für das iPhone, der Render-Schlüssel, das `gh`-Token). Widerrufe sie bei Vercel, Render und GitHub, falls das Telefon oder ein QR-Code von jemand anderem gesehen worden sein könnte.
- Vercel und GitHub: Es hat deine Logins von `vercel` und `gh` benutzt. `vercel logout` und `gh auth logout` beenden sie, auch für alles andere, das sie nutzt.

## Die CLI allein (Linux, WSL, CI)

Hast du `deploys` mit `install.sh` installiert, entferne es mit demselben `--prefix`, den du benutzt hast:

```bash
curl -fsSL https://deploycenter.app/install.sh | sh -s -- --uninstall
```

Dein Konfigurationsordner (`~/.config/deploys`) bleibt; lösche ihn, um ihn ebenfalls zu entfernen. Entferne außerdem, wo du sie hinzugefügt hast,
die GitHub-Action-Workflow-Dateien, die Deploy Center aufrufen, und ein Docker-Image, das du aus `integrations/docker` gebaut hast.
