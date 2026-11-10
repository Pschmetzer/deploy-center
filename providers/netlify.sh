#!/bin/bash
# providers/netlify.sh — the Netlify provider for `deploys` (opt-in: deploys providers enable netlify).
#
# Netlify cannot turn off "build on push" through its API in a way that still lets us deploy:
# build_settings.stop_builds also stops API and build-hook builds. So the switch lives in the
# repo instead: a netlify.toml `ignore` command that skips every build Netlify did not get from
# a build hook (INCOMING_HOOK_TITLE is only set for those). We create one build hook per site,
# named "deploy-center", remember its URL, and deploy by posting to it.
#
# Contract (see the A1 provider PR): netlify_meta, _ready, _json, _has, _off, _deploy_json,
# _status, _latest, _cancel, _rollback, _logs, _url, _set_key, _doctor.
# Phases: queued | building | ready | failed | canceled.
#
# Access: a personal access token (User settings > Applications > Personal access tokens),
# from NETLIFY_AUTH_TOKEN or the keychain service deploy-center-netlify. Never printed.
#
# Files (in the deploys config folder, mode 0600):
#   netlify-hooks.json  {siteId: {hookId, url, repo, ref, base, rule, ruleAt, offAt}}
#                       url is the build hook: anyone with it can start a build. Kept private.

NETLIFY_API="${NETLIFY_API:-https://api.netlify.com/api/v1}"
NETLIFY_KEYCHAIN="deploy-center-netlify"
NETLIFY_HOOK_TITLE="deploy-center"
# The line to add to netlify.toml. Exit 0 means "skip this build" to Netlify.
# shellcheck disable=SC2016  # the $ is for Netlify's shell, not this one
NETLIFY_IGNORE_LINE='ignore = "[ -z \"$INCOMING_HOOK_TITLE\" ]"'

# ---------- small helpers (the main script has its own; these stand in when sourced alone) ----------

netlify_die() {
  if declare -F die >/dev/null; then die "$@"; fi
  echo "Error: $*" >&2; exit 1
}
netlify_config_dir() { echo "${CONFIG_DIR:-${DEPLOYS_CONFIG:-$HOME/.config/deploys}}"; }
netlify_hooks_file() {
  local d f; d="$(netlify_config_dir)"; f="$d/netlify-hooks.json"
  mkdir -p "$d" && chmod 700 "$d" 2>/dev/null
  [ -s "$f" ] || (umask 077; echo '{}' > "$f")
  echo "$f"
}
# Change the hooks file with a jq filter; it stays 0600 because the hook URLs are secrets.
netlify_hooks_edit() {
  local f tmp; f="$(netlify_hooks_file)"; tmp="$(umask 077; mktemp)"
  jq "$@" "$f" > "$tmp" && mv "$tmp" "$f" && chmod 600 "$f"
}
netlify_b64d() { base64 -D 2>/dev/null || base64 -d; }

# The token: environment first, then the keychain. Uses the shared key_of when A1 provides it.
netlify_key() {
  local k=""
  if declare -F key_of >/dev/null; then k="$(key_of netlify 2>/dev/null)" || k=""
  elif [ -n "${NETLIFY_AUTH_TOKEN:-}" ]; then k="$NETLIFY_AUTH_TOKEN"
  else k="$(security find-generic-password -a "${USER:-$(id -un)}" -s "$NETLIFY_KEYCHAIN" -w 2>/dev/null)" || k=""
  fi
  [ -n "$k" ] || { echo "No Netlify token. Create one at app.netlify.com > User settings > Applications > Personal access tokens, then: pbpaste | deploys netlify set-key" >&2; return 1; }
  printf '%s' "$k"
}

