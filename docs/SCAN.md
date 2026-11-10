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
- **Only your own repos.** The scan runs build and test commands of the repo (`npm run`, `npm install`, `pytest`, …) on this Mac, with your rights. Scan only repos you trust, as you would before running `npm install` in them. The repo's own Claude settings, hooks and MCP servers are ignored (`claude --restricted --strict-mcp-config`), file tools stay in the scan's worktree, and only changed files and new test files go into the PR.
- **Limited tools.** Read, search and edit, plus build, test and lint commands and read-only git. No push, no `rm`, no network tools. Committing, pushing and opening the PR are done by `deploys`, not by Claude. A scan is ended after 90 minutes (`DEPLOYS_SCAN_TIMEOUT`).
- **One at a time.** No second scan of a repo while one runs or while a scan PR of it is open. At most 4 scans per 24 hours (`DEPLOYS_SCAN_PER_DAY`).
- **The Mac must be awake.** A scan takes 10–30 minutes. One whose process is gone (restart, sleep) is marked failed.
- **Never merges, never deploys.** You review the PR. After merging, deploy as usual.

## Settings (environment)

| Variable | Default | |
|---|---|---|
| `DEPLOYS_SCAN_MODEL` | `sonnet` | model passed to `claude --model` |
| `DEPLOYS_SCAN_MAX_FIXES` | `5` | fixes per scan |
| `DEPLOYS_SCAN_PER_DAY` | `4` | scans per 24 hours |
| `DEPLOYS_SCAN_TIMEOUT` | `5400` | seconds before a scan is ended |
| `DEPLOYS_SCAN_DIR` | `~/.config/deploys/scan` | clones, worktrees, reports |

## Commands

```
deploys scan start <owner/repo> [branch]
deploys scan status --json      installed, logged in, the newest scans
deploys scan list               the same as a table
deploys scan log <id>           Claude's report of one scan
```

# Security check: OSV-Scanner, gitleaks and Semgrep

"Security check" (right-click a row, or the project's details) runs three free tools on a fresh copy of the repo, on this Mac:

| Tool | Finds | |
|---|---|---|
| OSV-Scanner | packages with known vulnerabilities (lockfiles, requirements) | free, open source |
| gitleaks | keys and passwords in the code and the git history | free, offline |
| Semgrep CE | bug and security patterns in the code (`p/default`, metrics off) | free CLI |

```bash
brew install osv-scanner gitleaks semgrep
```

A missing tool is shown as missing; the others still run. The check runs **no code of the repo**, so it is safe on any repo.

**"Fix with Claude"** next to the result starts a bug scan (above) with the OSV and Semgrep findings: rule, file, line and message, at most 30, no code snippets. For a vulnerable package the scan may raise that package to a fixed version, the one exception to "no new dependencies".

**Secrets stay on this Mac.** gitleaks runs with `--redact`; only rule, file, line and commit are kept, never the value. Secret findings (gitleaks, and Semgrep's secret rules) are never handed to Claude and never put in a PR: on a public repo that PR would point at the leak, and a commit does not remove a key from the history anyway. The app lists them as "rotate these keys".

```
deploys check start <owner/repo> [branch]
deploys check show <id>                          findings (secrets redacted)
deploys scan start <owner/repo> [branch] --findings <id>
```

| Variable | Default | |
|---|---|---|
| `DEPLOYS_SEMGREP_CONFIG` | `p/default` | Semgrep rules |
| `DEPLOYS_CHECK_TIMEOUT` | `900` | seconds per tool |
