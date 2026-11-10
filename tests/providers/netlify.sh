#!/bin/bash
# Tests for providers/netlify.sh. No network: curl, gh, security and sleep are stand-ins.
# curl answers from tests/fixtures/netlify/routes. Run: bash tests/providers/netlify.sh
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
FIX="$PWD/tests/fixtures/netlify"
export FIX DEPLOYS_CONFIG="$tmp/config" CALLS="$tmp/calls.log" FAKE_STATE="$tmp/state"
export NETLIFY_AUTH_TOKEN="tok-secret-123" DEPLOYS_NETLIFY_POLLS=3 USER=tester
mkdir -p "$tmp/bin" "$FAKE_STATE"

# curl: the method and URL are logged, the -K config read from stdin (the token goes there),
# the answer comes from the routes file. FAKE_STATUS forces a status for every call.
cat > "$tmp/bin/curl" <<'CURL'
#!/bin/bash
m=GET; prev=""; data=""; for a in "$@"; do
  [ "$prev" = -X ] && m="$a"; [ "$prev" = --data ] && data="$a"; prev="$a"; done
url="${*: -1}"
conf="$(cat)"
echo "curl $m $url ARGS[$*] DATA[$data]" >> "$CALLS"
# The API gets the token on stdin; a build hook never does (it is a URL of its own).
case "$url" in
  https://api.netlify.com/build_hooks/*) case "$conf" in *Authorization*) echo "token sent to a build hook" >&2; exit 2 ;; esac ;;
  *) case "$conf" in *"Authorization: Bearer "*) ;; *) echo "no token on stdin" >&2; exit 2 ;; esac ;;
esac
if [ -n "${FAKE_STATUS:-}" ]; then printf '%s\n%s' "$(cat "$FIX/error-$FAKE_STATUS.json")" "$FAKE_STATUS"; exit 0; fi
case "$url" in https://api.netlify.com/build_hooks/*) touch "$FAKE_STATE/hooked" ;; esac
while read -r rm glob file status when; do
  case "$rm" in ''|'#'*) continue ;; esac
  [ "$rm" = "$m" ] || continue
  # shellcheck disable=SC2053
  [[ "$url" == $glob ]] || continue
  [ "${when:-}" = hooked ] && [ ! -f "$FAKE_STATE/hooked" ] && continue
  printf '%s\n%s' "$(cat "$FIX/$file")" "${status:-200}"; exit 0
