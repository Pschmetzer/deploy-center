# Repo upkeep

When Claude Code sessions work in worktrees or in the cloud and merge through pull requests, the main checkout of a
project stays on the branch it was last on. A few days later it is hundreds of commits behind `origin/main`, old
branches pile up, and so do worktrees nobody uses. `deploys repos` brings those checkouts back on top of origin,
and only where that cannot lose anything.

German: [REPOS.de.md](REPOS.de.md)

## In the terminal

```bash
deploys repos status            # fetch, then what each checkout is and what a sync would do; nothing changes
deploys repos sync --yes        # do it (without --yes: the same report as status)
deploys repos last --json       # the last result, without git or network (the app and the MCP server read it)
deploys repos schedule on       # every 30 minutes and at login, at low priority (a LaunchAgent)
deploys repos schedule off
```

## What happens to a checkout

After `git fetch origin` (old remote branches are pruned once `sync` has decided, so a branch deleted on origin is still recognised as fully pushed):

| The checkout | What happens |
| --- | --- |
| no changes, on `main` and behind | `git merge --ff-only origin/main` (never a merge commit) |
| no changes, on a branch that is merged | back to `main`, fast-forward, the branch is deleted |
| no changes, its branch gone on origin and every commit of it was pushed | back to `main`, fast-forward; the branch stays |
| no changes, a branch with commits of its own | reported (how far ahead and behind); nothing changes |
| uncommitted changes, untracked files, a conflict, a merge, rebase or cherry-pick running | **never touched**, shown as "needs you" |
| local `main` with commits that are not on origin | not switched to, shown as "needs you" |

A branch counts as merged when its commits are in `origin/main`, when merging it there would change nothing (a squash
merge), or when `gh` shows a merged pull request whose head is exactly this commit. The deleted branch's commit is in
the result and the journal: `git branch <name> <commit>` brings it back.

It also leaves a checkout alone when the fetch failed, when it was used in the last hour (a switch waits for the next
run), and when the update would overwrite an ignored file such as a local `.env` that the new commit tracks. Git hooks
are off for these steps, so a background run never starts `npm install`.

Linked worktrees: `git worktree prune`, then a worktree with no changes, unused for a day, with no process inside and
whose branch is merged is removed with `git worktree remove` (no `--force`) and its branch deleted. Worktrees under
`.claude/worktrees` are left to the Claude app. `deploys clean` frees the disk space of old worktrees separately.

## Which repos

`repos.json` in the config folder (optional):

```json
{"roots": ["~/Code"], "repos": ["~/other/project"], "skip": ["some-repo"]}
```

Without it the `roots` of `clean.json`, without that `~/Documents/Claude`. A repo is a folder directly under a root with
a `.git` folder; a linked worktree belongs to its main checkout.

## Left-behind work and its rescue

```bash
deploys repos stranded [--json]          # folders with uncommitted changes or commits on no remote (read-only)
deploys repos stranded --cached --json   # the last result, no git
deploys repos rescue <folder>            # what a rescue would do
deploys repos rescue <folder> --yes      # do it: a new branch rescue/<folder>-<time> and a draft pull request
```

A session archived by mistake, or one that stopped, can leave work in its worktree that nobody committed or pushed.
`stranded` looks at every work tree of the repos above, the ones under `.claude/worktrees` too, and lists those with
uncommitted changes (untracked files count, ignored ones do not) or commits that are on no remote. It leaves out a
folder a live Claude Code process works in and one changed within the last hour. First come folders whose desktop
session is archived, then folders with no known session, then the rest; within each, the oldest first. It does not
fetch and skips the scan while the Mac is overloaded (`deploys perf`). The result goes to `stranded-last.json`.

`rescue` never touches the folder: no checkout, no commit on its branch, not even its index. The commit is built in a
temporary index on top of the folder's HEAD and pushed as a new branch, never forced; then `gh pr create --draft`.
Commits that are only unpushed are pushed as they are. It refuses, and names the files, when the changes hold a
secret-like file (`.env`, `*.pem`, `*.key`, `id_rsa`, `credentials`, `.npmrc` ...), something that looks like a token
or private key, a file over 5 MB, more than 300 files (usually build output that is not ignored) or a nested repository.
It says when the repo is public, because pushing there publishes the work. The same changes twice are rescued once.
Each rescue is in the journal.

Limits: `DEPLOYS_STRANDED_MAX_FILES` (300), `DEPLOYS_STRANDED_MAX_KB` (5120) and `DEPLOYS_STRANDED_RECENT_MIN` (60,
the minutes a folder must be untouched). With `--json` a refusal is an answer (exit 0, `"state": "refused"`, the files
in `problems`); without it the exit code is 1. Tests (`tests/stranded-tests.sh`) use `DEPLOYS_STRANDED_NOW` (the
clock) and `DEPLOYS_STRANDED_NO_PERF=1` (no load check), temporary repos with a local bare origin and a stub `gh`.

In the menu bar, "Left-behind work: N folders" lists them (scanned once an hour, "Check now" for a fresh look). A click
on one shows what would be pushed and asks; only then it pushes and opens the draft pull request. A folder from an
archived session that is new in the list gets a notification; the first scan is silent.

## In the app and for Claude

Deploy menu → **Repo Upkeep …**: each checkout with its branch and how far behind it is, the ones that need you on top,
a **Sync now** button and the schedule switch. The MCP tool `deploys_repos` returns the last result (read-only);
`refresh: true` runs `deploys repos status` first.
