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

# trap_fn (idea 6): exit actions without eval; words with spaces survive, the exit status passes through
mkdir -p "$tmp/tf/lk"; : > "$tmp/tf/a b"; : > "$tmp/tf/c"
( export DEPLOYS_LIB=1 DEPLOYS_CONFIG="$tmp/tfc"; . ./deploys; trap_fn exit_rm "$tmp/tf/a b" "$tmp/tf/c"; trap_fn exit_rmdir "$tmp/tf/lk"; trap_add 'echo "late $?" > "$tmp/tf.out"'; exit 3 ) 2>/dev/null; rc=$?
expect "trap_fn: files and folder removed, old-style trap still runs, status kept" "$rc:$(ls "$tmp/tf" | wc -l | tr -d ' '):$(cat "$tmp/tf.out")" "3:0:late 3"

# secrets (idea 32): added lines that look like keys; the secret itself is never printed
sd='+++ b/src/a.env
+API=ok
+TOKEN=ghp_abcdefghijklmnopqrstuvwxyz0123456789
+-----BEGIN RSA PRIVATE KEY-----
+MIIabcsecretbody
+-----END RSA PRIVATE KEY-----
+plain'
printf '%s\n' "$sd" | cli secrets --stdin >"$tmp/s.out" 2>&1; rc=$?
expect "secrets: a diff with a token and a key exits 1" "$rc" "1"
expect "secrets: the secret is not printed" "$(grep -c 'abcdefghijklmnop\|MIIabcsecretbody' "$tmp/s.out")" "0"
expect "secrets: both hits are counted" "$(printf '%s\n' "$sd" | cli secrets --stdin --json | jq .found)" "2"
expect "secrets: a clean diff exits 0" "$(printf '+++ b/a\n+hello\n' | cli secrets --stdin >/dev/null; echo $?)" "0"
expect "secrets: without a project or --stdin is a usage line" "$(cli secrets >/dev/null 2>&1; echo $?)" "1"

# keychain_age_days / creds (ideas 30, 31): a fake `security` that reports a creation date
mkdir -p "$tmp/fakebin"
cat > "$tmp/fakebin/security" <<'SEC'
#!/bin/bash
printf '    "cdat"<timedate>=0x32303230303130313132303030305A00  "20200101120000Z\\000"\n'
SEC
chmod +x "$tmp/fakebin/security"
age="$( export DEPLOYS_LIB=1 DEPLOYS_CONFIG="$tmp/agecfg" PATH="$tmp/fakebin:$PATH"; . ./deploys; keychain_age_days render )"
expect "keychain_age_days: a key saved in 2020 is over 2000 days old" "$([ "${age:-0}" -gt 2000 ] && echo yes || echo "no:$age")" "yes"
expect "creds --json: a list with a rotate flag" "$(PATH="$tmp/fakebin:$PATH" cli creds --json 2>/dev/null | jq -r 'map(has("rotate")) | all')" "true"
expect "creds: a bad --max-age is refused" "$(cli creds --max-age 0 >/dev/null 2>&1; echo $?)" "1"

# cert_days_left (idea 34) with a fake openssl
cat > "$tmp/fakebin/openssl" <<'OSSL'
#!/bin/bash
case "$1" in s_client) cat > /dev/null ;; x509) cat > /dev/null; echo "notAfter=Jan  1 00:00:00 ${CERT_YEAR:-2020} GMT" ;; esac
OSSL
chmod +x "$tmp/fakebin/openssl"
cd1="$( export DEPLOYS_LIB=1 DEPLOYS_CONFIG="$tmp/certcfg" PATH="$tmp/fakebin:$PATH"; . ./deploys; cert_days_left example.test )"
cd2="$( export DEPLOYS_LIB=1 DEPLOYS_CONFIG="$tmp/certcfg" PATH="$tmp/fakebin:$PATH" CERT_YEAR=2099; . ./deploys; cert_days_left example.test )"
expect "cert_days_left: an expired certificate is negative" "$([ "${cd1:-0}" -lt 0 ] && echo yes || echo "no:$cd1")" "yes"
expect "cert_days_left: a certificate in 2099 has years left" "$([ "${cd2:-0}" -gt 3000 ] && echo yes || echo "no:$cd2")" "yes"

echo
[ "$fails" -eq 0 ] && echo "All round-9 tests passed." || { echo "$fails failed."; exit 1; }