# netlify_call METHOD PATH|URL [BODY] — the answer on stdout; on failure a reason on stderr, rc 1.
# The token goes to curl on stdin (-K -), so it never shows in the process list.
netlify_call() {
  local method="$1" path="$2" body="${3:-}" key url out code try err
  key="$(netlify_key)" || return 1
  local auth=1
  case "$path" in
    https://api.netlify.com/build_hooks/*) url="$path"; auth="" ;;
    http*) netlify_die "Netlify: not calling $path (only https://api.netlify.com/build_hooks/... is called by address)" ;;
    *) url="$NETLIFY_API$path" ;;
  esac
  local args=(-sS --connect-timeout 10 --max-time 60 -X "$method" -H "Accept: application/json" -K -)
  [ -n "$body" ] && args+=(-H "Content-Type: application/json" --data "$body")
  err="$(mktemp)"
  for try in 1 2 3; do
    out="$( { [ -z "$auth" ] || printf 'header = "Authorization: Bearer %s"\n' "$key"; } | curl "${args[@]}" -w '\n%{http_code}' "$url" 2>"$err")" || out=$'\n000'
    code="${out##*$'\n'}"; out="${out%$'\n'*}"
    # Only reads are repeated: a POST that timed out may have started a build already.
    case "$code" in
      429) [ "$try" -lt 3 ] && { sleep $((try * 3)); continue; } ;;
      5*|000) [ "$method" = GET ] && [ "$try" -lt 3 ] && { sleep $((try * 2)); continue; } ;;
    esac
    break
  done
  [ "$code" != 000 ] || out="$(tail -n 1 "$err")"
  rm -f "$err"
  if [[ "$code" != 2* ]]; then
    local hint="" fix="deploys netlify set-key" msg
    [ -n "${NETLIFY_AUTH_TOKEN:-}" ] && fix="check NETLIFY_AUTH_TOKEN in the environment"
    case "$code" in
      000) hint=" (no answer: network or timeout)";;
      401|403) hint=" (the Netlify token is wrong or expired: $fix)";;
      404) hint=" (not found: renamed or deleted?)";;
      422) hint=" (Netlify refused it)";;
      429) hint=" (rate limit: try again in a minute)";;
      5*) hint=" (Netlify had a problem: try again later)";;
    esac
    msg="$(printf '%s' "$out" | jq -r '.message // .error // empty' 2>/dev/null)" || msg=""
    echo "Netlify $method ${path%%\?*} -> HTTP $code$hint${msg:+: $msg}" >&2
    return 1
  fi
  printf '%s' "$out"
}

netlify_sites() {
  local page=1 all="[]" chunk
  while :; do
    chunk="$(netlify_call GET "/sites?filter=all&per_page=100&page=$page")" || return 1
    all="$(jq -s '.[0] + .[1]' <(echo "$all") <(echo "$chunk"))"
    [ "$(echo "$chunk" | jq 'length')" -lt 100 ] && break
    page=$((page + 1))
  done
  echo "$all"
}

# A site by name, custom domain or id. Two sites never share a name on Netlify.
netlify_id_of() {
  local n="$1" id
  id="$(netlify_sites | jq -r --arg n "$n" '.[] | select(.id==$n or .site_id==$n or .name==$n or .custom_domain==$n) | .id' | head -n 1)" || return 1
  [ -n "$id" ] || { echo "No Netlify site named \"$n\". See: deploys netlify list" >&2; return 1; }
  echo "$id"
}

