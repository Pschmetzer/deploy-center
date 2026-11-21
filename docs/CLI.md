# Command line: `deploys`

The app is a window over one bash script, `deploys`. You can use it on its own. It is inside the
app at `Deploy Center.app/Contents/Resources/deploys`, and `./deploys` in this repo.
`deploys --help` prints every command, and at its end the commands of each provider that is on.
There is a manual page too: `man deploys` after a Homebrew or `install.sh` install, `man man/deploys.1` in a checkout (written by `scripts/build-man.py` from this help and the table below).
A mistyped command gets one line with the nearest ones (`Unknown command "chaged". Did you mean: changed?`).

A project is named the same way everywhere: by its name, or as `<platform>:<name>` when two
platforms have one of that name (`render:api`). Names that would change an API path (`/ ? # & %`)
are refused before anything is asked; only Amplify ids have one `/` (`amplify:<appId>/<branch>`).

## Everyday commands

```bash
deploys doctor                          # what is connected (JSON)
deploys certs [--days 14] [--json]      # TLS certificate of every project's address (also the platform's own domain); exit 1 when one runs out within N days. A host that cannot be reached is "unknown", not a failure.
deploys creds [--max-age 90] [--json]   # per platform: where its key comes from (environment, keychain, login), if it works, how old a keychain key is. Reads only; never shows a key.
deploys doctor --text                   # one line each (ok or the problem), with the fix
deploys doctor --fix [--json]           # what to do about each problem, as commands for you to type; shows only, runs and changes nothing
deploys digest [--days 7] [--json] [--no-savings]   # the last week from the journal: deploys, failures, rollbacks, busiest day, projects, and the saving of `ledger` (an estimate; --no-savings skips it, it needs the network)
deploys timeline [--days 3] [--project <name>] [--limit 50] [--json]   # what happened, newest day first: deploys, failures, rollbacks, forced starts (from the journal, UTC; reads only)
deploys recovery [--days 30] [--project <name>] [--json]   # how long a failure lasted until the next deploy of that project; an outage without a later deploy is "open"
deploys streak [--days 90] [--project <name>] [--json]   # deploys in a row without a failure per project: now and longest (from the journal; reads only)
deploys note <project> "text"           # one line in the journal (result `note`, 200 characters); it shows in `timeline`. A text that looks like a secret is refused. Touches no platform.
deploys when [--days 90] [--by weekday|hour] [--json]   # on which weekday or hour of the day your deploys failed more often (UTC); a slot needs 5 tries to count
deploys list --format tsv               # platform, project, auto or manual, last state: tabs, no header, for scripts without jq
deploys idle [--days 90] [--json]       # projects with no deploy for N days: candidates to pause (read only)
deploys changed                         # what is merged on GitHub and not live: commits and PRs per project
deploys deploy-changed                  # the daily deploy: shows the list; add --yes to start it
deploys deploy-changed --when-green --yes  # only commits whose CI passed (waits for running checks)
deploys deploy my-project               # one project to production, on whichever platform it is
deploys deploy-json my-project --no-cache --yes   # build without the host's cache (Render, Netlify, DigitalOcean, Coolify; other hosts refuse it)
deploys deploy my-group                 # a group from deploy-center.json, in its order (TEAM.md)
deploys plan [--when-green] [--since 1d]  # the same list with an estimate per build and the sum (starts nothing); --since: only what changed in that time
deploys status                          # what is building now, and what failed last
deploys watch my-project [--timeout 30m] [--interval 6s] [--quiet] [--json]  # follow the newest deploy until live or failed
deploys watch a --and b --and c            # several at once (six at a time); Ctrl-C stops them all
deploys logs my-project                 # the end of the newest build log, keys and tokens always masked
deploys open my-project [--dashboard]   # the site, or its page at the platform
deploys ignore my-project               # leave it out of changed / deploy-changed
deploys list                            # every project on every provider that is on
```

