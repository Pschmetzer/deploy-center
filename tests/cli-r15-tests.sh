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

[ "$fails" = 0 ] && echo "all passed" || { echo "$fails failed"; exit 1; }
