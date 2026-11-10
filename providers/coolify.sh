#!/bin/bash
# providers/coolify.sh — the Coolify provider for `deploys` (opt-in: deploys providers enable coolify).
#
# Coolify builds on your own server. A push storm is not a bill there, it is a VPS at 100% CPU
# while your apps run on the same box. This provider turns off Coolify's per-application
# "Auto Deploy" and starts deploys by hand.
#
# Contract (see the A1 provider PR): coolify_meta, _ready, _json, _has, _off, _deploy_json,
# _status, _latest, _cancel, _rollback, _logs, _url, _set_key, _doctor.
# Phases: queued | building | ready | failed | canceled.
#
# Checked against Coolify's openapi.json and API controllers at v4.7.3. Rollback needs v4.3+.
#
# Instance: one per setup. COOLIFY_URL, else "url" in <config>/coolify.json, e.g.
#   {"url": "https://coolify.example.com"}
# Token: COOLIFY_TOKEN, else the keychain service deploy-center-coolify. Never printed.
# Permissions the token needs: read, write (auto-deploy switch), deploy; read:sensitive for build logs.
#
# State (in the deploys config folder, mode 0600):
#   coolify-off.json  {appUuid: {auto, previews, offAt}}  the values before we turned them off,
#                     so coolify_on can put them back.

COOLIFY_KEYCHAIN="deploy-center-coolify"

# ---------- small helpers (the main script has its own; these stand in when sourced alone) ----------

coolify_die() {
  if declare -F die >/dev/null; then die "$@"; fi
  echo "Error: $*" >&2; exit 1
}
coolify_config_dir() { echo "${CONFIG_DIR:-${DEPLOYS_CONFIG:-$HOME/.config/deploys}}"; }
coolify_off_file() {
  local d f; d="$(coolify_config_dir)"; f="$d/coolify-off.json"
  mkdir -p "$d" && chmod 700 "$d" 2>/dev/null
  [ -s "$f" ] || (umask 077; echo '{}' > "$f")
  echo "$f"
}
coolify_off_edit() {
  local f tmp; f="$(coolify_off_file)"; tmp="$(umask 077; mktemp)"
  jq "$@" "$f" > "$tmp" && mv "$tmp" "$f" && chmod 600 "$f"
}

# The instance, without a trailing slash or /api/v1 (both are accepted as input).
coolify_base() {
  local u="${COOLIFY_URL:-}" f
  if [ -z "$u" ]; then
    f="$(coolify_config_dir)/coolify.json"
    [ -f "$f" ] && u="$(jq -r '.url // empty' "$f" 2>/dev/null)"
  fi
  [ -n "$u" ] || { echo "No Coolify instance. Set COOLIFY_URL, or run: deploys coolify set-url https://coolify.example.com" >&2; return 1; }
  u="${u%/}"; u="${u%/api/v1}"; u="${u%/}"
  case "$u" in http://*|https://*) ;; *) u="https://$u" ;; esac
  printf '%s' "$u"
}

# The token: environment first, then the keychain. Uses the shared key_of when A1 provides it.
coolify_key() {
  local k=""
  if declare -F key_of >/dev/null; then k="$(key_of coolify 2>/dev/null)" || k=""
  elif [ -n "${COOLIFY_TOKEN:-}" ]; then k="$COOLIFY_TOKEN"
  else k="$(security find-generic-password -a "${USER:-$(id -un)}" -s "$COOLIFY_KEYCHAIN" -w 2>/dev/null)" || k=""
  fi
  [ -n "$k" ] || { echo "No Coolify token. Create one in Coolify under Keys & Tokens > API tokens (read, write, deploy), then: pbpaste | deploys coolify set-key" >&2; return 1; }
  printf '%s' "$k"
}

