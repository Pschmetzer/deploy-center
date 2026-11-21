#!/bin/bash
# providers/koyeb.sh — the Koyeb provider for `deploys` (opt-in: deploys providers enable koyeb).
#
# Koyeb builds from its Git integration (or a registry image). From here the API
# (app.koyeb.com/v1) can read services and their deployments and redeploy a service: "deploy"
# here means "redeploy the service with its current definition" (docs/providers/koyeb.md); it
# never builds another commit.
#
# Contract (docs/PROVIDERS.md): koyeb_meta, _ready, _json, _has, _off, _deploy_json, _status,
# _latest, _cancel, _rollback, _logs, _url, _set_key, _doctor. Phases: queued | building | ready | failed | canceled.
#
# Token: KOYEB_TOKEN (an API token), else the keychain item deploy-center-koyeb. It goes to curl
# on stdin (lib/http.sh), never as an argument.

KOYEB_KEYCHAIN="deploy-center-koyeb"
KOYEB_API="${KOYEB_API:-https://app.koyeb.com/v1}"

declare -F die >/dev/null || die() { echo "Error: $*" >&2; exit 1; }
# shellcheck source=../lib/http.sh
declare -F http_call >/dev/null || { _koyeb_h="$(dirname "${BASH_SOURCE[0]}")/../lib/http.sh"; [ ! -f "$_koyeb_h" ] || . "$_koyeb_h"; unset _koyeb_h; }

koyeb_key() {
  local k=""
  if declare -F key_of >/dev/null; then k="$(key_of koyeb 2>/dev/null)" || k=""
  elif [ -n "${KOYEB_TOKEN:-}" ]; then k="$KOYEB_TOKEN"
  else k="$(security find-generic-password -a "${USER:-$(id -un)}" -s "$KOYEB_KEYCHAIN" -w 2>/dev/null)" || k=""
  fi
  [ -n "$k" ] || { echo "No Koyeb token. Create an API token in the Koyeb console (Organization settings), then: pbpaste | deploys koyeb set-key (or set KOYEB_TOKEN)" >&2; return 1; }
  printf '%s' "$k"
}

# koyeb_call METHOD PATH [BODY]: the answer on stdout; on failure the reason on stderr, rc 1.
koyeb_call() {
  local k e rc=0 fix="pbpaste | deploys koyeb set-key"
  declare -F http_call >/dev/null || { echo "Koyeb: lib/http.sh is missing" >&2; return 1; }
  k="$(koyeb_key)" || return 1
  [ -z "${KOYEB_TOKEN:-}" ] || fix="check KOYEB_TOKEN in the environment"
  e="$(mktemp)"
  # HTTP_AUTH and HTTP_FIX are read by http_call: set for that one call only.
  ( HTTP_AUTH="Authorization: Bearer $k" HTTP_FIX="$fix" http_call "Koyeb" "$1" "$KOYEB_API$2" "${3:-}" ) 2>"$e" || rc=$?
  [ "$rc" = 0 ] || sed '1s/^[^ ]*Error:[^ ]* //' "$e" >&2
  rm -f "$e"; return "$rc"
}

# Service ids and deployment ids are UUIDs (letters, digits, dashes).
koyeb_valid() { case "$1" in ''|-*|*[!A-Za-z0-9-]*) return 1 ;; esac; }

