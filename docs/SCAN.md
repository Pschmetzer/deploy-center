# Bug scan: Claude looks through a repo and opens one fix PR

"Find bugs with Claude" (right-click a row, or the project's details) runs the Claude Code CLI **on this Mac** against the project's repository. Claude looks for real bugs, fixes up to five, runs the build and tests, and Deploy Center opens one pull request with a report. Nothing is merged or deployed by itself. No routine and nothing in claude.ai is needed.

```
click ──> deploys scan start <owner/repo> <branch>   (returns at once)
            └─ fresh worktree of the repo, branch claude/scan-<repo>-<sha7>
                 └─ claude -p (its own login), edits + build/test commands only
                      ├─ no change   ──> "nothing to fix"
                      └─ changes     ──> commit, push, gh pr create (report as the PR body)
```

## Setup (once)

```bash
npm i -g @anthropic-ai/claude-code
claude login
```

The scan uses the CLI's own login, for example a Claude subscription. An `ANTHROPIC_API_KEY` in the environment is ignored for scans, so they are not billed per token by accident. `gh` must be logged in, since it clones and opens the PR.

## Rules

- **Only bugs.** No style changes, refactors, renames or new dependencies. Anything Claude is not sure about is listed under "Not changed" in the PR, not changed.
- **Limited tools.** Read, search and edit, plus build, test and lint commands (`npm run`, `pytest`, `go test`, `cargo test`, `swift build`, …) and read-only git. No push, no `rm`, no network tools. Committing, pushing and opening the PR are done by `deploys`, not by Claude.
- **One at a time.** No second scan of a repo while one runs or while a scan PR of it is open. At most 4 scans per 24 hours (`DEPLOYS_SCAN_PER_DAY`).
- **The Mac must be awake.** A scan takes 10–30 minutes. One that has not finished after 2 hours is marked failed.
- **Never merges, never deploys.** You review the PR. After merging, deploy as usual.

## Settings (environment)

| Variable | Default | |
|---|---|---|
| `DEPLOYS_SCAN_MODEL` | `sonnet` | model passed to `claude --model` |
| `DEPLOYS_SCAN_MAX_FIXES` | `5` | fixes per scan |
| `DEPLOYS_SCAN_PER_DAY` | `4` | scans per 24 hours |
| `DEPLOYS_SCAN_DIR` | `~/.config/deploys/scan` | clones, worktrees, reports |

## Commands

```
deploys scan start <owner/repo> [branch]
deploys scan status --json      installed, logged in, the newest scans
deploys scan list               the same as a table
deploys scan log <id>           Claude's report of one scan
```
