# Session counter

Twenty or thirty Claude Code sessions at once are fine. What is not: ten tasks started at the same moment as ten
sessions, when one to three sessions working them one after another would do, or the same task running twice.
`deploys local-sessions` counts the sessions on this Mac, finds tasks that were started together on one repo and should have
been bundled, flags twins and idle sessions, and lists the extras so you can close them. It never closes a session by
itself.

German: [LOCAL-SESSIONS.de.md](LOCAL-SESSIONS.de.md)

## In the terminal

```bash
deploys local-sessions                 # every session: pid, idle time, CPU, RAM, state, title and folder; twins, idle ones, the hint
deploys local-sessions --json          # the same for scripts, the app and the MCP server (deploys_local_sessions)
deploys local-sessions stop 4242       # what ending that session would do
deploys local-sessions stop 4242 --yes # end it (SIGTERM); its transcript file stays, the Claude app may show it as stopped
```

What is flagged:

| Flag | Means |
| --- | --- |
| started together | More than `bundle-to` (default 3) sessions on one repository, each created within `burst-min` (default 10) minutes of the one before (its worktrees count as the repository). The ones beyond the first three are marked "close": those tasks belong in the first sessions. |
| twice | Two sessions with the same title (case, spaces and punctuation ignored): most likely the same task started twice. |
| same folder | Two sessions working in one folder (the same worktree): they may overwrite each other. Different worktrees of one repository are fine. |
| idle | No activity for longer than `idle-min` (default 60 minutes). |

The count turns yellow only near a limit: at `max-local` (default 30). The app's own session limit cannot be read on the
Mac, so this is a setting. With tasks started together, a twin or a yellow count, the hint is "bundle tasks". When a
task was created comes from the first time stamp of its transcript, not from the process start: after the desktop app
restarted all its sessions at once they are not "started together".

## Thresholds

```bash
deploys local-sessions set max-local 30   # yellow from this many sessions on this Mac
deploys local-sessions set max-cloud 30   # kept for a cloud count, see "Cloud sessions"
deploys local-sessions set bundle-to 3    # how many sessions tasks started together may use
deploys local-sessions set burst-min 10   # "together": each created within this many minutes of the one before, on one repository
deploys local-sessions set idle-min 60    # idle after this many minutes without activity
```

They are stored in `~/.config/deploys/local-sessions.json`.

## In the menu bar

The menu shows a line "Claude Code: 24 on this Mac" (cloud sessions have their own line, see below) with a green or yellow dot. Below it a "Bundle
tasks" menu names each group started together ("shop: 6 started within 4 min – 3 at most") and lists the extras, then
the twins, the sessions in one folder and the idle ones; a click on one asks first and then ends it. Nothing is ended without that click. Off with Settings → General → "Show the Claude Code session count".

## For Claude Code

The MCP server has a read-only tool `deploys_local_sessions` with the same JSON, so a session can check the count before
it starts new ones. It cannot end a session.

## Where the figures come from

All read-only:

- `~/.claude/sessions/<pid>.json`: one small file per running Claude Code process (CLI and desktop app) with its
  session id, folder, title and state. Only the `.json` files are read, never the files next to them.
- `ps`: whether the pid is alive and a Claude process, and that it started before the session (so a pid that was
  reused by another process is not counted); CPU and RAM of the session and everything it started.
- `~/.claude/projects/*/<session id>.jsonl`: the transcript; its modification time is the last activity, its first
  time stamp when the task was created. Without a transcript the process start counts for both.

## Cloud sessions

For cloud sessions as GitHub sees them (merged, waiting, stuck) there is `deploys sessions` and the Cloud Sessions
window. This counter covers the Mac. The number of cloud sessions running right now cannot be read on the Mac, so the
JSON says `"cloud": {"count": null, "status": "unknown"}`. What was checked:

- `claude --help` and `claude agents --json --all`: the CLI lists local and background sessions on this Mac; nothing
  in it marks or lists cloud sessions.
