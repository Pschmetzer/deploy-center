# shellcheck shell=bash
# lib/x-flaky.sh — `deploys flaky`: projects whose build fails and then works again soon after, without a pause that
# looks like a fix. A hint that a retry helped (a flaky test, a slow registry), not a verdict.
#
#   deploys flaky [--days 30] [--within 30m] [--min 2] [--json]
#
# From the journal: a failure followed by a start of the same project within --within (default 30 minutes) counts as one
# quick retry. A project with at least --min of them in the period is listed, the most first. `recovery` says how long
# failures last; this says which projects keep failing and passing again. Read-only. Sourced by deploys; uses
# journal_file, INSIGHTS_JQ (lib/insights.sh) and die.
# x-command: flaky | projects whose builds fail and pass again within minutes (a retry helped), from the journal | deploys flaky [--days 30] [--within 30m] [--min 2] [--json]

# flaky_from <now> <days> <within seconds> <min>: stdin is the journal.
flaky_from() {
  jq -cRs --argjson now "$1" --argjson days "$2" --argjson within "$3" --argjson min "$4" "$INSIGHTS_JQ"'
    def key: ((.platform // "") | clean) + "/" + ((.name // "") | clean);
    lines($now; $days) as $l
    | [ $l | map(select(started or .result == "failed")) | group_by(key)[]
        | (sort_by(.t)) as $e
        | { project: (.[0] | key),
            failures: ($e | map(select(.result == "failed")) | length),
            retries: ([ range(0; ($e | length) - 1) as $i | select($e[$i].result == "failed" and ($e[$i + 1] | started) and ($e[$i + 1].t - $e[$i].t) <= $within) | 1 ] | length) } ]
    | map(select(.retries >= $min)) | sort_by([-.retries, .project]) as $rows
    | {days: $days, withinSeconds: $within, min: $min, rows: $rows}'
}

flaky_print() {
  jq -r '
    "Quick retries, the last \(.days) days: a failure and a start of the same project within \(.withinSeconds / 60 | floor) minutes (at least \(.min))",
    (if (.rows | length) == 0 then "  none" else (.rows[] | "  \(.project)  \(.retries) quick retries of \(.failures) failures") end)'
}

x_flaky_main() {
  local days=30 within=1800 min=2 jf now n
  while [ "$#" -gt 0 ]; do
    case "$1" in
      --days) case "${2:-}" in ''|*[!0-9]*|0) die "--days takes a number of days, 1 or more" ;; esac; days="$2"; shift ;;
      --min) case "${2:-}" in ''|*[!0-9]*|0) die "--min takes a number, 1 or more" ;; esac; min="$2"; shift ;;
      --within)
        case "${2:-}" in
          *m) n="${2%m}" ;;
          *h) n="${2%h}"; case "$n" in ''|*[!0-9]*) n="" ;; *) n=$((n * 60)) ;; esac ;;
          *) n="" ;;
        esac
        case "$n" in ''|*[!0-9]*|0) die "--within takes minutes or hours: 30m, 2h" ;; esac
        within=$((n * 60)); shift ;;
      *) die "Unknown option $1. Usage: deploys flaky [--days 30] [--within 30m] [--min 2] [--json]" ;;
    esac
    shift
  done
  [ "$days" -le 3650 ] || die "--days: 3650 at most"
  [ "$within" -le 86400 ] || die "--within: 24h at most"
  jf="$(journal_file)"; now="$(date +%s)"; [ -s "$jf" ] || jf=/dev/null
  if [ "${json:-0}" = 1 ]; then flaky_from "$now" "$days" "$within" "$min" < "$jf" | jq .
  else flaky_from "$now" "$days" "$within" "$min" < "$jf" | flaky_print; fi
}
