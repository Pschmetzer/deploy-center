# Deno Deploy in Deploy Center

Deno Deploy builds from its GitHub integration (or `deployctl` in your CI). Deploy Center shows the projects of one organization with their newest deployment and can **redeploy that deployment as production**. It never builds another commit and never uploads code.

## What you need

An organization access token from the Deno Deploy dashboard, and the id of that organization (the UUID in the dashboard address). The token must be able to read projects and deployments, and to redeploy.

Set the organization with `DENO_DEPLOY_ORG`, or `{"org":"<id>"}` in `~/.config/deploys/deno.json`.

## Turn it on

```bash
deploys providers enable deno
```

```bash
pbpaste | deploys deno set-key
```

`set-key` tries the token against the API first and saves it in the keychain (`deploy-center-deno`) only if Deno Deploy takes it. `DENO_DEPLOY_TOKEN` in the environment wins over the keychain. The token goes to curl on stdin, never as an argument.

## Turn push-deploys off

Not available. The Git integration is changed in the dashboard; `deploys deno autodeploy-off` says so and sends nothing.

## Deploy by hand

```bash
deploys deno deploy <project> --yes
```

This redeploys the newest deployment of the project as production. The deploy id is the new deployment; `deploys deno status <project> <deployment id>` follows it: `pending` counts as building, `success` as ready, `failed` as failed. `--sha`, `--preview`, `--no-cache`, cancel, rollback and logs are refused before anything is sent.

## Other commands

`deploys deno list`, `deploys deno latest <project>`, `deploys deno doctor`, `deploys deno url <project> [--dashboard]`.

## Limits and rate limits

The doctor reports `expiresAt` and `rateLimit` as `null`. Not checked against a live account: this provider was written from the API reference and tested with fixtures, so field names may need a small fix on first use. A project's "last change" is the creation time of its newest deployment.

## Undo

Nothing was changed on Deno Deploy except a redeploy. Revoke the token in the dashboard or remove the keychain item `deploy-center-deno`, and run `deploys providers disable deno`.
