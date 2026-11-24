# shellcheck shell=bash
# lib/groups.sh — `deploys group`: your own ordered groups ("first api, then web"), kept in groups.json of the config folder
# (not in the repo). A run deploys the members one after the other, each one waited for until it is live, and stops at the
# first failure. It never starts without a clear yes: --yes, or an answer "y" on a terminal. Without either it only shows
# the order and what each member would do, and starts nothing. Team groups of the shared config stay `deploys deploy group:<name>`.
#
#   deploys group list [--json]
#   deploys group add <name> <project> <project>...    (replaces a group of that name)
#   deploys group remove <name>
#   deploys group run <name> [--preview] [--yes]
# Sourced by deploys; uses CONFIG_DIR, atomic_write, safe_name, require_write, window_json, die.

GROUPS_FILE="$CONFIG_DIR/groups.json"

groups_read() { [ -f "$GROUPS_FILE" ] && jq -c 'if type == "object" then . else {} end' "$GROUPS_FILE" 2>/dev/null || echo '{}'; }

# groups_add_json <groups JSON> <name> <member>...: the groups with <name> set. Pure.
groups_add_json() {
  local g="$1" n="$2"; shift 2
  printf '%s\n' "$@" | jq -Rn --argjson g "$g" --arg n "$n" '[inputs | select(length > 0)] as $m | $g + {($n): $m}'
}

groups_remove_json() { jq -c --arg n "$2" 'del(.[$n])' <<< "$1"; }

groups_print() {  # stdin: groups JSON
  jq -r 'if length == 0 then "No groups yet: deploys group add <name> <first> <then>..." else to_entries[] | "\(.key): \(.value | join(" -> "))" end'
}

groups_main() {
  local cmd="${1:-list}" name g
  [ "$#" -eq 0 ] || shift
  case "$cmd" in
    list) groups_read | { if [ "${json:-0}" = 1 ]; then jq .; else groups_print; fi; } ;;
    add)
      name="${1:-}"; [ "$#" -ge 3 ] || die_usage "Usage: deploys group add <name> <project> <project>..."
      [[ "$name" =~ ^[A-Za-z0-9._-]+$ ]] || die "A group name is letters, digits, . _ - only."
      shift
      local m; for m in "$@"; do safe_name "$m"; done
      groups_add_json "$(groups_read)" "$name" "$@" | atomic_write "$GROUPS_FILE" || die "Could not write $GROUPS_FILE."
      echo "Group $name: $*" | sed 's/ /, /2g;s/, / -> /g' ;;
    remove)
      name="${1:-}"; [ -n "$name" ] || die_usage "Usage: deploys group remove <name>"
      g="$(groups_read)"; jq -e --arg n "$name" 'has($n)' <<<"$g" >/dev/null || die "No group named \"$name\"."
      groups_remove_json "$g" "$name" | atomic_write "$GROUPS_FILE" || die "Could not write $GROUPS_FILE."
      echo "Group $name removed." ;;
    run) groups_run "$@" ;;
    *) die "Usage: deploys group list [--json] | add <name> <project>... | remove <name> | run <name> [--preview] [--yes]" ;;
  esac
}

groups_run() {
  local name="" pv="" yes="" members m n i=0 ans
  while [ "$#" -gt 0 ]; do
    case "$1" in
      --preview) pv=1 ;; --yes) yes=1 ;;
      -*) die "Unknown option $1. Usage: deploys group run <name> [--preview] [--yes]" ;;
      *) [ -z "$name" ] || die "Usage: deploys group run <name> [--preview] [--yes]"; name="$1" ;;
    esac
    shift
  done
  [ -n "$name" ] || die_usage "Usage: deploys group run <name> [--preview] [--yes]"
  members="$(groups_read | jq -r --arg n "$name" '.[$n] // empty | .[]')"
  [ -n "$members" ] || die "No group named \"$name\": deploys group list"
  n="$(echo "$members" | grep -c .)"
  echo "Group $name, in this order:"
  for m in $members; do i=$((i + 1)); echo "  $i. $m${pv:+ (preview)}"; done
  # The deploy window is asked for the whole group before the first member starts: a window must not stop a group halfway.
  if [ -z "$pv" ]; then
    if [ "$(window_json | jq -r .denied)" = true ]; then
      [ "${forced:-0}" = 1 ] || die "No deploys now: the deploy window says \"$(window_json | jq -r .reason)\". Nothing was started. To deploy anyway: --force \"why\""
    fi
  fi
  if [ -z "$yes" ]; then
    if [ -t 0 ] && [ -t 1 ]; then
      printf 'Start these %s deploys one after the other, stopping at the first failure? [y/N] ' "$n"
      read -r ans || ans=""
      case "$ans" in y|Y|yes|YES) ;; *) echo "Nothing was started."; return 0 ;; esac
    else
      echo "Nothing was started. To start: deploys group run $name --yes"
      return 0
    fi
  fi
  require_write "group run"
  i=0
  for m in $members; do
    i=$((i + 1))
    echo "[$i/$n] $m"
    if ! "$SELF" deploy "$m" --wait ${pv:+--preview}; then
      echo "$m did not go live; the rest of the group was not started." >&2
      return 1
    fi
  done
  echo "Group $name is live."
}
