#!/bin/bash
# Tests for providers/railway.sh. No network and no account: curl (a wrapper that logs the JSON
# body, then tests/lib/fake-curl.sh answers from tests/fixtures/railway), security and sleep are
# stand-ins. Run: bash tests/providers/railway.sh
set -uo pipefail
cd "$(dirname "$0")/../.." || exit 1
# The security stand-in reads stdin: never wait on a terminal.
exec </dev/null
fails=0
ok()   { echo "ok   $1"; }
fail() { echo "FAIL $1: $2"; fails=$((fails+1)); }
expect() { [ "$2" = "$3" ] && ok "$1" || fail "$1" "expected [$3], got [$2]"; }
bodies() { grep '^body ' "$CALLS" | sed 's/^body //'; }
has()  { case "$2" in *"$3"*) ok "$1" ;; *) fail "$1" "[$3] not in: $2" ;; esac; }

tmp="$(mktemp -d)"; trap 'rm -rf "$tmp"' EXIT
mkdir -p "$tmp/bin" "$tmp/real"
cp tests/lib/fake-curl.sh "$tmp/real/curl"
cat > "$tmp/bin/curl" <<'CURL'
#!/bin/bash
# Logs the body (the file behind --data-binary @file) and the arguments, then answers like fake-curl.
cfg="$(cat)"; prev=""; body=""
for a in "$@"; do [ "$prev" = --data-binary ] && body="$(cat "${a#@}")"; prev="$a"; done
echo "body $body" >> "$CALLS"; echo "args $*" >> "$CALLS"
# SWAP: a fixture that takes over once the redeploy mutation has gone out (the new deployment appears).
case "$body" in *serviceInstanceRedeploy*) [ ! -f "${SWAP:-/nonexistent}" ] || cp "$SWAP" "$FIXTURES/railway/POST_graphql_v2.json" ;; esac
printf '%s' "$cfg" | "$REAL_CURL" "$@"
CURL
cat > "$tmp/bin/security" <<'SEC'
#!/bin/bash
echo "security $* STDIN[$(cat)]" >> "$CALLS"
case "$1" in find-generic-password) exit 44 ;; esac
exit 0
SEC
printf '#!/bin/bash\nexit 0\n' > "$tmp/bin/sleep"
chmod +x "$tmp/bin"/* "$tmp/real"/*
export PATH="$tmp/bin:$PATH" REAL_CURL="$tmp/real/curl" FIXTURES="$tmp/fx" CALLS="$tmp/calls.log" DEPLOYS_CONFIG="$tmp/config" USER=tester
cp -R tests/fixtures "$tmp/fx"
export RAILWAY_API_TOKEN="rw_secret_token_123"
: > "$CALLS"
# shellcheck source=../../providers/railway.sh
. ./providers/railway.sh

W=a0000000-0000-4000-8000-000000000002; E=7e3b1d20-2222-4c4d-8e1f-1a2b3c4d5e6f; ID="$W:$E"

expect "meta: one line, the token variable, no push switch" "$(railway_meta | jq -c '[.id, .keyEnv[0], .defaultOn, .caps.off, .caps.sha, .caps.rollback]')" '["railway","RAILWAY_API_TOKEN",false,false,false,true]'
j="$(railway_json)"
expect "json: phases" "$(echo "$j" | jq -cS 'map({(.name): .phase}) | add')" '{"api":null,"cron":"failed","demo/web":"ready","other/web":"ready","worker":"building"}'
expect "json: the production environment is used, not the first one" "$(echo "$j" | jq -r '.[] | select(.name == "worker") | .id')" "$ID"
expect "json: a name two projects share gets the project in front" "$(echo "$j" | jq -c '[.[].name | select(test("web"))] | sort')" '["demo/web","other/web"]'
expect "json: sha only for what is live, message first line, repo and ref" "$(echo "$j" | jq -c '.[] | select(.name == "demo/web") | [.lastSha, .lastMsg, .repo, .ref, .auto]')" '["1a2b3c4d5e6f7a8b9c0d","feat: add cart","example/shop","main",true]'
expect "json: no sha for a build that is not live" "$(echo "$j" | jq -c '.[] | select(.name == "worker") | .lastSha')" "null"
expect "json: a service without a deployment is not failed" "$(echo "$j" | jq -c '.[] | select(.name == "api") | [.phase, .lastState, .url, .auto]')" '[null,null,null,false]'
expect "json: the timestamp with fractions is read" "$(echo "$j" | jq -c '.[] | select(.name == "worker") | .lastAt')" "1772445600"
expect "has: name and id both give the id" "$(railway_has worker):$(railway_has "$ID")" "$ID:$ID"
expect "has: a plain name that two projects share is not unique" "$(railway_has web >/dev/null; echo $?)" "1"
expect "has: project/name works" "$(railway_has demo/web)" "a0000000-0000-4000-8000-000000000001:$E"

# One query goes out as a POST with variables in the body.
: > "$CALLS"; railway_status "$ID" dep-live-3 >/dev/null
expect "status: the ids are variables in the JSON body, not in the query text" "$(bodies | jq -c '[.variables.s, .variables.e, (.query | contains("a0000000") | not)]')" "[\"$W\",\"$E\",true]"
expect "status: a final line" "$(railway_status "$ID" dep-live-3 | cut -f2,3)" "$(printf 'ready\tSUCCESS')"
expect "status: a deployment that is not among the newest is an error" "$( (railway_status "$ID" dep-gone) >/dev/null 2>&1; echo $?)" "1"
expect "latest: the newest" "$(railway_latest "$ID" | cut -f1)" "dep-live-3"
expect "ids that are not <service>:<env> never reach the API" "$(: > "$CALLS"; (railway_latest 'x y' ) >/dev/null 2>&1; echo $?:"$(grep -c '^curl' "$CALLS")")" "1:0"

# deploy: one redeploy mutation; the fixture answers with the same newest deployment, so no new one is seen.
: > "$CALLS"
d="$(railway_deploy_json "$ID" 2>/dev/null)"
expect "deploy: one redeploy mutation" "$(grep '^body ' "$CALLS" | grep -c serviceInstanceRedeploy)" "1"
expect "deploy: not yet listed is queued with no id" "$(echo "$d" | jq -c '[.id, .phase]')" '[null,"queued"]'
for o in --sha --preview --no-cache; do
  : > "$CALLS"; msg="$( (railway_deploy_json "$ID" $o x) 2>&1 )"
  has "deploy $o is refused" "$msg" "Railway cannot"
  expect "deploy $o sends nothing" "$(grep -c '^curl' "$CALLS")" "0"
done
# A new deployment appears after the redeploy: the answer names it.
printf '%s\n200\n' "$(head -n 1 tests/fixtures/railway/POST_graphql_v2.json | jq -c '.data.deployments.edges |= ([{"node":{"id":"dep-new-4","status":"INITIALIZING","createdAt":"2026-03-02T11:00:00Z","staticUrl":null,"meta":{}}}] + .)')" > "$tmp/swap.json"
SWAP="$tmp/swap.json" railway_deploy_json "$ID" > "$tmp/dj" 2>/dev/null
expect "deploy: the new deployment is named" "$(jq -c '[.id, .phase, .state]' "$tmp/dj")" '["dep-new-4","queued","INITIALIZING"]'
rm -rf "$tmp/fx"; cp -R tests/fixtures "$tmp/fx"

# cancel and rollback
: > "$CALLS"
expect "cancel" "$(railway_cancel "$ID" dep-worker-2 | jq -c '[.id, .phase]')" '["dep-worker-2","canceled"]'
expect "cancel: the id is a variable" "$(bodies | jq -r '.variables.d')" "dep-worker-2"
: > "$CALLS"
expect "rollback: the newest earlier deployment Railway can go back to" "$(railway_rollback "$ID" | jq -r '.id')" "dep-old-2"
expect "rollback: the mutation names it" "$(bodies | grep deploymentRollback | jq -r '.variables.d')" "dep-old-2"
expect "logs: the end of the build log" "$(railway_logs "$ID" 2 | tr '\n' '|')" "Step 2/4: build|Step 3/4: ship|"
expect "logs: lines must be a number" "$( (railway_logs "$ID" x) >/dev/null 2>&1; echo $?)" "1"
expect "url" "$(railway_url "$ID")" "https://worker-production-3c4d.up.railway.app"
has "url --dashboard" "$(railway_url "$ID" --dashboard)" "https://railway.com/project/5f1c2a9e-1111-4a3b-9c2d-0a1b2c3d4e5f/service/$W?environmentId=$E"
expect "off is refused" "$( (railway_off "$ID") 2>&1 | grep -c 'Railway cannot')" "1"

# A GraphQL error comes with HTTP 200: it is an error here.
cp "$tmp/fx/railway/errors.json" "$tmp/fx/railway/POST_graphql_v2.json"
msg="$( (railway_json) 2>&1 )"; rc=$?
expect "a GraphQL error is an error" "$rc:$(echo "$msg" | grep -c 'Not Authorized')" "1:1"
expect "an error never reads as a deploy" "$( (railway_deploy_json "$ID") >/dev/null 2>&1; echo $?)" "1"
rm -rf "$tmp/fx"; cp -R tests/fixtures "$tmp/fx"

# The token: never in an argument, always on stdin.
expect "the token is in no logged argument or body" "$(grep -c 'rw_secret_token_123' "$CALLS")" "0"
: > "$CALLS"; railway_json >/dev/null
expect "curl got no token in its arguments" "$(grep '^args ' "$CALLS" | grep -c rw_secret_token_123)" "0"
expect "the call is a POST, once per read" "$(grep -c '^curl POST ' "$CALLS")" "1"

# set-key
: > "$CALLS"
expect "set-key saves a working token" "$(printf 'rw_new\n' | railway_set_key 2>&1 | tail -n 1)" "Railway token saved and working."
expect "set-key: the token went to security on stdin" "$(grep -c '^security -i STDIN\[add-generic-password .* -s deploy-center-railway -w rw_new\]' "$CALLS")" "1"
: > "$CALLS"
expect "set-key refuses a token Railway does not take" "$(printf 'rw_bad\n' | CURLSTUB=401 railway_set_key 2>&1 | grep -c 'nothing was saved'):$(grep -c '^security -i' "$CALLS")" "1:0"
expect "set-key refuses a space or a quote" "$(printf 'a b\n' | railway_set_key 2>&1 | grep -c 'does not look like'):$(printf 'a"b\n' | railway_set_key 2>&1 | grep -c 'does not look like')" "1:1"
doc="$(railway_doctor)"
expect "doctor" "$(echo "$doc" | jq -c '[.key, .keyOk, .services, .expiresAt, .rateLimit]')" '["env",true,5,null,null]'
expect "doctor: a refused token is reported" "$(CURLSTUB=401 railway_doctor | jq -c '[.keyOk, (.error | length > 0)]')" "[false,true]"

echo
[ "$fails" = 0 ] && echo "All Railway tests passed." || { echo "$fails failed."; exit 1; }
