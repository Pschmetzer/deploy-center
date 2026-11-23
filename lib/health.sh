# shellcheck shell=bash
# lib/health.sh — two read-only scores from the journal: `deploys health` and `deploys weeks`.
#
#   deploys health [--days 30] [--project <name>] [--no-ci] [--json]   0-100 per project
#   deploys weeks  [--days 7]  [--project <name>] [--json]            the last period against the one before
#
# The score of `health` (documented in docs/CLI.md): four parts, each worth some points.
#   failures   40  failed / (deploys + failed) in the window: 0% earns all 40, 50% or more earns 0, linear between
#   recovery   25  a failure still open earns 0; none earns 25; otherwise the typical time from a failure to the next
#                  deploy (lib/insights.sh, recovery_from): 1 hour or less earns 25, 72 hours or more earns 0
#   freshness  20  age of the last deploy in the whole journal: 7 days or less earns 20, 90 days or more earns 0
#   CI         15  CI of the branch head: green or none 15, pending 10, red 0 (unknown or --no-ci: the part is left out)
# A part without data (no deploy in the window, no deploy ever, CI unknown) is left out and the others are scaled
# to 100, so a missing fact never counts as good or bad. Without any part the score is null. 80 or more is "good",
# 50 or more "watch", below "poor". Projects with no deploy or failure in the last 365 days are not listed.
# `weeks` counts like `deploys digest` and uses the same recovery. Nothing here starts or changes anything: the
# journal is read, and CI (health only) is asked for through ci_of. Sourced by deploys after lib/insights.sh.

# health_ci_json: [{platform, name, state}] for the branch head of every project that is set up; [] when nothing
# can be read (no platform, no gh): the CI part is then left out, never a failure.
health_ci_json() {
  local all out
  all="$( (all_json) 2>/dev/null )" || all=""
  [ -n "$all" ] || { echo '[]'; return 0; }
  out="[]"
  while IFS=$'\t' read -r plat name repo sha; do
    [ -n "$repo" ] && [ -n "$sha" ] || continue
    out="$(jq -c --arg p "$plat" --arg n "$name" --arg s "$(ci_of "$repo" "$sha" </dev/null 2>/dev/null | jq -r '.state // "unknown"' 2>/dev/null || echo unknown)" '. + [{platform:$p, name:$n, state:$s}]' <<<"$out")"
  done < <(jq -r '.[]? | [.platform, .name, (.repo // ""), (.headSha // "")] | @tsv' <<<"$all" 2>/dev/null)
  echo "$out"
}

