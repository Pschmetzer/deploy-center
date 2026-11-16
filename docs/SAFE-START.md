# Try it safely

Three steps: look first, then change one project, then all of them. Each step can be undone ([AUTO-DEPLOY.md](AUTO-DEPLOY.md#back-to-auto-deploy)).

## 1. Only look

Opening the app changes nothing on Vercel, Render or GitHub. It reads your projects and shows which ones still deploy on every push. Nothing changes until you press **Turn off auto-deploy** or **Deploy** and confirm.

The same in Terminal. Every command here only reads:

```bash
deploys doctor            # what is connected
deploys vercel list       # AUTO (owner/repo) or manual, per project
deploys render list       # auto-deploy setting per service
deploys changed           # what is merged on GitHub and not live
deploys triggers          # builds in the last 24 h nobody started from here, workflows that deploy
deploys deploy-changed    # without --yes: only shows what it would deploy
```

`deploys triggers` matters most. A GitHub workflow or a deploy hook that deploys by itself keeps building after auto-deploy is off.

## 2. One project

Pick a project you can afford to have down for a few minutes.

**Vercel**

```bash
deploys vercel autodeploy-off my-project         # removes the Git connection, remembers the repo
deploys vercel deploy my-project --preview       # a preview first, not production
deploys vercel deploy my-project                 # then production
deploys watch my-project                         # until it is live or failed
```

**Render**

```bash
deploys render autodeploy-off my-service         # sets auto-deploy to Off
deploys render deploy my-service
deploys watch my-service
```

In the app: right-click the row for **Preview** and **Roll back**. If something is wrong, `deploys vercel rollback my-project` or `deploys render rollback my-service` puts the deploy that was live before back.

Push a commit to the project's repo and check that no build starts. With the GitHub CLI logged in, `deploys changed` then lists the project as waiting.

## 3. All projects

```bash
deploys vercel autodeploy-off --all
deploys render autodeploy-off --all
```

Or press **Turn off auto-deploy** in the app. It lists every affected project before you confirm.

From then on, one daily deploy is enough. In the app: **Select all changed**, then **Deploy**. In Terminal: `deploys deploy-changed --yes`.

## Without the app (CLI only)

The same order works in a terminal, and nothing changes until you say so:

```bash
deploys status                          # what is connected, what is waiting; changes nothing
deploys list                            # your projects and whether auto-deploy is on; changes nothing
deploys deploy-changed                  # a list of what would deploy; it only deploys with --yes
```

Then turn off one project (`deploys vercel autodeploy-off my-project`), push a commit and check that no build starts,
and only then use `--all`. Back out with `deploys vercel autodeploy-on my-project`.
