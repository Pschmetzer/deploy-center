# Session counter

Twenty or thirty Claude Code sessions at once are fine. What is not: ten tasks started at the same moment as ten
sessions, when one to three sessions working them one after another would do, or the same task running twice.
`deploys sessions` counts the sessions on this Mac, finds tasks that were started together on one repo and should have
been bundled, flags twins and idle sessions, and lists the extras so you can close them. It never closes a session by
itself.

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
| started together | More than `bundle-to` (default 3) sessions created within `burst-min` (default 10) minutes on one repository (its worktrees count as the repository). The ones beyond the first three are marked "close": those tasks belong in the first sessions. |
| twice | Two sessions with the same title (case, spaces and punctuation ignored): most likely the same task started twice. |
| same folder | Two sessions working in one folder (the same worktree): they may overwrite each other. Different worktrees of one repository are fine. |
| idle | No activity for longer than `idle-min` (default 60 minutes). |

The count turns yellow only near a limit: at `max-local` (default 30). The app's own session limit cannot be read on the
Mac, so this is a setting. With tasks started together, a twin or a yellow count, the hint is "bundle tasks". When a
task was created comes from the first time stamp of its transcript, not from the process start: after the desktop app
restarted all its sessions at once they are not "started together".

## Thresholds

```bash
deploys sessions set max-local 30   # yellow from this many sessions on this Mac
deploys sessions set max-cloud 30   # kept for the cloud count, see below
deploys sessions set bundle-to 3    # how many sessions tasks started together may use
deploys sessions set burst-min 10   # "together": created within this many minutes on one repository
deploys sessions set idle-min 60    # idle after this many minutes without activity
```

They are stored in `~/.config/deploys/sessions.json`.

## In the menu bar

The menu shows a line "Claude Code: 24 on this Mac · cloud: unknown" with a green or yellow dot. Below it a "Bundle
tasks" menu names each group started together ("shop: 6 started within 4 min – 3 at most") and lists the extras, then
the twins, the sessions in one folder and the idle ones; a click on one asks first and then ends it. Nothing is ended without that click. Off with Settings → General → "Show the Claude Code session count".

## For Claude Code

The MCP server has a read-only tool `deploys_sessions` with the same JSON, so a session can check the count before
it starts new ones. It cannot end a session.

## Where the figures come from

All read-only:

- `~/.claude/sessions/<pid>.json`: one small file per running Claude Code process (CLI and desktop app) with its
  session id, folder, title and state. Only the `.json` files are read, never the files next to them.
- `ps`: whether the pid is alive and a Claude process, and that it started before the session (so a pid that was
  reused by another process is not counted); CPU and RAM of the session and everything it started.
- `~/.claude/projects/*/<session id>.jsonl`: the transcript; its modification time is the last activity, its first
  time stamp when the task was created. Without a transcript the process start counts for both.

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
