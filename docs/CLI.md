# Command line: `deploys`

The app is a window over one bash script, `deploys`. You can use it on its own. It is inside the
app at `Deploy Center.app/Contents/Resources/deploys`, and `./deploys` in this repo.
`deploys` without arguments prints the full help.

## Everyday commands

```bash
deploys doctor                          # what is connected
deploys changed                         # what is merged on GitHub and not live: commits and PRs per project
deploys deploy-changed                  # the daily deploy: shows the list; add --yes to start it
deploys plan [--when-green]             # the same list with an estimate per build and the sum (starts nothing)
deploys status                          # what is building now, and what failed last
deploys watch my-project                # follow the newest deploy until live or failed
deploys logs my-project                 # the end of the newest build log
deploys open my-project [--dashboard]   # the site, or its page at Vercel/Render
deploys ignore my-project               # leave it out of changed / deploy-changed
```

## Vercel

```bash
deploys vercel list                     # which projects still deploy on push
deploys vercel autodeploy-off --all     # or one project by name
deploys vercel autodeploy-on my-project # connect Git again (or --all)
deploys vercel deploy my-project        # newest commit to production
deploys vercel deploy my-project --preview
deploys vercel rollback my-project
deploys vercel map my-project me/my-repo main   # where a project deploys from, set by hand
deploys vercel team [<id>]              # show or set the Vercel team
```

## Render

```bash
deploys render list
deploys render autodeploy-off --all     # or one service by name
deploys render autodeploy-on my-service # auto-deploy "On Commit" again (or --all)
deploys render deploy my-service
deploys render rollback my-service
deploys render set-key                  # store the API key in the keychain (reads stdin)
deploys render forget-key
```

## More

```bash
deploys explain my-project              # why a project is (not) counted as changed
deploys diff my-project                 # commits and files between what is live and the branch
deploys notes my-project                # the same as release notes (Markdown)
deploys history my-project [n]          # the last n deploys
deploys costs [days]                    # Vercel charges per day
deploys simulate [--days 30]            # estimate: auto-deploy a month vs. once a day, see SAVINGS.md
deploys ledger                          # estimate: builds and money saved since auto-deploy was off
deploys price set vercel 0.008          # your price of one build minute, where no billing says it (prices.json)
deploys budget set 50 [--strict]        # deploy-changed --yes stops before going over $50 a month
deploys triggers                        # builds nobody started from here, deploying workflows, Blueprints
deploys where                           # config folder, version, key source, logins
deploys autofix [--dry-run]             # see AUTOFIX.md
deploys autofix --only vercel my-project  # this one failure now
deploys autodeploy allow vercel my-project 4   # auto-deploy on for 4 hours (see GUARD.md)
deploys autodeploy allowed | revoke vercel my-project
deploys guard [--dry-run] | status | schedule on|off   # auto-deploy off where it came back on
deploys ai explain|notes|ship my-project   # ask Claude with your own key, see CLAUDE.md
deploys ai ask my-project --question "will this run a migration?"   # your own question; its commits and log go along
deploys ai slow my-project              # why its builds take long (ai risk = ai ship)
deploys autofix --preview --only vercel my-project --json   # what a hand-over would send; sends nothing
deploys team init me/my-repo > deploy-center.json   # a shared config from this Mac's settings (writes nothing itself)
deploys schedule daily 09:00 [--when-green] [--by-rules]   # deploy-changed --yes once a day (launchd, or the cron line)
deploys schedule off | status [--json]
deploys hooks install [<repo>]          # before each push: which builds it would start (integrations/hooks)
deploys hooks uninstall | status [<repo>]
eval "$(deploys completion zsh)"        # tab completion (also: bash; fish: deploys completion fish | source)
deploys deploy --help                   # the help lines of one command
```

Add `--json` to any command for the machine answer. A name may be written `<provider>:<name>`
(`vercel:web`) wherever a project is asked for.

## Exit codes

`0` done (also "nothing to deploy"). `1` an error, something failed to start, or the state of some
project could not be read (it is named and left out, never counted as current). Per command:

