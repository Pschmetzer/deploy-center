# Changelog

## Unreleased

- App: "Put this live now?" is one sheet for the footer, a row and the palette, with a real "Only when checks are green" checkbox (it was the alert's "don't ask again" toggle). The palette now asks with the same sheet as the window, checkbox included.
- App: the command palette builds its lines once when it opens (and again when demo mode switches) and orders them once per query, instead of on every keystroke and every store poll.
- App: the reload button loads every platform of the tab at once; the build log and the details mask names once per load or redraw; the saving picture is rendered once; a row reads its autofix state once.
- Costs: with a monthly budget set, the chart shows the budget per day and a line says what is left until the month ends (or how the pace compares).
- App: "Settings → …" in texts is built from the settings tab; a test checks that every `deploycenter://settings/…` link names a real tab.
- App: MainWindow.swift is split; the costs sheet, the setup screens and the row have files of their own (no code changed).
- App logic: the latest 30 messages survive a restart (Application Support); a list that fails with HTTP 401/403 or an expired login asks the doctor again, so the setup view appears; a failed `autofix sync` is logged instead of swallowed; Claude's answers render Markdown; Render service types and raw deploy states are translated; the widget's saving uses the same function and day as the costs panel; a new app language reaches the widgets; one rule for "failed" (widget, menu bar, Claude); savings reports moved from the preferences into files, decoded off the main thread; the Claude config is written with sorted keys; "Copy diagnostics" names the script version; one quit/restart dialog; dead code and unused imports gone.
- Tests: the test runner never writes into the real Application Support, Caches or log (`DEPLOYCENTER_DATA_DIR`, or a temporary folder for a binary without a bundle); new tests for ticking changed rows, waiting on two branches, the provider list after a failed read, cancelling `Tool.run`, the widget snapshot, allowance dates, the message store and the savings move.
- iPhone app, deploys and rollbacks: "Nothing new to deploy" before a build of the live commit; the rollback question names the commit, its message and date, and the app follows the rollback until the old version is live; a success or error tap when a deploy or rollback ends.
- iPhone app, list: auto-deploy shown on rows, in the details and as a line above the list; long press for deploy, rollback, open domain, copy the live SHA and the Render dashboard; VoiceOver's "Roll back" asks right there; live and newest commit both shown and copyable; an empty account explains the team id; a refused key (401/403) says so and offers the settings; a private repo without a GitHub token says so.
- iPhone app, start and network: the last list shows at once while the first load runs; data older than five minutes reloads on return; offline shows "Offline" with the time of the data and reloads when the network is back.
- iPhone and iPad: ⌘R reload, ⌘, settings, ⌘D deploy the selection; each window keeps its own selection; wide screens open the first project that needs attention.
- iPhone app, settings: "Test connection" shows the account, team and project count per platform; empty fields say when the Mac's key is used; a note when Background App Refresh is off or Low Power Mode is on. The welcome screen links to creating a Vercel token and a Render API key.
- iPhone app, QR code: a wrong or old code keeps the camera open with the reason.
- iPhone app, speed: GitHub reads use ETags (with a token, a 304 does not count against the limit), the second compare pass and the PR lookups run in parallel, the keychain is read once per key, dates use shared formatters; the background refresh has a time budget and shorter retry waits.
- iPhone app, notes: one note per project and event with a fixed id (no pile-up), more than three become one summary with "+N more".
- Widgets: a "Demo" tag on made-up numbers; on iPhone the time of the data, orange after six hours; the language comes with the snapshot, read once; the iPhone app reloads widgets only when what they show changed.
- shared: `DeployRule` holds the building/failed/waiting rule, `DeploySnapshot.localized` the language pick. `ios/test.sh` checks the rule, PR numbers, rollback targets, ETags and error texts against made-up answers on the Mac.
- ios/build.sh: `--archive` sets the build number from the commit count (or `BUILD_NUMBER`); `--run` boots an iPhone simulator when none is booted. The app is not offered as an iPad app on Mac or Apple Vision Pro.

- pre-push hook: reads `deploys list --json`, so it warns for every platform that is on, and for GitLab remotes (`gitlab.com/group/sub/app`) too. An older CLI without `list` still gets the Vercel and Render lists.
- Status page: `platform/name` works for every platform, not only `vercel/` and `render/`.
- Badges: a name on two platforms gets one badge per platform (`vercel-web.svg`, `netlify-web.svg`); every other name keeps `<name>.svg`.
- Webhooks (notify, digest, status page): `http://` only to localhost, 127.0.0.1 or [::1]; anything else needs `https://`.
- Digest: GitLab merge requests get their title, author and labels through `glab`.
- VS Code: a timeout ends the CLI with everything it started; fuller secret masking; "Show log" opens a read-only document; a settings change during a refresh is not lost; GitLab repos match with host and subgroups.
- Raycast: every platform, `platform:name` for twins, "Deploy All" as one `deploy-changed` run (only when it matches the confirmed list) and off after a run, a timeout ends the CLI's children, and a "401" in a commit is no login error. Publishing uses the locked `ray`.
- `scripts/check-public.sh`: also tokens (GitHub, Anthropic, GitLab, AWS, Slack), private key blocks, email addresses, and words from `~/.config/deploys/private-words`; `--stdin` checks commit messages, which CI now does for every pull request.
- Website workflow and the example workflows pin actions by commit SHA and check out with `persist-credentials: false`. The Docker image pins its node base by digest and installs `gh` from GitHub's apt repo.
- docs/CLAUDE-CODE.md: the suggested deny rules cover every command that deploys, rolls back or turns automation on.
- Settings: new tabs Projects (hidden projects plus pinned, notes, check paths, roll back on failure and ignored build triggers, each with a reset), Costs (budget as a currency field with a stepper and a line saying when the warning comes) and iPhone; the ⌥⌘K hot key moved to General. Each tab has its own height, the window keeps its place, and tabs with options get "Reset to defaults …" (asks first, never touches keys or project data).
- Settings: links into Settings open the right tab ("Open Settings" for hidden projects, the Claude nudge, the Autofix toast, which also scrolls to Autofix, without the private `showSettingsWindow:` selector). New link `deploycenter://settings/<tab>`.
- Settings fixes: notification and login-item hints are read again when the app becomes active; "Open at login" no longer registers twice after an error; a stored value a picker does not offer becomes the nearest one; "Copy diagnostics" has a line per platform, GitLab and Autofix; the Help text names GitLab and every platform; Help lists the keyboard shortcuts.
- Settings → Platforms: platforms the window cannot show yet say "command line only" and cannot be switched on; planned ones sit in a folded "Planned" list without a switch; the locked last switch says why; after a switch "Vercel: on, 35 projects loaded", a failure offers "Try again"; Vercel and Render show whether they are connected.
- Settings → Deploy: "Ask before a single deploy" (on by default) for the row menu and the palette alike.
- Demo mode: View → Demo Mode (⇧⌘D) and a DEMO badge in the window. The output of Autofix, Claude, Team and the guard shows stand-ins; the iPhone QR code cannot be shown in demo mode and closes when it is turned on, and its window is left out of screenshots and screen sharing.
- The menu bar and `deploycenter://select?project=` show exactly that project (by platform when one name is on two; `platform:name` works in the link). A link only shows: it never ticks or starts anything.
- "Changed" counts leave hidden projects out everywhere. One compare link for GitHub and GitLab (`Item.compareURL`).
- Status banner: the status pages come from the provider data (Netlify, Cloudflare Pages, DigitalOcean and others, plus a `statusPage` the script may report), only for platforms that are on.
- Latest messages: a line about a project opens its build log; "Clear" empties the list.
- GitHub budget spent: the app reloads by itself shortly after it resets.
- Costs and build triggers say "As of …" when the last read failed and the values are older.
- The guard's "Run now" reloads only the platforms that are on, in parallel; platform names come from the provider labels ("DigitalOcean App Platform", not "Digitalocean").
- Autofix: "Copy prompt" says why when it fails.

- `./build.sh --install` builds the widgets too when a signing identity is set, so a local install no longer removes the widgets from ~/Applications.
- Autofix: "Claude is fixing it" no longer sticks. The app runs `deploys autofix sync` (new: records merged, closed or open fix PRs, never fires) every few minutes while a hand-over is open, so a merged fix shows "Fix merged – deploy now" even when the 10-minute job is not running. `autofix --only` syncs its project first.
- Autofix: 90 minutes after a hand-over with no PR the row says "No fix PR from Claude – see session" (a cause outside the code, say) and links the session, instead of "fixing" for good.
- `autofix status` reports `scheduled` only when launchd has the job loaded; `autofix sync` loads a job file launchd dropped again.
- CLI tarball and Homebrew formula ship `lib/` next to `deploys`, so team files, the two-person rule, observers, GitLab, `simulate` and `ledger` work after install.sh or `brew install`.
- MCP server: build logs are masked (tokens, keys, passwords, emails) before the agent sees them; arguments are checked against each tool's schema, an unknown or wrong one is an error; `deploys_logs` keeps the real end of a long log; `deploys_changed`/`deploys_status` are never cut in the middle of the JSON (whole entries are left out, with `truncated`).
- Release: `release.sh` refuses untracked files too (build.sh takes `app/*.swift`, `providers/*.sh`, `lib/*.sh` by glob), creates the GitHub release as a draft and publishes it only after the uploaded files match their SHA-256, gives the appcast the app's own minimum macOS (one `MIN_OS` in build.sh), and fails instead of shipping an app without the MCP server. `build.sh` bundles a `.mcpb` only when it is in git, signs only `deploys` on its own in both branches, and `--install` copies next to the old app and swaps, so a failed copy keeps it. `scripts/bump.sh` also sets the MCP server and Claude Code plugin versions and fails when a site line is not found.
- MCP server: `deploys_deploy` and `deploys_rollback` work on every platform (`<platform> deploy-json`) and take `platform:name` for a name on two platforms. A client with elicitation asks the human itself before each one. At most `DEPLOYS_MCP_MAX_DEPLOYS` (default 3) starts per server process, and `DEPLOYS_MCP_ALLOW_PROJECTS` limits which projects. A timed-out start says the build may be running, and the next try reads `status` first. Notes, explain and logs come framed as `<untrusted-data>`. Ending the server stops the `deploys` it started.
- GitHub Action: the deploy step reads `deploy-changed --yes --json` instead of parsing a text line (an answer that is not JSON fails the step). `deploy-on-marker.yml` runs one at a time (`concurrency`).
- Digest: when nothing waits any more, open digest issues are closed, so a later `deploy-approved` label cannot deploy the morning's list. **Changed:** `approve-deploy.yml` reads the list from the digest's own newest, unedited comment (`DEPLOYS_DIGEST_BOT`, default `github-actions[bot]`), not from the editable issue body; it accepts `platform:name`, reads every platform (`deploys list --json`), refuses one platform of a name that is on two, and passes `repo: "*"` to the action (its projects deploy from app repos).
- GitHub Action: with `deploy: true` only the projects of the workflow's repository are started (new input `repo`, `*` for every repo); it fails and starts nothing when that cannot be made sure.
- Claude Code plugin: the push reminder also works for GitLab remotes (subgroups too) and for `cd dir && git push` and `git -C dir push` (the hook no longer has an `if: Bash(git push *)` rule, the script filters). The skills deploy every platform with `deploys deploy <p> --wait`, forbid `--force`, `autodeploy allow`, `guard` and `autofix --only`, and `deploys-ship` no longer calls a project "already live" when `changed` could not read it. The MCP example config runs the server the app ships, no clone needed.
- Claude Code plugin: the push reminder ignores `git stash push`, `--dry-run` and rejected pushes, and reads the right repo for `cd dir && git push` and `git -C dir push`.
- `examples/daily-deploy.yml` installs the checked release tarball (with providers/ and lib/), pins the vercel CLI and sets `permissions:`. CI runs `integrations/tests/run.sh` with `REQUIRE_ALL=1`; a skipped part is reported as skipped, not passed.
- Netlify, Cloudflare Pages, Coolify, DigitalOcean and Amplify keep the provider contract: `<p> has` prints the id, `_status`/`_latest` give `id<TAB>phase<TAB>state`, so `deploy --wait`, group deploys, `watch` and `verify` work for them. The contract tests now run for all five. **Changed:** a Cloudflare project's id is its name (the API paths need it), not the UUID; `netlify logs` exits 1 because Netlify has no build log API.
- `deploys deploy <p>` and group deploys respect the deploy window like `<p> deploy`; forced starts go to the journal.
- Observer mode: `deploy-changed … --yes` is refused wherever `--yes` stands; `autodeploy allow|revoke` and `verify` (unless `--no-rollback`) are refused too.
- `--when-green` no longer passes `--sha` to hosts that cannot build a given commit; it says the branch's newest commit is built.
- Projects without a git repo (image services, unsupported git hosts) are `noRepo`, not "state unknown": `changed` no longer exits 1 for them on every run.
- Render: `render_last_of` has timeouts; a keychain that cannot be read makes `changed` fail ("keychain could not be read") instead of "Nothing to deploy".
- App: hidden projects are never ticked or deployed; ⌘A ticks only the rows the search and filter show.
- App: single deploys (row menu, retry, palette, commit deploy in details) check the deploy window and "only when green" like the batch.
- App: "Deploy to production …" in the row menu asks first, like the palette; "Stop all" asks with the number of deploys it ends. The confirmation names the platform under "All" and marks risky projects.
- App: an empty reason for "Deploy anyway" says that nothing started; rollback and build log are offered only where the platform has them; "Deploy all changed", the palette and the footer's "+2 on …" use enabled platforms only; tab counts and "Changed only" leave hidden projects out.
- App: ⌘K is in the View menu; the ⌥⌘K hot key opens the palette in one main window and its arrow keys no longer act in Settings; a hot key taken by another app is reported and the switch goes back off. The palette says when more than 60 lines match.
- App: GitLab repos get GitLab links (merge requests `!12`, compare) and texts; the details compare against the branch head when the branch is unknown, show "reloading failed" instead of a silent stale view, and list 30 waiting commits first. The monorepo hint counts Vercel projects only and its Ignored Build Step compares with `VERCEL_GIT_PREVIOUS_SHA`.
- App: cancelled deploys show grey "cancelled" instead of a red failure; a failed row shows the first line of its error; "Copy the error" masks tokens; release notes, "Copy for Claude" and "Copy the error" use the stand-ins in demo mode.
- App: a closed provider notice stays closed across launches; "Ignore" on a build trigger can be undone; load errors have Details and Copy; the folded notice line shows how urgent each one is; the search marks domain and source matches and ignores accents; a menu-bar click shows exactly that project; repo headers show project and commit counts.
- App: the monthly cost pace counts whole days only (today is marked "so far" in the chart); the costs list the projects by cost; "Copied ✓" resets and a failed PNG save is reported.
- App: VoiceOver names the build log and says what PR and commit buttons open; error lines carry a mark with "Differentiate without colour"; banners follow "Increase contrast"; toasts and notices only fade with "Reduce motion".
- App: a build past 40 minutes is not shown as failed and keeps its row locked (polled every 30 s, at most 12 hours), so a second paid build cannot start by mistake.
- App: waiting for green CI no longer holds a build slot and can be cancelled; the auto-rollback is skipped when a newer deploy has started; allowances for all platforms or all projects show their badge; demo mode hides the favicon in details; "Copy" in the build log masks secrets (⌥ copies the raw log).
- App: the menu bar list leaves out hidden projects; waiting commits are counted per repo and branch (staging on `develop` and production on `main` no longer merge); the stale alarm skips projects that cannot deploy; the budget pace leaves out the unfinished day; a run's summary counts skipped rows; a second "Undo" toast (a rollback's Cancel) waits instead of replacing the first; a frontend held back by its failed backend is "skipped" in the journal, not "failed"; plural fixes ("1 project").
- App: observer mode keeps the ticks when it refuses a deploy, refuses rollbacks, does not tick merged fixes, and is read again hourly (no need to open Settings → Team). Errors of "turn off auto-deploy", a failed doctor after saving the Render key and a failed `guard status` no longer vanish or reset the state; a failed `providers --json` keeps the last list instead of switching platforms back on, and a switched-off platform's saved list is not shown at start.
- App: a new refresh interval and more parallel builds take effect at once; no doubled reloads after wake; reloads pause while the screens sleep and run half as often in Low Power Mode (costs and strays wait); status polls back off to every 15 s in the middle of a long build; no App Nap or idle sleep while deploys run. Render's `succeeded` records the build time and marks a rollback as behind. The daily reminder shows with the app in front. "Open Settings" in the Autofix toast works on macOS 14+; "Autofix not set up" is read from the exit code (`ToolError.exitCode`).
- App: the script is run without blocked threads and answers even when a detached child keeps a pipe open; `claude` (Settings → Claude) and `gh auth token` (iPhone link) end with their whole process tree at the timeout. The error log masks secrets, is written off the main thread and cannot crash the app on a full disk (journal too). The masker knows Stripe, GitLab, npm, Google, AWS session keys, `--token` and private key blocks.
- App: demo mode scrubs names in Mac notifications too. GitLab repos get GitLab compare links; an `{"error": …}` answer shows its text. Reconnecting Claude Code restores the old entry when the new one fails; an MCP entry pointing into a moved app is reported; only the newest three Claude config backups stay. iCloud Keychain is written only when a key changed. Platform names in simulator and ledger use the provider's label; the German estimate text follows the script's method. Favicon lookup reads at most 64 KB of the front page. Autofix, guard and team status tolerate missing fields.
- iPhone: a second tap cannot start a second deploy; demo deploys need no passcode; rollback refuses when the live deploy is unknown instead of guessing; a QR import keeps keys the QR code leaves empty; a rewritten history or a compare error shows "count unknown" instead of "0 commits".
- iPhone, reading: API answers are no longer cached (a fresh push could hide behind GitHub's `max-age=60`); GitHub's 403 rate limit and `Retry-After` are honoured, with the reset time shown instead of "HTTP 403"; the Vercel team is resolved once, not on every status poll; several Vercel teams without a team id say so instead of silently showing the personal account; a failed deployments read, a list cut at 1000 and GitLab/Bitbucket services ("only GitHub repos are compared") are shown, not swallowed.
- iPhone, deploys: a Vercel deploy that is ready but held off the domains after an Instant Rollback says so instead of "is live"; raw states like `build_failed` are shown in words; the widget's "since" for building or failed projects is the start of the attempt.
- iPhone, background: the refresh uses the app's own store (the list is fresh on return), replaces nothing when iOS cuts it off, keeps what it has seen in Application Support instead of Caches, and sends no notes when there is nothing to compare with yet.
- iPhone, language: texts, dates and the system dialogs (camera, Face ID, now also in German) follow the same language; the widget gets it from the app.
- iPhone, privacy: QR codes older than two minutes are refused; token fields no longer offer to save to Passwords; optional "Unlock on open", which also hides the list in the app switcher; "Remove all keys from this iPhone" (the Mac keeps its keys); a warning when the GitHub token can write; widget project names are hidden while the device is locked; the widget snapshot carries no commit texts; two projects of the same name no longer share a widget row id.
- iPhone, settings: changed fields are not lost by swiping the sheet away (Cancel discards), and a keychain that refuses a key is reported.
- iPhone, accessibility: notes are announced by VoiceOver and errors stay until closed (with a close button); rows have Deploy, Roll back and Open domain actions; the status icon is not read; texts name Face ID, Touch ID or the code as the device has it; the QR scanner explains itself and gives haptic feedback; "Updated …" and "Waiting since" keep ticking; the widget reads as one sentence and scales with the text size.
- Docs and site: README, FAQ and guides no longer call built features "coming"; the site takes its version from `VERSION`; SECURITY.md and UNINSTALL.md list every data flow, job and keychain entry. `install.sh` runs from `main()` (a cut-off download installs nothing) and stops on Ctrl-C.
- CLI: `deploy --wait` exits 3 (not 1, "did not go live") when the platform could not be asked, and follows the newest deploy when a start has no id yet (Netlify). `changed` with no platform on and set up is an error pointing to `deploys providers`, not "every project is on its newest commit"; `--platform` with an unknown name is refused.
- CLI: a keychain that cannot be read is named for Netlify, Coolify, DigitalOcean, Cloudflare and Amplify too, instead of their "no token".
- CLI: `verify`, `risk` and `ai` take `p:name`. **Changed:** `verify` exits 3 when nothing was checked (unknown project, not live, no address, a wrong option), so 1 always means "rolled back"; with `--path`, a 4xx fails the check too, and redirects are followed.
- CLI: `guard schedule`/`guard status` say "on" only when launchd has the job loaded, and load a dropped one again. Two projects of one name on one platform name their ids instead of suggesting `p:name` again. The name cache forgets deleted projects. The journal writes a provider's label ("Netlify"), not its id.
- CLI: keys piped to `set-key`/`ai set-key` lose a trailing CR and surrounding spaces; spaces, quotes or a backslash inside are refused. `logs <p> 0` is refused (it printed the whole log), `history` takes 1 to 100, `open` only `--dashboard`. Tables work without `column` (an awk fallback).
- CLI: `ignore vercel:api` leaves out only that platform's project. A name that is a group and a project is refused by `deploys deploy`; `group:<name>` picks the group.
- Vercel: deploys from GitLab or Bitbucket get their commit (`lastSha`, rollback, history, savings). Turning auto-deploy off keeps a link whose repo cannot be written down (Bitbucket) instead of losing it; turning a GitLab one back on points to the dashboard. `vercel deploy --wait` gives up like `watch` (exit 3) instead of asking for ever. Vercel and Render `deploy-json` refuse unknown options instead of deploying the newest commit.
- Bug scan: "Find bugs with Claude" (row menu and details) runs the Claude Code CLI on this Mac against the repo, fixes up to five real bugs, runs build and tests, and opens one PR with a report. Never merges or deploys. `deploys scan start|status|list|log`. See docs/SCAN.md.
- Security check: OSV-Scanner, gitleaks and Semgrep on a repo, free and local (`deploys check start|show`, "Security check" in the row menu and details). "Fix with Claude" hands the package and code findings to a bug scan (`scan start … --findings <id>`). Secrets are redacted, never stored as values, never sent to Claude or put in a PR; the app lists them as keys to rotate.
- `deploys` refuses every command that changes something when `lib/team.sh` is missing but this Mac uses a shared deploy-center.json (team repos, overrides.json or a cached shared file): an install without `lib/` no longer skips the two-person rule and the observers list. Reading still works.
- The shared `window` and `health` of deploy-center.json now count in the CLI: a deploy outside a project's allowed window (in its `tz`) is refused, or skipped by `deploy-changed`, unless `--force "why"` (journaled); `verify` without `--path` checks the shared `health` path. An unknown time zone is an error, not UTC.
- Guard and allowances cover every platform that can turn auto-deploy off (Netlify, Cloudflare, Coolify, DigitalOcean, Amplify), not only Vercel and Render. **An already scheduled guard now also turns auto-deploy off there** when it is on without an allowance. A switch-off that leaves auto-deploy on (Netlify waiting for its netlify.toml line) is reported as failed, not as done. Netlify gets no allowance, since auto-deploy cannot come back on from here.
- `deploys ci` and `deploy-changed --when-green` read every page of check runs (a red check past the first 100 is red), and GitLab pipelines; a GitLab repo nobody here can read, or a host deploys does not know, is skipped at once instead of waiting 30 minutes. `details` counts checks over every page too.
- GitLab: `risk` and the `risk` of `changed`/`pending` work for GitLab repos; a GitLab host with a port (`git.example.com:8443`) is asked on that port; `deploys gitlab set-token` (trimmed and tried before it is saved, like `render set-key`) keeps the token in the keychain instead of `GITLAB_TOKEN` in the shell profile, and `gitlab forget-token` removes it.
- `changed` says why a branch head is unknown (rate limit, not logged in, no such repo or no access, host not reachable) instead of always "is gh installed and logged in?".
- The two-person rule says when GitHub could not be read to check approvals, instead of "Found none".
- `details` (and `risk`, `ai`) without a branch use the repo's default branch, never a silent `main`; when it cannot be read, `details` says so.
- `deploys logs --masked` hides keys, tokens, passwords and email addresses (the same mask as autofix), for logs that go to an agent or a model.
- `doctor` puts the Netlify, Coolify, DigitalOcean, Cloudflare and Amplify fields under their provider name (`netlify.tokenOk`), so one provider no longer overwrites another's. Vercel, Render and hook keys stay at the top.
- `triggers` finds workflows that deploy to Netlify, Cloudflare, DigitalOcean, Amplify or Coolify, in the repos of every platform that is on.
- Coolify: Ctrl-C during a deploy with `--sha` puts the app's commit back instead of leaving it pinned for later auto-deploys.
- Savings (`simulate`, `ledger`) no longer ask Render about another platform's projects: a provider without its own `<p>_builds` is marked unsupported.
- Open pull requests: a full page (100) is marked `openPartial`, a floor and not the exact count. `xargs` no longer runs once on empty input on Linux. The launchd job files escape `&` and `<` in paths.

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
