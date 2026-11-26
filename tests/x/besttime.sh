#!/bin/bash
# deploys besttime (lib/x-besttime.sh) and deploys slo (lib/x-slo.sh).
. "$(dirname "$0")/lib.sh"
DEPLOYS_LIB=1 . ./deploys 2>/dev/null; set +e
now=1790000000   # a Monday, 14:13 UTC
day=86400
at() { date -u -d "@$1" +%Y-%m-%dT%H:%M:%SZ 2>/dev/null || date -u -r "$1" +%Y-%m-%dT%H:%M:%SZ; }
ln() { printf '{"at":"%s","platform":"%s","name":"%s","result":"%s","detail":"x"}\n' "$(at "$1")" "$2" "$3" "$4"; }
mon10=$(( (now / day) * day + 10*3600 - 7*day ))   # last Monday 10:00 UTC
j="$( for i in 1 2 3 4 5; do ln $((mon10 - (i-1)*7*day)) vercel web live; done
      for i in 1 2 3 4 5; do ln $((mon10 + 2*day + 3600 - (i-1)*7*day)) vercel web live; done
      for i in 1 2 3 4 5 6; do ln $((mon10 + 4*day - (i-1)*7*day)) vercel web live; done
      ln $((mon10 + 4*day + 60)) vercel web failed; ln $((mon10 + 4*day + 120)) vercel web failed )"
b="$(besttime_from "$now" 90 5 <<<"$j")"
expect "besttime: Monday 10:00 and Wednesday 11:00 never failed" "$(jq -c '[.best[].label]' <<<"$b")" '["Mon 10:00","Wed 11:00"]'
expect "besttime: Friday 10:00 failed most" "$(jq -c '.worst[0] | [.label,.failures,.deploys]' <<<"$b")" '["Fri 10:00",2,8]'
expect "besttime: Monday 10:00 is past at 14:13, so the next good slot is Wednesday 11:00" "$(jq -r '.next.label' <<<"$b")" "Wed 11:00"
has "besttime text: best" "$(besttime_print <<<"$b")" "Mon 10:00  5 deploys, none failed"
expect "besttime: --min 99 leaves no slot" "$(besttime_from "$now" 90 99 <<<"$j" | jq -c '[.best,.worst,.next]')" "[[],[],null]"
has "cli: besttime --next on an empty journal" "$(cli besttime --next)" "no good slot yet"
cli besttime --min 0 >/dev/null 2>&1; expect "cli: --min 0 refused" "$?" "1"
# slo
s="$(slo_from "$now" 90 95 <<<"$j")"
expect "slo: 16 starts, 2 failures is 88.9 percent, below 95" "$(jq -c '[.rows[0].successPercent, .rows[0].met, .below]' <<<"$s")" "[88.9,false,1]"
expect "slo: no goal means no verdict" "$(slo_from "$now" 90 null <<<"$j" | jq -c '[.rows[0].met,.below]')" "[null,0]"
has "slo text" "$(slo_print <<<"$s")" "BELOW vercel/web  88.9%"
cli slo set 0 >/dev/null 2>&1; expect "cli: slo set 0 refused" "$?" "2"
cli slo set 101 >/dev/null 2>&1; expect "cli: slo set 101 refused" "$?" "2"
has "cli: slo set" "$(cli slo set 90)" "Goal set: 90%"
expect "cli: the goal is written" "$(jq -c . "$DEPLOYS_CONFIG/slo.json")" '{"percent":90}'
cp /dev/null "$DEPLOYS_JOURNAL"; echo "$j" > "$DEPLOYS_JOURNAL"
cli slo --days 3650 >/dev/null 2>&1; expect "cli: below the goal exits 1" "$?" "1"
cli slo set 80 >/dev/null; cli slo --days 3650 >/dev/null 2>&1; expect "cli: met goal exits 0" "$?" "0"
DEPLOYS_READONLY=1 cli slo set 50 >/dev/null 2>&1; expect "cli: observer mode refuses set" "$?" "1"
expect "cli: and the goal stays" "$(jq -r .percent "$DEPLOYS_CONFIG/slo.json")" "80"
cli slo off >/dev/null; [ ! -f "$DEPLOYS_CONFIG/slo.json" ] && ok "cli: slo off removes it" || fail "cli: slo off" "file remains"
exit "$fails"
