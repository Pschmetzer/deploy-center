# shellcheck shell=bash
# lib/notes.sh — `deploys streak` and `deploys note`.
#
#   deploys streak [--days 90] [--project <name>] [--json]   deploys in a row without a failure, per project (read only)
#   deploys note <project> "text" [--json]                   one line in the journal ("note"); it shows in `deploys timeline`
#
# streak reads the journal like `deploys digest`: a "deploy" is a line with the result live or a journaled
# start, a failure is "failed"; the current streak is the number of deploys since the last failure.
# note writes one line to the local journal (nothing on a platform is touched, so observer mode may use it).
# A text that looks like a secret (the mask of `deploys autofix`) is refused, not written masked, so a
# journal line never says something other than what was typed. Sourced by deploys; uses journal_file,
# journal_add, af_mask, die and the INSIGHTS_JQ of lib/insights.sh.

# streak_from <now> <days> <project>: stdin is the journal.
streak_from() {
  jq -cRs --argjson now "$1" --argjson days "$2" --arg project "$3" "$INSIGHTS_JQ"'
    lines($now; $days) as $l
    | [ $l[] | select(started or .result == "failed") | select($project == "" or ((.name // "") | tostring) == $project) ]
    | group_by([(.platform // ""), (.name // "")])
    | map(sort_by(.t) as $s
        | (reduce $s[] as $e ({cur: 0, best: 0, deploys: 0, failures: 0, lastFail: null};
            if $e.result == "failed" then .cur = 0 | .failures += 1 | .lastFail = $e.t
            else .cur += 1 | .deploys += 1 | .best = ([.best, .cur] | max) end)) as $r
        | {name:($s[0].name // "" | clean), platform:($s[0].platform // "" | clean), deploys:$r.deploys, failures:$r.failures,
           current:$r.cur, longest:$r.best, lastFailure:(if $r.lastFail == null then null else ($r.lastFail | todate) end)})
    | sort_by(-.current, .name) as $p
    | {days:$days, project:(if $project == "" then null else $project end), projects:$p[0:50],
       bestCurrent:($p[0] // null)}'
}

streak_print() {  # stdin is streak JSON
  jq -r '
    "Deploys in a row without a failure, last \(.days) day\(if .days == 1 then "" else "s" end)\(if .project then " for " + .project else "" end)",
    (if (.projects | length) == 0 then "  No deploys in the journal for this time."
     else .projects[] | "  \(.name) (\(.platform)): \(.current) now, longest \(.longest) (\(.deploys) deploy\(if .deploys == 1 then "" else "s" end), \(.failures) failed\(if .lastFailure then ", last failure " + .lastFailure[0:10] else "" end))" end)'
}

streak_main() {
  local days=90 project="" jf now out
  while [ "$#" -gt 0 ]; do
    case "$1" in
      --days) case "${2:-}" in ''|*[!0-9]*|0) die "--days takes a number of days, 1 or more" ;; esac; days="$2"; shift ;;
      --project) [ -n "${2:-}" ] || die "--project takes a project name"; project="$2"; shift ;;
      *) die "Unknown option $1. Usage: deploys streak [--days 90] [--project <name>] [--json]" ;;
    esac
    shift
  done
  [ "$days" -le 3650 ] || die "--days: 3650 at most"
  jf="$(journal_file)"; now="$(date +%s)"
  if [ -s "$jf" ]; then out="$(streak_from "$now" "$days" "$project" < "$jf")"; else out="$(streak_from "$now" "$days" "$project" < /dev/null)"; fi
  if [ "${json:-0}" = 1 ]; then jq . <<<"$out"; else streak_print <<<"$out"; fi
}

# note_text <text...>: the text as one clean line (control characters to spaces, 200 characters at most), or fail.
note_text() {
  local t masked
  t="$(printf '%s' "$*" | tr '[:cntrl:]' ' ' | sed 's/  */ /g; s/^ //; s/ $//')"
  [ -n "$t" ] || { echo "Error: the note is empty" >&2; return 1; }
  [ "${#t}" -le 200 ] || { echo "Error: a note is 200 characters at most (this one has ${#t})" >&2; return 1; }
  masked="$(printf '%s\n' "$t" | af_mask)" || return 1
  [ "$masked" = "$t" ] || { echo "Error: the note looks like it holds a secret (a key, token or password); it was not written" >&2; return 1; }
  printf '%s' "$t"
}

note_main() {
  local name="${1:-}" text
  [ "$#" -ge 2 ] || die "Usage: deploys note <project> \"text\""
  shift
  case "$name" in *[!A-Za-z0-9._:/@-]*|'') die "A project name has letters, digits and . _ : / @ - only" ;; esac
  text="$(note_text "$*")" || exit 1
  journal_add cli "$name" note "$text"
  if [ "${json:-0}" = 1 ]; then jq -nc --arg n "$name" --arg t "$text" '{ok:true, name:$n, note:$t}'; else echo "Noted for $name: $text"; fi
}
