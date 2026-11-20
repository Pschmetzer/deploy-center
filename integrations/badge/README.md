# Status badges

The script writes one SVG per project into a folder:

```bash
integrations/badge/badge.sh badges/                  # read every project through deploys
deploys vercel list --json > v.json && integrations/badge/badge.sh badges/ v.json
```

A badge reads, for example, `deployed | 2027-01-05 · 4 commits waiting` (the date of the live deploy, UTC: the file is read long after it was written). It is green when the project
is up to date, yellow when commits are waiting, red when the newest build failed, blue while one
is building, and grey when the project was never deployed.
The age is that of the commit that is live. On Render, a newer failed attempt does not reset it.

Next to every `<name>.svg` goes `<name>.json`, a [shields.io endpoint](https://shields.io/badges/endpoint-badge) (`schemaVersion` 1: label, message, colour). Serve it from any static host and a README can show the badge live: `https://img.shields.io/endpoint?url=<address of the JSON>`.

There is no server. Commit the SVGs, put them on any static host, or open them locally. To keep
the badges current, run the script on a schedule: launchd on a Mac, or a CI job with the Docker
image. Projects left out with `deploys ignore` still get a badge. Filter the list first if you
don't want one for them.

## Badges about the whole period

[`stats.sh`](stats.sh) writes three more badges, not one per project: the **failure rate**, the **estimated saving** and the
**time of the last deploy**. Each is an SVG with a shields.io endpoint JSON next to it, like the ones above.

```bash
integrations/badge/stats.sh badges/                  # the last 30 days: failure-rate, savings, last-deploy
integrations/badge/stats.sh badges/ --days 7         # another period (1 to 365)
integrations/badge/stats.sh badges/ --project web    # the failure rate of one project only
integrations/badge/stats.sh badges/ --no-savings     # leave the savings badge out (it asks GitHub through deploys ledger)
integrations/badge/stats.sh badges/ --digest d.json --list l.json   # saved JSON instead of the CLI
```

| Badge | Reads, for example | Colours |
|---|---|---|
| `failure-rate` | `failure rate \| 10 % (1 of 10, 30 d)` | green up to 5 %, yellow up to 15 %, red above (`isError` for shields.io), grey with no deploy in the period |
| `savings` | `saved (estimate) \| ~$12.40 saved` (or `42 builds skipped` when no price is set) | green with a saving, grey when none or unknown |
| `last-deploy` | `last deploy \| 2027-01-05 14:32 UTC` | green up to 7 days, yellow up to 30, grey older or never |

The failure rate is failed / (deploys + failed) from `deploys digest --json`. The saving is the estimate of `deploys ledger`:
builds that did not run since auto-deploy went off, not only in the period. The last deploy is the newest live time
over all projects, as a date in UTC, because the file is read long after it was written. If the CLI gives no digest, nothing is
written and the exit code is 1. Nothing is deployed; the files go to any static host, as above.