| Command | Codes |
| --- | --- |
| `watch` | `0` live, `1` failed or canceled, `3` the platform could not be asked (or its answer read) five times in a row, `4` still running after `--timeout` |
| `verify` | `0` healthy, `1` failed and rolled back, `2` failed and not rolled back |
| `ci` | `0` green or no checks, `1` red, `2` still pending or GitHub not reachable (`--json`: always `0`) |
| `window` | `0` open, `1` closed (`--json`: always `0`) |
| `deploy-changed --strict` | also `2` when a project was skipped (red or pending CI) |
| `autofix --only` | `2` not failed, `3` handed over already or busy, `4` a cap, `5` no routine, `6` locked |
| `deploy-changed --yes` with a budget | `1` over budget (or, with `--strict`, spending unknown) without `--force "why"` |
| `deploy --wait`, groups | `3` the platform accepted the start but named no deploy id, so it was not followed (a group stops there) |

## Environment variables

| Variable | What |
| --- | --- |
| `DEPLOYS_CONFIG` | the config folder (default `~/.config/deploys`) |
| `DEPLOYS_DIR` | where `providers/` (and, without one next to the script, `lib/`) are |
| `DEPLOYS_READONLY` | observer mode: any value but `0`, `false`, `no`, `off` turns it on |
| `DEPLOYS_NO_GITHUB` | ask no git host (as `status --no-github`) |
| `DEPLOYS_JOURNAL` | the deploy journal file (default: the app's, on Linux in the config folder) |
| `DEPLOYS_NOTIFY` | `0`: no macOS notifications from autofix and guard |
| `DEPLOYS_TEAM_TTL` | seconds a shared `deploy-center.json` is cached (default 600) |
| `DEPLOYS_AUTOFIX_PER_DAY`, `DEPLOYS_AUTOFIX_PER_PROJECT` | autofix caps per 24 h (default 6 and 2) |
| `DEPLOYS_GITLAB_HOSTS` | self-managed GitLab hosts (docs/GITLAB.md) |
| `DEPLOYS_ANTHROPIC_API_KEY` | the key for `deploys ai`, before `ANTHROPIC_API_KEY` and the keychain |
| `DEPLOYS_VERCEL_USD_PER_MIN`, `DEPLOYS_RENDER_USD_PER_MIN` | build-minute prices for `simulate` and `ledger` |
| `DEPLOYS_TIMEOUT` | seconds one `gh` or `glab` call may take (default 120, `0` = no limit; needs perl) |
| `DEPLOYS_LOG_MAX_BYTES` | size past which a launchd job log is renamed to `.1` (default 1 MB) |
| `NO_COLOR` | no colour |

**Budget brake.** `budget.json` (`deploys budget set 50`) holds dollars a month of Vercel build
charges. Before `deploy-changed --yes` starts anything it adds this month's charges up to yesterday
(`deploys costs`) and the plan's estimate for the run; over the budget it stops unless
`--force "why"`, and the reason goes to the journal. When the charges cannot be read (no Vercel,
billing down) it warns and goes ahead; with `--strict` it stops instead. Render has no billing API
and is not in the sum. `deploys costs --json` names days it could not read (`missingDays`) and
sums per month (`months`).

`DEPLOYS_NOW` (the time the window rules read) counts only with `DEPLOYS_TESTING=1`: it is for tests.

`deploys hooks install` puts a small `pre-push` into the repo's hooks folder (git's own, or
`core.hooksPath`). A `pre-push` that was there is kept as `pre-push.local` and runs first; its
"no" still stops the push. `deploys hooks uninstall` puts it back. With Husky it prints the line
to add to `.husky/pre-push` instead. The check itself reads GitHub remotes only.

`window.json` may name a time zone: `{"tz":"Europe/Berlin","deny":[…]}`. `deploys window` warns
about keys and times it does not understand. A rule over midnight (`"from":"22:00","to":"06:00"`)
belongs to the day it starts.

## Rules

