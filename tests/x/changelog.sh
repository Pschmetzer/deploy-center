#!/bin/bash
# deploys changelog (lib/x-changelog.sh): the grouping, on made-up commits.
. "$(dirname "$0")/lib.sh"
DEPLOYS_LIB=1 . ./deploys 2>/dev/null; set +e
n='{"project":"web","commits":[
 {"sha":"aaaaaaaa11","message":"feat(ui): dark mode","pr":12,"author":"ann","bot":false},
 {"sha":"bbbbbbbb22","message":"fix: login redirect","pr":null,"author":"bo","bot":false},
 {"sha":"cccccccc33","message":"feat!: drop the v1 API","pr":null,"author":"ann","bot":false},
 {"sha":"dddddddd44","message":"docs: update the readme","author":"cy","bot":false},
 {"sha":"eeeeeeee55","message":"Merge branch main","author":"cy","bot":false},
 {"sha":"ffffffff66","message":"chore(deps): bump x from 1 to 2","author":"bot","bot":true},
 {"sha":"9999999977","message":"perf: faster list\u0007 (BREAKING CHANGE: none)","author":"bo","bot":false}]}'
g="$(changelog_from 0 <<<"$n")"
expect "groups in order, empty ones left out" "$(jq -c '[.groups[].title]' <<<"$g")" '["Breaking changes","Features","Fixes","Documentation","Other"]'
expect "a ! and BREAKING CHANGE both count as breaking" "$(jq -c '.groups[0].items | map(.sha)' <<<"$g")" '["ccccccc","9999999"]'
expect "the scope goes behind the text" "$(jq -r '.groups[1].items[0].text' <<<"$g")" "dark mode (ui)"
expect "the pr number is kept" "$(jq -r '.groups[1].items[0].pr' <<<"$g")" "12"
expect "authors are left out by default" "$(jq -c '[.groups[].items[].author] | unique' <<<"$g")" "[null]"
expect "--authors names them" "$(changelog_from 1 <<<"$n" | jq -r '.groups[1].items[0].author')" "ann"
expect "a title without a prefix is Other" "$(jq -r '.groups[-1].items[0].text' <<<"$g")" "Merge branch main"
expect "bots are apart" "$(jq -c '.bots | map(.sha)' <<<"$g")" '["fffffff"]'
expect "control characters are cleaned" "$(jq -r '.groups[0].items[1].text' <<<"$g" | grep -c "$(printf '\007')")" "0"
md="$(changelog_print md <<<"$g")"
has "md: title" "$md" "# web"
has "md: group heading" "$md" "## Features"
has "md: item with pr" "$md" "- dark mode (ui) (#12)"
has "md: bots" "$md" "## Dependency updates"
has "text: heading" "$(changelog_print text <<<"$g")" "Fixes:"
has "nothing waits" "$(changelog_from 0 <<<'{"project":"web","commits":[]}' | changelog_print md)" "Nothing waits to deploy."
cli changelog >/dev/null 2>&1; expect "cli: a project is needed" "$?" "2"
cli changelog web --format html >/dev/null 2>&1; expect "cli: bad format" "$?" "1"
exit "$fails"
