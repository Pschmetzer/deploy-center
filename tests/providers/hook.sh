#!/bin/bash
# Tests for providers/hook.sh, the generic deploy-hook provider.
# No network: curl, gh and security are stand-ins. Run: bash tests/providers/hook.sh
set -uo pipefail
cd "$(dirname "$0")/../.." || exit 1
fails=0
ok()   { echo "ok   $1"; }
fail() { echo "FAIL $1: $2"; fails=$((fails+1)); }
expect() { [ "$2" = "$3" ] && ok "$1" || fail "$1" "expected [$3], got [$2]"; }

tmp="$(mktemp -d)"; trap 'rm -rf "$tmp"' EXIT
export DEPLOYS_CONFIG="$tmp/config" DEPLOYS_LIB=1 DEPLOYS_HOOK_STORE=file
export CALLS="$tmp/calls.log" CURLCFG="$tmp/curl.cfg"
mkdir -p "$tmp/bin"

# curl as the provider calls it: `curl -K -`, the config on stdin. The config is kept so the
# tests can see what was sent; argv is logged so they can see the URL was not on it.
# HOOKSTUB: 204 (default), 500, down.
cat > "$tmp/bin/curl" <<'CURL'
#!/bin/bash
cat > "$CURLCFG"
echo "curl $*" >> "$CALLS"
case "${HOOKSTUB:-204}" in
  down) echo "curl: (6) Could not resolve host: hooks.example.com" >&2; printf '000'; exit 6 ;;
  *) printf '%s' "${HOOKSTUB:-204}" ;;
esac
CURL
# gh: the branch head is GH_HEAD (aaaa, then bbbb); bbbb is 3 commits past aaaa.
cat > "$tmp/bin/gh" <<'GH'
#!/bin/bash
echo "gh $*" >> "$CALLS"
case "$*" in
  *rate_limit*) echo '{"limit":5000,"remaining":4000,"reset":0}' | jq "${@: -1}" 2>/dev/null ;;
  *"repos/me/app/commits/main"*) printf '{"sha":"%s","commit":{"message":"head %s\\nbody","committer":{"date":"2026-01-02T00:00:00Z"}}}\n' "${GH_HEAD:-aaaa}" "${GH_HEAD:-aaaa}" ;;
  *"repos/me/app/compare/aaaa...main"*) echo '{"ahead_by":3,"status":"ahead","commits":[
      {"sha":"c1","commit":{"message":"fix: one (#11)","committer":{"date":"2026-01-01T00:00:00Z"}}},
      {"sha":"c2","commit":{"message":"feat: two (#12)","committer":{"date":"2026-01-01T01:00:00Z"}}},
      {"sha":"bbbb","commit":{"message":"head bbbb","committer":{"date":"2026-01-02T00:00:00Z"}}}]}' ;;
  *"pulls?state=open"*) echo '{"key":"me/app","value":{"all":0,"drafts":0,"bots":0}}' ;;
  *) exit 1 ;;
esac
GH
# security: a keychain in a folder, so the keychain path is tested on Linux too.
cat > "$tmp/bin/security" <<'SEC'
#!/bin/bash
kc="$KCDIR"; mkdir -p "$kc"; echo "security $*" >> "$CALLS"
svc=""; prev=""; for a in "$@"; do [ "$prev" = -s ] && svc="$a"; prev="$a"; done
case "$1" in
  -i) read -r line; svc="$(echo "$line" | sed -E 's/.* -s ([^ ]+) .*/\1/')"; pw="$(echo "$line" | sed -E 's/.* -w "(.*)"$/\1/')"
      printf '%s' "$pw" > "$kc/$svc" ;;
  find-generic-password) [ -f "$kc/$svc" ] || exit 44; [ "${*: -1}" = -w ] && cat "$kc/$svc"; exit 0 ;;
  delete-generic-password) rm -f "$kc/$svc" ;;
