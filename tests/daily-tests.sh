#!/bin/bash
# Tests for `deploys daily` (lib/x-daily.sh): the file check, what is due, the text that goes out, the send through a
# fake curl (token never an argument), the caps, the schedule. Fakes only: no network, no launchd, no real HOME, no
# keychain. Run: tests/daily-tests.sh
set -uo pipefail
cd "$(dirname "$0")/.." || exit 1
exec </dev/null
fails=0
ok()   { echo "ok   $1"; }
fail() { echo "FAIL $1: $2"; fails=$((fails+1)); }
expect() { [ "$2" = "$3" ] && ok "$1" || fail "$1" "expected [$3], got [$2]"; }

tmp="$(mktemp -d)"; trap 'rm -rf "$tmp"' EXIT
export DEPLOYS_CONFIG="$tmp/config" HOME="$tmp/home" NO_COLOR=1 DEPLOYS_JOURNAL="$tmp/j.jsonl" DEPLOYS_NOTIFY=0 LANG=C LC_ALL=
export DEPLOYS_ROUTINE_API="http://routines.test" DEPLOYS_DAILY_TOKEN="sk-ant-oat01-SECRET" CALLS="$tmp/calls"
unset DEPLOYS_DAILY_PER_DAY DEPLOYS_DAILY_LATE
mkdir -p "$HOME" "$DEPLOYS_CONFIG" "$tmp/bin" "$tmp/agents"
cat > "$tmp/bin/curl" <<'CURL'
#!/bin/bash
echo "argv $*" >> "$CALLS"; sed 's/^/stdin /' >> "$CALLS"
case "${CODE:-200}" in
  200) printf '%s\n200' '{"type":"routine_fire","claude_code_session_url":"https://claude.ai/code/session_x"}' ;;
  *) printf '%s\n%s' '{"error":{"type":"x"}}' "$CODE" ;;
esac
CURL
cat > "$tmp/bin/gh" <<'GH'
#!/bin/bash
case "$*" in
  "repo list --limit 1000 --json nameWithOwner,isArchived") echo '[{"nameWithOwner":"me/app","isArchived":false},{"nameWithOwner":"me/old","isArchived":true}]' ;;
  "api user/orgs --jq .[].login") printf 'acme\nbad;name\n' ;;
  "repo list acme --limit 1000 --json nameWithOwner,isArchived") echo '[{"nameWithOwner":"acme/web","isArchived":false},{"nameWithOwner":"me/app","isArchived":false}]' ;;
  *) exit 1 ;;
esac
GH
printf '#!/bin/bash\nexit 0\n' > "$tmp/bin/launchctl"
chmod +x "$tmp/bin/"*
export PATH="$tmp/bin:$PATH" DEPLOYS_LAUNCH_DIR="$tmp/agents"
d() { bash ./deploys daily "$@"; }

# --- the defaults, add, the check ---
expect "blocks: four come with it" "$(d blocks --json | jq -c '[.[].id]')" '["ideas","bugs","ui","tests"]'
expect "blocks: German when the system speaks German" "$(LANG=de_DE.UTF-8 d blocks --json | jq -r '.[0].name')" "Ideen & Verbesserungen"
d add acme/web --blocks ideas,bugs --at 01:30 >/dev/null
d add acme/web --blocks ui --days 1,5 --model opus --on >/dev/null
expect "add: two tasks, the second gets its own id" "$(jq -c '[.tasks[] | [.id, .on, .model]]' "$DEPLOYS_CONFIG/daily.json")" '[["web",false,"sonnet"],["web-2",true,"opus"]]'
expect "add: the blocks are written into the file" "$(jq '.blocks | length' "$DEPLOYS_CONFIG/daily.json")" "4"
before="$(cat "$DEPLOYS_CONFIG/daily.json")"
rc=0; out="$(d add 'acme/web;rm' --blocks nope 2>&1)" || rc=$?
expect "add: a bad repo and an unknown block are refused" "$rc:$(echo "$out" | grep -c 'the repo is owner/name\|there is no block nope')" "1:2"
expect "add: the file is unchanged after a refusal" "$(cat "$DEPLOYS_CONFIG/daily.json")" "$before"
for bad in '{"blocks":[],"tasks":[{"id":"x","repo":"a/b","blocks":["q"],"at":"24:00","days":[8]}]}' 'not json' '[]' \
           '{"blocks":[{"id":"a","name":"A","text":"t"},{"id":"a","name":"B","text":"t"}],"tasks":[]}'; do
  rc=0; printf '%s' "$bad" | d save >/dev/null 2>&1 || rc=$?
  expect "save: refused ($(echo "$bad" | cut -c1-30))" "$rc" "1"
