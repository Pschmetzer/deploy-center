#!/bin/bash
# deploys more (lib/x-more.sh): the list is read from the x-command lines of lib/x-*.sh.
. "$(dirname "$0")/lib.sh"
out="$(cli more)"
has "more lists itself" "$out" "more "
expect "more names a command" "$(cli more more | head -n 1 | cut -d' ' -f1)" "more"
expect "more --json is an array of name, summary, usage" "$(cli more --json | jq -r '.[] | select(.name=="more") | [.name, (.usage|startswith("deploys more"))] | @tsv')" "$(printf 'more\ttrue')"
cli more nosuch >/dev/null 2>&1; expect "unknown extra command exits 1" "$?" "1"
cli more --bad >/dev/null 2>&1; expect "unknown option exits 2 (usage)" "$?" "2"
# an x file next to a copy of deploys is found, and its command runs
inst="$tmp/inst"; mkdir -p "$inst"; cp -R deploys lib providers VERSION "$inst/"
printf '%s\n' 'x_hello_world_main() { echo "hello $*"; }' '# x-command: hello-world | says hello | deploys hello-world [name]' > "$inst/lib/x-hello.sh"
expect "a new x file adds a command" "$(bash "$inst/deploys" hello-world there 2>&1)" "hello there"
has "and shows in more" "$(bash "$inst/deploys" more)" "hello-world"
exit "$fails"
