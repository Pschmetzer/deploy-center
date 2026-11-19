#!/bin/bash
# Timestamps in the providers' jq code: Z with or without fractions, a numeric offset, and a value
# that is no date at all. An odd one is null for that row; it must not end the whole list.
# No network. Run: bash tests/providers/timestamps.sh
set -uo pipefail
cd "$(dirname "$0")/../.." || exit 1
fails=0
ok()   { echo "ok   $1"; }
fail() { echo "FAIL $1: $2"; fails=$((fails+1)); }
expect() { [ "$2" = "$3" ] && ok "$1" || fail "$1" "expected [$3], got [$2]"; }

# 2026-11-05T10:00:00Z is 1793872800.
run() {  # run <jq var> <def name> <timestamp>
  DEPLOYS_LIB=1 PATH="/usr/bin:/bin:$PATH" HOME="$PWD" DEPLOYS_CONFIG="$(mktemp -d)" /bin/bash -c '. ./deploys; set +e; jq -n --arg v "$3" "${!1}"'"'"'$v | '"$2"''"'" _ "$1" "$2" "$3" 2>&1
}
for spec in "NETLIFY_JQ:t" "COOLIFY_JQ:t" "DIGITALOCEAN_JQ:t" "CF_PHASE:cf_t"; do
  var="${spec%%:*}"; fn="${spec#*:}"; name="${var%%_*}"
  for pair in "2026-11-05T10:00:00Z=1793872800" "2026-11-05T10:00:00.123456Z=1793872800" "2026-11-05T12:00:00+02:00=1793872800" \
              "2026-11-05T05:00:00-05:00=1793872800" "2026-11-05T10:00:00+00:00=1793872800" "not a date=null" "=null"; do
    ts="${pair%=*}"; want="${pair##*=}"
    expect "$name: [$ts]" "$(run "$var" "$fn" "$ts")" "$want"
  done
done

echo
[ "$fails" = 0 ] && echo "All timestamp tests passed." || { echo "$fails failed."; exit 1; }
