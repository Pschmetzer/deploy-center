#!/bin/bash
# Tests for the weekly cleanup `deploys repos clean` (lib/repos.sh): one made-up repo with a local bare origin and
# worktrees in every state, stub gh and claude on PATH, made-up session files. Nothing leaves the temporary folder.
# Run: bash tests/repos-cleanup-tests.sh
set -uo pipefail
cd "$(dirname "$0")/.." || exit 1
exec </dev/null
fails=0
ok()   { echo "ok   $1"; }
fail() { echo "FAIL $1: $2"; fails=$((fails+1)); }
expect() { if [ "$2" = "$3" ]; then ok "$1"; else fail "$1" "expected [$3], got [$2]"; fi; }

tmp="$(cd "$(mktemp -d)" && pwd -P)"; trap 'rm -rf "$tmp"' EXIT
root="$tmp/code"; desk="$tmp/desk/aaaaaaaa-0000-4000-8000-000000000001/bbbbbbbb-0000-4000-8000-000000000002"
mkdir -p "$root" "$tmp/bin" "$tmp/config" "$tmp/home" "$tmp/live" "$desk"
export HOME="$tmp/home" DEPLOYS_CONFIG="$tmp/config" DEPLOYS_JOURNAL="$tmp/journal.jsonl" NO_COLOR=1 DEPLOYS_TESTING=1
export DEPLOYS_STRANDED_NO_PERF=1 DEPLOYS_REPOS_NO_GH=1 DEPLOYS_REPOS_NO_LSOF=1
export DEPLOYS_LOCAL_SESSIONS_DIR="$tmp/live" DEPLOYS_DESKTOP_SESSIONS_BASE="$tmp/desk"
export GIT_AUTHOR_NAME=Test GIT_AUTHOR_EMAIL=test@example.invalid GIT_COMMITTER_NAME=Test GIT_COMMITTER_EMAIL=test@example.invalid
echo "{\"roots\":[\"$root\"]}" > "$tmp/config/repos.json"
cat > "$tmp/bin/gh" <<'GH'
#!/bin/bash
case "$1 $2" in "repo view") echo PRIVATE ;; "pr create") echo "https://example.invalid/pull/9" ;; esac
GH
cat > "$tmp/bin/claude" <<'CL'
#!/bin/bash
[ "$1 $2" = "agents --json" ] && { cat "$AGENTS_JSON" 2>/dev/null || echo '[]'; }
CL
chmod +x "$tmp/bin/gh" "$tmp/bin/claude"; export PATH="$tmp/bin:$PATH" AGENTS_JSON="$tmp/agents.json"
D() { ./deploys "$@"; }
g() { git -C "$@"; }

r="$root/app"
git init -q --bare -b main "$tmp/origin.git"
git init -q -b main "$r"; echo one > "$r/a.txt"; g "$r" add a.txt; g "$r" commit -qm one
g "$r" remote add origin "$tmp/origin.git"; g "$r" push -q -u origin main 2>/dev/null; g "$r" remote set-head origin main >/dev/null 2>&1
printf '.claude/\nnode_modules/\n' > "$r/.git/info/exclude"
W="$r/.claude/worktrees"
wt() { g "$r" worktree add -q -b "$1" "$W/$1" origin/main 2>/dev/null; }
# old <worktree>: everything in it and its git folder two years old
old() { local gd; gd="$(g "$1" rev-parse --absolute-git-dir)"; find "$1" "$gd" -exec touch -t 202001010000 {} + 2>/dev/null; }
session() { jq -n --arg c "$1" --argjson a "$2" '{cwd: $c, isArchived: $a, title: "t", lastActivityAt: 1}' > "$desk/local_cccccccc-0000-4000-8000-00000000000$3.json"; }

wt merged;    mkdir -p "$W/merged/node_modules/x"; echo big > "$W/merged/node_modules/x/i.js"
wt gone;      echo g > "$W/gone/g.txt"; g "$W/gone" add g.txt; g "$W/gone" commit -qm g; g "$W/gone" push -q -u origin gone 2>/dev/null
              git --git-dir="$tmp/origin.git" branch -D gone >/dev/null
wt dirty;     echo change >> "$W/dirty/a.txt"
wt unpushed;  echo u > "$W/unpushed/u.txt"; g "$W/unpushed" add u.txt; g "$W/unpushed" commit -qm u
wt live
wt open;      session "$W/open" false 1
wt archrec;   session "$W/archrec" true 2
wt recent
wt unmerged;  echo m > "$W/unmerged/m.txt"; g "$W/unmerged" add m.txt; g "$W/unmerged" commit -qm m; g "$W/unmerged" push -q -u origin unmerged 2>/dev/null
wt locked;    g "$r" worktree lock "$W/locked"
g "$r" worktree add -q --detach "$W/detached" origin/main 2>/dev/null   # no branch: merged by its commit
g "$r" worktree add -q --detach "$W/detlock" origin/main 2>/dev/null; g "$r" worktree lock "$W/detlock"
for n in merged gone dirty unpushed live open unmerged locked detached detlock; do old "$W/$n"; done
g "$r" branch -q --no-track b-merged origin/main; g "$r" branch -q --no-track b-own origin/main
g "$r" checkout -q b-own; echo own > "$r/own.txt"; g "$r" add own.txt; g "$r" commit -qm own; g "$r" checkout -q main
jq -n --arg c "$W/live" '[{pid: 1, cwd: $c, kind: "background", status: "busy"}]' > "$tmp/agents.json"
sleep 1 & wait

