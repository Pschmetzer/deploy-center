#!/bin/bash
# deploys-guard.sh — an Alfred Script Filter: is the guard on, what it did last, the running allowances,
# and whether deploys are closed now (the deploy freeze). From `deploys guard status --json` and
# `deploys freeze --json`. Read-only: it never runs the guard and starts nothing.
#
#   integrations/alfred/deploys-guard.sh [query]
#
# Env: DEPLOYS  the CLI (default: the app bundle, then deploys on PATH)
set -uo pipefail
export PATH="$PATH:/opt/homebrew/bin:/usr/local/bin"
query="$(printf '%s' "${1:-}" | tr '[:upper:]' '[:lower:]')"

bin="${DEPLOYS:-}"
if [ -z "$bin" ]; then
  for c in "/Applications/Deploy Center.app/Contents/Resources/deploys" "$HOME/Applications/Deploy Center.app/Contents/Resources/deploys"; do
    [ -x "$c" ] && { bin="$c"; break; }
  done
  [ -n "$bin" ] || bin="$(command -v deploys 2>/dev/null)"
fi
say() { jq -nc --arg t "$1" --arg s "$2" '{items:[{title:$t, subtitle:$s, valid:false}]}'; exit 0; }
command -v jq >/dev/null 2>&1 || { printf '{"items":[{"title":"jq is missing","subtitle":"brew install jq","valid":false}]}\n'; exit 0; }
if [ -z "$bin" ] || ! command -v "$bin" >/dev/null 2>&1; then
  say "deploys not found" "Install Deploy Center, or set DEPLOYS in the workflow's environment"
fi

g="$("$bin" guard status --json </dev/null 2>/dev/null)"
jq -e 'type == "object" and (.enabled | type == "boolean")' >/dev/null 2>&1 <<<"$g" || say "Could not read the guard" "Run deploys guard status in a terminal to see why"
# The freeze is a second, local read: when it fails the guard still shows.
f="$("$bin" freeze --json </dev/null 2>/dev/null)"
jq -e 'type == "object" and (.closedNow | type == "boolean")' >/dev/null 2>&1 <<<"$f" || f='null'

jq -c --arg q "$query" --argjson f "$f" '
  def ago($t): (now - $t) as $s | if $s < 3600 then "\([($s / 60 | floor), 1] | max) min ago" elif $s < 86400 then "\($s / 3600 | floor) h ago" else "\($s / 86400 | floor) d ago" end;
  def left($t): ($t - now) as $s | if $s <= 0 then "expired" elif $s < 3600 then "\([($s / 60 | floor), 1] | max) min left" else "\($s / 3600 | floor) h left" end;
  [ {title: (if .enabled then "Guard is on" else "Guard is off" end),
     subtitle: (if .enabled then "Every 30 minutes; " + (if .lastRun then "last run \(ago(.lastRun))\(if .lastDry then " (dry run)" else "" end)" else "has not run yet" end)
                else "Auto-deploy is not checked on a schedule" end)} ]
  + (if (.pathMissing | length) > 0 then [{title: "The scheduled job cannot find a tool", subtitle: "\(.pathMissing | join(", ")) not on its PATH. In a terminal: deploys guard schedule on"}] else [] end)
  + (if .firstRunPending then [{title: "The first run only reports", subtitle: "It changes nothing before you have seen what it would do"}] else [] end)
  + [ .lastActions[]? | {title: "\(.action) \(.project // "")" | rtrimstr(" "), subtitle: (if .error then "failed: \(.error)" else (.platform // "") end)} ]
  + [ .allowances[]? | {title: "Allowance: \(.project)", subtitle: "\(.platform) · \(left(.expiresAt))"} ]
  + (if $f == null then [] else
      [ {title: (if $f.closedNow then "Deploys are closed now" elif $f.configured then "Deploy window is open" else "No closed times (deploy freeze)" end),
         subtitle: (if $f.closedNow then "\($f.reason // "closed time"). A deploy needs --force with a reason." else "deploys freeze shows and sets the closed times" end)} ]
      + [ $f.rules[]? | {title: "\((.days // ["every day"]) | join(",")) \(.from // "00:00")-\(.to // "24:00")", subtitle: "Closed time \(.n)\(if .reason then " · \(.reason)" else "" end)"} ] end)
  | map(select($q == "" or ("\(.title) \(.subtitle)" | ascii_downcase | contains($q))) + {valid: false})
  | {cache: {seconds: 30, loose_reload: true}, items: (if length == 0 then [{title: "Nothing matches", valid: false}] else . end)}' <<<"$g"
