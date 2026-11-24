# shellcheck shell=bash
# lib/forecast.sh — `deploys forecast [--json]`: the build cost of this month so far and where it ends, with a warning near
# the limit of `deploys budget`. An estimate: Vercel's billing says what was spent, the journal says who deployed how often,
# so the spend is shared by deploys and projected by the days left. Render has no billing API: its projects only get counts.
# Sourced by deploys; uses budget_spent, budget_json (lib/plan.sh), journal_file, table, die.

# forecast_from <now epoch> <spent usd or "null"> <limit usd or "null"> <warn percent>: stdin is the journal.
forecast_from() {
  jq -cRs --argjson now "$1" --argjson spent "$2" --argjson limit "$3" --argjson warn "$4" '
    def ts: (.at // "" | tostring | sub("\\.[0-9]+Z$"; "Z") | try fromdateiso8601 catch null);
    def started: (.result == "live") or (.result == "other" and ((.detail // "") | tostring | test("^Started")));
    ($now | strftime("%Y-%m")) as $ym
    | ($now | strftime("%d") | tonumber) as $day
    | ($now | gmtime) as $g
    | (([$g[0], $g[1], 1, 0, 0, 0, 0, 0] | mktime) as $first
       | ((if $g[1] == 11 then [$g[0] + 1, 0, 1, 0, 0, 0, 0, 0] else [$g[0], $g[1] + 1, 1, 0, 0, 0, 0, 0] end) | mktime) as $next
       | (($next - $first) / 86400 | round)) as $dim
    | [ split("\n")[] | fromjson? | select(type == "object") | . + {t: ts} | select(.t != null and .t <= $now and (.t | strftime("%Y-%m")) == $ym and started) ] as $d
    | ($d | group_by([.platform, .name]) | map({platform:.[0].platform, name:.[0].name, deploys:length})) as $per
    | ($per | map(select(.platform | ascii_downcase == "vercel") | .deploys) | add // 0) as $vn
    | (if $spent == null then null else (($spent / $day * $dim) * 100 | round) / 100 end) as $proj
    | { month:$ym, day:$day, daysInMonth:$dim, spentUsd:$spent, projectedUsd:$proj, limitUsd:$limit,
        warning:(if $limit == null or $proj == null then null
                 elif $proj > $limit then "over"
                 elif $proj >= $limit * $warn / 100 then "near" else null end),
        projects:($per | map(. + {estimateUsd:(if ($spent != null and $vn > 0 and (.platform | ascii_downcase) == "vercel")
                                              then ((($spent / $vn * .deploys) / $day * $dim) * 100 | round) / 100 else null end)})
                       | sort_by([-.deploys, .name])) }'
}

forecast_print() {  # stdin: forecast JSON
  jq -r '
    "Forecast for \(.month) (day \(.day) of \(.daysInMonth)), an estimate",
    "  Spent so far: \(if .spentUsd == null then "unknown (Vercel billing could not be read)" else "$\(.spentUsd)" end)",
    "  End of month: \(if .projectedUsd == null then "unknown" else "about $\(.projectedUsd)" end)\(if .limitUsd != null then " of the $\(.limitUsd) budget" else " (no budget set: deploys budget set 50)" end)",
    (if .warning == "over" then "  WARNING: the forecast is over the budget." elif .warning == "near" then "  Warning: the forecast is close to the budget." else empty end),
    "  Per project (deploys this month, share of the spend by deploys):",
    (.projects[] | "    \(.platform)/\(.name): \(.deploys) deploys\(if .estimateUsd != null then ", about $\(.estimateUsd)" else "" end)")'
}

forecast_main() {
  local warn=80 spent limit out j
  while [ "$#" -gt 0 ]; do
    case "$1" in
      --warn) case "${2:-}" in ''|*[!0-9]*|0) die "--warn takes a percent of the budget, 1 or more" ;; esac; warn="$2"; shift ;;
      *) die "Unknown option $1. Usage: deploys forecast [--warn 80] [--json]" ;;
    esac
    shift
  done
  spent="$(budget_spent | jq -c '.spentUsd')"; [ -n "$spent" ] || spent=null
  limit=null; [ ! -f "$BUDGET" ] || limit="$(jq -c '.monthlyUsd | numbers' "$BUDGET" 2>/dev/null)"; [ -n "$limit" ] || limit=null
  j="$(journal_file)"; [ -f "$j" ] || j=/dev/null
  out="$(forecast_from "$(date +%s)" "$spent" "$limit" "$warn" < "$j")"
  if [ "${json:-0}" = 1 ]; then echo "$out" | jq .; else echo "$out" | forecast_print; fi
  [ "$(echo "$out" | jq -r '.warning // ""')" != over ] || exit 1
}
