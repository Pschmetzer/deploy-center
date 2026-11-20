#!/bin/bash
# providers/heroku.sh — the Heroku provider for `deploys` (opt-in: deploys providers enable heroku).
#
# Heroku builds from `git push heroku`, the GitHub integration or a CI that uses the Build API.
# From here the Platform API (api.heroku.com) can read apps and releases, restart the dynos, go
# back to an earlier release and read the log of the newest build. So "deploy" here means
# "restart the dynos on the release that is live"; it never builds new code and takes no commit
# (docs/providers/heroku.md).
#
# Contract (docs/PROVIDERS.md): heroku_meta, _ready, _json, _has, _off, _deploy_json, _status,
# _latest, _cancel, _rollback, _logs, _url, _set_key, _doctor. Phases: queued | building | ready | failed | canceled.
# A deploy id here is a release id: status follows that release, and while its dynos are still
# starting (or have crashed) the phase says so.
#
# Key: HEROKU_API_KEY (an authorization from `heroku authorizations:create`, ideally with an
# expiry), else the keychain item deploy-center-heroku. It goes to curl on stdin, never as an argument.

HEROKU_KEYCHAIN="deploy-center-heroku"
HEROKU_API="${HEROKU_API:-https://api.heroku.com}"

declare -F die >/dev/null || die() { echo "Error: $*" >&2; exit 1; }

heroku_key() {
  local k=""
  if declare -F key_of >/dev/null; then k="$(key_of heroku 2>/dev/null)" || k=""
  elif [ -n "${HEROKU_API_KEY:-}" ]; then k="$HEROKU_API_KEY"
  else k="$(security find-generic-password -a "${USER:-$(id -un)}" -s "$HEROKU_KEYCHAIN" -w 2>/dev/null)" || k=""
  fi
  [ -n "$k" ] || { echo "No Heroku key. Create one with: heroku authorizations:create -d deploy-center -e 31536000   then: pbpaste | deploys heroku set-key (or set HEROKU_API_KEY)" >&2; return 1; }
  printf '%s' "$k"
}

# FEA-078: {"remaining":N,"resetAt":null} from the RateLimit-Remaining header of a header file
# curl wrote (-D); null when there is none. Heroku sends no reset time.
heroku_ratelimit() {
  tr -d '\r' < "$1" 2>/dev/null | awk -F': *' 'tolower($1) == "ratelimit-remaining" && $2 ~ /^[0-9]+$/ { r = $2 }
    END { if (r == "") print "null"; else printf "{\"remaining\":%s,\"resetAt\":null}\n", r }'
}

# heroku_call METHOD PATH [BODY] [RANGE]: the answer on stdout; on failure a reason on stderr, rc 1.
# Own curl code (the API needs its own Accept header and a Range for lists). The key goes to curl on
# stdin; a body goes through a file of our own (0600). Reads are repeated after a 429, a 5xx or no
# answer; a write only after a 429 (which means it was not taken).
heroku_call() {
  local method="$1" path="$2" body="${3:-}" range="${4:-}" key out code try err bodyf="" msg hint="" fix="pbpaste | deploys heroku set-key"
  key="$(heroku_key)" || return 1
  [ -z "${HEROKU_API_KEY:-}" ] || fix="check HEROKU_API_KEY in the environment"
  local args=(-sS --connect-timeout 10 --max-time 60 -X "$method" -H "Accept: application/vnd.heroku+json; version=3" -K -)
  [ -z "$range" ] || args+=(-H "Range: $range")
  if [ -n "$body" ]; then bodyf="$(mktemp)"; printf '%s' "$body" > "$bodyf"; args+=(-H "Content-Type: application/json" --data-binary "@$bodyf"); fi
  [ -z "${HEROKU_HEADERS:-}" ] || args+=(-D "$HEROKU_HEADERS")
  err="$(mktemp)"
  for try in 1 2 3; do
    out="$(printf 'header = "Authorization: Bearer %s"\n' "$key" | curl "${args[@]}" -w '\n%{http_code}' "$HEROKU_API$path" 2>"$err")" || out=$'\n000'
    code="${out##*$'\n'}"; out="${out%$'\n'*}"
    case "$code" in
      429) [ "$try" -lt 3 ] && { sleep $((try * 3)); continue; } ;;
      5*|000) [ "$method" = GET ] && [ "$try" -lt 3 ] && { sleep $((try * 2)); continue; } ;;
    esac
    break
  done
  [ "$code" != 000 ] || out="$(tail -n 1 "$err")"
  rm -f "$err" ${bodyf:+"$bodyf"}
  if [[ "$code" != 2* ]]; then
    msg="$(printf '%s' "$out" | jq -r '.message // empty' 2>/dev/null)" || msg=""
    [ -n "$msg" ] || msg="$(printf '%s' "$out" | tr '\n\r\t' '   ' | cut -c1-200)"
    case "$code" in
      000) hint=" (no answer from Heroku: network or timeout)" ;;
      401) hint=" (the Heroku key is wrong or expired: $fix)" ;;
      403) hint=" (the key may not do this)" ;;
      404) hint=" (not found: renamed or deleted?)" ;;
      422) hint=" (Heroku refused it)" ;;
      429) hint=" (rate limit: try again in a while)" ;;
      5*) hint=" (Heroku had a problem: try again later)" ;;
    esac
    echo "Heroku $method ${path%%\?*} -> HTTP $code$hint${msg:+: $msg}" >&2
    return 1
  fi
  printf '%s' "$out"
}

