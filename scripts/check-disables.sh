#!/bin/bash
# A `# shellcheck disable=` silences a warning for good. Each one needs a reason, and there is a ceiling so they do not
# pile up unnoticed: raise it on purpose (in the same PR, with the reason) or fix the code instead.
#   scripts/check-disables.sh
set -euo pipefail
cd "$(dirname "$0")/.."
max=90   # 82 at round 12 part B
n="$(grep -rhE '#[[:space:]]*shellcheck[[:space:]]+disable=' deploys lib providers scripts release.sh build.sh tests integrations 2>/dev/null | grep -v 'check-disables' | wc -l | tr -d ' ')"
if [ "$n" -gt "$max" ]; then echo "check-disables: $n 'shellcheck disable' lines (limit $max)" >&2; exit 1; fi
echo "check-disables: ok ($n of $max)"
