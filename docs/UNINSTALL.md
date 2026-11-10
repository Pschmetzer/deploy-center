# Uninstall

Uninstalling does not turn auto-deploy back on. Your projects stay manual until you reconnect them ([AUTO-DEPLOY.md](AUTO-DEPLOY.md#back-to-auto-deploy)). Do that first if you want it, while `~/.config/deploys/vercel-repos.json` still tells you which repo each project came from.

## 1. Stop what runs on its own

- In the app, turn off **Settings → Open at login** (or remove Deploy Center under System Settings → General → Login Items).
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
| App settings | `~/Library/Preferences/app.deploycenter.mac.plist` | `defaults delete app.deploycenter.mac` |
| Cached lists, deploy history, site logos | `~/Library/Caches/app.deploycenter.mac/` | `rm -rf ~/Library/Caches/app.deploycenter.mac` |
| Error log | `~/Library/Logs/DeployCenter.log` | `rm ~/Library/Logs/DeployCenter.log` |
| CLI settings: remembered repos, team, ignored projects | `~/.config/deploys/` (or `$DEPLOYS_CONFIG`) | `rm -rf ~/.config/deploys` |

If you had a key under the old name, run the keychain line again with `-s render-api-key`.

Tab completion: remove the `eval "$(deploys completion zsh)"` line from `~/.zshrc` (or the bash line from `~/.bashrc`) if you added it.

## 4. Optional: revoke access

Deploy Center never had its own account. To revoke what it used:

- Render: delete the API key at dashboard.render.com → Account Settings → API Keys.
- Vercel and GitHub: it used your `vercel` and `gh` logins. `vercel logout` and `gh auth logout` end them, also for everything else that uses them.
