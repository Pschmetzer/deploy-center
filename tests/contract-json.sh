#!/bin/bash
# Writes what `deploys` answers to the app's JSON calls into <dir>, for tests/app-tests.swift to
# decode with the app's own models (a contract test: a field renamed in the script fails there).
# A temporary config folder with known state; stand-ins for security, launchctl, gh and the
# provider CLIs, so nothing reads the real keychain, launchd or the network.
#   tests/contract-json.sh <dir>
set -euo pipefail
cd "$(dirname "$0")/.."
out="${1:?usage: tests/contract-json.sh <dir>}"
mkdir -p "$out"
tmp="$(mktemp -d)"; trap 'rm -rf "$tmp"' EXIT
mkdir -p "$tmp/config" "$tmp/bin" "$tmp/home" "$tmp/agents"
for p in security launchctl gh glab vercel netlify wrangler aws doctl osascript curl; do
  printf '#!/bin/sh\nexit 1\n' > "$tmp/bin/$p"; chmod +x "$tmp/bin/$p"
done
c="$tmp/config" now="$(date +%s)"
jq -n --argjson t "$now" '{lastRun:$t, lastDry:false,
  lastActions:[{at:$t, platform:"render", project:"api", action:"off"},
               {at:$t, platform:"vercel", project:"web", action:"failed", error:"could not disconnect web"}]}' > "$c/guard.json"
jq -n --argjson t "$((now + 3600))" '{"vercel:web":$t, "*":$t}' > "$c/autodeploy-allow.json"
jq -n --argjson t "$now" '{fires:[
  {at:$t, project:"web", platform:"vercel", repo:"me/web", sha:"aaaa111", status:"fired", session:"https://claude.ai/code/s1",
   prNumber:9, prState:"merged", prUrl:"https://github.com/me/web/pull/9", mergedSha:"ffff999"},
  {at:($t - 60), project:"api", platform:"render", status:"failed", error:"no routine"}]}' > "$c/autofix.json"
echo "routine-1" > "$c/autofix-routine"
echo '{"projects":{"web":{"approvals":2},"docs":{"approvals":0}}}' > "$c/overrides.json"
jq -n '{deny:[{reason:"freeze"}]}' > "$c/window.json"   # closed all day, every day

jqdir="$(dirname "$(command -v jq)")"
d() {
  env -i HOME="$tmp/home" USER=tester PATH="$tmp/bin:$jqdir:/usr/bin:/bin" DEPLOYS_CONFIG="$c" \
    DEPLOYS_LAUNCH_DIR="$tmp/agents" DEPLOYS_NO_GITHUB=1 DEPLOYS_ROUTINE_TOKEN=sk-ant-test DEPLOYS_NOTIFY=0 \
    /bin/bash ./deploys "$@" </dev/null
}
d guard status --json > "$out/guard.json"
d autofix status --json > "$out/autofix.json"
d config --json > "$out/config.json"
d window --json > "$out/window.json"
# Two made-up sessions on one repo, one with a transcript (the app's SessionsSnapshot reads every field)
mkdir -p "$tmp/sess" "$tmp/proj/-work-shop" "$tmp/sessfx"
jq -n --argjson t "$((now * 1000 - 600000))" '{pid:501, sessionId:"c0000000-0000-4000-8000-000000000001", cwd:"/work/shop", name:"Fix the login", startedAt:$t, status:"busy"}' > "$tmp/sess/501.json"
jq -n --argjson t "$((now * 1000 - 600000))" '{pid:502, sessionId:"c0000000-0000-4000-8000-000000000002", cwd:"/work/shop/.claude/worktrees/b", name:"fix the login", startedAt:$t, status:"idle"}' > "$tmp/sess/502.json"
printf '{"type":"queue-operation","timestamp":"2026-01-01T00:00:00.000Z"}\n' > "$tmp/proj/-work-shop/c0000000-0000-4000-8000-000000000001.jsonl"
printf '  501 1 1.0 102400 20:00 /opt/bin/claude\n  502 1 0.0 102400 20:00 /opt/bin/claude\n' > "$tmp/sessfx/ps"
env -i HOME="$tmp/home" PATH="$tmp/bin:$jqdir:/usr/bin:/bin" DEPLOYS_CONFIG="$c" DEPLOYS_SESSIONS_DIR="$tmp/sess" \
  DEPLOYS_CLAUDE_PROJECTS="$tmp/proj" DEPLOYS_SESSIONS_FIXTURE="$tmp/sessfx" DEPLOYS_SESSIONS_NOW="$now" \
  /bin/bash ./deploys sessions --json </dev/null > "$out/sessions.json"
for f in guard autofix config window sessions; do jq -e . "$out/$f.json" >/dev/null || { echo "contract-json: $f.json is not JSON" >&2; exit 1; }; done
