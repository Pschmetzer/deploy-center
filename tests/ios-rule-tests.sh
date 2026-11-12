#!/bin/bash
# "Waiting" is decided twice: by `deploys` (CHANGED_RULE) and by the iPhone app (PhoneProject.changed).
# Both run here through the same cases (tests/fixtures/changed-rule/cases.json); ios/App/Clients.swift
# (and LogMask.swift, which it uses) is compiled along on macOS so a change there that breaks without UIKit shows. A case marked
# "known": "ios: ..." is a difference the iPhone app still has; it is reported, not failed.
set -euo pipefail
cd "$(dirname "$0")/.."
cases=tests/fixtures/changed-rule/cases.json
fails=0

echo "--- the script's rule"
rule="$(DEPLOYS_LIB=1 DEPLOYS_CONFIG="$(mktemp -d)" bash -c '. ./deploys >/dev/null 2>&1; printf "%s" "$CHANGED_RULE"')"
[ -n "$rule" ] || { echo "FAIL CHANGED_RULE not found in deploys"; exit 1; }
# The script's names: lastSha/lastAt for what is live, phase for a running build.
got="$(jq '[.[] | {deployable, paused, fetchError, compareStatus, lastSha: .liveSha, headSha, lastAt: .liveAt, headAt,
               phase: (if .building then "building" else "ready" end)}]' "$cases" | jq -c "$rule | map(.changed)")"
while IFS=$'\t' read -r name want have; do
  if [ "$want" = "$have" ]; then echo "ok   $name"; else echo "FAIL $name: expected [$want], got [$have]"; fails=$((fails+1)); fi
done < <(jq -r --argjson got "$got" 'to_entries[] | [.value.name, (.value.want | tostring), ($got[.key] | tostring)] | @tsv' "$cases")

if [ "$(uname -s)" = Darwin ] && command -v swiftc >/dev/null; then
  echo "--- the iPhone app's rule"
  out="$(mktemp -d)"; trap 'rm -rf "$out"' EXIT
  cp tests/ios-rule-tests.swift "$out/main.swift"
  swiftc -swift-version 5 -o "$out/rule" ios/App/Project.swift ios/App/Clients.swift ios/App/LogMask.swift shared/*.swift "$out/main.swift"
  "$out/rule" "$cases" || fails=$((fails+1))
else
  echo "skip the iPhone app's rule (needs macOS and swiftc)"
fi
echo
[ "$fails" = 0 ] && echo "All rule tests passed." || { echo "$fails failed."; exit 1; }
