#!/bin/bash
# Every test suite CI runs, in one go, with a summary at the end. No network, no real projects.
# The list is tests/suites.txt.
#   tests/all.sh                   CLI, team, install, release, iPhone and (on macOS) app tests, plus integrations
#   tests/all.sh --quick           without the app, iPhone and integration tests (no Swift build, no node)
#   tests/all.sh --list            the suites that would run, one per line
#   tests/all.sh --only <name>     only the suites whose path contains <name> (e.g. --only team, --only release)
#   tests/all.sh --changed         only the suites whose sources changed against origin/main (CHANGED_BASE=<ref> to compare elsewhere;
#                                  CHANGED_FILES="<paths, one per line>" instead of git, for tests)
# The summary lists the time and the number of `ok` lines per suite (a falling count is worth a look);
# in GitHub Actions it is also written to the job summary.
# The integration tests need `npm ci` in integrations/mcp and integrations/vscode for their full run.
set -uo pipefail
cd "$(dirname "$0")/.." || exit 1
quick=0 list=0 only="" changed=0
while [ $# -gt 0 ]; do
  case "$1" in
    --quick) quick=1 ;;
    --list) list=1 ;;
    --changed) changed=1 ;;
    --only) [ $# -ge 2 ] || { echo "all.sh: --only needs a name" >&2; exit 2; }; only="$2"; shift ;;
    -h|--help) sed -n '2,13p' "$0" | sed 's/^# \{0,1\}//'; exit 0 ;;
    *) echo "all.sh: unknown option $1 (see --help)" >&2; exit 2 ;;
  esac
  shift
done

# Which suites does a changed file belong to? A suite runs when a changed path starts with one of its patterns
# (tests/suites-map.txt), or when the suite file itself, tests/lib, tests/fixtures or tests/all.sh changed.
changed_files=""
if [ "$changed" = 1 ]; then
  if [ -n "${CHANGED_FILES+x}" ]; then
    changed_files="$CHANGED_FILES"   # a fixed list, one path per line (for tests)
  else
    base="${CHANGED_BASE:-origin/main}"
    git rev-parse --verify -q "$base" >/dev/null || { echo "all.sh: --changed needs $base (git fetch)" >&2; exit 2; }
    d1="$(git diff --no-renames --name-only "$base"...HEAD)" || { echo "all.sh: git diff against $base failed (shallow clone? git fetch --unshallow)" >&2; exit 2; }
    d2="$(git diff --no-renames --name-only HEAD)" || { echo "all.sh: git diff failed" >&2; exit 2; }
    d3="$(git ls-files --others --exclude-standard)" || { echo "all.sh: git ls-files failed" >&2; exit 2; }
    changed_files="$(printf '%s\n%s\n%s\n' "$d1" "$d2" "$d3" | sort -u)"
  fi
fi
suite_changed() {   # $1 suite path
  local f
  while IFS= read -r f; do
    [ -n "$f" ] || continue
    case "$f" in "$1"|tests/all.sh|tests/suites.txt|tests/suites-map.txt|tests/lib/*) return 0 ;; esac
    while read -r sp pat; do
      [ "$sp" = "$1" ] || continue
      # shellcheck disable=SC2254 # the table's second column is a glob on purpose
      case "$f" in $pat) return 0 ;; esac
    done < tests/suites-map.txt
  done <<EOF2
$changed_files
EOF2
  return 1
}

suites=()
while read -r path flags; do
  case "$path" in ""|"#"*) continue ;; esac
  case " $flags " in *" mac "*) [ "$(uname -s)" = Darwin ] || continue ;; esac
  case " $flags " in *" full "*) [ "$quick" = 0 ] || continue ;; esac
  [ -z "$only" ] || case "$path" in *"$only"*) ;; *) continue ;; esac
  if [ "$changed" = 1 ]; then suite_changed "$path" || continue; fi
  suites+=("$path")
done < tests/suites.txt

if [ "${#suites[@]}" -eq 0 ]; then
  [ "$changed" = 1 ] && { echo "all.sh: no suite is affected by the changes" >&2; exit 0; }
  echo "all.sh: no suite matches" >&2; exit 2
fi
if [ "$list" = 1 ]; then printf '%s\n' ${suites[@]+"${suites[@]}"}; exit 0; fi

failed=() times=()
for s in "${suites[@]}"; do
  echo "=== $s"
  t0=$SECONDS
  log="$(mktemp "${TMPDIR:-/tmp}/all-sh.XXXXXX")"
  bash "$s" 2>&1 | tee "$log"
  rc=${PIPESTATUS[0]}
  [ "$rc" = 0 ] || failed+=("$s")
  oks="$(grep -c '^ok' "$log" || true)"
  rm -f "$log"
  times+=("$((SECONDS - t0))s ${oks:-0} ok $s")
done
echo
printf 'Time and ok lines: %s\n' "${times[@]}"
echo
if [ -n "${GITHUB_STEP_SUMMARY:-}" ]; then
  { echo "### Test suites"; echo; echo "| Suite | Seconds | ok lines |"; echo "| --- | ---: | ---: |"
    for t in "${times[@]}"; do set -- $t; echo "| $4 | ${1%s} | $2 |"; done; } >> "$GITHUB_STEP_SUMMARY"
fi
if [ "${#failed[@]}" -gt 0 ]; then
  printf 'Failed: %s\n' "${failed[@]}"
  exit 1
fi
echo "All ${#suites[@]} suites passed."
