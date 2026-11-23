#!/bin/bash
# providers/railway.sh — the Railway provider for `deploys` (opt-in: deploys providers enable railway).
#
# Railway has one GraphQL endpoint. A "project" there holds services; one service in one
# environment (production, else the first) is one item here, and its id is
# "<service id>:<environment id>". A deploy is Railway's "redeploy" of the service's newest
# deployment (the same source, built again); it never takes a commit, and it is not a preview.
#
# Contract (docs/PROVIDERS.md): railway_meta, _ready, _json, _has, _off, _deploy_json, _status,
# _latest, _cancel, _rollback, _logs, _url, _set_key, _doctor. Phases: queued | building | ready | failed | canceled.
#
# Token: RAILWAY_API_TOKEN (an account or workspace token; a project token cannot list projects),
# else the keychain item deploy-center-railway. It goes to curl on stdin, never as an argument.
# Queries and mutations are made here; variables go in the JSON body, never into the query text.

RAILWAY_KEYCHAIN="deploy-center-railway"
RAILWAY_API="${RAILWAY_API:-https://backboard.railway.com/graphql/v2}"

declare -F die >/dev/null || die() { echo "Error: $*" >&2; exit 1; }
# shellcheck source=../lib/http.sh
declare -F curl_cfg_quote >/dev/null || { _ra_h="$(dirname "${BASH_SOURCE[0]}")/../lib/http.sh"; [ ! -f "$_ra_h" ] || . "$_ra_h"; unset _ra_h; }

railway_key() {
  local k=""
  if declare -F key_of >/dev/null; then k="$(key_of railway 2>/dev/null)" || k=""
  elif [ -n "${RAILWAY_API_TOKEN:-}" ]; then k="$RAILWAY_API_TOKEN"
  else k="$(security find-generic-password -a "${USER:-$(id -un)}" -s "$RAILWAY_KEYCHAIN" -w 2>/dev/null)" || k=""
  fi
  [ -n "$k" ] || { echo "No Railway token. Create one at railway.com/account/tokens (an account or workspace token), then: pbpaste | deploys railway set-key (or set RAILWAY_API_TOKEN)" >&2; return 1; }
  printf '%s' "$k"
}

# railway_gql <query> [<variables as JSON>]: the "data" object on stdout. Every call is a POST, so
# none is repeated (one that timed out may have started a redeploy): this is curl on its own, not
# http_call, which asks again after a 429. The token goes to curl on stdin. A GraphQL error comes
# with HTTP 200, so it is checked here: the first message goes to stderr and the rc is 1.
railway_gql() {
  local q="$1" v="${2:-}" k qk body bf err out code hint="" fix="pbpaste | deploys railway set-key"
  k="$(railway_key)" || return 1
  # Escaped for curl's config line; a control character is refused without a call (see heroku_call).
  qk="$(curl_cfg_quote "$k")" || { echo "Railway: the token has a line break or control character in it (a paste mistake?): set it again without" >&2; return 1; }
  [ -n "$v" ] || v='{}'
  [ -z "${RAILWAY_API_TOKEN:-}" ] || fix="check RAILWAY_API_TOKEN in the environment"
  body="$(jq -nc --arg q "$q" --argjson v "$v" '{query:$q, variables:$v}')" || return 1
  bf="$(mktemp)"; err="$(mktemp)"; printf '%s' "$body" > "$bf"
  out="$(printf 'header = "Authorization: Bearer %s"\n' "$qk" | curl -sS --connect-timeout 10 --max-time 60 -X POST \
    -H "Content-Type: application/json" -H "Accept: application/json" -K - --data-binary "@$bf" -w '\n%{http_code}' "$RAILWAY_API" 2>"$err")" || out=$'\n000'
  code="${out##*$'\n'}"; out="${out%$'\n'*}"
  [ "$code" != 000 ] || out="$(tail -n 1 "$err")"
  rm -f "$bf" "$err"
  if [[ "$code" != 2* ]]; then
    case "$code" in
      000) hint=" (no answer: network or timeout)" ;;
      401|403) hint=" (the token is wrong or expired: $fix)" ;;
      429) hint=" (rate limit: try again in a minute)" ;;
      5*) hint=" (Railway had a problem: try again later)" ;;
    esac
    echo "Railway POST -> HTTP $code$hint: $(printf '%s' "$out" | tr '\r\n\t' '   ' | cut -c1-200)" >&2; return 1
  fi
  printf '%s' "$out" | jq -e 'type == "object"' >/dev/null 2>&1 || { echo "Railway answered without JSON: $(printf '%s' "$out" | tr '\r\n\t' '   ' | cut -c1-120)" >&2; return 1; }
  if printf '%s' "$out" | jq -e '(.errors // []) | length > 0' >/dev/null 2>&1; then
    echo "Railway: $(printf '%s' "$out" | jq -r '.errors[0].message // "an error"' | tr '\r\n\t' '   ' | cut -c1-200)" >&2; return 1
  fi
  printf '%s' "$out" | jq -ce '.data | select(type == "object")' || { echo "Railway answered without data" >&2; return 1; }
}

