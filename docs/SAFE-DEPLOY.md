# Safe deploys

When AI agents push 30–50 times a day, you don't want every push to go live. Deploy Center can
batch those pushes into one deploy, and four checks keep that deploy safe:

1. **Green CI**: only commits whose checks passed go live.
2. **Health check with rollback**: if the site is broken after the deploy, production goes back.
3. **Deploy window**: no deploys at times you choose (Friday afternoon, holidays), unless you give a reason.
4. **Risk light**: a red dot when the waiting diff has migrations, a very large diff, or similar.

All four work in the terminal (`deploys …`) and in the app.

## 1. Deploy when CI is green

```bash
deploys deploy-changed --when-green --yes
```

For each project with changes, the CLI reads the head commit's combined status and check runs
through `gh api`:

| CI | What happens |
| --- | --- |
| green (everything passed, skipped or neutral) | deployed, at exactly that commit |
| no checks at all | deployed, since there is nothing to wait for |
| pending (anything still queued or running) | asked again after 10 s, 20 s, 40 s … (at most 2 minutes apart), up to `--wait` (default `30m`) |
| red (a failure, timeout, cancel, action required) | skipped, with the checks that failed |
| GitHub not reachable | treated like pending; skipped once `--wait` runs out |

All projects are checked in rounds, so one slow CI does not hold up the others. A project starts
as soon as its own commit is green. The checked commit is what deploys (`--sha`), so a push that
lands during the wait goes out in the next run, not unchecked in this one.

```bash
deploys deploy-changed --when-green --wait 45m --yes --json
```

This gives one record per project: `{"platform","name","action":"started|skipped|failed","reason","id","url"}`.
Without `--yes` it shows only what it would deploy.

For a single commit:

```bash
deploys ci owner/repo <sha-or-branch> [--wait 10m] [--json]
```

The exit code is 0 for green or no checks, 1 for red, and 2 when checks are still pending or
GitHub is not reachable. With `--json` the exit code is always 0 and the verdict is in the answer.

**In the app**, the deploy confirmation has a checkbox, **Only when checks are green**, which is
remembered. While a row waits, it says "waiting for checks". A red CI skips the row and shows the
reason. **Settings → Deploy → Deploy only when the checks are green** is the same switch.

## 2. Health check with auto-rollback

```bash
deploys verify <project> [--path /health] [--rollback-after 10] [--no-rollback] [--url https://…] [--json]
```

1. Waits until the newest production deploy is live (as `deploys watch` does). If the deploy failed, there is nothing to check.
2. Requests the site, plus `--path` if given, 3 times, 5 s apart.
3. The check fails only when **all three** answers are 5xx or nothing at all (a timeout or no
   connection). A fresh Render service can answer 502 for a few seconds. Redirects are followed.
   Without `--path` a 4xx is not a failure: it usually means a protected page, and rolling back
   would not fix that. With `--path` the address must exist: a 4xx there (a missing `/health`)
   counts as a failure too.
4. On failure it counts down (`Rolling back web in 10 s – Ctrl-C to stop`), then runs
   `deploys vercel|render rollback`. Ctrl-C stops the rollback. `--no-rollback` only reports.

| Exit | Meaning |
| --- | --- |
| 0 | healthy |
| 1 | the check failed and production was rolled back |
| 2 | the check failed and nothing was rolled back (`--no-rollback`, Ctrl-C, or the rollback failed) |
| 3 | nothing was checked: unknown project, the newest deploy is not live, no address, a wrong option |

The rollback, or the stopped rollback, goes to the journal.

Example, after a deploy from a script:

```bash
deploys deploy web && deploys verify web --path /api/health
```

**In the app**, open a project's details and tick **Roll back if the check fails**. This is set
per project and kept on this Mac. The app already checks the site after going live, using the
"page to check after deploy" path. With this box ticked, a 5xx or no answer starts a 10-second
countdown, shown as a notification (even while the app is in front) and as a line in the window,
both with **Cancel**. When the countdown ends, production rolls back to the deploy before.
A 404 does not start a rollback, and neither does the check after a rollback.

**Settings → Deploy → Watch the site after going live** keeps asking for a few minutes (every
minute) instead of once. Two failed answers in a row warn, or roll back where the project rolls back
by itself. When the site answers slower than before the deploy, the app says so. The details show
the uptime from these checks (30 days, this Mac only), and once a day the app warns when the site's
certificate ends within two weeks. The paths to ask are in the row menu: **Pages to check after
deploy …**.

## 3. Deploy window / freeze

`~/.config/deploys/window.json` (or `$DEPLOYS_CONFIG/window.json`):

```json
{
  "deny": [
    { "days": ["fri"], "from": "15:00" },
    { "days": ["sat", "sun"] },
    { "from": "22:00", "to": "06:00", "reason": "nobody is awake to fix it" },
    { "dates": ["2026-12-24", "2026-12-31"] }
  ]
}
```

