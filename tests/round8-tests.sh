#!/bin/bash
# Fast tests for the round-8 changes in `deploys`: the masker, and small commands that need no network.
# No network, no real projects. Run: tests/round8-tests.sh
set -uo pipefail
cd "$(dirname "$0")/.." || exit 1
exec </dev/null
fails=0
ok()   { echo "ok   $1"; }
fail() { echo "FAIL $1: $2"; fails=$((fails+1)); }
expect() { [ "$2" = "$3" ] && ok "$1" || fail "$1" "expected [$3], got [$2]"; }

tmp="$(mktemp -d)"; trap 'rm -rf "$tmp"' EXIT
export DEPLOYS_CONFIG="$tmp/config" DEPLOYS_LIB=1 DEPLOYS_TESTING=1 HOME="$tmp/home" NO_COLOR=1
mkdir -p "$HOME"
# shellcheck source=../deploys
. ./deploys

# --- af_mask: more shapes, a line cap, and what stays readable ---
m() { printf '%s\n' "$1" | af_mask; }
expect "mask: a Slack webhook URL" "$(m 'post https://hooks.slack.com/services/T000/B000/XXXXsecretXXXX failed')" "post https://hooks.slack.com/services/[masked] failed"
expect "mask: a Discord webhook URL" "$(m 'https://discord.com/api/webhooks/123456789012345678/abc-DEF_ghi.jkl')" "https://discord.com/api/webhooks/[masked]"
expect "mask: a Telegram bot token in a URL" "$(m 'GET https://api.telegram.org/bot123456789:AAHdqTcvCH1vGWJxfSeofSAs0K5PALDsaw8/getMe')" "GET https://api.telegram.org/bot[masked]/getMe"
expect "mask: a bare Telegram bot token" "$(m 'bot 123456789:AAHdqTcvCH1vGWJxfSeofSAs0K5PALDsaw8 ok')" "bot [masked] ok"
expect "mask: a Hugging Face token" "$(m 'login hf_abcdefghijklmnopqrstuvwxyz0123')" "login [masked]"
expect "mask: a Coolify token" "$(m 'token 12|abcdefghijklmnopqrstuvwxyzABCDEFGHIJ0123 ok')" "token [masked] ok"
expect "mask: a long key-like run on a line about a secret" "$(m 'the secret was Zm9vYmFyYmF6cXV4Zm9vYmFyYmF6cXV4Zm9vYmFyYmF6cXV4MTIz end')" "the secret was [masked] end"
expect "mask: a long run on an ordinary line stays" "$(m 'sha512-Zm9vYmFyYmF6cXV4Zm9vYmFyYmF6cXV4Zm9vYmFyYmF6cXV4MTIz built')" "sha512-Zm9vYmFyYmF6cXV4Zm9vYmFyYmF6cXV4Zm9vYmFyYmF6cXV4MTIz built"
expect "mask: a commit sha on a line about a token stays" "$(m 'token check for 0123456789abcdef0123456789abcdef01234567')" "token check for 0123456789abcdef0123456789abcdef01234567"
expect "mask: git@host stays readable" "$(m 'git@github.com:me/app.git: Permission denied')" "git@github.com:me/app.git: Permission denied"
expect "mask: a password with an @ in a URL" "$(m 'postgres://u:p@ss@host/db')" "postgres://u:[masked]@host/db"
# A line of 150000 characters: cut, and fast (a crafted line must not make the patterns crawl).
start=$SECONDS
long="$(perl -e 'print "a." x 75000')"
cut="$(printf '%s\n' "$long" | af_mask | wc -c | tr -d ' ')"
[ "$cut" -lt 4100 ] && [ $((SECONDS - start)) -lt 10 ] && ok "mask: a 150000-character line is cut and handled fast" || fail "mask: long line" "bytes $cut, $((SECONDS - start)) s"

echo
[ "$fails" -eq 0 ] && echo "All round-8 tests passed." || { echo "$fails failed."; exit 1; }
