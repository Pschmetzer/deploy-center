#!/bin/bash
# Tests for `deploys preview` (lib/preview.sh). Pure function with made-up JSON: no network, no real projects.
set -uo pipefail
cd "$(dirname "$0")/.." || exit 1
exec </dev/null
fails=0
ok()   { echo "ok   $1"; }
fail() { echo "FAIL $1: $2"; fails=$((fails+1)); }
expect() { [ "$2" = "$3" ] && ok "$1" || fail "$1" "expected [$3], got [$2]"; }

tmp="$(mktemp -d)"; trap 'rm -rf "$tmp"' EXIT
export DEPLOYS_CONFIG="$tmp/config" HOME="$tmp/home" NO_COLOR=1 DEPLOYS_LIB=1 DEPLOYS_TESTING=1
mkdir -p "$HOME" "$DEPLOYS_CONFIG"
# shellcheck source=../deploys
. ./deploys
set +e

proj='{"name":"web","platform":"vercel"}'
notes='{"commits":[{"sha":"abc1234567","message":"Fix header","author":"ann"},{"sha":"def7654321","message":"Add page","author":"bo"}]}'
green='{"level":"green","reasons":[],"files":3,"lines":40}'
red='{"level":"red","reasons":[{"level":"red","text":"database migrations: db/001.sql"}],"files":5,"lines":90}'
open='{"denied":false}'
shut='{"denied":true,"reason":"Friday"}'

j="$(preview_from "$proj" "$notes" "$green" '[]' "$open" null)"
expect "ok: two commits, nothing blocks" "$(jq -c '{v:.verdict, n:.commits.count, s:.startedNothing}' <<<"$j")" '{"v":"ok","n":2,"s":true}'
expect "files and lines are shown" "$(jq -c '[.files,.lines]' <<<"$j")" '[3,40]'
expect "red risk is careful" "$(preview_from "$proj" "$notes" "$red" '[]' "$open" null | jq -r .verdict)" "careful"
expect "freeze blocks" "$(preview_from "$proj" "$notes" "$green" '[]' "$shut" null | jq -c '[.verdict, .blockers[0]]')" '["blocked","deploy window closed: Friday"]'
expect "a hold rule blocks" "$(preview_from "$proj" "$notes" "$green" '[{"rule":"nofri","index":1,"matched":true,"action":"hold"}]' "$open" null | jq -r .verdict)" "blocked"
expect "over budget blocks" "$(preview_from "$proj" "$notes" "$green" '[]' "$open" '{"monthlyUsd":10,"spentUsd":9,"over":true}' | jq -r .verdict)" "blocked"
expect "unmatched rule is ignored" "$(preview_from "$proj" "$notes" "$green" '[{"rule":"x","index":1,"matched":false,"action":"hold"}]' "$open" null | jq -r .rule)" "null"
expect "nothing waits" "$(preview_from "$proj" '{"commits":[]}' "$green" '[]' "$open" null | jq -r .verdict)" "nothing-waits"
out="$(preview_from "$proj" "$notes" "$green" '[]' "$open" null | preview_print)"
expect "text: title" "$(head -n 1 <<<"$out")" "Preview of a production deploy: web (vercel)"
expect "text: ends by saying nothing started" "$(grep -c '^Nothing was started' <<<"$out")" "1"
expect "text: a commit line" "$(grep -c 'abc1234  Fix header (ann)' <<<"$out")" "1"

# --- domains_from ---
tsv=$'vercel\tweb\tweb.vercel.app\t80\nvercel\tweb\tshop.example.test\t12\nrender\tapi\tapi.example.test\t-3\nrender\tapi\tapi.onrender.com\t\n'
d="$(domains_from 30 <<<"$tsv")"
expect "domains: states" "$(jq -c '[.domains[].state]' <<<"$d")" '["ok","warn","expired","unknown"]'
expect "domains: kinds" "$(jq -c '[.domains[].kind]' <<<"$d")" '["platform","custom","custom","platform"]'
expect "domains: problems count" "$(jq .problems <<<"$d")" "2"
expect "domains: a lower threshold" "$(domains_from 10 <<<"$tsv" | jq .problems)" "1"
expect "domains: empty input" "$(domains_from 30 </dev/null | jq -c '{problems, n:(.domains|length)}')" '{"problems":0,"n":0}'
expect "domains: bad --warn refused" "$(env -u DEPLOYS_LIB bash ./deploys domains --warn x >/dev/null 2>&1; echo $?)" "1"

