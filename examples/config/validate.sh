#!/bin/sh
# Checks the files in this folder without a network, an account or a deploy:
#   sh examples/config/validate.sh
# window files go through `deploys window` at made-up times, rules and budget through jq (the shape
# lib/rules.sh and deploys read), the shared config through the JSON schema when python3 has jsonschema,
# the hooks and the Vercel script in a throwaway folder and repo.
here="$(cd "$(dirname "$0")" && pwd)"; root="$(cd "$here/../.." && pwd)"
tmp="$(mktemp -d)"; trap 'rm -rf "$tmp"' EXIT INT TERM
fail=0
ok()  { echo "ok    $1"; }
bad() { echo "FAIL  $1"; fail=1; }
check() { if [ "$2" = "$3" ]; then ok "$1"; else bad "$1 (wanted '$3', got '$2')"; fi; }

# 1. deploy windows: closed and open at fixed times (DEPLOYS_NOW counts only with DEPLOYS_TESTING=1)
win() {  # win <file> <now> -> denied true/false
  cp "$here/$1" "$tmp/window.json"
  DEPLOYS_CONFIG="$tmp" DEPLOYS_TESTING=1 DEPLOYS_NOW="$2" "$root/deploys" window --json 2>/dev/null | jq -r '.denied'
}
check "friday freeze: Friday 16:00 is closed"  "$(win window-friday-freeze.json 'fri 16:00 2026-11-20')" true
check "friday freeze: Friday 10:00 is open"    "$(win window-friday-freeze.json 'fri 10:00 2026-11-20')" false
check "friday freeze: Sunday is closed"        "$(win window-friday-freeze.json 'sun 12:00 2026-11-22')" true
check "friday freeze: Monday is open"          "$(win window-friday-freeze.json 'mon 10:00 2026-11-23')" false
check "holiday freeze: 24 December is closed"  "$(win window-holiday-freeze.json 'thu 12:00 2026-12-24')" true
check "holiday freeze: 23:00 is closed"        "$(win window-holiday-freeze.json 'tue 23:00 2026-12-01')" true
check "holiday freeze: 05:00 is closed"        "$(win window-holiday-freeze.json 'wed 05:00 2026-12-02')" true
check "holiday freeze: 12:00 is open"          "$(win window-holiday-freeze.json 'wed 12:00 2026-12-02')" false
cp "$here/window-friday-freeze.json" "$tmp/window.json"
check "friday freeze: nothing for deploys window to warn about" \
  "$(DEPLOYS_CONFIG="$tmp" "$root/deploys" window 2>&1 | grep -ci 'unknown\|is no ')" 0

# 2. rules: the shape lib/rules.sh reads, and no deploy rule without a condition (it would be ignored)
for f in rules-docs-ship rules-api-waits rules-collect-then-ship; do
  check "$f: a rules array whose actions are known" \
    "$(jq -r '(.rules | type) == "array" and all(.rules[]; .then as $t | ["deploy","hold","notify"] | index($t) != null)' "$here/$f.json")" true
  check "$f: every deploy rule has a condition" \
    "$(jq -r 'all(.rules[]; .then != "deploy" or ((.when // {}) | length) > 0)' "$here/$f.json")" true
  check "$f: only known conditions" \
    "$(jq -r '[.rules[].when // {} | keys[]] - ["projects","ciGreen","paths","onlyPaths","labels","minAgeHours","minAgeDays","minCommits","minPRs"] | length' "$here/$f.json")" 0
done

check "rules-api-waits: the deploy rule comes before the hold rule of the same project" \
  "$(jq -r '[.rules[] | select(.when.projects == ["render/example-api"]) | .then] == ["deploy","hold"]' "$here/rules-api-waits.json")" true

# 3. budget: what `deploys budget set 50` writes
check "budget.json: monthlyUsd is a number and strict a boolean" \
  "$(jq -r '(.monthlyUsd | type) == "number" and (.strict | type) == "boolean"' "$here/budget.json")" true

# 4. shared config against the schema (skipped without python3 + jsonschema)
if python3 -I -c 'import jsonschema' 2>/dev/null; then
  python3 -I - "$root/docs/deploy-center.schema.json" "$here/deploy-center-monorepo.json" <<'PY' && ok "deploy-center-monorepo.json fits the schema" || bad "deploy-center-monorepo.json does not fit the schema"
