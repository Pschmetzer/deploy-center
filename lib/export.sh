# shellcheck shell=bash
# lib/export.sh — `deploys export`: the journal and the Vercel costs as CSV or JSON, with a fixed schema.
#
#   deploys export [--format csv|json] [--what journal|costs|all] [--days 30] [--project <name>] [--out <file|dir>]
#
# Schema (docs/CLI.md, "export"; these columns never change order, new ones are only added at the end):
#   journal  at, platform, name, result, detail            (UTC, as the journal writes them; detail is masked)
#   costs    day, total_usd, build_usd                      (Vercel billing, one row per day; needs Vercel on)
# Keys and tokens in a detail are masked like a log (af_mask). In CSV a cell that starts with = + - @ gets a ' in
# front, so a spreadsheet does not read it as a formula. --out writes the file with mode 0600 (a temp file in the
# same folder, then moved); for --what all with csv, --out is a folder that gets journal.csv and costs.csv.
# Costs are optional: when Vercel is off or its billing cannot be read, costs is null with a reason (json) or has
# no rows (csv), never a failure. --project narrows the journal only (billing is per team). Read-only: the
# journal is read, `deploys costs` is asked for, nothing else. Sourced by deploys after lib/insights.sh.

# export_journal_json <now> <days> <project>: stdin is the journal; a JSON array of rows, details not yet masked.
export_journal_json() {
  jq -cRs --argjson now "$1" --argjson days "$2" --arg project "$3" "$INSIGHTS_JQ"'
    lines($now; $days) | map(select($project == "" or ((.name // "") | tostring) == $project))
    | sort_by(.t) | map({at:(.at | tostring), platform:((.platform // "") | tostring | clean), name:((.name // "") | tostring | clean),
                         result:((.result // "") | tostring | clean), detail:((.detail // "") | clean)})'
}

# export_mask_details: stdin is a rows array; the same array with every detail masked. When the masker changes the
# number of lines (a private key block), no detail is trusted: they are all replaced.
export_mask_details() {
  local rows n masked
  rows="$(cat)"; n="$(jq length <<<"$rows")"
  [ "$n" != 0 ] || { echo '[]'; return 0; }
  masked="$(jq -r '.[].detail' <<<"$rows" | af_mask)" || return 1
  if [ "$(printf '%s\n' "$masked" | wc -l | tr -d ' ')" != "$n" ]; then
    jq -c 'map(.detail = "[not exported]")' <<<"$rows"
  else
    jq -c --rawfile m <(printf '%s\n' "$masked") '. as $r | ($m | split("\n")) as $d | [range(0; $r | length) | $r[.] + {detail:$d[.]}]' <<<"$rows"
  fi
}

# export_costs_json <days>: {rows:[{day,total_usd,build_usd}], reason:null|text}; never fails.
export_costs_json() {
  local d="$1" c
  [ "$d" -le 90 ] || d=90
  if ! { is_enabled vercel && ( vercel_ready ) >/dev/null 2>&1; } 2>/dev/null; then echo '{"rows":[],"reason":"Vercel is off or not set up here, so there are no costs to read"}'; return 0; fi
  c="$("$SELF" costs "$d" 2>/dev/null </dev/null)" || c=""
  jq -c 'if (.days | type) == "array" then {rows:(.days | map({day, total_usd:.total, build_usd:.build})), reason:(if (.missingDays // 0) > 0 then "\(.missingDays) days could not be read" else null end)}
         else error("no days") end' <<<"$c" 2>/dev/null || echo '{"rows":[],"reason":"Vercel billing could not be read"}'
}

# export_csv <header> <columns as JSON>: stdin is a rows array; CSV with the header, formulas neutralised.
export_csv() {
  echo "$1"
  jq -r --argjson cols "$2" '.[] | [.[$cols[]]] | map(. // "" | tostring | if test("^[=+@\t\r-]") then ([39] | implode) + . else . end) | @csv'
}

# export_write <file> <content>: the file with mode 0600, written whole or not at all.
export_write() {
  local f="$1" t
  t="$(umask 077; mktemp "$(dirname "$f")/.export.XXXXXX")" || die "Could not write in $(dirname "$f")."
  printf '%s\n' "$2" > "$t" && chmod 600 "$t" && mv -f "$t" "$f" || { rm -f "$t"; die "Could not write $f."; }
}

export_main() {
  local fmt=csv what=journal days=30 project="" out="" jf now rows costs jcsv ccsv
  while [ "$#" -gt 0 ]; do
    case "$1" in
      --format) case "${2:-}" in csv|json) fmt="$2" ;; *) die "--format takes csv or json" ;; esac; shift ;;
      --what) case "${2:-}" in journal|costs|all) what="$2" ;; *) die "--what takes journal, costs or all" ;; esac; shift ;;
      --days) case "${2:-}" in ''|*[!0-9]*|0) die "--days takes a number of days, 1 or more" ;; esac; days="$2"; shift ;;
      --project) [ -n "${2:-}" ] || die "--project takes a project name"; project="$2"; shift ;;
      --out) [ -n "${2:-}" ] || die "--out takes a file (a folder for --what all with csv)"; out="$2"; shift ;;
      *) die "Unknown option $1. Usage: deploys export [--format csv|json] [--what journal|costs|all] [--days 30] [--project <name>] [--out <file>]" ;;
    esac
    shift
  done
  [ "$days" -le 3650 ] || die "--days: 3650 at most"
  [ "$what" != all ] || [ "$fmt" = json ] || [ -n "$out" ] || die "csv with --what all is two files: give a folder with --out"
  jf="$(journal_file)"; now="$(date +%s)"; rows='[]'; costs='{"rows":[],"reason":null}'
  if [ "$what" != costs ]; then
    if [ -s "$jf" ]; then rows="$(export_journal_json "$now" "$days" "$project" < "$jf" | export_mask_details)" || die "perl is missing, so secrets in the journal cannot be masked; nothing is exported."
    else rows="$(export_journal_json "$now" "$days" "$project" </dev/null)"; fi
  fi
  [ "$what" = journal ] || costs="$(export_costs_json "$days")"
  if [ "$fmt" = json ]; then
    local o
    case "$what" in
      journal) o="$(jq -c '{kind:"deploys-export", schema:1, journal:.}' <<<"$rows")" ;;
      costs) o="$(jq -c '{kind:"deploys-export", schema:1, costs:{rows:.rows, reason:.reason}}' <<<"$costs")" ;;
      *) o="$(jq -cn --argjson j "$rows" --argjson c "$costs" '{kind:"deploys-export", schema:1, journal:$j, costs:$c}')" ;;
    esac
    o="$(jq . <<<"$o")"
    if [ -n "$out" ]; then export_write "$out" "$o"; else printf '%s\n' "$o"; fi
    return 0
  fi
  jcsv="$(export_csv "at,platform,name,result,detail" '["at","platform","name","result","detail"]' <<<"$rows")"
  ccsv="$(jq '.rows' <<<"$costs" | export_csv "day,total_usd,build_usd" '["day","total_usd","build_usd"]')"
  if [ "$what" = all ]; then
    mkdir -p "$out" || die "Could not make the folder $out."
    export_write "$out/journal.csv" "$jcsv"; export_write "$out/costs.csv" "$ccsv"
  elif [ -n "$out" ]; then
    export_write "$out" "$([ "$what" = journal ] && echo "$jcsv" || echo "$ccsv")"
  else
    if [ "$what" = journal ]; then printf '%s\n' "$jcsv"; else printf '%s\n' "$ccsv"; fi
  fi
}