done
expect "save: refusals left the file alone" "$(cat "$DEPLOYS_CONFIG/daily.json")" "$before"
printf '%s' "$before" | jq '.tasks[0].name = "Web nightly"' | d save >/dev/null
expect "save: a good file is written" "$(jq -r '.tasks[0].name' "$DEPLOYS_CONFIG/daily.json")" "Web nightly"

# --- what is due (pure) ---
conf="$(cat "$DEPLOYS_CONFIG/daily.json" | jq '.tasks[0].on = true')"
due() { echo "$conf" | daily_due "$@"; }
# shellcheck source=../deploys
DEPLOYS_LIB=1 . ./deploys
set +e
expect "due: before the time, nothing" "$(due 2026-11-30 01:00 1 360 '{"fires":[]}' | tr '\n' ' ')" ""
expect "due: after the time, both on a Monday" "$(due 2026-11-30 02:10 1 360 '{"fires":[]}' | tr '\n' ' ')" "web web-2 "
expect "due: web-2 not on a Tuesday" "$(due 2026-12-01 02:10 2 360 '{"fires":[]}' | tr '\n' ' ')" "web "
expect "due: more than <late> minutes late waits" "$(due 2026-11-30 09:00 1 360 '{"fires":[]}' | tr '\n' ' ')" ""
expect "due: sent today is not sent again" "$(due 2026-11-30 02:10 1 360 '{"fires":[{"task":"web","date":"2026-11-30","status":"fired"},{"task":"web-2","date":"2026-11-30","status":"failed"}]}' | tr '\n' ' ')" ""
expect "due: a rate-limited send is tried again" "$(due 2026-11-30 02:10 1 360 '{"fires":[{"task":"web","date":"2026-11-30","status":"ratelimited"}]}' | tr '\n' ' ')" "web web-2 "
expect "due: yesterday's send does not count" "$(due 2026-11-30 02:10 1 360 '{"fires":[{"task":"web","date":"2026-11-29","status":"fired"}]}' | tr '\n' ' ')" "web web-2 "

# --- the text ---
txt="$(echo "$conf" | daily_payload web 2026-11-30)"
expect "payload: repo, blocks in order, rules" "$(echo "$txt" | grep -cE -e '^repo: acme/web$' -e '^## Ideas & improvements$' -e '^## Fix bugs$' -e '^## Rules \(always\)$' -e 'gh pr list' -e 'never force-push')" "6"
expect "payload: the docs show the routine prompt as it is" "$(daily_prompt | while IFS= read -r l; do grep -qxF -- "$l" docs/DAILY.md || echo "missing: $l"; done)" ""

# --- run: needs --yes, needs a routine; the send ---
rc=0; d run web >/dev/null 2>&1 || rc=$?
expect "run: without --yes nothing goes out" "$rc:$([ -f "$CALLS" ] && echo called || echo none)" "1:none"
rc=0; d run web --yes >/dev/null 2>&1 || rc=$?
expect "run: no routine set is a failure, noted" "$rc:$(jq -r '.fires[-1].status' "$DEPLOYS_CONFIG/daily-state.json"):$([ -f "$CALLS" ] && echo called || echo none)" "1:failed:none"
rm -f "$DEPLOYS_CONFIG/daily-state.json"
rc=0; d routine nope >/dev/null 2>&1 || rc=$?; expect "routine: a bad id is refused" "$rc" "1"
d routine trig_01Sonnet >/dev/null; d routine trig_01Opus --model opus >/dev/null
expect "routine: one per model" "$(jq -c . "$DEPLOYS_CONFIG/daily-routine")" '{"sonnet":"trig_01Sonnet","opus":"trig_01Opus"}'
expect "routine_for: haiku falls back to sonnet, a task's own wins" "$(daily_routine_for haiku) $(daily_routine_for opus) $(daily_routine_for opus trig_01Own)" "trig_01Sonnet trig_01Opus trig_01Own"
out="$(d run web --yes 2>&1)"
expect "run: sent to the sonnet routine" "$(grep -c '^argv .*http://routines.test/trig_01Sonnet/fire' "$CALLS")" "1"
expect "run: the token is never an argument" "$(grep '^argv' "$CALLS" | grep -c SECRET)" "0"
expect "run: the token goes on stdin" "$(grep -c '^stdin header = "Authorization: Bearer sk-ant-oat01-SECRET"' "$CALLS")" "1"
expect "run: noted as fired with the session" "$(jq -r '.fires[-1] | "\(.status) \(.session) \(.model)"' "$DEPLOYS_CONFIG/daily-state.json")" "fired https://claude.ai/code/session_x sonnet"
expect "run: a journal line, not counted as a deploy" "$(jq -r 'select(.platform == "claude") | "\(.name) \(.result)"' "$DEPLOYS_JOURNAL")" "acme/web other"
expect "run: the journal line does not start with Started" "$(jq -r 'select(.platform == "claude") | .detail' "$DEPLOYS_JOURNAL" | grep -c '^Started')" "0"
expect "run --dry-run: sends nothing" "$(d run web --dry-run | grep -c '^## Rules (always)$'):$(grep -c '^argv' "$CALLS")" "1:1"

