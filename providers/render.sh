# shellcheck shell=bash
# shellcheck disable=SC2154  # CONFIG_DIR, USER and the helpers come from `deploys`.
# Render, through an API key: RENDER_API_KEY, or the macOS keychain (`deploys render set-key`).
# Sourced by `deploys`; the contract is in docs/PROVIDERS.md. A service's id is its srv-/crn- id.

RENDER_API="https://api.render.com/v1"
RENDER_KEYCHAIN_SERVICE="deploy-center-render"
# The name the key was stored under before Deploy Center had its own. Still read, and removed by forget-key.
RENDER_LEGACY_KEYCHAIN_SERVICE="render-api-key"
export RENDER_KEYCHAIN_SERVICE RENDER_LEGACY_KEYCHAIN_SERVICE

render_meta() {
  printf '%s\n' '{"id":"render","label":"Render","noun":"service","defaultOn":true,"keyEnv":["RENDER_API_KEY"],"keychain":"deploy-center-render","auth":"API key","caps":{"off":true,"sha":true,"cancel":true,"rollback":true,"logs":true,"preview":false}}'
}

render_key() {
  # On a server or in CI there is no keychain: the key may come from the environment (key_of).
  key_of render \
    || security find-generic-password -a "$USER" -s "$RENDER_LEGACY_KEYCHAIN_SERVICE" -w 2>/dev/null \
    || { if declare -F keychain_broken >/dev/null && keychain_broken render; then
           die "Render: the keychain could not be read (locked, or no access from here: launchd, SSH). Unlock it (security unlock-keychain) or set RENDER_API_KEY"
         fi
         die "No Render API key. Create one at dashboard.render.com > Account Settings > API Keys, then: deploys render set-key"; }
}
# Whether a key is there. In a subshell: render_key ends with `die` (exit) when there is none,
# and an exit inside an `if` ends the whole script, not only the test.
render_ready() { ( render_key ) >/dev/null 2>&1; }

# The key goes to curl on stdin so it never shows in the process list.
render_call() {
  local method="$1" path="$2" body="${3:-}" key out code
  key="$(render_key)" || exit 1
  # A hung connection must not hang the app: 10 s to connect, 60 s in all.
  local args=(-sS --connect-timeout 10 --max-time 60 -X "$method" -H "Accept: application/json" -K -)
  [ -n "$body" ] && args+=(-H "Content-Type: application/json" --data "$body")
  local try err; err="$(mktemp)"
  for try in 1 2 3; do
    # A curl failure (no network, timeout) is code 000 here, not a silent stop under set -e.
    out="$(printf 'header = "Authorization: Bearer %s"\n' "$key" | curl "${args[@]}" -w '\n%{http_code}' "$RENDER_API$path" 2>"$err")" || out=$'\n000'
    code="${out##*$'\n'}"; out="${out%$'\n'*}"
    # 429 (rate limit), 5xx and network errors: wait and ask again. Only reads are repeated:
    # a POST that timed out may have started a build already.
    case "$code" in
      429) [ "$try" -lt 3 ] && { sleep $((try * 3)); continue; } ;;
      5*|000) [ "$method" = GET ] && [ "$try" -lt 3 ] && { sleep $((try * 2)); continue; } ;;
    esac
    break
  done
  [ "$code" != 000 ] || out="$(tail -n 1 "$err")"
  rm -f "$err"
  if [[ "$code" != 2* ]]; then
    local hint="" fix="deploys render set-key"
    [ -n "${RENDER_API_KEY:-}" ] && fix="check RENDER_API_KEY in the environment"
    case "$code" in 000) hint=" (no answer: network or timeout)";; 401|403) hint=" (the Render key is wrong or expired: $fix)";; 404) hint=" (not found: renamed or deleted?)";; 429) hint=" (rate limit: try again in a minute)";; 5*) hint=" (Render had a problem: try again later)";; esac
    die "Render $method $path -> HTTP $code$hint: $out"
  fi
  printf '%s' "$out"
}

render_services() {
  local cursor="" page all="[]"
  while :; do
    # `|| return`: inside $(...) set -e is off, and a failed page used to loop here for ever.
    page="$(render_call GET "/services?limit=100${cursor:+&cursor=$cursor}")" || return 1
    all="$(jq -s '.[0] + .[1]' <(echo "$all") <(echo "$page"))"
    [ "$(echo "$page" | jq 'length')" -lt 100 ] && break
    cursor="$(echo "$page" | jq -r '.[-1].cursor')"
  done
  echo "$all" | jq '[.[].service]'
}

