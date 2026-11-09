# Changelog

## Unreleased

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
