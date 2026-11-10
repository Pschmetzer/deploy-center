#!/bin/bash
# providers/digitalocean.sh — DigitalOcean App Platform for `deploys`
# (opt-in: deploys providers enable digitalocean).
#
# An App Platform app has components (services, static sites, workers, jobs, functions). Each one
# built from a repo has its own `deploy_on_push` flag in the app spec (github / gitlab / bitbucket
# source; for DOCR images it is image.deploy_on_push.enabled). The API cannot change one flag: the
# whole spec goes back with PUT /v2/apps/{id}. So `off` reads the spec, sets every flag to false,
# changes nothing else, and keeps the old spec in do-specs/ so `on` can put the flags back.
#
# Contract (see the A1 provider PR): digitalocean_meta, _ready, _json, _has, _off, _deploy_json,
# _status, _latest, _cancel, _rollback, _logs, _url, _set_key, _doctor. Extra: digitalocean_on.
# Phases: queued | building | ready | failed | canceled.
#
# Access: a personal access token (cloud.digitalocean.com > API > Tokens) with read and write
# scope for apps, from DIGITALOCEAN_TOKEN or the keychain service deploy-center-digitalocean.
# Never printed, never an argument: curl gets it on stdin.
#
# Files (in the deploys config folder, mode 0600, the spec can hold plain env values):
#   do-specs/<app-id>.json   the spec as it was before the last `off` that changed something

DIGITALOCEAN_API="${DIGITALOCEAN_API:-https://api.digitalocean.com}"
DIGITALOCEAN_KEYCHAIN="deploy-center-digitalocean"
DIGITALOCEAN_DASHBOARD="https://cloud.digitalocean.com/apps"

# ---------- small helpers ----------

# What `deploys` defines (PRV-131). These stand in only when this file is sourced on its own
# (the provider tests do that); under `deploys` its own die, mtime and start_lock are used.
declare -F die >/dev/null || die() { echo "Error: $*" >&2; exit 1; }
# GNU first: on Linux `stat -f` means the file system and "succeeds" with the wrong answer.
declare -F mtime >/dev/null || mtime() { stat -c %Y "$1" 2>/dev/null || stat -f %m "$1"; }
digitalocean_config_dir() { echo "${CONFIG_DIR:-${DEPLOYS_CONFIG:-$HOME/.config/deploys}}"; }
digitalocean_specs_dir() {
  local d; d="$(digitalocean_config_dir)/do-specs"
  mkdir -p "$d" && chmod 700 "$d" 2>/dev/null
  echo "$d"
}

# The token: environment first, then the keychain. Uses the shared key_of when A1 provides it.
digitalocean_key() {
  local k=""
  # Read once per list (digitalocean_json): its parallel reads must not each ask the keychain.
  if [ -n "${_DIGITALOCEAN_KEY:-}" ]; then printf '%s' "$_DIGITALOCEAN_KEY"; return 0; fi
  if declare -F key_of >/dev/null; then k="$(key_of digitalocean 2>/dev/null)" || k=""
  elif [ -n "${DIGITALOCEAN_TOKEN:-}" ]; then k="$DIGITALOCEAN_TOKEN"
  else k="$(security find-generic-password -a "${USER:-$(id -un)}" -s "$DIGITALOCEAN_KEYCHAIN" -w 2>/dev/null)" || k=""
  fi
  [ -n "$k" ] || { echo "No DigitalOcean token. Create one at cloud.digitalocean.com > API > Tokens (apps: read, update), then: pbpaste | deploys digitalocean set-key" >&2; return 1; }
  printf '%s' "$k"
}

