#!/bin/bash
# after-push.sh — Claude Code PostToolUse hook (plugin deploy-center). After Claude runs
# `git push`, print one line such as
#   3 commits waiting on app-web: deploy when ready (deploys changed)
# for the projects that deploy from the pushed repository.
#
# Read-only: it calls `deploys changed --json` and nothing else. It never deploys.
# Silent (exit 0, no output) when: the command was not a git push, `deploys` or `jq` is missing,
# the repository is not on GitHub, nothing is waiting, the CLI does not answer in time, or the
# reminder is turned off (plugin option push_reminder, or DEPLOYS_PUSH_REMINDER=off).
#
# Input: the hook JSON on stdin (tool_input.command, cwd).
# Output: JSON with systemMessage (shown to the user) and additionalContext (for Claude).
# Env: DEPLOYS                 the CLI to call (default: deploys on PATH, then the app bundle)
#      DEPLOYS_HOOK_TIMEOUT    seconds to wait for the CLI (default 15)

input="$(cat)"   # read all of stdin first, so Claude Code never writes into a closed pipe
for v in "${DEPLOYS_PUSH_REMINDER:-}" "${CLAUDE_PLUGIN_OPTION_PUSH_REMINDER:-}"; do
  case "$v" in off|false|0|no) exit 0 ;; esac
done
command -v jq >/dev/null 2>&1 || exit 0

cmd="$(jq -r '.tool_input.command // empty' <<<"$input" 2>/dev/null)"
cwd="$(jq -r '.cwd // empty' <<<"$input" 2>/dev/null)"
# A cheap first look; the word-by-word check below decides.
case "$cmd" in *git*push*) ;; *) exit 0 ;; esac
[ "$(jq -r '.tool_response.interrupted // false' <<<"$input" 2>/dev/null)" = true ] && exit 0
[ -n "$cwd" ] && [ -d "$cwd" ] || cwd="$PWD"

# Find `git [-C dir] [-c x=y] push <args>` where a command starts: at the beginning or after
# && ; | ||, after `VAR=value` prefixes. `cd dir && git push` and `git -C dir push` count;
# `echo "git push"` or a commit message that says "git push" does not (it is not at a command
# position). Quotes are not parsed; a quoted word just does not match.
set -f   # split the command into words on purpose, without expanding globs
# shellcheck disable=SC2086
set -- $cmd
set +f
atcmd=1 found=0 dir="$cwd" pushargs=()
while [ $# -gt 0 ]; do
  w="$1"; shift
  case "$w" in '&&'|';'|'|'|'||') atcmd=1; continue ;; esac
  if [ "$atcmd" = 1 ] && [ "$w" = cd ] && [ $# -gt 0 ]; then
    case "$1" in /*) dir="$1" ;; *) dir="$dir/$1" ;; esac; shift; continue
  fi
  if [ "$atcmd" = 1 ] && [[ "$w" == [A-Za-z_]*=* ]]; then continue; fi
  if [ "$atcmd" = 1 ] && [ "$w" = git ]; then
    while [ $# -gt 0 ]; do
      case "$1" in
        -C) [ $# -ge 2 ] || break; case "$2" in /*) dir="$2" ;; *) dir="$dir/$2" ;; esac; shift 2 ;;
        -c) shift 2 ;;
        -*) shift ;;
        *) break ;;
      esac
    done
    if [ "${1:-}" = push ]; then
      shift; found=1
      while [ $# -gt 0 ]; do
        case "$1" in '&&'|';'|'|'|'||') break ;; esac
        pushargs+=("$1"); shift
      done
      break
    fi
  fi
  atcmd=0
done
[ "$found" = 1 ] || exit 0
[ -d "$dir" ] && cwd="$dir"

# The CLI: DEPLOYS if set (and nothing else), then PATH, then the app bundle.
if [ -n "${DEPLOYS:-}" ]; then bin="$DEPLOYS"
else
  bin="$(command -v deploys 2>/dev/null)"
  for c in "/Applications/Deploy Center.app/Contents/Resources/deploys" \
           "$HOME/Applications/Deploy Center.app/Contents/Resources/deploys"; do
    [ -n "$bin" ] && break
    [ -x "$c" ] && bin="$c"
  done
fi
[ -n "$bin" ] && command -v "$bin" >/dev/null 2>&1 || exit 0

# Which remote: the first word after "push" that is not an option and names a remote, else origin.
# Which branch: the refspec after it ("main", "HEAD:main", "+x:main"), else the current branch.
# Unknown (--all, --tags, a detached HEAD): every branch counts.
git -C "$cwd" rev-parse --git-dir >/dev/null 2>&1 || exit 0
remote=origin branch="" spec="" nonopt=0 all=0
for w in ${pushargs[@]+"${pushargs[@]}"}; do
  case "$w" in --all|--mirror|--tags) all=1; continue ;; -*) continue ;; esac
  nonopt=$((nonopt + 1))
  if [ "$nonopt" = 1 ] && git -C "$cwd" remote get-url "$w" >/dev/null 2>&1; then remote="$w"; continue; fi
  [ "$nonopt" -le 2 ] && [ -z "$spec" ] && spec="$w"
done
if [ "$all" = 0 ]; then
  if [ -n "$spec" ]; then
    branch="${spec#+}"; branch="${branch##*:}"; branch="${branch#refs/heads/}"
    [ "$branch" = HEAD ] && branch="$(git -C "$cwd" symbolic-ref --short -q HEAD 2>/dev/null)"
  else
    branch="$(git -C "$cwd" symbolic-ref --short -q HEAD 2>/dev/null)"
  fi
fi
url="$(git -C "$cwd" remote get-url "$remote" 2>/dev/null)" || exit 0
repo="$(printf '%s' "$url" | sed -E 's#^(git@|ssh://git@|https?://([^@/]*@)?)github\.com[:/]##; s#\.git$##; s#/$##')"
case "$repo" in */*/*|*:*|'') exit 0 ;; */*) ;; *) exit 0 ;; esac

