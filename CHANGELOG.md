# Changelog

## Unreleased

- Autofix: "Claude is fixing it" no longer sticks. The app runs `deploys autofix sync` (new: records merged, closed or open fix PRs, never fires) every few minutes while a hand-over is open, so a merged fix shows "Fix merged – deploy now" even when the 10-minute job is not running. `autofix --only` syncs its project first.
- Autofix: 90 minutes after a hand-over with no PR the row says "No fix PR from Claude – see session" (a cause outside the code, say) and links the session, instead of "fixing" for good.
- `autofix status` reports `scheduled` only when launchd has the job loaded; `autofix sync` loads a job file launchd dropped again.
- Bug scan: "Find bugs with Claude" (row menu and details) runs the Claude Code CLI on this Mac against the repo, fixes up to five real bugs, runs build and tests, and opens one PR with a report. Never merges or deploys. `deploys scan start|status|list|log`. See docs/SCAN.md.

## 0.9.1

- Settings → General → Language: English, Deutsch or the Mac's language (the default). The app restarts to switch; the widgets follow it.

## 0.9.0

- `deploys status --json` carries the shared `phase` of each project. VS Code extension 0.2.0: every platform, not only Vercel and Render; failed and building from `phase`; a name on two platforms is passed as `platform:name`; a hint when no project matches the folder.
- Observer mode also refuses `guard` and `autofix --only` (without `--dry-run`); both change something. An approval check on a GitLab-linked Vercel project says that approvals are read from GitHub only.
- Command palette: in observer mode (Settings → Team) it offers no deploy, rollback or "deploy all changed", like the window.
- Ask Claude → Explain this failure: its button is now "Fix with Claude", the same as on the row (same caps, setup offer and toast).
- Updates via Sparkle 2: the app reads https://deploycenter.app/appcast.xml once a day (Settings can turn it off) and on "Check for Updates …", accepts a download only with a valid EdDSA signature and the same Developer ID, and installs once no deploy is running. Replaces the old GitHub release check and "Update now". The Homebrew cask says `auto_updates true`.

## 0.8.0

