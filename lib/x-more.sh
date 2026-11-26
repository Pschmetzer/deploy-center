# shellcheck shell=bash
# lib/x-more.sh — `deploys more [<command>] [--json]`: the extra commands that live in lib/x-<name>.sh.
#
# Every lib/x-<name>.sh adds one command `deploys <name>` by defining the function x_<name>_main (dashes in the name
# become underscores). The file says what it is in its header, one line per command:
#
#   # x-command: <name> | <what it does, one line> | <usage>
#
# `deploys more` reads those lines, so the list cannot fall behind the files. A command whose file is missing is
# simply not listed. Read-only: nothing here starts, changes or sends anything. Sourced by deploys; uses LIB_DIR, die.

# more_rows: one tab-separated row per extra command: name, summary, usage (sorted by name).
more_rows() {
  local f
  for f in "$LIB_DIR"/x-*.sh; do
    [ -f "$f" ] || continue
    sed -n 's/^# x-command: *\([a-z][a-z0-9-]*\) *| *\([^|]*[^| ]\) *| *\(.*[^ ]\) *$/\1\t\2\t\3/p' "$f"
  done | sort
}

x_more_main() {
  local rows want="" want_set=0
  while [ "$#" -gt 0 ]; do
    case "$1" in
      -*) die "Unknown option $1. Usage: deploys more [<command>] [--json]" ;;
      *) [ "$want_set" = 0 ] || die "Usage: deploys more [<command>] [--json]"; want="$1"; want_set=1 ;;
    esac
    shift
  done
  rows="$(more_rows)"
  if [ "$want_set" = 1 ]; then
    rows="$(printf '%s\n' "$rows" | awk -F'\t' -v w="$want" '$1 == w')"
    [ -n "$rows" ] || die "No extra command \"$want\". The list: deploys more"
  fi
  if [ "${json:-0}" = 1 ]; then
    printf '%s\n' "$rows" | jq -Rn '[inputs | select(length > 0) | split("\t") | {name:.[0], summary:.[1], usage:.[2]}]'
  elif [ "$want_set" = 1 ]; then
    printf '%s\n' "$rows" | awk -F'\t' '{ print $1 " — " $2; print "  " $3 }'
  else
    [ -n "$rows" ] || { echo "No extra commands are installed (lib/x-*.sh)."; return 0; }
    printf '%s\n' "$rows" | awk -F'\t' '{ printf "  %-14s %s\n", $1, $2 }'
    echo "Usage of one: deploys more <command>"
  fi
}
# x-command: more | the extra commands (lib/x-*.sh): what each does and its usage | deploys more [<command>] [--json]
