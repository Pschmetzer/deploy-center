# shellcheck shell=bash
# lib/hooks.sh — `deploys hooks install|uninstall|status`: the pre-push check of
# integrations/hooks/pre-push in a git repo, next to a pre-push hook that is already there.
#
# What install writes into the repo's hooks folder (git's own, or core.hooksPath):
#   pre-push          a small wrapper (marked "deploy-center hooks"): it reads the refs git hands
#                     on stdin once, gives them to pre-push.local first (when there is one; its
#                     "no" stops the push), then to pre-push.deploys
#   pre-push.deploys  a copy of integrations/hooks/pre-push (install again after an update)
#   pre-push.local    the hook that was there before, moved aside (uninstall puts it back)
# `--hook pre-commit` does the same for the commit: pre-commit.deploys runs `deploys secrets --stdin` on the staged changes
# and stops a commit that adds something that looks like a key or token (git config deploys.precommit.skip true: off).
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
  local ours=false local_=false husky=false copy=false lx=null
  hooks_ours "$d/pre-push" && ours=true
  # A pre-push.local that is not executable is skipped by git's own rules and by the wrapper: said, not silent.
  if [ -f "$d/pre-push.local" ]; then local_=true; if [ -x "$d/pre-push.local" ]; then lx=true; else lx=false; fi; fi
  [ -f "$d/pre-push.deploys" ] && copy=true
  hooks_husky "$repo" "$d" && husky=true
  jq -nc --arg d "$d" --arg hp "$hp" --argjson o "$ours" --argjson l "$local_" --argjson c "$copy" --argjson h "$husky" --argjson lx "$lx" \
    '{hooksDir:$d, hooksPath:(if $hp == "" then null else $hp end), installed:($o and $c), chained:($o and $l), husky:$h, localExecutable:$lx}'
}

# The scope of core.hooksPath: a global or system one makes the hook run in every repo that uses it.
hooks_path_scope() {  # hooks_path_scope <repo>: local, global, system, worktree, command or nothing
  { git -C "$1" config --show-scope --get core.hooksPath 2>/dev/null || true; } | awk '{ print $1 }'
}

# The pre-commit check, as a script: the staged changes through `deploys secrets --stdin`.
hooks_precommit_script() {
  cat <<'PC'
#!/bin/bash
# pre-commit.deploys: stops a commit that adds something that looks like a key or token (deploys secrets --stdin).
# git config deploys.precommit.skip true  turns it off. Any error in here lets the commit go.
DEPLOYS="${DEPLOYS:-deploys}"
[ "$(git config --bool deploys.precommit.skip 2>/dev/null)" = true ] && exit 0
command -v "$DEPLOYS" >/dev/null 2>&1 || exit 0
command -v jq >/dev/null 2>&1 || exit 0
res="$(git diff --cached -U0 --no-color 2>/dev/null | "$DEPLOYS" secrets --stdin --json 2>/dev/null)" || true
n="$(printf '%s' "$res" | jq -r '.found // 0' 2>/dev/null)" || exit 0
case "$n" in ""|0|*[!0-9]*) exit 0 ;; esac
echo "deploys: $n added line(s) look like a key or token (masked below). Commit stopped; git commit --no-verify to go on anyway." >&2
printf '%s' "$res" | jq -r '.hits[] | "  \(.file): \(.masked)"' >&2
exit 1
PC
}

