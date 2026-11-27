#!/bin/bash
# Tests for load shedding (lib/perfshed.sh) and the sharper gate (lib/perf.sh). Made-up outputs of ps, lsof, sysctl
# and launchctl and made-up desktop sessions in tests/fixtures/perf-shed: no real process is read or stopped except a
# dummy `sleep` this script starts itself. Run: bash tests/perf-shed-tests.sh
set -uo pipefail
cd "$(dirname "$0")/.." || exit 1
exec </dev/null
fails=0
ok()   { echo "ok   $1"; }
fail() { echo "FAIL $1: $2"; fails=$((fails+1)); }
expect() { [ "$2" = "$3" ] && ok "$1" || fail "$1" "expected [$3], got [$2]"; }

tmp="$(mktemp -d)"; trap 'rm -rf "$tmp"' EXIT
export DEPLOYS_CONFIG="$tmp/config" HOME="$tmp/home" NO_COLOR=1 DEPLOYS_TESTING=1 DEPLOYS_PERF_NORECORD=1
mkdir -p "$HOME" "$DEPLOYS_CONFIG/perf"
fx="$tmp/fx"; cp -R tests/fixtures/perf-shed "$fx"
export DEPLOYS_PERF_FIXTURE="$fx" DEPLOYS_DESKTOP_SESSIONS_BASE="$fx/sessions" DEPLOYS_DESKTOP_SESSIONS_FIXTURE="$tmp/ds"
export DEPLOYS_LOCAL_SESSIONS_DIR="$tmp/live" DEPLOYS_CLAUDE_PROJECTS="$tmp/projects" DEPLOYS_JOURNAL="$tmp/journal.jsonl"
export DEPLOYS_PERF_KILL_AFTER=0 DEPLOYS_PERF_NOTIFY_CMD="$tmp/notify"
mkdir -p "$tmp/ds" "$tmp/live" "$tmp/projects"; echo '[]' > "$tmp/ds/agents.json"; echo '{}' > "$tmp/ds/auth.json"; : > "$tmp/ds/alive"
printf '#!/bin/sh\necho "$1 | $2" >> "%s/notified"\n' "$tmp" > "$tmp/notify"; chmod +x "$tmp/notify"
echo '{}' > "$DEPLOYS_CONFIG/perf.json"
perf() { bash lib/perf.sh "$@"; }
now="$(date +%s)"; export DEPLOYS_PERF_NOW="$now"

# --- the gate: load 14.55 on 14 cores and 3.4 GB swap in use is no longer "may start" ---
j="$(perf status --json)"
expect "load just over the cores: held" "$(jq -c '[.level, .admit]' <<<"$j")" '["yellow",false]'
expect "swap in use is a yellow reason" "$(jq -r '.reasons | map(select(test("swap in use"))) | length' <<<"$j")" "1"
expect "swap in use alone is no memory pressure" "$(jq -r .memoryTight <<<"$j")" "false"
sed -i.bak 's/{ 14.55 14.20 12.00 }/{ 16.00 6.00 5.00 }/' "$fx/sysctl"
expect "a short spike (5-min load low) does not hold" "$(perf status --json | jq -r .admit)" "true"
echo '{"maxLoadPerCore":1.2,"maxSwapUsedMB":8192}' > "$DEPLOYS_CONFIG/perf.json"
sed -i.bak 's/{ 16.00 6.00 5.00 }/{ 15.00 15.00 12.00 }/' "$fx/sysctl"
expect "both limits come from perf.json" "$(perf status --json | jq -c '[.admit, (.reasons | map(select(test("swap in use"))) | length)]')" '[true,0]'
echo '{}' > "$DEPLOYS_CONFIG/perf.json"
sed -i.bak 's/^1$/2/' "$fx/sysctl"
expect "pressure at warn is memory pressure" "$(perf status --json | jq -r .memoryTight)" "true"
sed -i.bak 's/^2$/1/' "$fx/sysctl"

# --- rule S: who would be stopped ---
# every server last had a client an hour ago (perf/shed-seen.tsv: pid, start, last)
for p in 402 410 420 430 440 450 470 480 496; do printf '%s\t%s\t%s\n' "$p" "$((now - (p == 402 ? 18000 : 10800)))" "$((now - 3600))"; done > "$DEPLOYS_CONFIG/perf/shed-seen.tsv"
. lib/perf.sh; . lib/perfclean.sh; . lib/perfdocker.sh; . lib/desktopsessions.sh; . lib/perfshed.sh
list="$(perf_shed_list)"
expect "archived session, done and idle, idle without a session" "$(cut -f1 <<<"$list" | sort | tr '\n' ' ')" "402 410 430 496 "
expect "biggest first: next dev with its next-server" "$(head -n 1 <<<"$list" | cut -f1,4,5)" "$(printf '402\t1171\t402,403')"
expect "archived wins even without idle ports" "$(awk -F'\t' '$1 == 402 {print $2}' <<<"$list")" "its Claude session is archived"
expect "done needs idle ports" "$(awk -F'\t' '$1 == 410 {print $2}' <<<"$list")" "its Claude session is done, no client on port 5173 for 60 min"
expect "a client on the port keeps it (420); our own outgoing connection does not (430)" "$(grep -c '^420' <<<"$list")" "0"
expect "terminal, live Claude above it, open session, shared folder with an open session: kept" \
  "$(cut -f1 <<<"$list" | grep -cE '^(440|450|470|480)$')" "0"
