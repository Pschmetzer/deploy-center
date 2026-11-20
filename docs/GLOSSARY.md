# Glossary

Words used in the app, the CLI and these docs.

## Auto-deploy
The platform builds and deploys on every push to the repo. Deploy Center turns it off, so builds happen only when you start them.

## Git connection (Vercel)
The link between a Vercel project and its GitHub repo. It is what makes Vercel build on push. Deploy Center removes it to turn auto-deploy off and writes down the repo and branch in `~/.config/deploys/vercel-repos.json` first.

## Auto-Deploy setting (Render)
A per-service setting on Render: *On Commit*, *After CI Checks Pass*, or *Off*. Deploy Center sets it to *Off* (`autoDeployTrigger: off` in the API and in `render.yaml`).

## Production branch
The branch whose newest commit goes live, usually `main`. For Vercel it is saved as `ref` in `vercel-repos.json`. For Render it is the service's branch.

## Preview deployment
A Vercel deployment with its own URL that does not replace production. `deploys vercel deploy my-project --preview`, or **Preview** in the app's right-click menu.

## Rollback
Production goes back to the deploy that was live before the current one. Deploy Center skips an older deploy of the same commit, so a rollback really changes what is live.

## Ignored Build Step
A Vercel project setting (Settings → Git → Ignored Build Step) with a command that decides whether a build runs. If the command exits with 0, Vercel skips the build. In a monorepo, `git diff --quiet HEAD^ HEAD -- .` skips a build when nothing in the project's folder changed. The app then says "Skipped or canceled by Vercel (Ignored Build Step?)".

## Blueprint
Render's infrastructure as code: services described in a `render.yaml` in the repo. With **auto-sync** on, Render applies the file again on a push, which can turn auto-deploy back on. Add `autoDeployTrigger: off` to each service in the file.

## Deploy hook
A secret URL that starts a deploy when something calls it, for example a GitHub workflow. It works without auto-deploy, so it can keep building after auto-deploy is off. `deploys triggers` looks for workflows that call one.

## Stop builds (Netlify)
Netlify's `build_settings.stop_builds`. It stops builds on a push, but also from the API and from build hooks, so Deploy Center does not use it. It turns pushes off with an ignore command in `netlify.toml` and deploys through a build hook instead: [providers/netlify.md](providers/netlify.md).

## Branch control (Cloudflare Pages)
The project's Git switches for **production deployments** and **preview deployments**. `deploys cloudflare off` turns both off and remembers what they were: [providers/cloudflare.md](providers/cloudflare.md).

## Auto-build (AWS Amplify)
Amplify builds every connected branch with auto-build on, on each push. Deploy Center turns it off per branch and starts a job when you deploy: [providers/amplify.md](providers/amplify.md).

## Deploy on push (DigitalOcean), auto-deploy (Coolify)
The per-component `deploy_on_push` on DigitalOcean App Platform, and an application's `is_auto_deploy_enabled` on Coolify. `autodeploy-off` sets them to false: [providers/digitalocean.md](providers/digitalocean.md), [providers/coolify.md](providers/coolify.md).

## Merge request (GitLab)
GitLab's name for a pull request. For a repo on GitLab, "PRs waiting" counts merge requests: [GITLAB.md](GITLAB.md).

## Build minutes
What Vercel and Render charge for building. Every push with auto-deploy on costs a build per connected project.

## Live commit
The commit of the deploy that is live now.

## Branch head
The newest commit of the production branch on GitHub. Read with the GitHub CLI (`gh`).

## Changed / New changes
A project whose live commit is not the branch head. See [NUMBERS.md](NUMBERS.md) for the exact rule.

## Commits waiting, PRs waiting
How many commits and merged pull requests are on the branch but not live. See [NUMBERS.md](NUMBERS.md).

## Daily deploy
Deploying everything with changes once a day: **Select all changed** and **Deploy** in the app, or `deploys deploy-changed --yes`.

## Start lock
A second start of the same project within a minute is refused, from the app and the CLI alike, so two quick clicks do not pay for two builds.

## Ignored project
A project left out of `changed` and `deploy-changed`: `deploys ignore my-project`, undone with `deploys ignore my-project --undo`.

## Hidden project
A row hidden in the app. Hidden projects are listed in Settings → General, where **Show** brings them back.

