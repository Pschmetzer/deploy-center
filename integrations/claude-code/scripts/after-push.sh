#!/bin/bash
# after-push.sh — Claude Code PostToolUse hook (plugin deploy-center). After Claude runs
# `git push`, print one line such as
#   3 commits waiting on app-web: deploy when ready (deploys changed)
# for the projects that deploy from the pushed repository.
#
# Read-only: it calls `deploys changed --json` and nothing else. It never deploys.
# Silent (exit 0, no output) when: the command was not a git push (`git stash push`, a
# `--dry-run`, a rejected or failed push do not count), `deploys` or `jq` is missing,
# the remote is not a known git URL, nothing is waiting, the CLI does not answer in time, or the
# reminder is turned off (plugin option push_reminder, or DEPLOYS_PUSH_REMINDER=off).
#
# With --session-start (SessionStart hook, opt-in: plugin option session_hint): the same line at the
# start of a session, for the repository of the session's folder, every branch. No push needed.
#
# Input: the hook JSON on stdin (tool_input.command, cwd).
# Output: JSON with systemMessage (shown to the user) and additionalContext (for Claude).
# Env: DEPLOYS                 the CLI to call (default: the app bundle, then deploys on PATH)
#      DEPLOYS_HOOK_TIMEOUT    seconds to wait for the CLI (default 15)

input="$(cat)"   # read all of stdin first, so Claude Code never writes into a closed pipe
mode=push; [ "${1:-}" = --session-start ] && mode=session
if [ "$mode" = push ]; then
  for v in "${DEPLOYS_PUSH_REMINDER:-}" "${CLAUDE_PLUGIN_OPTION_PUSH_REMINDER:-}"; do
    case "$v" in off|false|0|no) exit 0 ;; esac
  done
else
  # Off unless turned on: it asks GitHub at every session start.
  case "${DEPLOYS_SESSION_HINT:-${CLAUDE_PLUGIN_OPTION_SESSION_HINT:-}}" in on|true|1|yes) ;; *) exit 0 ;; esac
fi
command -v jq >/dev/null 2>&1 || exit 0

cmd="$(jq -r '.tool_input.command // empty' <<<"$input" 2>/dev/null)"
cwd="$(jq -r '.cwd // empty' <<<"$input" 2>/dev/null)"
[ "$mode" = session ] && cmd="git push --all"   # every branch of origin counts
# hooks.json runs this after every Bash call (an `if` rule would miss `cd dir && git push` and
# `git -C dir push`), so anything that is not a push ends here, before any other work.
case "$cmd" in *"git push"*|*"git "*" push"*) ;; *) exit 0 ;; esac
[ "$(jq -r '.tool_response.interrupted // false' <<<"$input" 2>/dev/null)" = true ] && exit 0
# A push that did not happen: rejected, or git gave up.
case "$(jq -r '.tool_response.stderr // empty' <<<"$input" 2>/dev/null)" in
  *"[rejected]"*|*"failed to push"*|*"fatal:"*) exit 0 ;;
esac
[ -n "$cwd" ] && [ -d "$cwd" ] || cwd="$PWD"

