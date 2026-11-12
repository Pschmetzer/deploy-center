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
  local host="${u#*://}"; host="${host%%[/?#]*}"
  case "$u" in https://*) ;;
    # Plain http only to this Mac: the host exactly, with or without a port. Not
    # http://localhost.example.com, http://127.0.0.1.example.com or a user@ in front.
    http://*) case "$host" in localhost|localhost:[0-9]*|127.0.0.1|127.0.0.1:[0-9]*|\[::1\]|\[::1\]:[0-9]*) ;;
        *) die "Use the https:// address of the hook: over http the secret URL travels in the clear";; esac ;;
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
# Newlines, returns and tabs as \n, \r, \t (curl reads those escapes): a body over several lines
# would otherwise end the option and leave the rest as garbage.
hook_cq() {
  local s="${1//\\/\\\\}"; s="${s//\"/\\\"}"
  s="${s//$'\n'/\\n}"; s="${s//$'\r'/\\r}"; s="${s//$'\t'/\\t}"
  printf '"%s"' "$s"
}

# ---------- the contract ----------

# Compact, with printf: deploys greps it (meta_flag, meta_str) and doctor reads it without jq.
# Off by default (defaultOn false). Each hook's URL is its own secret, so there is no keyEnv and
# no single keychain item: the URLs live under deploy-center-hook-<name> (see below).
hook_meta() {
  printf '{"id":"hook","name":"hook","label":"Deploy hook","noun":"hook","defaultOn":false,"keyEnv":[],"keychain":null,"caps":%s,"note":"No status API: a 2xx answer to the hook counts as ready (lastState \\"triggered\\")."}\n' "$HOOK_CAPS"
}

# Set up as soon as one hook is configured.
hook_ready() { [ "$(hook_list_raw | jq 'length' 2>/dev/null || echo 0)" -gt 0 ]; }
# hook_known: a silent check for the functions below. hook_has (the contract) prints the id.
hook_known() { hook_valid_name "$1" >/dev/null 2>&1 || return 1; [ -n "$(hook_entry "$1")" ]; }
hook_has() { hook_known "${1:-}" && echo "$1"; }

# How long after a good trigger the list shows "queued" instead of "ready": a build usually
# takes that long, and green straight away would hide one that fails. HOOK_QUEUED_SECS, else 180.
hook_queued_secs() {
  case "${HOOK_QUEUED_SECS:-}" in ''|*[!0-9]*) echo 180 ;; *) echo "$HOOK_QUEUED_SECS" ;; esac
}