done < "$FIX/routes"
printf '%s\n404' '{"code":404,"message":"Not Found"}'
CURL
# gh: only repo contents and the repo itself.
cat > "$tmp/bin/gh" <<'GH'
#!/bin/bash
echo "gh $*" >> "$CALLS"
case "$*" in
  "api repos/me/shop/contents/netlify.toml?ref=main") cat "$FIX/gh-contents-shop.json" ;;
  "api repos/me/blog/contents/site/netlify.toml?ref=trunk") cat "$FIX/gh-contents-blog.json" ;;
  "api repos/me/"*/contents/*) echo "gh: Not Found (HTTP 404)" >&2; exit 1 ;;
  "api repos/me/"*) echo '{}' ;;
  *) exit 1 ;;
esac
GH
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
reset() { : > "$CALLS"; rm -f "$FAKE_STATE/hooked"; }

# shellcheck source=../../providers/netlify.sh
. ./providers/netlify.sh

# --- contract ---
for f in meta ready json has off deploy_json status latest cancel rollback logs url set_key doctor; do
  declare -F "netlify_$f" >/dev/null || fail "contract: netlify_$f" "not defined"
done
ok "contract: all 14 functions defined"
meta="$(netlify_meta)"
expect "meta: shape" "$(echo "$meta" | jq -c '[.id, .label, .keyEnv, .keychain, (.caps | keys)]')" \
  '["netlify","Netlify",["NETLIFY_AUTH_TOKEN"],"deploy-center-netlify",["cancel","logs","off","preview","rollback","sha"]]'
expect "meta: no sha, no logs, no previews" "$(echo "$meta" | jq -c '[.caps.sha, .caps.logs, .caps.preview, .caps.off]')" '[false,false,false,true]'
netlify_ready && ok "ready: with a token" || fail "ready" "not ready with NETLIFY_AUTH_TOKEN set"
( unset NETLIFY_AUTH_TOKEN; netlify_ready ) && fail "ready without token" "said ready" || ok "ready: not without a token"

# --- phases ---
for pair in new:queued enqueued:queued building:building uploading:building processing:building \
            ready:ready error:failed rejected:failed canceled:canceled skipped:canceled; do
  got="$(jq -rn --arg s "${pair%%:*}" "$NETLIFY_JQ"'$s | phase')"
  [ "$got" = "${pair#*:}" ] || fail "phase ${pair%%:*}" "expected ${pair#*:}, got $got"
done
ok "phase: every Netlify state maps to queued|building|ready|failed|canceled"

# --- json: shop is turned off and confirmed, the others are not ---
reset
mkdir -p "$DEPLOYS_CONFIG"
echo '{"site-shop":{"hookId":"hook-shop","url":"https://api.netlify.com/build_hooks/hook-shop","rule":true}}' > "$DEPLOYS_CONFIG/netlify-hooks.json"
out="$(DEPLOYS_NO_GITHUB=1 netlify_json)"; rc=$?
expect "json: exit 0" "$rc" 0
expect "json: sorted names" "$(echo "$out" | jq -c 'map(.name)')" '["blog","Paused","shop","static"]'
expect "json: every contract field on every site" "$(echo "$out" | jq -c 'map(keys) | unique')" \
  '[["auto","dashboardUrl","deployable","domain","fetchError","id","lastAt","lastMsg","lastSha","lastState","name","paused","phase","ref","repo","url"]]'
expect "json: phases are contract phases" "$(echo "$out" | jq '[.[].phase] - ["queued","building","ready","failed","canceled",null] | length')" 0
shop="$(echo "$out" | jq -c '.[] | select(.name=="shop")')"
expect "json: shop off and deployable" "$(echo "$shop" | jq -c '[.auto, .deployable, .paused]')" '[false,true,false]'
expect "json: shop repo, ref, domain" "$(echo "$shop" | jq -c '[.repo, .ref, .domain, .url, .dashboardUrl]')" \
  '["me/shop","main","shop.example.com","https://shop.example.com","https://app.netlify.com/sites/shop"]'
expect "json: a skipped build is not the last deploy" "$(echo "$shop" | jq -c '[.lastState, .phase, .lastAt]')" '["building","building",1793703600]'
expect "json: the commit is what is live" "$(echo "$shop" | jq -c '[.lastSha, .lastMsg]')" '["2222222","feat: cart"]'
blog="$(echo "$out" | jq -c '.[] | select(.name=="blog")')"
expect "json: no ignore rule -> auto, not deployable" "$(echo "$blog" | jq -c '[.auto, .deployable]')" '[true,false]'
expect "json: blog failed, netlify.app domain" "$(echo "$blog" | jq -c '[.phase, .domain]')" '["failed","blog-123.netlify.app"]'
expect "json: stop_builds is paused, never deployable" "$(echo "$out" | jq -c '.[] | select(.name=="Paused") | [.paused, .deployable, .phase, .repo]')" '[true,false,"queued","me/paused"]'
expect "json: no repo -> not auto, not deployable" "$(echo "$out" | jq -c '.[] | select(.name=="static") | [.auto, .deployable, .repo, .phase]')" '[false,false,null,"canceled"]'
expect "json: no GitHub calls with DEPLOYS_NO_GITHUB" "$(calls '^gh ')" 0
expect "json: token never in curl arguments" "$(calls tok-secret-123)" 0

# --- off: a site without the rule gets a hook and the snippet, but is not deployable ---
reset
out="$(netlify_off blog 2>&1)"; rc=$?
expect "off blog: exit 0" "$rc" 0
expect "off blog: created the hook" "$(calls 'curl POST .*/sites/site-blog/build_hooks')" 1
has "off blog: hook created on the site's branch" "$(grep 'build_hooks ARGS' "$CALLS")" '"branch":"trunk"'
has "off blog: prints the exact line" "$out" "ignore = \"[ -z \\\"\$INCOMING_HOOK_TITLE\\\" ]\""
has "off blog: in the base directory" "$out" "site/netlify.toml in me/blog (trunk)"
has "off blog: says why" "$out" "INCOMING_HOOK_TITLE is only set when a build hook started the build"
has "off blog: says the next step" "$out" "Not found in me/blog yet"
hf="$DEPLOYS_CONFIG/netlify-hooks.json"
expect "off blog: hook URL stored, rule false" "$(jq -c '."site-blog" | [.url, .rule, .repo, .ref, .base]' "$hf")" \
  '["https://api.netlify.com/build_hooks/hook-blog",false,"me/blog","trunk","site"]'
