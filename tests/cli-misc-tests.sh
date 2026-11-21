#!/bin/bash
# Tests for small CLI commands that had none: `where`, an unknown command, --version, and `help` listing
# every command the dispatcher knows. gh, vercel and security are stand-ins (no real login is read). No network.
# Run: bash tests/cli-misc-tests.sh
set -uo pipefail
cd "$(dirname "$0")/.." || exit 1
exec </dev/null
fails=0
ok()   { echo "ok   $1"; }
fail() { echo "FAIL $1: $2"; fails=$((fails+1)); }
expect() { [ "$2" = "$3" ] && ok "$1" || fail "$1" "expected [$3], got [$2]"; }
has()  { case "$2" in *"$3"*) ok "$1" ;; *) fail "$1" "[$2] lacks [$3]" ;; esac; }
hasnt() { case "$2" in *"$3"*) fail "$1" "[$2] holds [$3]" ;; *) ok "$1" ;; esac; }

tmp="$(mktemp -d)"; trap 'rm -rf "$tmp"' EXIT
mkdir -p "$tmp/bin" "$tmp/home"
unset RENDER_API_KEY VERCEL_TOKEN
for t in gh vercel security glab; do printf '#!/bin/bash\nexit 1\n' > "$tmp/bin/$t"; chmod +x "$tmp/bin/$t"; done
cli() {  # cli <args...>: stdout and stderr, the exit code on the last line
  local out rc
  out="$(env -u DEPLOYS_LIB -u DEPLOYS_JOURNAL PATH="$tmp/bin:/usr/bin:/bin" DEPLOYS_CONFIG="$tmp/config" HOME="$tmp/home" \
    NO_COLOR=1 DEPLOYS_NO_GITHUB=1 bash ./deploys "$@" 2>&1)"; rc=$?
  printf '%s\n%s' "$out" "$rc"
}

# --- where ---
w="$(RENDER_API_KEY=rnd_NOTAREALKEY0123456789 cli where)"
has "where: version" "$w" "version      $(bash ./deploys --version)"
has "where: the config folder" "$w" "config       $tmp/config"
has "where: render's key comes from the environment" "$w" "render key   environment (RENDER_API_KEY)"
hasnt "where: the key itself is never printed" "$w" "NOTAREALKEY"
has "where: no login is shown as such" "$w" "github user  not logged in"
has "where: autofix without routine or token" "$w" "autofix      routine none, token none"
expect "where: exit 0" "${w##*$'\n'}" 0
w2="$(cli where)"
has "where: without a key, none" "$w2" "render key   none"

# --- unknown command and options ---
u="$(cli frobnicate)"
expect "unknown command: exit 1" "${u##*$'\n'}" 1
has "unknown command: points to help" "$u" "help"
expect "--version: one line, a version number" "$(bash ./deploys --version | grep -cE '^[0-9]+\.[0-9]+\.[0-9]+$')" 1
expect "--version matches VERSION" "$(bash ./deploys --version)" "$(tr -d '[:space:]' < VERSION)"

# --- help lists what the dispatcher knows (a command nobody can find is a command nobody uses) ---
h="$(bash ./deploys help 2>&1)"
for c in doctor changed deploy-changed plan deploy rollback cancel journal status watch logs history explain diff notes open ignore \
         certs creds idle list verify secrets risk ci window freeze digest timeline where triggers; do
  has "help: names $c" "$h" "deploys $c"
done

echo
if [ "$fails" -gt 0 ]; then echo "$fails failed"; exit 1; fi
echo "All misc CLI tests passed."
