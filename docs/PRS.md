# Pull request upkeep

When many Claude Code sessions work on the same repositories, their pull requests start to conflict with each other
and wait. `deploys prs` looks at every open pull request you wrote, in every repository, and keeps them free of merge
conflicts: it merges the base branch into a conflicting branch (with Claude Code when git cannot do it alone), lets
GitHub bring branches that are behind up to date, and merges the ones that are green. Both automatic parts are off
until you turn them on.

## In the terminal

```bash
deploys prs                          # your open pull requests and what blocks each one
deploys prs --json                   # the same for scripts and the app: a conflicts array and a summary
deploys prs run --dry-run            # what one pass would do, without touching anything
deploys prs set autoResolve on       # resolve conflicts (off by default)
deploys prs set autoMerge on         # merge green pull requests (off by default)
deploys prs run --yes                # one pass now
deploys prs schedule on              # one pass every 5 minutes (launchd); the first only reports what it would do
deploys prs schedule off
deploys prs allow acme/web           # only these repos (empty: all of them)
deploys prs deny acme/legacy         # never these
deploys prs set perRun 2             # caps: resolves per pass, per day (perDay), merges per pass (mergesPerRun); 0 = no cap
```

One GraphQL search, `is:pr is:open author:@me`, covers every repository, so nothing has to be set up first. The
settings are in `~/.config/deploys/prs.json`, what the passes did in `prs-state.json` next to it and in the journal.

## What a pass does

| State | Means | What happens |
| --- | --- | --- |
| conflict | GitHub says `CONFLICTING` | The head branch is checked out in a temporary worktree of a cached clone and the base is merged into it. When git stops with conflicts, a headless `claude -p` resolves them there, keeping the intent of both sides, and runs the repo's checks. A normal merge commit is pushed only when no conflict marker is left and Claude ends with `RESULT: PASS`. |
| behind | the repo wants branches up to date | GitHub merges the base into the branch (`update-branch` with the expected head SHA). |
| ready | not a draft, `MERGEABLE`, `CLEAN`, checks green, no changes requested | `gh pr merge --merge --match-head-commit <sha>` (squash when the repo allows only that). |
| unknown | GitHub has not computed mergeability yet | Nothing. This is normal on a first read; the next pass reads it again. Never notified. |
| red, pending, changes, draft, blocked | | Nothing. |

Rules that always hold:

- Never a rebase, never a force push, never `gh pr merge --admin`, never a merge with red or missing checks
  (`set mergeWithoutChecks on` allows a repo without any checks).
- One attempt per `repo#pr:headOid`. A new push to the branch is a new attempt.
- A pull request that a pass just pushed to is not merged in the same pass; its checks have to run first. At most one
  merge per repo and base per pass, because the base moved and what GitHub said about the others is old.
- A branch that a busy Claude Code session on this Mac has checked out is skipped, so the pass never races that
  session's pushes. The sessions come from `~/.claude/sessions/*.json` and `claude agents --json` (folder, branch, busy).
- Pull requests from forks are skipped.
- When `deploys perf` says memory or swap is tight, the pass is skipped and the next one tries again.
- Claude runs with the CLI's own login (`claude login`), not an API key, with `--restricted`: the repo's own Claude
  settings and MCP servers are ignored, and the environment variables of this Mac that are not needed are removed.
- Merging is all it does. Auto-deploy stays as it is; a host that deploys on every merge to main will do so.

## In the app

The menu shows one line such as "PRs: 2 conflicts, 1 resolving, 3 merged today" and a "Resolve and merge now" item.
A notification goes out once per `repo#pr:headOid` for a conflict and once for each merge or failure. Settings > Deploy
has the toggles for resolving, merging and the 5-minute schedule.