expect "an app above it that launchd runs (the Claude app) does not protect it" "$(grep -c '^496' <<<"$list")" "1"
expect "the npm and shell wrappers are not listed, postgres never" "$(cut -f1 <<<"$list" | grep -cE '^(400|401|490)$')" "0"
expect "a server first seen now is not idle yet" "$(rm -f "$DEPLOYS_CONFIG/perf/shed-seen.tsv"; perf_shed_list | cut -f1 | tr '\n' ' ')" "402 "
expect "its first sighting is remembered" "$(grep -c '^430' "$DEPLOYS_CONFIG/perf/shed-seen.tsv")" "1"
for p in 402 410 420 430 440 450 470 480 496; do printf '%s\t%s\t%s\n' "$p" "$((now - (p == 402 ? 18000 : 10800)))" "$((now - 3600))"; done > "$DEPLOYS_CONFIG/perf/shed-seen.tsv"

# --- perf clean lists S, never stops it ---
out="$(json=1 perf_clean_main)"
expect "clean --json carries S, not stopping" "$(jq -c '[.processes[] | select(.rule == "S") | [.pid, .stops]]' <<<"$out")" '[[402,false],[410,false],[430,false],[496,false]]'
expect "clean text names the condition" "$(json=0 perf_clean_main | grep -c 'rule S (under memory pressure, with --shed)')" "4"

# --- the stop: only under memory pressure, a real dummy process ---
dummy="$(bash -c '(exec -a "node /work/z/node_modules/.bin/next dev" sleep 300) >/dev/null 2>&1 & echo $!')"
sleep 0.3
printf '%s 1 03:00:00 100000 S ?? node /work/z/node_modules/.bin/next dev\n' "$dummy" > "$fx/shedps"
printf 'p%s\nn*:3999\n' "$dummy" > "$fx/shedlisten"; : > "$fx/shedest"; printf 'p%s\nn/nonexistent-shed/z\n' "$dummy" > "$fx/shedcwd"
printf '%s\t%s\t%s\n' "$dummy" "$((now - 10800))" "$((now - 3600))" > "$DEPLOYS_CONFIG/perf/shed-seen.tsv"
perf_shed_main --yes --quiet --snap '{"level":"yellow","memoryTight":false}'
expect "yellow from load alone: nothing stopped" "$(kill -0 "$dummy" 2>/dev/null && echo alive)" "alive"
out="$(perf_shed_main --snap '{"level":"red","memoryTight":true}')"
expect "a dry run under pressure only lists" "$(kill -0 "$dummy" 2>/dev/null && echo alive) $(grep -c "would stop  $dummy  rule S" <<<"$out")" "alive 1"
echo '{"shed":{"enabled":true}}' > "$DEPLOYS_CONFIG/perf.json"
perf_shed_tick '{"level":"yellow","memoryTight":false}'
expect "the tick without memory pressure stops nothing" "$(kill -0 "$dummy" 2>/dev/null && echo alive)" "alive"
journal_add() { printf '%s\t%s\t%s\t%s\n' "$@" >> "$tmp/journal"; }
perf_shed_tick '{"level":"red","memoryTight":true}'
sleep 0.3
expect "under memory pressure: stopped" "$(kill -0 "$dummy" 2>/dev/null && echo alive || echo gone)" "gone"
expect "a notification" "$(grep -c 'stopped 1 unused dev server' "$tmp/notified")" "1"
expect "a journal entry" "$(cut -f1,3 "$tmp/journal")" "$(printf 'local\tshed')"
expect "logged" "$(grep -c "shed: stopped $dummy" "$DEPLOYS_CONFIG/perf/clean.log")" "1"
expect "the next pass waits 5 minutes" "$( [ -f "$DEPLOYS_CONFIG/perf/last-shed" ] && echo yes)" "yes"
expect "one that comes back (same folder and command) is left alone" "$(perf_shed_list | grep -c .)" "0"
rm -f "$DEPLOYS_CONFIG/perf/shed-stopped.tsv"
echo '{"shed":{"enabled":true,"maxPerRun":0}}' > "$DEPLOYS_CONFIG/perf.json"
expect "maxPerRun caps a pass" "$(perf_shed_main --yes --snap '{"level":"red","memoryTight":true}' | grep -c '^stopped')" "0"

