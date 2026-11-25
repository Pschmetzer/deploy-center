#!/bin/bash
# Tests for the performance guard (lib/perf.sh, lib/perfclean.sh, integrations/claude-code/hooks/perf-gate.sh).
# Made-up outputs of sysctl, vm_stat, ps, lsof and launchctl in tests/fixtures/perf-guard (DEPLOYS_PERF_FIXTURE):
# no real process is read or stopped, nothing is installed. Run: bash tests/perf-guard-tests.sh
set -uo pipefail
cd "$(dirname "$0")/.." || exit 1
exec </dev/null
fails=0
ok()   { echo "ok   $1"; }
fail() { echo "FAIL $1: $2"; fails=$((fails+1)); }
expect() { [ "$2" = "$3" ] && ok "$1" || fail "$1" "expected [$3], got [$2]"; }

tmp="$(mktemp -d)"; trap 'rm -rf "$tmp"' EXIT
export DEPLOYS_CONFIG="$tmp/config" HOME="$tmp/home" NO_COLOR=1 DEPLOYS_TESTING=1
mkdir -p "$HOME" "$DEPLOYS_CONFIG"
fx="$tmp/fx"; cp -R tests/fixtures/perf-guard "$fx"
export DEPLOYS_PERF_FIXTURE="$fx"
echo '{"stagger":0,"pollEvery":1}' > "$DEPLOYS_CONFIG/perf.json"
perf() { bash lib/perf.sh "$@"; }
setsys() { printf '%s\n%s\n51539607552\n14\n{ %s 2.50 2.00 }\ntotal = 8192.00M  used = %s  free = 1.00M  (encrypted)\n' "$1" "$2" "$3" "$4" > "$fx/sysctl"; }

# --- status ---
j="$(perf status --json)"
expect "green on a quiet Mac" "$(jq -c '[.level, .admit]' <<<"$j")" '["green",true]'
expect "one Claude session (the disclaimer wrapper is not one)" "$(jq -r .claudeSessions <<<"$j")" "1"
expect "two heavy checks: tsc and next build, not its worker or the shell" "$(jq -c '.checks' <<<"$j")" '{"running":2,"cap":3}'
expect "groups by memory" "$(jq -r '.groups[0].key' <<<"$j")" "checks"
expect "the MCP server is grouped" "$(jq -r '[.groups[] | select(.key == "mcp") | .count][0]' <<<"$j")" "1"
expect "swap free in MB" "$(jq -r .swap.freeMB <<<"$j")" "7168"
expect "no swap rate without an earlier sample" "$(jq -r .swap.swapoutMBPerMin <<<"$j")" "null"
expect "a sample was recorded" "$(wc -l < "$DEPLOYS_CONFIG/perf/samples.tsv" | tr -d ' ')" "1"
expect "text: first line" "$(perf status | head -n 1)" "Performance: GREEN"

# swap-out rate: 1000 pages of 16 KB in 60 s = 15.6 MB/min
now="$(date +%s)"
printf '%s 1000\n' "$((now - 60))" > "$DEPLOYS_CONFIG/perf/samples.tsv"
setsys 2 40 3.10 1024.00M
j="$(DEPLOYS_PERF_NOW=$now DEPLOYS_PERF_NORECORD=1 perf status --json)"
expect "rate from the stored sample" "$(jq -r .swap.swapoutMBPerMin <<<"$j")" "15.6"
expect "warn, slow swap, free swap: yellow but admitted" "$(jq -c '[.level, .admit]' <<<"$j")" '["yellow",true]'
printf '%s 0\n' "$((now - 60))" > "$DEPLOYS_CONFIG/perf/samples.tsv"
j="$(DEPLOYS_PERF_NOW=$now DEPLOYS_PERF_NORECORD=1 perf status --json)"
expect "warn and swapping 31 MB/min: held" "$(jq -c '[.level, .admit]' <<<"$j")" '["yellow",false]'
setsys 4 40 3.10 1024.00M
expect "critical pressure is red" "$(DEPLOYS_PERF_NORECORD=1 perf status --json | jq -c '[.level, .admit]')" '["red",false]'
setsys 1 40 60.00 1024.00M
expect "load over 4 per core is red" "$(DEPLOYS_PERF_NORECORD=1 perf status --json | jq -r .level)" "red"
setsys 1 61 3.10 1024.00M
echo '{"stagger":0,"pollEvery":1,"maxChecks":2}' > "$DEPLOYS_CONFIG/perf.json"
expect "the cap on running checks holds" "$(DEPLOYS_PERF_NORECORD=1 perf status --json | jq -c '[.admit, .checks.cap]')" '[false,2]'
echo '{"stagger":0,"pollEvery":1}' > "$DEPLOYS_CONFIG/perf.json"

