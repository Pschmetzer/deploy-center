#!/bin/bash
# providers/northflank.sh — the Northflank provider for `deploys` (opt-in: deploys providers enable northflank).
#
# Northflank builds combined services from Git. The API (api.northflank.com/v1) lists projects,
# their services and builds, and starts a build of a combined service: "deploy" here starts a build
# of the service's branch (or of a given commit with --sha). A service that only runs an image has
# no build and is shown, not deployable (docs/providers/northflank.md).
#
# The id the other functions take is "<project>/<service>" (both are slugs).
# Contract (docs/PROVIDERS.md): northflank_meta, _ready, _json, _has, _off, _deploy_json, _status,
# _latest, _cancel, _rollback, _logs, _url, _set_key, _doctor. Phases: queued | building | ready | failed | canceled.
#
# Token: NORTHFLANK_TOKEN (an API token), else the keychain item deploy-center-northflank. It goes
# to curl on stdin (lib/http.sh), never as an argument.

NORTHFLANK_KEYCHAIN="deploy-center-northflank"
NORTHFLANK_API="${NORTHFLANK_API:-https://api.northflank.com/v1}"
# Pages read of one list at most (100 items each): a runaway cursor ends, it does not loop.
NORTHFLANK_MAX_PAGES="${NORTHFLANK_MAX_PAGES:-20}"

declare -F die >/dev/null || die() { echo "Error: $*" >&2; exit 1; }
# shellcheck source=../lib/http.sh
declare -F http_call >/dev/null || { _nf_h="$(dirname "${BASH_SOURCE[0]}")/../lib/http.sh"; [ ! -f "$_nf_h" ] || . "$_nf_h"; unset _nf_h; }

northflank_key() {
  local k=""
  if declare -F key_of >/dev/null; then k="$(key_of northflank 2>/dev/null)" || k=""
  elif [ -n "${NORTHFLANK_TOKEN:-}" ]; then k="$NORTHFLANK_TOKEN"
  else k="$(security find-generic-password -a "${USER:-$(id -un)}" -s "$NORTHFLANK_KEYCHAIN" -w 2>/dev/null)" || k=""
  fi
  [ -n "$k" ] || { echo "No Northflank token. Create an API token in the Northflank team settings (API), then: pbpaste | deploys northflank set-key (or set NORTHFLANK_TOKEN)" >&2; return 1; }
  printf '%s' "$k"
}

# northflank_call METHOD PATH [BODY]: the answer on stdout; on failure the reason on stderr, rc 1.
northflank_call() {
  local k e rc=0 fix="pbpaste | deploys northflank set-key"
  declare -F http_call >/dev/null || { echo "Northflank: lib/http.sh is missing" >&2; return 1; }
  k="$(northflank_key)" || return 1
  [ -z "${NORTHFLANK_TOKEN:-}" ] || fix="check NORTHFLANK_TOKEN in the environment"
  e="$(mktemp)"
  ( HTTP_AUTH="Authorization: Bearer $k" HTTP_FIX="$fix" http_call "Northflank" "$1" "$NORTHFLANK_API$2" "${3:-}" ) 2>"$e" || rc=$?
  [ "$rc" = 0 ] || sed '1s/^[^ ]*Error:[^ ]* //' "$e" >&2
  rm -f "$e"; return "$rc"
}

# northflank_pages PATH KEY: every page of a list as one JSON array of its items (.data.<KEY>),
# following the cursor Northflank returns (.data.pagination or .pagination: hasNextPage, cursor).
northflank_pages() {
  local path="$1" key="$2" sep="?" cursor="" out n=0 all="[]" next
  case "$path" in *\?*) sep="&" ;; esac
  while :; do
    out="$(northflank_call GET "${path}${sep}per_page=100${cursor:+&cursor=$cursor}")" || return 1
    printf '%s' "$out" | jq -e --arg k "$key" '(.data[$k] | type) == "array"' >/dev/null 2>&1 \
      || { echo "Northflank answered without a $key list" >&2; return 1; }
    all="$(printf '%s' "$out" | jq -c --argjson a "$all" --arg k "$key" '$a + .data[$k]')"
    next="$(printf '%s' "$out" | jq -r '(.pagination // .data.pagination // {}) | if .hasNextPage == true then (.cursor // "") else "" end')"
    [ -n "$next" ] || break
    case "$next" in *[!A-Za-z0-9._=-]*) echo "Northflank sent a cursor that cannot be used" >&2; return 1 ;; esac
    n=$((n + 1)); [ "$n" -lt "$NORTHFLANK_MAX_PAGES" ] || { echo "Northflank: more than $NORTHFLANK_MAX_PAGES pages, stopped reading" >&2; return 1; }
    cursor="$next"
  done
  printf '%s' "$all"
}

