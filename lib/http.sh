# shellcheck shell=bash
# lib/http.sh — one HTTP call to a platform API, for providers/*.sh (PRV-130). The rules each
# provider copied: the secret header goes to curl on stdin (never in the process list), 10 s to
# connect and 60 s in all, 429 asked again (after the Retry-After it names), 5xx and no answer
# asked again for reads and for calls that can be repeated (PUT, PATCH, DELETE), never for a POST
# (one that timed out may have started a build), and an error that says what to do.
#
#   http_call <label> <method> <url> [<json body>]
#     HTTP_AUTH  the header line, e.g. "Authorization: Bearer <key>" (a shell variable, not exported)
#     HTTP_FIX   what to do on 401/403, e.g. "deploys render set-key"
#     HTTP_HEADERS  a file: the response headers of the last try go there (rate limits, Link)
#     HTTP_MAX_TIME seconds for one try (default 60; a large upload needs more)
#   A body "@<file>" is read from that file as it is (large or binary payloads); a JSON body
#   never starts with "@".
# Prints the body on 2xx; otherwise dies with "<label> <method> <path> -> HTTP <code> (<hint>): <body>".
# Sourced by deploys, so the providers it loads have it. A provider run on its own:
#   . "$(dirname "$0")/../lib/http.sh"

declare -F die >/dev/null 2>&1 || die() { echo "Error: $*" >&2; exit 1; }

# A value inside a curl config line ("..."): backslash and quote escaped, as curl reads it. A line
# break (or any other control character) would end the line and start a directive of its own, so
# it is refused (status 1) - and the caller says so without printing the value.
curl_cfg_quote() {  # curl_cfg_quote <value>
  case "$1" in *[[:cntrl:]]*) return 1 ;; esac
  local v="${1//\\/\\\\}"; v="${v//\"/\\\"}"
  printf '%s' "$v"
}

# A URL for curl's config on stdin (`curl -K -`): a signed URL holds its secret in the query, and
# `ps` shows every argument. Status 1 for a URL with a line break in it.
curl_url_cfg() {  # curl_url_cfg <url>
  local q; q="$(curl_cfg_quote "$1")" || return 1
  printf 'url = "%s"\n' "$q"
}

# Functions the parallel readers (xargs bash -c) need are named with par_fn and exported by xargs_par for that one
# xargs only (not for the whole script: a BASH_FUNC_* variable in every child process, git and the user's hooks too).
# deploys defines the same two before it loads this; they are here for a provider run on its own.
declare -F par_fn >/dev/null 2>&1 || {
  PAR_FNS=()
  par_fn() { PAR_FNS=(${PAR_FNS[@]+"${PAR_FNS[@]}"} "$@"); }
  xargs_par() {
    (
      local f
      # shellcheck disable=SC2163  # the name is in $f on purpose: export -f of each function par_fn named
      for f in ${PAR_FNS[@]+"${PAR_FNS[@]}"}; do ! declare -F "$f" >/dev/null 2>&1 || export -f "$f"; done
      exec xargs "$@"
    )
  }
}

# How many reads run at once in a list: DEPLOYS_PARALLEL (1 to 32), else the default the caller names.
# One place for amplify, coolify, digitalocean and render (a rate limit is hit by the sum of them).
parallel_limit() {  # parallel_limit <default>
  local n="${DEPLOYS_PARALLEL:-$1}"
  case "$n" in ""|*[!0-9]*) n="$1" ;; esac
  [ "$n" -ge 1 ] 2>/dev/null || n="$1"; [ "$n" -le 32 ] || n=32
  printf '%s' "$n"
}

