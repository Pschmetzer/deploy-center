#!/bin/bash
# Tests for providers/heroku.sh. No network and no account: curl, security and sleep are
# stand-ins (tests/lib/fake-curl.sh answers from tests/fixtures/heroku). Run: bash tests/providers/heroku.sh
set -uo pipefail
cd "$(dirname "$0")/../.." || exit 1
# The security stand-in reads stdin: never wait on a terminal.
exec </dev/null
fails=0
ok()   { echo "ok   $1"; }
fail() { echo "FAIL $1: $2"; fails=$((fails+1)); }
expect() { [ "$2" = "$3" ] && ok "$1" || fail "$1" "expected [$3], got [$2]"; }
has()  { case "$2" in *"$3"*) ok "$1" ;; *) fail "$1" "[$3] not in: $2" ;; esac; }

tmp="$(mktemp -d)"; trap 'rm -rf "$tmp"' EXIT
mkdir -p "$tmp/bin" "$tmp/real"
cp tests/lib/fake-curl.sh "$tmp/real/curl"
cat > "$tmp/bin/curl" <<'CURL'
#!/bin/bash
# Logs the arguments (headers included), the body and the key config, then answers like fake-curl.
cfg="$(cat)"; prev=""; body=""
for a in "$@"; do [ "$prev" = --data-binary ] && body="$(cat "${a#@}")"; prev="$a"; done
echo "args $*" >> "$CALLS"; [ -z "$body" ] || echo "body $body" >> "$CALLS"
printf '%s' "$cfg" | "$REAL_CURL" "$@"
# A header file asked for (-D): write what a real answer would carry.
prev=""; for a in "$@"; do [ "$prev" = -D ] && printf 'HTTP/2 200\r\nRateLimit-Remaining: 4321\r\n\r\n' > "$a"; prev="$a"; done
CURL
cat > "$tmp/bin/security" <<'SEC'
#!/bin/bash
echo "security $* STDIN[$(cat)]" >> "$CALLS"
case "$1" in find-generic-password) exit 44 ;; esac
exit 0
SEC
printf '#!/bin/bash\nexit 0\n' > "$tmp/bin/sleep"
chmod +x "$tmp/bin"/* "$tmp/real"/*
export PATH="$tmp/bin:$PATH" REAL_CURL="$tmp/real/curl" FIXTURES="$PWD/tests/fixtures" CALLS="$tmp/calls.log" DEPLOYS_CONFIG="$tmp/config" USER=tester
export HEROKU_API_KEY="hk_secret_key_123"
: > "$CALLS"
# shellcheck source=../../providers/heroku.sh
. ./providers/heroku.sh

R=3f1b8d9a-0001-4a2e-8c3b-5d6e7f8a9b01
expect "meta: no push switch, no cancel, rollback and logs yes" "$(heroku_meta | jq -c '[.id, .keyEnv[0], .caps.off, .caps.cancel, .caps.rollback, .caps.logs]')" '["heroku","HEROKU_API_KEY",false,false,true,true]'
j="$(heroku_json)"
expect "json: phases from the newest release" "$(echo "$j" | jq -cS 'map({(.name): .phase}) | add')" '{"alpha":"ready","beta":"building","delta":null,"epsilon":"ready","gamma":"failed"}'
expect "json: the sha comes from the newest succeeded deploy release" "$(echo "$j" | jq -c '.[] | select(.name == "alpha") | [.lastSha, .lastMsg, .url, .dashboardUrl]')" '["9f8e7d6","Deploy 9f8e7d6","https://alpha-1a2b3c4d5e6f.herokuapp.com","https://dashboard.heroku.com/apps/alpha"]'
expect "json: a release that is not a deploy gives no sha" "$(echo "$j" | jq -c '.[] | select(.name == "epsilon") | [.lastSha, .lastMsg, .paused]')" '[null,"Initial release",true]'
expect "json: a pending first release has no live sha" "$(echo "$j" | jq -c '.[] | select(.name == "beta") | .lastSha')" "null"
expect "json: fractions in a timestamp are read" "$(echo "$j" | jq -c '.[] | select(.name == "beta") | .lastAt')" "1772449200"
expect "has: prints the name, unknown is 1, odd names stay local" "$(heroku_has alpha):$(heroku_has nope >/dev/null; echo $?):$(: > "$CALLS"; heroku_has 'A/b' >/dev/null; echo $?):$(grep -c '^args' "$CALLS")" "alpha:1:1:0"

# Every call carries the version header; lists carry a Range; nothing carries the key in an argument.
: > "$CALLS"; heroku_latest alpha >/dev/null
expect "latest asks for one release, newest first" "$(grep -c 'Range: version ..; order=desc,max=1' "$CALLS")" "1"
expect "every call has the v3 Accept header" "$(grep -c 'Accept: application/vnd.heroku+json; version=3' "$CALLS")" "$(grep -c '^args' "$CALLS")"
expect "the key is in no argument" "$(grep -c 'hk_secret_key_123' "$CALLS")" "0"
expect "latest: succeeded and the dynos up is ready" "$(heroku_latest alpha | cut -f2,3)" "$(printf 'ready\tsucceeded')"
expect "latest: an app without a release is none" "$(heroku_latest delta)" "$(printf 'none\t\tnone')"
expect "status: a release id" "$(heroku_status alpha "$R" | cut -f1,2)" "$(printf '%s\tready' "$R")"
expect "status: an odd id is refused before a call" "$( : > "$CALLS"; (heroku_status alpha '../x') >/dev/null 2>&1; echo $?:"$(grep -c '^args' "$CALLS")")" "1:0"

# A release that succeeded while its dynos start (or crash) is not ready yet.
rm -rf "$tmp/fx"; cp -R tests/fixtures "$tmp/fx"; export FIXTURES="$tmp/fx"
printf '%s\n200\n' '[{"id":"d-1","type":"web","state":"starting"}]' > "$tmp/fx/heroku/GET_apps_alpha_dynos.json"
expect "status: dynos still starting means building" "$(heroku_status alpha "$R" | cut -f2,3)" "$(printf 'building\tstarting')"
printf '%s\n200\n' '[{"id":"d-1","type":"web","state":"crashed"}]' > "$tmp/fx/heroku/GET_apps_alpha_dynos.json"
expect "status: crashed dynos mean failed" "$(heroku_status alpha "$R" | cut -f2,3)" "$(printf 'failed\tcrashed')"
export FIXTURES="$PWD/tests/fixtures"

# deploy = restart the dynos; the id is the live release.
: > "$CALLS"
d="$(heroku_deploy_json alpha)"
expect "deploy: the live release is the id" "$(echo "$d" | jq -c '[.id, .phase, .state]')" "[\"$R\",\"building\",\"restarting\"]"
expect "deploy: one restart, a DELETE on the dynos" "$(grep -c '^curl DELETE .*/apps/alpha/dynos' "$CALLS"):$(grep -c '^curl POST' "$CALLS")" "1:0"
for o in --sha --preview --no-cache; do
  : > "$CALLS"; msg="$( (heroku_deploy_json alpha $o x) 2>&1 )"
  has "deploy $o is refused" "$msg" "Heroku cannot"
  expect "deploy $o sends nothing" "$(grep -c '^curl' "$CALLS")" "0"