# --- gate and wait ---
out="$(perf gate --max-wait 5s sh -c 'echo ran; exit 3' 2>&1)"; rc=$?
expect "green: the command runs, its exit code is kept" "$out $rc" "ran 3"
expect "gate with -- works too" "$(perf gate -- echo yes 2>/dev/null)" "yes"
expect "--json is passed to the command, not taken by perf" "$(perf gate echo --json 2>/dev/null)" "--json"
setsys 4 40 3.10 1024.00M
out="$(perf gate --max-wait 0 sh -c 'echo ran' 2>&1)"; rc=$?
expect "red after the wait: not started, exit 75" "$rc $(grep -c '^ran' <<<"$out")" "75 0"
expect "red: the reason says not to retry at once" "$(grep -c 'Do not retry right away' <<<"$out")" "1"
expect "red with --fail-open: started" "$(perf gate --max-wait 0 --fail-open echo ran 2>/dev/null)" "ran"
expect "DEPLOYS_PERF_GATE=0 skips the wait" "$(DEPLOYS_PERF_GATE=0 perf wait --max-wait 0 2>/dev/null; echo $?)" "0"
setsys 2 40 3.10 1024.00M
printf '%s 0\n' "$(( $(date +%s) - 60 ))" > "$DEPLOYS_CONFIG/perf/samples.tsv"
out="$(perf wait --max-wait 0 2>&1)"; rc=$?
expect "yellow after the wait: fail open with a message" "$rc $(grep -c 'starting anyway' <<<"$out")" "0 1"
rm -f "$DEPLOYS_CONFIG/perf/samples.tsv"
setsys 1 61 3.10 1024.00M
echo '{"stagger":300,"pollEvery":1}' > "$DEPLOYS_CONFIG/perf.json"
date +%s > "$DEPLOYS_CONFIG/perf/last-admit"
expect "a second heavy start within the stagger waits" "$(perf wait --max-wait 0 2>&1 | grep -c 'started just now')" "1"
echo '{"stagger":0,"pollEvery":1}' > "$DEPLOYS_CONFIG/perf.json"
mkdir -p "$DEPLOYS_CONFIG/perf/admit.lock"; echo 999999 > "$DEPLOYS_CONFIG/perf/admit.lock/pid"
expect "a lock of a dead process is broken" "$(perf wait --max-wait 0 2>/dev/null; echo $?)" "0"
mv "$fx/sysctl" "$fx/sysctl.off"
expect "the guard fails open when it cannot read the system" "$(perf gate --max-wait 0 echo ran 2>/dev/null)" "ran"
mv "$fx/sysctl.off" "$fx/sysctl"

# --- cleanup (only the fixtures; nothing is stopped in a dry run) ---
out="$(perf clean --json)"
expect "orphans: old vitest (A), tsc in a deleted worktree (B), test browser (P), dev server without a session (C)" "$(jq -c '[.processes[] | [.pid, .rule]]' <<<"$out")" '[[201,"A"],[209,"B"],[213,"P"],[214,"C"]]'
expect "the user's Chrome and a dev server in a terminal are not listed" "$(jq -r '[.processes[].pid] | map(select(. == 215 or . == 216)) | length' <<<"$out")" "0"
expect "dry run by default" "$(jq -r .stopped <<<"$out")" "false"
expect "dry run is logged" "$(grep -c 'would stop 201' "$DEPLOYS_CONFIG/perf/clean.log")" "1"
expect "a dev server needs --dev" "$(perf clean | grep -c '214  rule C (needs --dev)')" "1"
expect "text dry run says nothing was stopped" "$(perf clean | tail -n 1)" "(4 found; dry run, nothing was stopped. deploys perf clean --yes stops them.)"

