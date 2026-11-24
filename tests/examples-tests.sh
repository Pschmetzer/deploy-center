#!/bin/bash
# Tests for examples/: the ready-made config files and hooks (examples/config/validate.sh), the presets in
# examples/presets/ and the new hooks. A throwaway config folder; no network, no account, nothing is started.
set -uo pipefail
cd "$(dirname "$0")/.." || exit 1
exec </dev/null
fails=0
ok()   { echo "ok   $1"; }
fail() { echo "FAIL $1: $2"; fails=$((fails+1)); }
expect() { [ "$2" = "$3" ] && ok "$1" || fail "$1" "expected [$3], got [$2]"; }
tmp="$(mktemp -d)"; trap 'rm -rf "$tmp"' EXIT
P=examples/presets

# 1. the existing validation script
out="$(sh examples/config/validate.sh 2>&1)"; rc=$?
expect "validate.sh passes" "$rc" 0
expect "validate.sh has no FAIL line" "$(printf '%s\n' "$out" | grep -c '^FAIL')" 0

# 2. presets: every JSON file parses, only made-up names
for f in "$P"/*/*.json; do
  expect "$f is JSON" "$(jq -e . "$f" >/dev/null 2>&1; echo $?)" 0
done
expect "the presets name no project outside example-*" \
  "$(for f in "$P"/*/deploy-center.json; do jq -r '.projects | keys[]' "$f"; done | grep -vc '^example-')" 0
expect "agency: 20 client sites" "$(jq '.projects | length' $P/agency/deploy-center.json)" 20
expect "agency: the sites are all different" "$(jq -r '.projects | keys[]' $P/agency/deploy-center.json | sort -u | wc -l | tr -d ' ')" 20

# 3. rules: known actions, known conditions, a condition on every deploy rule; checked by deploys itself
for r in "$P"/*/rules.json; do
  expect "$r: known actions" "$(jq -r 'all(.rules[]; .then as $t | ["deploy","hold","notify"] | index($t) != null)' "$r")" true
  expect "$r: every deploy rule has a condition" "$(jq -r 'all(.rules[]; .then != "deploy" or ((.when // {}) | length) > 0)' "$r")" true
  expect "$r: only known conditions" "$(jq -r '[.rules[].when // {} | keys[]] - ["projects","ciGreen","paths","onlyPaths","labels","minAgeHours","minAgeDays","minCommits","minPRs"] | length' "$r")" 0
done
expect "monorepo-previews: nothing deploys by itself" "$(jq -r '[.rules[].then] | unique | join(",")' $P/monorepo-previews/rules.json)" hold
expect "agency: the Render override only changes a number the rule has" \
  "$(jq -r '.overrides[] | keys - ["minAgeHours","minAgeDays","minCommits","minPRs","ciGreen","onlyPaths","paths","labels","skip"] | length' $P/agency/rules.json)" 0

# 4. budgets: what `deploys budget set` writes
for b in "$P"/*/budget.json; do
  expect "$b: number and boolean" "$(jq -r '(.monthlyUsd | type) == "number" and (.strict | type) == "boolean"' "$b")" true
done
expect "student: the smallest budget is strict" "$(jq -r '.strict' $P/student/budget.json)" true

# 5. windows, read by deploys at fixed times
win() {  # win <preset> <now> -> denied
  d="$tmp/w-$1"; mkdir -p "$d"; cp "$P/$1/window.json" "$d/window.json"
  DEPLOYS_CONFIG="$d" DEPLOYS_TESTING=1 DEPLOYS_NOW="$2" ./deploys window --json 2>/dev/null | jq -r '.denied'
}
expect "solo: 23:00 is closed" "$(win solo 'tue 23:00 2026-12-01')" true
expect "solo: 03:00 is closed" "$(win solo 'wed 03:00 2026-12-02')" true
expect "solo: 12:00 is open" "$(win solo 'wed 12:00 2026-12-02')" false
expect "student: 22:00 is open" "$(win student 'wed 22:00 2026-12-02')" false
expect "student: 23:30 is closed" "$(win student 'wed 23:30 2026-12-02')" true
expect "monorepo-previews: closed on a Wednesday noon" "$(win monorepo-previews 'wed 12:00 2026-12-02')" true
expect "monorepo-previews: closed on a Sunday" "$(win monorepo-previews 'sun 12:00 2026-12-06')" true

