# shellcheck shell=bash
# lib/digest.sh — `deploys digest`: the last days (a week by default) from the journal, as a few lines or JSON.
#
#   deploys digest [--days 7] [--json] [--no-savings]
#
# Counts: "deploys" are the lines with the result live, and the starts the terminal journaled as "other"
# ("Started from the terminal ...", "Started by deploy-changed ..."); failures are "failed"; rollbacks,
# forced starts, skipped and cancelled are counted as they are. The savings are the estimate of
# `deploys ledger` (builds that did not run since auto-deploy went off, not only this week): they need
# the network, so --no-savings leaves them out. Reads only; starts nothing. Sourced by deploys; uses
# journal_file, SELF, die and json from there.

# digest_from <now epoch> <days>: stdin is the journal (JSON lines); prints the digest as one JSON object.
digest_from() {
  jq -cRs --argjson now "$1" --argjson days "$2" '
    def ts: (.at // "" | tostring | sub("\\.[0-9]+Z$"; "Z") | try fromdateiso8601 catch null);
    def clean: tostring | gsub("[\\x00-\\x1f\\x7f]"; " ") | .[0:160];
    def started: (.result == "live") or (.result == "other" and ((.detail // "") | tostring | test("^Started")));
    ($now - $days * 86400) as $since
    | [ split("\n")[] | fromjson? | select(type == "object") | . + {t: ts} | select(.t != null and .t >= $since and .t <= $now) ] as $l
    | ($l | map(select(started))) as $d
    | ($l | map(select(.result == "failed"))) as $f
    | def n($r): $l | map(select(.result == $r)) | length;
      {days:$days, since:($since | todate), until:($now | todate), entries:($l | length),
       deploys:($d | length), failures:($f | length), rollbacks:n("rollback"), forced:n("forced"),
       previews:n("preview"), skipped:n("skipped"), cancelled:n("cancelled"),
       failureRate:(if ($d | length) + ($f | length) == 0 then null else (($f | length) * 1000 / (($d | length) + ($f | length)) | round / 10) end),
       projects:($l | map(select(started or .result == "failed")) | group_by(.name // "")
         | map({name:(.[0].name // "" | clean), platform:(.[0].platform // "" | clean), deploys:(map(select(started)) | length),
                failures:(map(select(.result == "failed")) | length)})
         | sort_by(-.deploys, -.failures, .name) | .[0:10]),
       lastFailures:($f | sort_by(-.t) | .[0:5] | map({at:.at, name:(.name // "" | clean), detail:((.detail // "") | clean)})),
       busiestDay:($d | map(.t | strftime("%Y-%m-%d")) | group_by(.) | map({day:.[0], deploys:length}) | sort_by(-.deploys, .day) | .[0] // null)}'
}

# digest_savings <ledger json>: {usd, skipped, estimate} from `deploys ledger --json`, or null.
digest_savings() {
  jq -c 'if .kind == "ledger" and (.total | type) == "object"
         then {estimate:true, since:.since, skippedBuilds:.total.skipped, usd:(if .total.usdComplete then .total.usd else null end), usdComplete:.total.usdComplete}
         else null end' 2>/dev/null <<<"${1:-null}" || echo null
}

# digest_print: stdin is digest JSON (with "savings" when asked for); a few lines for a person.
digest_print() {
  jq -r '
    def plural($n; $w): "\($n) \($w)\(if $n == 1 then "" else "s" end)";
    "Digest of the last \(plural(.days; "day")) (\(.since[0:10]) to \(.until[0:10]))",
    (if .entries == 0 then "  Nothing in the journal for this time."
     else
       "  \(plural(.deploys; "deploy")), \(.failures) failed\(if .failureRate != null then " (\(.failureRate)%)" else "" end), \(.rollbacks) rolled back, \(.forced) forced",
       (if .busiestDay then "  Busiest day: \(.busiestDay.day) (\(.busiestDay.deploys))" else empty end),
       (if (.projects | length) > 0 then "  Projects:", (.projects[] | "    \(.name) (\(.platform)): \(.deploys) deploys, \(.failures) failed") else empty end),
       (if (.lastFailures | length) > 0 then "  Latest failures:", (.lastFailures[] | "    \(.at[0:16] | sub("T"; " ")) \(.name): \(.detail)") else empty end)
     end),
    (if .savings == null then (if .savingsAsked then "  Savings: not available (no ledger yet: deploys ledger)" else empty end)
     else "  Savings (estimate, since auto-deploy went off\(if .savings.since then " on " + .savings.since else "" end)): \(.savings.skippedBuilds) builds skipped\(if .savings.usd != null then ", about $\(.savings.usd)" else ", price unknown (deploys price set)" end)" end)'
}

digest_main() {
  local days=7 savings=1 jf now out sv="null"
  while [ "$#" -gt 0 ]; do
    case "$1" in
      --days) case "${2:-}" in ''|*[!0-9]*|0) die "--days takes a number of days, 1 or more" ;; esac; days="$2"; shift ;;
      --no-savings) savings=0 ;;
      *) die "Unknown option $1. Usage: deploys digest [--days 7] [--json] [--no-savings]" ;;
    esac
    shift
  done
  [ "$days" -le 3650 ] || die "--days: 3650 at most"
  jf="$(journal_file)"; now="$(date +%s)"
  if [ -s "$jf" ]; then out="$(digest_from "$now" "$days" < "$jf")"; else out="$(digest_from "$now" "$days" < /dev/null)"; fi
  if [ "$savings" = 1 ]; then
    # The ledger asks GitHub and the platforms; when it cannot, the digest still comes, without it.
    sv="$(digest_savings "$("$SELF" ledger --json 2>/dev/null || echo null)")"
  fi
  out="$(jq -c --argjson s "${sv:-null}" --argjson a "$([ "$savings" = 1 ] && echo true || echo false)" '. + {savings:$s, savingsAsked:$a}' <<<"$out")"
  if [ "${json:-0}" = 1 ]; then jq . <<<"$out"; else digest_print <<<"$out"; fi
}
