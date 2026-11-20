#!/bin/bash
# stats.sh — three badges about the whole period, not about one project: the failure rate, the estimated saving and
# the time of the last deploy. For a README or a status page. Reads only; deploys nothing, serves nothing.
#
#   integrations/badge/stats.sh [out-dir]                 last 30 days; writes failure-rate, savings, last-deploy (.svg and .json)
#   integrations/badge/stats.sh out --days 7              another period (1 to 365)
#   integrations/badge/stats.sh out --project app-web     only the failure rate of one project (the last deploy and the saving stay global)
#   integrations/badge/stats.sh out --digest d.json --list l.json    read saved JSON (- for stdin on one of them) instead of the CLI
#   integrations/badge/stats.sh out --no-savings          leave the savings badge out (it asks GitHub through `deploys ledger`)
#
# The failure rate is failed / (deploys + failed) over the days, from `deploys digest --json`: green up to 5 %,
# yellow up to 15 %, red above, grey with no deploy in the period. The saving is the estimate of `deploys ledger`
# (builds that did not run since auto-deploy went off, not only this period): "~$12.40 saved", grey when it is
# not known. The last deploy is the newest live time of `deploys list --json`, in UTC: green up to 7 days, yellow up
# to 30, grey older or never. Each badge has a shields.io endpoint JSON next to the SVG.
#
# Env: DEPLOYS  the CLI to call (default: deploys on PATH)
set -euo pipefail
DEPLOYS="${DEPLOYS:-deploys}"
here="$(cd "$(dirname "$0")" && pwd)"
# shellcheck source=svg.sh
. "$here/svg.sh"
# shellcheck source=../lib/projects.sh
. "$here/../lib/projects.sh"

out="badges" days=30 project="" digest_file="" list_file="" savings=1 gotout=0
while [ $# -gt 0 ]; do
  case "$1" in
    --days) days="${2:?--days N}"; shift ;;
    --project) project="${2:?--project NAME}"; shift ;;
    --digest) digest_file="${2:?--digest FILE}"; shift ;;
    --list) list_file="${2:?--list FILE}"; shift ;;
    --no-savings) savings=0 ;;
    -h|--help) sed -n '2,/^set /p' "$0" | sed -e '$d' -e 's/^# \{0,1\}//'; exit 0 ;;
    -*) echo "Unknown option $1. See --help." >&2; exit 1 ;;
    *) [ "$gotout" = 0 ] || { echo "One output folder only." >&2; exit 1; }; out="$1"; gotout=1 ;;
  esac
  shift
done
case "$days" in ''|*[!0-9]*|0) echo "--days takes a number of days, 1 or more." >&2; exit 1 ;; esac
[ "$days" -le 365 ] || { echo "--days: 365 at most." >&2; exit 1; }
[ "$digest_file" != - ] || [ "$list_file" != - ] || { echo "Only one of --digest and --list can read stdin." >&2; exit 1; }
now="${BADGE_NOW:-$(date +%s)}"; case "$now" in ''|*[!0-9]*) echo "BADGE_NOW must be seconds since 1970." >&2; exit 1 ;; esac

readj() { if [ "$1" = - ]; then cat; else cat "$1"; fi; }
nosav=(); [ "$savings" = 1 ] || nosav=(--no-savings)
if [ -n "$digest_file" ]; then dg="$(readj "$digest_file")"
else dg="$("$DEPLOYS" digest --days "$days" --json ${nosav[@]+"${nosav[@]}"} 2>/dev/null </dev/null)" || dg=""; fi
jq -e 'type == "object" and (.deploys | type) == "number"' >/dev/null 2>&1 <<<"${dg:-null}" \
  || { echo "Could not read the digest (deploys digest --days $days --json); no badge written." >&2; exit 1; }
if [ -n "$list_file" ]; then list="$(readj "$list_file")"; else list="$(all_projects)"; fi
jq -e 'type == "array"' >/dev/null 2>&1 <<<"${list:-null}" || { echo "Could not read the project list; no badge written." >&2; exit 1; }
mkdir -p "$out"

# 1. Failure rate: of one project when asked, else of everything.
read -r rate deploys failed <<<"$(jq -r --arg p "$project" '
  (if $p == "" then {d: .deploys, f: .failures} else ([.projects[] | select(.name == $p)] | {d: (map(.deploys) | add // 0), f: (map(.failures) | add // 0)}) end) as $x
  | "\(if $x.d + $x.f == 0 then "none" else ($x.f * 1000 / ($x.d + $x.f) | round / 10) end) \($x.d) \($x.f)"' <<<"$dg")"
if [ "$rate" = none ]; then text="no deploys in $days d"; colour="#6e6e6e"
else
  text="$rate % ($failed of $((deploys + failed)), $days d)"
  # awk compares the decimal; bash has only integers.
  colour="$(awk -v r="$rate" 'BEGIN { print (r <= 5 ? "#2e7d32" : (r <= 15 ? "#9a6700" : "#c0392b")) }')"
fi
write_badge "$out" failure-rate "failure rate" "$text" "$colour"

# 2. Saving (an estimate).
if [ "$savings" = 1 ]; then
  sv="$(jq -r 'if (.savings | type) == "object" then
        (if .savings.usd != null then "~$" + ((.savings.usd * 100 | round) as $c | "\($c / 100 | floor).\(($c % 100) | tostring | if length < 2 then "0" + . else . end)") + " saved"
         else "\(.savings.skippedBuilds) builds skipped" end) + "\t" + (if (.savings.skippedBuilds // 0) > 0 then "#2e7d32" else "#6e6e6e" end)
      else "unknown\t#6e6e6e" end' <<<"$dg")"
  write_badge "$out" savings "saved (estimate)" "${sv%%$'\t'*}" "${sv#*$'\t'}"
fi

# 3. The last deploy: the newest live time of any project, in UTC.
last="$(jq -r '[.[] | select(type == "object") | (.liveAt // .lastAt // 0)] | max // 0' <<<"$list")"
if [ "$last" -gt 0 ]; then
  text="$(jq -nr --argjson t "$last" '$t | strftime("%Y-%m-%d %H:%M UTC")')"
  age=$(( (now - last) / 86400 ))
  if [ "$age" -le 7 ]; then colour="#2e7d32"; elif [ "$age" -le 30 ]; then colour="#9a6700"; else colour="#6e6e6e"; fi
else text="never"; colour="#6e6e6e"; fi
write_badge "$out" last-deploy "last deploy" "$text" "$colour"

echo "$((2 + savings)) badge(s) in $out/"
