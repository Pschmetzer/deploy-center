# Deploy Center for VS Code, Cursor and Windsurf

See what is merged but not live on Vercel, Render and every other platform `deploys` knows, right where you code, and deploy it by hand
in one click. It is the editor side of [Deploy Center](https://deploycenter.app): auto-deploy
stays off, and nothing builds unless you click **Deploy** and confirm.

Made for AI coding. When Claude Code or Cursor merges a few PRs, the status bar says
`⏳ 3 waiting`. When a build fails, **Copy for AI** puts the first error block on the clipboard,
ready to paste back into the agent.

## What it shows

- **Status bar:** `⏳ 3 waiting` for the projects whose repo matches this folder's git remote
  (or all projects when none match), plus `1 failed` and `2 building` when there are any.
  Click it for **Deploy** (with confirmation), **Open site**, **Show log** and **Copy release notes**.
- **Tree "Deploy Center"** in the Explorer: each project with its waiting commits and PRs, how
  long they have waited, and whether it is building or failed. Refresh is in the view's title bar.
- **Failed builds:** **Show log** puts the build log into the "Deploy Center" output channel.
  **Copy for AI** copies the first error and the lines around it, with tokens and keys masked.

## Commands

| Command | What it does |
|---|---|
| Deploy Center: Deploy Waiting for This Repo | Every waiting project of this folder's repo, after one confirmation |
| Deploy Center: Refresh | Read the projects again |
| Deploy Center: Show Actions | The status bar's quick pick |
| Deploy Center: Show Build Log / Copy Build Error for AI / Copy Release Notes / Open Site / Open Dashboard | For one project |

## Needs

The `deploys` CLI, which comes with the free Mac app. It is looked for in this order:

1. the setting `deployCenter.cliPath`,
2. `/Applications/Deploy Center.app/Contents/Resources/deploys`,
3. `~/Applications/Deploy Center.app/Contents/Resources/deploys`,
4. `deploys` on `PATH` (also `/opt/homebrew/bin` and `/usr/local/bin`).

Without it, the status bar says `deploys not found` and offers the download and the setting.

## Settings

| Setting | Default | |
|---|---|---|
| `deployCenter.cliPath` | empty | Full path to `deploys` |
| `deployCenter.scope` | `auto` | `auto`: this repo's projects, else all. `repo`: only this repo's. `all`: every project |
| `deployCenter.pollMinutes` | `5` | How often to check while the window has focus. It also checks when the window gets focus again (at most once a minute) |
| `deployCenter.timeoutSeconds` | `120` | How long one CLI call may take |
| `deployCenter.logLines` | `200` | Lines of build log to show |

## How it works

Every few minutes it runs `deploys changed --json` (what waits, from GitHub) and
`deploys status --json --no-github` (building and failed, no GitHub calls), with `execFile`,
an argument list and a timeout, never a shell. A deploy is `deploys <platform> deploy-json <name>`,
which takes the same one-minute start lock as the app, so a double click cannot start two builds.
Logs, release notes and the site address come from `deploys logs`, `deploys notes` and `deploys open`.

It does not read or send anything else. No telemetry.

## Develop

```bash
cd integrations/vscode
npm ci
npm test          # unit tests against a stand-in deploys
npm run build     # dist/extension.js
npm run package   # deploy-center-<version>.vsix
```

Press F5 in VS Code with this folder open to try it in an Extension Development Host, or install
the `.vsix` with **Extensions: Install from VSIX…** (in Cursor and Windsurf too).
Publishing: [PUBLISHING.md](PUBLISHING.md).
