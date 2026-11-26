# shellcheck shell=bash
# lib/x-outages.sh — `deploys outages`: every failure period of every project, longest first.
#
#   deploys outages [--days 90] [--project <name>] [--limit 20] [--csv] [--json]
#
# From the journal: an outage starts with the first failure after a start (or after nothing) and ends with the next start
# of that project; with no start after it, it is open and runs until now. Several failures in a row are one outage.
# `deploys recovery` gives the median; this gives the list. --csv: outage rows for a spreadsheet (a text that starts with
# = + - @ gets a ' in front). Read-only; UTC. Sourced by deploys; uses journal_file, INSIGHTS_JQ (lib/insights.sh) and die.
# x-command: outages | every failure period per project with its length, longest first, from the journal | deploys outages [--days 90] [--project <name>] [--limit 20] [--csv] [--json]

# outages_from <now> <days> <project> <limit>: stdin is the journal. {days, total, open, outages:[{project, from, to, seconds, failures, open}]}
outages_from() {
  jq -cRs --argjson now "$1" --argjson days "$2" --arg project "$3" --argjson limit "$4" "$INSIGHTS_JQ"'
    def key: ((.platform // "") | clean) + "/" + ((.name // "") | clean);
    lines($now; $days) as $l
    | [ $l | map(select((started or .result == "failed") and ($project == "" or ((.name // "") | tostring) == $project))) | group_by(key)[]
        | sort_by(.t) | . as $e | (.[0] | key) as $k
        | reduce $e[] as $x ({cur: null, out: []};
            if $x.result == "failed" then (if .cur == null then .cur = {from: $x.t, failures: 1} else .cur.failures += 1 end)
            else (if .cur != null then .out += [.cur + {to: $x.t, open: false}] | .cur = null else . end) end)
        | (.out + (if .cur != null then [.cur + {to: $now, open: true}] else [] end))[]
        | {project: $k, from: (.from | todate), to: (if .open then null else (.to | todate) end), seconds: (.to - .from), failures: .failures, open: .open} ]
    | sort_by(-.seconds) as $all
    | {days: $days, total: ($all | length), open: ($all | map(select(.open)) | length), outages: $all[0:$limit]}'
}

outages_print() {
  jq -r '
    def human($s): if $s >= 86400 then "\($s / 86400 * 10 | floor / 10)d" elif $s >= 3600 then "\($s / 3600 * 10 | floor / 10)h" else "\($s / 60 | floor)m" end;
    "Outages, the last \(.days) days: \(.total) (\(.open) still open), longest first",
    (if (.outages | length) == 0 then "  none" else (.outages[] | "  \(human(.seconds))\t\(.project)\t\(.from)\t\(if .open then "still failing" else "until \(.to)" end)\t\(.failures) failure\(if .failures == 1 then "" else "s" end)") end)' | awk -F'\t' 'NF > 1 { printf "%-8s %-28s %s  %s, %s\n", $1, $2, $3, $4, $5; next } { print }'
}

outages_csv() {
  jq -r '"project,from,to,seconds,failures,open", (.outages[] | [(.project | if test("^[=+@-]") then "'" + . else . end | @csv), .from, (.to // ""), .seconds, .failures, .open] | join(","))'
}

x_outages_main() {
  local days=90 project="" limit=20 csv=0 jf now
  while [ "$#" -gt 0 ]; do
    case "$1" in
      --days) case "${2:-}" in ''|*[!0-9]*|0) die "--days takes a number of days, 1 or more" ;; esac; days="$2"; shift ;;
      --limit) case "${2:-}" in ''|*[!0-9]*|0) die "--limit takes a number, 1 or more" ;; esac; limit="$2"; shift ;;
      --project) [ -n "${2:-}" ] || die "--project takes a project name"; project="$2"; shift ;;
      --csv) csv=1 ;;
      *) die "Unknown option $1. Usage: deploys outages [--days 90] [--project <name>] [--limit 20] [--csv] [--json]" ;;
    esac
    shift
  done
  [ "$days" -le 3650 ] || die "--days: 3650 at most"
  jf="$(journal_file)"; now="$(date +%s)"; [ -s "$jf" ] || jf=/dev/null
  if [ "$csv" = 1 ]; then outages_from "$now" "$days" "$project" "$limit" < "$jf" | outages_csv
  elif [ "${json:-0}" = 1 ]; then outages_from "$now" "$days" "$project" "$limit" < "$jf" | jq .
  else outages_from "$now" "$days" "$project" "$limit" < "$jf" | outages_print; fi
}