# coolify_call METHOD PATH [BODY] — the answer on stdout; on failure a reason on stderr, rc 1.
# The token goes to curl on stdin (-K -), so it never shows in the process list.
coolify_call() {
  local method="$1" path="$2" body="${3:-}" key base out code try err
  base="$(coolify_base)" || return 1
  key="$(coolify_key)" || return 1
  local args=(-sS --connect-timeout 10 --max-time 60 -X "$method" -H "Accept: application/json" -K -)
  [ -n "$body" ] && args+=(-H "Content-Type: application/json" --data "$body")
  err="$(mktemp)"
  for try in 1 2 3; do
    out="$(printf 'header = "Authorization: Bearer %s"\n' "$key" | curl "${args[@]}" -w '\n%{http_code}' "$base/api/v1$path" 2>"$err")" || out=$'\n000'
    code="${out##*$'\n'}"; out="${out%$'\n'*}"
    # Only reads are repeated: a POST that timed out may have queued a build already.
    case "$code" in
      429) [ "$try" -lt 3 ] && { sleep $((try * 3)); continue; } ;;
      5*|000) [ "$method" = GET ] && [ "$try" -lt 3 ] && { sleep $((try * 2)); continue; } ;;
    esac
    break
  done
  [ "$code" != 000 ] || out="$(tail -n 1 "$err")"
  rm -f "$err"
  if [[ "$code" != 2* ]]; then
    local hint="" fix="deploys coolify set-key" msg
    [ -n "${COOLIFY_TOKEN:-}" ] && fix="check COOLIFY_TOKEN in the environment"
    msg="$(printf '%s' "$out" | jq -r '.message // .error // empty' 2>/dev/null)" || msg=""
    case "$code" in
      000) hint=" (no answer from $base: network, timeout or certificate)";;
      401) hint=" (the Coolify token is wrong or expired: $fix)";;
      403) case "$msg" in
             *"API is disabled"*) hint=" (turn on API access in Coolify: Settings > Advanced)";;
             *) hint=" (the token lacks a permission for this)";;
           esac;;
      404) hint=" (not found: deleted, or an older Coolify?)";;
      422) hint=" (Coolify refused it)";;
      429) hint=" (rate limit or deploy queue full: try again in a minute)";;
      5*) hint=" (Coolify had a problem: try again later)";;
    esac
    echo "Coolify $method ${path%%\?*} -> HTTP $code$hint${msg:+: $msg}" >&2
    return 1
  fi
  printf '%s' "$out"
}

coolify_apps() { coolify_call GET /applications; }

# An application by uuid or name. Names are not unique in Coolify (one per project/environment).
coolify_id_of() {
  local n="$1" ids
  ids="$(coolify_apps | jq -r --arg n "$n" '.[] | select(.uuid==$n or .name==$n) | .uuid')" || return 1
  [ -n "$ids" ] || { echo "No Coolify application named \"$n\". See: deploys coolify list" >&2; return 1; }
  [ "$(printf '%s\n' "$ids" | wc -l | tr -d ' ')" = 1 ] \
    || { echo "Several Coolify applications are named \"$n\"; use the uuid: $(printf '%s' "$ids" | tr '\n' ' ')" >&2; return 1; }
  echo "$ids"
}

