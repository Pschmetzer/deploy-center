#!/bin/bash
# Tests for providers/coolify.sh. No network: curl, security and sleep are stand-ins.
# curl answers from tests/fixtures/coolify/routes. Run: bash tests/providers/coolify.sh
#
# Self-contained until the A1 provider PR lands tests/lib/fake-curl.sh and
# tests/providers/contract.sh; the contract checks below mirror that contract.
set -uo pipefail
cd "$(dirname "$0")/../.." || exit 1
fails=0
ok()   { echo "ok   $1"; }
fail() { echo "FAIL $1: $2"; fails=$((fails+1)); }
expect() { [ "$2" = "$3" ] && ok "$1" || fail "$1" "expected [$3], got [$2]"; }
has()  { case "$2" in *"$3"*) ok "$1" ;; *) fail "$1" "[$3] not in: $2" ;; esac; }
hasnt() { case "$2" in *"$3"*) fail "$1" "[$3] should not be in: $2" ;; *) ok "$1" ;; esac; }

tmp="$(mktemp -d)"; trap 'rm -rf "$tmp"' EXIT
FIX="$PWD/tests/fixtures/coolify"
export FIX DEPLOYS_CONFIG="$tmp/config" CALLS="$tmp/calls.log" FAKE_STATE="$tmp/state"
export COOLIFY_URL="https://coolify.example.com/" COOLIFY_TOKEN="tok-secret-123" USER=tester
mkdir -p "$tmp/bin" "$FAKE_STATE"

# curl: the method, URL and body are logged, the -K config read from stdin (the token goes
# there), the answer comes from the routes file. FAKE_STATUS forces a status for every call.
cat > "$tmp/bin/curl" <<'CURL'
#!/bin/bash
m=GET; prev=""; data=""; for a in "$@"; do
  [ "$prev" = -X ] && m="$a"; [ "$prev" = --data ] && data="$a"; prev="$a"; done
url="${*: -1}"
case " $* " in *" -K - "*) conf="$(cat)" ;; *) conf="" ;; esac
echo "curl $m $url ARGS[$*] DATA[$data]" >> "$CALLS"
case "$url" in
  */api/health) ;;
  *) case "$conf" in *"Authorization: Bearer "*) ;; *) echo "no token on stdin" >&2; exit 2 ;; esac ;;
esac
if [ -n "${FAKE_STATUS:-}" ]; then printf '%s\n%s' "$(cat "$FIX/error-$FAKE_STATUS.json")" "$FAKE_STATUS"; exit 0; fi
while read -r rm glob dglob file status when sets; do
  case "$rm" in ''|'#'*) continue ;; esac
  [ "$rm" = "$m" ] || continue
  # shellcheck disable=SC2053
  [[ "$url" == $glob ]] || continue
  # shellcheck disable=SC2053
  [ "$dglob" = - ] || [[ "$data" == $dglob ]] || continue
  case "$when" in -|'') ;; '!'*) [ -f "$FAKE_STATE/${when#!}" ] && continue ;; *) [ -f "$FAKE_STATE/$when" ] || continue ;; esac
  case "$sets" in -|'') ;; *) touch "$FAKE_STATE/$sets" ;; esac
  printf '%s\n%s' "$(cat "$FIX/$file")" "${status:-200}"; exit 0
