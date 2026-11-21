#!/bin/bash
# Tests for providers/koyeb.sh. No network and no account: curl, security and sleep are stand-ins
# (tests/lib/fake-curl.sh answers from tests/fixtures/koyeb). Run: bash tests/providers/koyeb.sh
set -uo pipefail
cd "$(dirname "$0")/../.." || exit 1
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
export KOYEB_TOKEN="kyb_secret_token_123"
: > "$CALLS"
# shellcheck source=../../providers/koyeb.sh
. ./providers/koyeb.sh

expect "meta is one valid line with the token variable" "$(koyeb_meta | jq -c '[.id, .keyEnv[0], .defaultOn]')" '["koyeb","KOYEB_TOKEN",false]'
expect "json: phases from the newest deployment" "$(koyeb_json | jq -c 'map({(.name): .phase}) | add')" '{"alpha":"ready","beta":"building","delta":null,"gamma":"failed"}'
expect "json: id, dashboard and the newest deployment" "$(koyeb_json | jq -r '.[] | select(.name == "alpha") | "\(.id) \(.dashboardUrl) \(.latestId)"')" "svc-alpha https://app.koyeb.com/services/svc-alpha dep-alpha-3"
expect "json: a service without a state has no phase" "$(koyeb_json | jq -c '.[] | select(.name == "delta") | [.phase, .fetchError]')" "[null,null]"
expect "json: nothing counts as auto" "$(koyeb_json | jq -c 'map(.auto) | unique')" "[false]"
expect "has: prints the id" "$(koyeb_has alpha)" "svc-alpha"
expect "has: unknown is rc 1" "$(koyeb_has nope >/dev/null; echo $?)" "1"
expect "has: odd names never reach the API" "$(: > "$CALLS"; koyeb_has 'a/b' >/dev/null; grep -c '^curl' "$CALLS")" "0"

: > "$CALLS"
d="$(koyeb_deploy_json svc-alpha)"
expect "deploy: redeploys the service" "$(echo "$d" | jq -c '[.id, .phase]')" '["dep-alpha-4","building"]'
expect "deploy: one POST, the redeploy of the service" "$(grep -c '^curl POST .*/services/svc-alpha/redeploy' "$CALLS")" "1"
expect "deploy: a bad id sends no POST" "$(: > "$CALLS"; ( koyeb_deploy_json "a/b" ) >/dev/null 2>&1; echo $?:"$(grep -c '^curl POST' "$CALLS")")" "1:0"
for o in --sha --preview --no-cache; do
  : > "$CALLS"; msg="$( (koyeb_deploy_json svc-alpha $o x) 2>&1 )"
  has "deploy $o is refused" "$msg" "Koyeb cannot"
  expect "deploy $o sends nothing" "$(grep -c '^curl' "$CALLS")" "0"
done
expect "status: a finished deployment is ready" "$(koyeb_status svc-alpha dep-alpha-3 | cut -f2,3)" "$(printf 'ready\tHEALTHY')"
expect "latest: the newest deployment" "$(koyeb_latest svc-alpha | cut -f1)" "dep-alpha-3"
expect "latest: none without deployments" "$(koyeb_latest svc-delta)" "$(printf 'none\t\tnone')"
expect "status: an odd id is refused before a call" "$(: > "$CALLS"; (koyeb_status svc-alpha '../x') >/dev/null 2>&1; echo $?:"$(grep -c '^curl' "$CALLS")")" "1:0"
expect "url" "$(koyeb_url svc-alpha)" "https://app.koyeb.com/services/svc-alpha"
expect "the token is not in any logged call" "$(grep -c 'kyb_secret_token_123' "$CALLS")" "0"

: > "$CALLS"
expect "set-key saves a working token" "$(printf 'kyb_new_token\n' | koyeb_set_key 2>&1 | tail -n 1)" "Koyeb token saved and working."
expect "set-key: the token went to security on stdin" "$(grep -c '^security -i STDIN\[add-generic-password .* -s deploy-center-koyeb -w kyb_new_token\]' "$CALLS")" "1"
expect "set-key: and was in no argument" "$(grep -c '^security add' "$CALLS"):$(grep '^curl' "$CALLS" | grep -c kyb_new_token)" "0:0"
: > "$CALLS"
expect "set-key refuses a token Koyeb does not take" "$(printf 'kyb_bad\n' | CURLSTUB=401 koyeb_set_key 2>&1 | tail -n 1 | grep -c 'nothing was saved'):$(grep -c '^security -i' "$CALLS")" "1:0"
expect "set-key refuses a token with a quote" "$(printf 'a"b\n' | koyeb_set_key 2>&1 | grep -c 'does not look like')" "1"

for f in "koyeb_off alpha" "koyeb_cancel alpha x" "koyeb_rollback alpha" "koyeb_logs alpha 10"; do
  : > "$CALLS"; msg="$( ($f) 2>&1 )"; rc=$?
  expect "$f is refused: $rc, nothing sent" "$rc:$(grep -c '^curl' "$CALLS")" "1:0"
  has "$f says so" "$msg" "Koyeb cannot"
done

doc="$(koyeb_doctor)"
expect "doctor: key works and the count" "$(echo "$doc" | jq -c '[.key, .keyOk, .services, .expiresAt, .rateLimit]')" '["env",true,4,null,null]'
expect "doctor: a refused key is reported" "$(CURLSTUB=401 koyeb_doctor | jq -c '[.keyOk, (.error | length > 0)]')" "[false,true]"

echo
[ "$fails" = 0 ] && echo "All Koyeb tests passed." || { echo "$fails failed."; exit 1; }
