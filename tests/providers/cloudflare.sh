#!/bin/bash
# Tests for providers/cloudflare.sh. No network: curl, security and sleep are stand-ins.
# Run: bash tests/providers/cloudflare.sh
set -uo pipefail
cd "$(dirname "$0")/../.." || exit 1
fails=0
ok()   { echo "ok   $1"; }
fail() { echo "FAIL $1: $2"; fails=$((fails+1)); }
expect() { [ "$2" = "$3" ] && ok "$1" || fail "$1" "expected [$3], got [$2]"; }

FIX="$PWD/tests/fixtures/cloudflare"
tmp="$(mktemp -d)"; trap 'rm -rf "$tmp"' EXIT
export DEPLOYS_CONFIG="$tmp/config" CALLS="$tmp/calls.log" ROUTES="$tmp/routes" FIX
mkdir -p "$tmp/bin" "$DEPLOYS_CONFIG"

# A stand-in for curl. $ROUTES holds lines "METHOD <path regex> <fixture>[:code][,<fixture>[:code]...]":
# the first line that matches answers; a list answers its items in turn (the last one repeats).
# Every call is logged with its body, and a token "bad" is answered with 401.
# (tests/lib/fake-curl.sh from the providers-as-files change can replace this once it lands.)
cat > "$tmp/bin/curl" <<'CURL'
#!/bin/bash
cfg="$(cat)"
m=GET; prev=""; body=""; form=""
for a in "$@"; do
  case "$prev" in -X) m="$a";; --data) body="$a";; -F|--form-string) form="$form $a";; esac; prev="$a"
