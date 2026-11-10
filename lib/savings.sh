# shellcheck shell=bash
# Deploy Center — savings: what auto-deploy would cost (simulate) and what turning it off saved (ledger).
# Sourced by `deploys` for `deploys simulate` and `deploys ledger`; it uses the script's helpers
# (all_json, vercel_call, render_call, $REPOS, $CONFIG_DIR).
#
# Everything here is an ESTIMATE, and the JSON says how it was made:
#   pushes to the deploy branch (GitHub)  x  the average build of that project.
# Pushes come from GitHub's activity list; where that cannot be read, commits on the branch stand
# in (one push may carry several commits, so that count is an upper bound). The average build is
# the mean duration of the project's recent finished builds. A price per build comes from Vercel's
# billing (`deploys costs`), else from the team's price per build minute, else from a rate you set:
#   DEPLOYS_VERCEL_USD_PER_MIN   price of one Vercel build minute (only used without billing data)
#   DEPLOYS_RENDER_USD_PER_MIN   price of one Render pipeline minute (Render has no billing API)
# or, without those, from prices.json (`deploys price set vercel 0.008`).
#
# The calculations are pure jq on one "facts" document (sv_simulate_from, sv_ledger_from), so the
# tests feed them fixtures; only sv_facts talks to GitHub, Vercel and Render.

SV_MAX_JOBS=6

# prices.json: {"vercelUsdPerMinute":0.0, "renderUsdPerMinute":0.0}, written by `deploys price`.
PRICES="$CONFIG_DIR/prices.json"

# The price of one build minute you set: DEPLOYS_<P>_USD_PER_MIN, else prices.json, else empty.
sv_rate() {  # sv_rate vercel|render
  local env
  case "$1" in vercel) env="${DEPLOYS_VERCEL_USD_PER_MIN:-}" ;; render) env="${DEPLOYS_RENDER_USD_PER_MIN:-}" ;; *) return 0 ;; esac
  if [ -n "$env" ]; then echo "$env"; return 0; fi
  [ -f "$PRICES" ] || return 0
  jq -r --arg k "${1}UsdPerMinute" '.[$k] // empty | numbers' "$PRICES" 2>/dev/null || true
}


