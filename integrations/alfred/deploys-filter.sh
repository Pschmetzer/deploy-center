#!/bin/bash
# deploys-filter.sh — an Alfred Script Filter: what is waiting, building or failed, from
# `deploys status --json`. Read-only: it deploys nothing.
#
#   integrations/alfred/deploys-filter.sh [query]
#
# ↵ shows the project in Deploy Center (deploycenter://select?project=…), ⌘↵ opens its site
# (the arg is "open <name>" for deploys-open.sh). Set up in Alfred: a Script Filter (bash,
# "with input as argv") that runs this file with "$1", then an Open URL action for ↵ and a Run
# Script action with deploys-open.sh for ⌘. See README.md.
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
[ -n "$bin" ] && command -v "$bin" >/dev/null 2>&1 || say "deploys not found" "Install Deploy Center, or set DEPLOYS in the workflow's environment"

# `status --json` exits 1 when some project could not be read; the list it printed still counts.
out="$("$bin" status --json </dev/null 2>/dev/null)"
jq -e 'type == "array"' >/dev/null 2>&1 <<<"$out" || say "Could not read the projects" "Run deploys status in a terminal to see why"

jq -c --arg q "$query" '
  def failed: (.state // "") | test("error|fail"; "i");
  map(select($q == "" or (.name | ascii_downcase | contains($q))))
  | map(. + {rank: (if .building then 0 elif failed then 1 elif .changed then 2 else 3 end)})
  | sort_by(.rank, .name)
  | {items: (if length == 0 then [{title: "No project matches", valid: false}] else map({
      uid: "\(.platform)/\(.name)",
      title: .name,
      subtitle: ((if .building then "Building" elif failed then "Newest deploy failed (\(.state))" elif .changed then "Changes waiting" else "Up to date" end) + " · \(.platform)"),
      arg: "deploycenter://select?project=\(.name | @uri)",
      autocomplete: .name,
      mods: {cmd: {arg: "open \(.name)", subtitle: "Open the site"}}
    }) end)}' <<<"$out"
