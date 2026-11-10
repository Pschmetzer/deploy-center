# lib/hooks.sh — `deploys hooks install|uninstall|status`: the pre-push check of
# integrations/hooks/pre-push in a git repo, next to a pre-push hook that is already there.
#
# What install writes into the repo's hooks folder (git's own, or core.hooksPath):
#   pre-push          a small wrapper (marked "deploy-center hooks"): it reads the refs git hands
#                     on stdin once, gives them to pre-push.local first (when there is one; its
#                     "no" stops the push), then to pre-push.deploys
#   pre-push.deploys  a copy of integrations/hooks/pre-push (install again after an update)
#   pre-push.local    the hook that was there before, moved aside (uninstall puts it back)
# Husky keeps its hooks in .husky/ and writes git's hooks folder itself: there install only says
# which line to add. Sourced by deploys; uses die and SELF from there.

HOOKS_MARK="deploy-center hooks"

# The pre-push of this install: in a checkout and the CLI tarball, integrations/hooks/ next to deploys.
hooks_source() {
  local d f
  for d in "${DEPLOYS_DIR:-}" "$(dirname "$SELF")"; do
    f="$d/integrations/hooks/pre-push"; [ -n "$d" ] && [ -f "$f" ] && { echo "$f"; return 0; }
  done
  return 1
}

# The folder git runs hooks from, absolute. core.hooksPath counts (git rev-parse knows it).
hooks_dir() {  # hooks_dir <repo>
  local d; d="$(git -C "$1" rev-parse --git-path hooks 2>/dev/null)" || return 1
  case "$d" in /*) ;; *) d="$(cd "$1" && cd "$(dirname "$d")" && pwd)/$(basename "$d")" ;; esac
  echo "$d"
}

hooks_ours() { [ -f "$1" ] && grep -q "$HOOKS_MARK" "$1" 2>/dev/null; }

hooks_husky() {  # hooks_husky <repo> <hooks dir>: Husky manages this repo's hooks
  case "$2" in */.husky|*/.husky/*) return 0 ;; esac
  [ -d "$1/.husky" ]
}

hooks_status_json() {  # hooks_status_json <repo>
  local repo="$1" d hp=""; d="$(hooks_dir "$repo")" || die "$repo is no git repo."
  hp="$(git -C "$repo" config core.hooksPath 2>/dev/null || true)"
  local ours=false local_=false husky=false copy=false
  hooks_ours "$d/pre-push" && ours=true
  [ -f "$d/pre-push.local" ] && local_=true
  [ -f "$d/pre-push.deploys" ] && copy=true
  hooks_husky "$repo" "$d" && husky=true
  jq -nc --arg d "$d" --arg hp "$hp" --argjson o "$ours" --argjson l "$local_" --argjson c "$copy" --argjson h "$husky" \
    '{hooksDir:$d, hooksPath:(if $hp == "" then null else $hp end), installed:($o and $c), chained:($o and $l), husky:$h}'
}

hooks_install() {  # hooks_install <repo>
  local repo="$1" src d
  src="$(hooks_source)" || die "integrations/hooks/pre-push is not next to deploys. Install from a checkout or the CLI tarball, or set DEPLOYS_DIR."
  d="$(hooks_dir "$repo")" || die "$repo is no git repo."
  if hooks_husky "$repo" "$d" && ! hooks_ours "$d/pre-push"; then
    echo "Husky manages the hooks here. Add this line to .husky/pre-push (it reads the refs git hands on stdin):"
    echo "  DEPLOYS=\"$SELF\" \"$src\" \"\$@\""
    return 0
  fi
  mkdir -p "$d" || die "Could not make $d."
  if [ -e "$d/pre-push" ] && ! hooks_ours "$d/pre-push"; then
    [ ! -e "$d/pre-push.local" ] || die "$d has a pre-push and a pre-push.local already: nothing was changed. Move one of them away first."
    mv "$d/pre-push" "$d/pre-push.local" || die "Could not move the old pre-push aside."
    echo "The pre-push that was there is now pre-push.local and runs first."
  fi
  cp "$src" "$d/pre-push.deploys" && chmod +x "$d/pre-push.deploys" || die "Could not copy the hook to $d."
  cat > "$d/pre-push" <<HOOK || die "Could not write $d/pre-push."
#!/bin/bash
# $HOOKS_MARK: written by \`deploys hooks install\`, removed by \`deploys hooks uninstall\`.
# Runs pre-push.local (the hook that was here before) and then pre-push.deploys, both with the
# refs git hands on stdin. A "no" from pre-push.local stops the push; the deploys check only warns
# (unless git config deploys.prepush.block true).
here="\$(cd "\$(dirname "\$0")" && pwd)"
refs="\$(cat)"; [ -z "\$refs" ] || refs="\$refs"\$'\\n'
if [ -x "\$here/pre-push.local" ]; then printf '%s' "\$refs" | "\$here/pre-push.local" "\$@" || exit \$?; fi
[ -x "\$here/pre-push.deploys" ] || exit 0
printf '%s' "\$refs" | DEPLOYS="\${DEPLOYS:-$SELF}" "\$here/pre-push.deploys" "\$@"
HOOK
  chmod +x "$d/pre-push"
  echo "Installed: before each push, $repo says which builds the push would start ($d/pre-push)."
}

hooks_uninstall() {  # hooks_uninstall <repo>
  local repo="$1" d; d="$(hooks_dir "$repo")" || die "$repo is no git repo."
  if ! hooks_ours "$d/pre-push"; then
    [ ! -e "$d/pre-push.deploys" ] || rm -f "$d/pre-push.deploys"
    echo "No pre-push from deploys hooks install here: nothing to remove."; return 0
  fi
  rm -f "$d/pre-push" "$d/pre-push.deploys"
  if [ -e "$d/pre-push.local" ]; then mv "$d/pre-push.local" "$d/pre-push"; echo "Removed; the old pre-push is back."
  else echo "Removed."; fi
}