# --- tick: only what is due, once, caps, 429, failures ---
rm -f "$CALLS" "$DEPLOYS_CONFIG/daily-state.json"; d enable web >/dev/null
rc=0; d tick >/dev/null 2>&1 || rc=$?; expect "tick: without --yes nothing goes out" "$rc:$([ -f "$CALLS" ] && echo called || echo none)" "1:none"
DEPLOYS_DAILY_CLOCK="2026-11-30 02:10 1" d tick --yes >/dev/null 2>&1
expect "tick: both due tasks sent, opus to its routine" "$(grep -c '^argv' "$CALLS"):$(grep -c 'trig_01Opus/fire' "$CALLS")" "2:1"
DEPLOYS_DAILY_CLOCK="2026-11-30 02:20 1" d tick --yes >/dev/null 2>&1
expect "tick: not twice on one day" "$(grep -c '^argv' "$CALLS")" "2"
rm -f "$CALLS" "$DEPLOYS_CONFIG/daily-state.json"
DEPLOYS_DAILY_PER_DAY=1 DEPLOYS_DAILY_CLOCK="2026-11-30 02:10 1" d tick --yes >/dev/null 2>&1
expect "tick: the cap a day holds" "$(grep -c '^argv' "$CALLS")" "1"
rm -f "$CALLS" "$DEPLOYS_CONFIG/daily-state.json"
CODE=429 DEPLOYS_DAILY_CLOCK="2026-12-01 02:10 2" d tick --yes >/dev/null 2>&1
expect "tick: a 429 is noted as rate limited" "$(jq -r '[.fires[].status] | join(",")' "$DEPLOYS_CONFIG/daily-state.json")" "ratelimited"
DEPLOYS_DAILY_CLOCK="2026-12-01 02:20 2" d tick --yes >/dev/null 2>&1
expect "tick: tried again on the next run, one entry left" "$(jq -r '[.fires[].status] | join(",")' "$DEPLOYS_CONFIG/daily-state.json")" "fired"
rm -f "$CALLS" "$DEPLOYS_CONFIG/daily-state.json"
rc=0; CODE=500 DEPLOYS_DAILY_CLOCK="2026-12-01 02:10 2" d tick --yes >/dev/null 2>&1 || rc=$?
DEPLOYS_DAILY_CLOCK="2026-12-01 02:20 2" d tick --yes >/dev/null 2>&1
expect "tick: an error is noted and not retried that day" "$rc:$(grep -c '^argv' "$CALLS"):$(jq -r '.fires[0].status' "$DEPLOYS_CONFIG/daily-state.json")" "1:1:failed"
d disable web >/dev/null; rm -f "$CALLS" "$DEPLOYS_CONFIG/daily-state.json"
DEPLOYS_DAILY_CLOCK="2026-12-01 02:10 2" d tick --yes >/dev/null 2>&1
expect "tick: a task that is off is never sent" "$([ -f "$CALLS" ] && echo called || echo none)" "none"

# --- list, status, repos, schedule, observers ---
expect "status: tasks with their last send, routines, no token values" "$(d status | jq -c '[(.tasks | length), (.tasks[0].last.status), .routines.sonnet, (tostring | test("SECRET"))]')" '[2,null,"trig_01Sonnet",false]'
expect "list: one line per task" "$(d list | grep -c 'acme/web')" "2"
expect "repos: yours and your organisations', not archived, no odd names" "$(d repos --json)" '["acme/web","me/app"]'
d schedule on >/dev/null 2>&1
plist="$tmp/agents/app.deploycenter.dailytasks.plist"
expect "schedule: every 10 minutes, tick --yes" "$(grep -c '<integer>600</integer>' "$plist"):$(grep -c '<string>tick</string><string>--yes</string>' "$plist")" "1:1"
expect "schedule: the daily deploy's job is not touched" "$([ -e "$tmp/agents/app.deploycenter.daily.plist" ] && echo touched || echo apart)" "apart"
rc=0; DEPLOYS_READONLY=1 d run web-2 --yes >/dev/null 2>&1 || rc=$?
expect "observers cannot send" "$rc" "1"
expect "the extra command is listed" "$(bash ./deploys more --json | jq -r '.[] | select(.name == "daily") | .name')" "daily"

echo
if [ "$fails" = 0 ]; then echo "all daily tests passed"; else echo "$fails daily test(s) failed"; exit 1; fi
