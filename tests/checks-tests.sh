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

# --- scripts/export-strings.py: the export and the missing-pair check ---
expect "export-strings: TSV starts with its header" "$(python3 -I scripts/export-strings.py | head -1)" $'file\tline\tEnglish\tDeutsch'
expect "export-strings: --json is a list of pairs" "$(python3 -I scripts/export-strings.py --json | jq -r 'type + " " + (.[0] | keys | join(","))')" "array de,en,file,line"
expect "export-strings: as many rows as check-strings counts" \
  "$(python3 -I scripts/export-strings.py | tail -n +2 | wc -l | tr -d ' ')" "$(python3 -I scripts/check-strings.py | sed -n 's/^\([0-9]*\) L(en, de) pairs.*/\1/p')"
expect "export-strings: no visible literal without a pair (or in the ignore list)" "$(python3 -I scripts/export-strings.py --check --strict >/dev/null; echo $?)" 0
mkdir -p "$tmp/es"
printf 'import SwiftUI\nstruct V: View { var body: some View { Text("Save changes") } }\n' > "$tmp/es/V.swift"
expect "export-strings: a Text without L is found, one with a pair is not" \
  "$(python3 -I scripts/export-strings.py --check "$tmp/es/V.swift" | head -1 | grep -c 'Save changes')" 1
printf 'import SwiftUI\nstruct V: View { var body: some View { Text(L("Save changes", "Änderungen sichern")) } }\n' > "$tmp/es/W.swift"
expect "export-strings: an L pair is clean" "$(python3 -I scripts/export-strings.py --check --strict "$tmp/es/W.swift" >/dev/null; echo $?)" 0

# --- scripts/new-provider.sh: refuses bad names and existing hosts, and what it scaffolds passes its own test ---
expect "new-provider: a bad name is refused" "$(bash scripts/new-provider.sh 'Bad Name' >/dev/null 2>&1; echo $?)" 2
expect "new-provider: an existing host is refused" "$(bash scripts/new-provider.sh deno >/dev/null 2>&1; echo $?)" 1
np="$tmp/np"; mkdir -p "$np/scripts" "$np/providers" "$np/tests/providers" "$np/tests/fixtures" "$np/tests/lib"
cp scripts/new-provider.sh "$np/scripts/"; cp tests/lib/fake-curl.sh "$np/tests/lib/"
expect "new-provider: scaffolds a host" "$(cd "$np" && bash scripts/new-provider.sh acme Acme >/dev/null 2>&1; echo $?)" 0
expect "new-provider: the files are there" "$(cd "$np" && ls providers/acme.sh tests/providers/acme.sh tests/fixtures/acme/env tests/fixtures/acme/expect.json 2>&1 | wc -l | tr -d ' ')" 4
expect "new-provider: the scaffold's own test passes" "$(cd "$np" && bash tests/providers/acme.sh 2>&1 | tail -1)" "All acme tests passed."
expect "new-provider: the stub's meta is valid, off by default" "$(cd "$np" && . providers/acme.sh && acme_meta | jq -c '[.id, .defaultOn, .keyEnv[0]]')" '["acme",false,"ACME_TOKEN"]'

# --- scripts/clean-worktrees.sh: lists first, keeps dirty, unpushed, busy and young worktrees ---
cw="$tmp/cw"; mkdir -p "$cw"
git init -q --bare "$cw/origin.git"
git init -q -b main "$cw/repo" && cd "$cw/repo" || exit 1
git config user.email t@example.invalid; git config user.name t
echo a > a; git add a; git commit -q -m one; git remote add origin "$cw/origin.git"; git push -q origin main 2>/dev/null
for n in old dirty unpushed; do git worktree add -q -b "wt-$n" ".claude/worktrees/$n" main; done
echo x > .claude/worktrees/dirty/new.txt
( cd .claude/worktrees/unpushed && echo b > b && git add b && git commit -q -m two )
for n in old dirty unpushed; do
  touch -t 202001010000 ".git/worktrees/$n/HEAD" ".git/worktrees/$n/logs/HEAD" ".claude/worktrees/$n" 2>/dev/null
done
cd "$OLDPWD" || exit 1
cwl() { ( cd "$cw/repo" && bash "$OLDPWD/scripts/clean-worktrees.sh" "$@" 2>&1 ); }
cwl_out="$(cwl)"
expect "clean-worktrees: a clean old worktree is listed as stale" "$(echo "$cwl_out" | grep -c '^stale  old$')" 1
expect "clean-worktrees: uncommitted work is kept" "$(echo "$cwl_out" | grep -c '^kept   dirty: uncommitted')" 1
expect "clean-worktrees: an unpushed commit is kept" "$(echo "$cwl_out" | grep -c '^kept   unpushed: 1 commit')" 1
expect "clean-worktrees: listing removes nothing" "$(ls "$cw/repo/.claude/worktrees" | tr '\n' ' ')" "dirty old unpushed "
expect "clean-worktrees: --hours 100000 keeps even the old one" "$(cwl --hours 100000 | grep -c '^stale')" 0
cwl --remove >/dev/null
expect "clean-worktrees: --remove takes only the stale one" "$(ls "$cw/repo/.claude/worktrees" | tr '\n' ' ')" "dirty unpushed "
expect "clean-worktrees: its merged branch goes with it" "$(git -C "$cw/repo" branch --list wt-old | wc -l | tr -d ' ')" 0

echo
if [ "$fails" -gt 0 ]; then echo "$fails failed"; exit 1; fi
echo "All check-script tests passed."