hooks_install() {  # hooks_install <repo> [pre-push|pre-commit]; HOOKS_YES=1 for a global core.hooksPath
  local repo="$1" kind="${2:-pre-push}" src d scope hp
  case "$kind" in pre-push|pre-commit) ;; *) die "--hook is pre-push or pre-commit" ;; esac
  if [ "$kind" = pre-commit ]; then src="$(mktemp)"; hooks_precommit_script > "$src"; trap_fn exit_rm "$src"
  else src="$(hooks_source)" || die "integrations/hooks/pre-push is not next to deploys. Install from a checkout or the CLI tarball, or set DEPLOYS_DIR."; fi
  d="$(hooks_dir "$repo")" || die "$repo is no git repo."
  scope="$(hooks_path_scope "$repo")"
  if [ "$scope" = global ] || [ "$scope" = system ]; then
    hp="$(git -C "$repo" config --get core.hooksPath 2>/dev/null)"
    [ -n "${HOOKS_YES:-}" ] || die "core.hooksPath is set in your $scope git config ($hp): a hook put there runs in EVERY repo that uses it, not only $repo. To do that on purpose: add --yes. To keep it to this repo: git -C $repo config core.hooksPath .git/hooks, then install again."
  fi
  if hooks_husky "$repo" "$d" && ! hooks_ours "$d/$kind"; then
    echo "Husky manages the hooks here. Add this line to .husky/$kind$([ "$kind" = pre-push ] && echo " (it reads the refs git hands on stdin)"):"
    if [ "$kind" = pre-push ]; then echo "  DEPLOYS=\"$SELF\" \"$src\" \"\$@\""
    else echo "  git diff --cached -U0 --no-color | \"$SELF\" secrets --stdin >/dev/null || exit 1"; fi
    return 0
  fi
  mkdir -p "$d" || die "Could not make $d."
  if [ -e "$d/$kind" ] && ! hooks_ours "$d/$kind"; then
    [ ! -e "$d/$kind.local" ] || die "$d has a $kind and a $kind.local already: nothing was changed. Move one of them away first."
  fi
  # Everything new is written first; the old hook is only moved aside once that worked, so a full
  # disk or a missing right never leaves the repo without its hook.
  cp "$src" "$d/$kind.deploys.new" && chmod +x "$d/$kind.deploys.new" || { rm -f "$d/$kind.deploys.new"; die "Could not copy the hook to $d."; }
  # The hook runs from the repo's folder, so a relative path to deploys must be made absolute now.
  local self_abs="$SELF"; case "$self_abs" in /*) ;; *) self_abs="$(cd "$(dirname "$self_abs")" && pwd)/$(basename "$self_abs")" ;; esac
  local q_self; q_self="$(printf '%q' "$self_abs")"
  # pre-push gets the refs on stdin and hands them on; a pre-commit gets nothing on stdin, so none is read (it would wait).
  if [ "$kind" = pre-push ]; then
    cat > "$d/$kind.new" <<HOOK || { rm -f "$d/$kind.new" "$d/$kind.deploys.new"; die "Could not write $d/$kind."; }
#!/bin/bash
# $HOOKS_MARK: written by \`deploys hooks install\`, removed by \`deploys hooks uninstall\`.
# Runs pre-push.local (the hook that was here before) and then pre-push.deploys, both with the
# refs git hands on stdin. A "no" from pre-push.local stops the push; the deploys check only warns
# (unless git config deploys.prepush.block true).
deploys_default=$q_self
here="\$(cd "\$(dirname "\$0")" && pwd)"
refs="\$(cat)"; [ -z "\$refs" ] || refs="\$refs"\$'\\n'
if [ -f "\$here/pre-push.local" ] && [ ! -x "\$here/pre-push.local" ]; then echo "deploys: pre-push.local is not executable, so it was not run (chmod +x \$here/pre-push.local)" >&2; fi
if [ -x "\$here/pre-push.local" ]; then printf '%s' "\$refs" | "\$here/pre-push.local" "\$@" || exit \$?; fi
[ -x "\$here/pre-push.deploys" ] || exit 0
printf '%s' "\$refs" | DEPLOYS="\${DEPLOYS:-\$deploys_default}" "\$here/pre-push.deploys" "\$@"
HOOK
  else
    cat > "$d/$kind.new" <<HOOK || { rm -f "$d/$kind.new" "$d/$kind.deploys.new"; die "Could not write $d/$kind."; }
#!/bin/bash
# $HOOKS_MARK: written by \`deploys hooks install --hook pre-commit\`, removed by \`deploys hooks uninstall --hook pre-commit\`.
# Runs pre-commit.local (the hook that was here before) and then pre-commit.deploys (staged changes through
# deploys secrets --stdin). A "no" from either stops the commit.
deploys_default=$q_self
here="\$(cd "\$(dirname "\$0")" && pwd)"
if [ -f "\$here/pre-commit.local" ] && [ ! -x "\$here/pre-commit.local" ]; then echo "deploys: pre-commit.local is not executable, so it was not run (chmod +x \$here/pre-commit.local)" >&2; fi
if [ -x "\$here/pre-commit.local" ]; then "\$here/pre-commit.local" "\$@" || exit \$?; fi
[ -x "\$here/pre-commit.deploys" ] || exit 0
DEPLOYS="\${DEPLOYS:-\$deploys_default}" "\$here/pre-commit.deploys" "\$@"
HOOK
  fi
  chmod +x "$d/$kind.new"
  if [ -e "$d/$kind" ] && ! hooks_ours "$d/$kind"; then
    mv "$d/$kind" "$d/$kind.local" || { rm -f "$d/$kind.new" "$d/$kind.deploys.new"; die "Could not move the old $kind aside."; }
    echo "The $kind that was there is now $kind.local and runs first."
  fi
  mv "$d/$kind.deploys.new" "$d/$kind.deploys" || die "Could not install the hook in $d."
  # The second move failing must not leave the wrapper's half behind: put the first one back.
  mv "$d/$kind.new" "$d/$kind" || { rm -f "$d/$kind.deploys"; die "Could not install the hook in $d."; }
  if [ "$kind" = pre-push ]; then echo "Installed: before each push, $repo says which builds the push would start ($d/pre-push)."
  else echo "Installed: before each commit, $repo checks the staged changes for keys and tokens ($d/pre-commit)."; fi
}

hooks_uninstall() {  # hooks_uninstall <repo> [pre-push|pre-commit]
  local repo="$1" kind="${2:-pre-push}" d; d="$(hooks_dir "$repo")" || die "$repo is no git repo."
  case "$kind" in pre-push|pre-commit) ;; *) die "--hook is pre-push or pre-commit" ;; esac
  if ! hooks_ours "$d/$kind"; then
    [ ! -e "$d/$kind.deploys" ] || rm -f "$d/$kind.deploys"
    echo "No $kind from deploys hooks install here: nothing to remove."; return 0
  fi
  rm -f "$d/$kind" "$d/$kind.deploys"
  if [ -e "$d/$kind.local" ]; then mv "$d/$kind.local" "$d/$kind"; echo "Removed; the old $kind is back."
  else echo "Removed."; fi
}
