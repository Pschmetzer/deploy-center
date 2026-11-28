#!/bin/bash
# Tests for the performance history the app draws (perf/history.jsonl, lib/perf.sh perf_history_add) and the limits
# and free disk in status.json. Made-up system outputs from tests/fixtures/perf-guard; nothing real is read.
# Run: bash tests/perf-history-tests.sh
set -uo pipefail
cd "$(dirname "$0")/.." || exit 1
exec </dev/null
fails=0
ok()   { echo "ok   $1"; }
fail() { echo "FAIL $1: $2"; fails=$((fails+1)); }
expect() { [ "$2" = "$3" ] && ok "$1" || fail "$1" "expected [$3], got [$2]"; }

tmp="$(mktemp -d)"; trap 'rm -rf "$tmp"' EXIT
export DEPLOYS_CONFIG="$tmp/config" HOME="$tmp/home" NO_COLOR=1 DEPLOYS_TESTING=1 DEPLOYS_PERF_NOTIFY_CMD=true
mkdir -p "$HOME" "$DEPLOYS_CONFIG/perf"
fx="$tmp/fx"; cp -R tests/fixtures/perf-guard "$fx"
export DEPLOYS_PERF_FIXTURE="$fx"
echo '{"stagger":0,"pollEvery":1}' > "$DEPLOYS_CONFIG/perf.json"
echo '{"minFreeGB":80}' > "$DEPLOYS_CONFIG/disk.json"
perf() { bash lib/perf.sh "$@"; }
h="$DEPLOYS_CONFIG/perf/history.jsonl"

now="$(date +%s)"
DEPLOYS_PERF_NOW=$now perf tick
expect "one history line per tick" "$(wc -l < "$h" | tr -d ' ')" 1
expect "the line has the chart fields" "$(jq -c 'keys' "$h")" '["checks","disk","free","lpc","lvl","swap","t"]'
expect "status.json has the gauge limits" "$(jq -c '.limits | [.maxLoadPerCore, .redLoadPerCore, .maxSwapUsedMB, .minFreeDiskGB]' "$DEPLOYS_CONFIG/perf/status.json")" '[1.0,4,3072,80]'
expect "status.json has the free disk" "$(jq '.disk.freeGB | type' "$DEPLOYS_CONFIG/perf/status.json")" '"number"'

# Rotation: with a 2-minute window (62 lines before it rotates), old lines go and the new ones stay.
: > "$h"
for i in $(seq 1 70); do printf '{"t":%s,"lvl":"green","lpc":0.1,"swap":0,"free":50,"checks":0,"disk":100}\n' "$((now - 7000 + i))" >> "$h"; done
echo 'not json' >> "$h"
DEPLOYS_PERF_HISTORY_SEC=120 DEPLOYS_PERF_NOW=$now perf tick
expect "rotated: only the last 2 minutes" "$(wc -l < "$h" | tr -d ' ')" 1
expect "rotated: the newest line stays" "$(jq -r .lvl "$h" | head -n 1 | grep -c .)" 1
# Below the limit nothing is rewritten.
for i in 1 2 3; do printf '{"t":%s}\n' "$((now - 9000))" >> "$h"; done
DEPLOYS_PERF_HISTORY_SEC=120 DEPLOYS_PERF_NOW=$now perf tick
expect "under the limit: kept as it is" "$(wc -l < "$h" | tr -d ' ')" 5

[ "$fails" = 0 ] && echo "perf history tests: all ok" || echo "perf history tests: $fails failed"
exit "$fails"