done < "$FIX/routes"
printf '%s\n404' '{"message":"Not found."}'
CURL
# security: logs what it was asked, and what came on stdin (the token must come there).
cat > "$tmp/bin/security" <<'SEC'
#!/bin/bash
echo "security $* STDIN[$(cat)]" >> "$CALLS"
case "$1" in find-generic-password) exit 44 ;; esac
exit 0
SEC
printf '#!/bin/bash\nexit 0\n' > "$tmp/bin/sleep"
chmod +x "$tmp/bin"/*
export PATH="$tmp/bin:$PATH"
calls() { grep -c -- "$1" "$CALLS" 2>/dev/null || true; }
reset() { : > "$CALLS"; rm -f "$FAKE_STATE"/*; rm -f "$DEPLOYS_CONFIG/coolify-off.json"; }

# shellcheck source=../../providers/coolify.sh
. ./providers/coolify.sh

# --- contract ---
missing=0
for f in meta ready json has off deploy_json status latest cancel rollback logs url set_key doctor; do
  declare -F "coolify_$f" >/dev/null || { fail "contract: coolify_$f" "not defined"; missing=1; }
done
[ "$missing" = 0 ] && ok "contract: all 14 functions defined"
meta="$(coolify_meta)"
expect "meta: shape" "$(echo "$meta" | jq -c '[.id, .label, .keyEnv, .keychain, (.caps | keys)]')" \
  '["coolify","Coolify","COOLIFY_TOKEN","deploy-center-coolify",["cancel","logs","off","preview","rollback","sha"]]'
expect "meta: caps" "$(echo "$meta" | jq -c '[.caps.off, .caps.sha, .caps.cancel, .caps.rollback, .caps.logs, .caps.preview]')" \
  '[true,true,true,true,true,false]'
coolify_ready && ok "ready: with a URL and a token" || fail "ready" "not ready"
( unset COOLIFY_TOKEN; coolify_ready ) && fail "ready without token" "said ready" || ok "ready: not without a token"
( unset COOLIFY_URL; coolify_ready ) && fail "ready without URL" "said ready" || ok "ready: not without an instance"

# --- instance URL: env, or the config file; trailing / and /api/v1 are dropped ---
expect "base: env, trailing slash dropped" "$(coolify_base)" https://coolify.example.com
expect "base: /api/v1 dropped" "$(COOLIFY_URL=https://c.example.com/api/v1 coolify_base)" https://c.example.com
expect "base: scheme added" "$(COOLIFY_URL=c.example.com coolify_base)" https://c.example.com
mkdir -p "$DEPLOYS_CONFIG"; echo '{"url":"http://10.0.0.5:8000"}' > "$DEPLOYS_CONFIG/coolify.json"
expect "base: from coolify.json" "$( unset COOLIFY_URL; coolify_base )" http://10.0.0.5:8000
rm -f "$DEPLOYS_CONFIG/coolify.json"
out="$( unset COOLIFY_URL; coolify_base 2>&1 )"; rc=$?
expect "base: none is an error" "$rc" 1
has "base: says how" "$out" "deploys coolify set-url"

# --- phases ---
for pair in queued:queued in_progress:building finished:ready failed:failed cancelled-by-user:canceled; do
  got="$(jq -rn --arg s "${pair%%:*}" --arg base x "$COOLIFY_JQ"'$s | phase')"
  [ "$got" = "${pair#*:}" ] || fail "phase ${pair%%:*}" "expected ${pair#*:}, got $got"
done
ok "phase: every Coolify status maps to queued|building|ready|failed|canceled"

# --- json ---
reset
out="$(coolify_json 2>"$tmp/err")"; rc=$?
expect "json: exit 0 (one app's deployments failing is not fatal)" "$rc" 0
expect "json: sorted names" "$(echo "$out" | jq -c 'map(.name)')" '["api","blog","cache","shop"]'
expect "json: every contract field on every app" "$(echo "$out" | jq -c 'map(keys) | unique')" \
  '[["auto","dashboardUrl","deployable","domain","fetchError","id","lastAt","lastMsg","lastSha","lastState","name","paused","phase","ref","repo","url"]]'
expect "json: phases are contract phases" "$(echo "$out" | jq '[.[].phase] - ["queued","building","ready","failed","canceled",null] | length')" 0
shop="$(echo "$out" | jq -c '.[] | select(.name=="shop")')"
expect "json: shop auto on, deployable" "$(echo "$shop" | jq -c '[.id, .auto, .deployable, .paused]')" '["app-shop",true,true,false]'
expect "json: shop repo, ref, domain, url" "$(echo "$shop" | jq -c '[.repo, .ref, .domain, .url]')" \
  '["me/shop","main","shop.example.com","https://shop.example.com"]'
expect "json: dashboard is the app page" "$(echo "$shop" | jq -r .dashboardUrl)" \
  "https://coolify.example.com/project/p-1/environment/e-1/application/app-shop"
expect "json: a PR preview is not the last deploy" "$(echo "$shop" | jq -c '[.lastState, .phase, .lastAt]')" '["in_progress","building",1793613600]'
expect "json: the commit is what is live" "$(echo "$shop" | jq -c '[.lastSha[0:7], .lastMsg]')" '["2222222","feat: cart"]'
blog="$(echo "$out" | jq -c '.[] | select(.name=="blog")')"
expect "json: blog: auto off, github URL, no scheme in fqdn" "$(echo "$blog" | jq -c '[.auto, .repo, .ref, .domain, .url]')" \
  '[false,"me/blog","trunk","blog.example.com","https://blog.example.com"]'
expect "json: blog failed, +00:00 time read" "$(echo "$blog" | jq -c '[.phase, .lastAt, .lastSha[0:7]]')" '["failed",1793692800,"4444444"]'
api="$(echo "$out" | jq -c '.[] | select(.name=="api")')"
expect "json: non-GitHub repo: auto, but no repo to compare" "$(echo "$api" | jq -c '[.auto, .repo, .deployable]')" '[true,null,false]'
has "json: a failed deployment read is a fetchError" "$(echo "$api" | jq -r .fetchError)" "HTTP 500"
expect "json: the 500 read was retried" "$(calls 'curl GET .*/deployments/applications/app-api')" 3
cache="$(echo "$out" | jq -c '.[] | select(.name=="cache")')"
expect "json: image app: no auto, no repo, no ref, canceled" "$(echo "$cache" | jq -c '[.auto, .repo, .ref, .domain, .phase, .lastSha]')" \
  '[false,null,null,null,"canceled",null]'