`freeze` writes only the `deny` list of `window.json` (its `tz` and other keys stay) and starts nothing; it is allowed in observer mode, since it only closes times. A `window.json` that cannot be read is never overwritten.
`--json` is on every command that lists something: `list`, `idle`, `certs`, `creds`, `plan`, `history`, `providers`, `window`, `freeze`, `digest`, `timeline`, `recovery`, `when`, `streak`, `doctor --fix`, `ignore --list`, `team list`, `scan list` and `autofix list`.

## Safe deploys ([SAFE-DEPLOY.md](SAFE-DEPLOY.md))

```bash
deploys verify my-project [--path /health] [--no-rollback]   # ask the site; roll back on 5xx
deploys verify my-project --match "ok" --header "Cache-Control: no-store" --cert-days 14 --warmup 30s   # body, header, certificate, a fresh service
deploys risk my-project                 # green/yellow/red for what waits
deploys secrets my-project              # added lines that look like a key or token; exit 1 if any (a gate)
git diff A..B | deploys secrets --stdin # the same on a diff you pipe in (for GitLab or any repo)
deploys ci owner/repo [<ref>] [--wait 30m]   # the CI verdict of a commit
deploys window                          # is the deploy window (window.json) open now?
deploys freeze                          # the closed times of window.json, numbered, and whether deploys are closed now (--json too)
deploys freeze add fri 15:00            # close Fridays from 15:00 (<days>: fri, fri,sat, mon-fri, weekend, weekdays, daily; <to> is 24:00 unless given)
deploys freeze add sat,sun 0 --reason "weekend"   # a reason is shown in the refusal
deploys freeze remove 2 | clear         # take away rule 2 (the numbers `freeze` shows), or every rule
deploys deploy my-project --force "hotfix"   # inside a closed window; the reason is journaled
```

## Platforms

Vercel and Render are on by default; Netlify, Cloudflare Pages, AWS Amplify, DigitalOcean App
Platform, Coolify and deploy hooks are off until `deploys providers enable <p>`
([PROVIDERS.md](PROVIDERS.md), and one page each in [providers/](providers/)).

```bash
deploys providers [--json]              # every platform: on or off, set up or not
deploys providers enable netlify        # on; says the next step when it is not set up yet
deploys <p> list                        # its projects (JSON where it has no table)
deploys <p> autodeploy-off <name>|--all # pushes stop building
deploys <p> autodeploy-on <name>        # back on
deploys <p> deploy <name> [--preview]   # start one deploy
deploys <p> rollback <name>
deploys <vercel|netlify|cloudflare> previews <project>   # newest preview per pull request, with its URL (JSON, read only)
deploys <p> set-key                     # store its key in the keychain (reads stdin)
```

Each platform's own commands, for example:

```bash
deploys vercel map my-project me/my-repo main   # where a project deploys from (--no-check: offline)
deploys vercel team [<id>]              # show or set the Vercel team (checked with Vercel)
deploys render status my-service <deploy id>
deploys cloudflare selftest <project> --yes     # one real build: does deploying with push-builds off work?
deploys cloudflare account [<id>]
deploys coolify set-url https://coolify.example.com [--allow-http]
deploys netlify autodeploy-off my-site [--rule-added]
deploys hook add <name> <url> | remove <name> | list
```

## Team ([TEAM.md](TEAM.md))

```bash
deploys config [--json] [--refresh]     # the effective config, and where each value came from
deploys team add|remove owner/repo | list | refresh | journal
deploys journal verify | export [--since D] [--project p] | report [--month YYYY-MM]   # see JOURNAL.md
deploys readonly [on|off]               # observer mode: every command that changes something is refused
```

## More

