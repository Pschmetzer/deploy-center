# shellcheck shell=bash disable=SC2034  # failskip, list and the like are read by deploys
# lib/schedule.sh - `deploys schedule daily|off|status` and the nightly-batch filters of deploy-changed and plan
# (--skip-failed, --between). Sourced by deploys; uses job_on, job_off, job_plist, job_missing, die, json and the
# AUTOFIX_* rules and PREVIEW_ROWS from there.

# --skip-failed on the list of deploy-changed and plan: a project whose newest build failed at the
# very commit that would go out now (nothing new since) is left out, so a broken commit is not
# built again every night. A newer commit (a fix) still goes. A failed build whose commit is not
# known is left out too. The left-out rows go to $failskip (PREVIEW_ROWS, action "would-skip").
failskip="[]"
skip_failed() {
  local f="(($AUTOFIX_FAILED or $AUTOFIX_REPORT_ONLY) and ((.latestSha // null) == null or .latestSha == .headSha))"
  failskip="$(echo "$list" | jq -c "[.[] | select($f)] | map(.latestSha // null) as \$ls | ($PREVIEW_ROWS)"' | [to_entries[] | .key as $k
      | .value + {action:"would-skip", reason:(if $ls[$k] then "its last build failed at \($ls[$k][0:7]) and nothing is new since"
                                               else "its last build failed and its commit is not known" end)}]')"
  list="$(echo "$list" | jq -c "[.[] | select($f | not)]")"
}

# --between HH:MM-HH:MM: is the local time now inside it? (17:00-02:00 goes over midnight; the end is not inside.)
# For the scheduled job: launchd starts a missed run when the Mac wakes, and that must not deploy at 09:00.
between_ok() {  # between_ok <HH:MM-HH:MM> [<HHMM now>]
  local a="${1%-*}" b="${1#*-}" now="${2:-$(date +%H%M)}"
  a="${a/:/}"; b="${b/:/}"; a=$((10#$a)); b=$((10#$b)); now=$((10#$now))
  if [ "$a" -le "$b" ]; then [ "$now" -ge "$a" ] && [ "$now" -lt "$b" ]
  else [ "$now" -ge "$a" ] || [ "$now" -lt "$b" ]; fi
}
between_valid() {  # between_valid <text>: HH:MM-HH:MM with real times and two different ends
  [[ "${1:-}" =~ ^([0-2][0-9]):([0-5][0-9])-([0-2][0-9]):([0-5][0-9])$ ]] || return 1
  [ "$((10#${BASH_REMATCH[1]}))" -le 23 ] && [ "$((10#${BASH_REMATCH[3]}))" -le 23 ] && [ "${1%-*}" != "${1#*-}" ]
}

# schedule_main <the words of the command line>: FEA-068, the daily deploy as a launchd job (or the cron line).
schedule_main() {
  # FEA-068: the daily deploy as a launchd job (or the cron line): deploy-changed --yes at a time.
  sf="$CONFIG_DIR/schedule.json"; DAILY_LABEL="app.deploycenter.daily"
  case "${2:-}" in
    daily)
      at="09:00"; extra=(); wkd=""; sd_usage="Usage: deploys schedule daily [HH:MM] [--weekdays] [--when-green [--wait 30m]] [--by-rules] [--strict] [--only <p>]... [--exclude <p>]... [--platform <p>] [--max <n>] [--skip-failed] [--between 03:00-05:00] [--wait-for-window 3h]"
      set -- "${@:3}"
      while [ $# -gt 0 ]; do
        a="$1"
        case "$a" in
          [0-2][0-9]:[0-5][0-9]) [ "$((10#${a%%:*}))" -le 23 ] || die "The time is HH:MM, 00:00 to 23:59."; at="$a" ;;
          --weekdays) wkd=1 ;;
          --when-green|--by-rules|--strict|--skip-failed) extra+=("$a") ;;
          --between) between_valid "${2:-}" || die "--between takes two local times like 03:00-05:00"; extra+=("$a" "$2"); shift ;;
          # The options of deploy-changed that take a value, checked the way it checks them.
          --only|--exclude) [ -n "${2:-}" ] || die "$a takes a project name"; safe_name "$2"; extra+=("$a" "$2"); shift ;;
          --platform) [ -n "${2:-}" ] || die "--platform takes a platform"; is_provider "$2" || die "--platform: \"$2\" is not a platform here"; extra+=("$a" "$2"); shift ;;
          --max) case "${2:-}" in ''|*[!0-9]*|0) die "--max takes a number of projects, 1 or more" ;; esac; extra+=("$a" "$2"); shift ;;
          --wait|--wait-for-window) duration_s "${2:-}" >/dev/null 2>&1 || die "$a takes a time like 30m, 90s or 3h"; extra+=("$a" "$2"); shift ;;
          *) die "$sd_usage" ;;
        esac
        shift
      done
      require_write "schedule daily"
      JOB_WEEKDAYS="$wkd" job_on "$DAILY_LABEL" "@$at" DeployCenter-daily deploy-changed --yes ${extra[@]+"${extra[@]}"}
      jq -n --arg at "$at" --argjson wd "$([ -n "$wkd" ] && echo true || echo false)" --args '{daily:({at:$at, args:$ARGS.positional} + (if $wd then {weekdays:true} else {} end))}' -- ${extra[@]+"${extra[@]}"} > "$sf"
      command -v launchctl >/dev/null 2>&1 && echo "deploy-changed --yes${extra[*]:+ ${extra[*]}} runs every $([ -n "$wkd" ] && echo "weekday (Monday to Friday)" || echo day) at $at (log: ~/Library/Logs/DeployCenter-daily.log)." ;;
    off) job_off "$DAILY_LABEL"; rm -f "$sf"; echo "The daily deploy no longer runs by itself." ;;
    ""|status)
      on=false; [ -f "$(job_plist "$DAILY_LABEL")" ] && command -v launchctl >/dev/null 2>&1 && launchctl print "gui/$(id -u)/$DAILY_LABEL" >/dev/null 2>&1 && on=true
      st="$(jq -c --argjson on "$on" --arg miss "$(job_missing "$DAILY_LABEL")" '.daily + {scheduled:$on, pathMissing:($miss | split(" ") | map(select(. != "")))}' "$sf" 2>/dev/null \
        || echo '{"at":null,"args":[],"scheduled":false,"pathMissing":[]}')"
      if [ "${json:-0}" = 1 ]; then echo "$st"
      else echo "$st" | jq -r 'if .at then "daily at \(.at)\(if (.args | length) > 0 then " (\(.args | join(" ")))" else "" end): \(if .scheduled then "on" else "set, but launchd has no job (deploys schedule daily again)" end)" else "off" end'; fi ;;
    *) die "Usage: deploys schedule daily [HH:MM] [--when-green] [--by-rules] [--strict] | off | status [--json]" ;;
  esac
}
