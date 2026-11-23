# shellcheck shell=bash
# lib/prepare.sh — `deploys prepare`: a conditional morning job that gets a deploy READY and starts it only when you said so.
#
#   deploys prepare on [HH:MM] [--weekdays] [--when-green] [--no-freeze] [--yes] [deploy-changed filters...]
#   deploys prepare off | status [--json] | show [--json] | run
#
# Each run checks its conditions: with --no-freeze it does nothing inside a closed deploy window (no --force, ever); with
# --when-green only commits whose CI passed count. What would start is saved in prepared.json (config folder) and shown
# by `deploys prepare show`, with the one command that starts it. Without --yes stored in the entry NOTHING is started,
# also not "silently". With --yes the run goes on to `deploy-changed --yes` with the same filters. Sourced by deploys;
# uses job_on/job_off (launchd, or the cron line), atomic_write, window_json, require_write, SELF, CONFIG_DIR.

PREPARE_FILE="$CONFIG_DIR/prepare.json"     # the entry: {at, weekdays, whenGreen, noFreeze, yes, args}
PREPARED_FILE="$CONFIG_DIR/prepared.json"   # the last run: {at, state, rows, command}
PREPARE_LABEL="app.deploycenter.prepare"

# prepare_decide <conditions JSON> <frozen true|false> <rows JSON>: what a run does. Pure.
# state: frozen (nothing is done), nothing (nothing waits), prepared (saved, not started), start (--yes stored).
prepare_decide() {
  jq -nc --argjson c "$1" --argjson frozen "$2" --argjson rows "$3" '
    ([ $rows[] | select(.action == "would-deploy") ]) as $go
    | if ($c.noFreeze and $frozen) then {state:"frozen", rows:[]}
      elif ($go | length) == 0 then {state:"nothing", rows:[]}
      else {state:(if $c.yes then "start" else "prepared" end), rows:$go} end'
}

prepare_args() {  # prepare_args <entry JSON>: the deploy-changed options, one per line
  jq -r '(if .whenGreen then ["--when-green"] else [] end) + .args | .[]' <<< "$1"
}

prepare_main() {
  local cmd="${1:-status}"; [ "$#" -eq 0 ] || shift
  case "$cmd" in
    on) prepare_on "$@" ;;
    off) require_write "prepare off"; job_off "$PREPARE_LABEL"; rm -f "$PREPARE_FILE"; echo "The prepared deploy no longer runs by itself." ;;
    run) prepare_run ;;
    show)
      [ -f "$PREPARED_FILE" ] || { echo "Nothing prepared yet."; return 0; }
      if [ "${json:-0}" = 1 ]; then jq . "$PREPARED_FILE"
      else jq -r '"Last run \(.at): \(.state)", (.rows[]? | "  \(.platform)/\(.name)  \(.commits // "?") commits"), (if .state == "prepared" then "To start it: \(.command)" else empty end)' "$PREPARED_FILE"; fi ;;
    status)
      if [ ! -f "$PREPARE_FILE" ]; then if [ "${json:-0}" = 1 ]; then echo '{"scheduled":false}'; else echo "No prepared deploy is scheduled (deploys prepare on 08:30 --when-green --no-freeze)."; fi; return 0; fi
      if [ "${json:-0}" = 1 ]; then jq '. + {scheduled:true}' "$PREPARE_FILE"
      else jq -r '"Every \(if .weekdays then "weekday" else "day" end) at \(.at): get a deploy ready\(if .whenGreen then ", only green commits" else "" end)\(if .noFreeze then ", not in a closed window" else "" end); \(if .yes then "STARTS it (--yes stored)" else "starts nothing (you start it)" end)."' "$PREPARE_FILE"; fi ;;
    *) die "Usage: deploys prepare on [HH:MM] [--weekdays] [--when-green] [--no-freeze] [--yes] [--only <p>]... [--exclude <p>]... | off | status | show | run" ;;
  esac
}

prepare_on() {
  local at="08:30" wkd=false green=false nofreeze=false yes=false a args=()
  while [ "$#" -gt 0 ]; do
    a="$1"
    case "$a" in
      [0-2][0-9]:[0-5][0-9]) [ "$((10#${a%%:*}))" -le 23 ] || die "The time is HH:MM, 00:00 to 23:59."; at="$a" ;;
      --weekdays) wkd=true ;; --when-green) green=true ;; --no-freeze) nofreeze=true ;; --yes) yes=true ;;
      --only|--exclude) [ -n "${2:-}" ] || die "$a takes a project name"; safe_name "$2"; args+=("$a" "$2"); shift ;;
      --platform) [ -n "${2:-}" ] || die "--platform takes a platform"; is_provider "$2" || die "--platform: \"$2\" is not a platform here"; args+=("$a" "$2"); shift ;;
      --max) case "${2:-}" in ''|*[!0-9]*|0) die "--max takes a number of projects, 1 or more" ;; esac; args+=("$a" "$2"); shift ;;
      *) die "Unknown option $a. Usage: deploys prepare on [HH:MM] [--weekdays] [--when-green] [--no-freeze] [--yes] [--only <p>]..." ;;
    esac
    shift
  done
  require_write "prepare on"
  jq -nc --arg at "$at" --argjson wd "$wkd" --argjson g "$green" --argjson nf "$nofreeze" --argjson y "$yes" --args \
    '{at:$at, weekdays:$wd, whenGreen:$g, noFreeze:$nf, yes:$y, args:$ARGS.positional}' -- ${args[@]+"${args[@]}"} \
    | atomic_write "$PREPARE_FILE" || die "Could not write $PREPARE_FILE."
  JOB_WEEKDAYS="$([ "$wkd" = true ] && echo 1)" job_on "$PREPARE_LABEL" "@$at" DeployCenter-prepare prepare run
  prepare_main status
}

prepare_run() {
  [ -f "$PREPARE_FILE" ] || die "No prepared deploy is set up: deploys prepare on 08:30 --when-green --no-freeze"
  local entry frozen=false args=() line rows dec state cmd
  entry="$(cat "$PREPARE_FILE")"
  while IFS= read -r line; do [ -z "$line" ] || args+=("$line"); done < <(prepare_args "$entry")
  [ "$(window_json | jq -r .denied)" != true ] || frozen=true
  rows="$("$SELF" deploy-changed --json ${args[@]+"${args[@]}"} 2>/dev/null | jq -c 'if type == "array" then . else [] end' 2>/dev/null)" || rows='[]'
  [ -n "$rows" ] || rows='[]'
  dec="$(prepare_decide "$entry" "$frozen" "$rows")"; state="$(jq -r .state <<<"$dec")"
  cmd="deploys deploy-changed --yes ${args[*]-}"
  jq -nc --argjson d "$dec" --arg at "$(date -u +%Y-%m-%dT%H:%M:%SZ)" --arg c "$cmd" '$d + {at:$at, command:$c}' | atomic_write "$PREPARED_FILE" || true
  case "$state" in
    frozen) echo "The deploy window is closed: nothing was prepared or started." ;;
    nothing) echo "Nothing waits that matches: nothing was prepared." ;;
    prepared) echo "Prepared $(jq '.rows | length' <<<"$dec") deploy(s), nothing was started. See: deploys prepare show. Start: $cmd" ;;
    start)
      require_write "prepare run (--yes stored)"
      "$SELF" deploy-changed --yes ${args[@]+"${args[@]}"} ;;
  esac
}
