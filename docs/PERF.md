# Performance guard

Running many Claude Code sessions on one Mac works until a dozen of them start `tsc`, `vitest` or `next build` at the
same moment: memory fills up, macOS swaps, and the whole Mac hangs. The performance guard shows how full the Mac is
and holds heavy commands until there is room. It is read-only by default: it never stops a live session.

German: [PERF.de.md](PERF.de.md)

## How full is the Mac?

```bash
deploys perf status          # level, reasons, biggest groups and processes
deploys perf status --json   # the same for scripts, the app and the MCP server (deploys_perf)
```

| Level | Means |
| --- | --- |
| green | Memory pressure normal, no swapping, load under one per core. Start anything. |
| yellow | Busy: pressure at "warn", some swapping, over 3 GB swap in use, load above the core count, or the cap of heavy checks reached. Heavy commands may still start if the gate lets them. |
| red | Overloaded: pressure critical, swap almost full and still growing, load over 4 per core, or under 10 % memory free. Heavy commands wait; after the wait they are refused. |

The signals: the kernel's memory pressure level (`kern.memorystatus_vm_pressure_level`), the swap-out rate (the
`Swapouts` counter of `vm_stat`, in MB per minute between two readings), free swap (`vm.swapusage`), load per core,
and how many heavy checks already run. The "free %" of `memory_pressure` counts inactive and compressible pages and
ignores swap, so it is only a side signal.

Groups: Claude Code sessions, the Claude app, MCP servers, checks and builds, dev servers, Xcode and Swift, Chrome,
Docker and VMs, other.

## The gate: heavy commands wait for room

```bash
deploys perf gate [--max-wait 10m] [--fail-open] [--quiet] -- npm run verify
deploys perf wait [--max-wait 10m] [--fail-open]      # the same, without a command
```

A heavy command starts when all of these hold:

- memory pressure is normal, or at "warn" with a swap-out rate under 20 MB/min and at least 2 GB swap free;
- load is under 1 per core, now or over the last five minutes (a short spike from one build does not hold the next);
- fewer heavy checks run than the cap (`max(2, cores / 4)`);
- the last start through the gate was at least 20 s ago (so the new process shows up before the next one starts).

It polls every 10 s and prints one status line a minute. After `--max-wait` a yellow Mac starts the command anyway; a
red one does not (exit 75) unless `--fail-open` is given. Any error of the guard itself lets the command run.

### Claude Code hook

`integrations/claude-code/hooks/perf-gate.sh` is a `PreToolUse` hook for the Bash tool. It recognises heavy commands
(`tsc`, `vitest`, `jest`, `eslint`, `playwright`, `next build`, `npm|pnpm|yarn|bun run verify|test|build|typecheck|lint`,
`xcodebuild`, `swift build`, `docker build`, `./build.sh`) only as commands of their own, so `grep tsc` passes. Light
commands pass at once without starting anything. A heavy one waits through `deploys perf wait` (up to 10 minutes);
when the Mac stays red the command is not started, and Claude is told to wait or use a cloud session.
`DEPLOYS_PERF_GATE=0` turns it off for one session.

```bash
deploys perf hook    # prints the entry for ~/.claude/settings.json; nothing is changed
```

Copy the script to `~/.claude/hooks/perf-gate.sh` and add the printed entry under `hooks.PreToolUse`. The hook
timeout is 660 s, above the 10-minute wait.

## Cleanup and notifications

```bash
deploys perf clean            # dry run: lists orphaned dev processes
deploys perf clean --yes      # stops them (TERM, then KILL after 10 s)
deploys perf install --yes    # launchd agent every minute (report only)
deploys perf install --clean --yes   # ... and let it stop orphans every 10 minutes
deploys perf uninstall
```

Orphaned means, for processes of your user only:

- **A**: a short-lived check (`tsc`, `vitest`, a jest worker, `eslint`, `playwright`, `next build`) whose parent is
  launchd, older than 30 minutes: its session or terminal is gone.
- **B**: a node process, check or dev server whose working folder is inside a `.claude/worktrees/<name>` folder that no
  longer exists, older than 10 minutes, with no live Claude Code session above it.

Never stopped: processes launchd runs as a job, anything listening on a TCP port, Claude, Docker, databases, Chrome
and Xcode. Before the KILL the start time and command line are checked again, so a reused process id is left alone.

The agent writes `~/.config/deploys/perf/status.json` (the app and the menu bar read it), keeps samples for the
swap rate, logs to `~/.config/deploys/perf/clean.log`, and sends a macOS notification naming the biggest consumers
when the Mac has been red for 5 minutes (at most every 30 minutes).