expect "off blog: hooks file is private" "$(stat -c %a "$hf" 2>/dev/null || stat -f %Lp "$hf")" 600
has "off blog: hook URL never printed" "x$(echo "$out" | grep -c build_hooks/hook-blog)" "x0"
out="$(DEPLOYS_NO_GITHUB=1 netlify_json | jq -c '.[] | select(.name=="blog") | [.auto, .deployable]')"
expect "off blog: still auto and not deployable" "$out" '[true,false]'
out="$(netlify_deploy_json blog 2>&1)"; rc=$?
expect "deploy blog: refused" "$rc" 1
has "deploy blog: says why" "$out" "ignore rule was not found"

# --- off: the rule is in the repo, the hook exists already ---
reset
out="$(netlify_off shop 2>&1)"; rc=$?
expect "off shop: exit 0" "$rc" 0
expect "off shop: existing hook reused" "$(calls 'curl POST .*/build_hooks ')" 0
has "off shop: done" "$out" "no longer deploys on push"
expect "off shop: rule recorded" "$(jq -c '."site-shop" | [.rule, .hookId, (.ruleAt|type), (.offAt|type)]' "$hf")" '[true,"hook-shop","number","number"]'
# A rule added to a repo gh cannot read can be recorded by hand.
reset
( netlify_off blog --rule-added >/dev/null 2>&1 )
expect "off --rule-added: recorded" "$(jq '."site-blog".rule' "$hf")" true
expect "off --rule-added: gh not asked" "$(calls '^gh api repos/me/blog/contents')" 0
# The rule counts only as our exact line in [build].
rule() { printf '%b' "$1" | netlify_rule_in_build && echo yes || echo no; }
expect "rule: our line in [build]" "$(rule '[build]\n  command = "x"\n  ignore = "[ -z \\"$INCOMING_HOOK_TITLE\\" ]"\n')" yes
expect "rule: the same line under a context does not count" "$(rule '[build]\n  command = "x"\n[context.deploy-preview]\n  ignore = "[ -z \\"$INCOMING_HOOK_TITLE\\" ]"\n')" no
expect "rule: a reversed test does not count" "$(rule '[build]\n  ignore = "[ -n \\"$INCOMING_HOOK_TITLE\\" ]"\n')" no
# --all: each site, one failing does not stop the next, and the exit code says so.
out="$( netlify_sites() { echo '[{"id":"s-a"},{"id":"s-b"}]'; }; netlify_off_one() { echo "off $1"; [ "$1" = s-b ]; }
        netlify_off --all 2>&1 )"; rc=$?
expect "off --all: every site, the failure counted" "$rc:$(grep -c '^off s-' <<< "$out"):$(grep -c '1 Netlify sites could not' <<< "$out")" "1:2:1"
jq '."site-blog".rule = false' "$hf" > "$tmp/h" && mv "$tmp/h" "$hf"
# json re-checks unconfirmed sites on GitHub; blog still has no rule there.
reset
out="$(netlify_json | jq -c '.[] | select(.name=="blog") | .auto')"
expect "json: re-checks an unconfirmed site" "$(calls 'gh api repos/me/blog/contents/site/netlify.toml')" 1
expect "json: still auto after the re-check" "$out" true
# PRV-044: the re-check is remembered for ten minutes; a PR that is never merged costs nothing.
expect "json: the re-check is written down" "$(jq '."site-blog".ruleCheckedAt | type' "$hf")" '"number"'
reset; netlify_json >/dev/null
expect "json: no second GitHub check within ten minutes" "$(calls 'gh api repos/me/blog/contents')" 0
reset; DEPLOYS_NETLIFY_RULE_TTL=0 netlify_json >/dev/null
expect "json: DEPLOYS_NETLIFY_RULE_TTL=0 checks every time" "$(calls 'gh api repos/me/blog/contents/site/netlify.toml')" 1
# PRV-043: the deploys of all four sites are read (in parallel), each one once, every site listed.
reset; out="$(netlify_json)"
expect "json: every site's deploys read once" "$(calls '/deploys?production=true'):$(echo "$out" | jq -c '[.[].name]')" '4:["blog","Paused","shop","static"]'

