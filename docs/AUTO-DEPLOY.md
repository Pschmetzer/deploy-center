# Turning auto-deploy off, and back on

## What changes

| | Vercel | Render |
|---|---|---|
| What Deploy Center does | Removes the project's Git connection. It writes down the repo and production branch in `~/.config/deploys/vercel-repos.json` first. | Sets the service's auto-deploy to *Off*. The service stays connected to its repo. |
| Push to the production branch | Before: a production build. After: nothing. | Before: a deploy. After: nothing. |
| Push to another branch or a PR | Before: a preview build. After: nothing, since there is no Git connection. | Not changed by Deploy Center. |
| Deploying | `deploys vercel deploy` or the app (newest commit). **Redeploy** in the dashboard builds an existing deployment's commit again. | `deploys render deploy`, the app, or **Manual Deploy** in the dashboard. |
| What goes live | The newest commit of the remembered branch on GitHub. | The newest commit of the service's branch. |
| GitHub workflows, deploy hooks | GitHub workflows that deploy keep working; `deploys triggers` lists them. Vercel deploy hooks are set up under the Git settings: check them in the dashboard. | Keep working. A Blueprint with auto-sync can turn auto-deploy on again (see below). |
| Shown as | The row no longer says **deploys on every push**; `deploys vercel list` says `manual`. | The row no longer says **deploys on every push**; `deploys render list` says `off`. |

Render: if your services come from a Blueprint with auto-sync, add `autoDeployTrigger: off` to each service in `render.yaml`. Otherwise the next sync can set it back.

## Back to auto-deploy

For good, per project or for all:

```bash
deploys vercel autodeploy-on my-project   # or --all: connects Git again from vercel-repos.json
deploys render autodeploy-on my-service   # or --all: auto-deploy "On Commit"
```

For a few hours (the [guard](GUARD.md) turns it off again afterwards):

```bash
deploys autodeploy allow vercel my-project 4
```

Vercel needs the repo in `~/.config/deploys/vercel-repos.json` (each entry has `org`, `repo` and
`ref`, the production branch). Afterwards, check that Project → Settings → Git → Production Branch
matches `ref`. In the dashboard it is
Project → Settings → Git → connect the repository again.

**Render** in the dashboard: Service → Settings → Build & Deploy → Auto-Deploy → *On Commit*.

The app then shows the row as **deploys on every push** again, and the menu bar counts it in "Auto-deploy is still on for … projects". If the [guard](GUARD.md) is on, it turns it off again within 30 minutes unless an allowance covers it.

Before you uninstall Deploy Center, keep `~/.config/deploys/vercel-repos.json` until every Vercel project is connected again. For a project you disconnected with Deploy Center, it is the only record of where it deployed from.
