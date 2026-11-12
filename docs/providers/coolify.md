# Coolify

Coolify is off by default. Turn it on with:

```bash
deploys providers enable coolify
```

## Why it is worth it: no build storm on your VPS

On Vercel or Netlify, too many builds show up on a bill. On Coolify they show up on your own
server. Coolify builds on the same machine that runs your apps by default, unless you set up a
separate build server. A `docker build` of a Node or Next.js app takes one or two CPU cores and a
few GB of RAM for minutes.

With Auto Deploy on, every push to the branch queues a build. Five quick pushes are five builds
back to back. Your small VPS sits at 100% CPU for half an hour, response times go up for every
app on it, and the OOM killer may hit a database. Of those five builds, only the last one was
ever going to stay live.

With Auto Deploy off you build when you choose: once, at a quiet time, from the newest commit.

## How it works

Coolify has a real per-application switch for this, so nothing goes into your repo:

1. **`autodeploy-off`** sets the application's `is_auto_deploy_enabled` to false
   (`PATCH /api/v1/applications/{uuid}`). Coolify then ignores push webhooks for that app,
   from the GitHub App and from manual GitHub, GitLab, Bitbucket and Gitea webhooks. Deploy Center reads the setting back, so a Coolify that
   ignores the field is reported as an error, not as done. The value it found first is kept in
   `~/.config/deploys/coolify-off.json`, so `autodeploy-on` can put it back.
   PR preview deployments are a separate setting. If they are on, you get a note, and
   `autodeploy-off <app> --previews` turns them off too.
2. **Deploying** calls `POST /api/v1/deploy?uuid=<app>` and follows the deployment it returns.
3. **Deploying a commit** (`--sha`): `/deploy` has no commit field. A deployment takes the
   app's `git_commit_sha` setting at the moment it is queued. So Deploy Center pins that setting
   to your sha, queues the deploy, and sets it straight back to what it was (usually `HEAD`). If
   setting it back fails, you get a warning saying which value to restore under Configuration >
   Source.
4. **Rollback** (Coolify v4.3+) picks the newest finished production deployment before the
   live one that has a different commit, and calls `POST /api/v1/applications/{uuid}/rollback`.
   If that commit's image is still on the server, Coolify skips the build and only swaps the
   containers. The output says when that is the case.

## Setup

1. **API access.** In Coolify, open Settings > Advanced and turn on API access. Until then
   every call returns 403 "API is disabled".
2. **A token.** Create one under Keys & Tokens > API tokens. It needs these permissions:

   | Permission       | For                                   |
   |------------------|---------------------------------------|
   | `read`           | listing apps and deployments          |
   | `write`          | the Auto Deploy switch, `--sha`       |
   | `deploy`         | deploy, cancel, rollback              |
   | `read:sensitive` | build logs (optional)                 |

   A token limited to some projects cannot use `/applications` at all. Coolify answers 403 for
   that, so give the token team-wide scope.
3. **Tell Deploy Center where Coolify is, and store the token.** Each one is checked against
   your instance before it is saved:

   ```bash
   deploys coolify set-url https://coolify.example.com
   ```

   ```bash
   pbpaste | deploys coolify set-key
   ```

   `set-url` writes `{"url": "…"}` to `~/.config/deploys/coolify.json`. Instead, you can set
   `COOLIFY_URL` and `COOLIFY_TOKEN` in the environment, for CI or a server. The environment wins
   over the file and the keychain (service `deploy-center-coolify`). A trailing `/` or `/api/v1`
   on the URL is fine.
4. **Turn auto-deploy off** for each app:

   ```bash
   deploys coolify autodeploy-off <app>
   ```

   `<app>` is the app's name or its uuid. Coolify allows the same name in several projects. When
   a name is not unique, you are asked for the uuid instead.

## Commands

The names below assume the command layer from the providers-as-files PR (A1). In the
provider they are `coolify_off`, `coolify_deploy_json` and so on.

| Command | What it does |
|---|---|
| `deploys coolify list` | Every application with repo, branch, domain, last deployment and its phase |
| `deploys coolify autodeploy-off <app> [--previews]` | Auto Deploy off (and PR previews) |
| `deploys coolify autodeploy-on <app>` | Puts back what `autodeploy-off` found |
| `deploys coolify deploy <app> [--sha <commit>]` | Queue a deploy, optionally of one commit |
| `deploys coolify status <deployment>` | One deployment |
| `deploys coolify cancel <deployment>` | Cancel a queued or running deployment |
| `deploys coolify rollback <app>` | Back to the commit before the live one |
| `deploys coolify logs <app> [lines] [--id <deployment>]` | Build log (needs `read:sensitive`) |
| `deploys coolify logs <app> [lines] --runtime` | The running container's log |
| `deploys coolify url <app> [--dashboard]` | The app's first domain, or its page in Coolify |
| `deploys coolify doctor` | Instance, token source, whether it works, Coolify version |

## What the fields mean

- **phase**: `queued` ← queued, `building` ← in_progress, `ready` ← finished,
  `failed` ← failed, `canceled` ← cancelled-by-user. PR preview deployments are not counted
  as the app's last deployment.
- **lastSha / lastMsg** come from the newest *finished* production deployment, which is what
  is live. **lastAt / lastState / phase** come from the newest one of any status.
- **repo** is `owner/repo` for GitHub repositories, whether connected through the GitHub App
  or by URL. For GitLab, Bitbucket, Gitea and Docker-image apps it is empty. Those apps
  still deploy, but Deploy Center cannot compare them with the branch head, so they are not
  `deployable` in the "has new changes" sense.
- **auto** is false for Docker-image apps, because a push cannot start them.
- **paused** is always false: Coolify has no "suspended" state for applications.
- **dashboardUrl** is the app's page in Coolify, read from its newest deployment. It is
  empty for an app that was never deployed.

## Limits

- **One instance.** Deploy Center talks to one Coolify at a time. For a second one, use a
  separate shell with its own `COOLIFY_URL` and `COOLIFY_TOKEN`.
- **No preview deploys from here.** Coolify previews belong to a pull request. They are not
  a "deploy this branch somewhere else" target.
- **Services and databases** (one-click services, Compose stacks deployed as a Service) are not
  listed. Only Applications have the Auto Deploy setting and deployment history used here.
- **Self-signed certificates.** curl checks TLS. Point `CURL_CA_BUNDLE` at your CA, or use a
  real certificate. Plain `http://` is used only for this machine (localhost, 127.0.0.1,
  [::1]) or when you allow it on purpose, since the token then crosses the network unencrypted:
  `deploys coolify set-url http://10.0.0.5:8000 --allow-http` (kept for that address in
  coolify.json), or `DEPLOYS_COOLIFY_ALLOW_HTTP=1`. An `http://` instance saved before this
  change needs that once. `doctor` reports `"https": false`.
- Checked against Coolify's OpenAPI spec and API source at v4.7.3. Rollback needs v4.3 or
  newer. Cancel and the deployment list need v4.0.
