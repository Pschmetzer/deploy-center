#!/bin/bash
# deploys-open.sh — the ⌘↵ action of the Alfred filter: "open <name>" → deploys open <name>.
# Only a project name passes (letters, digits, . _ : -); anything else is refused.
set -euo pipefail
export PATH="$PATH:/opt/homebrew/bin:/usr/local/bin"
arg="${1:-}"; name="${arg#open }"
[[ "$arg" == "open "* && "$name" =~ ^[A-Za-z0-9._:-]+$ ]] || { echo "Not a project: $arg" >&2; exit 1; }
bin="${DEPLOYS:-}"
if [ -z "$bin" ]; then
  for c in "/Applications/Deploy Center.app/Contents/Resources/deploys" "$HOME/Applications/Deploy Center.app/Contents/Resources/deploys"; do
    [ -x "$c" ] && { bin="$c"; break; }
  done
  [ -n "$bin" ] || bin="deploys"
fi
exec "$bin" open "$name"
