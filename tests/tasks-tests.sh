#!/bin/bash
# Tests for `deploys tasks` (lib/x-tasks.sh): the file check, the schedules (once, hourly, daily, weekly) and their
# slots, the text that goes out, the routine per Claude account, the send through a fake curl (token never an
# argument), needs-setup and its one notice a day, the caps, the schedule job. Fakes only: no network, no launchd,
# no real HOME, no keychain. Run: tests/tasks-tests.sh
set -uo pipefail
cd "$(dirname "$0")/.." || exit 1
exec </dev/null
fails=0
ok()   { echo "ok   $1"; }
fail() { echo "FAIL $1: $2"; fails=$((fails+1)); }
expect() { [ "$2" = "$3" ] && ok "$1" || fail "$1" "expected [$3], got [$2]"; }

tmp="$(mktemp -d)"; trap 'rm -rf "$tmp"' EXIT
export DEPLOYS_CONFIG="$tmp/config" HOME="$tmp/home" NO_COLOR=1 DEPLOYS_JOURNAL="$tmp/j.jsonl" DEPLOYS_NOTIFY=0 LANG=C LC_ALL=
export DEPLOYS_ROUTINE_API="http://routines.test" DEPLOYS_TASKS_TOKEN="sk-ant-oat01-SECRET" CALLS="$tmp/calls"
export DEPLOYS_TASKS_ACCOUNT="acct-one-0001" DEPLOYS_NOTIFY_CMD="cat >> '$tmp/notices'"
unset DEPLOYS_TASKS_PER_DAY DEPLOYS_TASKS_PER_TASK DEPLOYS_TASKS_LATE
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
d() { bash ./deploys tasks "$@"; }
st() { jq -r "$1" "$DEPLOYS_CONFIG/tasks-state.json"; }
calls() { grep -c '^argv' "$CALLS" 2>/dev/null || echo 0; }
reset() { rm -f "$CALLS" "$DEPLOYS_CONFIG/tasks-state.json" "$tmp/notices"; }

# --- the defaults, add, the check ---
expect "blocks: four come with it" "$(d blocks --json | jq -c '[.[].id]')" '["ideas","bugs","ui","tests"]'
expect "blocks: German when the system speaks German" "$(LANG=de_DE.UTF-8 d blocks --json | jq -r '.[0].name')" "Ideen & Verbesserungen"
d add acme/web --blocks ideas,bugs --at 01:30 >/dev/null
d add acme/web --blocks ui --every weekly --days 5 --at 01:30 --model opus --on >/dev/null
d add acme/api --blocks bugs --every hourly --minute 15 --on >/dev/null
d add acme/api --blocks tests --every once --date 2026-12-24 --at 09:00 --on >/dev/null
f="$DEPLOYS_CONFIG/tasks.json"
expect "add: ids, switches, models" "$(jq -c '[.tasks[] | [.id, .on, .model, .schedule.kind]]' "$f")" \
  '[["web",false,"sonnet","daily"],["web-2",true,"opus","weekly"],["api",true,"sonnet","hourly"],["api-2",true,"sonnet","once"]]'
expect "add: the blocks are written into the file" "$(jq '.blocks | length' "$f")" "4"
before="$(cat "$f")"
rc=0; out="$(d add 'acme/web;rm' --blocks nope 2>&1)" || rc=$?
expect "add: a bad repo and an unknown block are refused" "$rc:$(echo "$out" | grep -cE 'the repo is owner/name|there is no block nope')" "1:2"
expect "add: the file is unchanged after a refusal" "$(cat "$f")" "$before"
rc=0; d add acme/web --blocks ui --every weekly --days 1,2 >/dev/null 2>&1 || rc=$?
expect "add: weekly is one day" "$rc" "1"
rc=0; d add acme/web --blocks ui --every once >/dev/null 2>&1 || rc=$?
expect "add: once needs a date" "$rc" "1"
for bad in '{"blocks":[],"tasks":[{"id":"x","repo":"a/b","blocks":["q"],"schedule":{"kind":"daily","at":"24:00","days":[8]}}]}' 'not json' '[]' \
           '{"blocks":[{"id":"a","name":"A","text":"t"},{"id":"a","name":"B","text":"t"}],"tasks":[]}' \
           '{"blocks":[{"id":"a","name":"A","text":"t"}],"tasks":[{"id":"x","repo":"a/b","blocks":["a"],"schedule":{"kind":"hourly","minute":75,"days":[1]}}]}' \
           '{"blocks":[{"id":"a","name":"A","text":"t"}],"tasks":[{"id":"x","repo":"a/b","blocks":["a"],"schedule":{"kind":"daily","at":"01:00","days":[1]},"account":"x;y"}]}'; do
  rc=0; printf '%s' "$bad" | d save >/dev/null 2>&1 || rc=$?
  expect "save: refused ($(echo "$bad" | cut -c1-40))" "$rc" "1"
