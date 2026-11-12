#!/bin/bash
# Every test suite CI runs, in one go, with a summary at the end. No network, no real projects.
#   tests/all.sh              CLI, team, install, release and (on macOS) app tests, plus integrations
#   tests/all.sh --quick      without the app tests and integrations (no Swift build, no node)
# The integration tests need `npm ci` in integrations/mcp and integrations/vscode for their full run.
set -uo pipefail
cd "$(dirname "$0")/.." || exit 1
quick=0; [ "${1:-}" = --quick ] && quick=1

suites=(tests/script-tests.sh tests/team-tests.sh tests/install-tests.sh tests/release-tests.sh tests/ios-rule-tests.sh)
if [ "$quick" = 0 ]; then
  [ "$(uname -s)" = Darwin ] && suites+=(tests/app-tests.sh)
  suites+=(integrations/tests/run.sh)
fi

failed=()
for s in "${suites[@]}"; do
  echo "=== $s"
  bash "$s" || failed+=("$s")
done
echo
if [ "${#failed[@]}" -gt 0 ]; then
  printf 'Failed: %s\n' "${failed[@]}"
  exit 1
fi
echo "All ${#suites[@]} suites passed."
