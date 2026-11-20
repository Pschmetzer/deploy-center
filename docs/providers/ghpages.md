# GitHub Pages in Deploy Center

A Pages site built with GitHub Actions publishes when its workflow runs. Deploy Center shows the newest run of the workflow of each repository you name, and **starts a deploy by dispatching that workflow** on its branch. It cannot turn the push trigger off, roll a site back or read logs (GitHub gives those as a zip or not at all): those are refused.

## What you need

- A repository whose Pages source is "GitHub Actions", with a workflow that has `on: workflow_dispatch`.
- A token (fine-grained: **Actions** read and write, **Pages** read, Metadata read; or a classic token with `repo`). `GITHUB_PAGES_TOKEN`, `GH_TOKEN` or `GITHUB_TOKEN`, in that order, or the keychain item `deploy-center-ghpages`.

## Turn it on

```bash
deploys providers enable ghpages
```

Name your sites. Either in the environment, `owner/repo[:workflow.yml[@branch]]`, space separated (workflow defaults to `pages.yml`, branch to `main`):

```bash
export DEPLOYS_GHPAGES_SITES="example/docs:deploy.yml@main example/blog"
```

or in `~/.config/deploys/ghpages.json`:

```bash
deploys ghpages add example/docs deploy.yml main
```

`deploys ghpages remove example/docs` takes one out again. Then store the token:

```bash
pbpaste | deploys ghpages set-key
```

It is tried (`GET /rate_limit`) and saved in the keychain only if GitHub takes it. It goes to curl on stdin, never as an argument.

## Turn push-deploys off

Not available from here: GitHub's API cannot edit a workflow's triggers. Remove the `push` trigger from the workflow file yourself. `deploys ghpages autodeploy-off` is refused without a call, and a site is shown with `auto: false` because its triggers are not read.

## Deploy by hand

```bash
deploys ghpages deploy <repo> --yes
```

This is `POST /repos/{owner}/{repo}/actions/workflows/{workflow}/dispatches` with the site's branch. The new run is looked up a few times (`DEPLOYS_GHPAGES_POLLS`, default 6, 3 s apart); the deploy id is the run id. If the run is not listed yet the answer has no id and says so. `--sha` (a dispatch runs on a branch), `--preview` and `--no-cache` are refused. `deploys ghpages cancel <repo> <run id>` cancels a run that is queued or in progress.

## Other commands

`deploys ghpages list`, `latest <repo>`, `status <repo> <run id>`, `url <repo> [--dashboard]` (the dashboard is the workflow's page in GitHub), `doctor`.

## Limits and rate limits

Run `queued`, `waiting`, `requested`, `pending` is queued; `in_progress` building; `success` (or `neutral`) ready; `cancelled` and `skipped` canceled; everything else failed. `lastSha` and `lastMsg` come from the newest successful run. A site whose Pages settings cannot be read is listed with a warning, not an error. The doctor's `rateLimit` comes from `GET /rate_limit` (core); `expiresAt` is `null`. Not checked against a live account.

## Undo

A dispatch is an ordinary workflow run; to go back to an older version, re-run an older successful run in GitHub (Actions). Remove sites with `deploys ghpages remove`, delete the keychain item `deploy-center-ghpages` and revoke the token in GitHub.
