# shellcheck shell=bash
# PRV-130 in the provider tests: http_stub defines http_call as deploys has it from lib/http.sh.
# With lib/http.sh in the tree (improve/cli merged) that file is used; else a stand-in with the
# same arguments and rules (key on stdin, die on non-2xx), so the providers' switch is tested on
# either branch. Every call is logged to $CALLS as "http_call <label> <method> <url> auth[..] fix[..]".
http_stub() {
  if [ -f lib/http.sh ]; then
    # shellcheck source=/dev/null
    . lib/http.sh
    eval "_real_$(declare -f http_call)"
  else
    _real_http_call() {
      local args=(-sS -X "$2" -H "Accept: application/json" -K -) out code
      [ -z "${4:-}" ] || args+=(-H "Content-Type: application/json" --data "$4")
      out="$(printf 'header = "%s"\n' "${HTTP_AUTH:-}" | curl "${args[@]}" -w '\n%{http_code}' "$3")" || out=$'\n000'
      code="${out##*$'\n'}"; out="${out%$'\n'*}"
      [[ "$code" == 2* ]] || die "$1 $2 ${3#*://*/} -> HTTP $code${HTTP_FIX:+ ($HTTP_FIX)}: $out"
      printf '%s' "$out"
    }
  fi
  http_call() {
    local a=other
    case "${HTTP_AUTH:-}" in 'Authorization: Bearer '?*) a=bearer ;; '') a=none ;; esac
    printf 'http_call %s %s %s auth[%s] fix[%s]\n' "$1" "$2" "$3" "$a" "${HTTP_FIX:+set}" >> "${CALLS:-/dev/null}"
    _real_http_call "$@"
  }
}
