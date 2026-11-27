#!/bin/bash
# Tests for `deploys morning` (lib/morning.sh): the night from the journal, prs-state.json and autofix.json, the
# file, the notification line and the schedule. Fakes only: no network, no launchd, no real HOME. Run: tests/morning-tests.sh
set -uo pipefail
cd "$(dirname "$0")/.." || exit 1
exec </dev/null
fails=0
ok()   { echo "ok   $1"; }
fail() { echo "FAIL $1: $2"; fails=$((fails+1)); }
expect() { [ "$2" = "$3" ] && ok "$1" || fail "$1" "expected [$3], got [$2]"; }

tmp="$(mktemp -d)"; trap 'rm -rf "$tmp"' EXIT
export DEPLOYS_CONFIG="$tmp/config" DEPLOYS_LIB=1 DEPLOYS_TESTING=1 HOME="$tmp/home" NO_COLOR=1 DEPLOYS_JOURNAL="$tmp/j.jsonl" DEPLOYS_NOTIFY=0
mkdir -p "$HOME" "$DEPLOYS_CONFIG"
# shellcheck source=../deploys
. ./deploys
set +e

now="$(date +%s)"; iso() { date -u -r "$1" +%Y-%m-%dT%H:%M:%SZ 2>/dev/null || date -u -d "@$1" +%Y-%m-%dT%H:%M:%SZ; }
{
  echo "{\"at\":\"$(iso $((now - 3600)))\",\"platform\":\"vercel\",\"name\":\"shop\",\"result\":\"other\",\"detail\":\"Started by deploy-changed from the terminal\"}"
  echo "{\"at\":\"$(iso $((now - 1800)))\",\"platform\":\"vercel\",\"name\":\"shop\",\"result\":\"live\",\"detail\":\"ok\"}"
  echo "{\"at\":\"$(iso $((now - 1200)))\",\"platform\":\"render\",\"name\":\"api\",\"result\":\"failed\",\"detail\":\"build failed\"}"
  echo "{\"at\":\"$(iso $((now - 200000)))\",\"platform\":\"render\",\"name\":\"old\",\"result\":\"failed\",\"detail\":\"long ago\"}"
  echo "not json"
} > "$DEPLOYS_JOURNAL"
prs="{\"events\":[{\"at\":$((now - 600)),\"kind\":\"merge\",\"result\":\"merged\",\"repo\":\"acme/web\",\"pr\":7,\"title\":\"fix: a\"},
  {\"at\":$((now - 600)),\"kind\":\"resolve\",\"result\":\"failed\",\"repo\":\"acme/web\",\"pr\":8,\"title\":\"x\"},
  {\"at\":$((now - 200000)),\"kind\":\"merge\",\"result\":\"merged\",\"repo\":\"acme/web\",\"pr\":1,\"title\":\"old\"}]}"
af="{\"fires\":[{\"at\":$((now - 900)),\"project\":\"api\",\"status\":\"fired\"},{\"at\":$((now - 200000)),\"project\":\"old\",\"status\":\"fired\"}]}"
w='[{"platform":"vercel","name":"blog","pendingCommits":3}]'

out="$(morning_from "$now" 24 "$prs" "$af" "$w" < "$DEPLOYS_JOURNAL")"
expect "morning: deployed once per project" "$(jq -c '[.deployed[].name]' <<<"$out")" '["shop"]'
expect "morning: failed in the last hours only" "$(jq -c '[.failed[].name]' <<<"$out")" '["api"]'
expect "morning: merged PRs only, in the time" "$(jq -c '[.merged[].pr]' <<<"$out")" '[7]'
expect "morning: autofix in the time" "$(jq -c '.autofix' <<<"$out")" '{"handedOver":1,"projects":["api"]}'
expect "morning: waiting" "$(jq -c '[.waiting[].name]' <<<"$out")" '["blog"]'
expect "morning: the notification line" "$(morning_line <<<"$out")" "1 deployed, 1 failed, 1 PRs merged, 1 waiting, 1 to autofix"
expect "morning: the text names the waiting project" "$(morning_text <<<"$out" | grep -c 'blog (vercel), 3 commits')" "1"
out="$(morning_from "$now" 24 '{}' '{"fires":[]}' null < /dev/null)"
expect "morning: nothing at all, waiting not read" "$(morning_line <<<"$out")" "0 deployed, 0 failed, 0 PRs merged"
expect "morning: the text says waiting was not read" "$(morning_text <<<"$out" | grep -c 'Still waiting: not read')" "1"

# --- the command: a file, the newest 30 kept, offline, a bad option ---
mkdir -p "$DEPLOYS_CONFIG/morning"
for i in $(seq 1 35); do : > "$DEPLOYS_CONFIG/morning/2020-01-$(printf '%02d' "$i").txt"; done
out="$(env -u DEPLOYS_LIB bash ./deploys morning --offline 2>&1)"; rc=$?
expect "morning --offline: exit 0" "$rc" "0"
expect "morning: today's file is written" "$(grep -c '^  Deployed: 1 (shop)' "$DEPLOYS_CONFIG/morning/$(date +%Y-%m-%d).txt" 2>/dev/null)" "1"
expect "morning: the newest 30 files stay" "$(find "$DEPLOYS_CONFIG/morning" -name '*.txt' | wc -l | tr -d ' ')" "30"
expect "morning --json: an object" "$(env -u DEPLOYS_LIB bash ./deploys morning --offline --no-file --json 2>/dev/null | jq -r '.deployed | length')" "1"
rc=0; env -u DEPLOYS_LIB bash ./deploys morning --nope >/dev/null 2>&1 || rc=$?
expect "morning: an unknown option is a wrong call" "$rc" "2"
rc=0; env -u DEPLOYS_LIB bash ./deploys morning --hours 0 >/dev/null 2>&1 || rc=$?
expect "morning: --hours 0 is refused" "$rc" "1"

# --- schedule: a launchd job at 08:00 that runs `morning` ---
mkdir -p "$tmp/lc" "$tmp/agents"
printf '#!/bin/bash\nexit 0\n' > "$tmp/lc/launchctl"; chmod +x "$tmp/lc/launchctl"
PATH="$tmp/lc:$PATH" DEPLOYS_LAUNCH_DIR="$tmp/agents" env -u DEPLOYS_LIB bash ./deploys morning schedule on >/dev/null 2>&1
plist="$tmp/agents/app.deploycenter.morning.plist"
expect "schedule: the job runs morning" "$(grep -c '<string>morning</string>' "$plist" 2>/dev/null)" "1"
expect "schedule: at 08:00" "$(grep -c '<key>Hour</key><integer>8</integer><key>Minute</key><integer>0</integer>' "$plist" 2>/dev/null)" "1"
expect "schedule status: on at 08:00" "$(PATH="$tmp/lc:$PATH" DEPLOYS_LAUNCH_DIR="$tmp/agents" env -u DEPLOYS_LIB bash ./deploys morning schedule status 2>&1)" "on, every day at 08:00"
rc=0; PATH="$tmp/lc:$PATH" DEPLOYS_LAUNCH_DIR="$tmp/agents" env -u DEPLOYS_LIB bash ./deploys morning schedule on 25:00 >/dev/null 2>&1 || rc=$?
expect "schedule: a bad time is refused" "$rc" "1"
rc=0; DEPLOYS_READONLY=1 PATH="$tmp/lc:$PATH" DEPLOYS_LAUNCH_DIR="$tmp/agents2" env -u DEPLOYS_LIB bash ./deploys morning schedule on >/dev/null 2>&1 || rc=$?
expect "schedule: observers cannot turn it on" "$rc:$([ -e "$tmp/agents2/app.deploycenter.morning.plist" ] && echo file || echo none)" "1:none"

echo
if [ "$fails" = 0 ]; then echo "all morning tests passed"; else echo "$fails morning test(s) failed"; exit 1; fi
