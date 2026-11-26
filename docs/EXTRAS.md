# Extra commands

Small commands that sit next to the big ones. Each lives in its own file, `lib/x-<name>.sh`, so `deploys` itself stays
small. `deploys more` lists them with one line each, `deploys more <command>` shows the usage of one. None of them starts a
build, a deploy or a rollback; the ones that write something (a backup file, a calendar file) say so and only write where
you point them.

German: [EXTRAS.de.md](EXTRAS.de.md)

```bash
deploys more                # every extra command, one line each
deploys more heatmap        # the usage of one
deploys more --json         # for scripts
```

## heatmap and trend: the journal as a picture

```bash
deploys heatmap                      # 12 weeks, Monday on top: · none, ░ few, ▒ some, ▓ many, █ most, ! a failure that day
deploys heatmap --weeks 26 --project web
deploys trend                        # one sparkline per project: deploys a day for 30 days, failures marked below
deploys trend web --days 14 --json
```

Counted as [`deploys digest`](CLI.md) counts, in UTC. Only the journal is read.

## handover and flaky

```bash
deploys handover                     # for the next person on duty: failing now, notes, counts, is the deploy window closed
deploys handover --hours 48 --json
deploys flaky                        # projects with 2 or more failures that passed again within 30 minutes (last 30 days)
deploys flaky --within 2h --min 1
```

`handover` asks no platform and no GitHub: it reads the journal (and `window.json`). "Failing now" means the project's newest
start or failure is a failure. Write a note with `deploys note <project> "text"` and it shows up in the handover.
`flaky` is a hint that a retry helped, not a verdict.

## besttime and slo

```bash
deploys besttime                     # the slots (weekday and hour, UTC) that went best, the ones that failed most, the next good one
deploys besttime --next              # only that: "Wed 11:00 (2026-12-02T11:00:00Z)"
deploys slo set 95                   # a goal: 95 % of the deploys of each project work (slo.json in the config folder)
deploys slo --days 30                # each project against it; exit 1 when one is below (a cron or CI gate)
deploys slo off
```

`besttime` reads your own journal only and does not know the deploy window: look at `deploys freeze` before you plan on a
slot. A slot needs `--min` (5) starts and failures to count. `slo` counts like `deploys digest`: starts against starts plus failures.

## calendar: the freezes in your calendar

```bash
deploys calendar                       # the closed times of the next 30 days as an .ics file on the terminal
deploys calendar --days 90 --out freezes.ics
```

One event "Deploys closed" per closed period of the "deny" rules of `window.json` (the reason, or "closed by the deploy window",
is its text). Times are the window's own local times, with its `tz` as the calendar's time zone when it has one.
[`deploys freeze import`](SAFE-DEPLOY.md) reads a calendar file the other way. Only the freezes are written, not the scheduled jobs.

## backup and restore: move your settings

```bash
deploys backup --out settings.json     # the settings files of the config folder in one file (mode 600)
deploys restore settings.json          # shows new / changed / same per file; writes nothing
deploys restore settings.json --yes    # writes; the files it replaces are kept in restore-backup-<time>/ first
```

In: window, rules, budget, prices, ignored, groups, guard, providers, clean, nightly, prepare, autofix limits, slo, checklists
and sessions (`.json`). Never in: the journal, caches, keys (keychain or environment), auto-deploy allowances (they end on
purpose, so restoring one would switch a safeguard off) and schedules (they belong to one machine). A file that is not valid
JSON, or looks like it holds a secret, is left out and named. `restore` refuses any file name that is not on that list, and `--yes`
is refused in observer mode.

## checklist and lint: your own points, your own files

```bash
deploys checklist add web "run the migration dry run"
deploys checklist add '*' "tell support before a Friday deploy"    # * = every project
deploys checklist web                                              # the points for web, then the ones for all
deploys checklist remove web 1
deploys lint                                                       # window, budget, slo, checklists and the rest: valid, and the right fields?
```

A checklist is a reminder: nothing waits for a tick and no deploy command reads it, so it cannot hold a deploy back or let one
through (use [rules and the deploy window](SAFE-DEPLOY.md) for that). `add` and `remove` change `checklists.json` and are refused
in observer mode; a point that looks like a secret is refused. `deploys lint` names the file, the rule and the problem
(`rule 2: "from" must be HH:MM`) and exits 1; `deploys doctor` checks tools and access, `lint` checks your files.

## changelog: release notes by kind

```bash
deploys changelog web                  # Markdown: Breaking changes, Features, Fixes, Performance, Documentation, ...
deploys changelog web --authors --format text
deploys changelog web --json
```

Reads the same commits as `deploys notes web --json` (what is merged but not live) and sorts them by the conventional-commit
prefix of the title (`feat:`, `fix(scope):`, `docs:` …). A `!` after the type, or "BREAKING CHANGE" in the title, puts a commit
under "Breaking changes". A title without a prefix goes under "Other"; dependency-bot commits are listed apart. Authors are left out
unless you ask. Nothing is written or deployed.

## outages: the list behind the median

```bash
deploys outages                        # every failure period of the last 90 days, longest first
deploys outages --project web --csv    # for a spreadsheet
```

An outage starts with the first failure after a start and ends with the next start of the same project; failures in a row are
one outage, and one with no start after it is "still failing". [`deploys recovery`](CLI.md) gives the median, this the list.

## Adding one

Put `lib/x-<name>.sh` next to `deploys`. It defines `x_<name>_main` (dashes in the name become underscores) and says what it
is in one header line: `# x-command: <name> | <what it does> | <usage>`. Its tests go to `tests/x/<name>.sh`; `tests/x-tests.sh`
runs them all.
