#!/bin/bash
# The CLI must run on the bash that macOS ships (3.2). This looks for what 3.2 does not know, in deploys, lib/, providers/,
# release.sh and the scripts: declare -A / local -A (associative arrays), declare -n / local -n, mapfile and readarray,
# ${x,,} and ${x^^}, |& and &>>, [[ -v name ]], wait -n, $BASHPID, $EPOCHSECONDS, ;& and ;;& in a case, coproc.
# On a Mac it also parses every file with /bin/bash -n, the real 3.2 (CI: the test job on macos).
#   scripts/check-bash32.sh
set -uo pipefail
cd "$(dirname "$0")/.." || exit 1
files="deploys release.sh build.sh $(ls lib/*.sh providers/*.sh scripts/*.sh 2>/dev/null | tr '\n' ' ')"
bad=0
# Only code: a line that is a comment is skipped. A word in quotes can still trip it; say so in a comment and use another word.
pat='(declare|local|typeset)[[:space:]]+-[a-zA-Z]*[AnN]([[:space:]]|$)|(^|[^A-Za-z_])(mapfile|readarray|coproc)[[:space:]]|\$\{[A-Za-z_][A-Za-z0-9_]*(,,|\^\^|@[QEPAa])\}|\|&|&>>|\[\[[[:space:]]+-v[[:space:]]|wait[[:space:]]+-n|\$BASHPID|\$EPOCHSECONDS|;;&|;&[[:space:]]*$'  # bash32-ok (the patterns this checker looks for)
for f in $files; do
  [ -f "$f" ] || continue
  [ "$f" != scripts/check-bash32.sh ] || continue
  out="$(grep -nE "$pat" "$f" | grep -vE '^[0-9]+:[[:space:]]*#' | grep -vE 'check-bash32: ok' || true)"
  if [ -n "$out" ]; then echo "check-bash32: $f uses something bash 3.2 does not have:" >&2; echo "$out" | sed 's/^/  /' >&2; bad=1; fi
done
if [ "$(uname -s)" = Darwin ] && [ -x /bin/bash ]; then
  for f in $files; do [ -f "$f" ] && { /bin/bash -n "$f" || { echo "check-bash32: /bin/bash -n $f failed" >&2; bad=1; }; }; done
fi
[ "$bad" = 0 ] && echo "check-bash32: ok"
exit "$bad"
