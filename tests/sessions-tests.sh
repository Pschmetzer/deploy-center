#!/bin/bash
# Tests for the session counter (lib/sessions.sh): made-up session files, transcripts and a ps output in a temporary
# folder (DEPLOYS_SESSIONS_FIXTURE, DEPLOYS_SESSIONS_DIR, DEPLOYS_CLAUDE_PROJECTS), a fixed clock. No real process is
# read or ended. Run: bash tests/sessions-tests.sh
set -uo pipefail
cd "$(dirname "$0")/.." || exit 1
exec </dev/null
fails=0
ok()   { echo "ok   $1"; }
fail() { echo "FAIL $1: $2"; fails=$((fails+1)); }
expect() { [ "$2" = "$3" ] && ok "$1" || fail "$1" "expected [$3], got [$2]"; }

tmp="$(mktemp -d)"; trap 'rm -rf "$tmp"' EXIT
now=1800000000
export DEPLOYS_CONFIG="$tmp/config" HOME="$tmp/home" NO_COLOR=1 DEPLOYS_TESTING=1 DEPLOYS_SESSIONS_NOW=$now
export DEPLOYS_SESSIONS_FIXTURE="$tmp/fx" DEPLOYS_SESSIONS_DIR="$tmp/sessions" DEPLOYS_CLAUDE_PROJECTS="$tmp/projects"
mkdir -p "$HOME" "$DEPLOYS_CONFIG" "$tmp/fx" "$tmp/sessions" "$tmp/projects"
s() { bash lib/sessions.sh "$@"; }

# sess <pid> <uuid> <cwd> <title> <started, seconds before now> [status]
sess() {
  jq -n --argjson pid "$1" --arg id "$2" --arg cwd "$3" --arg name "$4" --argjson st "$(( (now - $5) * 1000 ))" --arg status "${6:-idle}" \
    '{pid:$pid, sessionId:$id, cwd:$cwd, name:$name, startedAt:$st, kind:"interactive", entrypoint:"cli", status:$status}' > "$tmp/sessions/$1.json"
}
# transcript <uuid> <cwd> <minutes ago>
transcript() {
  local d; d="$tmp/projects/$(printf '%s' "$2" | sed 's/[^A-Za-z0-9-]/-/g')"; mkdir -p "$d"
  : > "$d/$1.jsonl"; perl -e 'utime $ARGV[0], $ARGV[0], $ARGV[1]' "$((now - $3 * 60))" "$d/$1.jsonl"
}

C=/opt/claude/bin/claude
sess 101 aaaaaaaa-0000-4000-8000-000000000001 /work/shop/.wt/alpha "Fix the login" 7200 busy
sess 102 aaaaaaaa-0000-4000-8000-000000000002 /work/shop/.wt/beta "fix  the login!" 7200
sess 103 aaaaaaaa-0000-4000-8000-000000000003 /work/blog "Write the newsletter" 7200
sess 104 aaaaaaaa-0000-4000-8000-000000000004 /work/blog "Tidy the images" 600
sess 105 aaaaaaaa-0000-4000-8000-000000000005 /work/api "Dead session" 600          # no process
sess 106 aaaaaaaa-0000-4000-8000-000000000006 /work/api "Reused pid" 7200           # pid now a newer process
sess 107 aaaaaaaa-0000-4000-8000-000000000007 /work/api "Not claude" 7200           # pid is something else
sess 108 aaaaaaaa-0000-4000-8000-000000000008 /work/docs "" 300                     # no title, no transcript
echo 'not json' > "$tmp/sessions/109.json"
echo 'SECRET-KEY-MATERIAL' > "$tmp/sessions/101.0123abcd.key"
transcript aaaaaaaa-0000-4000-8000-000000000001 /work/shop/.wt/alpha 2
transcript aaaaaaaa-0000-4000-8000-000000000002 /work/shop/.wt/beta 90
transcript aaaaaaaa-0000-4000-8000-000000000003 /work/blog 61
transcript aaaaaaaa-0000-4000-8000-000000000004 /work/blog 5

# pid ppid pcpu rss(KB) etime args
cat > "$tmp/fx/ps" <<PS
  101     1  10.0  204800    02:00:05 $C --output-format stream-json
  201   101  40.0  512000       05:00 node /work/shop/node_modules/.bin/vitest run
  202   201   5.5  102400       04:00 node worker.js
  102     1   1.0  102400    02:00:00 $C
  103     1   0.5  102400  1-00:00:00 $C --resume
  104     1   0.0  102400       10:00 $C
  106     1   0.0   10240       01:00 $C
  107     1   0.0   10240    03:00:00 /usr/bin/python3 server.py
  108     1   2.0  307200       05:00 $C
PS