# jq definitions shared by the readers below.
# shellcheck disable=SC2016
NETLIFY_JQ='
  def t: (. // null) | if . then (sub("\\.[0-9]+Z$";"Z") | fromdateiso8601) else null end;
  def phase: if . == null then null
    elif test("^(new|enqueued|accepted|pending_review)$") then "queued"
    elif . == "ready" then "ready"
    elif test("^(error|rejected|failed)$") then "failed"
    elif test("^(canceled|cancelled|skipped)$") then "canceled"
    elif test("^(building|uploading|uploaded|preparing|prepared|processing|processed|retrying)$") then "building"
    else null end;
  # A build our ignore rule (or "no content change") skipped: not a deploy anyone paid for.
  def skipped: (.skipped == true) or (.state == "skipped")
    or ((.error_message // "") | test("no content change|^skipped"; "i"));
  # GitHub: owner/name. GitLab, Bitbucket: host/path, so the git-host code asks the right host
  # (cutting the host made gitlab.com/g/n look like the GitHub repo g/n).
  def host_slug: (. // "") | sub("\\.git$";"") | sub("/$";"")
    | if test("^https?://(www\\.)?github\\.com/") then sub("^https?://(www\\.)?github\\.com/";"")
      elif test("^https?://[^/]*(gitlab|bitbucket)[^/]*/") then sub("^https?://";"")
      else null end | if . == "" then null else . end;
  def repo_of: (.build_settings.repo_url // null) | host_slug;
  def deploy_out: {id, state, phase:(.state | phase),
    url:(.deploy_ssl_url // .deploy_url // null),
    dashboardUrl:(if .admin_url and .id then "\(.admin_url)/deploys/\(.id)" else null end),
    sha:(.commit_ref // null), msg:((.title // null) | if . then split("\n")[0] else null end),
    createdAt:(.created_at | t), error:(.error_message // null)};
'

# Look for our ignore line in the repo's netlify.toml (base directory first). yes | no | unknown.
netlify_rule_in_repo() {
  local repo="$1" ref="$2" base="${3:-}" p raw got=0
  command -v gh >/dev/null 2>&1 || { echo unknown; return; }
  for p in ${base:+"${base%/}/netlify.toml"} netlify.toml; do
    raw="$(gh api "repos/$repo/contents/$p?ref=$(jq -rn --arg r "$ref" '$r|@uri')" 2>/dev/null)" || continue
    got=1
    if echo "$raw" | jq -r '.content // empty' | tr -d '\n' | netlify_b64d 2>/dev/null \
      | grep -Eq '^[[:space:]]*ignore[[:space:]]*=.*INCOMING_HOOK_TITLE'; then echo yes; return; fi
  done
  # Not found in a readable file is "no"; nothing readable at all may still be a gh problem.
  if [ "$got" = 1 ]; then echo no; else
    gh api "repos/$repo" >/dev/null 2>&1 && echo no || echo unknown
  fi
}

# ---------- the contract ----------

# Compact (jq -c): deploys greps it (meta_flag, meta_str, key_of). Contract fields: id, label,
# noun, defaultOn, keyEnv (an array), keychain, caps (docs/PROVIDERS.md). Off by default.
netlify_meta() {
  jq -nc --arg k "$NETLIFY_KEYCHAIN" '{id:"netlify", label:"Netlify", noun:"site", defaultOn:false, keyEnv:["NETLIFY_AUTH_TOKEN"], keychain:$k,
    caps:{off:true, sha:false, cancel:true, rollback:true, logs:false, preview:false}}'
}

# Usable without asking anyone: tools there and a token found (not checked against Netlify).
netlify_ready() {
  command -v curl >/dev/null 2>&1 && command -v jq >/dev/null 2>&1 && netlify_key >/dev/null 2>&1
}

netlify_has() { netlify_id_of "$1" 2>/dev/null; }

netlify_json() {
  local sites hooks out="[]" s id d repo ref base rule
  sites="$(netlify_sites)" || netlify_die "Could not list Netlify sites"
  hooks="$(cat "$(netlify_hooks_file)")"
  # A site turned off here whose rule is not confirmed yet: look again (the PR may be merged now).
  if [ -z "${DEPLOYS_NO_GITHUB:-}" ]; then
    while IFS=$'\t' read -r id repo ref base; do
      [ -n "$id" ] && [ "$repo" != null ] || continue
      rule="$(netlify_rule_in_repo "$repo" "$ref" "$base")"
      [ "$rule" = yes ] && netlify_hooks_edit --arg id "$id" '.[$id].rule = true | .[$id].ruleAt = (now|floor)'
    done < <(echo "$sites" | jq -r --argjson h "$hooks" "$NETLIFY_JQ"'
      .[] | select($h[.id] and ($h[.id].rule != true))
      | [.id, (repo_of // "null"), (.build_settings.repo_branch // "main"), (.build_settings.base // "")] | @tsv')
    hooks="$(cat "$(netlify_hooks_file)")"
  fi
  while IFS= read -r s; do
    id="$(echo "$s" | jq -r '.id')"
    if d="$(netlify_call GET "/sites/$id/deploys?production=true&per_page=10" 2>&1)"; then
      # A 200 that is not a deploy list (a proxy's login page) is this site's error, not an
      # empty --argjson that breaks the whole list.
      d="$(echo "$d" | jq -c 'if type == "array" then {deploys:.} else error("no list") end' 2>/dev/null)" \
        || d="$(jq -nc '{fetchError:"Netlify answered without a deploy list"}')"
    else
      d="$(jq -nc --arg e "$d" '{fetchError:$e}')"
    fi
    out="$(jq -c --argjson s "$s" --argjson d "$d" '. + [$s + {_d:$d}]' <<<"$out")"
  done < <(echo "$sites" | jq -c '.[]')
  echo "$out" | jq --argjson h "$hooks" "$NETLIFY_JQ"'
    [ .[] | ($h[.id] // {}) as $hk | (.build_settings // {}) as $b
      | ((._d.deploys // []) | map(select(skipped | not))) as $ds
      | ($ds[0] // {}) as $new | (.published_deploy // {}) as $live
      | {name, id,
         auto:((repo_of != null) and ($hk.rule != true)),
         paused:($b.stop_builds == true),
         deployable:((repo_of != null) and ($hk.url != null) and ($hk.rule == true) and ($b.stop_builds != true)),
         repo:repo_of, ref:($b.repo_branch // null),
         domain:(.custom_domain // ((.ssl_url // .url // "") | sub("^https?://";"") | if . == "" then null else . end)),
         url:(.ssl_url // .url // null), dashboardUrl:(.admin_url // null),
         lastAt:(($new.published_at // $new.created_at) | t), lastState:($new.state // null),
         lastSha:($live.commit_ref // null),
         lastMsg:(($live.title // null) | if . then split("\n")[0] else null end),
         fetchError:(._d.fetchError // null), phase:($new.state // null | phase)} ]
    | sort_by(.name | ascii_downcase)'
}

# netlify_off <site> [--rule-added]: build hook + the netlify.toml step. --rule-added records the
# rule by hand for repos gh cannot read (GitLab, Bitbucket, a private repo without access).
netlify_off() {
  # --all (docs/PROVIDERS.md): every site, one by one. One that fails does not stop the rest;
  # they are counted and the exit code says so. The list first, on its own: a failed read stops here.
  if [ "${1:-}" = --all ]; then
    local _names _n _bad=0
    _names="$(netlify_sites | jq -r '.[] | .id // empty')" || netlify_die "Netlify: could not list the sites"
    while IFS= read -r _n; do
      [ -n "$_n" ] || continue
      ( netlify_off_one "$_n" ) || _bad=$((_bad + 1))
    done <<< "$_names"
    [ "$_bad" = 0 ] || netlify_die "$_bad Netlify sites could not be switched off (see above); the others are done"
    echo "Done. No Netlify site deploys on push any more."
    return 0
  fi
  netlify_off_one "$@"
}

netlify_off_one() {
  local site="$1" by_hand="${2:-}" id info hooks hook url repo ref base rule
  id="$(netlify_id_of "$site")" || netlify_die "Netlify site $site not found"
  info="$(netlify_call GET "/sites/$id")" || netlify_die "Netlify: could not read $site"
  repo="$(echo "$info" | jq -r "$NETLIFY_JQ"'repo_of // empty')"
  ref="$(echo "$info" | jq -r '.build_settings.repo_branch // "main"')"
  base="$(echo "$info" | jq -r '.build_settings.base // empty')"
  [ -n "$repo" ] || { echo "Netlify: $site has no linked repo, so a push cannot deploy it (and a build hook cannot either)."; return 0; }
  [ "$(echo "$info" | jq '.build_settings.stop_builds == true')" = true ] \
    && echo "Netlify: builds are stopped for $site (Site configuration > Build & deploy). That also stops our build hook: turn \"Stop builds\" off again."

  hooks="$(netlify_call GET "/sites/$id/build_hooks")" || netlify_die "Netlify: could not read the build hooks of $site"
  hook="$(echo "$hooks" | jq -c --arg t "$NETLIFY_HOOK_TITLE" '[.[] | select(.title==$t)][0] // empty')"
  if [ -z "$hook" ]; then
    hook="$(netlify_call POST "/sites/$id/build_hooks" "$(jq -nc --arg t "$NETLIFY_HOOK_TITLE" --arg b "$ref" '{title:$t, branch:$b}')")" \
      || netlify_die "Netlify: could not create a build hook for $site"
    echo "Netlify: created the build hook \"$NETLIFY_HOOK_TITLE\" for $site"
  fi
  url="$(echo "$hook" | jq -r '.url // empty')"
  [ -n "$url" ] || netlify_die "Netlify: the build hook of $site has no URL"

  if [ "$by_hand" = --rule-added ]; then rule=yes; else rule="$(netlify_rule_in_repo "$repo" "$ref" "$base")"; fi
  netlify_hooks_edit --arg id "$id" --argjson hk "$hook" --arg r "$repo" --arg ref "$ref" --arg base "$base" --arg rule "$rule" \
    '.[$id] = ((.[$id] // {}) + {hookId:$hk.id, url:$hk.url, repo:$r, ref:$ref, base:$base, rule:($rule=="yes")}
      + (if $rule=="yes" then {ruleAt:(now|floor)} else {} end) + {offAt:(.[$id].offAt // (now|floor))})'

  if [ "$rule" = yes ]; then
    echo "Netlify: $site no longer deploys on push (the ignore rule is in $repo). Deploy with: deploys netlify deploy $site"
    return 0
  fi
  cat <<EOF
Netlify: one step left for $site. Netlify's API cannot turn off "build on push" without also
blocking our own deploys, so the switch goes into the repo. Add this to ${base:+$base/}netlify.toml in $repo ($ref):

  [build]
    $NETLIFY_IGNORE_LINE

Why: Netlify runs the ignore command before every build and skips the build when it exits 0.
INCOMING_HOOK_TITLE is only set when a build hook started the build, so pushes (and deploy
previews) are skipped and cost no credits; "deploys netlify deploy" posts to the hook and builds.
If netlify.toml already has a [build] section, add only the ignore line to it.
EOF
  case "$rule" in
    no) echo "Not found in $repo yet. Once it is on $ref, run: deploys netlify autodeploy-off $site" ;;
    *) echo "Could not read $repo with gh. Once the line is on $ref, run: deploys netlify autodeploy-off $site --rule-added" ;;
  esac
}

# netlify_deploy_json <site> [preview] [sha] — post to the hook, then find the deploy it started.
netlify_deploy_json() {
  local site="${1:-}" preview="" sha="" id hk before list new lock="" i polls
  shift || true
  # `deploys` calls <site> [--preview] [--sha <commit>]; the old positional <site> [preview] [sha]
  # still works. Without this, `--sha` landed in "preview" and was refused for the wrong reason.
  local _pos=0
  while [ $# -gt 0 ]; do
    case "$1" in
      --preview) preview=1 ;;
      --sha) [ -n "${2:-}" ] || netlify_die "Netlify: --sha needs a commit"; sha="$2"; shift ;;
      -*) netlify_die "Netlify: unknown option $1" ;;
      *) _pos=$((_pos + 1)); if [ "$_pos" = 1 ]; then preview="$1"; else sha="$1"; fi ;;
    esac
    shift
  done
  [ -z "$preview" ] || netlify_die "Netlify: preview deploys are not supported from here (the build hook deploys the production branch)"
  [ -z "$sha" ] || netlify_die "Netlify: a build hook always builds the newest commit of the branch; --sha is not supported"
  id="$(netlify_id_of "$site")" || netlify_die "Netlify site $site not found"
  hk="$(jq -c --arg id "$id" '.[$id] // empty' "$(netlify_hooks_file)")"
  [ -n "$hk" ] && [ "$(echo "$hk" | jq -r '.url // empty')" != "" ] \
    || netlify_die "$site has no build hook yet. Run: deploys netlify autodeploy-off $site"
  [ "$(echo "$hk" | jq '.rule == true')" = true ] \
    || netlify_die "$site is not deployable yet: the netlify.toml ignore rule was not found. Run: deploys netlify autodeploy-off $site"
  if declare -F start_lock >/dev/null; then lock="$(start_lock "netlify-$id")" || exit 1; fi
  # The deploys that exist before the call: the new one is the first id not among them. Ids, not
  # times, so a clock that is off by a minute cannot pick an old deploy.
  before="$(netlify_call GET "/sites/$id/deploys?per_page=20")" || { rm -f "$lock"; netlify_die "Netlify: could not read the deploys of $site"; }
  before="$(echo "$before" | jq -c '[.[].id]')"
  netlify_call POST "$(echo "$hk" | jq -r '.url')" '{"source":"deploy-center"}' >/dev/null \
    || { rm -f "$lock"; netlify_die "Netlify: the build hook of $site did not take the deploy"; }
  polls="${DEPLOYS_NETLIFY_POLLS:-15}"
  for ((i = 0; i < polls; i++)); do
    list="$(netlify_call GET "/sites/$id/deploys?per_page=5" 2>/dev/null)" || list="[]"
    new="$(echo "$list" | jq -c --argjson b "$before" "$NETLIFY_JQ"'[.[] | select(.id as $x | $b | index($x) | not)] | last // empty | deploy_out')"
    [ -n "$new" ] && { echo "$new" | jq '{id, url, state, phase}'; return 0; }
    sleep 2
  done
  # The hook took it; Netlify has not listed the build yet. Not an error: it will start.
  echo "Netlify: the deploy of $site was accepted but has not shown up yet" >&2
  jq -n '{id:null, url:null, state:"enqueued", phase:"queued"}'
}

# netlify_status_json [<site>] <deploy-id>
netlify_status_json() {
  local d="${2:-$1}" out
  out="$(netlify_call GET "/deploys/$d")" || netlify_die "Netlify: could not read deploy $d"
  echo "$out" | jq "$NETLIFY_JQ"'deploy_out'
}

# The newest production deploy that was not skipped by the ignore rule.
netlify_latest_json() {
  local id out
  id="$(netlify_id_of "$1")" || netlify_die "Netlify site $1 not found"
  out="$(netlify_call GET "/sites/$id/deploys?production=true&per_page=20")" || netlify_die "Netlify: could not read the deploys of $1"
  echo "$out" | jq "$NETLIFY_JQ"'map(select(skipped | not)) | .[0] // null | if . then deploy_out else null end'
}

# netlify_cancel [<site>] <deploy-id>
netlify_cancel() {
  local d="${2:-$1}"
  netlify_call POST "/deploys/$d/cancel" >/dev/null || netlify_die "Netlify: could not cancel $d"
  jq -nc --arg d "$d" '{id:$d, state:"canceled", phase:"canceled", message:"Netlify: deploy \($d) canceled"}'
}

# Back to the ready production deploy before the one that is live. A restore publishes files
# Netlify already has: no build, no credits.
netlify_rollback() {
  local id info live list prev
  id="$(netlify_id_of "$1")" || netlify_die "Netlify site $1 not found"
  info="$(netlify_call GET "/sites/$id")" || netlify_die "Netlify: could not read $1"
  live="$(echo "$info" | jq -r '.published_deploy.id // empty')"
  list="$(netlify_call GET "/sites/$id/deploys?production=true&state=ready&per_page=20")" || netlify_die "Netlify: could not read the deploys of $1"
  # The list is newest first. Only deploys older than the live one count: a newer ready one is
  # what an earlier rollback went back from.
  prev="$(echo "$list" | jq -r --arg live "$live" '(map(.id) | index($live)) as $i
    | (if $i == null then . else .[($i + 1):] end)
    | [.[] | select(.state=="ready" and .id != $live)][0].id // empty')"
  [ -n "$prev" ] || netlify_die "Netlify: $1 has no earlier ready production deploy to go back to"
  netlify_call POST "/sites/$id/deploys/$prev/restore" >/dev/null || netlify_die "Netlify: could not restore $prev"
  # A restore publishes files Netlify has: live at once, nothing builds.
  jq -nc --arg d "$prev" --arg s "$1" '{id:$d, state:"ready", phase:"ready", message:"Netlify: \($s) is back on deploy \($d)"}'
}

# Netlify's REST API has no build log (the dashboard streams it), so caps.logs is false. This
# prints what the API does say about the deploy, and where the full log is.
netlify_logs() {
  local site="$1" d="" out
  shift
  # `deploys logs` calls <site> <lines> <deployId>, positional; --id <deploy> works too.
  while [ $# -gt 0 ]; do case "$1" in
    --id) d="${2:-}"; shift 2 ;;
    -*) netlify_die "Unknown option $1. Usage: netlify_logs <site> [lines] [deployId | --id <deploy>]" ;;
    ''|*[!0-9]*) d="$1"; shift ;;
    *) shift ;;
  esac; done
  if [ -n "$d" ]; then out="$(netlify_status_json "$d")"; else out="$(netlify_latest_json "$site")"; fi
  [ "$out" != null ] || netlify_die "Netlify: $site has no deploys yet"
  echo "$out" | jq -r '"Deploy \(.id): \(.state)\(if .error then " — " + .error else "" end)",
    "Netlify gives no build log through its API. The full log: \(.dashboardUrl // "the site dashboard")"'
}

# netlify_url <site> [--dashboard]
netlify_url() {
  local id info
  id="$(netlify_id_of "$1")" || netlify_die "Netlify site $1 not found"
  info="$(netlify_call GET "/sites/$id")" || netlify_die "Netlify: could not read $1"
  if [ "${2:-}" = --dashboard ]; then echo "$info" | jq -r '.admin_url // empty'
  else echo "$info" | jq -r '.ssl_url // .url // empty'; fi
}

# The token on stdin. Tried against /user first, saved only when Netlify takes it.
netlify_set_key() {
  local key=""
  IFS= read -r key || true
  # A trailing CR, tab or newline from the clipboard is not part of the token.
  key="$(printf '%s' "$key" | tr -d '[:space:]')"
  [ -n "$key" ] || netlify_die "Pipe the token in: pbpaste | deploys netlify set-key"
  case "$key" in *\'*|*\"*|*' '*) netlify_die "That does not look like a Netlify token";; esac
  ( NETLIFY_AUTH_TOKEN="$key"; key_of() { printf '%s' "$NETLIFY_AUTH_TOKEN"; }; netlify_call GET /user >/dev/null ) \
    || netlify_die "Netlify did not accept that token; nothing was saved"
  # On stdin to `security -i`, so the token is never an argument anyone can see.
  printf 'add-generic-password -U -a %s -s %s -w %s\n' "${USER:-$(id -un)}" "$NETLIFY_KEYCHAIN" "$key" | security -i >/dev/null \
    || netlify_die "The token works, but could not be saved in the keychain"
  echo "Netlify token saved and working."
}

netlify_doctor() {
  local src="missing" ok=false err="" n=null hooks
  if [ -n "${NETLIFY_AUTH_TOKEN:-}" ]; then src="env"
  elif security find-generic-password -a "${USER:-$(id -un)}" -s "$NETLIFY_KEYCHAIN" >/dev/null 2>&1; then src="keychain"; fi
  if [ "$src" != missing ]; then
    if err="$(netlify_call GET /user 2>&1 >/dev/null)"; then ok=true; err=""
      n="$(netlify_sites 2>/dev/null | jq 'length' 2>/dev/null)" || n=null
    fi
  fi
  hooks="$(jq 'length' "$(netlify_hooks_file)" 2>/dev/null)" || hooks=0
  jq -n --arg src "$src" --argjson ok "$ok" --arg err "$err" --argjson n "${n:-null}" --argjson h "${hooks:-0}" \
    --argjson gh "$(command -v gh >/dev/null 2>&1 && echo true || echo false)" \
    '{provider:"netlify", key:$src, tokenOk:$ok, error:(if $err == "" then null else $err end),
      sites:$n, hooks:$h, gh:$gh}'
}

# ---------- the contract's status lines (docs/PROVIDERS.md) ----------
# `deploys watch`, `deploy --wait` and group deploys read one line: deployId<TAB>phase<TAB>state,
# and "none" as the id when there is no deploy. The JSON above stays for people:
# `deploys netlify status|latest` prints it (netlify_cli_status, netlify_cli_latest).
NETLIFY_TSV='if . == null then "none\t\tnone"
  else "\(.id // "none")\t\(.phase // "")\t\(.state // (if .stage then "\(.stage):\(.status // "")" else .status end) // "?")" end'
netlify_status() { local j; j="$(netlify_status_json "$@")" || return 1; printf '%s' "$j" | jq -r "$NETLIFY_TSV"; }
netlify_latest() { local j; j="$(netlify_latest_json "$@")" || return 1; printf '%s' "$j" | jq -r "$NETLIFY_TSV"; }
netlify_cli_status() { netlify_status_json "$@"; }
netlify_cli_latest() { netlify_latest_json "$@"; }
