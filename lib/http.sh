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

# The seconds a Retry-After header asks for (a number, at most 60), or nothing.
http_retry_after() {  # http_retry_after <header file>
  [ -r "$1" ] || return 0
  local v; v="$(tr -d '\r' < "$1" 2>/dev/null | awk 'tolower($1) == "retry-after:" { print $2 }' | tail -n 1)"
  case "$v" in ""|*[!0-9]*) return 0 ;; esac
  [ "$v" -le 60 ] || v=60
  printf '%s' "$v"
}

http_call() {
  local label="$1" method="$2" url="$3" body="${4:-}" out code try err hdr own="" wait bodyf=""
  local args=(-sS --connect-timeout 10 --max-time "${HTTP_MAX_TIME:-60}" -X "$method" -H "Accept: application/json" -K -)
  case "$body" in
    "") ;;
    @*) [ -r "${body#@}" ] || die "$label: the body file ${body#@} cannot be read"
        args+=(-H "Content-Type: application/json" --data-binary "$body") ;;
    # A JSON body goes in through a file of our own (0600), never as --data on the command line:
    # a body can hold a secret (an environment variable's value) and `ps` shows every argument.
    *) bodyf="$(mktemp)"; printf '%s' "$body" > "$bodyf"
       args+=(-H "Content-Type: application/json" --data-binary "@$bodyf") ;;
  esac
  err="$(mktemp)"
  # The headers are needed for Retry-After: a file of our own when the caller gave none.
  hdr="${HTTP_HEADERS:-}"; [ -n "$hdr" ] || { hdr="$(mktemp)"; own=1; }
  args+=(-D "$hdr")
  for try in 1 2 3; do
    out="$(printf 'header = "%s"\n' "${HTTP_AUTH:-}" | curl "${args[@]}" -w '\n%{http_code}' "$url" 2>"$err")" || out=$'\n000'
    code="${out##*$'\n'}"; out="${out%$'\n'*}"
    case "$code" in
      429) if [ "$try" -lt 3 ]; then wait="$(http_retry_after "$hdr")"; sleep "${wait:-$((try * 3 + RANDOM % 3))}"; continue; fi ;;
      5*|000) case "$method" in GET|PUT|PATCH|DELETE) if [ "$try" -lt 3 ]; then wait="$(http_retry_after "$hdr")"; sleep "${wait:-$((try * 2 + RANDOM % 2))}"; continue; fi ;; esac ;;
    esac
    break
  done
  [ "$code" != 000 ] || out="$(tail -n 1 "$err")"
  rm -f "$err" ${bodyf:+"$bodyf"}; [ -z "$own" ] || rm -f "$hdr"
  if [[ "$code" != 2* ]]; then
    local hint="" rest="${url#*://}" path
    path="/${rest#*/}"; [ "$rest" != "${rest#*/}" ] || path="/"
    case "$code" in
      000) hint=" (no answer: network or timeout)" ;;
      401|403) hint=" (the key is wrong or expired${HTTP_FIX:+: $HTTP_FIX})" ;;
      404) hint=" (not found: renamed or deleted?)" ;;
      429) hint=" (rate limit: try again in a minute)" ;;
      5*) hint=" ($label had a problem: try again later)" ;;
    esac
    # One line, 300 characters: an error page (HTML) must not fill the terminal.
    out="$(printf '%s' "$out" | tr '\r\n\t' '   ' | cut -c1-300)"
    die "$label $method $path -> HTTP $code$hint: $out"
  fi
  printf '%s' "$out"
}