# The projects with their repo, branch and the moment auto-deploy was first turned off (or null).
sv_projects() {
  local roff="$CONFIG_DIR/render-off.json" list
  [ -f "$roff" ] || echo '{}' > "$roff"
  # Without GitHub: the heads and open PRs are not needed here, and cost many calls.
  list="$(DEPLOYS_NO_GITHUB=1 all_json 2>/dev/null)" || true
  echo "${list:-[]}" | jq -c --slurpfile r "$REPOS" --slurpfile o "$roff" 'map({platform, name, id:(.id // .name),
      repo:(.repo // null), ref:(.ref // null), auto:(.auto // false),
      offAt:(if .platform == "vercel" then ($r[0][.name].offAt // null) else ($o[0][.id // ""] // null) end)})' 2>/dev/null || echo '[]'
}

# Pushes to <branch> since <epoch>, as {basis, list:[{at, sha}]}; {error} when GitHub cannot be read.
# A "push" is anything that moves the branch: a push, a force push, a PR merge or a merge-queue merge.
# Most changes reach main through PR merges, which GitHub lists as pr_merge, not push.
sv_pushes() {  # sv_pushes <owner/repo> <branch> <since epoch>
  local repo="$1" ref="$2" since="$3" age period raw basis=pushes
  # GitLab pushes are not read yet: said as such, not as "GitHub could not be read".
  if declare -F githost_of >/dev/null && [ "$(githost_of "$repo")" = gitlab ]; then
    echo '{"error":"a GitLab project: its pushes are not counted yet (GitHub only)"}'; return 0
  fi
  command -v gh >/dev/null 2>&1 || { echo '{"error":"counting pushes on GitHub needs gh: install it and run gh auth login"}'; return 0; }
  age=$(( ($(date +%s) - since) / 86400 ))
  if [ "$age" -lt 1 ]; then period=day; elif [ "$age" -lt 7 ]; then period=week
  elif [ "$age" -lt 30 ]; then period=month; elif [ "$age" -lt 90 ]; then period=quarter; else period=year; fi
  if ! raw="$(gh api --paginate "repos/$repo/activity?ref=refs/heads/$ref&time_period=$period&per_page=100" 2>/dev/null)" \
     || ! echo "$raw" | jq -e 'type == "array"' >/dev/null 2>&1; then
    basis=commits
    raw="$(gh api --paginate "repos/$repo/commits?sha=$ref&since=$(jq -rn --argjson s "$since" '$s | todate')&per_page=100" 2>/dev/null \
      | jq -c '.[] | {timestamp:.commit.committer.date, after:.sha}' 2>/dev/null | jq -sc .)" \
      || raw=""
    [ -n "$raw" ] && [ "$raw" != "null" ] || { echo '{"error":"GitHub could not be read (is gh logged in?)"}'; return 0; }
  fi
  # --paginate prints one array per page: jq reads them as a stream.
  echo "$raw" | jq -sc --arg b "$basis" --argjson since "$since" '[.[][] | select(.timestamp and .after)
      | select((.activity_type // "push") | IN("push", "force_push", "pr_merge", "merge_queue_merge"))
      | {at:(.timestamp | sub("\\.[0-9]+Z$"; "Z") | fromdateiso8601), sha:.after}]
      | map(select(.at >= $since)) | unique_by(.sha) | sort_by(.at) | {basis:$b, list:.}' 2>/dev/null \
    || echo '{"error":"unreadable answer from GitHub"}'
}

# Recent builds of one project: the minutes of finished builds, and which commits were built when.
sv_builds() {  # sv_builds <platform> <name> <id>
  if [ "$1" = vercel ]; then
    # Production only: a preview of the same commit is no proof the push was built for production.
    vercel_call "/v6/deployments?app=$2&limit=100&target=production" 2>/dev/null | jq -c '[.deployments[]?] |
      {minutes:(map(select(.state == "READY" and .buildingAt and .ready) | (.ready - .buildingAt) / 60000) | .[0:20]),
       built:map({at:((.buildingAt // .created) / 1000 | floor), sha:(.meta.githubCommitSha // null)}),
       full:(length < 100), oldestAt:(map((.buildingAt // .created) / 1000 | floor) | min)}' 2>/dev/null \
      || echo '{"error":"Vercel deployments could not be read"}'
  else
    render_call GET "/services/$3/deploys?limit=100" 2>/dev/null | jq -c 'def t: sub("\\.[0-9]+Z$"; "Z") | fromdateiso8601;
      [.[]?.deploy] | {minutes:(map(select(.status == "live" or .status == "deactivated") | select(.createdAt and .finishedAt)
                                 | ((.finishedAt | t) - (.createdAt | t)) / 60) | .[0:20]),
                       built:map(select(.createdAt) | {at:(.createdAt | t), sha:(.commit.id // null)}),
                       full:(length < 100), oldestAt:(map(select(.createdAt) | .createdAt | t) | min)}' 2>/dev/null \
      || echo '{"error":"Render deploys could not be read"}'
  fi
}

# Vercel billing per project (7 days); null without Vercel or when it cannot be read.
sv_costs() {
  local c; c="$("${DEPLOYS_SELF:-${SELF:-$0}}" costs 7 2>/dev/null)" || c=""
  echo "$c" | jq -c '{buildsComplete, projects:[.projects[]? | {name, build, builds}]}' 2>/dev/null || echo null
}

# Everything the estimate needs, in one document. <mode> is simulate or ledger.
sv_facts() {  # sv_facts <mode> <days>
  local mode="$1" days="$2" now t projects costs=null n=0 i since
  now="$(date +%s)"; t="$(mktemp -d)"
  projects="$(sv_projects)"
  if [ "$(echo "$projects" | jq 'any(.[]; .platform == "vercel")')" = true ]; then costs="$(sv_costs)"; fi
  n="$(echo "$projects" | jq length)"
  for ((i = 0; i < n; i++)); do
    [ $((i % SV_MAX_JOBS)) = 0 ] && [ "$i" -gt 0 ] && wait
    (
      p="$(echo "$projects" | jq -c ".[$i]")"
      # A separator that is not white space: an empty repo must stay an empty field.
      IFS=$'\x1f' read -r plat name id repo ref off < <(echo "$p" \
        | jq -r '[.platform, .name, .id, (.repo // ""), (.ref // ""), (.offAt // "" | tostring)] | join("\u001f")')
      if [ "$mode" = ledger ]; then since="$off"; else since=$((now - days * 86400)); fi
      if [ "$mode" = ledger ] && [ -z "$since" ]; then pushes=null; builds=null
      elif [ -z "$repo" ] || [ -z "$ref" ]; then pushes='{"error":"no GitHub repo and branch known"}'; builds=null
      else pushes="$(sv_pushes "$repo" "$ref" "$since")"; builds="$(sv_builds "$plat" "$name" "$id")"; fi
      echo "$p" | jq -c --argjson pu "$pushes" --argjson bu "$builds" '. + {pushes:$pu, builds:$bu}' > "$t/$i.json"
    ) &
  done
  wait
  cat_all "$t"/*.json | jq -sc --argjson now "$now" --argjson days "$days" --argjson costs "${costs:-null}" \
    --arg vr "$(sv_rate vercel)" --arg rr "$(sv_rate render)" \
    '{now:$now, days:$days, costs:$costs, projects:sort_by(.name | ascii_downcase),
      rates:{vercelUsdPerMinute:($vr | tonumber? // null), renderUsdPerMinute:($rr | tonumber? // null)}}'
  rm -rf "$t"
}

# Shared jq: averages, rounding, and the price of one build of a project.
SV_JQ_LIB='
def avg: if length == 0 then null else add / length end;
def r2: if . == null then null else (. * 100 | round) / 100 end;
def r1: if . == null then null else (. * 10 | round) / 10 end;
def day: strftime("%Y-%m-%d");
def mins($p): ($p.builds.minutes // []) | avg;
# The price of one Vercel build minute across the team: billed build dollars over billed build minutes.
def teamrate($f): [ $f.projects[] | select(.platform == "vercel") | . as $p
    | (($f.costs.projects // []) | map(select(.name == $p.name)) | .[0]) as $c
    | select($c != null and ($c.builds // 0) > 0 and (mins($p) // 0) > 0)
    | {usd:$c.build, min:($c.builds * mins($p))} ]
  | if length > 0 and (map(.min) | add) > 0 then (map(.usd) | add) / (map(.min) | add) else null end;
def price($f; $p; $team): mins($p) as $m
  | if $p.platform == "vercel" then
      (($f.costs.projects // []) | map(select(.name == $p.name)) | .[0]) as $c
      | if $f.costs.buildsComplete == true and $c != null and ($c.builds // 0) > 0
          then {usd:($c.build / $c.builds), source:"vercel-billing"}
        elif $m != null and $team != null then {usd:($m * $team), source:"vercel-team-rate"}
        elif $m != null and $f.rates.vercelUsdPerMinute != null then {usd:($m * $f.rates.vercelUsdPerMinute), source:"rate-setting"}
        else {usd:null, source:null} end
    elif $m != null and $f.rates.renderUsdPerMinute != null then {usd:($m * $f.rates.renderUsdPerMinute), source:"rate-setting"}
    else {usd:null, source:null} end;
def unit($p): if $p.platform == "vercel" then "build minutes" else "pipeline minutes" end;
def problem($p): if $p.pushes == null then null
  elif $p.pushes.error then $p.pushes.error
  elif ($p.builds.minutes // []) | length == 0 then "no finished build to measure"
  else null end;
'

SV_METHOD_SIM='Estimate. Pushes to the deploy branch in the window (GitHub activity; commits where pushes cannot be read, an upper bound) are each counted as one build. Each build is priced at the project'"'"'s average: minutes from its last finished builds (up to 20), dollars from Vercel billing per build over 7 days, else the team'"'"'s price per build minute, else DEPLOYS_VERCEL_USD_PER_MIN / DEPLOYS_RENDER_USD_PER_MIN. "Once a day" counts one build on each day that had a push. Per month = window scaled to 30 days.'
SV_METHOD_LEDGER='Estimate. Since auto-deploy was turned off, every push to the deploy branch whose commit was never built counts as a skipped build (GitHub activity; commits where pushes cannot be read, an upper bound). Each skipped build is priced at the project'"'"'s average: minutes from its last finished builds (up to 20), dollars from Vercel billing per build over 7 days, else the team'"'"'s price per build minute, else DEPLOYS_VERCEL_USD_PER_MIN / DEPLOYS_RENDER_USD_PER_MIN.'

# The same in German, for the app's German texts (methodDe in the JSON).
SV_METHOD_SIM_DE='Schätzung. Jeder Push auf den Deploy-Branch im Zeitraum (GitHub-Aktivität; wo Pushes nicht lesbar sind, Commits als Obergrenze) zählt als ein Build. Jeder Build kostet den Durchschnitt des Projekts: Minuten aus den letzten fertigen Builds (bis 20), Dollar aus der Vercel-Abrechnung je Build über 7 Tage, sonst der Minutenpreis des Teams, sonst der eingestellte Minutenpreis. „Einmal am Tag“ zählt einen Build an jedem Tag mit Push. Pro Monat = Zeitraum auf 30 Tage hochgerechnet.'
SV_METHOD_LEDGER_DE='Schätzung. Seit Auto-Deploy aus ist, zählt jeder Push auf den Deploy-Branch, dessen Commit nie gebaut wurde, als übersprungener Build (GitHub-Aktivität; wo Pushes nicht lesbar sind, Commits als Obergrenze). Gebaut zählt nur Production. Jeder übersprungene Build kostet den Durchschnitt des Projekts: Minuten aus den letzten fertigen Builds (bis 20), Dollar aus der Vercel-Abrechnung je Build über 7 Tage, sonst der Minutenpreis des Teams, sonst der eingestellte Minutenpreis.'

# What auto-deploy would cost per month, next to deploying once a day.
sv_simulate_from() {  # stdin: facts
  jq -c --arg method "$SV_METHOD_SIM" --arg methodDe "$SV_METHOD_SIM_DE" "$SV_JQ_LIB"'
  . as $f | teamrate($f) as $team | ($f.now - $f.days * 86400) as $from | (30 / $f.days) as $k
  | [ $f.projects[] | . as $p | problem($p) as $why | price($f; $p; $team) as $pr | mins($p) as $m
      | (($p.pushes.list // []) | map(select(.at >= $from))) as $pu
      | ($pu | map(.at | day) | unique | length) as $active
      | {platform, name, auto, unit:unit($p), basis:($p.pushes.basis // null), problem:$why,
         pushes:($pu | length), activeDays:$active, pushesPerDay:(($pu | length) / $f.days | r1),
         avgBuildMinutes:($m | r1), buildsMeasured:(($p.builds.minutes // []) | length),
         usdPerBuild:($pr.usd | r2), priceSource:$pr.source}
      | . + {auto_:{builds:(.pushes * $k)}, daily_:{builds:(.activeDays * $k)}}
      | .autoMonth = {builds:(.auto_.builds | r1), minutes:(if $m then .auto_.builds * $m | round else null end),
                      usd:(if $pr.usd then .auto_.builds * $pr.usd | r2 else null end)}
      | .dailyMonth = {builds:(.daily_.builds | r1), minutes:(if $m then .daily_.builds * $m | round else null end),
                       usd:(if $pr.usd then .daily_.builds * $pr.usd | r2 else null end)}
      | .savingMonth = {builds:((.autoMonth.builds - .dailyMonth.builds) | r1),
                        minutes:(if $m then .autoMonth.minutes - .dailyMonth.minutes else null end),
                        usd:(if $pr.usd then (.autoMonth.usd - .dailyMonth.usd) | r2 else null end)}
      | del(.auto_, .daily_) ] as $rows
  | def sum($k1; $k2; $plat): [ $rows[] | select($plat == null or .platform == $plat) | .[$k1][$k2] | numbers ] | add // 0;
    def tot($k): {usd:(sum($k; "usd"; null) | r2), vercelMinutes:sum($k; "minutes"; "vercel"),
                  renderMinutes:sum($k; "minutes"; "render"), builds:(sum($k; "builds"; null) | r1)};
  {estimate:true, kind:"simulate", currency:"USD", days:$f.days, generatedAt:$f.now, method:$method, methodDe:$methodDe,
   teamUsdPerBuildMinute:($team | if . then (. * 1000 | round) / 1000 else null end),
   projects:$rows,
   total:{autoMonth:tot("autoMonth"), dailyMonth:tot("dailyMonth"), savingMonth:tot("savingMonth"),
          usdComplete:([ $rows[] | select(.pushes > 0) | .usdPerBuild ] | all(. != null))}}'
}

# What turning auto-deploy off saved: pushes that did not build, priced at the average build.
sv_ledger_from() {  # stdin: facts
  jq -c --arg method "$SV_METHOD_LEDGER" --arg methodDe "$SV_METHOD_LEDGER_DE" "$SV_JQ_LIB"'
  . as $f | teamrate($f) as $team
  | [ $f.projects[] | select(.offAt != null) | . as $p | price($f; $p; $team) as $pr | mins($p) as $m
      | (($p.pushes.list // []) | map(select(.at >= $p.offAt))) as $pu
      | (($p.builds.built // []) | map(select(.at >= $p.offAt))) as $bu
      | ($bu | map(.sha) | map(select(. != null))) as $shas
      | ($pu | map(select(.sha as $s | $shas | index($s) | not))) as $sk
      | {platform, name, unit:unit($p), offAt, offDay:($p.offAt | day), basis:($p.pushes.basis // null),
         # Only the newest 100 builds are read: when they do not reach back to the day it went off,
         # older pushes would count as skipped although they were built.
         problem:(problem($p) // (if ($p.builds.full == false) and (($p.builds.oldestAt // 0) > $p.offAt)
                    then "only the newest 100 builds were read; skipped may be too high" else null end)),
         pushes:($pu | length), builds:($bu | length), skipped:($sk | length),
         avgBuildMinutes:($m | r1), buildsMeasured:(($p.builds.minutes // []) | length),
         usdPerBuild:($pr.usd | r2), priceSource:$pr.source,
         savedMinutes:(if $m then ($sk | length) * $m | round else null end),
         savedUsd:(if $pr.usd then ($sk | length) * $pr.usd | r2 else null end),
         builtUsd:(if $pr.usd then ($bu | length) * $pr.usd | r2 else null end),
         skippedPushes:($sk | sort_by(-.at) | .[0:20] | map({day:(.at | day), sha:((.sha // "")[0:7])}))} ] as $rows
  | ([ $rows[].offAt ] | min) as $first
  | def sum($k; $plat): [ $rows[] | select($plat == null or .platform == $plat) | .[$k] | numbers ] | add // 0;
    # Unknown, not 0, when a project skipped builds whose length is not known yet.
    def msum($plat): if any($rows[]; .platform == $plat and .skipped > 0 and .savedMinutes == null) then null
      else sum("savedMinutes"; $plat) end;
  {estimate:true, kind:"ledger", currency:"USD", generatedAt:$f.now, method:$method, methodDe:$methodDe,
   minutesComplete:([ $rows[] | select(.skipped > 0) | .savedMinutes ] | all(. != null)),
   since:(if $first then $first | day else null end),
   days:(if $first then (($f.now - $first) / 86400 | r1) else 0 end),
   projects:($rows | sort_by(-(.savedUsd // 0), -.skipped)),
   total:{skipped:sum("skipped"; null), pushes:sum("pushes"; null), builds:sum("builds"; null),
          usd:(sum("savedUsd"; null) | r2), builtUsd:(sum("builtUsd"; null) | r2),
          vercelMinutes:msum("vercel"), renderMinutes:msum("render"),
          usdComplete:([ $rows[] | select(.skipped > 0) | .usdPerBuild ] | all(. != null))}}'
}

# For a person at a terminal: the same numbers in a few lines.
sv_print() {  # stdin: simulate or ledger JSON
  jq -r 'def usd: if . == null then "?" else "$\(. * 100 | round / 100)" end;
    if .kind == "simulate" then
      "Estimate over the last \(.days) days, per month:",
      (.projects[] | "  \(.name) (\(.platform)): \(.pushes) pushes; auto-deploy ≈ \(.autoMonth.usd | usd), \(.autoMonth.minutes // "?") \(.unit); once a day ≈ \(.dailyMonth.usd | usd)\(if .problem then "  [\(.problem)]" else "" end)"),
      "Auto-deploy would cost ≈ \(.total.autoMonth.usd | usd) a month; deploying once a day ≈ \(.total.dailyMonth.usd | usd).",
      "", .method
    else
      (if .since then "Since \(.since): ≈ \(.total.usd | usd) saved, \(.total.skipped) builds skipped (\(.total.vercelMinutes) Vercel build minutes, \(.total.renderMinutes) Render pipeline minutes)."
       else "Auto-deploy was not turned off here yet: nothing saved so far. Try: deploys simulate" end),
      (.projects[] | "  \(.name) (\(.platform)), off since \(.offDay): \(.skipped) of \(.pushes) pushes not built, ≈ \(.savedUsd | usd), \(.savedMinutes // "?") \(.unit)"),
      "", .method
    end'
}

savings_main() {  # savings_main simulate|ledger [--days N]
  local mode="$1" days=30 out gotdays=""
  shift
  while [ $# -gt 0 ]; do
    case "$1" in
      --days) days="${2:-}"; gotdays=1; shift ;;
      *) die "Unknown option $1. Usage: deploys simulate [--days N] [--json] | deploys ledger [--json]" ;;
    esac
    shift
  done
  case "$days" in ''|*[!0-9]*) die "--days must be a number from 1 to 90";; esac
  days="$((10#$days))"   # 08 is eight, not a bad octal number
  [ "$days" -ge 1 ] && [ "$days" -le 90 ] || die "--days must be a number from 1 to 90"
  # The ledger counts from the day auto-deploy went off; a --days there would be ignored in silence.
  [ "$mode" != ledger ] || [ -z "$gotdays" ] || die "--days is for simulate; the ledger counts from the day auto-deploy went off"
  # gh is asked for per GitHub project (sv_pushes): projects on GitLab alone need none.
  if [ "$mode" = simulate ]; then out="$(sv_facts simulate "$days" | sv_simulate_from)"
  else out="$(sv_facts ledger "$days" | sv_ledger_from)"; fi
  if [ "${json:-0}" = 1 ]; then echo "$out"; else echo "$out" | sv_print; fi
}
