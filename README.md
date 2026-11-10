<p align="center"><b>English</b> · <a href="README.de.md">Deutsch</a></p>

<h1 align="center">Deploy Center</h1>

<p align="center"><b>Turn off auto-deploy on Vercel and Render. Deploy what changed with one click.</b><br>
Your agent pushes 40 times. You deploy once.<br>
Works great with Claude Code: let the agent push, you decide what ships.</p>

<p align="center">
  <a href="https://github.com/Pschmetzer/deploy-center/releases/latest"><img alt="Latest release" src="https://img.shields.io/github/v/release/Pschmetzer/deploy-center?label=release"></a>
  <img alt="macOS 15+" src="https://img.shields.io/badge/macOS-15%2B-black?logo=apple">
  <a href="#install"><img alt="Homebrew cask" src="https://img.shields.io/badge/brew-cask-orange?logo=homebrew&logoColor=white"></a>
  <a href="LICENSE"><img alt="MIT" src="https://img.shields.io/badge/license-MIT-green"></a>
</p>

<p align="center"><img src="docs/images/app.png" width="900" alt="Deploy Center: 149 PRs waiting to deploy, Vercel build costs of the last 7 days and the projects with commits waiting"></p>
<p align="center"><sub>The author's real build bill: $99 in 7 days. Project names hidden by demo mode.</sub></p>

## Install

```bash
brew tap pschmetzer/tap && brew trust pschmetzer/tap && brew install --cask deploy-center
```

