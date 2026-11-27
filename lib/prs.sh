# shellcheck shell=bash
# lib/prs.sh — `deploys prs`: your open pull requests, in every repo, kept free of merge conflicts and merged.
#
#   deploys prs [--json]                                  the open pull requests you wrote, with what blocks each one
#   deploys prs run --yes [--dry-run]                     one pass: resolve conflicts, bring branches up to date, merge
#   deploys prs schedule on|off                           that pass every 5 minutes (launchd); the first one only reports
#   deploys prs set autoResolve|autoMerge|mergeWithoutChecks on|off
#   deploys prs set perRun|perDay|mergesPerRun <n>        caps (0 = no cap)
#   deploys prs allow|deny|unlist <owner/name>            limit it to some repos, or leave some out
#
# One GraphQL search (is:pr is:open author:@me) covers every repo, so nothing has to be configured to see them.
# The settings live in prs.json in the config folder (never in a repo): {"autoResolve":false,"autoMerge":false,
# "mergeWithoutChecks":false,"perRun":2,"perDay":8,"mergesPerRun":10,"allow":[],"deny":[]}. Both automatic parts are
# off until you turn them on. What a pass did is in prs-state.json and in the journal. The pass itself (resolving with
# Claude, pushing, merging) is lib/prsfix.sh. docs/PRS.md has the whole story.
#
# A row's state, in this order:
#   draft     a draft: left alone
#   conflict  GitHub says CONFLICTING: the base is merged into the branch (with Claude when git cannot do it alone)
#   unknown   GitHub has not computed it yet (normal on a first read): neither conflict nor clean, never told
#   changes   a reviewer asked for changes: not merged
#   red       the checks failed: never merged
#   pending   the checks still run
#   behind    the base moved and the repo wants branches up to date: GitHub updates the branch (no clone, no Claude)
#   ready     MERGEABLE, CLEAN and green: merged
#   blocked   anything else GitHub blocks (a review is required, a rule): left alone, with the reason

PRS_FILE="${CONFIG_DIR:-$HOME/.config/deploys}/prs.json"
PRS_STATE="${CONFIG_DIR:-$HOME/.config/deploys}/prs-state.json"
PRS_LABEL="app.deploycenter.prs"
PRS_EVERY="${DEPLOYS_PRS_EVERY:-300}"

prs_conf() {  # the settings with their defaults; a number that is not one falls back
  { cat "$PRS_FILE" 2>/dev/null || echo '{}'; } | jq -c '(if type == "object" then . else {} end) as $f
    | def n($k; $d): ($f[$k] | if type == "number" and . >= 0 then floor else $d end);
      def b($k): ($f[$k] == true);
      {autoResolve: b("autoResolve"), autoMerge: b("autoMerge"), mergeWithoutChecks: b("mergeWithoutChecks"),
       perRun: n("perRun"; 2), perDay: n("perDay"; 8), mergesPerRun: n("mergesPerRun"; 10),
       allow: ([$f.allow[]? | strings] | unique), deny: ([$f.deny[]? | strings] | unique)}' 2>/dev/null \
    || echo '{"autoResolve":false,"autoMerge":false,"mergeWithoutChecks":false,"perRun":2,"perDay":8,"mergesPerRun":10,"allow":[],"deny":[]}'
}
prs_save() { jq . | atomic_write "$PRS_FILE"; }
prs_state() { { [ -s "$PRS_STATE" ] && jq -c 'if type == "object" then . else {} end' "$PRS_STATE" 2>/dev/null; } || echo '{}'; }
prs_state_save() { jq . | atomic_write "$PRS_STATE"; }
prs_now() { echo "${DEPLOYS_NOW:-$(date +%s)}"; }
prs_scheduled() { [ -f "$(job_plist "$PRS_LABEL")" ] && launchctl print "gui/$(id -u)/$PRS_LABEL" >/dev/null 2>&1; }

prs_query() {
  cat <<'GRAPHQL'
query($q:String!){viewer{login} search(type:ISSUE,query:$q,first:100){issueCount nodes{... on PullRequest{
 number title url isDraft mergeable mergeStateStatus reviewDecision baseRefName headRefName headRefOid isCrossRepository updatedAt
 repository{nameWithOwner mergeCommitAllowed squashMergeAllowed rebaseMergeAllowed}
 commits(last:1){nodes{commit{statusCheckRollup{state}}}}}}}}
GRAPHQL
}

# The raw answer of GitHub, or {"error": "…"}.
prs_fetch() {
  local out
  if out="$(gh api graphql -f query="$(prs_query)" -f q="is:pr is:open author:@me archived:false sort:updated-desc" 2>&1)" \
     && jq -e '.data.search' >/dev/null 2>&1 <<<"$out"; then
    jq -c '.data' <<<"$out"
  else
    jq -cn --arg e "$(printf '%s' "$out" | head -c 300)" '{error: (if $e == "" then "no answer from gh" else $e end)}'
  fi
}

