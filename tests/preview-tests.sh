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

[ "$fails" = 0 ] && echo "all ok" || { echo "$fails failed"; exit 1; }
