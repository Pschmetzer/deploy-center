#!/bin/bash
# Sourced by the integrations: every project, on every provider that is on and set up, as one
# JSON array.
#
# That is `deploys list --json`: each entry is what `deploys <p> list --json` prints, plus
# `platform`. `changed` is the CLI's own rule. Which providers are read (and that Render is read
# only with a key) is decided by the CLI. A provider that cannot be read is left out, with a
# warning on stderr. When no list can be read at all, all_projects prints [] and returns 1: an
# empty list must never stand for "nothing waiting" (the callers run with set -e and stop).
#
# Env: DEPLOYS  the CLI to call (default: deploys on PATH)
DEPLOYS="${DEPLOYS:-deploys}"

all_projects() {
  local out rc=0 err
  err="$(mktemp)"
  out="$("$DEPLOYS" list --json 2>"$err" </dev/null)" || rc=$?
  if jq -e 'type=="array"' <<<"${out:-null}" >/dev/null 2>&1; then
    [ "$rc" = 0 ] || echo "Warning: deploys list could not read every provider; the list may be short. $(tail -n 1 "$err")" >&2
    rm -f "$err"
    jq -c . <<<"$out"
    return 0
  fi
  echo "Error: deploys list --json gave no list (exit $rc). $(tail -n 1 "$err")" >&2
  rm -f "$err"
  echo '[]'
  return 1
}

# The names left out with `deploys ignore`, as a JSON array.
ignored_names() {
  local ign="${DEPLOYS_CONFIG:-$HOME/.config/deploys}/ignored.json"
  if [ -f "$ign" ]; then jq -c 'if type=="array" then . else [] end' "$ign" 2>/dev/null || echo '[]'; else echo '[]'; fi
}

# What `deploys changed --json` lists: changed, and not left out with `deploys ignore`.
changed_projects() {
  local all
  all="$(all_projects)" || return 1
  jq --argjson ign "$(ignored_names)" 'map(select(.changed and ((.name as $n | $ign | index($n)) | not)))' <<<"$all"
}