done
expect "save: refusals left the file alone" "$(cat "$f")" "$before"
printf '%s' "$before" | jq '.tasks[0].name = "Web nightly"' | d save >/dev/null
expect "save: a good file is written" "$(jq -r '.tasks[0].name' "$f")" "Web nightly"

# --- what is due (pure): slots per kind ---
# shellcheck source=../deploys
DEPLOYS_LIB=1 . ./deploys
set +e
conf="$(jq '.tasks[0].on = true' "$f")"
due() { echo "$conf" | tasks_due "$@" | tr '\t\n' '= '; }
E='{"fires":[]}'
expect "due: Monday 01:00, the hourly one of 00:15 only" "$(due 2026-11-30 01:00 1 360 "$E")" "api=2026-11-30T00 "
expect "due: Monday 01:40, daily and hourly" "$(due 2026-11-30 01:40 1 360 "$E")" "web=2026-11-30 api=2026-11-30T01 "
expect "due: Friday 01:40, the weekly one too" "$(due 2026-12-04 01:40 5 360 "$E")" "web=2026-12-04 web-2=2026-12-04 api=2026-12-04T01 "
expect "due: more than <late> minutes late waits" "$(due 2026-11-30 09:00 1 360 "$E")" "api=2026-11-30T08 "
expect "due: hourly before its first minute of the day, nothing" "$(due 2026-11-30 00:10 1 360 "$E")" ""
expect "due: once on its day after its time" "$(due 2026-12-24 09:30 4 360 "$E")" "api=2026-12-24T09 api-2=2026-12-24T09:00 "
expect "due: once not the day after" "$(due 2026-12-25 09:30 5 360 "$E" | grep -c api-2)" "0"
S='{"fires":[{"task":"web","slot":"2026-11-30","status":"fired"},{"task":"api","slot":"2026-11-30T01","status":"failed"}]}'
expect "due: a slot sent (or failed) is not sent again" "$(due 2026-11-30 01:40 1 360 "$S")" ""
expect "due: the next hour is a new slot" "$(due 2026-11-30 02:20 1 360 "$S")" "api=2026-11-30T02 "
S='{"fires":[{"task":"web","slot":"2026-11-30","status":"needs-setup"},{"task":"api","slot":"2026-11-30T01","status":"ratelimited"}]}'
expect "due: needs-setup and rate limited are tried again" "$(due 2026-11-30 01:40 1 360 "$S")" "web=2026-11-30 api=2026-11-30T01 "
expect "due: yesterday's send does not count" "$(due 2026-11-30 01:40 1 360 '{"fires":[{"task":"web","slot":"2026-11-29","status":"fired"}]}' | grep -c 'web=')" "1"

# --- the text ---
txt="$(echo "$conf" | tasks_payload web 2026-11-30)"
expect "payload: repo, blocks in order, rules" "$(echo "$txt" | grep -cE -e '^repo: acme/web$' -e '^## Ideas & improvements$' -e '^## Fix bugs$' -e '^## Rules \(always\)$' -e 'gh pr list' -e 'never force-push')" "6"
expect "payload: the docs show the routine prompt as it is" "$(tasks_prompt | while IFS= read -r l; do grep -qxF -- "$l" docs/TASKS.md || echo "missing: $l"; done)" ""

