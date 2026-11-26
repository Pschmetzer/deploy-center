# shellcheck shell=bash
# lib/locks.sh — `deploys lock <project> "why"`, `deploys unlock <project>`, `deploys lock [list] [--json]`: one project is closed
# for starts until someone opens it again, with no time window (`freeze` closes every project at set times). A start of a locked
# project is refused like one inside a deploy window: only --force "why" goes ahead, and the journal says so.
# The locks are in project-locks.json in the config folder: {"<project>": {"reason", "at", "by"}}.
# Sourced by deploys; uses CONFIG_DIR, die, journal_add, atomic_write, is_provider, table.

LOCKS_FILE="${DEPLOYS_LOCKS:-$CONFIG_DIR/project-locks.json}"

# lock_name <project or platform:project>: the bare project name.
lock_name() { local n="$1"; if [ "${n#*:}" != "$n" ] && is_provider "${n%%:*}"; then n="${n#*:}"; fi; printf '%s' "$n"; }

# lock_denied <project>: the lock's text when that project is locked, nothing otherwise.
lock_denied() {
  [ -s "$LOCKS_FILE" ] || return 0
  jq -r --arg n "$(lock_name "$1")" 'if type == "object" and (.[$n] | type) == "object" then "\($n) is locked: \(.[$n].reason // "no reason")" + (if .[$n].at then " (since \(.[$n].at[0:10]))" else "" end) + ". Open it with: deploys unlock \($n)" else empty end' "$LOCKS_FILE" 2>/dev/null || true
}

locks_main() {  # locks_main lock|unlock [args...]
  local cmd="$1"; shift
  local cur='{}' n reason by
  [ ! -s "$LOCKS_FILE" ] || cur="$(jq -c 'if type == "object" then . else {} end' "$LOCKS_FILE" 2>/dev/null)" || cur='{}'
  if [ "$cmd" = lock ] && { [ "$#" = 0 ] || [ "$1" = list ] || [ "$1" = --json ]; }; then
    if [ "${json:-0}" = 1 ] || [ "${1:-}" = --json ]; then echo "$cur"; exit 0; fi
    if [ "$cur" = '{}' ]; then echo "No project is locked."; exit 0; fi
    echo "$cur" | jq -r 'to_entries[] | [.key, (.value.at // "")[0:10], (.value.by // "-"), (.value.reason // "")] | @tsv' \
      | (printf 'PROJECT\tSINCE\tBY\tREASON\n'; cat) | table
    exit 0
  fi
  n="${1:-}"; shift || true
  [[ "$n" =~ ^[A-Za-z0-9._:-]{1,100}$ ]] || die "Usage: deploys lock <project> \"why\" | deploys unlock <project> | deploys lock [list] [--json]"
  n="$(lock_name "$n")"
  case "$cmd" in
    lock)
      reason="$*"
      [ -n "$reason" ] || die "Usage: deploys lock <project> \"why\" (a lock without a reason is no use to the next person)"
      by="${USER:-$(id -un 2>/dev/null || echo unknown)}"
      printf '%s' "$cur" | jq --arg n "$n" --arg r "$reason" --arg by "$by" '. + {($n): {reason:$r, at:(now | floor | todate), by:$by}}' | atomic_write "$LOCKS_FILE" \
        || die "Could not write $LOCKS_FILE."
      journal_add local "$n" locked "Locked: $reason" || true
      echo "$n is locked: $reason. Starts are refused until: deploys unlock $n" ;;
    unlock)
      [ "$(printf '%s' "$cur" | jq --arg n "$n" 'has($n)')" = true ] || { echo "$n was not locked."; exit 0; }
      printf '%s' "$cur" | jq --arg n "$n" 'del(.[$n])' | atomic_write "$LOCKS_FILE" || die "Could not write $LOCKS_FILE."
      journal_add local "$n" unlocked "Unlocked" || true
      echo "$n is open again." ;;
  esac
  exit 0
}
