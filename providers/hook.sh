#!/bin/bash
# providers/hook.sh — a generic "deploy hook" provider for deploys.
#
# Any host that gives you a build-trigger URL: Cloudflare Pages deploy hooks, Netlify build
# hooks, DigitalOcean App Platform, Coolify, Dokploy, Amplify webhooks, a CI's
# workflow_dispatch. A POST to the URL starts a build; there is no status API behind it, so a
# 2xx answer is all we know ("triggered"). See docs/providers/hook.md.
#
# Opt-in: it shows up only once a hook is added.
#
#   deploys hook add <name> <url|-> [--repo owner/name] [--ref main] [--site https://…]
#                    [--method POST] [--header 'Name: value'] [--body '{…}']
#   deploys hook remove <name>
#   deploys hook list
#   deploys hook deploy <name>          trigger the hook
#   deploys hook set-key <name>         replace the stored URL (read from stdin)
#   deploys hook json | doctor          for the app
#
# Config:  $CONFIG_DIR/hooks.json        [{name, method, headers, body, repo, ref, site}]
# State:   $CONFIG_DIR/hook-state.json   {name: {sha, msg, at, ok, http}} of the last trigger
# Secrets: the URL itself is a secret (anyone with it can start builds). It lives in the
#          keychain as deploy-center-hook-<name>, or without a keychain in a 0600 file under
#          $CONFIG_DIR/hook-urls/. Header values hold only references like $TOKEN, read from
#          the environment when the hook fires. No URL or header value is ever printed.
#
# Sourced by deploys (which brings die, with_heads, CONFIG_DIR). Run directly, it loads
# deploys as a library itself.

HOOK_CAPS='{"off":false,"sha":false,"cancel":false,"rollback":false,"logs":false,"preview":false}'
HOOK_KEYCHAIN_PREFIX="deploy-center-hook-"

hook_config() { echo "$CONFIG_DIR/hooks.json"; }
hook_state_file() { echo "$CONFIG_DIR/hook-state.json"; }
hook_list_raw() { local f; f="$(hook_config)"; if [ -s "$f" ]; then cat "$f"; else echo '[]'; fi; }
hook_state() { local f; f="$(hook_state_file)"; if [ -s "$f" ]; then cat "$f"; else echo '{}'; fi; }
# Writes go through a temp file in the same folder, so a crash never leaves half a file.
hook_write() { local f="$1" t; t="$(mktemp "$f.XXXXXX")" && cat > "$t" && chmod 600 "$t" && mv -f "$t" "$f"; }

hook_valid_name() {
  case "$1" in ''|-*|*[!A-Za-z0-9._-]*) die "A hook name is letters, digits, dot, dash or underscore: \"$1\"";; esac
  [ "${#1}" -le 64 ] || die "A hook name is at most 64 characters"
}
hook_entry() { hook_list_raw | jq -c --arg n "$1" '.[] | select(.name == $n)'; }

# ---------- the URL, a secret ----------

# keychain on a Mac, else files. DEPLOYS_HOOK_STORE=keychain|file forces one.
hook_store() {
  case "${DEPLOYS_HOOK_STORE:-}" in keychain|file) echo "$DEPLOYS_HOOK_STORE"; return;; esac
  if [ "$(uname)" = Darwin ] && command -v security >/dev/null 2>&1; then echo keychain; else echo file; fi
}
hook_url_file() { echo "$CONFIG_DIR/hook-urls/$1"; }

# Shown instead of the URL: scheme and host only. The path is where the secret is.
hook_mask() {
  local u="$1" rest host
  case "$u" in *://*) ;; *) echo "•••"; return;; esac
  rest="${u#*://}"; host="${rest%%[/?#]*}"; host="${host##*@}"
  echo "${u%%://*}://$host/•••"
}