# --- PRV-047: a broken hooks file is kept as .bak and started again; edits are locked ---
cp "$hf" "$tmp/hooks.good"
echo '{"site-shop": {"url": ' > "$hf"
out="$(netlify_hooks_file 2>&1 >/dev/null)"
expect "hooks file: broken one kept as .bak, 0600" "$(head -c 13 "$hf.bak"):$(stat -f %Lp "$hf.bak" 2>/dev/null || stat -c %a "$hf.bak")" '{"site-shop"::600'
expect "hooks file: started again as {}" "$(cat "$hf")" '{}'
has "hooks file: says so" "$out" "kept as"
cp "$tmp/hooks.good" "$hf"; rm -f "$hf.bak"
mkdir "$hf.lock"
out="$(netlify_hooks_edit '.x = 1' 2>&1)"; rc=$?
expect "hooks edit: a held lock is waited for, then refused" "$rc:$(jq -r '.x // "unchanged"' "$hf")" "1:unchanged"
touch -t 202001010000 "$hf.lock"
netlify_hooks_edit '.x = 1' 2>/dev/null
expect "hooks edit: a crashed run's old lock is taken over" "$(jq -r '.x' "$hf"):$([ -d "$hf.lock" ] && echo held || echo free)" "1:free"
jq 'del(.x)' "$hf" > "$tmp/h" && mv "$tmp/h" "$hf"

# --- PRV-048: a hook made for another branch is moved (PUT, same URL), and not deployable until then ---
mkdir -p "$tmp/fx48"; cp -R "$FIX"/. "$tmp/fx48/"
jq -c '.[0].branch = "old"' "$FIX/hooks-shop.json" > "$tmp/fx48/hooks-shop.json"
printf 'PUT   */api/v1/sites/site-shop/build_hooks/hook-shop   empty.json  204\n' | cat - "$FIX/routes" > "$tmp/fx48/routes"
jq '."site-shop".ref = "old"' "$hf" > "$tmp/h" && mv "$tmp/h" "$hf"
expect "json: a hook for another branch is not deployable" "$(netlify_json | jq -c '.[] | select(.name=="shop") | .deployable')" false
reset; out="$(FIX="$tmp/fx48" netlify_off shop 2>&1)"
expect "off: the hook is moved to the branch" "$(calls 'curl PUT .*/build_hooks/hook-shop ')" 1
has "off: says so" "$out" "now builds main"
expect "off: stored for the new branch, same URL" "$(jq -c '."site-shop" | [.ref, .url]' "$hf")" '["main","https://api.netlify.com/build_hooks/hook-shop"]'
reset; netlify_off shop >/dev/null 2>&1
expect "off: a hook on the right branch is not touched" "$(calls 'curl PUT ')" 0

# --- PRV-096: how long a 429 waits ---
printf 'HTTP/2 429\r\nRetry-After: 12\r\n\r\n' > "$tmp/h1"
printf 'HTTP/2 429\r\nX-RateLimit-Reset: %s\r\n\r\n' "$(( $(date +%s) + 20 ))" > "$tmp/h2"
printf 'HTTP/2 429\r\nretry-after: 900\r\n\r\n' > "$tmp/h3"
: > "$tmp/h4"
w2="$(netlify_wait 1 "$tmp/h2")"
expect "429: Retry-After, the reset time, at most 30 s, else 3 s then 6 s" \
  "$(netlify_wait 1 "$tmp/h1"):$([ "$w2" -ge 19 ] && [ "$w2" -le 20 ] && echo reset):$(netlify_wait 1 "$tmp/h3"):$(netlify_wait 1 "$tmp/h4"):$(netlify_wait 2 "$tmp/h4")" "12:reset:30:3:6"

# --- deploy: post to the hook, find the new deploy by id ---
reset
out="$(netlify_deploy_json shop 2>&1)"; rc=$?
expect "deploy shop: exit 0" "$rc" 0
expect "deploy shop: the new deploy" "$(echo "$out" | jq -c '[.id, .phase, .url]')" '["d-shop-new","queued","https://d-shop-new--shop.netlify.app"]'
expect "deploy shop: one hook call" "$(calls 'curl POST https://api.netlify.com/build_hooks/hook-shop')" 1
out="$(netlify_deploy_json shop --sha abc123 2>&1)"; rc=$?
expect "deploy --sha: refused" "$rc" 1
has "deploy --sha: says why" "$out" "not supported"
out="$(netlify_deploy_json shop --preview 2>&1)"; rc=$?
expect "deploy --preview: refused" "$rc" 1

# --- status, latest, cancel, rollback, logs, url, has ---
reset
expect "status" "$(netlify_status_json d-shop-3 | jq -c '[.id, .phase, .sha, .dashboardUrl]')" \
  '["d-shop-3","building","3333333","https://app.netlify.com/sites/shop/deploys/d-shop-3"]'
