# shellcheck shell=bash
# lib/x-besttime.sh — `deploys besttime`: the weekday and hour (UTC) when deploys went best, and when worst.
#
#   deploys besttime [--days 90] [--min 5] [--next] [--json]
#
# From the journal: every start and failure is put in a slot (weekday and hour, UTC). A slot with at least --min
# of them is rated by its share of failures. The quietest good slots come first; the worst are listed to avoid.
# `--next` names the next date and time a good slot begins. It only reads the journal and the clock: it does not know
# your deploy window, so check `deploys freeze` before you plan on a slot. A hint from your own history, not a rule.
# Sourced by deploys; uses journal_file, INSIGHTS_JQ (lib/insights.sh) and die.
# x-command: besttime | the weekday and hour when your deploys went best (and worst), and the next good slot | deploys besttime [--days 90] [--min 5] [--next] [--json]

# besttime_from <now> <days> <min>: stdin is the journal. {days, min, samples, best:[slot…], worst:[slot…], next}
# slot = {weekday:1-7 (Mon=1), hour, label, deploys, failures, failureRate}
besttime_from() {
  jq -cRs --argjson now "$1" --argjson days "$2" --argjson min "$3" "$INSIGHTS_JQ"'
    ["Mon","Tue","Wed","Thu","Fri","Sat","Sun"] as $wn
    | lines($now; $days) as $l
    | [ $l[] | select(started or .result == "failed")
        | {wd: ((((.t / 86400 | floor) + 3) % 7) + 1), h: ((.t % 86400) / 3600 | floor), f: (.result == "failed")} ] as $ev
    | ($ev | group_by([.wd, .h]) | map({weekday: .[0].wd, hour: .[0].h, label: ($wn[.[0].wd - 1] + " " + (.[0].h | tostring | if length < 2 then "0" + . else . end) + ":00"),
          deploys: (length), failures: (map(select(.f)) | length)}
          | . + {failureRate: ((.failures * 1000 / .deploys | round) / 10)})
      | map(select(.deploys >= $min))) as $slots
    | ($slots | sort_by([.failureRate, -.deploys, .weekday, .hour])) as $sorted
    | ($sorted | map(select(.failures == 0)) | .[0:5]) as $best
    | ($sorted | reverse | map(select(.failures > 0)) | sort_by([-.failureRate, -.deploys]) | .[0:3]) as $worst
    | ($now / 86400 | floor) as $today
    | ( [ range(0; 8) as $o | $best[] | . as $s | ($today + $o) as $d | ($d * 86400 + $s.hour * 3600) as $at
          | select(((($d + 3) % 7) + 1) == $s.weekday and $at > $now) | {at: ($at | todate), label: $s.label} ] | sort_by(.at) | first // null ) as $next
    | {days: $days, min: $min, samples: ($ev | length), best: $best, worst: $worst, next: $next}'
}

besttime_print() {
  jq -r '
    "Best times for a deploy (UTC), from \(.samples) starts and failures in the last \(.days) days; a slot needs \(.min) or more",
    (if (.best | length) == 0 then "  No slot has enough history without a failure yet." else "  Went best:", (.best[] | "    \(.label)  \(.deploys) deploys, none failed") end),
    (if (.worst | length) > 0 then "  Failed most often:", (.worst[] | "    \(.label)  \(.failures) of \(.deploys) failed (\(.failureRate)%)") else empty end),
    (if .next then "  Next good slot: \(.next.label) (\(.next.at))" else empty end),
    "  Your deploy window is not read here: deploys freeze says what is closed."'
}

x_besttime_main() {
  local days=90 min=5 next=0 jf now
  while [ "$#" -gt 0 ]; do
    case "$1" in
      --days) case "${2:-}" in ''|*[!0-9]*|0) die "--days takes a number of days, 1 or more" ;; esac; days="$2"; shift ;;
      --min) case "${2:-}" in ''|*[!0-9]*|0) die "--min takes a number, 1 or more" ;; esac; min="$2"; shift ;;
      --next) next=1 ;;
      *) die "Unknown option $1. Usage: deploys besttime [--days 90] [--min 5] [--next] [--json]" ;;
    esac
    shift
  done
  [ "$days" -le 3650 ] || die "--days: 3650 at most"
  jf="$(journal_file)"; now="$(date +%s)"; [ -s "$jf" ] || jf=/dev/null
  if [ "$next" = 1 ] && [ "${json:-0}" != 1 ]; then
    besttime_from "$now" "$days" "$min" < "$jf" | jq -r 'if .next then "\(.next.label) (\(.next.at))" else "no good slot yet: not enough history" end'
  elif [ "${json:-0}" = 1 ]; then besttime_from "$now" "$days" "$min" < "$jf" | jq .
  else besttime_from "$now" "$days" "$min" < "$jf" | besttime_print; fi
}
