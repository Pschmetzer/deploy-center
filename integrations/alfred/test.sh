#!/bin/bash
# Tests for the Alfred scripts that read costs, the journal and the guard: a stand-in `deploys` answers
# from fixtures written here. No network, no real projects, no Alfred. Run: integrations/alfred/test.sh
set -uo pipefail
cd "$(dirname "$0")" || exit 1
fails=0
ok()   { echo "ok   $1"; }
fail() { echo "FAIL $1: $2"; fails=$((fails+1)); }
expect() { [ "$2" = "$3" ] && ok "$1" || fail "$1" "expected [$3], got [$2]"; }
command -v jq >/dev/null 2>&1 || { echo "skip: jq is missing"; exit 0; }

tmp="$(mktemp -d)"; trap 'rm -rf "$tmp"' EXIT
mon="$(date -u +%Y-%m)"; now="$(date +%s)"
cat > "$tmp/costs.json" <<JSON
{"currency":"USD","offDay":null,"buildsComplete":true,"missingDays":${MISSING:-0},"days":[],
 "months":[{"month":"2000-01","total":40,"build":30,"days":29},{"month":"$mon","total":12.345,"build":8.1,"days":14}],
 "projects":[{"name":"app-web","build":6,"builds":12},{"name":"blog","build":0.9,"builds":null}]}
JSON
{
  echo 'at,platform,name,result,detail'
  echo '2026-11-18T09:00:00Z,Vercel,app-web,deployed,"Started from the app, 2 commits"'
  printf '%s\n' '2026-11-19T10:30:00Z,Vercel,app-web,failed,"Build failed' 'second line"'
  echo '2026-11-19T11:00:00Z,Render,api,rollback,"Rolled back (dpl_1)"'
  echo "2026-11-17T08:00:00Z,Vercel,blog,forced,\"'-- forced: release \"\"hotfix\"\"\""
  echo '2026-11-20T07:15:00Z,Vercel,site,deployed,'
} > "$tmp/journal.csv"
cat > "$tmp/guard.json" <<JSON
{"enabled":true,"lastRun":$((now - 7200)),"lastDry":false,"firstRunPending":false,
 "lastActions":[{"action":"auto-deploy-off","platform":"vercel","project":"app-web"},{"action":"auto-deploy-off","platform":"render","project":"api","error":"HTTP 401"}],
 "allowances":[{"platform":"vercel","project":"blog","expiresAt":$((now + 7300))}],"pathMissing":["jq"]}
JSON
cat > "$tmp/freeze.json" <<'JSON'
{"configured":true,"closedNow":true,"reason":"release freeze","rules":[{"n":1,"days":["fri"],"from":"15:00","to":"24:00","reason":"release freeze"}]}
JSON
mkdir "$tmp/bin"
cat > "$tmp/bin/deploys" <<SH
#!/bin/bash
echo "\$*" >> "$tmp/calls"
case "\$*" in
  "costs 31") cat "$tmp/costs.json" ;;
  "journal export --since "*) cat "$tmp/journal.csv" ;;
  "timeline --days 7 --limit 200 --json") cat "$tmp/timeline.json" ;;
  "guard status --json") cat "$tmp/guard.json" ;;
  "freeze --json") [ -n "\${NO_FREEZE:-}" ] && exit 1; cat "$tmp/freeze.json" ;;
  *) echo "unexpected: \$*" >&2; exit 2 ;;
esac
SH
chmod +x "$tmp/bin/deploys"
export DEPLOYS="$tmp/bin/deploys"

c="$(./deploys-costs.sh)"
expect "costs: the sum of this month first, then the projects" "$(jq -c '[.items[].title]' <<<"$c")" '["$12.35 this month","app-web","blog"]'
expect "costs: builds and the price of one build" "$(jq -r '.items[1].subtitle' <<<"$c")" '$6.00, last 7 days · 12 builds, about $0.50 each'
expect "costs: an unknown count says nothing about builds" "$(jq -r '.items[2].subtitle' <<<"$c")" '$0.90, last 7 days'
expect "costs: ↵ shows the project in Deploy Center" "$(jq -r '.items[1].arg' <<<"$c")" "deploycenter://select?project=vercel%3Aapp-web"
expect "costs: the month's builds are in the subtitle" "$(jq -r '.items[0].subtitle' <<<"$c")" "Vercel charges in $mon · builds \$8.10"
expect "costs: the answer is kept 5 minutes" "$(jq -c '.cache' <<<"$c")" '{"seconds":300,"loose_reload":true}'
expect "costs: the query filters the projects, the sum stays" "$(./deploys-costs.sh BLO | jq -c '[.items[].title]')" '["$12.35 this month","blog"]'
expect "costs: missing days are said" "$(MISSING=2 bash -c 'sed -i.bak "s/\"missingDays\":0/\"missingDays\":2/" "'"$tmp"'/costs.json"; ./deploys-costs.sh' | jq -r '.items[0].subtitle')" "Vercel charges in $mon · builds \$8.10 · 2 days could not be read, a floor"
expect "costs: a CLI without costs says so" "$(DEPLOYS=/usr/bin/false ./deploys-costs.sh | jq -r '.items[0].title')" "Could not read the costs"

