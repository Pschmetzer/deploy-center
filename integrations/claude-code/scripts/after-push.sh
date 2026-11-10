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
# The `if` rule in hooks.json already narrows this to git push; check again, it costs nothing.
case "$cmd" in *"git push"*|*"git "*" push"*) ;; *) exit 0 ;; esac
[ "$(jq -r '.tool_response.interrupted // false' <<<"$input" 2>/dev/null)" = true ] && exit 0

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
[ -n "$cwd" ] && [ -d "$cwd" ] || cwd="$PWD"
git -C "$cwd" rev-parse --git-dir >/dev/null 2>&1 || exit 0
remote=origin
set -f   # split the command into words on purpose, without expanding globs
# shellcheck disable=SC2086
set -- ${cmd#*push}
set +f
for w in "$@"; do
  case "$w" in -*) continue ;; '&&'|';'|'|'|'||') break ;; esac
  git -C "$cwd" remote get-url "$w" >/dev/null 2>&1 && remote="$w"
  break
done
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

msg="$(jq -r --arg repo "$repo" '
  if type != "array" then empty else
  map(select((.repo // "" | ascii_downcase) == ($repo | ascii_downcase)))
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
