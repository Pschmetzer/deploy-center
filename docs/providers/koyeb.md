# Koyeb in Deploy Center

Koyeb builds from its Git integration (or a container image). Deploy Center shows your services with the state of their newest deployment and can **redeploy a service** with its current definition. It never builds another commit and never uploads code.

## What you need

A Koyeb API token (Organization settings, API) that can read services and deployments and redeploy a service.

## Turn it on

```bash
deploys providers enable koyeb
```

```bash
pbpaste | deploys koyeb set-key
```

`set-key` tries the token against the API first and saves it in the keychain (`deploy-center-koyeb`) only if Koyeb takes it. `KOYEB_TOKEN` in the environment wins over the keychain. The token goes to curl on stdin, never as an argument.

## Turn push-deploys off

Not available. The Git integration is changed in the Koyeb console; `deploys koyeb autodeploy-off` says so and sends nothing.

## Deploy by hand

```bash
deploys koyeb deploy <service> --yes
```

The service is read first, then redeployed. The deploy id is the new deployment; `deploys koyeb status <service id> <deployment id>` follows it: `PENDING`, `STARTING` and similar count as building, `HEALTHY` as ready, `ERROR` as failed. `--sha`, `--preview`, `--no-cache`, cancel, rollback and logs are refused before anything is sent (`koyeb services logs` does the last).

## Other commands

`deploys koyeb list`, `deploys koyeb latest <service id>`, `deploys koyeb doctor`, `deploys koyeb url <service id>`.

## Limits and rate limits

The doctor reports `expiresAt` and `rateLimit` as `null`. Not checked against a live account: this provider was written from the API reference and tested with fixtures, so a field name may need a small fix on first use. The list reads the first 100 services.

## Undo

Nothing was changed on Koyeb except a redeploy. Revoke the token in the console or remove the keychain item `deploy-center-koyeb`, and run `deploys providers disable koyeb`.
