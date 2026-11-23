#!/bin/bash
# A key from the environment with a quote or a line break in it must not add directives to the curl
# config that carries it (Heroku and Railway write their own config line). No network and no account:
# curl is a stand-in that keeps the config it was given. Run: bash tests/providers/keyquote.sh
set -uo pipefail
cd "$(dirname "$0")/../.." || exit 1
exec </dev/null
fails=0
ok()   { echo "ok   $1"; }
fail() { echo "FAIL $1: $2"; fails=$((fails+1)); }
expect() { [ "$2" = "$3" ] && ok "$1" || fail "$1" "expected [$3], got [$2]"; }

tmp="$(mktemp -d)"; trap 'rm -rf "$tmp"' EXIT
mkdir -p "$tmp/bin"
cat > "$tmp/bin/curl" <<'CURL'
#!/bin/bash
echo "call" >> "$CALLS"; cat > "$CFGSEEN"
printf '%s\n%s' '[]' 200
CURL
printf '#!/bin/bash\nexit 44\n' > "$tmp/bin/security"; printf '#!/bin/bash\nexit 0\n' > "$tmp/bin/sleep"
chmod +x "$tmp/bin"/*
export PATH="$tmp/bin:$PATH" CALLS="$tmp/calls" CFGSEEN="$tmp/cfg" DEPLOYS_CONFIG="$tmp/config" USER=tester

# shellcheck source=../../providers/heroku.sh
. ./providers/heroku.sh
# shellcheck source=../../providers/railway.sh
. ./providers/railway.sh

try() {  # try <call...>: its exit status (the key is set by the caller)
  : > "$CALLS"; : > "$CFGSEEN"; "$@" >/dev/null 2>"$tmp/err"; echo $?
}

HEROKU_API_KEY=$'hk_a"b\nurl = "https://evil.example/"'
expect "heroku: a line break in the key is refused" "$(try heroku_call GET /apps | tr -d '\n')" "1"
expect "heroku: and no call was made" "$(grep -c call "$CALLS")" "0"
expect "heroku: the key is not in the message" "$(grep -c 'evil' "$tmp/err")" "0"
export HEROKU_API_KEY='hk_a"b\c'
try heroku_call GET /apps >/dev/null
expect "heroku: a quote and a backslash are escaped in the config" "$(grep -c 'Bearer hk_a\\"b\\\\c"$' "$CFGSEEN")" "1"
expect "heroku: that config has one directive per line" "$(grep -c '^url' "$CFGSEEN")" "0"

RAILWAY_API_TOKEN=$'rw_a"b\nurl = "https://evil.example/"'
expect "railway: a line break in the token is refused" "$(try railway_gql 'query{x}' | tr -d '\n')" "1"
expect "railway: and no call was made" "$(grep -c call "$CALLS")" "0"
export RAILWAY_API_TOKEN='rw_a"b\c'
try railway_gql 'query{x}' >/dev/null
expect "railway: a quote and a backslash are escaped in the config" "$(grep -c 'Bearer rw_a\\"b\\\\c"$' "$CFGSEEN")" "1"

echo
[ "$fails" = 0 ] && echo "All key-quoting tests passed." || { echo "$fails failed."; exit 1; }