- `days`: `mon` … `sun`. Leave it out for every day.
- `dates`: `YYYY-MM-DD`.
- `from` / `to`: local time, `HH:MM`. They default to `00:00` and `24:00`. If `from` is later than `to`, the rule runs over midnight.
- `reason`: the text shown. Without it the rule is described, e.g. `fri 15:00–24:00`.

Inside a denied window, these commands refuse to start production deploys:

- `deploys deploy`
- `deploys deploy-changed --yes`
- `deploys vercel deploy`
- `deploys render deploy`
- `deploy-json`, which the app uses

To deploy anyway, give a reason:

```bash
deploys deploy-changed --yes --force "hotfix for the login page"
```

Every project started this way gets a `forced` entry in the deploy history (the app's journal),
with the window and the reason. These still go out inside a window:

- previews (`--preview`)
- rollbacks
- `verify` (a rollback is a fix)

Autofix never deploys (see [AUTOFIX.md](AUTOFIX.md)). The fix you deploy after merging it goes through the window like any other deploy.

```bash
deploys window          # Open / Closed, and which rule
deploys window --json   # {"denied":true,"reason":"fri 15:00–24:00",…}
```

`deploys window` exits 1 while the window is closed. With `--json` it always exits 0.

**In the app**, Deploy in the confirmation asks first if the window is closed: "The deploy window
is closed". Click **Deploy anyway…**, then give the reason, which goes to the deploy history.
**Settings → Deploy → Deploy window** edits the same `window.json`: add a time (days, from, to,
over midnight too), **Save**. Keys the editor does not know are kept.

## 4. Risk light

```bash
deploys risk <project> [--json]
```

This scores the diff between what is live and the branch (from GitHub's comparison, at most 300
files):

| Found | Level |
| --- | --- |
| migrations: `migrations/`, `migrate/`, `prisma/`, `*.sql`, `schema.prisma`, `schema.rb` | red |
| lockfiles: `package-lock.json`, `pnpm-lock.yaml`, `yarn.lock`, `bun.lock`, `poetry.lock`, `uv.lock`, `Pipfile.lock`, `Gemfile.lock`, `Cargo.lock`, `go.sum`, `composer.lock` | yellow |
| `.env` and `.env.*` | yellow |
| config: `vercel.json`, `render.yaml`, `Dockerfile`, `docker-compose.yml`, `Procfile`, `next/vite/nuxt/astro/svelte/remix.config.*`, `.github/workflows/` | yellow |
| more than 500 changed lines or 30 files | yellow |
| more than 3000 changed lines or at least 100 files | red |

The worst finding sets the level.

```json
{"project":"web","platform":"vercel","level":"red","files":2,"lines":20,
 "reasons":[{"kind":"migrations","level":"red","files":["prisma/migrations/2/migration.sql"],"text":"database migrations: …"},
            {"kind":"lockfile","level":"yellow","files":["package-lock.json"],"text":"dependencies changed: …"}]}
```

The same score is part of `deploys changed --json` and of the lists the app reads (`risk`). It is
computed from the comparison already read for the commit count, so it costs no extra GitHub call.
`deploy-changed` without `--yes` names a red risk next to the project.

**In the app**, a row shows a red dot only when the risk is red. Yellow stays quiet. The details
show the level and every reason.

## 5. More brakes in the app

All opt-in, in **Settings → Deploy** unless the row menu is named:

- **Ask for a tick before database migrations go live:** when the waiting commits change migration
  files, every live deploy of them asks first.
- **Ask for Touch ID or the password before risky steps:** deploying several projects at once, a
  rollback by hand, and allowing auto-deploy. The automatic rollback after a failed check does not
  wait for it.
- **Critical projects** (row menu → **Critical: type the name to go live**): going live asks for the
  project's name.
- **A budget per project** (row menu → **Monthly budget …**): USD a month for its builds; a warning
  comes at 80 % of it, at the week's pace. The monthly budget for all projects is in Settings → Costs.
- **Rules** (Settings → Deploy → Rules): the editor for `rules.json`, "when … then deploy, hold or
  notify" (see [CLI.md](CLI.md#rules)). The app only edits the file; `deploys deploy-changed
  --by-rules` applies it.

## Tests

`tests/script-tests.sh` covers all four with stand-ins for `gh`, `curl` and `vercel`, so no
network is used:

- CI that is green, red, slow, never done, or has no checks
- the window rules, including over midnight
- `--force` and the journal
- verify: healthy, flaky, 5xx, timeout, `--no-rollback`, and Ctrl-C in the countdown
- the risk rules

`DEPLOYS_NOW="fri 16:00 2026-11-13"` sets the time the window rules read. `DEPLOYS_JOURNAL`
sets where journal lines go.
