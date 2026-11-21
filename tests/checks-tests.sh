#!/bin/bash
# Tests for the static check scripts (scripts/check-bash32.py, scripts/check-secrets.py): the repo passes, and
# each rule fires on a made-up bad file and stays quiet on a good one. No network.
set -uo pipefail
cd "$(dirname "$0")/.." || exit 1
exec </dev/null
fails=0
ok()   { echo "ok   $1"; }
fail() { echo "FAIL $1: $2"; fails=$((fails+1)); }
expect() { [ "$2" = "$3" ] && ok "$1" || fail "$1" "expected [$3], got [$2]"; }
tmp="$(mktemp -d)"; trap 'rm -rf "$tmp"' EXIT

# runs a checker on one made-up line: prints the exit code
chk() { # script line
  printf '%s\n' "$2" > "$tmp/t.sh"
  python3 -I "scripts/$1" "$tmp/t.sh" >/dev/null 2>&1; echo $?
}

expect "check-bash32: the repo passes" "$(python3 -I scripts/check-bash32.py >/dev/null 2>&1; echo $?)" 0
expect "check-secrets: the repo passes" "$(python3 -I scripts/check-secrets.py >/dev/null 2>&1; echo $?)" 0

for bad in 'declare -A m' 'local -A m' 'mapfile -t a < f' 'readarray a < f' 'y=${x,,}' 'y=${x^^}' 'y=${x@Q}' \
           'case a in a) :;&' 'cmd &>> f' 'a |& b' '[[ -v x ]]' 'wait -n' 'echo ${a[-1]}' 'echo $EPOCHSECONDS' \
           'shopt -s globstar' 'read -i x v' 'printf "%(%s)T" -1' 'coproc x { :; }'; do
  expect "check-bash32: refuses  $bad" "$(chk check-bash32.py "$bad")" 1
done
for good in 'declare -a m' 'local x=1' '# mapfile is fine in a comment' 'y="${x#a}"' 'echo "a;&b"' 'mapfile -t a # bash32-ok' \
            'x=$(tr A-Z a-z <<<"$y")' 'case a in a) :;; esac' 'printf "%s\n" 100%' '[ -n "${x:-}" ]'; do
  expect "check-bash32: accepts $good" "$(chk check-bash32.py "$good")" 0
done
printf 'cat <<EOF\ndeclare -A m\nEOF\necho done\n' > "$tmp/h.sh"
expect "check-bash32: a heredoc body is text" "$(python3 -I scripts/check-bash32.py "$tmp/h.sh" >/dev/null 2>&1; echo $?)" 0

for bad in 'curl -H "Authorization: Bearer $k" "$u"' "curl -sS -H 'X-Api-Key: \$k' \$u" 'curl -u "$user:$pw" "$u"' \
           'curl --oauth2-bearer "$t" "$u"' 'curl "$u?access_token=$t"' 'curl "$u?api_key=$k"' \
           'security add-generic-password -a me -s svc -w "$key"' 'set -x' 'set -euxo pipefail' 'bash -x ./deploys' 'set -o xtrace'; do
  expect "check-secrets: refuses  $bad" "$(chk check-secrets.py "$bad")" 1
done
for good in 'curl -sS -K - "$u"' 'curl -H "Accept: application/json" -K - "$u"' 'curl -H "Range: bytes=-5" "$u"' \
            'printf "header = \"Authorization: Bearer %s\"\n" "$k" | curl -K - "$u"' \
            'security find-generic-password -a me -s svc -w' 'security -i' 'set -eu' 'set -e -o pipefail' \
            '# curl -H "Authorization: x" is the bad way' 'curl -H "Authorization: x" "$u" # secrets-ok: fixed demo value'; do
  expect "check-secrets: accepts $good" "$(chk check-secrets.py "$good")" 0
done

echo
if [ "$fails" -gt 0 ]; then echo "$fails failed"; exit 1; fi
echo "All check-script tests passed."
