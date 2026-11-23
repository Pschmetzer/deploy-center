#!/bin/bash
# providers/deno.sh — the Deno Deploy provider for `deploys` (opt-in: deploys providers enable deno).
#
# Deno Deploy builds from the GitHub integration (or `deployctl` in CI). From here the Deploy API
# (api.deno.com/v1) can read the projects of one organization and their deployments, and start a
# redeploy of the newest deployment. So "deploy" here means "redeploy the newest deployment as
# production", never "build another commit" (docs/providers/deno.md).
#
# Contract (docs/PROVIDERS.md): deno_meta, _ready, _json, _has, _off, _deploy_json, _status,
# _latest, _cancel, _rollback, _logs, _url, _set_key, _doctor. Phases: queued | building | ready | failed | canceled.
#
# Token: DENO_DEPLOY_TOKEN (an organization access token), else the keychain item deploy-center-deno.
# The token goes to curl on stdin (lib/http.sh), never as an argument. Organization id:
# DENO_DEPLOY_ORG, else "org" in <config>/deno.json.

DENO_KEYCHAIN="deploy-center-deno"
DENO_API="${DENO_API:-https://api.deno.com/v1}"

declare -F die >/dev/null || die() { echo "Error: $*" >&2; exit 1; }
# shellcheck source=../lib/http.sh
declare -F http_call >/dev/null || { _deno_h="$(dirname "${BASH_SOURCE[0]}")/../lib/http.sh"; [ ! -f "$_deno_h" ] || . "$_deno_h"; unset _deno_h; }

deno_config_dir() { echo "${CONFIG_DIR:-${DEPLOYS_CONFIG:-$HOME/.config/deploys}}"; }

deno_key() {
  local k=""
  if declare -F key_of >/dev/null; then k="$(key_of deno 2>/dev/null)" || k=""
  elif [ -n "${DENO_DEPLOY_TOKEN:-}" ]; then k="$DENO_DEPLOY_TOKEN"
  else k="$(security find-generic-password -a "${USER:-$(id -un)}" -s "$DENO_KEYCHAIN" -w 2>/dev/null)" || k=""
  fi
  [ -n "$k" ] || { echo "No Deno Deploy token. Create an organization access token in the Deno Deploy dashboard, then: pbpaste | deploys deno set-key (or set DENO_DEPLOY_TOKEN)" >&2; return 1; }
  printf '%s' "$k"
}

# The organization id whose projects are listed (a UUID).
deno_org() {
  local o="${DENO_DEPLOY_ORG:-}" f
  if [ -z "$o" ]; then f="$(deno_config_dir)/deno.json"; [ ! -f "$f" ] || o="$(jq -r '.org // empty' "$f" 2>/dev/null)"; fi
  [ -n "$o" ] || { echo "Deno Deploy: no organization. Set DENO_DEPLOY_ORG (the organization id from the dashboard URL) or {\"org\":\"<id>\"} in $(deno_config_dir)/deno.json" >&2; return 1; }
  case "$o" in *[!A-Za-z0-9-]*) echo "Deno Deploy: \"$o\" is not an organization id" >&2; return 1 ;; esac
  printf '%s' "$o"
}

# deno_call METHOD PATH [BODY]: the answer on stdout; on failure the reason on stderr, rc 1.
deno_call() {
  local k e rc=0 fix="pbpaste | deploys deno set-key"
  declare -F http_call >/dev/null || { echo "Deno Deploy: lib/http.sh is missing" >&2; return 1; }
  k="$(deno_key)" || return 1
  [ -z "${DENO_DEPLOY_TOKEN:-}" ] || fix="check DENO_DEPLOY_TOKEN in the environment"
  # shellcheck disable=SC2034  # read by http_call
  local HTTP_AUTH="Authorization: Bearer $k" HTTP_FIX="$fix"
  e="$(mktemp)"
  ( http_call "Deno Deploy" "$1" "$DENO_API$2" "${3:-}" ) 2>"$e" || rc=$?
  [ "$rc" = 0 ] || sed '1s/^[^ ]*Error:[^ ]* //' "$e" >&2
  rm -f "$e"; return "$rc"
}

# Project names are lowercase letters, digits and dashes; a deployment id is letters and digits.
deno_valid() { case "$1" in ''|-*|*[!a-z0-9-]*) return 1 ;; esac; }
deno_valid_id() { case "$1" in ''|*[!A-Za-z0-9_-]*) return 1 ;; esac; }

