#!/bin/bash
# providers/fly.sh — the Fly.io provider for `deploys` (opt-in: deploys providers enable fly).
#
# Fly.io has no build-on-push of its own: `fly deploy` (or your CI) builds and ships an image.
# What the Machines API (api.machines.dev) can do from here is read the apps and their machines
# and restart the running machines on the image they already have. So "deploy" here means
# "restart the running machines", never "build new code" (docs/providers/fly.md).
#
# Contract (docs/PROVIDERS.md): fly_meta, _ready, _json, _has, _off, _deploy_json, _status,
# _latest, _cancel, _rollback, _logs, _url, _set_key, _doctor. Phases: queued | building | ready | failed | canceled.
#
# Token: FLY_API_TOKEN (a deploy or org token), else the keychain item deploy-center-fly.
# The token goes to curl on stdin (lib/http.sh), never as an argument. Organization: FLY_ORG, else
# "fly_org" in <config>/fly.json, else "personal".

FLY_KEYCHAIN="deploy-center-fly"
FLY_API="${FLY_API:-https://api.machines.dev/v1}"

declare -F die >/dev/null || die() { echo "Error: $*" >&2; exit 1; }
# shellcheck source=../lib/http.sh
declare -F http_call >/dev/null || { _fly_h="$(dirname "${BASH_SOURCE[0]}")/../lib/http.sh"; [ ! -f "$_fly_h" ] || . "$_fly_h"; unset _fly_h; }

fly_config_dir() { echo "${CONFIG_DIR:-${DEPLOYS_CONFIG:-$HOME/.config/deploys}}"; }

fly_key() {
  local k=""
  if declare -F key_of >/dev/null; then k="$(key_of fly 2>/dev/null)" || k=""
  elif [ -n "${FLY_API_TOKEN:-}" ]; then k="$FLY_API_TOKEN"
  else k="$(security find-generic-password -a "${USER:-$(id -un)}" -s "$FLY_KEYCHAIN" -w 2>/dev/null)" || k=""
  fi
  [ -n "$k" ] || { echo "No Fly.io token. Create one with: fly tokens create org   then: pbpaste | deploys fly set-key (or set FLY_API_TOKEN)" >&2; return 1; }
  printf '%s' "$k"
}

# The organization whose apps are listed.
fly_org() {
  local o="${FLY_ORG:-}" f
  if [ -z "$o" ]; then f="$(fly_config_dir)/fly.json"; [ ! -f "$f" ] || o="$(jq -r '.org // empty' "$f" 2>/dev/null)"; fi
  o="${o:-personal}"
  case "$o" in *[!A-Za-z0-9_-]*) echo "Fly.io: \"$o\" is not an organization slug" >&2; return 1 ;; esac
  printf '%s' "$o"
}

# fly_call METHOD PATH [BODY]: the answer on stdout; on failure the reason on stderr, rc 1.
# In a subshell, so http_call's die returns 1 here; its "Error: " is dropped.
fly_call() {
  local k e rc=0 fix="pbpaste | deploys fly set-key"
  declare -F http_call >/dev/null || { echo "Fly.io: lib/http.sh is missing" >&2; return 1; }
  k="$(fly_key)" || return 1
  [ -z "${FLY_API_TOKEN:-}" ] || fix="check FLY_API_TOKEN in the environment"
  # A token made by `fly tokens create` starts with "FlyV1 " and goes in as it is.
  local auth="Authorization: Bearer $k"
  case "$k" in "FlyV1 "*) auth="Authorization: $k" ;; esac
  # shellcheck disable=SC2034  # read by http_call
  local HTTP_AUTH="$auth" HTTP_FIX="$fix"
  e="$(mktemp)"
  ( http_call "Fly.io" "$1" "$FLY_API$2" "${3:-}" ) 2>"$e" || rc=$?
  [ "$rc" = 0 ] || sed '1s/^[^ ]*Error:[^ ]* //' "$e" >&2
  rm -f "$e"; return "$rc"
}

# Fly app names are lowercase letters, digits and dashes.
fly_valid() { case "$1" in ''|-*|*[!a-z0-9-]*) return 1 ;; esac; }