# The seconds a Retry-After header asks for: a number ("30") or a date ("Wed, 21 Oct 2026 07:28:00
# GMT", as seconds from now), or nothing. Not capped here: http_call stops when it is over a minute.
http_retry_after() {  # http_retry_after <header file>
  [ -r "$1" ] || return 0
  local v; v="$(tr -d '\r' < "$1" 2>/dev/null | awk 'tolower($1) == "retry-after:" { $1 = ""; sub(/^ +/, ""); print }' | tail -n 1)"
  case "$v" in
    "") return 0 ;;
  esac
  # A plain number: no leading zeros (08 is no number to bash arithmetic) and no more digits than it can count (such a
  # wait is far over a minute anyway, and the callers' [ -gt ] must be able to read it).
  case "$v" in *[!0-9]*) ;; *) v="${v#"${v%%[!0]*}"}"; [ -n "$v" ] || v=0; [ "${#v}" -le 9 ] || v=999999999 ;; esac
  case "$v" in
    *[!0-9]*) local t now   # the date form: GNU date -d, BSD date -j -f
      t="$(LC_ALL=C date -u -d "$v" +%s 2>/dev/null || LC_ALL=C date -j -u -f '%a, %d %b %Y %H:%M:%S GMT' "$v" +%s 2>/dev/null)" || return 0
      [ -n "$t" ] || return 0
      now="$(date +%s)"; v=$((t - now)); [ "$v" -ge 0 ] || v=0 ;;
  esac
  printf '%s' "$v"
}

# One line per call on stderr when DEPLOYS_HTTP_TRACE is set: method, path (no query: a query can
# hold a token), status and milliseconds. Never a header, never a body.
http_trace() {  # http_trace <method> <url> <code> <start seconds-ms>
  [ -n "${DEPLOYS_HTTP_TRACE:-}" ] || return 0
  local rest="${2#*://}" path ms
  path="/${rest#*/}"; [ "$rest" != "${rest#*/}" ] || path="/"; path="${path%%[?#]*}"
  ms="$(( ($(date +%s) - $4) * 1000 ))"
  printf 'http: %s %s -> %s (~%s ms)\n' "$1" "$path" "$3" "$ms" >&2
}

# 404: what kind of thing was not found, from the path (/services/srv-1 -> service "srv-1").
http_notfound_hint() {  # http_notfound_hint <path without query>
  local p="${1%/}" id kind
  id="${p##*/}"; p="${p%/*}"; kind="${p##*/}"
  case "$kind" in ""|v[0-9]*|api) echo " (not found: the path $1; renamed or deleted?)"; return ;; esac
  kind="${kind%s}"
  echo " (not found: no $kind \"$id\"; renamed or deleted?)"
}

