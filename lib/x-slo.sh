# shellcheck shell=bash
# lib/x-slo.sh — `deploys slo`: a goal for how many deploys work, checked against the journal. For cron and CI.
#
#   deploys slo [--days 30] [--json]        every project against the goal; exit 1 when one is below it
#   deploys slo set <percent>               the goal, 1-100 (slo.json in the config folder; refused in observer mode)
#   deploys slo off                         remove the goal
#
# Success = starts / (starts + failures) of a project in the period, counted as `deploys digest` counts. A project with
# no start and no failure is not rated. Without a goal the command prints the rates and says no goal is set (exit 0).
# Sourced by deploys; uses journal_file, INSIGHTS_JQ (lib/insights.sh), CONFIG_DIR, atomic_write, require_write and die.
# x-command: slo | a goal for how many deploys work (say 95%), checked per project against the journal, exit 1 below it | deploys slo [--days 30] [--json] | set <percent> | off

# slo_from <now> <days> <goal or null>: stdin is the journal.
slo_from() {
  jq -cRs --argjson now "$1" --argjson days "$2" --argjson goal "$3" "$INSIGHTS_JQ"'
    def key: ((.platform // "") | clean) + "/" + ((.name // "") | clean);
    lines($now; $days) as $l
    | [ $l | map(select(started or .result == "failed")) | group_by(key)[]
        | { project: (.[0] | key), deploys: (map(select(started)) | length), failures: (map(select(.result == "failed")) | length) }
        | . + { successPercent: ((.deploys * 1000 / (.deploys + .failures) | round) / 10) }
        | . + { met: (if $goal == null then null else (.successPercent >= $goal) end) } ] as $rows
    | { days: $days, goalPercent: $goal, rows: ($rows | sort_by([.successPercent, .project])),
        below: ($rows | map(select(.met == false)) | length) }'
}

slo_print() {
  jq -r '
    "Success of deploys, the last \(.days) days\(if .goalPercent != null then ", goal \(.goalPercent)%" else " (no goal set: deploys slo set 95)" end)",
    (if (.rows | length) == 0 then "  nothing in the journal for this time" else (.rows[] | "  \(if .met == false then "BELOW " elif .met == true then "ok    " else "      " end)\(.project)  \(.successPercent)%  (\(.deploys) deploys, \(.failures) failures)") end),
    (if .below > 0 then "\(.below) below the goal." else empty end)'
}

x_slo_main() {
  local days=30 jf now goal=null f="$CONFIG_DIR/slo.json" out
  case "${1:-}" in
    set)
      case "${2:-}" in ''|*[!0-9]*|0) die "Usage: deploys slo set <percent, 1-100>" ;; esac
      [ "$2" -le 100 ] && [ "$#" -eq 2 ] || die "Usage: deploys slo set <percent, 1-100>"
      require_write "slo set"
      jq -nc --argjson p "$2" '{percent:$p}' | atomic_write "$f" || die "Could not write $f"
      echo "Goal set: $2% of the deploys of every project work."; return 0 ;;
    off)
      [ "$#" -eq 1 ] || die "Usage: deploys slo off"
      require_write "slo off"; rm -f "$f"; echo "Goal removed."; return 0 ;;
  esac
  while [ "$#" -gt 0 ]; do
    case "$1" in
      --days) case "${2:-}" in ''|*[!0-9]*|0) die "--days takes a number of days, 1 or more" ;; esac; days="$2"; shift ;;
      *) die "Unknown option $1. Usage: deploys slo [--days 30] [--json] | set <percent> | off" ;;
    esac
    shift
  done
  [ "$days" -le 3650 ] || die "--days: 3650 at most"
  if [ -f "$f" ]; then goal="$(jq -c '.percent | select(type == "number" and . >= 1 and . <= 100)' "$f" 2>/dev/null)"; [ -n "$goal" ] || goal=null; fi
  jf="$(journal_file)"; now="$(date +%s)"; [ -s "$jf" ] || jf=/dev/null
  out="$(slo_from "$now" "$days" "$goal" < "$jf")"
  if [ "${json:-0}" = 1 ]; then jq . <<<"$out"; else slo_print <<<"$out"; fi
  [ "$(jq -r .below <<<"$out")" = 0 ]
}
