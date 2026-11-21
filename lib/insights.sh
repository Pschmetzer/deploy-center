# shellcheck shell=bash
# lib/insights.sh — three read-only views of the journal: `deploys timeline`, `deploys recovery`, `deploys when`.
#
#   deploys timeline [--days 3] [--project <name>] [--limit 50] [--json]   what happened, newest day first
#   deploys recovery [--days 30] [--project <name>] [--json]               how long a failure lasted until the next deploy
#   deploys when [--days 90] [--by weekday|hour] [--json]                  when deploys fail more often (UTC, a hint, not a rule)
#
# Same journal and same counting as `deploys digest` (lib/digest.sh): a "deploy" is a line with the result
# live or a journaled start; "failed" is a failure. Times are UTC, as the journal writes them. Nothing here
# starts, changes or sends anything; the journal is only read. Sourced by deploys; uses journal_file and die.

# The part every view shares: parse the lines, keep those in the window, name the kind.
INSIGHTS_JQ='
  def ts: (.at // "" | tostring | sub("\\.[0-9]+Z$"; "Z") | try fromdateiso8601 catch null);
  def clean: tostring | gsub("[\\x00-\\x1f\\x7f]"; " ") | .[0:160];
  def started: (.result == "live") or (.result == "other" and ((.detail // "") | tostring | test("^Started")));
  def kind: if started then "deploy" else (.result // "other" | clean) end;
  def lines($now; $days): ($now - $days * 86400) as $since
    | [ split("\n")[] | fromjson? | select(type == "object") | . + {t: ts}
        | select(.t != null and .t >= $since and .t <= $now) ];
'

# timeline_from <now> <days> <project> <limit>: stdin is the journal; one JSON object, newest first.
timeline_from() {
  jq -cRs --argjson now "$1" --argjson days "$2" --arg project "$3" --argjson limit "$4" "$INSIGHTS_JQ"'
    lines($now; $days) as $l
    | [ $l[] | select($project == "" or ((.name // "") | tostring) == $project)
        | {at:.at, t:.t, platform:(.platform // "" | clean), name:(.name // "" | clean), kind:kind, detail:((.detail // "") | clean)} ]
      | sort_by(-.t) as $all
    | {days:$days, project:(if $project == "" then null else $project end), total:($all | length),
       shown:($all[0:$limit] | length), entries:($all[0:$limit] | map(del(.t)))}'
}

timeline_print() {  # stdin is timeline JSON
  jq -r '
    def plural($n; $w): "\($n) \($w)\(if $n == 1 then "" else "s" end)";
    "Timeline of the last \(plural(.days; "day"))\(if .project then " for " + .project else "" end) (UTC)",
    (if .total == 0 then "  Nothing in the journal for this time."
     else
       (reduce .entries[] as $e ({day: "", out: []};
          ($e.at[0:10]) as $d
          | .out += (if $d != .day then ["  \($d)"] else [] end)
              + ["    \($e.at[11:16])  \(if $e.kind == "deploy" then "deploy  " elif $e.kind == "failed" then "FAILED  " else ($e.kind + "          ")[0:8] end) \($e.name) (\($e.platform))\(if $e.detail != "" then ": " + $e.detail else "" end)"]
              | .day = $d) | .out[]),
       (if .total > .shown then "  … \(.total - .shown) more (--limit)" else empty end)
     end)'
}

timeline_main() {
  local days=3 project="" limit=50 jf now
  while [ "$#" -gt 0 ]; do
    case "$1" in
      --days) case "${2:-}" in ''|*[!0-9]*|0) die "--days takes a number of days, 1 or more" ;; esac; days="$2"; shift ;;
      --limit) case "${2:-}" in ''|*[!0-9]*|0) die "--limit takes a number, 1 or more" ;; esac; limit="$2"; shift ;;
      --project) [ -n "${2:-}" ] || die "--project takes a project name"; project="$2"; shift ;;
      *) die "Unknown option $1. Usage: deploys timeline [--days 3] [--project <name>] [--limit 50] [--json]" ;;
    esac
    shift
  done
  [ "$days" -le 3650 ] || die "--days: 3650 at most"
  [ "$limit" -le 10000 ] || die "--limit: 10000 at most"
  jf="$(journal_file)"; now="$(date +%s)"
  local out
  if [ -s "$jf" ]; then out="$(timeline_from "$now" "$days" "$project" "$limit" < "$jf")"; else out="$(timeline_from "$now" "$days" "$project" "$limit" < /dev/null)"; fi
  if [ "${json:-0}" = 1 ]; then jq . <<<"$out"; else timeline_print <<<"$out"; fi
}

# recovery_from <now> <days> <project>: how long each failure lasted until the next deploy of the same project.
# Several failures in a row are one outage (it starts at the first). An outage without a later deploy is "open".
recovery_from() {
  jq -cRs --argjson now "$1" --argjson days "$2" --arg project "$3" "$INSIGHTS_JQ"'
    def median: sort | if length == 0 then null else (.[(length - 1) / 2 | floor] + .[length / 2 | floor]) / 2 | floor end;
    lines($now; $days) as $l
    | [ $l[] | select(started or .result == "failed") | select($project == "" or ((.name // "") | tostring) == $project) ]
    | group_by([(.platform // ""), (.name // "")])
    | map(sort_by(.t) as $s
        | (reduce $s[] as $e ({open: null, done: []};
            if $e.result == "failed" then (if .open == null then .open = $e.t else . end)
            elif ($e | started | not) then .
            elif .open != null then .done += [$e.t - .open] | .open = null
            else . end)) as $r
        | {name:($s[0].name // "" | clean), platform:($s[0].platform // "" | clean),
           recovered:($r.done | length), open:(if $r.open == null then 0 else 1 end),
           openSince:(if $r.open == null then null else ($r.open | todate) end),
           medianSeconds:($r.done | median), longestSeconds:($r.done | max)})
    | map(select(.recovered + .open > 0)) | sort_by(-.open, -(.longestSeconds // 0), .name) as $p
    | ([$p[].medianSeconds | select(. != null)] | median) as $m
    | {days:$days, project:(if $project == "" then null else $project end),
       outages:([$p[] | .recovered + .open] | add // 0), recovered:([$p[].recovered] | add // 0), open:([$p[].open] | add // 0),
       medianSeconds:$m, projects:$p[0:20]}'
}

recovery_human() {  # recovery_human <seconds>: 45s, 12m, 3h 20m, 2d 4h
  local s="$1"
  if [ "$s" -lt 60 ]; then echo "${s}s"
  elif [ "$s" -lt 3600 ]; then echo "$((s / 60))m"
  elif [ "$s" -lt 86400 ]; then echo "$((s / 3600))h $((s % 3600 / 60))m"
  else echo "$((s / 86400))d $((s % 86400 / 3600))h"; fi
}

recovery_print() {  # stdin is recovery JSON
  local j line s
  j="$(cat)"
  echo "Recovery over the last $(jq -r '"\(.days) day\(if .days == 1 then "" else "s" end)"' <<<"$j")$(jq -r 'if .project then " for " + .project else "" end' <<<"$j") (time from a failure to the next deploy)"
  if [ "$(jq .outages <<<"$j")" = 0 ]; then echo "  No failures in the journal for this time."; return 0; fi
  s="$(jq -r '.medianSeconds // empty' <<<"$j")"
  echo "  $(jq -r '"\(.outages) outage\(if .outages == 1 then "" else "s" end), \(.recovered) recovered, \(.open) still open"' <<<"$j")${s:+, typical recovery $(recovery_human "$s")}"
  jq -r '.projects[] | [.name, .platform, .recovered, .open, (.medianSeconds // "-"), (.longestSeconds // "-"), (.openSince // "-")] | @tsv' <<<"$j" |
    while IFS=$'\t' read -r name plat rec open med lng since; do
      line="    $name ($plat): $rec recovered"
      [ "$med" = - ] || line="$line, typical $(recovery_human "$med"), longest $(recovery_human "$lng")"
      [ "$open" = 0 ] || line="$line, OPEN since ${since:0:16}"
      echo "${line/T/ }"
    done
}

recovery_main() {
  local days=30 project="" jf now out
  while [ "$#" -gt 0 ]; do
    case "$1" in
      --days) case "${2:-}" in ''|*[!0-9]*|0) die "--days takes a number of days, 1 or more" ;; esac; days="$2"; shift ;;
      --project) [ -n "${2:-}" ] || die "--project takes a project name"; project="$2"; shift ;;
      *) die "Unknown option $1. Usage: deploys recovery [--days 30] [--project <name>] [--json]" ;;
    esac
    shift
  done
  [ "$days" -le 3650 ] || die "--days: 3650 at most"
  jf="$(journal_file)"; now="$(date +%s)"
  if [ -s "$jf" ]; then out="$(recovery_from "$now" "$days" "$project" < "$jf")"; else out="$(recovery_from "$now" "$days" "$project" < /dev/null)"; fi
  if [ "${json:-0}" = 1 ]; then jq . <<<"$out"; else recovery_print <<<"$out"; fi
}

# when_from <now> <days> <by>: failure rate per weekday (Mon..Sun) or per hour of the day, in UTC.
# A slot needs at least 5 tries before it can be called the best or worst one: fewer is noise.
when_from() {
  jq -cRs --argjson now "$1" --argjson days "$2" --arg by "$3" "$INSIGHTS_JQ"'
    def slot: if $by == "hour" then (.t | strftime("%H")) else (.t | strftime("%u %a")) end;
    lines($now; $days) as $l
    | [ $l[] | select(started or .result == "failed") ] as $x
    | ($x | group_by(slot) | map({slot:(.[0] | slot | if $by == "hour" then . + ":00" else .[2:] end),
         order:(.[0] | slot), deploys:(map(select(started)) | length), failures:(map(select(.result == "failed")) | length)}
         | . + {tries:(.deploys + .failures), rate:((.failures * 1000 / (.deploys + .failures)) | round / 10)})
       | sort_by(.order) | map(del(.order))) as $s
    | ($s | map(select(.tries >= 5))) as $ok
    | {days:$days, by:$by, tries:($x | length), slots:$s,
       worst:(if ($ok | length) < 2 then null else ($ok | sort_by(-.rate, .slot) | .[0]) end),
       best:(if ($ok | length) < 2 then null else ($ok | sort_by(.rate, .slot) | .[0]) end)}'
}

when_print() {  # stdin is when JSON
  jq -r '
    "Failure rate by \(if .by == "hour" then "hour of the day" else "weekday" end), last \(.days) days (UTC)",
    (if .tries == 0 then "  Nothing in the journal for this time."
     else
       (.slots[] | "  \(.slot)  \((.rate | tostring) + "%" | .[0:6] + "      " | .[0:6])  \(.failures) of \(.tries)\(if .tries < 5 then "  (too few to say)" else "" end)"),
       (if .worst and .worst.rate > 0 then "  Most failures: \(.worst.slot) (\(.worst.rate)%). Fewest: \(.best.slot) (\(.best.rate)%). A hint from your own history, not a rule." else "  No slot stands out." end)
     end)'
}

when_main() {
  local days=90 by=weekday jf now out
  while [ "$#" -gt 0 ]; do
    case "$1" in
      --days) case "${2:-}" in ''|*[!0-9]*|0) die "--days takes a number of days, 1 or more" ;; esac; days="$2"; shift ;;
      --by) case "${2:-}" in weekday|hour) by="$2" ;; *) die "--by takes weekday or hour" ;; esac; shift ;;
      *) die "Unknown option $1. Usage: deploys when [--days 90] [--by weekday|hour] [--json]" ;;
    esac
    shift
  done
  [ "$days" -le 3650 ] || die "--days: 3650 at most"
  jf="$(journal_file)"; now="$(date +%s)"
  if [ -s "$jf" ]; then out="$(when_from "$now" "$days" "$by" < "$jf")"; else out="$(when_from "$now" "$days" "$by" < /dev/null)"; fi
  if [ "${json:-0}" = 1 ]; then jq . <<<"$out"; else when_print <<<"$out"; fi
}
