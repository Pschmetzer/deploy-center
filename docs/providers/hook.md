# Deploy hooks (any host with a build-trigger URL)

Many hosts give you a secret URL. A request to it starts a build. Some examples are Cloudflare Pages deploy hooks, Netlify build hooks, DigitalOcean App Platform, Coolify, Dokploy, Amplify incoming webhooks, and a CI's `workflow_dispatch`. The `hook` provider turns each such URL into a project that Deploy Center can deploy by hand.

It is opt-in. Nothing shows up until you add a hook.

## What it can and cannot do

| | |
|---|---|
| Deploy | yes: one request to the URL. It is never retried, because a retry could start a second build. |
| Status | **only "triggered"**. A hook has no status API behind it. A 2xx answer counts as `ready` with `lastState: "triggered"`. The build itself may still fail at the host, so watch it there. |
| Waiting commits | yes, when you give `--repo`. The commit that was the branch head at the last successful trigger is recorded. `deploys changed` then counts the commits added since. This needs `gh`. |
| Turn off auto-deploy | no. That is a setting at the host (see below). `deploys hook autodeploy-off` says so and stops. |
| Cancel, rollback, logs, preview, deploy a given sha | no |

## Commands

```bash
deploys providers enable hook
deploys hook add <name> <url|-> [--repo owner/name] [--ref main] [--site https://…] \
                 [--method POST] [--header 'Name: value'] [--body '{…}']
deploys hook remove <name>
deploys hook list
deploys hook deploy <name>
deploys hook set-key <name>      # replace the stored URL, read from stdin
deploys hook doctor              # JSON, URLs masked
```

The hook provider is off by default. Turn it on once with `deploys providers enable hook`; `providers/hook.sh` also runs on its own, with the same arguments.

`add` for a name that exists updates that hook: what you give changes, the rest (method, headers,
body, repo, ref, site) stays, and the answer names what was kept. Given headers are added to the
ones there; to drop one, `remove` the hook and add it again.

Pass `-` as the URL to read it from stdin. The URL then stays out of your shell history:

```bash
pbpaste | deploys hook add blog - --repo me/blog --site https://blog.example.com
```

## Secrets

- **The URL is a secret.** Anyone who has it can start builds. On a Mac it goes into the keychain as `deploy-center-hook-<name>`. Without a keychain (Linux) it goes into `~/.config/deploys/hook-urls/<name>`, mode 0600. `hooks.json` never holds it.
- **It is masked everywhere.** `list`, `doctor`, `json` and error messages show only `https://host/•••`. The URL reaches curl on stdin, never on its command line, so it does not show up in `ps`.
- **Header values are references, not secrets.** Write `--header 'Authorization: Bearer $GH_TOKEN'`. `$VAR` and `${VAR}` are read from the environment when the hook fires. Nothing else is expanded, and nothing is `eval`ed. If the variable is not set, the hook does not fire. A header that looks like a credential (Authorization, Token, Key, Secret, Password, Cookie) is refused unless it names a variable.
- `deploys hook remove` deletes the stored URL here. The URL still works at the host until you delete or rotate it there.

## Files

`~/.config/deploys/hooks.json`:

```json
[
  {"name": "blog", "method": "POST", "repo": "me/blog", "ref": "main", "site": "https://blog.example.com"},
  {"name": "ci", "method": "POST",
   "headers": {"Authorization": "Bearer $GH_DISPATCH", "Accept": "application/vnd.github+json"},
   "body": "{\"ref\":\"main\"}", "repo": "me/app", "ref": "main"}
]
```

`~/.config/deploys/hook-state.json` holds the last trigger of each hook: `{ok, http, at, sha, msg}`. After a failed trigger, it adds `error` and keeps the `sha` of the last good trigger.

## Examples

### Cloudflare Pages deploy hook

Go to Workers & Pages, then your project, then Settings, then Builds, then **Deploy hooks**. Add one for the production branch and copy the URL. It looks like `https://api.cloudflare.com/client/v4/pages/webhooks/deploy_hooks/<id>`.

```bash
pbpaste | deploys hook add site - --repo me/site --ref main --site https://site.pages.dev
```

To stop a build on every push, go to Settings, then Builds, then **Branch control**. Turn off automatic production deployments, and set preview deployments to "None" if you do not want those either.

### Coolify

In the resource, go to **Webhooks**. Copy the deploy webhook (`https://coolify.example.com/api/v1/deploy?uuid=<uuid>&force=false`). It needs an API token, which you create under Keys & Tokens, then API tokens.

```bash
export COOLIFY_TOKEN=…   # in your shell profile, not in the file
pbpaste | deploys hook add api - --method GET --header 'Authorization: Bearer $COOLIFY_TOKEN' \
  --repo me/api --site https://api.example.com
```

Turn **Auto Deploy** off in the resource's General / Advanced settings.

### DigitalOcean App Platform

App Platform has no anonymous hook. Its API endpoint for a new deployment works as one:

```bash
export DO_TOKEN=…
deploys hook add shop "https://api.digitalocean.com/v2/apps/<app-id>/deployments" \
  --header 'Authorization: Bearer $DO_TOKEN' --body '{"force_build":true}' \
  --repo me/shop --site https://shop.example.com
```

The app id is not secret here, but the provider still stores the URL like any other. To turn off building on push, go to the app's Settings, then the component, then Source, and untick **Autodeploy**.

### GitHub Actions `workflow_dispatch`

Use this when your deploy is a workflow with `on: workflow_dispatch`. Make a fine-grained token with *Actions: read and write* on the repo.

```bash
export GH_DISPATCH=github_pat_…
deploys hook add app "https://api.github.com/repos/me/app/actions/workflows/deploy.yml/dispatches" \
  --header 'Authorization: Bearer $GH_DISPATCH' --header 'Accept: application/vnd.github+json' \
  --body '{"ref":"main"}' --repo me/app --ref main
```

GitHub answers `204 No Content`, which counts as triggered. The run shows up in the repo's Actions tab.

### GitHub Pages and Surge (static sites)

GitHub Pages and Surge have no deploy hook of their own; a workflow builds and uploads the
site, so the dispatch above is the hook. Give the workflow only `on: workflow_dispatch` (no
`push:`), so a push builds nothing. For GitHub Pages this holds only with Settings → Pages →
Source set to **GitHub Actions**; with "Deploy from a branch", Pages builds every push anyway:

```yaml
on: workflow_dispatch
permissions: { contents: read, pages: write, id-token: write }
jobs:
  deploy:
    runs-on: ubuntu-latest
    environment: github-pages
    steps:
      - uses: actions/checkout@v4
      - run: npm ci && npm run build
      - uses: actions/upload-pages-artifact@v3
        with: { path: dist }
      - uses: actions/deploy-pages@v4
```

For Surge, the last two steps are `npx surge dist my-site.surge.sh` with `SURGE_TOKEN` from the
repo's secrets. Then add it as above, with `--site https://me.github.io/app` (or the surge.sh
address) so `deploys open` and the site check know where it lives.

### Netlify, Dokploy, Amplify, others

The pattern is the same: copy the hook URL, then `pbpaste | deploys hook add <name> - --repo … --site …`. Netlify's build hooks are under Site configuration, then Build & deploy, then **Build hooks**. Netlify stops building on push with **Stop builds**, under Build settings.