# --- reap: hung check runs (a real dummy process named tsc, so the stop can be seen) ---
# started by a shell that exits at once: not a job of this script, so its end prints nothing
dummy="$(bash -c '(exec -a "tsc --noEmit" sleep 300) >/dev/null 2>&1 & echo $!')"
sleep 0.3
# reap reads `ps -o pid,ppid,etime,rss,stat,time,tty,args` (fixture psr); perf/cpu.tsv holds the CPU progress
cat > "$fx/psr" <<ROWS
$dummy 1 1:10:00 51200 S 0:01.00 ?? tsc --noEmit
301 1 50:00 1000 S 0:00.10 ?? /bin/zsh -c npm run verify
302 301 50:00 40000 S 0:02.00 ?? npm run verify
303 302 50:00 1000 S 0:00.10 ?? sh -c npm run lint
304 303 49:00 900000 S 2:00.00 ?? npm run lint
305 304 49:00 800000 R 9:00.00 ?? node /work/app/node_modules/.bin/eslint .
306 1 50:00 300000 S 0:10.00 ?? node /work/site/node_modules/.bin/next dev
307 1 50:00 300000 S 0:10.00 ?? node /work/x/mcp-server/index.js --stdio
308 1 10:00 300000 S 0:10.00 ?? npx vitest run
309 1 3:00:00 300000 S 0:10.00 ?? node /work/old/node_modules/.bin/vite
310 1 3:00:00 300000 S 0:10.00 ?? node /work/w/node_modules/.bin/tsc -w
311 1 3:00:00 900000 T 0:10.00 ?? node /work/dbg/node_modules/.bin/tsc
312 1 40:00 300000 S 0:10.00 ?? /Users/dev/Library/Caches/ms-playwright/chromium-1/chrome-mac/Chromium.app/Contents/MacOS/Chromium --headless
313 900 50:00 700000 S 1:00.00 ?? node /work/s/node_modules/.bin/tsc --noEmit
900 1 5:00:00 1000 S 0:01.00 ttys002 /bin/zsh -l
ROWS
now="$(date +%s)"
printf '313\t%s\t60\t%s\n' "$((now - 3000))" "$((now - 1200))" > "$DEPLOYS_CONFIG/perf/cpu.tsv"
echo '{"stagger":0,"reap":{"perCommand":{"verify":60}}}' > "$DEPLOYS_CONFIG/perf.json"
setsys 1 61 3.10 1024.00M
j="$(DEPLOYS_PERF_NOW=$now perf reap --all --json)"
v() { jq -r --argjson p "$1" '.runs[] | select(.pid == $p) | "\(.class) \(.verdict) \(.auto)"' <<<"$j"; }
expect "reap: the topmost run of a tree counts once" "$(jq -c '[.runs[] | select(.pid == 302 or .pid == 304) | .pid]' <<<"$j")" '[302]'
expect "reap: the tree's memory adds up" "$(jq -r '.runs[] | select(.pid == 302) | .mb' <<<"$j")" "1700"
expect "reap: a check whose session is gone is an orphan" "$(v "$dummy")" "check orphan true"
expect "reap: 50 min with CPU progress is fine" "$(v 302)" "check ok false"
expect "reap: 50 min without CPU progress for 20 min hangs" "$(v 313)" "check hang true"
expect "reap: an MCP server without its session is an orphan" "$(v 307)" "mcp orphan true"
expect "reap: a test browser without its run is an orphan" "$(v 312)" "testbrowser orphan true"
expect "reap: a dev server without a session for 3 h: report only" "$(v 309)" "devserver useless false"
expect "reap: a young dev server is fine" "$(v 306)" "devserver ok false"
expect "reap: tsc -w is a dev server, not a check" "$(v 310)" "devserver useless false"
expect "reap: a stopped process (debugger) is never listed" "$(v 311)" ""
expect "reap: a young run is fine" "$(v 308)" "check ok false"
expect "reap: CPU progress is kept for the next run" "$(cut -f1 "$DEPLOYS_CONFIG/perf/cpu.tsv" | grep -c '^313$')" "1"
expect "reap: dry run by default" "$(DEPLOYS_PERF_NOW=$now perf reap | tail -n 1)" "(dry run, nothing was stopped. deploys perf reap --yes stops the ones not marked report only.)"
expect "reap: the dummy is still alive after the dry run" "$(kill -0 "$dummy" 2>/dev/null && echo alive)" "alive"
setsys 4 40 3.10 1024.00M
expect "reap: red shortens the limits (verify 60 x 0.35 = 21 min)" "$(DEPLOYS_PERF_NOW=$now perf reap --all --json | jq -c '.runs[] | select(.pid == 302) | [.verdict, .reason]')" '["hang","over 21 min"]'
setsys 1 61 3.10 1024.00M
expect "reap --pid needs a listed process" "$(perf reap --pid 900 --yes >/dev/null 2>&1; echo $?)" "1"
# only the dummy may be stopped for real: the made-up rows go
grep -E "^$dummy " "$fx/psr" > "$fx/psr.r" && mv "$fx/psr.r" "$fx/psr"
DEPLOYS_PERF_KILL_AFTER=0 perf reap --yes >/dev/null
sleep 0.5
expect "reap --yes stops the run over its limit" "$(kill -0 "$dummy" 2>/dev/null && echo alive || echo stopped)" "stopped"
expect "reap: logged with class, reason and runtime" "$(grep -c "reap: stopped $dummy check (orphan: its session is gone) after 70 min" "$DEPLOYS_CONFIG/perf/clean.log")" "1"
kill "$dummy" 2>/dev/null; rm -f "$fx/psr"
echo '{"stagger":0,"pollEvery":1}' > "$DEPLOYS_CONFIG/perf.json"

