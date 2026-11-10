#!/bin/bash
# Tests for providers/amplify.sh. No network: aws, curl, security and sleep are stand-ins.
# Run: bash tests/providers/amplify.sh
set -uo pipefail
cd "$(dirname "$0")/../.." || exit 1
fails=0
ok()   { echo "ok   $1"; }
fail() { echo "FAIL $1: $2"; fails=$((fails+1)); }
expect() { [ "$2" = "$3" ] && ok "$1" || fail "$1" "expected [$3], got [$2]"; }
has() { [[ "$2" == *"$3"* ]] && ok "$1" || fail "$1" "[$3] not in [$2]"; }
hasnt() { [[ "$2" != *"$3"* ]] && ok "$1" || fail "$1" "[$3] should not be in [$2]"; }

FIX="$PWD/tests/fixtures/amplify"
tmp="$(mktemp -d)"; trap 'rm -rf "$tmp"' EXIT
export DEPLOYS_CONFIG="$tmp/config" CALLS="$tmp/calls.log" ROUTES="$tmp/routes" FIX
mkdir -p "$tmp/bin" "$DEPLOYS_CONFIG"

# A stand-in for the aws CLI. $ROUTES holds lines "<service> <command> <args regex> <fixture>[:rc][,...]":
# the first line that matches answers; a list answers its items in turn (the last one repeats).
# A nonzero rc prints the fixture on stderr, as the CLI does. Every call is logged, without
# "--output json". A regex cannot hold spaces: "." stands in for one.
cat > "$tmp/bin/aws" <<'AWS'
#!/bin/bash
[ "${1:-}" = --version ] && { echo "aws-cli/2.31.0 Python/3.13 Darwin/25 source/arm64"; exit 0; }
args=(); skip=0
for a in "$@"; do
  [ "$skip" = 1 ] && { skip=0; continue; }
  [ "$a" = --output ] && { skip=1; continue; }
  args+=("$a")