- Mac widgets ship with the app (small: PRs waiting; medium: top projects and the saving). Add them from the widget gallery.
- `deploys`: each platform is one file, `providers/vercel.sh` and `providers/render.sh`, behind one contract (`docs/PROVIDERS.md`). Nothing changes for Vercel and Render users. New: `deploys list --json` (every project on every platform), `deploys providers [--json]`, `deploys providers enable|disable <p>` (Vercel and Render are on by default, any later platform is off until turned on), and names as `render:web`. Every `json` entry has a `phase` (queued, building, ready, failed, canceled). `render deploy-json --preview` is refused instead of deploying production.
- `providers/hook.sh` (generic deploy hook) follows the same contract: off until `deploys providers enable hook`, then `deploys hook add|remove|list|deploy` route through `deploys`. `deploys hook status <name>` keeps its JSON; its doctor fields are `hookReady`, `hookStore`, `hookCurl` and `hooks`.
- Auto-deploy guard (`deploys guard`, Settings → Auto-deploy guard): every 30 minutes it turns auto-deploy off again wherever it is on without an allowance, and notifies. `deploys autodeploy allow <platform> <project>|--all <hours>` allows it for a while (emergencies); `deploys vercel|render autodeploy-on` turns it back on. The first run is a dry run.
- Window: each row shows what autofix does ("Claude is fixing", fix PR open/merged, "deploy the fix"), a "Fix with Claude" button on failed rows (`deploys autofix --only`), allowance badges, and the count in the menu bar.
- Self-update moved to `Updater.swift`: checks the folder is writable, swaps with a rollback, accepts only the same Team ID and no downgrade, runs off the main thread, asks before quitting during deploys, cleans up on every path.
- Fixed: after a deploy, rows return to idle, so new commits count as waiting again; "today" is the local day, not UTC; notifications are asked for at the first one, not only at the first deploy.
- Fixed: a timeout ends the whole process group; a deploy timeout no longer causes a double deploy; cancel cannot leave a row running forever; a load error keeps the cached list and shows above it.
- Build log: secrets are masked before "Copy for Claude", fewer false error lines, ANSI codes removed; one broken project no longer fails the whole list.
- Journal and saved state live in Application Support; CSV export is safe in spreadsheets.
- UI: demo mode masks names everywhere; one collapsible notice area; settings in sections; Help menu, Dock badge, VoiceOver labels and actions, clearer empty states, raw states like `build_failed` translated, build log selectable across lines.
- `deploys`: a Render read error no longer marks services changed, an unreachable API is an error instead of "Nothing to deploy", `changed --platform X --json` keeps the filter, only a real missing ancestor counts as rewritten history; `--help`, `--version`, `where`, `history`, `forget-key`, `deploy --wait`; timeouts and retries for Render.
- Release: `release.sh` passes `--repo` and `--target`, checks the tree, can publish an existing build; the cask depends on jq, quits the app on uninstall and explains `brew trust` and `--appdir`.
- Security: Autofix log masking keeps `Authorization: Bearer` tokens out (they used to pass, and a `$1[masked]` replacement emptied other matches) and now also masks AWS secret keys, Stripe, GitLab, npm and Google keys, private key blocks, `--token` arguments and `*_KEY=` values.
- Security: a Vercel team id or a temp folder path can no longer run as shell code in `costs`, `vercel json`, `render json` and `triggers`; team ids are checked. Project and repo names reach `jq` as `--arg`, never inside a filter; JSON from GitHub file names is built by `jq`.
- Security: project names and deploy ids with `/ ? # & % \` or control characters are refused before any API call; `logs` takes digits only for the line count; `autofix set-token` refuses tokens with spaces or quotes.
- `SECURITY.md`: threat model, what is sent where, rules for new code.
- GitLab as a source next to GitHub (gitlab.com and self-managed): waiting commits, merged and open merge requests, and `details`, through `glab` or `GITLAB_TOKEN` (+ `GITLAB_HOST`). Same JSON as for GitHub; `doctor` reports `gitlabCli` and `gitlabLoggedIn`. See `docs/GITLAB.md`.
- The CLI installs on its own (macOS, Linux, WSL, CI): `curl -fsSL https://deploycenter.app/install.sh | sh` (SHA-256 checked, `~/.local/bin`, sudo only for a prefix that needs it; `--prefix`, `--version`, `--uninstall`) or `brew install pschmetzer/tap/deploys`. Releases carry `deploys-cli-<version>.tar.gz` and `checksums.txt` next to the app zip. See `README-CLI.md`.
- Claude Code plugin in `integrations/claude-code/`: a skill, `/deploys-*` commands and a read-only reminder after `git push`; install with `/plugin marketplace add Pschmetzer/deploy-center`. See `docs/CLAUDE-CODE.md`.
- `providers/amplify.sh`: AWS Amplify Hosting, opt-in. Auto-build off per branch, deploy (`start-job RELEASE`, with `--sha`), cancel, logs, and rollback by rebuilding an earlier commit, through the `aws` CLI. See `docs/providers/amplify.md`.
- Claude in the app (opt-in, off by default, your own Anthropic API key): *Ask Claude* in the detail sheet and build log explains a failed build (with *Hand to Autofix*), writes plain release notes in English or German, and answers "Is this safe to ship?". Settings → Claude in the app: key in the keychain, Verify, model, monthly token cap and usage. CLI: `deploys ai explain|notes|ship <project>`. Only masked text is sent; the masker now also hides email addresses. See `docs/CLAUDE.md`.
- `examples/claude-pr-ship-check.yml`: on each PR, Anthropic's Claude Code GitHub Action comments "What this ships" from `deploys changed --json`.
- `integrations/mcp/`: an MCP server for AI coding agents. Read-only by default (`changed`, `status`, `explain`, `notes`, `logs`, `doctor`); deploy and rollback of one project per call only with `DEPLOYS_MCP_ALLOW_DEPLOY=1`.
- Safe deploys (see `docs/SAFE-DEPLOY.md`): `deploy-changed --when-green [--wait 30m]` deploys only commits whose CI passed (and waits for running checks); `deploys verify <project>` checks the site after a deploy and rolls back after a countdown; `window.json` closes deploy windows (`--force "why"` goes to the journal); `deploys risk <project>` scores the waiting diff green/yellow/red. New: `deploys deploy <project>`, `deploys ci`, `deploys window`.
- App: "Only when checks are green" in the deploy confirmation, "Roll back if the check fails" per project in the details (a countdown notification with Cancel), a warning with "Deploy anyway…" inside a closed deploy window, and a red dot for risky changes.
- Team mode, without a server (`docs/TEAM.md`): a shared `deploy-center.json` in each repo (project → repo/branch, health paths, deploy window, ignored projects, groups, approvals, observers), read with `gh` and cached, merged below this Mac's own files. `deploys config [--json]` shows each value and where it came from; schema in `docs/deploy-center.schema.json`.
- Observer mode: `DEPLOYS_READONLY=1`, `~/.config/deploys/readonly` (`deploys readonly on|off`, Settings → Team), or a login in `observers`. Every command that changes something is refused; the app hides its deploy buttons and shows "Observer".
- Two-person rule (optional per project): a production deploy needs an approving PR review or a `deploy-approved-by:<login>` label from someone else, on the exact commit, which is then pinned. `--force "reason"` overrides and is journaled (`deploys team journal`).
- `deploys deploy <project>|<group>`: one project on either platform, or a group in order, each waiting for the one before to be live.
- Fixed: file ages on Linux (`stat`), which the start lock and the Vercel team cache depend on.
- Window: the tabs come from the enabled providers (`deploys providers --json`; Vercel and Render with an older script). One provider has no tabs, two or three a segmented control with "All", four and more a menu; ⌘1, ⌘2 … follow the order, "All" takes the next digit (⌘3 with Vercel and Render, as before).
- Settings → Platforms: a switch per provider. Vercel and Render are on; others say "coming soon" until the script reports them, and switching runs `deploys providers enable|disable`.
- Calmer window: one summary line ("12 PRs waiting · $41 saved") instead of the waiting banner and sparkline; the cost bar is one number that opens a Costs sheet with the chart and "Share the saving"; "updated hh:mm" is in the reload tooltip; rows show one figure and sit under a small repo header instead of "same as above"; the footer has "More" (select all changed ⌘A, clear, preview deploy, history, messages) next to "Deploy N"; the row menu is Deploy, Build log, Open site, More.
- Agent digest (`integrations/digest/`): once a day, what waits per project with agent and human commits apart, pull requests and risk hints, as Markdown, an issue and a webhook message with an approve button. An example workflow deploys only the projects a listed person approved (button or `deploy-approved` label).
- `deploys details`: each commit carries its `Co-Authored-By` trailers as `coAuthors`.
- Savings, all marked as estimates (≈) with the method in the JSON: `deploys simulate [--days 30] --json` counts pushes to each deploy branch (GitHub) times the project's average build and puts "auto-deploy ≈ X a month" next to "once a day ≈ Y"; `deploys ledger --json` counts the pushes since auto-deploy was turned off that never built, in dollars, Vercel build minutes and Render pipeline minutes (logic in `lib/savings.sh`). The app has a Simulator sheet (a banner before anything is turned off, and Settings > Costs) and a Ledger ("≈ $X saved since …", per project, skipped pushes, share card).
- App: command palette (⌘K). Fuzzy search over the actions (deploy all changed, reload, stop all, journal, settings, costs) and per project deploy, log, open, dashboard, rollback and notes; recent commands first. Deploys and rollbacks ask first, as in the window. Optional global ⌥⌘K under Settings → Advanced (off by default).
- `deploys autofix`: a failed build (Vercel `ERROR`, Render `build_failed`) is handed to a Claude Code routine that opens a fix PR; after the merge it only notifies you; deploying stays a click (#51). Caps, no duplicates, never merges. See `docs/AUTOFIX.md` and `scripts/autofix.plist.example`.
- `deploys status --json` carries each project's `repo` (owner/name), so an editor can match it to the open folder.
- New: a VS Code / Cursor / Windsurf extension in `integrations/vscode/` (waiting count in the status bar, a project tree, deploy with confirmation, build log and "Copy for AI").
- `deploys logs <project> --id <deploy>` reads the log of one deploy; `vercel json` and `render json` carry `latestId` and `latestSha` of the newest attempt.

## 0.7.0

- Build log: a failed last deploy ("Last deploy … build_failed") has its own log button, not only a deploy started from the app.
- Settings: "Check for updates now", and "Update now" downloads the newest release, checks its signature, replaces the app and restarts it.
- Site: legal notice and privacy policy.

## 0.6.0

Includes everything listed under 0.5.0, which was not published as its own release.

- Rollback skips an older deploy of the same commit (Vercel and Render), so it really changes what is live.
- Menu bar: a line when auto-deploy is still on somewhere, and the current provider outages.
- "Share the saving" under the cost bar: copies a picture and a sentence with your build cost before and since auto-deploy was turned off, without project names.
- `deploys changed --platform vercel|render`; the completion names file no longer grows; the login-shell PATH is read once a day instead of at every start.
- `deploys explain <project>` says why a project is, or is not, counted as having changes.
- Tabs show "35 · 9" (projects · with changes); "Stand" reads "Aktualisiert".
- `release.sh` refuses an empty changelog and an already tagged version; issue template "A number is wrong"; `docs/ZAHLEN.md` explains the counts.
- Rows of one repo (frontend + backend) stay together; the later ones say "same changes as the row above" instead of repeating commits, oldest commit and open PRs.
- Fixed: costs, budget and provider outages refresh while the app runs (menu bar), not only at start; status feeds load in parallel.
- Fixed: the site check no longer holds a build slot of the queue.
- Fixed: after a deploy run the lists reload; a running deploy on one platform no longer pauses the other.
- Fixed: a rollback says "rolled back" and a preview "preview is ready" instead of "is live"; "1 Projekt" instead of "1 Projekte".
- Fixed: every queued deploy waits from its own click; a later selection no longer delays an earlier one.
- Fixed: the start lock cannot be taken twice at the same moment; Render rate limits (429) are retried (also in the parallel list read) and errors say what to do.
- Fixed: after a rollback the row no longer claims to be on the newest commit.
- Fixed: a repo shared by a frontend and a backend counts its PRs and commits once in the banner and the menu bar.
- Fixed: the banner says how many of the waiting projects are on the open tab.
- Fixed: a lost network or login is shown during a deploy instead of spinning silently.
- Fixed: the site check asks three times (fresh Render services answer 502 at first) and treats 401/403 as protected, not broken.
- `deploy-changed` starts Render services through the same lock as the app; `triggers` asks Render in parallel.
- Build log: failing lines in red, "Jump to the first error", "Errors only", "Copy for Claude".
- Demo mode (Settings): project names and domains are replaced, for screenshots.
- CI on GitHub (tests and type-check; no deploys).
- A wait before a deploy starts (Settings, default 8 s) with "cancel" in the row; "Stop all" in the footer; a summary when a run of several deploys ends.
- "Copy release notes" in the project details; "Page to check after deploy" per project (e.g. /health).
- Monthly build budget with a warning at 80 % of the pace; the cost bar also shows under "All".
- Tab and filters are remembered; the menu bar icon shows building and failed; lists reload after sleep.
- `deploycenter://select?project=name` shows a project (never starts a build).
- The script runs on Linux too (stat, date, base64).
- Hiding a project can be undone from the message; hidden projects are listed in Settings, one by one.
- A bell in the footer lists the latest messages; queued rows say "place 2 of 5".
- Settings: warn when commits wait longer than N days; "Copy diagnostics" (versions only, no names or keys).
- Deploy history (clock in the footer): every ended deploy with duration, "n of the last 10 failed", CSV copy.
- A banner when Vercel, Render or GitHub report a problem on their status pages; an empty state for accounts without projects.
- A build that takes twice as long as usual turns orange. `deploys status --watch`. Docs: security, contributing, launchd and deploy-on-label examples.
- `deploys diff <project>` and `deploys notes <project>` (release notes in Markdown).

## 0.5.0

- A deploy queue (at most N builds at once), a backend before the frontend of the same repo,
  cancel, retry, deploy up to a chosen commit, Render with a cleared cache, a lock against
  starting a project twice.
  Tested against Vercel: a preview build, the lock and following a build. Not yet: the queue
  in the app, cancel, Render.
- A daily reminder at a chosen hour (it never deploys by itself); search marks; Shift-click ranges.
- The code is split into a few files; tests for the script and the app.
- Project details: the waiting commits with their PRs, files changed, files worth a look
  (migrations, lockfiles, env, Dockerfile, workflows), CI of the branch, open PRs with CI.
- The last build log in the app and as `deploys logs <project>`.
- Costs over 14 days: per day before and since auto-deploy went off, a month at this pace,
  outlier days marked, about how much one build of a project costs.
- Settings (⌘,): reload interval, menu bar, no Dock icon, open at login, notifications, update check.
- An All tab with both platforms; pin, hide and a note per project.
- PRs waiting per day as a small line; elapsed time of a running deploy; a check that the site
  answers after going live; a note when a newer version is out.
- New commands: `status`, `watch`, `logs`, `open`, `ignore`, `completion`, `details`,
  `github-budget`, and `--json` on any command. `RENDER_API_KEY` works without a keychain.
- Fixes: a failed Render deploy no longer hides the changes; a Vercel build started elsewhere is
  not ticked again; rollback goes to the deploy before the live one; GitHub calls are cached and
  stop before the hourly budget runs out; the menu bar stays current with the window closed;
  `vercel` installed through nvm, volta or fnm is found.
- Errors are written to `~/Library/Logs/DeployCenter.log`.

## 0.4.0

- Counts what waits on GitHub: commits and merged PRs not live, per project and in total,
  and open PRs. A menu bar icon with the number.
- `deploys changed` and `deploys deploy-changed [--yes]`; `deploys vercel map`.
- The last lists show at once and are read again every 15 minutes; a notification when a
  deploy ends; changed projects first; the waiting commits on GitHub from the context menu.

## 0.3.0

- Build costs per day and project from Vercel's billing; a warning when something else
  (a workflow, a deploy hook, a Blueprint) still starts builds.

## 0.2.0

- Preview deploys, rollback, commit-based change detection, universal binary.

## 0.1.0

- Turn off auto-deploy on Vercel and Render; deploy the newest commit by hand from one window.
