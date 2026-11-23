# Northflank in Deploy Center

Northflank builds combined services from Git. Deploy Center shows the services of all your projects with the state of their newest build and can **start a build** of a service's branch, or of a given commit. It never uploads code. A service that only runs an image has no build: it is listed, not deployable.

## What you need

A Northflank API token (team settings, API) with the rights to read projects, services and builds and to start a build.

## Turn it on

```bash
deploys providers enable northflank
```

```bash
pbpaste | deploys northflank set-key
```

`set-key` tries the token against the API first and saves it in the keychain (`deploy-center-northflank`) only if Northflank takes it. `NORTHFLANK_TOKEN` in the environment wins over the keychain. The token goes to curl on stdin, never as an argument.

## Turn push-deploys off

Not available. The build rules of a service are changed in the Northflank console; `deploys northflank autodeploy-off` says so and sends nothing.

## Deploy by hand

```bash
deploys northflank deploy <project>/<service> --yes
deploys northflank deploy <project>/<service> --sha <commit> --yes
```

A service is addressed as `<project>/<service>` (both slugs). The service is read first (its branch, its type), then a build is started. The new build's id is the deploy id: `deploys northflank status <project>/<service> <build id>` follows it (`PENDING` is queued, `IN_PROGRESS` building, `SUCCESS` ready, `FAILURE` failed, `CANCELLED` canceled). `--preview`, `--no-cache`, cancel, rollback and logs are refused before anything is sent.

## Other commands

`deploys northflank list`, `deploys northflank latest <project>/<service>`, `deploys northflank doctor`, `deploys northflank url <project>/<service>`.

## Limits and rate limits

The doctor reports `expiresAt` and `rateLimit` as `null`. Lists are read page by page (100 items, following the cursor, at most 20 pages). Not checked against a live account: this provider was written from the API reference and tested with fixtures, so a field name may need a small fix on first use.

## Undo

Nothing was changed on Northflank except a build you started. Revoke the token in the console or remove the keychain item `deploy-center-northflank`, and run `deploys providers disable northflank`.