cat > "$tmp/timeline.json" <<'JSON'
{"days":7,"project":null,"total":2,"shown":2,"entries":[
 {"at":"2026-11-20T09:00:00Z","platform":"vercel","name":"app-web","kind":"failed","detail":"Build failed"},
 {"at":"2026-11-19T08:00:00Z","platform":"render","name":"api","kind":"deploy","detail":""}]}
JSON
t="$(./deploys-timeline.sh)"
expect "timeline: newest first, kind in the title" "$(jq -c '[.items[].title]' <<<"$t")" '["app-web · failed","api · deploy"]'
expect "timeline: ↵ shows the project, ⌘C copies the line" "$(jq -r '.items[0] | .arg + " | " + .text.copy' <<<"$t")" "deploycenter://select?project=app-web | 2026-11-20T09:00:00Z vercel:app-web failed Build failed"
expect "timeline: every word must match" "$(./deploys-timeline.sh 'API deploy' | jq -c '[.items[].title]')" '["api · deploy"]'
j="$(./deploys-journal.sh)"
expect "journal: newest first" "$(jq -c '[.items[].title]' <<<"$j")" '["site · deployed","api · rollback","app-web · failed","app-web · deployed","blog · forced"]'
expect "journal: a detail over two lines is one line" "$(jq -r '.items[2].subtitle' <<<"$j")" "2026-11-19 10:30 · Build failed second line"
expect "journal: the formula-guard quote is taken off, doubled quotes are one" "$(jq -r '.items[4].subtitle' <<<"$j")" '2026-11-17 08:00 · -- forced: release "hotfix"'
expect "journal: a comma inside quotes stays in the detail" "$(jq -r '.items[3].subtitle' <<<"$j")" "2026-11-18 09:00 · Started from the app, 2 commits"
expect "journal: ↵ shows the project, ⌘C copies the line" "$(jq -r '.items[1] | .arg + " | " + .text.copy' <<<"$j")" "deploycenter://select?project=api | 2026-11-19T11:00:00Z Render:api rollback Rolled back (dpl_1)"
expect "journal: every word must match, any case" "$(./deploys-journal.sh 'APP-web failed' | jq -c '[.items[].title]')" '["app-web · failed"]'
expect "journal: no match is one item" "$(./deploys-journal.sh zzz | jq -r '.items[0].title')" "No entry matches"
expect "journal: the export asks for a start date 90 days back" "$(grep -c '^journal export --since 20[0-9][0-9]-[0-9][0-9]-[0-9][0-9]$' "$tmp/calls" | awk '$1 > 0 {print "yes"}')" "yes"
expect "journal: a CLI without a journal says so" "$(DEPLOYS=/usr/bin/false ./deploys-journal.sh | jq -r '.items[0].title')" "Could not read the journal"

g="$(./deploys-guard.sh)"
expect "guard: on, last run, the tool warning, actions, allowance, freeze" "$(jq -c '[.items[].title]' <<<"$g")" '["Guard is on","The scheduled job cannot find a tool","auto-deploy-off app-web","auto-deploy-off api","Allowance: blog","Deploys are closed now","fri 15:00-24:00"]'
expect "guard: the last run reads in hours" "$(jq -r '.items[0].subtitle' <<<"$g")" "Every 30 minutes; last run 2 h ago"
expect "guard: a failed action says why" "$(jq -r '.items[3].subtitle' <<<"$g")" "failed: HTTP 401"
expect "guard: an allowance says what is left" "$(jq -r '.items[4].subtitle' <<<"$g")" "vercel · 2 h left"
expect "guard: a closed window needs --force" "$(jq -r '.items[5].subtitle' <<<"$g")" "release freeze. A deploy needs --force with a reason."
expect "guard: without a readable freeze the guard still shows" "$(NO_FREEZE=1 ./deploys-guard.sh | jq -r '.items | length')" 5
expect "guard: the query filters" "$(./deploys-guard.sh allowance | jq -c '[.items[].title]')" '["Allowance: blog"]'
expect "guard: a CLI without a guard status says so" "$(DEPLOYS=/usr/bin/false ./deploys-guard.sh | jq -r '.items[0].title')" "Could not read the guard"
expect "guard: items are not actionable" "$(jq -c '[.items[].valid] | unique' <<<"$g")" '[false]'

# Nothing here may start anything: only reads were asked of the CLI.
expect "read-only: the CLI was asked for reads only" "$(grep -Ev '^(costs 31|journal export --since |timeline --days 7 --limit 200 --json|guard status --json|freeze --json)' "$tmp/calls" | grep -c . || true)" 0

echo; [ "$fails" = 0 ] && echo "alfred: all passed" || { echo "alfred: $fails failed"; exit 1; }