# An id is "<project>/<service>": slugs, one slash.
northflank_valid() { case "$1" in */*/*|/*|*/|''|-*|*[!A-Za-z0-9/_-]*) return 1 ;; */*) return 0 ;; esac; return 1; }
northflank_slug() { case "$1" in ''|-*|*[!A-Za-z0-9_-]*) return 1 ;; esac; }
northflank_proj() { printf '%s' "${1%%/*}"; }
northflank_svc() { printf '%s' "${1#*/}"; }

NORTHFLANK_JQ='
  def t: (. // null) | if . then ((try (capture("^(?<d>[0-9]{4}-[0-9]{2}-[0-9]{2}T[0-9]{2}:[0-9]{2}:[0-9]{2})(\\.[0-9]+)?(?<z>Z|[+-][0-9]{2}:?[0-9]{2})?$") | (.d + "Z" | fromdateiso8601) - (if (.z // "Z") == "Z" then 0 else (.z | (if startswith("-") then -1 else 1 end) * ((.[1:3] | tonumber) * 3600 + (.[-2:] | tonumber) * 60)) end)) catch null) // null) else null end;
  def phase: if . == null then null
    elif test("^(PENDING|QUEUED|WAITING)$"; "i") then "queued"
    elif test("^(IN_PROGRESS|RUNNING|BUILDING|STARTING)$"; "i") then "building"
    elif test("^(SUCCESS|SUCCEEDED|COMPLETED)$"; "i") then "ready"
    elif test("^(FAILURE|FAILED|ERROR)$"; "i") then "failed"
    elif test("^(CANCELLED|CANCELED|ABORTED)$"; "i") then "canceled"
    else null end;
'

northflank_meta() {
  printf '{"id":"northflank","label":"Northflank","noun":"service","defaultOn":false,"keyEnv":["NORTHFLANK_TOKEN"],"keychain":"%s","caps":{"off":false,"sha":true,"cancel":false,"rollback":false,"logs":false,"preview":false}}\n' "$NORTHFLANK_KEYCHAIN"
}

northflank_ready() { command -v curl >/dev/null 2>&1 && command -v jq >/dev/null 2>&1 && northflank_key >/dev/null 2>&1; }

# Every project's services as one array: [{project, ...service}].
northflank_services() {
  local projects ids p svcs all="[]" err=""
  projects="$(northflank_pages "/projects" projects)" || return 1
  ids="$(printf '%s' "$projects" | jq -r '.[].id | strings')"
  for p in $ids; do
    northflank_slug "$p" || continue
    if svcs="$(northflank_pages "/projects/$p/services" services 2>&1)"; then
      all="$(printf '%s' "$svcs" | jq -c --argjson a "$all" --arg p "$p" '$a + map(. + {project:$p})')"
    else err="$svcs"; fi
  done
  # A project that could not be read is an error, not a silent hole in the list.
  [ -z "$err" ] || [ "$all" != "[]" ] || { echo "$err" >&2; return 1; }
  printf '%s' "$all"
}

# One service's newest build (the full object), or null.
northflank_newest_build() {
  local out
  out="$(northflank_call GET "/projects/$(northflank_proj "$1")/services/$(northflank_svc "$1")/builds?per_page=1")" || return 1
  printf '%s' "$out" | jq -e '(.data.builds | type) == "array"' >/dev/null 2>&1 || { echo "Northflank answered without a build list for $1" >&2; return 1; }
  printf '%s' "$out" | jq -c '.data.builds[0] // null'
}

northflank_has() {
  local id
  case "$1" in ''|*[!A-Za-z0-9._/-]*) return 1 ;; esac
  case "$1" in */*) northflank_valid "$1" || return 1
    id="$(northflank_services 2>/dev/null | jq -r --arg n "$1" '.[] | select((.project + "/" + .id) == $n) | (.project + "/" + .id)' | head -n 1)" ;;
    *) id="$(northflank_services 2>/dev/null | jq -r --arg n "$1" '.[] | select(.id == $n or .name == $n) | (.project + "/" + .id)' | head -n 1)" ;;
  esac
  [ -n "$id" ] && printf '%s\n' "$id"
}

northflank_json() {
  local svcs rows="" row s id b
  svcs="$(northflank_services)" || die "Could not list Northflank services"
  while IFS= read -r s; do
    [ -n "$s" ] || continue
    id="$(printf '%s' "$s" | jq -r '.project + "/" + .id')"
    if [ "$(printf '%s' "$s" | jq -r '.serviceType // "combined"')" != combined ]; then
      row="$(printf '%s' "$s" | jq -c --arg id "$id" '{name:(.name // .id), id:$id, auto:false, deployable:false, paused:(.status.deployment.status == "PAUSED"),
        repo:null, ref:null, domain:null, url:null, dashboardUrl:("https://app.northflank.com/t/" + (.project) + "/services"),
        lastAt:null, lastState:null, lastSha:null, lastMsg:null, fetchError:null, phase:null}')"
    elif b="$(northflank_newest_build "$id" 2>&1)"; then
      row="$(printf '%s' "$s" | jq -c --arg id "$id" --argjson b "$b" "$NORTHFLANK_JQ"'
        {name:(.name // .id), id:$id, auto:(.disabledCI == false), deployable:true, paused:(.status.deployment.status == "PAUSED"),
         repo:null, ref:($b.branch // null), domain:null, url:null, dashboardUrl:("https://app.northflank.com/t/" + (.project) + "/services"),
         lastAt:(($b.concluded // $b.createdAt // null) | t), lastState:($b.status // null), lastSha:($b.sha // null), lastMsg:($b.message // null),
         fetchError:null, phase:(($b.status // null) | phase), latestId:($b.id // null)}')"
    else
      row="$(printf '%s' "$s" | jq -c --arg id "$id" --arg e "$b" '{name:(.name // .id), id:$id, auto:false, deployable:true, paused:false,
        repo:null, ref:null, domain:null, url:null, dashboardUrl:("https://app.northflank.com/t/" + (.project) + "/services"),
        lastAt:null, lastState:null, lastSha:null, lastMsg:null, fetchError:$e, phase:null}')"
    fi
    rows="$rows$row
"
  done < <(printf '%s' "$svcs" | jq -c '.[]')
  printf '%s' "$rows" | jq -s -c 'sort_by(.name | ascii_downcase)'
}

northflank_off() { die "Northflank cannot turn auto-deploy off from here: change the build rules of the service in the console"; }
northflank_cancel() { die "Northflank cannot cancel a build from here"; }
northflank_rollback() { die "Northflank cannot roll back from here: release an earlier build in the console"; }
northflank_logs() { die "Northflank cannot show build logs from here: use the console or \`northflank get service logs\`"; }

# northflank_deploy_json <project/service> [--sha S]: start a build of the service's branch.
northflank_deploy_json() {
  local id="${1:-}" sha="" lock="" out b branch body
  shift || true
  while [ $# -gt 0 ]; do
    case "$1" in
      --preview) die "Northflank cannot deploy a preview from here" ;;
      --no-cache) die "Northflank cannot build without a cache from here" ;;
      --sha) shift; sha="${1:-}"; case "$sha" in ''|*[!0-9a-fA-F]*) die "Northflank: --sha needs a commit hash" ;; esac ;;
      "") ;;
      *) die "Unknown option $1. Usage: deploy-json <project/service> [--sha S]" ;;
    esac; shift
  done
  northflank_valid "$id" || die "Northflank: \"$id\" is not a service id (project/service)"
  if declare -F start_lock >/dev/null; then lock="$(start_lock "northflank-$id")" || exit 1; fi
  out="$(northflank_call GET "/projects/$(northflank_proj "$id")/services/$(northflank_svc "$id")" 2>&1)" || { rm -f "$lock"; die "Northflank: could not read service $id: $out"; }
  printf '%s' "$out" | jq -e '.data.id' >/dev/null 2>&1 || { rm -f "$lock"; die "Northflank answered without a service for $id"; }
  printf '%s' "$out" | jq -e '(.data.serviceType // "combined") == "combined"' >/dev/null 2>&1 \
    || { rm -f "$lock"; die "Northflank: $id runs an image and has no build to start"; }
  branch="$(printf '%s' "$out" | jq -r '.data.vcs.projectBranch // .data.branch // empty')"
  if [ -n "$sha" ]; then body="$(jq -nc --arg s "$sha" --arg b "$branch" '{sha:$s} + (if $b == "" then {} else {branch:$b} end)')"
  elif [ -n "$branch" ]; then body="$(jq -nc --arg b "$branch" '{branch:$b}')"
  else rm -f "$lock"; die "Northflank: $id has no branch to build"; fi
  if ! out="$(northflank_call POST "/projects/$(northflank_proj "$id")/services/$(northflank_svc "$id")/build" "$body" 2>&1)"; then
    rm -f "$lock"; die "Northflank: starting a build of $id failed: $out"
  fi
  printf '%s' "$out" | jq -e '.data.id' >/dev/null 2>&1 || { rm -f "$lock"; die "Northflank answered without a build for $id"; }
  b="$(printf '%s' "$out" | jq -c "$NORTHFLANK_JQ"'.data | {id:.id, url:null, state:(.status // "PENDING"), phase:((.status // "PENDING") | phase)}')"
  printf '%s\n' "$b"
}

# One TSV line from a build: <id> <phase> <state>.
northflank_tsv() { jq -r "$NORTHFLANK_JQ"'if . == null then "none\t\tnone" else "\(.id)\t\(.status | phase)\t\(.status)" end'; }

northflank_status() {
  local s="${1:-}" d="${2:-}" m
  northflank_valid "$s" && northflank_slug "$d" || die "Usage: status <project/service> <build id>"
  m="$(northflank_call GET "/projects/$(northflank_proj "$s")/services/$(northflank_svc "$s")/builds/$d")" || die "Northflank: could not read build $d"
  printf '%s' "$m" | jq -e '.data | type == "object" and has("id") and has("status")' >/dev/null 2>&1 || die "Northflank answered without a build for $d"
  printf '%s\n' "$m" | jq -c '.data' | northflank_tsv
}
northflank_cli_status() { northflank_call GET "/projects/$(northflank_proj "$1")/services/$(northflank_svc "$1")/builds/$2"; }

northflank_latest() {
  northflank_valid "${1:-}" || die "Northflank: \"${1:-}\" is not a service id (project/service)"
  local b
  b="$(northflank_newest_build "$1")" || die "Northflank: could not read the builds of $1"
  printf '%s\n' "$b" | northflank_tsv
}
northflank_cli_latest() { northflank_call GET "/projects/$(northflank_proj "$1")/services/$(northflank_svc "$1")/builds?per_page=1"; }

northflank_url() {
  northflank_valid "${1:-}" || die "Northflank: \"${1:-}\" is not a service id (project/service)"
  echo "https://app.northflank.com/t/$(northflank_proj "$1")/services"
}

northflank_setup_hint() { echo "create an API token in the Northflank team settings, then: pbpaste | deploys northflank set-key   (or set NORTHFLANK_TOKEN)"; }

northflank_set_key() {
  local key=""
  if [ -t 0 ]; then IFS= read -rs key || true; echo >&2; else IFS= read -r key || true; fi
  key="$(printf "%s" "$key" | tr -d "\r" | sed "s/^[[:space:]]*//; s/[[:space:]]*\$//")"
  [ -n "$key" ] || die "Pipe the token in: pbpaste | deploys northflank set-key"
  case "$key" in *[[:space:]]*|*\'*|*\"*|*\\*|*[[:cntrl:]]*) die "That does not look like a Northflank token" ;; esac
  ( NORTHFLANK_TOKEN="$key"; key_of() { printf '%s' "$NORTHFLANK_TOKEN"; }; northflank_pages "/projects" projects >/dev/null ) || die "Northflank did not accept that token; nothing was saved"
  printf 'add-generic-password -U -a %s -s %s -w %s\n' "${USER:-$(id -un)}" "$NORTHFLANK_KEYCHAIN" "$key" | security -i >/dev/null \
    || die "The token works, but could not be saved in the keychain"
  echo "Northflank token saved and working."
}

northflank_doctor() {
  local src="missing" ok=false err="" n=null e
  if [ -n "${NORTHFLANK_TOKEN:-}" ]; then src="env"
  elif security find-generic-password -a "${USER:-$(id -un)}" -s "$NORTHFLANK_KEYCHAIN" >/dev/null 2>&1; then src="keychain"; fi
  if [ "$src" != missing ]; then
    e="$(mktemp)"
    if n="$(northflank_pages "/projects" projects 2>"$e" | jq 'length' 2>/dev/null)" && [ -n "$n" ]; then ok=true; else n=null; err="$(tail -n 1 "$e")"; fi
    rm -f "$e"
  fi
  jq -n --arg src "$src" --argjson ok "$ok" --arg err "$err" --argjson n "${n:-null}" \
    '{provider:"northflank", key:$src, keyOk:$ok, error:(if $err == "" then null else $err end),
      projects:$n, expiresAt:null, rateLimit:null}'
}