`rules.json` in the config folder (the app's rule editor writes it) says "when … then …" for the
daily deploy:

```json
{"rules":[{"name":"docs ship by themselves","enabled":true,
           "when":{"projects":["vercel/*"],"paths":["docs/**","*.md"],"onlyPaths":true,"ciGreen":true},
           "then":"deploy"},
          {"name":"api waits a day","when":{"projects":["render/api"],"minAgeHours":24},"then":"hold"}]}
```

Every condition given must hold. `projects` are `<platform>/<name>` (`*` matches any part).
`paths` are globs (`**` any folders, `*` within one; without `/` the file name anywhere);
`onlyPaths: true` means every changed file matches, otherwise one is enough (GitHub only, up to
300 files). `labels`: a pull request of the head commit has one. `minAgeHours`: the oldest
waiting commit is that old. `ciGreen`: CI of the head is green or has no checks.

The first enabled rule that matches a project decides: `hold` leaves it out of `deploy-changed`
and `plan` (named, counted as skipped); `deploy` is what `deploy-changed --by-rules` starts (the
deploy window and the budget still count); `notify` only shows in `rules check`. A `deploy` rule
without a condition is ignored. `deploys rules check [--json]` shows each rule against each
waiting project: `[{rule, index, project, matched, action, unmet}]`.

## New JSON fields

- `deploys details <owner/repo> <live sha> [<branch>]`: `secrets` (`[{file, line, kind}]`, lines
  added in the diff that look like a key or a password assignment; the value is never printed),
  `lockfiles` (`[{file, additions, deletions}]`), `unverified` (commits without a verified
  signature) and per commit `verified` / `verification`.
- `deploys autofix status --json`: `summary` `{handedOver, opened, merged, redeployed}`.
- `deploys costs --json`: `missingDays`, `months`.
- `deploys doctor`: `githubRateLimit` `{remaining, limit, resetAt}` (null without a GitHub login).
- The journal: lines the CLI writes carry `prevHash`, the SHA-256 of the line before.
- `deploys schedule status --json`: `{at, args, scheduled, pathMissing}`.
- `deploys autofix --preview --only <platform> <project> --json`: `{project, platform, repo, deployId,
  sha, routine, prompt, payload, masked_log, class, reason}`. The routine id only, never its token;
  nothing is sent or recorded. Without perl (no masking) it stops.
- `deploys autofix status --json`: per fire `class` (`env`, `auth`, `quota`, `outage`, `dependency`,
  `code`, `unknown`) and `reason` (the masked log line that says so); `null` for older fires.
- `deploys triggers --json`: build entries carry `minutes` and `usd` (minutes × your price per minute
  from `deploys price`; `null` when either is unknown).
- `deploys team add` takes `https://github.com/owner/repo(.git)` and `git@github.com:owner/repo.git` too.
- `deploys verify <p> --json`: `checks` `[{url, codes, healthy}]`, one per check asked. `url` and
  `codes` stay those of the first failing check (else the first).

## Checks, groups and observers in deploy-center.json

- `projects.<name>.checks`: `["/health", {"path": "/api/ping", "expect": "2xx"}]`. Without `--path`,
  `deploys verify` asks each of them (three times, as before); one failing fails the check. Only
  HTTP paths: a shared file never names a command that runs on your Mac.
- `groups.<name>` may be `{"order": ["api", "web"], "checks": true, "stopOnFail": true}`. With
  `checks`, `deploys deploy <group>` runs `deploys verify <member> --no-rollback` once each member
  is live (the last one too); with `stopOnFail` a failed check stops the rest of the group. A
  group as a plain list works as before.
- `observers` may hold `{"login": "a-login", "until": "2026-12-31"}`: an observer until that day
  ends (UTC); a full ISO time counts to the second. A date that cannot be read keeps the observer.

## On a server or in CI

- `RENDER_API_KEY` takes the place of the keychain.
- `VERCEL_TOKEN` is read by the Vercel CLI instead of `vercel login`.
- `GH_TOKEN` for `gh`. Without it no branch head is known, and nothing counts as changed.
- `DEPLOYS_CONFIG`: a folder with your `vercel-repos.json`.
- `DEPLOYS_VERCEL_TEAM`: the team id, if the token sees several teams.
- `DEPLOYS_VERCEL_USD_PER_MIN`, `DEPLOYS_RENDER_USD_PER_MIN`: the price of one build minute for `simulate` and `ledger`, where no billing says it. See [SAVINGS.md](SAVINGS.md).

See [examples/](../examples/) for a daily deploy from GitHub Actions.

## Settings

Settings live in `~/.config/deploys/` (or `$DEPLOYS_CONFIG`):

- `vercel-repos.json`: which repo and branch each Vercel project deploys from. Written when
  auto-deploy is turned off. Keep it: it is the only record of where a disconnected project came from.
- `vercel-team`: the team id, detected automatically (empty for a personal account).
