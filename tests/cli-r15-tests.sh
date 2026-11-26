#!/bin/bash
# Round 15 (docs/IDEEN-15.md, blocks B and C): CLI fixes. Locale, shared team window, exit codes, masking,
# hook hosts. No network, no real projects.
set -uo pipefail
cd "$(dirname "$0")/.." || exit 1
exec </dev/null
fails=0
ok()   { echo "ok   $1"; }
fail() { echo "FAIL $1: $2"; fails=$((fails+1)); }
expect() { [ "$2" = "$3" ] && ok "$1" || fail "$1" "expected [$3], got [$2]"; }

tmp="$(mktemp -d)"; trap 'rm -rf "$tmp"' EXIT
export DEPLOYS_CONFIG="$tmp/config" HOME="$tmp/home" NO_COLOR=1 DEPLOYS_LIB=1 DEPLOYS_TESTING=1 DEPLOYS_JOURNAL="$tmp/journal.jsonl"
mkdir -p "$HOME" "$DEPLOYS_CONFIG" "$tmp/bin"
# shellcheck source=../deploys
. ./deploys
set +e
root="$PWD"
cli() { env -u DEPLOYS_LIB bash "$root/deploys" "$@"; }

# --- shared team window: over midnight reads the day before; every window has its own zone ---
team_on() { return 0; }
TEAM_EFF_CACHE='{"projects":{"night":{"window":{"value":{"days":["fri"],"from":"22:00","to":"06:00","tz":"UTC"}}},
  "two":{"window":{"value":[{"days":["mon"],"from":"09:00","to":"10:00","tz":"UTC"},{"days":["mon"],"from":"09:00","to":"10:00","tz":"Pacific/Auckland"}]}}}}'
twd() { DEPLOYS_NOW="$1" team_window_denied "$2"; }
expect "team window: Fri 23:00 open" "$(twd "fri 23:00 2026-11-13" night)" ""
expect "team window: Sat 03:00 open (Friday night)" "$(twd "sat 03:00 2026-11-14" night)" ""
expect "team window: Fri 03:00 closed (Thursday night)" "$(twd "fri 03:00 2026-11-13" night | cut -c1-20)" "outside the shared d"
expect "team window: Sat 07:00 closed" "$(twd "sat 07:00 2026-11-14" night | cut -c1-20)" "outside the shared d"
# DEPLOYS_NOW stands in for every zone in tests; two windows still evaluate (any one open is enough)
expect "team window list: one open is enough" "$(twd "mon 09:30 2026-11-09" two)" ""
expect "team window list: none open" "$(twd "mon 11:00 2026-11-09" two | cut -c1-20)" "outside the shared d"

# --- LC_ALL=C for date parsing ---
cat > "$tmp/bin/openssl" <<'O'
#!/bin/bash
case "$1" in
  s_client) cat >/dev/null; echo x ;;
  x509) cat >/dev/null; echo "notAfter=Dec  1 12:00:00 2099 GMT" ;;
esac
O
chmod +x "$tmp/bin/openssl"
d="$(PATH="$tmp/bin:$PATH" LC_ALL=de_DE.UTF-8 cert_days_left example.test)"
case "$d" in [0-9]*) ok "cert_days_left reads English month names under de_DE" ;; *) fail "cert_days_left under de_DE" "got [$d]" ;; esac

# --- team list with no repos exits 0; dot paths are refused; unknown command --help is a usage error (2) ---
cli team list >/dev/null 2>&1; expect "team list: no repos exits 0" "$?" "0"
cli team add ../x >/dev/null 2>&1; expect "team add ../x refused" "$?" "1"
cli team add ./x >/dev/null 2>&1; expect "team add ./x refused" "$?" "1"
cli nosuchcmd --help >/dev/null 2>&1; expect "unknown command --help exits 2" "$?" "2"

# --- af_mask: formats that used to pass, spaces in a password, escaped quotes, database URLs ---
m() { printf '%s\n' "$1" | af_mask; }
# Obviously made-up values (like the samples in cli-r12b-tests.sh), only as long as the masker's patterns need.
for t in 'ya29.abcdefghijklmnopqrstu' 'GOCSPX-abcdefghijklmnop' 'shpat_abcdefghijklmnop' \
  'pypi-abcdefghijklmnop' 'dckr_pat_abcdefghijkl' 'SK00000000000000000000000000000000' \
  'ops_eyJabcdefghijklmnop'; do
  expect "af_mask: $t" "$(m "x $t y")" "x [masked] y"