# Ask the CLI, but never longer than DEPLOYS_HOOK_TIMEOUT seconds.
tmp="$(mktemp -d 2>/dev/null)" || exit 0
trap 'rm -rf "$tmp"' EXIT
killtree() { local c; for c in $(pgrep -P "$1" 2>/dev/null); do killtree "$c"; done; kill "$1" 2>/dev/null; }
( exec "$bin" changed --json >"$tmp/out" 2>/dev/null </dev/null ) & pid=$!
limit="${DEPLOYS_HOOK_TIMEOUT:-15}"; case "$limit" in ''|*[!0-9]*) limit=15 ;; esac
waited=0
while kill -0 "$pid" 2>/dev/null; do
  if [ "$waited" -ge $((limit * 5)) ]; then killtree "$pid"; exit 0; fi
  sleep 0.2; waited=$((waited + 1))
done
# `changed --json` exits 1 when some project could not be read; the list it printed still counts.

# A push to a feature branch does not touch what a project deploys from: only projects whose
# branch (.ref) is the pushed one count, or all of them when the branch is unknown.
msg="$(jq -r --arg repo "$repo" --arg br "$branch" '
  if type != "array" then empty else
  map(select((.repo // "" | ascii_downcase) == ($repo | ascii_downcase)))
  | map(select($br == "" or (.ref // "") == "" or .ref == $br))
  | map(if (.pendingCommits | type) == "number"
        then "\(.pendingCommits) commit\(if .pendingCommits == 1 then "" else "s" end) waiting on \(.name)"
        else "changes waiting on \(.name)" end)
  | if length == 0 then empty else "\(join(", ")): deploy when ready (deploys changed)" end
  end' "$tmp/out" 2>/dev/null)"
[ -n "$msg" ] || exit 0

jq -cn --arg m "$msg" '{
  systemMessage: $m,
  hookSpecificOutput: {
    hookEventName: "PostToolUse",
    additionalContext: ("Deploy Center: " + $m + ". Auto-deploy is off, so this push did not go live. Tell the user in one line. Do not deploy unless the user explicitly says so.")
  }
}'
exit 0
