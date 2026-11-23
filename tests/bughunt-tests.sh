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

[ "$fails" = 0 ] && echo "all ok" || { echo "$fails failed"; exit 1; }
