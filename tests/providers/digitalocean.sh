#!/bin/bash
# Tests for providers/digitalocean.sh. No network: curl, security and sleep are stand-ins.
# curl answers from tests/fixtures/digitalocean/routes. Run: bash tests/providers/digitalocean.sh
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

tmp="$(mktemp -d)"; trap 'rm -rf "$tmp"' EXIT
FIX="$PWD/tests/fixtures/digitalocean"
export FIX DEPLOYS_CONFIG="$tmp/config" CALLS="$tmp/calls.log" FAKE_STATE="$tmp/state"
export DIGITALOCEAN_TOKEN="dop_v1_secret123" USER=tester
mkdir -p "$tmp/bin" "$FAKE_STATE"

# curl: the method and URL are logged, the -K config read from stdin (the token goes there), a
# --data-binary @file body kept as body-<n>.json. The answer comes from the routes file, except:
#   GET /v2/apps/<id>   the app from the app pages, with the spec of the last PUT if there was one
#   PUT /v2/apps/<id>   stores the spec and answers {app:{id, spec}} like App Platform does
#   https://logs-store.example.com/*  a pre-signed log URL: must come without a token
# FAKE_STATUS forces a status for every API call.
cat > "$tmp/bin/curl" <<'CURL'
#!/bin/bash
m=GET; prev=""; bodyf=""; conf=""; for a in "$@"; do
  [ "$prev" = -X ] && m="$a"; [ "$prev" = --data-binary ] && bodyf="${a#@}"; prev="$a"; done
url="${*: -1}"
case " $* " in *" -K - "*) conf="$(cat)" ;; esac
n=$(( $(wc -l < "$CALLS" 2>/dev/null || echo 0) + 1 ))
[ -n "$bodyf" ] && cp "$bodyf" "$FAKE_STATE/body-$n.json"
echo "curl $m $url ARGS[$*] BODY[${bodyf:+body-$n.json}] AUTH[$( [ -n "$conf" ] && echo yes || echo no)]" >> "$CALLS"
case "$url" in https://logs-store.example.com/*)
  case "$*$conf" in *Authorization*|*dop_v1*) echo "token sent to the log host" >&2; exit 9 ;; esac
  printf 'Step 1/3 : npm ci\nStep 2/3 : npm run build\nbuild complete\n'; exit 0 ;;
esac
case "$conf" in *"Authorization: Bearer "*) ;; *) echo "no token on stdin" >&2; exit 2 ;; esac
if [ -n "${FAKE_STATUS:-}" ]; then printf '%s\n%s' "$(cat "$FIX/error-$FAKE_STATUS.json")" "$FAKE_STATUS"; exit 0; fi
path="${url#https://api.digitalocean.com}"
if [[ "$path" =~ ^/v2/apps/([a-z-]+)$ ]]; then
  id="${BASH_REMATCH[1]}"
  if [ "$m" = PUT ]; then
    jq -c '.spec' "$bodyf" > "$FAKE_STATE/spec-$id.json"
    jq -c --arg id "$id" '{app:{id:$id, spec:.spec}}' "$bodyf"; printf '\n200'; exit 0
  fi
  app="$(jq -c --arg id "$id" '.apps[] | select(.id==$id)' "$FIX"/apps-page*.json)"
  [ -n "$app" ] || { printf '%s\n404' '{"id":"not_found","message":"app not found"}'; exit 0; }
  if [ -f "$FAKE_STATE/spec-$id.json" ]; then
    app="$(jq -c --slurpfile s "$FAKE_STATE/spec-$id.json" '.spec = $s[0]' <<<"$app")"; fi
  printf '{"app":%s}\n200' "$app"; exit 0
fi
# The app pages carry the spec of the last PUT too, like the real list does.
if [ "$m" = GET ] && [[ "$path" =~ ^/v2/apps\?page=([0-9]+) ]]; then
  pg="$FIX/apps-page${BASH_REMATCH[1]}.json"; out="$(cat "$pg")"
  for sf in "$FAKE_STATE"/spec-*.json; do
    [ -f "$sf" ] || continue; sid="${sf##*/spec-}"; sid="${sid%.json}"
    out="$(jq -c --arg id "$sid" --slurpfile s "$sf" '.apps |= map(if .id == $id then .spec = $s[0] else . end)' <<<"$out")"
  done
  printf '%s\n200' "$out"; exit 0