http_call() {
  local label="$1" method="$2" url="$3" body="${4:-}" out code try err hdr own="" wait bodyf="" rc t0 deadline limit_hit="" auth q
  # Under `bash -x` the trace would print the key (and the body): off for this call, on again at its end.
  local xt=""; case $- in *x*) xt=1; set +x ;; esac
  local args=(-sS --connect-timeout 10 --max-time "${HTTP_MAX_TIME:-60}" -X "$method" -H "Accept: application/json" -K -)
  auth="${HTTP_AUTH:-}"
  # The key goes into a curl config line: a quote or line break must not add directives, and an
  # error must not print what was typed (a key with a line break is a paste mistake, but still a key).
  q="$(curl_cfg_quote "$auth")" || die "$label: the key has a line break or control character in it (a paste mistake?): set it again without"
  case "$body" in
    "") ;;
    @*) [ -r "${body#@}" ] || die "$label: the body file ${body#@} cannot be read"
        args+=(-H "Content-Type: application/json" --data-binary "$body") ;;
    # A JSON body goes in through a file of our own (0600), never as --data on the command line:
    # a body can hold a secret (an environment variable's value) and `ps` shows every argument.
    *) bodyf="$(umask 077; mktemp)"; printf '%s' "$body" > "$bodyf"
       args+=(-H "Content-Type: application/json" --data-binary "@$bodyf") ;;
  esac
  err="$(umask 077; mktemp)"
  # The headers are needed for Retry-After: a file of our own when the caller gave none.
  hdr="${HTTP_HEADERS:-}"; [ -n "$hdr" ] || { hdr="$(umask 077; mktemp)"; own=1; }
  args+=(-D "$hdr")
  # Ctrl-C or kill: the files (a body can hold a secret) go, then the signal's exit status.
  local old_int old_term; old_int="$(trap -p INT)"; old_term="$(trap -p TERM)"
  # shellcheck disable=SC2064  # the file names are fixed now on purpose
  trap "rm -f '$err' '$bodyf' ${own:+'$hdr'}; exit 130" INT
  # shellcheck disable=SC2064
  trap "rm -f '$err' '$bodyf' ${own:+'$hdr'}; exit 143" TERM
  t0="$(date +%s)"; deadline="${HTTP_DEADLINE:-120}"
  for try in 1 2 3; do
    rc=0
    out="$(printf 'header = "%s"\n' "$q" | curl "${args[@]}" -w '\n%{http_code}' "$url" 2>"$err")" || { rc=$?; out=$'\n000'; }
    code="${out##*$'\n'}"; out="${out%$'\n'*}"
    # How long to wait before the next try, and whether the whole budget allows another one.
    wait=""
    case "$code" in
      429) wait="$(http_retry_after "$hdr")"
           if [ -n "$wait" ] && [ "$wait" -gt 60 ]; then limit_hit="$wait"; break; fi
           [ "$try" -lt 3 ] && { wait="${wait:-$((try * 3 + RANDOM % 3))}"; } ;;
      5*|000)
        if [ "$try" -lt 3 ]; then
          case "$method" in
            GET|PUT|PATCH|DELETE) wait="$(http_retry_after "$hdr")"; wait="${wait:-$((try * 2 + RANDOM % 2))}" ;;
            # A POST is asked again only when nothing can have arrived: curl 6 (host not found) or 7 (no connection).
            *) case "$rc" in 6|7) wait=$((try * 2)) ;; esac ;;
          esac
        fi ;;
    esac
    [ -n "$wait" ] || break
    # The budget for all tries together: no sleeping past it.
    if [ "$(( $(date +%s) - t0 + wait ))" -gt "$deadline" ]; then break; fi
    sleep "$wait"
  done
  http_trace "$method" "$url" "$code" "$t0"
  [ "$code" != 000 ] || out="$(tail -n 1 "$err")"
  rm -f "$err" ${bodyf:+"$bodyf"}; [ -z "$own" ] || rm -f "$hdr"
  trap - INT TERM; [ -z "$old_int" ] || eval "$old_int"; [ -z "$old_term" ] || eval "$old_term"
  if [[ "$code" != 2* ]]; then
    local hint="" rest="${url#*://}" path
    path="/${rest#*/}"; [ "$rest" != "${rest#*/}" ] || path="/"
    case "$code" in
      000) hint=" (no answer: network or timeout)" ;;
      401|403) hint=" (the key is wrong or expired${HTTP_FIX:+: $HTTP_FIX})" ;;
      404) hint="$(http_notfound_hint "${path%%[?#]*}")" ;;
      429) if [ -n "$limit_hit" ]; then hint=" (rate limit: the server asks to wait ${limit_hit} s; try again later)"
           else hint=" (rate limit: try again in a minute)"; fi ;;
      5*) hint=" ($label had a problem: try again later)" ;;
    esac
    # One line, 300 characters: an error page (HTML) must not fill the terminal. A secret the
    # platform echoes back (a token in an error message) is masked like a log is.
    if declare -F af_mask >/dev/null 2>&1; then out="$(printf '%s' "$out" | af_mask 2>/dev/null)" || out="(the answer is not shown: it could not be masked)"; fi
    out="$(printf '%s' "$out" | tr '\r\n\t' '   ' | cut -c1-300)"
    die "$label $method $path -> HTTP $code$hint: $out"
  fi
  [ -z "$xt" ] || set -x  # secrets-ok: restores a trace the caller had on
  printf '%s' "$out"
}
