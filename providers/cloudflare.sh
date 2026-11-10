#!/bin/bash
# providers/cloudflare.sh: Cloudflare Pages for `deploys`. Opt-in, not a default provider.
#
# Contract (see the A1 change, "deploys: providers as files"): cloudflare_meta, _ready, _json,
# _has, _off, _deploy_json, _status, _latest, _cancel, _rollback, _logs, _url, _set_key, _doctor.
# Extra commands that are Cloudflare's own (on, selftest, account) go through cloudflare_cmd.
#
# Sourced by `deploys`, or run on its own while the dispatcher does not route here yet:
#   bash providers/cloudflare.sh <command> [args]     (see cloudflare_cmd for the list)
#
# Access: an API token with "Cloudflare Pages: Edit", from CLOUDFLARE_API_TOKEN or the keychain
# item deploy-center-cloudflare (`deploys cloudflare set-key`, reads stdin). Never printed.
# Account: CLOUDFLARE_ACCOUNT_ID, then accountId in $CONFIG_DIR/cloudflare.json, then the one
# account the token sees (remembered once found).
#
# The open question: does POST /deployments build while production_deployments_enabled=false?
# Cloudflare does not document it. Until `deploys cloudflare selftest <project> --yes` has shown
# a build start, production projects with push-deploys off are not "deployable", doctor says
# "unverified", and deploy refuses. --toggle (or DEPLOYS_CLOUDFLARE_TOGGLE=1) is the opt-in
# fallback: turn push-deploys on for a moment, start the build, turn them off again. A push that
# lands in those seconds is built too: that is the race window (docs/providers/cloudflare.md).
#
# shellcheck disable=SC2155  # `local x="$(...)"` is only used where the status does not matter.

CLOUDFLARE_API="${CLOUDFLARE_API_BASE:-https://api.cloudflare.com/client/v4}"
CLOUDFLARE_KEYCHAIN="deploy-center-cloudflare"
CONFIG_DIR="${CONFIG_DIR:-${DEPLOYS_CONFIG:-$HOME/.config/deploys}}"
CLOUDFLARE_STATE="$CONFIG_DIR/cloudflare.json"
USER="${USER:-$(id -un)}"

# What `deploys` itself defines, for when this file runs on its own.
declare -F die >/dev/null || die() { echo "Error: $*" >&2; exit 1; }
# GNU first: on Linux `stat -f` means the file system and "succeeds" with the wrong answer.
cf_mtime() { stat -c %Y "$1" 2>/dev/null || stat -f %m "$1"; }

# ---------- state: account id, remembered settings, the self-test ----------

cf_state() { [ -s "$CLOUDFLARE_STATE" ] && cat "$CLOUDFLARE_STATE" || echo '{}'; }
# cf_state_set <jq filter> [jq args...]: change the state file in one step.
cf_state_set() {
  local f="$1" tmp lock i=0; shift
  mkdir -p "$CONFIG_DIR"; tmp="$(umask 077; mktemp)"; lock="$CLOUDFLARE_STATE.lock"
  # A mkdir lock: two runs at once must not lose each other's change. A lock older than a
  # minute is a crashed run's.
  while ! mkdir "$lock" 2>/dev/null; do
    [ $(( $(date +%s) - $(mtime "$lock" 2>/dev/null || date +%s) )) -lt 60 ] || { rmdir "$lock" 2>/dev/null; continue; }
    i=$((i + 1)); [ "$i" -lt 50 ] || { rm -f "$tmp"; die "$CLOUDFLARE_STATE is locked by another run"; }
    sleep 0.1
  done
  cf_state | jq "$@" "$f" > "$tmp" && mv "$tmp" "$CLOUDFLARE_STATE" || { rm -f "$tmp"; rmdir "$lock" 2>/dev/null; die "Could not write $CLOUDFLARE_STATE"; }
  rmdir "$lock" 2>/dev/null || true
}

# "verified", "failed" (a self-test saw the build skipped) or "unverified" (none ran).
cf_verified() { cf_state | jq -r '.selftest.result // "unverified"'; }
cf_toggle_on() { [ "${DEPLOYS_CLOUDFLARE_TOGGLE:-}" = 1 ]; }

# ---------- access ----------