import json, sys, jsonschema
jsonschema.validate(json.load(open(sys.argv[2])), json.load(open(sys.argv[1])))
PY
else echo "skip  schema check (python3 jsonschema is not installed)"; fi

# 5. hooks: run as deploys runs them, with the variables it sets
hook() { env -i PATH="$PATH" DEPLOYS_PLATFORM=vercel DEPLOYS_PROJECT=example-web "$@" >/dev/null 2>&1; echo $?; }
check "pre-deploy-friday stops Friday 15:xx"      "$(hook HOOK_NOW=515 sh "$here/hooks.d/pre-deploy-friday")" 1
check "pre-deploy-friday stops Saturday"          "$(hook HOOK_NOW=609 sh "$here/hooks.d/pre-deploy-friday")" 1
check "pre-deploy-friday lets Friday morning go"  "$(hook HOOK_NOW=509 sh "$here/hooks.d/pre-deploy-friday")" 0
check "pre-deploy-friday lets Monday go"          "$(hook HOOK_NOW=110 sh "$here/hooks.d/pre-deploy-friday")" 0
check "pre-deploy-require-sha stops without a sha" "$(hook sh "$here/hooks.d/pre-deploy-require-sha")" 1
check "pre-deploy-require-sha lets a sha go"       "$(hook DEPLOYS_SHA=abc1234 sh "$here/hooks.d/pre-deploy-require-sha")" 0
check "pre-deploy-require-sha: ALLOW_NO_SHA=1"     "$(hook ALLOW_NO_SHA=1 sh "$here/hooks.d/pre-deploy-require-sha")" 0
check "post-deploy-notify does nothing without a URL" "$(hook sh "$here/hooks.d/post-deploy-notify")" 0
for h in "$here"/hooks.d/*; do
  [ -x "$h" ] && ok "$(basename "$h") is executable" || bad "$(basename "$h") is not executable"
done

# 6. Vercel's Ignored Build Step in a throwaway repo: exit 0 skips, exit 1 builds
repo="$tmp/repo"; mkdir -p "$repo/apps/web" "$repo/apps/docs" "$repo/packages/ui"
git -C "$repo" init -q . && git -C "$repo" config user.email demo@example.invalid && git -C "$repo" config user.name demo
git -C "$repo" config commit.gpgsign false
echo 1 > "$repo/apps/web/a.txt"; echo 1 > "$repo/apps/docs/a.txt"; echo 1 > "$repo/packages/ui/a.txt"
git -C "$repo" add -A && git -C "$repo" commit -q -m one
# VERCEL_GIT_PREVIOUS_SHA is the last commit Vercel deployed on the branch; PATHS are relative to the Root Directory.
sha() { git -C "$repo" rev-parse HEAD; }
ign() { (cd "$repo/apps/web" && VERCEL_GIT_PREVIOUS_SHA="$1" PATHS=". ../../packages/ui" sh "$here/vercel-ignored-build-step.sh" >/dev/null 2>&1; echo $?); }
first="$(sha)"
check "ignored build step: no previous deployment builds" "$(ign '')" 1
check "ignored build step: an unknown commit builds (shallow clone)" "$(ign 0123456789012345678901234567890123456789)" 1
echo 2 > "$repo/apps/docs/a.txt"; git -C "$repo" commit -q -am docs
check "ignored build step: a change in another app skips" "$(ign "$first")" 0
echo 2 > "$repo/apps/web/a.txt"; git -C "$repo" commit -q -am web
check "ignored build step: a change in the app builds" "$(ign "$first")" 1
second="$(sha)"
echo 3 > "$repo/apps/docs/a.txt"; git -C "$repo" commit -q -am docs2
check "ignored build step: another app's later commit does not hide the app's earlier change" "$(ign "$first")" 1
check "ignored build step: nothing since the last deployment skips" "$(ign "$second")" 0
echo 2 > "$repo/packages/ui/a.txt"; git -C "$repo" commit -q -am ui
check "ignored build step: a change in a shared package builds" "$(ign "$second")" 1

[ "$fail" = 0 ] && echo "all examples are fine" || { echo "some examples are broken"; exit 1; }
