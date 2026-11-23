#!/bin/bash
# Tests for providers/northflank.sh. No network and no account: curl, security and sleep are stand-ins
# (tests/lib/fake-curl.sh answers from tests/fixtures/northflank). Run: bash tests/providers/northflank.sh
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
export NORTHFLANK_TOKEN="nf_secret_token_123"
: > "$CALLS"
# shellcheck source=../../providers/northflank.sh
. ./providers/northflank.sh

expect "meta is one valid line with the token variable" "$(northflank_meta | jq -c '[.id, .keyEnv[0], .defaultOn, .caps.sha]')" '["northflank","NORTHFLANK_TOKEN",false,true]'
expect "json: phases, across two pages of projects" "$(northflank_json | jq -c 'map({(.name): .phase}) | add')" '{"alpha":"ready","beta":"building","delta":null,"epsilon":null,"gamma":"failed"}'
expect "json: id is project/service, build id and sha" "$(northflank_json | jq -r '.[] | select(.name == "alpha") | "\(.id) \(.latestId) \(.lastSha)"')" "demo/alpha bld-alpha-3 aaaaaaa1111111"
expect "json: a time with an offset is read (12:05 at +02:00 is 10:05 UTC)" "$(northflank_json | jq '.[] | select(.name == "alpha") | .lastAt')" "1772445900"
expect "json: auto follows disabledCI" "$(northflank_json | jq -c 'map({(.name): .auto}) | add')" '{"alpha":true,"beta":true,"delta":false,"epsilon":false,"gamma":false}'
expect "json: an image service is shown, not deployable" "$(northflank_json | jq -c '.[] | select(.name == "epsilon") | [.deployable, .phase]')" "[false,null]"
expect "json: a service with no build has no phase" "$(northflank_json | jq -c '.[] | select(.name == "delta") | [.phase, .fetchError]')" "[null,null]"
: > "$CALLS"; northflank_json >/dev/null
expect "json: the second page was asked for with its cursor" "$(grep -c 'projects?per_page=100&cursor=c2' "$CALLS")" "1"
expect "json: no build is read for an image service" "$(grep -c 'extra/services/epsilon/builds' "$CALLS")" "0"
expect "json: one unreadable service is a fetchError on its row" "$(northflank_json | jq -c '[.[] | select(.name == "delta" or .name == "alpha")] | length')" "2"
expect "has: a project/service id" "$(northflank_has demo/alpha)" "demo/alpha"
expect "has: a bare name finds it" "$(northflank_has alpha)" "demo/alpha"
expect "has: a name in the second project's page" "$(northflank_has epsilon)" "extra/epsilon"
expect "has: unknown is rc 1" "$(northflank_has nope >/dev/null; echo $?)" "1"
expect "has: odd names never reach the API" "$(: > "$CALLS"; northflank_has 'a b' >/dev/null; northflank_has '../x' >/dev/null; grep -c '^curl' "$CALLS")" "0"

: > "$CALLS"
d="$(northflank_deploy_json demo/alpha)"
expect "deploy: starts a build" "$(echo "$d" | jq -c '[.id, .phase]')" '["bld-alpha-4","queued"]'
expect "deploy: one POST, the build of the service" "$(grep -c '^curl POST .*/projects/demo/services/alpha/build$' "$CALLS")" "1"
expect "deploy: a bad id sends no POST" "$(: > "$CALLS"; ( northflank_deploy_json "a/b/c" ) >/dev/null 2>&1; ( northflank_deploy_json "alpha" ) >/dev/null 2>&1; grep -c '^curl' "$CALLS")" "0"
expect "deploy: a bad sha sends nothing" "$(: > "$CALLS"; ( northflank_deploy_json demo/alpha --sha 'x;y' ) >/dev/null 2>&1; echo $?:"$(grep -c '^curl' "$CALLS")")" "1:0"
: > "$CALLS"; northflank_deploy_json demo/alpha --sha abc1234 >/dev/null
expect "deploy --sha: the commit is in the body" "$(grep -c '^curl POST' "$CALLS")" "1"
for o in --preview --no-cache; do
  : > "$CALLS"; msg="$( (northflank_deploy_json demo/alpha $o) 2>&1 )"
  has "deploy $o is refused" "$msg" "Northflank cannot"
  expect "deploy $o sends nothing" "$(grep -c '^curl' "$CALLS")" "0"
done
expect "deploy: an image service is refused before the POST" "$(: > "$CALLS"; ( northflank_deploy_json extra/epsilon ) >/dev/null 2>&1; echo $?:"$(grep -c '^curl POST' "$CALLS")")" "1:0"
expect "status: a finished build is ready" "$(northflank_status demo/alpha bld-alpha-3 | cut -f2,3)" "$(printf 'ready\tSUCCESS')"
expect "status: a pending build is queued" "$(northflank_status demo/alpha bld-alpha-4 | cut -f2)" "queued"
expect "latest: the newest build" "$(northflank_latest demo/alpha | cut -f1)" "bld-alpha-3"
expect "latest: none without builds" "$(northflank_latest demo/delta)" "$(printf 'none\t\tnone')"
expect "status: an odd id is refused before a call" "$(: > "$CALLS"; (northflank_status demo/alpha '../x') >/dev/null 2>&1; echo $?:"$(grep -c '^curl' "$CALLS")")" "1:0"
expect "url" "$(northflank_url demo/alpha)" "https://app.northflank.com/t/demo/services"
expect "the token is not in any logged call" "$(grep -c 'nf_secret_token_123' "$CALLS")" "0"
expect "a 429 on a list ends with the reason" "$(CURLSTUB=429 northflank_json 2>&1 | grep -c 'Could not list')" "1"

: > "$CALLS"
expect "set-key saves a working token" "$(printf 'nf_new_token\n' | northflank_set_key 2>&1 | tail -n 1)" "Northflank token saved and working."
expect "set-key: the token went to security on stdin" "$(grep -c '^security -i STDIN\[add-generic-password .* -s deploy-center-northflank -w nf_new_token\]' "$CALLS")" "1"
expect "set-key: and was in no argument" "$(grep -c '^security add' "$CALLS"):$(grep '^curl' "$CALLS" | grep -c nf_new_token)" "0:0"
: > "$CALLS"
expect "set-key refuses a token Northflank does not take" "$(printf 'nf_bad\n' | CURLSTUB=401 northflank_set_key 2>&1 | tail -n 1 | grep -c 'nothing was saved'):$(grep -c '^security -i' "$CALLS")" "1:0"
expect "set-key refuses a token with a quote" "$(printf 'a"b\n' | northflank_set_key 2>&1 | grep -c 'does not look like')" "1"

for f in "northflank_off demo/alpha" "northflank_cancel demo/alpha x" "northflank_rollback demo/alpha" "northflank_logs demo/alpha 10"; do
  : > "$CALLS"; msg="$( ($f) 2>&1 )"; rc=$?
  expect "$f is refused: $rc, nothing sent" "$rc:$(grep -c '^curl' "$CALLS")" "1:0"
  has "$f says so" "$msg" "Northflank cannot"
done

doc="$(northflank_doctor)"
expect "doctor: key works and the count" "$(echo "$doc" | jq -c '[.key, .keyOk, .projects, .expiresAt, .rateLimit]')" '["env",true,2,null,null]'
expect "doctor: a refused key is reported" "$(CURLSTUB=401 northflank_doctor | jq -c '[.keyOk, (.error | length > 0)]')" "[false,true]"

echo
[ "$fails" = 0 ] && echo "All Northflank tests passed." || { echo "$fails failed."; exit 1; }
