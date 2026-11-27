# shellcheck shell=bash
# lib/morning.sh — `deploys morning`: what happened overnight, as a few lines, a text file and one notification.
#
#   deploys morning [--hours 24] [--json] [--no-notify] [--no-file] [--offline]
#   deploys morning schedule on [HH:MM] | off | status [--json]     (launchd, 08:00 by default; off until turned on)
#
# From what this Mac already has: the journal (deployed, failed), prs-state.json of `deploys prs` (merged),
# autofix.json (handed to the routine), and `deploys changed` (still waiting; --offline leaves it out). Reads
# only; starts nothing. The text goes to $CONFIG_DIR/morning/<date>.txt (the newest 30 are kept) and one line to
# af_notify (the Mac notification, and DEPLOYS_NOTIFY_CMD when you set one). Sourced by deploys; uses
# journal_file, af_notify, af_state, job_on, job_off, job_plist, atomic_write, SELF, die and json from there.
MORNING_LABEL="app.deploycenter.morning"
MORNING_KEEP=30

# morning_from <now> <hours> <prs state JSON> <autofix state JSON> <waiting JSON or null>; stdin: the journal.
morning_from() {
  jq -cRs --argjson now "$1" --argjson h "$2" --argjson prs "$3" --argjson af "$4" --argjson w "$5" '
    def ts: (.at // "" | tostring | sub("\\.[0-9]+Z$"; "Z") | try fromdateiso8601 catch null);
    def clean: tostring | gsub("[\\x00-\\x1f\\x7f]"; " ") | .[0:160];
    def started: (.result == "live") or (.result == "other" and ((.detail // "") | tostring | test("^Started")));
    ($now - $h * 3600) as $since
    | [ split("\n")[] | fromjson? | select(type == "object") | . + {t: ts} | select(.t != null and .t >= $since and .t <= $now) ] as $l
    | {hours:$h, since:($since | todate), until:($now | todate),
       deployed:($l | map(select(started)) | map({name:(.name // "" | clean), platform:(.platform // "" | clean)}) | unique),
       failed:($l | map(select(.result == "failed")) | sort_by(-.t)
         | map({name:(.name // "" | clean), platform:(.platform // "" | clean), detail:((.detail // "") | clean)}) | unique_by(.name + .platform)),
       merged:([($prs.events // [])[] | select(.kind == "merge" and .result == "merged" and (.at // 0) >= $since)
         | {repo:(.repo // "" | clean), pr:(.pr // null), title:((.title // "") | clean)}] | unique_by(.repo + "#" + (.pr | tostring))),
       autofix:([($af.fires // [])[] | select((.at // 0) >= $since and (.status // "") == "fired") | (.project // "" | clean)] as $f
         | {handedOver:($f | length), projects:($f | unique)}),
       waiting:(if $w == null then null
         else [$w[] | {name:(.name // "" | clean), platform:(.platform // "" | clean), commits:(.pendingCommits // null)}] end)}'
}

# morning_text: stdin is morning JSON; the lines of the report.
morning_text() {
  jq -r '
    def names: map(.name) | join(", ");
    "Deploy Center, the last \(.hours) hours (until \(.until[0:16] | sub("T"; " ")) UTC)",
    "  Deployed: \(.deployed | length)\(if (.deployed | length) > 0 then " (\(.deployed | names))" else "" end)",
    "  Failed: \(.failed | length)", (.failed[] | "    \(.name) (\(.platform)): \(.detail)"),
    "  Merged PRs: \(.merged | length)", (.merged[] | "    \(.repo)#\(.pr) \(.title)"),
    "  Handed to autofix: \(.autofix.handedOver)\(if .autofix.handedOver > 0 then " (\(.autofix.projects | join(", ")))" else "" end)",
    (if .waiting == null then "  Still waiting: not read (offline, or the platforms could not be asked)"
     else "  Still waiting: \(.waiting | length)", (.waiting[] | "    \(.name) (\(.platform))\(if .commits then ", \(.commits) commits" else "" end)") end)'
}

# morning_line: stdin is morning JSON; the one line of the notification.
morning_line() {
  jq -r '"\(.deployed | length) deployed, \(.failed | length) failed, \(.merged | length) PRs merged"
    + (if .waiting == null then "" else ", \(.waiting | length) waiting" end)
    + (if .autofix.handedOver > 0 then ", \(.autofix.handedOver) to autofix" else "" end)'
}

morning_dir() { echo "$CONFIG_DIR/morning"; }

morning_schedule() {
  case "${1:-status}" in
    on)
      local at="${2:-08:00}"
      case "$at" in [0-2][0-9]:[0-5][0-9]) [ "$((10#${at%%:*}))" -le 23 ] || die "The time is HH:MM, 00:00 to 23:59." ;; *) die "The time is HH:MM, 00:00 to 23:59." ;; esac
      require_write "morning schedule"
      job_on "$MORNING_LABEL" "@$at" DeployCenter-morning morning
      command -v launchctl >/dev/null 2>&1 && echo "The morning report runs every day at $at (file: $(morning_dir)/<date>.txt, log: ~/Library/Logs/DeployCenter-morning.log)." ;;
    off) job_off "$MORNING_LABEL"; echo "The morning report no longer runs by itself." ;;
    status)
      local on=false at=null
      [ -f "$(job_plist "$MORNING_LABEL")" ] && command -v launchctl >/dev/null 2>&1 && launchctl print "gui/$(id -u)/$MORNING_LABEL" >/dev/null 2>&1 && on=true
      [ -f "$(job_plist "$MORNING_LABEL")" ] && at="$(sed -n 's|.*<key>Hour</key><integer>\([0-9]*\)</integer><key>Minute</key><integer>\([0-9]*\)</integer>.*|\1 \2|p' "$(job_plist "$MORNING_LABEL")" | head -n 1 | awk '{printf "\"%02d:%02d\"", $1, $2}')"
      [ -n "$at" ] || at=null
      if [ "${json:-0}" = 1 ]; then jq -n --argjson on "$on" --argjson at "$at" '{scheduled:$on, at:$at}'
      elif [ "$on" = true ]; then echo "on, every day at $(echo "$at" | tr -d '"')"; else echo off; fi ;;
    *) die "Usage: deploys morning schedule on [HH:MM] | off | status [--json]" ;;
  esac
}

morning_main() {
  local hours=24 notify=1 file=1 offline=0 now w="null" out txt f d
  [ "${1:-}" != schedule ] || { shift; morning_schedule "$@"; return; }
  while [ "$#" -gt 0 ]; do
    case "$1" in
      --hours) case "${2:-}" in ''|*[!0-9]*|0|????*) die "--hours takes a number of hours, 1 to 999" ;; esac; hours="$2"; shift ;;
      --no-notify) notify=0 ;;
      --no-file) file=0 ;;
      --offline) offline=1 ;;
      *) die "Unknown option $1. Usage: deploys morning [--hours 24] [--json] [--no-notify] [--no-file] [--offline] | schedule on [HH:MM]|off|status" ;;
    esac
    shift
  done
  log_rotate DeployCenter-morning
  now="$(date +%s)"
  if [ "$offline" = 0 ]; then
    # What still waits: the same list as `deploys changed`. When it cannot be read, the report still comes, without it.
    w="$("$SELF" changed --json 2>/dev/null </dev/null)" || w=""
    jq -e 'type == "array"' <<<"${w:-x}" >/dev/null 2>&1 || w="null"
  fi
  d="$(prs_state 2>/dev/null)" || d='{}'; jq -e 'type == "object"' <<<"$d" >/dev/null 2>&1 || d='{}'
  f="$(af_state 2>/dev/null)" || f='{"fires":[]}'; jq -e 'type == "object"' <<<"$f" >/dev/null 2>&1 || f='{"fires":[]}'
  local jf; jf="$(journal_file)"
  if [ -s "$jf" ]; then out="$(morning_from "$now" "$hours" "$d" "$f" "$w" < "$jf")"; else out="$(morning_from "$now" "$hours" "$d" "$f" "$w" < /dev/null)"; fi
  txt="$(morning_text <<<"$out")"
  if [ "$file" = 1 ]; then
    mkdir -p "$(morning_dir)"
    printf '%s\n' "$txt" | atomic_write "$(morning_dir)/$(date +%Y-%m-%d).txt"
    # The newest MORNING_KEEP reports stay.
    local old n=0
    for old in $(printf '%s\n' "$(morning_dir)"/[0-9][0-9][0-9][0-9]-[0-9][0-9]-[0-9][0-9].txt | sort -r); do
      n=$((n + 1)); [ "$n" -le "$MORNING_KEEP" ] || rm -f "$old"
    done
  fi
  if [ "${json:-0}" = 1 ]; then jq . <<<"$out"; else printf '%s\n' "$txt"; fi
  if [ "$notify" = 1 ]; then ( af_notify "Morning: $(morning_line <<<"$out")" >/dev/null ); fi
  return 0
}