expect "status: site and deploy" "$(netlify_status_json shop d-shop-3 | jq -r .id)" d-shop-3
expect "latest: skips the skipped build" "$(netlify_latest_json shop | jq -r .id)" d-shop-3
expect "status: the contract line" "$(netlify_status shop d-shop-3)" "d-shop-3	building	building"
for u in "https://github.com/me/app.git|me/app" "https://gitlab.com/g/sub/n|gitlab.com/g/sub/n" "https://bitbucket.org/o/r|bitbucket.org/o/r" "|null"; do
  expect "repo of ${u%%|*}: the git host's form" "$(jq -nr --arg u "${u%%|*}" "$NETLIFY_JQ"'{build_settings:{repo_url:(if $u == "" then null else $u end)}} | repo_of')" "${u#*|}"
done
expect "latest: the contract line" "$(netlify_latest shop | cut -f1,2)" "d-shop-3	building"
expect "has: gives the id" "$(netlify_has blog)" "site-blog"
out="$(netlify_cancel shop d-shop-3)"
expect "cancel: posted" "$(calls 'curl POST .*/deploys/d-shop-3/cancel')" 1
has "cancel: said" "$out" "canceled"
out="$(netlify_rollback shop)"; rc=$?
expect "rollback: exit 0" "$rc" 0
expect "rollback: restores the ready deploy before the live one" "$(calls 'curl POST .*/sites/site-shop/deploys/d-shop-1/restore')" 1
out="$(netlify_logs shop 2>&1)"
has "logs: points to the dashboard" "$out" "https://app.netlify.com/sites/shop/deploys/d-shop-3"
out="$(netlify_logs blog --id d-shop-3 2>&1)"
has "logs --id" "$out" "Deploy d-shop-3: building"
expect "url" "$(netlify_url shop)" https://shop.example.com
expect "url --dashboard" "$(netlify_url shop --dashboard)" https://app.netlify.com/sites/shop
netlify_has blog && ok "has: blog" || fail "has: blog" "not found"
netlify_has site-shop && ok "has: by id" || fail "has: by id" "not found"
netlify_has nope && fail "has: nope" "found" || ok "has: unknown site"

# --- 401: a wrong token is an error with a reason, never an empty list ---
reset
out="$(FAKE_STATUS=401 netlify_json 2>&1)"; rc=$?
expect "401: json exit 1" "$rc" 1
has "401: says the token is wrong" "$out" "the Netlify token is wrong or expired: check NETLIFY_AUTH_TOKEN"
has "401: Netlify's message" "$out" "Access Denied"
expect "401: not retried" "$(calls 'curl GET')" 1
out="$(FAKE_STATUS=401 netlify_doctor)"
expect "doctor 401" "$(echo "$out" | jq -c '[.key, .tokenOk, (.error | test("401"))]')" '["env",false,true]'
expect "doctor ok" "$(netlify_doctor | jq -c '[.provider, .key, .tokenOk, .sites, .gh]')" '["netlify","env",true,4,true]'
out="$( unset NETLIFY_AUTH_TOKEN; netlify_doctor )"
expect "doctor: no token" "$(echo "$out" | jq -c '[.key, .tokenOk]')" '["missing",false]'

# --- set_key: tried first, saved only when it works, never as an argument ---
reset
out="$(echo "bad-token" | FAKE_STATUS=401 netlify_set_key 2>&1)"; rc=$?
expect "set-key 401: exit 1" "$rc" 1
has "set-key 401: nothing saved" "$out" "nothing was saved"
expect "set-key 401: keychain untouched" "$(calls '^security')" 0
reset
out="$( unset NETLIFY_AUTH_TOKEN; echo "good-token" | netlify_set_key 2>&1 )"; rc=$?
expect "set-key: exit 0" "$rc" 0
expect "set-key: checked with /user" "$(calls 'curl GET .*/api/v1/user')" 1
expect "set-key: saved via stdin" "$(grep -c 'security -i STDIN\[add-generic-password -U -a tester -s deploy-center-netlify -w good-token\]' "$CALLS")" 1
expect "set-key: token never an argument" "$(grep -- 'good-token' "$CALLS" | grep -vc 'STDIN\[')" 0
out="$(printf '' | netlify_set_key 2>&1)"; rc=$?
expect "set-key: empty refused" "$rc" 1

echo
[ "$fails" = 0 ] && echo "All Netlify provider tests passed." || { echo "$fails failed."; exit 1; }