# --- run: needs --yes; no routine for the account: needs-setup, one notice a day ---
rc=0; d run web >/dev/null 2>&1 || rc=$?
expect "run: without --yes nothing goes out" "$rc:$(calls)" "1:0"
rc=0; d run web --yes >/dev/null 2>&1 || rc=$?
expect "run: no routine for the account: nothing sent, needs-setup" "$rc:$(st '.fires[-1].status'):$(calls)" "3:needs-setup:0"
d run web --yes >/dev/null 2>&1
expect "run: needs-setup notifies once a day per account" "$(grep -c 'set up a routine for the Claude account acct-one' "$tmp/notices")" "1"
reset
rc=0; d routine nope >/dev/null 2>&1 || rc=$?; expect "routine: a bad id is refused" "$rc" "1"
d routine trig_01Sonnet --label Main >/dev/null; d routine trig_01Opus --model opus >/dev/null
d routine trig_01Two --account acct-two-0002 >/dev/null
expect "routine: per account and model" "$(jq -c . "$DEPLOYS_CONFIG/tasks-routines")" \
  '{"accounts":{"acct-one-0001":{"sonnet":"trig_01Sonnet","label":"Main","opus":"trig_01Opus"},"acct-two-0002":{"sonnet":"trig_01Two"}}}'
expect "routine_for: haiku falls back to sonnet; another account has its own" \
  "$(tasks_routine_for acct-one-0001 haiku) $(tasks_routine_for acct-one-0001 opus) $(tasks_routine_for acct-two-0002 opus) [$(tasks_routine_for nobody-0000 sonnet)]" \
  "trig_01Sonnet trig_01Opus trig_01Two []"
rc=0; printf 'tok\n' | d set-token >/dev/null 2>&1 || rc=$?
expect "set-token: a routine must be named (no shared token)" "$rc" "1"
d run web --yes >/dev/null 2>&1
expect "run: the signed-in account's sonnet routine" "$(grep -c '^argv .*http://routines.test/trig_01Sonnet/fire' "$CALLS")" "1"
expect "run: the token is never an argument" "$(grep '^argv' "$CALLS" | grep -c SECRET)" "0"
expect "run: the token goes on stdin" "$(grep -c '^stdin header = "Authorization: Bearer sk-ant-oat01-SECRET"' "$CALLS")" "1"
expect "run: noted as fired with the session" "$(st '.fires[-1] | "\(.status) \(.session) \(.model) \(.account)"')" "fired https://claude.ai/code/session_x sonnet acct-one-0001"
expect "run: a journal line, not counted as a deploy" "$(jq -r 'select(.platform == "claude") | "\(.name) \(.result)"' "$DEPLOYS_JOURNAL")" "acme/web other"
expect "run: the journal line does not start with Started" "$(jq -r 'select(.platform == "claude") | .detail' "$DEPLOYS_JOURNAL" | grep -c '^Started')" "0"
DEPLOYS_TASKS_ACCOUNT=acct-two-0002 d run web --yes >/dev/null 2>&1
expect "run: after switching account, that account's routine" "$(grep -c 'trig_01Two/fire' "$CALLS")" "1"
expect "run --dry-run: sends nothing" "$(d run web --dry-run | grep -c '^## Rules (always)$'):$(calls)" "1:2"

