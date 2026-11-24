# shellcheck shell=bash
# lib/preview.sh — `deploys preview <project>`: what a production deploy of one project would do, started by nothing.
#
#   deploys preview <project> [--json]
#
# Puts together what is already known and shows it in one place: the commits that wait, the files they touch, the
# risk check, the rule that matches, the deploy window (freeze), the monthly budget and a verdict. It only reads:
# nothing is started, no hook runs, nothing is written. Sourced by deploys; uses die, resolve, journal-free helpers.

# preview_from <project JSON> <notes JSON> <risk JSON> <rules JSON> <window JSON> <budget JSON>: one object.
# Every part may be null (not known / not set up); the verdict is the worst of what is known.
preview_from() {
  jq -nc --argjson p "$1" --argjson notes "$2" --argjson risk "$3" --argjson rules "$4" --argjson win "$5" --argjson budget "$6" '
    ($notes.commits // []) as $c
    | ($rules | map(select(.matched)) | sort_by(.index) | .[0]) as $rule
    | ($win.denied == true) as $frozen
    | ($budget != null and $budget.over == true) as $over
    | ($rule != null and $rule.action == "hold") as $held
    | { project:$p.name, platform:$p.platform, wouldDeploy:true, preview:false,
        commits:{count:($c | length), list:($c[0:10] | map({sha:(.sha // null), message:.message, author:(.author // null)}))},
        files:($risk.files // null), lines:($risk.lines // null),
        risk:{level:($risk.level // "unknown"), reasons:(($risk.reasons // []) | map(.text))},
        rule:(if $rule then {name:$rule.rule, action:$rule.action} else null end),
        freeze:{denied:$frozen, reason:(if $frozen then $win.reason else null end)},
        budget:(if $budget == null then null else {monthlyUsd:$budget.monthlyUsd, spentUsd:$budget.spentUsd, over:$budget.over} end),
        blockers:([ (if $frozen then "deploy window closed: \($win.reason)" else empty end),
                    (if $over then "over the monthly budget" else empty end),
                    (if $held then "rule \"\($rule.rule)\" says hold" else empty end) ]),
        verdict:(if $frozen or $over or $held then "blocked"
                 elif ($risk.level // "") == "red" then "careful"
                 elif ($c | length) == 0 and $risk.level == "green" then "nothing-waits"
                 else "ok" end),
        startedNothing:true }'
}

preview_print() {  # stdin: preview JSON
  jq -r '
    "Preview of a production deploy: \(.project) (\(.platform))",
    "  Commits: \(.commits.count)\(if .commits.count == 0 then " (nothing waits, or the live commit is not known)" else "" end)",
    (.commits.list[] | "    \((.sha // "-")[0:7])  \(.message)\(if .author then " (" + .author + ")" else "" end)"),
    (if .files != null then "  Files: \(.files), lines changed: \(.lines)" else empty end),
    "  Risk: \(.risk.level)",
    (.risk.reasons[] | "    - \(.)"),
    "  Rule: \(if .rule then "\(.rule.name) -> \(.rule.action)" else "none matches" end)",
    "  Deploy window: \(if .freeze.denied then "CLOSED (\(.freeze.reason))" else "open" end)",
    "  Budget: \(if .budget == null then "none set" else "$\(.budget.spentUsd // "?") of $\(.budget.monthlyUsd) spent this month\(if .budget.over then " (over)" else "" end)" end)",
    "  Verdict: \(.verdict)\(if (.blockers | length) > 0 then " - " + (.blockers | join("; ")) else "" end)",
    "Nothing was started. To deploy: deploys deploy \(.project)"'
}

preview_main() {  # preview_main <project> [--json handled globally]
  local p="" j
  while [ "$#" -gt 0 ]; do
    case "$1" in
      -*) die "Unknown option $1. Usage: deploys preview <project> [--json]" ;;
      *) [ -z "$p" ] || die "Usage: deploys preview <project> [--json]"; p="$1" ;;
    esac
    shift
  done
  [ -n "$p" ] || die_usage "Usage: deploys preview <project> [--json]"
  safe_name "$p"; resolve "$p"
  local plat="$PLAT" name="$PNAME" notes risk rules win budget
  notes="$("$SELF" notes "$p" --json 2>/dev/null)" || notes='{"commits":[]}'
  risk="$("$SELF" risk "$p" --json 2>/dev/null)" || risk='{"level":"unknown","reasons":[]}'
  rules="$("$SELF" rules check --json 2>/dev/null | jq -c --arg n "$name" --arg pl "$plat" '[.[]? | select(.name == $n and .platform == $pl)]' 2>/dev/null)" || rules='[]'
  [ -n "$rules" ] || rules='[]'
  win="$(window_json)" || win='{"denied":false}'
  if team_on; then
    local why; why="$(team_window_denied "$name" 2>/dev/null || true)"
    [ -z "$why" ] || win="$(jq -nc --arg r "$why" '{denied:true, reason:$r}')"
  fi
  budget="$(budget_json 0 2>/dev/null)" || budget=null
  [ -n "$budget" ] || budget=null
  j="$(preview_from "$(jq -nc --arg n "$name" --arg p "$plat" '{name:$n, platform:$p}')" "$notes" "$risk" "$rules" "$win" "$budget")"
  if [ "${json:-0}" = 1 ]; then echo "$j" | jq .; else echo "$j" | preview_print; fi
}
