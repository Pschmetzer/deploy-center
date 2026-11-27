# shellcheck shell=bash
# lib/prsfix.sh — the pass of `deploys prs run --yes` (lib/prs.sh reads the pull requests, this file acts on them).
#
# For each of your open pull requests, in this order:
#   conflict  the head branch is checked out in a temporary worktree of a cached clone and the base is merged into it
#             (git merge, never a rebase). When git cannot do it alone, a headless `claude -p` resolves the conflicts
#             there (the CLI's own login, not an API key; see sc_claude in deploys) and runs the repo's checks. A normal
#             commit is pushed only when no conflict is left and Claude reports the checks passed. Never a force push.
#   behind    GitHub merges the base into the branch itself (update-branch with the expected head SHA).
#   ready     gh pr merge --merge (squash when the repo allows only that) with --match-head-commit. Never --admin,
#             never with red checks, never in the same pass that pushed to it, at most one per repo and base per pass
#             (the base moved, so what GitHub said about the others is old).
# One attempt per repo#pr:headOid: a new push to the branch is a new attempt. Caps per pass and per 24 hours.
# A pull request whose branch a busy Claude Code session on this Mac has checked out is skipped (it would race its
# pushes): ~/.claude/sessions/*.json and `claude agents --json`, cwd and branch. The pass waits for nothing: when the
# load brake (deploys perf) says memory or swap is tight, it is skipped and the next one tries again.
# Every push and merge goes into the journal. Nothing here deploys: auto-deploy stays as it is.

PRS_CACHE="${CONFIG_DIR:-$HOME/.config/deploys}/prs-cache"
PRS_TIMEOUT="${DEPLOYS_PRS_TIMEOUT:-1800}"

# Seams: the address of a repo (only tests point it elsewhere), git with the gh login, the load brake.
prs_remote_url() {
  if [ "${DEPLOYS_TESTING:-}" = 1 ] && [ -n "${DEPLOYS_PRS_REMOTE:-}" ]; then echo "$DEPLOYS_PRS_REMOTE/$1.git"
  else echo "https://github.com/$1.git"; fi
}
prs_git() { git -c credential.helper= -c 'credential.helper=!gh auth git-credential' -c core.hooksPath=/dev/null "$@"; }
prs_brake() {  # the reason when memory or swap is tight, else nothing
  if [ "${DEPLOYS_TESTING:-}" = 1 ] && [ -n "${DEPLOYS_PRS_BRAKE+x}" ]; then printf '%s' "$DEPLOYS_PRS_BRAKE"; return 0; fi
  declare -F perf_snapshot >/dev/null || return 0
  local s; s="$(perf_snapshot 2>/dev/null)" || return 0
  # Only memory and swap count: a busy CPU or other heavy checks slow a pass down but do not freeze the Mac.
  jq -r '[.hold[]? | select(test("swap|pressure|memory|RAM"; "i"))] | if length > 0 then join("; ") else empty end' <<<"$s" 2>/dev/null || true
}
prs_repo_of_url() { printf '%s' "$1" | sed -E 's#\.git/?$##; s#/+$##' | awk -F'[/:]' 'NF >= 2 { print $(NF-1) "/" $NF }'; }

