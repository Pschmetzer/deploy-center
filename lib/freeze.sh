# shellcheck shell=bash
# lib/freeze.sh — `deploys freeze`: set and show the deploy window (window.json) without editing JSON.
#
#   deploys freeze [status] [--json]            the closed times, and whether deploys are closed now
#   deploys freeze add <days> <from> [<to>] [--reason "why"]   e.g.  freeze add fri 15:00
#   deploys freeze remove <n>                   take away rule n (the numbers `freeze` shows)
#   deploys freeze import <calendar.ics> [--dry-run]   closed dates from a calendar (all-day and timed events)
#   deploys freeze clear                        no closed times at all
#
# <days>: mon..sun (also full names), a list (fri,sat), a range (mon-fri), weekend, weekdays or daily.
# <from>/<to>: 15, 15:00 or 9:30; <to> is 24:00 when left out. Only the "deny" list of window.json is
# written; its other keys (tz, ...) stay. Sourced by deploys; uses die, atomic_write, file_lock,
# window_json, WINDOW, WINDOW_LINT and json from there. Starts nothing: it only edits a file.

# freeze_time <t>: "9", "09", "9:30", "15:00" to HH:MM (24:00 is the end of the day); fails for anything else.
freeze_time() {
  local t="${1:-}" h m
  case "$t" in
    [0-9]|[0-9][0-9]) h="$t"; m=00 ;;
    [0-9]:[0-9][0-9]|[0-9][0-9]:[0-9][0-9]) h="${t%%:*}"; m="${t##*:}" ;;
    *) return 1 ;;
  esac
  h=$((10#$h)); m=$((10#$m))
  if [ "$h" -eq 24 ] && [ "$m" -eq 0 ]; then echo "24:00"; return 0; fi
  [ "$h" -le 23 ] && [ "$m" -le 59 ] || return 1
  printf '%02d:%02d\n' "$h" "$m"
}

# freeze_day <name>: mon..sun from a day's name (first three letters, any case); fails for anything else.
freeze_day() {
  local d; d="$(printf '%s' "${1:-}" | tr '[:upper:]' '[:lower:]')"
  case "$d" in
    mon|monday|tue|tues|tuesday|wed|wednesday|thu|thur|thurs|thursday|fri|friday|sat|saturday|sun|sunday) echo "${d:0:3}" ;;
    *) return 1 ;;
  esac
}

# freeze_days <spec>: the days of a rule as a JSON array ([] means every day).
freeze_days() {
  local spec a b days="mon tue wed thu fri sat sun" list="" part
  spec="$(printf '%s' "${1:-}" | tr '[:upper:]' '[:lower:]')"
  case "$spec" in
    daily|all|every|everyday) echo '[]'; return 0 ;;
    weekend|weekends) echo '["sat","sun"]'; return 0 ;;
    weekday|weekdays) echo '["mon","tue","wed","thu","fri"]'; return 0 ;;
    "") return 1 ;;
  esac
  local parts=()
  IFS=, read -r -a parts <<<"$spec"
  for part in "${parts[@]}"; do
    case "$part" in
      *-*)
        a="$(freeze_day "${part%%-*}")" && b="$(freeze_day "${part#*-}")" || return 1
        # A range may wrap past Sunday (fri-mon).
        local seq=() started="" d
        for d in $days $days; do
          [ -n "$started" ] || [ "$d" = "$a" ] && started=1
          [ -z "$started" ] || seq+=("$d")
          [ -z "$started" ] || [ "$d" != "$b" ] || break
        done
        for d in "${seq[@]}"; do list="$list $d"; done ;;
      *) a="$(freeze_day "$part")" || return 1; list="$list $a" ;;
    esac
  done
  # In week order, once each.
  local picked=() d
  for d in $days; do case " $list " in *" $d "*) picked+=("$d") ;; esac; done
  [ "${#picked[@]}" -gt 0 ] || return 1
  printf '%s\n' "${picked[@]}" | jq -Rsc 'split("\n") | map(select(. != ""))'
}

