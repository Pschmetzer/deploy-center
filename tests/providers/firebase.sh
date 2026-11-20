#!/bin/bash
# Tests for providers/firebase.sh. No network and no account: curl, security and sleep are
# stand-ins (tests/lib/fake-curl.sh answers from tests/fixtures/firebase). Run: bash tests/providers/firebase.sh
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
export FIREBASE_ACCESS_TOKEN="ya29.secret_token_123" FIREBASE_PROJECT=fixture-project
: > "$CALLS"
# shellcheck source=../../providers/firebase.sh
. ./providers/firebase.sh

expect "meta: roll back yes, cancel and logs no" "$(firebase_meta | jq -c '[.id, .keyEnv[0], .defaultOn, .caps.rollback, .caps.cancel, .caps.logs, .caps.sha]')" '["firebase","FIREBASE_ACCESS_TOKEN",false,true,false,false,false]'
j="$(firebase_json)"
expect "json: phases from the version of the live release" "$(echo "$j" | jq -cS 'map({(.name): .phase}) | add')" '{"alpha":"ready","beta":"building","delta":null,"gamma":"failed"}'
expect "json: url, dashboard, release type and the time of the release" "$(echo "$j" | jq -c '.[] | select(.name == "alpha") | [.url, .dashboardUrl, .releaseType, .lastAt, .lastMsg]')" '["https://alpha.web.app","https://console.firebase.google.com/project/fixture-project/hosting/sites/alpha","ROLLBACK",1772614800,"rollback"]'
expect "json: a site that never released is neither failed nor changed" "$(echo "$j" | jq -c '.[] | select(.name == "delta") | [.phase, .lastAt, .fetchError]')" "[null,null,null]"
expect "has" "$(firebase_has alpha):$(firebase_has nope >/dev/null; echo $?):$(: > "$CALLS"; firebase_has 'a/b' >/dev/null; echo $?:"$(grep -c '^curl' "$CALLS")")" "alpha:1:1:0"

# Without the project, nothing is called.
: > "$CALLS"; np="$(env -u FIREBASE_PROJECT bash -c '. ./providers/firebase.sh; firebase_json' 2>&1 | grep -c 'No Firebase project')"
expect "no project: said, nothing sent" "$np:$(grep -c '^curl' "$CALLS")" "1:0"
expect "a project id with odd characters is refused" "$(FIREBASE_PROJECT='a/b' firebase_project 2>&1)" 'Firebase: "a/b" is not a project id'

# deploy: roll forward to the newest finished version that is newer than the live one.
: > "$CALLS"
d="$(firebase_deploy_json alpha)"
expect "deploy: the release made, ready" "$(echo "$d" | jq -c '[.id, .phase, .url]')" '["r-new-3","ready","https://alpha.web.app"]'
expect "deploy: one POST, for the newest finished version (not the one still being created or deleted)" "$(grep '^curl POST' "$CALLS" | sed 's/.*versionName=//')" "sites/alpha/versions/bbb222"
for o in --sha --preview --no-cache; do
  : > "$CALLS"; msg="$( (firebase_deploy_json alpha $o x) 2>&1 )"
  has "deploy $o is refused" "$msg" "Firebase Hosting cannot"
  expect "deploy $o sends nothing" "$(grep -c '^curl' "$CALLS")" "0"
done
# Nothing newer than the live version: refused, nothing released.
rm -rf "$tmp/fx"; cp -R tests/fixtures "$tmp/fx"; export FIXTURES="$tmp/fx"
jq -c '.versions |= map(select(.name | endswith("aaa111")))' <(head -n 1 tests/fixtures/firebase/GET_v1beta1_sites_alpha_versions_pageSize_25.json) | { cat; echo 200; } > "$tmp/fx/firebase/GET_v1beta1_sites_alpha_versions_pageSize_25.json"
: > "$CALLS"
expect "deploy: no newer version is refused, no POST" "$( (firebase_deploy_json alpha) 2>&1 | grep -c 'nothing to roll forward'):$(grep -c '^curl POST' "$CALLS")" "1:0"
export FIXTURES="$PWD/tests/fixtures"

