# Command line: `deploys`

The app is a window over one bash script, `deploys`. You can use it on its own. It is inside the
app at `Deploy Center.app/Contents/Resources/deploys`, and `./deploys` in this repo.
`deploys --help` prints every command, and at its end the commands of each provider that is on.
A mistyped command gets one line with the nearest ones (`Unknown command "chaged". Did you mean: changed?`).

A project is named the same way everywhere: by its name, or as `<platform>:<name>` when two
platforms have one of that name (`render:api`). Names that would change an API path (`/ ? # & %`)
are refused before anything is asked; only Amplify ids have one `/` (`amplify:<appId>/<branch>`).

## Everyday commands

```bash
deploys doctor                          # what is connected (JSON)
deploys changed                         # what is merged on GitHub and not live: commits and PRs per project
deploys deploy-changed                  # the daily deploy: shows the list; add --yes to start it
deploys deploy-changed --when-green --yes  # only commits whose CI passed (waits for running checks)
deploys deploy my-project               # one project to production, on whichever platform it is
deploys deploy my-group                 # a group from deploy-center.json, in its order (TEAM.md)
deploys status                          # what is building now, and what failed last
deploys watch my-project [--timeout 30m]  # follow the newest deploy until live or failed
deploys logs my-project                 # the end of the newest build log
deploys open my-project [--dashboard]   # the site, or its page at the platform
deploys ignore my-project               # leave it out of changed / deploy-changed
deploys list                            # every project on every provider that is on
```

## Safe deploys ([SAFE-DEPLOY.md](SAFE-DEPLOY.md))

```bash
deploys verify my-project [--path /health] [--no-rollback]   # ask the site; roll back on 5xx
deploys risk my-project                 # green/yellow/red for what waits
deploys ci owner/repo [<ref>] [--wait 30m]   # the CI verdict of a commit
deploys window                          # is the deploy window (window.json) open now?
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
deploys readonly [on|off]               # observer mode: every command that changes something is refused
```

## More

```bash
deploys explain my-project              # why a project is (not) counted as changed
deploys diff my-project                 # commits and files between what is live and the branch
deploys notes my-project                # the same as release notes (Markdown)
deploys history my-project [n]          # the last n deploys
deploys costs [days]                    # Vercel charges per day (Vercel only)
deploys simulate [--days 30]            # estimate: auto-deploy a month vs. once a day, see SAVINGS.md
deploys ledger                          # estimate: builds and money saved since auto-deploy was off
deploys triggers                        # builds nobody started from here, deploying workflows, Blueprints
deploys where                           # config folder, version, key source, logins
deploys autofix [--dry-run]             # see AUTOFIX.md
deploys autofix --only vercel my-project  # this one failure now
deploys autodeploy allow vercel my-project 4   # auto-deploy on for 4 hours (see GUARD.md)
deploys autodeploy allowed | revoke vercel my-project
deploys guard [--dry-run] | status | schedule on|off   # auto-deploy off where it came back on
deploys ai explain|notes|ship my-project   # ask Claude with your own key, see CLAUDE.md
deploys scan start owner/repo           # Claude Code looks for bugs and opens one fix PR (SCAN.md)
eval "$(deploys completion zsh)"        # tab completion (also: bash)
```

## JSON

`--json` gives the machine answer of: `changed`, `deploy-changed`, `deploy` (one object; for a
group one array of the starts), `status`, `list`, `providers`, `config`, `team journal`, `risk`,
`ci`, `window`, `verify`, `simulate`, `ledger`, `autodeploy allowed`, `guard status`,
`scan status`, `autofix status`, `ai explain|notes|ship`, and `deploys <p> list|deploy`.
`doctor`, `details`, `costs`, `triggers` and `github-budget` always answer JSON (the app reads
them). `watch`, `logs`, `history`, `explain`, `diff` and `notes` are text only. With `--json` an
error still goes to stderr as text, with a non-zero exit code; stdout holds only what was done
before it (a group that stopped halfway prints the array of the starts so far), else nothing.
Everything after `--` is passed on as it is (a value `--json` stays a value).

## Exit codes