hook_check_url() {
  local u="$1"
  case "$u" in https://*) ;; http://localhost*|http://127.0.0.1*) ;;
    http://*) die "Use the https:// address of the hook: over http the secret URL travels in the clear";;
    *) die "That is not a hook URL (it should start with https://)";; esac
  case "$u" in *[[:space:]\"\'\\]*) die "The hook URL contains spaces, quotes or backslashes";; esac
  [ "${#u}" -le 2048 ] || die "The hook URL is longer than 2048 characters"
}

hook_url_save() {
  local n="$1" u="$2"
  if [ "$(hook_store)" = keychain ]; then
    # Through `security -i` on stdin: the URL never shows up in the process list.
    printf 'add-generic-password -U -a %s -s %s%s -w "%s"\n' "$USER" "$HOOK_KEYCHAIN_PREFIX" "$n" "$u" | security -i >/dev/null \
      || die "Could not save the hook URL in the keychain"
  else
    mkdir -p "$CONFIG_DIR/hook-urls" && chmod 700 "$CONFIG_DIR/hook-urls"
    ( umask 077; printf '%s' "$u" > "$(hook_url_file "$n")" ) || die "Could not save the hook URL"
    chmod 600 "$(hook_url_file "$n")"
  fi
}
hook_url_get() {
  if [ "$(hook_store)" = keychain ]; then security find-generic-password -a "$USER" -s "$HOOK_KEYCHAIN_PREFIX$1" -w 2>/dev/null
  else cat "$(hook_url_file "$1")" 2>/dev/null; fi
}
# Whether one is stored, without reading it out.
hook_url_stored() {
  if [ "$(hook_store)" = keychain ]; then security find-generic-password -a "$USER" -s "$HOOK_KEYCHAIN_PREFIX$1" >/dev/null 2>&1
  else [ -s "$(hook_url_file "$1")" ]; fi
}
hook_url_forget() {
  if [ "$(hook_store)" = keychain ]; then security delete-generic-password -a "$USER" -s "$HOOK_KEYCHAIN_PREFIX$1" >/dev/null 2>&1 || true
  else rm -f "$(hook_url_file "$1")"; fi
}

# $TOKEN and ${TOKEN} in a header value, from the environment. Nothing else is expanded
# (no eval, no command substitution). An unset variable stops the trigger.
hook_expand() {
  local s="$1" out="" v re='^([^$]*)\$(\{([A-Za-z_][A-Za-z0-9_]*)\}|([A-Za-z_][A-Za-z0-9_]*))(.*)$'
  while [[ "$s" =~ $re ]]; do
    v="${BASH_REMATCH[3]:-${BASH_REMATCH[4]}}"
    [ -n "${!v+x}" ] || { echo "\$$v" >&2; return 1; }
    out+="${BASH_REMATCH[1]}${!v}"; s="${BASH_REMATCH[5]}"
  done
  printf '%s' "$out$s"
}
# A value for curl's config file: backslashes and quotes escaped.
hook_cq() { local s="${1//\\/\\\\}"; printf '"%s"' "${s//\"/\\\"}"; }

# ---------- the contract ----------

hook_meta() {
  jq -nc --argjson caps "$HOOK_CAPS" '{name:"hook", title:"Deploy hook", optIn:true, caps:$caps,
    note:"No status API: a 2xx answer to the hook counts as ready (lastState \"triggered\")."}'
}

# Set up as soon as one hook is configured.
hook_ready() { [ "$(hook_list_raw | jq 'length' 2>/dev/null || echo 0)" -gt 0 ]; }
hook_has() { hook_valid_name "$1" >/dev/null 2>&1 || return 1; [ -n "$(hook_entry "$1")" ]; }

