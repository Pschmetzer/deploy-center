#!/bin/bash
# Runs every tests/x/*.sh: one file per extra command (lib/x-<name>.sh). A new extra command adds its test file
# there and changes neither ci.yml nor tests/suites.txt. Run: tests/x-tests.sh [name]
set -uo pipefail
cd "$(dirname "$0")/.." || exit 1
exec </dev/null
fails=0; n=0
for f in tests/x/*${1:-}*.sh; do
  [ -f "$f" ] && [ "$(basename "$f")" != lib.sh ] || continue
  n=$((n+1))
  echo "== $f"
  bash "$f" || fails=$((fails+1))
done
[ "$n" -gt 0 ] || { echo "FAIL: no tests found"; exit 1; }
echo "x-tests: $n files, $fails failed"
[ "$fails" = 0 ]
