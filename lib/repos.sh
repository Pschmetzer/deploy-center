# shellcheck shell=bash
# lib/repos.sh — `deploys repos`: keep the local checkouts of your projects on top of origin.
#
#   deploys repos status [--no-fetch] [--json]   what each checkout is and what a sync would do (changes nothing)
#   deploys repos sync [--yes] [--json]          without --yes the same report; with --yes it does it
#   deploys repos last [--json]                  the result of the last run (repos-last.json), no git, no network
#   deploys repos schedule on|off|status         a LaunchAgent: `repos sync --yes` every 30 minutes and at login
#
# When sessions work in worktrees or in the cloud and merge through pull requests, the main checkout stays
# on an old branch and falls hundreds of commits behind. Per repo, after `git fetch origin` (stale refs are pruned once a sync has decided):
#   clean, on the default branch        -> fast-forward (git merge --ff-only), never a merge commit
#   clean, on a branch that is merged   -> switch to the default branch, fast-forward, delete the branch
#     (merged: its commits are in origin/<default>, or merging it there changes nothing (a squash merge),
#      or `gh` shows a merged pull request whose head is exactly this commit)
#   clean, branch gone on origin, every commit of it was pushed -> switch and fast-forward; the branch stays
#   clean, branch with commits of its own -> reported (ahead/behind), nothing changes
#   changes, a conflict, a merge/rebase/cherry-pick running -> never touched, reported as "needs you"
# Never acted on: a repo whose fetch failed, a switch while the checkout was used in the last hour or git holds
# its index lock, a local default branch with commits of its own, and an update that would overwrite an
# ignored file (a local .env) that the new commit tracks.
# Linked worktrees: `git worktree prune`; a worktree with no changes, unused for a day, no process inside,
# not under .claude/worktrees (the Claude app manages those), whose branch is merged, is removed with `git worktree remove` (no --force) and its branch deleted.
# A deleted branch's commit is in the result and the journal: `git branch <name> <commit>` brings it back.
# Hooks are off for the switch and the merge (core.hooksPath): a background job must not run npm scripts.
#
# Which repos: repos.json in the config folder {"roots":["~/Code"],"repos":["~/x"],"skip":["name"]};
# without it the roots of clean.json; without that ~/Documents/Claude. A repo is a folder directly under a
# root with a .git folder (a linked worktree has a .git file and belongs to its main checkout).
# The last result goes to repos-last.json (the app and the MCP server read it).
# Sourced by deploys; uses die, journal_add, job_on, job_off, job_plist, lock_clear_stale and CONFIG_DIR.

REPOS_LABEL="com.deploycenter.repos"
REPOS_IDLE_MIN="${DEPLOYS_REPOS_IDLE_MIN:-1440}"   # a worktree used within this many minutes is left alone

repos_cfg() {  # repos_cfg <file> <jq path>
  [ -f "$CONFIG_DIR/$1" ] || return 0
  jq -r "$2 // empty" "$CONFIG_DIR/$1" 2>/dev/null || true
}