# --- Docker (a fake docker that only records its calls) ---
mkdir -p "$tmp/bin"; printf '#!/bin/bash\n[ "$1" = inspect ] && exit 0\necho "$*" >> "%s"\n' "$tmp/docker.calls" > "$tmp/bin/docker"; chmod +x "$tmp/bin/docker"
export PATH="$tmp/bin:$PATH" DEPLOYS_PERF_DB_WAIT=0
j="$(perf docker --json)"
expect "stacks: the compose project groups its two containers" "$(jq -c '[.[] | [.stack, .running, .total]]' <<<"$j")" '[["shop",2,2],["notes-pg",1,1],["cache-redis",1,1],["old-pg",0,1]]'
expect "memory adds up (200 MiB + 1.5 GiB)" "$(jq -r '.[0].memMB' <<<"$j")" "1736"
expect "an open connection to its port makes a stack active" "$(jq -r '.[] | select(.stack == "notes-pg") | .active' <<<"$j")" "true"
expect "CPU over 1 % makes a stack active" "$(jq -r '.[] | select(.stack == "cache-redis") | .active' <<<"$j")" "true"
expect "stop without --yes only says what it would do" "$(perf stop shop | grep -c '^Would stop'; [ -f "$tmp/docker.calls" ] && echo called || echo none)" "1
none"
perf stop shop --yes >/dev/null
expect "stop: the db last" "$(cat "$tmp/docker.calls")" "stop bbbbbbbbbbbb
stop aaaaaaaaaaaa"
expect "the stopped stack is remembered" "$(jq -r 'keys[0]' "$DEPLOYS_CONFIG/perf/docker-stopped.json")" "shop"
: > "$tmp/docker.calls"; perf wake shop >/dev/null
expect "wake: the db first" "$(cat "$tmp/docker.calls")" "start aaaaaaaaaaaa
start bbbbbbbbbbbb"
expect "woken stacks are forgotten" "$(jq -r 'length' "$DEPLOYS_CONFIG/perf/docker-stopped.json")" "0"
expect "no rm, no volume command ever" "$(grep -cE '(^| )(rm|volume|down|prune)( |$)' "$tmp/docker.calls")" "0"
: > "$tmp/docker.calls"
echo '{"docker":{"autoStop":true,"always":["notes-pg"]}}' > "$DEPLOYS_CONFIG/perf.json"
setsys 1 61 3.10 1024.00M
t0="$(date +%s)"
DEPLOYS_PERF_NOW=$t0 perf tick
expect "idle stop: nothing on first sight" "$(wc -c < "$tmp/docker.calls" | tr -d ' ')" "0"
rm -f "$DEPLOYS_CONFIG/perf/last-docker"
DEPLOYS_PERF_NOW=$((t0 + 7300)) DEPLOYS_PERF_NOTIFY_CMD=true perf tick
expect "idle stop after 2 h: only the idle stack" "$(cut -d' ' -f2 "$tmp/docker.calls" | tr '\n' ' ')" "bbbbbbbbbbbb aaaaaaaaaaaa "
echo '{"docker":{"autoStop":false}}' > "$DEPLOYS_CONFIG/perf.json"; : > "$tmp/docker.calls"; rm -f "$DEPLOYS_CONFIG/perf/last-docker" "$DEPLOYS_CONFIG/perf/docker-seen.json"
DEPLOYS_PERF_NOW=$((t0 + 99999)) perf tick
expect "idle stop is off by default" "$(wc -c < "$tmp/docker.calls" | tr -d ' ')" "0"
j="$(perf consumers --json)"
expect "consumers: the booted simulator" "$(jq -c '[.simulators[].name]' <<<"$j")" '["iPhone Test"]'
expect "consumers: the Docker stacks" "$(jq -r '.docker | length' <<<"$j")" "4"

