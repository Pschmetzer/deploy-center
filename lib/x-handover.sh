# shellcheck shell=bash
# lib/x-handover.sh — `deploys handover`: what the next person on duty needs to know, from the journal and the deploy window.
#
#   deploys handover [--hours 24] [--json]
#
# Four things: projects whose newest start or failure is a failure (so, not fixed yet), the notes written with
# `deploys note`, the counts of the period, and whether the deploy window is closed now. It asks no platform and no
# GitHub; the window is read from window.json. Read-only. Times are UTC, as the journal writes them.
# Sourced by deploys; uses journal_file, INSIGHTS_JQ (lib/insights.sh), die and, for the window, `$SELF window --json`.
# x-command: handover | what is still failing, the notes of the last hours, the counts and whether deploys are closed now | deploys handover [--hours 24] [--json]

# handover_from <now> <hours> <window json>: stdin is the journal.
handover_from() {
  jq -cRs --argjson now "$1" --argjson hours "$2" --argjson win "$3" "$INSIGHTS_JQ"'
    def key: ((.platform // "") | clean) + "/" + ((.name // "") | clean);
    ($now - $hours * 3600) as $since
    | [ split("\n")[] | fromjson? | select(type == "object") | . + {t: ts} | select(.t != null and .t <= $now) ] as $all
    | ($all | map(select(started or .result == "failed")) | group_by(key)
       | map(sort_by(.t) | last | select(.result == "failed") | {project: key, failedAt: .at, detail: ((.detail // "") | clean)})
       | sort_by(.failedAt) | reverse) as $open
    | ($all | map(select(.t >= $since)) | sort_by(-.t)) as $l
    | { hours: $hours,
        open: $open,
        notes: ($l | map(select(.result == "note") | {at: .at, project: key, text: ((.detail // "") | clean)})),
        deploys: ($l | map(select(started)) | length),
        failures: ($l | map(select(.result == "failed")) | length),
        window: {closed: ($win.denied // false), reason: ($win.reason // null)} }'
}

handover_print() {
  jq -r '
    "Handover, the last \(.hours) hours (UTC)",
    (if (.open | length) == 0 then "  Failing now: nothing" else "  Failing now:", (.open[] | "    \(.project)  since \(.failedAt)\(if .detail != "" then "  (\(.detail))" else "" end)") end),
    (if (.notes | length) == 0 then "  Notes: none" else "  Notes:", (.notes[] | "    \(.at)  \(.project): \(.text)") end),
    "  Counts: \(.deploys) deploys, \(.failures) failures",
    (if .window.closed then "  Deploy window: CLOSED now\(if .window.reason then " (\(.window.reason))" else "" end)" else "  Deploy window: open" end)'
}

x_handover_main() {
  local hours=24 jf now win
  while [ "$#" -gt 0 ]; do
    case "$1" in
      --hours) case "${2:-}" in ''|*[!0-9]*|0) die "--hours takes a number of hours, 1 or more" ;; esac; hours="$2"; shift ;;
      *) die "Unknown option $1. Usage: deploys handover [--hours 24] [--json]" ;;
    esac
    shift
  done
  [ "$hours" -le 2160 ] || die "--hours: 2160 at most"
  jf="$(journal_file)"; now="$(date +%s)"; [ -s "$jf" ] || jf=/dev/null
  win="$("$SELF" window --json 2>/dev/null </dev/null)"; jq -e . >/dev/null 2>&1 <<<"$win" || win='{}'
  if [ "${json:-0}" = 1 ]; then handover_from "$now" "$hours" "$win" < "$jf" | jq .
  else handover_from "$now" "$hours" "$win" < "$jf" | handover_print; fi
}