KOYEB_JQ='
  def t: (. // null) | if . then (sub("\\.[0-9]+Z";"Z") | try fromdateiso8601 catch null) else null end;
  def phase: if . == null then null
    elif test("^(PENDING|PROVISIONING|SCHEDULED|ALLOCATING|STARTING|HEALTHY_PENDING)$") then "building"
    elif . == "STASHED" or . == "ERRORING" or . == "ERROR" or . == "UNHEALTHY" or . == "DEGRADED" then "failed"
    elif . == "CANCELED" or . == "CANCELING" or . == "STOPPED" or . == "STOPPING" or . == "ERASED" or . == "ERASING" then "canceled"
    elif . == "HEALTHY" or . == "RUNNING" or . == "SLEEPING" then "ready"
    else null end;
'

koyeb_meta() {
  printf '{"id":"koyeb","label":"Koyeb","noun":"service","defaultOn":false,"keyEnv":["KOYEB_TOKEN"],"keychain":"%s","caps":{"off":false,"sha":false,"cancel":false,"rollback":false,"logs":false,"preview":false}}\n' "$KOYEB_KEYCHAIN"
}

koyeb_ready() { command -v curl >/dev/null 2>&1 && command -v jq >/dev/null 2>&1 && koyeb_key >/dev/null 2>&1; }

koyeb_services() {
  local out
  out="$(koyeb_call GET "/services?limit=100")" || return 1
  printf '%s' "$out" | jq -e '.services | type == "array"' >/dev/null 2>&1 || { echo "Koyeb answered without a service list" >&2; return 1; }
  printf '%s' "$out"
}

koyeb_has() {
  local id
  case "$1" in ''|*[!A-Za-z0-9._-]*) return 1 ;; esac
  id="$(koyeb_services 2>/dev/null | jq -r --arg n "$1" '.services[] | select(.name == $n or .id == $n) | .id' | head -n 1)"
  [ -n "$id" ] && printf '%s\n' "$id"
}

