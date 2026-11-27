#!/bin/bash
# Tests for stopping the dev servers of finished work (lib/perffinished.sh). The made-up processes and sessions of
# tests/fixtures/perf-shed plus a made-up branch state (branchpr); nothing real is read or stopped except a dummy
# `sleep` this script starts itself. Run: bash tests/perf-finished-tests.sh
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
printf '/nonexistent-shed/plain\tMERGED\n/nonexistent-shed/plain2\tOPEN\n/nonexistent-shed/plain3\tCLOSED\n/nonexistent-shed/plain4\tNONE\n' > "$fx/branchpr"
export DEPLOYS_PERF_FIXTURE="$fx" DEPLOYS_DESKTOP_SESSIONS_BASE="$fx/sessions" DEPLOYS_DESKTOP_SESSIONS_FIXTURE="$tmp/ds"
export DEPLOYS_LOCAL_SESSIONS_DIR="$tmp/live" DEPLOYS_CLAUDE_PROJECTS="$tmp/projects"
export DEPLOYS_PERF_KILL_AFTER=0 DEPLOYS_PERF_NOTIFY_CMD="$tmp/notify"
mkdir -p "$tmp/ds" "$tmp/live" "$tmp/projects"; echo '[]' > "$tmp/ds/agents.json"; echo '{}' > "$tmp/ds/auth.json"; : > "$tmp/ds/alive"
printf '#!/bin/sh\necho "$1 | $2" >> "%s/notified"\n' "$tmp" > "$tmp/notify"; chmod +x "$tmp/notify"
echo '{}' > "$DEPLOYS_CONFIG/perf.json"
now="$(date +%s)"; export DEPLOYS_PERF_NOW="$now"
. lib/perf.sh; . lib/perfclean.sh; . lib/perfdocker.sh; . lib/desktopsessions.sh; . lib/perfshed.sh; . lib/perffinished.sh

list="$(perf_finished_list)"
expect "archived, done (busy or not), merged and closed branch" "$(cut -f1 <<<"$list" | sort | tr '\n' ' ')" "402 410 420 430 450 "
expect "an open pull request, none, an open session, a terminal: kept" "$(cut -f1 <<<"$list" | grep -cE '^(440|470|480|496)$')" "0"
expect "the reason" "$(awk -F'\t' '$1 == 430 {print $2}' <<<"$list")" "the pull request of its branch is merged"
expect "just found: finished for 0 min" "$(awk -F'\t' '$1 == 402 {print $3}' <<<"$list")" "0"
sed -i.bak "s/^402\t\([0-9]*\)\t.*/402\t\1\t$((now - 600))/" "$DEPLOYS_CONFIG/perf/finished-seen.tsv"
expect "the first sighting is kept" "$(perf_finished_list | awk -F'\t' '$1 == 402 {print $3}')" "10"
out="$(perf_finished_main)"
expect "dry run says when" "$(grep -c 'would stop  410  its Claude session is done (in 10 min)' <<<"$out")" "1"

# --- the stop, at any level, after the grace time; a real dummy process ---
dummy="$(bash -c '(exec -a "node /work/z/node_modules/.bin/next dev" sleep 300) >/dev/null 2>&1 & echo $!')"
sleep 0.3
printf '%s 1 03:00:00 100000 S ?? node /work/z/node_modules/.bin/next dev\n' "$dummy" > "$fx/shedps"
printf 'p%s\nn*:3999\n' "$dummy" > "$fx/shedlisten"; : > "$fx/shedest"; printf 'p%s\nn/nonexistent-shed/z\n' "$dummy" > "$fx/shedcwd"
printf '/nonexistent-shed/z\tMERGED\n' > "$fx/branchpr"
: > "$DEPLOYS_CONFIG/perf/finished-seen.tsv"
perf_finished_main --yes --quiet
expect "inside the grace time: kept" "$(kill -0 "$dummy" 2>/dev/null && echo alive)" "alive"
printf '%s\t%s\t%s\n' "$dummy" "$((now - 10800))" "$((now - 660))" > "$DEPLOYS_CONFIG/perf/finished-seen.tsv"
perf_finished_tick
expect "the tick does nothing while off" "$(kill -0 "$dummy" 2>/dev/null && echo alive)" "alive"
echo '{"stopFinished":{"enabled":true}}' > "$DEPLOYS_CONFIG/perf.json"
journal_add() { printf '%s\t%s\t%s\t%s\n' "$@" >> "$tmp/journal"; }
perf_finished_tick
sleep 0.3
expect "past the grace time, green Mac: stopped" "$(kill -0 "$dummy" 2>/dev/null && echo alive || echo gone)" "gone"
expect "a notification" "$(grep -c 'Stopped 1 dev server(s) of finished work' "$tmp/notified")" "1"
expect "a journal entry" "$(cut -f1,3 "$tmp/journal")" "$(printf 'local\tshed')"
expect "the next pass waits 5 minutes" "$(perf_finished_tick; grep -c 'finished: stopped' "$DEPLOYS_CONFIG/perf/clean.log")" "1"
expect "one that comes back is left alone" "$(perf_finished_list | grep -c .)" "0"
expect "install without --yes changes nothing" "$(bash lib/perf.sh install --stop-finished >/dev/null 2>&1; echo $?)" "2"

[ "$fails" = 0 ] && echo "perf-finished: all passed" || { echo "perf-finished: $fails failed"; exit 1; }
