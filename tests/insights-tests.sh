#!/bin/bash
# Tests for `deploys timeline`, `deploys recovery` and `deploys when` (lib/insights.sh). No network, no real
# projects: the journal is made up in a temp folder. Run: tests/insights-tests.sh
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
# shellcheck source=../deploys
. ./deploys
set +e
cli() { env -u DEPLOYS_LIB DEPLOYS_JOURNAL="$tmp/journal.jsonl" bash ./deploys "$@"; }

# A fixed moment: Wednesday 2027-01-13 12:00:00 UTC.
now=1799841600
iso() { date -u -r "$1" +%Y-%m-%dT%H:%M:%SZ 2>/dev/null || date -u -d "@$1" +%Y-%m-%dT%H:%M:%SZ; }
h() { iso $((now - $1 * 3600)); }
journal="$(cat <<J
{"at":"$(h 50)","platform":"Vercel","name":"web","result":"failed","detail":"Build failed: exit 1"}
{"at":"$(h 49)","platform":"Vercel","name":"web","result":"failed","detail":"Build failed again"}
{"at":"$(h 47)","platform":"Vercel","name":"web","result":"live","detail":"ok"}
{"at":"$(h 30)","platform":"Render","name":"api","result":"failed","detail":"Deploy failed"}
{"at":"$(h 5)","platform":"Vercel","name":"web","result":"other","detail":"Started from the terminal (dpl_1)"}
{"at":"$(h 4)","platform":"Vercel","name":"web","result":"rollback","detail":"back"}
{"at":"$(h 3)","platform":"Vercel","name":"web","result":"forced","detail":"Deployed in the window \"Friday\": hotfix"}
{"at":"$(iso $((now - 86400 * 40)))","platform":"Vercel","name":"old","result":"failed","detail":"too old"}
{"at":"$(iso $((now + 3600)))","platform":"Vercel","name":"later","result":"live","detail":"in the future"}
not json at all
{"at":"nope","name":"bad","result":"live"}
J
)"

