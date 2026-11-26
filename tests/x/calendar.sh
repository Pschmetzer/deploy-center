#!/bin/bash
# deploys calendar (lib/x-calendar.sh): the closed times of window.json as .ics.
. "$(dirname "$0")/lib.sh"
DEPLOYS_LIB=1 . ./deploys 2>/dev/null; set +e
now=1790000000   # Monday 2026-09-21 14:13 UTC
w='{"deny":[{"days":["fri"],"from":"15:00"},{"from":"22:00","to":"06:00","reason":"night, nobody; \"awake\""},{"dates":["2026-12-24"]}],"tz":"Europe/Berlin"}'
ics="$(calendar_from "$now" 14 Europe/Berlin <<<"$w")"
expect "ics: starts and ends the calendar" "$(printf '%s' "$ics" | tr -d '\r' | sed -n '1p;$p' | paste -sd,)" "BEGIN:VCALENDAR,END:VCALENDAR"
expect "ics: CRLF line ends" "$(printf '%s' "$ics" | head -n 1 | od -An -c | grep -c '\\r')" "1"
n="$(printf '%s' "$ics" | tr -d '\r' | grep -c '^BEGIN:VEVENT')"
expect "ics: two Fridays and fourteen nights" "$n" "16"
has "ics: a TZID" "$ics" "DTSTART;TZID=Europe/Berlin:"
has "ics: the night rule runs over midnight" "$(printf '%s' "$ics" | tr -d '\r' | grep -A1 -m1 'T220000$' | tail -n 1)" "DTEND;TZID=Europe/Berlin:"
has "ics: reason is escaped" "$ics" 'night\, nobody\; "awake"'
expect "ics: a date rule outside the range makes no event" "$(printf '%s' "$ics" | grep -c '1224')" "0"
long="$(calendar_from "$now" 120 "" <<<"$w" | tr -d '\r' | grep -c '^DTSTART:20261224T000000$')"
expect "ics: a date rule inside the range, floating time" "$long" "1"
expect "ics: no window, no events" "$(calendar_from "$now" 5 "" </dev/null | tr -d '\r' | grep -c VEVENT)" "0"
expect "ics: the Friday event starts 15:00 and ends 24:00 (next day 00:00)" "$(calendar_from "$now" 14 "" <<<'{"deny":[{"days":["fri"],"from":"15:00"}]}' | tr -d '\r' | grep -E '^DT(START|END)' | head -2 | paste -sd,)" "DTSTART:20260925T150000,DTEND:20260926T000000"
cli calendar --days 0 >/dev/null 2>&1; expect "cli: --days 0 refused" "$?" "1"
printf '%s' "$w" > "$DEPLOYS_CONFIG/window.json"
has "cli: writes a file" "$(cli calendar --days 7 --out "$tmp/c.ics")" "Wrote $tmp/c.ics"
has "cli: the file is a calendar" "$(head -c 15 "$tmp/c.ics")" "BEGIN:VCALENDAR"
printf 'not json' > "$DEPLOYS_CONFIG/window.json"; cli calendar >/dev/null 2>&1; expect "cli: a broken window.json is named" "$?" "1"
exit "$fails"
