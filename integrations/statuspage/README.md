# Status page

A static "what shipped when" page for customers and teams. The script writes four files and
deploys nothing:

| File | What is in it |
|---|---|
| `index.html` | One file, no external assets. Light and dark, readable on a phone. |
| `feed.xml` | An Atom feed: one entry per deploy in the timeline, per outage and per maintenance window. |
| `feed.json` | The same entries as a [JSON Feed](https://jsonfeed.org/version/1.1) 1.1, with the same ids. |
| `status.json` | The same data, for other tools. The page and the feed are made from it. It has `schema: 1`; a tool that reads it can tell when the format changes. |

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

## Components and maintenance windows

A project can list **components**: parts that are checked on their own, each with its own address.

```json
{ "name": "app-web", "label": "Website", "components": [
    { "name": "Pages", "url": "https://www.example.com/" },
    { "name": "Login", "url": "https://login.example.com/health" } ] }
```

The card lists each component with "Site up · HTTP 200" or "Site not reachable". The `url` of the project itself still
works beside them. The components share the time budget (`STATUSPAGE_CHECK_BUDGET`) of the site checks.

**Maintenance windows** are planned, so a failed check inside one is not an outage:

```json
"maintenance": [
  { "id": "db-upgrade", "title": "Database upgrade", "start": "2027-01-10T22:00:00Z", "end": "2027-01-11T00:00:00Z",
    "note": "Read-only for a short while.", "projects": ["API"] }
]
```

`start` and `end` are UTC times like `2027-01-10T22:00:00Z`; the end must be after the start. `projects` lists the names
or labels it concerns (empty: all of them). `id` may hold letters, digits and `. _ -`; without one it is made from
the title and the start day, so give it one if you may change the title. A window is **scheduled** until it starts,
**active** until it ends, then **completed** and stays on the page for a week. While one is active, the projects it
concerns say "Maintenance", and a site that does not answer says "Not reachable during planned maintenance"; it is not a
feed entry as an outage. The page is made when the job runs, so run it at the start and the end of a window (or every
hour) for the state to change on time. `status.json` has `maintenance` (the windows) and, per project, `maintenance`
(true while a window concerns it) and `components`; `schema` stays 1, as these are additions.

## The feeds and their ids

`feed.xml` and `feed.json` are made from one list, so a reader sees each entry once, whatever the format:

| Entry | Id |
|---|---|
| A deploy | `urn:deploy-center:<platform>:<name>:<time>` |
| A site that is down | `urn:deploy-center:check:<platform>:<name>`, and `…:<component>` for a component. No date: an outage that lasts is one entry, not a new one for every daily run. |
| A maintenance window | `urn:deploy-center:maintenance:<id>`. It keeps its id when it changes from scheduled to active to completed; its `updated` time changes. |

The name in an id is the project's `label` when you set one: changing a label changes its ids once. The feeds link to
`baseUrl` (the JSON feed's `feed_url` is `<baseUrl>feed.json`) and carry no commit text.

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
| `maintenance` | none | Planned windows (see above): `title`, `start`, `end`, and optionally `id`, `note`, `projects`. |
| `title` | `Deploys` | Page and feed title. |
| `description` | empty | A line under the title. |
| `baseUrl` | empty | Where the page will live. Used for the feed's links and ids. Must be an `http(s)://` address. |
| `strict` | `false` | `true` is the setting for a page anyone may see: it implies `hideMessages`, moves the page's script into `status.js` (no inline script, so a `script-src 'self'` policy holds; the page carries one as a meta tag) and adds `noindex`. Off by default, so existing pages do not change. |
| `texts` | none | Your own wording for any text of the page: `{"recent": "History", "noDeploys": "Nothing yet."}` replaces the text of the chosen `lang` under that key. Plain strings only. |
| `hideMessages` | `false` | `true` shows "Updated" instead of every commit message, in the page, the feed and `status.json`. The example config sets it to `true`: commit messages and the titles of waiting commits ("Coming next") are often not meant for the public. Set `false` only for a page you would show anyone. |
| `showAuthors` | `false` | Keep the author names that `deploys notes` adds. |
| `timeline` | `30` | How many deploys the timeline keeps. |
| `timelinePerProject` | `10` | At most this many of them per project, so one busy project does not push the others out of the list. |
| `lang` | `en` | `en` or `de`: the page's texts, the feed's titles and "Updated" in `status.json`. |
| `staleHours` | `48` | When the page is older than this (the job that makes it may have stopped), a red line on the page says how old it is. Needs scripts in the browser. |
| `journal` | the app's | Path to a `journal.jsonl`. `DEPLOYS_JOURNAL` overrides it. Without a journal (in CI, on another machine) the timeline comes from each platform's history, when the CLI has `deploys history --json`. |

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

**Any static host.** Upload the files: S3, Cloudflare Pages, a web server
(`rsync -a public/ host:/var/www/status/`). Nothing runs on the server.

To refresh it daily from the Mac, run the script from launchd or cron and then upload.

## Tests

`integrations/tests/run.sh` runs the script against a stand-in `deploys`, a stand-in `curl` and a
journal fixture, with no network. `integrations/tests/ops.sh` adds the components, the windows (scheduled, active,
completed, bad configs), the ids of both feeds and German texts, with a fixed clock (`STATUSPAGE_NOW`). It checks the allowlist (nothing else leaks), `hideMessages`
(no commit text anywhere), the timeline limit and order, escaping, and that no journal detail,
SHA or repo is published. Not tested yet: a run against real accounts, and the example workflow on
GitHub.
All add-ons at a glance: [what is tested](../README.md#what-is-tested-and-what-is-not).
## Settings

`STATUSPAGE_RETRY_WAIT` (seconds, default 2) is the pause before the second try of a site check. The site checks send the user agent `deploy-center-statuspage`, so a site's owner can tell and allow them. The journal is read from `DEPLOYS_JOURNAL`, else the app's folder on a Mac and `$DEPLOYS_CONFIG/journal.jsonl` elsewhere (as the CLI writes it).
