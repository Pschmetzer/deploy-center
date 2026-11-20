# Heroku in Deploy Center

Heroku builds from `git push heroku`, the GitHub integration or a CI that uses the Build API. Deploy Center lists your apps with their newest release, can **restart the dynos**, go back to an earlier release and read the log of the newest build. It never builds new code and takes no commit.

## What you need

An authorization (API key) for the Platform API. One that expires is best:

```bash
heroku authorizations:create -d deploy-center -e 31536000
```

## Turn it on

```bash
deploys providers enable heroku
```

```bash
pbpaste | deploys heroku set-key
```

The key is tried (`GET /apps`) and saved in the keychain (`deploy-center-heroku`) only if Heroku takes it. `HEROKU_API_KEY` in the environment wins. The key goes to curl on stdin, never as an argument. Calls carry `Accept: application/vnd.heroku+json; version=3`; lists ask for the newest releases with a `Range` header.

## Turn push-deploys off

Not available from here (the GitHub connection is not in the Platform API): `deploys heroku autodeploy-off` is refused without a call. Disconnect GitHub in the app's Deploy tab.

## Deploy by hand

```bash
deploys heroku deploy <app> --yes
```

This restarts all dynos (`DELETE /apps/{app}/dynos`) on the release that is live. The deploy id is that release; `deploys heroku status <app> <release id>` reads the release and the dynos: a release that succeeded while its dynos are `starting` is still building, and `crashed` dynos make it failed. `--sha`, `--preview` and `--no-cache` are refused.

- `deploys heroku rollback <app>` makes the next older release that succeeded and has code live again. Heroku does this as a **new release** (a new version number), and it brings back that release's config variables too.
- `deploys heroku logs <app> 100` prints the end of the newest build's log (builds made through the Build API: `git push`, the GitHub integration, CI). A container deploy has none. The runtime log is `heroku logs`.

## Other commands

`deploys heroku list`, `latest <app>`, `url <app> [--dashboard]`, `doctor`. Cancel is not available.

## Limits and rate limits

Release `pending` is building, `succeeded` ready, `failed` failed. `lastSha` is read from a description of the form `Deploy <sha>` of the newest successful release; other releases (config changes) give none. The doctor reports `rateLimit.remaining` from the `RateLimit-Remaining` header (Heroku sends no reset time) and `expiresAt` as `null`. Not checked against a live account.

## Undo

A restart changes nothing. A rollback is a release; to undo it, roll back again or deploy as usual. Revoke the key with `heroku authorizations:revoke` and delete the keychain item `deploy-center-heroku`.
