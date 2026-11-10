# GitHub Action: deploy-center changed

Runs `deploys changed --json` on a Linux runner and gives you the result as outputs. It deploys
only when the workflow sets `deploy: true`, and then it runs `deploys deploy-changed --yes` for the
projects that deploy from **this** repository (input `repo`), not for every project the tokens can see.

```yaml
- uses: Pschmetzer/deploy-center/integrations/action@<tag or commit SHA>
  id: dc
  with:
    vercel-token: ${{ secrets.VERCEL_TOKEN }}
    render-api-key: ${{ secrets.RENDER_API_KEY }}
    repos-json: ${{ vars.DEPLOYS_REPOS_JSON }}   # your ~/.config/deploys/vercel-repos.json
    # deploy: true                               # only where a person asked for it
- run: echo "${{ steps.dc.outputs.count }} waiting: ${{ steps.dc.outputs.names }}"
```

Pin the action to a release tag or a full commit SHA, not to `main`. Give the job a `timeout-minutes`: with a wrong Render key the CLI currently does not come back.

| Input | Default | |
|---|---|---|
| `deploy` | `false` | `true` starts the deploys. Any other value only reports. |
| `repo` | `github.repository` | With `deploy: true`, only projects whose repo is this one are started (`owner/name`, or `host/group/name` for GitLab; case does not matter). From an "ops" repo, name the app repo here. `*` starts every changed project in every repo (what `deploy: true` did in 0.9.1 and earlier). |
| `vercel-token` | none | Read by the Vercel CLI (`VERCEL_TOKEN`). Leave it empty if you have no Vercel projects. |
| `vercel-team` | none | The team id, if the token sees several teams. |
| `render-api-key` | none | Leave it empty to skip Render. |
| `github-token` | `github.token` | Reads branch heads and pull requests. Other private repos need a token that can read them. |
| `repos-json` | none | The content of `vercel-repos.json`. Without it, Vercel projects whose Git connection is off are never counted. |
| `vercel-cli-version` | `65.12.1` | Installed only when no `vercel` is on the runner. |

| Output | |
|---|---|
| `count` | How many projects have changes. |
| `names` | Their names, comma-separated. |
| `projects` | The JSON array from `deploys changed --json`. |
| `started`, `failed` | How many deploys were started, and how many failed to start. |
| `deployed` | `true` when every start succeeded and every state could be read. Otherwise the step fails, after writing the outputs. |

The outputs `count`, `names` and `projects` still list every changed project the tokens see; only
the deploy is limited to `repo`. How: every other project goes into `ignored.json` of the run's own
config folder (in `RUNNER_TEMP`, gone after the job), and `deploy-changed --json` is asked first what
it would start. The step fails and starts nothing when the project list cannot be read, when a name
exists in this repo and in another one (deploying it would start both), or when anything outside
`repo` would still be started.

Each step also writes a short summary to the job page. When some project's state cannot be read,
the step warns and leaves that project out. It is never counted as up to date.

The example [examples/deploy-on-marker.yml](examples/deploy-on-marker.yml) deploys only when the
last commit of a push says `[deploy]`, or when someone runs the workflow by hand and ticks the box.
For a time-based deploy, see [../../examples/daily-deploy.yml](../../examples/daily-deploy.yml).

Not tested yet: a run on GitHub's runners against real accounts. The steps' scripts are tested
locally with a stand-in `deploys` (`integrations/tests/run.sh`).
