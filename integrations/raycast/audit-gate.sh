#!/bin/bash
# audit-gate.sh — `npm audit --omit=dev --audit-level=high`, except for advisories listed in
# audit-allow.txt (one GHSA id per line, "#" comments). An allowed advisory needs a reason there.
# Everything else at high or critical still fails. The allowance goes away by itself when the line
# is deleted; delete it when a patched version exists.
set -euo pipefail
cd "$(dirname "$0")"
allow="$(grep -oE 'GHSA(-[a-z0-9]{4}){3}' audit-allow.txt 2>/dev/null | sort -u || true)"
report="$(npm audit --omit=dev --json 2>/dev/null || true)"
bad="$(jq -r --arg allow "$allow" '
  ($allow | split("\n") | map(select(. != ""))) as $ok
  | [ .vulnerabilities // {} | to_entries[] | .value
      | select(.severity == "high" or .severity == "critical")
      | . as $v
      # a package is covered only when every advisory it carries is allowed (a package that is
      # only "via" another package is judged by that package)
      | ([ .via[] | select(type == "object") | (.url | split("/") | last) ] ) as $ids
      | select(($ids | length) > 0 and ($ids | all(. as $i | $ok | index($i))) | not)
      | select(($ids | length) > 0)
      | "\($v.name) (\($ids | join(", ")))" ] | unique | .[]' <<<"$report")"
if [ -n "$bad" ]; then
  echo "npm audit found high or critical advisories that are not allowed:" >&2
  echo "$bad" >&2
  exit 1
fi
echo "npm audit: no high or critical advisories beyond audit-allow.txt"
