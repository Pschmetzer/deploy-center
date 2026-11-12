# Providers: adding a platform

Each platform `deploys` can deploy to is one file: `providers/<p>.sh`. Today these are
`vercel.sh` and `render.sh` (on by default), and `netlify.sh`, `cloudflare.sh`, `amplify.sh`,
`digitalocean.sh`, `coolify.sh` and `hook.sh` (a generic deploy hook), each off until turned on
(`ls providers` is the list). `deploys` sources every `providers/*.sh` at start. There is no
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
| `<p>_meta` | One JSON object: `{id, label, noun, defaultOn, keyEnv:[…], keychain, caps:{off, sha, cancel, rollback, logs, preview}}`. `noun` is what one item is called ("project", "service"), used in usage lines and errors. **One line, written with `printf`, not jq**: `deploys` greps it (`meta_flag`, `meta_str`, `key_of`), also where jq is missing. `contract.sh` checks that it is one valid line. Extra keys are allowed: Cloudflare and Amplify add `name`, `default`, `billing`, `needs`, `profileEnv`; `auth` says how Vercel logs in; `runtimeLogs` and `onDryRun` are flags `deploys` reads. |
| `<p>_ready` | Exit 0 when this Mac is set up for it (a key, a CLI login). Never prints a key. |
| `<p>_json` | A JSON array, one entry per project (fields below), sorted by name. No GitHub calls: the core adds branch heads and `changed`. |
| `<p>_has <name>` | Exit 0 and **print the id** (what the other functions take) when a project of that name (or id) exists: `lookup` uses that output, so a `_has` that only sets the exit code breaks `deploys deploy p:name`. Example: `netlify_has shop` prints `site-shop`. Exit 1 when there is none; Vercel exits 2 when it could not be asked. |
| `<p>_off <id>\|--all` | Turn auto-deploy on push off. Print one line per project. `--all`: every project, one failure does not stop the rest, the exit code counts them. (Amplify's `--all` means "the other branches too"; `deploys amplify off --all` is per app.) |
| `<p>_deploy_json <id> [--sha S] [--preview]` | Start a deploy; print `{id, url, state, phase}` (`url` may be null). Take the start lock with `start_lock "<p>-<id>"`. |
| `<p>_status <id> <deployId>` | **One TSV line**, `deployId<TAB>phase<TAB>rawState`, of one deploy (for example `d-shop-3<TAB>ready<TAB>ready`), never JSON: `watch` reads the first line only, and a `{` there used to loop for ever. A JSON variant for people is `<p>_cli_status`. |
| `<p>_latest <id> [--preview]` | The same line for the newest deploy (production, or any target with `--preview`); `none<TAB><TAB>none` when there is none (not an error: `watch` says "no deploy"). |
| `<p>_cancel <id> <deployId>` | Cancel; print `{id, state, phase}` (a `message` for people may come along). |
| `<p>_rollback <id>` | Production back to the deploy that was live before; print `{id, state}` (and `phase`, `message`). The app reads it from `deploys <p> rollback <id>`, so no `_cli_rollback` with prose. |
| `<p>_logs <id> <lines> [deployId]` | The end of a build log, plain text. All three positional: `deploys logs` passes an empty `deployId` for the newest. A provider whose `_meta` says `"runtimeLogs":true` (Render, Coolify) takes `--runtime` in the third place for the running app's own log instead. |
| `<p>_url <id> [--dashboard]` | The site's address, or the project's page at the platform. |
| `<p>_set_key` | Read a key from stdin, try it, save it in the keychain as `deploy-center-<p>`. |
| `<p>_doctor` | One JSON object of checks (`{"<p>Key":true, …}`). Its fields join `deploys doctor`. Prefer `printf`; a provider whose checks carry free text (an error line) may build it with `jq -n` for the escaping (Netlify, Cloudflare, Amplify, Coolify, DigitalOcean do), and then `doctor` without jq loses only its fields. Providers with `"provider"` in it also give `expiresAt` (Unix seconds, when the key ends) and `rateLimit` (`{remaining, resetAt}`, Unix seconds) from the call the doctor makes anyway, `null` where the platform does not say (below). |

Optional: `<p>_where` (lines for `deploys where`), `<p>_history <id> <n>` (a table for
`deploys history`), `<p>_usage <argc> <verb>` (usage lines for verbs with more arguments), and
`<p>_cli_<verb>` for a command people type whose output is not the contract's. For example,
`vercel_cli_status` keeps the JSON that `deploys vercel status <id>` always printed, and
`<p>_cli_status` / `<p>_cli_latest` do the same for Netlify, Cloudflare, Amplify, DigitalOcean
and Coolify (their `_status_json` / `_latest_json`).
`vercel_on` and `render_on` (`deploys vercel|render autodeploy-on <p>|--all`) take `--dry-run`:
they only read and print what they would switch back on, one line each, or with `--json`
`{provider, dryRun:true, items:[{name, id, action:"on"|"skip"|"already", reason}], on, skipped}`
(FEA-110, for "turn everything back on" in docs/UNINSTALL.md). The flag goes after the target
(`autodeploy-on --all --dry-run`: `deploys` checks the third word as a name). Their `_meta` says
`"onDryRun":true`; a caller checks that first, because an older provider ignores `--dry-run` and
really switches everything on.
Platform extras that are not part of the contract stay where they are: `vercel map`,
`vercel team`, `costs`, `triggers`.

### Key end and rate limit in the doctor

| Provider | `expiresAt` | `rateLimit` |
|---|---|---|
| Cloudflare | `expires_on` of `GET /user/tokens/verify` (only a token with an end date) | `Ratelimit: "default";r=…;t=…` (`resetAt` = now + t) |
| Netlify | null (the API does not say) | `X-RateLimit-Remaining`, `X-RateLimit-Reset` of `GET /user` |
| DigitalOcean | null | `ratelimit-remaining`, `ratelimit-reset` of `GET /v2/account` (per hour) |
| Coolify | null | `X-RateLimit-Remaining`; `resetAt` null (Laravel sends a reset only with a 429) |
| Amplify | null (an SSO session end would need the credentials read out) | null |
| Vercel, Render, Hook | left out: their fields also join the top level of `deploys doctor` | left out |

The headers come from the provider's own curl code (`<P>_HEADERS=<file>` makes `<p>_call` keep
them; `http_call` does not), and `tests/fixtures/ratelimit/` holds header files for the parsers.

