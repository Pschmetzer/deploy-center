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

[ "$fails" = 0 ] && echo "all passed" || { echo "$fails failed"; exit 1; }
