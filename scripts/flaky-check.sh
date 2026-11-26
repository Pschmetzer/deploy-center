#!/bin/bash
# Finds flaky tests: runs the suites twice (or --runs N times) and reports every test line that came out differently.
#   scripts/flaky-check.sh [--runs N] [--only <name>] [--quick]
# A test line is a line of a suite starting with `ok` or `FAIL` (timing in the text is not compared: digits are
# masked). Exit 0 when all runs agree, 1 when a line differs or a suite failed in one run only, 2 for a wrong call.
# Runs tests/all.sh, so no network and no real projects; nothing is changed in the repo.
set -uo pipefail
cd "$(dirname "$0")/.." || exit 1
runs=2 args=()
while [ $# -gt 0 ]; do
  case "$1" in
    --runs) [ $# -ge 2 ] && [ "$2" -ge 2 ] 2>/dev/null || { echo "flaky-check: --runs needs a number >= 2" >&2; exit 2; }; runs="$2"; shift ;;
    --only) [ $# -ge 2 ] || { echo "flaky-check: --only needs a name" >&2; exit 2; }; args+=(--only "$2"); shift ;;
    --quick) args+=(--quick) ;;
    -h|--help) sed -n '2,6p' "$0" | sed 's/^# \{0,1\}//'; exit 0 ;;
    *) echo "flaky-check: unknown option $1" >&2; exit 2 ;;
  esac
  shift
done
tmp="$(mktemp -d)"; trap 'rm -rf "$tmp"' EXIT
i=1
while [ "$i" -le "$runs" ]; do
  bash tests/all.sh ${args[@]+"${args[@]}"} 2>&1 | grep -E '^(ok|FAIL|=== )' | sed -E 's/[0-9]+/N/g' | sort > "$tmp/run$i"
  i=$((i + 1))
done
rc=0 i=2
while [ "$i" -le "$runs" ]; do
  if ! diff "$tmp/run1" "$tmp/run$i" > "$tmp/diff"; then
    [ "$rc" = 0 ] && echo "Flaky: these lines differ between run 1 and a later run:"
    grep -E '^[<>]' "$tmp/diff" | sed "s/^/  (run $i) /"
    rc=1
  fi
  i=$((i + 1))
done
[ "$rc" = 0 ] && echo "No flaky tests in $runs runs ($(wc -l < "$tmp/run1" | tr -d ' ') test lines compared)."
exit "$rc"