# --- timeline_from ---
t="$(timeline_from "$now" 3 "" 50 <<<"$journal")"
expect "timeline: counts the lines of the window, junk and the future left out" "$(jq -c '{total, shown}' <<<"$t")" '{"total":7,"shown":7}'
expect "timeline: newest first" "$(jq -c '[.entries[0:3][] | .kind]' <<<"$t")" '["forced","rollback","deploy"]'
expect "timeline: a journaled start is a deploy, a failure keeps its kind" "$(jq -c '[.entries[] | .kind] | unique' <<<"$t")" '["deploy","failed","forced","rollback"]'
expect "timeline: --limit shows fewer and says how many there are" "$(timeline_from "$now" 3 "" 2 <<<"$journal" | jq -c '{total, shown}')" '{"total":7,"shown":2}'
expect "timeline: one project" "$(timeline_from "$now" 3 api 50 <<<"$journal" | jq -c '{total, n:[.entries[].name] | unique}')" '{"total":1,"n":["api"]}'
expect "timeline: a longer window takes the old line in" "$(timeline_from "$now" 60 "" 50 <<<"$journal" | jq .total)" "8"
expect "timeline: an empty journal" "$(timeline_from "$now" 3 "" 50 </dev/null | jq -c '{total, entries}')" '{"total":0,"entries":[]}'
out="$(timeline_print <<<"$t")"
expect "timeline: the text starts with its title" "$(head -n 1 <<<"$out")" "Timeline of the last 3 days (UTC)"
expect "timeline: a failure is shouted, a day is a heading" "$(grep -c 'FAILED\|^  20' <<<"$out")" "6"
expect "timeline: control characters in a detail are blanked" "$(timeline_from "$now" 3 "" 5 <<<'{"at":"'"$(h 1)"'","name":"x","result":"failed","detail":"a\u001b[31mb"}' | jq -r '.entries[0].detail')" "a [31mb"

# --- recovery_from ---
r="$(recovery_from "$now" 30 "" <<<"$journal")"
expect "recovery: two failures in a row are one outage, ended by the next deploy" "$(jq -c '.projects[] | select(.name == "web") | {recovered, open, medianSeconds}' <<<"$r")" '{"recovered":1,"open":0,"medianSeconds":10800}'
expect "recovery: a failure without a later deploy is open" "$(jq -c '.projects[] | select(.name == "api") | {recovered, open, m:.medianSeconds}' <<<"$r")" '{"recovered":0,"open":1,"m":null}'
expect "recovery: totals, the open outage first" "$(jq -c '{outages, recovered, open, first:.projects[0].name}' <<<"$r")" '{"outages":2,"recovered":1,"open":1,"first":"api"}'
expect "recovery: the old failure is out of a 30-day window" "$(jq '[.projects[].name] | index("old")' <<<"$r")" "null"
expect "recovery: no failures, no outages" "$(recovery_from "$now" 30 "" </dev/null | jq -c '{outages, projects}')" '{"outages":0,"projects":[]}'
expect "recovery: one project" "$(recovery_from "$now" 30 web <<<"$journal" | jq -c '[.projects[].name]')" '["web"]'
expect "recovery_human" "$(recovery_human 45) $(recovery_human 720) $(recovery_human 12000) $(recovery_human 187200)" "45s 12m 3h 20m 2d 4h"
out="$(recovery_print <<<"$r")"
expect "recovery: the text names the open outage" "$(grep -c 'api (Render): 0 recovered, OPEN since' <<<"$out")" "1"

# --- when_from ---
w="$(when_from "$now" 90 weekday <<<"$journal")"
expect "when: slots are weekdays, Monday first" "$(jq -c '[.slots[].slot]' <<<"$w")" '["Mon","Tue","Wed","Fri"]'
expect "when: tries are deploys and failures" "$(jq .tries <<<"$w")" "6"
expect "when: too few tries name no best or worst" "$(jq -c '[.best, .worst]' <<<"$w")" '[null,null]'
many=""; for i in 1 2 3 4 5 6; do many="$many{\"at\":\"$(iso $((now - 86400 * 7 * i)))\",\"platform\":\"Vercel\",\"name\":\"w\",\"result\":\"$([ $i -le 3 ] && echo failed || echo live)\",\"detail\":\"x\"}
"; done
for i in 1 2 3 4 5 6; do many="$many{\"at\":\"$(iso $((now - 86400 * 7 * i - 86400)))\",\"platform\":\"Vercel\",\"name\":\"w\",\"result\":\"live\",\"detail\":\"x\"}
"; done
w2="$(when_from "$now" 90 weekday <<<"$many")"
expect "when: Wednesdays fail half the time, Tuesdays never" "$(jq -c '{worst, best}' <<<"$w2")" '{"worst":{"slot":"Wed","deploys":3,"failures":3,"tries":6,"rate":50},"best":{"slot":"Tue","deploys":6,"failures":0,"tries":6,"rate":0}}'
expect "when: by hour, one slot at 12:00" "$(when_from "$now" 90 hour <<<"$many" | jq -c '[.slots[] | select(.tries > 0) | .slot] | unique')" '["12:00"]'
expect "when: the text says it is a hint" "$(when_print <<<"$w2" | grep -c 'not a rule')" "1"

# --- the commands ---
# The commands read the real clock: a journal of the last hours, written now.
rnow="$(date +%s)"
{ echo "{\"at\":\"$(iso $((rnow - 7200)))\",\"platform\":\"Vercel\",\"name\":\"web\",\"result\":\"failed\",\"detail\":\"x\"}"
  echo "{\"at\":\"$(iso $((rnow - 3600)))\",\"platform\":\"Vercel\",\"name\":\"web\",\"result\":\"live\",\"detail\":\"ok\"}"; } > "$tmp/journal.jsonl"
cli timeline --days 1 --limit 1 --json | jq -e '.shown == 1 and .total == 2' >/dev/null; expect "cli timeline --json" "$?" "0"
expect "cli recovery: typical recovery of one hour" "$(cli recovery 2>&1 | sed -n 2p)" "  1 outage, 1 recovered, 0 still open, typical recovery 1h 0m"
expect "cli: a bad --days is refused" "$(cli recovery --days x 2>&1 | head -n 1)" "Error: --days takes a number of days, 1 or more"
expect "cli: a bad --by is refused" "$(cli when --by month 2>&1 | head -n 1)" "Error: --by takes weekday or hour"
expect "cli: an unknown option is refused" "$(cli timeline --nope 2>&1 | head -n 1 | cut -c1-28)" "Error: Unknown option --nope"
: > "$tmp/journal.jsonl"
expect "cli: an empty journal is said, not an error" "$(cli when 2>&1 | sed -n 2p)" "  Nothing in the journal for this time."
expect "cli: observer mode may look" "$(DEPLOYS_READONLY=1 cli recovery 2>&1 | sed -n 2p)" "  No failures in the journal for this time."
expect "completion knows the commands" "$(cli completion bash | grep -c 'recovery')" "2"

# --- streak_from ---
sj="$(cat <<J
{"at":"$(h 90)","platform":"Vercel","name":"web","result":"live","detail":"ok"}
{"at":"$(h 80)","platform":"Vercel","name":"web","result":"live","detail":"ok"}
{"at":"$(h 70)","platform":"Vercel","name":"web","result":"live","detail":"ok"}
{"at":"$(h 60)","platform":"Vercel","name":"web","result":"failed","detail":"x"}
{"at":"$(h 50)","platform":"Vercel","name":"web","result":"other","detail":"Started from the terminal (dpl_1)"}
{"at":"$(h 40)","platform":"Vercel","name":"web","result":"live","detail":"ok"}
{"at":"$(h 30)","platform":"Vercel","name":"web","result":"rollback","detail":"not a deploy"}
{"at":"$(h 20)","platform":"Render","name":"api","result":"failed","detail":"x"}
J
)"
st="$(streak_from "$now" 30 "" <<<"$sj")"
expect "streak: now counts since the last failure, a rollback is not a deploy" "$(jq -c '.projects[] | select(.name == "web") | {current, longest, deploys, failures}' <<<"$st")" '{"current":2,"longest":3,"deploys":5,"failures":1}'
expect "streak: a project that only failed has no streak" "$(jq -c '.projects[] | select(.name == "api") | {current, longest}' <<<"$st")" '{"current":0,"longest":0}'
expect "streak: the longest running streak first" "$(jq -r '.projects[0].name' <<<"$st")" "web"
expect "streak: one project" "$(streak_from "$now" 30 api <<<"$sj" | jq -c '[.projects[].name]')" '["api"]'
expect "streak: an empty journal" "$(streak_from "$now" 30 "" </dev/null | jq -c '.projects')" "[]"
expect "streak: the text line" "$(streak_print <<<"$(streak_from "$now" 30 api <<<"$sj")" | tail -n 1)" "  api (Render): 0 now, longest 0 (0 deploys, 1 failed, last failure $(iso $((now - 20 * 3600)) | cut -c1-10))"