# jq definitions shared by the readers below. $base is the instance URL.
# shellcheck disable=SC2016
COOLIFY_JQ='
  def t: (. // null) | if . then (sub("\\.[0-9]+Z$";"Z") | sub("\\+00:00$";"Z") | fromdateiso8601) else null end;
  def phase: if . == null then null
    elif . == "queued" then "queued"
    elif . == "finished" then "ready"
    elif . == "failed" then "failed"
    elif test("^cancel") then "canceled"
    else "building" end;
  # owner/repo for GitHub (the GitHub App stores it short), null for other hosts and image apps.
  def repo_of: (.git_repository // "") as $r
    | if (.build_pack // "") == "dockerimage" or $r == "" then null
      elif ($r | test("^[A-Za-z0-9_.-]+/[A-Za-z0-9_.-]+$")) then $r
      elif ($r | test("github\\.com[:/]")) then ($r | sub("^.*github\\.com[:/]";"") | sub("\\.git$";"") | sub("/$";""))
      else null end;
  # Only apps that build from git react to a push; an image app has nothing to auto-deploy.
  def git_based: ((.git_repository // "") != "") and ((.build_pack // "") != "dockerimage");
  def domains: (.fqdn // "") | split(",") | map(gsub("^\\s+|\\s+$";"")) | map(select(. != ""));
  def app_url: (domains[0] // null) | if . == null then null elif test("^https?://") then . else "https://" + . end;
  def dash($p): if $p then $base + $p else null end;
  # The application page: a deployment path without its /deployment/<uuid> tail.
  def app_dash: (.deployment_url // null) | if . then dash(sub("/deployment/[^/]+$";"")) else null end;
  def prod: map(select((.pull_request_id // 0) == 0));
  def deploy_out: {id:.deployment_uuid, state:.status, phase:(.status | phase), url:null,
    dashboardUrl:dash(.deployment_url // null),
    sha:((.commit // null) | if . == "HEAD" then null else . end),
    msg:((.commit_message // null) | if . then split("\n")[0] else null end),
    createdAt:(.created_at | t), rollback:(.rollback // false)};
'

# ---------- the contract ----------

# Compact (jq -c): deploys greps it (meta_flag, meta_str, key_of). Contract fields: id, label,
# noun, defaultOn, keyEnv (an array), keychain, caps (docs/PROVIDERS.md). Off by default.
coolify_meta() {
  jq -nc --arg k "$COOLIFY_KEYCHAIN" '{id:"coolify", label:"Coolify", noun:"application", defaultOn:false, keyEnv:["COOLIFY_TOKEN"], urlEnv:"COOLIFY_URL", keychain:$k,
    caps:{off:true, sha:true, cancel:true, rollback:true, logs:true, preview:false}}'
}

# Usable without asking anyone: tools there, an instance and a token found (not checked against Coolify).
coolify_ready() {
  command -v curl >/dev/null 2>&1 && command -v jq >/dev/null 2>&1 \
    && coolify_base >/dev/null 2>&1 && coolify_key >/dev/null 2>&1
}

coolify_has() { coolify_id_of "$1" 2>/dev/null; }

coolify_json() {
  local apps base out="[]" uuid one d
  base="$(coolify_base)" || coolify_die "Coolify: no instance configured"
  apps="$(coolify_apps)" || coolify_die "Could not list Coolify applications"
  # The list has no settings (auto-deploy lives there), so each app is read once more.
  while IFS= read -r uuid; do
    [ -n "$uuid" ] || continue
    if one="$(coolify_call GET "/applications/$uuid" 2>&1)"; then
      if d="$(coolify_call GET "/deployments/applications/$uuid?take=20" 2>&1)"; then
        d="$(echo "$d" | jq -c '{deployments:(.deployments // [])}')"
      else
        d="$(jq -nc --arg e "$d" '{fetchError:$e}')"
      fi
      one="$(echo "$one" | jq -c --argjson d "$d" '. + {_d:$d}')"
    else
      one="$(echo "$apps" | jq -c --arg u "$uuid" --arg e "$one" '.[] | select(.uuid==$u) | . + {_d:{fetchError:$e}}')"
    fi
    out="$(jq -c --argjson a "$one" '. + [$a]' <<<"$out")"
  done < <(echo "$apps" | jq -r '.[].uuid')
  echo "$out" | jq --arg base "$base" "$COOLIFY_JQ"'
    [ .[] | ((._d.deployments // []) | prod) as $ds
      | ($ds[0] // {}) as $new
      | ([$ds[] | select(.status == "finished")][0] // {}) as $live
      | {name, id:.uuid,
         auto:(git_based and (.settings.is_auto_deploy_enabled != false)),
         paused:false,
         deployable:(repo_of != null),
         repo:repo_of, ref:(if (.build_pack // "") == "dockerimage" then null else (.git_branch // null) end),
         domain:((domains[0] // null) | if . then sub("^https?://";"") | sub("/.*$";"") else null end),
         url:app_url,
         dashboardUrl:(($ds[0] // {}) | app_dash),
         lastAt:($new.created_at | t), lastState:($new.status // null),
         lastSha:(($live.commit // null) | if . == "HEAD" then null else . end),
         lastMsg:(($live.commit_message // null) | if . then split("\n")[0] else null end),
         fetchError:(._d.fetchError // null), phase:($new.status // null | phase)} ]
    | sort_by(.name | ascii_downcase)'
}

# coolify_off <app> [--previews]: Auto Deploy off. --previews also stops PR preview builds.
# The values before are remembered (the first time only), for coolify_on.
coolify_off() {
  local app="$1" previews="${2:-}" id info auto prev body after
  id="$(coolify_id_of "$app")" || coolify_die "Coolify application $app not found"
  info="$(coolify_call GET "/applications/$id")" || coolify_die "Coolify: could not read $app"
  auto="$(echo "$info" | jq '.settings.is_auto_deploy_enabled != false')"
  prev="$(echo "$info" | jq '.settings.is_preview_deployments_enabled // false')"
  coolify_off_edit --arg id "$id" --argjson a "$auto" --argjson p "$prev" \
    '.[$id] = ({auto:$a, previews:$p, offAt:(now|floor)} + (.[$id] // {}))'
  body='{"is_auto_deploy_enabled":false}'
  [ "$previews" = --previews ] && body='{"is_auto_deploy_enabled":false,"is_preview_deployments_enabled":false}'
  if [ "$auto" = false ] && { [ "$previews" != --previews ] || [ "$prev" = false ]; }; then
    echo "Coolify: $app already does not deploy on push."
  else
    coolify_call PATCH "/applications/$id" "$body" >/dev/null || coolify_die "Coolify: could not turn off auto-deploy for $app"
    # Read back: an older Coolify that ignores the field must not look like a success.
    after="$(coolify_call GET "/applications/$id")" || coolify_die "Coolify: could not read $app back"
    [ "$(echo "$after" | jq '.settings.is_auto_deploy_enabled != false')" = false ] \
      || coolify_die "Coolify accepted the change but $app still has Auto Deploy on (Coolify too old?)"
    echo "Coolify: $app no longer deploys on push. Deploy with: deploys coolify deploy $app"
  fi
  if [ "$previews" != --previews ] && [ "$prev" = true ]; then
    echo "Note: PR preview deployments are on for $app and still build on every push to a pull request. To stop them too: deploys coolify autodeploy-off $app --previews"
  fi
}

# coolify_on <app>: put back what coolify_off found (not part of the contract).
coolify_on() {
  local app="$1" id rec body
  id="$(coolify_id_of "$app")" || coolify_die "Coolify application $app not found"
  rec="$(jq -c --arg id "$id" '.[$id] // empty' "$(coolify_off_file)")"
  [ -n "$rec" ] || rec='{"auto":true,"previews":null}'
  body="$(echo "$rec" | jq -c '{is_auto_deploy_enabled:.auto} + (if .previews == true then {is_preview_deployments_enabled:true} else {} end)')"
  coolify_call PATCH "/applications/$id" "$body" >/dev/null || coolify_die "Coolify: could not change $app"
  coolify_off_edit --arg id "$id" 'del(.[$id])'
  echo "Coolify: $app is back to auto-deploy $(echo "$rec" | jq -r 'if .auto then "on" else "off" end')."
}

# Put an application's git_commit_sha back after a pinned deploy; says so when that fails.
coolify_unpin() {  # coolify_unpin <id> <value before> <pinned sha> [<name>]
  coolify_call PATCH "/applications/$1" "$(jq -nc --arg s "$2" '{git_commit_sha:$s}')" >/dev/null \
    || echo "Warning: the Coolify application ${4:-$1} is still pinned to $3. Set its Git commit back to $2 (Configuration > Source)." >&2
}

# coolify_deploy_json <app> [preview] [sha]
# A sha: Coolify's /deploy has no commit field, but a deployment takes the application's
# git_commit_sha when it is queued. So: pin the sha, queue, put the old value back.
coolify_deploy_json() {
  local app="$1" sha="" id info pinned="" out did lock="" one base rc
  shift || true
  while [ $# -gt 0 ]; do
    case "$1" in
      --preview) coolify_die "Coolify cannot deploy a preview from here (preview deploys need a pull request)" ;;
      --sha) sha="${2:-}"; [ -n "$sha" ] || coolify_die "Usage: deploy-json <application> --sha <commit>"; shift ;;
      "") ;;
      *) coolify_die "Unknown option $1. Usage: deploy-json <application> [--sha <commit>]" ;;
    esac; shift
  done
  if [ -n "$sha" ]; then
    [[ "$sha" =~ ^[0-9a-fA-F]{7,40}$ ]] || coolify_die "Coolify: \"$sha\" is not a commit sha"
  fi
  id="$(coolify_id_of "$app")" || coolify_die "Coolify application $app not found"
  if declare -F start_lock >/dev/null; then lock="$(start_lock "coolify-$id")" || exit 1; fi
  if [ -n "$sha" ]; then
    info="$(coolify_call GET "/applications/$id")" || { rm -f "$lock"; coolify_die "Coolify: could not read $app"; }
    [ "$(echo "$info" | jq -r '.build_pack // ""')" != dockerimage ] && [ "$(echo "$info" | jq -r '.git_repository // ""')" != "" ] \
      || { rm -f "$lock"; coolify_die "Coolify: $app does not build from git; --sha does not apply"; }
    pinned="$(echo "$info" | jq -r '.git_commit_sha // "HEAD" | if . == "" then "HEAD" else . end')"
    coolify_call PATCH "/applications/$id" "$(jq -nc --arg s "$sha" '{git_commit_sha:$s}')" >/dev/null \
      || { rm -f "$lock"; coolify_die "Coolify: could not pin $app to $sha"; }
  fi
  # From the pin to its undoing, Ctrl-C or a kill must not leave the app pinned for good (every
  # later auto-deploy would build that commit): the trap puts the old value back first. No EXIT
  # trap: the call below runs in a subshell, so a failure there cannot end this one early, and an
  # EXIT trap would replace one the caller has.
  if [ -n "$pinned" ]; then
    # shellcheck disable=SC2064  # the values now, not when it fires
    trap "coolify_unpin '$id' '$pinned' '$sha'; rm -f '$lock'; trap - INT TERM HUP; exit 130" INT TERM HUP
  fi
  out="$(coolify_call POST "/deploy?uuid=$id" 2>&1)"; rc=$?
  if [ -n "$pinned" ]; then
    trap - INT TERM HUP
    coolify_unpin "$id" "$pinned" "$sha" "$app"
  fi
  [ "$rc" = 0 ] || { rm -f "$lock"; coolify_die "Coolify: the deploy of $app was not taken: $out"; }
  did="$(echo "$out" | jq -r '[.deployments[]? | select(.deployment_uuid != null)][0].deployment_uuid // empty')"
  if [ -z "$did" ]; then
    rm -f "$lock"
    coolify_die "Coolify did not queue $app: $(echo "$out" | jq -r '[.deployments[]?.message, .message] | map(select(. != null)) | first // "no reason given"')"
  fi
  base="$(coolify_base)"
  one="$(coolify_call GET "/deployments/$did" 2>/dev/null)" || one=""
  if [ -n "$one" ]; then
    echo "$one" | jq --arg base "$base" "$COOLIFY_JQ"'deploy_out | {id, url, state, phase, dashboardUrl}'
  else
    jq -n --arg id "$did" '{id:$id, url:null, state:"queued", phase:"queued", dashboardUrl:null}'
  fi
}

# coolify_status_json [<app>] <deployment-uuid>
coolify_status_json() {
  local d="${2:-$1}" out base
  base="$(coolify_base)" || coolify_die "Coolify: no instance configured"
  out="$(coolify_call GET "/deployments/$d")" || coolify_die "Coolify: could not read deployment $d"
  echo "$out" | jq --arg base "$base" "$COOLIFY_JQ"'deploy_out'
}

# The newest production deployment (not a PR preview).
coolify_latest_json() {
  local id out base
  base="$(coolify_base)" || coolify_die "Coolify: no instance configured"
  id="$(coolify_id_of "$1")" || coolify_die "Coolify application $1 not found"
  out="$(coolify_call GET "/deployments/applications/$id?take=20")" || coolify_die "Coolify: could not read the deployments of $1"
  echo "$out" | jq --arg base "$base" "$COOLIFY_JQ"'(.deployments // []) | prod | .[0] // null | if . then deploy_out else null end'
}

# The contract (watch, deploy --wait): deployId<TAB>phase<TAB>state, "none" when there is none.
# The JSON stays in coolify_status_json/_latest_json, and `deploys coolify status|latest` prints it.
COOLIFY_TSV='if . == null then "none\t\t?" else "\(.id // "none")\t\(.phase // "")\t\(.state // .status // .phase // "?")" end'
coolify_status() { local j; j="$(coolify_status_json "$@")" || return 1; printf '%s\n' "${j:-null}" | jq -r "$COOLIFY_TSV"; }
coolify_latest() { local j; j="$(coolify_latest_json "$@")" || return 1; printf '%s\n' "${j:-null}" | jq -r "$COOLIFY_TSV"; }
coolify_cli_status() { coolify_status_json "$@"; }
coolify_cli_latest() { coolify_latest_json "$@"; }

# coolify_cancel [<app>] <deployment-uuid>
coolify_cancel() {
  local d="${2:-$1}"
  coolify_call POST "/deployments/$d/cancel" >/dev/null || coolify_die "Coolify: could not cancel $d"
  echo "Coolify: deployment $d canceled"
}

# Back to the commit before the one that is live: the newest finished production deployment
# older than the live one, with another commit. Coolify allows only such commits (or image tags
# still on the server), and reuses the image when it is still there: then nothing is built.
coolify_rollback() {
  local id list target images local_img="" out
  id="$(coolify_id_of "$1")" || coolify_die "Coolify application $1 not found"
  list="$(coolify_call GET "/deployments/applications/$id?take=50")" || coolify_die "Coolify: could not read the deployments of $1"
  target="$(echo "$list" | jq -r "$COOLIFY_JQ"'[(.deployments // []) | prod | .[] | select(.status == "finished")] as $f
    | ($f[0].commit // null) as $live
    | [$f[1:][] | select(.rollback != true and .commit != $live and .commit != "HEAD" and (.commit // "") != "")][0].commit // empty')"
  [ -n "$target" ] || coolify_die "Coolify: $1 has no earlier finished deployment of another commit to go back to"
  images="$(coolify_call GET "/applications/$id/rollback-images" 2>/dev/null)" || images=""
  [ -n "$images" ] && echo "$images" | jq -e --arg t "$target" '.images[]? | select(.tag == $t)' >/dev/null 2>&1 && local_img=1
  if ! out="$(coolify_call POST "/applications/$id/rollback" "$(jq -nc --arg c "$target" '{commit:$c}')" 2>&1)"; then
    case "$out" in *"HTTP 404"*) coolify_die "Coolify: rollback needs Coolify v4.3 or newer ($out)";; esac
    coolify_die "Coolify: could not roll $1 back: $out"
  fi
  echo "Coolify: $1 is going back to ${target:0:7}$( [ -n "$local_img" ] && echo " (image still on the server: no build)") — deployment $(echo "$out" | jq -r '.deployment_uuid // "queued"')"
}

# coolify_logs <app> [lines] [--id <deployment>] [--runtime]
# The build log of a deployment (needs the token's read:sensitive permission), or with
# --runtime the running container's log.
coolify_logs() {
  local app="$1" lines=200 d="" runtime="" id out
  shift
  while [ $# -gt 0 ]; do
    case "$1" in
      --id) d="${2:-}"; shift 2 ;;
      --runtime) runtime=1; shift ;;
      ''|*[!0-9]*) shift ;;
      *) lines="$1"; shift ;;
    esac
  done
  if [ -n "$runtime" ]; then
    id="$(coolify_id_of "$app")" || coolify_die "Coolify application $app not found"
    out="$(coolify_call GET "/applications/$id/logs?lines=$lines")" || coolify_die "Coolify: could not read the logs of $app"
    echo "$out" | jq -r '.logs // ""'
    return 0
  fi
  if [ -z "$d" ]; then
    d="$(coolify_latest_json "$app" | jq -r '.id // empty')"
    [ -n "$d" ] || coolify_die "Coolify: $app has no deployments yet"
  fi
  out="$(coolify_call GET "/deployments/$d")" || coolify_die "Coolify: could not read deployment $d"
  echo "$out" | jq -e 'has("logs") and .logs != null' >/dev/null \
    || coolify_die "Coolify sent no build log for $d: give the token the read:sensitive permission"
  echo "$out" | jq -r --argjson n "$lines" '.logs | (try fromjson catch [{output:.}])
    | map(select(.hidden != true)) | sort_by(.order // 0)
    | map((if .command then "$ " + .command + "\n" else "" end) + (.output // "")) | join("\n")
    | split("\n") | .[-$n:] | .[]'
}

# coolify_url <app> [--dashboard]
coolify_url() {
  local id info base
  base="$(coolify_base)" || coolify_die "Coolify: no instance configured"
  id="$(coolify_id_of "$1")" || coolify_die "Coolify application $1 not found"
  if [ "${2:-}" = --dashboard ]; then
    info="$(coolify_call GET "/deployments/applications/$id?take=1" 2>/dev/null)" || info='{}'
    info="$(echo "$info" | jq -r --arg base "$base" "$COOLIFY_JQ"'(.deployments // [])[0] // {} | app_dash // empty')"
    echo "${info:-$base}"
  else
    coolify_apps | jq -r --arg u "$id" "$COOLIFY_JQ"'.[] | select(.uuid == $u) | app_url // empty'
  fi
}

# coolify_set_url <url>: write the instance to coolify.json, after Coolify answered /health there.
coolify_set_url() {
  local u="${1:-}" f d tmp
  [ -n "$u" ] || coolify_die "Usage: deploys coolify set-url https://coolify.example.com"
  u="$(COOLIFY_URL="$u" coolify_base)" || coolify_die "That is not a URL"
  curl -sSf --connect-timeout 10 --max-time 20 "$u/api/health" >/dev/null 2>&1 \
    || coolify_die "No Coolify answered at $u/api/health; nothing was saved"
  d="$(coolify_config_dir)"; f="$d/coolify.json"; mkdir -p "$d"
  [ -s "$f" ] || echo '{}' > "$f"
  tmp="$(mktemp)"; jq --arg u "$u" '.url = $u' "$f" > "$tmp" && mv "$tmp" "$f"
  echo "Coolify instance set to $u"
}

# The token on stdin. Tried against the instance first, saved only when Coolify takes it.
coolify_set_key() {
  local key=""
  IFS= read -r key || true
  # A key copied with a CR (Windows) or spaces around it: trimmed; spaces, quotes or a backslash inside are refused.
  key="$(printf "%s" "$key" | tr -d "\r" | sed "s/^[[:space:]]*//; s/[[:space:]]*\$//")"
  [ -n "$key" ] || coolify_die "Pipe the token in: pbpaste | deploys coolify set-key"
  case "$key" in *\'*|*\"*|*\\*|*[[:space:]]*|*[[:cntrl:]]*) coolify_die "That does not look like a Coolify token";; esac
  coolify_base >/dev/null || coolify_die "Set the instance first: deploys coolify set-url https://coolify.example.com"
  ( COOLIFY_TOKEN="$key"; key_of() { printf '%s' "$COOLIFY_TOKEN"; }; coolify_call GET /applications >/dev/null ) \
    || coolify_die "Coolify did not accept that token; nothing was saved"
  # On stdin to `security -i`, so the token is never an argument anyone can see.
  printf 'add-generic-password -U -a %s -s %s -w %s\n' "${USER:-$(id -un)}" "$COOLIFY_KEYCHAIN" "$key" | security -i >/dev/null \
    || coolify_die "The token works, but could not be saved in the keychain"
  echo "Coolify token saved and working."
}

coolify_doctor() {
  local src="missing" ok=false err="" n=null base="" usrc="missing" ver="" e
  if [ -n "${COOLIFY_URL:-}" ]; then usrc="env"
  elif [ -f "$(coolify_config_dir)/coolify.json" ] && jq -e '.url' "$(coolify_config_dir)/coolify.json" >/dev/null 2>&1; then usrc="file"; fi
  base="$(coolify_base 2>/dev/null)" || base=""
  if [ -n "${COOLIFY_TOKEN:-}" ]; then src="env"
  elif security find-generic-password -a "${USER:-$(id -un)}" -s "$COOLIFY_KEYCHAIN" >/dev/null 2>&1; then src="keychain"; fi
  if [ -n "$base" ] && [ "$src" != missing ]; then
    e="$(mktemp)"
    if n="$(coolify_apps 2>"$e" | jq 'length' 2>/dev/null)" && [ -n "$n" ]; then ok=true
      ver="$(coolify_call GET /version 2>/dev/null | tr -d '"' | head -c 40)" || ver=""
    else n=null; err="$(tail -n 1 "$e")"; fi
    rm -f "$e"
  fi
  jq -n --arg src "$src" --argjson ok "$ok" --arg err "$err" --argjson n "${n:-null}" \
    --arg base "$base" --arg usrc "$usrc" --arg ver "$ver" \
    '{provider:"coolify", url:(if $base == "" then null else $base end), urlSource:$usrc,
      https:($base | startswith("https://")), key:$src, tokenOk:$ok,
      error:(if $err == "" then null else $err end), version:(if $ver == "" then null else $ver end), apps:$n}'
}