# shellcheck disable=SC2016
RAILWAY_LIST_Q='query { projects { edges { node { id name environments { edges { node { id name } } } services { edges { node { id name serviceInstances { edges { node { environmentId latestDeployment { id status createdAt staticUrl meta } } } } } } } } } } }'
# shellcheck disable=SC2016
RAILWAY_DEPLOYS_Q='query($s: String!, $e: String!) { deployments(first: 20, input: {serviceId: $s, environmentId: $e}) { edges { node { id status createdAt staticUrl meta canRollback } } } }'

# jq helpers. The timestamps end in Z (with or without fractions).
# shellcheck disable=SC2016
RAILWAY_JQ='
  def t: (. // null) | if . then ((try (capture("^(?<d>[0-9]{4}-[0-9]{2}-[0-9]{2}T[0-9]{2}:[0-9]{2}:[0-9]{2})(\\.[0-9]+)?(?<z>Z|[+-][0-9]{2}:?[0-9]{2})?$") | (.d + "Z" | fromdateiso8601) - (if (.z // "Z") == "Z" then 0 else (.z | (if startswith("-") then -1 else 1 end) * ((.[1:3] | tonumber) * 3600 + (.[-2:] | tonumber) * 60)) end)) catch null) // null) else null end;
  def phase: if . == null then null
    elif test("^(INITIALIZING|QUEUED|WAITING|NEEDS_APPROVAL)$") then "queued"
    elif test("^(BUILDING|DEPLOYING)$") then "building"
    elif . == "SUCCESS" then "ready"
    elif test("^(FAILED|CRASHED)$") then "failed"
    elif test("^(REMOVED|REMOVING|SKIPPED)$") then "canceled"
    else null end;
  def host($d): ($d.staticUrl // null) | if . then sub("^https?://";"") else null end;
  def dep_line: if . == null then "none\t\t?" else "\(.id)\t\(.status | phase // "")\t\(.status)" end;
'

railway_meta() {
  printf '{"id":"railway","label":"Railway","noun":"service","defaultOn":false,"keyEnv":["RAILWAY_API_TOKEN"],"keychain":"%s","caps":{"off":false,"sha":false,"cancel":true,"rollback":true,"logs":true,"preview":false}}\n' "$RAILWAY_KEYCHAIN"
}

railway_ready() { command -v curl >/dev/null 2>&1 && command -v jq >/dev/null 2>&1 && railway_key >/dev/null 2>&1; }

# <service id>:<environment id>, letters, digits and dashes (UUIDs).
railway_ids() {  # railway_ids <id>: sets RW_S and RW_E, rc 1 when it is not one
  case "$1" in *:*) ;; *) return 1 ;; esac
  RW_S="${1%%:*}"; RW_E="${1#*:}"
  case "$RW_S$RW_E" in ''|*[!A-Za-z0-9:-]*|*:*) return 1 ;; esac
  [ -n "$RW_S" ] && [ -n "$RW_E" ]
}