expect "json: token never in curl arguments" "$(grep -c 'ARGS\[.*tok-secret-123' "$CALLS")" 0
expect "json: URL is the instance's api/v1" "$(calls 'curl GET https://coolify.example.com/api/v1/applications ')" 1

# --- off: remembers what it found, verifies, mentions previews ---
reset
out="$(coolify_off shop 2>&1)"; rc=$?
expect "off shop: exit 0" "$rc" 0
expect "off shop: one PATCH" "$(grep -c 'curl PATCH .*/applications/app-shop .*DATA\[{"is_auto_deploy_enabled":false}\]' "$CALLS")" 1
expect "off shop: read back" "$(calls 'curl GET .*/applications/app-shop ')" 2
has "off shop: done" "$out" "no longer deploys on push"
has "off shop: previews still build" "$out" "PR preview deployments are on"
of="$DEPLOYS_CONFIG/coolify-off.json"
expect "off shop: prior values remembered" "$(jq -c '."app-shop" | [.auto, .previews, (.offAt|type)]' "$of")" '[true,true,"number"]'
expect "off shop: state file is private" "$(stat -c %a "$of" 2>/dev/null || stat -f %Lp "$of")" 600
expect "json: shop auto off now" "$(coolify_json 2>/dev/null | jq -c '.[] | select(.name=="shop") | .auto')" false
# A second off must not overwrite what was there before the first.
out="$(coolify_off shop 2>&1)"
has "off again: already off" "$out" "already does not deploy on push"
expect "off again: prior still true" "$(jq '."app-shop".auto' "$of")" true
# --previews: both off, no note.
reset
out="$(coolify_off shop --previews 2>&1)"; rc=$?
expect "off --previews: exit 0" "$rc" 0
expect "off --previews: both in the PATCH" "$(grep -c 'DATA\[{"is_auto_deploy_enabled":false,"is_preview_deployments_enabled":false}\]' "$CALLS")" 1
hasnt "off --previews: no note" "$out" "PR preview deployments are on"
# blog was off already: no PATCH.
reset
out="$(coolify_off blog 2>&1)"
expect "off blog: no PATCH when already off" "$(calls 'curl PATCH')" 0
expect "off blog: prior false remembered" "$(jq '."app-blog".auto' "$of")" false
# A PATCH that Coolify takes but does not apply is an error.
reset
out="$(coolify_off api 2>&1)"; rc=$?
expect "off api: not applied -> exit 1" "$rc" 1
has "off api: says so" "$out" "still has Auto Deploy on"
# on: back to what it was.
reset
coolify_off shop >/dev/null 2>&1
out="$(coolify_on shop 2>&1)"
expect "on: restores auto and previews" "$(grep -c 'curl PATCH .*DATA\[{"is_auto_deploy_enabled":true,"is_preview_deployments_enabled":true}\]' "$CALLS")" 1
expect "on: record dropped" "$(jq 'has("app-shop")' "$of")" false

# --- deploy ---
reset
out="$(coolify_deploy_json shop 2>&1)"; rc=$?
expect "deploy shop: exit 0" "$rc" 0
expect "deploy shop: the new deployment" "$(echo "$out" | jq -c '[.id, .phase, .state]')" '["dep-new","queued","queued"]'
expect "deploy shop: dashboard link" "$(echo "$out" | jq -r .dashboardUrl)" \
  "https://coolify.example.com/project/p-1/environment/e-1/application/app-shop/deployment/dep-new"
