# Providers: adding a platform

Each platform `deploys` can deploy to is one file: `providers/<p>.sh`. Today these are
`vercel.sh` and `render.sh` (on by default), and `netlify.sh`, `cloudflare.sh`, `amplify.sh`,
`digitalocean.sh`, `coolify.sh` and `hook.sh` (a generic deploy hook), off until `deploys providers enable <p>`;
each has a page: [netlify](providers/netlify.md), [cloudflare](providers/cloudflare.md),
[amplify](providers/amplify.md), [digitalocean](providers/digitalocean.md), [coolify](providers/coolify.md), [hook](providers/hook.md). `deploys` sources every `providers/*.sh` at start. There is no
list to edit: adding the file adds the provider, and its id is the file name without `.sh`.
The shared commands (`changed`, `deploy-changed`, `status`, `watch`, `logs`, `open`, `explain`,
`doctor`, `where`, `list`) call only the functions below. A new provider changes nothing outside
its own file, its fixtures and its tests.

The script finds the folder next to itself, following symlinks (a `~/bin/deploys` link keeps
working). `DEPLOYS_DIR` overrides this; the Docker image sets it to `/usr/local/lib/deploys`.
`build.sh` copies `providers/` into the app's `Contents/Resources/`.

## On and off

Vercel and Render are on by default. Every other provider is off until someone turns it on:

```bash
deploys providers enable netlify
```

```bash
deploys providers disable render
```

The choice is stored in `${DEPLOYS_CONFIG:-~/.config/deploys}/providers.json` as
`{"enabled":["netlify","render","vercel"]}`. Without that file (or with one that cannot be read),
the defaults apply: the providers whose `_meta` says `"defaultOn":true`. Only Vercel and Render
may say that, so a new provider adds nothing to anyone's window until it is turned on.

`list`, `changed`, `status`, `deploy-changed` and name lookups touch only providers that are
**on and ready**. A provider that is off is never called and never asked for a key. Even
`deploys providers --json` does not ask it whether it is set up (`"ready": null`). A command
addressed to it directly (`deploys netlify json`) is refused with the line that turns it on.
A Vercel or Render user who never runs `enable` sees exactly what they saw before.

`deploys providers --json` lists every provider: its `_meta` plus `enabled` and `ready`. The app
shows tabs only for the enabled ones, and a switch in Settings for the others.

## The functions

`<p>` is the provider id. Every function is required (`tests/providers/contract.sh` checks that
they exist). Where a capability is `false` in `_meta`, the function still exists and calls
`die "<label> cannot …"` without sending anything.

| Function | Prints / does |
|---|---|
| `<p>_meta` | One JSON object: `{id, label, noun, defaultOn, keyEnv:[…], keychain, caps:{off, sha, cancel, rollback, logs, preview}}`. `noun` is what one item is called ("project", "service"), used in usage lines and errors. Written with `printf`: `doctor` reads it without jq. |
| `<p>_ready` | Exit 0 when this Mac is set up for it (a key, a CLI login). Never prints a key. |
| `<p>_json` | A JSON array, one entry per project (fields below), sorted by name. No GitHub calls: the core adds branch heads and `changed`. |
| `<p>_has <name>` | Exit 0 and print the id when a project of that name (or id) exists. |
| `<p>_off <id>\|--all` | Turn auto-deploy on push off. Print one line per project. |
| `<p>_deploy_json <id> [--sha S] [--preview]` | Start a deploy; print `{id, url, state, phase}` (`url` may be null). Take the start lock with `start_lock "<p>-<id>"`. |
| `<p>_status <id> <deployId>` | `deployId<TAB>phase<TAB>rawState` of one deploy. |
| `<p>_latest <id> [--preview]` | The same line for the newest deploy (production, or any target with `--preview`); `none` as the id when there is none. |
| `<p>_cancel <id> <deployId>` | Cancel; print `{…, state}`. |
| `<p>_rollback <id>` | Production back to the deploy that was live before; print `{id, state}`. |
| `<p>_logs <id> <lines> [deployId]` | The end of a build log, plain text. |
| `<p>_url <id> [--dashboard]` | The site's address, or the project's page at the platform. |
| `<p>_set_key` | Read a key from stdin, try it, save it in the keychain as `deploy-center-<p>`. |
| `<p>_doctor` | One JSON object of checks (`{"<p>Key":true, …}`), with `printf`, not jq. Its fields join `deploys doctor`. |

Optional: `<p>_where` (lines for `deploys where`), `<p>_history <id> <n>` (a table for
`deploys history`), `<p>_usage <argc> <verb>` (usage lines for verbs with more arguments), and
`<p>_cli_<verb>` for a command people type whose output is not the contract's. For example,
`vercel_cli_status` keeps the JSON that `deploys vercel status <id>` always printed.
Platform extras that are not part of the contract stay where they are: `vercel map`,
`vercel team`, `costs`, `triggers`.

