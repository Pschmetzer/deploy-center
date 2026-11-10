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
eval "$(deploys completion zsh)"        # tab completion (also: bash)
```

Add `--json` to any command for the machine answer.

## Exit codes

`0` done (also "nothing to deploy"). `1` an error, something failed to start, or the state of some
project could not be read (it is named and left out, never counted as current).
`watch`: `3` the platform could not be reached.

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
