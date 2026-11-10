# GitHub Action: deploy-center changed

Runs `deploys changed --json` on a Linux runner and gives you the result as outputs. It deploys
only when the workflow sets `deploy: true`, and then it runs `deploys deploy-changed --yes`.

```yaml
- uses: Pschmetzer/deploy-center/integrations/action@<tag or commit SHA>
  id: dc
  with:
    vercel-token: ${{ secrets.VERCEL_TOKEN }}
    render-api-key: ${{ secrets.RENDER_API_KEY }}
    repos-json: ${{ vars.DEPLOYS_REPOS_JSON }}   # your ~/.config/deploys/vercel-repos.json
    # deploy: true                               # only where a person asked for it
- env:   # outputs through env, never inside run: (a project name must not become shell code)
    COUNT: ${{ steps.dc.outputs.count }}
    NAMES: ${{ steps.dc.outputs.names }}
  run: echo "$COUNT waiting: $NAMES"
```

Pin the action to a release tag (`@v0.9.1`) or a full commit SHA, not to `main`: the action gets
your Vercel and Render tokens, and a branch runs whatever is pushed to it next. Dependabot or
Renovate can keep the tag current. Give the job a `timeout-minutes`: with a wrong Render key the CLI currently does not come back.

| Input | Default | |
|---|---|---|
| `deploy` | `false` | `true` starts the deploys. `dry-run` writes what would be deployed to the job summary and starts nothing. Any other value only reports. |
| `only` | none | Comma-separated names: only these projects count and deploy. |
| `exclude` | none | Comma-separated names to leave out, also of the deploy. |
| `vercel-token` | none | Read by the Vercel CLI (`VERCEL_TOKEN`). Leave it empty if you have no Vercel projects. |
| `vercel-team` | none | The team id, if the token sees several teams. |
| `render-api-key` | none | Leave it empty to skip Render. |
| `github-token` | `github.token` | Reads branch heads and pull requests. Other private repos need a token that can read them. |
| `repos-json` | none | The content of `vercel-repos.json`. Without it, Vercel projects whose Git connection is off are never counted. |
| `wait` | none | With `deploy: true`: follow each started build (`deploys watch`) until it is live or failed, at most this long (`20m`, `90s`, `1h`; a plain number is minutes; up to `6h`). A failed build fails the step. Without it, `deployed` only means "started". |
| `fail-on-risk` | none | `red` (or `yellow`): fail before anything is deployed when a project with changes has that risk or higher (migrations, lockfiles, config, size; see `deploys risk`). Empty only reports it. |
| `vercel-cli-version` | `65.12.1` | Installed only when no `vercel` is on the runner, into the runner's temp folder (no global install). |

| Output | |
|---|---|
| `count` | How many projects have changes. |
| `names` | Their names, comma-separated. |
| `projects` | The JSON array from `deploys changed --json`. |
| `started`, `failed` | How many deploys were started, and how many failed to start. |
| `deployed` | `true` when every start succeeded and every state could be read. Otherwise the step fails, after writing the outputs. |
| `risk`, `risky` | The highest risk of what waits (`green`, `yellow`, `red`; empty when nothing was compared), and the projects that are yellow or red. |
| `states` | With `wait`: JSON, project name to `ready`, `failed`, `timeout` or `unknown` (the platform could not be asked). |
| `failed-builds`, `live` | With `wait`: the projects whose build failed, and `true` when every build went live in time. |

As a gate on pull requests or before a scheduled deploy, `fail-on-risk: red` turns a red risk into
a failed check, so a migration or a lockfile change gets a look first. Cost estimates are not part
of the action.

Each step also writes a short summary to the job page. When some project's state cannot be read,
the step warns and leaves that project out. It is never counted as up to date.

The example [examples/deploy-on-marker.yml](examples/deploy-on-marker.yml) deploys only when the
last commit of a push says `[deploy]`, or when someone runs the workflow by hand and ticks the box.
For a time-based deploy, see [../../examples/daily-deploy.yml](../../examples/daily-deploy.yml).

Not tested yet: a run on GitHub's runners against real accounts. The steps' scripts are tested
locally with a stand-in `deploys` (`integrations/tests/run.sh`); see the table in
[../README.md](../README.md#what-is-tested-and-what-is-not).