done
line="${args[*]}"; echo "aws $line" >> "$CALLS"
svc="${args[0]:-}"; cmd="${args[1]:-}"; rest="${args[*]:2}"
[ "$svc $cmd" = "configure get" ] && { echo "${FAKE_REGION:-}"; [ -n "${FAKE_REGION:-}" ]; exit; }
n=0
while read -r rs rc re fx; do
  n=$((n+1)); [ -n "$rs" ] || continue
  [ "$rs" = "$svc" ] && [ "$rc" = "$cmd" ] && [[ " $rest " =~ $re ]] || continue
  c="$(cat "$ROUTES.$n" 2>/dev/null || echo 0)"; echo $((c+1)) > "$ROUTES.$n"
  IFS=, read -ra list <<< "$fx"; i=$c; [ "$i" -lt "${#list[@]}" ] || i=$(( ${#list[@]} - 1 ))
  f="${list[$i]}"; code=0; case "$f" in *:*) code="${f##*:}"; f="${f%%:*}";; esac
  if [ "$code" = 0 ]; then cat "$FIX/$f"; else echo; cat "$FIX/$f" >&2; fi
  exit "$code"
done < "$ROUTES"
echo "An error occurred (BadRequestException): no route in test for: $line" >&2; exit 254
AWS
# curl only fetches log links here: https://logs.example/<name>?... answers log-<name>.txt.
cat > "$tmp/bin/curl" <<'CURL'
#!/bin/bash
url="${*: -1}"; echo "curl $url" >> "$CALLS"
name="${url#https://logs.example/}"; name="${name%%\?*}"
[ -f "$FIX/log-$name.txt" ] || { echo "curl: (22) The requested URL returned error: 403" >&2; exit 22; }
cat "$FIX/log-$name.txt"
CURL
# security: -i logs what it is given; find-generic-password answers $FAKE_KEYCHAIN, or "not found".
cat > "$tmp/bin/security" <<'SEC'
#!/bin/bash
echo "security $*" >> "$CALLS"
[ "$1" = -i ] && cat >> "$CALLS"
if [ "$1" = find-generic-password ]; then [ -n "${FAKE_KEYCHAIN:-}" ] || exit 44; echo "$FAKE_KEYCHAIN"; fi
exit 0
SEC
printf '#!/bin/bash\nexit 0\n' > "$tmp/bin/sleep"
chmod +x "$tmp/bin"/*
export PATH="$tmp/bin:$PATH"
unset AWS_PROFILE AWS_REGION AWS_DEFAULT_REGION FAKE_KEYCHAIN FAKE_REGION
export DEPLOYS_AMPLIFY_PROFILE=deployer

# Fresh routes and call log for each case.
routes() { rm -f "$ROUTES".*; : > "$CALLS"; printf '%s\n' "$@" > "$ROUTES"; }
calls() { grep -c -- "$1" "$CALLS" 2>/dev/null || true; }
amp() { bash providers/amplify.sh "$@"; }

# The usual account: Shop (main + dev, custom domain), blog (production branch by stage), static (no Git).
STD=(
  "amplify list-apps . apps.json"
  "amplify get-app d1shop0001 get-app-shop.json"
  "amplify list-branches d1shop0001 branches-shop.json"
  "amplify list-branches d2blog0002 branches-blog.json"
  "amplify list-branches d3static003 branches-none.json"
  "amplify list-jobs d1shop0001 jobs-shop.json"
  "amplify list-jobs d2blog0002 jobs-blog.json"
  "amplify list-domain-associations d1shop0001 domains-shop.json"
  "amplify list-domain-associations . domains-none.json"
)

# --- phase mapping and times ---
# shellcheck source=../../providers/amplify.sh
. providers/amplify.sh
while IFS=$'\t' read -r want got s; do expect "phase $s" "$got" "$want"; done \
  < <(jq -r "$AMP_JQ"' .[] | [.want, ({status:.s} | amp_phase), .s] | @tsv' "$FIX/statuses.json")
expect "phase: no status" "$(jq -n "$AMP_JQ"' {} | amp_phase')" null
expect "time: Z" "$(jq -n "$AMP_JQ"' "2026-01-01T10:00:00Z" | amp_t')" 1767261600
expect "time: fraction and +01:00" "$(jq -n "$AMP_JQ"' "2026-01-02T05:04:05.123000+01:00" | amp_t')" 1767326645
expect "time: -05:30" "$(jq -n "$AMP_JQ"' "2026-01-01T04:30:00-05:30" | amp_t')" 1767261600
expect "time: epoch number" "$(jq -n "$AMP_JQ"' 1767261600.5 | amp_t')" 1767261600
expect "time: junk is null" "$(jq -n "$AMP_JQ"' "yesterday" | amp_t')" null

# --- meta ---
expect "meta: caps" "$(amp meta | jq -c '.caps')" '{"off":true,"sha":true,"cancel":true,"rollback":true,"logs":true,"preview":true}'
expect "meta: not a default provider" "$(amp meta | jq '.default')" false
expect "meta: keychain item" "$(amp meta | jq -r '.keychain')" deploy-center-amplify

# --- ready: opt-in ---
expect "ready: with a profile" "$(amplify_ready && echo y || echo n)" y
expect "ready: AWS_PROFILE alone does not opt in" "$(DEPLOYS_AMPLIFY_PROFILE='' AWS_PROFILE=x amplify_ready && echo y || echo n)" n
expect "ready: keychain opts in" "$(DEPLOYS_AMPLIFY_PROFILE='' FAKE_KEYCHAIN=work amplify_ready && echo y || echo n)" y
expect "ready: no aws CLI" "$(PATH=/nonexistent amplify_ready && echo y || echo n)" n

# --- profile and region are passed on ---
routes "amplify list-apps . apps-dupe.json"
amp json >/dev/null 2>&1
has "profile: --profile from DEPLOYS_AMPLIFY_PROFILE" "$(head -n 1 "$CALLS")" "--profile deployer"
: > "$CALLS"; DEPLOYS_AMPLIFY_PROFILE='' AWS_PROFILE=other AWS_REGION=eu-west-1 amp json >/dev/null 2>&1
l="$(head -n 1 "$CALLS")"
hasnt "profile: AWS_PROFILE is left to the CLI" "$l" "--profile"
has "region: AWS_REGION is passed" "$l" "--region eu-west-1"
: > "$CALLS"; DEPLOYS_AMPLIFY_PROFILE='' FAKE_KEYCHAIN=work amp json >/dev/null 2>&1
has "profile: from the keychain" "$(grep '^aws' "$CALLS" | head -n 1)" "--profile work"
: > "$CALLS"; DEPLOYS_AMPLIFY_PROFILE=default amp json >/dev/null 2>&1
hasnt "profile: default means the default chain" "$(head -n 1 "$CALLS")" "--profile"

# --- errors say what to fix ---
routes "amplify list-apps . err-creds.txt:253"
out="$(amp json 2>&1)"; rc=$?
expect "no credentials: stops" "$rc" 1
has "no credentials: says what to do" "$out" "no AWS credentials"
routes "amplify list-apps . err-region.txt:253"
has "no region: says what to do" "$(amp json 2>&1)" "set AWS_REGION"
routes "amplify list-apps . err-expired.txt:254"
has "expired: says sso login" "$(amp json 2>&1)" "aws sso login --profile deployer"
out="$(PATH=/usr/bin:/bin amp json 2>&1)"
has "no CLI: says install it" "$out" "brew install awscli"

# --- json ---
routes "${STD[@]}"
out="$(amp json)"; rc=$?
expect "json: runs" "$rc" 0
expect "json: sorted by name" "$(echo "$out" | jq -c 'map(.name)')" '["blog","Shop","static"]'
s="$(echo "$out" | jq -c '.[] | select(.name=="Shop")')"
expect "json: contract fields" "$(echo "$s" | jq -c 'keys')" \
  '["auto","dashboardUrl","deployable","domain","fetchError","id","lastAt","lastMsg","lastSha","lastState","name","paused","phase","ref","repo","url"]'
expect "json: id is app/branch" "$(echo "$s" | jq -r .id)" "d1shop0001/main"
expect "json: auto is enableAutoBuild" "$(echo "$s" | jq .auto)" true
expect "json: custom domain of the branch" "$(echo "$s" | jq -r '.domain + " " + .url')" "www.example.com https://www.example.com"
expect "json: phase and state of the newest job" "$(echo "$s" | jq -r '.phase + " " + .lastState')" "building RUNNING"
expect "json: lastAt in seconds" "$(echo "$s" | jq .lastAt)" 1767326645
expect "json: live commit is the newest succeeded" "$(echo "$s" | jq -r '.lastSha + " " + .lastMsg')" "bbbb222 feat: b"
expect "json: repo and ref" "$(echo "$s" | jq -r '.repo + "@" + .ref')" "me/shop@main"
expect "json: dashboard" "$(echo "$s" | jq -r .dashboardUrl)" "https://eu-central-1.console.aws.amazon.com/amplify/apps/d1shop0001/branches/main/deployments"
expect "json: deployable" "$(echo "$s" | jq -c '[.deployable, .paused, .fetchError]')" '[true,false,null]'
b="$(echo "$out" | jq -c '.[] | select(.name=="blog")')"
expect "json: production branch by stage" "$(echo "$b" | jq -c '[.id, .auto, .phase, .repo]')" '["d2blog0002/release",false,"canceled","me/blog"]'
expect "json: default domain" "$(echo "$b" | jq -r .url)" "https://release.d2blog0002.amplifyapp.com"
expect "json: no succeeded build, no live commit" "$(echo "$b" | jq -c '[.lastSha, .lastMsg]')" '[null,null]'
st="$(echo "$out" | jq -c '.[] | select(.name=="static")')"
expect "json: no Git, no branch: not deployable" "$(echo "$st" | jq -c '[.deployable, .auto, .id, .phase, .ref]')" '[false,false,"d3static003",null,null]'
has "json: no branch is a fetchError" "$(echo "$st" | jq -r .fetchError)" "no production branch"
expect "json: no jobs asked for an app without a branch" "$(calls 'list-jobs --app-id d3static003')" 0
routes "amplify list-apps . apps.json" "amplify list-branches d1shop0001 err-notfound.txt:254" "amplify list-branches d2blog0002 branches-blog.json" \
  "amplify list-branches d3static003 branches-two.json" "amplify list-jobs . jobs-blog.json" "amplify list-domain-associations . domains-none.json"
out="$(amp json)"; rc=$?
expect "json: one app failing does not stop the list" "$rc/$(echo "$out" | jq length)" "0/3"
has "json: the failure is that app's fetchError" "$(echo "$out" | jq -r '.[] | select(.name=="Shop") | .fetchError')" "NotFoundException"
expect "json: failing app is not deployable" "$(echo "$out" | jq '.[] | select(.name=="Shop") | .deployable')" false
expect "json: two branches, none production: no guess" "$(echo "$out" | jq -c '.[] | select(.name=="static") | [.ref, .deployable]')" '[null,false]'

# --- resolving names ---
routes "${STD[@]}"
expect "has: by name" "$(amp has Shop && echo y)" y
expect "has: by app id" "$(amp has d2blog0002 && echo y)" y
expect "has: unknown" "$(amp has nope && echo y || echo n)" n
routes "amplify list-apps . apps-dupe.json"
out="$(amp latest Shop 2>&1)"; rc=$?
expect "two apps with one name: stops" "$rc" 1
has "two apps with one name: lists the ids" "$out" "d9shop0009"

# --- off / on ---
routes "amplify list-apps . apps.json" "amplify list-branches d1shop0001 branches-shop.json" "amplify update-branch d1shop0001 update-off.json"
out="$(amp off Shop 2>"$tmp/err")"; rc=$?
expect "off: done" "$rc/$out" "0/Amplify: main of Shop no longer builds on push"
has "off: --no-enable-auto-build on main" "$(grep update-branch "$CALLS")" "--app-id d1shop0001 --branch-name main --no-enable-auto-build"
expect "off: only the production branch" "$(calls update-branch)" 1
has "off: warns about other auto-building branches" "$(cat "$tmp/err")" "dev"
routes "amplify list-apps . apps.json" "amplify list-branches d1shop0001 branches-shop.json" "amplify update-branch d1shop0001 update-off.json" "amplify update-app d1shop0001 update-app.json"
out="$(amp off Shop --all 2>&1)"; rc=$?
expect "off --all: every branch" "$rc/$(calls update-branch)" "0/2"
has "off --all: dev too" "$(grep update-branch "$CALLS" | tail -n 1)" "--branch-name dev --no-enable-auto-build"
has "off --all: new branches too" "$(grep update-app "$CALLS")" "--no-enable-branch-auto-build"
routes "amplify get-app d1shop0001 get-app-shop.json" "amplify list-branches d1shop0001 branches-shop-off.json"
out="$(amp off d1shop0001/main 2>/dev/null)"
expect "off: already manual, nothing changed" "$out/$(calls update-branch)" "Amplify: main of d1shop0001/main was already manual/0"
routes "amplify list-apps . apps.json" "amplify list-branches d1shop0001 branches-shop.json" "amplify update-branch d1shop0001 update-on.json"
out="$(amp off Shop 2>&1)"; rc=$?
expect "off: still on after the call: stops" "$rc" 1
has "off: and says so" "$out" "still shows it on"
routes "amplify list-apps . apps.json" "amplify list-branches d1shop0001 branches-shop-off.json" "amplify update-branch d1shop0001 update-on.json"
out="$(amp on Shop)"
has "on: --enable-auto-build" "$(grep update-branch "$CALLS")" "--branch-name main --enable-auto-build"

# --- deploy ---
routes "${STD[@]}" "amplify start-job d1shop0001 start-job.json"
out="$(amp deploy-json Shop)"; rc=$?
expect "deploy: runs" "$rc" 0
expect "deploy: result" "$(echo "$out" | jq -c '[.id, .phase, .state, .branch, .url]')" '["13","queued","queued","main","https://www.example.com"]'
j="$(grep start-job "$CALLS")"
has "deploy: RELEASE on the production branch" "$j" "--app-id d1shop0001 --branch-name main --job-type RELEASE"
hasnt "deploy: no commit without --sha" "$j" "--commit-id"
out="$(amp deploy-json Shop 2>&1)"; rc=$?
expect "deploy: a second start within a minute is refused" "$rc/$(calls start-job)" "1/1"
has "deploy: says why" "$out" "being started already"
rm -rf "$DEPLOYS_CONFIG/locks"
routes "${STD[@]}" "amplify start-job d1shop0001 start-job-sha.json"
out="$(amp deploy-json Shop --sha aaaa111)"
has "deploy --sha: commit id passed" "$(grep start-job "$CALLS")" "--commit-id aaaa111"
expect "deploy --sha: the commit comes back" "$(echo "$out" | jq -r .sha)" aaaa111
out="$(amp deploy-json Shop --sha 'x; rm' 2>&1)"; rc=$?
expect "deploy --sha: not a hash, refused" "$rc/$(calls start-job)" "1/1"
rm -rf "$DEPLOYS_CONFIG/locks"
routes "${STD[@]}" "amplify start-job d1shop0001 start-job.json"
out="$(amp deploy-json Shop --preview --branch dev)"
has "preview: other branch" "$(grep start-job "$CALLS")" "--branch-name dev"
expect "preview: its domain" "$(echo "$out" | jq -r .url)" "https://dev.example.com"
out="$(amp deploy-json Shop --preview 2>&1)"; rc=$?
expect "preview: needs a branch" "$rc" 1
out="$(amp deploy-json Shop --preview --branch main 2>&1)"; rc=$?
expect "preview: not the production branch" "$rc" 1
rm -rf "$DEPLOYS_CONFIG/locks"
routes "${STD[@]}"
out="$(amp deploy-json static 2>&1)"; rc=$?
expect "deploy: no Git, refused before any start" "$rc/$(calls start-job)" "1/0"

# --- status / latest ---
routes "${STD[@]}" "amplify get-job --job-id.12 get-job.json"
expect "latest: newest job" "$(amp latest Shop | jq -c '[.id, .phase, .sha, .msg, .createdAt]')" '["12","building","cccc333","feat: c",1767326645]'
has "latest: one job asked for" "$(grep list-jobs "$CALLS")" "--max-items 1"
expect "status: by id" "$(amp status Shop 12 | jq -c '[.id, .phase, .status]')" '["12","failed","FAILED"]'
routes "${STD[@]}" "amplify list-jobs d1shop0001 jobs-none.json"
routes "amplify list-apps . apps.json" "amplify list-branches d1shop0001 branches-shop.json" "amplify list-jobs . jobs-none.json"
out="$(amp latest Shop 2>&1)"; rc=$?
expect "latest: none" "$rc" 1
has "latest: says so" "$out" "no builds yet"

# --- cancel ---
routes "${STD[@]}" "amplify stop-job d1shop0001 stop-job.json"
out="$(amp cancel Shop)"
has "cancel: the running job" "$(grep stop-job "$CALLS")" "--branch-name main --job-id 12"
expect "cancel: canceled" "$(echo "$out" | jq -r .phase)" canceled
routes "amplify list-apps . apps.json" "amplify list-branches d1shop0001 branches-shop.json" "amplify list-jobs . jobs-done.json" "amplify stop-job . stop-job.json"
out="$(amp cancel Shop 2>&1)"; rc=$?
expect "cancel: nothing running, nothing stopped" "$rc/$(calls stop-job)" "1/0"
routes "${STD[@]}" "amplify stop-job . stop-job.json"
amp cancel Shop 9 >/dev/null
has "cancel: a given job" "$(grep stop-job "$CALLS")" "--job-id 9"

# --- rollback ---
rm -rf "$DEPLOYS_CONFIG/locks"
routes "${STD[@]}" "amplify start-job d1shop0001 start-job-sha.json"
out="$(amp rollback Shop 2>"$tmp/err")"; rc=$?
expect "rollback: runs" "$rc" 0
j="$(grep start-job "$CALLS")"
has "rollback: the previous good commit, not a rebuild of the live one" "$j" "--commit-id aaaa111"
has "rollback: a message that says so" "$j" "Rollback to aaaa111: fix: a"
has "rollback: RELEASE on main" "$j" "--branch-name main --job-type RELEASE"
expect "rollback: list-jobs looked far enough back" "$(grep -c 'list-jobs.*--max-items 50' "$CALLS")" 1
has "rollback: says what it rebuilds" "$(cat "$tmp/err")" "rebuilding Shop at aaaa111"
rm -rf "$DEPLOYS_CONFIG/locks"
routes "${STD[@]}" "amplify start-job d1shop0001 start-job-sha.json"
amp rollback Shop 9 >/dev/null 2>&1
has "rollback: to a given job's commit" "$(grep start-job "$CALLS")" "--commit-id dddd444"
rm -rf "$DEPLOYS_CONFIG/locks"
routes "${STD[@]}" "amplify start-job d1shop0001 start-job-sha.json"
amp rollback Shop 0123abcd >/dev/null 2>&1
has "rollback: to a sha not in the list" "$(grep start-job "$CALLS")" "--commit-id 0123abcd"
routes "amplify list-apps . apps.json" "amplify list-branches d1shop0001 branches-shop.json" "amplify list-jobs . jobs-done.json" "amplify start-job . start-job.json"
out="$(amp rollback Shop 2>&1)"; rc=$?
expect "rollback: only one good commit, nothing to go back to" "$rc/$(calls start-job)" "1/0"

# --- logs ---
routes "${STD[@]}" "amplify get-job --job-id.12 get-job.json"
out="$(amp logs Shop)"; rc=$?
expect "logs: runs" "$rc" 0
expect "logs: every step, prefixed" "$(echo "$out" | head -n 1)/$(echo "$out" | tail -n 1)" "BUILD  # Starting phase: preBuild/DEPLOY  Error: artifact too large"
expect "logs: steps without a log are skipped" "$(echo "$out" | grep -c VERIFY)" 0
hasnt "logs: the signed link is never printed" "$out" "X-Amz-Signature"
expect "logs: tail" "$(amp logs Shop 2 | tr '\n' '|')" "DEPLOY  Deploying|DEPLOY  Error: artifact too large|"
routes "${STD[@]}" "amplify get-job --job-id.7 get-job-expired.json"
out="$(amp logs Shop 60 7)"
has "logs: an expired link says so" "$out" "could not be read"
hasnt "logs: and keeps it secret" "$out" "secret3"

# --- url ---
routes "${STD[@]}"
expect "url: custom domain" "$(amp url Shop)" "https://www.example.com"
expect "url: default domain" "$(amp url blog)" "https://release.d2blog0002.amplifyapp.com"
routes "amplify list-apps . apps.json" "amplify list-branches d3static003 branches-two.json"
expect "url: no production branch" "$(amp url static 2>/dev/null || echo stop)" stop
routes "${STD[@]}"
expect "url: dashboard" "$(amp url blog --dashboard)" "https://eu-central-1.console.aws.amazon.com/amplify/apps/d2blog0002/branches/release/deployments"

# --- set-key ---
routes "sts get-caller-identity --profile.work sts.json"
out="$(echo work | DEPLOYS_AMPLIFY_PROFILE='' amp set-key)"; rc=$?
expect "set-key: works" "$rc" 0
has "set-key: tried with that profile" "$(grep sts "$CALLS")" "--profile work"
has "set-key: saved to the keychain" "$(cat "$CALLS")" "add-generic-password -U -a $USER -s deploy-center-amplify -w work"
routes "sts get-caller-identity . err-creds.txt:253"
out="$(echo nope | DEPLOYS_AMPLIFY_PROFILE='' amp set-key 2>&1)"; rc=$?
expect "set-key: a profile that does not sign in is not saved" "$rc/$(calls add-generic-password)" "1/0"
: > "$CALLS"; out="$(echo AKIAIOSFODNN7EXAMPLE | DEPLOYS_AMPLIFY_PROFILE='' amp set-key 2>&1)"; rc=$?
expect "set-key: an access key is refused" "$rc/$(calls 'sts ')" "1/0"
has "set-key: and says where keys go" "$out" "aws configure"

# --- doctor ---
routes "sts get-caller-identity . sts.json"
out="$(FAKE_REGION=eu-central-1 amp doctor)"
expect "doctor: ready" "$(echo "$out" | jq -c '[.cli, .credentialsValid, .profile, .profileSource, .region, .enabled, .note]')" \
  '[true,true,"deployer","environment","eu-central-1",true,"ready"]'
expect "doctor: identity" "$(echo "$out" | jq -r .identity)" "arn:aws:iam::123456789012:user/deployer"
routes "sts get-caller-identity . err-creds.txt:253"
has "doctor: cannot sign in" "$(amp doctor | jq -r .note)" "cannot sign in"
expect "doctor: without the CLI" "$(PATH=/usr/bin:/bin amp doctor | jq -c '[.cli, .note]')" '[false,"install the aws CLI: brew install awscli"]'

echo
if [ "$fails" = 0 ]; then echo "All amplify provider tests passed."; else echo "$fails failed."; exit 1; fi