- `~/.claude/sessions/`: local processes only.
- The desktop app's own session files under `~/Library/Application Support/Claude/claude-code-sessions/`: a local
  session records the ids of the cloud sessions it started, but not whether they still run, and has no time stamp
  for them, so most of those ids belong to finished sessions. Cloud sessions started on the web or on the phone are
  not recorded on this Mac at all. Its "bridge" ids are Remote Control connections, not cloud sessions.
- The desktop app's session list as a Claude session sees it: only sessions of this Mac.
- The app's browser storage (IndexedDB, Local Storage) was not read: private and changes with every app version.
- GitHub (`deploys sessions`): the branches and pull requests cloud sessions push in the watched repositories. A good
  view of what finished or waits, but it sees only watched repositories and only sessions that pushed, so it is no
  count of running sessions either.

Counting any of these as "running" would be a guess, so the tool does not do it. The `max-cloud` threshold is kept
for the day a reliable source exists.

## Desktop sessions across accounts

`deploys desktop-sessions [--json]` looks at the Code sessions of the Claude desktop app, for every account signed in
on this Mac, and shows per account how many are open, done but still open, waiting on you and running, with the list.
It is read-only: it archives and ends nothing.

Done is judged conservatively. A session counts as done only when:

- it has at least one pull request and every one is merged or closed,
- it is not running: a live Claude Code process for it (`~/.claude/sessions/*.json`, matched by `hostSessionId` or
  the CLI session id, with a pid that is still alive) or `claude agents --json` does not say `busy`,
- nobody is asked: `interruptedAwaitingPerson` is unset, the summary has no `needs_action` and the process is not
  `waiting`,
- its summary is not `review_ready` or `blocked`.

A process that is alive but idle does not keep a session from being done (the app keeps processes of open sessions
around). A completed session without a pull request is only shown as idle after `idleHours` (24).

Where it reads: `~/Library/Application Support/Claude/claude-code-sessions/<account>/<org>/local_*.json`, one file
per desktop session (title, folder, branch, pull requests, last activity, archived or not). Only `local_*.json` is
read; never `.key` files, IndexedDB or Local Storage, and nothing there is ever written. `claude auth status --json`
marks the account in use; only its `orgId` is read. The same org can belong to more than one account folder, then
more than one is marked and the JSON says `"activeAmbiguous": true`.

Accounts are labelled "Account N (first 8 hex characters)", never by email. Your own labels go in
`~/.config/deploys/desktop-sessions.json`:

```json
{"labels": {"<account folder id>": "Work"}, "idleHours": 24}
```

**Archiving is the Claude app's job.** Turn on "Auto-archive sessions when their pull request closes" (Settings →
Claude Code) once in each account; the app then archives a session when its pull request merges or closes, also
while it keeps running. Deploy Center does not edit the app's session files: they are private app state and an edit
races the running app.

In the menu bar (with "Show the Claude Code sessions on this Mac") a line "Done, still open: 14 across 5 accounts"
opens the list per account with that hint. A notification comes only for a session that newly became done or newly
waits on you; the first look after installing is silent.

## Tests

`tests/localsessions-tests.sh` runs on made-up files: `DEPLOYS_LOCAL_SESSIONS_FIXTURE` (a folder with a `ps` output),
`DEPLOYS_LOCAL_SESSIONS_DIR` (the session files), `DEPLOYS_CLAUDE_PROJECTS` (the transcripts) and `DEPLOYS_LOCAL_SESSIONS_NOW`
(the clock). With `DEPLOYS_LOCAL_SESSIONS_FIXTURE` set, `stop --yes` sends nothing.

`tests/desktopsessions-tests.sh` runs on made-up account folders with made-up UUIDs: `DEPLOYS_DESKTOP_SESSIONS_BASE`
(the `claude-code-sessions` folder), `DEPLOYS_LOCAL_SESSIONS_DIR` (the live files), `DEPLOYS_DESKTOP_SESSIONS_FIXTURE`
(a folder with `auth.json`, `agents.json` and `alive`, so `claude` and `kill -0` are never called) and
`DEPLOYS_DESKTOP_SESSIONS_NOW` (the clock).