```bash
deploys explain my-project              # why a project is (not) counted as changed
deploys diff my-project                 # commits and files between what is live and the branch
deploys notes my-project                # the same as release notes (Markdown)
deploys history my-project [n]          # the last n deploys
deploys logs my-project [lines] [--follow]  # the end of the newest build log; --follow reads it again (DEPLOYS_FOLLOW_EVERY) until the build ends
deploys rollback my-project [<id>]      # production back to the deploy before, on whichever platform it is on (asks first; --yes in scripts)
deploys cancel my-project [<id>]        # stop a build that is running, on whichever platform
deploys metrics --out /var/lib/node_exporter/deploys.prom   # waiting commits, their age, failures: Prometheus text
deploys gitlab set-token                # a GitLab token into the keychain, read from stdin (GITLAB.md)
deploys costs [days]                    # Vercel charges per day (Vercel only)
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
deploys ai explain|notes|ship my-project   # ask Claude with your own key, see CLAUDE-IN-APP.md
deploys scan start owner/repo           # Claude Code looks for bugs and opens one fix PR (SCAN.md)
deploys scan status | list | log <id>   # installed and logged in, the newest scans, one report
deploys check start owner/repo [branch] # OSV-Scanner, gitleaks and Semgrep on a fresh copy, on this Mac (SCAN.md)
deploys check show <id>                 # the findings, secrets redacted
deploys config [--json] [--refresh]     # every setting in effect (shared files, this Mac) and where each came from
deploys ai ask my-project --question "will this run a migration?"   # your own question; its commits and log go along
deploys ai slow my-project              # why its builds take long (ai risk = ai ship)
deploys autofix --preview --only vercel my-project --json   # what a hand-over would send; sends nothing
deploys team init me/my-repo > deploy-center.json   # a shared config from this Mac's settings (writes nothing itself)
deploys schedule daily 09:00 [--when-green] [--by-rules]   # deploy-changed --yes once a day (launchd, or the cron line)
deploys schedule off | status [--json]
deploys hooks install [<repo>] [--hook pre-commit] [--yes]   # before each push: which builds it would start (integrations/hooks); --hook pre-commit stops a commit that adds a key
deploys hooks uninstall | status [<repo>]
eval "$(deploys completion zsh)"        # tab completion (also: bash; fish: deploys completion fish | source)
deploys deploy --help                   # the help lines of one command
```

## Hooks: scripts around a start (`hooks.d`)

Executable files named `pre-deploy*` or `post-deploy*` in `~/.config/deploys/hooks.d` (the config
folder, see `DEPLOYS_CONFIG`) run around every start from the terminal, `deploy-changed` and the
scheduled job. They get `DEPLOYS_HOOK` (`pre-deploy` or `post-deploy`), `DEPLOYS_PLATFORM`,
`DEPLOYS_PROJECT`, `DEPLOYS_SHA` and, after the start, `DEPLOYS_STATE`. Their output goes to stderr.

```bash
mkdir -p ~/.config/deploys/hooks.d
cat > ~/.config/deploys/hooks.d/pre-deploy-smoke <<'SH'
#!/bin/sh
# no deploy on Friday afternoon: a non-zero exit stops this start
[ "$(date +%u%H)" -lt 515 ] || { echo "no deploys on Friday afternoon" >&2; exit 1; }
SH
cat > ~/.config/deploys/hooks.d/post-deploy-ping <<'SH'
#!/bin/sh
curl -fsS -d "$DEPLOYS_PLATFORM/$DEPLOYS_PROJECT started at ${DEPLOYS_SHA:-?}: $DEPLOYS_STATE" https://ntfy.example.com/deploys >/dev/null
SH
chmod 700 ~/.config/deploys/hooks.d/*
```

- A `pre-deploy` hook that exits non-zero stops that start (the rest of a group goes on); a `post-deploy` hook cannot stop anything.
- A hook that runs longer than `DEPLOYS_HOOK_TIMEOUT` seconds (default 300, `0` no limit) is stopped and counts as failed.
- A file that the group or others can write to, or that belongs to another account (root excepted), is never run; the line says what to `chmod`.
- Hooks are yours: they are read from your config folder only, never from a repo or a shared `deploy-center.json`.

**Not the same as `deploys hooks install`.** That puts a Git `pre-push` hook into one repo (it shows which builds a push would start). `hooks.d` has nothing to do with Git: it holds scripts that run around a deploy started here.

## JSON