# digitalocean_call METHOD PATH [BODY] — the answer on stdout; on failure a reason on stderr, rc 1.
# The token goes to curl on stdin (-K -), so it never shows in the process list. Only for
# api.digitalocean.com: log URLs are pre-signed and must never get the token (digitalocean_fetch).
digitalocean_call() {
  local method="$1" path="$2" body="${3:-}" key out code try err bodyf=""
  key="$(digitalocean_key)" || return 1
  local args=(-sS --connect-timeout 10 --max-time 60 -X "$method" -H "Accept: application/json" -K -)
  # A body goes through a private file, not an argument: a spec can hold plain env values.
  if [ -n "$body" ]; then
    bodyf="$(umask 077; mktemp)"; printf '%s' "$body" > "$bodyf"
    args+=(-H "Content-Type: application/json" --data-binary "@$bodyf")
  fi
  err="$(mktemp)"
  for try in 1 2 3; do
    out="$(printf 'header = "Authorization: Bearer %s"\n' "$key" | curl "${args[@]}" -w '\n%{http_code}' "$DIGITALOCEAN_API$path" 2>"$err")" || out=$'\n000'
    code="${out##*$'\n'}"; out="${out%$'\n'*}"
    # Only reads are repeated: a POST that timed out may have started a deployment already.
    case "$code" in
      429) [ "$try" -lt 3 ] && { sleep $((try * 3)); continue; } ;;
      5*|000) [ "$method" = GET ] && [ "$try" -lt 3 ] && { sleep $((try * 2)); continue; } ;;
    esac
    break
  done
  [ "$code" != 000 ] || out="$(tail -n 1 "$err")"
  rm -f "$err" ${bodyf:+"$bodyf"}
  if [[ "$code" != 2* ]]; then
    local hint="" fix="deploys digitalocean set-key" msg
    [ -n "${DIGITALOCEAN_TOKEN:-}" ] && fix="check DIGITALOCEAN_TOKEN in the environment"
    case "$code" in
      000) hint=" (no answer: network or timeout)";;
      401) hint=" (the DigitalOcean token is wrong or expired: $fix)";;
      403) hint=" (the token may not do this: it needs read and update scope for apps)";;
      404) hint=" (not found: renamed or deleted?)";;
      409|422) hint=" (DigitalOcean refused it)";;
      429) hint=" (rate limit: try again in a minute)";;
      5*) hint=" (DigitalOcean had a problem: try again later)";;
    esac
    msg="$(printf '%s' "$out" | jq -r '.message // .id // empty' 2>/dev/null)" || msg=""
    # Not JSON (curl's own error, a proxy's HTML page): its first 200 characters, on one line.
    [ -n "$msg" ] || msg="$(printf '%s' "$out" | tr '\n\r\t' '   ' | cut -c1-200)"
    echo "DigitalOcean $method ${path%%\?*} -> HTTP $code$hint${msg:+: $msg}" >&2
    return 1
  fi
  printf '%s' "$out"
}

# A pre-signed log URL: https only, and without the token (it would leak to another host).
digitalocean_fetch() {
  case "$1" in https://*) ;; *) echo "DigitalOcean: skipped a log URL that is not https" >&2; return 1 ;; esac
  curl -sSfL --proto =https --proto-redir =https --connect-timeout 10 --max-time 120 "$1"
}

# Every app, all pages (links.pages.next is set while there are more).
digitalocean_apps() {
  local page=1 all="[]" chunk
  while :; do
    chunk="$(digitalocean_call GET "/v2/apps?page=$page&per_page=100")" || return 1
    all="$(jq -s '.[0] + (.[1].apps // [])' <(echo "$all") <(echo "$chunk"))"
    [ "$(echo "$chunk" | jq -r '.links.pages.next // empty')" = "" ] && break
    page=$((page + 1))
    [ "$page" -gt 50 ] && break
  done
  echo "$all"
}

# An app by name (spec.name), id, live domain or one of its domains.
digitalocean_id_of() {
  local n="$1" id
  # An app id (a UUID) needs no listing of every app; a wrong one fails at the next call.
  if [[ "$n" =~ ^[0-9a-f]{8}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{12}$ ]]; then echo "$n"; return 0; fi
  id="$(digitalocean_apps | jq -r --arg n "$n" '.[] | select(.id==$n or .spec.name==$n
    or .live_domain==$n or ([.spec.domains[]?.domain] | index($n))) | .id' | head -n 1)" || return 1
  [ -n "$id" ] || { echo "No DigitalOcean app named \"$n\". See: deploys digitalocean list" >&2; return 1; }
  echo "$id"
}