expect "deploy shop: one POST, no PATCH" "$(calls 'curl POST .*/deploy?uuid=app-shop')|$(calls 'curl PATCH')" "1|0"
# With a sha: pin, deploy, put back — in that order.
reset
out="$(coolify_deploy_json shop "" abc1234 2>&1)"; rc=$?
expect "deploy --sha: exit 0" "$rc" 0
expect "deploy --sha: pin, deploy, restore" "$(grep -oE 'curl (PATCH|POST) [^ ]+|DATA\[[^]]*\]' "$CALLS" | grep -vE 'DATA\[\]' | tr '\n' ' ')" \
  'curl PATCH https://coolify.example.com/api/v1/applications/app-shop DATA[{"git_commit_sha":"abc1234"}] curl POST https://coolify.example.com/api/v1/deploy?uuid=app-shop curl PATCH https://coolify.example.com/api/v1/applications/app-shop DATA[{"git_commit_sha":"HEAD"}] '
out="$(coolify_deploy_json shop "" 'abc;rm' 2>&1)"; rc=$?
expect "deploy --sha: not a sha refused" "$rc" 1
reset
out="$(coolify_deploy_json cache "" abc1234 2>&1)"; rc=$?
expect "deploy --sha on an image app: refused" "$rc" 1
has "deploy --sha on an image app: says why" "$out" "does not build from git"
expect "deploy --sha on an image app: nothing changed" "$(calls 'curl PATCH')" 0
out="$(coolify_deploy_json cache 2>&1)"; rc=$?
expect "deploy not queued: exit 1" "$rc" 1
has "deploy not queued: Coolify's reason" "$out" "Unauthorized to deploy this application"
out="$(coolify_deploy_json shop preview 2>&1)"; rc=$?
expect "deploy --preview: refused" "$rc" 1

# --- status, latest, cancel, rollback, logs, url, has ---
reset
expect "status" "$(coolify_status dep-shop-3 | jq -c '[.id, .phase, .sha[0:7], .msg]')" '["dep-shop-3","building","3333333","feat: checkout"]'
expect "status: app and deployment" "$(coolify_status shop dep-shop-3 | jq -r .id)" dep-shop-3
expect "latest: skips the PR preview" "$(coolify_latest shop | jq -r .id)" dep-shop-3
expect "latest: HEAD is no sha" "$(coolify_latest cache | jq -c '[.id, .phase, .sha]')" '["dep-cache-1","canceled",null]'
out="$(coolify_cancel shop dep-shop-3)"
expect "cancel: posted" "$(calls 'curl POST .*/deployments/dep-shop-3/cancel')" 1
has "cancel: said" "$out" "canceled"
out="$(coolify_cancel blog dep-blog-4 2>&1)"; rc=$?
expect "cancel finished: exit 1" "$rc" 1
has "cancel finished: Coolify's reason" "$out" "Current status: finished"
reset
out="$(coolify_rollback shop 2>&1)"; rc=$?
expect "rollback: exit 0" "$rc" 0
expect "rollback: to the commit before the live one" "$(grep -c 'curl POST .*/applications/app-shop/rollback .*DATA\[{"commit":"1111111111111111111111111111111111111111"}\]' "$CALLS")" 1
has "rollback: no build when the image is there" "$out" "image still on the server: no build"
has "rollback: the deployment" "$out" "dep-rb"
out="$(coolify_rollback blog 2>&1)"; rc=$?
expect "rollback on an old Coolify: exit 1" "$rc" 1
has "rollback on an old Coolify: says the version" "$out" "needs Coolify v4.3"
has "rollback: blog goes to the commit before the live one" "$(grep 'app-blog/rollback' "$CALLS")" '"commit":"3333333333333333333333333333333333333333"'
out="$(coolify_rollback cache 2>&1)"; rc=$?
expect "rollback with nothing earlier: exit 1" "$rc" 1
out="$(coolify_logs shop 2>&1)"
has "logs: the build log of the newest deploy" "$out" "built in 41s"
has "logs: commands shown" "$out" '$ npm run build'
hasnt "logs: hidden lines left out" "$out" "secret internals"
expect "logs: lines limit" "$(coolify_logs shop 1 2>&1)" "Rolling update started."
out="$(coolify_logs blog 200 --id dep-blog-5 2>&1)"; rc=$?
expect "logs without read:sensitive: exit 1" "$rc" 1
has "logs without read:sensitive: says which permission" "$out" "read:sensitive"
out="$(coolify_logs shop 50 --runtime 2>&1)"
has "logs --runtime" "$out" "listening on :3000"
has "logs --runtime: lines passed" "$(grep 'app-shop/logs' "$CALLS")" "lines=50"
expect "url" "$(coolify_url shop)" https://shop.example.com
expect "url: no scheme gets https" "$(coolify_url blog)" https://blog.example.com
expect "url --dashboard" "$(coolify_url shop --dashboard)" https://coolify.example.com/project/p-1/environment/e-1/application/app-shop
expect "url: image app without domain" "$(coolify_url cache)" ""
coolify_has blog && ok "has: blog" || fail "has: blog" "not found"
coolify_has app-shop && ok "has: by uuid" || fail "has: by uuid" "not found"
coolify_has nope && fail "has: nope" "found" || ok "has: unknown app"

