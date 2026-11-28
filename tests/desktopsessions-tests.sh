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

expect "totals" "$(jq -c '.totals' <<<"$j")" '{"accounts":3,"open":14,"done":5,"waiting":3,"running":2,"stopped":0,"accountsWithDone":3}'
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
case "$t" in *"Work: 5 open, 2 done but open, 2 waiting on you, 0 stopped, 1 running"*) ok "text: account line" ;; *) fail "text: account line" "$t" ;; esac
case "$t" in *"done     Merged one"*) ok "text: done row" ;; *) fail "text: done row" "$t" ;; esac
case "$t" in *"Auto-archive sessions when their pull request closes"*) ok "text: archive hint" ;; *) fail "text: archive hint" "$t" ;; esac
case "$t" in *"(signed in now)"*) ok "text: active mark" ;; *) fail "text: active mark" "$t" ;; esac

# through deploys
expect "deploys desktop-sessions --json" "$(./deploys desktop-sessions --json | jq -r '.totals.done')" 5
./deploys desktop-sessions nonsense >/dev/null 2>&1; expect "unknown subcommand" "$?" 2

# no folder at all
expect "no base folder" "$(DEPLOYS_DESKTOP_SESSIONS_BASE="$tmp/none" d --json | jq -c '.totals')" '{"accounts":0,"open":0,"done":0,"waiting":0,"running":0,"stopped":0,"accountsWithDone":0}'
expect "no fixture answers" "$(rm -f "$tmp/fx/agents.json" "$tmp/fx/auth.json"; d --json | jq -c '[.accounts[].active]')" '[false,false,false]'

