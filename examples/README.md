# Examples

Deploy without a Mac: the `deploys` script is bash and also runs on Linux, for example in CI.
These examples have not been tested by the project yet; please report what you find in an issue.

| File | What it does |
|---|---|
| [daily-deploy.yml](daily-deploy.yml) | GitHub Actions: every weekday, deploy everything with commits that are not live (`deploys deploy-changed --yes`). Run by hand, it only shows the list. |
| [../docs/deploy-on-label.yml](../docs/deploy-on-label.yml) | GitHub Actions in your app's repo: a merged PR with the label `deploy` calls a Render deploy hook. |
| [../scripts/daily-deploy.plist.example](../scripts/daily-deploy.plist.example) | macOS LaunchAgent: the daily deploy on your own Mac at 18:00. |

## What `deploys` needs outside a Mac

- `bash`, `curl`, `jq`, and the Vercel CLI (`npm i -g vercel`, which needs Node). GitHub's Ubuntu runners have `jq`, `curl` and `gh`.
- `gh` logged in through `GH_TOKEN`. Without it no branch head is known, and nothing counts as changed.
- `VERCEL_TOKEN`: read by the Vercel CLI instead of `vercel login`.
- `RENDER_API_KEY`: takes the place of the macOS keychain.
- `DEPLOYS_CONFIG`: a folder with your `vercel-repos.json` (copied from `~/.config/deploys/`). Without it, Vercel projects have no remembered repo and cannot be deployed.
- `DEPLOYS_VERCEL_TEAM`: the team id, if the token sees several teams.

The commands that turn auto-deploy off are best run once from a Mac or a terminal, where you can watch them.