done
url="${*: -1}"; path="${url#*client/v4}"
echo "$m $path${body:+ $body}${form:+ form:$form}" >> "$CALLS"
case "$cfg" in *"Bearer bad"*) cat "$FIX/unauthorized.json"; printf '\n401'; exit 0;; esac
n=0
while read -r rm re fx; do
  n=$((n+1)); [ -n "$rm" ] || continue
  [ "$rm" = "$m" ] && [[ "$path" =~ $re ]] || continue
  c="$(cat "$ROUTES.$n" 2>/dev/null || echo 0)"; echo $((c+1)) > "$ROUTES.$n"
  IFS=, read -ra list <<< "$fx"; i=$c; [ "$i" -lt "${#list[@]}" ] || i=$(( ${#list[@]} - 1 ))
  f="${list[$i]}"; code=200; case "$f" in *:*) code="${f##*:}"; f="${f%%:*}";; esac
  cat "$FIX/$f"; printf '\n%s' "$code"; exit 0
done < "$ROUTES"
printf '{"success":false,"errors":[{"code":7003,"message":"no route in test"}]}\n404'
CURL
printf '#!/bin/bash\necho "security $*" >> "$CALLS"; cat >/dev/null; exit 0\n' > "$tmp/bin/security"
printf '#!/bin/bash\nexit 0\n' > "$tmp/bin/sleep"
chmod +x "$tmp/bin"/*
export PATH="$tmp/bin:$PATH"

# Fresh routes, call log and state for each case.
routes() { rm -f "$ROUTES".* "$DEPLOYS_CONFIG/cloudflare.json"; : > "$CALLS"; printf '%s\n' "$@" > "$ROUTES"; }
calls() { grep -c -- "$1" "$CALLS" 2>/dev/null || true; }
cf() { bash providers/cloudflare.sh "$@"; }
A=acc0000000000000000000000000000a
export CLOUDFLARE_API_TOKEN=tok CLOUDFLARE_ACCOUNT_ID=$A

# --- phase mapping ---
# shellcheck source=../../providers/cloudflare.sh
. providers/cloudflare.sh
while IFS=$'\t' read -r want got d; do expect "phase $d" "$got" "$want"; done \
  < <(jq -r "$CF_PHASE"' .[] | [.want, (.d | cf_phase), (.d | tojson)] | @tsv' "$FIX/stages.json")

# --- meta ---
expect "meta: cancel is off" "$(cf meta | jq -c '.caps')" '{"off":true,"sha":false,"cancel":false,"rollback":true,"logs":true,"preview":true}'
expect "meta: not a default provider" "$(cf meta | jq '.default')" false

# --- account auto-detect ---
routes "GET ^/accounts accounts-one.json"
out="$(CLOUDFLARE_ACCOUNT_ID='' cf account)"
expect "account: the only one is used" "$out" "$A"
expect "account: and remembered" "$(jq -r .accountId "$DEPLOYS_CONFIG/cloudflare.json")" "$A"
: > "$CALLS"; out="$(CLOUDFLARE_ACCOUNT_ID='' cf account)"
expect "account: remembered, not asked again" "$out/$(calls /accounts)" "$A/0"
routes "GET ^/accounts accounts-two.json"
out="$(CLOUDFLARE_ACCOUNT_ID='' cf account 2>&1)"; rc=$?
expect "account: several stop" "$rc" 1
[[ "$out" == *"acc0000000000000000000000000000b"*"Several Cloudflare accounts"* ]] && ok "account: several are listed" || fail "account: several are listed" "$out"
[ ! -s "$DEPLOYS_CONFIG/cloudflare.json" ] || [ "$(jq -r '.accountId // ""' "$DEPLOYS_CONFIG/cloudflare.json")" = "" ] \
  && ok "account: several, none remembered" || fail "account: several, none remembered" "$(cat "$DEPLOYS_CONFIG/cloudflare.json")"
routes "GET ^/accounts accounts-none.json"
out="$(CLOUDFLARE_ACCOUNT_ID='' cf account 2>&1)"; rc=$?
expect "account: none stops" "$rc" 1
routes "GET ^/accounts accounts-two.json"
out="$(CLOUDFLARE_ACCOUNT_ID=envacct cf account)"
expect "account: environment first, no call" "$out/$(calls /accounts)" "envacct/0"

# --- 401 ---
routes "GET /pages/projects projects.json"
out="$(CLOUDFLARE_API_TOKEN=bad cf json 2>&1)"; rc=$?
expect "401: stops" "$rc" 1
[[ "$out" == *"HTTP 401"*"wrong, expired"*"CLOUDFLARE_API_TOKEN"* ]] && ok "401: says what to fix" || fail "401: says what to fix" "$out"
[[ "$out" != *bad* ]] && ok "401: token not printed" || fail "401: token not printed" "$out"
expect "401: reads are not repeated" "$(calls GET)" 1
expect "ready: with a token" "$(cloudflare_ready && echo y)" y

# --- json ---
routes "GET /pages/projects\\? projects.json"
out="$(cf json)"
expect "json: sorted by name" "$(echo "$out" | jq -c 'map(.name)')" '["Blog","site","upload"]'
s="$(echo "$out" | jq -c '.[] | select(.name=="site")')"
expect "json: contract fields" "$(echo "$s" | jq -c 'keys')" \
  '["auto","dashboardUrl","deployable","domain","fetchError","id","lastAt","lastMsg","lastSha","lastState","name","paused","phase","projectId","ref","repo","url"]'
# The id is the name (cf_proj puts it in the URL path); the UUID would 404 there.
expect "json: id is the project name, the UUID is projectId" "$(echo "$s" | jq -c '[.id, .projectId]')" '["site","p1"]'
expect "json: off project is not auto" "$(echo "$s" | jq .auto)" false
expect "json: custom domain over pages.dev" "$(echo "$s" | jq -r .url)" "https://www.example.com"
expect "json: live commit" "$(echo "$s" | jq -r '.lastSha + " " + .lastMsg')" "aaaa111 fix: live"
expect "json: phase of the newest" "$(echo "$s" | jq -r .phase)" building
expect "json: lastAt in seconds" "$(echo "$s" | jq .lastAt)" 1767323045
expect "json: repo and ref" "$(echo "$s" | jq -r '.repo + "@" + .ref')" "me/site@main"
expect "json: off + unverified is not deployable" "$(echo "$s" | jq .deployable)" false
expect "json: on project is auto and deployable" "$(echo "$out" | jq -c '.[] | select(.name=="Blog") | [.auto, .deployable, .phase]')" '[true,true,"ready"]'
expect "json: direct upload is neither" "$(echo "$out" | jq -c '.[] | select(.name=="upload") | [.auto, .deployable, .repo, .phase]')" '[false,false,null,null]'
out="$(DEPLOYS_CLOUDFLARE_TOGGLE=1 cf json)"
expect "json: toggle opt-in makes it deployable" "$(echo "$out" | jq '.[] | select(.name=="site") | .deployable')" true

# --- off / on ---
routes "GET /pages/projects/site$ project-on.json,project-on.json,project-off.json" "PATCH /pages/projects/site$ ok.json"
out="$(cf off site)"; rc=$?
expect "off: done" "$rc/$out" "0/Cloudflare: site no longer deploys on push"
p="$(grep '^PATCH' "$CALLS" | sed 's/^PATCH [^ ]* //')"
expect "off: both switches off" "$(echo "$p" | jq -c '.source.config | [.production_deployments_enabled, .preview_deployment_setting]')" '[false,"none"]'
expect "off: the full config is sent" "$(echo "$p" | jq -c '[.source.type, .source.config.owner, .source.config.preview_branch_includes, .source.config.pr_comments_enabled]')" '["github","me",["dev"],true]'
expect "off: prior values kept" "$(jq -c '.off.site | [.production_deployments_enabled, .preview_deployment_setting]' "$DEPLOYS_CONFIG/cloudflare.json")" '[true,"custom"]'
st="$(cat "$DEPLOYS_CONFIG/cloudflare.json")"
rm -f "$ROUTES".*; : > "$CALLS"; printf '%s\n' "GET /pages/projects/site$ project-off.json" "PATCH /pages/projects/site$ ok.json" > "$ROUTES"
out="$(cf off site)"
expect "off: already manual, nothing sent" "$out/$(calls PATCH)" "Cloudflare: site was already manual/0"
expect "off: prior values not overwritten" "$(cat "$DEPLOYS_CONFIG/cloudflare.json")" "$st"
: > "$CALLS"; out="$(cf on site)"
p="$(grep '^PATCH' "$CALLS" | sed 's/^PATCH [^ ]* //')"
expect "on: restores what was there" "$(echo "$p" | jq -c '.source.config | [.production_deployments_enabled, .preview_deployment_setting]')" '[true,"custom"]'
expect "on: forgets it" "$(jq -c '.off.site' "$DEPLOYS_CONFIG/cloudflare.json")" null
routes "GET /pages/projects/site$ project-on.json,project-on.json,project-on.json" "PATCH /pages/projects/site$ ok.json"
out="$(cf off site 2>&1)"; rc=$?
expect "off: a PATCH that did not take is an error" "$rc" 1
routes "GET /pages/projects/site$ project-upload.json"
out="$(cf off site 2>&1)"; rc=$?
[ "$rc" = 1 ] && [[ "$out" == *"direct upload"* ]] && ok "off: direct upload explained" || fail "off: direct upload explained" "$rc $out"

# --- deploy ---
routes "GET /pages/projects/site$ project-on.json" "POST /deployments$ deploy-queued.json"
out="$(cf deploy-json site)"; rc=$?
expect "deploy: started" "$rc/$(echo "$out" | jq -c '[.id, .state, .branch, .toggled]')" '0/["d-q","queued","main",false]'
expect "deploy: production branch sent" "$(grep -c 'POST .* form: branch=main' "$CALLS")" 1
rm -rf "$DEPLOYS_CONFIG/locks"
routes "GET /pages/projects/site$ project-on.json" "POST /deployments$ deploy-queued.json"
out="$(cf deploy-json site --preview --branch dev)"
expect "deploy: preview on a branch" "$(grep -c 'form: branch=dev' "$CALLS")/$(echo "$out" | jq -r .branch)" "1/dev"
out="$(cf deploy-json site --preview 2>&1)"; rc=$?
expect "deploy: preview needs a branch" "$rc" 1
out="$(cf deploy-json site --sha abc 2>&1)"; rc=$?
expect "deploy: no --sha" "$rc" 1
rm -rf "$DEPLOYS_CONFIG/locks"

routes "GET /pages/projects/site$ project-off.json" "POST /deployments$ deploy-queued.json"
out="$(cf deploy-json site 2>&1)"; rc=$?
[ "$rc" = 1 ] && [[ "$out" == *Unverified*selftest* ]] && ok "deploy: off + unverified refuses" || fail "deploy: off + unverified refuses" "$rc $out"
expect "deploy: and starts nothing" "$(calls POST)" 0

# --- the skipped deployment and its fallback ---
routes "GET /pages/projects/site$ project-off.json" "POST /deployments$ deploy-skipped.json,deploy-queued.json" "PATCH /pages/projects/site$ ok.json"
echo "{\"selftests\":{\"site\":{\"result\":\"verified\",\"at\":$(date +%s)}}}" > "$DEPLOYS_CONFIG/cloudflare.json"
out="$(cf deploy-json site 2>&1)"; rc=$?
[ "$rc" = 1 ] && [[ "$out" == *"skipped the build"*production_deployments_disabled*--toggle* ]] && ok "skipped: says so, points at --toggle" || fail "skipped: says so" "$rc $out"
expect "skipped: without --toggle nothing is switched" "$(calls PATCH)" 0
[ -z "$(ls -A "$DEPLOYS_CONFIG/locks" 2>/dev/null)" ] && ok "skipped: lock released" || fail "skipped: lock released" "$(ls "$DEPLOYS_CONFIG/locks")"

routes "GET /pages/projects/site$ project-off.json" "POST /deployments$ deploy-skipped.json,deploy-queued.json" "PATCH /pages/projects/site$ ok.json"
out="$(cf deploy-json site --toggle 2>"$tmp/err")"; rc=$?
expect "toggle: started" "$rc/$(echo "$out" | jq -c '[.id, .toggled]')" '0/["d-q",true]'
expect "toggle: two starts, two switches" "$(calls POST)/$(calls PATCH)" "2/2"
seq="$(grep -E '^(POST|PATCH)' "$CALLS" | awk '{print $1}' | tr '\n' ' ')"
expect "toggle: on, start, off, in that order" "$seq" "POST PATCH POST PATCH "
expect "toggle: switched on, then back off" "$(grep '^PATCH' "$CALLS" | sed 's/^PATCH [^ ]* //' | jq -c '.source.config.production_deployments_enabled' | tr '\n' ' ')" "true false "
expect "toggle: previews untouched" "$(grep '^PATCH' "$CALLS" | sed 's/^PATCH [^ ]* //' | jq -r '.source.config.preview_deployment_setting' | sort -u)" none
grep -q "race window" "$tmp/err" && ok "toggle: race window announced" || fail "toggle: race window announced" "$(cat "$tmp/err")"
rm -rf "$DEPLOYS_CONFIG/locks"

routes "GET /pages/projects/site$ project-off.json" "POST /deployments$ deploy-skipped.json,unauthorized.json:403" "PATCH /pages/projects/site$ ok.json"
out="$(DEPLOYS_CLOUDFLARE_TOGGLE=1 cf deploy-json site 2>&1)"; rc=$?
expect "toggle: a failed start still switches back" "$rc/$(calls PATCH)" "1/2"
expect "toggle: switched back, nothing left open" "$(jq -c '.toggling // {}' "$DEPLOYS_CONFIG/cloudflare.json")" "{}"
rm -rf "$DEPLOYS_CONFIG/locks"
# The switch back fails: the note stays, and doctor names it.
routes "GET /pages/projects/site$ project-off.json" "POST /deployments$ deploy-skipped.json,deploy-queued.json" "PATCH /pages/projects/site$ ok.json,unauthorized.json:403"
DEPLOYS_CLOUDFLARE_TOGGLE=1 cf deploy-json site >/dev/null 2>&1
expect "toggle: a failed switch back stays written down" "$(jq -c '.toggling | keys' "$DEPLOYS_CONFIG/cloudflare.json")" '["site"]'
rm -rf "$DEPLOYS_CONFIG/locks"
expect "toggle: switched back off" "$(grep '^PATCH' "$CALLS" | tail -n 1 | sed 's/^PATCH [^ ]* //' | jq '.source.config.production_deployments_enabled')" false

# --- self-test ---
routes "GET /pages/projects/site$ project-off.json" "POST /deployments$ deploy-queued.json" "GET /deployments/d-q$ deploy-queued.json,deployment-build.json"
out="$(cf selftest site)"
expect "selftest: asks for --yes, starts nothing" "$(calls POST)" 0
out="$(cf selftest site --yes)"; rc=$?
[ "$rc" = 0 ] && [[ "$out" == *passed*cccc333* ]] && ok "selftest: passes at the build stage" || fail "selftest: passes" "$rc $out"
expect "selftest: recorded" "$(jq -c '.selftest | [.result, .sha, .deploymentId]' "$DEPLOYS_CONFIG/cloudflare.json")" '["verified","cccc333","d-q"]'
expect "doctor: verified" "$(cf doctor | jq -r .deployWhileOff)" verified
routes "GET /pages/projects/site$ project-off.json" "POST /deployments$ deploy-skipped.json"
out="$(cf selftest site --yes)"; rc=$?
expect "selftest: skipped fails" "$rc/$(jq -r .selftest.result "$DEPLOYS_CONFIG/cloudflare.json")" "1/failed"
routes "GET /pages/projects/site$ project-on.json"
out="$(cf selftest site --yes 2>&1)"; rc=$?
expect "selftest: needs push-deploys off" "$rc/$(calls POST)" "1/0"
routes "GET /pages/projects/site$ project-off.json" "POST /deployments$ deploy-queued.json" "GET /deployments/d-q$ deploy-queued.json"
out="$(DEPLOYS_CLOUDFLARE_SELFTEST_TRIES=3 cf selftest site --yes)"; rc=$?
[ "$rc" = 1 ] && [[ "$out" == *inconclusive* ]] && ok "selftest: no build stage is inconclusive" || fail "selftest: inconclusive" "$rc $out"
expect "selftest: inconclusive records nothing" "$(jq -r '.selftest.result // "none"' "$DEPLOYS_CONFIG/cloudflare.json" 2>/dev/null || echo none)" none

# PRV-056: a self-test counts for its own project, and not for ever. site has push-deploys off.
# (The JSON is built first: macOS bash 3.2 mangles braces inside "$(f "...")".)
now="$(date +%s)"
st() { jq -nc --arg p "$1" --argjson at "$2" --arg k "${3:-selftests}" 'if $k == "selftest" then {selftest:{result:"verified", project:$p, at:$at}} else {selftests:{($p):{result:"verified", at:$at}}} end'; }
sel() { routes "GET /pages/projects\\? projects.json"; echo "$1" > "$DEPLOYS_CONFIG/cloudflare.json"; cf list | jq -c '.[] | select(.name=="site") | .deployable'; }
j1="$(st Blog "$now")"; j2="$(st site "$now")"; j3="$(st site $((now - 40 * 86400)))"; j4="$(st site "$now" selftest)"; j5="$(st Blog "$now" selftest)"
expect "selftest: another project's test does not make site deployable" "$(sel "$j1")" false
expect "selftest: its own test does" "$(sel "$j2")" true
expect "selftest: one older than 30 days counts no more" "$(sel "$j3")" false
expect "selftest: an earlier record counts for the project it names only" "$(sel "$j4"):$(sel "$j5")" "true:false"
routes "GET /pages/projects/site$ project-off.json" "POST /deployments$ deploy-queued.json"
echo "$j1" > "$DEPLOYS_CONFIG/cloudflare.json"
out="$(cf deploy-json site 2>&1)"; rc=$?
expect "selftest: deploy of an untested project still refuses" "$rc:$(calls POST)" "1:0"
rm -rf "$DEPLOYS_CONFIG/locks"

# PRV-057: a remembered account the token does not reach is looked for again, once.
routes "GET /accounts/accOLD/pages/projects unauthorized.json:403" "GET /accounts\\? accounts-one.json" "GET /pages/projects\\? projects.json"
echo '{"accountId":"accOLD"}' > "$DEPLOYS_CONFIG/cloudflare.json"
out="$(CLOUDFLARE_ACCOUNT_ID='' cf list 2>"$tmp/err")"; rc=$?
expect "account: a stale one is found again" "$rc:$(echo "$out" | jq length):$(jq -r .accountId "$DEPLOYS_CONFIG/cloudflare.json")" "0:3:$A"
grep -q "using the token's account" "$tmp/err" && ok "account: and says so" || fail "account: and says so" "$(cat "$tmp/err")"
routes "GET /accounts/accOLD/pages/projects unauthorized.json:403" "GET /accounts\\? accounts-two.json"
echo '{"accountId":"accOLD"}' > "$DEPLOYS_CONFIG/cloudflare.json"
out="$(CLOUDFLARE_ACCOUNT_ID='' cf list 2>&1)"; rc=$?
expect "account: several accounts: the choice stays, the error shows" "$rc:$(jq -r .accountId "$DEPLOYS_CONFIG/cloudflare.json")" "1:accOLD"
routes "GET /pages/projects\\? unauthorized.json:403"
out="$(cf list 2>&1)"; rc=$?
expect "account: from the environment it is never forgotten" "$rc:$(calls '^GET /accounts?')" "1:0"
routes "GET /user/tokens/verify token-active.json"
echo "{\"accountId\":\"accOLD\",\"selftests\":{}}" > "$DEPLOYS_CONFIG/cloudflare.json"
echo good | (unset CLOUDFLARE_API_TOKEN; cf set-key) >/dev/null 2>&1
expect "set-key: the remembered account is forgotten" "$(jq -c '[.accountId, .selftests]' "$DEPLOYS_CONFIG/cloudflare.json")" '[null,{}]'

# --- doctor ---
routes "GET /user/tokens/verify token-active.json"
out="$(cf doctor)"
expect "doctor: unverified by default" "$(echo "$out" | jq -c '[.tokenSource, .tokenValid, .account, .accountSource, .deployWhileOff]')" "[\"environment\",true,\"$A\",\"environment\",\"unverified\"]"
[[ "$(echo "$out" | jq -r .note)" == unverified* ]] && ok "doctor: says unverified" || fail "doctor: says unverified" "$out"
out="$(CLOUDFLARE_API_TOKEN=bad cf doctor)"
expect "doctor: a rejected token" "$(echo "$out" | jq .tokenValid)" false

# --- status, latest, rollback, logs, url, cancel ---
routes "GET /deployments\\?per_page=1 deployments-prod.json" "GET /deployments/d-q$ deployment-build.json"
expect "latest: newest, mapped" "$(cf latest site | jq -c '[.id, .phase]')" '["d-fail","failed"]'
expect "status: one deployment" "$(cf status site d-q | jq -c '[.phase, .stage, .sha, .msg]')" '["building","build","cccc333","feat: new"]'
routes "GET /pages/projects/site$ project-on.json" "GET /deployments\\?env=production deployments-prod.json" "POST /deployments/[^/]+/rollback$ rollback.json"
out="$(cf rollback site)"
expect "rollback: to the newest good one before live" "$(grep -o 'POST [^ ]*' "$CALLS" | sed 's|.*/deployments/||')" "d-old/rollback"
expect "rollback: answer" "$(echo "$out" | jq -c '[.id, .state]')" '["d-old2","building"]'
: > "$CALLS"; cf rollback site d-x >/dev/null
expect "rollback: to a given one" "$(grep -c 'deployments/d-x/rollback' "$CALLS")" 1
routes "GET /deployments/d-q/history/logs logs.json"
expect "logs: the last lines" "$(cf logs site 2 d-q | sed 's/.*  //' | tr '\n' '|')" "Building|Success: Assets published!|"
routes "GET /pages/projects/site$ project-on.json"
expect "url: the site" "$(cf url site)" "https://www.example.com"
expect "url: the dashboard" "$(cf url site --dashboard)" "https://dash.cloudflare.com/$A/pages/view/site"
out="$(cf cancel site 2>&1)"; rc=$?
expect "cancel: not offered" "$rc" 1

# --- set-key ---
routes "GET /user/tokens/verify token-active.json"
out="$(echo "good-token" | CLOUDFLARE_API_TOKEN='' cf set-key)"; rc=$?
expect "set-key: saved" "$rc/$(calls 'security -i')" "0/1"
: > "$CALLS"; out="$(echo "bad" | CLOUDFLARE_API_TOKEN='' cf set-key 2>&1)"; rc=$?
expect "set-key: a rejected token is not saved" "$rc/$(calls 'security -i')" "1/0"
[[ "$(grep -v '^GET' "$CALLS")" != *good-token* ]] && ok "set-key: token never in an argument" || fail "set-key: token in args" "$(cat "$CALLS")"
out="$(printf '' | CLOUDFLARE_API_TOKEN='' cf set-key 2>&1)"; rc=$?
expect "set-key: empty input" "$rc" 1

# --- the shared contract, once it exists ---
has() { case "$2" in *"$3"*) ok "$1" ;; *) fail "$1" "[$3] not in: $2" ;; esac; }
# --- PRV-130: with deploys' http_call, JSON calls go through it; a form keeps the own path ---
# shellcheck source=../fixtures/http/stub.sh
. tests/fixtures/http/stub.sh
routes "GET /user/tokens/verify$ token-active.json"
out="$( http_stub; cf_call GET /user/tokens/verify 2>"$tmp/err" | jq -r '.status' )"
expect "PRV-130: .result read after http_call" "$out" active
has "PRV-130: http_call with the bearer header and a fix" "$(cat "$CALLS")" "http_call Cloudflare GET https://api.cloudflare.com/client/v4/user/tokens/verify auth[bearer] fix[set]"
routes "POST /deployments$ deploy-queued.json"
( http_stub; cf_call POST "/accounts/$A/pages/projects/site/deployments" --form-string "branch=main" >/dev/null 2>&1 )
expect "PRV-130: a form is not sent through http_call" "$(calls '^http_call')" 0
routes "GET /user/tokens/verify$ unauthorized.json:200"
out="$( http_stub; cf_call GET /user/tokens/verify 2>&1 )"; rc=$?
expect "PRV-130: success:false with a 2xx still fails" "$rc" 1
has "PRV-130: with Cloudflare's own error text" "$out" "Cloudflare GET /user/tokens/verify:"

if [ -f tests/providers/contract.sh ]; then bash tests/providers/contract.sh cloudflare || fails=$((fails+1)); fi

echo
[ "$fails" = 0 ] && echo "All Cloudflare tests passed." || { echo "$fails failed."; exit 1; }
