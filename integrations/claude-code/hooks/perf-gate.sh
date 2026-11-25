#!/bin/bash
# perf-gate.sh — Claude Code PreToolUse hook (matcher "Bash"): holds heavy commands (tsc, vitest, eslint, next build,
# playwright, npm run verify|test|build|typecheck|lint, xcodebuild, swift build, docker build, ./build.sh) until the Mac
# has room, through `deploys perf wait` (lib/perf.sh). Light commands pass at once, without starting anything.
# Exit 0 = run it. Exit 2 = not started: the Mac stayed overloaded (red) for the whole wait; the reason goes to Claude.
# Any error of the guard itself is exit 0: it never blocks work on its own fault. DEPLOYS_PERF_GATE=0 turns it off.
# Install: copy to ~/.claude/hooks/perf-gate.sh and add the entry `deploys perf hook` prints (timeout 660).
input="$(cat 2>/dev/null)" || exit 0
[ "${DEPLOYS_PERF_GATE:-1}" = 0 ] && exit 0
cmd="$(printf '%s' "$input" | jq -r '.tool_input.command // empty' 2>/dev/null)" || exit 0
[ -n "$cmd" ] || exit 0
case "$cmd" in *"perf gate"*|*"perf wait"*) exit 0 ;; esac

# Heavy only as a command of its own: at the start, or after && || ; | ( or a newline, past VAR=value and cd … &&.
# `grep tsc file` or `echo vitest` is not heavy.
heavy='(^|[;&|(])[[:space:]]*([A-Za-z_][A-Za-z0-9_]*=[^[:space:]]*[[:space:]]+)*(time[[:space:]]+)?'
heavy="$heavy"'((npx|pnpm[[:space:]]+exec|pnpm[[:space:]]+dlx|bunx|yarn)[[:space:]]+)?'
heavy="$heavy"'(tsc|vitest|jest|eslint|playwright|next[[:space:]]+build|xcodebuild|swift[[:space:]]+build|swift[[:space:]]+test|docker[[:space:]]+(build|compose[[:space:]]+build)|\./build\.sh'
heavy="$heavy"'|(npm|pnpm|yarn|bun)[[:space:]]+(run[[:space:]]+)?(verify|test|build|typecheck|type-check|lint|e2e)([[:space:]:]|$)|npm[[:space:]]+t([[:space:]]|$))'
nl=$'\n'
one="${cmd//$nl/;}"
printf '%s' "$one" | grep -Eq "$heavy" || exit 0

# lib/perf.sh: DEPLOYS_PERF_LIB, else next to the deploys on PATH (symlinks followed), else the app's copy.
lib="${DEPLOYS_PERF_LIB:-}"
if [ -z "$lib" ]; then
  d="$(command -v deploys 2>/dev/null)"
  while [ -n "$d" ] && [ -L "$d" ]; do t="$(readlink "$d")"; case "$t" in /*) d="$t" ;; *) d="$(dirname "$d")/$t" ;; esac; done
  [ -n "$d" ] && [ -f "$(dirname "$d")/lib/perf.sh" ] && lib="$(dirname "$d")/lib/perf.sh"
  for c in "$HOME/Applications/Deploy Center.app" "/Applications/Deploy Center.app"; do
    [ -n "$lib" ] || { [ -f "$c/Contents/Resources/lib/perf.sh" ] && lib="$c/Contents/Resources/lib/perf.sh"; }
  done
fi
[ -n "$lib" ] && [ -f "$lib" ] || exit 0

# The wait stops at --max-wait (10 min), below the hook's own timeout (660 s); a hook that times out lets the command run.
out="$(/bin/bash "$lib" wait --max-wait "${DEPLOYS_PERF_MAX_WAIT:-10m}" 2>&1 1>/dev/null)"; rc=$?
if [ "$rc" = 75 ]; then
  printf '%s\n' "$out" | tail -n 1 >&2
  exit 2
fi
exit 0