# Stopped sessions: a fourth account with transcripts (DEPLOYS_CLAUDE_PROJECTS).
export DEPLOYS_CLAUDE_PROJECTS="$tmp/projects"; mkdir -p "$tmp/projects/-work-x"
A4=44444444-dddd-4000-8000-000000000004
# tr <n> <minutes ago> <jsonl lines...>: the transcript of cli id cccccccc-...-00000000020n
tr() {
  local f ago="$2"; f="$tmp/projects/-work-x/cccccccc-0000-4000-8000-0000000002$(printf '%02d' "$1").jsonl"; shift 2
  printf '%s\n' "$@" > "$f"; perl -e 'utime $ARGV[0], $ARGV[0], $ARGV[1]' "$((now - ago * 60))" "$f"
}
cli() { echo "\"cliSessionId\":\"cccccccc-0000-4000-8000-0000000002$(printf '%02d' "$1")\""; }
old="\"lastActivityAt\":$(( (now - 3 * 3600) * 1000 ))"
U='{"type":"user","uuid":"u1","message":{"content":"Do the thing"}}'
AT='{"type":"assistant","uuid":"a1","message":{"content":[{"type":"text","text":"All done."}]}}'
STOP='{"type":"system","subtype":"stop_hook_summary","uuid":"s1"}'
LIM='{"type":"assistant","uuid":"lim1","isApiErrorMessage":true,"error":"rate_limit","message":{"content":[{"type":"text","text":"You hit your weekly limit · resets Dec 1 at 11am (Europe/Example)"}]}}'
ERR='{"type":"system","subtype":"api_error","uuid":"err1","level":"error"}'
TU='{"type":"assistant","uuid":"tu1","message":{"content":[{"type":"tool_use","name":"Bash","input":{}}]}}'
TR='{"type":"user","uuid":"tr1","message":{"content":[{"type":"tool_result","content":"ok"}]}}'
INT='{"type":"user","uuid":"int1","message":{"content":[{"type":"text","text":"[Request interrupted by user]"}]}}'
NOISE='{"type":"cost-state"}'
desk $A4 $O1 20 "{\"title\":\"Limit\",$(cli 20),$old}";            tr 20 120 "$U" "$LIM" "$NOISE"
desk $A4 $O1 21 "{\"title\":\"Api error\",$(cli 21),$old}";        tr 21 120 "$U" "$AT" "$ERR" '{"type":"api-request"}'
desk $A4 $O1 22 "{\"title\":\"Cut off\",$(cli 22),$old}";          tr 22 120 "$U" "$TU" "$TR"
desk $A4 $O1 23 "{\"title\":\"User stopped\",$(cli 23),$old}";     tr 23 120 "$U" "$TU" "$INT"
desk $A4 $O1 24 "{\"title\":\"Finished\",$(cli 24),$old}";         tr 24 120 "$U" "$AT" "$STOP" "$NOISE"
desk $A4 $O1 25 "{\"title\":\"Tool pending\",$(cli 25),$old}";     tr 25 120 "$U" "$TU"
desk $A4 $O1 26 "{\"title\":\"Asks, then error\",$(cli 26),$old,\"postTurnSummary\":{\"status_category\":\"blocked\",\"needs_action\":\"Pick one\"}}"; tr 26 120 "$U" "$ERR"
desk $A4 $O1 27 "{\"title\":\"Done, then error\",$(cli 27),$old,\"prs\":[$M]}"; tr 27 120 "$U" "$ERR"
desk $A4 $O1 28 "{\"title\":\"Fresh error\",$(cli 28),\"lastActivityAt\":$(( (now - 120) * 1000 ))}"; tr 28 2 "$U" "$ERR"
desk $A4 $O1 30 "{\"title\":\"Notice after the turn\",$(cli 30),$old}"; tr 30 120 "$U" "$AT" "$STOP" '{"type":"user","uuid":"n1","message":{"content":"<task-notification>\\n<task-id>x</task-id>"}}'
desk $A4 $O1 29 "{\"title\":\"Broken tail\",$(cli 29),$old}";      tr 29 120 'not json' "$U" '{"type":"assistant","uu'
jt="$(find "$tmp/projects" -type f -exec cksum {} + | sort)"
j="$(d --json)"
expect "transcripts untouched" "$(find "$tmp/projects" -type f -exec cksum {} + | sort)" "$jt"
s4() { jq -r --arg t "$1" '[.accounts[].sessions[] | select(.title == $t) | "\(.state):\(.stopReason // "")"] | join(",")' <<<"$j"; }
expect "usage limit is stopped" "$(s4 Limit)" "stopped:limit"
expect "limit note" "$(jq -r '[.accounts[].sessions[] | select(.title == "Limit") | .stopNote][0]' <<<"$j")" "resets Dec 1 at 11am (Europe/Example)"
expect "api error is stopped" "$(s4 'Api error')" "stopped:error"
expect "a tool result without an answer is stopped" "$(s4 'Cut off')" "stopped:cut"
expect "stopped by the person: not stopped" "$(s4 'User stopped')" "idle:"
expect "user-stopped is marked" "$(jq -r '[.accounts[].sessions[] | select(.title == "User stopped") | .userStopped][0]' <<<"$j")" true
expect "a finished turn is not stopped" "$(s4 Finished)" "idle:"
expect "a pending tool call is left alone" "$(s4 'Tool pending')" "idle:"
expect "waiting beats stopped" "$(s4 'Asks, then error')" "waiting:"
expect "done beats stopped" "$(s4 'Done, then error')" "done:"
expect "under stoppedMin: not yet" "$(s4 'Fresh error')" "idle:"
expect "a task notice after a finished turn is no stop" "$(s4 'Notice after the turn')" "idle:"
expect "a broken tail line is skipped" "$(s4 'Broken tail')" "stopped:cut"
expect "stop key is the last entry" "$(jq -r '[.accounts[].sessions[] | select(.title == "Api error") | .stopKey][0]' <<<"$j")" err1
expect "open link" "$(jq -r '[.accounts[].sessions[] | select(.title == "Limit") | .openUrl][0]' <<<"$j")" "claude://claude.ai/epitaxy/local_dddddddd-0000-4000-8000-000000000020"
expect "stopped per account" "$(jq -r '.accounts[] | select(.id == "'"$A4"'") | .stopped' <<<"$j")" 4
case "$j" in *"Do the thing"*|*"All done."*) fail "no conversation text in the output" "found" ;; *) ok "no conversation text in the output" ;; esac
echo "{\"stoppedMin\":180}" > "$DEPLOYS_CONFIG/desktop-sessions.json"
expect "stoppedMin from the config" "$(d --json | jq -r '.totals.stopped')" 0
case "$(d)" in *"stopped  Limit"*) fail "text: stopped row" "shown above stoppedMin" ;; *) ok "text: stopped row hidden under stoppedMin" ;; esac
rm -f "$DEPLOYS_CONFIG/desktop-sessions.json"
case "$(d)" in *"stopped  Limit — shop — limit (resets Dec 1 at 11am (Europe/Example)) — open: claude://"*) ok "text: stopped row" ;; *) fail "text: stopped row" "$(d)" ;; esac

# The signed-in account from ~/.claude.json (accountUuid) wins over the org guess.
echo "{\"oauthAccount\":{\"accountUuid\":\"$A2\",\"emailAddress\":\"someone@example.invalid\"}}" > "$tmp/fx/claude.json"
expect "active by account uuid" "$(d --json | jq -c '[[.accounts[].active], .activeAmbiguous]')" '[[false,true,false,false],false]'
case "$(d --json)" in *example.invalid*) fail "no email from claude.json" "found" ;; *) ok "no email from claude.json" ;; esac

# The nudge switch: on when missing, off and on again, nothing else in the file.
expect "nudge: on when missing" "$(d nudge status)" "Keep idle sessions going: on"
d nudge off >/dev/null
expect "nudge: off" "$(d nudge status)" "Keep idle sessions going: off"
expect "nudge: file" "$(jq -c . "$DEPLOYS_CONFIG/nudge.json")" '{"enabled":false}'
d nudge on >/dev/null
expect "nudge: on again" "$(jq -r .enabled "$DEPLOYS_CONFIG/nudge.json")" true
d nudge maybe >/dev/null 2>&1; expect "nudge: bad value is a usage error" "$?" 2

echo
[ "$fails" = 0 ] && echo "all desktop-sessions tests passed" || { echo "$fails failed"; exit 1; }
