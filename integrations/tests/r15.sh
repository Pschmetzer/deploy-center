#!/bin/bash
# Round 15 (docs/IDEEN-15.md block C): the Claude Code deploy gate and the perf gate against the ways around them.
# Tables of commands: what the hook must ask about, and what it must leave alone. No network, no real projects.
set -uo pipefail
cd "$(dirname "$0")/../.." || exit 1
fails=0
ok()   { [ "${1:-}" = --quiet ] || true; echo "ok   $1"; }
fail() { echo "FAIL $1: $2"; fails=$((fails+1)); }
expect() { [ "$2" = "$3" ] && ok "$1" || fail "$1" "expected [$3], got [$2]"; }
cc=integrations/claude-code
# shellcheck source=../claude-code/scripts/deploys-call.sh
. "$cc/scripts/deploys-call.sh"
sub() { deploys_call "$1"; printf '%s' "$DC_SUB"; }

# Every one of these starts or undoes a deploy (or runs a program we cannot read with a deploy verb): the gate asks.
while IFS= read -r c; do
  [ -n "$c" ] || continue
  expect "ask: $c" "$([ -n "$(sub "$c")" ] && echo ask || echo pass)" ask
done <<'LIST'
deploys deploy web
command deploys deploy web
env X=1 deploys deploy web
nohup deploys deploy web &
time deploys rollback web
sudo -u root deploys deploy web
echo hi | xargs deploys deploy
deploys --config x deploy web
D=deploys; $D deploy web
eval "deploys deploy web"
for p in a b; do deploys deploy $p; done
if deploys deploy web; then echo; fi
(deploys deploy web)
{ deploys deploy web; }
$(which deploys) deploy web
/usr/local/bin/deploys deploy web
bash -c "deploys deploy web"
deploys deploy-changed --yes
deploys vercel deploy web
deploys autodeploy allow web 2h
deploys prepare run --yes
deploys cancel web
deploys ignore web
deploys freeze clear
deploys freeze remove 1
deploys guard schedule off
LIST
# These must stay quiet.
while IFS= read -r c; do
  [ -n "$c" ] || continue
  expect "quiet: $c" "$(sub "$c")" ""
done <<'LIST'
echo deploys deploy web
git stash push
grep deploys deploy.txt
deploys status
deploys deploy-changed
deploys changed --json
deploys freeze status
deploys ignore list
deploys prepare run
deploys guard schedule on
LIST
deploys_call "deploys deploy --sha abc123 web"; expect "project after --sha" "$DC_PROJECT" "web"
deploys_call "deploys deploy web --dry-run"; expect "dry run is seen" "$DC_DRY" "1"
deploys_call "deploys freeze clear"; expect "weaken text" "$DC_WEAKEN" "removes a freeze"

# The hook itself: weakening commands and writes to the window file are asked.
hook() { jq -nc --arg c "$1" '{tool_input:{command:$c}}' | DEPLOYS_DEPLOY_GATE= bash "$cc/scripts/before-deploy.sh"; }
expect "hook asks for freeze clear" "$(hook 'deploys freeze clear' | jq -r .hookSpecificOutput.permissionDecision)" "ask"
expect "hook asks for sed -i on window.json" "$(hook "sed -i 's/fri/mon/' ~/.config/deploys/window.json" | jq -r .hookSpecificOutput.permissionDecision)" "ask"
expect "hook asks for a redirect into rules.json" "$(hook 'echo {} > ~/.config/deploys/rules.json' | jq -r .hookSpecificOutput.permissionDecision)" "ask"
expect "hook leaves cat window.json alone" "$(hook 'cat ~/.config/deploys/window.json')" ""
cfg() { jq -nc --arg f "$1" '{tool_input:{file_path:$f}}' | bash "$cc/scripts/before-config-edit.sh"; }
expect "edit of window.json is asked" "$(cfg /home/u/.config/deploys/window.json | jq -r .hookSpecificOutput.permissionDecision)" "ask"
expect "edit of another file is quiet" "$(cfg /home/u/project/src/app.ts)" ""
expect "hooks.json has the edit hook" "$(jq -r '[.hooks.PreToolUse[].matcher] | index("Edit|Write|MultiEdit") != null' "$cc/hooks/hooks.json")" "true"

