#!/bin/bash
# Tests for `deploys repos` (lib/repos.sh): made-up repos and one bare origin in a temp folder, gh faked. No network.
# Run: tests/repos-tests.sh
set -uo pipefail
cd "$(dirname "$0")/.." || exit 1
exec </dev/null
fails=0
ok()   { echo "ok   $1"; }
fail() { echo "FAIL $1: $2"; fails=$((fails+1)); }
expect() { [ "$2" = "$3" ] && ok "$1" || fail "$1" "expected [$3], got [$2]"; }

tmp="$(mktemp -d)"; trap 'rm -rf "$tmp"' EXIT
export DEPLOYS_CONFIG="$tmp/config" HOME="$tmp/home" NO_COLOR=1 DEPLOYS_TESTING=1 DEPLOYS_REPOS_NO_LSOF=1
export GIT_AUTHOR_NAME=t GIT_AUTHOR_EMAIL=t@example.com GIT_COMMITTER_NAME=t GIT_COMMITTER_EMAIL=t@example.com
export GIT_CONFIG_GLOBAL="$tmp/gitconfig"; printf '[init]\n\tdefaultBranch = main\n' > "$GIT_CONFIG_GLOBAL"
mkdir -p "$HOME" "$DEPLOYS_CONFIG" "$tmp/root" "$tmp/bin"
printf '{"enabled":[]}' > "$DEPLOYS_CONFIG/providers.json"
printf '{"roots":["%s"]}' "$tmp/root" > "$DEPLOYS_CONFIG/repos.json"
# gh: one merged pull request, for branch "pr-done", whose head is the commit in $tmp/pr-head.
cat > "$tmp/bin/gh" <<EOF
#!/bin/bash
[ -f "$tmp/pr-head" ] && printf 'pr-done\t%s\n' "\$(cat "$tmp/pr-head")"
exit 0
EOF
chmod +x "$tmp/bin/gh"; export PATH="$tmp/bin:$PATH"
cli() { env DEPLOYS_JOURNAL="$tmp/journal.jsonl" bash ./deploys "$@"; }
old() { find "$1" "$(git -C "$1" rev-parse --absolute-git-dir)" -maxdepth 3 -exec touch -t 202001010000 {} + 2>/dev/null; }
g() { git -C "$@"; }

# origin with main, a seed clone that pushes
git init -q --bare -b main "$tmp/origin.git"
git clone -q "$tmp/origin.git" "$tmp/seed" 2>/dev/null
printf '.env\nnode_modules/\n' > "$tmp/seed/.gitignore"; echo a > "$tmp/seed/a.txt"
g "$tmp/seed" add -A; g "$tmp/seed" commit -qm init; g "$tmp/seed" push -q origin main 2>/dev/null
push() { echo "$1" > "$tmp/seed/$1"; g "$tmp/seed" add -A; g "$tmp/seed" commit -qm "$1"; g "$tmp/seed" push -q origin main 2>/dev/null; }
clone() { git clone -q "$tmp/origin.git" "$tmp/root/$1" 2>/dev/null; }