fi
while read -r rm glob file status; do
  case "$rm" in ''|'#'*) continue ;; esac
  [ "$rm" = "$m" ] || continue
  # shellcheck disable=SC2053
  [[ "$url" == $glob ]] || continue
  printf '%s\n%s' "$(cat "$FIX/$file")" "${status:-200}"; exit 0
done < "$FIX/routes"
printf '%s\n404' '{"id":"not_found","message":"The resource you were accessing could not be found."}'
CURL
# security: logs what it was asked, and what came on stdin (the token must come there).
cat > "$tmp/bin/security" <<'SEC'
#!/bin/bash
in=""; [ "${1:-}" = -i ] && in="$(cat)"
echo "security $* STDIN[$in]" >> "$CALLS"
case "$1" in find-generic-password) exit 44 ;; esac
exit 0
SEC
printf '#!/bin/bash\nexit 0\n' > "$tmp/bin/sleep"
chmod +x "$tmp/bin"/*
export PATH="$tmp/bin:$PATH"
calls() { grep -c -- "$1" "$CALLS" 2>/dev/null || true; }
reset() { : > "$CALLS"; rm -f "$FAKE_STATE"/*; }
last_body() { local f; f="$(grep -o 'BODY\[body-[0-9]*\.json\]' "$CALLS" | tail -n 1 | tr -d '[]' | sed 's/^BODY//')"; cat "$FAKE_STATE/$f"; }

# shellcheck source=../../providers/digitalocean.sh
. ./providers/digitalocean.sh

# --- contract ---
for f in meta ready json has off deploy_json status latest cancel rollback logs url set_key doctor; do
  declare -F "digitalocean_$f" >/dev/null || fail "contract: digitalocean_$f" "not defined"
done
ok "contract: all 14 functions defined"
meta="$(digitalocean_meta)"
expect "meta: shape" "$(echo "$meta" | jq -c '[.id, .label, .keyEnv, .keychain, (.caps | keys)]')" \
  '["digitalocean","DigitalOcean App Platform","DIGITALOCEAN_TOKEN","deploy-center-digitalocean",["cancel","logs","off","preview","rollback","sha"]]'
expect "meta: caps" "$(echo "$meta" | jq -c '[.caps.off, .caps.sha, .caps.cancel, .caps.rollback, .caps.logs, .caps.preview]')" \
  '[true,false,true,true,true,false]'
digitalocean_ready && ok "ready: with a token" || fail "ready" "not ready with DIGITALOCEAN_TOKEN set"
( unset DIGITALOCEAN_TOKEN; digitalocean_ready ) && fail "ready without token" "said ready" || ok "ready: not without a token"

# --- phases: every App Platform phase, and the contract's five only ---
for pair in PENDING_BUILD:queued PENDING_DEPLOY:queued QUEUED:queued UNKNOWN:queued \
            BUILDING:building DEPLOYING:building ACTIVE:ready ERROR:failed \
            CANCELED:canceled SUPERSEDED:canceled; do
  got="$(jq -rn --arg s "${pair%%:*}" "$DIGITALOCEAN_JQ"'$s | phase')"
  expect "phase ${pair%%:*}" "$got" "${pair#*:}"
done
expect "phase: none is null" "$(jq -rn "$DIGITALOCEAN_JQ"'null | phase')" null

# --- the spec merge, on its own: only the flags change ---
spec="$(jq -c '.apps[0].spec' "$FIX/apps-page1.json")"
new="$(echo "$spec" | jq -c "$DIGITALOCEAN_JQ"'push_off')"
expect "merge: auto on before" "$(echo "$spec" | jq "$DIGITALOCEAN_JQ"'auto_on')" true
expect "merge: auto off after" "$(echo "$new" | jq "$DIGITALOCEAN_JQ"'auto_on')" false
expect "merge: every git source false" "$(echo "$new" | jq -c '[(.services, .static_sites, .workers, .jobs)[] | (.github // .gitlab // .bitbucket // empty) | .deploy_on_push]')" \
  '[false,false,false,false]'
expect "merge: a source without the flag gets it, false" "$(echo "$new" | jq -c '.jobs[0].bitbucket')" '{"repo":"me/shop","branch":"main","deploy_on_push":false}'
expect "merge: DOCR image flag off" "$(echo "$new" | jq -c '.workers[0].image.deploy_on_push')" '{"enabled":false}'
strip='del(.. | objects | .deploy_on_push?)'
expect "merge: nothing else changed" "$(echo "$new" | jq -cS "$strip")" "$(echo "$spec" | jq -cS "$strip")"
expect "merge: same keys, same order" "$(echo "$new" | jq -c '[paths | map(tostring) | join(".")] | map(select(test("deploy_on_push") | not))')" \
  "$(echo "$spec" | jq -c '[paths | map(tostring) | join(".")] | map(select(test("deploy_on_push") | not))')"
img="$(jq -c '.apps[1].spec' "$FIX/apps-page2.json")"
expect "merge: an image without the flag is left alone" "$(echo "$img" | jq -c "$DIGITALOCEAN_JQ"'push_off')" "$img"
expect "merge: on puts the old flags back" "$(echo "$new" | jq -cS --argjson o "$spec" "$DIGITALOCEAN_JQ"'push_from($o)')" \
  "$(echo "$spec" | jq -cS '.jobs[0].bitbucket.deploy_on_push = false')"

# --- json ---
reset
out="$(digitalocean_json)"; rc=$?
expect "json: exit 0" "$rc" 0
expect "json: both pages, sorted" "$(echo "$out" | jq -c 'map(.name)')" '["blog","image","Pinned","shop"]'
expect "json: every contract field on every app" "$(echo "$out" | jq -c 'map(keys) | unique')" \
  '[["auto","dashboardUrl","deployable","domain","fetchError","id","lastAt","lastMsg","lastSha","lastState","name","paused","phase","ref","repo","url"]]'
expect "json: phases are contract phases" "$(echo "$out" | jq '[.[].phase] - ["queued","building","ready","failed","canceled",null] | length')" 0
shop="$(echo "$out" | jq -c '.[] | select(.name=="shop")')"
expect "json: shop auto, deployable" "$(echo "$shop" | jq -c '[.auto, .deployable, .paused]')" '[true,true,false]'
expect "json: shop repo, ref, domain, urls" "$(echo "$shop" | jq -c '[.repo, .ref, .domain, .url, .dashboardUrl]')" \
  '["me/shop","main","shop.example.com","https://shop.example.com","https://cloud.digitalocean.com/apps/app-shop"]'
expect "json: shop newest deploy building, live commit" "$(echo "$shop" | jq -c '[.phase, .lastState, .lastAt, .lastSha, .lastMsg]')" \
  '["building","BUILDING",1793610000,"2222222aaaa","commit 2222222 pushed to github.com/me/shop"]'
blog="$(echo "$out" | jq -c '.[] | select(.name=="blog")')"
expect "json: blog off already, last one failed" "$(echo "$blog" | jq -c '[.auto, .deployable, .phase, .ref, .domain]')" \
  '[false,true,"failed","trunk","blog-xyz.ondigitalocean.app"]'
expect "json: pinned app is paused, not deployable" "$(echo "$out" | jq -c '.[] | select(.name=="Pinned") | [.auto, .paused, .deployable, .phase]')" \
  '[true,true,false,"queued"]'
expect "json: image app: no repo, no deploys" "$(echo "$out" | jq -c '.[] | select(.name=="image") | [.auto, .repo, .phase, .url]')" \
  '[false,null,null,null]'
expect "json: token never in curl arguments" "$(calls dop_v1_secret123)" 0

# --- off: GET, flip, PUT the whole spec; the old spec saved ---
reset
out="$(digitalocean_off shop 2>&1)"; rc=$?
expect "off shop: exit 0" "$rc" 0
has "off shop: said" "$out" "shop no longer deploys on push"
expect "off shop: one PUT" "$(calls 'curl PUT .*/v2/apps/app-shop ')" 1
put="$(last_body)"
expect "off shop: PUT body keeps the source versions" "$(echo "$put" | jq -c '[keys, .update_all_source_versions]')" '[["spec","update_all_source_versions"],false]'
expect "off shop: PUT spec is the merge of the GET spec" "$(echo "$put" | jq -cS .spec)" "$(echo "$spec" | jq -cS "$DIGITALOCEAN_JQ"'push_off')"
expect "off shop: nothing but flags changed" "$(echo "$put" | jq -cS ".spec | $strip")" "$(echo "$spec" | jq -cS "$strip")"
expect "off shop: body never an argument" "$(grep 'PUT' "$CALLS" | grep -c '"deploy_on_push"')" 0
bk="$DEPLOYS_CONFIG/do-specs/app-shop.json"
expect "off shop: backup is the old spec" "$(jq -cS . "$bk")" "$(echo "$spec" | jq -cS .)"
expect "off shop: backup is private" "$(stat -c %a "$bk" 2>/dev/null || stat -f %Lp "$bk")" 600
expect "off shop: json says off now" "$(digitalocean_json | jq -c '.[] | select(.name=="shop") | [.auto, .deployable]')" '[false,true]'
: > "$CALLS"
out="$(digitalocean_off shop 2>&1)"
has "off again: nothing to do" "$out" "already does not deploy on push"
expect "off again: no PUT" "$(calls 'curl PUT')" 0
expect "off again: backup kept" "$(jq -cS . "$bk")" "$(echo "$spec" | jq -cS .)"
# on: the flags come back from the backup.
: > "$CALLS"
out="$(digitalocean_on shop 2>&1)"; rc=$?
expect "on shop: exit 0" "$rc" 0
expect "on shop: spec as before (bitbucket flag stays explicit false)" "$(last_body | jq -cS .spec)" \
  "$(echo "$spec" | jq -cS '.jobs[0].bitbucket.deploy_on_push = false')"
