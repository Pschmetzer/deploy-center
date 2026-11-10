# Changelog

## Unreleased

- `integrations/mcp/`: an MCP server for AI coding agents. Read-only by default (`changed`, `status`, `explain`, `notes`, `logs`, `doctor`); deploy and rollback of one project per call only with `DEPLOYS_MCP_ALLOW_DEPLOY=1`.
- App: command palette (⌘K). Fuzzy search over the actions (deploy all changed, reload, stop all, journal, settings, costs) and per project deploy, log, open, dashboard, rollback and notes; recent commands first. Deploys and rollbacks ask first, as in the window. Optional global ⌥⌘K under Settings → Advanced (off by default).
- `deploys autofix`: a failed build (Vercel `ERROR`, Render `build_failed`) is handed to a Claude Code routine that opens a fix PR; after the merge, the next run deploys that merge commit once. Caps, no duplicates, never merges. See `docs/AUTOFIX.md` and `scripts/autofix.plist.example`.
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
