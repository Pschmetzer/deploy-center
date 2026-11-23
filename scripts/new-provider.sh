#!/bin/bash
# Scaffolds a new host: providers/<host>.sh with every function of the contract (docs/PROVIDERS.md) as a
# stub that says "not implemented", its own test tests/providers/<host>.sh and the fixture folder the
# contract test reads (tests/fixtures/<host>/). Nothing is overwritten; a host that exists is refused.
#   scripts/new-provider.sh <host> [Label]     host: lower case letters and digits, e.g. acme
# The scaffold passes its own test and `bash -n`; tests/providers/contract.sh fails for the host until
# its fixtures answer real calls (that is the point: fill them in, then the contract holds).
set -euo pipefail
cd "$(dirname "$0")/.."
p="${1:-}"; label="${2:-}"
case "$p" in
  ""|-h|--help) sed -n '2,7p' "$0" | sed 's/^# \{0,1\}//'; [ -n "$p" ] && exit 0; exit 2 ;;
  *[!a-z0-9]*|[0-9]*) echo "new-provider: host must be lower case letters and digits, starting with a letter (got: $p)" >&2; exit 2 ;;
esac
[ -n "$label" ] || label="$(printf '%s' "${p:0:1}" | tr "[:lower:]" "[:upper:]")${p:1}"
P="$(printf '%s' "$p" | tr "[:lower:]" "[:upper:]")"
for f in "providers/$p.sh" "tests/providers/$p.sh" "tests/fixtures/$p"; do
  [ ! -e "$f" ] || { echo "new-provider: $f exists, nothing written" >&2; exit 1; }
done

funcs="ready json has off deploy_json status latest cancel rollback logs url set_key doctor"
{
  cat <<EOF
#!/bin/bash
# providers/$p.sh: the $label provider for \`deploys\` (opt-in: deploys providers enable $p).
#
# Scaffolded by scripts/new-provider.sh. The contract is docs/PROVIDERS.md; every function below is a
# stub until it is filled in. Phases: queued | building | ready | failed | canceled.
#
# Token: ${P}_TOKEN, else the keychain item deploy-center-$p. Keys go to curl on stdin (lib/http.sh),
# never as an argument.

${P}_KEYCHAIN="deploy-center-$p"

declare -F die >/dev/null || die() { echo "Error: \$*" >&2; exit 1; }

${p}_meta() {
  printf '{"id":"$p","label":"$label","noun":"project","defaultOn":false,"keyEnv":["${P}_TOKEN"],"keychain":"%s","caps":{"off":false,"sha":false,"cancel":false,"rollback":false,"logs":false,"preview":false}}\n' "\$${P}_KEYCHAIN"
}

EOF
  for f in $funcs; do
    case "$f" in
      ready) echo "${p}_ready() { return 1; }   # TODO: exit 0 when a key is set; never print it" ;;
      *) echo "${p}_$f() { die \"$label: $f is not implemented yet\"; }   # TODO: see docs/PROVIDERS.md" ;;
    esac
  done
} > "providers/$p.sh"

mkdir -p "tests/fixtures/$p/config"
cat > "tests/fixtures/$p/env" <<EOF
# Sourced by tests/providers/contract.sh before this provider is tested. Stand-in values only.
export ${P}_TOKEN=${p}_fixture
CONTRACT_ID=alpha CONTRACT_NAME=alpha CONTRACT_DEPLOY=dpl-alpha-1
# A pending deployment turns into a finished one for the \`deploys watch\` check (sed on the fixture).
CONTRACT_DONE='s/"status": *"pending"/"status": "success"/g'
EOF
echo '{"alpha":"ready"}' > "tests/fixtures/$p/expect.json"
echo "api.$p.example" > "tests/fixtures/$p/HOST"
echo '{"enabled":["'"$p"'"]}' > "tests/fixtures/$p/config/providers.json"

cat > "tests/providers/$p.sh" <<EOF
#!/bin/bash
# Tests for providers/$p.sh. No network and no account: curl, security and sleep are stand-ins
# (tests/lib/fake-curl.sh answers from tests/fixtures/$p). Run: bash tests/providers/$p.sh
set -uo pipefail
cd "\$(dirname "\$0")/../.." || exit 1
exec </dev/null
fails=0
ok()   { echo "ok   \$1"; }
fail() { echo "FAIL \$1: \$2"; fails=\$((fails+1)); }
expect() { [ "\$2" = "\$3" ] && ok "\$1" || fail "\$1" "expected [\$3], got [\$2]"; }

tmp="\$(mktemp -d)"; trap 'rm -rf "\$tmp"' EXIT
mkdir -p "\$tmp/bin"
cp tests/lib/fake-curl.sh "\$tmp/bin/curl"
printf '#!/bin/bash\\nexit 44\\n' > "\$tmp/bin/security"
printf '#!/bin/bash\\nexit 0\\n' > "\$tmp/bin/sleep"
chmod +x "\$tmp/bin"/*
export PATH="\$tmp/bin:\$PATH" FIXTURES="\$PWD/tests/fixtures" CALLS="\$tmp/calls.log" DEPLOYS_CONFIG="\$tmp/config" USER=tester
export ${P}_TOKEN="${p}_secret_token"
: > "\$CALLS"
# shellcheck source=../../providers/$p.sh
. ./providers/$p.sh

missing=""
for v in meta $funcs; do declare -F "${p}_\$v" >/dev/null || missing="\$missing \$v"; done
expect "every contract function exists" "\$missing" ""
expect "meta is one valid line, off by default" "\$(${p}_meta | jq -c '[.id, .defaultOn]')" '["$p",false]'
# TODO: tests of your own, one per behaviour (json phases, has, deploy_json, status, errors, key never in argv).

[ "\$fails" = 0 ] && { echo "All $p tests passed."; exit 0; }
echo "\$fails failed."; exit 1
EOF
chmod +x "tests/providers/$p.sh" "providers/$p.sh"
bash -n "providers/$p.sh" && bash -n "tests/providers/$p.sh"
cat <<EOF
Scaffolded $p:
  providers/$p.sh            fill in each function (docs/PROVIDERS.md, one table row each)
  tests/providers/$p.sh      its own test (passes now: functions exist, meta valid)
  tests/fixtures/$p/         env, expect.json, HOST and one file per API call for tests/lib/fake-curl.sh
Next: docs/providers/$p.md, a line in docs/PROVIDERS.md, CHANGELOG.md; then bash tests/providers/contract.sh
EOF