done
expect "deploy: an app without a release has nothing to restart" "$( (heroku_deploy_json delta) 2>&1 | grep -c 'nothing to restart')" "1"

# rollback: a new release from the next older one that succeeded and has code (v6 has none).
: > "$CALLS"
rb="$(heroku_rollback alpha)"
expect "rollback: names the new release" "$(echo "$rb" | jq -c '[.phase, .version, .message]')" '["building",8,"Heroku: alpha is going back to v5 (a new release)"]'
expect "rollback: the body names v5's release" "$(grep '^body ' "$CALLS" | sed 's/^body //' | jq -r '.release')" "3f1b8d9a-0003-4a2e-8c3b-5d6e7f8a9b03"
expect "rollback: an app with one release has nowhere to go" "$( (heroku_rollback epsilon) 2>&1 | grep -c 'no earlier release')" "1"

# logs: the end of the newest build, line breaks trimmed
expect "logs: the last two lines" "$(heroku_logs alpha 2 | tr '\n' '|')" "-----> Node.js app detected|-----> Build succeeded!|"
expect "logs: lines must be a number" "$( (heroku_logs alpha x) >/dev/null 2>&1; echo $?)" "1"
expect "logs: an app with no build says so" "$( (heroku_logs beta 5) 2>&1 | grep -c 'no build with a log')" "1"
expect "url" "$(heroku_url alpha)" "https://alpha-1a2b3c4d5e6f.herokuapp.com"
expect "url --dashboard" "$(heroku_url alpha --dashboard)" "https://dashboard.heroku.com/apps/alpha"

