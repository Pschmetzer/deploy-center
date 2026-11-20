#!/bin/bash
# Every test suite CI runs, in one go, with a summary at the end. No network, no real projects.
# The list is tests/suites.txt.
#   tests/all.sh                   CLI, team, install, release, iPhone and (on macOS) app tests, plus integrations
#   tests/all.sh --quick           without the app, iPhone and integration tests (no Swift build, no node)
#   tests/all.sh --list            the suites that would run, one per line
#   tests/all.sh --only <name>     only the suites whose path contains <name> (e.g. --only team, --only release)
# The integration tests need `npm ci` in integrations/mcp and integrations/vscode for their full run.
set -uo pipefail
cd "$(dirname "$0")/.." || exit 1
quick=0 list=0 only=""
while [ $# -gt 0 ]; do
  case "$1" in
    --quick) quick=1 ;;
    --list) list=1 ;;
    --only) [ $# -ge 2 ] || { echo "all.sh: --only needs a name" >&2; exit 2; }; only="$2"; shift ;;
    -h|--help) sed -n '2,9p' "$0" | sed 's/^# \{0,1\}//'; exit 0 ;;
    *) echo "all.sh: unknown option $1 (see --help)" >&2; exit 2 ;;
  esac
  shift
done

suites=()
while read -r path flags; do
  case "$path" in ""|"#"*) continue ;; esac
  case " $flags " in *" mac "*) [ "$(uname -s)" = Darwin ] || continue ;; esac
  case " $flags " in *" full "*) [ "$quick" = 0 ] || continue ;; esac
  [ -z "$only" ] || case "$path" in *"$only"*) ;; *) continue ;; esac
  suites+=("$path")
done < tests/suites.txt

if [ "$list" = 1 ]; then printf '%s\n' ${suites[@]+"${suites[@]}"}; exit 0; fi
[ "${#suites[@]}" -gt 0 ] || { echo "all.sh: no suite matches" >&2; exit 2; }

failed=() times=()
for s in "${suites[@]}"; do
  echo "=== $s"
  t0=$SECONDS
  bash "$s" || failed+=("$s")
  times+=("$((SECONDS - t0))s $s")
done
echo
printf 'Time: %s\n' "${times[@]}"
echo
if [ "${#failed[@]}" -gt 0 ]; then
  printf 'Failed: %s\n' "${failed[@]}"
  exit 1
fi
echo "All ${#suites[@]} suites passed."