j="$(s --json)"
expect "JSON parses" "$(jq -r type <<<"$j")" "object"
expect "live claude sessions only: dead, reused and foreign pids and broken files left out" "$(jq -c '[.sessions[].pid] | sort' <<<"$j")" "[101,102,103,104,108]"
expect "count" "$(jq -r .local.count <<<"$j")" "5"
expect "five is under the default of 8: green" "$(jq -c '[.level, .local.max, .local.over]' <<<"$j")" '["green",8,false]'
expect "cloud is unknown, not zero" "$(jq -c '[.cloud.count, .cloud.status, .cloud.max]' <<<"$j")" '[null,"unknown",4]'
expect "CPU and RAM include the processes under the session" "$(jq -c '.sessions[] | select(.pid == 101) | [.cpu, .mb]' <<<"$j")" "[55.5,800]"
expect "title, folder and state" "$(jq -c '.sessions[] | select(.pid == 101) | [.title, .folder, .state]' <<<"$j")" '["Fix the login","alpha","busy"]'
expect "idle minutes from the transcript" "$(jq -c '[.sessions[] | {(.pid | tostring): .idleMin}] | add' <<<"$j")" '{"101":2,"104":5,"108":5,"103":61,"102":90}'
expect "no transcript: the session start counts" "$(jq -r '.sessions[] | select(.pid == 108) | .lastActivity' <<<"$j")" "$((now - 300))"
expect "idle for over an hour" "$(jq -c '.idle | sort' <<<"$j")" "[102,103]"
expect "same task twice (case, spaces and punctuation ignored)" "$(jq -c '.duplicates' <<<"$j")" '[{"title":"Fix the login","pids":[101,102]}]'
expect "two sessions in one folder" "$(jq -c '[.sameFolder[] | [.folder, (.pids | sort)]]' <<<"$j")" '[["blog",[103,104]]]'
expect "different folders of one repo are not the same folder" "$(jq -r '.sessions[] | select(.pid == 101) | .sameFolder' <<<"$j")" "false"
expect "an empty title is never a duplicate" "$(jq -r '.sessions[] | select(.pid == 108) | .duplicate' <<<"$j")" "false"
expect "flags on a session" "$(jq -c '.sessions[] | select(.pid == 102) | [.duplicate, .idle]' <<<"$j")" "[true,true]"
expect "the hint is to bundle" "$(jq -r .hint <<<"$j")" "bundle tasks"
expect "most recent first" "$(jq -r '.sessions[0].pid' <<<"$j")" "101"
grep -rq SECRET "$tmp/config" 2>/dev/null && fail "key file" "copied" || ok "the .key file is never read"
[[ "$j" == *SECRET* ]] && fail "key file" "in the output" || ok "nothing of the .key file in the output"

# --- threshold ---
expect "set max-local" "$(s set max-local 5)" "sessions: max-local = 5"
expect "at the threshold: yellow" "$(s --json | jq -c '[.level, .local.over]')" '["yellow",true]'
s set max-local 6 >/dev/null
expect "one under: green" "$(s --json | jq -r .level)" "green"
s set max-cloud 3 >/dev/null; s set idle-min 100 >/dev/null
expect "the config keeps every key" "$(jq -c -S . "$DEPLOYS_CONFIG/sessions.json")" '{"idleMin":100,"maxCloud":3,"maxLocal":6}'
expect "idle threshold from the config" "$(s --json | jq -c '[.idle, .cloud.max]')" "[[],3]"
s set max-local 0 >/dev/null 2>&1; expect "0 is refused" "$?" "2"
s set max-local abc >/dev/null 2>&1; expect "a word is refused" "$?" "2"
s set nonsense 3 >/dev/null 2>&1; expect "an unknown key is refused" "$?" "2"
echo '{"maxLocal":"lots","idleMin":-4}' > "$DEPLOYS_CONFIG/sessions.json"
expect "a broken config falls back to the defaults" "$(s config)" '{"maxLocal":8,"maxCloud":4,"idleMin":60}'
echo '[1,2]' > "$DEPLOYS_CONFIG/sessions.json"
expect "a config that is not an object is ignored" "$(s config | jq -r .maxLocal)" "8"
rm -f "$DEPLOYS_CONFIG/sessions.json"

# --- no sessions ---
mkdir -p "$tmp/empty"
expect "no session folder: zero, green, no hint" "$(DEPLOYS_SESSIONS_DIR="$tmp/empty" s --json | jq -c '[.local.count, .level, .hint]')" '[0,"green",null]'

# --- text ---
t="$(s)"
expect "text: first line" "$(head -n 1 <<<"$t")" "Claude Code sessions on this Mac: 5 (yellow at 8) · cloud: unknown"
[[ "$t" == *"Same task twice:"* && "$t" == *"Fix the login: 101, 102"* ]] && ok "text names the twins" || fail "text names the twins" "$t"
[[ "$t" == *"Hint: bundle tasks"* && "$t" == *"deploys sessions stop <pid> --yes"* ]] && ok "text gives the hint and the way to close" || fail "hint" "$t"

# --- stop ---
o="$(s stop 102)"; [[ "$o" == "Would end session 102 (fix  the login!)"* ]] && ok "stop without --yes only says what it would do" || fail "stop dry" "$o"
expect "stop --yes (fixture: nothing sent)" "$(s stop 102 --yes)" "Ended session 102 (fixture: nothing sent)."
s stop 105 --yes >/dev/null 2>&1; expect "a dead session cannot be stopped" "$?" "1"
s stop 107 --yes >/dev/null 2>&1; expect "a pid that is not claude cannot be stopped" "$?" "1"
s stop 106 --yes >/dev/null 2>&1; expect "a reused pid cannot be stopped" "$?" "1"
s stop 'x; rm' --yes >/dev/null 2>&1; expect "a pid that is not a number is refused" "$?" "2"

# --- through deploys ---
expect "deploys sessions --json" "$(./deploys sessions --json | jq -r .local.count)" "5"

echo
[ "$fails" = 0 ] && echo "All session tests passed." || { echo "$fails failed"; exit 1; }