# --- note ---
expect "note_text: control characters and runs of blanks" "$(note_text $'fix\t the   login\001 bug ')" "fix the login bug"
note_text "" >/dev/null 2>&1; expect "note_text: empty is refused" "$?" "1"
note_text "$(printf 'x%.0s' $(seq 1 201))" >/dev/null 2>&1; expect "note_text: over 200 characters is refused" "$?" "1"
if command -v perl >/dev/null 2>&1; then
  note_text "token ghp_abcdefghijklmnop12" >/dev/null 2>&1; expect "note_text: a token is refused, not masked" "$?" "1"
  note_text "DB_PASSWORD=hunter2hunter2" >/dev/null 2>&1; expect "note_text: a password setting is refused" "$?" "1"
fi
: > "$tmp/journal.jsonl"
expect "cli note: says what it wrote" "$(cli note web "hotfix for login")" "Noted for web: hotfix for login"
expect "cli note: one journal line with the result note" "$(jq -c '{platform, name, result, detail}' "$tmp/journal.jsonl")" '{"platform":"cli","name":"web","result":"note","detail":"hotfix for login"}'
expect "cli note: it is in the timeline" "$(cli timeline --days 1 | grep -c 'note .*web (cli): hotfix for login')" "1"
expect "cli note: observer mode may use it (only the local journal)" "$(DEPLOYS_READONLY=1 cli note web "seen" | head -n 1)" "Noted for web: seen"
expect "cli note: a bad project name is refused" "$(cli note 'a b' x 2>&1 | head -n 1 | cut -c1-31)" "Error: A project name has lette"
expect "cli note: text is needed" "$(cli note web 2>&1 | head -n 1)" 'Error: Usage: deploys note <project> "text"'
expect "cli streak --json" "$(cli streak --json | jq -c '[.projects[].name]')" "[]"
expect "cli streak: an empty window says so" "$(cli streak | tail -n 1)" "  No deploys in the journal for this time."

echo; [ "$fails" = 0 ] && echo "All insights tests passed." || { echo "$fails failed."; exit 1; }