for f in "heroku_off alpha" "heroku_cancel alpha x"; do
  : > "$CALLS"; msg="$( ($f) 2>&1 )"; rc=$?
  expect "$f is refused: $rc, nothing sent" "$rc:$(grep -c '^curl' "$CALLS")" "1:0"
  has "$f says so" "$msg" "Heroku cannot"
done

# errors: the host's message is kept; a refused key is said
rm -rf "$tmp/fx"; cp -R tests/fixtures "$tmp/fx"; export FIXTURES="$tmp/fx"
printf '%s\n422\n' '{"id":"invalid_params","message":"Release not found"}' > "$tmp/fx/heroku/POST_apps_alpha_releases.json"
expect "rollback: Heroku's own message comes through" "$( (heroku_rollback alpha) 2>&1 | grep -c 'HTTP 422 (Heroku refused it): Release not found')" "1"
export FIXTURES="$PWD/tests/fixtures"
expect "a 401 names the fix" "$( (CURLSTUB=401 heroku_json) 2>&1 | grep -c 'check HEROKU_API_KEY')" "1"

# set-key
: > "$CALLS"
expect "set-key saves a working key" "$(printf 'hk_new\n' | heroku_set_key 2>&1 | tail -n 1)" "Heroku key saved and working."
expect "set-key: the key went to security on stdin" "$(grep -c '^security -i STDIN\[add-generic-password .* -s deploy-center-heroku -w hk_new\]' "$CALLS")" "1"
expect "set-key: and was in no curl argument" "$(grep '^args' "$CALLS" | grep -c hk_new)" "0"
: > "$CALLS"
expect "set-key refuses a key Heroku does not take" "$(printf 'hk_bad\n' | CURLSTUB=401 heroku_set_key 2>&1 | grep -c 'nothing was saved'):$(grep -c '^security -i' "$CALLS")" "1:0"
expect "set-key refuses a space or a quote" "$(printf 'a b\n' | heroku_set_key 2>&1 | grep -c 'does not look like'):$(printf 'a"b\n' | heroku_set_key 2>&1 | grep -c 'does not look like')" "1:1"

doc="$(heroku_doctor)"
expect "doctor: the key, the count and the rate limit from the header" "$(echo "$doc" | jq -c '[.key, .keyOk, .apps, .expiresAt, .rateLimit]')" '["env",true,5,null,{"remaining":4321,"resetAt":null}]'
expect "doctor: a refused key is reported" "$(CURLSTUB=401 heroku_doctor | jq -c '[.keyOk, (.error | length > 0)]')" "[false,true]"
expect "ratelimit: no header is null" "$(printf 'HTTP/2 200\r\n\r\n' > "$tmp/h"; heroku_ratelimit "$tmp/h")" "null"

echo
[ "$fails" = 0 ] && echo "All Heroku tests passed." || { echo "$fails failed."; exit 1; }