# Heroku app names: lowercase letters, digits and dashes.
heroku_valid() { case "$1" in ''|-*|*[!a-z0-9-]*) return 1 ;; esac; }

heroku_apps() {
  local out
  out="$(heroku_call GET /apps)" || return 1
  printf '%s' "$out" | jq -e 'type == "array"' >/dev/null 2>&1 || { echo "Heroku answered without an app list" >&2; return 1; }
  printf '%s' "$out"
}

# The newest releases of an app, newest first.
heroku_releases() {  # heroku_releases <app> [n]
  local out
  out="$(heroku_call GET "/apps/$1/releases" "" "version ..; order=desc,max=${2:-10}")" || return 1
  printf '%s' "$out" | jq -e 'type == "array"' >/dev/null 2>&1 || { echo "Heroku answered without a release list for $1" >&2; return 1; }
  printf '%s' "$out"
}

# shellcheck disable=SC2016
HEROKU_JQ='
  def t: (. // null) | if . then (sub("\\.[0-9]+Z$";"Z") | try fromdateiso8601 catch null) else null end;
  def phase: if . == null then null
    elif . == "pending" then "building"
    elif . == "succeeded" then "ready"
    elif . == "failed" then "failed"
    else null end;
  def sha: ((.description // "") | capture("^Deploy (?<s>[0-9a-f]{7,40})$")? | .s) // null;
'

heroku_meta() {
  printf '{"id":"heroku","label":"Heroku","noun":"app","defaultOn":false,"keyEnv":["HEROKU_API_KEY"],"keychain":"%s","caps":{"off":false,"sha":false,"cancel":false,"rollback":true,"logs":true,"preview":false}}\n' "$HEROKU_KEYCHAIN"
}

heroku_ready() { command -v curl >/dev/null 2>&1 && command -v jq >/dev/null 2>&1 && heroku_key >/dev/null 2>&1; }

heroku_has() {
  local id
  heroku_valid "$1" || return 1
  id="$(heroku_apps 2>/dev/null | jq -r --arg n "$1" '.[] | select(.name == $n) | .name' | head -n 1)"
  [ -n "$id" ] && printf '%s\n' "$id"
}

heroku_json() {
  local apps name rel rows="" row
  apps="$(heroku_apps)" || die "Could not list Heroku apps"
  while IFS= read -r name; do
    [ -n "$name" ] || continue
    if rel="$(heroku_releases "$name" 10 2>&1)"; then row="$(jq -nc --arg n "$name" --argjson r "$rel" '{name:$n, rel:$r}')"
    else row="$(jq -nc --arg n "$name" --arg e "$rel" '{name:$n, rel:[], err:$e}')"; fi
    rows="$rows$row"$'\n'
  done < <(printf '%s' "$apps" | jq -r '.[].name')
  jq -n --argjson apps "$apps" --slurpfile rows <(printf '%s' "$rows") "$HEROKU_JQ"'
    ($rows | map({(.name): .}) | add // {}) as $by
    | [$apps[] | . as $a | ($by[$a.name] // {rel:[]}) as $x | ($x.rel[0] // {}) as $new
      | ([$x.rel[] | select(.status == "succeeded")][0] // {}) as $live
      | {name:$a.name, id:$a.name, auto:false, deployable:true, paused:($a.maintenance // false),
         repo:null, ref:null,
         domain:(($a.web_url // "") | sub("^https?://";"") | sub("/.*$";"") | if . == "" then null else . end),
         url:($a.web_url // null | if . then rtrimstr("/") else null end),
         dashboardUrl:("https://dashboard.heroku.com/apps/" + $a.name),
         lastAt:($new.created_at | t), lastState:($new.status // null),
         lastSha:($live | sha), lastMsg:($live.description // null),
         fetchError:($x.err // null), phase:(if $x.err then null else ($new.status | phase) end),
         latestId:($new.id // null)}]
    | sort_by(.name | ascii_downcase)'
}

heroku_off() { die "Heroku cannot turn auto-deploy off from here: disconnect GitHub in the app's Deploy tab"; }
heroku_cancel() { die "Heroku cannot cancel a release from here"; }

# One TSV line from a release: its phase, made worse by what the dynos do. A release that
# succeeded while the dynos are still starting is still building, and crashed dynos are a failure.
heroku_line() {  # heroku_line <app> <release json>
  local rel="$2" ph dy st
  ph="$(printf '%s' "$rel" | jq -r "$HEROKU_JQ"'.status | phase // ""')"
  st="$(printf '%s' "$rel" | jq -r '.status')"
  if [ "$ph" = ready ]; then
    dy="$(heroku_call GET "/apps/$1/dynos" 2>/dev/null)" || dy=""
    if [ -n "$dy" ] && printf '%s' "$dy" | jq -e 'type == "array"' >/dev/null 2>&1; then
      if printf '%s' "$dy" | jq -e 'any(.[]; .state == "crashed")' >/dev/null 2>&1; then ph=failed; st="crashed"
      elif printf '%s' "$dy" | jq -e 'any(.[]; .state == "starting" or .state == "restarting")' >/dev/null 2>&1; then ph=building; st="starting"; fi
    fi
  fi
  printf '%s' "$rel" | jq -r --arg ph "$ph" --arg st "$st" '"\(.id)\t\($ph)\t\($st)"'
}

heroku_status() {
  local app="$1" d="${2:-}" r
  heroku_valid "$app" && [ -n "$d" ] || die "Usage: status <app> <release id>"
  case "$d" in *[!A-Za-z0-9-]*) die "Heroku: \"$d\" is not a release id" ;; esac
  r="$(heroku_call GET "/apps/$app/releases/$d")" || die "Heroku: could not read release $d"
  printf '%s' "$r" | jq -e 'type == "object" and has("id") and has("status")' >/dev/null 2>&1 || die "Heroku answered without a release for $d"
  heroku_line "$app" "$r"
}
heroku_cli_status() { heroku_call GET "/apps/$1/releases/$2"; }

heroku_latest() {
  local rel
  heroku_valid "$1" || die "Heroku: \"$1\" is not an app name"
  rel="$(heroku_releases "$1" 1)" || die "Heroku: could not read the releases of $1"
  rel="$(printf '%s' "$rel" | jq -c '.[0] // empty')"
  [ -n "$rel" ] || { printf 'none\t\tnone\n'; return 0; }
  heroku_line "$1" "$rel"
}
heroku_cli_latest() { heroku_releases "$1" 1 | jq '.[0] // null'; }

# heroku_deploy_json <app>: restart all dynos (the release that is live stays). The id is that release.
heroku_deploy_json() {
  local app="${1:-}" rel id lock="" url
  shift || true
  while [ $# -gt 0 ]; do
    case "$1" in
      --preview) die "Heroku cannot deploy a preview from here" ;;
      --sha) die "Heroku cannot deploy a given commit from here: it restarts the release that is live" ;;
      --no-cache) die "Heroku cannot build without a cache from here: it restarts the release that is live" ;;
      "") ;;
      *) die "Unknown option $1. Usage: deploy-json <app>" ;;
    esac; shift
  done
  heroku_valid "$app" || die "Heroku: \"$app\" is not an app name"
  if declare -F start_lock >/dev/null; then lock="$(start_lock "heroku-$app")" || exit 1; fi
  rel="$(heroku_releases "$app" 5)" || { rm -f "$lock"; die "Heroku: could not read the releases of $app"; }
  id="$(printf '%s' "$rel" | jq -r '([.[] | select(.current == true)][0] // .[0] // {}).id // empty')"
  [ -n "$id" ] || { rm -f "$lock"; die "Heroku: $app has no release yet; there is nothing to restart"; }
  heroku_call DELETE "/apps/$app/dynos" >/dev/null || { rm -f "$lock"; die "Heroku: could not restart the dynos of $app"; }
  url="$(heroku_apps 2>/dev/null | jq -r --arg n "$app" '.[] | select(.name == $n) | .web_url // empty' | head -n 1)" || url=""
  jq -nc --arg id "$id" --arg u "${url%/}" '{id:$id, url:(if $u == "" then null else $u end), state:"restarting", phase:"building"}'
}

# Back to the release before the one that is live: the next older one that succeeded and has code.
# Heroku makes it a new release (a new version number).
heroku_rollback() {
  local app="$1" rel target out
  heroku_valid "$app" || die "Heroku: \"$app\" is not an app name"
  rel="$(heroku_releases "$app" 20)" || die "Heroku: could not read the releases of $app"
  target="$(printf '%s' "$rel" | jq -r '(map(.current == true) | index(true)) as $c
    | ($c // ([.[] | .status == "succeeded"] | index(true))) as $live
    | if $live == null then empty else [.[($live + 1):][] | select(.status == "succeeded" and .slug != null)][0] // empty | "\(.id) \(.version)" end')"
  [ -n "$target" ] || die "Heroku: $app has no earlier release to go back to"
  out="$(heroku_call POST "/apps/$app/releases" "$(jq -nc --arg r "${target%% *}" '{release:$r}')")" || die "Heroku: could not roll $app back"
  printf '%s' "$out" | jq -c --arg a "$app" --arg v "${target#* }" "$HEROKU_JQ"'{id, state:(.status // "pending"), phase:((.status // "pending") | phase), version:.version,
    message:"Heroku: \($a) is going back to v\($v) (a new release)"}' 2>/dev/null || die "Heroku answered without a release for the rollback"
}

# heroku_logs <app> <lines> [ignored]: the end of the newest build's log (builds made through the
# Build API: `git push`, the GitHub integration, a CI). The runtime log is `heroku logs`.
heroku_logs() {
  local app="$1" lines="${2:-200}" b id r
  heroku_valid "$app" || die "Heroku: \"$app\" is not an app name"
  case "$lines" in ''|*[!0-9]*) die "Usage: logs <app> <lines>" ;; esac
  b="$(heroku_call GET "/apps/$app/builds" "" "created_at ..; order=desc,max=1")" || die "Heroku: could not read the builds of $app"
  id="$(printf '%s' "$b" | jq -r 'if type == "array" then .[0].id // empty else empty end' 2>/dev/null)"
  [ -n "$id" ] || die "Heroku: $app has no build with a log (it was deployed by container or has not been built yet)"
  r="$(heroku_call GET "/apps/$app/builds/$id/result")" || die "Heroku: could not read the log of build $id"
  printf '%s' "$r" | jq -r --argjson n "$((lines + 0))" '(.lines // []) | map((.line // "") | rtrimstr("\n")) | .[-$n:] | .[]'
}

heroku_url() {
  local u
  heroku_valid "$1" || die "Heroku: \"$1\" is not an app name"
  if [ "${2:-}" = --dashboard ]; then echo "https://dashboard.heroku.com/apps/$1"; return 0; fi
  u="$(heroku_apps | jq -r --arg n "$1" '.[] | select(.name == $n) | .web_url // empty' | head -n 1)" || die "Heroku: could not read $1"
  echo "${u:-https://$1.herokuapp.com}" | sed 's#/*$##'
}

heroku_setup_hint() { echo "heroku authorizations:create -d deploy-center -e 31536000, then: pbpaste | deploys heroku set-key   (or set HEROKU_API_KEY)"; }

heroku_set_key() {
  local key=""
  if [ -t 0 ]; then IFS= read -rs key || true; echo >&2; else IFS= read -r key || true; fi
  key="$(printf "%s" "$key" | tr -d "\r" | sed "s/^[[:space:]]*//; s/[[:space:]]*\$//")"
  [ -n "$key" ] || die "Pipe the key in: pbpaste | deploys heroku set-key"
  case "$key" in *\'*|*\"*|*\\*|*[[:space:]]*|*[[:cntrl:]]*) die "That does not look like a Heroku key" ;; esac
  ( HEROKU_API_KEY="$key"; key_of() { printf '%s' "$HEROKU_API_KEY"; }; heroku_apps >/dev/null ) || die "Heroku did not accept that key; nothing was saved"
  printf 'add-generic-password -U -a %s -s %s -w %s\n' "${USER:-$(id -un)}" "$HEROKU_KEYCHAIN" "$key" | security -i >/dev/null \
    || die "The key works, but could not be saved in the keychain"
  echo "Heroku key saved and working."
}

heroku_doctor() {
  local src="missing" ok=false err="" n=null e h rl=null
  if [ -n "${HEROKU_API_KEY:-}" ]; then src="env"
  elif security find-generic-password -a "${USER:-$(id -un)}" -s "$HEROKU_KEYCHAIN" >/dev/null 2>&1; then src="keychain"; fi
  if [ "$src" != missing ]; then
    e="$(mktemp)"; h="$(mktemp)"
    if n="$(HEROKU_HEADERS="$h" heroku_apps 2>"$e" | jq 'length' 2>/dev/null)" && [ -n "$n" ]; then ok=true; else n=null; err="$(tail -n 1 "$e")"; fi
    rl="$(heroku_ratelimit "$h")"; rm -f "$e" "$h"
  fi
  jq -n --arg src "$src" --argjson ok "$ok" --arg err "$err" --argjson n "${n:-null}" --argjson rl "${rl:-null}" \
    '{provider:"heroku", key:$src, keyOk:$ok, error:(if $err == "" then null else $err end), apps:$n, expiresAt:null, rateLimit:$rl}'
}