expect "on shop: auto again" "$(digitalocean_json | jq -c '.[] | select(.name=="shop") | .auto')" true
reset
out="$(digitalocean_off blog 2>&1)"
has "off blog: already off" "$out" "already does not deploy on push"
expect "off blog: no PUT, no backup" "$(calls 'curl PUT'):$([ -e "$DEPLOYS_CONFIG/do-specs/app-blog.json" ] && echo yes || echo no)" "0:no"
out="$(digitalocean_on blog 2>&1)"; rc=$?
expect "on blog without backup: refused" "$rc" 1
has "on blog: points to the dashboard" "$out" "cloud.digitalocean.com/apps/app-blog/settings"

# --- deploy ---
reset
out="$(digitalocean_deploy_json shop 2>&1)"; rc=$?
expect "deploy shop: exit 0" "$rc" 0
expect "deploy shop: the new deployment" "$(echo "$out" | jq -c '[.id, .phase, .state, .url]')" '["d-shop-new","queued","PENDING_BUILD","https://shop.example.com"]'
expect "deploy shop: one POST, no forced build" "$(calls 'curl POST .*/v2/apps/app-shop/deployments ')" 1
expect "deploy shop: body" "$(last_body)" '{"force_build":false}'
out="$(digitalocean_deploy_json shop "" abc123 2>&1)"; rc=$?
expect "deploy --sha: refused" "$rc" 1
has "deploy --sha: says why" "$out" "not supported"
out="$(digitalocean_deploy_json shop preview 2>&1)"; rc=$?
expect "deploy --preview: refused" "$rc" 1
out="$(digitalocean_deploy_json Pinned 2>&1)"; rc=$?
expect "deploy pinned: refused" "$rc" 1
has "deploy pinned: says why" "$out" "pinned to a rollback"