## Repo group
Projects that share one GitHub repo, shown under one header in the list. The header folds (the state is remembered) and counts failed projects. See [SEARCH.md](SEARCH.md#repo-groups).

## Saved search
A search such as `is:failed host:render` that you keep with the bookmark button next to the search field. It is only text on this Mac; running it changes nothing. See [SEARCH.md](SEARCH.md#saved-searches).

## Merged fix
An [Autofix](AUTOFIX.md) pull request that was merged but is not live yet. Its row stands out, and **More → Tick the N merged fixes** ticks them all. Deploying still needs a click.

## Demo mode
Settings → General → Demo mode replaces project names and domains, for screenshots.

## GitHub budget
GitHub's hourly limit of API calls for your login. Under 300 left, Deploy Center reads only the branch heads. `deploys github-budget` shows what is left.

## Deploy window
A rule that says when deploys are closed (for example Friday afternoon). `deploys window` shows whether it is open and exits 1 while it is closed; `--force "why"` goes through and the reason is written to the journal. See [SAFE-DEPLOY.md](SAFE-DEPLOY.md).

## Verify (health check)
`deploys verify <project>` asks the live site after a deploy and rolls back on a 5xx answer, unless you pass `--no-rollback`.

## Observer mode
A mode in which `deploys` only reads: commands that change something are refused. It is turned on with `deploys readonly on`, `DEPLOYS_READONLY`, or an observers list in the shared `deploy-center.json`. See [TEAM.md](TEAM.md).

## Two-person rule
An optional team rule: a live deploy needs an approval from someone else, kept in the repo's shared `deploy-center.json`, without a server. See [TEAM.md](TEAM.md).

## Autofix routine
A Claude Code routine you set up once. When a build fails, `deploys autofix` sends it the masked build log and the routine opens a fix pull request. It never merges and never deploys. See [AUTOFIX.md](AUTOFIX.md).

## Guard
`deploys guard` notices when auto-deploy has come back on by itself and turns it off again; it can also allow auto-deploy for a few hours on purpose. See [GUARD.md](GUARD.md).

## MCP server
The `deploys` server that lets an AI agent in Claude Code, Cursor or Codex read what is waiting and, after your confirmation, deploy. See [integrations/mcp](../integrations/mcp/).

## Simulate and ledger
`deploys simulate` estimates what auto-deploy would cost a month before you switch it off; `deploys ledger` estimates what turning it off saved. Both are marked as estimates. See [SAVINGS.md](SAVINGS.md).

## Freeze
A closed time in the deploy window, such as Friday from 15:00 or the days around a holiday. `deploys freeze add fri 15:00 --reason "…"` writes it into `window.json`; `deploys freeze` lists the closed times. See [SAFE-DEPLOY.md](SAFE-DEPLOY.md) and [examples/config/](../examples/config/).

## Forced start
A start inside a closed window or over the budget, made on purpose with `--force "why"`. The reason and the window or budget it went past are written to the journal as a `forced` entry.

## Hook (`hooks.d`)
An executable file named `pre-deploy*` or `post-deploy*` in the config folder's `hooks.d`. It runs around every start from the terminal, `deploy-changed` and the scheduled job. A `pre-deploy` hook that exits non-zero stops that start; a `post-deploy` hook cannot. Not the Git `pre-push` hook of `deploys hooks install`. See [CLI.md](CLI.md#hooks-scripts-around-a-start-hooksd).

## Budget brake
`budget.json` (`deploys budget set 50`): the dollars a month of Vercel build charges that `deploy-changed --yes` may not go over without `--force "why"`. With `strict` it also stops when the charges cannot be read.

## Rule (`rules.json`)
A "when … then …" line for the daily deploy: `when` names conditions (projects, changed paths, CI green, labels, age, number of commits or PRs), `then` is `deploy`, `hold` or `notify`. The first enabled rule that matches a project decides. `deploys rules check` shows why a rule did or did not match. See [CLI.md](CLI.md#rules).

## Config folder
Where Deploy Center keeps its files on a Mac or in CI: `~/.config/deploys`, or the folder `DEPLOYS_CONFIG` names. `window.json`, `rules.json`, `budget.json`, `ignored.json` and `hooks.d` live here. `deploys where` prints it.

## Shared config (`deploy-center.json`)
A file at the root of a repo (or `.deploy-center.json`) that gives every teammate's Mac the same projects, groups, windows and approvals, without a server. This Mac's own files are merged on top. See [TEAM.md](TEAM.md).

## Deploy group
Projects deployed together, in order: `deploys deploy <group>` starts each one once the one before is live (backend before frontend). Defined under `groups` in `deploy-center.json`; with `checks` it runs each member's health checks and with `stopOnFail` stops the rest after a failure.
