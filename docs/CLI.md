# Command line: `deploys`

The app is a window over one bash script, `deploys`. You can use it on its own. It is inside the
app at `Deploy Center.app/Contents/Resources/deploys`, and `./deploys` in this repo.
`deploys` without arguments prints the full help.

## Everyday commands

```bash
deploys doctor                          # what is connected
deploys changed                         # what is merged on GitHub and not live: commits and PRs per project
deploys deploy-changed                  # the daily deploy: shows the list; add --yes to start it
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
deploys triggers                        # builds nobody started from here, deploying workflows, Blueprints
deploys where                           # config folder, version, key source, logins
deploys autofix [--dry-run]             # see AUTOFIX.md
deploys autofix --only vercel my-project  # this one failure now
deploys autodeploy allow vercel my-project 4   # auto-deploy on for 4 hours (see GUARD.md)
deploys autodeploy allowed | revoke vercel my-project
deploys guard [--dry-run] | status | schedule on|off   # auto-deploy off where it came back on
deploys ai explain|notes|ship my-project   # ask Claude with your own key, see CLAUDE.md
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
| `NO_COLOR` | no colour |

`window.json` may name a time zone: `{"tz":"Europe/Berlin","deny":[…]}`. `deploys window` warns
about keys and times it does not understand. A rule over midnight (`"from":"22:00","to":"06:00"`)
belongs to the day it starts.

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
