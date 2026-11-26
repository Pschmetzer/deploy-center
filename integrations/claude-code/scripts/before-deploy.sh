#!/bin/bash
# before-deploy.sh — Claude Code PreToolUse hook (plugin deploy-center). When Claude is about to run a command that
# starts a deploy or a rollback (`deploys deploy`, `deploys deploy-changed --yes`, `deploys rollback`, a platform's
# deploy through deploys), Claude Code is told to ask the user first, and the question carries what a check reads:
#   Deploy Center: app-web goes to production. Risk: yellow (a lockfile changed). Deploy window: closed (Friday freeze).
#
# It never allows anything: the answer is "ask" (or nothing), so the user's own permission rules cannot be loosened by
# it, and it never denies. Read-only: it calls `deploys risk <project> --json` and `deploys window --json`, nothing
# else, and gives up after DEPLOYS_HOOK_TIMEOUT seconds (default 8). `--dry-run` calls and commands that are no deploy
# pass without a word. It always exits 0.
#
# Off with the plugin option deploy_gate, or DEPLOYS_DEPLOY_GATE=off. Input: the hook JSON on stdin (tool_input.command).
# Env: DEPLOYS               the CLI to call (default: the app bundle, then deploys on PATH)
#      DEPLOYS_HOOK_TIMEOUT  seconds to wait for each read (default 8)

input="$(cat)"
for v in "${DEPLOYS_DEPLOY_GATE:-}" "${CLAUDE_PLUGIN_OPTION_DEPLOY_GATE:-}"; do
  case "$v" in off|false|0|no) exit 0 ;; esac
done
command -v jq >/dev/null 2>&1 || exit 0
cmd="$(jq -r '.tool_input.command // empty' <<<"$input" 2>/dev/null)"
# A write to the files that hold the deploy window, rules and ignore list (sed -i, >, tee, mv, rm ...) is asked too:
# it would lift a freeze as well as `deploys freeze clear` does.
guarded='deploys/(window|rules|ignored|overrides|vercel-repos|schedule)\.json'
if printf '%s' "$cmd" | grep -Eq "$guarded" && printf '%s' "$cmd" | grep -Eq '(>|sed[[:space:]]+(-[a-z]*i)|tee|[[:space:]](rm|mv|cp|truncate|install|ln)[[:space:]]|perl[[:space:]]+-[a-z]*i|jq[[:space:]].*-i)'; then
  jq -cn '{hookSpecificOutput:{hookEventName:"PreToolUse",permissionDecision: "ask",permissionDecisionReason:"Deploy Center: this changes the deploy window, rules or ignore list on disk, which can lift a freeze. Confirm only if the user asked for it."}}'
  exit 0
fi
case "$cmd" in *deploys*) ;; *) exit 0 ;; esac
# shellcheck source=deploys-call.sh
. "$(dirname "$0")/deploys-call.sh"
deploys_call "$cmd"
[ -n "$DC_SUB" ] && [ "$DC_DRY" = 0 ] || exit 0
if [ "$DC_SUB" = weaken ]; then
  jq -cn --arg w "$DC_WEAKEN" '{hookSpecificOutput:{hookEventName:"PreToolUse",permissionDecision: "ask",permissionDecisionReason:("Deploy Center: this " + $w + ", a safeguard of your deploys. Confirm only if the user asked for it.")}}'
  exit 0
fi

what="a deploy to production"
[ "$DC_SUB" != rollback ] || what="a rollback"
if [ "$DC_SUB" = deploy-changed ]; then what="a deploy of every project that has changes waiting"
elif [ -n "$DC_PROJECT" ]; then what="$what of $DC_PROJECT"; fi
note=""

bin="$(deploys_bin)"
if [ -n "$bin" ] && [ "$DC_SUB" != rollback ]; then
  tmp="$(mktemp -d 2>/dev/null)" || tmp=""
  if [ -n "$tmp" ]; then
    trap 'rm -rf "$tmp"' EXIT
    limit="${DEPLOYS_HOOK_TIMEOUT:-8}"; case "$limit" in ''|*[!0-9]*) limit=8 ;; esac
    if [ -n "$DC_PROJECT" ] && run_limited "$limit" "$tmp/risk" "$bin" risk "$DC_PROJECT" --json; then
      r="$(jq -r 'if type == "object" and (.level | type) == "string" then
            "Risk: \(.level)" + (if (.reasons | type) == "array" and (.reasons | length) > 0 then " (" + ([.reasons[].text | tostring | gsub("[\\x00-\\x1f\\x7f]"; " ")] | join("; ") | .[0:200]) + ")" else "" end) + "."
          else empty end' "$tmp/risk" 2>/dev/null)"
      [ -z "$r" ] || note="$note $r"
    fi
    if run_limited "$limit" "$tmp/window" "$bin" window --json; then
      w="$(jq -r 'if type == "object" and .configured == true then
            (if .denied == true then "Deploy window: closed (\(.reason // "closed" | tostring | gsub("[\\x00-\\x1f\\x7f]"; " ") | .[0:120]))." else "Deploy window: open." end)
          else empty end' "$tmp/window" 2>/dev/null)"
      [ -z "$w" ] || note="$note $w"
    fi
  fi
fi

jq -cn --arg what "$what" --arg note "$note" --arg p "$DC_PROJECT" '{
  hookSpecificOutput: {
    hookEventName: "PreToolUse",
    permissionDecision: "ask",
    permissionDecisionReason: ("Deploy Center: this is " + $what + "." + $note + " Confirm only if the user asked for it" + (if $p != "" then " (/deploy-center:deploys-precheck " + $p + " shows the full check)" else "" end) + ".")
  }
}'
exit 0
