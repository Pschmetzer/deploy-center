#!/bin/bash
# Tests for `deploys clean` (lib/clean.sh). No network: a made-up repo with worktrees in a temp folder.
# Run: tests/clean-tests.sh
set -uo pipefail
cd "$(dirname "$0")/.." || exit 1
exec </dev/null
fails=0
ok()   { echo "ok   $1"; }
fail() { echo "FAIL $1: $2"; fails=$((fails+1)); }
expect() { [ "$2" = "$3" ] && ok "$1" || fail "$1" "expected [$3], got [$2]"; }

tmp="$(mktemp -d)"; trap 'rm -rf "$tmp"' EXIT
export DEPLOYS_CONFIG="$tmp/config" HOME="$tmp/home" NO_COLOR=1 DEPLOYS_TESTING=1
export GIT_AUTHOR_NAME=t GIT_AUTHOR_EMAIL=t@example.com GIT_COMMITTER_NAME=t GIT_COMMITTER_EMAIL=t@example.com
mkdir -p "$HOME" "$DEPLOYS_CONFIG" "$tmp/root"
printf '{"enabled":[]}' > "$DEPLOYS_CONFIG/providers.json"
cli() { env DEPLOYS_JOURNAL="$tmp/journal.jsonl" bash ./deploys "$@"; }
old() { find "$1" "$(git -C "$1" rev-parse --absolute-git-dir)" -maxdepth 3 -exec touch -t 202001010000 {} + 2>/dev/null; }

# origin (bare) and a clone "shop" with main
git init -q --bare -b main "$tmp/origin.git"
git clone -q "$tmp/origin.git" "$tmp/root/shop" 2>/dev/null
r="$tmp/root/shop"
printf 'node_modules/\n.next/\n' > "$r/.gitignore"; echo a > "$r/a.txt"; mkdir -p "$r/build"; echo kept > "$r/build/tracked.txt"
git -C "$r" add -A && git -C "$r" commit -qm init && git -C "$r" push -q origin main 2>/dev/null

# merged: a branch whose change is in main (squash style: same content, other commit)
git -C "$r" worktree add -q -b merged "$tmp/root/shop-merged" main
echo b > "$tmp/root/shop-merged/b.txt"; git -C "$tmp/root/shop-merged" add -A; git -C "$tmp/root/shop-merged" commit -qm b
echo b > "$r/b.txt"; git -C "$r" add -A; git -C "$r" commit -qm "squash b"; git -C "$r" push -q origin main 2>/dev/null
mkdir -p "$tmp/root/shop-merged/node_modules/x"; echo 1 > "$tmp/root/shop-merged/node_modules/x/i.js"
# open: not merged, with node_modules and a tracked build/ folder
git -C "$r" worktree add -q -b open "$tmp/root/shop-open" main
echo c > "$tmp/root/shop-open/c.txt"; git -C "$tmp/root/shop-open" add -A; git -C "$tmp/root/shop-open" commit -qm c
mkdir -p "$tmp/root/shop-open/node_modules/y" "$tmp/root/shop-open/.next"; echo 1 > "$tmp/root/shop-open/node_modules/y/i.js"
# dirty: merged but with an uncommitted change
git -C "$r" worktree add -q -b dirty "$tmp/root/shop-dirty" main
echo z >> "$tmp/root/shop-dirty/a.txt"; mkdir -p "$tmp/root/shop-dirty/node_modules"
# fresh: changed just now, with node_modules
git -C "$r" worktree add -q -b fresh "$tmp/root/shop-fresh" main
mkdir -p "$tmp/root/shop-fresh/node_modules"
# busy: old on the outside, but a file deep inside was saved just now (a session at work)
git -C "$r" worktree add -q -b busy "$tmp/root/shop-busy" main
mkdir -p "$tmp/root/shop-busy/src/deep" "$tmp/root/shop-busy/node_modules"
for w in merged open dirty busy; do old "$tmp/root/shop-$w"; done
echo now > "$tmp/root/shop-busy/src/deep/file.ts"; touch -t 202001010000 "$tmp/root/shop-busy/src"
git -C "$tmp/root/shop-dirty" status >/dev/null   # looking must not make a worktree "recent"

out="$(cli clean 2>&1)"; expect "no root: a hint" "$(echo "$out" | grep -c 'deploys clean --root')" 1

