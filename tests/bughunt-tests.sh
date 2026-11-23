#!/bin/bash
# Regression tests for bugs found by reading deploys and lib/*.sh: one block per bug, written to fail first.
# No network, no real projects.
set -uo pipefail
cd "$(dirname "$0")/.." || exit 1
exec </dev/null
fails=0
ok()   { echo "ok   $1"; }
fail() { echo "FAIL $1: $2"; fails=$((fails+1)); }
expect() { [ "$2" = "$3" ] && ok "$1" || fail "$1" "expected [$3], got [$2]"; }

tmp="$(mktemp -d)"; trap 'rm -rf "$tmp"' EXIT
export DEPLOYS_CONFIG="$tmp/config" HOME="$tmp/home" NO_COLOR=1 DEPLOYS_LIB=1 DEPLOYS_TESTING=1
mkdir -p "$HOME" "$DEPLOYS_CONFIG"
# shellcheck source=../deploys
. ./deploys
set +e

# --- journal: a last line that was cut off (no newline) must not swallow the next entry ---
export DEPLOYS_JOURNAL="$tmp/journal.jsonl"
printf '%s\n%s' '{"at":"2026-01-01T00:00:00Z","name":"a"}' '{"at":"2026-01-02T00:00:00Z","na' > "$DEPLOYS_JOURNAL"
journal_add vercel demo started "after a torn line" 2>/dev/null
expect "journal_add: the new entry is a line of its own after a torn last line" \
  "$(tail -n 1 "$DEPLOYS_JOURNAL" | jq -r '.name // "broken"' 2>/dev/null)" "demo"
expect "journal_add: the torn line stays one broken line (nothing is merged into it)" "$(wc -l < "$DEPLOYS_JOURNAL" | tr -d ' ')" "3"
unset DEPLOYS_JOURNAL

# --- http_retry_after: a number too big for bash arithmetic is still "more than a minute" ---
printf 'HTTP/1.1 429\r\nRetry-After: 99999999999999999999999\r\n\r\n' > "$tmp/h-big"
w="$(http_retry_after "$tmp/h-big")"
expect "http_retry_after: a huge number is capped, so the caller's integer tests still work" \
  "$([ "${#w}" -le 10 ] && [ "$w" -gt 60 ] 2>/dev/null && echo capped)" "capped"
printf 'HTTP/1.1 429\r\nRetry-After: 08\r\n\r\n' > "$tmp/h-08"
expect "http_retry_after: 08 is eight seconds, not an octal error" "$(http_retry_after "$tmp/h-08"):$(( 1 + $(http_retry_after "$tmp/h-08") ))" "8:9"

# --- exit codes: docs/CLI.md says a wrong call (Usage:, an unknown option or command) is 2, an error is 1 ---
cli() { env -u DEPLOYS_LIB bash ./deploys "$@"; }
for c in "freeze add" "freeze remove" "freeze remove x" "journal" "journal bogus" "hooks" "scan log" "check show" "ai" "autofix --only" \
         "frobnicate" "ignore --bogus" "idle --bogus" "doctor --bogus" "deploy-changed --bogus" "journal export --bogus"; do
  # shellcheck disable=SC2086  # the words of $c are the arguments
  expect "exit code: a wrong call is 2: deploys $c" "$(cli $c >/dev/null 2>&1; echo $?)" "2"
done
expect "exit code: an error that is no wrong call stays 1 (a date that is none)" "$(cli journal export --since x >/dev/null 2>&1; echo $?)" "1"

[ "$fails" = 0 ] && echo "all ok" || { echo "$fails failed"; exit 1; }