# --- 401 / 403: a wrong token is an error with a reason, never an empty list ---
reset
out="$(FAKE_STATUS=401 coolify_json 2>&1)"; rc=$?
expect "401: json exit 1" "$rc" 1
has "401: says the token is wrong" "$out" "the Coolify token is wrong or expired: check COOLIFY_TOKEN"
has "401: Coolify's message" "$out" "Unauthenticated."
expect "401: not retried" "$(calls 'curl GET')" 1
out="$(FAKE_STATUS=401 coolify_deploy_json shop 2>&1)"; rc=$?
expect "401: deploy exit 1" "$rc" 1
out="$(FAKE_STATUS=403 coolify_json 2>&1)"
has "403 API disabled: says where to turn it on" "$out" "turn on API access in Coolify"
out="$(FAKE_STATUS=401 coolify_doctor)"
expect "doctor 401" "$(echo "$out" | jq -c '[.key, .tokenOk, (.error | test("401"))]')" '["env",false,true]'
expect "doctor ok" "$(coolify_doctor | jq -c '[.provider, .url, .urlSource, .https, .key, .tokenOk, .version, .apps]')" \
  '["coolify","https://coolify.example.com","env",true,"env",true,"v4.7.3",4]'
out="$( unset COOLIFY_TOKEN; coolify_doctor )"
expect "doctor: no token" "$(echo "$out" | jq -c '[.key, .tokenOk]')" '["missing",false]'
out="$( unset COOLIFY_URL; COOLIFY_URL=http://10.0.0.5:8000 coolify_doctor )"
expect "doctor: plain http flagged" "$(echo "$out" | jq .https)" false

# --- set-url, set-key ---
reset
out="$( unset COOLIFY_URL; coolify_set_url https://coolify.example.com/api/v1/ 2>&1 )"; rc=$?
expect "set-url: exit 0" "$rc" 0
expect "set-url: saved, normalized" "$(jq -r .url "$DEPLOYS_CONFIG/coolify.json")" https://coolify.example.com
expect "set-url: checked /api/health" "$(calls 'curl GET https://coolify.example.com/api/health')" 1
reset
out="$(echo "bad-token" | FAKE_STATUS=401 coolify_set_key 2>&1)"; rc=$?
expect "set-key 401: exit 1" "$rc" 1
has "set-key 401: nothing saved" "$out" "nothing was saved"
expect "set-key 401: keychain untouched" "$(calls '^security')" 0
reset
out="$( unset COOLIFY_TOKEN; echo "1|goodtoken" | coolify_set_key 2>&1 )"; rc=$?
expect "set-key: exit 0" "$rc" 0
expect "set-key: tried first" "$(calls 'curl GET .*/api/v1/applications ')" 1
expect "set-key: saved via stdin" "$(grep -c 'security -i STDIN\[add-generic-password -U -a tester -s deploy-center-coolify -w 1|goodtoken\]' "$CALLS")" 1
expect "set-key: token never an argument" "$(grep -- 'goodtoken' "$CALLS" | grep -vc 'STDIN\[')" 0
out="$(printf '' | coolify_set_key 2>&1)"; rc=$?
expect "set-key: empty refused" "$rc" 1

echo
[ "$fails" = 0 ] && echo "All Coolify provider tests passed." || { echo "$fails failed."; exit 1; }