# jq: the rows. In: {data, conf}. A repo outside allow (when allow is set) or in deny is left out.
prs_rows_jq() {
  cat <<'JQ'
.conf as $c
| [.data.search.nodes[]? | select(.number != null)
   | .repository.nameWithOwner as $repo
   | select((($c.allow | length) == 0 or ($c.allow | index($repo))) and (($c.deny | index($repo)) | not))
   | (.commits.nodes[0].commit.statusCheckRollup.state // null) as $ci
   | (if .isDraft then ["draft", "a draft"]
      elif .mergeable == "CONFLICTING" then ["conflict", "merge conflict with \(.baseRefName)"]
      elif .mergeable != "MERGEABLE" then ["unknown", "GitHub is still computing whether it merges"]
      elif .reviewDecision == "CHANGES_REQUESTED" then ["changes", "changes requested"]
      elif $ci == "FAILURE" or $ci == "ERROR" then ["red", "checks failed"]
      elif $ci == "PENDING" or $ci == "EXPECTED" then ["pending", "checks are running"]
      elif .mergeStateStatus == "BEHIND" then ["behind", "\(.baseRefName) moved on; the branch needs it"]
      elif .mergeStateStatus == "CLEAN" and ($ci == "SUCCESS" or ($ci == null and $c.mergeWithoutChecks)) then ["ready", "ready to merge"]
      elif .mergeStateStatus == "CLEAN" and $ci == null then ["blocked", "no checks ran (mergeWithoutChecks is off)"]
      else ["blocked", "GitHub says \(.mergeStateStatus | ascii_downcase)"] end) as $s
   | {repo: $repo, pr: .number, title, url, draft: .isDraft, mergeable, mergeState: .mergeStateStatus,
      review: .reviewDecision, ci: $ci, base: .baseRefName, head: .headRefName, headOid: .headRefOid,
      cross: .isCrossRepository, updatedAt, state: $s[0], why: $s[1],
      key: "\($repo)#\(.number):\(.headRefOid)",
      methods: ([(if .repository.mergeCommitAllowed then "merge" else empty end),
                 (if .repository.squashMergeAllowed then "squash" else empty end),
                 (if .repository.rebaseMergeAllowed then "rebase" else empty end)])}]
JQ
}

prs_report() {  # the whole answer as JSON
  local conf now data rows='[]' errors='[]' user="" state sched=false
  conf="$(prs_conf)"; now="$(prs_now)"; state="$(prs_state)"
  data="$(prs_fetch)"
  if jq -e '.error' >/dev/null <<<"$data"; then errors="$(jq -c '[{error: .error}]' <<<"$data")"
  else
    user="$(jq -r '.viewer.login // ""' <<<"$data")"
    rows="$(jq -c --argjson c "$conf" "{data: ., conf: \$c} | $(prs_rows_jq)" <<<"$data")"
  fi
  prs_scheduled && sched=true
  # "resolving": a pass holds the lock and names the pull request it works on.
  local running='null'
  [ -d "$CONFIG_DIR/locks/prs" ] && running="$(jq -c '.running // null' <<<"$state")"
  jq -n --argjson rows "$rows" --argjson errors "$errors" --argjson conf "$conf" --argjson now "$now" \
     --argjson st "$state" --arg user "$user" --argjson sched "$sched" --argjson running "$running" '
    def cnt($s): [$rows[] | select(.state == $s)] | length;
    ([$st.events[]? | select((.at // 0) >= $now - 86400)]) as $day
    | {at: ($now | todate), user: $user, settings: $conf, schedule: $sched, running: $running,
       firstRunPending: ($st.firstRunPending == true), errors: $errors,
       summary: {open: ($rows | length), conflicts: cnt("conflict"), unknown: cnt("unknown"), behind: cnt("behind"),
                 ready: cnt("ready"), red: cnt("red"), pending: cnt("pending"), draft: cnt("draft"),
                 changes: cnt("changes"), blocked: cnt("blocked"), resolving: (if $running == null then 0 else 1 end),
                 mergedToday: ([$day[] | select(.kind == "merge" and .result == "merged")] | length),
                 resolvedToday: ([$day[] | select((.kind == "resolve" or .kind == "update") and .result == "pushed")] | length),
                 failedToday: ([$day[] | select(.result == "failed")] | length)},
       conflicts: [$rows[] | select(.state == "conflict")],
       prs: $rows, lastRun: ($st.lastRun // null), events: ($day | sort_by(-.at) | .[0:30])}'
}

prs_print() {  # stdin: the JSON of prs_report
  jq -r '
    "Your open pull requests\(if .user != "" then " (" + .user + ")" else "" end): \(.summary.open)",
    "  \(.summary.conflicts) with conflicts, \(.summary.ready) ready, \(.summary.behind) behind, \(.summary.pending) checks running, \(.summary.red) red, \(.summary.unknown) not computed yet",
    "  today: \(.summary.mergedToday) merged, \(.summary.resolvedToday) brought up to date, \(.summary.failedToday) failed",
    "  automatic: resolve \(if .settings.autoResolve then "on" else "off" end), merge \(if .settings.autoMerge then "on" else "off" end), schedule \(if .schedule then "on" else "off" end)\(if .firstRunPending then " (the next pass only reports)" else "" end)",
    (.errors[] | "  not read: \(.error | split("\n")[0])"),
    (.prs[] | "  \(.state | ("        " + .)[-8:])  \(.repo)#\(.pr)  \(.title // "" | .[0:56])  – \(.why)")'
}

prs_set() {  # prs_set <key> <value>
  local v
  case "$1" in
    autoResolve|autoMerge|mergeWithoutChecks)
      case "${2:-}" in on|true|1) v=true ;; off|false|0) v=false ;; *) die_usage "deploys prs set $1 on|off" ;; esac
      prs_conf | jq --arg k "$1" --argjson v "$v" '.[$k] = $v' | prs_save ;;
    perRun|perDay|mergesPerRun)
      [[ "${2:-}" =~ ^[0-9]{1,4}$ ]] || die_usage "deploys prs set $1 <number, 0-9999 (0 = no cap)>"
      prs_conf | jq --arg k "$1" --argjson v "$((10#$2))" '.[$k] = $v' | prs_save ;;
    *) die_usage "deploys prs set autoResolve|autoMerge|mergeWithoutChecks on|off | perRun|perDay|mergesPerRun <n>" ;;
  esac
  prs_conf | jq -r '"Resolve: \(if .autoResolve then "on" else "off" end), merge: \(if .autoMerge then "on" else "off" end), without checks: \(if .mergeWithoutChecks then "yes" else "no" end), caps: \(.perRun) per pass, \(.perDay) per day, \(.mergesPerRun) merges per pass"'
}

prs_main() {
  local yes="" dry=""
  case "${1:-}" in
    set) prs_set "${2:-}" "${3:-}"; return ;;
    allow|deny|unlist)
      [[ "${2:-}" =~ ^[A-Za-z0-9_.-]+/[A-Za-z0-9_.-]+$ ]] || die_usage "deploys prs $1 <owner/name>"
      case "$1" in
        allow) prs_conf | jq --arg r "$2" '.allow = (.allow + [$r] | unique) | .deny -= [$r]' | prs_save ;;
        deny) prs_conf | jq --arg r "$2" '.deny = (.deny + [$r] | unique) | .allow -= [$r]' | prs_save ;;
        unlist) prs_conf | jq --arg r "$2" '.allow -= [$r] | .deny -= [$r]' | prs_save ;;
      esac
      prs_conf | jq -r '"Only: \(if (.allow | length) == 0 then "every repo" else (.allow | join(", ")) end); left out: \(if (.deny | length) == 0 then "none" else (.deny | join(", ")) end)"'
      return ;;
    schedule)
      case "${2:-}" in
        on) job_on "$PRS_LABEL" "$PRS_EVERY" DeployCenter-prs prs run --yes
            prs_state | jq '.firstRunPending = true' | prs_state_save
            echo "deploys prs runs every $((PRS_EVERY / 60)) minutes (log: ~/Library/Logs/DeployCenter-prs.log). The first pass only reports what it would do." ;;
        off) job_off "$PRS_LABEL"; echo "deploys prs no longer runs by itself." ;;
        ""|status) if prs_scheduled; then echo on; else echo off; fi ;;
        *) die_usage "deploys prs schedule on|off" ;;
      esac
      return ;;
    run)
      shift
      while [ "$#" -gt 0 ]; do
        case "$1" in --yes) yes=1 ;; --dry-run) dry=1 ;; *) die_usage "deploys prs run --yes [--dry-run]" ;; esac
        shift
      done
      [ -n "$yes" ] || [ -n "$dry" ] || die_usage "deploys prs run --yes pushes and merges; --dry-run only reports what it would do"
      command -v gh >/dev/null 2>&1 || die "deploys prs needs the GitHub CLI (gh), logged in: gh auth login"
      declare -F prs_run >/dev/null || die "lib/prsfix.sh is not next to deploys."
      prs_run "$dry"; return ;;
    "") ;;
    *) die_usage "Usage: deploys prs [--json] | run --yes [--dry-run] | schedule on|off | set <key> <value> | allow|deny|unlist <owner/name>" ;;
  esac
  command -v gh >/dev/null 2>&1 || die "deploys prs needs the GitHub CLI (gh), logged in: gh auth login"
  if [ "${json:-0}" = 1 ]; then prs_report; else prs_report | prs_print; fi
}