# The services of every project as one flat list: {project, projectId, sname, sid, eid, dep}.
railway_items() {
  local d
  d="$(railway_gql "$RAILWAY_LIST_Q")" || return 1
  printf '%s' "$d" | jq -c '
    [ (.projects.edges // [])[].node as $p
      | ($p.environments.edges | map(.node)) as $envs
      | ((($envs | map(select(.name == "production")) | .[0]) // $envs[0])) as $env
      | select($env != null)
      | $p.services.edges[].node as $s
      | {project:$p.name, projectId:$p.id, sname:$s.name, sid:$s.id, eid:$env.id, env:$env.name,
         dep:(($s.serviceInstances.edges | map(.node) | map(select(.environmentId == $env.id)) | .[0].latestDeployment) // null)} ]' 2>/dev/null \
    || { echo "Railway answered without a project list" >&2; return 1; }
}

# A service by name ("web", or "project/web" where two share a name) or by id.
railway_has() {
  local items id
  items="$(railway_items 2>/dev/null)" || return 1
  id="$(printf '%s' "$items" | jq -r --arg n "$1" '
    (map(.sname) | group_by(.) | map({(.[0]): length}) | add // {}) as $c
    | [.[] | select((if $c[.sname] > 1 then .project + "/" + .sname else .sname end) == $n or (.sid + ":" + .eid) == $n) | (.sid + ":" + .eid)] | .[0] // empty')"
  [ -n "$id" ] && printf '%s\n' "$id"
}

railway_json() {
  local items
  items="$(railway_items)" || die "Could not list Railway services"
  printf '%s' "$items" | jq "$RAILWAY_JQ"'
    (map(.sname) | group_by(.) | map({(.[0]): length}) | add // {}) as $c
    | map(. as $i | ($i.dep // {}) as $d | ($d.meta // {}) as $m
      | ($d.status | phase) as $ph
      | {name:(if $c[$i.sname] > 1 then $i.project + "/" + $i.sname else $i.sname end),
         id:($i.sid + ":" + $i.eid), auto:(($m.repo // null) != null), deployable:true, paused:false,
         repo:($m.repo // null), ref:($m.branch // null),
         domain:host($d), url:(host($d) | if . then "https://" + . else null end),
         dashboardUrl:("https://railway.com/project/" + $i.projectId + "/service/" + $i.sid + "?environmentId=" + $i.eid),
         lastAt:($d.createdAt | t), lastState:($d.status // null),
         lastSha:(if $ph == "ready" then ($m.commitHash // null) else null end),
         lastMsg:(($m.commitMessage // null) | if . then split("\n")[0] else null end),
         fetchError:null, phase:$ph, latestId:($d.id // null), environment:$i.env})
    | sort_by(.name | ascii_downcase)'
}

# Railway pushes deploy when a service is connected to a repository; switching that off is done
# in the service settings (a deployment trigger), not from here.
railway_off() { die "Railway cannot turn auto-deploy off from here: disconnect the branch in the service settings"; }

# The newest deployments of a service, newest first, as a JSON array of nodes.
railway_deploys() {  # railway_deploys <id>
  local d
  railway_ids "$1" || { echo "Railway: \"$1\" is not a service id (<service id>:<environment id>)" >&2; return 1; }
  d="$(railway_gql "$RAILWAY_DEPLOYS_Q" "$(jq -nc --arg s "$RW_S" --arg e "$RW_E" '{s:$s, e:$e}')")" || return 1
  printf '%s' "$d" | jq -ce '.deployments.edges | map(.node) | select(type == "array")' || { echo "Railway answered without deployments" >&2; return 1; }
}

railway_deploy_json() {
  local id="${1:-}" prev new="" n=0 lock="" d one
  shift || true
  while [ $# -gt 0 ]; do
    case "$1" in
      --preview) die "Railway cannot deploy a preview from here" ;;
      --sha) die "Railway cannot deploy a given commit from here: a redeploy builds the source the service has" ;;
      --no-cache) die "Railway cannot build without a cache from here" ;;
      "") ;;
      *) die "Unknown option $1. Usage: deploy-json <service id>" ;;
    esac; shift
  done
  railway_ids "$id" || die "Railway: \"$id\" is not a service id (<service id>:<environment id>)"
  if declare -F start_lock >/dev/null; then lock="$(start_lock "railway-$id")" || exit 1; fi
  d="$(railway_deploys "$id")" || { rm -f "$lock"; die "Railway: could not read the deployments of $id"; }
  prev="$(printf '%s' "$d" | jq -r '.[0].id // ""')"
  # shellcheck disable=SC2016
  railway_gql 'mutation($s: String!, $e: String!) { serviceInstanceRedeploy(serviceId: $s, environmentId: $e) }' \
    "$(jq -nc --arg s "$RW_S" --arg e "$RW_E" '{s:$s, e:$e}')" | jq -e '.serviceInstanceRedeploy == true' >/dev/null 2>&1 \
    || { rm -f "$lock"; die "Railway did not start the redeploy of $id"; }
  # The new deployment shows up a moment later: look for one that is not the previous newest.
  while [ "$n" -lt "${DEPLOYS_RAILWAY_POLLS:-5}" ]; do
    one="$(railway_deploys "$id" 2>/dev/null | jq -c --arg p "$prev" '.[0] | select(. != null and .id != $p)')" || one=""
    if [ -n "$one" ]; then new="$one"; break; fi
    n=$((n + 1)); sleep 2
  done
  if [ -z "$new" ]; then
    echo "Railway: the redeploy is accepted but its deployment is not listed yet; see: deploys railway latest $id" >&2
    jq -nc '{id:null, url:null, state:"QUEUED", phase:"queued"}'
  else
    printf '%s' "$new" | jq -c "$RAILWAY_JQ"'{id, url:(host(.) | if . then "https://" + . else null end), state:.status, phase:(.status | phase)}'
  fi
}

railway_status() {
  local id="$1" dep="${2:-}" d line
  [ -n "$dep" ] || die "Usage: status <service id> <deployment id>"
  d="$(railway_deploys "$id")" || die "Railway: could not read the deployments of $id"
  line="$(printf '%s' "$d" | jq -r --arg d "$dep" "$RAILWAY_JQ"'(map(select(.id == $d)) | .[0]) // null | dep_line')"
  [ "$line" != "$(printf 'none\t\t?')" ] || die "Railway: deployment $dep is not among the newest of $id"
  printf '%s\n' "$line"
}
railway_cli_status() { railway_deploys "$1" | jq --arg d "$2" '.[] | select(.id == $d)'; }

railway_latest() {
  local d
  d="$(railway_deploys "$1")" || die "Railway: could not read the deployments of $1"
  printf '%s' "$d" | jq -r "$RAILWAY_JQ"'.[0] // null | dep_line'
}
railway_cli_latest() { railway_deploys "$1" | jq '.[0] // null'; }

railway_cancel() {
  local dep="${2:-}"
  case "$dep" in ''|*[!A-Za-z0-9-]*) die "Railway: \"$dep\" is not a deployment id" ;; esac
  # shellcheck disable=SC2016
  railway_gql 'mutation($d: String!) { deploymentCancel(id: $d) }' "$(jq -nc --arg d "$dep" '{d:$d}')" \
    | jq -e '.deploymentCancel == true' >/dev/null 2>&1 || die "Railway did not cancel deployment $dep"
  jq -nc --arg d "$dep" '{id:$d, state:"canceled", phase:"canceled", message:"Railway: deployment \($d) canceled"}'
}

# The newest deployment after the live one that Railway still lets go back to.
railway_rollback() {
  local d target
  d="$(railway_deploys "$1")" || die "Railway: could not read the deployments of $1"
  target="$(printf '%s' "$d" | jq -r '(map(.status) | index("SUCCESS")) as $live
    | if $live == null then empty else [.[($live + 1):][] | select(.canRollback == true)][0].id // empty end')"
  [ -n "$target" ] || die "Railway: $1 has no earlier deployment to go back to"
  # shellcheck disable=SC2016
  railway_gql 'mutation($d: String!) { deploymentRollback(id: $d) }' "$(jq -nc --arg d "$target" '{d:$d}')" \
    | jq -e '.deploymentRollback == true' >/dev/null 2>&1 || die "Railway did not roll $1 back"
  jq -nc --arg t "$target" '{id:$t, state:"rolling back", phase:"building", message:"Railway: going back to deployment \($t)"}'
}

# railway_logs <id> <lines> [deployment id]: the end of the build log.
railway_logs() {
  local id="$1" lines="${2:-200}" dep="${3:-}" out
  case "$lines" in ''|*[!0-9]*) die "Usage: logs <service id> <lines> [deployment id]" ;; esac
  if [ -z "$dep" ]; then
    dep="$(railway_deploys "$id" | jq -r '.[0].id // empty')" || die "Railway: could not read the deployments of $id"
    [ -n "$dep" ] || die "Railway: $id has no deployments yet"
  fi
  case "$dep" in *[!A-Za-z0-9-]*) die "Railway: \"$dep\" is not a deployment id" ;; esac
  # shellcheck disable=SC2016
  out="$(railway_gql 'query($d: String!, $n: Int) { buildLogs(deploymentId: $d, limit: $n) { message } }' \
    "$(jq -nc --arg d "$dep" --argjson n "$((lines + 0))" '{d:$d, n:$n}')")" || die "Railway: could not read the build log of $dep"
  printf '%s' "$out" | jq -r --argjson n "$((lines + 0))" '(.buildLogs // []) | map(.message // "") | .[-$n:] | .[]'
}

railway_url() {
  local items
  items="$(railway_items)" || die "Could not read Railway services"
  printf '%s' "$items" | jq -r --arg i "$1" --arg dash "${2:-}" "$RAILWAY_JQ"'
    map(select((.sid + ":" + .eid) == $i)) | .[0] // empty
    | if $dash == "--dashboard" then "https://railway.com/project/" + .projectId + "/service/" + .sid + "?environmentId=" + .eid
      else (host(.dep // {}) | if . then "https://" + . else "https://railway.com/project/" + $i end) end' | head -n 1
}

railway_setup_hint() { echo "pbpaste | deploys railway set-key   (an account or workspace token from railway.com/account/tokens, or set RAILWAY_API_TOKEN)"; }

railway_set_key() {
  local key=""
  if [ -t 0 ]; then IFS= read -rs key || true; echo >&2; else IFS= read -r key || true; fi
  key="$(printf "%s" "$key" | tr -d "\r" | sed "s/^[[:space:]]*//; s/[[:space:]]*\$//")"
  [ -n "$key" ] || die "Pipe the token in: pbpaste | deploys railway set-key"
  case "$key" in *\'*|*\"*|*\\*|*[[:space:]]*|*[[:cntrl:]]*) die "That does not look like a Railway token" ;; esac
  ( RAILWAY_API_TOKEN="$key"; key_of() { printf '%s' "$RAILWAY_API_TOKEN"; }; railway_items >/dev/null ) || die "Railway did not accept that token; nothing was saved"
  printf 'add-generic-password -U -a %s -s %s -w %s\n' "${USER:-$(id -un)}" "$RAILWAY_KEYCHAIN" "$key" | security -i >/dev/null \
    || die "The token works, but could not be saved in the keychain"
  echo "Railway token saved and working."
}

railway_doctor() {
  local src="missing" ok=false err="" n=null e items
  if [ -n "${RAILWAY_API_TOKEN:-}" ]; then src="env"
  elif security find-generic-password -a "${USER:-$(id -un)}" -s "$RAILWAY_KEYCHAIN" >/dev/null 2>&1; then src="keychain"; fi
  if [ "$src" != missing ]; then
    e="$(mktemp)"
    if items="$(railway_items 2>"$e")" && n="$(printf '%s' "$items" | jq 'length' 2>/dev/null)" && [ -n "$n" ]; then ok=true; else n=null; err="$(tail -n 1 "$e")"; fi
    rm -f "$e"
  fi
  jq -n --arg src "$src" --argjson ok "$ok" --arg err "$err" --argjson n "${n:-null}" \
    '{provider:"railway", key:$src, keyOk:$ok, error:(if $err == "" then null else $err end), services:$n, expiresAt:null, rateLimit:null}'
}
