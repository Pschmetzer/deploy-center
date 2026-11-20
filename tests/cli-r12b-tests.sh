#!/bin/bash
# Tests for the CLI and provider fixes of round 12, part B (docs/IDEEN-12.md): lib/http.sh, the hook
# provider, completion, watch, verify, release.sh and the small helpers. No network, no real projects.
set -uo pipefail
cd "$(dirname "$0")/.." || exit 1
exec </dev/null
fails=0
ok()   { echo "ok   $1"; }
fail() { echo "FAIL $1: $2"; fails=$((fails+1)); }
expect() { [ "$2" = "$3" ] && ok "$1" || fail "$1" "expected [$3], got [$2]"; }

tmp="$(mktemp -d)"; trap 'rm -rf "$tmp"' EXIT
export DEPLOYS_CONFIG="$tmp/config" HOME="$tmp/home" NO_COLOR=1 DEPLOYS_LIB=1 DEPLOYS_TESTING=1 DEPLOYS_JOURNAL="$tmp/journal.jsonl"
mkdir -p "$HOME" "$DEPLOYS_CONFIG" "$tmp/bin"
printf '#!/bin/bash\nexit 1\n' > "$tmp/bin/gh"; chmod +x "$tmp/bin/gh"
printf '#!/bin/bash\nexit 0\n' > "$tmp/bin/sleep"; chmod +x "$tmp/bin/sleep"
export PATH="$tmp/bin:$PATH"
# shellcheck source=../deploys
. ./deploys
set +e
cli() { env -u DEPLOYS_LIB bash ./deploys "$@"; }

# --- lib/http.sh: a curl stand-in that answers from $HTTP_MODE and logs what it got ---
cat > "$tmp/bin/curl" <<'C'
#!/bin/bash
k="$(cat)"; echo "$*|$k" >> "$HTTP_LOG"
hf=""; p=""; for a in "$@"; do [ "$p" = -D ] && hf="$a"; p="$a"; done
n="$(wc -l < "$HTTP_LOG" | tr -d ' ')"
case "$HTTP_MODE" in
  ok) printf '%s\n200' '{"ok":true}' ;;
  date429) printf 'HTTP/1.1 429\r\nRetry-After: Wed, 21 Oct 2099 07:28:00 GMT\r\n\r\n' > "$hf"; printf '%s\n429' 'slow' ;;
  num429) printf 'HTTP/1.1 429\r\nRetry-After: 2\r\n\r\n' > "$hf"; printf '%s\n429' 'slow' ;;
  exit6) echo "curl: (6) Could not resolve host" >&2; exit 6 ;;
  exit6then) if [ "$n" = 1 ]; then echo "curl: (6) Could not resolve host" >&2; exit 6; fi; printf '%s\n200' '{"ok":true}' ;;
  html) printf '<html>502</html>\n502' ;;
  leak) printf '%s\n500' '{"error":"bad token ghp_abcdefghijklmnop1234"}' ;;
  nf) printf '%s\n404' 'no' ;;
esac
C
chmod +x "$tmp/bin/curl"
hlog="$tmp/http.log"
hcall() {  # hcall <mode> <method> [url] [body]: output, then |rc
  ( export HTTP_LOG="$hlog" HTTP_MODE="$1"; : > "$hlog"; . ./lib/http.sh; HTTP_AUTH="${HTTP_AUTH-Authorization: Bearer sekret}"
    ( http_call X "$2" "${3:-https://api.x.test/v1/things}" "${4:-}" ) 2>&1; echo "|rc=$?" )
}
expect "curl_cfg_quote: quotes and backslashes are escaped" "$(. ./lib/http.sh; curl_cfg_quote 'a"b\c')" 'a\"b\\c'
expect "curl_cfg_quote: a line break is refused" "$(. ./lib/http.sh; curl_cfg_quote $'a\nurl = x' >/dev/null; echo $?)" "1"
out="$(HTTP_AUTH=$'Authorization: Bearer fragment123\nurl = x' hcall ok GET)"
expect "http_call: a key with a line break stops before curl, without the key" "$(echo "$out" | grep -c fragment123):$(echo "$out" | grep -c 'line break'):$(grep -c . "$hlog")" "0:1:0"
HTTP_AUTH='Authorization: Bearer a"b' hcall ok GET >/dev/null
expect "http_call: a quote in the key is escaped in the config line" "$(grep -c 'header = "Authorization: Bearer a\\"b"' "$hlog")" "1"
expect "http_call: Retry-After as a date far away stops with a hint (one try)" "$(hcall date429 GET | grep -c 'asks to wait'):$(wc -l < "$hlog" | tr -d ' ')" "1:1"
expect "http_call: Retry-After as a number is waited for and asked again" "$(hcall num429 GET >/dev/null; wc -l < "$hlog" | tr -d ' ')" "3"
expect "http_call: a POST is asked again when the host was not found (curl 6)" "$(hcall exit6then POST '' '{"a":1}' | head -n 1):$(wc -l < "$hlog" | tr -d ' ')" '{"ok":true}|rc=0:2'
expect "http_call: a POST after a timeout (curl 28 or a 5xx) is not asked again" "$(hcall html POST >/dev/null; wc -l < "$hlog" | tr -d ' ')" "1"
expect "http_call: a deadline of 0 allows no second try" "$(HTTP_DEADLINE=0 hcall exit6 GET >/dev/null; wc -l < "$hlog" | tr -d ' ')" "1"
expect "http_call: 404 names the kind of thing" "$(hcall nf GET https://a.test/v1/services/srv-1 | head -n 1)" 'Error: X GET /v1/services/srv-1 -> HTTP 404 (not found: no service "srv-1"; renamed or deleted?): no'
expect "http_call: an error body is masked like a log" "$(af_mask() { sed 's/ghp_[A-Za-z0-9]*/[masked]/g'; }; export -f af_mask; hcall leak GET | grep -c 'ghp_')" "0"
expect "http_call: DEPLOYS_HTTP_TRACE prints method, path, code; no query, no key" \
  "$(DEPLOYS_HTTP_TRACE=1 hcall ok GET 'https://a.test/v1/x?token=zzz' | grep -c '^http: GET /v1/x -> 200'):$(DEPLOYS_HTTP_TRACE=1 hcall ok GET 'https://a.test/v1/x?token=zzz' | grep -c 'zzz\|sekret')" "1:0"
