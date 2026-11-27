# shellcheck shell=bash
# lib/stranded.sh — work left behind in local checkouts, and a rescue to a draft pull request.
#
#   deploys repos stranded [--json] [--cached]      checkouts and worktrees with uncommitted changes or commits that
#                                                   are on no remote; read-only. --cached: the last result, no git.
#   deploys repos rescue <folder> [--yes] [--json]  without --yes what it would do; with --yes the changes go to a new
#                                                   branch rescue/<folder>-<time> on origin and a draft pull request.
#
# Why: a session archived by mistake (or one that stopped) leaves its worktree with work nobody pushed.
# Which folders: every work tree (`git worktree list`, including .claude/worktrees) of the repos `deploys repos` looks
# at (repos.json, clean.json, else ~/Documents/Claude). Left out: a folder a live Claude Code process works in, and one
# changed within the last hour. The rest is sorted: its desktop session archived, no session known, idle the longest.
#
# The rescue never touches the folder: no checkout, no commit on its branch, not even its index. The commit is built
# in a temporary index (read-tree HEAD, add -A, write-tree, commit-tree) and pushed as a new branch, never forced.
# It refuses when the changes hold a secret-like file name (.env, *.pem, *.key, id_rsa, credentials ...) or a token
# (ghp_, github_pat_, sk-, AKIA, xox?-, a private key), a file over 5 MB, more than 300 files, or a nested repo. It says when
# the repo is public: pushing there publishes the work. One rescue per state: the same changes twice are skipped.
#
#   deploys repos rescue --auto [--yes] [--json]    the unattended mode: rescues, without asking, the folders left over from
#                                                   an archived Claude session or idle for 24 h (rescue.json "idleHours").
#   deploys repos rescue schedule on|off|status     a LaunchAgent: `rescue --auto --yes` every hour; `on` is the opt-in.
# The automatic mode keeps every refusal above and adds its own: never a folder a running session works in (also
# `claude agents --json`), never a public repo or one whose visibility gh cannot tell (pushing publishes; "public": true
# in rescue.json allows it), at most "perRun" (3) rescues per run and "perDay" (10) per day. Without --yes it only shows.
# rescue.json in the config folder: {"auto":true,"perRun":3,"perDay":10,"idleHours":24,"public":false}.
# Bash 3.2. Sourced by deploys; uses CONFIG_DIR, journal_add, repos_list and repos_git from lib/repos.sh.
#
# Tests: DEPLOYS_DESKTOP_SESSIONS_BASE and DEPLOYS_LOCAL_SESSIONS_DIR point at made-up session files,
# DEPLOYS_STRANDED_NOW fixes the clock, DEPLOYS_STRANDED_NO_PERF=1 skips the load check, gh and claude are stubs on PATH
# (DEPLOYS_STRANDED_NO_AGENTS=1 skips `claude agents`).

STRANDED_MAX_FILES="${DEPLOYS_STRANDED_MAX_FILES:-300}"
STRANDED_MAX_KB="${DEPLOYS_STRANDED_MAX_KB:-5120}"
STRANDED_RECENT_MIN="${DEPLOYS_STRANDED_RECENT_MIN:-60}"

stranded_now() { if [ -n "${DEPLOYS_STRANDED_NOW:-}" ]; then echo "$DEPLOYS_STRANDED_NOW"; else date +%s; fi; }
stranded_mtime() { stat -c %Y "$1" 2>/dev/null || stat -f %m "$1" 2>/dev/null || true; }
stranded_git() { git -c core.hooksPath=/dev/null --no-optional-locks "$@"; }

# Every work tree of the repos, one path per line.
stranded_trees() {
  local r
  repos_list | while IFS= read -r r; do
    git -C "$r" worktree list --porcelain 2>/dev/null | sed -n 's/^worktree //p'
  done | awk '!seen[$0]++'
}

