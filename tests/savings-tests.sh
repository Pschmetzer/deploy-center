#!/bin/bash
# Tests for `deploys simulate` and `deploys ledger` (lib/savings.sh). No network: the facts are
# fixtures in tests/fixtures/savings, and gh, Vercel and Render are stand-ins. Run: tests/savings-tests.sh
set -uo pipefail
cd "$(dirname "$0")/.." || exit 1
fails=0
ok()   { echo "ok   $1"; }
fail() { echo "FAIL $1: $2"; fails=$((fails+1)); }
expect() { [ "$2" = "$3" ] && ok "$1" || fail "$1" "expected [$3], got [$2]"; }

fx=tests/fixtures/savings
tmp="$(mktemp -d)"; trap 'rm -rf "$tmp"' EXIT
export DEPLOYS_CONFIG="$tmp/config" DEPLOYS_LIB=1 FX="$PWD/$fx"
# gh: GitHub's activity list (or, with GH_NO_ACTIVITY, a 404 for it) and the commits of a branch.
mkdir -p "$tmp/bin"
cat > "$tmp/bin/gh" <<'GH'
#!/bin/bash
echo "gh $*" >> "${CALLS:-/dev/null}"
case "$*" in
  *"/activity?"*) [ -n "${GH_NO_ACTIVITY:-}" ] && { echo "gh: Not Found (HTTP 404)" >&2; exit 1; }; cat "$FX/gh-activity.json" ;;
  *"/commits?sha="*) [ -n "${GH_DOWN:-}" ] && exit 1; cat "$FX/gh-commits.json" ;;
  *) exit 1 ;;
esac
GH
chmod +x "$tmp/bin/gh"; export PATH="$tmp/bin:$PATH" CALLS="$tmp/calls.log"
# shellcheck source=../deploys
. ./deploys
# shellcheck source=../lib/savings.sh
. ./lib/savings.sh
set +e

# --- simulate: pushes times the average build, per month, next to once a day ---
sim="$(sv_simulate_from < "$fx/simulate-facts.json")"
row() { echo "$sim" | jq -c --arg n "$1" ".projects[] | select(.name == \$n) | $2"; }
expect "simulate: marked as an estimate and says how" "$(echo "$sim" | jq -c '{estimate, kind, days, m:(.method | test("^Estimate"))}')" \
  '{"estimate":true,"kind":"simulate","days":30,"m":true}'
expect "simulate: pushes before the window are left out" "$(row web '{pushes, activeDays, avgBuildMinutes}')" '{"pushes":6,"activeDays":2,"avgBuildMinutes":3}'
expect "simulate: Vercel billing prices a build" "$(row web '{usdPerBuild, priceSource}')" '{"usdPerBuild":0.2,"priceSource":"vercel-billing"}'
expect "simulate: auto-deploy a month" "$(row web '.autoMonth')" '{"builds":6,"minutes":18,"usd":1.2}'
expect "simulate: once a day a month" "$(row web '.dailyMonth')" '{"builds":2,"minutes":6,"usd":0.4}'
expect "simulate: the difference" "$(row web '.savingMonth')" '{"builds":4,"minutes":12,"usd":0.8}'
expect "simulate: without its own billing, the team's price per minute" "$(row api '{usdPerBuild, priceSource, basis}')" \
  '{"usdPerBuild":0.67,"priceSource":"vercel-team-rate","basis":"commits"}'
expect "simulate: Render in pipeline minutes, no price without a rate" "$(row svc '{unit, autoMonth, dailyMonth}')" \
  '{"unit":"pipeline minutes","autoMonth":{"builds":4,"minutes":20,"usd":null},"dailyMonth":{"builds":1,"minutes":5,"usd":null}}'
expect "simulate: a project GitHub could not answer for is named, not counted" "$(row lost '{pushes, problem:(.problem | test("GitHub"))}')" \
  '{"pushes":0,"problem":true}'
