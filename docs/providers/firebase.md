# Firebase Hosting in Deploy Center

Firebase Hosting has no build service: `firebase deploy` or your CI uploads files and makes a version live. Deploy Center lists your sites with their live release, and can **make a finished version live**: roll forward to the newest one, or go back to the one that was live before. It never uploads files or builds anything.

## What you need

A Google OAuth access token that may use the Hosting API, and the project id. Tokens last an hour, so prefer a command that prints a fresh one:

```bash
export FIREBASE_PROJECT=my-project-id
export FIREBASE_ACCESS_TOKEN_CMD='gcloud auth print-access-token'
```

`FIREBASE_ACCESS_TOKEN` or `GOOGLE_OAUTH_ACCESS_TOKEN` hold a token directly. The project can also be `{"project":"my-project-id"}` in `~/.config/deploys/firebase.json`. The account needs the Firebase Hosting Admin role (or `firebasehosting.sites.*` and `firebasehosting.versions.*`).

## Turn it on

```bash
deploys providers enable firebase
```

```bash
gcloud auth print-access-token | deploys firebase set-key
```

`set-key` is for a token that will be gone within the hour; the command above is better. The token is tried first and saved in the keychain (`deploy-center-firebase`) only if Google takes it. It goes to curl on stdin, never as an argument.

## Turn push-deploys off

Not applicable: Firebase Hosting does not deploy on push. `deploys firebase autodeploy-off` says so and sends nothing.

## Deploy by hand

```bash
deploys firebase deploy <site> --yes
```

This releases the newest finished version of the site that is **newer than the live one** (after a rollback, the version you came from). With nothing newer it refuses and sends nothing. The deploy id is the release id; `deploys firebase status <site> <release id>` follows it. `--sha`, `--preview` and `--no-cache` are refused: preview channels are made with `firebase hosting:channel:deploy`.

```bash
deploys firebase rollback <site> --yes
```

This releases the version that was live before the current one. Rolling back twice goes back and forth between two versions.

## Other commands

`deploys firebase list`, `latest <site>`, `url <site> [--dashboard]`, `doctor`. Cancel and logs are not available.

## Limits and rate limits

A release shows its version's state: `FINALIZED` is ready, `CREATED` and `CLONING` building, `ABANDONED` failed, `DELETED` and `EXPIRED` canceled. Only the sites of one project are listed (up to 100). Old versions are deleted by Firebase after a while (the project's version history setting), so a rollback target can be gone. The doctor reports `expiresAt` and `rateLimit` as `null`. Not checked against a live account; the endpoints follow the v1beta1 reference and are tested with fixtures.

## Undo

A release is an entry in the live channel's history; release the other version again (`rollback`, or `deploy`) to undo it. Delete the keychain item `deploy-center-firebase` and turn the provider off with `deploys providers disable firebase`.
