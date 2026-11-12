# shellcheck shell=bash
# lib/plan.sh — what the daily deploy would do and cost, before it does it:
#   deploys plan [--when-green] [--json]   the deploy-changed preview with a price per build
#   deploys price [set <vercel|render> <usd per minute> | unset <vercel|render>]
#   deploys budget [set <usd a month> [--strict] | off]   the budget brake of deploy-changed --yes
# Sourced by deploys, after lib/savings.sh (price(), mins(), sv_builds, sv_costs come from there).
#
# Files in the config folder:
#   prices.json  {"vercelUsdPerMinute":0.0, "renderUsdPerMinute":0.0}   (the env variables win)
#   budget.json  {"monthlyUsd":50, "strict":false}

BUDGET="$CONFIG_DIR/budget.json"

price_main() {  # price_main [set <p> <usd> | unset <p>]
  local p="${2:-}" v="${3:-}" tmp
  case "${1:-}" in
    set|unset)
      case "$p" in vercel|render) ;; *) die "Usage: deploys price set <vercel|render> <usd per build minute> | unset <vercel|render>" ;; esac
      [ -f "$PRICES" ] || echo '{}' > "$PRICES"
      tmp="$(mktemp "$CONFIG_DIR/prices.XXXXXX")" || die "Could not write $PRICES."
      if [ "$1" = set ]; then
        [[ "$v" =~ ^[0-9]+(\.[0-9]+)?$ ]] || die "The price is dollars per build minute, a number like 0.008."
        jq --arg k "${p}UsdPerMinute" --argjson v "$v" '.[$k] = $v' "$PRICES" > "$tmp" && mv "$tmp" "$PRICES"
        echo "One $p build minute costs \$$v here (for plan, simulate and ledger, where no billing says it)."
      else
        jq --arg k "${p}UsdPerMinute" 'del(.[$k])' "$PRICES" > "$tmp" && mv "$tmp" "$PRICES"
        echo "No price set for $p."
      fi ;;
    "")
      local out; out="$(jq -n --arg v "$(sv_rate vercel)" --arg r "$(sv_rate render)" \
        --arg ve "${DEPLOYS_VERCEL_USD_PER_MIN:-}" --arg re "${DEPLOYS_RENDER_USD_PER_MIN:-}" \
        '{vercelUsdPerMinute:($v | tonumber? // null), renderUsdPerMinute:($r | tonumber? // null),
          source:{vercel:(if $ve != "" then "env" elif $v != "" then "file" else null end),
                  render:(if $re != "" then "env" elif $r != "" then "file" else null end)}}')"
      if [ "${json:-0}" = 1 ]; then echo "$out"
      else echo "$out" | jq -r '"vercel: \(.vercelUsdPerMinute // "not set")\(if .source.vercel == "env" then " (DEPLOYS_VERCEL_USD_PER_MIN)" else "" end)",
                                 "render: \(.renderUsdPerMinute // "not set")\(if .source.render == "env" then " (DEPLOYS_RENDER_USD_PER_MIN)" else "" end)"'; fi ;;
    *) die "Usage: deploys price [set <vercel|render> <usd per build minute> | unset <vercel|render>]" ;;
  esac
}

# ---------- plan ----------

PLAN_METHOD='Estimate. Each project that would start is one build, priced at the project'"'"'s average: minutes from its last finished production builds (up to 20), dollars from Vercel billing per build over 7 days, else the team'"'"'s price per build minute, else the price per minute you set (deploys price). A build that waits for CI counts too; a skipped one does not.'
PLAN_METHOD_DE='Schätzung. Jedes Projekt, das starten würde, ist ein Build zum Durchschnitt des Projekts: Minuten aus den letzten fertigen Production-Builds (bis 20), Dollar aus der Vercel-Abrechnung je Build über 7 Tage, sonst der Minutenpreis des Teams, sonst der eingestellte Minutenpreis (deploys price). Ein Build, der auf CI wartet, zählt mit; ein übersprungener nicht.'