Two more rules: **P**, a test browser (Playwright's, Chrome for Testing, chrome-headless-shell) whose parent is
launchd, older than 30 minutes, stopped with its process group; **C**, a dev server (`next dev`, `vite`) started
without a terminal, older than 2 hours, with no Claude Code session above it or in its folder: listed, and stopped only
with `--dev`. Your own Chrome (`/Applications/Google Chrome.app`) is never touched.

## Hung and orphaned processes (reap)

Everything that costs memory belongs to a class with one rule. `deploys perf reap` lists what hangs or is orphaned
(a dry run), `--all` every member with its class and verdict, `--yes` stops what may be stopped, `--pid N --yes` one
tree of any verdict (what the app's menu item does). `deploys perf install --reap --yes` lets the agent do the `--yes`
part every 5 minutes, with a notification ("stopped 3 process trees, about 2.1 GB RSS").

| Class | What | Stopped on its own (after `install --reap`) | Only reported (stop by click or `--pid`) |
| --- | --- | --- | --- |
| check | `npm run lint/typecheck/test/verify/build`, `npm exec tsc`, `eslint`, `tsc`, `vitest run`, `jest`, `playwright test`, `next build` | **hang**: older than 45 min without CPU progress for 15 min (and over 500 MB), or older than 90 min; **orphan**: its session is gone (parent launchd) for 10 min | |
| testbrowser | Playwright's browsers, Chrome for Testing, headless shell | **orphan** after 30 min | no CPU progress for an hour (not `--headed`, `--ui`) |
| mcp | MCP servers | **orphan** after 10 min | |
| npmexec | other `npm exec` / `npx` runs | **orphan** after 30 min | |
| devserver | `next dev`, `vite`, `webpack-dev`, `nodemon`, checks in watch mode | | **useless**: no terminal, no Claude Code session above it or in its folder for 2 h |

The topmost process of a tree counts, with everything below it; the tree gets SIGTERM, survivors SIGKILL after 10 s
(only when start time and command line are unchanged). Hang limits shrink with pressure (yellow x0.6, red x0.35, never
under 15 min for checks); the orphan waits never shrink. `reap.perCommand` sets the hard limit per command
(`{"playwright": 120, "verify": 60}`). A session that is only quiet is never a reason to stop its MCP servers.
Never touched: Claude, your Chrome, databases, Docker, launchd jobs, a stopped process (state T), anything under an
editor (VS Code, Cursor, Xcode) or a debugger, and deploys itself. Each stop is logged with class, reason, folder,
command, run time and memory in `~/.config/deploys/perf/clean.log`.

## Docker, simulators and caches

```bash
deploys perf consumers [--json]      # Docker stacks, booted simulators, cache sizes
deploys perf docker [--json]         # the Docker stacks: running, RAM, CPU, in use or idle
deploys perf stop <stack> --yes      # docker stop of its containers (Supabase: the db last)
deploys perf wake <stack>            # docker start again (Supabase: the db first)
deploys perf stop simulators --yes   # shut down booted simulators, unless Xcode or Simulator.app runs
```

A stack is a compose project, a Supabase CLI project or a single container. Only `docker stop` and `docker start`:
containers, volumes and data always stay. A stack is "in use" while a TCP connection to one of its ports is open, its
CPU is over 1 %, or a Claude Code session works in its compose folder.

Idle stop is off by default. `deploys perf install --docker --yes` (or `"docker": {"autoStop": true}` in perf.json)
lets the agent stop a stack that was not in use for 2 hours (1 hour when the Mac is yellow, 30 minutes when red), with
a notification; `deploys perf wake <stack>` starts it again. Stacks in `"docker": {"always": [...]}` are never
stopped. Note: the Docker VM gives freed memory back to macOS slowly, so Docker Desktop's own Resource Saver (it
stops the VM when no container runs) and a lower memory limit in Docker's settings often help more.

Caches (npm, Playwright browsers, Xcode DerivedData, simulator caches, `~/.cache`) are measured once a day with low
priority and only reported, never deleted.

## Shedding load under memory pressure

```bash
deploys perf shed              # what it would stop now (dry run)
deploys perf shed --yes        # stop them, only while memory is tight
deploys perf install --clean --shed --yes   # let the agent do it (off by default)
```

When memory is tight (pressure at "warn", swapping, under 10 % memory or under 2 GB swap free; load alone does not
count, a sleeping dev server costs no CPU) the agent stops, at most every 5 minutes and at most `shed.maxPerRun` (3)
at a time, biggest first, dev servers (`next dev`, `vite`, `webpack-dev`, `nodemon`, with everything they started)
that nobody uses any more. The folder decides, by the most specific Claude desktop session folder that holds it
(read-only, as `deploys desktop-sessions` reads them):

| Rule S | Stopped when |
| --- | --- |
| archived | every session with that folder is archived |
| done | every session with that folder is archived or done, and no client was connected to its port for `shed.idleMin` (30) minutes |
| idle | no client for 30 minutes, no Claude Code process above it, no terminal, and no open session with that folder |

"No client" means no open TCP connection on the server's side of one of its listening ports; the agent looks every
minute. A server that comes back after a stop (same folder and command) is left alone for 24 hours. With shedding on,
the Docker idle stop below also runs under memory pressure, for stacks without a database container (Postgres,
Supabase, Redis, MySQL, Mongo ...). Every stop sends a notification, goes to the journal and to
`~/.config/deploys/perf/clean.log`; TERM first, KILL after 10 s. Never stopped: Claude, Chrome, databases, launchd
jobs, anything under an editor or a debugger. `deploys perf clean` lists the same servers as rule S, but never stops
them.

### Dev servers of finished work

```bash
deploys perf finished          # what it would stop (dry run)
deploys perf install --clean --shed --stop-finished --yes   # the agent does it every 5 minutes
```

At any load, not only under pressure: a dev server (the same ones as rule S) whose folder belongs to a desktop session
that is archived or done (and to no open one), or, without a session, whose branch's pull request is merged or closed
(`gh`, at most 5 look-ups a pass, cached for an hour), is stopped once it stayed so for `stopFinished.graceMin` (10)
minutes. TERM, KILL after 10 s, a notification and a journal entry; one that comes back is left alone for 24 hours.

### MCP servers

```bash
deploys perf mcp [--days 7] [--json]
```

Every Claude Code session starts its own MCP servers, so 20 sessions run 20 copies of each. This groups them by name
(processes, memory, in how many sessions), counts their tool calls in the last days in the session transcripts
(`~/.claude/projects/*/*.jsonl`, read-only, cached per file in `perf/mcp-usage.tsv`) per project (a worktree counts
as its repo) and reads only the server names in `~/.claude.json` (global or per project, never a command or env
value). The suggestion: off where it had no call at all, off in the projects that never used it, or only in the
projects that use it instead of everywhere. Nothing is changed: turning a server off is yours (`claude mcp remove`,
the plugin or connector settings, a project's `.mcp.json`). The Mac app shows the same in the performance panel.

### Quitting apps

Settings → General → "Quit apps I picked when the Mac is overloaded" (off by default) lists the running apps with
their memory and a "Not needed?" suggestion (everything running except Chrome and the never list) to pick with one
click; the list is `"quitApps": {"enabled", "apps": [bundle ids], "idleMin": 30, "helpers": false}` in `perf.json`.
Deploy Center itself does it, so it has to run: only when the Mac is red with memory pressure for 5 minutes and a
shedding pass had 90 s to work, one app at a time (at most one every 2 minutes), biggest first, only apps in the
background that were not active for `idleMin` minutes. Only like ⌘Q (`terminate`), never forced: an app with unsaved
documents asks and stays open, and is left alone until the pressure is over. With `helpers`, windowless helper
processes inside the quit app's bundle get a TERM (never login items, XPC services, launchd jobs or system services,
nothing with sudo). Each quit sends a notification with the app's name and the memory it held and goes to the journal.
Never quit, whatever the file says: Claude, Terminal, iTerm, Xcode, the Simulator, Finder, Deploy Center.
`deploys perf clean` shows which apps would be quit now (from `perf/quit-plan.json`, which the app writes).

### Lower priority for heavy checks

`deploys perf gate` starts the command through `taskpolicy -b` (background QoS: efficiency cores, low disk priority,
no admin needed) while the Mac is yellow or red. `"lowPriority": "always"` does it always, `false` never. The Claude
Code hook only waits: changing the command it runs would need `updatedInput` with `permissionDecision: "allow"`,
which skips your permission rules.

Shedding helps a Mac over a peak. It is no answer to a Mac that is full all day: then fewer local sessions, and more
work in cloud sessions, are.

## Settings

`~/.config/deploys/perf.json`, every key optional:

```json
{
  "maxLoadPerCore": 1.0, "redLoadPerCore": 4, "maxSwapUsedMB": 3072,
  "maxSwapoutMBPerMin": 20, "redSwapoutMBPerMin": 50,
  "minSwapFreeMB": 2048, "redSwapFreeMB": 1536,
  "maxChecks": 0, "maxWait": "10m", "stagger": 20, "pollEvery": 10,
  "clean": false, "lowPriority": "busy", "notifyAfterMin": 5, "notifyEveryMin": 30,
  "reap": { "enabled": false, "limitMin": 45, "hardLimitMin": 90, "stallMin": 15, "stallMB": 500,
            "devserverIdleMin": 120, "perCommand": { "playwright": 120 } },
  "shed": { "enabled": false, "idleMin": 30, "maxPerRun": 3 },
  "stopFinished": { "enabled": false, "graceMin": 10 },
  "quitApps": { "enabled": false, "apps": [], "idleMin": 30, "helpers": false },
  "docker": { "autoStop": false, "always": [], "idleMin": 120, "idleMinYellow": 60, "idleMinRed": 30 }
}
```

`maxChecks: 0` means `max(2, cores / 4)`. `maxSwapUsedMB`: swap in use at or over it makes the level yellow, but does
not hold heavy commands (macOS keeps swap in use for hours after the pressure is gone; the swap rate and free swap
hold them).

## The app

The menu bar icon gets a green, yellow or red dot, and the menu shows the reason, the three biggest groups, the
number of Claude Code sessions and heavy checks, and whether a heavy check may start now. Settings → General →
"Show how full the Mac is" turns it off. Under "Docker" each running stack has a Stop item and each stack the guard
stopped has a Wake item; under "Processes" the hung, orphaned and unused trees come first, then the biggest others, each
with class, run time, memory and a Stop item. Nothing happens without that click.
