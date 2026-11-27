#!/bin/bash
# Tests for the desktop session monitor (lib/desktopsessions.sh): made-up account folders with made-up UUIDs, live
# session files and claude answers in a temporary folder (DEPLOYS_DESKTOP_SESSIONS_BASE, DEPLOYS_LOCAL_SESSIONS_DIR,
# DEPLOYS_DESKTOP_SESSIONS_FIXTURE), a fixed clock. claude is never called and nothing is written to the session files.
# Run: bash tests/desktopsessions-tests.sh
set -uo pipefail
cd "$(dirname "$0")/.." || exit 1
exec </dev/null
fails=0
ok()   { echo "ok   $1"; }
fail() { echo "FAIL $1: $2"; fails=$((fails+1)); }
expect() { [ "$2" = "$3" ] && ok "$1" || fail "$1" "expected [$3], got [$2]"; }

tmp="$(mktemp -d)"; trap 'rm -rf "$tmp"' EXIT
now=1800000000
base="$tmp/Application Support/Claude/claude-code-sessions"   # a space in the path, as on a Mac
export DEPLOYS_CONFIG="$tmp/config" HOME="$tmp/home" NO_COLOR=1 DEPLOYS_TESTING=1 DEPLOYS_DESKTOP_SESSIONS_NOW=$now
export DEPLOYS_DESKTOP_SESSIONS_BASE="$base" DEPLOYS_LOCAL_SESSIONS_DIR="$tmp/live" DEPLOYS_DESKTOP_SESSIONS_FIXTURE="$tmp/fx"
export DEPLOYS_CLAUDE_BIN="$tmp/no-claude"   # would fail loudly if the fixture were ignored
mkdir -p "$HOME" "$DEPLOYS_CONFIG" "$tmp/live" "$tmp/fx"
d() { bash lib/desktopsessions.sh "$@"; }

A1=11111111-aaaa-4000-8000-000000000001; A2=22222222-bbbb-4000-8000-000000000002; A3=33333333-cccc-4000-8000-000000000003
O1=0000000a-0000-4000-8000-00000000000a; O2=0000000b-0000-4000-8000-00000000000b

# desk <account> <org> <n> <json fields>: one desktop file local_<made-up uuid>.json
desk() {
  local dir="$base/$1/$2" id; id="local_dddddddd-0000-4000-8000-$(printf '%012d' "$3")"; mkdir -p "$dir"
  jq -n --argjson f "$4" --argjson la "$(( (now - 7200) * 1000 ))" \
    '{sessionId: "x", title: "Task", cwd: "/work/shop", branch: "claude/x", isArchived: false, prs: [],
      lastActivityAt: $la, interruptedAwaitingPerson: null, postTurnSummary: {status_category: "completed", needs_action: ""},
      cliSessionId: "cccccccc-0000-4000-8000-000000000000"} + $f' > "$dir/$id.json"
}
# live <pid> <host n> <cli id> <status>
live() {
  jq -n --argjson pid "$1" --arg h "local_dddddddd-0000-4000-8000-$(printf '%012d' "$2")" --arg s "$3" --arg st "$4" \
    '{pid: $pid, sessionId: $s, hostSessionId: $h, status: $st}' > "$tmp/live/$1.json"
}
M='{"state":"MERGED","prNumber":1}'; C='{"state":"CLOSED","prNumber":2}'; O='{"state":"OPEN","prNumber":3}'