# Which command was the push, and in which folder. The command is split at && || ; | and
# newlines; `cd dir` changes the folder for what follows, `git -C dir` for that git only.
# Only `git [options] push`: not `git stash push`, not `--dry-run`/`-n`.
resolve() {  # resolve <base> <path>: the folder, or nothing when it does not exist
  local t="${2#[\"\']}"; t="${t%[\"\']}"
  case "$t" in \~) t="$HOME" ;; \~/*) t="$HOME/${t#\~/}" ;; /*) ;; *) t="$1/$t" ;; esac
  [ -d "$t" ] && (cd "$t" 2>/dev/null && pwd)
}
dir="$cwd" pushdir="" pushargs=()
segment() {
  local i=0 n=${#seg[@]} w d
  [ "$n" -gt 0 ] || return 0
  while [ "$i" -lt "$n" ] && [[ "${seg[$i]}" == [A-Za-z_]*=* ]]; do i=$((i+1)); done
  w="${seg[$i]:-}"
  if [ "$w" = cd ]; then d="$(resolve "$dir" "${seg[$((i+1))]:-~}")"; dir="${d:-$dir}"; return 0; fi
  [ "$w" = git ] || return 0
  d="$dir"; i=$((i+1))
  while [ "$i" -lt "$n" ]; do
    case "${seg[$i]}" in
      -C) d="$(resolve "$d" "${seg[$((i+1))]:-}")"; [ -n "$d" ] || return 0; i=$((i+2)) ;;
      -c|--git-dir|--work-tree|--namespace|--exec-path) i=$((i+2)) ;;
      -*) i=$((i+1)) ;;
      *) break ;;
    esac
  done
  [ "${seg[$i]:-}" = push ] || return 0
  local a args=("${seg[@]:$((i+1))}")
  for a in ${args[@]+"${args[@]}"}; do case "$a" in --dry-run|-n) return 0 ;; esac; done
  pushdir="$d"; pushargs=(${args[@]+"${args[@]}"})
}
words="$cmd"
for sep in '&&' '||' ';' '|' $'\n'; do words="${words//"$sep"/ ; }"; done
seg=()
set -f   # split the command into words on purpose, without expanding globs
# shellcheck disable=SC2086
set -- $words
set +f
for w in "$@"; do
  if [ "$w" = ";" ]; then segment; seg=(); [ -n "$pushdir" ] && break; else seg+=("$w"); fi
done
[ -n "$pushdir" ] || { segment; }
[ -n "$pushdir" ] || exit 0
cwd="$pushdir"


# The CLI: DEPLOYS if set (and nothing else), then the app bundle, then PATH (the order of the
# MCP server and the editor add-ons: an older deploys on PATH does not win over the app's).
if [ -n "${DEPLOYS:-}" ]; then bin="$DEPLOYS"
else
  bin=""
  for c in "/Applications/Deploy Center.app/Contents/Resources/deploys" \
           "$HOME/Applications/Deploy Center.app/Contents/Resources/deploys"; do
    [ -x "$c" ] && { bin="$c"; break; }
  done
  [ -n "$bin" ] || bin="$(command -v deploys 2>/dev/null)"
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
# The repo as deploys names it: owner/name on GitHub, host/group[/sub]/name elsewhere (GitLab:
# gitlab.com/group/name, see docs/GITLAB.md).
hostpath="$(printf '%s' "$url" | sed -E 's#^(ssh://)?([^@/]*@)?##; s#^https?://([^@/]*@)?##; s#^([^:/]+):([0-9]+/)?#\1/#; s#\.git$##; s#/$##')"
case "$hostpath" in
  github.com/*/*) repo="${hostpath#github.com/}"; case "$repo" in */*/*) exit 0 ;; esac ;;
  */*/*) repo="$hostpath" ;;
  *) exit 0 ;;
esac
case "$repo" in *[!A-Za-z0-9._/-]*|'') exit 0 ;; esac

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
  map(select((.repo // "" | ascii_downcase | sub("^github\\.com/"; "")) == ($repo | ascii_downcase)))
  | map(select($br == "" or (.ref // "") == "" or .ref == $br))
  | map(if (.pendingCommits | type) == "number"
        then "\(.pendingCommits) commit\(if .pendingCommits == 1 then "" else "s" end) waiting on \(.name)"
        else "changes waiting on \(.name)" end)
  | if length == 0 then empty else "\(join(", ")): deploy when ready (deploys changed)" end
  end' "$tmp/out" 2>/dev/null)"
[ -n "$msg" ] || exit 0

if [ "$mode" = session ]; then
  jq -cn --arg m "$msg" '{
    systemMessage: ("Deploy Center: " + $m),
    hookSpecificOutput: {
      hookEventName: "SessionStart",
      additionalContext: ("Deploy Center: " + $m + ". Auto-deploy is off. Mention it only if the user asks about deploys or before they ship. Do not deploy unless the user explicitly says so.")
    }
  }'
  exit 0
fi
jq -cn --arg m "$msg" '{
  systemMessage: $m,
  hookSpecificOutput: {
    hookEventName: "PostToolUse",
    additionalContext: ("Deploy Center: " + $m + ". Auto-deploy is off, so this push did not go live. Tell the user in one line. Do not deploy unless the user explicitly says so.")
  }
}'
exit 0