expect "simulate: totals" "$(echo "$sim" | jq -c '.total | {a:.autoMonth, d:.dailyMonth.usd, c:.usdComplete}')" \
  '{"a":{"usd":3.2,"vercelMinutes":48,"renderMinutes":20,"builds":13},"d":2.4,"c":false}'
expect "simulate: a Render rate prices Render" \
  "$(jq '.rates.renderUsdPerMinute = 0.01' "$fx/simulate-facts.json" | sv_simulate_from | jq -c '.projects[] | select(.name == "svc") | {usdPerBuild, priceSource, u:.autoMonth.usd}')" \
  '{"usdPerBuild":0.05,"priceSource":"rate-setting","u":0.2}'
expect "simulate: incomplete billing counts falls back to the team rate" \
  "$(jq '.costs.buildsComplete = false' "$fx/simulate-facts.json" | sv_simulate_from | jq -c '.projects[] | select(.name == "web") | .priceSource')" '"vercel-team-rate"'

# --- ledger: pushes since auto-deploy was off whose commit never built ---
led="$(sv_ledger_from < "$fx/ledger-facts.json")"
lrow() { echo "$led" | jq -c --arg n "$1" ".projects[] | select(.name == \$n) | $2"; }
expect "ledger: an estimate, from the first day off" "$(echo "$led" | jq -c '{estimate, kind, since, days}')" \
  '{"estimate":true,"kind":"ledger","since":"2026-01-20","days":11}'
expect "ledger: only projects that were turned off" "$(echo "$led" | jq -c '[.projects[].name]')" '["web","svc"]'
expect "ledger: a pushed commit that was deployed by hand is not skipped" "$(lrow web '{pushes, builds, skipped, savedMinutes, savedUsd, builtUsd}')" \
  '{"pushes":5,"builds":1,"skipped":4,"savedMinutes":12,"savedUsd":0.8,"builtUsd":0.2}'
expect "ledger: skipped pushes are listed, newest first" "$(lrow web '[.skippedPushes[].sha]')" '["a4","a3","a2","a1"]'
expect "ledger: Render in pipeline minutes" "$(lrow svc '{skipped, savedMinutes, savedUsd, unit, offDay}')" \
  '{"skipped":2,"savedMinutes":10,"savedUsd":null,"unit":"pipeline minutes","offDay":"2026-01-25"}'
expect "ledger: totals" "$(echo "$led" | jq -c '.total')" \
  '{"skipped":6,"pushes":8,"builds":2,"usd":0.8,"builtUsd":0.2,"vercelMinutes":12,"renderMinutes":10,"usdComplete":false}'
expect "ledger: nothing turned off is an empty ledger, not an error" \
  "$(jq '.projects |= map(.offAt = null)' "$fx/ledger-facts.json" | sv_ledger_from | jq -c '{since, days, n:(.projects | length), s:.total.skipped}')" \
  '{"since":null,"days":0,"n":0,"s":0}'

# The app's tests decode these two files: they must be what the script prints today.
expect "fixture simulate-report.json is current" "$(echo "$sim" | jq -S -c .)" "$(jq -S -c . "$fx/simulate-report.json")"
expect "fixture ledger-report.json is current" "$(echo "$led" | jq -S -c .)" "$(jq -S -c . "$fx/ledger-report.json")"

# --- GitHub: pushes from the activity list, commits when that cannot be read ---
since=1769644800   # 2026-01-29
expect "pushes: from GitHub's activity list, since the given time" "$(sv_pushes me/web main "$since" | jq -c '{basis, s:[.list[].sha]}')" \
  '{"basis":"pushes","s":["p1","p2"]}'
expect "pushes: commits stand in when the activity list is refused" "$(GH_NO_ACTIVITY=1 sv_pushes me/web main "$since" | jq -c '{basis, s:[.list[].sha]}')" \
  '{"basis":"commits","s":["c1","c2"]}'
