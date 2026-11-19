# Provider sketches (not active)

Two hosts that fit the [provider contract](../PROVIDERS.md) in part. Nothing here is built, and none of
it has been checked against a live account: the API names below come from the hosts' public docs and must
be confirmed before a provider file is written. A new host would be one `providers/<host>.sh`, off by default.

## Railway

| Contract | Railway |
| --- | --- |
| Key | A project or account token, sent as a bearer header (`RAILWAY_API_TOKEN`; keychain item `deploy-center-railway`). |
| API | One GraphQL endpoint (`backboard.railway.com/graphql/v2`). Every call is a POST, so `_call` must tell reads (`query`) from writes (`mutation`) itself: only queries may be repeated. |
| `_json` | `projects` → `services` → `deployments(first: 1)`; `status` maps to the phase (`INITIALIZING`/`QUEUED`/`WAITING` queued, `BUILDING`/`DEPLOYING` building, `SUCCESS` ready, `FAILED`/`CRASHED` failed, `REMOVED`/`SKIPPED` canceled). |
| `id` | The service id; the environment id travels with it (a project has several). |
| `_deploy_json` | `deploymentRedeploy`, or `serviceInstanceDeploy` for the newest commit. `--sha` has no obvious API: caps `sha:false` until confirmed. |
| `_off` | The deployment trigger of the service (`deploymentTriggerUpdate`, or delete the trigger and remember it). |
| `_cancel`, `_rollback` | `deploymentCancel`; `deploymentRollback`. |
| `_logs` | `buildLogs(deploymentId)` and `deploymentLogs`: `runtimeLogs:true`. |
| Open questions | Pagination is cursor based (`edges`/`pageInfo`): needs the same page guards as Render. Rate limits are per plan and come in headers; the doctor can read them. |

## Fly.io

| Contract | Fly.io |
| --- | --- |
| Key | An app or org deploy token (`FLY_API_TOKEN`; keychain item `deploy-center-fly`). |
| API | The Machines REST API (`api.machines.dev/v1/apps/<app>/machines`). |
| What it does not do | Fly builds and ships an image with `flyctl deploy` (a remote builder); the REST API only creates or updates machines from an image. There is no "deploy the newest commit of the branch" call, and no push-triggered deploy on Fly's side (that is a GitHub Action in the repo). |
| Likely shape | A provider that **observes** and **restarts**: `_json` lists apps with their machines (`state`: `started`, `starting`, `stopped`, `failed`), the image tag and `updated_at`. `_deploy_json` could only redeploy the current image (a machine update with an unchanged config), which is not what a user means by deploy. |
| Verdict | Weak fit. Better as a read-only status tab (`deployable:false` for every row) than as a deploy target, unless the repo's workflow can be started through the GitHub API (workflow dispatch), which is the GitHub host's job, not Fly's. |

## Before either is built

1. Confirm each name above on a throwaway account the owner chooses; no real names in fixtures.
2. Fixtures per API call (GraphQL answers as files keyed by a short query id, since all calls share one path).
3. Pass the contract test, including the failure stubs (401, 403, 429, 503, empty, HTML, no answer).
