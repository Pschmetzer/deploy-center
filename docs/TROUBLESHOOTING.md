# Troubleshooting

Each heading is a message the app or `deploys` shows, word for word. Search this page for the text you see.

First steps for any problem:

- `deploys doctor` prints what is connected as JSON (`jq`, `vercelCli`, `vercelApi`, `vercelLoggedIn`, `githubCli`, `githubLoggedIn`, `renderKey`).
- In the app, **Settings → Copy diagnostics** copies versions and what is connected, without project names or keys. Paste it into an issue.
- **Settings → Open the error log** opens `~/Library/Logs/DeployCenter.log`: every failed call to `deploys` and what it said.

The app runs the `deploys` script inside it (`Deploy Center.app/Contents/Resources/deploys`), so every error below can be reproduced in Terminal with the same command.

## Installing

### Homebrew asks you to trust the tap

Homebrew 6 asks once before it installs from a third-party tap. Trust it, then install:

```bash
brew tap pschmetzer/tap && brew trust pschmetzer/tap && brew install --cask deploy-center
```

### No admin rights

`/Applications` needs an admin password. Install into your own Applications folder instead:

```bash
brew install --cask deploy-center --appdir="$HOME/Applications"
```

By hand: unzip the release and drag **Deploy Center** into `~/Applications`. The built-in updater (Sparkle) replaces the app where it is, so updates need no admin rights either.

### macOS says the app cannot be opened (Gatekeeper)

Releases are signed with a Developer ID and notarized by Apple, so they open without a warning. If macOS still refuses:

