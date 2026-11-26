# shellcheck shell=bash
# lib/x-calendar.sh — `deploys calendar`: the closed times of the deploy window as an .ics calendar file.
#
#   deploys calendar [--days 30] [--out <file>]
#
# Reads the "deny" rules of window.json (the same file `deploys freeze` edits) and writes one event per closed
# period for the next --days days (default 30, at most 366): "Deploys closed" with the reason or the rule as its text.
# The times are the window's own local times (with its "tz" as TZID when it has one; else floating times). Import it
# into a calendar, or serve it, so a team sees the freezes next to its other plans. `deploys freeze import` reads
# such a file the other way. Without --out the file goes to the terminal; --out writes it atomically.
# Read-only for the deploy side: nothing is deployed or changed. Sourced by deploys; uses WINDOW, atomic_write, die.
# x-command: calendar | the closed times of the deploy window (window.json) as an .ics file for the next days | deploys calendar [--days 30] [--out <file>]

# calendar_from <now> <days> <tz or "">: stdin is window.json (or empty). The calendar, lines separated by newlines.
calendar_from() {
  jq -rs --argjson now "$1" --argjson days "$2" --arg tz "$3" '
    def esc: gsub("\\\\"; "\\\\") | gsub(";"; "\\;") | gsub(","; "\\,") | gsub("[\\r\\n]+"; " ");
    def hm($t): ($t | split(":") | (.[0] | tonumber) * 60 + (.[1] | tonumber));
    def stamp($d; $min): ($d * 86400 + $min * 60 | strftime("%Y%m%dT%H%M%S"));
    ["mon","tue","wed","thu","fri","sat","sun"] as $wn
    | (.[0] // {}) as $w | ($w.deny // []) as $deny | ($now / 86400 | floor) as $today
    | ($now | strftime("%Y%m%dT%H%M%SZ")) as $dtstamp
    | (if $tz != "" then ";TZID=" + $tz else "" end) as $z
    | [ range(0; $days) as $o | ($today + $o) as $d | ($d * 86400 | strftime("%Y-%m-%d")) as $date | $wn[($d + 3) % 7] as $wd
        | $deny | to_entries[] | . as $e | $e.value as $r
        | select(($r | type) == "object")
        | select(if ($r.dates // null) != null then (($r.dates | index($date)) != null) else true end)
        | select(if ($r.days // null) != null and (($r.days | length) > 0) then (($r.days | index($wd)) != null) else true end)
        | (hm($r.from // "00:00")) as $a | (hm($r.to // "24:00")) as $b
        | { uid: "freeze-\($e.key + 1)-\($date)@deploy-center.invalid",
            start: stamp($d; $a), end: (if $b > $a then stamp($d; $b) else stamp($d + 1; $b) end),
            text: ($r.reason // "closed by the deploy window") } ] as $ev
    | ( "BEGIN:VCALENDAR", "VERSION:2.0", "PRODID:-//Deploy Center//deploys calendar//EN", "CALSCALE:GREGORIAN",
        ( $ev[] | "BEGIN:VEVENT", "UID:\(.uid)", "DTSTAMP:\($dtstamp)", "DTSTART\($z):\(.start)", "DTEND\($z):\(.end)",
          "SUMMARY:Deploys closed", "DESCRIPTION:\(.text | esc | .[0:120])", "TRANSP:OPAQUE", "END:VEVENT" ),
        "END:VCALENDAR" )' | sed 's/$/\r/'
}

x_calendar_main() {
  local days=30 out="" tz="" f src
  while [ "$#" -gt 0 ]; do
    case "$1" in
      --days) case "${2:-}" in ''|*[!0-9]*|0) die "--days takes a number of days, 1 or more" ;; esac; days="$2"; shift ;;
      --out) [ -n "${2:-}" ] || die "--out takes a file name"; out="$2"; shift ;;
      *) die "Unknown option $1. Usage: deploys calendar [--days 30] [--out <file>]" ;;
    esac
    shift
  done
  [ "$days" -le 366 ] || die "--days: 366 at most"
  f="${WINDOW:-$CONFIG_DIR/window.json}"; src=/dev/null
  if [ -s "$f" ]; then
    jq -e 'type == "object"' "$f" >/dev/null 2>&1 || die "$f is not a JSON object: deploys freeze shows what is wrong"
    src="$f"; tz="$(jq -r '.tz // "" | if test("^[A-Za-z0-9_+/-]{1,64}$") then . else "" end' "$f")"
  fi
  if [ -n "$out" ]; then
    calendar_from "$(date +%s)" "$days" "$tz" < "$src" | atomic_write "$out" || die "Could not write $out"
    echo "Wrote $out (the closed times of the next $days days)."
  else
    calendar_from "$(date +%s)" "$days" "$tz" < "$src"
  fi
}
