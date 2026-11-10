# Uninstall

Uninstalling does not turn auto-deploy back on. Your projects stay manual until you reconnect them ([AUTO-DEPLOY.md](AUTO-DEPLOY.md#back-to-auto-deploy)). Do that first if you want it, while `~/.config/deploys/vercel-repos.json` still tells you which repo each project came from.

## 1. Stop what runs on its own

- In the app, turn off **Settings → Open at login** (or remove Deploy Center under System Settings → General → Login Items).
- **Settings → iPhone**: turn off **Connect the iPhone app (iCloud Keychain)**. That removes the keys the Mac put into iCloud Keychain, on every device signed in with your Apple ID. Deleting the app does not.
- **Settings → Claude**: press **Disconnect** for Claude Desktop and for Claude Code. That removes the `deploy-center` entry from `~/Library/Application Support/Claude/claude_desktop_config.json` and from Claude Code.
- The guard and Autofix, if you turned them on (each is a LaunchAgent):
  ```bash
  deploys guard schedule off      # removes ~/Library/LaunchAgents/app.deploycenter.guard.plist
  deploys autofix schedule off    # removes ~/Library/LaunchAgents/app.deploycenter.autofix.plist
  rm -f ~/Library/Logs/DeployCenter-guard.log ~/Library/Logs/DeployCenter-autofix.log
  ```
  Without the CLI: `"/Applications/Deploy Center.app/Contents/Resources/deploys" guard schedule off`, or `launchctl unload` and remove the two plist files.
- Only if you set up the daily LaunchAgent from [`scripts/daily-deploy.plist.example`](../scripts/daily-deploy.plist.example):
  ```bash
  launchctl unload ~/Library/LaunchAgents/app.deploycenter.daily.plist
  rm ~/Library/LaunchAgents/app.deploycenter.daily.plist /tmp/deploy-center-daily.log
  ```

Then quit the app.

## 2. Remove the app

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

## 3. Remove what it kept on your Mac

| What | Where | Remove with |
|---|---|---|
| Render API key | Keychain, a password item with the service name `deploy-center-render` (older versions: `render-api-key`) | `security delete-generic-password -a "$USER" -s deploy-center-render` |
| Anthropic API key (Claude in the app) | Keychain, service name `deploy-center-anthropic` | `deploys ai forget-key`, or `security delete-generic-password -a "$USER" -s deploy-center-anthropic` |
| Autofix routine token | Keychain, `deploy-center-routine` | `deploys autofix forget-token` |
| Vercel token for the iPhone | Keychain, `deploy-center-phone-vercel` | `security delete-generic-password -a "$USER" -s deploy-center-phone-vercel` |
| Keys handed to the iPhone | iCloud Keychain (synced), service `app.deploycenter.link` | turn off **Settings → iPhone** first (see above); it removes them on all devices |
| Netlify, Cloudflare, DigitalOcean, Coolify tokens | Keychain, `deploy-center-netlify`, `-cloudflare`, `-digitalocean`, `-coolify` | `security delete-generic-password -a "$USER" -s deploy-center-netlify` (and so on) |
| AWS Amplify profile name (not a key) | Keychain, `deploy-center-amplify` | `security delete-generic-password -a "$USER" -s deploy-center-amplify` |
| Deploy hook URLs | Keychain, `deploy-center-hook-<name>`, or files in `~/.config/deploys/hook-urls/` | `deploys hook remove <name>` for each (`deploys hook list`) |
| App settings | `~/Library/Preferences/app.deploycenter.mac.plist` | `defaults delete app.deploycenter.mac` |
| Cached lists, deploy history, site logos | `~/Library/Caches/app.deploycenter.mac/` | `rm -rf ~/Library/Caches/app.deploycenter.mac` |
| Error log | `~/Library/Logs/DeployCenter.log` | `rm ~/Library/Logs/DeployCenter.log` |
| CLI settings: remembered repos, team, ignored projects, enabled platforms, guard and Autofix state, allowances, Claude model, cap and usage (`ai-*`) | `~/.config/deploys/` (or `$DEPLOYS_CONFIG`) | `rm -rf ~/.config/deploys` |

If you had a key under the old name, run the keychain line again with `-s render-api-key`.

Tab completion: remove the `eval "$(deploys completion zsh)"` line from `~/.zshrc` (or the bash line from `~/.bashrc`) if you added it.

## 4. Optional: revoke access

Deploy Center never had its own account. To revoke what it used:

- Render: delete the API key at dashboard.render.com → Account Settings → API Keys.
- Netlify, Cloudflare, DigitalOcean, Coolify, Anthropic: delete the token you made for Deploy Center in that service's settings.
- iPhone: the keys it got are the Mac's (the Vercel token for the iPhone, the Render key, the `gh` token). Revoke them at Vercel, Render and GitHub if the phone or a QR code may have been seen by someone else.
- Vercel and GitHub: it used your `vercel` and `gh` logins. `vercel logout` and `gh auth logout` end them, also for everything else that uses them.
