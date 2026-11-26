# shellcheck shell=bash
# lib/x-changelog.sh — `deploys changelog <project>`: what waits to deploy, as a changelog grouped by kind of change.
#
#   deploys changelog <project> [--authors] [--format md|text]      (--json: the groups as JSON)
#
# Takes the commits `deploys notes <project> --json` reads (what is merged but not live) and sorts them by the prefix of
# their title in the conventional-commit style: feat, fix, perf, docs, refactor, test, build/ci/chore (grouped as
# "Maintenance"), everything else under "Other"; a `!` after the type or "BREAKING CHANGE" in the title puts a commit under
# "Breaking changes" first. Dependency-bot commits are listed apart. Authors are left out unless you ask (--authors).
# Nothing is deployed or written; it asks GitHub through `deploys notes`, as that does. Sourced by deploys; uses SELF, die.
# x-command: changelog | what waits to deploy as a changelog grouped by kind (features, fixes, docs …), from the commit titles | deploys changelog <project> [--authors] [--format md|text] [--json]

# changelog_from <authors 0|1>: stdin is the JSON of `deploys notes <p> --json`. {project, groups:[{title, items:[{text, sha, pr, author}]}], bots:[…]}
changelog_from() {
  jq -c --argjson authors "$1" '
    def kind($m): ($m | capture("^(?<t>[a-zA-Z]+)(\\((?<s>[^)]*)\\))?(?<b>!)?: (?<r>.*)$")?) // null;
    def clean: tostring | gsub("[\\x00-\\x1f\\x7f]"; " ") | .[0:200];
    def group($t; $breaking): if $breaking then "Breaking changes"
      elif $t == "feat" then "Features" elif $t == "fix" then "Fixes" elif $t == "perf" then "Performance"
      elif $t == "docs" then "Documentation" elif $t == "refactor" then "Refactoring" elif $t == "test" then "Tests"
      elif ($t == "build" or $t == "ci" or $t == "chore" or $t == "style" or $t == "revert") then "Maintenance" else "Other" end;
    ["Breaking changes","Features","Fixes","Performance","Documentation","Refactoring","Tests","Maintenance","Other"] as $order
    | (.commits // []) as $c
    | ($c | map(select(.bot | not) | (.message // "" | clean) as $m | kind($m) as $k
          | ((.message // "") | test("BREAKING CHANGE")) as $bc
          | {g: group(($k.t // "" | ascii_downcase); (($k.b // "") == "!" or $bc)),
             text: (if $k != null then ($k.r + (if ($k.s // "") != "" then " (" + $k.s + ")" else "" end)) else $m end),
             sha: ((.sha // "") | tostring | .[0:7]), pr: (.pr // null), author: (if $authors == 1 then (.author // null) else null end)})) as $items
    | { project: (.project // null),
        groups: [ $order[] as $o | ($items | map(select(.g == $o) | del(.g))) as $i | select(($i | length) > 0) | {title: $o, items: $i} ],
        bots: ($c | map(select(.bot) | {text: ((.message // "") | clean), sha: ((.sha // "") | tostring | .[0:7])})) }'
}

# changelog_print <md|text>: stdin is changelog_from JSON.
changelog_print() {
  jq -r --arg f "$1" '
    def li: "- \(.text)\(if .pr then " (#\(.pr))" else "" end)\(if .author then " – \(.author)" else "" end)";
    (if $f == "md" then "# \(.project // "Changes")" else "\(.project // "Changes")" end),
    (if (.groups | length) == 0 and (.bots | length) == 0 then "", "Nothing waits to deploy." else empty end),
    (.groups[] | "", (if $f == "md" then "## \(.title)" else "\(.title):" end), (.items[] | li)),
    (if (.bots | length) > 0 then "", (if $f == "md" then "## Dependency updates" else "Dependency updates:" end), (.bots[] | "- \(.text)") else empty end)'
}

x_changelog_main() {
  local p="" authors=0 fmt=md notes
  while [ "$#" -gt 0 ]; do
    case "$1" in
      --authors) authors=1 ;;
      --format) case "${2:-}" in md|text) fmt="$2" ;; *) die "--format takes md or text" ;; esac; shift ;;
      -*) die "Unknown option $1. Usage: deploys changelog <project> [--authors] [--format md|text] [--json]" ;;
      *) [ -z "$p" ] || die "Usage: deploys changelog <project> [--authors] [--format md|text] [--json]"; p="$1" ;;
    esac
    shift
  done
  [ -n "$p" ] || die "Usage: deploys changelog <project> [--authors] [--format md|text] [--json]"
  notes="$("$SELF" notes "$p" --json </dev/null)" || exit 1
  jq -e '.commits | type == "array"' >/dev/null 2>&1 <<<"$notes" || die "deploys notes did not answer with commits for $p"
  if [ "${json:-0}" = 1 ]; then changelog_from "$authors" <<<"$notes" | jq .
  else changelog_from "$authors" <<<"$notes" | changelog_print "$fmt"; fi
}