### Shared helpers

`deploys` defines `die`, `mtime`, `b64d`, `start_lock`, `key_of` and `CONFIG_DIR` before it
sources the providers, and they use those. A provider that its own tests source alone defines
a stand-in behind `declare -F die >/dev/null || die() { … }`, so the one in `deploys` always wins
(`tests/providers/contract.sh` fails on a `<p>_die`, `<p>_mtime` or `<p>_lock` copy).

### HTTP calls

A provider that talks to an HTTP API with a bearer key uses `http_call` from `lib/http.sh` when
`deploys` has loaded it (`declare -F http_call`), with `HTTP_AUTH` and `HTTP_FIX` as locals,
and its own curl code otherwise (the file run on its own). The key goes to curl on stdin either
way. Today Coolify, DigitalOcean (calls without a body) and Cloudflare (JSON calls) do this.
They keep their own code where `http_call` would lose something:

- a request body that may hold env values (DigitalOcean specs): `http_call` puts it in argv;
- a form upload (Cloudflare `--form-string`);
- `Retry-After` and other response headers (Render, Netlify, and the doctors' rate limits);
- a call without the key (Netlify build hooks).

`<p>_call`'s promise stays the same: Coolify and DigitalOcean return 1 with the reason on
stderr (without `Error:`), Cloudflare ends the command. `tests/fixtures/http/stub.sh` gives the
provider tests an `http_call` (the real one when `lib/http.sh` is there).

### Dispatch

`deploys <p> <verb> [args]` runs `<p>_cli_<verb>` if it exists, else `<p>_<verb>` for a contract
verb (`-` becomes `_`, and `autodeploy-off` is `off`). `on` and `autodeploy-on` run `<p>_on`
where the provider has one, and `list` is `json` where it has no `<p>_cli_list`. A verb it does
not have is refused with the list of its commands; `deploys --help` lists them for every
provider that is on, from the same functions (so a provider's own command, like
`cloudflare_cli_selftest`, shows up there by being defined). `<p>_setup_hint` (optional) is the
next step `deploys providers enable <p>` prints while the provider is not set up. `<p> json` adds the branch heads and the
`changed` rule to `<p>_json`. `--json` turns `<p> list` into `<p> json` and `<p> deploy` into
`<p> deploy-json`. Every older spelling keeps working (`vercel json`, `render deploy-json`, and
`"$0" "$1" deploy-json` from autofix).

### `_json` fields

`{name, id, auto, deployable, paused, repo, ref, domain, url, dashboardUrl, lastAt, lastState,
lastSha, lastMsg, fetchError, phase}`. Every key is present; unknown values are `null`.

- `id`: what the other functions take. For Vercel it is the project name; for Render the `srv-` id.
- `auto`: a push still deploys it. `deployable`: this tool can start a deploy (the repo is known).
  Vercel: only a repo written down counts. A project connected to Git without one is `deployable:false`
  with `repoUnknown:true` and is never built from its live link (`deploys vercel map` writes it down).
- `repo` is `owner/name` on GitHub, `ref` the branch. Both are needed for "changed".
- `lastAt` (Unix seconds), `lastSha`, `lastMsg`: what is live. `lastState`: the platform's own
  word for the newest attempt, kept raw for display.
- `fetchError`: why the live deploy could not be read. A project with one is never counted as
  changed and never as up to date.
- `phase`: see below. Extra fields (`latestState`, `latestId`, `latestSha`, `type`) are welcome.
- `fetchWarn` (optional): something that could not be read but does not make the row wrong
  enough for `fetchError`, for example Amplify's custom domains (the address shown may be the
  default one). The app shows it quietly at the row.