# freeze_add_json <window.json text> <days json> <from> <to> <reason>: the file with one more deny rule.
freeze_add_json() {
  jq -c --argjson days "$2" --arg from "$3" --arg to "$4" --arg reason "$5" '
    (if type == "object" then . else error("not an object") end)
    | .deny = ((.deny // []) + [ ({from:$from, to:$to}
        + (if ($days | length) > 0 then {days:$days} else {} end)
        + (if $reason != "" then {reason:$reason} else {} end)) ])' <<<"$1"
}

# freeze_remove_json <window.json text> <n>: the file without rule n (1-based); fails when there is none.
freeze_remove_json() {
  jq -c --argjson n "$2" '
    if (.deny // [] | length) < $n or $n < 1 then error("no such rule") else .deny |= (to_entries | map(select(.key != ($n - 1)) | .value)) end' <<<"$1"
}

# freeze_view <window.json text or empty> <window_json answer>: status as JSON.
freeze_view() {
  local file="${1:-}" w="$2"
  [ -n "$file" ] || file='{}'
  jq -nc --argjson f "$file" --argjson w "$w" --arg path "$WINDOW" '
    {file:$path, configured:($w.configured // false), closedNow:($w.denied // false), reason:($w.reason // null),
     now:($w.now // null), tz:($f.tz // null),
     rules:(($f.deny // []) | to_entries | map({n:(.key + 1), days:(.value.days // null), from:(.value.from // "00:00"),
        to:(.value.to // "24:00"), reason:(.value.reason // null)} + (if .value.dates then {dates:.value.dates} else {} end)))}'
}

# freeze_ics_events <file>: "<start>\t<end>\t<summary>\t<repeats 0|1>" per event. Folded lines are joined, CRLF dropped.
freeze_ics_events() {
  awk '
    { sub(/\r$/, "") }
    /^[ \t]/ { if (n > 0) line[n] = line[n] substr($0, 2); next }
    { line[++n] = $0 }
    END {
      for (i = 1; i <= n; i++) {
        l = line[i]; u = toupper(l)
        if (u == "BEGIN:VEVENT") { s = ""; e = ""; t = ""; r = 0; inev = 1; continue }
        if (u == "END:VEVENT") { if (inev && s != "") printf "%s\t%s\t%s\t%d\n", s, e, t, r; inev = 0; continue }
        if (!inev) continue
        c = index(l, ":"); if (c == 0) continue
        key = toupper(substr(l, 1, c - 1)); val = substr(l, c + 1); sub(/;.*/, "", key)
        if (key == "DTSTART") s = val; else if (key == "DTEND") e = val
        else if (key == "SUMMARY") { gsub(/\\[nN,;]/, " ", val); gsub(/\t/, " ", val); t = val }
        else if (key == "RRULE" || key == "RDATE") r = 1
      }
    }' "$1"
}

# freeze_ics_rules <events TSV> <today YYYY-MM-DD>: deny rules (JSON array). All-day events close their days (the end is
# exclusive); a timed event of one day closes those hours; a longer one, or one in UTC (Z), closes whole days: the
# calendar's zone is not window.json's, so the safe side wins. Events that ended before today and repeating events are left out.
freeze_ics_rules() {
  jq -Rsc --arg today "$2" '
    def iso: "\(.[0:4])-\(.[4:6])-\(.[6:8])";
    def days($a; $b): [range(($a + "T00:00:00Z" | fromdateiso8601); ($b + "T00:00:00Z" | fromdateiso8601); 86400) | strftime("%Y-%m-%d")];
    [split("\n")[] | select(. != "") | split("\t")
     | select((.[3] // "0") == "0" and (.[0] | test("^[0-9]{8}(T[0-9]{6}Z?)?$")))
     | (.[0]) as $s | (.[1] // "") as $e | (.[2] // "") as $t
     | ($s | length > 8) as $timed | ($s | endswith("Z")) as $utc
     | ($s[0:8] | iso) as $sd
     | (if ($e | test("^[0-9]{8}")) then ($e[0:8] | iso) else "" end) as $ed
     | (if $timed then
          (if $ed == "" or $ed == $sd or ($ed > $sd and $e[9:13] == "0000" and false) then [$sd] else days($sd; $ed) + [$ed] end)
        else (if $ed > $sd then days($sd; $ed) else [$sd] end) end) as $d
     | ($d | .[0:366]) as $dd
     | select(($dd | last) >= $today)
     | {dates:$dd}
       + (if $timed and ($utc | not) and ($dd | length) == 1 then {from:"\($s[9:11]):\($s[11:13])", to:(if $ed == $sd then "\($e[9:11]):\($e[11:13])" else "24:00" end)} else {} end)
       + (if ($t | gsub("[\u0000-\u001f]"; "") | .[0:120]) != "" then {reason:($t | gsub("[\u0000-\u001f]"; "") | .[0:120])} else {} end)
     | select((.from // "") != (.to // "") or .from == null)]' <<<"$1"
}

freeze_print() {  # stdin: freeze_view JSON
  jq -r '
    def days: if .days == null then "every day" else (.days | join(",")) end;
    (if (.rules | length) == 0 then "No closed times set. Deploys are allowed at any time.\nClose one: deploys freeze add fri 15:00"
     else "Closed times (\(.file)):",
          (.rules[] | "  \(.n). \(if .dates then (.dates | if length > 3 then "\(.[0]) … \(.[-1]) (\(length) days)" else join(",") end) else days end) \(.from)-\(.to)\(if .reason then "  (\(.reason))" else "" end)"),
          (if .closedNow then "Closed now: \(.reason). Deploys need --force \"why\"." else "Open now." end) end)'
}

freeze_main() {
  local sub="${1:-status}" cur="" w
  [ "$#" -eq 0 ] || shift
  case "$sub" in
    status|show|list)
      [ "$#" -eq 0 ] || die "Usage: deploys freeze [status] [--json]"
      [ -f "$WINDOW" ] && { cur="$(jq -c . "$WINDOW" 2>/dev/null)" || die "$WINDOW could not be read (see docs/SAFE-DEPLOY.md for the format)"; }
      w="$(window_json)" || exit 2
      if [ "${json:-0}" = 1 ]; then freeze_view "$cur" "$w"; else freeze_view "$cur" "$w" | freeze_print; fi ;;
    add)
      local spec="${1:-}" from="${2:-}" to="" reason="" days f t
      [ -n "$spec" ] && [ -n "$from" ] || die "Usage: deploys freeze add <days> <from> [<to>] [--reason \"why\"]  (for example: freeze add fri 15:00)"
      shift 2
      if [ "$#" -gt 0 ] && [ "${1:0:1}" != - ]; then to="$1"; shift; fi
      while [ "$#" -gt 0 ]; do
        case "$1" in
          --reason) [ "$#" -ge 2 ] || die "--reason needs the reason"; reason="$2"; shift ;;
          --reason=*) reason="${1#--reason=}" ;;
          *) die "Unknown option $1. Usage: deploys freeze add <days> <from> [<to>] [--reason \"why\"]" ;;
        esac
        shift
      done
      days="$(freeze_days "$spec")" || die "\"$spec\" is no day: use mon..sun, a list (fri,sat), a range (mon-fri), weekend, weekdays or daily"
      f="$(freeze_time "$from")" || die "\"$from\" is no time: use 15, 15:00 or 9:30"
      t="24:00"; [ -z "$to" ] || t="$(freeze_time "$to")" || die "\"$to\" is no time: use 15, 15:00 or 9:30"
      [ "$f" != "$t" ] || die "from and to are the same time: that closes nothing (or everything). Leave <to> out to close until midnight."
      reason="$(printf '%s' "$reason" | tr -d '\000-\037' | cut -c1-120)"
      freeze_write add "$days" "$f" "$t" "$reason"
      echo "Closed: $(jq -r 'if length == 0 then "every day" else join(",") end' <<<"$days") $f-$t${reason:+ ($reason)}"
      freeze_main status ;;
    import)
      local ics="${1:-}" dry=0 tsv rules before
      [ -n "$ics" ] || die "Usage: deploys freeze import <calendar.ics> [--dry-run]"
      shift; [ "${1:-}" != --dry-run ] || { dry=1; shift; }
      [ "$#" -eq 0 ] || die "Usage: deploys freeze import <calendar.ics> [--dry-run]"
      [ -f "$ics" ] && [ -r "$ics" ] || die "Usage: deploys freeze import <calendar.ics>: $ics was not found"
      [ "$(wc -c < "$ics")" -le 5000000 ] || die "$ics is too big for a calendar of closed days (5 MB at most)"
      grep -qi '^BEGIN:VCALENDAR' "$ics" || die "$ics is no calendar (.ics): no BEGIN:VCALENDAR. Nothing was changed."
      tsv="$(freeze_ics_events "$ics")"
      rules="$(freeze_ics_rules "$tsv" "$(now_parts | cut -d' ' -f3)")" || die "$ics could not be read as a calendar. Nothing was changed."
      before="$( [ -f "$WINDOW" ] && jq -c '.deny // []' "$WINDOW" 2>/dev/null || echo '[]')"
      rules="$(jq -c --argjson b "$before" '[.[] | select(. as $r | ($b | map(del(.reason)) | index($r | del(.reason))) == null)] | reduce .[] as $r ([]; if (map(del(.reason)) | index($r | del(.reason))) == null then . + [$r] else . end)' <<<"$rules")"
      local nrep; nrep="$(printf '%s\n' "$tsv" | awk -F'\t' '$4 == 1' | wc -l | tr -d ' ')"
      [ "$nrep" = 0 ] || echo "Left out: $nrep repeating event(s) (RRULE): add those days by hand with deploys freeze add."
      echo "$(jq length <<<"$rules") new closed time(s) from $ics."
      if [ "$dry" = 1 ] || [ "$(jq length <<<"$rules")" = 0 ]; then jq -r '.[] | "  \(.dates | join(",")) \(.from // "")-\(.to // "")  \(.reason // "")"' <<<"$rules"; return 0; fi
      freeze_write import "$rules"
      freeze_main status ;;
    remove|rm)
      case "${1:-}" in ''|*[!0-9]*) die "Usage: deploys freeze remove <n>  (the numbers deploys freeze shows)" ;; esac
      [ -f "$WINDOW" ] || die "No closed times set ($WINDOW)."
      freeze_write remove "$1"
      freeze_main status ;;
    clear)
      [ "$#" -eq 0 ] || die "Usage: deploys freeze clear"
      if [ ! -f "$WINDOW" ]; then echo "No closed times set."; return 0; fi
      freeze_write clear
      freeze_main status ;;
    *) die "Usage: deploys freeze [status] [--json] | add <days> <from> [<to>] [--reason \"why\"] | import <calendar.ics> [--dry-run] | remove <n> | clear" ;;
  esac
}

# freeze_write add <days json> <from> <to> <reason> | remove <n> | clear: window.json under a lock, all or nothing.
freeze_write() {
  local op="$1" cur='{}' new locked=""
  file_lock "$WINDOW" && locked=1
  if [ -f "$WINDOW" ]; then
    cur="$(jq -c . "$WINDOW" 2>/dev/null)" || { [ -z "$locked" ] || file_unlock "$WINDOW"; die "$WINDOW could not be read: not changed (see docs/SAFE-DEPLOY.md for the format)"; }
  fi
  case "$op" in
    # `|| new=""`: a jq error must reach the message below, not end the script under set -e.
    add) new="$(freeze_add_json "$cur" "$2" "$3" "$4" "$5" 2>/dev/null)" || new="" ;;
    remove) new="$(freeze_remove_json "$cur" "$2" 2>/dev/null)" || new="" ;;
    clear) new="$(jq -c '.deny = []' <<<"$cur" 2>/dev/null)" || new="" ;;
    import) new="$(jq -c --argjson r "$2" '(if type == "object" then . else error("not an object") end) | .deny = ((.deny // []) + $r)' <<<"$cur" 2>/dev/null)" || new="" ;;
  esac
  if [ -z "${new:-}" ]; then
    [ -z "$locked" ] || file_unlock "$WINDOW"
    case "$op" in remove) die "There is no rule $2 (deploys freeze shows the numbers)" ;; *) die "$WINDOW is not a JSON object: not changed" ;; esac
  fi
  jq . <<<"$new" | atomic_write "$WINDOW" || { [ -z "$locked" ] || file_unlock "$WINDOW"; die "Could not write $WINDOW"; }
  [ -z "$locked" ] || file_unlock "$WINDOW"
}
