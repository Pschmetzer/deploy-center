#!/bin/bash
# Tests for the round-9 CLI changes: journal export (CSV) and journal report (Markdown). No network.
set -uo pipefail
cd "$(dirname "$0")/.." || exit 1
exec </dev/null
fails=0
ok()   { echo "ok   $1"; }
fail() { echo "FAIL $1: $2"; fails=$((fails+1)); }
expect() { [ "$2" = "$3" ] && ok "$1" || fail "$1" "expected [$3], got [$2]"; }

tmp="$(mktemp -d)"; trap 'rm -rf "$tmp"' EXIT
export DEPLOYS_CONFIG="$tmp/config" HOME="$tmp/home" NO_COLOR=1 DEPLOYS_JOURNAL="$tmp/j.jsonl"
mkdir -p "$HOME"
cli() { env -u DEPLOYS_LIB bash ./deploys "$@"; }
cat > "$tmp/j.jsonl" <<'J'
{"at":"2025-03-02T10:00:00Z","platform":"Vercel","name":"shop","result":"success","detail":"=SUM(1), \"q\""}
{"at":"2025-04-02T10:00:00Z","platform":"Render","name":"api","result":"failed","detail":"x | y"}
{"at":"2025-04-09T10:00:00Z","platform":"Render","name":"api","result":"success","detail":"ok"}
J

expect "export: header and 3 rows" "$(cli journal export | wc -l | tr -d ' ')" "4"
expect "export: a formula is defused and quotes doubled" "$(cli journal export | sed -n 2p)" "\"2025-03-02T10:00:00Z\",\"Vercel\",\"shop\",\"success\",\"'=SUM(1), \"\"q\"\"\""
expect "export: --since and --project" "$(cli journal export --since 2025-04-05 --project api | wc -l | tr -d ' ')" "2"
expect "export: a bad date is refused" "$(cli journal export --since nope >/dev/null 2>&1; echo $?)" "1"
expect "report: counts per result" "$(cli journal report --month 2025-04 | grep -c '^| \(failed\|success\) | 1 |')" "2"
expect "report: pipes in text cannot break the table" "$(cli journal report --month 2025-04 | grep -c '| api | Render | 2 |')" "1"
expect "report: an empty month" "$(cli journal report --month 2024-01 | tail -1)" "Nothing in this month."
expect "report: a bad month is refused" "$(cli journal report --month 2025-13x >/dev/null 2>&1; echo $?)" "1"
printf '%s\n' '{"at":"2025-04-20T10:00:00Z","name":"api","detail":"no result or platform"}' '{"at":12345}' >> "$tmp/j.jsonl"
expect "report: a line without result or platform still counts" "$(cli journal report --month 2025-04 | grep -c '^|  | 1 |$')" "1"
expect "report: odd lines do not stop it" "$(cli journal report --month 2025-04 >/dev/null 2>&1; echo $?)" "0"
expect "export: a tab in front is defused too" "$(printf '%s\n' '{"at":"2025-05-01","name":"\tx"}' > "$tmp/t.jsonl"; DEPLOYS_JOURNAL="$tmp/t.jsonl" cli journal export | sed -n 2p | cut -d, -f3)" "\"'"$'\t'"x\""
rm "$tmp/j.jsonl"
expect "export: no journal gives only the header" "$(cli journal export | wc -l | tr -d ' ')" "1"

# atomic_write (idea 5) and the documented exit codes (idea 22, docs/CLI.md)
(
  export DEPLOYS_LIB=1; cd "$tmp" || exit 1; . "$OLDPWD/deploys" 2>/dev/null
  set +e
  printf 'one\n' | atomic_write "$tmp/aw/state.json"; r1=$?
  printf 'two\n' | atomic_write "$tmp/aw/state.json"
  echo "$r1:$(cat "$tmp/aw/state.json"):$(ls "$tmp/aw" | wc -l | tr -d ' ')" > "$tmp/aw.out"
)
expect "atomic_write: creates the folder, replaces whole, leaves no temp file" "$(cat "$tmp/aw.out")" "0:two:1"
expect "exit code: an unknown command is 1" "$(cli frobnicate >/dev/null 2>&1; echo $?)" "1"
expect "exit code: journal with a bad verb is 1" "$(cli journal bogus >/dev/null 2>&1; echo $?)" "1"
expect "exit code: idle --days 0 is 1" "$(cli idle --days 0 >/dev/null 2>&1; echo $?)" "1"

echo
[ "$fails" -eq 0 ] && echo "All round-9 tests passed." || { echo "$fails failed."; exit 1; }
