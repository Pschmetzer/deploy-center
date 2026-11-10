#!/bin/bash
# bot-only.sh — which projects wait only for dependency updates (every waiting commit is by a bot
# account: Dependabot, Renovate, …). For holding those back from the daily deploy and shipping
# them once a week (dependency-updates-weekly.yml).
#
#   examples/bot-only.sh            {"botOnly":["api"],"other":["app-web"],"unknown":[]}
#   examples/bot-only.sh --hold     also adds the bot-only ones to $DEPLOYS_CONFIG/ignored.json,
#                                   so deploy-changed leaves them out of this run
#   examples/bot-only.sh --only     adds every other project to ignored.json instead
#
# A project whose commits cannot be read counts as "unknown" and is never held back.
# Env: DEPLOYS (default: deploys on PATH), DEPLOYS_CONFIG (for ignored.json)
set -euo pipefail
DEPLOYS="${DEPLOYS:-deploys}"
mode="${1:-}"
case "$mode" in ""|--hold|--only) ;; *) echo "Usage: bot-only.sh [--hold|--only]" >&2; exit 1 ;; esac

rc=0; list="$("$DEPLOYS" changed --json </dev/null)" || rc=$?
jq -e 'type == "array"' >/dev/null 2>&1 <<<"$list" || { echo "deploys changed --json did not answer a list" >&2; exit 1; }
[ "$rc" = 0 ] || echo "Warning: some projects could not be read and are left out." >&2

bot=(); other=(); unknown=()
while IFS=$'\t' read -r name repo sha ref; do
  d=""
  [ -n "$repo" ] && [ -n "$sha" ] && d="$("$DEPLOYS" details "$repo" "$sha" "$ref" </dev/null 2>/dev/null)" || true
  kind="$(jq -r 'if type == "object" and (.commits | type) == "array" and (.commits | length) > 0
                 then (if (.commits | all(.bot == true)) then "bot" else "other" end) else "unknown" end' <<<"${d:-null}" 2>/dev/null || echo unknown)"
  case "$kind" in bot) bot+=("$name") ;; other) other+=("$name") ;; *) unknown+=("$name") ;; esac
done < <(jq -r '.[] | [.name, (.repo // ""), (.lastSha // ""), (.ref // "main")] | @tsv' <<<"$list")

arr() { if [ $# -eq 0 ]; then echo '[]'; else printf '%s\n' "$@" | jq -Rnc '[inputs]'; fi; }
b="$(arr ${bot[@]+"${bot[@]}"})"; o="$(arr ${other[@]+"${other[@]}"})"; u="$(arr ${unknown[@]+"${unknown[@]}"})"
jq -nc --argjson b "$b" --argjson o "$o" --argjson u "$u" '{botOnly:$b, other:$o, unknown:$u}'

[ -n "$mode" ] || exit 0
cfg="${DEPLOYS_CONFIG:?DEPLOYS_CONFIG must name the config folder}"; mkdir -p "$cfg"
ign="$cfg/ignored.json"; [ -f "$ign" ] || echo '[]' > "$ign"
if [ "$mode" = --hold ]; then add="$b"; else add="$(jq -nc --argjson o "$o" --argjson u "$u" '$o + $u')"; fi
jq --argjson a "$add" '(. + $a) | unique' "$ign" > "$ign.t" && mv "$ign.t" "$ign"
