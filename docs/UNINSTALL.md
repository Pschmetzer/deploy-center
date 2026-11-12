# Uninstall

Uninstalling does not turn auto-deploy back on. Your projects stay manual until you reconnect them ([AUTO-DEPLOY.md](AUTO-DEPLOY.md#back-to-auto-deploy)). Do that first if you want it, while `~/.config/deploys/vercel-repos.json` still tells you which repo each project came from: `deploys vercel autodeploy-on --all` and `deploys render autodeploy-on --all`.

## 1. Stop what runs on its own

- In the app, turn off **Settings → General → Open at login** (or remove Deploy Center under System Settings → General → Login Items).
- Autofix, if you turned on its schedule (launchd job `app.deploycenter.autofix`):
  ```bash
  deploys autofix schedule off
  ```
- The guard, if you turned on its schedule (launchd job `app.deploycenter.guard`, see [GUARD.md](GUARD.md)):
  ```bash
  deploys guard schedule off
  ```
  Both remove their file in `~/Library/LaunchAgents/`. Without `deploys`, run
  `launchctl bootout gui/$(id -u)/app.deploycenter.autofix` (or `.guard`) and delete
  `~/Library/LaunchAgents/app.deploycenter.autofix.plist` (or `.guard.plist`).
- The daily deploy, if you set it up with `deploys schedule daily` (launchd job `app.deploycenter.daily`):
  ```bash
  deploys schedule off
  ```
  If you set it up by hand from [`scripts/daily-deploy.plist.example`](../scripts/daily-deploy.plist.example):
  ```bash
  launchctl unload ~/Library/LaunchAgents/app.deploycenter.daily.plist
  rm ~/Library/LaunchAgents/app.deploycenter.daily.plist /tmp/deploy-center-daily.log
  ```
- The pre-push check, in each repo where you ran `deploys hooks install`:
  ```bash
  deploys hooks uninstall <repo folder>   # puts back the pre-push hook that was there before
  ```
- The iPhone app: in Settings → iPhone, turn off **Connect the iPhone app (iCloud Keychain)**. That removes
  the keys the Mac put into your iCloud Keychain (item `app.deploycenter.link`), so they leave your
  other devices too. A QR code leaves nothing behind on the Mac; delete the iOS app on the phone.

Then quit the app.

## 2. Disconnect Claude and the editor add-ons

Only what you set up:

- **Claude Desktop and Claude Code** (connected in **Settings → Claude**): disconnect them there
  before you remove the app. Without the app:
  ```bash
  claude mcp remove deploy-center --scope user
  ```
  For Claude Desktop, delete the `deploy-center` entry under `mcpServers` in
  `~/Library/Application Support/Claude/claude_desktop_config.json` and restart Claude Desktop.
  If you added the MCP server by hand under another name (for example `deploys`), remove that name.
- **The Claude Code plugin**, in a Claude Code session:
  ```text
  /plugin uninstall deploy-center@deploy-center
  ```
  ```text
  /plugin marketplace remove deploy-center
  ```
- **The VS Code extension** (also Cursor, Windsurf): uninstall it from the Extensions view, or
  `code --uninstall-extension deploycenter.deploy-center`.
- **The Raycast extension**: remove it in Raycast → Settings → Extensions.
- **Widgets**: remove the Deploy Center widgets from the desktop or Notification Center (Mac) and
  from the Home Screen (iPhone, iPad).

## 3. Remove the app

Installed with Homebrew:

```bash
brew uninstall --cask deploy-center
```

`brew uninstall --zap --cask deploy-center` also removes the settings and the error log (see below). It keeps `~/.config/deploys`.

Installed by hand: move **Deploy Center** from Applications (or `~/Applications`) to the Trash.

Only the CLI, installed with the script (use the same `--prefix` as for the install):

```bash
curl -fsSL https://deploycenter.app/install.sh | sh -s -- --uninstall
```

Only the CLI, installed with Homebrew: `brew uninstall deploys`.

## 4. Remove what it kept on your Mac

| What | Where | Remove with |
|---|---|---|
| Render API key | Keychain, a password item with the service name `deploy-center-render` (older versions: `render-api-key`) | `security delete-generic-password -a "$USER" -s deploy-center-render` |
| Anthropic API key (Claude in the app) | Keychain, service name `deploy-center-anthropic` | `deploys ai forget-key`, or `security delete-generic-password -a "$USER" -s deploy-center-anthropic` |
| Autofix routine token | Keychain, service name `deploy-center-routine` | `deploys autofix forget-token`, or `security delete-generic-password -a "$USER" -s deploy-center-routine` |
| Keys of the opt-in hosts (Netlify, Cloudflare, DigitalOcean, Coolify; Amplify keeps only a profile name) | Keychain, service names `deploy-center-netlify`, `deploy-center-cloudflare`, `deploy-center-digitalocean`, `deploy-center-coolify`, `deploy-center-amplify` | `security delete-generic-password -a "$USER" -s deploy-center-<name>` for each one you set |
| Deploy hook URLs | Keychain, `deploy-center-hook-<name>` (without a keychain: `~/.config/deploys/hook-urls/`) | `deploys hook remove <name>` |
| The Vercel token made for the iPhone | Keychain, service name `deploy-center-phone-vercel` | `security delete-generic-password -a "$USER" -s deploy-center-phone-vercel` |
| Keys handed to the iPhone | iCloud Keychain (synced), service `app.deploycenter.link` | turn off **Settings → iPhone** first (see above); it removes them on all devices |
| Widget data (a small snapshot of what waits) | `~/Library/Group Containers/<team id>.app.deploycenter/` | delete that folder (only builds with widgets have it) |
| App settings | `~/Library/Preferences/app.deploycenter.mac.plist` | `defaults delete app.deploycenter.mac` |
| Cached lists, deploy history, site logos | `~/Library/Caches/app.deploycenter.mac/` | `rm -rf ~/Library/Caches/app.deploycenter.mac` |
| Error log | `~/Library/Logs/DeployCenter.log` | `rm ~/Library/Logs/DeployCenter.log` |
| CLI settings: remembered repos, team, ignored projects, Claude model, cap and usage (`ai-*`), Autofix and guard state, allowances, Netlify hook URLs | `~/.config/deploys/` (or `$DEPLOYS_CONFIG`) | `rm -rf ~/.config/deploys` |

If you had a key under the old name, run the keychain line again with `-s render-api-key`.

Tab completion: remove the `eval "$(deploys completion zsh)"` line from `~/.zshrc` (or the bash line from `~/.bashrc`) if you added it.

## 5. Optional: revoke access

Deploy Center never had its own account. To revoke what it used:

- Render: delete the API key at dashboard.render.com → Account Settings → API Keys.
- Anthropic: delete the API key at console.anthropic.com → Settings → API keys, and the Autofix
  routine (and its token) at claude.ai → Code → Routines.
- Netlify, Cloudflare, DigitalOcean, Coolify: delete the token you made for Deploy Center in each
  dashboard. On Netlify, also delete the build hook named `deploy-center` and, if you want builds on
  push again, the `ignore` line in `netlify.toml`.
- GitLab: `glab auth logout`, or revoke the `GITLAB_TOKEN` in GitLab → Preferences → Access tokens.
- iPhone: the keys it got are the Mac's (the Vercel token for the iPhone, the Render key, the `gh` token). Revoke them at Vercel, Render and GitHub if the phone or a QR code may have been seen by someone else.
- Vercel and GitHub: it used your `vercel` and `gh` logins. `vercel logout` and `gh auth logout` end them, also for everything else that uses them.