desk $A1 $O1 1 "{\"title\":\"Merged one\",\"prs\":[$M]}"                                   # done
desk $A1 $O1 2 "{\"title\":\"Merged and closed\",\"prs\":[$M,$C],\"cwd\":\"/work/blog\"}"    # done
desk $A1 $O1 3 "{\"title\":\"One still open\",\"prs\":[$M,$O]}"                             # open
desk $A1 $O1 4 "{\"title\":\"Asks you\",\"prs\":[$M],\"interruptedAwaitingPerson\":{\"kind\":\"q\"}}"  # waiting
desk $A1 $O1 5 "{\"title\":\"Busy\",\"prs\":[$M],\"cliSessionId\":\"cccccccc-0000-4000-8000-000000000005\"}"  # running (live, busy)
desk $A1 $O1 6 "{\"title\":\"Review ready\",\"prs\":[$M],\"postTurnSummary\":{\"status_category\":\"review_ready\"}}"
desk $A1 $O1 7 "{\"title\":\"Blocked\",\"prs\":[$C],\"postTurnSummary\":{\"status_category\":\"blocked\"}}"
desk $A1 $O1 8 "{\"title\":\"Archived\",\"prs\":[$M],\"isArchived\":true}"                  # not counted
desk $A1 $O2 9 "{\"title\":\"No PR, idle\",\"lastActivityAt\":$(( (now - 30 * 3600) * 1000 ))}"   # idle 30 h
desk $A2 $O1 10 "{\"title\":\"Needs action\",\"prs\":[$M],\"postTurnSummary\":{\"status_category\":\"completed\",\"needs_action\":\"Merge it\"}}"
desk $A2 $O1 11 "{\"title\":\"Dead pid busy\",\"prs\":[$M]}"                                # live file busy, pid gone: done
desk $A2 $O1 12 "{\"title\":\"Agents says busy\",\"prs\":[$M],\"cliSessionId\":\"cccccccc-0000-4000-8000-000000000012\"}"
desk $A2 $O1 13 "{\"title\":\"Waits live\",\"prs\":[$M]}"
desk $A2 $O1 14 "{\"title\":\"Idle process\",\"prs\":[$M]}"                                 # alive but idle: done
desk $A3 $O2 15 "{\"title\":\"\",\"cwd\":\"/work/api\",\"prs\":[{\"state\":\"merged\",\"prNumber\":4}]}"  # lower case state
echo '{broken' > "$base/$A2/$O1/local_dddddddd-0000-4000-8000-999999999999.json"
echo '[1,2]' > "$base/$A2/$O1/local_dddddddd-0000-4000-8000-999999999998.json"
echo '{"isArchived":false,"title":"Not a local file","prs":[{"state":"MERGED"}]}' > "$base/$A2/$O1/deleted_dddddddd.json"
echo 'SECRET-KEY-MATERIAL' > "$base/$A2/$O1/local_x.key"
echo 'SECRET-KEY-MATERIAL' > "$tmp/live/501.0123abcd.key"

live 501 5 cccccccc-0000-4000-8000-000000000005 busy
live 502 11 cccccccc-0000-4000-8000-000000000011 busy       # dead
live 503 13 cccccccc-0000-4000-8000-000000000013 waiting
live 504 14 cccccccc-0000-4000-8000-000000000014 idle
printf '501\n503\n504\n' > "$tmp/fx/alive"
echo '[{"sessionId":"cccccccc-0000-4000-8000-000000000012","status":"busy","pid":9}]' > "$tmp/fx/agents.json"
echo "{\"orgId\":\"$O2\",\"email\":\"someone@example.invalid\",\"orgName\":\"Example org\"}" > "$tmp/fx/auth.json"

# The files must not change: a checksum of the whole tree before and after.
sum() { find "$base" "$tmp/live" -type f -exec cksum {} + | sort; }
before="$(sum)"
j="$(d --json)" || fail "json runs" "exit $?"
expect "files untouched" "$(sum)" "$before"