# The token: the environment first, then the keychain. key_of from `deploys` when it has one.
cloudflare_key() {
  if [ -n "${CLOUDFLARE_API_TOKEN:-}" ]; then printf '%s' "$CLOUDFLARE_API_TOKEN"; return; fi
  if declare -F key_of >/dev/null; then key_of cloudflare && return; fi
  security find-generic-password -a "$USER" -s "$CLOUDFLARE_KEYCHAIN" -w 2>/dev/null \
    || die "No Cloudflare API token. Create one (template \"Edit Cloudflare Pages\" or permission Pages: Edit) at dash.cloudflare.com > My Profile > API Tokens, then: deploys cloudflare set-key"
}
cf_key_source() {
  if [ -n "${CLOUDFLARE_API_TOKEN:-}" ]; then echo environment
  elif security find-generic-password -a "$USER" -s "$CLOUDFLARE_KEYCHAIN" -w >/dev/null 2>&1; then echo keychain
  else echo none; fi
}

# cf_call METHOD PATH [json body | -F|--form-string field=value ...]: the API, `result` on success.
# The token goes to curl on stdin, never into the process list. Reads are retried on 429/5xx.
cf_call() {
  local method="$1" path="$2" key out code try err; shift 2
  key="$(cloudflare_key)" || exit 1
  local args=(-sS --connect-timeout 10 --max-time 60 -X "$method" -H "Accept: application/json" -K -)
  if [ "${1:-}" = -F ] || [ "${1:-}" = --form-string ]; then args+=("$@")
  elif [ -n "${1:-}" ]; then args+=(-H "Content-Type: application/json" --data "$1"); fi
  err="$(mktemp)"
  for try in 1 2 3; do
    out="$(printf 'header = "Authorization: Bearer %s"\n' "$key" | curl "${args[@]}" -w '\n%{http_code}' "$CLOUDFLARE_API$path" 2>"$err")" || out=$'\n000'
    code="${out##*$'\n'}"; out="${out%$'\n'*}"
    case "$code" in
      429) [ "$try" -lt 3 ] && { sleep $((try * 3)); continue; } ;;
      5*|000) [ "$method" = GET ] && [ "$try" -lt 3 ] && { sleep $((try * 2)); continue; } ;;
    esac
    break
  done
  [ "$code" != 000 ] || out="$(tail -n 1 "$err")"
  rm -f "$err"
  # `|| ok=""`: an answer that is not JSON (an HTML 502, a curl error) must reach the message
  # below, not end the script without a word under set -e.
  local ok; ok="$(printf '%s' "$out" | jq -r '.success // false' 2>/dev/null)" || ok=""
  if [[ "$code" != 2* ]] || [ "$ok" != true ]; then
    local hint="" fix="deploys cloudflare set-key" msg
    [ -n "${CLOUDFLARE_API_TOKEN:-}" ] && fix="check CLOUDFLARE_API_TOKEN in the environment"
    msg="$(printf '%s' "$out" | jq -r '[.errors[]? | "\(.code): \(.message)"] | join("; ") | select(. != "")' 2>/dev/null)"
    case "$code" in
      000) hint=" (no answer: network or timeout)";;
      401|403) hint=" (the Cloudflare token is wrong, expired or lacks Pages: Edit: $fix)";;
      404) hint=" (not found: renamed or deleted?)";;
      429) hint=" (rate limit: try again in a minute)";;
      5*) hint=" (Cloudflare had a problem: try again later)";;
    esac
    die "Cloudflare $method $path -> HTTP $code$hint: ${msg:-$(printf '%s' "$out" | head -c 300)}"
  fi
  printf '%s' "$out" | jq '.result'
}

# The account: environment, remembered, or the only one the token can see.
cloudflare_account() {
  if [ -n "${CLOUDFLARE_ACCOUNT_ID:-}" ]; then echo "$CLOUDFLARE_ACCOUNT_ID"; return; fi
  local id; id="$(cf_state | jq -r '.accountId // empty')"
  if [ -n "$id" ]; then echo "$id"; return; fi
  local accts n; accts="$(cf_call GET "/accounts?per_page=50")" || exit 1
  n="$(echo "$accts" | jq 'length')"
  case "$n" in
    0) die "The Cloudflare token sees no account. Give it access to one, or set CLOUDFLARE_ACCOUNT_ID" ;;
    1) id="$(echo "$accts" | jq -r '.[0].id')"
       cf_state_set '.accountId = $a' --arg a "$id"; echo "$id" ;;
    *) echo "$accts" | jq -r '.[] | "  \(.id)  \(.name)"' >&2
       die "Several Cloudflare accounts. Choose one: deploys cloudflare account <id> (or set CLOUDFLARE_ACCOUNT_ID)" ;;
  esac
}
cf_proj() { local a; a="$(cloudflare_account)" || exit 1; printf '/accounts/%s/pages/projects%s' "$a" "${1:+/$1}"; }