`--json` gives the machine answer of: `changed`, `deploy-changed`, `deploy` (one object; for a
group one array of the starts), `status`, `list`, `providers`, `config`, `team journal`, `risk`,
`ci`, `window`, `verify`, `simulate`, `ledger`, `autodeploy allowed`, `guard status`,
`scan status`, `autofix status`, `ai explain|notes|ship|ask|slow|risk`, `plan`, `rules check`,
`schedule status`, `history`, `notes`, `autofix --preview`, and `deploys <p> list|deploy`.
`doctor`, `details`, `costs`, `triggers` and `github-budget` always answer JSON (the app reads
them). `watch`, `logs`, `explain` and `diff` are text only. With `--json` an
error still goes to stderr as text, with a non-zero exit code; stdout holds only what was done
before it (a group that stopped halfway prints the array of the starts so far), else nothing.
Everything after `--` is passed on as it is (a value `--json` stays a value).

An example (made-up names), `deploys changed --json`: one object per project that has commits
which are not live. The fields are those of [PROVIDERS.md](PROVIDERS.md) (`_json` fields); unknown values are `null`.

```json
[{"name":"shop-web","platform":"vercel","id":"shop-web","repo":"acme/shop-web","ref":"main",
  "auto":false,"deployable":true,"lastState":"READY","lastSha":"3f9c2ab","lastAt":1767225600,
  "lastMsg":"Fix cart total","changed":true,"headSha":"a41d7e0","pendingCommits":3,
  "pendingPRs":2,"compareStatus":"ahead","risk":"green"}]
```

`jq -r '.[] | "\(.platform)/\(.name): \(.pendingCommits) waiting"'` turns it into one line per project.

Global options, before or after the command: `--json` (the answer as JSON), `--quiet` (progress lines off: only the result),
`--debug` (the calls to the platforms as a trace, secrets masked), `--force "why"` (a deploy inside a closed window).
`deploys exit-codes` prints the table below in short.

`deploys config export [<file>]` writes this Mac's settings (prices, rules, budget, window, providers, overrides, Vercel
repos) as one JSON file, without keys, journal or hook URLs; `deploys config import <file> [--yes]` checks it (every part
JSON, nothing that looks like a key or token), says what would change and writes it only with `--yes` (the old file stays
as `<name>.bak`). `deploys digest`, `simulate` and `ledger` take `--format markdown`. `deploys metrics` also writes
`deploycenter_up` (0 when a platform did not answer) and `deploycenter_scrape_timestamp_seconds`.

`watch --json` prints one line at the end: `{project, id, phase, state, url}`; `phase` is `ready`, `failed`, `canceled`,
`timeout` or `unreachable`. `verify` can also check the answer's text (`--match`), a response header (`--header 'Name: part'`),
the TLS certificate (`--cert-days N`), wait for a fresh service (`--warmup 30s`) and ask again while the connection is
refused (`--retry-connrefused`); with several checks they run at the same time, and a check that got no answer says why
(DNS, refused, timeout, TLS) in `checks[].why`.

## Exit codes

