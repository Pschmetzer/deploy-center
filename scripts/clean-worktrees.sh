#!/bin/bash
# Lists the stale agent worktrees in .claude/worktrees/ and, only with --remove, removes the safe ones.
#   scripts/clean-worktrees.sh                 list: every worktree, what state it is in and why it is kept or stale
#   scripts/clean-worktrees.sh --remove        remove the stale ones (git worktree remove, never --force)
#   scripts/clean-worktrees.sh --hours N       younger than N hours counts as active (default 24)
# A worktree is stale only when ALL of these hold; anything else is kept and the reason is printed:
#   - nothing uncommitted (no changes, no untracked files)
#   - no commit that is neither in origin/main nor on a pushed branch
#   - no running process has its working directory in it (a session of Claude Code, an editor, a build)
#   - it is not the folder this script runs in
#   - it was not touched for N hours
# A removed worktree's branch is deleted with `git branch -d` (git itself refuses an unmerged one).
set -uo pipefail
remove=0 hours=24
while [ $# -gt 0 ]; do
  case "$1" in
    --remove) remove=1 ;;
    --hours) [ $# -ge 2 ] && [ "$2" -ge 0 ] 2>/dev/null || { echo "clean-worktrees: --hours needs a number" >&2; exit 2; }; hours="$2"; shift ;;
    -h|--help) sed -n '2,13p' "$0" | sed 's/^# \{0,1\}//'; exit 0 ;;
    *) echo "clean-worktrees: unknown option $1 (see --help)" >&2; exit 2 ;;
  esac
  shift
done

# The main checkout, from any worktree: the first entry of the list.
main="$(git worktree list --porcelain 2>/dev/null | sed -n 's/^worktree //p' | head -1)"
[ -n "$main" ] || { echo "clean-worktrees: not in a git repository" >&2; exit 1; }
here="$(pwd -P)"
git -C "$main" fetch -q origin 2>/dev/null || echo "clean-worktrees: fetch failed, going by the last known origin/main" >&2

# Working directories of every running process of this user (macOS and Linux).
cwds="$(lsof -a -d cwd -Fn -u "$(id -u)" 2>/dev/null | sed -n 's/^n//p')"
now="$(date +%s)"
kept=0 stale=0 removed=0
mtime() { stat -f %m "$1" 2>/dev/null || stat -c %Y "$1" 2>/dev/null || echo 0; }

while IFS= read -r wt; do
  [ -n "$wt" ] || continue
  case "$wt" in */.claude/worktrees/*) ;; *) continue ;; esac
  name="${wt##*/}"
  [ -d "$wt" ] || { echo "kept   $name: folder is gone (run: git worktree prune)"; kept=$((kept+1)); continue; }
  real="$(cd "$wt" && pwd -P)"
  why=""
  case "$here/" in "$real/"*) why="this is the folder the script runs in" ;; esac
  if [ -z "$why" ] && [ -n "$cwds" ] && printf '%s\n' "$cwds" | grep -F -x -e "$real" -e "$wt" >/dev/null 2>&1; then why="a running process works in it"; fi
  if [ -z "$why" ] && printf '%s\n' "$cwds" | grep -F "$real/" >/dev/null 2>&1; then why="a running process works in it"; fi
  if [ -z "$why" ] && [ -n "$(git -C "$wt" status --porcelain 2>/dev/null)" ]; then why="uncommitted changes or untracked files"; fi
  if [ -z "$why" ]; then
    # Commits on no remote branch: they would be lost with the worktree.
    lost="$(git -C "$wt" log --oneline HEAD --not --remotes 2>/dev/null | wc -l | tr -d ' ')"
    [ "$lost" = 0 ] || why="$lost commit(s) not on any remote branch"
  fi
  if [ -z "$why" ]; then
    gitdir="$(git -C "$wt" rev-parse --git-dir 2>/dev/null)"; case "$gitdir" in /*) ;; *) gitdir="$wt/$gitdir" ;; esac
    # The last touch: the newest of HEAD, its log (a commit or checkout) and the folder. Not the index: git status rewrites it.
    newest=0
    for f in "$gitdir/HEAD" "$gitdir/logs/HEAD" "$wt"; do t="$(mtime "$f")"; [ "$t" -le "$newest" ] || newest="$t"; done
    age=$(( (now - newest) / 3600 ))
    [ "$age" -ge "$hours" ] || why="touched $age h ago (less than $hours h)"
  fi
  if [ -n "$why" ]; then echo "kept   $name: $why"; kept=$((kept+1)); continue; fi
  stale=$((stale+1))
  if [ "$remove" = 1 ]; then
    branch="$(git -C "$wt" symbolic-ref -q --short HEAD 2>/dev/null || true)"
    if git -C "$main" worktree remove "$wt" 2>/dev/null; then
      removed=$((removed+1)); echo "removed $name"
      [ -z "$branch" ] || git -C "$main" branch -d "$branch" >/dev/null 2>&1 || true
    else
      echo "kept   $name: git refused to remove it"; stale=$((stale-1)); kept=$((kept+1))
    fi
  else
    echo "stale  $name"
  fi
done < <(git -C "$main" worktree list --porcelain | sed -n 's/^worktree //p')

echo "$kept kept, $stale stale$([ "$remove" = 1 ] && echo ", $removed removed")$([ "$remove" = 0 ] && [ "$stale" -gt 0 ] && echo " (run with --remove to remove them)")"
