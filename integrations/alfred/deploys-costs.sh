#!/bin/bash
# deploys-costs.sh — an Alfred Script Filter: what Vercel charged this month and which projects cost
# the most, from `deploys costs 31`. Read-only: it starts nothing.
#
#   integrations/alfred/deploys-costs.sh [query]
#
# The first item is this month's sum ("$12.35 this month"), then one item per project of the last
# 7 days with its price and, where the count is known, the price of one build. ↵ shows the project in
# Deploy Center (deploycenter://select?project=vercel:…). Vercel's charges only: other platforms have
# no costs view. The numbers come from Vercel's billing API; Alfred keeps the answer for 5 minutes.
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

# `costs` reads one billing call per day: slow, so Alfred keeps the answer (and refreshes it in the background).
out="$("$bin" costs 31 </dev/null 2>/dev/null)"
jq -e 'type == "object" and (.months | type == "array") and (.projects | type == "array")' >/dev/null 2>&1 <<<"$out" \
  || say "Could not read the costs" "Run deploys costs in a terminal to see why (Vercel must be on)"

jq -c --arg q "$query" '
  # Two decimals always: $1.20, not $1.2.
  def usd: if . == null then "?" else (. * 100 | round) as $c | "$\($c / 100 | floor).\(if ($c % 100) < 10 then "0" else "" end)\($c % 100)" end;
  (now | strftime("%Y-%m")) as $m
  | (.months | map(select(.month == $m)) | .[0]) as $cur
  | {cache: {seconds: 300, loose_reload: true},
     items: (
      [ if $cur then
          {title: "\($cur.total | usd) this month",
           subtitle: ("Vercel charges in \($m)" + (if $cur.build != null then " · builds \($cur.build | usd)" else "" end)
                      + (if (.missingDays // 0) > 0 then " · \(.missingDays) days could not be read, a floor" else "" end)),
           valid: false}
        else {title: "No charges read for this month yet", subtitle: "Vercel charges, last 31 days", valid: false} end ]
      + ( .projects | map(select($q == "" or (.name | ascii_downcase | contains($q))))
          | map({
              uid: "vercel/\(.name)",
              skipknowledge: true,
              title: .name,
              subtitle: ("\(.build | usd), last 7 days"
                         + (if (.builds // 0) > 0 then " · \(.builds) build\(if .builds == 1 then "" else "s" end), about \(.build / .builds | usd) each" else "" end)),
              arg: "deploycenter://select?project=\("vercel:\(.name)" | @uri)",
              autocomplete: .name }) ) )}' <<<"$out"