| Command | Codes |
|---|---|
| every command | `0` done (also "nothing to deploy"); `2` a wrong call (`Usage: …`, a missing argument); `1` an error, something failed to start, or the state of some project could not be read (it is named and left out, never counted as current) |
| `watch` | `0` live, `1` failed or canceled (`--json` tells which: `phase`), `3` the platform could not be asked (or its answer read) five times in a row, or it refused the key (401/403: no waiting), `4` `--timeout` passed first (it may still go live) |
| `deploy --wait`, `deploy <group>` | as `watch` for the member that stopped: `1` it failed, `3` it could not be followed, also when the platform accepted the start but named no deploy id (a group stops there) |
| `verify` | `0` healthy, `1` failed and rolled back, `2` failed and not rolled back, `3` nothing was checked |
| `ci` | `0` green (or no checks), `1` red, `2` still pending or GitHub not reachable; with `--json` always `0`, unless `--exit-code` is given |
| `certs` | `1` a certificate ends soon |
| `creds` | `1` a key is not accepted |
| `secrets` | `1` something that looks like a secret was found |
| `journal verify` | `1` the hash chain is broken |
| `doctor --text --strict` | `1` when a line says `FIX`; without `--strict` (and with the JSON) always `0` |
| `idle` | always `0` |
| `window` | `0` open, `1` closed, `2` window.json could not be read; with `--json` `0` unless it could not be read |
| `autofix --only` | `2` the build did not fail, `3` a fix is already under way, `4` a cap is reached, `5` no routine set up, `6` another autofix run holds the lock ([AUTOFIX.md](AUTOFIX.md)) |
| `deploy-changed --strict` | also `2` when a project was skipped (red or pending CI) |
| `deploy-changed --yes` with a budget | `1` over budget (or, with `--strict`, spending unknown) without `--force "why"` |
| a GitHub, GitLab or Vercel CLI call | `124` when it gave no answer within `DEPLOYS_CLI_TIMEOUT` seconds |
| `with_timeout` (a hook, a provider call) | `124` when the time ran out (the perl alarm's `142` is mapped to it) |

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
| `DEPLOYS_HTTP_TRACE` | `1`: one line per call to a platform on stderr (method, path without query, status, time; no header, no body); `--debug` sets it |
| `DEPLOYS_QUIET`, `DEPLOYS_DEBUG` | what the global `--quiet` and `--debug` set: only the result; the trace of the calls |
| `DEPLOYS_PARALLEL` | how many platform or git host reads run at once in a list (default 8, at most 32; 3 while GitHub's budget is under 1000) |
| `HTTP_DEADLINE` | seconds one platform call may take in all, tries and waits included (default 120) |
| `DEPLOYS_CLOUDFLARE_PER_PAGE` | page size of the Cloudflare project list (default 10) |
| `DEPLOYS_ANTHROPIC_API_KEY` | the key for `deploys ai`, before `ANTHROPIC_API_KEY` and the keychain |
| `DEPLOYS_VERCEL_USD_PER_MIN`, `DEPLOYS_RENDER_USD_PER_MIN` | build-minute prices for `simulate` and `ledger` |
| `DEPLOYS_TIMEOUT` | the older name of `DEPLOYS_CLI_TIMEOUT`, used where that is not set |
| `DEPLOYS_LOG_MAX_BYTES` | size past which a job log is renamed to `.1` (default 1 MB); runs from launchd rotate by themselves, others with `DEPLOYS_LOG_ROTATE=1` |
| `DEPLOYS_CLI_TIMEOUT` | seconds a `gh api`, `glab api` or `vercel api` call may take (default 90; `0` no limit). The Vercel CLI asks `DEPLOYS_VERCEL_TIMEOUT` first (default 60), then this one |
| `DEPLOYS_VERCEL_TIMEOUT` | seconds one `vercel` call may take (default 60; falls back to `DEPLOYS_CLI_TIMEOUT` when that is set) |
| `DEPLOYS_VERCEL_TEAM` | the Vercel team id, if the token sees several teams |
| `DEPLOYS_AMPLIFY_PROFILE` | the aws CLI profile for Amplify |
| `DEPLOYS_CLOUDFLARE_TOGGLE` | `1`: Cloudflare deploys switch push-builds on for the start ([providers/cloudflare.md](providers/cloudflare.md)) |
| `DEPLOYS_COOLIFY_ALLOW_HTTP` | `1`: the Coolify token may go to a plain `http://` instance that is not this machine |
| `DEPLOYS_NETLIFY_POLLS` | how often a Netlify start looks for its new build (default 15) |
| `<NAME>_CMD` | a command that prints a key, asked after the variable `<NAME>` and before the keychain (`RENDER_API_KEY_CMD='op read op://vault/render/key'`; 1Password, pass, Vault, a company tool). First line of its output, 20 s limit. For CI and for Macs where the keychain is off limits |
| `DEPLOYS_NOTIFY_CMD` | your own command for notifications (ntfy, a webhook through `curl`, `notify-send` on Linux): the text is on its stdin and in `DEPLOYS_MESSAGE`, 20 s limit |
| `DEPLOYS_CI_GRACE` | seconds a young commit without any check counts as "CI not started yet" for `--when-green` (default 90; [SAFE-DEPLOY.md](SAFE-DEPLOY.md)) |
| `DEPLOYS_CI_IGNORE` | a regex for check names that do not count for `--when-green` (an optional check that is always red) |
| `DEPLOYS_NO_JOURNAL` | `1`: a start from the terminal writes no journal line (tests, containers) |
| `DEPLOYS_HOOK_TIMEOUT` | seconds one `hooks.d` script may run (default 300; `0` no limit; see "Hooks" below) |
| `DEPLOYS_LOG_ROTATE` | `1`: rotate the job log of this run (the jobs from `schedule`, `guard schedule` and `autofix schedule` set it; `DEPLOYS_LOG_MAX_BYTES` is the size) |
| `DEPLOYS_FOLLOW_EVERY` | seconds between two reads of `logs --follow` (default 5) |
| `DEPLOYS_STRIP_ESC` | `1`: cut colors and control characters out of build logs also on a pipe or into a file (for text that goes into a ticket) |
| `DEPLOYS_ROUTINE_API` | where autofix hand-overs go (default Anthropic's routines API; https only, it receives your token) |
| `DEPLOYS_ROUTINE_BETA` | the `anthropic-beta` header of those calls (default `experimental-cc-routine-2026-04-01`); set it when Anthropic renames the beta and autofix answers with an API error ([AUTOFIX.md](AUTOFIX.md)) |
| `DEPLOYS_SCAN_FOREGROUND` | `1`: `scan start` and `check start` run in the foreground instead of a background process, so a CI job ends after the scan ([SCAN.md](SCAN.md)) |
| `DEPLOYS_TEAM_REFRESH` | `1`: read the shared files from GitHub again whatever the cache's age (as `team refresh`; the age is `DEPLOYS_TEAM_TTL`) |
| `DEPLOYS_LAUNCH_DIR` | another folder for the launchd job files (default `~/Library/LaunchAgents`; for tests and sandboxed accounts) |
| `NO_COLOR` | no color |

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
waiting commit is that old; `minAgeDays` is the same in days. `minCommits` and `minPRs`: at least
that many commits or pull requests wait (collect first, then ship). Conditions are AND: `{"minAgeDays":3,"minPRs":200}`
means three days and 200 PRs; for "50 commits or 3 days" write two rules. `ciGreen`: CI of the head is green or has no checks.

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

- `deploys <p> autodeploy-on … --dry-run` is passed on only to a provider whose meta says
  `"onDryRun": true`; an older provider file would ignore the flag and really turn auto-deploy on,
  so `deploys` stops with an error instead.
- `deploys logs <p> --runtime`: the running service's log, for providers with `"runtimeLogs": true`
  (masked like build logs); others say so.
- `lib/http.sh`: `HTTP_HEADERS=<file>` keeps the response headers; a body `@<file>` is read from it.

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

- `RENDER_API_KEY` takes the place of the keychain; each other provider has its own variable
  (README-CLI.md lists them).
- `VERCEL_TOKEN` is read by the Vercel CLI instead of `vercel login`. Install the CLI in the
  runner (`npm i -g vercel`): without it Vercel is not "ready" and is left out.
- `GH_TOKEN` for `gh`. Without it no branch head is known, and nothing counts as changed.
- `DEPLOYS_CONFIG`: a folder with your `vercel-repos.json`. Keep it between runs (a cache step):
  without it no Vercel project is deployable.

See [examples/](../examples/) for a daily deploy from GitHub Actions.

## Settings

Settings live in `~/.config/deploys/` (or `$DEPLOYS_CONFIG`):

- `vercel-repos.json`: which repo and branch each Vercel project deploys from. Written when
  auto-deploy is turned off. Keep it: it is the only record of where a disconnected project came from.
- `vercel-team`: the team id, detected automatically (empty for a personal account).
- `providers.json`: which providers are on, once changed with `deploys providers`.
- `window.json`: when deploys are closed ([SAFE-DEPLOY.md](SAFE-DEPLOY.md)).
- `overrides.json`, `readonly`: this Mac's team settings ([TEAM.md](TEAM.md)).
