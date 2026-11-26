# shellcheck shell=bash
# lib/x-checklist.sh — `deploys checklist`: your own "before you deploy" list per project (checklists.json).
#
#   deploys checklist [<project>] [--json]          the points for a project (and the "*" points for all), or every list
#   deploys checklist add <project|*> "text"        add a point (200 characters; a text that looks like a secret is refused)
#   deploys checklist remove <project|*> <n>        take away point n (the numbers the list shows)
#
# It is a reminder, never a gate: nothing waits for a tick and no deploy command reads it, so it cannot hold anything back
# or let anything through. checklists.json is {"<project>": ["point", ...], "*": ["point for every project"]}.
# `add` and `remove` change that file (refused in observer mode). Sourced by deploys; uses CONFIG_DIR, atomic_write,
# note_text (lib/notes.sh), require_write and die.
# x-command: checklist | your own list of points to look at before deploying a project (a reminder, never a gate) | deploys checklist [<project>] [--json] | add <project|*> "text" | remove <project|*> <n>

checklist_file() { printf '%s' "$CONFIG_DIR/checklists.json"; }

# checklist_for <project>: JSON {project, points:[{scope, n, text}]} from stdin (the file's JSON or {}).
checklist_for() {
  jq -c --arg p "$1" '
    (if type == "object" then . else {} end) as $c
    | { project: $p, points: ( [ ($c["*"] // []) | to_entries[] | {scope: "*", n: (.key + 1), text: (.value | tostring)} ]
                               + (if $p == "" or $p == "*" then [] else [ ($c[$p] // []) | to_entries[] | {scope: $p, n: (.key + 1), text: (.value | tostring)} ] end) ) }'
}

x_checklist_main() {
  local f; f="$(checklist_file)"
  case "${1:-}" in
    add)
      [ "$#" -ge 3 ] || die "Usage: deploys checklist add <project|*> \"text\""
      local p="$2" t cur='{}'; shift 2
      case "$p" in *[!A-Za-z0-9._:/@*-]*|'') die "A project name has letters, digits and . _ : / @ - only (or * for every project)" ;; esac
      declare -F note_text >/dev/null || die "lib/notes.sh is not next to deploys."
      t="$(note_text "$*")" || exit 1
      require_write "checklist add"
      if [ -s "$f" ]; then cur="$(jq -c 'if type == "object" then . else error("not an object") end' "$f" 2>/dev/null)" || die "$f is not a JSON object; deploys lint says what is wrong"; fi
      [ "$(jq --arg p "$p" '(.[$p] // []) | length' <<<"$cur")" -lt 30 ] || die "30 points for $p are enough"
      jq --arg p "$p" --arg t "$t" '.[$p] = ((.[$p] // []) + [$t])' <<<"$cur" | atomic_write "$f" || die "Could not write $f"
      echo "Added to the checklist for $p: $t"; return 0 ;;
    remove)
      [ "$#" -eq 3 ] || die "Usage: deploys checklist remove <project|*> <n>"
      case "$3" in ''|*[!0-9]*|0) die "<n> is a point number, 1 or more" ;; esac
      [ -s "$f" ] || die "There is no checklist yet."
      require_write "checklist remove"
      [ "$(jq --arg p "$2" --argjson n "$3" '(.[$p] // []) | length >= $n' "$f" 2>/dev/null)" = true ] || die "No point $3 for $2: deploys checklist $2"
      jq --arg p "$2" --argjson n "$3" '.[$p] |= (to_entries | map(select(.key != ($n - 1)) | .value)) | if (.[$p] | length) == 0 then del(.[$p]) else . end' "$f" | atomic_write "$f" || die "Could not write $f"
      echo "Removed point $3 of $2."; return 0 ;;
  esac
  local p="" src=/dev/null out
  while [ "$#" -gt 0 ]; do
    case "$1" in
      -*) die "Unknown option $1. Usage: deploys checklist [<project>] [--json] | add <project|*> \"text\" | remove <project|*> <n>" ;;
      *) [ -z "$p" ] || die "Usage: deploys checklist [<project>] [--json]"; p="$1" ;;
    esac
    shift
  done
  if [ -s "$f" ]; then jq -e . "$f" >/dev/null 2>&1 || die "$f is not valid JSON; deploys lint says what is wrong"; src="$f"; fi
  if [ -z "$p" ]; then
    if [ "${json:-0}" = 1 ]; then if [ "$src" = /dev/null ]; then echo '{}'; else jq . "$src"; fi; return 0; fi
    [ "$src" != /dev/null ] || { echo "No checklists. Add a point: deploys checklist add <project|*> \"text\""; return 0; }
    jq -r 'to_entries[] | "\(.key):", (.value | to_entries[] | "  \(.key + 1). \(.value)")' "$src"; return 0
  fi
  if [ "$src" = /dev/null ]; then out="$(echo '{}' | checklist_for "$p")"; else out="$(checklist_for "$p" < "$src")"; fi
  if [ "${json:-0}" = 1 ]; then jq . <<<"$out"
  elif [ "$(jq '.points | length' <<<"$out")" = 0 ]; then echo "No points for $p. Add one: deploys checklist add $p \"text\""
  else
    echo "Before you deploy $p (a reminder; nothing waits for it):"
    jq -r '.points[] | "  [ ] \(.text)\(if .scope == "*" then "   (all projects)" else "" end)"' <<<"$out"
  fi
}