# A temp file made for the call is gone when the call ends.
mkdir -p "$tmp/tt"; TMPDIR="$tmp/tt" hcall ok POST '' '{"x":"secret-body"}' >/dev/null; TMPDIR="$tmp/tt" hcall html GET >/dev/null
expect "http_call: no temp file is left behind" "$(ls "$tmp/tt" | wc -l | tr -d ' ')" "0"

# --- hook: userinfo, DNS, the lock after a failed trigger ---
expect "hook_check_url: https://evil.com@127.0.0.1/x is refused (user@host)" "$( ( hook_check_url 'https://evil.com@127.0.0.1/x' ) 2>&1 | grep -c 'user name')" "1"
expect "hook_check_url: https://user:pw@example.com/x is refused" "$( ( hook_check_url 'https://user:pw@example.com/x' ) >/dev/null 2>&1; echo $?)" "1"
hook_resolve() { case "$1" in rebind.example.com) echo 127.0.0.1 ;; ok.example.com) printf '2001:db8::1\n93.184.216.34\n' ;; esac; }
expect "hook_check_url: a name that resolves to 127.0.0.1 is refused" "$( ( hook_check_url 'https://rebind.example.com/x' ) 2>&1 | grep -c 'private or local')" "1"
expect "hook_check_url: --allow-private lets it through" "$( ( HOOK_ALLOW_PRIVATE=1 hook_check_url 'https://rebind.example.com/x' ) >/dev/null 2>&1; echo $?)" "0"
expect "hook_pin: pins the address that was checked (IPv4 first)" "$(hook_pin 'https://ok.example.com:8443/x')" 'resolve = "ok.example.com:8443:93.184.216.34"'
expect "hook_pin: nothing for an address in the URL" "$(hook_pin 'https://93.184.216.34/x')" ""
export DEPLOYS_HOOK_STORE=file
hook_add h1 'https://ok.example.com/hook/secret' --status-url 'https://ok.example.com/status' >/dev/null
expect "hook add: --status-url is stored" "$(hook_entry h1 | jq -r .statusUrl)" "https://ok.example.com/status"
cat > "$tmp/bin/curl" <<'C'
#!/bin/bash
cfg="$(cat)"; echo "$cfg" >> "$HTTP_LOG"
case "$cfg" in *"/status"*) printf '{"status":"BUILDING"}' ;; *) out="$(printf '%s\n' "$cfg" | sed -n 's/^output = "\(.*\)"$/\1/p')"; printf '' > "$out"; printf '%s' "${HOOK_CODE:-200}" ;; esac
C
: > "$hlog"; export HTTP_LOG="$hlog"
expect "hook status: a statusUrl says building" "$(hook_status h1 | cut -f2)" "building"
: > "$hlog"
expect "hook deploy: the config pins the checked address" "$( ( HOOK_CODE=200 hook_deploy_json h1 ) >/dev/null 2>&1; grep -c 'resolve = "ok.example.com:443:93.184.216.34"' "$hlog")" "1"
rm -rf "$DEPLOYS_CONFIG/locks"
( HOOK_CODE=401 hook_deploy_json h1 ) >/dev/null 2>&1
expect "hook deploy: a 401 leaves no one-minute lock" "$(ls "$DEPLOYS_CONFIG/locks" 2>/dev/null | wc -l | tr -d ' ')" "0"
( HOOK_CODE=503 hook_deploy_json h1 ) >/dev/null 2>&1
expect "hook deploy: a 503 keeps the lock (a build may have started)" "$(ls "$DEPLOYS_CONFIG/locks" 2>/dev/null | wc -l | tr -d ' ')" "1"

[ "$fails" = 0 ] && echo "All tests passed." || { echo "$fails failed."; exit 1; }