# ---------- mapping ----------

# A deployment to one phase: queued|building|ready|failed|canceled. Skipped counts as canceled.
CF_PHASE='def cf_skipped: (.is_skipped == true) or (.skip_reason != null) or (.latest_stage.status == "skipped");
  def cf_phase: (.latest_stage // {}) as $s
  | if cf_skipped then "canceled"
    elif $s.status == "failure" then "failed"
    elif $s.status == "canceled" then "canceled"
    elif ($s.name == "deploy") and ($s.status == "success") then "ready"
    elif ($s.name // "queued") == "queued" then "queued"
    else "building" end;
  def cf_t: (. // null) | if . then (sub("\\.[0-9]+Z$";"Z") | fromdateiso8601) else null end;
  def cf_dep: {id, phase:cf_phase, stage:(.latest_stage.name // null), status:(.latest_stage.status // null),
    environment, branch:(.deployment_trigger.metadata.branch // null),
    sha:(.deployment_trigger.metadata.commit_hash // null),
    msg:(.deployment_trigger.metadata.commit_message // null | if . then split("\n")[0] else null end),
    url, skipped:cf_skipped, skipReason:(.skip_reason // null),
    createdAt:(.created_on | cf_t)};'

# Whether a push still builds: production deploys on, or previews on for some branches.
CF_AUTO='def cf_auto: (.source.config // null) as $c
  | if $c == null then false
    else (($c.production_deployments_enabled != false) or (($c.preview_deployment_setting // "all") != "none")) end;'

# ---------- the contract ----------

# Compact (jq -c): deploys greps it (meta_flag, meta_str, key_of). Contract fields: id, label,
# noun, defaultOn, keyEnv (an array), keychain, caps (docs/PROVIDERS.md). Off by default.
cloudflare_meta() {
  jq -nc '{id:"cloudflare", name:"cloudflare", label:"Cloudflare Pages", noun:"project", defaultOn:false, default:false,
    caps:{off:true, sha:false, cancel:false, rollback:true, logs:true, preview:true},
    keyEnv:["CLOUDFLARE_API_TOKEN"], keychain:"deploy-center-cloudflare",
    billing:"build count (Free: 500 per month), not price per build"}'
}

# Ready when there is a token. Says nothing, decides by its exit status.
cloudflare_ready() { [ -n "${CLOUDFLARE_API_TOKEN:-}" ] || ( cloudflare_key ) >/dev/null 2>&1; }

# The project's name is what every call here takes, so that is the id given back.
cloudflare_has() { ( cf_call GET "$(cf_proj "$1")" ) >/dev/null 2>&1 && echo "$1"; }

cf_projects() {
  local page=1 all="[]" out pages
  while :; do
    out="$(cf_call GET "$(cf_proj)?page=$page&per_page=10")" || return 1
    all="$(jq -s '.[0] + .[1]' <(echo "$all") <(echo "$out"))"
    # The list endpoint pages by 10; a short page is the last.
    pages="$(echo "$out" | jq 'length')"
    [ "$pages" -lt 10 ] && break
    page=$((page + 1)); [ "$page" -le 100 ] || break
  done
  echo "$all"
}

cloudflare_json() {
  local acct list
  acct="$(cloudflare_account)" || exit 1
  list="$(cf_projects)" || exit 1
  echo "$list" | jq --arg a "$acct" --arg v "$(cf_verified)" --arg tg "${DEPLOYS_CLOUDFLARE_TOGGLE:-}" "$CF_PHASE $CF_AUTO"'
    [.[] | (.source.config // null) as $c | (.canonical_deployment // {}) as $live | (.latest_deployment // null) as $new
      | ((.domains // []) | map(select(endswith(".pages.dev") | not)) | .[0]) as $custom
      | ($custom // .subdomain // null) as $dom
      # id is the name: every call here puts it in the URL path (projects/<name>), where the
      # project UUID would 404. The UUID stays as projectId.
      | {name, id:.name, projectId:.id, auto:cf_auto,
         # Git-connected, and a POST is known to build: push-deploys still on, the self-test
         # passed, or the opt-in toggle fallback is allowed.
         deployable:($c != null and (($c.production_deployments_enabled != false) or $v == "verified" or $tg == "1")),
         paused:false,
         # GitHub: owner/name; GitLab with its host (source.type), so heads are asked there.
         repo:(if $c then (if .source.type == "gitlab" then "gitlab.com/" else "" end) + "\($c.owner)/\($c.repo_name)" else null end),
         ref:($c.production_branch // .production_branch // null),
         domain:$dom, url:(if $dom then "https://\($dom)" else null end),
         dashboardUrl:"https://dash.cloudflare.com/\($a)/pages/view/\(.name)",
         lastAt:(($new // {}).created_on | cf_t), lastState:(($new // {}).latest_stage | if . and .name then "\(.name):\(.status // "")" else null end),
         lastSha:($live.deployment_trigger.metadata.commit_hash // null),
         lastMsg:($live.deployment_trigger.metadata.commit_message // null | if . then split("\n")[0] else null end),
         fetchError:null,
         phase:(if $new then ($new | cf_phase) else null end)}]
    | sort_by(.name | ascii_downcase)'
}

# PATCH the whole source.config (partial PATCH is not documented as safe): GET, merge, PATCH.
# cf_patch_config <project> <jq object to merge into source.config>
cf_patch_config() {
  local p="$1" change="$2" info body
  info="$(cf_call GET "$(cf_proj "$p")")" || exit 1
  [ "$(echo "$info" | jq '.source.config != null')" = true ] || die "Cloudflare: $p is not connected to Git (direct upload): pushes do not build it"
  body="$(echo "$info" | jq -c --argjson ch "$change" '{source:{type:.source.type, config:(.source.config + $ch)}}')"
  cf_call PATCH "$(cf_proj "$p")" "$body" >/dev/null || exit 1
}
cf_config() { cf_call GET "$(cf_proj "$1")" | jq -c '.source.config // null'; }

# Both push switches off. What they were is kept (only the first time), so `on` can restore it.
cloudflare_off() {
  # --all (docs/PROVIDERS.md): every project, one by one. One that fails does not stop the rest;
  # they are counted and the exit code says so. The list first, on its own: a failed read stops here.
  if [ "${1:-}" = --all ]; then
    local _names _n _bad=0
    _names="$(cf_projects | jq -r '.[] | .name // empty')" || die "Cloudflare: could not list the projects"
    while IFS= read -r _n; do
      [ -n "$_n" ] || continue
      ( cloudflare_off_one "$_n" ) || _bad=$((_bad + 1))
    done <<< "$_names"
    [ "$_bad" = 0 ] || die "$_bad Cloudflare projects could not be switched off (see above); the others are done"
    echo "Done. No Cloudflare project deploys on push any more."
    return 0
  fi
  cloudflare_off_one "$@"
}

cloudflare_off_one() {
  local p="$1" cfg
  cfg="$(cf_config "$p")" || exit 1
  [ "$cfg" != null ] || die "Cloudflare: $p is not connected to Git (direct upload): pushes do not build it"
  if [ "$(echo "$cfg" | jq '(.production_deployments_enabled == false) and (.preview_deployment_setting == "none")')" = true ]; then
    echo "Cloudflare: $p was already manual"; return
  fi
  cf_state_set '.off[$p] = (.off[$p] // ($c | {production_deployments_enabled:(.production_deployments_enabled != false),
      preview_deployment_setting:(.preview_deployment_setting // "all"), offAt:(now|floor)}))' --arg p "$p" --argjson c "$cfg"
  cf_patch_config "$p" '{"production_deployments_enabled":false,"preview_deployment_setting":"none"}'
  cfg="$(cf_config "$p")" || exit 1
  [ "$(echo "$cfg" | jq '(.production_deployments_enabled == false) and (.preview_deployment_setting == "none")')" = true ] \
    || die "Cloudflare: asked to turn off push-deploys for $p, but it still shows them on"
  echo "Cloudflare: $p no longer deploys on push"
}

# The settings from before `off`, or both on when none were kept.
cloudflare_on() {
  local p="$1" prev
  prev="$(cf_state | jq -c --arg p "$p" '.off[$p] // {production_deployments_enabled:true, preview_deployment_setting:"all"}
    | {production_deployments_enabled, preview_deployment_setting}')"
  cf_patch_config "$p" "$prev"
  cf_state_set 'del(.off[$p])' --arg p "$p"
  echo "Cloudflare: $p deploys on push again ($(echo "$prev" | jq -r '"production \(if .production_deployments_enabled then "on" else "off" end), previews \(.preview_deployment_setting)"'))"
}

cf_lock() {
  if declare -F start_lock >/dev/null; then start_lock "$1"; return; fi
  local d="$CONFIG_DIR/locks" f; mkdir -p "$d"; f="$d/$(echo "$1" | tr '/ ' '__')"
  if [ -f "$f" ] && [ $(( $(date +%s) - $(cf_mtime "$f") )) -ge 60 ]; then rm -f "$f"; fi
  ( set -C; : > "$f" ) 2>/dev/null || die "$1 is being started already (wait a minute)"
  echo "$f"
}

# --form-string, not -F: a branch named "@file" or "<file" must not upload that file.
cf_post_deploy() { cf_call POST "$(cf_proj "$1")/deployments" --form-string "branch=$2"; }

# Push builds back to what they were; the note in the state goes only when that worked.
cf_toggle_back() {  # <project> <before json> <setting>
  if ( cf_patch_config "$1" "$2" ); then cf_state_set 'del(.toggling[$p])' --arg p "$1"
  else echo "Cloudflare: could not turn $3 back off for $1. Run: deploys cloudflare off $1" >&2; fi
}

# cloudflare_deploy_json <project> [--preview] [--branch <b>] [--toggle]
# Prints {id, url, state, phase, branch, toggled}. --preview needs a branch other than production.
cloudflare_deploy_json() {
  local p="$1" preview=0 branch="" toggle=0 info cfg prod lock out
  shift
  while [ $# -gt 0 ]; do
    case "$1" in
      --preview|preview) preview=1 ;;
      --branch) branch="${2:-}"; shift ;;
      --toggle) toggle=1 ;;
      --sha) die "Cloudflare Pages cannot deploy a given commit, only the newest one of a branch (--branch)" ;;
      "") ;;
      *) die "Unknown option $1. Usage: deploy-json <project> [--preview] [--branch <b>] [--toggle]" ;;
    esac; shift
  done
  cf_toggle_on && toggle=1
  info="$(cf_call GET "$(cf_proj "$p")")" || exit 1
  cfg="$(echo "$info" | jq -c '.source.config // null')"
  [ "$cfg" != null ] || die "Cloudflare: $p is not connected to Git; deploy it with wrangler instead"
  prod="$(echo "$cfg" | jq -r '.production_branch // empty')"; prod="${prod:-$(echo "$info" | jq -r '.production_branch // "main"')}"
  [ -n "$branch" ] || { [ "$preview" = 1 ] && die "A preview needs a branch other than $prod: --branch <b>"; branch="$prod"; }
  [ "$preview" = 1 ] && [ "$branch" = "$prod" ] && die "$prod is the production branch; a preview needs another branch"
  # Which switch would keep this build from starting, and whether it is off now.
  local sw="production_deployments_enabled" onval=true blocked
  if [ "$branch" != "$prod" ]; then sw="preview_deployment_setting"; onval='"all"'; fi
  blocked="$(echo "$cfg" | jq --arg s "$sw" 'if $s == "preview_deployment_setting" then (.[$s] // "all") == "none" else .[$s] == false end')"
  if [ "$blocked" = true ] && [ "$sw" = production_deployments_enabled ] && [ "$toggle" = 0 ] && [ "$(cf_verified)" != verified ]; then
    die "Unverified: Cloudflare may skip a build while push-deploys are off. Run once: deploys cloudflare selftest $p --yes (or pass --toggle, see docs/providers/cloudflare.md)"
  fi
  lock="$(cf_lock "cloudflare-$p")" || exit 1
  out="$(cf_post_deploy "$p" "$branch")" || { rm -f "$lock"; exit 1; }
  local toggled=false
  if [ "$(echo "$out" | jq "$CF_PHASE"' cf_dep | .skipped')" = true ]; then
    if [ "$toggle" = 0 ]; then
      rm -f "$lock"
      die "Cloudflare skipped the build ($(echo "$out" | jq -r '.skip_reason // "push-deploys are off"')). Nothing was built. To turn push-deploys on for a moment and start it: add --toggle (see docs/providers/cloudflare.md for the race window)"
    fi
    # The fallback: switch on, start, switch back to exactly what it was. Switched back even when
    # the start fails. A push in between is built too.
    local before; before="$(echo "$cfg" | jq -c --arg s "$sw" '{($s): .[$s]}')"
    echo "Cloudflare: turning $sw on for $p for a moment (race window: a push now would build too)" >&2
    # Written down first, and switched back on Ctrl-C too: push builds left on cost builds.
    # `doctor` names any that stayed open (togglesOpen).
    cf_state_set '.toggling[$p] = {before:$b, at:(now|floor)}' --arg p "$p" --argjson b "$before"
    trap 'cf_toggle_back "$p" "$before" "$sw"; rm -f "$lock"; exit 130' INT TERM
    cf_patch_config "$p" "{\"$sw\":$onval}" || { trap - INT TERM; cf_state_set 'del(.toggling[$p])' --arg p "$p"; rm -f "$lock"; exit 1; }
    local rc=0; out="$(cf_post_deploy "$p" "$branch")" || rc=$?
    cf_toggle_back "$p" "$before" "$sw"
    trap - INT TERM
    [ "$rc" = 0 ] || { rm -f "$lock"; exit 1; }
    toggled=true
    [ "$(echo "$out" | jq "$CF_PHASE"' cf_dep | .skipped')" = true ] && { rm -f "$lock"; die "Cloudflare skipped the build even with $sw on"; }
  fi
  echo "$out" | jq --argjson tg "$toggled" --arg b "$branch" "$CF_PHASE"' cf_dep | {id, url, state:.phase, phase, branch:$b, toggled:$tg}'
}

cloudflare_latest_json() {
  # A failed call is that failure (cf_call says why); no deployment is null, not an error.
  local out; out="$(cf_call GET "$(cf_proj "$1")/deployments?per_page=1")" || exit 1
  printf '%s' "$out" | jq "$CF_PHASE"' .[0] // null | if . then cf_dep else null end'
}
# cloudflare_status_json <project> [<id>]: one deployment (the newest without an id).
cloudflare_status_json() {
  [ -n "${2:-}" ] || { cloudflare_latest_json "$1"; return; }
  cf_call GET "$(cf_proj "$1")/deployments/$2" | jq "$CF_PHASE"' cf_dep'
}

cloudflare_cancel() { die "Cloudflare Pages has no documented way to cancel a deployment. Stop it in the dashboard: $(cloudflare_url "$1" --dashboard)"; }

# cloudflare_rollback <project> [<id>]: production back to <id>, or to the newest good one before live.
cloudflare_rollback() {
  local p="$1" id="${2:-}" live
  if [ -z "$id" ]; then
    live="$(cf_call GET "$(cf_proj "$p")" | jq -r '.canonical_deployment.id // empty')" || exit 1
    id="$(cf_call GET "$(cf_proj "$p")/deployments?env=production&per_page=25" | jq -r --arg live "$live" "$CF_PHASE"'
      [.[] | select(.id != $live and cf_phase == "ready")] | .[0].id // empty')" || exit 1
    [ -n "$id" ] || die "Cloudflare: no earlier good production deployment of $p to go back to"
  fi
  cf_call POST "$(cf_proj "$p")/deployments/$id/rollback" | jq "$CF_PHASE"' cf_dep | {id, url, state:.phase, phase}'
}

# cloudflare_logs <project> [lines] [<id>]
cloudflare_logs() {
  local p="$1" n="${2:-60}" id="${3:-}"
  [ -n "$id" ] || id="$(cloudflare_latest_json "$p" | jq -r '.id // empty')" || exit 1
  [ -n "$id" ] || die "Cloudflare: $p has no deployments"
  cf_call GET "$(cf_proj "$p")/deployments/$id/history/logs" | jq -r '.data[]? | "\(.ts // "")  \(.line // "")"' | tail -n "$n"
}

# cloudflare_url <project> [--dashboard]
cloudflare_url() {
  local p="$1" info acct
  acct="$(cloudflare_account)" || exit 1
  if [ "${2:-}" = --dashboard ]; then echo "https://dash.cloudflare.com/$acct/pages/view/$p"; return; fi
  info="$(cf_call GET "$(cf_proj "$p")")" || exit 1
  echo "$info" | jq -r '((.domains // []) | map(select(endswith(".pages.dev") | not)) | .[0]) // .subdomain // empty | "https://\(.)"'
}

# Read from stdin, tried first, saved only when Cloudflare says it is active.
cloudflare_set_key() {
  local key st
  IFS= read -r key || true
  key="$(printf '%s' "$key" | tr -d '[:space:]')"
  [ -n "$key" ] || die "Pipe the token in: pbpaste | deploys cloudflare set-key"
  case "$key" in *\'*|*\"*|*\\*) die "That does not look like a Cloudflare API token";; esac
  st="$(CLOUDFLARE_API_TOKEN="$key" cf_call GET /user/tokens/verify 2>/dev/null | jq -r '.status // empty')" || st=""
  [ "$st" = active ] || die "Cloudflare did not accept that token${st:+ (status: $st)}; nothing was saved"
  # On stdin to `security -i`: never an argument anyone can see.
  printf 'add-generic-password -U -a %s -s %s -w %s\n' "$USER" "$CLOUDFLARE_KEYCHAIN" "$key" | security -i >/dev/null \
    || die "The token works, but could not be saved in the keychain"
  echo "Cloudflare token saved and working."
}

cloudflare_doctor() {
  local src valid=false acct="" asrc=none
  src="$(cf_key_source)"
  if [ "$src" != none ]; then
    [ "$(cf_call GET /user/tokens/verify 2>/dev/null | jq -r '.status // empty')" = active ] && valid=true
    if [ -n "${CLOUDFLARE_ACCOUNT_ID:-}" ]; then asrc=environment
    elif [ -n "$(cf_state | jq -r '.accountId // empty')" ]; then asrc=config
    else asrc=detected; fi
    acct="$( (cloudflare_account) 2>/dev/null)" || asrc=none
  fi
  cf_state | jq -c --arg src "$src" --argjson valid "$valid" --arg acct "$acct" --arg asrc "$asrc" --arg tg "${DEPLOYS_CLOUDFLARE_TOGGLE:-}" '
    {provider:"cloudflare", tokenSource:$src, tokenValid:$valid,
     account:(if $acct == "" then null else $acct end), accountSource:$asrc,
     deployWhileOff:(.selftest.result // "unverified"), selftest:(.selftest // null),
     toggleFallback:($tg == "1"), togglesOpen:((.toggling // {}) | keys),
     note:(if (.selftest.result // "unverified") == "verified" then "a deploy builds while push-deploys are off (self-test passed)"
           elif .selftest.result == "failed" then "Cloudflare skipped the self-test build: deploy needs --toggle"
           else "unverified: run deploys cloudflare selftest <project> --yes" end)}'
}

# ---------- the self-test ----------

# cloudflare_selftest <project> --yes: with push-deploys off, start one real build and watch it
# reach the build stage with a commit hash. Uses one build of the quota.
cloudflare_selftest() {
  local p="$1" yes="${2:-}" cfg prod out id st tries="${DEPLOYS_CLOUDFLARE_SELFTEST_TRIES:-36}" i
  cfg="$(cf_config "$p")" || exit 1
  [ "$cfg" != null ] || die "Cloudflare: $p is not connected to Git"
  [ "$(echo "$cfg" | jq '.production_deployments_enabled == false')" = true ] \
    || die "Push-deploys of $p are on, so the test would prove nothing. First: deploys cloudflare off $p"
  prod="$(echo "$cfg" | jq -r '.production_branch // "main"')"
  if [ "$yes" != --yes ]; then
    echo "This starts one real production build of $p (branch $prod) while push-deploys are off,"
    echo "and counts against the build quota. Run again with --yes to do it."
    return 0
  fi
  out="$(cf_post_deploy "$p" "$prod")" || exit 1
  st="$(echo "$out" | jq -c "$CF_PHASE"' cf_dep')"
  if [ "$(echo "$st" | jq '.skipped')" = true ]; then
    cf_state_set '.selftest = {result:"failed", at:(now|floor), project:$p, reason:($s.skipReason // "skipped")}' --arg p "$p" --argjson s "$st"
    echo "Self-test: Cloudflare skipped the build ($(echo "$st" | jq -r '.skipReason // "skipped"')). Deploys need --toggle; see docs/providers/cloudflare.md."
    return 1
  fi
  id="$(echo "$st" | jq -r '.id')"
  for ((i = 0; i < tries; i++)); do
    if [ "$(echo "$st" | jq '(.stage == "build" or .stage == "deploy" or .phase == "ready") and ((.sha // "") != "")')" = true ]; then
      cf_state_set '.selftest = {result:"verified", at:(now|floor), project:$p, deploymentId:$s.id, sha:$s.sha}' --arg p "$p" --argjson s "$st"
      echo "Self-test passed: deployment $id reached the $(echo "$st" | jq -r '.stage') stage at $(echo "$st" | jq -r '.sha[0:7]'). Deploys now work while push-deploys are off."
      return 0
    fi
    case "$(echo "$st" | jq -r '.phase')" in
      failed|canceled)
        echo "Self-test inconclusive: deployment $id ended $(echo "$st" | jq -r '.phase') at stage $(echo "$st" | jq -r '.stage') before building. Fix the project and run it again."
        return 1 ;;
    esac
    printf '.' >&2
    sleep 5
    st="$(cloudflare_status_json "$p" "$id" | jq -c .)" || exit 1
  done
  echo >&2
  echo "Self-test inconclusive: deployment $id did not reach the build stage in time (stage $(echo "$st" | jq -r '.stage')). Run it again later."
  return 1
}

# ---------- commands ----------

cloudflare_cmd() {
  local c="${1:-}"; shift || true
  case "$c" in
    meta) cloudflare_meta ;;
    json|list) cloudflare_json ;;
    has) cloudflare_has "${1:?project}" ;;
    off|autodeploy-off) cloudflare_off "${1:?project}" ;;
    on|autodeploy-on) cloudflare_on "${1:?project}" ;;
    deploy-json|deploy) cloudflare_deploy_json "${1:?project}" "${@:2}" ;;
    status) cloudflare_status_json "${1:?project}" "${2:-}" ;;
    latest) cloudflare_latest_json "${1:?project}" ;;
    cancel) cloudflare_cancel "${1:?project}" ;;
    rollback) cloudflare_rollback "${1:?project}" "${2:-}" ;;
    logs) cloudflare_logs "${1:?project}" "${2:-60}" "${3:-}" ;;
    url|open) cloudflare_url "${1:?project}" "${2:-}" ;;
    set-key) cloudflare_set_key ;;
    doctor) cloudflare_doctor ;;
    selftest) cloudflare_selftest "${1:?project}" "${2:-}" ;;
    account)
      if [ -n "${1:-}" ]; then cf_state_set '.accountId = $a' --arg a "$1"; echo "Cloudflare account set."
      else cloudflare_account; fi ;;
    *) die "Usage: deploys cloudflare meta|list|has|off|on|deploy|deploy-json|status|latest|rollback|logs|url|set-key|doctor|selftest|account" ;;
  esac
}

if [ "${BASH_SOURCE[0]}" = "$0" ]; then
  set -euo pipefail
  cloudflare_cmd "$@"
fi

# ---------- the contract's status lines (docs/PROVIDERS.md) ----------
# `deploys watch`, `deploy --wait` and group deploys read one line: deployId<TAB>phase<TAB>state,
# and "none" as the id when there is no deploy. The JSON above stays for people:
# `deploys cloudflare status|latest` prints it (cloudflare_cli_status, cloudflare_cli_latest).
CLOUDFLARE_TSV='if . == null then "none\t\tnone"
  else "\(.id // "none")\t\(.phase // "")\t\(.state // (if .stage then "\(.stage):\(.status // "")" else .status end) // "?")" end'
cloudflare_status() { local j; j="$(cloudflare_status_json "$@")" || return 1; printf '%s' "$j" | jq -r "$CLOUDFLARE_TSV"; }
cloudflare_latest() { local j; j="$(cloudflare_latest_json "$@")" || return 1; printf '%s' "$j" | jq -r "$CLOUDFLARE_TSV"; }
cloudflare_cli_status() { cloudflare_status_json "$@"; }
cloudflare_cli_latest() { cloudflare_latest_json "$@"; }