esac
SEC
chmod +x "$tmp/bin"/*
export PATH="$tmp/bin:$PATH" KCDIR="$tmp/keychain"

# shellcheck source=../../deploys
. ./deploys
# shellcheck source=../../providers/hook.sh
. ./providers/hook.sh
set +e

SECRET="https://hooks.example.com/deploy/s3cr3t-T0KEN-abc"
leaks() { grep -c 's3cr3t' <<< "$1"; }

# --- contract shape ---
expect "meta names the provider" "$(hook_meta | jq -r .name)" "hook"
expect "every cap is false" "$(hook_meta | jq -c '.caps | [.off, .sha, .cancel, .rollback, .logs, .preview] | unique')" "[false]"
for f in meta ready json has off deploy_json status latest cancel rollback logs url set_key doctor; do
  declare -F "hook_$f" >/dev/null || fail "contract function hook_$f" "missing"
done
ok "all contract functions are defined"
hook_ready; expect "not ready without hooks (opt-in)" "$?" "1"
expect "an empty list without hooks" "$(DEPLOYS_NO_GITHUB=1 hook_json | jq -c .)" "[]"

# --- add / list / remove ---
out="$(echo "$SECRET" | hook_cli add site - --repo me/app --site https://example.com 2>&1)"
expect "add from stdin" "$?:$(leaks "$out")" "0:0"
expect "add says the masked URL" "$out" "Hook site added (https://hooks.example.com/•••)."
expect "the URL is in a 0600 file" "$(stat -c %a "$DEPLOYS_CONFIG/hook-urls/site" 2>/dev/null || stat -f %Lp "$DEPLOYS_CONFIG/hook-urls/site")" "600"
expect "the URL is not in hooks.json" "$(leaks "$(cat "$DEPLOYS_CONFIG/hooks.json")")" "0"
expect "repo and ref default" "$(jq -c '.[0] | [.name, .method, .repo, .ref, .site]' "$DEPLOYS_CONFIG/hooks.json")" '["site","POST","me/app","main","https://example.com"]'
hook_ready; expect "ready with a hook" "$?" "0"
hook_cli add other "https://hooks.example.com/other/s3cr3t-2" >/dev/null
out="$(hook_cli list)"
expect "list shows both hooks" "$(grep -c -E '^(site|other)' <<< "$out")" "2"
expect "list never shows a URL" "$(leaks "$out")" "0"
expect "list shows repo@ref" "$(grep -c 'me/app@main' <<< "$out")" "1"
# PRV-124: a second add changes what it is given and keeps the rest (and says so).
hook_cli add other "https://hooks.example.com/other/s3cr3t-2" --method PUT --header 'X-Env: prod' --body '{"a":1}' --repo me/other --ref dev --site https://other.example.com >/dev/null
out="$(hook_cli add other "https://hooks.example.com/other/s3cr3t-3" --header 'X-Team: web')"
expect "add again: the rest is kept" "$(jq -c '.[] | select(.name=="other") | [.method, .headers, .body, .repo, .ref, .site]' "$DEPLOYS_CONFIG/hooks.json")" \
  '["PUT",{"X-Env":"prod","X-Team":"web"},"{\"a\":1}","me/other","dev","https://other.example.com"]'
expect "add again: says what was kept, never the URL" "$out:$(leaks "$out")" "Hook other updated (https://hooks.example.com/•••); kept: method PUT; headers X-Env; body; repo me/other; ref dev; site https://other.example.com.:0"
hook_cli add other "https://hooks.example.com/other/s3cr3t-3" --ref main --method post >/dev/null
expect "add again: what is given changes" "$(jq -c '.[] | select(.name=="other") | [.method, .repo, .ref]' "$DEPLOYS_CONFIG/hooks.json")" '["POST","me/other","main"]'
out="$(hook_cli remove other)"
expect "remove" "$?:$(hook_list_raw | jq -r 'map(.name) | join(",")')" "0:site"
expect "remove deletes the stored URL" "$([ -e "$DEPLOYS_CONFIG/hook-urls/other" ] && echo kept || echo gone)" "gone"
out="$(hook_cli remove nope 2>&1)"; expect "remove of an unknown hook fails" "$?:$(grep -c 'No hook named' <<< "$out")" "1:1"

# --- refusals ---
out="$(hook_cli add bad "http://hooks.example.com/x" 2>&1)"; expect "plain http is refused" "$?" "1"
for u in http://localhost.evil.example/x http://127.0.0.1.evil.example/x http://user@localhost/x; do
  ( hook_check_url "$u" ) >/dev/null 2>&1; expect "plain http to $u is refused (not this Mac)" "$?" "1"
done
for u in http://localhost:3000/x http://127.0.0.1/x "http://[::1]:8080/x"; do
  ( hook_check_url "$u" ) >/dev/null 2>&1; expect "plain http to $u is allowed (this Mac)" "$?" "0"
done
expect "a body over several lines stays one config value" "$(hook_cq "$(printf '{\n  "ref": "main"\n}')")" '"{\n  \"ref\": \"main\"\n}"'
out="$(hook_cli add bad "not a url" 2>&1)"; expect "a non-URL is refused" "$?" "1"
out="$(hook_cli add 'bad name' "$SECRET" 2>&1)"; expect "a bad name is refused" "$?" "1"
out="$(hook_cli add bad "$SECRET" --header 'Authorization: Bearer abc123' 2>&1)"
expect "a literal secret in a header is refused" "$?:$(grep -c 'looks like a secret' <<< "$out")" "1:1"
out="$(hook_cli add bad "$SECRET" --header 'Authorization: Bearer abc123$x' 2>&1)"
expect "a secret with a \$ somewhere in it is still refused" "$?:$(grep -c 'looks like a secret' <<< "$out")" "1:1"
expect "nothing was saved by the refusals" "$(hook_list_raw | jq length)" "1"

# --- trigger: success ---
: > "$CALLS"
out="$(GH_HEAD=aaaa hook_deploy_json site 2>&1)"
expect "a 2xx trigger succeeds" "$?:$(echo "$out" | jq -r '"\(.phase) \(.state) \(.http) \(.sha)"')" "0:ready triggered 204 aaaa"
expect "the URL was not on curl's command line" "$(leaks "$(cat "$CALLS")")" "0"
expect "the URL went to curl on stdin" "$(grep -c "^url = \"$SECRET\"" "$CURLCFG")" "1"
expect "POST is the default method" "$(grep -c '^request = "POST"' "$CURLCFG")" "1"
expect "the state records sha and time" "$(jq -c '.site | [.ok, .sha, .msg, (.at > 0)]' "$DEPLOYS_CONFIG/hook-state.json")" '[true,"aaaa","head aaaa",true]'
j="$(DEPLOYS_NO_GITHUB=1 hook_json | jq -c '.[0]')"
expect "json after a trigger: ready, triggered" "$(echo "$j" | jq -r '"\(.phase) \(.lastState) \(.lastSha) \(.domain)"')" "ready triggered aaaa example.com"
expect "json has every contract field" "$(echo "$j" | jq -c '[has("name","id","auto","deployable","paused","repo","ref","domain","url","dashboardUrl","lastAt","lastState","lastSha","lastMsg","fetchError","phase")] | unique')" "[true]"
expect "json never has a URL" "$(leaks "$(hook_json)")" "0"
expect "status after a trigger" "$(hook_cli_status site | jq -r .phase):$(hook_status site | cut -f2,3)" "ready:ready	triggered"

# --- waiting commits since the last trigger, with repo set ---
j="$(GH_HEAD=aaaa provider_json hook | jq -c '.[0]')"
expect "branch at the triggered commit: nothing waiting" "$(echo "$j" | jq -c '[.changed, .pendingCommits]')" "[false,0]"
j="$(GH_HEAD=bbbb provider_json hook | jq -c '.[0]')"
expect "three commits since the last trigger: changed" "$(echo "$j" | jq -c '[.changed, .pendingCommits, .pendingPRs, .headSha]')" '[true,3,2,"bbbb"]'

# A second trigger within a minute is refused (the start lock), and nothing is sent.
mkdir -p "$tmp/t"
out="$(TMPDIR="$tmp/t" hook_deploy_json site 2>&1)"
expect "a second trigger within a minute is refused" "$?:$(grep -c 'being started already' <<< "$out"):$(grep -c '^curl' "$CALLS")" "1:1:1"
expect "a refused trigger leaves no config (it holds the URL)" "$(find "$tmp/t" -type f | wc -l | tr -d ' ')" "0"
unlock() { rm -rf "$DEPLOYS_CONFIG/locks"; }

# --- trigger: failure ---
unlock; out="$(HOOKSTUB=500 GH_HEAD=bbbb hook_deploy_json site 2>&1)"
expect "a 500 is a failed trigger" "$?:$(grep -c 'did not start a build: HTTP 500' <<< "$out")" "1:1"
expect "the failure message never has the URL" "$(leaks "$out")" "0"
j="$(DEPLOYS_NO_GITHUB=1 hook_json | jq -c '.[0]')"
expect "json after a failure: failed, last good sha kept" "$(echo "$j" | jq -r '"\(.phase)|\(.lastState)|\(.lastSha)"')" "failed|trigger failed (HTTP 500)|aaaa"
unlock; out="$(HOOKSTUB=down hook_deploy_json site 2>&1)"
expect "no answer is a failed trigger" "$?:$(grep -c 'no answer' <<< "$out")" "1:1"
expect "curl was asked once per trigger (never retried)" "$(grep -c '^curl' "$CALLS")" "3"

# --- headers from the environment ---
hook_cli add ci "https://api.github.com/repos/me/app/actions/workflows/deploy.yml/dispatches" \
  --header 'Authorization: Bearer $GH_DISPATCH' --header 'Accept: application/vnd.github+json' --body '{"ref":"main"}' >/dev/null
out="$(env -u GH_DISPATCH bash -c '. ./deploys; . ./providers/hook.sh; hook_deploy_json ci' 2>&1)"
expect "an unset header variable stops the trigger" "$?:$(grep -c 'needs $GH_DISPATCH' <<< "$out")" "1:1"
unlock; out="$(GH_DISPATCH=tok-s3cr3t hook_deploy_json ci 2>&1)"
expect "a header variable is expanded" "$?:$(grep -c '^header = "Authorization: Bearer tok-s3cr3t"' "$CURLCFG")" "0:1"
expect "the body is sent as JSON" "$(grep -c '^data = "{\\"ref\\":\\"main\\"}"' "$CURLCFG")" "1"
expect "the token is not in hooks.json" "$(leaks "$(cat "$DEPLOYS_CONFIG/hooks.json")")" "0"
expect "the token is not in the trigger's answer" "$(leaks "$out")" "0"
expect "expansion is not eval" "$(X='$(touch '"$tmp"'/pwned)' hook_expand 'a $X b'; [ -e "$tmp/pwned" ] && echo " pwned")" 'a $(touch '"$tmp"'/pwned) b'

# --- caps that are false die ---
for f in off cancel rollback logs; do
  out="$("hook_$f" site 2>&1)"; expect "hook_$f dies" "$?" "1"
done
expect "off says to do it at the host" "$(hook_off site 2>&1 | grep -c 'setting at the host')" "1"
expect "url is the site, not the hook" "$(hook_url site)" "https://example.com"

# --- doctor masks ---
out="$(hook_doctor)"
expect "doctor lists hooks, masked" "$(echo "$out" | jq -r '.hooks | map(.url) | join(" ")')" "https://api.github.com/••• https://hooks.example.com/•••"
expect "doctor never has a URL or token" "$(leaks "$out"):$(grep -c dispatches <<< "$out")" "0:0"

# --- set-key rotates ---
echo "https://hooks.example.com/deploy/new-s3cr3t" | hook_set_key site >/dev/null
expect "set-key replaces the URL" "$(cat "$DEPLOYS_CONFIG/hook-urls/site")" "https://hooks.example.com/deploy/new-s3cr3t"
rm -f "$DEPLOYS_CONFIG/hook-urls/site"
expect "a missing URL is a fetchError, not deployable" "$(DEPLOYS_NO_GITHUB=1 hook_json | jq -c '.[] | select(.name=="site") | [.deployable, (.fetchError != null)]')" "[false,true]"

# --- keychain store ---
export DEPLOYS_HOOK_STORE=keychain
: > "$CALLS"
echo "$SECRET" | hook_cli add kc - >/dev/null
expect "keychain: stored under deploy-center-hook-<name>" "$(cat "$KCDIR/deploy-center-hook-kc" 2>/dev/null)" "$SECRET"
expect "keychain: the URL was not on security's command line" "$(leaks "$(cat "$CALLS")")" "0"
unlock; out="$(hook_deploy_json kc 2>&1)"; expect "keychain: trigger reads it" "$?" "0"
hook_cli remove kc >/dev/null
expect "keychain: remove deletes it" "$([ -e "$KCDIR/deploy-center-hook-kc" ] && echo kept || echo gone)" "gone"

# --- run directly, as `deploys hook …` will ---
export DEPLOYS_HOOK_STORE=file
out="$(env -u DEPLOYS_LIB bash providers/hook.sh list 2>&1)"
expect "providers/hook.sh runs on its own" "$?:$(grep -c '^ci' <<< "$out")" "0:1"

echo
if [ "$fails" = 0 ]; then echo "All hook provider tests passed."; else echo "$fails failed."; exit 1; fi
