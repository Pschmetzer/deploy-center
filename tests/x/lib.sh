# Shared by tests/x/*.sh: a temp config and journal, ok/fail/expect, and `cli` to run deploys with them.
set -uo pipefail
cd "$(dirname "${BASH_SOURCE[0]}")/../.." || exit 1
exec </dev/null
fails=0
ok()   { echo "ok   $1"; }
fail() { echo "FAIL $1: $2"; fails=$((fails+1)); }
expect() { [ "$2" = "$3" ] && ok "$1" || fail "$1" "expected [$3], got [$2]"; }
has() { case "$2" in *"$3"*) ok "$1" ;; *) fail "$1" "no [$3] in [$2]" ;; esac; }
tmp="$(mktemp -d)"; trap 'rm -rf "$tmp"' EXIT
export DEPLOYS_CONFIG="$tmp/config" HOME="$tmp/home" NO_COLOR=1 DEPLOYS_TESTING=1
mkdir -p "$HOME" "$DEPLOYS_CONFIG"
printf '{"enabled":[]}' > "$DEPLOYS_CONFIG/providers.json"
export DEPLOYS_JOURNAL="$tmp/journal.jsonl"
cli() { bash ./deploys "$@"; }
