# The deploy journal

Every deploy, rollback and cancel that Deploy Center starts is written to a journal on your Mac, one line each: time, platform, project, result and a detail. Error texts are masked before they are written. The journal never leaves the Mac.

Where it is: the app's journal file (on Linux, in the config folder); `DEPLOYS_JOURNAL` points the CLI at another file.

## Check it

```bash
deploys journal verify          # is the chain intact?
deploys journal verify --json
```

Each line holds the SHA-256 of the line before it (`prevHash`). A changed or removed line shows as a broken link, and the command exits with `1`. The first line is not checked, because the app shortens the file from the front.

## Export it

```bash
deploys journal export > journal.csv
deploys journal export --since 2026-11-01 --project my-shop > my-shop.csv
```

The CSV has the columns `at,platform,name,result,detail`. Text that a spreadsheet could read as a formula (starting with `=`, `+`, `-` or `@`) gets a `'` in front, so opening the file never runs anything.

## A monthly report

```bash
deploys journal report                   # this month
deploys journal report --month 2026-10   # another month
```

The report is Markdown: how many entries, a table of results and a table of projects with their entry counts. Without entries it says "Nothing in this month."; without a journal, "No journal yet."

See also [CLI.md](CLI.md) and [TEAM.md](TEAM.md) (`deploys team journal`).
