# Vercel

On by default. `deploys` uses the Vercel CLI for everything, so it never holds a Vercel token of its own.

## What it saves you: build minutes

Vercel builds every connected project for every push: production on the production branch, a preview on every other
branch. With auto-deploy off, a push builds nothing and you deploy once when you decide. The
[build cost calculator](https://deploycenter.app/vercel-build-cost-calculator/) and `deploys simulate` estimate what that is worth for you.

## Setup

```bash
npm i -g vercel
vercel login
```

In CI, set `VERCEL_TOKEN` instead of logging in, and install the CLI in the runner. `deploys doctor` says what is missing.
If your login sees several teams, choose one with `deploys vercel team <id>` (or `DEPLOYS_VERCEL_TEAM`).

## Turning auto-deploy off

```bash
deploys vercel autodeploy-off <project>      # or --all
```

This removes the project's Git connection. The repo and production branch are written to
`~/.config/deploys/vercel-repos.json` first, because Vercel forgets them. GitHub workflows and deploy hooks that
deploy keep working; `deploys triggers` lists them. A project that has no remembered repo is shown as not deployable until
you say where it deploys from: `deploys vercel map <project> <owner/repo> [branch]`.

## Deploying

```bash
deploys vercel deploy <project>              # the newest commit of the remembered branch
deploys vercel deploy <project> --preview    # a preview first
deploys vercel deploy <project> --sha <commit>
```

`--sha` deploys that commit instead of the newest. Vercel is the host that supports previews here; Render does not.

## Other commands

| Command | What it does |
| --- | --- |
| `deploys vercel list` | projects, whether a push builds them (`manual` when it does not), and the newest deployment |
| `deploys status` | what is building or failed, on every host |
| `deploys logs <project> [lines]` | the end of the newest build log |
| `deploys vercel rollback <project>` | production back to the deploy before the live one |
| `deploys vercel cancel <deploy id>` | stops a build that is running |

## Undo

```bash
deploys vercel autodeploy-on <project>       # or --all: connects Git again from vercel-repos.json
```

Afterwards check Project → Settings → Git → Production Branch against the remembered branch. Keep
`vercel-repos.json` until every project is connected again: for a project you disconnected with Deploy Center it is the
only record of where it deployed from. More: [AUTO-DEPLOY.md](../AUTO-DEPLOY.md), [TROUBLESHOOTING.md](../TROUBLESHOOTING.md#vercel).
