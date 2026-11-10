# Glossary

Words used in the app, the CLI and these docs.

### Auto-deploy
The platform builds and deploys on every push to the repo. Deploy Center turns it off, so builds happen only when you start them.

### Git connection (Vercel)
The link between a Vercel project and its GitHub repo. It is what makes Vercel build on push. Deploy Center removes it to turn auto-deploy off and writes down the repo and branch in `~/.config/deploys/vercel-repos.json` first.

### Auto-Deploy setting (Render)
A per-service setting on Render: *On Commit*, *After CI Checks Pass*, or *Off*. Deploy Center sets it to *Off* (`autoDeployTrigger: off` in the API and in `render.yaml`).

### Production branch
The branch whose newest commit goes live, usually `main`. For Vercel it is saved as `ref` in `vercel-repos.json`. For Render it is the service's branch.

### Preview deployment
A Vercel deployment with its own URL that does not replace production. `deploys vercel deploy my-project --preview`, or **Preview** in the app's right-click menu.

### Rollback
Production goes back to the deploy that was live before the current one. Deploy Center skips an older deploy of the same commit, so a rollback really changes what is live.

### Ignored Build Step
A Vercel project setting (Settings → Git → Ignored Build Step) with a command that decides whether a build runs. If the command exits with 0, Vercel skips the build. In a monorepo, `git diff --quiet HEAD^ HEAD -- .` skips a build when nothing in the project's folder changed. The app then says "Skipped or canceled by Vercel (Ignored Build Step?)".

### Blueprint
Render's infrastructure as code: services described in a `render.yaml` in the repo. With **auto-sync** on, Render applies the file again on a push, which can turn auto-deploy back on. Add `autoDeployTrigger: off` to each service in the file.

### Deploy hook
A secret URL that starts a deploy when something calls it, for example a GitHub workflow. It works without auto-deploy, so it can keep building after auto-deploy is off. `deploys triggers` looks for workflows that call one.

### Build minutes
What Vercel and Render charge for building. Every push with auto-deploy on costs a build per connected project.

### Live commit
The commit of the deploy that is live now.

### Branch head
The newest commit of the production branch on GitHub. Read with the GitHub CLI (`gh`).

### Changed / New changes
A project whose live commit is not the branch head. See [NUMBERS.md](NUMBERS.md) for the exact rule.

### Commits waiting, PRs waiting
How many commits and merged pull requests are on the branch but not live. See [NUMBERS.md](NUMBERS.md).

### Daily deploy
Deploying everything with changes once a day: **Select all changed** and **Deploy** in the app, or `deploys deploy-changed --yes`.

### Start lock
A second start of the same project within a minute is refused, from the app and the CLI alike, so two quick clicks do not pay for two builds.

### Ignored project
A project left out of `changed` and `deploy-changed`: `deploys ignore my-project`, undone with `deploys ignore my-project --undo`.

### Hidden project
A row hidden in the app. Hidden projects are listed in Settings, where **Show** brings them back.

### Demo mode
Settings → Demo mode replaces project names and domains, for screenshots.

### GitHub budget
GitHub's hourly limit of API calls for your login. Under 300 left, Deploy Center reads only the branch heads. `deploys github-budget` shows what is left.
