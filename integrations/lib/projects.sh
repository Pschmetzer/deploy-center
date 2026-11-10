#!/bin/bash
# Sourced by the integrations: every project, both platforms, as one JSON array.
#
# Each entry is what `deploys vercel list --json` / `deploys render list --json` print, plus
# `platform`. `changed` is the CLI's own rule. Render is read only when a key is there: in
# the environment (RENDER_API_KEY) or, on a Mac, as `deploys doctor` reports it. (Without one,
# `deploys render list --json` does not come back; see integrations/README.md.)
#
# Env: DEPLOYS  the CLI to call (default: deploys on PATH)
DEPLOYS="${DEPLOYS:-deploys}"

has_render_key() {
  [ -n "${RENDER_API_KEY:-}" ] && return 0
  "$DEPLOYS" doctor 2>/dev/null | jq -e '.renderKey == true' >/dev/null 2>&1
}

all_projects() {
  local v r='[]'
  v="$("$DEPLOYS" vercel list --json 2>/dev/null </dev/null)" || v='[]'
  if has_render_key; then r="$("$DEPLOYS" render list --json 2>/dev/null </dev/null)" || r='[]'; fi
  jq -n --argjson v "$(jq -c 'if type=="array" then . else [] end' <<<"$v" 2>/dev/null || echo '[]')" \
        --argjson r "$(jq -c 'if type=="array" then . else [] end' <<<"$r" 2>/dev/null || echo '[]')" \
    '($v | map(. + {platform:"vercel"})) + ($r | map(. + {platform:"render"}))'
}

# What `deploys changed --json` lists: changed, and not left out with `deploys ignore`.
changed_projects() {
  local ign="${DEPLOYS_CONFIG:-$HOME/.config/deploys}/ignored.json" i='[]'
  [ -f "$ign" ] && i="$(jq -c 'if type=="array" then . else [] end' "$ign" 2>/dev/null || echo '[]')"
  all_projects | jq --argjson ign "$i" 'map(select(.changed and ((.name as $n | $ign | index($n)) | not)))'
}