# jq definitions shared by the readers below.
# shellcheck disable=SC2016
DIGITALOCEAN_JQ='
  def t: (. // null) | if . then (sub("\\.[0-9]+Z$";"Z") | fromdateiso8601) else null end;
  # App Platform deployment phase -> contract phase. UNKNOWN is what a deployment has before
  # App Platform gave it a phase: it has not started, so it counts as queued.
  def phase: if . == null then null
    elif test("^(PENDING_BUILD|PENDING_DEPLOY|QUEUED|UNKNOWN)$") then "queued"
    elif test("^(BUILDING|DEPLOYING)$") then "building"
    elif . == "ACTIVE" then "ready"
    elif . == "ERROR" then "failed"
    elif test("^(CANCELED|SUPERSEDED)$") then "canceled"
    else null end;
  def kinds: ["services","static_sites","workers","jobs","functions"];
  def gits: ["github","gitlab","bitbucket"];
  def components: . as $s | [kinds[] as $k | ($s[$k] // [])[]];
  def git_of: first(gits[] as $g | .[$g] // empty | objects);
  # The flag of one component: true, false, or null when it has no source that can deploy on push.
  def push_flag: if git_of then (git_of.deploy_on_push == true)
    elif (.image.deploy_on_push | type) == "object" then (.image.deploy_on_push.enabled == true)
    else null end;
  def auto_on: [components[] | push_flag] | any(. == true);
  # The only change `off` makes: every deploy_on_push to false. Image sources only where the flag
  # is there already (it is valid for DOCR images only); everything else stays byte for byte.
  def push_off: reduce kinds[] as $k (.;
    if (.[$k] | type) == "array" then .[$k] |= map(
      reduce gits[] as $g (.; if (.[$g] | type) == "object" then .[$g].deploy_on_push = false else . end)
      | if (.image.deploy_on_push | type) == "object" then .image.deploy_on_push.enabled = false else . end)
    else . end);
  # `on`: the flags from a saved spec put back, matched by component kind and name.
  def push_from($old): reduce kinds[] as $k (.;
    if (.[$k] | type) == "array" then .[$k] |= map(. as $c
      | (($old[$k] // []) | map(select(.name == $c.name)) | .[0]) as $o
      | if $o == null then . else
          reduce gits[] as $g (.; if (.[$g] | type) == "object" and ($o[$g] | type) == "object"
            then .[$g].deploy_on_push = ($o[$g].deploy_on_push // false) else . end)
          | if (.image.deploy_on_push | type) == "object" and ($o.image.deploy_on_push | type) == "object"
            then .image.deploy_on_push.enabled = ($o.image.deploy_on_push.enabled // false) else . end
        end)
    else . end);
  def sha_of: [(.services, .static_sites, .workers, .jobs, .functions) // [] | .[]
    | .source_commit_hash // empty] | .[0] // null;
  def deploy_out($url; $app): {id, state:(.phase // null), phase:(.phase | phase), url:$url,
    dashboardUrl:(if $app and .id then "'"$DIGITALOCEAN_DASHBOARD"'/\($app)/deployments/\(.id)" else null end),
    sha:sha_of, msg:(.cause // null), createdAt:(.created_at | t),
    progress:(if .progress then "\(.progress.success_steps // 0)/\(.progress.total_steps // 0)" else null end),
    error:(if .phase == "ERROR" then ([.progress.steps[]? | select(.status == "ERROR") | .reason.message // .name] | .[0] // null) else null end)};
  def url_of: .live_url // .default_ingress // null;
'

digitalocean_app() { digitalocean_call GET "/v2/apps/$1"; }

# ---------- the contract ----------

# Compact (jq -c): deploys greps it (meta_flag, meta_str, key_of). Contract fields: id, label,
# noun, defaultOn, keyEnv (an array), keychain, caps (docs/PROVIDERS.md). Off by default.
digitalocean_meta() {
  jq -nc --arg k "$DIGITALOCEAN_KEYCHAIN" '{id:"digitalocean", label:"DigitalOcean App Platform", noun:"app", defaultOn:false,
    keyEnv:["DIGITALOCEAN_TOKEN"], keychain:$k,
    caps:{off:true, sha:false, cancel:true, rollback:true, logs:true, preview:false}}'
}

# Usable without asking anyone: tools there and a token found (not checked against DigitalOcean).
digitalocean_ready() {
  command -v curl >/dev/null 2>&1 && command -v jq >/dev/null 2>&1 && digitalocean_key >/dev/null 2>&1
}

digitalocean_has() { digitalocean_id_of "$1" 2>/dev/null; }

# One app with its newest deployment as {..app, _d:{last} | {fetchError}}, for digitalocean_json.
digitalocean_app_last() {
  local a="$1" id d
  id="$(echo "$a" | jq -r '.id')"
  if d="$(digitalocean_call GET "/v2/apps/$id/deployments?page=1&per_page=1" 2>&1)"; then
    # A 200 that is not JSON (a proxy's page) is this app's error, not an empty --argjson.
    d="$(echo "$d" | jq -c 'if type == "object" then {last:(.deployments[0] // null)} else error("no list") end' 2>/dev/null)" \
      || d="$(jq -nc '{fetchError:"DigitalOcean answered without a deployment list"}')"
  else
    d="$(jq -nc --arg e "$d" '{fetchError:$e}')"
  fi
  jq -nc --argjson a "$a" --argjson d "$d" '$a + {_d:$d}'
}

digitalocean_json() {
  local apps out a tmpd n=0 _DIGITALOCEAN_KEY pids=()
  apps="$(digitalocean_apps)" || die "Could not list DigitalOcean apps"
  # The token once, for the reads below (they run eight at a time).
  _DIGITALOCEAN_KEY="$(digitalocean_key)" || die "Could not list DigitalOcean apps"
  # The app list has the active and the in-progress deployment, not a failed one: ask for the
  # newest, eight apps at a time (one after another took seconds for many apps), a file each.
  tmpd="$(mktemp -d)"
  while IFS= read -r a; do
    [ -n "$a" ] || continue
    n=$((n + 1))
    ( digitalocean_app_last "$a" > "$tmpd/$n.json" ) &
    pids+=("$!")
    # Only these jobs are waited for (not others of the calling shell).
    [ $((n % 8)) -ne 0 ] || { wait "${pids[@]}"; pids=(); }
  done < <(echo "$apps" | jq -c '.[]')
  # ${pids[@]+...}: an empty array is "unbound" under set -u in macOS bash 3.2.
  wait ${pids[@]+"${pids[@]}"}
  out="$(cat "$tmpd"/*.json 2>/dev/null | jq -s '.')" || out="[]"
  rm -rf "$tmpd"
  echo "$out" | jq "$DIGITALOCEAN_JQ"'
    [ .[] | (.spec // {}) as $s
      | ([$s | components[] | git_of] | .[0]) as $git
      | (._d.last // .in_progress_deployment // .pending_deployment // .active_deployment // {}) as $new
      | (.active_deployment // {}) as $live
      | ((.pinned_deployment != null) or ($s.maintenance.archive == true)) as $paused
      | {name:($s.name // .id), id,
         auto:($s | auto_on),
         paused:$paused,
         deployable:(([$s | components[] | select(git_of or (.image | type) == "object")] | length > 0) and ($paused | not)),
         # GitHub: owner/name; GitLab and Bitbucket with their host, so heads are asked there.
         repo:(([$s | components[] | first(gits[] as $g | select((.[$g] | type) == "object") | $g)] | .[0]) as $h
               | ($git.repo // null) | if . == null then null elif $h == "gitlab" then "gitlab.com/\(.)"
                 elif $h == "bitbucket" then "bitbucket.org/\(.)" else . end),
         ref:($git.branch // null),
         domain:(.live_domain // ((url_of // "") | sub("^https?://";"") | sub("/.*$";"") | if . == "" then null else . end)),
         url:url_of, dashboardUrl:"'"$DIGITALOCEAN_DASHBOARD"'/\(.id)",
         lastAt:($new.created_at | t), lastState:($new.phase // null),
         lastSha:(($live | sha_of) // ($new | sha_of)),
         lastMsg:($live.cause // $new.cause // null),
         fetchError:(._d.fetchError // null), phase:($new.phase // null | phase)} ]
    | sort_by(.name | ascii_downcase)'
}

# digitalocean_off <app>: deploy_on_push=false on every component. GET the spec, change only the
# flags, PUT the whole spec back. The spec before the change goes to do-specs/<id>.json.
digitalocean_off() {
  # --all (docs/PROVIDERS.md): every app, one by one. One that fails does not stop the rest;
  # they are counted and the exit code says so. The list first, on its own: a failed read stops here.
  if [ "${1:-}" = --all ]; then
    local _names _n _bad=0
    _names="$(digitalocean_apps | jq -r '.[] | .id // empty')" || die "DigitalOcean: could not list the apps"
    while IFS= read -r _n; do
      [ -n "$_n" ] || continue
      ( digitalocean_off_one "$_n" ) || _bad=$((_bad + 1))
    done <<< "$_names"
    [ "$_bad" = 0 ] || die "$_bad DigitalOcean apps could not be switched off (see above); the others are done"
    echo "Done. No DigitalOcean app deploys on push any more."
    return 0
  fi
  digitalocean_off_one "$@"
}

digitalocean_off_one() {
  local app="$1" id info spec new back res left
  id="$(digitalocean_id_of "$app")" || die "DigitalOcean app $app not found"
  info="$(digitalocean_app "$id")" || die "DigitalOcean: could not read $app"
  spec="$(echo "$info" | jq -c '.app.spec // empty')"
  [ -n "$spec" ] || die "DigitalOcean: $app came back without a spec"
  if [ "$(echo "$spec" | jq "$DIGITALOCEAN_JQ"'auto_on')" != true ]; then
    echo "DigitalOcean: $app already does not deploy on push. Deploy with: deploys digitalocean deploy $app"
    return 0
  fi
  back="$(digitalocean_specs_dir)/$id.json"
  (umask 077; echo "$spec" | jq . > "$back.tmp") && mv "$back.tmp" "$back" && chmod 600 "$back" \
    || die "DigitalOcean: could not save the spec of $app; nothing was changed"
  new="$(echo "$spec" | jq -c "$DIGITALOCEAN_JQ"'push_off')"
  # update_all_source_versions stays false: the PUT must not pull a newer commit.
  res="$(digitalocean_call PUT "/v2/apps/$id" "$(jq -nc --argjson s "$new" '{spec:$s, update_all_source_versions:false}')")" \
    || die "DigitalOcean: could not update the spec of $app (the old one is kept in $back)"
  left="$(echo "$res" | jq -r "$DIGITALOCEAN_JQ"'.app.spec // {} | [components[] | select(push_flag == true) | .name] | join(", ")')"
  [ -z "$left" ] || die "DigitalOcean: $app still deploys on push for: $left"
  echo "DigitalOcean: $app no longer deploys on push (the old spec is in $back). Deploy with: deploys digitalocean deploy $app"
}

# digitalocean_on <app>: the deploy_on_push flags from the saved spec put back on the current
# spec. Only the flags: other changes made since `off` (env, sizes, domains) are kept.
digitalocean_on() {
  local app="$1" id info spec back new
  id="$(digitalocean_id_of "$app")" || die "DigitalOcean app $app not found"
  back="$(digitalocean_specs_dir)/$id.json"
  [ -s "$back" ] || die "DigitalOcean: no saved spec for $app ($back). Turn it on in the dashboard: $DIGITALOCEAN_DASHBOARD/$id/settings"
  info="$(digitalocean_app "$id")" || die "DigitalOcean: could not read $app"
  spec="$(echo "$info" | jq -c '.app.spec')"
  new="$(echo "$spec" | jq -c --slurpfile old "$back" "$DIGITALOCEAN_JQ"'push_from($old[0])')"
  if [ "$new" = "$spec" ]; then echo "DigitalOcean: $app already has the saved deploy-on-push settings"; return 0; fi
  digitalocean_call PUT "/v2/apps/$id" "$(jq -nc --argjson s "$new" '{spec:$s, update_all_source_versions:false}')" >/dev/null \
    || die "DigitalOcean: could not update the spec of $app"
  echo "DigitalOcean: $app deploys on push again, as before"
}

# digitalocean_deploy_json <app> [preview] [sha] — a new deployment of the branch's newest commit.
digitalocean_deploy_json() {
  local app="${1:-}" preview="" sha="" id info out lock=""
  shift || true
  # `deploys` calls <app> [--preview] [--sha <commit>]; the old positional <app> [preview] [sha]
  # still works. Without this, `--sha` landed in "preview" and was refused for the wrong reason.
  local _pos=0
  while [ $# -gt 0 ]; do
    case "$1" in
      --preview) preview=1 ;;
      --sha) [ -n "${2:-}" ] || die "DigitalOcean: --sha needs a commit"; sha="$2"; shift ;;
      -*) die "DigitalOcean: unknown option $1" ;;
      *) _pos=$((_pos + 1)); if [ "$_pos" = 1 ]; then preview="$1"; else sha="$1"; fi ;;
    esac
    shift
  done
  [ -z "$preview" ] || die "DigitalOcean App Platform cannot deploy a preview: it has no preview deploys"
  [ -z "$sha" ] || die "DigitalOcean App Platform cannot deploy a given commit: a deployment always builds the newest commit of the branch (--sha is not supported)"
  id="$(digitalocean_id_of "$app")" || die "DigitalOcean app $app not found"
  info="$(digitalocean_app "$id")" || die "DigitalOcean: could not read $app"
  [ "$(echo "$info" | jq '.app.pinned_deployment != null')" = true ] \
    && die "DigitalOcean: $app is pinned to a rollback. Commit or revert it in the dashboard first: $DIGITALOCEAN_DASHBOARD/$id"
  if declare -F start_lock >/dev/null; then lock="$(start_lock "digitalocean-$id")" || exit 1; fi
  out="$(digitalocean_call POST "/v2/apps/$id/deployments" '{"force_build":false}')" \
    || { rm -f "$lock"; die "DigitalOcean: could not start a deployment of $app"; }
  echo "$out" | jq -e '.deployment.id' >/dev/null 2>&1 || { rm -f "$lock"; die "DigitalOcean: $(echo "$out" | head -c 400)"; }
  echo "$out" | jq --argjson a "$(echo "$info" | jq -c .app)" "$DIGITALOCEAN_JQ"'
    .deployment | {id, url:($a | url_of), state:(.phase // null), phase:(.phase | phase)}'
}

# digitalocean_status_json <app> <deployment-id> — App Platform needs the app to find a deployment.
digitalocean_status_json() {
  local app="${1:-}" d="${2:-}" id out
  [ -n "$d" ] || die "DigitalOcean: status needs the app and the deployment id"
  id="$(digitalocean_id_of "$app")" || die "DigitalOcean app $app not found"
  out="$(digitalocean_call GET "/v2/apps/$id/deployments/$d")" || die "DigitalOcean: could not read deployment $d"
  echo "$out" | jq --arg app "$id" "$DIGITALOCEAN_JQ"'.deployment | deploy_out(null; $app)'
}

digitalocean_latest_json() {
  local id out
  id="$(digitalocean_id_of "$1")" || die "DigitalOcean app $1 not found"
  out="$(digitalocean_call GET "/v2/apps/$id/deployments?page=1&per_page=1")" || die "DigitalOcean: could not read the deployments of $1"
  echo "$out" | jq --arg app "$id" "$DIGITALOCEAN_JQ"'.deployments[0] // null | if . then deploy_out(null; $app) else null end'
}

# digitalocean_cancel <app> <deployment-id>
digitalocean_cancel() {
  local app="${1:-}" d="${2:-}" id
  [ -n "$d" ] || die "DigitalOcean: cancel needs the app and the deployment id"
  id="$(digitalocean_id_of "$app")" || die "DigitalOcean app $app not found"
  digitalocean_call POST "/v2/apps/$id/deployments/$d/cancel" >/dev/null || die "DigitalOcean: could not cancel $d"
  jq -nc --arg d "$d" '{id:$d, state:"CANCELED", phase:"canceled", message:"DigitalOcean: deployment \($d) canceled"}'
}

# digitalocean_rollback <app> [deployment-id]: back to the deployment that was live before the
# active one (or the one given). Each candidate is checked with /rollback/validate first. The
# rollback is committed at once (skip_pin): a pinned app takes no new deployments, ours included.
digitalocean_rollback() {
  local app="$1" want="${2:-}" id info live list cands c v target=""
  id="$(digitalocean_id_of "$app")" || die "DigitalOcean app $app not found"
  if [ -n "$want" ]; then cands="$want"; else
    info="$(digitalocean_app "$id")" || die "DigitalOcean: could not read $app"
    live="$(echo "$info" | jq -r '.app.active_deployment.id // empty')"
    list="$(digitalocean_call GET "/v2/apps/$id/deployments?page=1&per_page=20")" || die "DigitalOcean: could not read the deployments of $app"
    # Newest first. Only deployments older than the live one, and only ones that went live.
    cands="$(echo "$list" | jq -r --arg live "$live" '.deployments // [] | (map(.id) | index($live)) as $i
      | (if $i == null then . else .[($i + 1):] end)
      | [.[] | select(.id != $live and (.phase == "SUPERSEDED" or .phase == "ACTIVE"))] | .[:5][] | .id')"
  fi
  for c in $cands; do
    v="$(digitalocean_call POST "/v2/apps/$id/rollback/validate" "$(jq -nc --arg d "$c" '{deployment_id:$d, skip_pin:true}')")" || continue
    if [ "$(echo "$v" | jq '.valid == true')" = true ]; then
      target="$c"
      echo "$v" | jq -r '.warnings[]? | "DigitalOcean warns: \(.message)"' >&2
      break
    fi
    [ -n "$want" ] && die "DigitalOcean: cannot roll $app back to $c: $(echo "$v" | jq -r '.error.message // "not valid"')"
  done
  [ -n "$target" ] || die "DigitalOcean: $app has no earlier deployment that can be rolled back to"
  local out
  out="$(digitalocean_call POST "/v2/apps/$id/rollback" "$(jq -nc --arg d "$target" '{deployment_id:$d, skip_pin:true}')")" \
    || die "DigitalOcean: could not roll back to $target"
  # The rollback is a deployment of its own when App Platform names one; else the target.
  printf '%s' "$out" | jq -c --arg t "$target" --arg a "$app" "$DIGITALOCEAN_JQ"'(try .deployment catch null) as $d
    | {id:($d.id // $t), state:($d.phase // "PENDING_DEPLOY"), phase:(($d.phase // "PENDING_DEPLOY") | phase), target:$t,
       message:"DigitalOcean: \($a) is rolling back to deployment \($t)"}' 2>/dev/null \
    || jq -nc --arg t "$target" --arg a "$app" '{id:$t, state:"PENDING_DEPLOY", phase:"queued", target:$t, message:"DigitalOcean: \($a) is rolling back to deployment \($t)"}'
}

# digitalocean_logs <app> [--id <deployment>] [--component <name>]: the build log of each
# component, read from the historic URLs App Platform returns (pre-signed, no token sent there).
digitalocean_logs() {
  local app="$1" d="" only="" n="" id dep comps c res urls u
  shift
  # `deploys logs` calls <app> <lines> <deployId>, positional; the flags work too.
  while [ $# -gt 0 ]; do case "$1" in
    --id) d="${2:-}"; shift 2 ;;
    --component) only="${2:-}"; shift 2 ;;
    -*) die "Unknown option $1. Usage: digitalocean_logs <app> [lines] [deployId | --id <deployment>] [--component <name>]" ;;
    '') shift ;;
    *[!0-9]*) d="$1"; shift ;;
    *) n="$1"; shift ;;
  esac; done
  id="$(digitalocean_id_of "$app")" || die "DigitalOcean app $app not found"
  if [ -n "$d" ]; then
    dep="$(digitalocean_call GET "/v2/apps/$id/deployments/$d")" || die "DigitalOcean: could not read deployment $d"
    dep="$(echo "$dep" | jq -c '.deployment')"
  else
    dep="$(digitalocean_call GET "/v2/apps/$id/deployments?page=1&per_page=1")" || die "DigitalOcean: could not read the deployments of $app"
    dep="$(echo "$dep" | jq -c '.deployments[0] // empty')"
  fi
  [ -n "$dep" ] || die "DigitalOcean: $app has no deployments yet"
  d="$(echo "$dep" | jq -r '.id')"
  # Components built from source; databases have no build log.
  comps="$(echo "$dep" | jq -r "$DIGITALOCEAN_JQ"'.spec // {} | components[] | .name')"
  [ -n "$comps" ] || comps="$(digitalocean_app "$id" | jq -r "$DIGITALOCEAN_JQ"'.app.spec // {} | components[] | .name')"
  [ -n "$comps" ] || die "DigitalOcean: $app has no components with a build log"
  for c in $comps; do
    [ -z "$only" ] || [ "$c" = "$only" ] || continue
    res="$(digitalocean_call GET "/v2/apps/$id/deployments/$d/components/$c/logs?type=BUILD&follow=false")" || continue
    urls="$(echo "$res" | jq -r '.historic_urls[]? // empty')"
    echo "== $c (deployment $d) =="
    if [ -z "$urls" ]; then
      echo "(no build log archived yet; the build may still be running: $DIGITALOCEAN_DASHBOARD/$id/deployments/$d)"
      continue
    fi
    # The end of each log, like the other providers: a build log can be megabytes.
    for u in $urls; do
      if [ -n "$n" ]; then digitalocean_fetch "$u" | tail -n "$n" || echo "(could not read $c's log: $DIGITALOCEAN_DASHBOARD/$id/deployments/$d)"
      else digitalocean_fetch "$u" || echo "(could not read $c's log: $DIGITALOCEAN_DASHBOARD/$id/deployments/$d)"; fi
    done
  done
}

# digitalocean_url <app> [--dashboard]
digitalocean_url() {
  local id info
  id="$(digitalocean_id_of "$1")" || die "DigitalOcean app $1 not found"
  if [ "${2:-}" = --dashboard ]; then echo "$DIGITALOCEAN_DASHBOARD/$id"; return 0; fi
  info="$(digitalocean_app "$id")" || die "DigitalOcean: could not read $1"
  echo "$info" | jq -r "$DIGITALOCEAN_JQ"'.app | url_of // empty'
}

# The token on stdin. Tried against GET /v2/account first, saved only when DigitalOcean takes it.
digitalocean_set_key() {
  local key=""
  IFS= read -r key || true
  # A trailing CR, tab or newline from the clipboard is not part of the token.
  key="$(printf '%s' "$key" | tr -d '[:space:]')"
  [ -n "$key" ] || die "Pipe the token in: pbpaste | deploys digitalocean set-key"
  case "$key" in *\'*|*\"*|*' '*|*\\*) die "That does not look like a DigitalOcean token";; esac
  ( DIGITALOCEAN_TOKEN="$key"; key_of() { printf '%s' "$DIGITALOCEAN_TOKEN"; }; digitalocean_call GET /v2/account >/dev/null ) \
    || die "DigitalOcean did not accept that token; nothing was saved"
  # On stdin to `security -i`, so the token is never an argument anyone can see.
  printf 'add-generic-password -U -a %s -s %s -w %s\n' "${USER:-$(id -un)}" "$DIGITALOCEAN_KEYCHAIN" "$key" | security -i >/dev/null \
    || die "The token works, but could not be saved in the keychain"
  echo "DigitalOcean token saved and working."
}

digitalocean_doctor() {
  local src="missing" ok=false err="" n=null specs
  if [ -n "${DIGITALOCEAN_TOKEN:-}" ]; then src="env"
  elif security find-generic-password -a "${USER:-$(id -un)}" -s "$DIGITALOCEAN_KEYCHAIN" >/dev/null 2>&1; then src="keychain"; fi
  if [ "$src" != missing ]; then
    if err="$(digitalocean_call GET /v2/account 2>&1 >/dev/null)"; then ok=true; err=""
      n="$(digitalocean_apps 2>/dev/null | jq 'length' 2>/dev/null)" || n=null
    fi
  fi
  specs="$(find "$(digitalocean_specs_dir)" -name '*.json' 2>/dev/null | wc -l | tr -d ' ')"
  jq -n --arg src "$src" --argjson ok "$ok" --arg err "$err" --argjson n "${n:-null}" --argjson s "${specs:-0}" \
    '{provider:"digitalocean", key:$src, tokenOk:$ok, error:(if $err == "" then null else $err end),
      apps:$n, savedSpecs:$s}'
}

# ---------- the contract's status lines (docs/PROVIDERS.md) ----------
# `deploys watch`, `deploy --wait` and group deploys read one line: deployId<TAB>phase<TAB>state,
# and "none" as the id when there is no deploy. The JSON above stays for people:
# `deploys digitalocean status|latest` prints it (digitalocean_cli_status, digitalocean_cli_latest).
DIGITALOCEAN_TSV='if . == null then "none\t\tnone"
  else "\(.id // "none")\t\(.phase // "")\t\(.state // (if .stage then "\(.stage):\(.status // "")" else .status end) // "?")" end'
digitalocean_status() { local j; j="$(digitalocean_status_json "$@")" || return 1; printf '%s' "$j" | jq -r "$DIGITALOCEAN_TSV"; }
digitalocean_latest() { local j; j="$(digitalocean_latest_json "$@")" || return 1; printf '%s' "$j" | jq -r "$DIGITALOCEAN_TSV"; }
digitalocean_cli_status() { digitalocean_status_json "$@"; }
digitalocean_cli_latest() { digitalocean_latest_json "$@"; }
