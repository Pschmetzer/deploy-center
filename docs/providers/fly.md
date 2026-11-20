# Fly.io in Deploy Center

Fly.io builds only when you run `fly deploy` or your CI does, so there is no push build to switch off. Deploy Center shows your apps and the state of their machines, and can **restart the running machines** on the image they already have. It never builds or uploads code and never takes a commit.

## What you need

A Fly.io token that can read the apps of one organization and restart their machines (an org token, or a deploy token for one app). Create one:

```bash
fly tokens create org
```

Name the organization with `FLY_ORG` (default `personal`), or `{"org":"my-org"}` in `~/.config/deploys/fly.json`. The Machines API at `api.machines.dev` lists apps per organization.

## Turn it on

```bash
deploys providers enable fly
```

```bash
pbpaste | deploys fly set-key
```

`set-key` tries the token against the API first and saves it in the keychain (`deploy-center-fly`) only if Fly.io takes it. `FLY_API_TOKEN` in the environment wins over the keychain. The token goes to curl on stdin, never as an argument.

## Turn push-deploys off

Not applicable. Fly.io does not deploy on push by itself; `deploys fly autodeploy-off` says so and sends nothing.

## Deploy by hand

```bash
deploys fly deploy <app> --yes
```

This restarts every machine of the app that is **started**, one after another and without waiting between them (stopped machines stay stopped: autostop is normal on Fly). With a single machine the app is down for the restart. The deploy id is the first machine; `deploys fly status <app> <machine id>` follows its state: `created`, `starting`, `replacing` count as building, `started` and `stopped` as ready, `failed` as failed.

To ship new code, run `fly deploy` (or your CI). `--sha`, `--preview`, `--no-cache`, cancel, rollback and logs are not available and are refused before anything is sent (`fly releases`, `fly logs -a <app>` do those).

## Other commands

`deploys fly list`, `deploys fly latest <app>`, `deploys fly doctor`, `deploys fly url <app> [--dashboard]`.

## Limits and rate limits

The Machines API answers per organization; the doctor reports `expiresAt` and `rateLimit` as `null` because Fly.io sends neither in a form read here. Not checked against a live account: this provider was written from the API reference and tested with fixtures. An app's "last change" is the newest `updated_at` of its machines, and `lastMsg` shows the release version from the machine's metadata when Fly.io sets it.

## Undo

Nothing was changed on Fly.io except machine restarts. Delete the token with `fly tokens` or remove the keychain item `deploy-center-fly`, and turn the provider off with `deploys providers disable fly`.