# shellcheck disable=SC2016
DENO_JQ='
  def t: (. // null) | if . then ((try (capture("^(?<d>[0-9]{4}-[0-9]{2}-[0-9]{2}T[0-9]{2}:[0-9]{2}:[0-9]{2})(\\.[0-9]+)?(?<z>Z|[+-][0-9]{2}:?[0-9]{2})?$") | (.d + "Z" | fromdateiso8601) - (if (.z // "Z") == "Z" then 0 else (.z | (if startswith("-") then -1 else 1 end) * ((.[1:3] | tonumber) * 3600 + (.[-2:] | tonumber) * 60)) end)) catch null) // null) else null end;
  def phase: if . == null then null
    elif . == "failed" then "failed"
    elif . == "success" then "ready"
    elif . == "queued" then "queued"
    elif . == "pending" or . == "building" or . == "deploying" then "building"
    else null end;
'

deno_meta() {
  printf '{"id":"deno","label":"Deno Deploy","noun":"project","defaultOn":false,"keyEnv":["DENO_DEPLOY_TOKEN"],"keychain":"%s","caps":{"off":false,"sha":false,"cancel":false,"rollback":false,"logs":false,"preview":false}}\n' "$DENO_KEYCHAIN"
}

deno_ready() { command -v curl >/dev/null 2>&1 && command -v jq >/dev/null 2>&1 && deno_key >/dev/null 2>&1 && deno_org >/dev/null 2>&1; }

deno_projects() {
  local org out
  org="$(deno_org)" || return 1
  out="$(deno_call GET "/organizations/$org/projects?limit=100")" || return 1
  printf '%s' "$out" | jq -e 'type == "array"' >/dev/null 2>&1 || { echo "Deno Deploy answered without a project list" >&2; return 1; }
  printf '%s' "$out"
}

deno_deployments() {  # deno_deployments <project id>: newest first
  local out
  out="$(deno_call GET "/projects/$1/deployments?limit=20")" || return 1
  printf '%s' "$out" | jq -e 'type == "array"' >/dev/null 2>&1 || { echo "Deno Deploy answered without a deployment list for $1" >&2; return 1; }
  printf '%s' "$out" | jq -c 'sort_by(.createdAt // "") | reverse'
}

deno_has() {
  deno_valid "$1" || return 1
  local id
  id="$(deno_projects 2>/dev/null | jq -r --arg n "$1" '.[] | select(.name == $n) | .name' | head -n 1)"
  [ -n "$id" ] && printf '%s\n' "$id"
}

deno_json() {
  local ps name ds rows="" row
  ps="$(deno_projects)" || die "Could not list Deno Deploy projects"
  while IFS= read -r name; do
    [ -n "$name" ] || continue
    if ds="$(deno_deployments "$name" 2>&1)"; then row="$(jq -nc --arg n "$name" --argjson ds "$ds" '{name:$n, ds:$ds}')"
    else row="$(jq -nc --arg n "$name" --arg e "$ds" '{name:$n, ds:[], err:$e}')"; fi
    rows="$rows$row"$'\n'
  done < <(printf '%s' "$ps" | jq -r '.[].name')
  printf '%s' "$rows" | jq -s "$DENO_JQ"'
    map(. as $p | ($p.ds | first // null) as $new
      | {name:$p.name, id:$p.name, auto:false, deployable:($p.ds | length > 0), paused:false,
         repo:null, ref:null, domain:($p.name + ".deno.dev"), url:("https://" + $p.name + ".deno.dev"),
         dashboardUrl:("https://dash.deno.com/projects/" + $p.name),
         lastAt:($new.createdAt | t), lastState:($new.status // null),
         lastSha:($new.relatedCommit.hash // null), lastMsg:($new.relatedCommit.message // null),
         fetchError:(.err // null),
         phase:(if .err then null else ($new.status | phase) end),
         latestId:($new.id // null)})
    | sort_by(.name | ascii_downcase)'
}

# Deno Deploy builds from its GitHub integration or deployctl; this tool does not switch that.
deno_off() { die "Deno Deploy cannot turn auto-deploy off from here: change the Git integration in the dashboard"; }
deno_cancel() { die "Deno Deploy cannot cancel a deployment from here"; }
deno_rollback() { die "Deno Deploy cannot roll back from here: promote an earlier deployment in the dashboard"; }
deno_logs() { die "Deno Deploy cannot show build logs from here: open the deployment in the dashboard"; }

# deno_deploy_json <project>: redeploy the newest deployment as production.
deno_deploy_json() {
  local p="${1:-}" ds newest lock="" out
  shift || true
  while [ $# -gt 0 ]; do
    case "$1" in
      --preview) die "Deno Deploy cannot deploy a preview from here" ;;
      --sha) die "Deno Deploy cannot deploy a given commit from here: it redeploys the newest deployment" ;;
      --no-cache) die "Deno Deploy cannot build without a cache from here" ;;
      "") ;;
      *) die "Unknown option $1. Usage: deploy-json <project>" ;;
    esac; shift
  done
  deno_valid "$p" || die "Deno Deploy: \"$p\" is not a project name"
  if declare -F start_lock >/dev/null; then lock="$(start_lock "deno-$p")" || exit 1; fi
  ds="$(deno_deployments "$p")" || { rm -f "$lock"; die "Deno Deploy: could not read the deployments of $p"; }
  newest="$(printf '%s' "$ds" | jq -r '.[0].id // empty')"
  [ -n "$newest" ] || { rm -f "$lock"; die "Deno Deploy: $p has no deployment to redeploy"; }
  deno_valid_id "$newest" || { rm -f "$lock"; die "Deno Deploy: odd deployment id \"$newest\""; }
  if ! out="$(deno_call POST "/deployments/$newest/redeploy" '{"production":true}' 2>&1)"; then
    rm -f "$lock"; die "Deno Deploy: redeploying $p failed: $out"
  fi
  printf '%s' "$out" | jq -e 'type == "object" and has("id")' >/dev/null 2>&1 || { rm -f "$lock"; die "Deno Deploy answered without a deployment for the redeploy of $p"; }
  printf '%s' "$out" | jq -c --arg u "https://$p.deno.dev" "$DENO_JQ"'{id:.id, url:$u, state:(.status // "pending"), phase:((.status // "pending") | phase)}'
}

# One TSV line from a deployment: <id> <phase> <state>.
deno_tsv() { jq -r "$DENO_JQ"'if . == null then "none\t\tnone" else "\(.id)\t\(.status | phase)\t\(.status)" end'; }

deno_status() {
  local p="$1" d="${2:-}" m
  deno_valid "$p" && [ -n "$d" ] || die "Usage: status <project> <deployment id>"
  deno_valid_id "$d" || die "Deno Deploy: odd deployment id \"$d\""
  m="$(deno_call GET "/deployments/$d")" || die "Deno Deploy: could not read deployment $d"
  printf '%s' "$m" | jq -e 'type == "object" and has("id") and has("status")' >/dev/null 2>&1 || die "Deno Deploy answered without a deployment for $d"
  printf '%s\n' "$m" | deno_tsv
}
deno_cli_status() { deno_call GET "/deployments/$2"; }

deno_latest() {
  local ds
  deno_valid "$1" || die "Deno Deploy: \"$1\" is not a project name"
  ds="$(deno_deployments "$1")" || die "Deno Deploy: could not read the deployments of $1"
  printf '%s' "$ds" | jq -c '.[0] // null' | deno_tsv
}
deno_cli_latest() { deno_deployments "$1"; }

deno_url() {
  deno_valid "$1" || die "Deno Deploy: \"$1\" is not a project name"
  if [ "${2:-}" = --dashboard ]; then echo "https://dash.deno.com/projects/$1"; else echo "https://$1.deno.dev"; fi
}

deno_setup_hint() { echo "create an organization access token in the Deno Deploy dashboard, then: pbpaste | deploys deno set-key   (or set DENO_DEPLOY_TOKEN; DENO_DEPLOY_ORG names the organization id)"; }

deno_set_key() {
  local key=""
  if [ -t 0 ]; then IFS= read -rs key || true; echo >&2; else IFS= read -r key || true; fi
  key="$(printf "%s" "$key" | tr -d "\r" | sed "s/^[[:space:]]*//; s/[[:space:]]*\$//")"
  [ -n "$key" ] || die "Pipe the token in: pbpaste | deploys deno set-key"
  case "$key" in *[[:space:]]*|*\'*|*\"*|*\\*|*[[:cntrl:]]*) die "That does not look like a Deno Deploy token" ;; esac
  ( DENO_DEPLOY_TOKEN="$key"; key_of() { printf '%s' "$DENO_DEPLOY_TOKEN"; }; deno_projects >/dev/null ) || die "Deno Deploy did not accept that token; nothing was saved"
  printf 'add-generic-password -U -a %s -s %s -w %s\n' "${USER:-$(id -un)}" "$DENO_KEYCHAIN" "$key" | security -i >/dev/null \
    || die "The token works, but could not be saved in the keychain"
  echo "Deno Deploy token saved and working."
}

deno_doctor() {
  local src="missing" ok=false err="" n=null e org=""
  org="$(deno_org 2>/dev/null)" || org=""
  if [ -n "${DENO_DEPLOY_TOKEN:-}" ]; then src="env"
  elif security find-generic-password -a "${USER:-$(id -un)}" -s "$DENO_KEYCHAIN" >/dev/null 2>&1; then src="keychain"; fi
  if [ "$src" != missing ] && [ -n "$org" ]; then
    e="$(mktemp)"
    if n="$(deno_projects 2>"$e" | jq 'length' 2>/dev/null)" && [ -n "$n" ]; then ok=true; else n=null; err="$(tail -n 1 "$e")"; fi
    rm -f "$e"
  fi
  jq -n --arg src "$src" --argjson ok "$ok" --arg err "$err" --argjson n "${n:-null}" --arg org "$org" \
    '{provider:"deno", key:$src, keyOk:$ok, org:(if $org == "" then null else $org end),
      error:(if $err == "" then null else $err end), projects:$n, expiresAt:null, rateLimit:null}'
}
