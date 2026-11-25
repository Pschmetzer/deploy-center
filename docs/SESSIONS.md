# Session counter

Running many Claude Code sessions in parallel is easy to overdo: the same task ends up running twice, sessions sit
idle for hours, and the cloud session limit is reached. `deploys sessions` counts the sessions on this Mac, flags
twins and idle ones, and once there are too many it suggests bundling tasks: one session that works several tasks one
after another instead of one session per task. It never closes a session by itself.

German: [SESSIONS.de.md](SESSIONS.de.md)

## In the terminal

```bash
deploys sessions                 # every session: pid, idle time, CPU, RAM, state, title and folder; twins, idle ones, the hint
deploys sessions --json          # the same for scripts, the app and the MCP server (deploys_sessions)
deploys sessions stop 4242       # what ending that session would do
deploys sessions stop 4242 --yes # end it (SIGTERM); its transcript stays and it can be resumed
```

What is flagged:

| Flag | Means |
| --- | --- |
| twice | Two sessions with the same title (case, spaces and punctuation ignored): most likely the same task started twice. |
| same folder | Two sessions working in one folder (the same worktree): they may overwrite each other. Different worktrees of one repository are fine. |
| idle | No activity for longer than `idle-min` (default 60 minutes). |

The count turns yellow at `max-local` (default 8). With a yellow count, a twin or an idle session, the hint is
"bundle tasks".

## Thresholds

```bash
deploys sessions set max-local 8    # yellow from this many sessions on this Mac
deploys sessions set max-cloud 4    # kept for the cloud count, see below
deploys sessions set idle-min 60    # idle after this many minutes without activity
```

They are stored in `~/.config/deploys/sessions.json`.

## In the menu bar

The menu shows a line "Claude Code: 9 on this Mac · cloud: unknown" with a green or yellow dot. With a hint there is a
"Bundle tasks" menu that lists the twins, the sessions in one folder and the idle ones; a click on one asks first and
then ends it. Nothing is ended without that click. Off with Settings → General → "Show the Claude Code session count".

## For Claude Code

The MCP server has a read-only tool `deploys_sessions` with the same JSON, so a session can check the count before
it starts new ones. It cannot end a session.

## Where the figures come from

All read-only:

- `~/.claude/sessions/<pid>.json`: one small file per running Claude Code process (CLI and desktop app) with its
  session id, folder, title and state. Only the `.json` files are read, never the files next to them.
- `ps`: whether the pid is alive and a Claude process, and that it started before the session (so a pid that was
  reused by another process is not counted); CPU and RAM of the session and everything it started.
- `~/.claude/projects/*/<session id>.jsonl`: the transcript; its modification time is the last activity. Without a
  transcript the session's start counts.

## Cloud sessions: unknown

Cloud sessions are not counted, and the count says "cloud: unknown" instead of a number. What was checked:

- `claude --help` and `claude agents --json --all`: the CLI lists local and background sessions on this Mac; nothing
  in it marks or lists cloud sessions.
- `~/.claude/sessions/`: local processes only.
- The desktop app's own session files under `~/Library/Application Support/Claude/claude-code-sessions/`: a local
  session records the cloud sessions it started (their ids), but not whether they still run, and has no time stamp
  for them, so most of those ids belong to finished sessions. Cloud sessions started on the web or on the phone are
  not recorded on this Mac at all. Its "bridge" ids are Remote Control connections, not cloud sessions.
- The app's browser storage (IndexedDB, Local Storage) was not read: private and changes with every app version.

Counting the ids would be a guess, so the tool does not do it. The `max-cloud` threshold is kept for the day a
reliable source exists.

## Tests

`tests/sessions-tests.sh` runs on made-up files: `DEPLOYS_SESSIONS_FIXTURE` (a folder with a `ps` output),
`DEPLOYS_SESSIONS_DIR` (the session files), `DEPLOYS_CLAUDE_PROJECTS` (the transcripts) and `DEPLOYS_SESSIONS_NOW`
(the clock). With `DEPLOYS_SESSIONS_FIXTURE` set, `stop --yes` sends nothing.
