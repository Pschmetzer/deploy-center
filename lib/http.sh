# shellcheck shell=bash
# lib/http.sh — one HTTP call to a platform API, for providers/*.sh (PRV-130). The rules each
# provider copied: the secret header goes to curl on stdin (never in the process list), 10 s to
# connect and 60 s in all, 429 asked again, 5xx and no answer asked again for reads only (a POST
# that timed out may have started a build), and an error that says what to do.
#
#   http_call <label> <method> <url> [<json body>]
#     HTTP_AUTH  the header line, e.g. "Authorization: Bearer <key>" (a shell variable, not exported)
#     HTTP_FIX   what to do on 401/403, e.g. "deploys render set-key"
#     HTTP_HEADERS  a file: the response headers of the last try go there (rate limits, Link)
#   A body "@<file>" is read from that file as it is (large or binary payloads); a JSON body
#   never starts with "@".
# Prints the body on 2xx; otherwise dies with "<label> <method> <path> -> HTTP <code> (<hint>): <body>".
# Sourced by deploys, so the providers it loads have it. A provider run on its own:
#   . "$(dirname "$0")/../lib/http.sh"

declare -F die >/dev/null 2>&1 || die() { echo "Error: $*" >&2; exit 1; }

http_call() {
  local label="$1" method="$2" url="$3" body="${4:-}" out code try err
  local args=(-sS --connect-timeout 10 --max-time 60 -X "$method" -H "Accept: application/json" -K -)
  case "$body" in
    "") ;;
    @*) [ -r "${body#@}" ] || die "$label: the body file ${body#@} cannot be read"
        args+=(-H "Content-Type: application/json" --data-binary "$body") ;;
    *) args+=(-H "Content-Type: application/json" --data "$body") ;;
  esac
  [ -z "${HTTP_HEADERS:-}" ] || args+=(-D "$HTTP_HEADERS")
  err="$(mktemp)"
  for try in 1 2 3; do
    out="$(printf 'header = "%s"\n' "${HTTP_AUTH:-}" | curl "${args[@]}" -w '\n%{http_code}' "$url" 2>"$err")" || out=$'\n000'
    code="${out##*$'\n'}"; out="${out%$'\n'*}"
    case "$code" in
      429) [ "$try" -lt 3 ] && { sleep $((try * 3)); continue; } ;;
      5*|000) [ "$method" = GET ] && [ "$try" -lt 3 ] && { sleep $((try * 2)); continue; } ;;
    esac
    break
  done
  [ "$code" != 000 ] || out="$(tail -n 1 "$err")"
  rm -f "$err"
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
    die "$label $method $path -> HTTP $code$hint: $out"
  fi
  printf '%s' "$out"
}
