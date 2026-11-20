#!/bin/bash
# deploys-rollback.sh — an Alfred Script Filter: what a rollback would do, from `deploys history --json`.
# Read-only: it rolls nothing back. A rollback is done in Deploy Center (or the CLI), which asks first.
#
#   integrations/alfred/deploys-rollback.sh [query]
#
# Type part of a name: the matching projects, Tab completes "name ". With the name and a space
# ("web "), the first item is "Now: <commit> · <state>", the second "Would go back to: <commit> · <state>"
# (the newest earlier deploy that went live), then the newest deploys. ↵ shows the project in Deploy Center.
#
# Env: DEPLOYS  the CLI (default: the app bundle, then deploys on PATH)
set -uo pipefail
export PATH="$PATH:/opt/homebrew/bin:/usr/local/bin"
raw="${1:-}"
query="$(printf '%s' "$raw" | tr '[:upper:]' '[:lower:]' | sed 's/^[[:space:]]*//')"

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

list="$("$bin" list --json </dev/null 2>/dev/null)"
jq -e 'type == "array"' >/dev/null 2>&1 <<<"$list" || say "Could not read the projects" "Run deploys list in a terminal to see why"

# "web " (a name and a space): the preview of that project. A name on two platforms is shown as platform:name.
name="${query%% }"
if [ "$name" != "$query" ] && [[ "$name" =~ ^[a-z0-9._:-]+$ ]]; then
  ref="$(jq -r --arg n "$name" '
    (map(select((.name | ascii_downcase) == $n or ("\(.platform):\(.name)" | ascii_downcase) == $n))) as $m
    | if ($m | length) == 1 then "\($m[0].platform):\($m[0].name)" else empty end' <<<"$list")"
  [ -n "$ref" ] || say "No single project called $name" "Use platform:name when a name is on two platforms"
  hist="$("$bin" history "$ref" 5 --json </dev/null 2>/dev/null)"
  jq -e 'type == "array" and length > 0' >/dev/null 2>&1 <<<"$hist" || say "No deploys to show for $ref" "Run deploys history $ref in a terminal to see why"
  jq -c --arg ref "$ref" '
    def line: [((.commit // "") | .[0:7]), (.state // ""), (.when // "")] | map(select(. != "")) | join(" · ");
    def live: (.state // "") | test("^(ready|live|succe|success|active)"; "i");
    (.[0]) as $cur
    | (.[1:] | map(select(live)) | .[0]) as $tgt
    | "deploycenter://select?project=\($ref | @uri)" as $url
    | {items: (
        [ {title: "Now: \($cur | line)", subtitle: "The newest deploy of \($ref)", arg: $url}
        , (if $tgt then {title: "Would go back to: \($tgt | line)", subtitle: "Nothing is rolled back here; ↵ shows it in Deploy Center, which asks first", arg: $url}
           else {title: "No earlier deploy that went live in the newest five", subtitle: "A rollback has nothing to go back to", arg: $url} end) ]
        + (map({title: line, subtitle: "Newest deploys, current first", arg: $url})) )}' <<<"$hist"
  exit 0
fi

jq -c --arg q "$query" '
  {cache: {seconds: 30, loose_reload: true}, items: (map(select($q == "" or (.name | ascii_downcase | contains($q)) or ("\(.platform):\(.name)" | ascii_downcase | contains($q))))
    | map({
        uid: "\(.platform)/\(.name)",
        title: .name,
        subtitle: "\(.platform) · Tab, then see what a rollback would do",
        arg: "deploycenter://select?project=\("\(.platform):\(.name)" | @uri)",
        skipknowledge: true,
        autocomplete: "\(.name) " }))}' <<<"$list"