hook_json() {
  local list st stored='{}' n
  list="$(hook_list_raw)"; st="$(hook_state)"
  for n in $(echo "$list" | jq -r '.[].name'); do
    hook_url_stored "$n" && stored="$(echo "$stored" | jq -c --arg n "$n" '.[$n] = true')"
  done
  list="$(echo "$list" | jq --argjson st "$st" --argjson ok "$stored" '[.[] | ($st[.name] // {}) as $s | {
      name, id:.name,
      # Whether a push builds by itself is up to the host; this side cannot tell.
      auto:null,
      deployable:($ok[.name] // false), paused:false,
      repo:(.repo // null), ref:(if .repo then (.ref // "main") else (.ref // null) end),
      domain:((.site // "") | sub("^https?://";"") | sub("/.*$";"") | if . == "" then null else . end),
      url:(.site // null), dashboardUrl:null,
      lastAt:($s.at // null),
      lastState:(if $s.at == null then null elif $s.ok then "triggered" else "trigger failed (\($s.error // "HTTP \($s.http // "?")"))" end),
      lastSha:($s.sha // null), lastMsg:($s.msg // null),
      fetchError:(if $ok[.name] then null else "the hook URL is not stored here (deploys hook set-key \(.name))" end),
      # No status API: a 2xx answer is as far as anyone can see.
      phase:(if $s.at == null then null elif $s.ok then "ready" else "failed" end)}]
    | sort_by(.name | ascii_downcase)')"
  if declare -F with_heads >/dev/null; then with_heads "$list"; else echo "$list"; fi
}

hook_off() {
  hook_has "${1:-}" || die "No hook named \"${1:-}\""
  die "A deploy hook cannot turn off auto-deploy: that is a setting at the host (for example Cloudflare Pages > Settings > Builds > Branch control, Netlify > Build settings > Stop builds, Coolify > Auto Deploy, DigitalOcean > Source > Autodeploy). Turn it off there; the hook keeps working."
}

# The head of the branch right now, so the trigger can say which commit it asked for.
hook_head() {
  local repo="$1" ref="$2"
  command -v gh >/dev/null 2>&1 && [ -z "${DEPLOYS_NO_GITHUB:-}" ] || return 0
  gh api "repos/$repo/commits/$ref" 2>/dev/null \
    | jq -c '{sha, msg:(.commit.message | split("\n")[0])}' 2>/dev/null || true
}

hook_record() {
  local n="$1" rec="$2" st
  st="$(hook_state | jq -c --arg n "$n" --argjson r "$rec" '.[$n] = $r')" || return 0
  echo "$st" | hook_write "$(hook_state_file)"
}

# Fire the hook once (never again on failure: it may already have started a build).
hook_deploy_json() {
  local n="${1:-}" e u method headers body cfg out code rc=0 h hv miss head sha=null msg=null now rec repo ref
  hook_has "$n" || die "No hook named \"$n\""
  e="$(hook_entry "$n")"
  u="$(hook_url_get "$n")" || u=""
  [ -n "$u" ] || die "The URL of hook $n is not stored here. Store it: pbpaste | deploys hook set-key $n"
  method="$(echo "$e" | jq -r '.method // "POST"')"
  body="$(echo "$e" | jq -r '.body // empty')"
  repo="$(echo "$e" | jq -r '.repo // empty')"; ref="$(echo "$e" | jq -r '.ref // "main"')"
  cfg="$(mktemp)"; out="$(mktemp)"
  # The URL and the headers go to curl on stdin (a config), never on its command line.
  {
    printf 'url = %s\nrequest = %s\n' "$(hook_cq "$u")" "$(hook_cq "$method")"
    printf 'silent\nshow-error\nmax-time = 30\nproto = "=https,http"\noutput = %s\nwrite-out = "%%{http_code}"\n' "$(hook_cq "$out")"
    printf 'header = "User-Agent: deploy-center"\n'
    [ -z "$body" ] || printf 'header = "Content-Type: application/json"\ndata = %s\n' "$(hook_cq "$body")"
  } > "$cfg"
  headers="$(echo "$e" | jq -r '(.headers // {}) | to_entries[] | "\(.key)\t\(.value)"')"
  while IFS=$'\t' read -r h hv; do
    [ -n "$h" ] || continue
    if ! hv="$(hook_expand "$hv" 2>&1)"; then miss="$hv"; rm -f "$cfg" "$out"; die "Hook $n needs $miss in the environment for its $h header"; fi
    printf 'header = %s\n' "$(hook_cq "$h: $hv")" >> "$cfg"
  done <<< "$headers"
  if [ -n "$repo" ]; then head="$(hook_head "$repo" "$ref")"
    [ -z "$head" ] || { sha="$(echo "$head" | jq -c .sha)"; msg="$(echo "$head" | jq -c .msg)"; }
  fi
  code="$(curl -K - < "$cfg" 2>"$out.err")" || rc=$?
  rm -f "$cfg" "$out"
  now="$(date +%s)"
  if [ "$rc" = 0 ] && [[ "$code" =~ ^2[0-9][0-9]$ ]]; then
    rec="$(jq -nc --argjson sha "$sha" --argjson msg "$msg" --argjson at "$now" --arg c "$code" '{ok:true, http:($c|tonumber), at:$at, sha:$sha, msg:$msg}')"
    hook_record "$n" "$rec"; rm -f "$out.err"
    jq -nc --arg n "$n" --argjson r "$rec" '{name:$n, id:"\($n)@\($r.at)", phase:"ready", state:"triggered", http:$r.http, sha:$r.sha, at:$r.at,
      note:"The host accepted the trigger; it reports no build status."}'
    return 0
  fi
  # curl's own error, with the URL masked in case it names it.
  local err; err="$(tail -n 1 "$out.err" 2>/dev/null | cut -c1-200)"; rm -f "$out.err"
  err="${err//"$u"/$(hook_mask "$u")}"
  if [ "$rc" != 0 ]; then err="no answer (${err:-curl exit $rc})"; else err="HTTP ${code:-000}"; fi
  # A failed trigger keeps the sha of the last good one: what is live has not moved.
  rec="$(hook_state | jq -c --arg n "$n" --argjson at "$now" --arg e "$err" --arg c "${code:-0}" '(.[$n] // {}) + {ok:false, http:($c|tonumber? // 0), at:$at, error:$e}')"
  hook_record "$n" "$rec"
  die "Hook $n did not start a build: $err"
}

hook_status() {
  local n="${1:-}"; hook_has "$n" || die "No hook named \"$n\""
  hook_state | jq -c --arg n "$n" '(.[$n] // null) as $s | {name:$n,
    phase:(if $s == null then null elif $s.ok then "ready" else "failed" end),
    state:(if $s == null then "never triggered" elif $s.ok then "triggered" else "trigger failed" end),
    at:($s.at // null), sha:($s.sha // null)}'
}
hook_latest() { hook_status "$@"; }
hook_cancel() { die "A deploy hook cannot cancel a build: there is no API behind it. Cancel it at the host."; }
hook_rollback() { die "A deploy hook cannot roll back: there is no API behind it. Roll back at the host."; }
hook_logs() { die "A deploy hook has no logs: there is no API behind it. The build log is at the host."; }

hook_url() {
  local n="${1:-}" s; hook_has "$n" || die "No hook named \"$n\""
  s="$(hook_entry "$n" | jq -r '.site // empty')"
  [ -n "$s" ] || die "Hook $n has no site address (deploys hook add $n - --site https://…)"
  echo "$s"
}

# Replace the stored URL, read from stdin (a new hook URL after rotating it at the host).
hook_set_key() {
  local n="${1:-}" u; hook_has "$n" || die "No hook named \"$n\". Add it: deploys hook add $n -"
  IFS= read -r u || true
  [ -n "$u" ] || die "Pipe the hook URL in: pbpaste | deploys hook set-key $n"
  hook_check_url "$u"; hook_url_save "$n" "$u"
  echo "URL of hook $n saved ($(hook_mask "$u"))."
}

hook_doctor() {
  local list n u items='[]' ok
  list="$(hook_list_raw)"
  for n in $(echo "$list" | jq -r '.[].name'); do
    ok=false; u="$(hook_url_get "$n" 2>/dev/null || true)"; [ -n "$u" ] && ok=true
    items="$(echo "$items" | jq -c --arg n "$n" --arg m "$( [ -n "$u" ] && hook_mask "$u")" --argjson ok "$ok" \
      --argjson e "$(echo "$list" | jq -c --arg n "$n" '.[] | select(.name == $n)')" \
      '. + [{name:$n, stored:$ok, url:(if $ok then $m else null end), method:($e.method // "POST"),
             headers:(($e.headers // {}) | keys), repo:($e.repo // null), site:($e.site // null)}]')"
  done
  jq -nc --arg store "$(hook_store)" --argjson h "$items" --argjson curl "$(command -v curl >/dev/null && echo true || echo false)" \
    '{provider:"hook", ready:($h | length > 0), store:$store, curl:$curl, hooks:$h}'
}

# ---------- commands ----------

hook_add() {
  local n="${1:-}" u="${2:-}" repo="" ref="" site="" method="POST" body="" headers='{}' h k v
  [ -n "$n" ] && [ -n "$u" ] || die "Usage: deploys hook add <name> <url|-> [--repo owner/name] [--ref main] [--site https://…] [--method POST] [--header 'Name: value'] [--body '{…}']"
  hook_valid_name "$n"; shift 2
  while [ $# -gt 0 ]; do
    case "$1" in
      --repo) repo="${2:?--repo owner/name}"; shift;;
      --ref) ref="${2:?--ref <branch>}"; shift;;
      --site) site="${2:?--site https://…}"; shift;;
      --method) method="$(echo "${2:?--method POST}" | tr '[:lower:]' '[:upper:]')"; shift;;
      --body) body="${2:?--body '{…}'}"; shift;;
      --header) h="${2:?--header 'Name: value'}"; shift
        k="${h%%:*}"; v="${h#*:}"; v="${v# }"
        [ "$k" != "$h" ] && [[ "$k" =~ ^[A-Za-z0-9-]+$ ]] || die "A header is 'Name: value'"
        # Secrets stay out of the file: a credential-looking header must name a variable.
        if [[ "$k" =~ [Aa]uthorization|[Tt]oken|[Kk]ey|[Ss]ecret|[Pp]assword|[Cc]ookie ]] && [[ "$v" != *'$'* ]]; then
          die "The $k header looks like a secret. Put it in the environment and write a reference: --header '$k: Bearer \$TOKEN'"
        fi
        headers="$(echo "$headers" | jq -c --arg k "$k" --arg v "$v" '.[$k] = $v')";;
      *) die "Unknown option $1";;
    esac; shift
  done
  case "$method" in POST|GET|PUT|PATCH) ;; *) die "--method is POST, GET, PUT or PATCH";; esac
  [ -z "$repo" ] || [[ "$repo" =~ ^[A-Za-z0-9_.-]+/[A-Za-z0-9_.-]+$ ]] || die "--repo is owner/name"
  [ -z "$site" ] || [[ "$site" =~ ^https?://[^[:space:]]+$ ]] || die "--site is an http(s) address"
  [ -z "$body" ] || echo "$body" | jq -e . >/dev/null 2>&1 || die "--body is JSON"
  # "-" reads the URL from stdin: it then stays out of the shell history.
  if [ "$u" = - ]; then IFS= read -r u || true; [ -n "$u" ] || die "No URL on stdin"; fi
  hook_check_url "$u"
  local existed=0; [ -n "$(hook_entry "$n")" ] && existed=1
  hook_url_save "$n" "$u"
  hook_list_raw | jq --arg n "$n" --arg m "$method" --argjson h "$headers" --arg b "$body" --arg r "$repo" --arg f "$ref" --arg s "$site" '
      map(select(.name != $n)) + [{name:$n, method:$m}
        + (if ($h | length) > 0 then {headers:$h} else {} end)
        + (if $b != "" then {body:$b} else {} end)
        + (if $r != "" then {repo:$r, ref:(if $f == "" then "main" else $f end)} elif $f != "" then {ref:$f} else {} end)
        + (if $s != "" then {site:$s} else {} end)]
      | sort_by(.name)' | hook_write "$(hook_config)"
  if [ "$existed" = 1 ]; then echo "Hook $n updated ($(hook_mask "$u"))."; else echo "Hook $n added ($(hook_mask "$u"))."; fi
}

hook_remove() {
  local n="${1:-}"; [ -n "$n" ] || die "Usage: deploys hook remove <name>"
  hook_has "$n" || die "No hook named \"$n\""
  hook_list_raw | jq --arg n "$n" 'map(select(.name != $n))' | hook_write "$(hook_config)"
  hook_state | jq --arg n "$n" 'del(.[$n])' | hook_write "$(hook_state_file)"
  hook_url_forget "$n"
  echo "Hook $n removed. The URL still works at the host until you delete or rotate it there."
}

hook_list() {
  local list n u rows=""
  list="$(hook_list_raw)"
  [ "$(echo "$list" | jq length)" -gt 0 ] || { echo "No hooks yet. Add one: deploys hook add <name> -  (URL on stdin)"; return 0; }
  for n in $(echo "$list" | jq -r '.[].name'); do
    u="$(hook_url_get "$n" 2>/dev/null || true)"
    rows+="$(echo "$list" | jq -r --arg n "$n" --arg m "$( if [ -n "$u" ]; then hook_mask "$u"; else echo "(not stored)"; fi)" --argjson st "$(hook_state)" \
      '.[] | select(.name == $n) | ($st[.name] // {}) as $s | [.name, (.method // "POST"), $m,
        (if .repo then "\(.repo)@\(.ref // "main")" else "-" end), (.site // "-"),
        (if $s.at == null then "never" elif $s.ok then ($s.at | strftime("%Y-%m-%d %H:%M")) + " ok" else ($s.at | strftime("%Y-%m-%d %H:%M")) + " failed" end)] | @tsv')"$'\n'
  done
  printf 'NAME\tMETHOD\tURL\tREPO\tSITE\tLAST TRIGGER (UTC)\n%s' "$rows" \
    | if command -v column >/dev/null 2>&1; then column -t -s $'\t'; else cat; fi
}

hook_cli() {
  local c="${1:-list}"; [ $# -eq 0 ] || shift
  case "$c" in
    add) hook_add "$@";;
    remove|rm) hook_remove "$@";;
    list) hook_list;;
    json) hook_json;;
    deploy) hook_deploy_json "$@" | jq -r '"Triggered \(.name) (HTTP \(.http)). The host reports no build status; watch it there."';;
    deploy-json) hook_deploy_json "$@";;
    status) hook_status "$@";;
    open|url) hook_url "$@";;
    set-key) hook_set_key "$@";;
    autodeploy-off|off) hook_off "$@";;
    cancel) hook_cancel;; rollback) hook_rollback;; logs) hook_logs;;
    doctor) hook_doctor;;
    meta) hook_meta;;
    *) die "Usage: deploys hook add|remove|list|deploy|set-key|json|doctor";;
  esac
}

# Run directly (until deploys routes `deploys hook …` here itself): load deploys as a library.
if [ "${BASH_SOURCE[0]}" = "$0" ]; then
  _hook_args=("$@"); set --
  # shellcheck source=../deploys
  DEPLOYS_LIB=1 . "$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)/deploys"
  hook_cli ${_hook_args[@]+"${_hook_args[@]}"}
fi