| Command | Codes |
|---|---|
| every command | `0` done (also "nothing to deploy"); `1` an error, something failed to start, or the state of some project could not be read (it is named and left out, never counted as current) |
| `watch` | `0` live, `1` failed or canceled, `3` the platform could not be asked five times in a row, `4` `--timeout` passed first (it may still go live) |
| `deploy --wait`, `deploy <group>` | as `watch` for the member that stopped: `1` it failed, `3` it could not be followed |
| `verify` | `0` healthy, `1` failed and rolled back, `2` failed and not rolled back, `3` nothing was checked |
| `ci` | `0` green (or no checks), `1` red, `2` still pending or GitHub not reachable; with `--json` always `0` |
| `window` | `0` open, `1` closed, `2` window.json could not be read; with `--json` `0` unless it could not be read |
| `autofix --only` | `2` the build did not fail, `3` a fix is already under way, `4` a cap is reached, `5` no routine set up, `6` another autofix run holds the lock ([AUTOFIX.md](AUTOFIX.md)) |
| a GitHub, GitLab or Vercel CLI call | `124` when it gave no answer within `DEPLOYS_CLI_TIMEOUT` seconds |

## On a server or in CI

- `RENDER_API_KEY` takes the place of the keychain; each other provider has its own variable
  (README-CLI.md lists them).
- `VERCEL_TOKEN` is read by the Vercel CLI instead of `vercel login`. Install the CLI in the
  runner (`npm i -g vercel`): without it Vercel is not "ready" and is left out.
- `GH_TOKEN` for `gh`. Without it no branch head is known, and nothing counts as changed.
- `DEPLOYS_CONFIG`: a folder with your `vercel-repos.json`. Keep it between runs (a cache step):
  without it no Vercel project is deployable.

See [examples/](../examples/) for a daily deploy from GitHub Actions.

## Environment variables

| Variable | What |
|---|---|
| `DEPLOYS_CONFIG` | the config folder (default `~/.config/deploys`) |
| `DEPLOYS_READONLY` | `1`: observer mode, as `deploys readonly on` |
| `DEPLOYS_NO_GITHUB` | `1`: no GitHub or GitLab calls (nothing counts as changed then) |
| `DEPLOYS_CLI_TIMEOUT` | seconds a `gh api`, `glab api` or `vercel api` call may take (default 90; `0` no limit) |
| `DEPLOYS_VERCEL_TEAM` | the Vercel team id, if the token sees several teams |
| `DEPLOYS_GITLAB_HOSTS` | self-managed GitLab hosts besides gitlab.com ([GITLAB.md](GITLAB.md)) |
| `DEPLOYS_JOURNAL` | where the deploy journal is written |
| `DEPLOYS_NOTIFY` | `0`: no macOS notifications from autofix (default `1`) |
| `DEPLOYS_TEAM_TTL` | seconds a shared deploy-center.json is kept before it is read again ([TEAM.md](TEAM.md)) |
| `DEPLOYS_AUTOFIX_PER_PROJECT`, `DEPLOYS_AUTOFIX_PER_DAY` | autofix caps ([AUTOFIX.md](AUTOFIX.md)) |
| `DEPLOYS_VERCEL_USD_PER_MIN`, `DEPLOYS_RENDER_USD_PER_MIN` | the price of one build minute for `simulate` and `ledger` ([SAVINGS.md](SAVINGS.md)) |
| `DEPLOYS_AMPLIFY_PROFILE` | the aws CLI profile for Amplify |
| `DEPLOYS_CLOUDFLARE_TOGGLE` | `1`: Cloudflare deploys switch push-builds on for the start ([providers/cloudflare.md](providers/cloudflare.md)) |
| `DEPLOYS_COOLIFY_ALLOW_HTTP` | `1`: the Coolify token may go to a plain `http://` instance that is not this machine |
| `DEPLOYS_NETLIFY_POLLS` | how often a Netlify start looks for its new build (default 15) |
| `DEPLOYS_DIR` | where `providers/` and `lib/` are, when not next to the script (Docker) |
| `NO_COLOR` | no colours, also at a terminal |

## Settings

Settings live in `~/.config/deploys/` (or `$DEPLOYS_CONFIG`):

- `vercel-repos.json`: which repo and branch each Vercel project deploys from. Written when
  auto-deploy is turned off. Keep it: it is the only record of where a disconnected project came from.
- `vercel-team`: the team id, detected automatically (empty for a personal account).
- `providers.json`: which providers are on, once changed with `deploys providers`.
- `window.json`: when deploys are closed ([SAFE-DEPLOY.md](SAFE-DEPLOY.md)).
- `overrides.json`, `readonly`: this Mac's team settings ([TEAM.md](TEAM.md)).
