#!/bin/bash
# Tests for `deploys health`, `deploys weeks` and `deploys export` (lib/health.sh, lib/export.sh). No network, no real
# projects: the journal is made up in a temp folder. Run: tests/health-tests.sh
set -uo pipefail
cd "$(dirname "$0")/.." || exit 1
exec </dev/null
fails=0
ok()   { echo "ok   $1"; }
fail() { echo "FAIL $1: $2"; fails=$((fails+1)); }
expect() { [ "$2" = "$3" ] && ok "$1" || fail "$1" "expected [$3], got [$2]"; }

tmp="$(mktemp -d)"; trap 'rm -rf "$tmp"' EXIT
export DEPLOYS_CONFIG="$tmp/config" HOME="$tmp/home" NO_COLOR=1 DEPLOYS_LIB=1 DEPLOYS_TESTING=1
mkdir -p "$HOME" "$DEPLOYS_CONFIG"
printf '{"enabled":[]}' > "$DEPLOYS_CONFIG/providers.json"   # no platform: nothing is asked of the network
# shellcheck source=../deploys
. ./deploys
set +e
cli() { env -u DEPLOYS_LIB DEPLOYS_JOURNAL="$tmp/journal.jsonl" bash ./deploys "$@"; }

now=1799841600
iso() { date -u -r "$1" +%Y-%m-%dT%H:%M:%SZ 2>/dev/null || date -u -d "@$1" +%Y-%m-%dT%H:%M:%SZ; }
h() { iso $((now - $1 * 3600)); }
d() { iso $((now - $1 * 86400)); }
journal="$(cat <<J
{"at":"$(h 50)","platform":"Vercel","name":"web","result":"failed","detail":"Build failed"}
{"at":"$(h 47)","platform":"Vercel","name":"web","result":"live","detail":"ok"}
{"at":"$(h 5)","platform":"Vercel","name":"web","result":"live","detail":"ok"}
{"at":"$(h 30)","platform":"Render","name":"api","result":"failed","detail":"=SUM(1) token=ghp_abcdefgh12345678 broke"}
{"at":"$(d 100)","platform":"Render","name":"old","result":"live","detail":"long ago"}
{"at":"$(d 9)","platform":"Vercel","name":"web","result":"live","detail":"before"}
{"at":"$(d 10)","platform":"Vercel","name":"web","result":"failed","detail":"before"}
{"at":"$(d 9)","platform":"Vercel","name":"web","result":"live","detail":"before 2"}
not json
J
)"

mode_of() { stat -c %a "$1" 2>/dev/null || stat -f %Lp "$1"; }

# --- health ---
hj="$(health_from "$now" 30 "" '[{"platform":"Vercel","name":"web","state":"green"}]' <<<"$journal")"
expect "health: worst first, the stale project is listed" "$(jq -c '[.projects[].name]' <<<"$hj")" '["api","old","web"]'
expect "health: an open failure earns no recovery points" "$(jq -c '.projects[] | select(.name == "api") | .parts.recovery.points' <<<"$hj")" "0"
expect "health: CI green earns its 15 points" "$(jq -c '.projects[] | select(.name == "web") | .parts.ci' <<<"$hj")" '{"points":15,"max":15}'
expect "health: a part without data is null, not zero" "$(jq -c '.projects[] | select(.name == "api") | .parts.ci.points' <<<"$hj")" "null"
expect "health: the score is 0-100" "$(jq -c '[.projects[].score | select(. < 0 or . > 100)] | length' <<<"$hj")" "0"
expect "health: ratings" "$(jq -c '[.projects[] | .rating]' <<<"$hj")" '["poor","poor","watch"]'
expect "health: --project narrows" "$(health_from "$now" 30 api '[]' <<<"$journal" | jq -c '[.projects[].name]')" '["api"]'
expect "health: no journal, no projects" "$(health_from "$now" 30 "" '[]' </dev/null | jq -c '{p:.projects, a:.average}')" '{"p":[],"a":null}'
perfect="$(printf '{"at":"%s","platform":"Vercel","name":"x","result":"live","detail":"ok"}\n' "$(h 2)")"
expect "health: a clean project with CI unknown scores 100" "$(health_from "$now" 30 "" '[]' <<<"$perfect" | jq '.projects[0].score')" "100"
expect "health: a CI that is red costs its points" "$(health_from "$now" 30 "" '[{"platform":"Vercel","name":"x","state":"red"}]' <<<"$perfect" | jq '.projects[0].score')" "85"
out="$(health_print <<<"$hj")"
expect "health: text starts with its title" "$(head -n 1 <<<"$out")" "Health of your projects, last 30 days (0-100, worst first)"
expect "health: cli --json is JSON with --no-ci" "$(printf '%s\n' "$journal" > "$tmp/journal.jsonl"; cli health --no-ci --json | jq -r '.ciRead')" "false"
expect "health: a wrong option is refused" "$(cli health --bogus 2>&1 | grep -c 'Usage: deploys health')" "1"