# --- forecast_from ---
fnow=1799841600   # 2027-01-13 12:00 UTC: day 13 of 31
fj="$(printf '%s\n' '{"at":"2027-01-05T10:00:00Z","platform":"vercel","name":"web","result":"live"}' '{"at":"2027-01-06T10:00:00Z","platform":"vercel","name":"web","result":"live"}' '{"at":"2027-01-07T10:00:00Z","platform":"vercel","name":"api","result":"other","detail":"Started from the terminal"}' '{"at":"2027-01-08T10:00:00Z","platform":"render","name":"old","result":"live"}' '{"at":"2026-12-30T10:00:00Z","platform":"vercel","name":"web","result":"live"}' '{"at":"2027-01-06T10:00:00Z","platform":"vercel","name":"web","result":"failed"}' 'junk')"
f="$(forecast_from "$fnow" 13 30 80 <<<"$fj")"
expect "forecast: projection by days" "$(jq -c '[.daysInMonth, .projectedUsd]' <<<"$f")" '[31,31]'
expect "forecast: over the limit warns" "$(jq -r .warning <<<"$f")" "over"
expect "forecast: near the limit" "$(forecast_from "$fnow" 13 35 80 <<<"$fj" | jq -r .warning)" "near"
expect "forecast: under the limit" "$(forecast_from "$fnow" 13 100 80 <<<"$fj" | jq -r .warning)" "null"
expect "forecast: spend unknown" "$(forecast_from "$fnow" null 30 80 <<<"$fj" | jq -c '[.projectedUsd, .warning]')" '[null,null]'
expect "forecast: this month only, failures left out" "$(jq -c '[.projects[] | "\(.name)=\(.deploys)"]' <<<"$f")" '["web=2","api=1","old=1"]'
expect "forecast: render has no estimate" "$(jq -c '[.projects[] | select(.platform == "render") | .estimateUsd]' <<<"$f")" '[null]'
expect "forecast: no journal" "$(forecast_from "$fnow" 0 null 80 </dev/null | jq -c '.projects')" '[]'

# --- envdiff_from: names only, a value never shows ---
secret="sk_test_FAKE_SECRET_VALUE_123"
ev="[{\"key\":\"DB_URL\",\"targets\":[\"production\",\"preview\"],\"value\":\"$secret\"},{\"key\":\"API_KEY\",\"targets\":[\"production\"],\"value\":\"$secret\"},{\"key\":\"DEBUG\",\"targets\":[\"preview\",\"development\"]}]"
e="$(envdiff_from <<<"$ev")"
expect "env-diff: only in production" "$(jq -c .onlyProduction <<<"$e")" '["API_KEY"]'
expect "env-diff: only in preview" "$(jq -c .onlyPreview <<<"$e")" '["DEBUG"]'
expect "env-diff: counts" "$(jq -c '[.production,.preview,.both,.same]' <<<"$e")" '[2,2,1,false]'
expect "env-diff: a value is not in the JSON" "$(grep -c "$secret" <<<"$e")" "0"
expect "env-diff: a value is not in the text" "$(envdiff_print web <<<"$e" | grep -c "$secret")" "0"
expect "env-diff: same names" "$(envdiff_from <<<'[{"key":"A","targets":["production","preview"]}]' | jq .same)" "true"
expect "env-diff: a single string target" "$(envdiff_from <<<'[{"key":"A","targets":"production"}]' | jq -c .production)" "1"

# --- groups ---
g="$(groups_add_json '{}' api api web)"
expect "group: add keeps the order" "$(jq -c .api <<<"$g")" '["api","web"]'
expect "group: add replaces and keeps others" "$(groups_add_json "$g" site a | jq -c 'keys')" '["api","site"]'
expect "group: remove" "$(groups_remove_json "$g" api | jq -c .)" '{}'
expect "group: print" "$(groups_print <<<"$g")" "api: api -> web"
expect "group: print empty" "$(groups_print <<<'{}' | head -c 15)" "No groups yet: "
gcli() { env -u DEPLOYS_LIB bash ./deploys "$@"; }
expect "group: add" "$(gcli group add stack api web >/dev/null 2>&1; jq -c .stack "$DEPLOYS_CONFIG/groups.json")" '["api","web"]'
expect "group: run without --yes and without a terminal starts nothing" "$(gcli group run stack 2>&1 | grep -c 'Nothing was started')" "1"
expect "group: an unknown group is refused" "$(gcli group run nope >/dev/null 2>&1; echo $?)" "1"
expect "group: a bad name is refused" "$(gcli group add 'a b' x y >/dev/null 2>&1; echo $?)" "1"

# --- prepare_decide ---
rows='[{"platform":"vercel","name":"web","action":"would-deploy"},{"platform":"vercel","name":"api","action":"would-skip"}]'
c0='{"noFreeze":true,"yes":false,"whenGreen":true,"args":[]}'
expect "prepare: prepares, starts nothing" "$(prepare_decide "$c0" false "$rows" | jq -c '[.state, (.rows|length)]')" '["prepared",1]'
expect "prepare: frozen does nothing" "$(prepare_decide "$c0" true "$rows" | jq -r .state)" "frozen"
expect "prepare: frozen is ignored without --no-freeze" "$(prepare_decide '{"noFreeze":false,"yes":false}' true "$rows" | jq -r .state)" "prepared"
expect "prepare: nothing waits" "$(prepare_decide "$c0" false '[]' | jq -r .state)" "nothing"
expect "prepare: yes stored starts" "$(prepare_decide '{"noFreeze":true,"yes":true}' false "$rows" | jq -r .state)" "start"
expect "prepare: yes stored, still frozen: no start" "$(prepare_decide '{"noFreeze":true,"yes":true}' true "$rows" | jq -r .state)" "frozen"
expect "prepare: args" "$(prepare_args '{"whenGreen":true,"args":["--only","web"]}' | paste -sd' ' -)" "--when-green --only web"
expect "prepare: status without an entry" "$(env -u DEPLOYS_LIB bash ./deploys prepare status 2>&1 | head -c 24)" "No prepared deploy is sc"

[ "$fails" = 0 ] && echo "all ok" || { echo "$fails failed"; exit 1; }