# perf-gate: a stand-in lib that says "red" (75) holds every heavy command; light ones pass.
pg() {
  local d rc; d="$(mktemp -d)"; printf '#!/bin/bash\nexit 75\n' > "$d/perf.sh"
  printf '{"tool_input":{"command":%s}}' "$(jq -Rn --arg c "$1" '$c')" | DEPLOYS_PERF_LIB="$d/perf.sh" HOME="$d" DEPLOYS_CONFIG="$d/cfg" ${PG_ENV:+env "$PG_ENV"} bash "$cc/hooks/perf-gate.sh" >/dev/null 2>&1; rc=$?
  rm -rf "$d"; echo "$rc"
}
while IFS= read -r c; do
  [ -n "$c" ] || continue
  expect "perf-gate holds: $c" "$(pg "$c")" 2
done <<'LIST'
npm test
bash -c "npm test"
env CI=1 npm test
caffeinate -i npm test
sudo xcodebuild build
nohup tsc &
echo x | xargs tsc
npx -y tsc
node_modules/.bin/tsc
pnpm run -r build
vite build
turbo run build
cargo build
go test ./...
pytest -q
make
./gradlew build
mvn package
npm ci
pnpm install
docker compose up --build
git commit -m "perf wait"; npm test
echo "perf wait"; npm run build
LIST
while IFS= read -r c; do
  [ -n "$c" ] || continue
  expect "perf-gate passes: $c" "$(pg "$c")" 0
done <<'LIST'
echo tsc
grep vitest src
git log --grep=build
deploys perf wait
deploys perf gate --max-wait 5m
ls
cat Makefile
LIST
expect "perf-gate: DEPLOYS_PERF_HEAVY_EXTRA" "$(PG_ENV=DEPLOYS_PERF_HEAVY_EXTRA='terraform[[:space:]]+apply' pg 'terraform apply')" 2

# --- docker scheduler: sub-commands and flags, SIGTERM during a job, heartbeat ticker, ping ---
sch="integrations/docker/scheduler.sh"
tmp="$(mktemp -d)"; trap 'rm -rf "$tmp"' EXIT
bad_job() { printf 'every 5m %s\n' "$1" > "$tmp/j.conf"; DEPLOYS_INTEGRATIONS="$PWD/integrations" bash "$sch" --jobs "$tmp/j.conf" --check >/dev/null 2>&1; echo $?; }
for j in 'deploys freeze clear' 'deploys freeze remove 1' 'deploys doctor --fix' 'deploys digest --post' 'deploys history --clear'; do
  expect "scheduler refuses: $j" "$(bad_job "$j")" 1
done
for j in 'deploys freeze' 'deploys freeze status' 'deploys doctor' 'deploys digest --days 7'; do
  expect "scheduler accepts: $j" "$(bad_job "$j")" 0
done
mkdir -p "$tmp/bin"
cat > "$tmp/bin/deploys" <<'D'
#!/bin/bash
echo "ro=${DEPLOYS_READONLY:-}" >> "$CALLS"
sleep 20.31
D
chmod +x "$tmp/bin/deploys"
printf 'every 5m out=%s/out.json deploys changed --json\n' "$tmp" > "$tmp/term.conf"
export CALLS="$tmp/calls"; : > "$CALLS"
DEPLOYS="$tmp/bin/deploys" DEPLOYS_INTEGRATIONS="$PWD/integrations" DEPLOYS_HEARTBEAT_FILE="$tmp/hb" bash "$sch" --jobs "$tmp/term.conf" --tick 1 >"$tmp/term.out" 2>&1 &
sp=$!
n=0; while [ ! -s "$CALLS" ] && [ "$n" -lt 50 ]; do sleep 0.1; n=$((n + 1)); done
sleep 1.2
expect "scheduler: the job gets DEPLOYS_READONLY=1" "$(head -n 1 "$CALLS")" "ro=1"
hb1="$(cat "$tmp/hb" 2>/dev/null)"
sleep 1.1
expect "scheduler: the heartbeat moves while a job runs" "$([ "$(cat "$tmp/hb" 2>/dev/null)" -gt "$hb1" ] && echo moved || echo stuck)" moved
t_a="$(date +%s)"; kill -TERM "$sp"; wait "$sp"; rc=$?; t_b="$(date +%s)"
expect "scheduler: TERM ends it with 143" "$rc" 143
expect "scheduler: TERM does not wait for the job" "$([ $((t_b - t_a)) -le 3 ] && echo quick || echo slow)" quick
expect "scheduler: no temp file after TERM" "$(ls "$tmp"/out.json.* 2>/dev/null | wc -l | tr -d ' ')" 0
expect "scheduler: no stand-in job is left" "$(pgrep -f 'sleep 20.31' | wc -l | tr -d ' ')" 0
printf 'every 5m deploys changed --json\n' > "$tmp/ping.conf"
cat > "$tmp/bin/curl" <<'C'
#!/bin/bash
echo "curl $*" >> "$CALLS"
C
chmod +x "$tmp/bin/curl"
printf '#!/bin/bash\nexit 0\n' > "$tmp/bin/deploys"
: > "$CALLS"
PATH="$tmp/bin:$PATH" DEPLOYS_PING_URL="https://ping.example.test/abc" DEPLOYS="$tmp/bin/deploys" DEPLOYS_INTEGRATIONS="$PWD/integrations" bash "$sch" --jobs "$tmp/ping.conf" --once >/dev/null 2>&1
expect "scheduler: a ping after a job that worked" "$(grep -c 'ping.example.test' "$CALLS")" 1
: > "$CALLS"
PATH="$tmp/bin:$PATH" DEPLOYS_PING_URL="http://ping.example.test/abc" DEPLOYS="$tmp/bin/deploys" DEPLOYS_INTEGRATIONS="$PWD/integrations" bash "$sch" --jobs "$tmp/ping.conf" --once >/dev/null 2>&1
expect "scheduler: an http ping URL is refused" "$(grep -c 'ping.example.test' "$CALLS")" 0