# The facts price() needs, for the projects of a preview only: their builds, and billing when one is on Vercel.
plan_facts() {  # plan_facts <preview list JSON>
  local list="$1" t n i costs=null
  t="$(mktemp -d)"; n="$(echo "$list" | jq length)"
  if [ "$(echo "$list" | jq 'any(.[]; .platform == "vercel")')" = true ]; then costs="$(sv_costs)"; fi
  for ((i = 0; i < n; i++)); do
    [ $((i % 6)) = 0 ] && [ "$i" -gt 0 ] && wait
    (
      IFS=$'\x1f' read -r plat name id < <(echo "$list" | jq -r ".[$i] | [.platform, .name, (.id // .name)] | join(\"\u001f\")")
      b="$(sv_builds "$plat" "$name" "$id" </dev/null)"; [ -n "$b" ] || b=null
      jq -nc --arg p "$plat" --arg n "$name" --argjson b "$b" '{platform:$p, name:$n, builds:$b}' > "$t/$(printf '%04d' "$i").json"
    ) &
  done
  wait
  cat_all "$t"/*.json | jq -sc --argjson costs "${costs:-null}" --arg vr "$(sv_rate vercel)" --arg rr "$(sv_rate render)" \
    '{costs:$costs, projects:., rates:{vercelUsdPerMinute:($vr | tonumber? // null), renderUsdPerMinute:($rr | tonumber? // null)}}'
  rm -rf "$t"
}

# The preview rows with a price each, and the sum of what would start. Pure jq on <facts>.
plan_from() {  # plan_from <preview rows JSON> <facts JSON>  (rows as deploy-changed --json prints them)
  jq -nc --argjson rows "$1" --argjson f "$2" --arg method "$PLAN_METHOD" --arg methodDe "$PLAN_METHOD_DE" "$SV_JQ_LIB"'
    teamrate($f) as $team
    | [ $rows[] | . as $r | (($f.projects // []) | map(select(.platform == $r.platform and .name == $r.name)) | .[0] // {platform:$r.platform}) as $p
        | price($f; $p; $team) as $pr
        | $r + {minutes:(mins($p) | r1), usd:($pr.usd | r2), priceSource:$pr.source} ] as $out
    | ($out | map(select(.action != "would-skip" and .action != "held-by-rule"))) as $go
    | {estimate:true, kind:"plan", currency:"USD", method:$method, methodDe:$methodDe,
       projects:$out,
       total:{builds:($go | length), usd:([ $go[].usd | numbers ] | add // 0 | r2),
              unpriced:([ $go[] | select(.usd == null) ] | length),
              minutes:([ $go[].minutes | numbers ] | add // 0 | r1)}}'
}

plan_print() {  # stdin: plan JSON
  jq -r 'def usd: if . == null then "?" else "$\(. * 100 | round / 100)" end;
    (.projects[] | "  \(.platform)  \(.name)  \(.action)\(if .commits then "  (\(.commits) commits)" else "" end)  ≈ \(.usd | usd)\(if .minutes then ", \(.minutes) min" else "" end)\(if .rule then "  rule: \(.rule.name // "#\(.rule.index + 1)") -> \(.rule.then)" else "" end)\(if .ci then "  checks: \(.ci.state)" else "" end)"),
    "Would start \(.total.builds) builds, ≈ \(.total.usd | usd)\(if .total.unpriced > 0 then " (\(.total.unpriced) without a price)" else "" end).",
    (if .window.denied then "The deploy window is closed now (\(.window.reason)): --yes needs --force \"why\"." else empty end),
    (if .budget then
       (if .budget.spentUsd == null then "Budget $\(.budget.monthlyUsd) a month: what was spent this month could not be read."
        else "Budget: $\(.budget.spentUsd) of $\(.budget.monthlyUsd) spent this month\(if .budget.over then "; this run would go over it (--yes needs --force \"why\")" else "" end)." end)
     else empty end),
    "", .method'
}

# ---------- budget ----------

# Build dollars spent this calendar month (UTC), from Vercel billing ("deploys costs"). Render has
# no billing API: it is not in here. Prints {spentUsd} or {spentUsd:null, why}.
budget_spent() {
  local dom c; dom="$(date -u +%d)"; dom="$((10#$dom))"
  c="$("$SELF" costs "$dom" 2>/dev/null)" || c=""
  echo "$c" | jq -c --arg m "$(date -u +%Y-%m)" 'if (.days | type) != "array" then error("no days")
      elif (.missingDays // 0) > 0 then {spentUsd:null, why:"Vercel billing could not be read for \(.missingDays) of this month'"'"'s days"}
      else {spentUsd:([.days[] | select(.day | startswith($m)) | .build] | add // 0 | (. * 100 | round) / 100)} end' 2>/dev/null \
    || echo '{"spentUsd":null,"why":"Vercel billing could not be read"}'
}

# The budget as plan and deploy-changed see it: null without budget.json.
budget_json() {  # budget_json <usd this run would add>
  [ -f "$BUDGET" ] || { echo null; return 0; }
  local b s; b="$(jq -c '{monthlyUsd:(.monthlyUsd | numbers), strict:(.strict // false)}' "$BUDGET" 2>/dev/null)" \
    || die "$BUDGET could not be read: it holds {\"monthlyUsd\": 50} (deploys budget set 50)."
  s="$(budget_spent)"
  jq -nc --argjson b "$b" --argjson s "$s" --argjson add "${1:-0}" \
    '$b + $s + {addUsd:$add, over:(if $s.spentUsd == null then null else ($s.spentUsd + $add) > $b.monthlyUsd end)}'
}

budget_main() {  # budget_main [set <usd> [--strict] | off]
  case "${1:-}" in
    set)
      [[ "${2:-}" =~ ^[0-9]+(\.[0-9]+)?$ ]] || die "Usage: deploys budget set <dollars a month> [--strict]"
      local strict=false; [ "${3:-}" != --strict ] || strict=true
      jq -n --argjson v "$2" --argjson s "$strict" '{monthlyUsd:$v, strict:$s}' > "$BUDGET" || die "Could not write $BUDGET."
      echo "Budget: \$$2 a month of Vercel build charges. deploy-changed --yes stops before going over it$([ "$strict" = true ] && echo ", and when the spending cannot be read")." ;;
    off) rm -f "$BUDGET"; echo "No budget." ;;
    "")
      local out; out="$(budget_json 0)"
      if [ "${json:-0}" = 1 ]; then echo "$out"
      elif [ "$out" = null ]; then echo "No budget (deploys budget set 50)."
      else echo "$out" | jq -r '"$\(.spentUsd // "?") of $\(.monthlyUsd) spent this month\(if .spentUsd == null then " (\(.why))" else "" end)\(if .strict then "; strict" else "" end)."'; fi ;;
    *) die "Usage: deploys budget [set <dollars a month> [--strict] | off]" ;;
  esac
}

# The brake of deploy-changed --yes: over budget (or unknown, with strict) needs --force "why".
# Sets budget_over to the text the journal gets when the run goes ahead with --force.
# shellcheck disable=SC2034  # budget_over is read by deploy-changed in deploys
budget_over=""
# shellcheck disable=SC2034
budget_check() {  # budget_check <preview rows JSON>
  [ -f "$BUDGET" ] || return 0
  local add b; add="$(plan_from "$1" "$(plan_facts "$1")" | jq '.total.usd')"
  b="$(budget_json "$add")"
  if [ "$(echo "$b" | jq -r '.spentUsd == null')" = true ]; then
    if [ "$(echo "$b" | jq -r .strict)" = true ]; then
      budget_over="budget unknown: $(echo "$b" | jq -r .why)"
      [ "${forced:-0}" = 1 ] || die "The budget is strict and this month's spending is unknown ($(echo "$b" | jq -r .why)). To deploy anyway: --force \"why\""
    else
      echo "Warning: the budget is not checked: $(echo "$b" | jq -r .why)." >&2
    fi
    return 0
  fi
  if [ "$(echo "$b" | jq -r .over)" = true ]; then
    budget_over="$(echo "$b" | jq -r '"over budget: $\(.spentUsd) spent + ≈ $\(.addUsd) of $\(.monthlyUsd)"')"
    [ "${forced:-0}" = 1 ] || die "Over budget: $(echo "$b" | jq -r '"$\(.spentUsd) spent this month + ≈ $\(.addUsd) for this run > $\(.monthlyUsd)"'). To deploy anyway: --force \"why\""
  fi
}
