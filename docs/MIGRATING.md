# Moving from auto-deploy to deploying by hand

A checklist for a team or a person who has "every push deploys" today and wants "one deploy a day, on purpose". It takes an afternoon for a few projects. [SAFE-START.md](SAFE-START.md) is the short tour; this page is the plan around it. Nothing here starts a build unless a command says `--yes` or you click.

## 1. Find out what builds today

```bash
deploys doctor --text            # tools and logins, with the fix for each problem
deploys list                     # every project, and whether a push still deploys it
deploys triggers                 # builds nobody started from here, workflows that deploy, Blueprints
deploys simulate --days 30       # an estimate: a month of auto-deploy against one deploy a day
```

`deploys triggers` is the one that surprises people. These keep building after auto-deploy is off, because they do not use the Git connection:

- a GitHub Actions workflow that deploys (`vercel deploy`, a deploy hook `curl`, `render deploy`),
- a deploy hook someone pasted into a webhook (a CMS, a cron service),
- a Render Blueprint with auto-sync (add `autoDeployTrigger: off` to each service in `render.yaml`),
- pull request preview builds: on Vercel they stop with the Git connection; check whether your Render services have previews of their own.

Decide for each one: keep it, move it behind a click, or delete it.

## 2. Agree on the rule

Write down what "a deploy" means for the team before anyone turns anything off:

- **When**: one fixed time a day (`deploys schedule daily 17:30 --weekdays`), or by hand when someone needs a fix live. [SAFE-DEPLOY.md](SAFE-DEPLOY.md) covers deploy windows and freezes.
- **What**: only commits whose CI is green (`--when-green`), and which projects are never batched (`hold` rules, [CLI.md](CLI.md#rules)).
- **Who**: in team mode a shared `deploy-center.json` carries the same rules to every Mac, and observers can look but not deploy ([TEAM.md](TEAM.md)).

## 3. Turn it off, one project first

Follow [SAFE-START.md](SAFE-START.md): one project you can afford to have stale for a few minutes, a preview, then production, then push a commit and check that no build starts. Only then `--all`. Everything is written down so it can be undone: for Vercel the repo and branch go to `~/.config/deploys/vercel-repos.json` first ([AUTO-DEPLOY.md](AUTO-DEPLOY.md)).

## 4. Set up the daily deploy

```bash
deploys deploy-changed                       # shows what it would deploy
deploys deploy-changed --when-green --yes    # only green commits (waits for running checks)
deploys schedule daily 17:30 --weekdays --when-green
```

`deploys plan` prints the same list with an estimate of the cost. In the app: select the changed projects, check the commit messages in the confirmation, press **Deploy**.

## 5. Put the safety nets on

- `deploys deploy my-project && deploys verify my-project --path /health` asks the site after a deploy and rolls back when it answers 5xx ([SAFE-DEPLOY.md](SAFE-DEPLOY.md)).
- `deploys guard schedule on` turns auto-deploy off again within 30 minutes when someone switches it back on ([GUARD.md](GUARD.md)). For a few hours of auto-deploy on purpose: `deploys autodeploy allow vercel my-project 4`.
- `deploys journal verify` checks the journal of what was started and by whom ([JOURNAL.md](JOURNAL.md)).

## 6. After a week

`deploys ledger` shows an estimate of the builds skipped and the money saved since auto-deploy went off ([SAVINGS.md](SAVINGS.md)). If a project needs to deploy faster than once a day, deploy it by hand (`deploys deploy my-project`) or allow auto-deploy for it; you do not have to go all the way back.

## Going back

```bash
deploys vercel autodeploy-on --all     # connects Git again from the remembered repos
deploys render autodeploy-on --all     # auto-deploy "On Commit"
```

Keep `~/.config/deploys/vercel-repos.json` until every Vercel project is connected again. What the other hosts do: [providers/README.md](providers/README.md).