# Folders with a live Claude Code process: the cwd of ~/.claude/sessions/*.json whose pid is alive.
stranded_live_cwds() {
  local d f p c; d="${DEPLOYS_LOCAL_SESSIONS_DIR:-$HOME/.claude/sessions}"
  for f in "$d"/*.json; do
    [ -f "$f" ] || continue
    p="$(jq -r '.pid // empty' "$f" 2>/dev/null)"; c="$(jq -r '.cwd // empty' "$f" 2>/dev/null)"
    case "$p" in ""|*[!0-9]*) continue ;; esac
    if [ -n "$c" ] && kill -0 "$p" 2>/dev/null; then echo "$c"; fi
  done
  # Plus the sessions `claude agents --json` knows (background ones too). Read once per run: STRANDED_AGENTS.
  [ -n "${STRANDED_AGENTS+x}" ] || STRANDED_AGENTS="$(stranded_agent_cwds)"
  [ -z "$STRANDED_AGENTS" ] || printf '%s\n' "$STRANDED_AGENTS"
}
stranded_agent_cwds() {
  [ "${DEPLOYS_STRANDED_NO_AGENTS:-}" != 1 ] && command -v claude >/dev/null 2>&1 || return 0
  perl -e 'alarm 20; exec @ARGV' claude agents --json </dev/null 2>/dev/null | jq -r '.[]? | .cwd // empty' 2>/dev/null || true
}

STRANDED_PICK='select(type == "object" and (.cwd | type) == "string")
  | {cwd, archived: (.isArchived == true), title: (.title // "" | tostring), at: (.lastActivityAt // 0)}'
STRANDED_READ="$(cat <<'SH'
[ $# -gt 0 ] || exit 0
jq -c "$F" "$@" 2>/dev/null || for f in "$@"; do jq -c "$F" "$f" 2>/dev/null; done
SH
)"
# The desktop sessions by folder, archived ones too: JSON {cwd: {archived, title}} (the newest per folder wins).
stranded_sessions() {
  local base="${DEPLOYS_DESKTOP_SESSIONS_BASE:-$HOME/Library/Application Support/Claude/claude-code-sessions}"
  [ -d "$base" ] || { echo '{}'; return 0; }
  find "$base" -mindepth 3 -maxdepth 3 -type f -name 'local_*.json' -print0 2>/dev/null \
    | F="$STRANDED_PICK" xargs -0 sh -c "$STRANDED_READ" _ \
    | jq -sc 'sort_by(.at) | map({key: .cwd, value: {archived, title}}) | from_entries'
}

# One row (JSON) per work tree with something left, or nothing.
stranded_one() {  # stranded_one <tree> <now> <live cwds, newline separated> <sessions JSON>
  local t="$1" now="$2" st n up last m f i=0 repo br remotes
  [ -d "$t" ] || return 0
  st="$(stranded_git -C "$t" status --porcelain 2>/dev/null)" || return 0
  n=0; [ -z "$st" ] || n="$(printf '%s\n' "$st" | wc -l | tr -d ' ')"
  remotes="$(git -C "$t" remote 2>/dev/null)"
  up=0
  if git -C "$t" rev-parse -q --verify HEAD >/dev/null 2>&1; then
    if [ -n "$remotes" ]; then up="$(git -C "$t" rev-list --count HEAD --not --remotes 2>/dev/null || echo 0)"; fi
  fi
  [ "$n" -gt 0 ] || [ "$up" -gt 0 ] || return 0
  # The newest change: the changed files (at most 200 looked at), else the last commit.
  last=0
  while IFS= read -r f; do
    i=$((i+1)); [ "$i" -le 200 ] || break
    m="$(stranded_mtime "$t/$f" || true)"; [ -n "$m" ] && [ "$m" -gt "$last" ] && last="$m"
  done <<<"$(stranded_paths "$t")"
  [ "$last" -gt 0 ] || last="$(git -C "$t" log -1 --format=%ct 2>/dev/null || echo 0)"
  [ $(( (now - last) / 60 )) -ge "$STRANDED_RECENT_MIN" ] || return 0
  printf '%s\n' "$3" | grep -qxF "$t" && return 0
  printf '%s\n' "$3" | awk -v t="$t/" 'index($0 "/", t) == 1 { f = 1 } END { exit !f }' && return 0
  repo="$(git -C "$t" rev-parse --path-format=absolute --git-common-dir 2>/dev/null | sed 's#/\.git$##' || true)"
  br="$(git -C "$t" symbolic-ref -q --short HEAD 2>/dev/null || echo "")"
  jq -nc --arg path "$t" --arg repo "$repo" --arg branch "$br" --argjson changed "$n" --argjson unpushed "$up" \
    --argjson last "$last" --argjson now "$now" --argjson s "$4" --arg remote "$([ -n "$remotes" ] && echo yes)" '
    ($s[$path] // null) as $x
    | {path: $path, name: ($path | split("/") | last), repo: $repo, repoName: ($repo | split("/") | last),
       branch: $branch, changed: $changed, unpushed: $unpushed, hasRemote: ($remote == "yes"),
       lastChange: $last, idleHours: ((($now - $last) / 3600) | floor),
       session: (if $x == null then "none" elif $x.archived then "archived" else "open" end),
       title: ($x.title // "")}
    | . + {class: (if .session == "archived" then "archived" elif .session == "none" then "no-session" else "idle" end)}'
}

stranded_scan() {
  local now live sess t
  now="$(stranded_now)"
  if [ "${DEPLOYS_STRANDED_NO_PERF:-}" != 1 ] && declare -F perf_snapshot >/dev/null; then
    if [ "$(perf_snapshot 2>/dev/null | jq -r '.level // "green"' 2>/dev/null)" = red ]; then
      [ -f "$CONFIG_DIR/stranded-last.json" ] && { jq -c '. + {skipped: "the Mac is overloaded; last result shown"}' "$CONFIG_DIR/stranded-last.json"; return 0; }
      echo '{"ranAt":null,"skipped":"the Mac is overloaded","items":[],"summary":{"folders":0,"archived":0,"noSession":0,"files":0,"unpushed":0}}'; return 0
    fi
  fi
  live="$(stranded_live_cwds)"; sess="$(stranded_sessions)"; [ -n "$sess" ] || sess='{}'
  stranded_trees | while IFS= read -r t; do stranded_one "$t" "$now" "$live" "$sess"; done \
    | jq -sc --arg at "$(date -u +%Y-%m-%dT%H:%M:%SZ)" '
      sort_by((if .class == "archived" then 0 elif .class == "no-session" then 1 else 2 end), -.idleHours) as $i
      | {ranAt: $at, items: $i,
         summary: {folders: ($i | length), archived: ([$i[] | select(.class == "archived")] | length),
                   noSession: ([$i[] | select(.class == "no-session")] | length),
                   files: ([$i[].changed] | add // 0), unpushed: ([$i[].unpushed] | add // 0)}}'
}

stranded_print() {
  jq -r '
    (if .skipped then "Note: \(.skipped)." else empty end),
    "Work left behind: \(.summary.folders) folders, \(.summary.files) changed files, \(.summary.unpushed) commits on no remote",
    (.items[] | "  \(.class | if . == "archived" then "archived  " elif . == "no-session" then "no session" else "idle      " end)  \(.name) [\(.branch // "-")]  \(.changed) files, \(.unpushed) unpushed, idle \(.idleHours) h  \(.path)"),
    (if .summary.folders > 0 then "Rescue one to a draft pull request: deploys repos rescue <folder> (shows first; --yes does it)" else empty end)'
}

stranded_main() {
  local cached=0 a
  for a in "$@"; do case "$a" in --json) json=1 ;; --cached) cached=1 ;; *) die "Usage: deploys repos stranded [--json] [--cached]" ;; esac; done
  local res
  if [ "$cached" = 1 ]; then
    if [ -f "$CONFIG_DIR/stranded-last.json" ]; then res="$(cat "$CONFIG_DIR/stranded-last.json")"
    else res='{"ranAt":null,"items":[],"summary":{"folders":0,"archived":0,"noSession":0,"files":0,"unpushed":0}}'; fi
  else
    res="$(stranded_scan)" || return 1
    if [ -z "$(jq -r '.skipped // empty' <<<"$res")" ]; then
      mkdir -p "$CONFIG_DIR"
      printf '%s\n' "$res" > "$CONFIG_DIR/stranded-last.json.tmp" && mv -f "$CONFIG_DIR/stranded-last.json.tmp" "$CONFIG_DIR/stranded-last.json"
    fi
  fi
  if [ "${json:-0}" = 1 ]; then printf '%s\n' "$res"; else stranded_print <<<"$res"; fi
}

# The files of the rescue that must not go out, one reason per line: "secret: .env", "big: x.zip (9 MB)" ...
stranded_check() {  # stranded_check <tree> <changed paths, one per line>
  local t="$1" f k n=0
  while IFS= read -r f; do
    [ -n "$f" ] || continue
    n=$((n+1))
    if [ "$f" = "(a file name with a line break)" ]; then echo "file name with a line break: cannot be checked"; continue; fi
    case "$(basename "$f")" in
      .env|.env.*|*.pem|*.key|*.p12|*.pfx|id_rsa|id_rsa*|id_ed25519*|id_ecdsa*|credentials|credentials.*|.npmrc|.pypirc|.netrc|*.keychain*)
        echo "secret-like file: $f" ;;
    esac
    if [ -d "$t/$f" ] && [ -e "$t/$f/.git" ]; then echo "nested repository: $f"; continue; fi
    [ -f "$t/$f" ] || continue
    k="$(du -k "$t/$f" 2>/dev/null | cut -f1)"
    [ -z "$k" ] || [ "$k" -le "$STRANDED_MAX_KB" ] || echo "file over $((STRANDED_MAX_KB / 1024)) MB: $f"
    if grep -Iq -E 'ghp_[A-Za-z0-9]{20,}|github_pat_[A-Za-z0-9_]{20,}|sk-[A-Za-z0-9_-]{20,}|AKIA[0-9A-Z]{16}|xox[abprs]-[A-Za-z0-9-]{10,}|-----BEGIN [A-Z ]*PRIVATE KEY' "$t/$f" 2>/dev/null; then
      echo "looks like a key or token inside: $f"
    fi
  done <<<"$2"
  [ "$n" -le "$STRANDED_MAX_FILES" ] || echo "too many files: $n (at most $STRANDED_MAX_FILES; build output or node_modules not ignored?)"
}

# The changed paths of a work tree, one per line, unquoted: read NUL-separated (-z), so a name with a quote, a
# backslash, a tab or a non-ASCII byte is the real name and its size and token checks run. For a rename the record
# after it (the old name) is skipped. A name with a newline in it is refused by stranded_check (it cannot be listed).
stranded_paths() {  # stranded_paths <tree>
  local rec skip=0
  stranded_git -C "$1" status --porcelain -z -uall 2>/dev/null | while IFS= read -r -d '' rec; do
    if [ "$skip" = 1 ]; then skip=0; continue; fi
    case "${rec:0:2}" in R?|?R|C?|?C) skip=1 ;; esac   # a rename or copy, staged or not: its old name follows
    rec="${rec:3}"
    case "$rec" in *$'\n'*) echo "(a file name with a line break)"; continue ;; esac
    printf '%s\n' "$rec"
  done
}

stranded_rescue() {
  local yes=0 t="" a
  for a in "$@"; do case "$a" in --yes) yes=1 ;; --json) json=1 ;; -*) die "Unknown option $a" ;; *) t="$a" ;; esac; done
  [ -n "$t" ] || die "Usage: deploys repos rescue <folder> [--yes] [--json]"
  t="${t%/}"; [ -d "$t" ] || die "No folder $t"
  t="$(cd "$t" && pwd -P)"
  local top; top="$(git -C "$t" rev-parse --show-toplevel 2>/dev/null)" || die "$t is not a git work tree"
  [ "$(cd "$top" && pwd -P)" = "$t" ] || die "$t is not the top of its work tree ($top)"
  git -C "$t" remote get-url origin >/dev/null 2>&1 || die "$t has no remote named origin"
  if stranded_live_cwds | awk -v t="$t" '$0 == t || index($0 "/", t "/") == 1 { f = 1 } END { exit !f }'; then
    die "A Claude Code session is working in $t; rescue it after that session ends."
  fi
  local files head base tree commit name branch vis problems now
  now="$(stranded_now)"
  files="$(stranded_paths "$t")"
  head="$(git -C "$t" rev-parse -q --verify HEAD 2>/dev/null || echo "")"
  problems="$(stranded_check "$t" "$files")"
  base="$(git -C "$t" symbolic-ref -q --short refs/remotes/origin/HEAD 2>/dev/null | sed 's#^origin/##' || true)"; [ -n "$base" ] || base=main
  name="$(basename "$t" | tr -c 'A-Za-z0-9._-' '-' | sed 's/-*$//' | cut -c1-40)"
  branch="rescue/$name-$(date -u -r "$now" +%Y%m%d-%H%M 2>/dev/null || date -u -d "@$now" +%Y%m%d-%H%M)"
  vis="$(cd "$t" && gh repo view --json visibility -q .visibility 2>/dev/null || echo UNKNOWN)"
  local nfiles=0; [ -z "$files" ] || nfiles="$(printf '%s\n' "$files" | wc -l | tr -d ' ')"
  local up=0; [ -z "$head" ] || up="$(git -C "$t" rev-list --count HEAD --not --remotes 2>/dev/null || echo 0)"
  summary() {  # summary <state> <note>
    jq -nc --arg path "$t" --arg branch "$branch" --arg base "$base" --arg vis "$vis" --argjson files "$nfiles" --argjson unpushed "$up" \
      --arg problems "$problems" --arg state "$1" --arg note "$2" --arg pr "${3:-}" \
      '{path: $path, branch: $branch, base: $base, visibility: $vis, files: $files, unpushed: $unpushed,
        problems: ($problems | split("\n") | map(select(. != ""))), state: $state, note: $note, pr: (if $pr == "" then null else $pr end)}'
  }
  say() { if [ "${json:-0}" = 1 ]; then summary "$@"; else printf '%s\n' "$2"; [ -z "$problems" ] || printf '  %s\n' "$problems"; fi; }
  if [ "$nfiles" = 0 ] && [ "$up" = 0 ]; then say nothing "Nothing to rescue in $t."; return 0; fi
  # With --json the refusal is an answer (exit 0, state "refused", the problems listed) so the app can show the files.
  if [ -n "$problems" ]; then
    say refused "Not rescued: the changes in $t hold something that must not be pushed. Fix or ignore these first:"
    [ "${json:-0}" = 1 ] && return 0; return 1
  fi
  # The commit, built beside the folder's own index.
  local idx; idx="$(mktemp "${TMPDIR:-/tmp}/stranded-idx.XXXXXX")"
  if [ -n "$head" ]; then GIT_INDEX_FILE="$idx" git -C "$t" read-tree HEAD; else rm -f "$idx"; fi
  GIT_INDEX_FILE="$idx" git -C "$t" add -A . 2>/dev/null || { rm -f "$idx"; say error "Could not stage the changes in $t."; return 1; }
  tree="$(GIT_INDEX_FILE="$idx" git -C "$t" write-tree)"; rm -f "$idx"
  local rec="$CONFIG_DIR/stranded-rescued.json" prev
  prev="$( [ -f "$rec" ] && jq -r --arg p "$t" --arg k "$tree:$head" '.[$p] | select(.key == $k) | .branch' "$rec" 2>/dev/null || true)"
  if [ -n "$prev" ]; then say done-before "Already rescued as $prev; nothing new since."; return 0; fi
  local what="$nfiles changed files"; [ "$up" = 0 ] || what="$what and $up commits on no remote"
  local warn=""; [ "$vis" != PUBLIC ] || warn=" The repo is PUBLIC: pushing publishes this work."
  if [ "$yes" != 1 ]; then
    say plan "Would push $what from $t to a new branch $branch on origin and open a draft pull request into $base. The folder itself is not changed.$warn Add --yes."
    return 0
  fi
  if [ -n "$head" ] && [ "$tree" = "$(git -C "$t" rev-parse "HEAD^{tree}")" ]; then commit="$head"
  else
    local msg; msg="Rescue: uncommitted changes from $(basename "$t")"
    if [ -n "$head" ]; then commit="$(git -C "$t" commit-tree "$tree" -p "$head" -m "$msg")"
    else commit="$(git -C "$t" commit-tree "$tree" -m "$msg")"; fi
  fi
  [ -n "$commit" ] || { say error "Could not build the rescue commit."; return 1; }
  if [ -n "$(git -C "$t" ls-remote --heads origin "$branch" 2>/dev/null)" ]; then say error "Branch $branch already exists on origin; try again in a minute."; return 1; fi
  if ! stranded_git -C "$t" push -q origin "$commit:refs/heads/$branch" 2>/dev/null; then say error "The push of $branch failed."; return 1; fi
  local pr
  pr="$(cd "$t" && gh pr create --draft --head "$branch" --base "$base" --title "Rescue: $(basename "$t")" \
        --body "Changes left in a local folder ($(basename "$t"), branch $(git -C "$t" symbolic-ref -q --short HEAD 2>/dev/null || echo detached)), pushed by \`deploys repos rescue\`. The folder was not changed. Check before merging." 2>/dev/null | tail -n 1 || true)"
  mkdir -p "$CONFIG_DIR"
  jq -n --argjson cur "$( [ -f "$rec" ] && cat "$rec" || echo '{}')" --arg p "$t" --arg k "$tree:$head" --arg b "$branch" --arg pr "$pr" \
    '$cur + {($p): {key: $k, branch: $b, pr: $pr}}' > "$rec.tmp" 2>/dev/null && mv -f "$rec.tmp" "$rec"
  journal_add cli repos live "rescued $(basename "$t") to $branch${pr:+ ($pr)}" 2>/dev/null || true
  local tail="; draft pull request: $pr"; [ -n "$pr" ] || tail=" (no pull request: gh failed; open one for $branch by hand)"
  say rescued "Pushed $what to $branch$tail" "$pr"
}

# ---- The automatic rescue ----------------------------------------------------------------------------------------
RESCUE_LABEL="com.deploycenter.rescue"
stranded_cfg() {  # stranded_cfg <jq path>: a value of rescue.json, empty without one
  [ -f "$CONFIG_DIR/rescue.json" ] || return 0
  jq -r "$1 // empty" "$CONFIG_DIR/rescue.json" 2>/dev/null || true
}
stranded_num() { case "$1" in ''|*[!0-9]*) echo "$2" ;; *) echo "$1" ;; esac; }

# One rescue, its JSON on stdout. In a subshell: stranded_rescue ends with die on a folder that went away or a
# session that started in the meantime, and that must cost this folder only, not the run.
stranded_try() {  # stranded_try <folder> [--yes]
  local e out; e="$(mktemp)"
  out="$( ( stranded_rescue "$@" --json ) 2>"$e" | tail -n 1)"
  if ! jq -e 'type == "object"' >/dev/null 2>&1 <<<"$out"; then
    out="$(jq -nc --arg n "$(grep -v '^\s*$' "$e" | tail -n 1 | sed 's/^[^ ]*Error:[^ ]* //' | cut -c1-200)" '{state: "error", note: $n}')"
  fi
  rm -f "$e"; printf '%s\n' "$out"
}

stranded_auto() {
  local yes=0 a
  for a in "$@"; do case "$a" in --auto) ;; --yes) yes=1 ;; --json) json=1 ;; *) die "Usage: deploys repos rescue --auto [--yes] [--json]" ;; esac; done
  if [ "$yes" = 1 ] && [ "$(stranded_cfg .auto)" != true ]; then
    if [ "${json:-0}" = 1 ]; then echo '{"ranAt":null,"off":true,"items":[]}'
    else echo "The automatic rescue is off. Turn it on: deploys repos rescue schedule on (deploys repos rescue --auto shows what it would do)."; fi
    return 0
  fi
  local per_run per_day idle pub
  per_run="$(stranded_num "$(stranded_cfg .perRun)" 3)"; per_day="$(stranded_num "$(stranded_cfg .perDay)" 10)"
  idle="$(stranded_num "$(stranded_cfg .idleHours)" 24)"; pub="$(stranded_cfg .public)"
  mkdir -p "$CONFIG_DIR/locks"
  local lock="$CONFIG_DIR/locks/rescue.lock"
  lock_clear_stale "$lock" 3600
  if ! mkdir "$lock" 2>/dev/null; then echo "Another rescue run is going on." >&2; [ "${json:-0}" != 1 ] || echo '{"ranAt":null,"busy":true,"items":[]}'; return 0; fi
  trap_add "rmdir '$lock' 2>/dev/null || true"
  # The day's count: rescue-state.json {"day":"YYYY-MM-DD","count":n,"refused":{"<folder>":"<problems>"}}.
  local st="$CONFIG_DIR/rescue-state.json" day count refused
  day="$(date -u -r "$(stranded_now)" +%Y-%m-%d 2>/dev/null || date -u +%Y-%m-%d)"
  count="$( [ -f "$st" ] && jq -r --arg d "$day" 'if .day == $d then .count // 0 else 0 end' "$st" 2>/dev/null || echo 0)"
  refused="$( [ -f "$st" ] && jq -c '.refused // {}' "$st" 2>/dev/null || echo '{}')"; [ -n "$refused" ] || refused='{}'
  STRANDED_AGENTS="$(stranded_agent_cwds)"; export STRANDED_AGENTS
  local scan; scan="$(stranded_scan)"
  if [ -n "$(jq -r '.skipped // empty' <<<"$scan")" ]; then
    rmdir "$lock" 2>/dev/null || true; trap_pop
    if [ "${json:-0}" = 1 ]; then jq -c '{ranAt: null, skipped, items: []}' <<<"$scan"; else echo "Not now: $(jq -r .skipped <<<"$scan")."; fi
    return 0
  fi
  local rows; rows="$(mktemp)"
  local item p plan state vis r done_now=0 note
  while IFS= read -r item; do
    [ -n "$item" ] || continue
    p="$(jq -r .path <<<"$item")"; note=""
    if [ "$done_now" -ge "$per_run" ] || [ "$count" -ge "$per_day" ]; then state=capped; note="the limit of this run or day is reached; next run"
    else
      plan="$(stranded_try "$p")"; state="$(jq -r '.state // "error"' <<<"$plan")"; vis="$(jq -r '.visibility // "UNKNOWN"' <<<"$plan")"
      note="$(jq -r '.note // ""' <<<"$plan")"; r="$plan"
      if [ "$state" = plan ] && [ "$vis" != PRIVATE ] && [ "$vis" != INTERNAL ] && [ "$pub" != true ]; then
        state=public; note="the repo is $(printf '%s' "$vis" | tr '[:upper:]' '[:lower:]'): not pushed without asking. Rescue it by hand: deploys repos rescue $p --yes"
      elif [ "$state" = plan ] && [ "$yes" = 1 ]; then
        r="$(stranded_try "$p" --yes)"; state="$(jq -r '.state // "error"' <<<"$r")"; note="$(jq -r '.note // ""' <<<"$r")"
        [ "$state" != rescued ] || { done_now=$((done_now+1)); count=$((count+1)); }
      elif [ "$state" = plan ]; then state=would-rescue
      fi
      if [ "$state" = refused ] && [ "$yes" = 1 ]; then
        local pr_s; pr_s="$(jq -r '.problems | join("; ")' <<<"$r")"
        if [ "$(jq -r --arg p "$p" '.[$p] // ""' <<<"$refused")" != "$pr_s" ]; then
          journal_add cli repos live "rescue of $(basename "$p") refused: $pr_s" 2>/dev/null || true
          refused="$(jq -c --arg p "$p" --arg v "$pr_s" '. + {($p): $v}' <<<"$refused")"
        fi
      fi
    fi
    [ -n "${r:-}" ] || r='{}'
    jq -c --arg state "$state" --arg note "$note" --argjson r "$r" \
      '{path, name, repoName, branch, class, session, idleHours, changed, unpushed, state: $state, note: $note,
        problems: ($r.problems // []), pr: ($r.pr // null), rescueBranch: ($r.branch // null), visibility: ($r.visibility // null)}' <<<"$item" >> "$rows"
    r=""
  done < <(jq -c --argjson h "$idle" '.items[] | select(.hasRemote) | select(.class == "archived" or .idleHours >= $h)' <<<"$scan")
  local res
  res="$(jq -sc --argjson applied "$yes" --arg at "$(date -u +%Y-%m-%dT%H:%M:%SZ)" --argjson perRun "$per_run" --argjson perDay "$per_day" --argjson today "$count" '
    def n($s): [.[] | select(.state == $s)] | length;
    {ranAt: $at, applied: ($applied == 1), items: .,
     summary: {candidates: length, rescued: n("rescued"), wouldRescue: n("would-rescue"), public: n("public"),
               refused: n("refused"), capped: n("capped"), errors: n("error"), today: $today, perRun: $perRun, perDay: $perDay}}' < "$rows")"
  rm -f "$rows"
  if [ "$yes" = 1 ]; then
    jq -n --arg d "$day" --argjson c "$count" --argjson r "$refused" '{day: $d, count: $c, refused: $r}' > "$st.tmp" 2>/dev/null && mv -f "$st.tmp" "$st"
    journal_add cli repos live "Automatic rescue: $(jq -r '.summary | "\(.rescued) rescued, \(.refused) refused, \(.public) public (left), \(.capped) for later"' <<<"$res")" 2>/dev/null || true
  fi
  printf '%s\n' "$res" > "$CONFIG_DIR/rescue-last.json.tmp" && mv -f "$CONFIG_DIR/rescue-last.json.tmp" "$CONFIG_DIR/rescue-last.json"
  rmdir "$lock" 2>/dev/null || true; trap_pop
  if [ "${json:-0}" = 1 ]; then printf '%s\n' "$res"; return 0; fi
  jq -r '
    (.items[] | "  \(.state | . + (" " * ([12 - length, 0] | max)))  \(.name) [\(.branch // "-")]  \(.changed) files, \(.unpushed) unpushed, \(.class), idle \(.idleHours) h\(if .pr then "  " + .pr elif .note != "" then "  (" + .note + ")" else "" end)"),
    (.summary | "Automatic rescue: \(.candidates) folders left over, \(.rescued) rescued, \(.wouldRescue) would be, \(.public) in public repos (left), \(.refused) refused, \(.capped) for a later run."),
    (if .applied then empty else "Nothing was pushed. To do it: deploys repos rescue --auto --yes" end)' <<<"$res"
}

stranded_schedule() {
  case "${1:-status}" in
    on)
      mkdir -p "$CONFIG_DIR"
      jq -n --argjson cur "$( [ -f "$CONFIG_DIR/rescue.json" ] && cat "$CONFIG_DIR/rescue.json" || echo '{}')" '$cur + {auto: true}' \
        > "$CONFIG_DIR/rescue.json.tmp" && mv -f "$CONFIG_DIR/rescue.json.tmp" "$CONFIG_DIR/rescue.json"
      job_on "$RESCUE_LABEL" 3600 deploys-rescue repos rescue --auto --yes
      echo "Left-behind work is rescued to draft pull requests every hour (archived sessions, or idle for a day; public repos only by hand). Log: ~/Library/Logs/deploys-rescue.log" ;;
    off)
      job_off "$RESCUE_LABEL"
      if [ -f "$CONFIG_DIR/rescue.json" ]; then jq '. + {auto: false}' "$CONFIG_DIR/rescue.json" > "$CONFIG_DIR/rescue.json.tmp" && mv -f "$CONFIG_DIR/rescue.json.tmp" "$CONFIG_DIR/rescue.json"; fi
      echo "The automatic rescue is off." ;;
    status)
      if [ -f "$(job_plist "$RESCUE_LABEL")" ] && [ "$(stranded_cfg .auto)" = true ]; then echo "on (every hour)"; else echo "off"; fi
      [ ! -f "$CONFIG_DIR/rescue-last.json" ] || jq -r '"last run \(.ranAt): \(.summary.rescued) rescued, \(.summary.public) public, \(.summary.refused) refused"' "$CONFIG_DIR/rescue-last.json" 2>/dev/null || true ;;
    *) die "Usage: deploys repos rescue schedule on|off|status" ;;
  esac
}
