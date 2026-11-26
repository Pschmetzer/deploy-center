#!/bin/bash
# deploys heatmap and deploys trend (lib/x-heatmap.sh): made-up journal, fixed clock through the functions.
. "$(dirname "$0")/lib.sh"
DEPLOYS_LIB=1 . ./deploys 2>/dev/null; set +e
now=1790000000   # a Monday
day=86400
at() { date -u -d "@$1" +%Y-%m-%dT%H:%M:%SZ 2>/dev/null || date -u -r "$1" +%Y-%m-%dT%H:%M:%SZ; }
j="$(
  printf '{"at":"%s","platform":"vercel","name":"web","result":"live","detail":"x"}\n' "$(at $((now - 100)))" "$(at $((now - 200)))" "$(at $((now - 3*day)))"
  printf '{"at":"%s","platform":"vercel","name":"web","result":"failed","detail":"x"}\n' "$(at $((now - 3*day - 50)))"
  printf '{"at":"%s","platform":"render","name":"api","result":"live","detail":"x"}\n' "$(at $((now - 9*day)))"
  printf '{"at":"%s","platform":"render","name":"api","result":"live","detail":"old"}\n' "$(at $((now - 400*day)))"
)"
h="$(heatmap_from "$now" 4 "" <<<"$j")"
expect "heatmap: seven rows of four weeks" "$(jq -c '[(.grid|length), (.grid[0]|length)]' <<<"$h")" "[7,4]"
expect "heatmap: totals count deploys and failures, the old line is out" "$(jq -c '[.total,.failures,.max]' <<<"$h")" "[4,1,2]"
expect "heatmap: days after today are empty" "$(jq -c '[.grid[1][3], .grid[6][3]]' <<<"$h")" "[null,null]"
expect "heatmap: today holds two deploys" "$(jq -c '.grid[0][3] | [.deploys, .failures]' <<<"$h")" "[2,0]"
expect "heatmap: the project filter" "$(heatmap_from "$now" 4 api <<<"$j" | jq -c '[.total,.project]')" '[1,"api"]'
out="$(heatmap_print <<<"$h")"
has "heatmap text: a Monday row" "$out" "  Mon "
has "heatmap text: the failure mark" "$out" "!"
has "heatmap text: the total line" "$out" "4 deploys, 1 failures in 4 weeks"
expect "heatmap: an empty journal is all dots" "$(heatmap_from "$now" 2 "" </dev/null | heatmap_print | sed -n 2p | tr -d ' ·' | sed 's/Mon//')" ""
t="$(trend_from "$now" 5 "" <<<"$j")"
expect "trend: busiest project first" "$(jq -r '.rows[0].name' <<<"$t")" "web"
expect "trend: five days, today last" "$(jq -c '.rows[0].perDay' <<<"$t")" "[0,1,0,0,2]"
expect "trend: the failure day is marked" "$(jq -c '.rows[0].failDays' <<<"$t")" "[0,1,0,0,0]"
expect "trend: a deploy older than the window is out" "$(jq '.rows | length' <<<"$t")" "1"
has "trend text: sparkline" "$(trend_print <<<"$t")" "web  ·▄··█  3 deploys, 1 failed"
cli heatmap --weeks 0 >/dev/null 2>&1; expect "cli: --weeks 0 refused" "$?" "1"
cli heatmap --weeks 3 >/dev/null 2>&1; expect "cli: an empty journal works" "$?" "0"
expect "cli: trend --json" "$(cli trend --json | jq -c '.rows')" "[]"
cli trend --days x >/dev/null 2>&1; expect "cli: trend --days x refused" "$?" "1"
has "more lists both" "$(cli more)" "heatmap"
has "more lists trend" "$(cli more)" "trend"
exit "$fails"