- `triggeredSha` (optional, hook): `lastSha` is then the branch head when the hook fired, not a
  commit seen live (the host may build another one). It still counts the commits since the
  trigger; the app need not call it live. A hook's `phase` is `queued` for `HOOK_QUEUED_SECS`
  (180) after a good trigger, then `ready`; its `_status` line is `ready` at once, since
  `watch` would learn nothing more by waiting.

### Phase

`phase` is one of `queued`, `building`, `ready`, `failed`, `canceled`. It is `null` only when there
is no deploy at all, or the platform answered a state the provider does not know. Each provider
maps its own states. `CHANGED_RULE`, `watch` and `status` read only `phase`; `lastState` stays
raw. A deploy that was replaced before it went live (Render `deactivated`) ends as `canceled`.

### bash 3.2

`deploys` runs under macOS's `/bin/bash` 3.2. There `"${x:-{\}}"` is the text `{\}`, not `{}`:
an empty variable then breaks `--argjson` and with it the whole list. Set the default on a line of
its own and check it (`[ -n "$x" ] || x='{}'`, then `jq -e 'type == "object"'`).
`tests/providers/vercel.sh` fails when that pattern shows up in `providers/` or `lib/githost.sh`.

## Overrides

For tests and unusual setups; none is needed in normal use.

| Variable | What |
|---|---|
| `DEPLOYS_VERCEL_TEAM` | The Vercel team id, instead of the remembered one |
| `DEPLOYS_VERCEL_TIMEOUT` | Seconds one `vercel` call may take (60) |
| `DEPLOYS_VERCEL_ANY_SHA` | `1`: a production `--sha` that GitHub says is not on the remembered branch (a fork, another branch) is deployed anyway; without it, refused (FEA-042) |
| `NETLIFY_API`, `CLOUDFLARE_API_BASE`, `DIGITALOCEAN_API` | Another API address (test servers) |
| `DEPLOYS_NETLIFY_POLLS` | How often a Netlify start looks for its new deploy |
| `DEPLOYS_CLOUDFLARE_SELFTEST_TRIES` | Rounds of the Cloudflare self-test (5 s each) |
| `DEPLOYS_CLOUDFLARE_TOGGLE` | Cloudflare: switch push builds on just for a start |
| `DEPLOYS_CLOUDFLARE_SELFTEST_TTL` | Seconds a Cloudflare self-test counts for its project (30 days) |
| `DEPLOYS_GITLAB_TIMEOUT` | Seconds one `glab api` call may take (60) |
| `DEPLOYS_GITLAB_CURL` | Ask GitLab with curl even when `glab` is there |
| `DEPLOYS_RENDER_NAME_TTL` | Seconds Render keeps service names for lookups (60; 0 = never) |
| `DEPLOYS_NETLIFY_RULE_TTL` | Seconds between GitHub checks of an unconfirmed Netlify rule (600) |
| `DEPLOYS_AMPLIFY_PARALLEL` | Amplify apps read at once in a list (4) |
| `DEPLOYS_AMPLIFY_LOG_BYTES` | Bytes read from the end of each Amplify log step (262144) |
| `DEPLOYS_HOOK_STORE` | `keychain` or `file`: where hook URLs are kept (file: tests, Linux) |

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
   - `config/` (optional): files copied into the config folder first. A provider that is off by
     default needs `providers.json` there (`{"enabled":["<p>","render","vercel"]}`).
   - `CONTRACT_DONE` (optional, in `env`): a sed script that turns the files of
     `CONTRACT_DEPLOY` into a finished deploy, for the `deploys watch` check (the default fits
     Render and Vercel).
   - `bin/` (optional): stand-ins for a provider's own CLI, put on the PATH (Amplify: `aws`).
   - One file per API call: `<METHOD>_<path>.json`, where `<path>` is the URL path and query with
     every character other than letters, digits, `.` and `-` as `_` (for example
     `GET_v1_services_limit_100.json`). The file holds the body, a newline and the HTTP status.
2. `tests/lib/fake-curl.sh` answers from those files and logs `curl METHOD URL` to `$CALLS`.
   `CURLSTUB=401|503|down` simulates errors. A provider that uses a CLI (like Vercel) gets a
   stand-in like `tests/lib/fake-vercel.sh`. The aws CLI (Amplify) is answered by
   `tests/lib/fake-aws.sh` from `AWS_<service>_<command>[_<app id>[_<job id>]].json` files.
   A provider without `env` fails the contract; it is not skipped.
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
