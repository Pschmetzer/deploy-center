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
nl=$'\n'
one="${cmd//$nl/;}"
# Only a command that is itself `deploys perf gate|wait` is left alone ("git commit -m 'perf wait'; npm test" is not).
printf '%s' "$one" | grep -Eq '^[[:space:]]*(env[[:space:]]+([A-Za-z_][A-Za-z0-9_]*=[^[:space:]]*[[:space:]]+)*)?([^[:space:];&|]*/)?deploys[[:space:]]+perf[[:space:]]+(gate|wait)([[:space:]]|$)' \
  && ! printf '%s' "$one" | grep -Eq '[;&|]' && exit 0

# Heavy only as a command of its own: at the start, or after && || ; | ( or a newline, past VAR=value, wrappers
# (env, time, nohup, sudo, caffeinate, xargs, npx -y, bash -c) and cd … &&. `grep tsc file` or `echo vitest` is not heavy.
wrap='((env|time|nohup|sudo|caffeinate|nice|xargs|exec|command|setsid|stdbuf|timeout)([[:space:]]+(-[A-Za-z-]+|[A-Za-z_][A-Za-z0-9_]*=[^[:space:]]*|[0-9]+[smh]?))*[[:space:]]+)*'
heavy='(^|[;&|(]|bash[[:space:]]+-[a-z]*c[[:space:]]+["'"'"']?|sh[[:space:]]+-[a-z]*c[[:space:]]+["'"'"']?)[[:space:]]*([A-Za-z_][A-Za-z0-9_]*=[^[:space:]]*[[:space:]]+)*'"$wrap"
heavy="$heavy"'((npx([[:space:]]+(-y|--yes|--no-install))?|pnpm[[:space:]]+exec|pnpm[[:space:]]+dlx|bunx|yarn)[[:space:]]+|(\./)?node_modules/\.bin/)?'
heavy="$heavy"'(tsc|vitest|jest|eslint|playwright|vite[[:space:]]+build|turbo[[:space:]]+(run[[:space:]]+)?(build|test|lint)|next[[:space:]]+build|xcodebuild|swift[[:space:]]+build|swift[[:space:]]+test|docker[[:space:]]+(build|compose[[:space:]]+build|compose[[:space:]]+up[[:space:]]+.*--build)|\./build\.sh'
heavy="$heavy"'|cargo[[:space:]]+(build|test|check|clippy)|go[[:space:]]+(build|test|vet)|pytest|make([[:space:]]|$)|\./gradlew|gradle[[:space:]]+(build|test)|mvn[[:space:]]+(package|test|install|verify)|npm[[:space:]]+ci([[:space:]]|$)|(pnpm|yarn|bun)[[:space:]]+install([[:space:]]|$)'
heavy="$heavy"'|(npm|pnpm|yarn|bun)[[:space:]]+(run[[:space:]]+(-r[[:space:]]+)?)?(verify|test|build|typecheck|type-check|lint|e2e)([[:space:]:"'"'"']|$)|npm[[:space:]]+t([[:space:]]|$)'
# More of your own: DEPLOYS_PERF_HEAVY_EXTRA (an ERE, e.g. "terraform[[:space:]]+apply|bazel") and one ERE per line in ~/.config/deploys/heavy.txt.
extra="${DEPLOYS_PERF_HEAVY_EXTRA:-}"
hf="${DEPLOYS_CONFIG:-$HOME/.config/deploys}/heavy.txt"
if [ -r "$hf" ]; then extra="$extra|$(grep -Ev '^[[:space:]]*(#|$)' "$hf" 2>/dev/null | paste -sd'|' -)"; fi
extra="${extra#|}"; extra="${extra%|}"
[ -z "$extra" ] || heavy="$heavy|$extra"
heavy="$heavy)"
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
