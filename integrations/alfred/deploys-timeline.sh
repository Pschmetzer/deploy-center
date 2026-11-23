#!/bin/bash
# deploys-timeline.sh — an Alfred Script Filter: what happened in the last 7 days, newest first
# (deploys, failures, rollbacks, forced starts), from `deploys timeline --json`. Read-only: it starts nothing.
#
#   integrations/alfred/deploys-timeline.sh [query]
#
# Every word of the query must be in the project, platform, kind or text. 40 at most.
# ↵ shows the project in Deploy Center (deploycenter://select?project=…); ⌘C copies the line.
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

out="$("$bin" timeline --days 7 --limit 200 --json </dev/null 2>/dev/null)"
jq -e '.entries | arrays' >/dev/null 2>&1 <<<"$out" || say "Could not read the timeline" "Run deploys timeline in a terminal to see why"

jq -c --arg q "$query" '
  ($q | split(" ") | map(select(. != ""))) as $w
  | [.entries[] | select(. as $r | ("\($r.name) \($r.platform) \($r.kind) \($r.detail)" | ascii_downcase) as $hay | all($w[]; . as $x | $hay | contains($x)))] | .[0:40]
  | {cache: {seconds: 30, loose_reload: true},
     items: (if length == 0 then [{title: (if $q == "" then "Nothing happened in the last 7 days" else "No entry matches" end), valid: false}]
             else map({
               skipknowledge: true,
               title: "\(.name) · \(.kind)",
               subtitle: "\(.at | sub("T"; " ") | .[0:16]) · \((.detail // "") | gsub("[[:cntrl:]]"; " "))",
               arg: "deploycenter://select?project=\(.name | @uri)",
               text: {copy: "\(.at) \(.platform):\(.name) \(.kind) \(.detail // "")", largetype: (.detail // "")}
             }) end)}' <<<"$out"
