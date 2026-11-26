# shellcheck shell=bash
# lib/x-heatmap.sh — two pictures of the journal for the terminal: `deploys heatmap` and `deploys trend`.
#
#   deploys heatmap [--weeks 12] [--project <name>] [--json]    one block per day, weeks side by side, Monday on top
#   deploys trend [<project>] [--days 30] [--json]              one line per project: deploys a day as ▁▂▃▄▅▆▇█, failures marked
#
# Counted as `deploys digest` counts (a "deploy" is a line with the result live or a journaled start; "failed" is a
# failure) and in UTC, as the journal writes it. Read-only: the journal is only read. Sourced by deploys; uses
# journal_file, INSIGHTS_JQ (lib/insights.sh) and die.
# x-command: heatmap | the last weeks as a calendar of blocks, one per day (darker = more deploys, ! = a failure that day) | deploys heatmap [--weeks 12] [--project <name>] [--json]
# x-command: trend | deploys a day as a sparkline per project, failures marked below | deploys trend [<project>] [--days 30] [--json]

# heatmap_from <now> <weeks> <project>: stdin is the journal. {weeks, project, from, to, total, failures, max, grid:[[cell|null ×weeks] ×7]}
# where a cell is {day, deploys, failures}; days after today are null.
heatmap_from() {
  jq -cRs --argjson now "$1" --argjson weeks "$2" --arg project "$3" "$INSIGHTS_JQ"'
    ($now / 86400 | floor) as $today
    | (($today + 3) % 7) as $wd
    | ($today - $wd - ($weeks - 1) * 7) as $start
    | lines($now; $weeks * 7 + 7) as $l
    | [ $l[] | select($project == "" or ((.name // "") | tostring) == $project)
        | {d: (.t / 86400 | floor), s: started, f: (.result == "failed")} | select(.d >= $start) ] as $ev
    | ($ev | group_by(.d) | map({key: (.[0].d | tostring), value: {deploys: (map(select(.s)) | length), failures: (map(select(.f)) | length)}}) | from_entries) as $by
    | [ range(0; 7) as $r | [ range(0; $weeks) as $w | ($start + $w * 7 + $r) as $d
          | if $d > $today then null
            else {day: ($d * 86400 | strftime("%Y-%m-%d"))} + ($by[$d | tostring] // {deploys: 0, failures: 0}) end ] ] as $grid
    | {weeks: $weeks, project: (if $project == "" then null else $project end),
       from: ($start * 86400 | strftime("%Y-%m-%d")), to: ($today * 86400 | strftime("%Y-%m-%d")),
       total: ([$grid[][] | select(. != null) | .deploys] | add // 0),
       failures: ([$grid[][] | select(. != null) | .failures] | add // 0),
       max: ([$grid[][] | select(. != null) | .deploys] | max // 0), grid: $grid}'
}

# heatmap_print: stdin is heatmap_from JSON.
heatmap_print() {
  jq -r '
    def glyph($c; $max): if $c.deploys == 0 then "·" else
      (if $max <= 4 then ($c.deploys | if . >= 3 then "▓" elif . == 2 then "▒" else "░" end)
       else (($c.deploys * 4 / $max) | ceil | if . >= 4 then "█" elif . == 3 then "▓" elif . == 2 then "▒" else "░" end) end) end;
    . as $h | ["Mon", "Tue", "Wed", "Thu", "Fri", "Sat", "Sun"] as $names
    | "Deploys per day, \($h.from) to \($h.to) (UTC)\(if $h.project then ", project \($h.project)" else "" end)",
      ( range(0; 7) as $r | "  \($names[$r]) " + ([$h.grid[$r][] | if . == null then " " elif .failures > 0 then "!" else glyph(.; $h.max) end] | join(" ")) ),
      "  · none  ░ few  ▒ some  ▓ many  █ most  ! a failure that day",
      "  \($h.total) deploys, \($h.failures) failures in \($h.weeks) weeks"'
}

x_heatmap_main() {
  local weeks=12 project="" jf now
  while [ "$#" -gt 0 ]; do
    case "$1" in
      --weeks) case "${2:-}" in ''|*[!0-9]*|0) die "--weeks takes a number of weeks, 1 or more" ;; esac; weeks="$2"; shift ;;
      --project) [ -n "${2:-}" ] || die "--project takes a project name"; project="$2"; shift ;;
      *) die "Unknown option $1. Usage: deploys heatmap [--weeks 12] [--project <name>] [--json]" ;;
    esac
    shift
  done
  [ "$weeks" -le 104 ] || die "--weeks: 104 at most"
  jf="$(journal_file)"; now="$(date +%s)"; [ -s "$jf" ] || jf=/dev/null
  if [ "${json:-0}" = 1 ]; then heatmap_from "$now" "$weeks" "$project" < "$jf" | jq .
  else heatmap_from "$now" "$weeks" "$project" < "$jf" | heatmap_print; fi
}

# trend_from <now> <days> <project>: stdin is the journal. {days, rows:[{platform, name, deploys, failures, perDay:[n…], failDays:[0|1…]}]}
# oldest day first; at most 20 rows, the busiest first.
trend_from() {
  jq -cRs --argjson now "$1" --argjson days "$2" --arg project "$3" "$INSIGHTS_JQ"'
    ($now / 86400 | floor) as $today | ($today - $days + 1) as $start
    | [ lines($now; $days + 1)[] | select($project == "" or ((.name // "") | tostring) == $project)
        | {p: (.platform // "" | clean), n: (.name // "" | clean), d: (.t / 86400 | floor), s: started, f: (.result == "failed")}
        | select(.d >= $start and (.s or .f)) ] as $ev
    | { days: $days,
        rows: ($ev | group_by([.p, .n]) | map(. as $g
              | {platform: $g[0].p, name: $g[0].n, deploys: ($g | map(select(.s)) | length), failures: ($g | map(select(.f)) | length),
                 perDay: [range($start; $today + 1) as $d | $g | map(select(.d == $d and .s)) | length],
                 failDays: [range($start; $today + 1) as $d | if ($g | map(select(.d == $d and .f)) | length) > 0 then 1 else 0 end]})
              | sort_by([-.deploys, .name]) | .[0:20]) }'
}

trend_print() {
  jq -r '
    def bar($n; $max): if $n == 0 then "·" else (["▁","▂","▃","▄","▅","▆","▇","█"] | .[((($n * 8 / $max) | ceil) - 1) | if . < 0 then 0 elif . > 7 then 7 else . end]) end;
    "Deploys a day, the last \(.days) days (UTC), oldest first",
    (if (.rows | length) == 0 then "  nothing in the journal for this time" else
      (.rows[] | . as $r | ($r.perDay | max) as $m
       | "  \($r.platform)/\($r.name)  \([$r.perDay[] | bar(.; $m)] | join(""))  \($r.deploys) deploys, \($r.failures) failed",
         (if $r.failures > 0 then "  " + ((($r.platform + "/" + $r.name) | length) * " ") + "  " + ([$r.failDays[] | if . == 1 then "!" else " " end] | join("")) else empty end)) end)'
}

x_trend_main() {
  local days=30 project="" jf now
  while [ "$#" -gt 0 ]; do
    case "$1" in
      --days) case "${2:-}" in ''|*[!0-9]*|0) die "--days takes a number of days, 1 or more" ;; esac; days="$2"; shift ;;
      -*) die "Unknown option $1. Usage: deploys trend [<project>] [--days 30] [--json]" ;;
      *) [ -z "$project" ] || die "Usage: deploys trend [<project>] [--days 30] [--json]"; project="$1" ;;
    esac
    shift
  done
  [ "$days" -le 366 ] || die "--days: 366 at most"
  jf="$(journal_file)"; now="$(date +%s)"; [ -s "$jf" ] || jf=/dev/null
  if [ "${json:-0}" = 1 ]; then trend_from "$now" "$days" "$project" < "$jf" | jq .
  else trend_from "$now" "$days" "$project" < "$jf" | trend_print; fi
}
