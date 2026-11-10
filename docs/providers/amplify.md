# AWS Amplify Hosting

Opt-in provider. `deploys` leaves Amplify alone until you choose an AWS profile for it (see Setup).
Having AWS credentials on the Mac for other tools does not turn it on.

> **Status:** written against the "providers as files" contract (A1). Until that change lands,
> `deploys` does not route to it yet; run it directly with `bash providers/amplify.sh <command>`.
> The examples below use the routed form, `deploys amplify <command>`.

## What it saves you: build minutes

Amplify Hosting bills **build minutes**: $0.01 per minute on the standard build instance (larger
instances cost more). With a Git-connected branch, every push builds, and so does every push to any
other branch with auto-build on. A 4-minute build pushed 20 times a day is about 80 minutes, or
$0.80 a day, for one branch. Built by hand once a day it is 4 minutes. Hosting and data transfer are
billed separately and do not change.

## Why the aws CLI, not hand-signed requests

Every Amplify API call must be signed with AWS Signature Version 4. `deploys` could do that in bash
with `openssl`, but it would then also have to read every way AWS credentials can be set up: access
keys, named profiles, IAM Identity Center (SSO) sessions, assumed roles with MFA,
`credential_process`, and refreshing short-lived tokens. The `aws` CLI already does all of that,
retries throttled calls, and is what AWS tests against. A second, smaller copy in bash would be
weaker and would need access keys stored somewhere, which is exactly what we do not want. So the
provider calls `aws amplify ...` and never sees a secret.

## Setup

1. Install the CLI and sign in. Any way the CLI supports works:

   ```bash
   brew install awscli
   ```

   ```bash
   aws configure sso --profile deployer
   ```

   (or `aws configure --profile deployer` for access keys).
2. Tell `deploys` which profile to use. It is checked first and kept in the keychain item
   `deploy-center-amplify` only if `aws sts get-caller-identity` works with it. The keychain holds
   the profile **name**, never a key:

   ```bash
   echo deployer | deploys amplify set-key
   ```

   Use `default` for the CLI's default chain (environment keys, the default profile, an instance
   role). On a server or in CI, set `DEPLOYS_AMPLIFY_PROFILE` instead (`default` works there too).
3. Region: `AWS_REGION` if set, otherwise the profile's region (or `AWS_DEFAULT_REGION`). Only apps
   in that one region are listed.
4. Check it:

   ```bash
   deploys amplify doctor
   ```

Which profile is used: `DEPLOYS_AMPLIFY_PROFILE`, then `AWS_PROFILE`, then the keychain, then the
CLI's default chain.

### Permissions

The identity needs `amplify:ListApps`, `GetApp`, `ListBranches`, `ListJobs`, `GetJob`,
`ListDomainAssociations`, `UpdateBranch`, `StartJob` and `StopJob`. `UpdateApp` is used only by
`off --all`.

## Projects

One project per app and its **production branch**: `name` is the app name, `id` is
`<appId>/<branch>`. The production branch is the app's `productionBranch`, else the branch with
stage `PRODUCTION`, else the only branch. An app with several branches and none marked production
is listed with a `fetchError` and can be used by id (`d1abc/main`). Commands take the id, the app
id, or the app name.

Listing costs one `list-apps` call, plus three per app (`list-branches`, `list-jobs`,
`list-domain-associations`). One app that fails to load shows its error in `fetchError` and does
not stop the rest.

| Field | From |
| --- | --- |
| `auto` | the branch's `enableAutoBuild` |
| `deployable` | the app is connected to a repository and the branch is known |
| `domain`, `url` | the custom domain mapped to the branch, else `<branch>.<defaultDomain>` |
| `lastAt`, `lastState`, `phase` | the newest job |
| `lastSha`, `lastMsg` | the newest job that succeeded (what is live) |
| `dashboardUrl` | the branch's deployments page in the Amplify console |

Job status to `phase`:

| Amplify | phase |
| --- | --- |
| `CREATED`, `PENDING`, `PROVISIONING` | `queued` |
| `RUNNING` | `building` |
| `SUCCEED` | `ready` |
| `FAILED` | `failed` |
| `CANCELLING`, `CANCELLED` | `canceled` |

## Turning auto-build off

```bash
deploys amplify off <project>
```

Runs `aws amplify update-branch --no-enable-auto-build` for the production branch and reads the
answer back. Other branches that still build on push are named in a warning; to turn those off
too, and the app's setting that auto-builds branches Amplify creates later
(`update-app --no-enable-branch-auto-build`):

```bash
deploys amplify off <project> --all
```

`deploys amplify on <project>` turns auto-build on again for the production branch.

Pull-request previews (`enablePullRequestPreview`) are not changed; they build only when a PR is
opened or updated, and you can switch them off in the console.

## Deploying

```bash
deploys amplify deploy <project>
```

Runs `aws amplify start-job --job-type RELEASE` on the production branch: Amplify builds the newest
commit of that branch. Unlike some other platforms, this works the same with auto-build off; no
toggling is needed.

- `--sha <commit>` passes that commit as `--commit-id`. Not yet checked against a real account:
  AWS describes a RELEASE job as building the newest change of the branch, so look at the job's
  commit in the console the first time you use it.
- `--preview --branch <b>` builds another branch that is connected in Amplify.
- A second start of the same branch within a minute is refused.

Apps without a Git connection (manual deploys by upload) have nothing to build; `deploy` says so.

## Status, cancel, logs

- `deploys amplify status <project> [<job id>]`: one job, the newest without an id.
- `deploys amplify cancel <project> [<job id>]`: `stop-job` for the given job, or the newest that is
  still queued or building.
- `deploys amplify logs <project> [lines] [<job id>]`: reads every step's log from its `logUrl`
  (a short-lived signed S3 link from `get-job`), prefixes each line with its step (`BUILD`,
  `DEPLOY`, ...) and prints the last lines. The link itself is never printed; if it has expired, run
  `logs` again for a fresh one.

## Rollback

```bash
deploys amplify rollback <project> [<job id>|<sha>]
```

Amplify Hosting has no instant rollback for Git-built branches. `rollback` starts a new `RELEASE`
job with the commit of an earlier build (`start-job --commit-id`). Without a target it picks the
newest succeeded build whose commit differs from the live one, so a rebuild of the same commit is
skipped. It is a full build and **costs build minutes** like any other.

## Limits

- One region at a time (`AWS_REGION` or the profile's).
- `paused` is always false; Amplify has no paused state for a branch.
- Amplify Gen 2 backends build in the same job; the minutes are the same.