# health_from <now> <days> <project> <ci json>: stdin is the journal; one JSON object.
health_from() {
  local now="$1" days="$2" project="$3" ci="${4:-[]}" jr names rec all="[]" n
  jr="$(cat)"
  # Names with any deploy or failure in the last 365 days (a stale project must show, with a poor score).
  names="$(jq -cRs --argjson now "$now" --arg project "$project" "$INSIGHTS_JQ"'
    lines($now; 365) | map(select(started or .result == "failed") | select($project == "" or ((.name // "") | tostring) == $project)
      | {platform:((.platform // "") | clean), name:((.name // "") | clean)}) | unique' <<<"$jr")"
  while IFS= read -r n; do
    [ -n "$n" ] || continue
    rec="$(recovery_from "$now" "$days" "$(jq -r .name <<<"$n")" <<<"$jr")"
    all="$(jq -c --argjson n "$n" --argjson r "$rec" '. + [$n + {recovery:($r.projects | map(select(.platform == $n.platform and .name == $n.name)) | .[0] // null)}]' <<<"$all")"
  done < <(jq -c '.[]' <<<"$names")
  jq -cn --argjson now "$now" --argjson days "$days" --arg project "$project" --argjson ci "$ci" --argjson rows "$all" --rawfile j <(printf '%s' "$jr") "$INSIGHTS_JQ"'
    def lerp($v; $best; $worst; $max): if $v <= $best then $max elif $v >= $worst then 0 else ($max * ($worst - $v) / ($worst - $best)) end;
    ($j | lines($now; 365)) as $l
    | ($l | map(select(started or .result == "failed"))) as $ev
    | ($j | lines($now; $days)) as $w
    | def part($p; $max): {points:($p | if . == null then null else (. * 10 | round / 10) end), max:$max};
      [ $rows[] | . as $r
        | ($ev | map(select(((.platform // "") | clean) == $r.platform and ((.name // "") | clean) == $r.name))) as $e
        | ($e | map(select(.t >= $now - $days * 86400))) as $we
        | ($we | map(select(started)) | length) as $d | ($we | map(select(.result == "failed")) | length) as $f
        | ($e | map(select(started)) | map(.t) | max) as $last
        | (if $d + $f == 0 then null else $f / ($d + $f) end) as $rate
        | (($r.recovery // {recovered:0, open:0, medianSeconds:null})) as $rc
        | (($ci | map(select(.platform == $r.platform and .name == $r.name)) | .[0].state) // null) as $cis
        | (($ci | length) > 0 and $cis != null and ($cis | IN("green", "none", "pending", "red"))) as $haveCi
        | (if $rate == null then null else lerp($rate; 0; 0.5; 40) end) as $pf
        | (if $d + $f == 0 then null elif $rc.open > 0 then 0 elif $rc.recovered == 0 then 25 else lerp($rc.medianSeconds; 3600; 259200; 25) end) as $pr
        | (if $last == null then null else lerp(($now - $last) / 86400; 7; 90; 20) end) as $pa
        | (if $haveCi | not then null else ({green:15, none:15, pending:10, red:0}[$cis]) end) as $pc
        | ([[$pf, 40], [$pr, 25], [$pa, 20], [$pc, 15]] | map(select(.[0] != null))) as $got
        | ($got | map(.[1]) | add) as $maxsum
        | {platform:$r.platform, name:$r.name,
           score:(if $maxsum == null then null else (($got | map(.[0]) | add) * 100 / $maxsum | round) end),
           deploys:$d, failures:$f, failureRate:(if $rate == null then null else ($rate * 1000 | round / 10) end),
           openOutage:($rc.open > 0), recoveredOutages:$rc.recovered, medianRecoverySeconds:$rc.medianSeconds,
           lastDeployAt:(if $last == null then null else ($last | todate) end),
           lastDeployAgeDays:(if $last == null then null else (($now - $last) / 86400 * 10 | floor / 10) end),
           ci:(if $haveCi then $cis else null end),
           parts:{failures:part($pf; 40), recovery:part($pr; 25), freshness:part($pa; 20), ci:part($pc; 15)}}
        | . + {rating:(if .score == null then null elif .score >= 80 then "good" elif .score >= 50 then "watch" else "poor" end)} ]
      | sort_by(.score // 101, .name) as $p
      | {days:$days, project:(if $project == "" then null else $project end), ciRead:(($ci | length) > 0),
         projects:$p, average:(if ($p | map(select(.score != null)) | length) == 0 then null
                               else (($p | map(.score | select(. != null)) | add) / ($p | map(select(.score != null)) | length) | round) end)}'
}

health_print() {  # stdin is health JSON
  jq -r '
    "Health of your projects, last \(.days) day\(if .days == 1 then "" else "s" end)\(if .project then " for " + .project else "" end) (0-100, worst first)",
    (if (.projects | length) == 0 then "  No deploys in the journal for this time."
     else
       (.projects[] | "  \(if .score == null then " -" else (.score | tostring | ("   " + .)[-3:]) end)  \(.name) (\(.platform))  \(.rating // "no data"): \(.deploys) deploys, \(.failures) failed\(if .openOutage then ", a failure is still open" else "" end)\(if .lastDeployAgeDays != null then ", last deploy \(.lastDeployAgeDays | floor) d ago" else "" end)\(if .ci then ", CI \(.ci)" else "" end)"),
       (if .average != null then "  Average \(.average)." else empty end),
       (if .ciRead | not then "  CI was not read (--no-ci, or no platform and gh set up): that part is left out." else empty end)
     end)'
}

health_main() {
  local days=30 project="" ci=1 jf now cij out
  while [ "$#" -gt 0 ]; do
    case "$1" in
      --days) case "${2:-}" in ''|*[!0-9]*|0) die "--days takes a number of days, 1 or more" ;; esac; days="$2"; shift ;;
      --project) [ -n "${2:-}" ] || die "--project takes a project name"; project="$2"; shift ;;
      --no-ci) ci=0 ;;
      *) die "Unknown option $1. Usage: deploys health [--days 30] [--project <name>] [--no-ci] [--json]" ;;
    esac
    shift
  done
  [ "$days" -le 3650 ] || die "--days: 3650 at most"
  jf="$(journal_file)"; now="$(date +%s)"
  cij='[]'; [ "$ci" = 0 ] || cij="$(health_ci_json)"
  if [ -s "$jf" ]; then out="$(health_from "$now" "$days" "$project" "$cij" < "$jf")"; else out="$(health_from "$now" "$days" "$project" "$cij" < /dev/null)"; fi
  if [ "${json:-0}" = 1 ]; then jq . <<<"$out"; else health_print <<<"$out"; fi
}

# weeks_period <now> <days> <project> <journal>: counts of one period, as digest counts them, plus its recovery.
weeks_period() {
  local now="$1" days="$2" project="$3" jr="$4" rec
  rec="$(recovery_from "$now" "$days" "$project" <<<"$jr")"
  jq -cn --argjson now "$now" --argjson days "$days" --arg project "$project" --argjson rec "$rec" --rawfile j <(printf '%s' "$jr") "$INSIGHTS_JQ"'
    ($j | lines($now; $days) | map(select($project == "" or ((.name // "") | tostring) == $project))) as $l
    | ($l | map(select(started)) | length) as $d | ($l | map(select(.result == "failed")) | length) as $f
    | {from:($now - $days * 86400 | todate), to:($now | todate), deploys:$d, failures:$f,
       failureRate:(if $d + $f == 0 then null else ($f * 1000 / ($d + $f) | round / 10) end),
       outages:$rec.outages, recovered:$rec.recovered, open:$rec.open, medianRecoverySeconds:$rec.medianSeconds}'
}

# weeks_from <now> <days> <project>: stdin is the journal; the last <days> days against the <days> before.
weeks_from() {
  local now="$1" days="$2" project="$3" jr cur prev
  jr="$(cat)"
  cur="$(weeks_period "$now" "$days" "$project" "$jr")"
  prev="$(weeks_period "$((now - days * 86400))" "$days" "$project" "$jr")"
  jq -cn --argjson days "$days" --arg project "$project" --argjson c "$cur" --argjson p "$prev" '
    def d($a; $b): if $a == null or $b == null then null else (($a - $b) * 10 | round / 10) end;
    {days:$days, project:(if $project == "" then null else $project end), current:$c, previous:$p,
     change:{deploys:($c.deploys - $p.deploys), failureRatePoints:d($c.failureRate; $p.failureRate),
             medianRecoverySeconds:(if $c.medianRecoverySeconds == null or $p.medianRecoverySeconds == null then null else $c.medianRecoverySeconds - $p.medianRecoverySeconds end)}}'
}

weeks_print() {  # stdin is weeks JSON
  local j; j="$(cat)"
  jq -r '
    def rate: if . == null then "no deploys" else "\(.)%" end;
    def pl($n; $w): "\($n) \($w)\(if $n == 1 then "" else "s" end)";
    "The last \(pl(.days; "day"))\(if .project then " for " + .project else "" end) against the \(.days) before (UTC)",
    (if .current.deploys + .current.failures + .previous.deploys + .previous.failures == 0 then "  Nothing in the journal for this time."
     else
       "  deploys        \(.current.deploys)  (before: \(.previous.deploys))",
       "  failure rate   \(.current.failureRate | rate)  (before: \(.previous.failureRate | rate))"
     end)' <<<"$j"
  jq -r '
    def hum: if . == null then "none" elif . < 60 then "\(.)s" elif . < 3600 then "\(. / 60 | floor)m" elif . < 86400 then "\(. / 3600 | floor)h \(. % 3600 / 60 | floor)m" else "\(. / 86400 | floor)d \(. % 86400 / 3600 | floor)h" end;
    select(.current.deploys + .current.failures + .previous.deploys + .previous.failures > 0)
    | "  recovery       \(.current.medianRecoverySeconds | hum)  (before: \(.previous.medianRecoverySeconds | hum)); \(.current.open) still open"' <<<"$j"
}

weeks_main() {
  local days=7 project="" jf now out
  while [ "$#" -gt 0 ]; do
    case "$1" in
      --days) case "${2:-}" in ''|*[!0-9]*|0) die "--days takes a number of days, 1 or more" ;; esac; days="$2"; shift ;;
      --project) [ -n "${2:-}" ] || die "--project takes a project name"; project="$2"; shift ;;
      *) die "Unknown option $1. Usage: deploys weeks [--days 7] [--project <name>] [--json]" ;;
    esac
    shift
  done
  [ "$days" -le 1825 ] || die "--days: 1825 at most"
  jf="$(journal_file)"; now="$(date +%s)"
  if [ -s "$jf" ]; then out="$(weeks_from "$now" "$days" "$project" < "$jf")"; else out="$(weeks_from "$now" "$days" "$project" < /dev/null)"; fi
  if [ "${json:-0}" = 1 ]; then jq . <<<"$out"; else weeks_print <<<"$out"; fi
}