1. Download the zip again from [the latest release](https://github.com/Pschmetzer/deploy-center/releases/latest). A broken or partial download is the usual cause.
2. Check what Gatekeeper says:
   ```bash
   spctl -a -vv "/Applications/Deploy Center.app"
   ```
   `accepted` and `source=Notarized Developer ID` is the expected answer.
3. If it says `rejected`, please open an issue with that output. Do not turn Gatekeeper off for it.

A build you made yourself with `./build.sh` is not notarized. Open it with right-click → **Open** the first time.

## Vercel

### Connect Vercel – "Install the Vercel CLI, then log in once in Terminal."

The app did not find the `vercel` command. Install it, then log in:

```bash
npm i -g vercel
vercel login
```

Then press **Done – check again**.

### `vercel` is installed (nvm, volta, fnm), but the app does not find it

A Mac app does not get your Terminal's `PATH`. The app looks in `/opt/homebrew/bin`, `/usr/local/bin` and `~/.local/bin`, plus the `PATH` of your **login shell**, which it reads once a day.

A login shell started by the app (`zsh -l`) does not read `~/.zshrc`. If nvm is set up only in `~/.zshrc`, neither `vercel` nor `node` is found. Check what the app will see:

```bash
zsh -lc 'command -v vercel node'
```

If that prints nothing, pick one:

- Move the nvm (or volta, fnm) setup lines from `~/.zshrc` into `~/.zprofile`.
- Or install Node with Homebrew (`brew install node`), then `npm i -g vercel`. Both land in `/opt/homebrew/bin`.

The app keeps the `PATH` it read for a day. To read it again now, quit the app, run the line below, and open it again:

```bash
defaults delete app.deploycenter.mac searchPath
```

### Connect Vercel – "Log in once in Terminal. The app uses that login."

`vercel` is there but not logged in. Run `vercel login`. In Terminal the same case reads:

> Error: The vercel CLI is not logged in. Run: vercel login

### Update the Vercel CLI – "Your Vercel CLI is too old (it has no `vercel api`)."

```bash
npm i -g vercel@latest
```

### "Several Vercel teams. Choose one: deploys vercel team <id>"

Your login belongs to more than one team. The error lists each team id and name. Pick one:

```bash
deploys vercel team team_abc123
```

The choice is saved in `~/.config/deploys/vercel-team`. In CI, set `DEPLOYS_VERCEL_TEAM` instead.

### "<project> has no remembered repo. Turn its auto-deploy off with this tool, or add it to …/vercel-repos.json"

Deploy Center learns a project's repo when it turns auto-deploy off. A project that was disconnected some other way has no repo on record. Tell it:

```bash
deploys vercel map my-project me/my-repo main
```

In the app such a row says **repo unknown**.

### "Skipped or canceled by Vercel (Ignored Build Step?)"

Vercel canceled the build, usually because the project's **Ignored Build Step** decided nothing changed. That is not an error. See [GLOSSARY.md](GLOSSARY.md#ignored-build-step).

## GitHub

### "GitHub CLI is not logged in, so the waiting commits and PRs cannot be counted. In Terminal: gh auth login"

The GitHub CLI is optional. Without it, deploying works, but the app cannot see what is waiting on GitHub: no **New changes**, no counts, and **Select all changed** has nothing to select.

```bash
brew install gh
gh auth login
```

`deploys explain my-project` says the same in Terminal:

> unknown: the branch head is not known (gh missing or not logged in?)

### "GitHub's hourly budget is nearly spent …"

GitHub allows a fixed number of API calls per hour for your login. Under 300 left, Deploy Center reads only the newest commit of each branch and skips the counts. They come back when the hour resets. `deploys github-budget` shows what is left.

## Render

### Connect Render

Create an API key at dashboard.render.com → Account Settings → API Keys and paste it into the app. It is stored in your macOS keychain. In Terminal:

```bash
pbpaste | deploys render set-key
```

Related messages:

- `Error: No Render API key. Create one at dashboard.render.com > Account Settings > API Keys, then: deploys render set-key`
- `Error: Pipe the key in: pbpaste | deploys render set-key` (nothing came in on stdin)
- `Error: That does not look like a Render API key` (it has a space or a quote in it; copy it again)

### "… -> HTTP 401 (the Render key is wrong or expired: deploys render set-key)"

Render refused the key (401 or 403). It was revoked, expired, or copied wrong. Create a new one and save it again with `pbpaste | deploys render set-key`. The new key replaces the old one.

### "… -> HTTP 429 (rate limit: try again in a minute)"

Render limits how fast its API may be called. Deploy Center already waits and retries twice. Try again in a minute.

### "… -> HTTP 404 (not found: renamed or deleted?)"

The service was renamed or deleted on Render. Reload the list.

### Auto-deploy turns itself back on

A Render **Blueprint** with auto-sync can apply `render.yaml` again on a push. Add `autoDeployTrigger: off` to the services in `render.yaml`. `deploys triggers` lists Blueprints with auto-sync on.

## GitLab

### "gitlab: HTTP 401: …"

The GitLab token is missing, wrong or expired. Log in with `glab auth login` (for your own GitLab: `--hostname`), or set `GITLAB_TOKEN` (scope `read_api`). With both, `glab` is used. See [GITLAB.md](GITLAB.md).

### A GitLab project shows "branch head unknown"

Neither `glab` nor `GITLAB_TOKEN` is set up, or the repo is on another host (Bitbucket, Gitea): those are not read. For your own GitLab set `GITLAB_HOST`.

## Other hosts

Netlify, Cloudflare Pages, AWS Amplify, DigitalOcean App Platform, Coolify and deploy hooks are off until `deploys providers enable <p>`. Each has its own page with its errors: [Netlify](providers/netlify.md), [Cloudflare](providers/cloudflare.md), [Amplify](providers/amplify.md), [DigitalOcean](providers/digitalocean.md), [Coolify](providers/coolify.md), [deploy hook](providers/hook.md).

## Team mode

### "Observer mode (…): "deploys …" changes something and is refused."

This Mac is an observer: you are on the `observers` list of the repo's `deploy-center.json`, or observer mode is on here. Observers can look, not deploy. The message ends with what to do: `deploys readonly off`, unset `DEPLOYS_READONLY`, or ask to be taken off the list. See [TEAM.md](TEAM.md).

## Claude and Autofix

### "That does not look like a routine token (sk-ant-...)"

`deploys autofix set-token` takes the routine's token on stdin: `pbpaste | deploys autofix set-token`. See [AUTOFIX.md](AUTOFIX.md).

### "autofix is running already"

A run is still going (the scheduled one every 10 minutes, or one you started). Wait for it; its log is `~/Library/Logs/DeployCenter-autofix.log`.

### "This month's Claude cap is reached (…)"

Claude in the app stops at the monthly token cap you set. Raise it in Settings → Claude in the app, or with `deploys ai cap <tokens>`. See [CLAUDE.md](CLAUDE.md).

### "The config file is not valid JSON. Nothing was changed."

Settings → Claude → Connect for Claude Desktop edits `~/Library/Application Support/Claude/claude_desktop_config.json` only when it is valid JSON. Fix or remove the broken file, then connect again.

## iPhone

### "This build cannot use iCloud Keychain. Use the QR code."

A self-built (ad hoc signed) app has no keychain group to share with the iPhone. Use **Show a QR code for the iPhone …** in Settings → iPhone, or install a release.

### "Could not write to iCloud Keychain (error …)"

iCloud Keychain is off on this Mac (System Settings → your name → iCloud → Passwords), or the Mac is signed in with another Apple ID than the iPhone. The number is the keychain's error code; it is also in the error log.

## Deploying

### "<project> is being started already (wait a minute)"

The same project was started less than a minute ago, from the app or from Terminal. The lock stops two builds from two quick clicks. It expires after a minute, and at once if the start failed.

### "No answer after 120 seconds – try again."

A call to Vercel, Render or GitHub hung. Check your network and try again.

### "No result after 40 minutes – check the dashboard"

The app stopped following a deploy after 40 minutes. The deploy may still be running. Look in the Vercel or Render dashboard, or run `deploys watch my-project`.

### "Not started: the backend of the same repo failed"

When a Vercel frontend and a Render backend deploy from the same repo in one run, the frontend waits for the backend. The backend failed, so the frontend was not started. Fix the backend first.

### A build ran although auto-deploy is off

Something else started it: a GitHub workflow, a deploy hook, or a Render Blueprint. List what started builds in the last 24 hours and which workflows deploy by themselves:

```bash
deploys triggers
```

## Updating

### An update does not show up, or does not install

The app updates itself with Sparkle: once a day (Settings → **Check for updates automatically**) and on **Check for Updates …** in the app menu. It reads `https://deploycenter.app/appcast.xml`, downloads the zip from GitHub, and installs it only if the EdDSA signature and the Developer ID match, and only once no deploy is running. If a check fails, the app stays as it was and Sparkle says why. Install by hand from [the latest release](https://github.com/Pschmetzer/deploy-center/releases/latest), or with `brew upgrade --cask --greedy deploy-center`.

## Still stuck?

Open an [issue](https://github.com/Pschmetzer/deploy-center/issues) with the output of **Copy diagnostics** and the relevant lines of the error log. Issues are public: remove project names and domains first. Never paste a key.
