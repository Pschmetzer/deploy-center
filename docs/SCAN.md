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
| `DEPLOYS_SCAN_FOREGROUND` | unset | `1`: `scan start` and `check start` run in the foreground instead of a background process. Set it in CI, or the job may end before the scan does |

## Commands

```
deploys scan start <owner/repo> [branch]
deploys scan status --json      installed, logged in, the newest scans
deploys scan list               the same as a table
deploys scan log <id>           Claude's report of one scan
```

## Security check: OSV-Scanner, gitleaks and Semgrep

"Security check" (right-click a row, or the project's details) runs three free tools on a fresh copy of the repo, on this Mac:

| Tool | Finds | |
|---|---|---|
| OSV-Scanner | packages with known vulnerabilities (lockfiles, requirements) | free, open source; asks `api.osv.dev` for the package names and versions |
| gitleaks | keys and passwords in the code and the git history | free, offline |
| Semgrep CE | bug and security patterns in the code (`p/default`, metrics off) | free CLI; downloads the `p/default` rules from the Semgrep registry |

```bash
brew install osv-scanner gitleaks semgrep
```

Only gitleaks works fully offline. OSV-Scanner sends the names and versions of your dependencies to `api.osv.dev`, and Semgrep fetches its rules from `semgrep.dev`; no source code and no secret leaves the Mac ([SECURITY.md](../SECURITY.md#what-is-sent-where)). A missing tool is shown as missing; the others still run. The check runs **no code of the repo**, so it is safe on any repo.

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

## Nightly check: every repo, only what is new

Settings > Claude > "Nightly check", or `deploys nightly schedule on`, runs the security check above on every repo of your projects once a night (03:00 by default), one after the other, through launchd. A Mac that is asleep then runs it when it wakes. Both switches are **off** by default.

- **The first check of a repo is its starting point.** What is there already is noted, not reported and not sent to Claude; use "Fix with Claude" on a check for that.
- **Only new findings count.** Each finding gets a fingerprint (OSV: file, package, version and advisories; Semgrep: rule, file and message, without the line, since lines move). A finding is reported once, not every night.
- **"Claude fixes new findings"** (`deploys nightly fix on`): new vulnerable packages and new Semgrep findings of severity `ERROR` (or `CRITICAL`, `HIGH`) go to a bug scan (above) with **only those findings**, at most 2 a night (`DEPLOYS_NIGHTLY_MAX_SCANS`) and within the daily scan cap. A scan that is refused (an open scan PR of the repo, the cap) keeps its findings new for the next night. It opens a PR; it never merges or deploys.
- **Leaked keys are only reported**, as for the manual check: rotate them.
- **One notification** at the end, and none when nothing is new. A finding is in a notification once, also while it waits for a scan; a check that keeps failing is notified when it starts failing.
- Paused and ignored projects are left out, and so is a repo you skip (`deploys nightly skip <owner/repo>`, or "Skip" in the app). GitHub repos only.
- Build, type and test errors (tsc, ESLint, the test suite) are not part of the nightly check: they need `npm install`, which runs code of the repo unattended. The bug scan runs them when it fixes something.

```
deploys nightly schedule on [HH:MM] | off     the launchd job (log: ~/Library/Logs/DeployCenter-nightly.log)
deploys nightly fix on | off                  new findings to a Claude bug scan
deploys nightly skip | unskip <owner/repo>
deploys nightly list                          the repos a run checks
deploys nightly run | start                   one run now (start: in the background)
deploys nightly status --json                 settings and the last run per repo (no finding text)
```
