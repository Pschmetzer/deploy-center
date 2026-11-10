#!/bin/bash
# Sourced by the integrations: every project, on every provider that is on and set up, as one
# JSON array.
#
# That is `deploys list --json`: each entry is what `deploys <p> list --json` prints, plus
# `platform`. `changed` is the CLI's own rule. Which providers are read (and that Render is read
# only with a key) is decided by the CLI. A provider that cannot be read is left out here: the
# integrations show what is known, and `deploys changed` is where an unread project is an error.
#
# Env: DEPLOYS  the CLI to call (default: deploys on PATH)
DEPLOYS="${DEPLOYS:-deploys}"

all_projects() {
  local out
  out="$("$DEPLOYS" list --json 2>/dev/null </dev/null)" || true
  jq -c 'if type=="array" then . else [] end' <<<"${out:-[]}" 2>/dev/null || echo '[]'
}

# What `deploys changed --json` lists: changed, and not left out with `deploys ignore`.
changed_projects() {
  local ign="${DEPLOYS_CONFIG:-$HOME/.config/deploys}/ignored.json" i='[]'
  [ -f "$ign" ] && i="$(jq -c 'if type=="array" then . else [] end' "$ign" 2>/dev/null || echo '[]')"
  all_projects | jq --argjson ign "$i" 'map(select(.changed and ((.name as $n | $ign | index($n)) | not)))'
}
