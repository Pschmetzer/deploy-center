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