# --- weeks ---
wj="$(weeks_from "$now" 7 "" <<<"$journal")"
expect "weeks: this period counts the last 7 days" "$(jq -c '.current | {deploys, failures}' <<<"$wj")" '{"deploys":2,"failures":2}'
expect "weeks: the period before is the 7 days before" "$(jq -c '.previous | {deploys, failures, recovered}' <<<"$wj")" '{"deploys":2,"failures":1,"recovered":1}'
expect "weeks: the change is current minus previous" "$(jq -c '.change.deploys' <<<"$wj")" "0"
expect "weeks: --project" "$(weeks_from "$now" 7 api <<<"$journal" | jq -c '.current | {deploys, failures}')" '{"deploys":0,"failures":1}'
expect "weeks: an empty journal" "$(weeks_from "$now" 7 "" </dev/null | jq -c '.current | {deploys, failureRate}')" '{"deploys":0,"failureRate":null}'
expect "weeks: text says nothing when there is nothing" "$(weeks_from "$now" 7 "" </dev/null | weeks_print | tail -n 1)" "  Nothing in the journal for this time."
expect "weeks: a wrong --days is refused" "$(cli weeks --days 0 2>&1 | grep -c 'takes a number')" "1"

# --- export ---
real="$(date +%s)"
rh() { iso $((real - $1 * 3600)); }
rows="$(export_journal_json "$now" 30 "" <<<"$journal" | export_mask_details)"
expect "export: junk left out, the old line too" "$(jq length <<<"$rows")" "7"
expect "export: a token in a detail is masked" "$(jq -r '[.[] | select(.name == "api") | .detail][0]' <<<"$rows" | grep -c 'ghp_abcdefgh')" "0"
cat > "$tmp/journal.jsonl" <<J
{"at":"$(rh 3)","platform":"Vercel","name":"web","result":"live","detail":"ok"}
{"at":"$(rh 2)","platform":"Render","name":"api","result":"failed","detail":"=1+1 key sk-abcdefghij12345678"}
J
csv="$(cli export --days 30)"
expect "export: csv header is fixed" "$(head -n 1 <<<"$csv")" "at,platform,name,result,detail"
expect "export: a detail that starts with = is neutralised" "$(grep -c "\"'=1+1" <<<"$csv")" "1"
expect "export: a key in a detail is masked" "$(grep -c 'sk-abcdefghij' <<<"$csv")" "0"
expect "export: --project narrows" "$(cli export --project web | wc -l | tr -d ' ')" "2"
cli export --format json --out "$tmp/out.json" >/dev/null
expect "export: --out writes valid JSON with the schema" "$(jq -c '{kind, schema, n:(.journal | length)}' "$tmp/out.json")" '{"kind":"deploys-export","schema":1,"n":2}'
mode="$(mode_of "$tmp/out.json")"
expect "export: the file is 0600" "$mode" "600"
cli export --what all --out "$tmp/dir" >/dev/null
expect "export: csv all writes two files, both 0600" "$(ls "$tmp/dir" | paste -sd' ' -):$(mode_of "$tmp/dir/journal.csv")" "costs.csv journal.csv:600"
expect "export: costs csv without Vercel has just the header" "$(cat "$tmp/dir/costs.csv")" "day,total_usd,build_usd"
expect "export: csv all needs a folder" "$(cli export --what all 2>&1 | grep -c 'give a folder')" "1"
expect "export: a wrong format is refused" "$(cli export --format xml 2>&1 | grep -c 'csv or json')" "1"
expect "completion knows the commands" "$(cli completion bash | grep -c 'health')" "2"

[ "$fails" = 0 ] && echo "all ok" || { echo "$fails failed"; exit 1; }