render_auto() { echo '(.autoDeployTrigger // (if .autoDeploy=="yes" then "commit" else "off" end))'; }

render_id_of() {
  local name="$1" id
  case "$name" in srv-*|crn-*) echo "$name"; return;; esac
  id="$(render_services | jq -r --arg n "$name" '.[] | select(.name==$n) | .id')"
  [ -n "$id" ] || die "No Render service named \"$name\". See: deploys render list"
  # Two services may share a name (in different projects): never pick one at random.
  [ "$(echo "$id" | wc -l | tr -d ' ')" = 1 ] || die "Several Render services are named \"$name\" ($(echo "$id" | tr '\n' ' ')). Use the srv- id."
  echo "$id"
}

render_has() { render_id_of "$1"; }

render_off_one() {
  render_call PATCH "/services/$1" '{"autoDeployTrigger":"off"}' >/dev/null
  # When it was turned off, so a later push-triggered build can be told apart from earlier ones.
  local f="$CONFIG_DIR/render-off.json" tmp; [ -f "$f" ] || echo '{}' > "$f"; tmp="$(mktemp)"
  jq --arg id "$1" '.[$id] = (.[$id] // (now|floor))' "$f" > "$tmp" && mv "$tmp" "$f"
  echo "Render: $2 no longer deploys on push"
}

# render_off <service>|--all
# Auto-deploy "On Commit" again.
render_on_one() {
  render_call PATCH "/services/$1" '{"autoDeployTrigger":"commit"}' >/dev/null
  echo "Render: $2 deploys on push again"
}
render_on() {
  local target="${1:-}" bad=0 todo id name
  [ -n "$target" ] || die "Give a service name or --all"
  if [ "$target" = "--all" ]; then
    todo="$(render_services | jq -r '.[] | select('"$(render_auto)"' == "off") | "\(.id)\t\(.name)"')"
    while IFS=$'\t' read -r id name; do
      [ -n "$id" ] || continue; ( render_on_one "$id" "$name" ) || bad=$((bad + 1))
    done <<< "$todo"
    [ "$bad" = 0 ] || die "$bad Render services could not be switched on (see above); the others are done"
    echo "Done. Every Render service deploys on push again."
  else
    render_on_one "$(render_id_of "$target")" "$target"
  fi
}
render_cli_autodeploy_on() { render_on "$@"; }

render_off() {
  local target="${1:-}" bad todo id name
  [ -n "$target" ] || die "Give a service name or --all"
  if [ "$target" = "--all" ]; then
    bad=0; todo="$(render_services | jq -r '.[] | select('"$(render_auto)"' != "off") | "\(.id)\t\(.name)"')"
    while IFS=$'\t' read -r id name; do
      [ -n "$id" ] || continue; ( render_off_one "$id" "$name" ) || bad=$((bad + 1))
    done <<< "$todo"
    [ "$bad" = 0 ] || die "$bad Render services could not be switched off (see above); the others are done"
    echo "Done. No Render service deploys on push any more."
  else
    render_off_one "$(render_id_of "$target")" "$target"
  fi
}

# Raw Render states to the shared phase (docs/PROVIDERS.md). A deactivated deploy was replaced
# before it went live: it ends like a cancelled one. Unknown or none: null.
RENDER_PHASE='def rphase: if . == null then null
  elif . == "created" or . == "queued" then "queued"
  elif . == "build_in_progress" or . == "update_in_progress" or . == "pre_deploy_in_progress" then "building"
  elif . == "live" or . == "succeeded" then "ready"
  elif . == "build_failed" or . == "update_failed" or . == "pre_deploy_failed" then "failed"
  elif . == "canceled" or . == "deactivated" then "canceled" else null end;'

