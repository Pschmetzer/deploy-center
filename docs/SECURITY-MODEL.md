# Security model: what Deploy Center reads, stores and sends

Deploy Center is a Mac app and a bash script that run as you, with your own logins. It has no server, no account and no telemetry. This page is the plain-language version; [SECURITY.md](../SECURITY.md) at the top of the repo has the full threat model, every host it talks to and how to report a problem.

## What it reads

- **Your hosts**: project and service lists, deploys, build logs and the auto-deploy setting from Vercel, Render and the opt-in hosts ([providers/README.md](providers/README.md)), through the `vercel` CLI login or an API key you gave it.
- **Your git hosts**: commits, compares, pull requests, check runs and workflow file names from GitHub (the `gh` CLI login) and, for repos there, GitLab ([GITLAB.md](GITLAB.md)). It never reads your source code on your disk; for a bug scan or a security check it starts tools on a clone you chose ([SCAN.md](SCAN.md)).
- **Your own sites**: their icons, and a plain GET after a deploy when you use `deploys verify`.
- **Your Mac's config**: `~/.config/deploys` (see below) and the CLI logins it already has.

Everything that comes from outside (project names, commit messages, build logs, a `deploy-center.json` in a repo) is treated as data, never as code: it is passed to `jq` as an argument, to API paths only after a name check, and to the MCP server as a plain argument list.

## What it stores

| What | Where | Notes |
|---|---|---|
| The Render key, the Claude routine token, your Anthropic key, the keys of the opt-in hosts, deploy hook URLs | the macOS keychain, items named `deploy-center-…` | Read from stdin when you set them, handed to `curl` on stdin. Never a command-line argument, never printed. In CI they come from environment variables. |
| Which repo and branch a Vercel project deployed from, the ignore list, settings, locks | `~/.config/deploys` (mode `0700`) | No API keys in it. Keep `vercel-repos.json` until Git is connected again ([AUTO-DEPLOY.md](AUTO-DEPLOY.md)). |
| What the app and CLI started, rolled back or canceled | the deploy journal, one line each, hash-chained | Never leaves the Mac; error texts are masked ([JOURNAL.md](JOURNAL.md)). |
| App settings | the app's preferences | [SETTINGS.md](SETTINGS.md) |
| Keys for the iPhone app | one item in your iCloud Keychain, or a QR code | Only when you turn it on. The QR code is not encrypted: anyone who photographs it has the keys. Use keys made for the phone ([SECURITY.md](../SECURITY.md#iphone-link)). |

`deploys where` shows where the keys come from; `deploys creds` shows whether each one works and how old it is. Neither prints a key.

## What it sends, and where

| To | What | When |
|---|---|---|
| Vercel, Render and the other hosts you turned on | the calls you would make in their dashboards: lists, deploys, logs, starts and rollbacks | always, with your login; starts only on a click or `--yes` |
| GitHub, GitLab | the calls for commits, pull requests and checks | with your `gh` or `glab` login or token |
| your own domains | a GET for the icon and the site check | after a deploy with `verify`, and for icons |
| the status pages of Vercel, Render and GitHub | a plain GET, nothing of yours | the app, to say whether a host is down |
| `deploycenter.app/appcast.xml` | an update check, no system profile | once a day, can be turned off; the update itself comes from GitHub |
| Anthropic | a masked log excerpt or commit titles, only with your own key or routine | only after you set up Claude in the app, Autofix or a scan, and only when you ask ([CLAUDE-IN-APP.md](CLAUDE-IN-APP.md#privacy), [AUTOFIX.md](AUTOFIX.md)) |
| OSV and Semgrep | package names and versions; the rule set is downloaded | only for the security check ([SCAN.md](SCAN.md)) |
| a webhook you chose | project names and counts | only when you run the daily summary |

Nothing else leaves the Mac. Masking of build logs (tokens, passwords, keys) is a help, not a guarantee: if a build can print secrets in an odd shape, do not turn Autofix on.

## What it will not do on its own

- Start a build, a rollback or a cancel: only a click, or a command with `--yes`. A `deploycenter://` link only shows a project or opens a settings tab.
- Merge anything. Autofix and scans open pull requests; a person merges.
- Deploy from an AI agent: the MCP server is read-only unless you start it with `DEPLOYS_MCP_ALLOW_DEPLOY=1`, and then it still asks you for each one ([integrations/mcp](../integrations/mcp/README.md#safety)).
- Switch auto-deploy back on: only you can, and the [guard](GUARD.md) turns it off again.

## What to do to keep it tight

- Make keys just for this app and revoke them when you uninstall ([UNINSTALL.md](UNINSTALL.md)).
- Turn on observer mode (`deploys readonly on`) on Macs that should only look ([TEAM.md](TEAM.md)). It stops slips; it is not access control.
- Verify a download before you open it ([integrations/VERIFY.md](../integrations/VERIFY.md)).
- Report a problem through a private security advisory, not a public issue ([SECURITY.md](../SECURITY.md#report-a-problem)).