# The branches busy Claude Code sessions on this Mac are on: lines "owner/name<TAB>branch".
prs_busy() {
  local d f b cwd br url
  d="${DEPLOYS_LOCAL_SESSIONS_DIR:-$HOME/.claude/sessions}"
  {
    for f in "$d"/*.json; do
      [ -f "$f" ] || continue
      jq -r 'select((.status // "") as $s | $s != "" and $s != "idle" and $s != "done" and $s != "completed" and $s != "stopped" and $s != "exited")
             | "\(.pid // 0)\t\(.cwd // "")"' "$f" 2>/dev/null \
        | while IFS="$(printf '\t')" read -r pid cwd; do kill -0 "$pid" 2>/dev/null && echo "$cwd"; done
    done
    b="$(sc_claude_bin)"
    if [ -n "$b" ]; then
      perl -e 'alarm shift; exec @ARGV or die' 20 "$b" agents --json </dev/null 2>/dev/null \
        | jq -r '.[]? | select((.status // "") as $s | $s != "" and $s != "idle" and $s != "done" and $s != "completed" and $s != "stopped" and $s != "exited") | .cwd // empty' 2>/dev/null || true
    fi
  } | sort -u | while IFS= read -r cwd; do
    [ -n "$cwd" ] && [ -d "$cwd" ] || continue
    br="$(git -C "$cwd" symbolic-ref --short -q HEAD 2>/dev/null)" || continue
    url="$(git -C "$cwd" remote get-url origin 2>/dev/null)" || continue
    printf '%s\t%s\n' "$(prs_repo_of_url "$url")" "$br"
  done
}

PRS_RUN_STATE=""   # the state while a pass runs: kept in memory, saved after each step
prs_put() { PRS_RUN_STATE="$(jq -c "$@" <<<"$PRS_RUN_STATE")"; printf '%s' "$PRS_RUN_STATE" | prs_state_save; }
# prs_event <kind> <row json> <result> <detail>: remembered (one attempt per key), told in the journal and on stdout.
prs_event() {
  local now; now="$(prs_now)"
  prs_put --arg k "$1" --argjson r "$2" --arg res "$3" --arg d "$4" --argjson now "$now" '
    .attempts = ((.attempts // {}) + {("\($k):\($r.key)"): {at: $now, result: $res}})
    | .events = (((.events // []) + [{at: $now, kind: $k, repo: $r.repo, pr: $r.pr, key: $r.key, title: $r.title, url: $r.url, result: $res, detail: $d}]) | .[-300:])
    | .run.actions += [{kind: $k, repo: $r.repo, pr: $r.pr, key: $r.key, result: $res, detail: $d}]'
  local res="$3"; [ "$3" != merged ] && [ "$3" != pushed ] || res="${1}d"   # resolved, updated, merged
  journal_add github "$(jq -r '"\(.repo)#\(.pr)"' <<<"$2")" "$res" "$4" 2>/dev/null || true
  echo "  $1 $(jq -r '"\(.repo)#\(.pr)"' <<<"$2"): $3${4:+ – $4}"
}
prs_skip() { prs_put --argjson r "$1" --arg w "$2" '.run.skips += [{repo: $r.repo, pr: $r.pr, key: $r.key, why: $w}]'; }
prs_tried() {  # prs_tried <kind> <key> [retry after seconds]: an attempt that counts is there
  jq -e --arg a "$1:$2" --argjson now "$(prs_now)" --argjson after "${3:-0}" \
    '(.attempts // {})[$a] as $x | $x != null and ($after == 0 or $x.result != "failed" or ($now - $x.at) < $after)' <<<"$PRS_RUN_STATE" >/dev/null
}
prs_day_count() { jq --argjson now "$(prs_now)" '[.events[]? | select(.at >= $now - 86400 and (.kind == "resolve" or .kind == "update"))] | length' <<<"$PRS_RUN_STATE"; }

prs_prompt() {  # prs_prompt <base> <head> <files>
  cat <<PROMPT
You are in a git worktree of the branch "$2". The branch "$1" was just merged into it and git stopped with merge
conflicts in these files:
$3

1. Resolve every conflict: remove all conflict markers (<<<<<<<, =======, >>>>>>>) and keep the intent of both sides.
   Where both sides changed the same thing, combine them; do not simply take one side. Do not touch other files unless
   the merge needs it to build.
2. Do not run git commands that change history or the index (no commit, add, merge, rebase, reset, checkout, push).
3. Find the repo's checks (AGENTS.md, CONTRIBUTING.md, package.json scripts, Makefile, tests/) and run the fast ones
   (build, type check, lint, unit tests). Fix what the merge broke.
4. End your answer with exactly one line: "RESULT: PASS" when no conflict is left and the checks pass, or
   "RESULT: FAIL <short reason>" otherwise. Never paste tokens or environment values.
PROMPT
}

PRS_R="" PRS_D=""   # the result of prs_resolve: pushed|failed|moved and a detail
prs_resolve() {  # prs_resolve <row json>
  local repo base head oid slug cache tmp wt files f bad report sha how
  repo="$(jq -r .repo <<<"$1")"; base="$(jq -r .base <<<"$1")"; head="$(jq -r .head <<<"$1")"; oid="$(jq -r .headOid <<<"$1")"
  slug="$(sc_slug "$repo")"; cache="$PRS_CACHE/$slug.git"; PRS_R=failed; PRS_D=""
  mkdir -p "$PRS_CACHE"
  if [ ! -d "$cache" ]; then
    prs_git clone -q --bare --filter=blob:none "$(prs_remote_url "$repo")" "$cache" </dev/null >/dev/null 2>&1 \
      || { rm -rf "$cache"; PRS_D="could not clone $repo"; return; }
  fi
  prs_git -C "$cache" fetch -q --no-tags origin "+refs/heads/$base:refs/remotes/origin/$base" "+refs/heads/$head:refs/remotes/origin/$head" </dev/null >/dev/null 2>&1 \
    || { PRS_D="could not fetch $base and $head"; return; }
  if [ "$(git -C "$cache" rev-parse "refs/remotes/origin/$head" 2>/dev/null)" != "$oid" ]; then PRS_R=moved; PRS_D="the branch moved since GitHub was read"; return; fi
  tmp="$(mktemp -d "${TMPDIR:-/tmp}/deploys-prs.XXXXXX")"; wt="$tmp/wt"
  git -C "$cache" worktree add -q --detach "$wt" "refs/remotes/origin/$head" </dev/null >/dev/null 2>&1 || { rm -rf "$tmp"; PRS_D="could not check out $head"; return; }
  local ident=()
  [ -n "$(git -C "$wt" config user.email 2>/dev/null)" ] || ident=(-c user.name="Deploy Center" -c user.email="deploy-center@users.noreply.github.com")
  how="clean merge"
  if ! prs_git ${ident[@]+"${ident[@]}"} -C "$wt" merge -q --no-ff --no-edit -m "Merge $base into $head (deploys prs)" "refs/remotes/origin/$base" </dev/null >/dev/null 2>&1; then
    files="$(git -C "$wt" diff --name-only --diff-filter=U 2>/dev/null)"
    if [ -z "$files" ]; then PRS_D="git merge failed without conflicts"
    elif [ -z "$(sc_claude_bin)" ]; then PRS_D="conflicts in $(echo "$files" | wc -l | tr -d ' ') files and the Claude Code CLI is not installed"
    else
      report="$(SCAN_TIMEOUT="$PRS_TIMEOUT" sc_claude "$wt" "$(prs_prompt "$base" "$head" "$files")" </dev/null 2>/dev/null)" || report=""
      bad=""
      while IFS= read -r f; do
        [ -n "$f" ] || continue
        if [ -f "$wt/$f" ] && grep -qE '^(<<<<<<<|>>>>>>>)( |$)' "$wt/$f"; then bad="$bad $f"; else git -C "$wt" add -A -- "$f" 2>/dev/null || bad="$bad $f"; fi
      done <<<"$files"
      git -C "$wt" add -A 2>/dev/null || true
      if [ -n "$bad" ]; then PRS_D="conflict markers left in$bad"
      elif [ -n "$(git -C "$wt" diff --name-only --diff-filter=U 2>/dev/null)" ]; then PRS_D="files are still unmerged"
      elif ! printf '%s\n' "$report" | grep -qE '^RESULT: PASS[[:space:]]*$'; then
        PRS_D="Claude did not report passing checks: $(printf '%s\n' "$report" | grep -E '^RESULT:' | tail -1 | cut -c1-160)"
        [ -n "$report" ] || PRS_D="Claude gave no answer (timeout or error)"
      elif ! prs_git ${ident[@]+"${ident[@]}"} -C "$wt" commit -q --no-edit </dev/null >/dev/null 2>&1; then PRS_D="the merge commit failed"
      else how="conflicts in $(echo "$files" | wc -l | tr -d ' ') files resolved by Claude, checks passed"; fi
    fi
    [ "$how" != "clean merge" ] || [ -z "$PRS_D" ] || { git -C "$cache" worktree remove --force "$wt" >/dev/null 2>&1; rm -rf "$tmp"; return; }
  fi
  sha="$(git -C "$wt" rev-parse HEAD)"
  # A normal push: when someone pushed in the meantime it is refused, and the next pass tries the new head.
  if prs_git -C "$wt" push -q origin "HEAD:refs/heads/$head" </dev/null >/dev/null 2>&1; then PRS_R=pushed; PRS_D="merged $base into $head ($how), pushed ${sha:0:7}"
  else PRS_D="the push was refused (the branch moved?)"; fi
  git -C "$cache" worktree remove --force "$wt" >/dev/null 2>&1 || true; rm -rf "$tmp"
}

prs_merge_method() { jq -r 'if (.methods | index("merge")) then "merge" elif (.methods | index("squash")) then "squash" else "" end' <<<"$1"; }

prs_run() {  # prs_run <dry: 1 or "">
  local dry="$1" lock conf report brake busy row key repo pr why n=0 merges=0 day perRun perDay perMerge pushed="" bases="" first=""
  [ -n "$dry" ] || require_write "prs run"
  mkdir -p "$CONFIG_DIR/locks"; lock="$CONFIG_DIR/locks/prs"
  lock_clear_stale "$lock" 3600
  mkdir "$lock" 2>/dev/null || { echo "deploys prs: a pass is running already."; return 0; }
  trap_fn exit_rmdir "$lock"
  conf="$(prs_conf)"; PRS_RUN_STATE="$(prs_state)"
  if [ -z "$dry" ] && jq -e '.firstRunPending == true' <<<"$PRS_RUN_STATE" >/dev/null; then dry=1; first=1; fi
  prs_put --argjson now "$(prs_now)" --argjson dry "$([ -n "$dry" ] && echo true || echo false)" \
    '.run = {at: $now, dry: $dry, brake: null, actions: [], skips: []} | .running = null'
  if [ -z "$dry" ] && ! jq -e '.autoResolve or .autoMerge' <<<"$conf" >/dev/null; then
    prs_put '.lastRun = (.run + {off: true}) | del(.run)'
    echo "deploys prs: resolving and merging are off (deploys prs set autoResolve on, deploys prs set autoMerge on)."; return 0
  fi
  brake=""; [ -n "$dry" ] && [ -z "$first" ] || brake="$(prs_brake)"
  if [ -n "$brake" ]; then
    prs_put --arg b "$brake" '.run.brake = $b | .lastRun = .run | del(.run)'
    echo "deploys prs: skipped, the Mac is busy ($brake). The next pass tries again."; return 0
  fi
  report="$(prs_report)"
  if jq -e '.errors | length > 0' <<<"$report" >/dev/null; then
    prs_put --arg e "$(jq -r '.errors[0].error' <<<"$report")" '.run.error = $e | .lastRun = .run | del(.run)'
    echo "deploys prs: GitHub was not read: $(jq -r '.errors[0].error' <<<"$report" | head -1)"; return 1
  fi
  busy="$(prs_busy)"
  perRun="$(jq -r .perRun <<<"$conf")"; perDay="$(jq -r .perDay <<<"$conf")"; perMerge="$(jq -r .mergesPerRun <<<"$conf")"
  echo "deploys prs$([ -n "$dry" ] && echo " (dry run$([ -n "$first" ] && echo ", the first pass after turning it on"))"): $(jq -r '"\(.summary.open) open, \(.summary.conflicts) with conflicts, \(.summary.behind) behind, \(.summary.ready) ready"' <<<"$report")"

  # Conflicts and branches behind their base: brought up to date, within the caps.
  while IFS= read -r row <&3; do
    key="$(jq -r .key <<<"$row")"; repo="$(jq -r .repo <<<"$row")"; pr="$(jq -r .pr <<<"$row")"
    local kind=resolve; [ "$(jq -r .state <<<"$row")" = behind ] && kind=update
    if [ -z "$dry" ] && ! jq -e '.autoResolve' <<<"$conf" >/dev/null; then prs_skip "$row" "autoResolve is off"; continue; fi
    if [ "$(jq -r .cross <<<"$row")" = true ]; then prs_skip "$row" "the branch is in a fork"; continue; fi
    if printf '%s\n' "$busy" | grep -qxF "$repo$(printf '\t')$(jq -r .head <<<"$row")"; then prs_skip "$row" "a Claude Code session on this Mac is working on this branch"; continue; fi
    if prs_tried "$kind" "$key"; then prs_skip "$row" "tried once at this commit"; continue; fi
    day="$(prs_day_count)"
    if [ "$perRun" -gt 0 ] && [ "$n" -ge "$perRun" ]; then prs_skip "$row" "cap of $perRun per pass reached"; continue; fi
    if [ "$perDay" -gt 0 ] && [ "$day" -ge "$perDay" ]; then prs_skip "$row" "cap of $perDay per day reached"; continue; fi
    n=$((n + 1))
    if [ -n "$dry" ]; then prs_put --argjson r "$row" --arg k "$kind" '.run.actions += [{kind: $k, repo: $r.repo, pr: $r.pr, key: $r.key, result: "would", detail: ""}]'
      echo "  would $kind $repo#$pr"; continue; fi
    brake="$(prs_brake)"
    if [ -n "$brake" ]; then prs_skip "$row" "the Mac is busy ($brake)"; break; fi
    if [ "$kind" = update ]; then
      if gh api -X PUT "repos/$repo/pulls/$pr/update-branch" -f expected_head_sha="$(jq -r .headOid <<<"$row")" </dev/null >/dev/null 2>&1; then
        prs_event update "$row" pushed "GitHub merged $(jq -r .base <<<"$row") into the branch"
      else prs_event update "$row" failed "GitHub did not update the branch"; fi
    else
      prs_put --argjson r "$row" --argjson now "$(prs_now)" '.running = {key: $r.key, repo: $r.repo, pr: $r.pr, at: $now}'
      prs_resolve "$row"
      prs_put '.running = null'
      # A branch that moved is not an attempt: the next pass reads the new head.
      if [ "$PRS_R" = moved ]; then prs_skip "$row" "$PRS_D"; n=$((n - 1)); continue; fi
      prs_event resolve "$row" "$PRS_R" "$PRS_D"
    fi
    pushed="$pushed $key"
  done 3< <(jq -c '.prs[] | select(.state == "conflict" or .state == "behind")' <<<"$report")

  # Ready ones: merged, one per repo and base, never one this pass pushed to.
  while IFS= read -r row <&3; do
    key="$(jq -r .key <<<"$row")"; repo="$(jq -r .repo <<<"$row")"; pr="$(jq -r .pr <<<"$row")"
    if [ -z "$dry" ] && ! jq -e '.autoMerge' <<<"$conf" >/dev/null; then prs_skip "$row" "autoMerge is off"; continue; fi
    case " $pushed " in *" $key "*) continue ;; esac
    case " $bases " in *" $repo:$(jq -r .base <<<"$row") "*) prs_skip "$row" "another pull request was merged into $(jq -r .base <<<"$row") in this pass"; continue ;; esac
    if printf '%s\n' "$busy" | grep -qxF "$repo$(printf '\t')$(jq -r .head <<<"$row")"; then prs_skip "$row" "a Claude Code session on this Mac is working on this branch"; continue; fi
    if prs_tried merge "$key" 21600; then prs_skip "$row" "tried once at this commit"; continue; fi
    if [ "$perMerge" -gt 0 ] && [ "$merges" -ge "$perMerge" ]; then prs_skip "$row" "cap of $perMerge merges per pass reached"; continue; fi
    local m; m="$(prs_merge_method "$row")"
    if [ -z "$m" ]; then prs_skip "$row" "the repo allows neither merge commits nor squash"; continue; fi
    merges=$((merges + 1)); bases="$bases $repo:$(jq -r .base <<<"$row")"
    if [ -n "$dry" ]; then prs_put --argjson r "$row" '.run.actions += [{kind: "merge", repo: $r.repo, pr: $r.pr, key: $r.key, result: "would", detail: ""}]'
      echo "  would merge $repo#$pr"; continue; fi
    if why="$(gh pr merge "$pr" --repo "$repo" "--$m" --match-head-commit "$(jq -r .headOid <<<"$row")" </dev/null 2>&1)"; then
      prs_event merge "$row" merged "merged into $(jq -r .base <<<"$row") ($m)"
    else prs_event merge "$row" failed "gh pr merge: $(printf '%s' "$why" | head -1 | cut -c1-160)"; fi
  done 3< <(jq -c '.prs[] | select(.state == "ready")' <<<"$report")

  prs_put "$( [ -n "$first" ] && echo '.firstRunPending = false |' ) .lastRun = .run | del(.run)"
  jq -r '.lastRun | "  done: \([.actions[] | select(.result != "would")] | length) actions, \([.actions[] | select(.result == "would")] | length) would be done, \(.skips | length) skipped",
    (.skips[] | "  skipped \(.repo)#\(.pr): \(.why)")' <<<"$PRS_RUN_STATE"
}