st() { jq -r --arg t "$1" '[.accounts[].sessions[] | select(.title == $t) | .state] | join(",")' <<<"$j"; }
expect "merged is done" "$(st 'Merged one')" "done"
expect "merged and closed is done" "$(st 'Merged and closed')" "done"
expect "an open PR is not done" "$(st 'One still open')" open
expect "interruptedAwaitingPerson waits" "$(st 'Asks you')" waiting
expect "live busy runs" "$(st 'Busy')" running
expect "review_ready is not done" "$(st 'Review ready')" review
expect "blocked is not done" "$(st 'Blocked')" blocked
expect "archived is left out" "$(st 'Archived')" ""
expect "no PR, completed: idle" "$(st 'No PR, idle')" idle
expect "needs_action waits" "$(st 'Needs action')" waiting
expect "a dead pid does not count as busy" "$(st 'Dead pid busy')" "done"
expect "claude agents busy runs" "$(st 'Agents says busy')" running
expect "live waiting waits" "$(st 'Waits live')" waiting
expect "an idle process is done" "$(st 'Idle process')" "done"
expect "lower-case state is read" "$(st '')" "done"
expect "deleted_ and broken files are skipped" "$(jq -r '[.accounts[].sessions[] | select(.title == "Not a local file")] | length' <<<"$j")" 0

expect "totals" "$(jq -c '.totals' <<<"$j")" '{"accounts":3,"open":14,"done":5,"waiting":3,"running":2,"accountsWithDone":3}'
expect "per account" "$(jq -c '[.accounts[] | [.open, .done, .waiting, .running, .idle]]' <<<"$j")" '[[8,2,1,1,1],[5,2,2,1,0],[1,1,0,0,0]]'
expect "idle hours" "$(jq -r '[.accounts[].sessions[] | select(.title == "No PR, idle") | .idleHours][0]' <<<"$j")" 30
expect "fallback labels, sorted" "$(jq -c '[.accounts[].label]' <<<"$j")" '["Account 1 (11111111)","Account 2 (22222222)","Account 3 (33333333)"]'
expect "active marks every account with the org" "$(jq -c '[.accounts[].active]' <<<"$j")" '[true,false,true]'
expect "ambiguous active" "$(jq -r '.activeAmbiguous' <<<"$j")" true
expect "hint" "$(jq -r '.hint | test("Auto-archive")' <<<"$j")" true
case "$j" in *example.invalid*|*"Example org"*|*SECRET*) fail "no email, org name or key material" "found in output" ;; *) ok "no email, org name or key material" ;; esac

# labels from the config; a wrong type is ignored
echo "{\"labels\":{\"$A2\":\"Work\",\"$A3\":7}}" > "$DEPLOYS_CONFIG/desktop-sessions.json"
expect "label from config" "$(d --json | jq -c '[.accounts[].label]')" '["Account 1 (11111111)","Work","Account 3 (33333333)"]'

t="$(d)"
case "$t" in *"done, still open: 5"*) ok "text: summary line" ;; *) fail "text: summary line" "$t" ;; esac
case "$t" in *"Work: 5 open, 2 done but open, 2 waiting on you, 1 running"*) ok "text: account line" ;; *) fail "text: account line" "$t" ;; esac
case "$t" in *"done     Merged one"*) ok "text: done row" ;; *) fail "text: done row" "$t" ;; esac
case "$t" in *"Auto-archive sessions when their pull request closes"*) ok "text: archive hint" ;; *) fail "text: archive hint" "$t" ;; esac
case "$t" in *"(signed in now)"*) ok "text: active mark" ;; *) fail "text: active mark" "$t" ;; esac

# through deploys
expect "deploys desktop-sessions --json" "$(./deploys desktop-sessions --json | jq -r '.totals.done')" 5
./deploys desktop-sessions nonsense >/dev/null 2>&1; expect "unknown subcommand" "$?" 2

# no folder at all
expect "no base folder" "$(DEPLOYS_DESKTOP_SESSIONS_BASE="$tmp/none" d --json | jq -c '.totals')" '{"accounts":0,"open":0,"done":0,"waiting":0,"running":0,"accountsWithDone":0}'
expect "no fixture answers" "$(rm -f "$tmp/fx/agents.json" "$tmp/fx/auth.json"; d --json | jq -c '[.accounts[].active]')" '[false,false,false]'

echo
[ "$fails" = 0 ] && echo "all desktop-sessions tests passed" || { echo "$fails failed"; exit 1; }