### Dispatch

`deploys <p> <verb> [args]` runs `<p>_cli_<verb>` if it exists, else `<p>_<verb>` for a contract
verb (`-` becomes `_`, and `autodeploy-off` is `off`). `<p> json` adds the branch heads and the
`changed` rule to `<p>_json`. `--json` turns `<p> list` into `<p> json` and `<p> deploy` into
`<p> deploy-json`. Every older spelling keeps working (`vercel json`, `render deploy-json`, and
`"$0" "$1" deploy-json` from autofix).

### `_json` fields

`{name, id, auto, deployable, paused, repo, ref, domain, url, dashboardUrl, lastAt, lastState,
lastSha, lastMsg, fetchError, phase}`. Every key is present; unknown values are `null`.

- `id`: what the other functions take. For Vercel it is the project name; for Render the `srv-` id.
- `auto`: a push still deploys it. `deployable`: this tool can start a deploy (the repo is known).
- `repo` is `owner/name` on GitHub, `ref` the branch. Both are needed for "changed".
- `lastAt` (Unix seconds), `lastSha`, `lastMsg`: what is live. `lastState`: the platform's own
  word for the newest attempt, kept raw for display.
- `fetchError`: why the live deploy could not be read. A project with one is never counted as
  changed and never as up to date.
- `phase`: see below. Extra fields (`latestState`, `latestId`, `latestSha`, `type`) are welcome.

### Phase

`phase` is one of `queued`, `building`, `ready`, `failed`, `canceled`. It is `null` only when there
is no deploy at all, or the platform answered a state the provider does not know. Each provider
maps its own states. `CHANGED_RULE`, `watch` and `status` read only `phase`; `lastState` stays
raw. A deploy that was replaced before it went live (Render `deactivated`) ends as `canceled`.

## Keys

`key_of <p>` (in `deploys`) returns the provider's key: the first variable in `keyEnv` that is
set, else the keychain item `deploy-center-<p>` (`security find-generic-password -a "$USER"
-s deploy-center-<p> -w`). It prints nothing and fails when there is none. Send the key to curl on
stdin (`-K -`), never as an argument. Render also reads its older keychain name `render-api-key`,
inside `render.sh`.

## Names

`deploys logs web` finds the provider through, in order:

1. `p:name` written out (`render:web`);
2. `names.json` in the config folder, `[{name, platform, id}]`, written by every list read. A
   name found on two enabled providers is refused, with the `p:name` to use instead;
3. `<p>_has <name>` on each provider that is on and ready.

The plain `names` file (one name per line) stays for tab completion and `deploys ignore`.

## Functions run under xargs

`bash -c` under `xargs -P` sees only exported functions. A provider that reads in parallel
exports its worker: `export -f render_last_of`.

## Tests

1. Add `tests/fixtures/<p>/`:
   - `HOST`: the API's host name, for example `api.render.com`.
   - `env`: sourced before the tests. It holds stand-in keys and `CONTRACT_ID`, `CONTRACT_NAME`
     and `CONTRACT_DEPLOY`, which `_has`, `_status`, `_latest`, `_deploy_json` and `_url` are
     called with.
   - `expect.json`: `{"<name>": "<phase>"}` for every project in the list fixture.
   - `config/` (optional): files copied into the config folder first.
   - One file per API call: `<METHOD>_<path>.json`, where `<path>` is the URL path and query with
     every character other than letters, digits, `.` and `-` as `_` (for example
     `GET_v1_services_limit_100.json`). The file holds the body, a newline and the HTTP status.
2. `tests/lib/fake-curl.sh` answers from those files and logs `curl METHOD URL` to `$CALLS`.
   `CURLSTUB=401|503|down` simulates errors. A provider that uses a CLI (like Vercel) gets a
   stand-in like `tests/lib/fake-vercel.sh`.
3. `tests/providers/contract.sh` runs for every `providers/*.sh`. It checks the functions, `_meta`,
   the fields and the phases of `_json`, the TSV lines, that a missing capability is refused
   without a call, and the on/off rules. `tests/script-tests.sh` runs every `tests/providers/*.sh`;
   a provider may add its own file there.
4. `shellcheck --severity=warning providers/*.sh` must be clean (CI runs it).

The fixtures are public: only stand-in names (`example`, `alpha`, `web`), never a real project,
team id, domain or key.

## Checklist for a new provider

- `providers/<p>.sh` with every function, `"defaultOn":false` in `_meta`.
- `tests/fixtures/<p>/`, and `bash tests/script-tests.sh` passes.
- A line in `CHANGELOG.md` under Unreleased.
- The app (A2) reads `deploys providers --json` and needs no change for a new provider.
