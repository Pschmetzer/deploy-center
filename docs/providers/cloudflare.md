# Cloudflare Pages

Opt-in provider. `deploys` lists Cloudflare Pages projects once it has a token; until then it
leaves Cloudflare alone.

## What it saves you: quota, not dollars

Cloudflare does not charge per build. Pages plans have a **build count limit**: 500 builds a month
on Free, more on paid plans, and only one build (Free) or a few at a time. Each git push to a
connected repository uses one build, and so does each preview branch push. With push-deploys off and
a deploy by hand once a day you use roughly 30 builds a month instead of one per push, and builds
stop queueing behind each other. Pushing more often does not cost more money, but it does use up
the quota.

## Setup

1. Create an API token at **dash.cloudflare.com > My Profile > API Tokens > Create Token**. Use the
   "Edit Cloudflare Pages" template, or a custom token with **Account > Cloudflare Pages > Edit**
   for the account that holds your projects.
2. Store it in the keychain (it is checked first and saved only if Cloudflare says it is active):

   ```bash
   pbpaste | deploys cloudflare set-key
   ```

   Or, on a server or in CI, set `CLOUDFLARE_API_TOKEN` in the environment instead.
3. The account is found automatically when the token sees exactly one. With several, choose one:

   ```bash
   deploys cloudflare account <account-id>
   ```

   `CLOUDFLARE_ACCOUNT_ID` in the environment wins over the remembered one
   (`~/.config/deploys/cloudflare.json`).
4. Check it:

   ```bash
   deploys cloudflare doctor
   ```

## Turning push-deploys off

```bash
deploys cloudflare off <project>
```

This sets both of the project's Git switches off: **production deployments** and **preview
deployments** (to "none"). It reads the whole `source.config` first and sends it back with only those
two values changed, because Cloudflare does not document whether a partial update keeps the other
settings. What the two switches were before is written to `~/.config/deploys/cloudflare.json`, only
the first time.

Projects made by direct upload (wrangler) have no Git connection; pushes never build them, and
`deploys` says so instead of changing anything.

## The self-test (once per project)

Cloudflare does not document whether "create deployment" builds while production deployments are
off. It may build, or it may create a deployment that is **skipped**
(`skip_reason: production_deployments_disabled`). Until that is known for your account, production
projects with push-deploys off are shown as not deployable, `doctor` reports `"deployWhileOff":
"unverified"`, and `deploy` refuses.

Find out with one real build:

```bash
deploys cloudflare off <project>
deploys cloudflare selftest <project> --yes
```

Without `--yes` it only explains what it would do. With it, it starts one production deployment of
the production branch and watches it for up to three minutes.

- **Passed:** the deployment reached the `build` stage with a commit hash. This is remembered for
  that project, for 30 days (`DEPLOYS_CLOUDFLARE_SELFTEST_TTL`, in seconds), and its deploys work
  until then. A test of one project does not count for another: each has its own Git provider,
  plan or account. `doctor` says `verified` and lists every project's result in `selftests`.
- **Skipped:** Cloudflare refused to build while push-deploys are off. `doctor` says `failed`, and a
  deploy needs the toggle fallback below.
- **Inconclusive:** the build failed or stopped before the build stage (a broken project, a slow
  queue). Nothing is recorded; fix the project and run it again.

The test uses one build of your quota.

## Deploying

```bash
deploys cloudflare deploy <project>                         # newest commit of the production branch
deploys cloudflare deploy <project> --preview --branch dev  # a preview of another branch
```

Cloudflare builds the newest commit of a branch; it cannot build a given commit, so `--sha` is not
offered.

### The toggle fallback (opt-in)

If Cloudflare skips the build, nothing is built and `deploys` says so. To build anyway:

```bash
deploys cloudflare deploy <project> --toggle
```

or set `DEPLOYS_CLOUDFLARE_TOGGLE=1` to allow it for every deploy. Then `deploys`:

1. turns the one switch that blocked the build on (production deployments, or previews for a preview),
2. starts the deployment,
3. turns the switch back to exactly what it was, even if step 2 failed.

**The race window:** between steps 1 and 3, usually two or three seconds, the project deploys on
push again. A push to that branch that lands in those seconds starts its own build too, and uses
another build of your quota. Nothing else changes. If step 3 fails (the network drops), `deploys`
says so; run `deploys cloudflare off <project>` to close it.

## Other commands

| Command | What it does |
| --- | --- |
| `deploys cloudflare list` | projects, whether a push still builds them, and the newest deployment |
| `deploys cloudflare status <project> [<id>]` | one deployment (the newest without an id) |
| `deploys cloudflare logs <project> [lines] [<id>]` | the end of the build log |
| `deploys cloudflare rollback <project> [<id>]` | production back to the newest good deployment before the live one, or to `<id>` |
| `deploys cloudflare url <project> [--dashboard]` | the site (a custom domain over `*.pages.dev`), or its dashboard page |

Phases: `queued` (the queue stage), `building` (initialize, clone, build, or deploy still running),
`ready` (deploy stage succeeded), `failed`, `canceled` (also a skipped deployment). Cloudflare has
no documented way to cancel a deployment, so cancel is not offered; stop one in the dashboard.

## Undo

Turn push-deploys back on, with the values they had before `off`:

```bash
deploys cloudflare on <project>
```

(Both on, previews "all", if nothing was remembered.) The same is possible in the dashboard:
**Workers & Pages > project > Settings > Builds & deployments > Configure Production deployments /
Preview deployments**.

Remove the token and what was remembered:

```bash
security delete-generic-password -s deploy-center-cloudflare
```

```bash
rm ~/.config/deploys/cloudflare.json
```

Delete the API token itself at **My Profile > API Tokens**.