repos_list() {  # one absolute repo path per line
  local roots=() r d skip
  while IFS= read -r r; do [ -n "$r" ] && roots+=("${r/#\~/$HOME}"); done < <(repos_cfg repos.json '.roots[]?')
  if [ ${#roots[@]} -eq 0 ] && [ -z "$(repos_cfg repos.json '.repos[]?')" ]; then
    while IFS= read -r r; do [ -n "$r" ] && roots+=("${r/#\~/$HOME}"); done < <(repos_cfg clean.json '.roots[]?')
    [ ${#roots[@]} -gt 0 ] || roots=("$HOME/Documents/Claude")
  fi
  skip=" $(repos_cfg repos.json '.skip[]?' | tr '\n' ' ') "
  {
    for r in "${roots[@]}"; do for d in "$r"/*/; do d="${d%/}"; [ -d "$d/.git" ] && echo "$d"; done; done
    repos_cfg repos.json '.repos[]?' | while IFS= read -r d; do d="${d/#\~/$HOME}"; [ -d "$d/.git" ] && echo "${d%/}"; done
  } | awk '!seen[$0]++' | while IFS= read -r d; do
    case "$skip" in *" $(basename "$d") "*|*" $d "*) ;; *) echo "$d" ;; esac
  done
}

repos_git() { git -c core.hooksPath=/dev/null -c advice.detachedHead=false "$@"; }

# A merge, rebase, cherry-pick, revert or bisect is running in this checkout.
repos_busy() {  # repos_busy <work tree>
  local gd; gd="$(git -C "$1" rev-parse --absolute-git-dir 2>/dev/null)" || return 0
  [ -e "$gd/MERGE_HEAD" ] || [ -d "$gd/rebase-merge" ] || [ -d "$gd/rebase-apply" ] || [ -e "$gd/CHERRY_PICK_HEAD" ] \
    || [ -e "$gd/REVERT_HEAD" ] || [ -e "$gd/BISECT_LOG" ]
}
# Uncommitted changes or untracked files (ignored files do not count); a failing status counts as dirty.
repos_dirty() {  # repos_dirty <work tree>
  local s; s="$(git -C "$1" status --porcelain 2>/dev/null)" || return 0
  [ -n "$s" ]
}

# Everything on <commit> is in <base>: an ancestor, or merging it changes nothing (a squash merge).
repos_in_base() {  # repos_in_base <repo> <base ref> <commit>
  local t b
  git -C "$1" merge-base --is-ancestor "$3" "$2" 2>/dev/null && return 0
  t="$(git -C "$1" merge-tree --write-tree "$2" "$3" 2>/dev/null)" || return 1
  t="$(printf '%s\n' "$t" | head -n 1)"; b="$(git -C "$1" rev-parse "$2^{tree}" 2>/dev/null)"
  [ -n "$t" ] && [ "$t" = "$b" ]
}
# A merged pull request on GitHub whose head is exactly <commit> (gh, when it is there and signed in). The last
# 200 merged pull requests of a repo are read once per run (REPOS_PR_CACHE), not once per branch.
repos_pr_merged() {  # repos_pr_merged <repo> <branch> <commit>
  [ "${DEPLOYS_REPOS_NO_GH:-}" = 1 ] && return 1
  [ -n "$2" ] && command -v gh >/dev/null 2>&1 || return 1
  local c="${REPOS_PR_CACHE:-}"
  [ -n "$c" ] && [ -d "$c" ] || return 1
  if [ ! -f "$c/list" ]; then
    (cd "$1" && GH_PROMPT_DISABLED=1 perl -e 'alarm 30; exec @ARGV' gh pr list --state merged --limit 200 \
      --json headRefName,headRefOid -q '.[] | "\(.headRefName)\t\(.headRefOid)"' > "$c/list" 2>/dev/null) || : > "$c/list"
  fi
  grep -qxF "$2"$'\t'"$3" "$c/list"
}
repos_merged() {  # repos_merged <repo> <base ref> <branch> <commit>
  repos_in_base "$1" "$2" "$4" || repos_pr_merged "$1" "$3" "$4"
}

# A process (a shell, an editor, a session) has its working folder inside <dir>.
repos_in_use() {  # repos_in_use <dir>
  [ "${DEPLOYS_REPOS_NO_LSOF:-}" = 1 ] && return 1
  command -v lsof >/dev/null 2>&1 || return 1
  # The working folders of every process, read once per repo (REPOS_CWDS), not once per worktree.
  [ -n "${REPOS_CWDS:-}" ] || REPOS_CWDS="$(lsof -a -d cwd -Fn 2>/dev/null || true)"; REPOS_CWDS="${REPOS_CWDS:-none}"
  local c="$REPOS_CWDS"
  awk -v d="$1" '/^n/ { p = substr($0, 2); if (p == d || index(p, d "/") == 1) f = 1 } END { exit !f }' <<< "$c"
}
# Used within REPOS_IDLE_MIN minutes: its HEAD log or a top-level entry changed. Not the index: looking
# (git status, git diff) may rewrite it, so the check itself would count as use.
repos_recent() {  # repos_recent <work tree>
  local gd; gd="$(git -C "$1" rev-parse --absolute-git-dir 2>/dev/null)" || return 0
  [ -n "$(find "$gd/logs/HEAD" "$gd/HEAD" -mmin "-$REPOS_IDLE_MIN" -print -quit 2>/dev/null)" ] && return 0
  [ -n "$(find "$1" -mindepth 1 -maxdepth 1 -mmin "-$REPOS_IDLE_MIN" -not -name .git -not -name node_modules -not -name .next -print -quit 2>/dev/null)" ]
}

# An ignored file in the work tree that <target> tracks: a checkout would overwrite it without a word.
repos_clobbers() {  # repos_clobbers <repo> <target ref>
  local ign; ign="$(git -C "$1" ls-files -o -i --exclude-standard --directory 2>/dev/null || true)"
  [ -n "$ign" ] || return 1
  # --directory names an ignored folder once ("node_modules/"): a tracked path inside it counts too.
  local ch; ch="$(git -C "$1" diff --name-only --diff-filter=AMRC HEAD "$2" 2>/dev/null || true)"
  awk -v list="$ign" '
    BEGIN { n = split(list, l, "\n") }
    { for (i = 1; i <= n; i++) if ($0 == l[i] || (substr(l[i], length(l[i])) == "/" && index($0, l[i]) == 1)) { f = 1; exit } }
    END { exit !f }' <<< "$ch"
}
# The main checkout is in use: git holds its index lock, or it changed within the last hour.
repos_active() {  # repos_active <repo>
  local gd; gd="$(git -C "$1" rev-parse --absolute-git-dir 2>/dev/null)" || return 0
  [ -e "$gd/index.lock" ] && return 0
  REPOS_IDLE_MIN=60 repos_recent "$1"
}

# No --prune here: the remote-tracking ref of a branch deleted on origin is what shows that every commit of it
# was pushed. repos_one prunes after a sync has decided (and not while a switch is still waiting).
repos_fetch() {  # repos_fetch <repo>: git's message on stdout when it fails
  GIT_TERMINAL_PROMPT=0 GIT_SSH_COMMAND="${GIT_SSH_COMMAND:-ssh -o BatchMode=yes}" \
    perl -e 'alarm 60; exec @ARGV' git -C "$1" fetch -q origin </dev/null 2>&1 >/dev/null
}

repos_gone() {  # repos_gone <repo> <refs/heads/name>: origin answered and does not have it
  local ls; ls="$(GIT_TERMINAL_PROMPT=0 GIT_SSH_COMMAND="${GIT_SSH_COMMAND:-ssh -o BatchMode=yes}" \
    perl -e 'alarm 30; exec @ARGV' git -C "$1" ls-remote --heads origin "$2" </dev/null 2>/dev/null)" || return 1
  [ -z "$ls" ]
}

repos_default() {  # repos_default <repo>: main, master or what origin/HEAD names
  local h; h="$(git -C "$1" symbolic-ref -q --short refs/remotes/origin/HEAD 2>/dev/null)"
  if [ -n "$h" ] && git -C "$1" rev-parse -q --verify "$h" >/dev/null; then echo "${h#origin/}"; return; fi
  for h in main master; do git -C "$1" rev-parse -q --verify "origin/$h" >/dev/null && { echo "$h"; return; }; done
}

# Out: TSV, one row per repo: name path branch default state action behind ahead note worktrees
#   state  current | updated | switched | behind | merged | unmerged | diverged | detached | needs-hand | error | no-remote
repos_one() {  # repos_one <repo> <apply 0|1> <fetch 0|1>
  local repo="$1" apply="$2" fetch="$3" name br def base up="" upgone=0 st="" act="" note="" behind=0 ahead=0 wtn=0 head lr lb
  name="$(basename "$repo")"; REPOS_PR_CACHE="$(mktemp -d)"
  out() { rm -rf "$REPOS_PR_CACHE"; printf '%s\t%s\t%s\t%s\t%s\t%s\t%s\t%s\t%s\t%s\n' "$name" "$repo" "${br:-}" "${def:-}" "$st" "$act" "$behind" "$ahead" "$(printf '%s' "$note" | tr '\t\n' '  ')" "$wtn"; }
  git -C "$repo" remote get-url origin >/dev/null 2>&1 || { st=no-remote; note="no remote origin"; out; return; }
  br="$(git -C "$repo" symbolic-ref -q --short HEAD 2>/dev/null || true)"
  local fetched=1 ferr=""
  if [ "$fetch" = 1 ] && ! ferr="$(repos_fetch "$repo")" && ! { sleep 3; ferr="$(repos_fetch "$repo")"; }; then
    note="git fetch failed: $(printf '%s' "$ferr" | grep -v '^\s*$' | tail -n 1 | cut -c1-160); nothing done"; fetched=0
  fi
  def="$(repos_default "$repo" || true)"
  [ -n "$def" ] || { st=error; note="${note:+$note; }no origin/main or origin/master"; out; return; }
  base="origin/$def"
  # Gone on origin: the branch has an upstream, origin no longer has it (ls-remote answered), and its last known
  # remote-tracking ref is still here (fetch does not prune) to show what was pushed.
  local mref; mref="$( [ -z "$br" ] || git -C "$repo" config "branch.$br.merge" 2>/dev/null || true)"
  if [ -n "$br" ] && [ "$br" != "$def" ] && [ "$fetched" = 1 ] && [ -n "$mref" ]; then
    up="$(git -C "$repo" rev-parse -q --verify "refs/remotes/origin/${mref#refs/heads/}" 2>/dev/null || true)"
  fi
  lr="$(git -C "$repo" rev-list --left-right --count "$base...HEAD" 2>/dev/null || echo "0 0")"
  behind="$(printf '%s' "$lr" | awk '{print $1+0}')"; ahead="$(printf '%s' "$lr" | awk '{print $2+0}')"

  local hands_off=0
  if [ "$fetched" = 0 ]; then
    st=error; apply=0
  elif repos_busy "$repo"; then
    st=needs-hand; hands_off=1; note="${note:+$note; }a merge, rebase or cherry-pick is running"
  elif [ -n "$(git -C "$repo" diff --name-only --diff-filter=U 2>/dev/null | head -n 1)" ]; then
    st=needs-hand; hands_off=1; note="${note:+$note; }conflicts"
  elif repos_dirty "$repo"; then
    local pc nm nu; pc="$(git -C "$repo" status --porcelain 2>/dev/null || true)"
    nu="$(printf '%s\n' "$pc" | grep -c '^??' || true)"; nm="$(printf '%s\n' "$pc" | grep -v '^??' | grep -c . || true)"
    local ex; ex="$(printf '%s\n' "$pc" | sed -n 's/^?? //p' | head -n 3 | tr '\n' ' ' | sed 's/ $//')"
    st=needs-hand; note="${note:+$note; }uncommitted changes ($nm changed, $nu untracked$([ -z "$ex" ] || echo ": $ex"))"
  elif [ -z "$br" ]; then
    st=detached; note="${note:+$note; }detached HEAD"
  elif [ "$br" = "$def" ]; then
    if [ "$behind" = 0 ]; then st=current; [ "$ahead" = 0 ] || { st=diverged; note="${note:+$note; }$ahead commits not on origin"; }
    elif [ "$ahead" != 0 ]; then st=diverged; note="${note:+$note; }$ahead own commits, $behind behind: merge or rebase by hand"
    elif repos_clobbers "$repo" "$base"; then st=needs-hand; note="${note:+$note; }an ignored local file would be overwritten by $base"
    elif [ "$apply" = 1 ]; then
      if repos_git -C "$repo" merge -q --ff-only "$base" >/dev/null 2>&1; then st=updated; act="fast-forward $behind"; behind=0
      else st=error; note="${note:+$note; }fast-forward failed"; fi
    else st=behind; act="fast-forward $behind"; fi
  else
    head="$(git -C "$repo" rev-parse HEAD 2>/dev/null || true)"
    local keep=0 why=""
    if repos_merged "$repo" "$base" "$br" "$head"; then why="merged"
    elif [ -n "$up" ] && repos_gone "$repo" "$mref"; then upgone=1; fi
    if [ -n "$why" ]; then :
    elif [ "$upgone" = 1 ] && git -C "$repo" merge-base --is-ancestor "$head" "$up" 2>/dev/null; then why="gone"; keep=1
    fi
    # A local default branch with commits of its own is not switched to: that needs a person.
    lb="$(git -C "$repo" rev-parse -q --verify "refs/heads/$def" 2>/dev/null || true)"
    if [ -n "$why" ] && [ -n "$lb" ] && ! git -C "$repo" merge-base --is-ancestor "$lb" "$base" 2>/dev/null; then
      st=needs-hand; note="${note:+$note; }$br is done, but local $def has commits that are not on origin"
    elif [ -n "$why" ] && repos_clobbers "$repo" "$base"; then
      st=needs-hand; note="${note:+$note; }$br is done, but switching would overwrite an ignored local file"
    elif [ -n "$why" ] && [ "$apply" = 1 ] && repos_active "$repo"; then
      st=merged; act="switch to $def (waiting: used within the last hour)"
    elif [ -n "$why" ]; then
      if [ "$apply" = 1 ]; then
        if repos_git -C "$repo" switch -q "$def" >/dev/null 2>&1 && repos_git -C "$repo" merge -q --ff-only "$base" >/dev/null 2>&1; then
          st=switched; act="switch to $def"; behind=0; ahead=0
          if [ "$keep" = 0 ] && git -C "$repo" branch -D "$br" >/dev/null 2>&1; then
            act="$act, deleted $br"; note="${note:+$note; }$br was at ${head:0:12} (git branch $br $head brings it back)"
          else note="${note:+$note; }$br kept (gone on origin, every commit was pushed)"; fi
        else st=error; note="${note:+$note; }switching to $def failed (checked out in another worktree?)"; fi
      else
        st=merged
        if [ "$keep" = 0 ]; then act="switch to $def, delete $br"; note="${note:+$note; }$br is merged"
        else act="switch to $def"; note="${note:+$note; }$br is gone on origin, every commit was pushed (kept)"; fi
      fi
    else
      st=unmerged; note="${note:+$note; }$br: $ahead own commits, $behind behind $base"
    fi
  fi
  # A checkout in the middle of a merge or with conflicts is left completely alone, its worktrees too.
  [ "$hands_off" = 1 ] || wtn="$(repos_worktrees "$repo" "$base" "$apply")"
  # Stale remote-tracking refs go once a sync has decided; not while a switch waits (they show what was pushed).
  if [ "$apply" = 1 ] && [ "$hands_off" = 0 ] && [ "$st" != merged ]; then git -C "$repo" remote prune origin >/dev/null 2>&1 || true; fi
  out
}

# Linked worktrees that are done: no changes, idle, no process inside, merged. Prints how many went (or would go).
repos_worktrees() {  # repos_worktrees <repo> <base ref> <apply>
  local repo="$1" base="$2" apply="$3" n=0 wt b lk h
  local REPOS_CWDS=""
  [ "$apply" = 1 ] && git -C "$repo" worktree prune 2>/dev/null
  while IFS=$'\t' read -r wt b lk; do
    [ -d "$wt" ] && [ "$lk" = 0 ] || continue
    case "$wt" in */.claude/worktrees/*) continue ;; esac
    # Cheap checks first: git status in a big worktree takes a second, gh a round trip.
    repos_busy "$wt" && continue
    repos_recent "$wt" && continue
    h="$(git -C "$wt" rev-parse HEAD 2>/dev/null)" || continue
    if repos_in_base "$repo" "$base" "$h"; then repos_dirty "$wt" && continue
    else repos_dirty "$wt" && continue; repos_pr_merged "$repo" "$b" "$h" || continue; fi
    repos_in_use "$wt" && continue
    if [ "$apply" = 1 ]; then
      git -C "$repo" worktree remove "$wt" >/dev/null 2>&1 || continue
      if [ -n "$b" ] && git -C "$repo" branch -D "$b" >/dev/null 2>&1; then
        journal_add cli repos live "worktree $wt removed, branch $b was at $h" 2>/dev/null || true
      fi
    fi
    n=$((n+1))
  done < <(git -C "$repo" worktree list --porcelain 2>/dev/null | awk '
    /^worktree /{p=substr($0,10); b=""; l=0} /^branch /{b=substr($0,19)} /^locked/{l=1}
    /^$/{ if (n++) print p "\t" b "\t" l; p="" } END{ if (p!="" && n++) print p "\t" b "\t" l }')
  echo "$n"
}

repos_main() {
  local cmd="${1:-status}" apply=0 fetch=1 yes=0
  [ $# -eq 0 ] || shift
  case "$cmd" in
    schedule) repos_schedule "$@"; return ;;
    stranded|rescue) declare -F stranded_main >/dev/null || die "deploys repos $cmd needs lib/stranded.sh"
      if [ "$cmd" = stranded ]; then stranded_main "$@"; return; fi
      case "${1:-} $* " in "schedule "*) shift; stranded_schedule "$@" ;; *" --auto "*) stranded_auto "$@" ;; *) stranded_rescue "$@" ;; esac; return ;;
    status|sync) ;;
    last)
      [ -f "$CONFIG_DIR/repos-last.json" ] || { [ "${json:-0}" = 1 ] && echo '{"ranAt":null,"repos":[]}' || echo "No run yet: deploys repos status"; return 0; }
      cat "$CONFIG_DIR/repos-last.json"; return 0 ;;
    *) die "Usage: deploys repos status [--no-fetch] [--json] | repos sync [--yes] [--json] | repos last | repos schedule on|off|status | repos stranded [--json] | repos rescue <folder> [--yes] | repos rescue --auto [--yes] | repos rescue schedule on|off|status" ;;
  esac
  while [ $# -gt 0 ]; do
    case "$1" in
      --yes) yes=1 ;; --no-fetch) fetch=0 ;; --json) json=1 ;;
      *) die "Unknown option $1 for deploys repos $cmd" ;;
    esac; shift
  done
  [ "$cmd" = sync ] && [ "$yes" = 1 ] && apply=1
  mkdir -p "$CONFIG_DIR/locks"
  local lock="$CONFIG_DIR/locks/repos.lock"
  lock_clear_stale "$lock" 1800
  if ! mkdir "$lock" 2>/dev/null; then
    echo "Another repos run is going on; try again in a minute." >&2
    # For the app and scripts: the last result, marked busy, rather than nothing on stdout.
    if [ "${json:-0}" = 1 ]; then
      if [ -f "$CONFIG_DIR/repos-last.json" ]; then jq -c '. + {busy:true}' "$CONFIG_DIR/repos-last.json"
      else echo '{"ranAt":null,"busy":true,"repos":[]}'; fi
    fi
    return 0
  fi
  trap_add "rmdir '$lock' 2>/dev/null || true"
  local GIT_OPTIONAL_LOCKS=0; export GIT_OPTIONAL_LOCKS
  # A few repos at a time (each its own row file, joined in order): fetches wait on the network, not the Mac.
  local rows r i=0 par="${DEPLOYS_REPOS_PARALLEL:-6}" parts; rows="$(mktemp)"; parts="$(mktemp -d)"
  while IFS= read -r r; do
    i=$((i+1)); printf '%s' "$r" > "$parts/$(printf '%05d' "$i").path"
    ( repos_one "$r" "$apply" "$fetch" > "$parts/$(printf '%05d' "$i")" ) &
    [ $((i % par)) -ne 0 ] || wait
  done < <(repos_list)
  wait
  local f p
  for f in "$parts"/*.path; do
    [ -e "$f" ] || continue; p="$(cat "$f")"
    # A repo whose look failed half-way still gets its row instead of quietly dropping out of the report.
    if [ -s "${f%.path}" ]; then cat "${f%.path}"
    else printf '%s\t%s\t\t\terror\t\t0\t0\tcould not be read (git failed)\t0\n' "$(basename "$p")" "$p"; fi
  done > "$rows"
  rm -rf "$parts"
  local res
  res="$(jq -Rn --argjson applied "$apply" --arg at "$(date -u +%Y-%m-%dT%H:%M:%SZ)" '
    [inputs | split("\t") | {name:.[0], path:.[1], branch:.[2], default:.[3], state:.[4], action:.[5],
      behind:(.[6]|tonumber), ahead:(.[7]|tonumber), note:.[8], worktrees:(.[9]|tonumber),
      needsHand:(.[4] as $s | ["needs-hand","diverged","error"] | index($s) != null)}] as $r |
    {ranAt:$at, applied:($applied==1), repos:$r,
     summary:{repos:($r|length), updated:([$r[]|select(.state=="updated" or .state=="switched")]|length),
       needsHand:([$r[]|select(.needsHand)]|length), unmerged:([$r[]|select(.state=="unmerged")]|length),
       worktrees:([$r[].worktrees]|add // 0)}}' < "$rows")"
  rm -f "$rows"; rmdir "$lock" 2>/dev/null || true; trap_pop
  printf '%s\n' "$res" > "$CONFIG_DIR/repos-last.json.tmp" && mv -f "$CONFIG_DIR/repos-last.json.tmp" "$CONFIG_DIR/repos-last.json"
  if [ "$apply" = 1 ]; then
    local s; s="$(printf '%s' "$res" | jq -r '.summary | "\(.updated) updated, \(.worktrees) worktrees removed, \(.needsHand) need you"')"
    printf '%s' "$res" | jq -r '.repos[] | select(.state=="switched" or .state=="updated") | "\(.name): \(.action)"' | while IFS= read -r r; do
      journal_add cli repos live "$r" 2>/dev/null || true
    done
    journal_add cli repos live "Repo upkeep: $s" 2>/dev/null || true
  fi
  if [ "${json:-0}" = 1 ]; then printf '%s\n' "$res"; return 0; fi
  printf '%s' "$res" | jq -r '
    def icon: {current:"ok ", updated:"up ", switched:"up ", behind:"-> ", merged:"-> ", unmerged:".. ",
      detached:".. ", "no-remote":".. ", diverged:"!! ", "needs-hand":"!! ", error:"!! "}[.] // "   ";
    .repos[] | "\(.state|icon) \(.name)  [\(.branch // "-")]  \(.state)\(if .action != "" then "  " + .action else "" end)\(if .worktrees > 0 then "  worktrees: \(.worktrees)" else "" end)\(if .note != "" then "  (" + .note + ")" else "" end)"'
  printf '%s' "$res" | jq -r 'if .applied then .summary | "\(.repos) repos: \(.updated) updated, \(.worktrees) worktrees removed, \(.needsHand) need you."
    else .summary | "\(.repos) repos, \(.needsHand) need you. Nothing was changed. To do it: deploys repos sync --yes" end'
}

repos_schedule() {
  case "${1:-status}" in
    on)
      JOB_RUN_AT_LOAD=1 job_on "$REPOS_LABEL" 1800 deploys-repos repos sync --yes
      echo "Repo upkeep runs every 30 minutes and at login, at low priority. Log: ~/Library/Logs/deploys-repos.log" ;;
    off) job_off "$REPOS_LABEL"; echo "Repo upkeep schedule is off." ;;
    status)
      if [ -f "$(job_plist "$REPOS_LABEL")" ]; then echo "on (every 30 minutes and at login)"; else echo "off"; fi
      [ ! -f "$CONFIG_DIR/repos-last.json" ] || jq -r '"last run \(.ranAt): \(.summary.repos) repos, \(.summary.needsHand) need you"' "$CONFIG_DIR/repos-last.json" 2>/dev/null || true ;;
    *) die "Usage: deploys repos schedule on|off|status" ;;
  esac
}