# --- tick (what the launchd agent runs) ---
setsys 4 40 3.10 1024.00M
echo '{"stagger":0,"notifyAfterMin":0,"notifyEveryMin":30}' > "$DEPLOYS_CONFIG/perf.json"
printf '#!/bin/bash\nprintf "%%s|%%s\\n" "$1" "$2" >> "%s"\n' "$tmp/notes" > "$tmp/notify"; chmod +x "$tmp/notify"
DEPLOYS_PERF_NOTIFY_CMD="$tmp/notify" perf tick
expect "tick writes status.json" "$(jq -r .level "$DEPLOYS_CONFIG/perf/status.json")" "red"
expect "red: a notification naming the biggest group" "$(grep -c 'Checks and builds' "$tmp/notes")" "1"
DEPLOYS_PERF_NOTIFY_CMD="$tmp/notify" perf tick
expect "no second notification within notifyEveryMin" "$(wc -l < "$tmp/notes" | tr -d ' ')" "1"
setsys 1 61 3.10 1024.00M
perf tick
expect "green again: red-since is cleared" "$([ -f "$DEPLOYS_CONFIG/perf/red-since" ] && echo there || echo gone)" "gone"

# --- the hook ---
hook=integrations/claude-code/hooks/perf-gate.sh
hk() { jq -nc --arg c "$1" '{tool_input:{command:$c}}' | DEPLOYS_PERF_LIB="$PWD/lib/perf.sh" DEPLOYS_PERF_MAX_WAIT=0 bash "$hook" 2>"$tmp/hook.err"; echo $?; }
setsys 4 40 3.10 1024.00M
expect "hook: a light command passes even when red" "$(hk 'git status')" "0"
expect "hook: grep tsc is not heavy" "$(hk 'grep -rn tsc src')" "0"
expect "hook: npm run verify is held and refused when red" "$(hk 'cd app && npm run verify')" "2"
expect "hook: the reason reaches Claude" "$(grep -c 'overloaded' "$tmp/hook.err")" "1"
expect "hook: npx tsc is heavy" "$(hk 'npx tsc --noEmit')" "2"
expect "hook: DEPLOYS_PERF_GATE=0 turns it off" "$(jq -nc '{tool_input:{command:"npx vitest run"}}' | DEPLOYS_PERF_GATE=0 bash "$hook"; echo $?)" "0"
expect "hook: no lib, no block" "$(jq -nc '{tool_input:{command:"npx vitest run"}}' | DEPLOYS_PERF_LIB=/nonexistent bash "$hook"; echo $?)" "0"
expect "hook: broken input, no block" "$(echo 'not json' | bash "$hook"; echo $?)" "0"
setsys 1 61 3.10 1024.00M
expect "hook: heavy command on a green Mac passes" "$(hk 'npm test')" "0"

# --- through deploys ---
expect "deploys perf status --json" "$(DEPLOYS_PERF_NORECORD=1 ./deploys perf status --json | jq -r .level)" "green"
expect "perf install needs --yes" "$(./deploys perf install >/dev/null 2>&1; echo $?)" "2"
expect "perf hook prints the settings entry" "$(./deploys perf hook | sed -n '3,$p' | jq -r '.hooks[0].timeout')" "660"

echo
[ "$fails" = 0 ] && echo "perf-guard: all passed" || echo "perf-guard: $fails failed"
[ "$fails" = 0 ]
