#!/bin/bash
# deploys-plan.sh — an Alfred Script Filter: what the next deploy would start and what it would
# cost, from `deploys plan --json`. Read-only: it starts nothing. The numbers are an estimate.
#
#   integrations/alfred/deploys-plan.sh [query]
#
# The first item is the sum ("3 builds, about $1.20"), then one item per project. ↵ shows the
# project in Deploy Center (deploycenter://select?project=…), where a deploy asks first.
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

# `plan --json` exits 1 when the list could not be read completely; what it printed still counts.
out="$("$bin" plan --json </dev/null 2>/dev/null)"
jq -e 'type == "object" and (.projects | type == "array")' >/dev/null 2>&1 <<<"$out" || say "Could not work out the plan" "Run deploys plan in a terminal to see why"

jq -c --arg q "$query" '
  def usd: if . == null then "?" else "$\(. * 100 | round / 100)" end;
  def skipped: .action == "would-skip" or .action == "held-by-rule";
  (.total) as $t
  | {items: (
      [ {title: (if $t.builds == 0 then "Nothing would start" else "\($t.builds) build\(if $t.builds == 1 then "" else "s" end), about \($t.usd | usd)" end),
         subtitle: ("Estimate for the next deploy" + (if ($t.unpriced // 0) > 0 then " · \($t.unpriced) without a price" else "" end)),
         valid: false} ]
      + ( .projects | map(select($q == "" or (.name | ascii_downcase | contains($q))))
          | map({
              uid: "\(.platform)/\(.name)",
              title: .name,
              subtitle: ((if skipped then "Would not start" else "about \(.usd | usd)" end) + " · \(.platform)"),
              arg: "deploycenter://select?project=\("\(.platform):\(.name)" | @uri)",
              autocomplete: .name }) ) )}' <<<"$out"