# --- status, latest, cancel, rollback, url, has ---
reset
expect "status" "$(digitalocean_status shop d-shop-3 | jq -c '[.id, .phase, .sha, .progress, .dashboardUrl]')" \
  '["d-shop-3","building","3333333cccc","1/4","https://cloud.digitalocean.com/apps/app-shop/deployments/d-shop-3"]'
expect "status: the failed step" "$(digitalocean_status shop d-shop-x | jq -c '[.phase, .error]')" '["failed","Build failed: npm exited 1"]'
out="$(digitalocean_status d-shop-3 2>&1)"; rc=$?
expect "status: needs the app" "$rc" 1
expect "latest" "$(digitalocean_latest shop | jq -c '[.id, .phase]')" '["d-shop-3","building"]'
expect "latest: none" "$(digitalocean_latest image)" null
out="$(digitalocean_cancel shop d-shop-3)"
expect "cancel: posted" "$(calls 'curl POST .*/v2/apps/app-shop/deployments/d-shop-3/cancel')" 1
has "cancel: said" "$out" "canceled"
reset
out="$(digitalocean_rollback shop 2>&1)"; rc=$?
expect "rollback: exit 0" "$rc" 0
has "rollback: to the one live before, skipping the failed one" "$out" "rolling back to deployment d-shop-1"
has "rollback: warnings shown" "$out" "missing an image digest"
expect "rollback: validated, then rolled back, unpinned" "$(calls 'rollback/validate'):$(last_body)" '1:{"deployment_id":"d-shop-1","skip_pin":true}'
expect "url" "$(digitalocean_url shop)" https://shop.example.com
expect "url: default ingress" "$(digitalocean_url blog)" https://blog-xyz.ondigitalocean.app
expect "url --dashboard" "$(digitalocean_url shop --dashboard)" https://cloud.digitalocean.com/apps/app-shop
digitalocean_has blog && ok "has: by name" || fail "has: blog" "not found"
digitalocean_has app-shop && ok "has: by id" || fail "has: by id" "not found"
digitalocean_has shop.example.com && ok "has: by domain" || fail "has: by domain" "not found"
digitalocean_has nope && fail "has: nope" "found" || ok "has: unknown app"