hook_json() {
  local list st stored='{}' n
  list="$(hook_list_raw)"; st="$(hook_state)"
  for n in $(echo "$list" | jq -r '.[].name'); do
    hook_url_stored "$n" && stored="$(echo "$stored" | jq -c --arg n "$n" '.[$n] = true')"
  done
  list="$(echo "$list" | jq --argjson st "$st" --argjson ok "$stored" --argjson now "$(date +%s)" --argjson qs "$(hook_queued_secs)" '[.[] | ($st[.name] // {}) as $s | {
      name, id:.name,
      # Whether a push builds by itself is up to the host; this side cannot tell.
      auto:null,
      deployable:($ok[.name] // false), paused:false,
      repo:(.repo // null), ref:(if .repo then (.ref // "main") else (.ref // null) end),
      domain:((.site // "") | sub("^https?://";"") | sub("/.*$";"") | if . == "" then null else . end),
      url:(.site // null), dashboardUrl:null,
      lastAt:($s.at // null),
      lastState:(if $s.at == null then null elif $s.ok then "triggered" else "trigger failed (\($s.error // "HTTP \($s.http // "?")"))" end),
      # The branch head when the hook fired, not a commit seen live: the host may build another
      # branch or commit. lastSha keeps it for "commits since the last trigger"; triggeredSha
      # says what it is, so the app need not call it live (PRV-077).
      lastSha:($s.sha // null), triggeredSha:($s.sha // null), lastMsg:($s.msg // null),
      fetchError:(if $ok[.name] then null else "the hook URL is not stored here (deploys hook set-key \(.name))" end),
      # No status API: a 2xx answer is as far as anyone can see. For a while after it the build
      # is likely still running, so the list says queued, then ready (PRV-125).
      phase:(if $s.at == null then null elif $s.ok then (if ($now - $s.at) < $qs then "queued" else "ready" end) else "failed" end)}]
    | sort_by(.name | ascii_downcase)')"
  # No GitHub calls here: `deploys hook json` adds the branch heads (provider_json).
  echo "$list"
}

hook_off() {
  hook_known "${1:-}" || die "No hook named \"${1:-}\""
  die "Deploy hook cannot turn off auto-deploy: that is a setting at the host (for example Cloudflare Pages > Settings > Builds > Branch control, Netlify > Build settings > Stop builds, Coolify > Auto Deploy, DigitalOcean > Source > Autodeploy). Turn it off there; the hook keeps working."
}

# The head of the branch right now, so the trigger can say which commit it asked for.
hook_head() {
  local repo="$1" ref="$2"
  command -v gh >/dev/null 2>&1 && [ -z "${DEPLOYS_NO_GITHUB:-}" ] || return 0
  gh api "repos/$repo/commits/$ref" 2>/dev/null \
    | jq -c '{sha, msg:(.commit.message | split("\n")[0])}' 2>/dev/null || true
}

hook_record() {
  local n="$1" rec="$2" st f lock i=0
  f="$(hook_state_file)"; lock="$f.lock"
  # Two triggers at once (a group deploy) must not overwrite each other: a mkdir lock, given up
  # after five seconds (a crashed run's lock older than a minute is taken over).
  while ! mkdir "$lock" 2>/dev/null; do
    if [ -d "$lock" ] && [ $(( $(date +%s) - $(mtime "$lock" 2>/dev/null || date +%s) )) -ge 60 ]; then rmdir "$lock" 2>/dev/null; continue; fi
    i=$((i + 1)); [ "$i" -lt 50 ] || { echo "Warning: hook state is locked; the trigger of $n is not recorded" >&2; return 0; }
    sleep 0.1
  done
  # A broken state file is kept aside and started anew, with a warning: the trigger did happen.
  if ! st="$(hook_state | jq -c --arg n "$n" --argjson r "$rec" '.[$n] = $r' 2>/dev/null)"; then
    cp "$f" "$f.bak" 2>/dev/null || true
    echo "Warning: $f was not readable; kept as $f.bak and started anew" >&2
    st="$(jq -nc --arg n "$n" --argjson r "$rec" '{($n): $r}')"
  fi
  echo "$st" | hook_write "$f"
  rmdir "$lock" 2>/dev/null || true
}

# Fire the hook once (never again on failure: it may already have started a build).
hook_deploy_json() {
  local n="${1:-}" e u method headers body cfg out code rc=0 h hv miss head sha=null msg=null now rec repo ref
  hook_known "$n" || die "No hook named \"$n\""
  local _a; for _a in "${@:2}"; do case "$_a" in --preview|--sha) ;; -*) die "Deploy hook: unknown option $_a";; esac; done
  case " ${*:2} " in
    *" --preview "*) die "Deploy hook cannot start a preview: the hook builds what the host is set to build.";;
    *" --sha "*) die "Deploy hook cannot deploy a given commit: the hook builds what the host is set to build.";;
  esac
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
  # Two clicks or two runs must not build twice: the same one-minute lock as the other providers.
  if declare -F start_lock >/dev/null; then
    # In a subshell: start_lock's die would end the script here and leave the config, which
    # holds the secret URL, in the temp folder.
    ( start_lock "hook-$n" ) >/dev/null || { rm -f "$cfg" "$out"; exit 1; }
  fi
  code="$(curl -K - < "$cfg" 2>"$out.err")" || rc=$?
  local said=""; said="$(head -c 200 "$out" 2>/dev/null | tr '\n\r\t' '   ')" || said=""
  rm -f "$cfg" "$out"
  now="$(date +%s)"
  if [ "$rc" = 0 ] && [[ "$code" =~ ^2[0-9][0-9]$ ]]; then
    rec="$(jq -nc --argjson sha "$sha" --argjson msg "$msg" --argjson at "$now" --arg c "$code" '{ok:true, http:($c|tonumber), at:$at, sha:$sha, msg:$msg}')"
    hook_record "$n" "$rec"; rm -f "$out.err"
    jq -nc --arg n "$n" --argjson r "$rec" --arg site "$(echo "$e" | jq -r '.site // empty')" '{name:$n, id:"\($n)@\($r.at)", url:(if $site == "" then null else $site end), phase:"ready", state:"triggered", http:$r.http, sha:$r.sha, at:$r.at,
      note:"The host accepted the trigger; it reports no build status."}'
    return 0
  fi
  # curl's own error, with the URL masked in case it names it.
  local err; err="$(tail -n 1 "$out.err" 2>/dev/null | cut -c1-200)"; rm -f "$out.err"
  err="${err//"$u"/$(hook_mask "$u")}"
  said="${said//"$u"/$(hook_mask "$u")}"
  if [ "$rc" != 0 ]; then err="no answer (${err:-curl exit $rc})"; else err="HTTP ${code:-000}${said:+: $said}"; fi
  # A failed trigger keeps the sha of the last good one: what is live has not moved.
  rec="$(hook_state | jq -c --arg n "$n" --argjson at "$now" --arg e "$err" --arg c "${code:-0}" '(.[$n] // {}) + {ok:false, http:($c|tonumber? // 0), at:$at, error:$e}')"
  hook_record "$n" "$rec"
  # No answer (curl failed, a timeout): the host may have started a build anyway.
  [ "$rc" = 0 ] || die "Hook $n: $err. Whether a build started is unknown: look at the host before triggering again"
  die "Hook $n did not start a build: $err"
}

# The contract's line: deployId<TAB>phase<TAB>state. The id is name@time of the last trigger,
# "none" when it was never triggered. Always final ("ready" after a 2xx, never "queued"):
# `deploys watch` waits on this line, and no later answer will ever tell it more.
hook_status() {
  local n="${1:-}"; hook_known "$n" || die "No hook named \"$n\""
  hook_state | jq -r --arg n "$n" '(.[$n] // null) as $s
    | if $s == null then ["none", "", "never triggered"]
      else ["\($n)@\($s.at)", (if $s.ok then "ready" else "failed" end), (if $s.ok then "triggered" else "trigger failed" end)] end | @tsv'
}
hook_latest() { hook_status "$1"; }
# deploys hook status <name>: as JSON, for people and scripts, with the phase the list shows
# (queued for a while after a trigger, see hook_queued_secs).
hook_cli_status() {
  local n="${1:-}"; hook_known "$n" || die "No hook named \"$n\""
  hook_state | jq -c --arg n "$n" --argjson now "$(date +%s)" --argjson qs "$(hook_queued_secs)" '(.[$n] // null) as $s | {name:$n,
    phase:(if $s == null then null elif $s.ok then (if ($now - $s.at) < $qs then "queued" else "ready" end) else "failed" end),
    state:(if $s == null then "never triggered" elif $s.ok then "triggered" else "trigger failed" end),
    at:($s.at // null), sha:($s.sha // null)}'
}
hook_cancel() { die "Deploy hook cannot cancel a build: there is no API behind it. Cancel it at the host."; }
hook_rollback() { die "Deploy hook cannot roll back: there is no API behind it. Roll back at the host."; }
hook_logs() { die "Deploy hook cannot show logs: there is no API behind it. The build log is at the host."; }

hook_url() {
  local n="${1:-}" s; hook_known "$n" || die "No hook named \"$n\""
  s="$(hook_entry "$n" | jq -r '.site // empty')"
  [ -n "$s" ] || die "Hook $n has no site address (deploys hook add $n - --site https://…)"
  echo "$s"
}

# Replace the stored URL, read from stdin (a new hook URL after rotating it at the host).
hook_set_key() {
  local n="${1:-}" u; hook_known "$n" || die "No hook named \"$n\". Add it: deploys hook add $n -"
  IFS= read -r u || true
  [ -n "$u" ] || die "Pipe the hook URL in: pbpaste | deploys hook set-key $n"
  hook_check_url "$u"; hook_url_save "$n" "$u"
  echo "URL of hook $n saved ($(hook_mask "$u"))."
}

# Its fields join `deploys doctor`, so each is named for the hook (no bare "ready").
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
    '{hookReady:($h | length > 0), hookStore:$store, hookCurl:$curl, hooks:$h}'
}

# ---------- commands ----------

hook_add() {
  local n="${1:-}" u="${2:-}" repo="" ref="" site="" method="" body="" headers='{}' h k v
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
        # A reference is the whole secret part: "$TOKEN", "${TOKEN}" or "<scheme> $TOKEN".
        local ref_re='^([A-Za-z]+ )?\$(\{[A-Za-z_][A-Za-z0-9_]*\}|[A-Za-z_][A-Za-z0-9_]*)$'
        if [[ "$k" =~ [Aa]uthorization|[Tt]oken|[Kk]ey|[Ss]ecret|[Pp]assword|[Cc]ookie ]] && ! [[ "$v" =~ $ref_re ]]; then
          die "The $k header looks like a secret. Put it in the environment and write a reference: --header '$k: Bearer \$TOKEN'"
        fi
        headers="$(echo "$headers" | jq -c --arg k "$k" --arg v "$v" '.[$k] = $v')";;
      *) die "Unknown option $1";;
    esac; shift
  done
  case "$method" in ""|POST|GET|PUT|PATCH) ;; *) die "--method is POST, GET, PUT or PATCH";; esac
  [ -z "$repo" ] || [[ "$repo" =~ ^[A-Za-z0-9_.-]+/[A-Za-z0-9_.-]+$ ]] || die "--repo is owner/name"
  [ -z "$site" ] || [[ "$site" =~ ^https?://[^[:space:]]+$ ]] || die "--site is an http(s) address"
  [ -z "$body" ] || echo "$body" | jq -e . >/dev/null 2>&1 || die "--body is JSON"
  # "-" reads the URL from stdin: it then stays out of the shell history.
  if [ "$u" = - ]; then IFS= read -r u || true; [ -n "$u" ] || die "No URL on stdin"; fi
  hook_check_url "$u"
  # An existing hook is updated, not replaced: what is not given again (method, headers, body,
  # repo, ref, site) stays as it was, and the answer names what was kept. Given headers are added
  # to the ones there.
  local old existed=0 kept
  old="$(hook_entry "$n")"; [ -n "$old" ] && existed=1; [ -n "$old" ] || old='{}'
  hook_url_save "$n" "$u"
  hook_list_raw | jq --arg n "$n" --arg m "$method" --argjson h "$headers" --arg b "$body" --arg r "$repo" --arg f "$ref" --arg s "$site" --argjson o "$old" '
      (($o.headers // {}) + $h) as $hs
      | map(select(.name != $n)) + [{name:$n, method:(if $m != "" then $m else ($o.method // "POST") end)}
        + (if ($hs | length) > 0 then {headers:$hs} else {} end)
        + (if $b != "" then {body:$b} elif $o.body then {body:$o.body} else {} end)
        + (if $r != "" then {repo:$r, ref:(if $f != "" then $f else ($o.ref // "main") end)}
           elif $o.repo then {repo:$o.repo, ref:(if $f != "" then $f else ($o.ref // "main") end)}
           elif $f != "" then {ref:$f} elif $o.ref then {ref:$o.ref} else {} end)
        + (if $s != "" then {site:$s} elif $o.site then {site:$o.site} else {} end)]
      | sort_by(.name)' | hook_write "$(hook_config)"
  if [ "$existed" = 1 ]; then
    kept="$(echo "$old" | jq -r --arg m "$method" --argjson h "$headers" --arg b "$body" --arg r "$repo" --arg f "$ref" --arg s "$site" '
      [ (if $m == "" and .method then "method \(.method)" else empty end),
        (((.headers // {}) | keys) - ($h | keys) | select(length > 0) | "headers \(join(", "))"),
        (if $b == "" and .body then "body" else empty end),
        (if $r == "" and .repo then "repo \(.repo)" else empty end),
        (if $f == "" and .ref then "ref \(.ref)" else empty end),
        (if $s == "" and .site then "site \(.site)" else empty end) ] | join("; ")')"
    echo "Hook $n updated ($(hook_mask "$u"))${kept:+; kept: $kept}."
  else echo "Hook $n added ($(hook_mask "$u"))."; fi
}

hook_remove() {
  local n="${1:-}"; [ -n "$n" ] || die "Usage: deploys hook remove <name>"
  hook_known "$n" || die "No hook named \"$n\""
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
    status) hook_cli_status "$@";;
    open|url) hook_url "$@";;
    set-key) hook_set_key "$@";;
    autodeploy-off|off) hook_off "$@";;
    cancel) hook_cancel;; rollback) hook_rollback;; logs) hook_logs;;
    doctor) hook_doctor;;
    meta) hook_meta;;
    *) die "Usage: deploys hook add|remove|list|deploy|set-key|json|doctor";;
  esac
}

# Commands people type that are not the contract's: deploys hook add|remove|list|deploy.
hook_cli_add() { hook_add "$@"; }
hook_cli_remove() { hook_remove "$@"; }
hook_cli_rm() { hook_remove "$@"; }
hook_cli_list() { hook_list; }
hook_cli_deploy() { hook_cli deploy "$@"; }

# Run directly: load deploys as a library. deploys sources this file again; HOOK_DIRECT keeps
# that inner load from running the commands a second time.
if [ "${BASH_SOURCE[0]}" = "$0" ] && [ -z "${HOOK_DIRECT:-}" ]; then
  HOOK_DIRECT=1
  _hook_args=("$@"); set --
  # shellcheck source=../deploys
  DEPLOYS_LIB=1 . "$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)/deploys"
  hook_cli ${_hook_args[@]+"${_hook_args[@]}"}
fi
