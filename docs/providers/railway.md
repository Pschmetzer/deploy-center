# Railway in Deploy Center

Railway deploys a service when its connected branch gets a push. Deploy Center lists your services with the state of their newest deployment, and can **redeploy** a service, cancel a running deployment, go back to an earlier one and read a build log. It cannot turn the push trigger off (that is a setting of the service in Railway) and never takes a commit.

## What you need

An **account** or **workspace** token (railway.com/account/tokens). A project token cannot list projects and is not used. Railway has one GraphQL endpoint, `backboard.railway.com/graphql/v2`.

One service in one environment is one item. The environment is `production` if the project has one, otherwise its first. The item's id is `<service id>:<environment id>`; its name is the service name, or `project/service` where two projects use the same name.

## Turn it on

```bash
deploys providers enable railway
```

```bash
pbpaste | deploys railway set-key
```

The token is tried first (`projects` query) and saved in the keychain (`deploy-center-railway`) only if Railway takes it. `RAILWAY_API_TOKEN` in the environment wins. The token goes to curl on stdin; queries carry their ids as GraphQL variables, never in the query text.

## Turn push-deploys off

Not available from here: `deploys railway autodeploy-off` is refused without a call. In Railway, disconnect the branch in the service settings.

## Deploy by hand

```bash
deploys railway deploy <service> --yes
```

This is Railway's redeploy of the service's newest deployment (the same source, built again). The new deployment is looked up a few times (`DEPLOYS_RAILWAY_POLLS`, default 5, 2 s apart); if it is not listed yet the answer has no id and says so, and `deploys railway latest <service>` shows it later. `--sha`, `--preview` and `--no-cache` are refused.

- `deploys railway cancel <service> <deployment id>` cancels a deployment that is queued or building.
- `deploys railway rollback <service>` goes back to the newest deployment after the live one that Railway still allows (`canRollback`).
- `deploys railway logs <service> 100 [deployment id]` prints the end of the build log.

## Other commands

`deploys railway list`, `latest`, `status <service> <deployment id>`, `url <service> [--dashboard]`, `doctor`.

## Limits and rate limits

Phases: `INITIALIZING`, `QUEUED`, `WAITING`, `NEEDS_APPROVAL` are queued; `BUILDING`, `DEPLOYING` building; `SUCCESS` ready; `FAILED`, `CRASHED` failed; `REMOVED`, `REMOVING`, `SKIPPED` canceled. A service's `lastSha` is shown only while its newest deployment is live. Every call is one POST that is never repeated, so a timeout is reported, not retried. A GraphQL error (HTTP 200 with `errors`) is reported with its first message. The doctor reports `expiresAt` and `rateLimit` as `null`. Not checked against a live account; the GraphQL field names follow Railway's public schema and are tested with fixtures.

## Undo

Redeploys and rollbacks are ordinary Railway deployments; roll forward by redeploying. Revoke the token at railway.com/account/tokens and delete the keychain item `deploy-center-railway`.