# --- notify: link and zone are checked; a bad post says why; http hosts by name ---
nt="integrations/notify/notify.sh"
printf '[]' > "$tmp/empty.json"
nrun() { DEPLOYS="$tmp/bin/deploys" "$@" 2>&1; }
expect "notify: a javascript: link is refused" "$(DEPLOYS_NOTIFY_URL=https://hooks.example.test/x bash "$nt" --dry-run --link 'javascript:alert(1)' "$tmp/empty.json" >/dev/null 2>&1; echo $?)" 1
expect "notify: an https link passes the check" "$(DEPLOYS_NOTIFY_URL=https://hooks.example.test/x bash "$nt" --dry-run --link 'https://x.example.test/a' "$tmp/empty.json" 2>&1 | grep -c 'must be an https')" 0
expect "notify: an unknown zone is refused" "$(DEPLOYS_NOTIFY_TZ=Mars/Base bash "$nt" --dry-run "$tmp/empty.json" 2>&1 | grep -c 'not a time zone')" 1
. integrations/lib/post.sh
WEBHOOK_BODY='{"text":"x"}' WEBHOOK_TYPE=application/json
printf '#!/bin/bash\n[ -t 0 ] || cat >/dev/null; for a in "$@"; do [ "$p" = -o ] && echo "{\"error\":\"invalid_blocks\"}" > "$a"; p="$a"; done; exit 22\n' > "$tmp/bin/curl"; chmod +x "$tmp/bin/curl"
out="$(PATH="$tmp/bin:$PATH" webhook_send https://hooks.example.test/x slack 2>&1)"
case "$out" in *invalid_blocks*) ok "post: a rejected post shows the answer" ;; *) fail "post: a rejected post shows the answer" "[$out]" ;; esac
expect "post: no temp file is left after a failed post" "$(mkdir -p "$tmp/t"; TMPDIR="$tmp/t" PATH="$tmp/bin:$PATH" webhook_send https://hooks.example.test/x slack >/dev/null 2>&1; ls "$tmp/t" | wc -l | tr -d ' ')" 0
out="$(PATH="$tmp/bin:$PATH" webhook_send http://ntfy.lan.example/topic ntfy 2>&1)"; case "$out" in *must\ start\ with\ https*) ok "post: http to an unlisted host is refused" ;; *) fail "post: http refused" "[$out]" ;; esac
out="$(DEPLOYS_NOTIFY_ALLOW_HTTP_HOSTS=ntfy.lan.example PATH="$tmp/bin:$PATH" webhook_send http://ntfy.lan.example/topic ntfy 2>&1)"; case "$out" in *must\ start*) fail "post: an allowed http host" "[$out]" ;; *) ok "post: http to an allowed host goes out" ;; esac

[ "$fails" = 0 ] && echo "all passed" || { echo "$fails failed"; exit 1; }