# The key comes from a 0600 file the caller wrote once, so twenty services do not mean
# twenty keychain reads (or twenty permission prompts).
render_last_of() {
  local id="$1" out="$2" key
  # Whatever goes wrong, the service is written down as "not known", never left out: a missing
  # record would read as "never deployed" and make the service look changed.
  last_fail() { jq -nc --arg k "$id" --arg e "$1" '{key:$k, value:{fetchError:$e}}' > "$out/$id.json"; }
  key="$(cat "$3" 2>/dev/null)"; [ -n "$key" ] || { last_fail "no Render key"; return 0; }
  # Eight of these run at once: this is where Render's rate limit (429) hits. Wait and ask again.
  local raw code try
  for try in 1 2 3; do
    raw="$(printf 'header = "Authorization: Bearer %s"\n' "$key" \
      | curl -sS --connect-timeout 10 --max-time 60 -K - -w '\n%{http_code}' -H "Accept: application/json" "https://api.render.com/v1/services/$id/deploys?limit=10")" || raw=$'\n000'
    code="${raw##*$'\n'}"
    [ "$code" = 429 ] && [ "$try" -lt 3 ] && { sleep $((try * 3)); continue; }
    break
  done
  [[ "$code" == 2* ]] || { last_fail "HTTP $code"; return 0; }
  printf '%s' "${raw%$'\n'*}" \
    | jq -c --arg id "$id" 'def t: (. // null) | if . then (sub("\\.[0-9]+Z$";"Z")|fromdateiso8601) else null end;
        [.[].deploy] as $d | ($d[0] // {}) as $new | (($d | map(select(.status=="live")) | .[0]) // {}) as $live
        # The status is the newest attempt (a failure shows), the commit is what is live: a failed
        # deploy of the newest commit must not make the project look up to date.
        | {key:$id, value:{lastAt:(($new.finishedAt // $new.createdAt) | t), lastState:$new.status,
                           lastSha:($live.commit.id // null), lastMsg:($live.commit.message // null | if . then split("\n")[0] else null end), liveAt:(($live.finishedAt // $live.createdAt) | t),
                           latestId:($new.id // null), latestSha:($new.commit.id // null)}}' \
    > "$out/$id.json" 2>/dev/null || last_fail "unreadable answer"
  [ -s "$out/$id.json" ] || last_fail "empty answer"
}
export -f render_last_of

render_json() {
  local list tmp kf lasts
  list="$(render_services | jq '[.[] | {id, name, type, paused:(.suspended=="suspended"),
    auto:('"$(render_auto)"' != "off"), deployable:(.suspended!="suspended"),
    url:(.serviceDetails.url // null),
    dashboardUrl:(.dashboardUrl // null),
    domain:((.serviceDetails.url // "") | sub("^https?://";"") | if . == "" then null else . end),
    repo:((.repo // "") | '"$GITHOST_SLUG_JQ"' | if . == "" then null else . end),
    ref:(.branch // null)}] | sort_by(.name | ascii_downcase)')" || exit 1
  tmp="$(mktemp -d)"; kf="$tmp/key"; (umask 077; render_key > "$kf")
  echo "$list" | jq -r '.[].id' | xargs -P 8 -n 1 bash -c 'render_last_of "$2" "$0" "$1"' "$tmp" "$kf"
  rm -f "$kf"
  lasts="$(cat_all "$tmp"/*.json | jq -s 'from_entries')"; rm -rf "$tmp"
  echo "$list" | jq --argjson l "${lasts:-{\}}" "$RENDER_PHASE"'map({lastAt:null, lastState:null, lastSha:null, lastMsg:null, fetchError:null}
    + . + ($l[.id] // {}) | . + {phase:(.lastState | rphase)})'
}

# render_deploy_json <service> [--sha <commit>] [--clear-cache]
render_deploy_json() {
  local id sha="" cc="" lock body out
  local name="${1:?service}" svc
  id="$(render_id_of "$name")"; shift || true
  while [ $# -gt 0 ]; do case "$1" in --sha) sha="${2:?commit}"; shift;; --clear-cache) cc=1;; --preview) die "Render cannot deploy a preview";; "") ;; *) die "Unknown option $1. Usage: deploy-json <service> [--sha <commit>] [--clear-cache]";; esac; shift; done
  # Production waits for its approvals (two-person rule); the commit checked is the one deployed.
  if team_on; then
    svc="$(render_call GET "/services/$id")" || exit 1
    # By its name, as the shared config knows it, also when it was given by its srv- id.
    name="$(echo "$svc" | jq -r --arg n "$name" '.name // $n')"
    sha="$(team_gate render "$name" "$(echo "$svc" | jq -r '(.repo // "") | sub("^https://github.com/";"") | sub("\\.git$";"")')" \
      "$(echo "$svc" | jq -r '.branch // "main"')" "$sha")" || exit 1
  fi
  lock="$(start_lock "render-$id")" || exit 1
  body="$(jq -nc --arg sha "$sha" --arg cc "$cc" '(if $sha != "" then {commitId:$sha} else {} end) + (if $cc != "" then {clearCache:"clear"} else {} end)')"
  out="$(render_call POST "/services/$id/deploys" "$body")" || { rm -f "$lock"; exit 1; }
  echo "$out" | jq --arg s "$id" "$RENDER_PHASE"'{id, serviceId:$s, url:null, state:.status, phase:(.status | rphase)}'
}

# deployId<TAB>phase<TAB>raw state. The service id is resolved by the caller (lookup).
render_status() {
  (render_call GET "/services/${1:?service id}/deploys/${2:?deploy id}") \
    | jq -r "$RENDER_PHASE"'"\(.id)\t\(.status | rphase // "")\t\(.status // "?")"'
}

# The newest deploy. Render has no previews: --preview changes nothing (the newest is the only kind).
render_latest() {
  (render_call GET "/services/${1:?service id}/deploys?limit=1") \
    | jq -r "$RENDER_PHASE"'(.[0].deploy // {id:"none"}) | "\(.id)\t\(.status | rphase // "")\t\(.status // "?")"'
}

render_cancel() {
  render_call POST "/services/${1:?service id}/deploys/${2:?deploy id}/cancel" '{}' | jq '{id, state:.status}'
}

# Back to the deploy that was live before the current one.
render_rollback() {
  local id prev
  id="$(render_id_of "${1:?service}")"
  prev="$(render_call GET "/services/$id/deploys?limit=20" | jq -r '([.[].deploy | select(.status=="live")][0].commit.id // "") as $cur
      | [.[].deploy | select(.status=="deactivated" and ((.commit.id // "") != $cur))][0].id // empty')"
  [ -n "$prev" ] || die "No earlier live deploy to roll back to"
  render_call POST "/services/$id/rollback" "{\"deployId\":\"$prev\"}" | jq --arg s "$id" '{id, serviceId:$s, state:.status}'
}

# render_logs <service> <lines> [deployId]
# The workspace (owner) of a service never changes: read once, then kept in render-owners.json.
render_owner_of() {
  local id="$1" f="$CONFIG_DIR/render-owners.json" o t
  o="$(jq -r --arg i "$id" '.[$i] // empty' "$f" 2>/dev/null)"
  if [ -z "$o" ]; then
    o="$(render_call GET "/services/$id" | jq -r '.ownerId // empty')" || return 1
    [ -n "$o" ] || return 1
    t="$(mktemp "$CONFIG_DIR/.owners.XXXXXX")" \
      && { jq --arg i "$id" --arg o "$o" '. + {($i): $o}' "$f" 2>/dev/null || jq -n --arg i "$id" --arg o "$o" '{($i): $o}'; } > "$t" \
      && mv "$t" "$f" || rm -f "$t"
  fi
  printf '%s\n' "$o"
}

render_logs() {
  local id n="$2" did="${3:-}" owner win="" page all='[]' got=0 lim more next
  id="$(render_id_of "$1")"; owner="$(render_owner_of "$id")" || die "Render: could not read service $id"
  # Render's logs have no deploy filter: the deploy's own time window stands in for it.
  [ -z "$did" ] || win="$(render_call GET "/services/$id/deploys/$did" | jq -r '"&startTime=\(.createdAt | @uri)" + (if .finishedAt then "&endTime=\(.finishedAt | @uri)" else "" end)')"
  # The logs API answers at most 100 lines a question: more come page by page, newest first,
  # through the next window it names (hasMore, nextStartTime, nextEndTime). Without those, it stops.
  while [ "$got" -lt "$n" ]; do
    lim=$((n - got)); [ "$lim" -le 100 ] || lim=100
    page="$(render_call GET "/logs?ownerId=$owner&resource=$id&type=build&limit=$lim&direction=backward$win")" || { [ "$got" -gt 0 ] && break; return 1; }
    all="$(jq -cs '.[0] + (.[1].logs // [])' <(printf '%s' "$all") <(printf '%s' "$page"))" || return 1
    got="$(jq 'length' <<< "$all")"
    more="$(jq -r '.hasMore // false' <<< "$page")"
    next="$(jq -r 'if .nextStartTime and .nextEndTime then "&startTime=\(.nextStartTime | @uri)&endTime=\(.nextEndTime | @uri)" else empty end' <<< "$page")"
    [ "$more" = true ] && [ -n "$next" ] && [ "$(jq '.logs // [] | length' <<< "$page")" -gt 0 ] || break
    win="$next"
  done
  jq -r '.[:'"$n"'] | reverse | .[].message' <<< "$all" | sed $'s/\x1b\\[[0-9;]*m//g'
}

render_url() {
  local svc; svc="$(render_call GET "/services/$(render_id_of "$1")")"
  if [ "${2:-}" = "--dashboard" ]; then echo "$svc" | jq -r '.dashboardUrl // empty'
  else echo "$svc" | jq -r '.serviceDetails.url // .dashboardUrl // empty'; fi
}

render_set_key() {
  local key
  IFS= read -r key || true
  # A key copied with a CR (Windows) or spaces around it: trimmed; spaces, quotes or a backslash inside are refused.
  key="$(printf "%s" "$key" | tr -d "\r" | sed "s/^[[:space:]]*//; s/[[:space:]]*\$//")"
  [ -n "$key" ] || die "Pipe the key in: pbpaste | deploys render set-key"
  case "$key" in *\'*|*\"*|*\\*|*[[:space:]]*|*[[:cntrl:]]*) die "That does not look like a Render API key";; esac
  # Tried first, saved only when Render takes it: a typo must not replace a working key.
  ( RENDER_API_KEY="$key" render_call GET "/services?limit=1" >/dev/null ) || die "Render did not accept that key; nothing was saved"
  # Sent to `security -i` on stdin, so the key is never an argument anyone can see.
  printf 'add-generic-password -U -a %s -s %s -w %s\n' "$USER" "$RENDER_KEYCHAIN_SERVICE" "$key" | security -i >/dev/null \
    || die "The key works, but could not be saved in the keychain"
  echo "Render key saved and working."
}

# Whether a key is there and where from, without reading it into a variable. printf, not jq.
render_key_source() {
  if [ -n "${RENDER_API_KEY:-}" ]; then echo environment
  elif security find-generic-password -a "$USER" -s "$RENDER_KEYCHAIN_SERVICE" -w >/dev/null 2>&1 \
    || security find-generic-password -a "$USER" -s "$RENDER_LEGACY_KEYCHAIN_SERVICE" -w >/dev/null 2>&1; then echo keychain
  else echo none; fi
}

render_doctor() {
  local src k=false; src="$(render_key_source)"; [ "$src" = none ] || k=true
  printf '{"renderKey":%s,"renderKeySource":"%s"}\n' "$k" "$src"
}

render_where() {
  local src; src="$(render_key_source)"; [ "$src" = environment ] && src="environment (RENDER_API_KEY)"
  printf '%-13s%s\n' "render key" "$src"
}

render_history() {
  render_call GET "/services/$(render_id_of "$1")/deploys?limit=$2" | jq -r 'def t: sub("\\.[0-9]+Z$";"Z") | fromdateiso8601;
    .[].deploy | [(.createdAt | t | strftime("%Y-%m-%d %H:%M")), .status, ((.commit.id // "")[0:7]), (.trigger // ""),
       (if .finishedAt then "\(((.finishedAt | t) - (.createdAt | t)))s" else "" end)]
    | map(if . == "" or . == null then "-" else . end) | @tsv' \
    | (printf 'WHEN (UTC)\tSTATE\tCOMMIT\tTRIGGER\tTOOK\n'; cat) | table
}

render_usage() {  # <argc> <verb>
  case "$2" in cancel|status) usage_if_short "$1" 4 "render $2 <service id> <deploy id>" ;; esac
}

# ---------- Commands people type (deploys render <verb>), kept as they always were ----------

render_cli_list() {
  render_services | jq -r '.[] | [.name, .type, '"$(render_auto)"', (if .suspended=="suspended" then "suspended" else "active" end)] | @tsv' \
    | (printf 'NAME\tTYPE\tAUTO-DEPLOY\tSTATE\n'; cat) | table
}

# Through deploy-json, so the same one-minute start lock as the app and deploy-changed applies.
render_cli_deploy() { render_deploy_json "$@" | jq -r '"Render: deploy started (\(.id), \(.state))"'; }

# render status <service name or srv- id> <deploy id>
render_cli_status() {
  local id; id="$(render_id_of "${1:?Usage: deploys render status <service> <deploy id>}")"
  render_call GET "/services/$id/deploys/${2:?Usage: deploys render status <service> <deploy id>}" | jq '{id, state:.status}'
}

render_cli_forget_key() {
  # Both names the key was ever stored under. A key in RENDER_API_KEY is not touched.
  local gone=0 svc
  for svc in "$RENDER_KEYCHAIN_SERVICE" "$RENDER_LEGACY_KEYCHAIN_SERVICE"; do
    security delete-generic-password -a "$USER" -s "$svc" >/dev/null 2>&1 && gone=$((gone + 1))
  done
  if [ "$gone" -gt 0 ]; then echo "Render key removed from the keychain."; else echo "No Render key was in the keychain."; fi
  [ -z "${RENDER_API_KEY:-}" ] || echo "RENDER_API_KEY is still set in the environment."
}
