#!/bin/bash
# plan-comment.sh — turns `deploys plan --json` into a Markdown comment: what the next deploy would
# start and what it would cost (an estimate). Read-only; nothing is started.
#
#   deploys plan --json | examples/plan-comment.sh > comment.md
#
# The first line is a marker (<!-- deploy-center-plan -->) so a workflow can find and update its
# own comment. Names are escaped, so a project name cannot break the table or inject Markdown.
set -euo pipefail
in="$(cat)"
jq -e 'type == "object" and (.projects | type == "array") and (.total | type == "object")' >/dev/null 2>&1 <<<"$in" \
  || { echo "plan-comment: input is not the JSON of deploys plan --json" >&2; exit 1; }

jq -r '
  def usd: if . == null then "?" else (. * 100 | round) as $c | "$\($c / 100 | floor).\(($c % 100) | tostring | if length < 2 then "0" + . else . end)" end;
  def esc: tostring | gsub("[\\r\\n]+"; " ") | gsub("(?<c>[\\\\`*_{}\\[\\]<>()#+!|~&@])"; "\\\(.c)");
  def skipped: .action == "would-skip" or .action == "held-by-rule";
  "<!-- deploy-center-plan -->",
  "### Next deploy",
  "",
  (if .total.builds == 0 then "Nothing would start."
   else "**\(.total.builds) build\(if .total.builds == 1 then "" else "s" end)**, about **\(.total.usd | usd)**\(if (.total.unpriced // 0) > 0 then " (\(.total.unpriced) without a price)" else "" end)." end),
  "",
  (if (.projects | length) > 0 then
     "| Project | Host | What happens | Estimate |", "|---|---|---|---|",
     (.projects[] | "| \(.name | esc) | \(.platform | esc) | \(if skipped then "left out (\(.action))" else .action end) | \(if skipped then "–" else (.usd | usd) end) |")
   else empty end),
  "",
  (if .window.denied then "The deploy window is closed now (\(.window.reason // "no reason given" | esc))." else empty end),
  (if .budget and .budget.monthlyUsd then
     (if .budget.spentUsd == null then "Budget \(.budget.monthlyUsd | usd) a month: what was spent could not be read."
      else "Budget: \(.budget.spentUsd | usd) of \(.budget.monthlyUsd | usd) spent this month\(if .budget.over then "; this run would go over it" else "" end)." end)
   else empty end),
  "",
  "_An estimate (build minutes times your rate). Nothing is deployed from this comment._"' <<<"$in"