Or [download the zip](https://github.com/Pschmetzer/deploy-center/releases/latest), unzip it and drag
**Deploy Center** to *Applications*. Free, MIT, signed and notarized by Apple. Website: [deploycenter.app](https://deploycenter.app).

**Only the CLI** (macOS, Linux, WSL, CI; no app): `deploys` on its own, checked against the
release's SHA-256, into `~/.local/bin` without sudo. Or with Homebrew on macOS and Linux:

```bash
curl -fsSL https://deploycenter.app/install.sh | sh
brew install pschmetzer/tap/deploys
```

Docker, CI keys and first steps: [README-CLI.md](README-CLI.md).

<details>
<summary>Homebrew notes and requirements</summary>

Homebrew 6 asks you to trust a third-party tap once (`brew trust`). Without admin rights, add
`--appdir="$HOME/Applications"`. Updates: `brew upgrade --cask deploy-center` or **Update now** in Settings.

| What | Needed for | Install |
|---|---|---|
| macOS 15 or newer, Apple silicon or Intel | the app | |
| `jq` | everything (the app asks for it if it is missing) | `brew install jq` |
| Vercel CLI, which needs Node.js | Vercel | `npm i -g vercel`, then `vercel login` |
| Render API key | Render | dashboard.render.com → Account Settings → API Keys |
| GitHub CLI `gh` | optional: what is waiting (*New changes*, commits and PRs) | `brew install gh`, then `gh auth login` |

The app finds `vercel` from nvm, volta or fnm only if your login shell sets them up (`~/.zprofile`, not only `~/.zshrc`).
See [Troubleshooting](docs/TROUBLESHOOTING.md#vercel-is-installed-nvm-volta-fnm-but-the-app-does-not-find-it).
</details>

## Why

Every push builds every connected project, and build minutes cost money. AI coding agents push
many times a day, so the builds add up. Deploying once a day with a click costs a fraction,
and nothing ships by accident. Try the [cost calculator](https://deploycenter.app/#calc).

## How it works

1. **Connect.** Vercel uses your `vercel login`. For Render, paste an API key; it is stored in your macOS keychain.
2. **Turn off auto-deploy.** One click for all projects. A push now builds nothing.
3. **Deploy when you want.** The app shows what is waiting. *Select all changed* + *Deploy* is the daily deploy.

New to it? [Try it safely](docs/SAFE-START.md): look first, then one project, then all.

Batching many pushes (AI agents)? [Safe deploys](docs/SAFE-DEPLOY.md): only green CI, a health check with rollback, deploy windows and a risk light.

## Features

- Turns off auto-deploy for all Vercel projects and Render services at once. [What changes](docs/AUTO-DEPLOY.md)
- Deploys the newest commit, for one project or many, and follows each deploy until live or failed
- Shows what is waiting: commits and merged PRs not live yet, per project and in total. [How it counts](docs/NUMBERS.md)
- Shows your Vercel build costs
- Estimates what auto-deploy would cost a month, and what turning it off saved since. [How it estimates](docs/SAVINGS.md)
- Menu bar icon with the number of PRs waiting, and a notification when a deploy ends
- Preview deploys (Vercel) and rollback to the previous live deploy
- A bash CLI, `deploys`, that does all of this without the app, also on Linux and in CI. [CLI reference](docs/CLI.md)
- Add-ons: a GitHub Action, badges, a daily summary to a webhook, a pre-push hook, a Docker image. [Integrations](integrations/)
- Autofix: a failed build goes to a Claude Code routine that opens a fix PR. [Autofix](docs/AUTOFIX.md)
- English and German

## Deploy Center + Claude Code

- **Autofix: a failed build fixes itself (almost).** Deploy Center hands the masked build log to a Claude Code
  routine, and Claude opens a PR with the fix. After you merge, the next run deploys that merge commit, once.
  It never merges by itself. [Autofix](docs/AUTOFIX.md)
- **One deploy for many pushes.** Let the agent push as often as it likes; nothing builds until you deploy what changed.
- **Copy for Claude.** The build log of a failed deploy has a button that copies the error and the log around it as a prompt, ready to paste.
- *Coming:* an MCP server, so Claude can ask what is waiting and deploy only with your OK, and a digest of what the agent pushed for you to approve.

More: [deploycenter.app/claude-code](https://deploycenter.app/claude-code/)

## What it changes, and how to undo it

| | What Deploy Center does | How to undo it |
|---|---|---|
| **Vercel** | Removes the project's Git connection. It writes down the repo and branch in `~/.config/deploys/vercel-repos.json` first. | Project → Settings → Git → connect the repository again. |
| **Render** | Sets the service's auto-deploy to *Off*. The service stays connected to its repo. | Service → Settings → Build & Deploy → Auto-Deploy → *On Commit*. |

There is no undo command: you turn auto-deploy back on in each dashboard. Uninstalling does not turn it back on.
Deploy hooks and GitHub workflows that deploy keep working; `deploys triggers` lists them. On Render, a
Blueprint with auto-sync can turn auto-deploy on again: add `autoDeployTrigger: off` to your services in
`render.yaml`. Details: [Auto-deploy off and back on](docs/AUTO-DEPLOY.md) · [Uninstall](docs/UNINSTALL.md).

## Command line

```bash
deploys changed               # what is merged on GitHub and not live
deploys deploy-changed --yes  # deploy all of it
deploys simulate              # estimate: auto-deploy a month vs. once a day
deploys ledger                # estimate: saved since auto-deploy was turned off
```

Inside the app at `Deploy Center.app/Contents/Resources/deploys`. All commands, CI variables and
settings: [docs/CLI.md](docs/CLI.md).

## Roadmap

- [x] Vercel and Render: auto-deploy off, deploy, preview, rollback
- [x] What is waiting (commits and PRs) and Vercel build costs
- [x] Menu bar, notifications, English and German
- [x] `deploys` CLI, GitHub Action, badges, daily webhook summary, pre-push hook, Docker image
- [x] Autofix for failed builds
- [ ] Netlify
- [ ] Cloudflare Pages
- [ ] AWS Amplify
- [ ] Generic deploy hook (any platform with a deploy URL)
- [ ] MCP server for AI agents
- [ ] Raycast extension
- [ ] Linux CLI packaging
- [ ] Team sync

Which platform should come next? [Vote with an issue](https://github.com/Pschmetzer/deploy-center/issues/new?template=platform-request.yml).

## Alternatives

- **Vercel Ignored Build Step.** Built into Vercel and free. A command per project decides on each
  push whether to build. Great for monorepos, and works well together with Deploy Center. It does not
  give you one place to see and deploy what is waiting. See the [Glossary](docs/GLOSSARY.md#ignored-build-step).
- **The dashboard toggle.** Disconnect Git on Vercel or set auto-deploy to *Off* on Render by hand.
  Fine for one or two projects. With many, it is a lot of clicks, and you deploy from each dashboard.
- **Status-only menu bar apps.** They show deploy status, some for more providers than Deploy Center
  supports. They leave auto-deploy as it is. If you only want to watch builds, they may be all you need.

## FAQ

**What does it cost?** Nothing. You pay Vercel and Render for the builds you start, and fewer of them.

**Does it deploy anything by itself?** No. It deploys when you press **Deploy** or run a `deploys`
command with `--yes`. A scheduled deploy is yours to set up: [examples/](examples/).

**Where is my Render key?** In your macOS keychain. It is sent only to api.render.com. It gives full
access to your Render account.

**Does the app send data anywhere?** No telemetry, no account, no server of ours. It talks to Vercel,
Render and GitHub with your own logins, to your sites for logos and the check after a deploy, and once a
day to GitHub's release page for updates (Settings can turn that off). Errors go to `~/Library/Logs/DeployCenter.log` on your Mac.

**GitLab or Bitbucket?** Not yet. Deploys start from GitHub.

**Windows or Linux?** The app needs macOS 15. The `deploys` CLI is bash and runs on Linux and in CI.

More: [FAQ](docs/FAQ.md) · [Troubleshooting](docs/TROUBLESHOOTING.md) · [Glossary](docs/GLOSSARY.md) · [All docs](docs/README.md)

## Contributing

Ideas and bug reports are welcome in [Issues](https://github.com/Pschmetzer/deploy-center/issues).
Most wanted: GitLab next to GitHub, and reports when a number in the app looks wrong.
Small tasks to start with: [Good first issues](docs/GOOD-FIRST-ISSUES.md). How to build and test:
[CONTRIBUTING.md](CONTRIBUTING.md).

```bash
./build.sh               # app and zip in build/
tests/script-tests.sh    # the rules in deploys, no network needed
tests/app-tests.sh       # the rules in the app
```

## License

MIT, see [LICENSE](LICENSE). Not affiliated with Vercel or Render.
Claude is a trademark of Anthropic; not affiliated.

[Legal notice (Impressum)](https://deploycenter.app/impressum.html) · [Privacy policy (Datenschutz)](https://deploycenter.app/datenschutz.html)