expect "pushes: GitHub down is an error, not zero pushes" "$(GH_NO_ACTIVITY=1 GH_DOWN=1 sv_pushes me/web main "$since" | jq -c 'has("error")')" 'true'
: > "$CALLS"; sv_pushes me/web prod "$since" >/dev/null
expect "pushes: asked for the deploy branch" "$(grep -c 'ref=refs/heads/prod&activity_type=push' "$CALLS")" "1"

# --- builds: minutes of finished builds and which commits were built ---
vercel_call() { cat "$FX/vercel-deployments.json"; }
render_call() { cat "$FX/render-deploys.json"; }
expect "Vercel builds: minutes of READY builds only, built commits with their time" "$(sv_builds vercel web web | jq -c '{minutes, b:[.built[].sha]}')" \
  '{"minutes":[3,1],"b":["a5","a4",null]}'
expect "Render builds: minutes of live builds, fractions of seconds read" "$(sv_builds render svc srv-x | jq -c '{minutes:(.minutes | map(. * 10 | round)), b:[.built[].sha]}')" \
  '{"minutes":[40],"b":["r3","r2"]}'

# --- the whole way, with the projects and billing stood in ---
sv_projects() { echo '[{"platform":"vercel","name":"web","id":"web","repo":"me/web","ref":"main","auto":true,"offAt":1769644800},
                       {"platform":"vercel","name":"bare","id":"bare","repo":null,"ref":null,"auto":true,"offAt":null}]'; }
sv_costs() { echo '{"buildsComplete":true,"projects":[{"name":"web","build":0.6,"builds":3}]}'; }
facts="$(sv_facts ledger 30)"
expect "facts: one document with every project, rates from the environment" \
  "$(echo "$facts" | jq -c '{n:(.projects | length), bare:.projects[0].pushes, r:.rates}')" '{"n":2,"bare":null,"r":{"vercelUsdPerMinute":null,"renderUsdPerMinute":null}}'
expect "facts to ledger: pushes since off, the built one not skipped" "$(echo "$facts" | sv_ledger_from | jq -c '.projects[0] | {pushes, skipped, usdPerBuild}')" \
  '{"pushes":2,"skipped":2,"usdPerBuild":0.2}'
expect "facts for simulate: a project without a repo is named" \
  "$(DEPLOYS_RENDER_USD_PER_MIN=0.02 sv_facts simulate 30 | jq -c '{bare:(.projects[] | select(.name == "bare") | .pushes.error), r:.rates.renderUsdPerMinute}')" \
  '{"bare":"no GitHub repo and branch known","r":0.02}'
expect "print: a line a person can read" "$(echo "$led" | sv_print | head -n 1)" \
  'Since 2026-01-20: ≈ $0.8 saved, 6 builds skipped (12 Vercel build minutes, 10 Render pipeline minutes).'

# --- the commands ---
cli() { env -u DEPLOYS_LIB PATH="$tmp/bin:/usr/bin:/bin" HOME="$tmp" NO_COLOR=1 /bin/bash ./deploys "$@" 2>&1; }
expect "simulate refuses a word for --days" "$(cli simulate --days abc --json | grep -c 'number from 1 to 90')" "1"
expect "simulate refuses an unknown option" "$(cli simulate --weeks 2 | grep -c 'Unknown option --weeks')" "1"
expect "--help lists simulate and ledger" "$(cli --help | grep -cE 'deploys (simulate|ledger)')" "2"
expect "a missing lib is a clear error" "$(DEPLOYS_SAVINGS_LIB=/nonexistent cli ledger --json | grep -c 'lib/savings.sh is missing')" "1"
expect "the fixtures hold no personal data" "$(grep -rcE '(srv|prj|team)_?-?[a-z0-9]{16,}|/Users/' "$fx" | grep -vc ':0$')" "0"

echo
[ "$fails" = 0 ] && echo "All savings tests passed." || { echo "$fails savings tests failed."; exit 1; }
