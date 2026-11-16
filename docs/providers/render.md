# Render

On by default. `deploys` talks to the Render API with your own key.

## What it saves you: a deploy per push

A Render service with auto-deploy on deploys on every push to its branch. Set to Off, a push does nothing and you deploy
when you decide. The service stays connected to its repository.

## Setup

Create an API key under dashboard.render.com → Account Settings → API Keys, then:

```bash
pbpaste | deploys render set-key
```

The key goes into the macOS keychain (item `deploy-center-render`). On a server or in CI set `RENDER_API_KEY` instead.

## Turning auto-deploy off

```bash
deploys render autodeploy-off <service>      # or --all
```

This sets the service's auto-deploy to Off. If your services come from a Blueprint with auto-sync, also put
`autoDeployTrigger: off` on each service in `render.yaml`, or the next sync can switch it back on. Cron jobs are left out:
a manual deploy of a cron job is refused by Render.

## Deploying

```bash
deploys render deploy <service>              # the newest commit of the service's branch
deploys render deploy <service> --sha <commit>
```

Render has no preview deploys here, so `--preview` is not offered.

## Other commands

| Command | What it does |
| --- | --- |
| `deploys render list` | services, whether a push deploys them (`off` when it does not), and the newest deploy |
| `deploys render status <service> [<deploy id>]` | one deploy; the newest without an id |
| `deploys logs <service> [lines] [--runtime]` | the end of the newest build log, or the running service's log |
| `deploys render rollback <service>` | back to the deploy before the live one |
| `deploys render cancel <deploy id>` | stops a deploy that is running |

## Undo

```bash
deploys render autodeploy-on <service>       # or --all: auto-deploy "On Commit"
```

Or in the dashboard: Service → Settings → Build & Deploy → Auto-Deploy → On Commit. Remove the stored key with
`security delete-generic-password -s deploy-center-render`. More: [AUTO-DEPLOY.md](../AUTO-DEPLOY.md),
[TROUBLESHOOTING.md](../TROUBLESHOOTING.md#render).
