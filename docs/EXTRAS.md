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

## Adding one

Put `lib/x-<name>.sh` next to `deploys`. It defines `x_<name>_main` (dashes in the name become underscores) and says what it
is in one header line: `# x-command: <name> | <what it does> | <usage>`. Its tests go to `tests/x/<name>.sh`; `tests/x-tests.sh`
runs them all.
