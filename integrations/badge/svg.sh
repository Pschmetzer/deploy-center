#!/bin/bash
# Sourced by stats.sh: write_badge <dir> <stem> <label> <message> <colour> draws <stem>.svg and the shields.io endpoint
# <stem>.json (schemaVersion 1). The look is the one of badge.sh: white text on colours that reach 4.5:1 (WCAG AA).

# XML-safe text.
badge_esc() { printf '%s' "$1" | tr -d '\000-\010\013\014\016-\037\177' | sed -e 's/&/\&amp;/g' -e 's/</\&lt;/g' -e 's/>/\&gt;/g' -e 's/"/\&quot;/g'; }
# Characters, not bytes, whatever the locale: a rough 6.5 px each (Verdana 11) plus padding.
badge_width() { local n; n="$(jq -rn --arg s "$1" '$s | length')"; echo $(( n * 65 / 10 + 12 )); }

write_badge() {  # write_badge <dir> <stem> <label> <message> <colour like #2e7d32>
  local dir="$1" stem="$2" left="$3" text="$4" colour="$5" lw rw w id iserr=false
  lw="$(badge_width "$left")"; rw="$(badge_width "$text")"; w=$((lw + rw))
  id="$(printf '%s' "$stem" | tr -c 'A-Za-z0-9_-' '_')"
  cat > "$dir/$stem.svg" <<SVG
<svg xmlns="http://www.w3.org/2000/svg" width="$w" height="20" role="img" aria-label="$(badge_esc "$left"): $(badge_esc "$text")">
  <title>$(badge_esc "$left"): $(badge_esc "$text")</title>
  <linearGradient id="s-$id" x2="0" y2="100%"><stop offset="0" stop-color="#bbb" stop-opacity=".1"/><stop offset="1" stop-opacity=".1"/></linearGradient>
  <clipPath id="r-$id"><rect width="$w" height="20" rx="3" fill="#fff"/></clipPath>
  <g clip-path="url(#r-$id)">
    <rect width="$lw" height="20" fill="#555"/>
    <rect x="$lw" width="$rw" height="20" fill="$colour"/>
    <rect width="$w" height="20" fill="url(#s-$id)"/>
  </g>
  <g fill="#fff" text-anchor="middle" font-family="Verdana,Geneva,DejaVu Sans,sans-serif" font-size="11">
    <text x="$((lw / 2))" y="14">$(badge_esc "$left")</text>
    <text x="$((lw + rw / 2))" y="14">$(badge_esc "$text")</text>
  </g>
</svg>
SVG
  [ "$colour" != "#c0392b" ] || iserr=true
  jq -n --arg l "$left" --arg m "$text" --arg c "${colour#\#}" --argjson e "$iserr" \
    '{schemaVersion: 1, label: $l, message: $m, color: $c, labelColor: "555555", cacheSeconds: 300} + (if $e then {isError: true} else {} end)' > "$dir/$stem.json"
}
