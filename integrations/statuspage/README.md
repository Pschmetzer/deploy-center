# Status page

A static "what shipped when" page for customers and teams. The script writes three files and
deploys nothing:

| File | What is in it |
|---|---|
| `index.html` | One file, no external assets. Light and dark, readable on a phone. |
| `feed.xml` | An Atom feed, one entry per deploy in the timeline. |
| `status.json` | The same data, for other tools. The page and the feed are made from it. |

```bash
cp integrations/statuspage/statuspage.example.json statuspage.json   # then edit it
integrations/statuspage/statuspage.sh                  # reads ./statuspage.json, writes ./public/
integrations/statuspage/statuspage.sh --config statuspage.json --out public --no-check --no-notes
```

## What the page shows

For each project in the config:

- **State and time** of the live deploy: Live, Deploying, Failed, or "Live · last deploy failed"
  (Render: the newest attempt failed and the one before is still live).
- **The live commit's message**, or only "Updated" (see `hideMessages`).
- **Coming next**: what is merged but not live yet, from `deploys notes <project>`. Read only for
  projects with changes. Authors are left out unless `showAuthors` is on.
- **Site check** (optional): with a `url`, the address is fetched once while the page is made.
  2xx and 3xx count as up, and 401/403 too (a login wall answers). At most 5 redirects, http(s) only. It is the result at that moment, not uptime over time.

Below that, **Recent deploys**: the last 30 that went live or failed, newest first, from the
app's journal. Skipped and cancelled deploys are left out. The journal's error text is never
published.

## The config: `statuspage.json`

```json
{
  "title": "Acme deploys",
  "description": "What shipped when.",
  "baseUrl": "https://status.example.com/",
  "projects": [
    "app-web",
    "render/worker",
    { "name": "api", "platform": "render", "label": "API", "url": "https://api.example.com/health" }
  ],
  "hideMessages": true,
  "showAuthors": false,
  "timeline": 30
}
```

| Key | Default | |
|---|---|---|
| `projects` | none | **The allowlist.** Only these are shown, in this order. A name, `platform/name`, or an object with `name`, `platform`, `label` (shown instead of the name) and `url` (the site check). Without it the script stops and writes nothing. |
| `title` | `Deploys` | Page and feed title. |
| `description` | empty | A line under the title. |
| `baseUrl` | empty | Where the page will live. Used for the feed's links and ids. Must be an `http(s)://` address. |
| `hideMessages` | `false` | `true` shows "Updated" instead of every commit message, in the page, the feed and `status.json`. The example config sets it to `true`: commit messages and the titles of waiting commits ("Coming next") are often not meant for the public. Set `false` only for a page you would show anyone. |
| `showAuthors` | `false` | Keep the author names that `deploys notes` adds. |
| `timeline` | `30` | How many deploys the timeline keeps. |
| `journal` | the app's | Path to a `journal.jsonl`. `DEPLOYS_JOURNAL` overrides it. |

What never leaves the script: projects not in the list, repos, commit SHAs, error texts, the
URLs of site checks. A project in the list that cannot be read shows as "Unknown".

## The journal

The Mac app writes every deploy that ended to
`~/Library/Application Support/app.deploycenter.mac/journal.jsonl` (one JSON object per line;
see `app/Journal.swift`). The `deploys` CLI alone does not write one. Without a journal the
timeline says "No deploys recorded yet." and the rest of the page still works.

## Publishing

The output is plain files, so any static host works. Make it on the Mac (where the journal is)
or in CI.

**GitHub Pages.** Copy [examples/statuspage-daily.yml](examples/statuspage-daily.yml) to
`.github/workflows/` in a repo with your `statuspage.json`, and set Settings > Pages > Source to
"GitHub Actions". It regenerates the page every day and on demand. It needs the same secrets as
the [Action](../action/): `VERCEL_TOKEN`, `RENDER_API_KEY`, and the variables `DEPLOYS_VERCEL_TEAM` and
`DEPLOYS_REPOS_JSON` (the content of `~/.config/deploys/vercel-repos.json`). For "Coming next"
from private repos, add a `DEPLOYS_GH_TOKEN` that can read them. CI has no journal: to get the
timeline there, commit a copy as `status/journal.jsonl`. From the Mac you can also push the
output to a `gh-pages` branch:

```bash
integrations/statuspage/statuspage.sh --out /tmp/status
cd /tmp/status && git init -q && git add . && git commit -qm status && git push -f git@github.com:you/status.git HEAD:gh-pages
```

**Netlify Drop.** Run the script, then drag the `public/` folder onto
<https://app.netlify.com/drop>. To update it, drag the folder onto the site's Deploys page again.

**Any static host.** Upload the three files: S3, Cloudflare Pages, a web server
(`rsync -a public/ host:/var/www/status/`). Nothing runs on the server.

To refresh it daily from the Mac, run the script from launchd or cron and then upload.

## Tests

`integrations/tests/run.sh` runs the script against a stand-in `deploys`, a stand-in `curl` and a
journal fixture, with no network. It checks the allowlist (nothing else leaks), `hideMessages`
(no commit text anywhere), the timeline limit and order, escaping, and that no journal detail,
SHA or repo is published. Not tested yet: a run against real accounts, and the example workflow on
GitHub.
