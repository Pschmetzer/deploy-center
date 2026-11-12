#!/bin/bash
# badge.sh — one SVG status badge per project, e.g. "deployed | 3 d ago · 4 commits waiting".
#
#   integrations/badge/badge.sh [out-dir]              read every project through `deploys`
#   integrations/badge/badge.sh [out-dir] list.json    read a saved list instead (- for stdin)
#
# The list is any JSON array that `deploys` prints for projects: `vercel list --json`,
# `render list --json` (all projects, each with a `changed` field) or `changed --json`
# (only those with changes). Without a list both platform lists are read, so up-to-date
# projects get a badge too. Nothing is deployed, nothing is served: commit the SVGs, put
# them on any static host, or open them locally.
#
# Env: DEPLOYS  the CLI to call (default: deploys on PATH)
set -euo pipefail
DEPLOYS="${DEPLOYS:-deploys}"
# shellcheck source=../lib/projects.sh
. "$(dirname "$0")/../lib/projects.sh"
out="${1:-badges}"
from="${2:-}"
mkdir -p "$out"

if [ -z "$from" ]; then
  list="$(all_projects)"
elif [ "$from" = - ]; then list="$(cat)"
else list="$(cat "$from")"
fi

# name<TAB>right-hand text<TAB>colour, one line per project. Times: seconds since 1970 (UTC).
lines="$(echo "$list" | jq -r '
  def age: (now - .) as $s
    | if $s < 3600 then "\(($s / 60) | floor) min ago"
      elif $s < 86400 then "\(($s / 3600) | floor) h ago"
      else "\(($s / 86400) | floor) d ago" end;
  (map(select(.name) | .name) | group_by(.) | map(select(length > 1) | .[0])) as $twice
  | .[] | select(.name)
  # The commit that is live (Render: liveAt), not the newest attempt, which may have failed.
  | ((.liveAt // .lastAt // 0) | if . > 0 then age else "never" end) as $when
  # The newest build, as the status page reads it: building, or failed (Render: an older one is
  # still live). A failed or running build is never shown as a green "up to date".
  | ((.lastState // "") | ascii_downcase) as $s
  | (if .building or (.phase // "") == "building" then "building"
     elif ($s | test("fail|error")) then "failed" else "" end) as $build
  | (if $build == "building" then "building"
     elif $build == "failed" then "build failed"
     elif .changed then
       (if .pendingCommits then "\(.pendingCommits) commit\(if .pendingCommits == 1 then "" else "s" end) waiting"
        else "changes waiting" end)
     else "up to date" end) as $what
  # A name on two platforms gets the platform in its file name (vercel-web.svg), so one badge
  # does not overwrite the other; every other name keeps <name>.svg.
  | [(if (.name as $n | $twice | index($n)) and .platform then "\(.platform)-\(.name)" else .name end), "\($when) · \($what)",
     (if $build == "failed" then "#e05d44" elif $build == "building" then "#007ec6"
      elif (.liveAt // .lastAt // 0) == 0 then "#9f9f9f" elif .changed then "#dfb317" else "#4c1" end),
     (.platform // "")]
  | @tsv')"

# XML-safe text; a rough width per character (Verdana 11 averages about 6.5 px).
esc() { printf '%s' "$1" | sed -e 's/&/\&amp;/g' -e 's/</\&lt;/g' -e 's/>/\&gt;/g' -e 's/"/\&quot;/g'; }
# Characters, not bytes, whatever the locale (Alpine and CI images often have no UTF-8 one).
width() { local n; n="$(jq -rn --arg s "$1" '$s | length')"; echo $(( n * 65 / 10 + 12 )); }

n=0 written=$'\n'
while IFS=$'\t' read -r name text colour platform; do
  [ -n "$name" ] || continue
  left="deployed"; lw="$(width "$left")"; rw="$(width "$text")"; w=$((lw + rw))
  stem="$(printf '%s' "$name" | tr -c 'A-Za-z0-9._-' '_')"
  # Two projects that come out as the same file (a/b and a_b, or one name on two platforms):
  # the second one gets its platform in front, instead of overwriting the first.
  case "$written" in *$'\n'"$stem"$'\n'*) stem="$(printf '%s' "${platform:-other}" | tr -c 'A-Za-z0-9._-' '_')_$stem" ;; esac
  written="$written$stem"$'\n'
  file="$out/$stem.svg"
  # IDs per badge: several badges inlined in one HTML page must not share a gradient or clip.
  id="$(printf '%s' "$stem" | tr -c 'A-Za-z0-9_-' '_')"
  cat > "$file" <<SVG
<svg xmlns="http://www.w3.org/2000/svg" width="$w" height="20" role="img" aria-label="$(esc "$name"): $left $(esc "$text")">
  <title>$(esc "$name"): $left $(esc "$text")</title>
  <linearGradient id="s-$id" x2="0" y2="100%"><stop offset="0" stop-color="#bbb" stop-opacity=".1"/><stop offset="1" stop-opacity=".1"/></linearGradient>
  <clipPath id="r-$id"><rect width="$w" height="20" rx="3" fill="#fff"/></clipPath>
  <g clip-path="url(#r-$id)">
    <rect width="$lw" height="20" fill="#555"/>
    <rect x="$lw" width="$rw" height="20" fill="$colour"/>
    <rect width="$w" height="20" fill="url(#s-$id)"/>
  </g>
  <g fill="#fff" text-anchor="middle" font-family="Verdana,Geneva,DejaVu Sans,sans-serif" font-size="11">
    <text x="$((lw / 2))" y="14">$left</text>
    <text x="$((lw + rw / 2))" y="14">$(esc "$text")</text>
  </g>
</svg>
SVG
  n=$((n + 1))
done <<< "$lines"
echo "$n badge(s) in $out/"