# --- install --shed and the Docker part ---
expect "install without --yes changes nothing" "$(perf install --shed >/dev/null 2>&1; echo $?)" "2"
echo '{"docker":{}}' > "$DEPLOYS_CONFIG/perf.json"
cp tests/fixtures/perf-guard/dockerps tests/fixtures/perf-guard/dockerstats "$fx/"
printf 'ffffffffffff1\tweb-preview\trunning\t\t\t\t127.0.0.1:8080->80/tcp\n' >> "$fx/dockerps"; : > "$fx/established"; : > "$fx/ps"; : > "$fx/sessioncwd"
docker() { echo "docker $*" >> "$tmp/docker.log"; }; perfdocker_have() { return 0; }
echo '{"shed":{"enabled":true}}' > "$DEPLOYS_CONFIG/perf.json"
echo '{"shop":0,"notes-pg":0,"cache-redis":0,"web-preview":0}' > "$DEPLOYS_CONFIG/perf/docker-seen.json"
perfdocker_idle_tick yellow false
expect "shed only, no memory pressure: no Docker stop" "$( [ -f "$tmp/docker.log" ] && grep -c 'docker stop' "$tmp/docker.log" || echo 0)" "0"
perfdocker_idle_tick yellow true
expect "under memory pressure: only the idle stack without a database (redis counts) is stopped" "$(grep 'docker stop' "$tmp/docker.log" | tr '\n' ' ')" "docker stop ffffffffffff "

# --- the gate runs heavy commands at background priority while the Mac is busy ---
printf '#!/bin/sh\necho "low:$*"\n' > "$tmp/taskpolicy"; chmod +x "$tmp/taskpolicy"
export DEPLOYS_PERF_TASKPOLICY="$tmp/taskpolicy"
echo '{"stagger":0,"pollEvery":1,"maxLoadPerCore":9}' > "$DEPLOYS_CONFIG/perf.json"
expect "yellow: through taskpolicy -b" "$(bash lib/perf.sh gate --max-wait 0 echo hi 2>/dev/null)" "low:-b echo hi"
echo '{"stagger":0,"pollEvery":1,"maxLoadPerCore":9,"lowPriority":false}' > "$DEPLOYS_CONFIG/perf.json"
expect "lowPriority false: as it is" "$(bash lib/perf.sh gate --max-wait 0 echo hi 2>/dev/null)" "hi"
printf '1\n61\n51539607552\n14\n{ 1.00 1.00 1.00 }\ntotal = 8192.00M  used = 10.00M  free = 8182.00M  (encrypted)\n' > "$fx/sysctl"
echo '{"stagger":0,"pollEvery":1}' > "$DEPLOYS_CONFIG/perf.json"
expect "green: full speed" "$(bash lib/perf.sh gate --max-wait 0 echo hi 2>/dev/null)" "hi"
echo '{"stagger":0,"pollEvery":1,"lowPriority":"always"}' > "$DEPLOYS_CONFIG/perf.json"
expect "always: low even when green" "$(bash lib/perf.sh gate --max-wait 0 echo hi 2>/dev/null)" "low:-b echo hi"
unset DEPLOYS_PERF_TASKPOLICY

# --- apps the Mac app would quit (its plan file), shown by perf clean ---
echo '{"quitApps":{"enabled":true}}' > "$DEPLOYS_CONFIG/perf.json"
rm -f "$DEPLOYS_CONFIG/perf/quit-plan.json"
expect "no plan: the app is not running" "$(perf_quit_plan)" "$(printf '#\tthe Deploy Center app is not running: no apps are quit')"
printf '{"time":%s,"enabled":true,"pressed":false,"candidates":[{"bundleId":"com.example.editor","name":"Example Editor","mb":2048,"idleMin":45}]}' "$now" > "$DEPLOYS_CONFIG/perf/quit-plan.json"
expect "the plan lists the candidates" "$(json=0 perf_clean_main | grep -c 'would quit app  Example Editor  2048 MB  idle 45 min')" "1"
expect "and in --json" "$(json=1 perf_clean_main | jq -c '.apps')" '[{"name":"Example Editor","mb":2048,"idleMin":45}]'
echo '{}' > "$DEPLOYS_CONFIG/perf.json"
expect "off: nothing about apps" "$(json=0 perf_clean_main | grep -c 'apps\|quit app')" "0"

[ "$fails" = 0 ] && echo "perf-shed: all passed" || { echo "perf-shed: $fails failed"; exit 1; }
