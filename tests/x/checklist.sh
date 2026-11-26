#!/bin/bash
# deploys checklist (lib/x-checklist.sh) and deploys lint (lib/x-lint.sh).
. "$(dirname "$0")/lib.sh"
C="${DEPLOYS_CONFIG:?}"; rm -f "$C/providers.json"
clear_json() { find "${C:?}" -maxdepth 1 -name '*.json' -type f -delete; }
has "checklist: none yet" "$(cli checklist web)" "No points for web"
has "checklist: add" "$(cli checklist add web "run the migration dry run")" "Added to the checklist for web: run the migration dry run"
cli checklist add '*' "tell support" >/dev/null
cli checklist add web "second point" >/dev/null
out="$(cli checklist web)"
has "checklist: header" "$out" "Before you deploy web (a reminder; nothing waits for it):"
has "checklist: the all-projects point comes first" "$(printf '%s\n' "$out" | sed -n 2p)" "[ ] tell support   (all projects)"
expect "checklist: json" "$(cli checklist web --json | jq -c '[.points[] | [.scope,.n]]')" '[["*",1],["web",1],["web",2]]'
expect "checklist: another project sees only the * point" "$(cli checklist api --json | jq -c '[.points[].text]')" '["tell support"]'
has "checklist: all lists" "$(cli checklist)" "web:"
cli checklist add web "key ghp_abcdefghijklmnopqrstuvwxyz0123456789ABCD" >/dev/null 2>&1; expect "checklist: a secret is refused" "$?" "1"
cli checklist add 'we b' "x" >/dev/null 2>&1; expect "checklist: a bad project name is refused" "$?" "1"
cli checklist add web "" >/dev/null 2>&1; expect "checklist: an empty point is refused" "$?" "1"
cli checklist remove web 9 >/dev/null 2>&1; expect "checklist: a missing number is refused" "$?" "1"
has "checklist: remove" "$(cli checklist remove web 1)" "Removed point 1 of web."
expect "checklist: the second is now the first" "$(cli checklist web --json | jq -r '.points[1].text')" "second point"
cli checklist remove web 1 >/dev/null; expect "checklist: an empty list is dropped from the file" "$(jq -c 'has("web")' "$C/checklists.json")" "false"
DEPLOYS_READONLY=1 cli checklist add web "x" >/dev/null 2>&1; expect "checklist: observer mode refuses add" "$?" "1"
for i in $(seq 1 30); do cli checklist add many "p$i" >/dev/null; done
cli checklist add many "one too many" >/dev/null 2>&1; expect "checklist: 30 points at most" "$?" "1"
# lint
clear_json
has "lint: nothing there" "$(cli lint)" "nothing to check"
printf '{"deny":[{"days":["fri","funday"],"from":"25:00"},{"dates":["2026-13-01"]},"x"]}' > "$C/window.json"
printf '{"monthlyUsd":-3}' > "$C/budget.json"
printf '{"percent":95}' > "$C/slo.json"
printf '{"web":["ok",5]}' > "$C/checklists.json"
printf '{"a":' > "$C/rules.json"
printf '{}' > "$C/groups.json"
out="$(cli lint 2>&1)"; rc=$?
expect "lint: exit 1 with problems" "$rc" "1"
has "lint: a bad day" "$out" '"funday" is not mon'
has "lint: a bad time" "$out" 'rule 1: "from" must be HH:MM'
has "lint: a bad date" "$out" 'is not YYYY-MM-DD'
has "lint: a non-object rule" "$out" "rule 3 must be an object"
has "lint: budget" "$out" '"monthlyUsd" must be a number above 0'
has "lint: slo is fine" "$out" "ok       slo.json"
has "lint: checklist point" "$out" 'a point must be a text of 1 to 200 characters'
has "lint: broken JSON" "$out" "rules.json"
has "lint: the summary" "$out" "6 files checked, 4 with problems."
expect "lint: json" "$(cli lint --json 2>/dev/null | jq -c '[.checked,.withProblems]')" "[6,4]"
clear_json; printf '{"deny":[{"days":["sat"],"from":"09:00","to":"24:00"}]}' > "$C/window.json"
cli lint >/dev/null 2>&1; expect "lint: a good file exits 0" "$?" "0"
cli lint --bad >/dev/null 2>&1; expect "lint: unknown option exits 2" "$?" "2"
exit "$fails"
