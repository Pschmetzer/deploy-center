#!/bin/bash
# deploys outages (lib/x-outages.sh): made-up journal, fixed clock.
. "$(dirname "$0")/lib.sh"
DEPLOYS_LIB=1 . ./deploys 2>/dev/null; set +e
now=1790000000; h=3600
at() { date -u -d "@$1" +%Y-%m-%dT%H:%M:%SZ 2>/dev/null || date -u -r "$1" +%Y-%m-%dT%H:%M:%SZ; }
ln() { printf '{"at":"%s","platform":"%s","name":"%s","result":"%s","detail":"x"}\n' "$(at "$1")" "$2" "$3" "$4"; }
j="$(
  ln $((now - 50*h)) vercel web live; ln $((now - 40*h)) vercel web failed; ln $((now - 39*h)) vercel web failed; ln $((now - 30*h)) vercel web live
  ln $((now - 20*h)) vercel web failed; ln $((now - 19*h)) vercel web live
  ln $((now - 10*h)) render api failed
  ln $((now - 8*h)) render =evil live
)"
o="$(outages_from "$now" 5 "" 20 <<<"$j")"
expect "three outages, one open" "$(jq -c '[.total,.open]' <<<"$o")" "[3,1]"
expect "longest first: the 10 h one, then the open 10 h api one" "$(jq -c '[.outages[] | [.project,.seconds,.failures,.open]]' <<<"$o")" '[["vercel/web",36000,2,false],["render/api",36000,1,true],["vercel/web",3600,1,false]]'
expect "the closed one has an end" "$(jq -r '.outages[0].to | length > 0' <<<"$o")" "true"
expect "the open one has none" "$(jq -r '.outages[1].to' <<<"$o")" "null"
expect "the project filter" "$(outages_from "$now" 5 api 20 <<<"$j" | jq -c '.total')" "1"
expect "the limit" "$(outages_from "$now" 5 "" 1 <<<"$j" | jq -c '[.total, (.outages|length)]')" "[3,1]"
txt="$(outages_print <<<"$o")"
has "text: header" "$txt" "Outages, the last 5 days: 3 (1 still open), longest first"
has "text: still failing" "$txt" "still failing"
has "text: hours" "$txt" "10h"
has "csv: header" "$(outages_csv <<<"$o")" "project,from,to,seconds,failures,open"
has "csv: a row" "$(outages_csv <<<"$o")" '"vercel/web",'
expect "empty journal" "$(outages_from "$now" 5 "" 20 </dev/null | jq -c '.total')" "0"
has "cli: text" "$(cli outages)" "Outages, the last 90 days: 0"
cli outages --limit 0 >/dev/null 2>&1; expect "cli: --limit 0 refused" "$?" "1"
cli outages --csv | head -n 1 | grep -q '^project,from' && ok "cli: csv header" || fail "cli: csv" "no header"
exit "$fails"