# --- logs: follow the historic URLs, without the token ---
reset
out="$(digitalocean_logs shop 2>&1)"; rc=$?
expect "logs: exit 0" "$rc" 0
has "logs: component header" "$out" "== web (deployment d-shop-3) =="
has "logs: the archived log" "$out" "build complete"
has "logs: no archive yet" "$out" "== api (deployment d-shop-3) ==
(no build log archived yet"
expect "logs: BUILD logs asked for every component (web, api, docs, queue, migrate)" "$(calls 'components/.*/logs?type=BUILD&follow=false')" 5
expect "logs: log host got no token" "$(grep 'logs-store.example.com' "$CALLS" | grep -c 'AUTH\[no\]')" 1
reset
out="$(digitalocean_logs shop --id d-shop-3 --component web 2>&1)"
expect "logs --component: only that one" "$(calls 'components/.*/logs')" 1

# --- 401: a wrong token is an error with a reason, never an empty list ---
reset
out="$(FAKE_STATUS=401 digitalocean_json 2>&1)"; rc=$?
expect "401: json exit 1" "$rc" 1
has "401: says the token is wrong" "$out" "the DigitalOcean token is wrong or expired: check DIGITALOCEAN_TOKEN"
has "401: DigitalOcean's message" "$out" "Unable to authenticate you"
expect "401: not retried" "$(calls 'curl GET')" 1
reset
out="$(FAKE_STATUS=401 digitalocean_off shop 2>&1)"; rc=$?
expect "401: off exit 1, no PUT" "$rc:$(calls 'curl PUT')" "1:0"
out="$(FAKE_STATUS=401 digitalocean_doctor)"
expect "doctor 401" "$(echo "$out" | jq -c '[.key, .tokenOk, (.error | test("401"))]')" '["env",false,true]'
expect "doctor ok" "$(digitalocean_doctor | jq -c '[.provider, .key, .tokenOk, .apps]')" '["digitalocean","env",true,4]'
out="$( unset DIGITALOCEAN_TOKEN; digitalocean_doctor )"
expect "doctor: no token" "$(echo "$out" | jq -c '[.key, .tokenOk]')" '["missing",false]'

# --- set_key: checked with GET /v2/account first, saved only when it works, never as an argument ---
reset
out="$(echo "bad-token" | FAKE_STATUS=401 digitalocean_set_key 2>&1)"; rc=$?
expect "set-key 401: exit 1" "$rc" 1
has "set-key 401: nothing saved" "$out" "nothing was saved"
expect "set-key 401: keychain untouched" "$(calls '^security')" 0
reset
out="$( unset DIGITALOCEAN_TOKEN; echo "dop_v1_good" | digitalocean_set_key 2>&1 )"; rc=$?
expect "set-key: exit 0" "$rc" 0
expect "set-key: checked with /v2/account" "$(calls 'curl GET https://api.digitalocean.com/v2/account')" 1
expect "set-key: saved via stdin" "$(grep -c 'security -i STDIN\[add-generic-password -U -a tester -s deploy-center-digitalocean -w dop_v1_good\]' "$CALLS")" 1
expect "set-key: token never an argument" "$(grep -- 'dop_v1_good' "$CALLS" | grep -vc 'STDIN\[')" 0
out="$(printf '' | digitalocean_set_key 2>&1)"; rc=$?
expect "set-key: empty refused" "$rc" 1

echo
[ "$fails" = 0 ] && echo "All DigitalOcean provider tests passed." || { echo "$fails failed."; exit 1; }