# 6. the shared config fits the schema (when python3 has jsonschema)
if python3 -I -c 'import jsonschema' 2>/dev/null; then
  for c in "$P"/*/deploy-center.json; do
    expect "$c fits the schema" "$(python3 -I -c 'import json,sys,jsonschema; jsonschema.validate(json.load(open(sys.argv[2])), json.load(open(sys.argv[1])))' docs/deploy-center.schema.json "$c" >/dev/null 2>&1; echo $?)" 0
  done
else echo "skip schema checks (python3 jsonschema is not installed)"; fi

# 7. hooks: the backup and the smoke test, with the variables deploys sets
H=examples/config/hooks.d
cfg="$tmp/cfg"; mkdir -p "$cfg"; echo '{"monthlyUsd":5}' > "$cfg/budget.json"; echo '{"rules":[]}' > "$cfg/rules.json"
bk() { env -i PATH="$PATH" HOME="$tmp" DEPLOYS_CONFIG="$cfg" DEPLOY_BACKUP_DIR="$tmp/bk" DEPLOY_BACKUP_KEEP=2 DEPLOYS_PLATFORM=vercel DEPLOYS_PROJECT=example-web "$@" sh $H/pre-deploy-backup >/dev/null 2>&1; echo $?; }
expect "backup: exits 0" "$(bk)" 0
expect "backup: one tar with the settings" "$(tar -tf "$tmp"/bk/deploys-*.tar | sort | tr '\n' ' ')" "budget.json rules.json "
expect "backup: private (0600)" "$(ls -l "$tmp"/bk/deploys-*.tar | cut -c1-10)" "-rw-------"
bk >/dev/null; sleep 1; bk >/dev/null; sleep 1; bk >/dev/null
expect "backup: keeps only the newest 2" "$(ls "$tmp"/bk/deploys-*.tar | wc -l | tr -d ' ')" 2
expect "backup: stops the start when the folder cannot be made" "$(bk DEPLOY_BACKUP_DIR=/proc/nope/x)" 1
empty="$tmp/empty"; mkdir -p "$empty"
expect "backup: nothing to save is no error" "$(env -i PATH="$PATH" HOME="$tmp" DEPLOYS_CONFIG="$empty" sh $H/pre-deploy-backup >/dev/null 2>&1; echo $?)" 0

echo ok > "$tmp/example-web"
sm() { env -i PATH="$PATH" DEPLOYS_PLATFORM=vercel DEPLOYS_PROJECT=example-web DEPLOY_SMOKE_TRIES=2 DEPLOY_SMOKE_WAIT=0 "$@" sh $H/post-deploy-smoke >/dev/null 2>&1; echo $?; }
expect "smoke: does nothing without a URL" "$(sm)" 0
expect "smoke: a URL that answers (%s is the project)" "$(sm DEPLOY_SMOKE_URL="file://$tmp/%s")" 0
expect "smoke: a URL that does not answer says so with exit 1" "$(sm DEPLOY_SMOKE_URL="file://$tmp/missing-%s")" 1
expect "smoke: the hook reports on stderr" "$(env -i PATH="$PATH" DEPLOYS_PLATFORM=vercel DEPLOYS_PROJECT=example-web DEPLOY_SMOKE_TRIES=1 DEPLOY_SMOKE_URL="file://$tmp/nope" sh $H/post-deploy-smoke 2>&1 >/dev/null | grep -c 'did NOT answer')" 1

# 8. through hook_run: the backup runs as a pre-deploy hook, in a folder only you can write
hd="$tmp/hcfg/hooks.d"; mkdir -p "$hd"; chmod 700 "$hd"; cp $H/pre-deploy-backup "$hd/"; chmod 700 "$hd/pre-deploy-backup"
echo '{}' > "$tmp/hcfg/window.json"
res="$(DEPLOYS_LIB=1 DEPLOYS_CONFIG="$tmp/hcfg" DEPLOY_BACKUP_DIR="$tmp/hbk" bash -c '. ./deploys; hook_run pre-deploy vercel example-web abc1234; echo rc=$?' 2>&1)"
expect "hook_run: runs the backup and returns 0" "$(printf '%s\n' "$res" | grep -c 'rc=0')" 1
expect "hook_run: the tar is there" "$(ls "$tmp"/hbk/deploys-*.tar 2>/dev/null | wc -l | tr -d ' ')" 1

[ "$fails" = 0 ] && { echo "all example tests passed"; exit 0; } || { echo "$fails failed"; exit 1; }