clone behind                                          # clean main, behind: fast-forward
clone squash; g "$tmp/root/squash" switch -qc feat    # a branch whose change went in as a squash
echo s > "$tmp/root/squash/s.txt"; g "$tmp/root/squash" add -A; g "$tmp/root/squash" commit -qm s
cp "$tmp/root/squash/s.txt" "$tmp/seed/s.txt"; g "$tmp/seed" add -A; g "$tmp/seed" commit -qm "squash s"; g "$tmp/seed" push -q origin main 2>/dev/null
clone open; g "$tmp/root/open" switch -qc wip         # a branch with work of its own
echo w > "$tmp/root/open/w.txt"; g "$tmp/root/open" add -A; g "$tmp/root/open" commit -qm w
clone dirty; g "$tmp/root/dirty" switch -qc d         # uncommitted change
echo x >> "$tmp/root/dirty/a.txt"
clone untracked; echo u > "$tmp/root/untracked/new.txt"
clone conflict; g "$tmp/root/conflict" switch -qc c   # a merge stopped on a conflict
echo c1 > "$tmp/root/conflict/a.txt"; g "$tmp/root/conflict" commit -qam c1
g "$tmp/root/conflict" switch -q main; echo c2 > "$tmp/root/conflict/a.txt"; g "$tmp/root/conflict" commit -qam c2
g "$tmp/root/conflict" switch -q c; g "$tmp/root/conflict" merge -q main >/dev/null 2>&1
clone ahead; echo m > "$tmp/root/ahead/m.txt"; g "$tmp/root/ahead" add -A; g "$tmp/root/ahead" commit -qm m   # local main ahead
clone prdone; g "$tmp/root/prdone" switch -qc pr-done # gh says merged, head matches
echo p > "$tmp/root/prdone/p.txt"; g "$tmp/root/prdone" add -A; g "$tmp/root/prdone" commit -qm p
g "$tmp/root/prdone" rev-parse HEAD > "$tmp/pr-head"
clone prmoved; g "$tmp/root/prmoved" switch -qc pr-done   # gh's head is another commit: stays
echo q > "$tmp/root/prmoved/q.txt"; g "$tmp/root/prmoved" add -A; g "$tmp/root/prmoved" commit -qm q
clone mainahead; g "$tmp/root/mainahead" switch -qc feat2       # branch merged, but local main has own commits
echo o > "$tmp/root/mainahead/o.txt"; g "$tmp/root/mainahead" switch -q main; g "$tmp/root/mainahead" add -A; g "$tmp/root/mainahead" commit -qm own
g "$tmp/root/mainahead" switch -q feat2
clone envfile; echo secret > "$tmp/root/envfile/.env"           # an ignored .env that the new main tracks
clone hooked; mkdir -p "$tmp/root/hooked/.git/hooks"; printf '#!/bin/sh\ntouch "%s"\n' "$tmp/hook-ran" > "$tmp/root/hooked/.git/hooks/post-merge"; chmod +x "$tmp/root/hooked/.git/hooks/post-merge"
clone offline
# worktrees of "behind": one merged and clean (goes), one with a change (stays), one fresh (stays)
g "$tmp/root/behind" worktree add -q -b wt-done "$tmp/wt-done" origin/main 2>/dev/null
g "$tmp/root/behind" worktree add -q -b wt-dirty "$tmp/wt-dirty" origin/main 2>/dev/null; echo y >> "$tmp/wt-dirty/a.txt"
g "$tmp/root/behind" worktree add -q -b wt-fresh "$tmp/wt-fresh" origin/main 2>/dev/null
old "$tmp/wt-done"; old "$tmp/wt-dirty"
for r in "$tmp"/root/*; do old "$r"; done

# origin moves on; the .env becomes tracked upstream (git add -f)
push later1; push later2
echo committed > "$tmp/seed/.env"; g "$tmp/seed" add -f .env; g "$tmp/seed" commit -qm env; g "$tmp/seed" push -q origin main 2>/dev/null
g "$tmp/root/envfile" fetch -q; old "$tmp/root/envfile"
g "$tmp/root/offline" remote set-url origin "$tmp/nowhere.git"

st() { jq -r --arg n "$1" '.repos[] | select(.name==$n) | .state' "$tmp/out.json"; }

# status: a report only
cli repos status --json > "$tmp/out.json" 2>"$tmp/err" || fail "status runs" "$(cat "$tmp/err")"
expect "status: behind main would fast-forward" "$(st behind)" "behind"
expect "status: squash-merged branch would switch" "$(st squash)" "merged"
expect "status: nothing changed" "$(g "$tmp/root/squash" branch --show-current):$(g "$tmp/root/behind" rev-list --count HEAD..origin/main)" "feat:4"
expect "status: worktree not removed" "$([ -d "$tmp/wt-done" ] && echo there)" "there"
cli repos sync --json > "$tmp/out.json" 2>/dev/null
expect "sync without --yes changes nothing" "$(jq -r .applied "$tmp/out.json"):$(g "$tmp/root/squash" branch --show-current)" "false:feat"

# sync --yes
cli repos sync --yes --json > "$tmp/out.json" 2>"$tmp/err" || fail "sync runs" "$(cat "$tmp/err")"
expect "behind: fast-forwarded" "$(st behind):$(g "$tmp/root/behind" rev-list --count HEAD..origin/main)" "updated:0"
expect "squash: on main, branch deleted" "$(st squash):$(g "$tmp/root/squash" branch --show-current):$(g "$tmp/root/squash" branch --list feat | wc -l | tr -d ' ')" "switched:main:0"
expect "squash: the old commit is in the note" "$(jq -r '.repos[]|select(.name=="squash")|.note' "$tmp/out.json" | grep -c 'git branch feat')" "1"
expect "open branch: untouched" "$(st open):$(g "$tmp/root/open" branch --show-current)" "unmerged:wip"
expect "dirty: untouched" "$(st dirty):$(g "$tmp/root/dirty" branch --show-current):$(g "$tmp/root/dirty" status --porcelain | wc -l | tr -d ' ')" "needs-hand:d:1"
expect "untracked file: untouched" "$(st untracked):$(g "$tmp/root/untracked" rev-list --count HEAD..origin/main)" "needs-hand:3"
expect "merge conflict: untouched" "$(st conflict):$([ -f "$tmp/root/conflict/.git/MERGE_HEAD" ] && echo merging)" "needs-hand:merging"
expect "local main ahead: diverged, untouched" "$(st ahead):$(g "$tmp/root/ahead" rev-list --count origin/main..HEAD)" "diverged:1"
expect "gh merged, same head: switched" "$(st prdone):$(g "$tmp/root/prdone" branch --show-current)" "switched:main"
expect "gh merged, other head: stays" "$(st prmoved):$(g "$tmp/root/prmoved" branch --show-current)" "unmerged:pr-done"
expect "local main with own commits: not switched" "$(st mainahead):$(g "$tmp/root/mainahead" branch --show-current)" "needs-hand:feat2"
expect "ignored .env tracked upstream: not overwritten" "$(st envfile):$(cat "$tmp/root/envfile/.env")" "needs-hand:secret"
expect "hooks do not run" "$(st hooked):$([ -e "$tmp/hook-ran" ] && echo ran || echo no)" "updated:no"
expect "failed fetch: nothing done" "$(st offline):$(g "$tmp/root/offline" rev-list --count HEAD..origin/main)" "error:0"
expect "worktrees: merged clean one removed, dirty and fresh kept" "$([ -d "$tmp/wt-done" ] && echo y || echo n)$([ -d "$tmp/wt-dirty" ] && echo y)$([ -d "$tmp/wt-fresh" ] && echo y)" "nyy"
expect "worktree branch deleted" "$(g "$tmp/root/behind" branch --list wt-done | wc -l | tr -d ' ')" "0"
expect "summary counts" "$(jq -r '.summary | "\(.updated)/\(.worktrees)"' "$tmp/out.json")" "4/1"
expect "last: the same result, no git" "$(cli repos last --json | jq -r .ranAt)" "$(jq -r .ranAt "$tmp/out.json")"
expect "journal has the upkeep line" "$(grep -c 'Repo upkeep' "$tmp/journal.jsonl")" "1"
expect "text output" "$(cli repos status --no-fetch | tail -n 1 | grep -c 'need you')" "1"

# a second run changes nothing more
cli repos sync --yes --json > "$tmp/out.json" 2>/dev/null
expect "second run: up to date" "$(st behind):$(st squash)" "current:current"

# schedule writes a background job that also runs at login (no real launchd: a test folder)
plist="$tmp/la/com.deploycenter.repos.plist"
if command -v launchctl >/dev/null 2>&1 && command -v plutil >/dev/null 2>&1; then
  ( export DEPLOYS_LAUNCH_DIR="$tmp/la"; launchctl() { [ "$1" != print ]; }; export -f launchctl; cli repos schedule on >/dev/null 2>&1 || true )
  if [ -f "$plist" ]; then
    expect "schedule: RunAtLoad, 30 minutes, sync --yes" "$(grep -c RunAtLoad "$plist"):$(grep -c '<integer>1800</integer>' "$plist"):$(grep -c '<string>--yes</string>' "$plist")" "1:1:1"
  else ok "schedule: skipped (no job file written here)"; fi
fi

[ -n "${KEEP:-}" ] && { cp -R "$tmp" "$KEEP"; }
echo; [ "$fails" = 0 ] && echo "repos: all passed" || echo "repos: $fails failed"
exit "$fails"
