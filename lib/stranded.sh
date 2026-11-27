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
# Bash 3.2. Sourced by deploys; uses CONFIG_DIR, journal_add, repos_list and repos_git from lib/repos.sh.
#
# Tests: DEPLOYS_DESKTOP_SESSIONS_BASE and DEPLOYS_LOCAL_SESSIONS_DIR point at made-up session files,
# DEPLOYS_STRANDED_NOW fixes the clock, DEPLOYS_STRANDED_NO_PERF=1 skips the load check, gh is a stub on PATH.

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
    f="${f:3}"; f="${f#\"}"; f="${f%\"}"; case "$f" in *" -> "*) f="${f##* -> }" ;; esac
    m="$(stranded_mtime "$t/$f" || true)"; [ -n "$m" ] && [ "$m" -gt "$last" ] && last="$m"
  done <<<"$st"
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
  files="$(stranded_git -C "$t" status --porcelain -uall 2>/dev/null | cut -c4- | sed 's/^"//; s/"$//; s/.* -> //' || true)"
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
  if [ -n "$problems" ]; then say refused "Not rescued: the changes in $t hold something that must not be pushed. Fix or ignore these first:"; return 1; fi
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
  say rescued "Pushed $what to $branch${pr:+; draft pull request: $pr}${pr:- (no pull request: gh failed; open one for $branch by hand)}" "$pr"
}
