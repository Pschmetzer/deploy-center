#!/bin/bash
# Tests for the nightly batch options of deploy-changed: --skip-failed and --between (and their pass-through
# in plan and schedule daily). Fakes only: no network, no launchd, no real HOME. Run: tests/nightbatch-tests.sh
set -uo pipefail
cd "$(dirname "$0")/.." || exit 1
exec </dev/null
fails=0
ok()   { echo "ok   $1"; }
fail() { echo "FAIL $1: $2"; fails=$((fails+1)); }
expect() { [ "$2" = "$3" ] && ok "$1" || fail "$1" "expected [$3], got [$2]"; }

tmp="$(mktemp -d)"; trap 'rm -rf "$tmp"' EXIT
export DEPLOYS_CONFIG="$tmp/config" DEPLOYS_LIB=1 DEPLOYS_TESTING=1 HOME="$tmp/home" NO_COLOR=1 DEPLOYS_JOURNAL="$tmp/j.jsonl"
mkdir -p "$HOME" "$DEPLOYS_CONFIG"
# shellcheck source=../deploys
. ./deploys
set +e

# --- between_ok / between_valid ---
expect "between: inside" "$(between_ok 03:00-05:00 0330 && echo in || echo out)" "in"
expect "between: the end is outside" "$(between_ok 03:00-05:00 0500 && echo in || echo out)" "out"
expect "between: a late run at 09:00 is outside" "$(between_ok 03:00-05:00 0900 && echo in || echo out)" "out"
expect "between: over midnight, 23:30 is inside" "$(between_ok 23:00-02:00 2330 && echo in || echo out)" "in"
expect "between: over midnight, 01:59 is inside" "$(between_ok 23:00-02:00 0159 && echo in || echo out)" "in"
expect "between: over midnight, 12:00 is outside" "$(between_ok 23:00-02:00 1200 && echo in || echo out)" "out"
for bad in "" "3:00-5:00" "25:00-05:00" "03:00-03:00" "03:00" "03:60-05:00" "x"; do
  expect "between_valid: [$bad] is refused" "$(between_valid "$bad" && echo yes || echo no)" "no"
done
expect "between_valid: 03:00-05:00" "$(between_valid 03:00-05:00 && echo yes || echo no)" "yes"

# --- skip_failed: failed at the same commit waits, a newer commit goes ---
list='[
 {"platform":"vercel","name":"shop","latestState":"ERROR","latestSha":"aaaaaaa1","headSha":"aaaaaaa1"},
 {"platform":"vercel","name":"blog","latestState":"ERROR","latestSha":"bbbbbbb1","headSha":"bbbbbbb2"},
 {"platform":"vercel","name":"docs","latestState":"READY","latestSha":"ccccccc1","headSha":"ccccccc2"},
 {"platform":"render","name":"api","lastState":"build_failed","latestSha":null,"headSha":"ddddddd2"},
 {"platform":"render","name":"jobs","lastState":"update_failed","latestSha":"eeeeeee1","headSha":"eeeeeee1"},
 {"platform":"render","name":"mail","lastState":"live","latestSha":"fffffff1","headSha":"fffffff2"}]'
failskip="[]"; skip_failed
expect "skip_failed: what still goes" "$(echo "$list" | jq -c '[.[].name]')" '["blog","docs","mail"]'
expect "skip_failed: what waits" "$(echo "$failskip" | jq -c '[.[].name]')" '["shop","api","jobs"]'
expect "skip_failed: the rows say would-skip and why" "$(echo "$failskip" | jq -r '.[0] | .action + "|" + .reason')" "would-skip|its last build failed at aaaaaaa and nothing is new since"
expect "skip_failed: an unknown commit is named so" "$(echo "$failskip" | jq -r '.[1].reason')" "its last build failed and its commit is not known"

# --- deploy-changed: --between outside starts nothing (checked before any platform is asked) ---
if [ "$(date +%H%M)" != 0000 ]; then
  out="$(env -u DEPLOYS_LIB bash ./deploys deploy-changed --yes --between 00:00-00:01 2>&1)"; rc=$?
  expect "deploy-changed --between outside: nothing started, exit 0" "$rc:$(grep -c 'nothing was started' <<<"$out")" "0:1"
fi
rc=0; env -u DEPLOYS_LIB bash ./deploys deploy-changed --between 3-5 >/dev/null 2>&1 || rc=$?
expect "deploy-changed --between with a bad time: refused" "$rc" "1"

# --- schedule daily: the new options go into the job ---
mkdir -p "$tmp/lc" "$tmp/agents"
printf '#!/bin/bash\nexit 0\n' > "$tmp/lc/launchctl"; chmod +x "$tmp/lc/launchctl"
PATH="$tmp/lc:$PATH" DEPLOYS_LAUNCH_DIR="$tmp/agents" env -u DEPLOYS_LIB bash ./deploys schedule daily 03:00 --when-green --skip-failed --between 03:00-05:00 >/dev/null 2>&1
plist="$tmp/agents/app.deploycenter.daily.plist"
expect "schedule daily: --skip-failed and --between are in the job" \
  "$(grep -c '<string>deploy-changed</string><string>--yes</string><string>--when-green</string><string>--skip-failed</string><string>--between</string><string>03:00-05:00</string>' "$plist" 2>/dev/null)" "1"
rc=0; PATH="$tmp/lc:$PATH" DEPLOYS_LAUNCH_DIR="$tmp/agents" env -u DEPLOYS_LIB bash ./deploys schedule daily 03:00 --between 5-3 >/dev/null 2>&1 || rc=$?
expect "schedule daily: a bad --between is refused" "$rc" "1"

echo
[ "$fails" = 0 ] && echo "all nightbatch tests passed" || { echo "$fails nightbatch test(s) failed"; exit 1; }
