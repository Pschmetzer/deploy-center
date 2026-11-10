# DigitalOcean App Platform

DigitalOcean App Platform is off by default. Turn it on with:

```bash
deploys providers enable digitalocean
```

> `deploys providers enable` comes with the provider-files change ("deploys: providers as
> files", A1). Until that is merged, `providers/digitalocean.sh` can be sourced and tested on
> its own: `bash tests/providers/digitalocean.sh`.

## Why it is worth it

App Platform builds and deploys an app every time you push to the branch it watches. Each
build uses build minutes, and every deploy restarts the app. Turning this off for each
component, and deploying when you choose, gives you one build per release instead of one
per push.

## How it works

Every component of an app (service, static site, worker, job, function) that is built from a
repo has its own **Autodeploy** switch. In the
[app spec](https://docs.digitalocean.com/products/app-platform/reference/app-spec/) that is
`deploy_on_push` on the component's `github`, `gitlab` or `bitbucket` source. For DOCR images
it is `image.deploy_on_push.enabled`.

The API cannot change a single switch. `PUT /v2/apps/{id}` takes the whole spec. So
`autodeploy-off`:

1. reads the app with `GET /v2/apps/{id}`,
2. sets `deploy_on_push` to `false` on every component and changes nothing else in the spec.
   The tests check this. Image sources are only touched where the flag is already there,
   because it is only valid for DOCR images,
3. saves the spec as it was in `~/.config/deploys/do-specs/<app-id>.json` (mode 0600, since the
   spec can hold plain environment values),
4. sends the spec back with `PUT /v2/apps/{id}` and `update_all_source_versions: false`, so
   the update does not fetch a newer commit,
5. checks the spec that comes back: if a component still deploys on push, it says which one.

If no component deploys on push, nothing is sent and the saved spec is kept as it is.

App Platform can start one deployment after a spec change, with the commit the app already
runs. This is how App Platform handles spec updates, not something Deploy Center starts. It
was not confirmed against a live account while this provider was written.

**Deploying** is `POST /v2/apps/{id}/deployments` with `force_build: false`. App Platform takes
the newest commit of each component's branch and reuses a cached build where it can.

## Setup

1. Create a personal access token at cloud.digitalocean.com > API > Tokens. Give it read and
   update scope for apps, or full access. Then store it. It is checked with `GET /v2/account`
   before it is saved:

   ```bash
   pbpaste | deploys digitalocean set-key
   ```

   You can set `DIGITALOCEAN_TOKEN` in the environment instead, for CI or a server. The
   environment wins over the keychain (service `deploy-center-digitalocean`). `doctl`'s
   `DIGITALOCEAN_ACCESS_TOKEN` is not read.

2. Turn auto-deploy off for an app. The app can be named by its name, its id or its domain:

   ```bash
   deploys digitalocean autodeploy-off <app>
   ```

3. Deploy when you want to:

   ```bash
   deploys digitalocean deploy <app>
   ```

## Phases

| App Platform | Deploy Center |
|---|---|
| `PENDING_BUILD`, `PENDING_DEPLOY`, `QUEUED`, `UNKNOWN` | queued |
| `BUILDING`, `DEPLOYING` | building |
| `ACTIVE` | ready |
| `ERROR` | failed |
| `CANCELED`, `SUPERSEDED` | canceled |

`QUEUED` is not in the current API reference, and `UNKNOWN` is: it is what a deployment shows
before App Platform gives it a phase. Both count as queued.

The list shows the newest deployment of each app (`GET /v2/apps/{id}/deployments`), so a
failed one shows up, not only the one that is live. The commit and the message ("commit
abc1234 pushed to …", "manual") come from the live deployment.

## What you can and cannot do

| | |
|---|---|
| Deploy | yes: the newest commit of each component's branch |
| Deploy a given commit (`--sha`) | no: the deployments API cannot choose a commit |
| Preview deploys | no: App Platform has no preview deploys |
| Cancel a deploy | yes: `POST /v2/apps/{id}/deployments/{dep}/cancel` |
| Roll back | yes: see below |
| Build log | yes: see below |

**Rollback** goes to the newest deployment that was live before the current one. Failed and
canceled ones are skipped. Each candidate is checked with `POST /v2/apps/{id}/rollback/validate`
first, and warnings such as "missing an image digest" are shown. The rollback is sent with
`skip_pin: true`, which commits it at once. A pinned rollback would block every new
deployment, including the next one from Deploy Center, until someone commits or reverts it
in the dashboard. You can name a deployment: `deploys digitalocean rollback <app> <deployment-id>`.

An app that is still pinned to an earlier rollback shows as paused. `deploy` refuses it and
points to the dashboard.

**Build logs**: for each component, `GET .../deployments/{dep}/components/{c}/logs?type=BUILD`
returns `historic_urls`, and Deploy Center downloads them. These are pre-signed links on
another host, so the token is never sent to them. A build that is still running has no
archive yet: Deploy Center says so and links the deployment in the dashboard. Use
`--component <name>` for one component and `--id <deployment>` for an older deployment.

## Undo

1. Turn auto-deploy back on with the flags as they were:

   ```bash
   deploys digitalocean autodeploy-on <app>
   ```

   This reads the saved spec and puts back only the `deploy_on_push` flags, matched by
   component. Everything else you changed since (env, sizes, domains) stays as it is now.
   Without a saved spec, turn it on per component in the app's Settings in the dashboard.

   `autodeploy-on` is `digitalocean_on` in the provider. The command name comes with the
   provider-files change (A1).
2. Optionally delete `~/.config/deploys/do-specs/<app-id>.json`.
3. To remove the token: `security delete-generic-password -s deploy-center-digitalocean`.
4. `deploys providers disable digitalocean` hides DigitalOcean again.

## Errors

| HTTP | What it means |
|---|---|
| 401 | The token is wrong, expired or revoked. Run `set-key` again, or check `DIGITALOCEAN_TOKEN`. |
| 403 | The token works but cannot do this: it needs update scope for apps. |
| 404 | The app or deployment is gone, or was renamed. |
| 429 | Rate limit. Retried twice after a short wait. A 429 means nothing was started, so this is safe for a deploy too. |

Reads that time out or get a 5xx are retried twice. A `POST` is never repeated, because one
that timed out may already have started a deployment.
