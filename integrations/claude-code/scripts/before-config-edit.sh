#!/bin/bash
# before-config-edit.sh — Claude Code PreToolUse hook (matcher "Edit|Write|MultiEdit"). Editing the files that hold the
# deploy window, rules, ignore list and schedule lifts a freeze as surely as `deploys freeze clear`: the user is asked
# first. Never allows, never denies; always exits 0. Off with DEPLOYS_DEPLOY_GATE=off, as before-deploy.sh.
input="$(cat)"
for v in "${DEPLOYS_DEPLOY_GATE:-}" "${CLAUDE_PLUGIN_OPTION_DEPLOY_GATE:-}"; do
  case "$v" in off|false|0|no) exit 0 ;; esac
done
command -v jq >/dev/null 2>&1 || exit 0
f="$(jq -r '.tool_input.file_path // .tool_input.path // empty' <<<"$input" 2>/dev/null)"
case "$f" in
  */deploys/window.json|*/deploys/rules.json|*/deploys/ignored.json|*/deploys/overrides.json|*/deploys/vercel-repos.json|*/deploys/schedule.json) ;;
  *) exit 0 ;;
esac
jq -cn --arg f "${f##*/}" '{hookSpecificOutput:{hookEventName:"PreToolUse",permissionDecision: "ask",permissionDecisionReason:("Deploy Center: this edits " + $f + ", which holds the deploy window, rules or ignore list and can lift a freeze. Confirm only if the user asked for it.")}}'
exit 0