# jq helpers. A machine state is mapped to a phase; stopped and suspended machines are normal on
# Fly (autostop), so they count as ready.
# shellcheck disable=SC2016
FLY_JQ='
  def t: (. // null) | if . then ((try (capture("^(?<d>[0-9]{4}-[0-9]{2}-[0-9]{2}T[0-9]{2}:[0-9]{2}:[0-9]{2})(\\.[0-9]+)?(?<z>Z|[+-][0-9]{2}:?[0-9]{2})?$") | (.d + "Z" | fromdateiso8601) - (if (.z // "Z") == "Z" then 0 else (.z | (if startswith("-") then -1 else 1 end) * ((.[1:3] | tonumber) * 3600 + (.[-2:] | tonumber) * 60)) end)) catch null) // null) else null end;
  def phase: if . == null then null
    elif . == "failed" then "failed"
    elif test("^(created|starting|replacing|updating|stopping|migrating|launching)") then "building"
    elif test("^destroy") then "canceled"
    else "ready" end;
  def live: map(select((.state // "") | test("^destroy") | not));
'

fly_meta() {
  printf '{"id":"fly","label":"Fly.io","noun":"app","defaultOn":false,"keyEnv":["FLY_API_TOKEN"],"keychain":"%s","caps":{"off":false,"sha":false,"cancel":false,"rollback":false,"logs":false,"preview":false}}\n' "$FLY_KEYCHAIN"
}

fly_ready() { command -v curl >/dev/null 2>&1 && command -v jq >/dev/null 2>&1 && fly_key >/dev/null 2>&1; }

fly_apps() {
  local org out
  org="$(fly_org)" || return 1
  out="$(fly_call GET "/apps?org_slug=$org")" || return 1
  printf '%s' "$out" | jq -e '.apps | type == "array"' >/dev/null 2>&1 || { echo "Fly.io answered without an app list" >&2; return 1; }
  printf '%s' "$out"
}

fly_machines() {  # fly_machines <app>: the machines as a JSON array
  local out
  out="$(fly_call GET "/apps/$1/machines")" || return 1
  printf '%s' "$out" | jq -e 'type == "array"' >/dev/null 2>&1 || { echo "Fly.io answered without a machine list for $1" >&2; return 1; }
  printf '%s' "$out"
}

fly_has() {
  fly_valid "$1" || return 1
  local id
  id="$(fly_apps 2>/dev/null | jq -r --arg n "$1" '.apps[] | select(.name == $n) | .name' | head -n 1)"
  [ -n "$id" ] && printf '%s\n' "$id"
}

fly_json() {
  local apps name ms rows="" row
  apps="$(fly_apps)" || die "Could not list Fly.io apps"
  while IFS= read -r name; do
    [ -n "$name" ] || continue
    if ms="$(fly_machines "$name" 2>&1)"; then row="$(jq -nc --arg n "$name" --argjson ms "$ms" '{name:$n, ms:$ms}')"
    else row="$(jq -nc --arg n "$name" --arg e "$ms" '{name:$n, ms:[], err:$e}')"; fi
    rows="$rows$row"$'\n'
  done < <(printf '%s' "$apps" | jq -r '.apps[].name')
  printf '%s' "$rows" | jq -s "$FLY_JQ"'
    map(. as $a | ($a.ms | live) as $m
      | ($m | sort_by(.updated_at // "") | last // {}) as $new
      | ([$m[].state | phase] ) as $ph
      | {name:$a.name, id:$a.name, auto:false, deployable:true,
         paused:(($m | length) > 0 and ([$m[] | select(.state == "started")] | length) == 0),
         repo:null, ref:null, domain:($a.name + ".fly.dev"), url:("https://" + $a.name + ".fly.dev"),
         dashboardUrl:("https://fly.io/apps/" + $a.name),
         lastAt:($new.updated_at | t), lastState:($new.state // null), lastSha:null,
         lastMsg:(($new.config.metadata.fly_release_version // null) | if . then "release v\(.)" else null end),
         fetchError:(.err // null),
         phase:(if .err then null elif ($ph | length) == 0 then null
                elif ($ph | index("failed")) then "failed" elif ($ph | index("building")) then "building"
                elif ($ph | index("canceled")) and (($ph | unique | length) == 1) then "canceled" else "ready" end),
         latestId:($new.id // null)})
    | sort_by(.name | ascii_downcase)'
}

# Fly has no push-build to switch off: an app deploys when `fly deploy` runs.
fly_off() { die "Fly.io cannot turn auto-deploy off: Fly builds only when you run \`fly deploy\` or your CI does"; }
fly_cancel() { die "Fly.io cannot cancel a restart from here"; }
fly_rollback() { die "Fly.io cannot roll back from here: use \`fly releases\` and \`fly deploy --image <earlier image>\`"; }
fly_logs() { die "Fly.io cannot show logs from here: use \`fly logs -a $1\`"; }

# fly_deploy_json <app>: restart the machines that are running, one after another, on the image
# they have. The id is the first machine; its state is what `status` follows.
fly_deploy_json() {
  local app="${1:-}" ms ids first id lock="" n=0 done_="" out
  shift || true
  while [ $# -gt 0 ]; do
    case "$1" in
      --preview) die "Fly.io cannot deploy a preview from here" ;;
      --sha) die "Fly.io cannot deploy a given commit from here: it restarts the image the machines have" ;;
      --no-cache) die "Fly.io cannot build without a cache from here: it restarts the image the machines have" ;;
      "") ;;
      *) die "Unknown option $1. Usage: deploy-json <app>" ;;
    esac; shift
  done
  fly_valid "$app" || die "Fly.io: \"$app\" is not an app name"
  if declare -F start_lock >/dev/null; then lock="$(start_lock "fly-$app")" || exit 1; fi
  ms="$(fly_machines "$app")" || { rm -f "$lock"; die "Fly.io: could not read the machines of $app"; }
  ids="$(printf '%s' "$ms" | jq -r '.[] | select(.state == "started") | .id')"
  [ -n "$ids" ] || { rm -f "$lock"; die "Fly.io: $app has no running machine to restart"; }
  first="$(printf '%s\n' "$ids" | head -n 1)"
  while IFS= read -r id; do
    [ -n "$id" ] || continue
    case "$id" in *[!A-Za-z0-9]*) rm -f "$lock"; die "Fly.io: odd machine id \"$id\"" ;; esac
    if ! out="$(fly_call POST "/apps/$app/machines/$id/restart" 2>&1)"; then
      rm -f "$lock"; die "Fly.io: restarting machine $id of $app failed${done_:+ (restarted before: $done_)}: $out"
    fi
    done_="${done_:+$done_ }$id"; n=$((n + 1))
  done <<< "$ids"
  jq -nc --arg id "$first" --arg u "https://$app.fly.dev" --argjson n "$n" \
    '{id:$id, url:$u, state:"restarting", phase:"building", machines:$n}'
}

# One TSV line from a machine: <id> <phase> <state>.
fly_tsv() { jq -r "$FLY_JQ"'if . == null then "none\t\t?" else "\(.id)\t\(.state | phase)\t\(.state)" end'; }

fly_status() {
  local app="$1" d="${2:-}" m
  fly_valid "$app" && [ -n "$d" ] || die "Usage: status <app> <machine id>"
  case "$d" in *[!A-Za-z0-9]*) die "Fly.io: odd machine id \"$d\"" ;; esac
  m="$(fly_call GET "/apps/$app/machines/$d")" || die "Fly.io: could not read machine $d"
  printf '%s' "$m" | jq -e 'type == "object" and has("id") and has("state")' >/dev/null 2>&1 || die "Fly.io answered without a machine for $d"
  printf '%s\n' "$m" | fly_tsv
}
fly_cli_status() { fly_call GET "/apps/$1/machines/$2"; }

fly_latest() {
  local ms
  fly_valid "$1" || die "Fly.io: \"$1\" is not an app name"
  ms="$(fly_machines "$1")" || die "Fly.io: could not read the machines of $1"
  printf '%s' "$ms" | jq -c "$FLY_JQ"'live | sort_by(.updated_at // "") | last // null' | fly_tsv
}
fly_cli_latest() { fly_machines "$1"; }

fly_url() {
  fly_valid "$1" || die "Fly.io: \"$1\" is not an app name"
  if [ "${2:-}" = --dashboard ]; then echo "https://fly.io/apps/$1"; else echo "https://$1.fly.dev"; fi
}

fly_setup_hint() { echo "fly tokens create org, then: pbpaste | deploys fly set-key   (or set FLY_API_TOKEN; FLY_ORG names the organization, default personal)"; }

fly_set_key() {
  local key=""
  if [ -t 0 ]; then IFS= read -rs key || true; echo >&2; else IFS= read -r key || true; fi
  key="$(printf "%s" "$key" | tr -d "\r" | sed "s/^[[:space:]]*//; s/[[:space:]]*\$//")"
  [ -n "$key" ] || die "Pipe the token in: pbpaste | deploys fly set-key"
  # "FlyV1 fm2_…" has one space; anything else with a space, a quote or a backslash is no token.
  case "$key" in "FlyV1 "*) [[ "${key#FlyV1 }" != *[[:space:]]* ]] || die "That does not look like a Fly.io token" ;; *[[:space:]]*) die "That does not look like a Fly.io token" ;; esac
  case "$key" in *\'*|*\"*|*\\*|*[[:cntrl:]]*) die "That does not look like a Fly.io token" ;; esac
  ( FLY_API_TOKEN="$key"; key_of() { printf '%s' "$FLY_API_TOKEN"; }; fly_apps >/dev/null ) || die "Fly.io did not accept that token; nothing was saved"
  printf 'add-generic-password -U -a %s -s %s -w %s\n' "${USER:-$(id -un)}" "$FLY_KEYCHAIN" "$key" | security -i >/dev/null \
    || die "The token works, but could not be saved in the keychain"
  echo "Fly.io token saved and working."
}

fly_doctor() {
  local src="missing" ok=false err="" n=null e org=""
  org="$(fly_org 2>/dev/null)" || org=""
  if [ -n "${FLY_API_TOKEN:-}" ]; then src="env"
  elif security find-generic-password -a "${USER:-$(id -un)}" -s "$FLY_KEYCHAIN" >/dev/null 2>&1; then src="keychain"; fi
  if [ "$src" != missing ] && [ -n "$org" ]; then
    e="$(mktemp)"
    if n="$(fly_apps 2>"$e" | jq '.apps | length' 2>/dev/null)" && [ -n "$n" ]; then ok=true; else n=null; err="$(tail -n 1 "$e")"; fi
    rm -f "$e"
  fi
  jq -n --arg src "$src" --argjson ok "$ok" --arg err "$err" --argjson n "${n:-null}" --arg org "$org" \
    '{provider:"fly", key:$src, keyOk:$ok, org:(if $org == "" then null else $org end),
      error:(if $err == "" then null else $err end), apps:$n, expiresAt:null, rateLimit:null}'
}