list() { g "$r" worktree list --porcelain | sed -n 's#^worktree .*/##p' | sort | tr '\n' ' ' | sed 's/ $//'; }
before="$(list)"
j="$(D repos clean --json)" || fail "dry run runs" "exit $?"
expect "dry run: worktrees" "$(jq -r '[.worktrees[] | .path | split("/") | last] | sort | join(" ")' <<<"$j")" "archrec detached gone merged"
expect "dry run: branches" "$(jq -r '[.branches[].branch] | sort | join(" ")' <<<"$j")" "archrec b-merged merged"
expect "dry run changes nothing" "$(list)" "$before"
kept() { jq -r --arg n "$1" '.kept[] | select(.path | endswith("/" + $n)) | .reason' <<<"$j"; }
expect "kept: dirty" "$(kept dirty)" "uncommitted changes"
expect "kept: unpushed" "$(kept unpushed)" "1 commits on no remote"
expect "kept: running agent" "$(kept live)" "a running session works in it"
expect "kept: open desktop session" "$(kept open)" "its desktop session is open (not archived)"
expect "kept: recent, no session" "$(kept recent)" "used within the last day"
expect "kept: unmerged on origin" "$(kept unmerged)" "branch not merged: unmerged"
expect "kept: locked" "$(kept locked)" "locked"
expect "kept: locked, detached" "$(kept detlock)" "locked"
expect "gone: reason" "$(jq -r '.worktrees[] | select(.branch == "gone") | .reason' <<<"$j")" "gone on origin, every commit pushed"
expect "size counted" "$(jq -r '.summary.kb > 0' <<<"$j")" true
case "$(D repos clean)" in *"Would remove: 4 worktrees and 3 merged branches"*"deploys repos clean --yes"*) ok "dry run text" ;; *) fail "dry run text" "$(D repos clean)" ;; esac

j="$(D repos clean --yes --json)"
expect "removed" "$(list)" "$(printf '%s\n' "$before" | tr ' ' '\n' | grep -vxE 'archrec|detached|gone|merged' | tr '\n' ' ' | sed 's/ $//')"
expect "folders gone" "$([ -e "$W/merged" ] || [ -e "$W/gone" ] || [ -e "$W/archrec" ] || [ -e "$W/detached" ] && echo there || echo gone)" gone
expect "merged branches deleted, gone and own kept" "$(g "$r" for-each-ref --format='%(refname:short)' refs/heads/ | sort | tr '\n' ' ')" "b-own dirty gone live locked main open recent unmerged unpushed "
expect "dirty work untouched" "$(g "$W/dirty" status --porcelain)" " M a.txt"
expect "journal: worktree" "$(grep -c 'worktree .*merged removed (merged)' "$tmp/journal.jsonl")" 1
expect "journal: branches, one line" "$(grep -c '3 merged branches of app deleted' "$tmp/journal.jsonl")" 1
expect "branch log: name and commit" "$(awk -F'\t' '$3 == "b-merged" {print $4}' "$tmp/config/repos-clean-branches.log")" "$(git --git-dir="$tmp/origin.git" rev-parse main)"
expect "journal: summary" "$(grep -c 'Weekly cleanup: removed 4 worktrees and 3 merged branches' "$tmp/journal.jsonl")" 1
expect "last result" "$(jq -r '.applied' "$tmp/config/repos-clean-last.json")" true
expect "second run: nothing" "$(D repos clean --yes --json | jq -r '.summary | "\(.worktrees) \(.branches)"')" "0 0"

# rescue first: an archived session's worktree with changes goes to a draft pull request and stays
wt leftover; echo work > "$W/leftover/w.txt"; old "$W/leftover"; session "$W/leftover" true 3
echo '{"auto":true}' > "$tmp/config/rescue.json"
j="$(D repos clean --yes --json)"
# dirty and unpushed (idle for years, no session) go too: everything left over gets its draft pull request
expect "rescued first" "$(jq -r .rescued <<<"$j"):$(git --git-dir="$tmp/origin.git" branch --list 'rescue/leftover-*' | wc -l | tr -d ' ')" "3:1"
expect "rescued folder kept" "$(kept leftover):$([ -f "$W/leftover/w.txt" ] && echo here)" "uncommitted changes:here"

# --scheduled: only on Sundays or a week after the last one
if [ "$(date +%u)" != 7 ]; then
  case "$(D repos clean --yes --scheduled)" in "Not today"*) ok "scheduled: waits for Sunday" ;; *) fail "scheduled: waits for Sunday" "ran" ;; esac
  echo 1 > "$tmp/config/repos-clean.stamp"
  case "$(D repos clean --yes --scheduled)" in *"Removed:"*) ok "scheduled: catches up after a week" ;; *) fail "scheduled: catches up" "$(D repos clean --yes --scheduled)" ;; esac
else ok "scheduled: skipped on a Sunday"; fi
expect "usage" "$(D repos clean --bogus 2>&1 >/dev/null | grep -c Usage)" 1

if command -v launchctl >/dev/null 2>&1 && command -v plutil >/dev/null 2>&1; then
  ( export DEPLOYS_LAUNCH_DIR="$tmp/la"; launchctl() { [ "$1" != print ]; }; export -f launchctl; D repos clean schedule on >/dev/null 2>&1 || true )
  plist="$tmp/la/com.deploycenter.repos-clean.plist"
  expect "schedule: 04:00, --yes --scheduled" "$(grep -c '<key>Hour</key><integer>4</integer>' "$plist"):$(grep -c '<string>--scheduled</string>' "$plist")" "1:1"
else ok "schedule: skipped (no launchd here)"; fi

echo
if [ "$fails" = 0 ]; then echo "all repos clean tests passed"; else echo "$fails failed"; exit 1; fi