koyeb_json() {
  local out
  out="$(koyeb_services)" || die "Could not list Koyeb services"
  printf '%s' "$out" | jq "$KOYEB_JQ"'
    [.services[] | . as $s
      | {name:$s.name, id:$s.id, auto:false, deployable:true,
         paused:(($s.status // "") | test("^(PAUSED|PAUSING)$")),
         repo:null, ref:null, domain:null, url:null,
         dashboardUrl:("https://app.koyeb.com/services/" + $s.id),
         lastAt:(($s.updated_at // $s.created_at) | t), lastState:($s.status // null),
         lastSha:($s.active_deployment_id // null), lastMsg:null,
         fetchError:null, phase:(($s.status // null) | phase),
         latestId:($s.latest_deployment_id // null)}]
    | sort_by(.name | ascii_downcase)'
}

koyeb_off() { die "Koyeb cannot turn auto-deploy off from here: change the Git integration in the console"; }
koyeb_cancel() { die "Koyeb cannot cancel a deployment from here"; }
koyeb_rollback() { die "Koyeb cannot roll back from here: redeploy an earlier deployment in the console"; }
koyeb_logs() { die "Koyeb cannot show build logs from here: use \`koyeb services logs $1\`"; }

# koyeb_deploy_json <service id>: redeploy the service with its current definition.
koyeb_deploy_json() {
  local id="${1:-}" lock="" out
  shift || true
  while [ $# -gt 0 ]; do
    case "$1" in
      --preview) die "Koyeb cannot deploy a preview from here" ;;
      --sha) die "Koyeb cannot deploy a given commit from here: it redeploys the service as defined" ;;
      --no-cache) die "Koyeb cannot build without a cache from here" ;;
      "") ;;
      *) die "Unknown option $1. Usage: deploy-json <service id>" ;;
    esac; shift
  done
  koyeb_valid "$id" || die "Koyeb: \"$id\" is not a service id"
  if declare -F start_lock >/dev/null; then lock="$(start_lock "koyeb-$id")" || exit 1; fi
  # Read the service first: a missing id or a rate limit ends here, before anything is sent.
  out="$(koyeb_call GET "/services/$id" 2>&1)" || { rm -f "$lock"; die "Koyeb: could not read service $id: $out"; }
  printf '%s' "$out" | jq -e '.service.id' >/dev/null 2>&1 || { rm -f "$lock"; die "Koyeb answered without a service for $id"; }
  if ! out="$(koyeb_call POST "/services/$id/redeploy" '{}' 2>&1)"; then
    rm -f "$lock"; die "Koyeb: redeploying $id failed: $out"
  fi
  printf '%s' "$out" | jq -e '.deployment.id' >/dev/null 2>&1 || { rm -f "$lock"; die "Koyeb answered without a deployment for the redeploy of $id"; }
  printf '%s' "$out" | jq -c "$KOYEB_JQ"'.deployment | {id:.id, url:null, state:(.status // "PENDING"), phase:((.status // "PENDING") | phase)}'
}

# One TSV line from a deployment: <id> <phase> <state>.
koyeb_tsv() { jq -r "$KOYEB_JQ"'if . == null then "none\t\tnone" else "\(.id)\t\(.status | phase)\t\(.status)" end'; }

koyeb_status() {
  local s="$1" d="${2:-}" m
  koyeb_valid "$s" && koyeb_valid "$d" || die "Usage: status <service id> <deployment id>"
  m="$(koyeb_call GET "/deployments/$d")" || die "Koyeb: could not read deployment $d"
  printf '%s' "$m" | jq -e '.deployment | type == "object" and has("id") and has("status")' >/dev/null 2>&1 || die "Koyeb answered without a deployment for $d"
  printf '%s\n' "$m" | jq -c '.deployment' | koyeb_tsv
}
koyeb_cli_status() { koyeb_call GET "/deployments/$2"; }

koyeb_latest() {
  local out
  koyeb_valid "$1" || die "Koyeb: \"$1\" is not a service id"
  out="$(koyeb_call GET "/deployments?service_id=$1&limit=1")" || die "Koyeb: could not read the deployments of $1"
  printf '%s' "$out" | jq -e '.deployments | type == "array"' >/dev/null 2>&1 || die "Koyeb answered without a deployment list for $1"
  printf '%s' "$out" | jq -c '.deployments[0] // null' | koyeb_tsv
}
koyeb_cli_latest() { koyeb_call GET "/deployments?service_id=$1&limit=1"; }

koyeb_url() {
  koyeb_valid "$1" || die "Koyeb: \"$1\" is not a service id"
  echo "https://app.koyeb.com/services/$1"
}

koyeb_setup_hint() { echo "create an API token in the Koyeb console, then: pbpaste | deploys koyeb set-key   (or set KOYEB_TOKEN)"; }

koyeb_set_key() {
  local key=""
  if [ -t 0 ]; then IFS= read -rs key || true; echo >&2; else IFS= read -r key || true; fi
  key="$(printf "%s" "$key" | tr -d "\r" | sed "s/^[[:space:]]*//; s/[[:space:]]*\$//")"
  [ -n "$key" ] || die "Pipe the token in: pbpaste | deploys koyeb set-key"
  case "$key" in *[[:space:]]*|*\'*|*\"*|*\\*|*[[:cntrl:]]*) die "That does not look like a Koyeb token" ;; esac
  ( KOYEB_TOKEN="$key"; key_of() { printf '%s' "$KOYEB_TOKEN"; }; koyeb_services >/dev/null ) || die "Koyeb did not accept that token; nothing was saved"
  printf 'add-generic-password -U -a %s -s %s -w %s\n' "${USER:-$(id -un)}" "$KOYEB_KEYCHAIN" "$key" | security -i >/dev/null \
    || die "The token works, but could not be saved in the keychain"
  echo "Koyeb token saved and working."
}

koyeb_doctor() {
  local src="missing" ok=false err="" n=null e
  if [ -n "${KOYEB_TOKEN:-}" ]; then src="env"
  elif security find-generic-password -a "${USER:-$(id -un)}" -s "$KOYEB_KEYCHAIN" >/dev/null 2>&1; then src="keychain"; fi
  if [ "$src" != missing ]; then
    e="$(mktemp)"
    if n="$(koyeb_services 2>"$e" | jq '.services | length' 2>/dev/null)" && [ -n "$n" ]; then ok=true; else n=null; err="$(tail -n 1 "$e")"; fi
    rm -f "$e"
  fi
  jq -n --arg src "$src" --argjson ok "$ok" --arg err "$err" --argjson n "${n:-null}" \
    '{provider:"koyeb", key:$src, keyOk:$ok, error:(if $err == "" then null else $err end),
      services:$n, expiresAt:null, rateLimit:null}'
}