# --- tick: only what is due, once a slot, caps, 429, failures, switches ---
reset; d enable web >/dev/null
rc=0; d tick >/dev/null 2>&1 || rc=$?; expect "tick: without --yes nothing goes out" "$rc:$(calls)" "1:0"
DEPLOYS_TASKS_CLOCK="2026-12-04 01:40 5" d tick --yes >/dev/null 2>&1
expect "tick: three due, opus to its routine" "$(calls):$(grep -c 'trig_01Opus/fire' "$CALLS")" "3:1"
DEPLOYS_TASKS_CLOCK="2026-12-04 01:50 5" d tick --yes >/dev/null 2>&1
expect "tick: not twice in one slot" "$(calls)" "3"
DEPLOYS_TASKS_CLOCK="2026-12-04 02:20 5" d tick --yes >/dev/null 2>&1
expect "tick: the hourly one again in the next hour" "$(calls)" "4"
reset
DEPLOYS_TASKS_PER_DAY=1 DEPLOYS_TASKS_CLOCK="2026-11-30 01:40 1" d tick --yes >/dev/null 2>&1
expect "tick: the cap a day holds" "$(calls)" "1"
reset
DEPLOYS_TASKS_PER_TASK=1 DEPLOYS_TASKS_CLOCK="2026-11-30 01:40 1" d tick --yes >/dev/null 2>&1
DEPLOYS_TASKS_PER_TASK=1 DEPLOYS_TASKS_CLOCK="2026-11-30 02:20 1" d tick --yes >/dev/null 2>&1
expect "tick: the cap of one task holds" "$(calls)" "2"
reset
CODE=429 DEPLOYS_TASKS_CLOCK="2026-11-30 01:40 1" d tick --yes >/dev/null 2>&1
expect "tick: a 429 is noted as rate limited" "$(st '[.fires[].status] | join(",")')" "ratelimited,ratelimited"
DEPLOYS_TASKS_CLOCK="2026-11-30 01:50 1" d tick --yes >/dev/null 2>&1
expect "tick: tried again on the next run, one entry each" "$(st '[.fires[].status] | join(",")')" "fired,fired"
reset
rc=0; CODE=500 DEPLOYS_TASKS_CLOCK="2026-11-30 01:40 1" d tick --yes >/dev/null 2>&1 || rc=$?
DEPLOYS_TASKS_CLOCK="2026-11-30 01:50 1" d tick --yes >/dev/null 2>&1
expect "tick: an error is noted and not retried in that slot" "$rc:$(calls):$(st '.fires[0].status')" "1:2:failed"
expect "tick: a failed send is not a failed deploy for the morning report" \
  "$(morning_from "$(date +%s)" 24 '{}' '{"fires":[]}' null < "$DEPLOYS_JOURNAL" | jq -c '[(.failed | length), (.deployed | length)]')" "[0,0]"
reset
DEPLOYS_TASKS_ACCOUNT=nobody-0000 DEPLOYS_TASKS_CLOCK="2026-11-30 01:40 1" d tick --yes >/dev/null 2>&1
DEPLOYS_TASKS_ACCOUNT=nobody-0000 DEPLOYS_TASKS_CLOCK="2026-11-30 01:50 1" d tick --yes >/dev/null 2>&1
expect "tick: an account without routine sends nothing, one notice" "$(calls):$(grep -c 'Claude account' "$tmp/notices")" "0:1"
DEPLOYS_TASKS_CLOCK="2026-11-30 02:00 1" d tick --yes >/dev/null 2>&1
expect "tick: after signing in to a set-up account, the same slots go out" "$(calls):$(st '[.fires[].status] | unique | join(",")')" "2:fired"
d disable web >/dev/null; d disable api >/dev/null; reset
DEPLOYS_TASKS_CLOCK="2026-11-30 01:40 1" d tick --yes >/dev/null 2>&1
expect "tick: tasks that are off are never sent" "$(calls)" "0"

# --- list, status, accounts, repos, schedule, observers ---
expect "status: tasks, accounts, no token values" "$(d status | jq -c '[(.tasks | length), .active, (.accounts | length), (.accounts[0].tokens), (tostring | test("SECRET"))]')" \
  '[4,"acct-one-0001",2,["sonnet","opus"],false]'
expect "list: one line per task" "$(d list | grep -c 'acme/')" "4"
expect "repos: yours and your organisations', not archived, no odd names" "$(d repos --json)" '["acme/web","me/app"]'
d schedule on >/dev/null 2>&1
plist="$tmp/agents/app.deploycenter.tasks.plist"
expect "schedule: every 10 minutes, tick --yes" "$(grep -c '<integer>600</integer>' "$plist"):$(grep -c '<string>tick</string><string>--yes</string>' "$plist")" "1:1"
expect "schedule: the daily deploy's job is not touched" "$([ -e "$tmp/agents/app.deploycenter.daily.plist" ] && echo touched || echo apart)" "apart"
rc=0; DEPLOYS_READONLY=1 d run web-2 --yes >/dev/null 2>&1 || rc=$?
expect "observers cannot send" "$rc" "1"
expect "the extra command is listed" "$(bash ./deploys more --json | jq -r '.[] | select(.name == "tasks") | .name')" "tasks"

echo
if [ "$fails" = 0 ]; then echo "all tasks tests passed"; else echo "$fails tasks test(s) failed"; exit 1; fi
