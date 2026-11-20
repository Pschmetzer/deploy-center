# Examples

Deploy without a Mac: the `deploys` script is bash and also runs on Linux, for example in CI.
What is tested: the scripts these workflows call (`deploys`, the action's steps) run in this
repo's tests with a stand-in CLI. What is not: a run of these workflows on GitHub against real
accounts. Run each one by hand once and read the log; please report what you find in an issue.

| File | What it does |
|---|---|
| [daily-deploy.yml](daily-deploy.yml) | GitHub Actions: every weekday, deploy everything with commits that are not live (`deploys deploy-changed --yes`). Run by hand, it only shows the list. It downloads the CLI tarball of a pinned release and checks it against `checksums.txt`. |
| [dependency-updates-weekly.yml](dependency-updates-weekly.yml) + [bot-only.sh](bot-only.sh) | GitHub Actions: projects that wait only for bot commits (Dependabot, Renovate) go live every Monday. Add `examples/bot-only.sh --hold` as a step before the deploy in `daily-deploy.yml`, and the daily run leaves them out. A project with any human commit still ships daily. |
| [telegram-waiting-bot.sh](telegram-waiting-bot.sh) | A read-only Telegram bot: `/waiting` and `/failed` in the chats you list (`DEPLOYS_BOT_CHATS`). Long polling, no webhook or open port; it has no command that deploys. |
| [plan-pr-comment.yml](plan-pr-comment.yml) + [plan-comment.sh](plan-comment.sh) | GitHub Actions in your app's repo: when a PR is merged, it comments what the next deploy would start and what it would cost (`deploys plan --json`, an estimate), and updates that comment on later merges. Read-only. `plan-comment.sh` turns the plan JSON into Markdown and escapes project names. |
| [claude-pr-ship-check.yml](claude-pr-ship-check.yml) | GitHub Actions in your app's repo: on each PR, Claude comments "What this ships" (projects affected, risk, auto-deploy off). See [docs/CLAUDE-IN-APP.md](../docs/CLAUDE-IN-APP.md). |
| [../docs/deploy-on-label.yml](../docs/deploy-on-label.yml) | GitHub Actions in your app's repo: a merged PR with the label `deploy` calls a Render deploy hook. |
| [../scripts/daily-deploy.plist.example](../scripts/daily-deploy.plist.example) | macOS LaunchAgent: the daily deploy on your own Mac at 18:00. |

## What `deploys` needs outside a Mac

- The CLI tarball of a release (`deploys`, `VERSION`, `providers/`), not the `deploys` file alone; see [integrations/VERIFY.md](../integrations/VERIFY.md).
- `bash`, `curl`, `jq`, and the Vercel CLI (`npm i -g vercel@<version>`, which needs Node). GitHub's Ubuntu runners have `jq`, `curl` and `gh`.
- `gh` logged in through `GH_TOKEN`. Without it no branch head is known, and nothing counts as changed.
- `VERCEL_TOKEN`: read by the Vercel CLI instead of `vercel login`.
- `RENDER_API_KEY`: takes the place of the macOS keychain.
- `DEPLOYS_CONFIG`: a folder with your `vercel-repos.json` (copied from `~/.config/deploys/`). Without it, Vercel projects have no remembered repo and cannot be deployed.
- `DEPLOYS_VERCEL_TEAM`: the team id, if the token sees several teams.

**Scheduled workflows stop after 60 days.** GitHub switches a `schedule:` workflow off when the repo has had no activity for 60 days, and a private "ops" repo that nobody pushes to is exactly that: the daily deploy then stops without an error. Look at the Actions tab now and then, or keep it alive with a small workflow of your own that runs `gh workflow enable daily-deploy.yml` every few weeks (a token that may manage workflows is needed; the workflow's own `GITHUB_TOKEN` cannot). The daily example ends with a step that POSTs to `NOTIFY_URL` (a secret; ntfy or a Slack webhook) when a run fails, so a failed deploy is not only a line in the Actions log.

The commands that turn auto-deploy off are best run once from a Mac or a terminal, where you can watch them.
