#!/bin/bash
# Keeps the big files from growing without anyone noticing: `deploys` and the Swift files have a line ceiling.
# Raise a ceiling on purpose (in the same PR, with a reason) or, better, move code out into lib/ or a new file.
set -euo pipefail
cd "$(dirname "$0")/.."
max_script=4650   # deploys (4800 until round 12 part B; watch, verify, completion, the risk rules and hook_run moved to lib/). Raised to 4650 after the window and self-update fixes (main was at 4605); raise it only with a reason, or move more to lib/
max_lib=800       # each lib/*.sh and providers/*.sh
max_swift=2400    # each app/*.swift
bad=0
check() { # file limit
  local n; n=$(wc -l < "$1")
  if [ "$n" -gt "$2" ]; then echo "check-size: $1 has $n lines (limit $2)" >&2; bad=1; fi
}
check deploys "$max_script"
for f in lib/*.sh providers/*.sh; do check "$f" "$max_lib"; done
for f in app/*.swift; do check "$f" "$max_swift"; done
[ "$bad" = 0 ] && echo "check-size: ok"
exit "$bad"