# rollback: the version that was live before the live one (alpha was rolled back to aaa111 from bbb222)
: > "$CALLS"
rb="$(firebase_rollback alpha)"
expect "rollback: the release made and what it goes back to" "$(echo "$rb" | jq -c '[.id, .phase, .message]')" '["r-new-3","ready","Firebase: going back to version bbb222"]'
expect "rollback: aimed at the version before the live one" "$(grep '^curl POST' "$CALLS" | sed 's/.*versionName=//')" "sites/alpha/versions/bbb222"
expect "rollback: a site with one release has nowhere to go" "$( (firebase_rollback beta) 2>&1 | grep -c 'no earlier version')" "1"

expect "status: a release id" "$(firebase_status alpha r-live-2)" "$(printf 'r-live-2\tready\tFINALIZED')"
expect "status: an odd id is refused before a call" "$(: > "$CALLS"; (firebase_status alpha '../x') >/dev/null 2>&1; echo $?:"$(grep -c '^curl' "$CALLS")")" "1:0"
expect "latest" "$(firebase_latest alpha)" "$(printf 'r-live-2\tready\tFINALIZED')"
expect "latest: a site without a release is none" "$(firebase_latest delta)" "$(printf 'none\t\t?')"
expect "url and dashboard" "$(firebase_url alpha):$(firebase_url alpha --dashboard)" "https://alpha.web.app:https://console.firebase.google.com/project/fixture-project/hosting/sites/alpha"

for f in "firebase_off alpha" "firebase_cancel alpha x" "firebase_logs alpha 10"; do
  : > "$CALLS"; msg="$( ($f) 2>&1 )"; rc=$?
  expect "$f is refused: $rc, nothing sent" "$rc:$(grep -c '^curl' "$CALLS")" "1:0"
  has "$f says so" "$msg" "Firebase Hosting cannot"
done

# The token travels on stdin only.
: > "$CALLS"; firebase_json >/dev/null
expect "the token is in no logged call" "$(grep -c 'ya29.secret_token_123' "$CALLS")" "0"
expect "a 401 says how to get a fresh token" "$( (CURLSTUB=401 firebase_json) 2>&1 | grep -c 'FIREBASE_ACCESS_TOKEN_CMD')" "1"

# set-key
: > "$CALLS"
expect "set-key saves a working token" "$(printf 'ya29.new\n' | firebase_set_key 2>&1 | tail -n 1 | cut -c1-34)" "Firebase access token saved and wo"
expect "set-key: the token went to security on stdin" "$(grep -c '^security -i STDIN\[add-generic-password .* -s deploy-center-firebase -w ya29.new\]' "$CALLS")" "1"
: > "$CALLS"
expect "set-key refuses a token Google does not take" "$(printf 'ya29.bad\n' | CURLSTUB=401 firebase_set_key 2>&1 | grep -c 'nothing was saved'):$(grep -c '^security -i' "$CALLS")" "1:0"
expect "set-key refuses a space or a quote" "$(printf 'a b\n' | firebase_set_key 2>&1 | grep -c 'does not look like'):$(printf 'a"b\n' | firebase_set_key 2>&1 | grep -c 'does not look like')" "1:1"

doc="$(firebase_doctor)"
expect "doctor" "$(echo "$doc" | jq -c '[.key, .keyOk, .project, .sites, .expiresAt, .rateLimit]')" '["env",true,"fixture-project",4,null,null]'
expect "doctor: a command that prints a token counts as a key" "$(env -u FIREBASE_ACCESS_TOKEN FIREBASE_ACCESS_TOKEN_CMD='echo x' bash -c '. ./providers/firebase.sh; firebase_doctor' | jq -r .key)" "command"
expect "doctor: a refused token is reported" "$(CURLSTUB=401 firebase_doctor | jq -c '[.keyOk, (.error | length > 0)]')" "[false,true]"

echo
[ "$fails" = 0 ] && echo "All Firebase Hosting tests passed." || { echo "$fails failed."; exit 1; }
