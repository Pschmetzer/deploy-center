#!/bin/bash
# Tests for providers/deno.sh. No network and no account: curl, security and sleep are stand-ins
# (tests/lib/fake-curl.sh answers from tests/fixtures/deno). Run: bash tests/providers/deno.sh
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
export DENO_DEPLOY_TOKEN="ddo_secret_token_123" DENO_DEPLOY_ORG=org-fixture
: > "$CALLS"
# shellcheck source=../../providers/deno.sh
. ./providers/deno.sh

expect "meta is one valid line with the token variable" "$(deno_meta | jq -c '[.id, .keyEnv[0], .defaultOn]')" '["deno","DENO_DEPLOY_TOKEN",false]'
expect "json: phases from the newest deployment" "$(deno_json | jq -c 'map({(.name): .phase}) | add')" '{"alpha":"ready","beta":"building","delta":null,"gamma":"failed"}'
expect "json: url, dashboard, sha, message" "$(deno_json | jq -r '.[] | select(.name == "alpha") | "\(.url) \(.dashboardUrl) \(.lastSha) \(.lastMsg)"')" "https://alpha.deno.dev https://dash.deno.com/projects/alpha aaaa333 Add page"
expect "json: a project without deployments is not deployable" "$(deno_json | jq -c '.[] | select(.name == "delta") | [.deployable, .fetchError]')" "[false,null]"
expect "json: nothing counts as auto" "$(deno_json | jq -c 'map(.auto) | unique')" "[false]"
expect "has: prints the name" "$(deno_has alpha)" "alpha"
expect "has: unknown is rc 1" "$(deno_has nope >/dev/null; echo $?)" "1"
expect "has: odd names never reach the API" "$(: > "$CALLS"; deno_has 'a/b' >/dev/null; grep -c '^curl' "$CALLS")" "0"

: > "$CALLS"
d="$(deno_deploy_json alpha)"
expect "deploy: redeploys the newest deployment" "$(echo "$d" | jq -c '[.id, .phase, .url]')" '["dpl-alpha-4","building","https://alpha.deno.dev"]'
expect "deploy: one POST, on the newest id" "$(grep -c '^curl POST .*/deployments/dpl-alpha-3/redeploy' "$CALLS")" "1"
expect "deploy: a project without deployment sends no POST" "$(: > "$CALLS"; ( deno_deploy_json delta ) >/dev/null 2>&1; echo $?:"$(grep -c '^curl POST' "$CALLS")")" "1:0"
for o in --sha --preview --no-cache; do
  : > "$CALLS"; msg="$( (deno_deploy_json alpha $o x) 2>&1 )"
  has "deploy $o is refused" "$msg" "Deno Deploy cannot"
  expect "deploy $o sends nothing" "$(grep -c '^curl' "$CALLS")" "0"
done
expect "status: a finished deployment is ready" "$(deno_status alpha dpl-alpha-3 | cut -f2,3)" "$(printf 'ready\tsuccess')"
expect "latest: the newest deployment" "$(deno_latest alpha | cut -f1)" "dpl-alpha-3"
expect "latest: none without deployments" "$(deno_latest delta)" "$(printf 'none\t\tnone')"
expect "status: an odd id is refused before a call" "$(: > "$CALLS"; (deno_status alpha '../x') >/dev/null 2>&1; echo $?:"$(grep -c '^curl' "$CALLS")")" "1:0"
# More than 100 projects: page 2 is read; an API that ignores page does not loop.
pg="$tmp/pg"; mkdir -p "$pg"; cp -R "$PWD/tests/fixtures/deno" "$pg/deno"
jq -n '[range(0;100) | {name:"p\(.)"}]' > "$pg/p1.json"
{ cat "$pg/p1.json"; echo 200; } > "$pg/deno/GET_v1_organizations_org-fixture_projects_limit_100.json"
{ echo '[{"name":"last"}]'; echo 200; } > "$pg/deno/GET_v1_organizations_org-fixture_projects_limit_100_page_2.json"
: > "$CALLS"
expect "list: a second page past 100 projects is read" "$(FIXTURES="$pg" deno_projects | jq 'length')" "101"
expect "list: page 2 asked with page=2" "$(grep -c 'projects?limit=100&page=2' "$CALLS")" "1"
{ cat "$pg/p1.json"; echo 200; } > "$pg/deno/GET_v1_organizations_org-fixture_projects_limit_100_page_2.json"
expect "list: an API that ignores page ends the read" "$(FIXTURES="$pg" deno_projects | jq 'length')" "100"
expect "url" "$(deno_url alpha)" "https://alpha.deno.dev"
expect "the token is not in any logged call" "$(grep -c 'ddo_secret_token_123' "$CALLS")" "0"

: > "$CALLS"
expect "set-key saves a working token" "$(printf 'ddo_new_token\n' | deno_set_key 2>&1 | tail -n 1)" "Deno Deploy token saved and working."
expect "set-key: the token went to security on stdin" "$(grep -c '^security -i STDIN\[add-generic-password .* -s deploy-center-deno -w ddo_new_token\]' "$CALLS")" "1"
expect "set-key: and was in no argument" "$(grep -c '^security add' "$CALLS"):$(grep '^curl' "$CALLS" | grep -c ddo_new_token)" "0:0"
: > "$CALLS"
expect "set-key refuses a token Deno Deploy does not take" "$(printf 'ddo_bad\n' | CURLSTUB=401 deno_set_key 2>&1 | tail -n 1 | grep -c 'nothing was saved'):$(grep -c '^security -i' "$CALLS")" "1:0"
expect "set-key refuses a token with a quote" "$(printf 'a"b\n' | deno_set_key 2>&1 | grep -c 'does not look like')" "1"

for f in "deno_off alpha" "deno_cancel alpha x" "deno_rollback alpha" "deno_logs alpha 10"; do
  : > "$CALLS"; msg="$( ($f) 2>&1 )"; rc=$?
  expect "$f is refused: $rc, nothing sent" "$rc:$(grep -c '^curl' "$CALLS")" "1:0"
  has "$f says so" "$msg" "Deno Deploy cannot"
done

doc="$(deno_doctor)"
expect "doctor: key works, org and count" "$(echo "$doc" | jq -c '[.key, .keyOk, .org, .projects, .expiresAt, .rateLimit]')" '["env",true,"org-fixture",4,null,null]'
expect "doctor: a refused key is reported" "$(CURLSTUB=401 deno_doctor | jq -c '[.keyOk, (.error | length > 0)]')" "[false,true]"
expect "no organization is said, not guessed" "$(DENO_DEPLOY_ORG='' deno_org 2>&1 | grep -c 'no organization')" "1"
expect "a bad organization id is refused" "$(DENO_DEPLOY_ORG='a/b' deno_org 2>&1)" 'Deno Deploy: "a/b" is not an organization id'

echo
[ "$fails" = 0 ] && echo "All Deno Deploy tests passed." || { echo "$fails failed."; exit 1; }