done
expect "af_mask: curl -u user:pass" "$(m 'curl -u admin:hunter2hunter2 https://x.test')" "curl -u [masked] https://x.test"
expect "af_mask: password with spaces" "$(m 'password: my secret pass phrase')" "password: [masked]"
expect "af_mask: client_secret with a space" "$(m 'client_secret=abc def')" "client_secret=[masked]"
expect "af_mask: escaped quote in a quoted value" "$(m 'token="abc\"def ghi" ok')" "token=[masked] ok"
expect "af_mask: slash in a database password" "$(m 'postgres://user:p/ss@db/app x')" "postgres://user:[masked]@db/app x"
expect "af_mask: plain text stays" "$(m 'say hello world')" "say hello world"
# a long run of odd input: no crash, never longer than the cap
long="$(head -c 20000 /dev/zero | tr '\0' 'a')"
expect "af_mask: a very long line is cut" "$(printf '%s\n' "$long" | af_mask | wc -c | tr -d ' ' | awk '{ print ($1 < 4100) }')" "1"

# --- journal: the detail is masked when it is written ---
: > "$DEPLOYS_JOURNAL"
journal_add vercel web ok 'forced: token=ghp_abcdefghijklmnop1234 done'
expect "journal_add masks the detail" "$(grep -c ghp_ "$DEPLOYS_JOURNAL")" "0"
expect "journal_add keeps the rest" "$(jq -r .detail "$DEPLOYS_JOURNAL" | grep -c forced)" "1"

# --- hook hosts: every spelling of a private IPv6 address ---
. ./providers/hook.sh
for h in 0:0:0:0:0:ffff:7f00:1 0000:0000:0000:0000:0000:ffff:7f00:0001 ::127.0.0.1 ::ffff:10.0.0.1 0:0:0:0:0:0:7f00:1 '[::ffff:a9fe:a9fe]' zz::1; do
  hook_private_host "$h"; expect "hook_private_host: $h is private" "$?" "0"
done
for h in 2606:4700:4700::1111 2001:4860:4860::8888 0:0:0:0:0:ffff:808:808; do
  hook_private_host "$h"; expect "hook_private_host: $h is public" "$?" "1"
done

# --- API bases must be https ---
for pv in heroku:HEROKU_API netlify:NETLIFY_API cloudflare:CLOUDFLARE_API_BASE; do
  p="${pv%%:*}"; v="${pv##*:}"
  got="$(env -u DEPLOYS_TESTING "$v=http://api.example.test" DEPLOYS_LIB=1 bash -c ". ./deploys >/dev/null 2>&1; . ./providers/$p.sh 2>/dev/null; echo \"\${HEROKU_API:-}\${NETLIFY_API:-}\${CLOUDFLARE_API:-}\"")"
  case "$got" in https://api.*) ok "$p: http:// base is not used" ;; *) fail "$p: http:// base refused" "got [$got]" ;; esac
done

# --- robustness: huge numbers, budget 0, typo hint, export folder, risk of .sql ---
out="$(cli digest --days 99999999999999999999 2>&1)"; rc=$?
expect "--days with a huge number: our error only (2/1), no raw bash message" "$(printf '%s' "$out" | grep -c 'integer expression')" "0"
cli budget set 0 >/dev/null 2>&1; expect "budget set 0 is refused" "$?" "2"
cli budget set 5 >/dev/null 2>&1; expect "budget set 5 works" "$?" "0"
expect "typo hint: a three-letter word does not suggest fly/hook" "$(cli foo 2>&1 | grep -c 'Did you mean: fly')" "0"
expect "typo hint: a close command is named" "$(cli statu 2>&1 | grep -c 'Did you mean: status')" "1"
out="$(cli export --out /nonexistent/dir/x.csv 2>&1)"
expect "export into a missing folder: no raw mktemp text" "$(printf '%s' "$out" | grep -c 'mkstemp')" "0"
sqlrisk() { echo "{\"files\":[{\"filename\":\"$1\"}]}" | jq -c "${RISK_DEF%;}; "'[(.files // [])[] | .filename | {mig: test(re_mig), cfg: test(re_cfg)}] | .[0]'; }
expect "risk: a numbered .sql is a migration" "$(sqlrisk 20260101_add_users.sql)" '{"mig":true,"cfg":true}'
expect "risk: a seed .sql in a test folder is not red" "$(sqlrisk test/seed.sql | jq -r .mig)" "false"

[ "$fails" = 0 ] && echo "all passed" || { echo "$fails failed"; exit 1; }