out="$(cli clean --root "$tmp/root" --json)"
expect "dry run deletes nothing" "$(echo "$out" | jq .deleted)" false
expect "dry run: node_modules still there" "$([ -d "$tmp/root/shop-open/node_modules" ] && echo yes)" yes
expect "build items: open node_modules, .next, merged node_modules, dirty node_modules" \
  "$(echo "$out" | jq -r '[.items[]|select(.kind=="build")|(.path|split("/")|last)+":"+.what]|sort|join(" ")')" \
  "shop-dirty:node_modules shop-merged:node_modules shop-open:.next shop-open:node_modules"
expect "tracked build/ is not listed" "$(echo "$out" | jq '[.items[]|select(.what=="build")]|length')" 0
expect "fresh worktree left alone" "$(echo "$out" | jq '[.items[]|select(.path|test("fresh"))]|length')" 0
expect "main checkout left alone" "$(echo "$out" | jq --arg r "$r" '[.items[]|select(.path==$r)]|length')" 0
expect "kept recent counted (fresh, busy)" "$(echo "$out" | jq .keptRecent)" 2
expect "busy worktree left alone" "$(echo "$out" | jq '[.items[]|select(.path|test("busy"))]|length')" 0

out="$(cli clean --root "$tmp/root" --worktrees --json)"
expect "--worktrees: merged worktree is a candidate" "$(echo "$out" | jq -r '[.items[]|select(.kind=="worktree")|.what]|join(" ")')" merged

cli clean --root "$tmp/root" --worktrees --yes >/dev/null 2>&1
expect "merged worktree removed" "$([ -d "$tmp/root/shop-merged" ] && echo there || echo gone)" gone
expect "its branch stays" "$(git -C "$r" rev-parse -q --verify refs/heads/merged >/dev/null && echo yes)" yes
expect "open: node_modules gone" "$([ -d "$tmp/root/shop-open/node_modules" ] && echo there || echo gone)" gone
expect "open: commits and files stay" "$(cat "$tmp/root/shop-open/c.txt")" c
expect "dirty: change kept" "$(git -C "$tmp/root/shop-dirty" status --porcelain | wc -l | tr -d ' ')" 1
expect "dirty worktree kept" "$([ -d "$tmp/root/shop-dirty" ] && echo there)" there
expect "fresh: node_modules kept" "$([ -d "$tmp/root/shop-fresh/node_modules" ] && echo there)" there
expect "tracked build/ kept" "$(cat "$r/build/tracked.txt")" kept
expect "journal line" "$(grep -c '"clean"' "$tmp/journal.jsonl" 2>/dev/null)" 1

out="$(cli clean --root "$tmp/root" --min-free 1 --json)"
expect "enough free space: skipped" "$(echo "$out" | jq .skipped)" true

# --docker: build cache and dangling images through a fake docker, never volumes or containers.
mkdir -p "$tmp/dbin"; cat > "$tmp/dbin/docker" <<'D'
#!/bin/bash
echo "$*" >> "$DOCKER_CALLS"
case "$1" in info) exit 0 ;; builder) echo "Total reclaimed space: 1.5GB" ;; image) echo "Total reclaimed space: 0B" ;; esac
D
chmod +x "$tmp/dbin/docker"; export DOCKER_CALLS="$tmp/docker.calls"; : > "$DOCKER_CALLS"
out="$(DEPLOYS_DOCKER_BIN="$tmp/dbin/docker" cli clean --root "$tmp/root" --docker --yes 2>&1)"
expect "docker: build cache pruned" "$(grep -c 'builder prune -f --filter until=72h' "$DOCKER_CALLS")" 1
expect "docker: dangling images pruned" "$(grep -c '^image prune -f$' "$DOCKER_CALLS")" 1
expect "docker: never volumes or system prune" "$(grep -cE 'volume|system' "$DOCKER_CALLS")" 0
expect "docker: reported" "$(echo "$out" | grep -c 'Docker build cache: Total reclaimed space: 1.5GB')" 1
: > "$DOCKER_CALLS"; DEPLOYS_DOCKER_BIN="$tmp/dbin/docker" cli clean --root "$tmp/root" --docker >/dev/null 2>&1
expect "docker: nothing without --yes" "$(wc -l < "$DOCKER_CALLS" | tr -d ' ')" 0
out="$(DEPLOYS_DOCKER_BIN="$tmp/nope" cli clean --root "$tmp/root" --docker --yes 2>&1)"
expect "docker missing: left alone" "$(echo "$out" | grep -c 'Docker does not run')" 1

echo; [ "$fails" = 0 ] && echo "All clean tests passed." || { echo "$fails failed."; exit 1; }
