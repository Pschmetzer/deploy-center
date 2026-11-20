#!/bin/bash
# Tests for providers/fly.sh. No network and no account: curl, security and sleep are stand-ins
# (tests/lib/fake-curl.sh answers from tests/fixtures/fly). Run: bash tests/providers/fly.sh
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
mkdir -p "$tmp/bin"
cp tests/lib/fake-curl.sh "$tmp/bin/curl"
cat > "$tmp/bin/security" <<'SEC'
#!/bin/bash
echo "security $* STDIN[$(cat)]" >> "$CALLS"
case "$1" in find-generic-password) exit 44 ;; esac
exit 0
SEC
printf '#!/bin/bash\nexit 0\n' > "$tmp/bin/sleep"
chmod +x "$tmp/bin"/*
export PATH="$tmp/bin:$PATH" FIXTURES="$PWD/tests/fixtures" CALLS="$tmp/calls.log" DEPLOYS_CONFIG="$tmp/config" USER=tester
export FLY_API_TOKEN="fm_secret_token_123" FLY_ORG=fixture-org
: > "$CALLS"
# shellcheck source=../../providers/fly.sh
. ./providers/fly.sh

expect "meta is one valid line with the token variable" "$(fly_meta | jq -c '[.id, .keyEnv[0], .defaultOn]')" '["fly","FLY_API_TOKEN",false]'
expect "json: phases from the machines" "$(fly_json | jq -c 'map({(.name): .phase}) | add')" '{"alpha":"ready","beta":"building","delta":null,"gamma":"failed"}'
expect "json: one app, the url and dashboard" "$(fly_json | jq -r '.[] | select(.name == "alpha") | "\(.url) \(.dashboardUrl) \(.lastMsg)"')" "https://alpha.fly.dev https://fly.io/apps/alpha release v7"
expect "json: an app without machines is not paused or failed" "$(fly_json | jq -c '.[] | select(.name == "delta") | [.paused, .fetchError]')" "[false,null]"
expect "json: nothing is switched off (no push build on Fly)" "$(fly_json | jq -c 'map(.auto) | unique')" "[false]"
expect "has: prints the name" "$(fly_has alpha)" "alpha"
expect "has: an unknown app is rc 1" "$(fly_has nope >/dev/null; echo $?)" "1"
expect "has: odd names never reach the API" "$(: > "$CALLS"; fly_has 'a/b' >/dev/null; grep -c '^curl' "$CALLS")" "0"

: > "$CALLS"
d="$(fly_deploy_json alpha)"
expect "deploy: restarts both running machines, first one is the id" "$(echo "$d" | jq -c '[.id, .machines, .phase]')" '["e2865e1a3b0c08",2,"building"]'
expect "deploy: two POSTs, one per machine" "$(grep -c '^curl POST .*/machines/[a-z0-9]*/restart' "$CALLS")" "2"
expect "deploy: only started machines are restarted" "$(: > "$CALLS"; ( fly_deploy_json beta ) >/dev/null 2>&1; echo $?:"$(grep -c '^curl POST' "$CALLS")")" "1:0"
for o in --sha --preview --no-cache; do
  : > "$CALLS"; msg="$( (fly_deploy_json alpha $o x) 2>&1 )"; rc=$?
  has "deploy $o is refused" "$msg" "Fly.io cannot"
  expect "deploy $o sends nothing" "$(grep -c '^curl' "$CALLS")" "0"
done
expect "status: a started machine is ready" "$(fly_status alpha e2865e1a3b0c08 | cut -f2,3)" "$(printf 'ready\tstarted')"
expect "latest: the newest machine of the app" "$(fly_latest alpha | cut -f1)" "d8d4e1f6a7b219"
expect "latest: an app without machines is none" "$(fly_latest delta)" "$(printf 'none\t\t?')"
expect "status: an odd id is refused before a call" "$(: > "$CALLS"; (fly_status alpha '../x') >/dev/null 2>&1; echo $?:"$(grep -c '^curl' "$CALLS")")" "1:0"
expect "url" "$(fly_url alpha)" "https://alpha.fly.dev"

# The token travels on stdin only: never in the log of curl's arguments (the stand-in logs method and URL).
expect "the token is not in any logged call" "$(grep -c 'fm_secret_token_123' "$CALLS")" "0"

# set-key: tried first, then saved through `security -i` (the token on stdin, never an argument).
: > "$CALLS"
expect "set-key saves a working token" "$(printf 'fm_new_token\n' | fly_set_key 2>&1 | tail -n 1)" "Fly.io token saved and working."
expect "set-key: the token went to security on stdin" "$(grep -c '^security -i STDIN\[add-generic-password .* -s deploy-center-fly -w fm_new_token\]' "$CALLS")" "1"
expect "set-key: and was in no argument" "$(grep -c '^security add' "$CALLS"):$(grep '^curl' "$CALLS" | grep -c fm_new_token)" "0:0"
: > "$CALLS"
expect "set-key refuses a token Fly.io does not take" "$(printf 'fm_bad\n' | CURLSTUB=401 fly_set_key 2>&1 | tail -n 1 | grep -c 'nothing was saved'):$(grep -c '^security -i' "$CALLS")" "1:0"
expect "set-key refuses a token with a quote" "$(printf 'a"b\n' | fly_set_key 2>&1 | grep -c 'does not look like')" "1"
expect "set-key refuses a space inside" "$(printf 'fm a\n' | fly_set_key 2>&1 | grep -c 'does not look like')" "1"

# What Fly.io cannot do is refused without a call.
for f in "fly_off alpha" "fly_cancel alpha x" "fly_rollback alpha" "fly_logs alpha 10"; do
  : > "$CALLS"; msg="$( ($f) 2>&1 )"; rc=$?
  expect "$f is refused: $rc, nothing sent" "$rc:$(grep -c '^curl' "$CALLS")" "1:0"
  has "$f says so" "$msg" "Fly.io cannot"
done

doc="$(fly_doctor)"
expect "doctor: key works, org and count" "$(echo "$doc" | jq -c '[.key, .keyOk, .org, .apps, .expiresAt, .rateLimit]')" '["env",true,"fixture-org",4,null,null]'
expect "doctor: a refused key is reported, not hidden" "$(CURLSTUB=401 fly_doctor | jq -c '[.keyOk, (.error | length > 0)]')" "[false,true]"
expect "an organization with a bad slug is refused" "$(FLY_ORG='a/b' fly_org 2>&1)" 'Fly.io: "a/b" is not an organization slug'

echo
[ "$fails" = 0 ] && echo "All Fly.io tests passed." || { echo "$fails failed."; exit 1; }
