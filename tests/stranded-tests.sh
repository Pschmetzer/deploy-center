#!/bin/bash
# Tests for left-behind work and its rescue (lib/stranded.sh): made-up repos with a local bare origin, a stub gh on
# PATH, made-up session files, a fixed clock. Nothing leaves the temporary folder.
# Run: bash tests/stranded-tests.sh
set -uo pipefail
cd "$(dirname "$0")/.." || exit 1
exec </dev/null
fails=0
ok()   { echo "ok   $1"; }
fail() { echo "FAIL $1: $2"; fails=$((fails+1)); }
expect() { if [ "$2" = "$3" ]; then ok "$1"; else fail "$1" "expected [$3], got [$2]"; fi; }

tmp="$(cd "$(mktemp -d)" && pwd -P)"; trap 'rm -rf "$tmp"' EXIT
root="$tmp/code"; mkdir -p "$root" "$tmp/bin" "$tmp/config" "$tmp/home" "$tmp/live" "$tmp/desk/aaaaaaaa-0000-4000-8000-000000000001/bbbbbbbb-0000-4000-8000-000000000002"
export HOME="$tmp/home" DEPLOYS_CONFIG="$tmp/config" DEPLOYS_JOURNAL="$tmp/journal.jsonl" NO_COLOR=1 DEPLOYS_TESTING=1 DEPLOYS_STRANDED_NO_PERF=1
export DEPLOYS_LOCAL_SESSIONS_DIR="$tmp/live" DEPLOYS_DESKTOP_SESSIONS_BASE="$tmp/desk"
export GIT_AUTHOR_NAME=Test GIT_AUTHOR_EMAIL=test@example.invalid GIT_COMMITTER_NAME=Test GIT_COMMITTER_EMAIL=test@example.invalid
echo "{\"roots\":[\"$root\"]}" > "$tmp/config/repos.json"
# gh stub: visibility from GH_VIS, pr create prints a made-up URL and logs its arguments
cat > "$tmp/bin/gh" <<'GH'
#!/bin/bash
echo "$*" >> "$GH_LOG"
case "$1 $2" in
  "repo view") # GH_FLIP=<folder>: private on the first look there, public after (made public between plan and push)
    if [ -n "${GH_FLIP:-}" ] && [ "$PWD" = "$GH_FLIP" ]; then [ -f "$GH_LOG.flip" ] && echo PUBLIC || { echo PRIVATE; touch "$GH_LOG.flip"; }
    else echo "${GH_VIS:-PRIVATE}"; fi ;;
  "pr create") [ -z "${GH_FAIL:-}" ] || exit 1; echo "https://example.invalid/pull/7" ;;
esac
GH
# claude stub: `claude agents --json` lists the sessions in $tmp/agents.json (none by default)
cat > "$tmp/bin/claude" <<'CL'
#!/bin/bash
[ -z "${AGENTS_FAIL:-}" ] || { echo 'not json'; exit 0; }
# AGENTS_LATE=<folder>: a session there starts after the first look
if [ -n "${AGENTS_LATE:-}" ]; then [ -f "$AGENTS_JSON.seen" ] && printf '[{"cwd":"%s"}]\n' "$AGENTS_LATE" || { echo '[]'; touch "$AGENTS_JSON.seen"; }; exit 0; fi
[ "$1 $2" = "agents --json" ] && { cat "$AGENTS_JSON" 2>/dev/null || echo '[]'; }
CL
chmod +x "$tmp/bin/gh" "$tmp/bin/claude"; export PATH="$tmp/bin:$PATH" GH_LOG="$tmp/gh.log" AGENTS_JSON="$tmp/agents.json"
D() { ./deploys "$@"; }

# repo <name>: a repo under the root with a bare origin and one pushed commit
repo() {
  git init -q --bare "$tmp/origin-$1.git"
  git init -q -b main "$root/$1"; ( cd "$root/$1" && echo one > a.txt && git add a.txt && git commit -qm one \
    && git remote add origin "$tmp/origin-$1.git" && git push -q origin main && git remote set-head origin main >/dev/null 2>&1 ) || true
}
old() { find "$1" -path "$1/.git" -prune -o -exec touch -t 202001010000 {} + 2>/dev/null; }

repo clean
repo dirty;    echo change >> "$root/dirty/a.txt"; echo new > "$root/dirty/b.txt"; old "$root/dirty"
repo ahead;    ( cd "$root/ahead" && git checkout -qb feature && echo x > c.txt && git add c.txt && git commit -qm local ); old "$root/ahead"
repo fresh;    echo just-now >> "$root/fresh/a.txt"
repo live;     echo change >> "$root/live/a.txt"; old "$root/live"
repo arch;     echo change >> "$root/arch/a.txt"; old "$root/arch"
repo secret;   echo 'KEY=x' > "$root/secret/.env"; old "$root/secret"
repo token;    printf 'const k = "ghp_%s";\n' "abcdefghijklmnopqrstuvwx1234" > "$root/token/k.js"; old "$root/token"
repo odd;      printf 'const k = "ghp_%s";\n' "abcdefghijklmnopqrstuvwx1234" > "$root/odd/tab	\"q\" café.js"; old "$root/odd"
repo ren;      ( cd "$root/ren" && seq 1 50 > Rold.txt && git add Rold.txt && git commit -qm r && git push -q origin main \
                 && mv Rold.txt new.txt && git add -N new.txt ) >/dev/null 2>&1
               printf 'k = "ghp_%s"\n' "abcdefghijklmnopqrstuvwx1234" > "$root/ren/zz.txt"; old "$root/ren"
repo many;     mkdir -p "$root/many/gen"; for i in $(seq 1 12); do echo "$i" > "$root/many/gen/$i.txt"; done; old "$root/many"
repo wt;       git -C "$root/wt" worktree add -q -b claude/w "$root/wt/.claude/worktrees/w1" 2>/dev/null; echo w > "$root/wt/.claude/worktrees/w1/w.txt"
               printf '.claude/\n' > "$root/wt/.git/info/exclude"; old "$root/wt/.claude/worktrees/w1"
sleep 1 & wait
# a live session in "live" (this shell's pid is alive), an archived desktop session in "arch"
jq -n --arg c "$root/live" --argjson p $$ '{pid: $p, cwd: $c, sessionId: "s"}' > "$tmp/live/1.json"
jq -n --arg c "$root/arch" '{cwd: $c, isArchived: true, title: "Old task", lastActivityAt: 1}' \
  > "$tmp/desk/aaaaaaaa-0000-4000-8000-000000000001/bbbbbbbb-0000-4000-8000-000000000002/local_cccccccc-0000-4000-8000-000000000003.json"

j="$(D repos stranded --json)" || fail "stranded runs" "exit $?"
names() { jq -r '[.items[].name] | sort | join(" ")' <<<"$j"; }
expect "listed folders" "$(names)" "ahead arch dirty many odd ren secret token w1"
expect "archived first" "$(jq -r '.items[0].name' <<<"$j")" arch
expect "archived class" "$(jq -r '.items[] | select(.name == "arch") | .class' <<<"$j")" archived
expect "changed files counted" "$(jq -r '.items[] | select(.name == "dirty") | .changed' <<<"$j")" 2
expect "unpushed without upstream" "$(jq -r '.items[] | select(.name == "ahead") | "\(.changed) \(.unpushed) \(.branch)"' <<<"$j")" "0 1 feature"
expect "worktree under .claude/worktrees" "$(jq -r '.items[] | select(.name == "w1") | .repoName' <<<"$j")" wt
expect "cached result" "$(D repos stranded --cached --json | jq -r '.summary.folders')" 9
case "$(D repos stranded)" in *"Work left behind: 9 folders"*) ok "text output" ;; *) fail "text output" "$(D repos stranded)" ;; esac

# rescue: dry run first, the folder untouched
state() { ( cd "$1" && git rev-parse HEAD; git status --porcelain; cksum .git/index; find . -path ./.git -prune -o -type f -exec cksum {} + | sort ) 2>/dev/null; }
before="$(state "$root/dirty")"
out="$(D repos rescue "$root/dirty")"
case "$out" in *"Would push 2 changed files"*"Add --yes."*) ok "dry run says what it would do" ;; *) fail "dry run" "$out" ;; esac
expect "dry run pushes nothing" "$(git -C "$tmp/origin-dirty.git" branch --list 'rescue/*' | wc -l | tr -d ' ')" 0
r="$(D repos rescue "$root/dirty" --yes --json)"
expect "rescued" "$(jq -r .state <<<"$r")" rescued
expect "rescue note names the PR once" "$(jq -r .note <<<"$r" | grep -o 'pull/7' | wc -l | tr -d ' ')" 1
expect "pull request link" "$(jq -r .pr <<<"$r")" "https://example.invalid/pull/7"
b="$(jq -r .branch <<<"$r")"
case "$b" in rescue/dirty-*) ok "branch name" ;; *) fail "branch name" "$b" ;; esac
expect "branch on origin holds the changes" "$(git -C "$tmp/origin-dirty.git" show "$b:b.txt" 2>/dev/null)" new
expect "parent is the folder's HEAD" "$(git -C "$tmp/origin-dirty.git" rev-parse "$b^")" "$(git -C "$root/dirty" rev-parse HEAD)"
expect "folder untouched (HEAD, status, index, files)" "$(state "$root/dirty")" "$before"
if grep -q -- '--draft' "$GH_LOG"; then ok "draft pull request"; else fail "draft pull request" "$(cat "$GH_LOG")"; fi
expect "second rescue does nothing" "$(D repos rescue "$root/dirty" --yes --json | jq -r .state)" done-before
if grep -q 'rescued dirty to rescue/dirty-' "$tmp/journal.jsonl" 2>/dev/null; then ok "journal"; else fail "journal" "no line"; fi

# unpushed commits only: pushed as they are
r="$(D repos rescue "$root/ahead" --yes --json)"
expect "unpushed commit rescued as is" "$(git -C "$tmp/origin-ahead.git" rev-parse "$(jq -r .branch <<<"$r")")" "$(git -C "$root/ahead" rev-parse HEAD)"

# refusals
echo more > "$root/many/extra.txt"
r="$(GH_FAIL=1 D repos rescue "$root/many" --yes --json)"
case "$(jq -r .note <<<"$r")" in *"no pull request: gh failed"*) ok "gh failure: fallback note" ;; *) fail "gh failure: fallback note" "$r" ;; esac
expect "gh failure: no pr" "$(jq -r .pr <<<"$r")" null
expect "secret file refused" "$(D repos rescue "$root/secret" --yes --json | jq -r '"\(.state) \(.problems[0])"')" "refused secret-like file: .env"
expect "token refused" "$(D repos rescue "$root/token" --yes --json | jq -r '"\(.state) \(.problems[0])"')" "refused looks like a key or token inside: k.js"
expect "token in a quoted file name refused" "$(D repos rescue "$root/odd" --yes --json | jq -r '.state')" refused
D repos rescue "$root/secret" --yes >/dev/null 2>&1; expect "refusal exits 1 without --json" "$?" 1
expect "unstaged rename does not hide the next file" "$(D repos rescue "$root/ren" --yes --json | jq -r '"\(.state) \(.problems | join(","))"')" "refused looks like a key or token inside: zz.txt"
expect "too many files refused" "$(DEPLOYS_STRANDED_MAX_FILES=10 D repos rescue "$root/many" --yes --json | jq -r '.state')" refused
expect "big file refused" "$(DEPLOYS_STRANDED_MAX_KB=0 D repos rescue "$root/dirty" --json | jq -r '.problems | length > 0')" true
D repos rescue "$root/live" --yes >/dev/null 2>&1; expect "live session refused" "$?" 1
expect "nothing pushed when refused" "$(git -C "$tmp/origin-secret.git" branch --list 'rescue/*' | wc -l | tr -d ' ')" 0
expect "clean: nothing to rescue" "$(D repos rescue "$root/clean" --yes --json | jq -r .state)" nothing
GH_VIS=PUBLIC; export GH_VIS
case "$(D repos rescue "$root/w1" 2>&1; D repos rescue "$root/wt/.claude/worktrees/w1")" in *"PUBLIC"*) ok "public repo warned" ;; *) fail "public repo warned" "no warning" ;; esac
D repos rescue "$root/dirty/sub" >/dev/null 2>&1; expect "missing folder" "$?" 1

# ---- the automatic rescue: its own config folder and root, so the folders above do not count ----
unset GH_VIS
export DEPLOYS_CONFIG="$tmp/config2"; mkdir -p "$tmp/config2"
root="$tmp/code2"; mkdir -p "$root"; echo "{\"roots\":[\"$root\"]}" > "$tmp/config2/repos.json"
two_h="$(date -r $(( $(date +%s) - 7200 )) +%Y%m%d%H%M 2>/dev/null || date -d @$(( $(date +%s) - 7200 )) +%Y%m%d%H%M)"
recent2h() { find "$1" -path "$1/.git" -prune -o -exec touch -t "$two_h" {} + 2>/dev/null; }
for n in a1 a6 a7; do repo "$n"; echo change >> "$root/$n/a.txt"; old "$root/$n"; done
repo a2; echo change >> "$root/a2/a.txt"; recent2h "$root/a2"                  # idle 2 h, no session: left
repo a3; echo change >> "$root/a3/a.txt"; recent2h "$root/a3"                  # idle 2 h, archived session: rescued
repo a4; echo change >> "$root/a4/a.txt"; old "$root/a4"                       # a running agent: never
repo a5; echo 'KEY=x' > "$root/a5/.env"; old "$root/a5"                        # a secret: refused
jq -n --arg c "$root/a3" '{cwd: $c, isArchived: true, title: "Done", lastActivityAt: 2}' \
  > "$tmp/desk/aaaaaaaa-0000-4000-8000-000000000001/bbbbbbbb-0000-4000-8000-000000000002/local_cccccccc-0000-4000-8000-000000000004.json"
jq -n --arg c "$root/a4" '[{pid: 1, cwd: $c, kind: "background", status: "busy"}]' > "$tmp/agents.json"
pushed() { git -C "$tmp/origin-$1.git" branch --list 'rescue/*' | wc -l | tr -d ' '; }

j="$(D repos rescue --auto --json)"
expect "auto dry run: candidates" "$(jq -r '[.items[] | "\(.name):\(.state)"] | sort | join(" ")' <<<"$j")" "a1:would-rescue a3:would-rescue a5:refused a6:would-rescue a7:would-rescue"
expect "auto dry run pushes nothing" "$(pushed a1)$(pushed a3)" 00
expect "auto --yes is off without the opt-in" "$(D repos rescue --auto --yes --json | jq -r .off)" true
expect "off: nothing pushed" "$(pushed a1)" 0
echo '{"auto":true,"perRun":3,"perDay":4}' > "$tmp/config2/rescue.json"
j="$(D repos rescue --auto --yes --json)"
expect "auto: 3 rescued, 1 for later, 1 refused" "$(jq -r '.summary | "\(.rescued) \(.capped) \(.refused)"' <<<"$j")" "3 1 1"
expect "auto: archived one first" "$(jq -r '.items[0] | "\(.name) \(.state)"' <<<"$j")" "a3 rescued"
expect "auto: draft pull request" "$(jq -r '[.items[] | select(.state == "rescued") | .pr] | unique | join(" ")' <<<"$j")" "https://example.invalid/pull/7"
expect "auto: running agent left alone" "$(pushed a4):$(jq -r '[.items[] | select(.name == "a4")] | length' <<<"$j")" "0:0"
expect "auto: idle 2 h without session left alone" "$(pushed a2)" 0
expect "auto: secret not pushed" "$(pushed a5)" 0
expect "auto: refusal journaled" "$(grep -c 'rescue of a5 refused' "$tmp/journal.jsonl")" 1
expect "auto: summary journaled" "$(grep -c 'Automatic rescue: 3 rescued' "$tmp/journal.jsonl")" 1
j="$(D repos rescue --auto --yes --json)"
expect "auto: next run takes the rest, day cap 4" "$(jq -r '.summary | "\(.rescued) \(.today)"' <<<"$j")" "1 4"
expect "auto: rescued ones are not pushed again" "$(pushed a1)$(pushed a3)$(pushed a6)$(pushed a7)" 1111
expect "auto: refusal journaled once" "$(grep -c 'rescue of a5 refused' "$tmp/journal.jsonl")" 1
repo a8; echo change >> "$root/a8/a.txt"; old "$root/a8"
expect "auto: day cap reached" "$(D repos rescue --auto --yes --json | jq -r '.items[] | select(.name == "a8") | .state')" capped
echo '{"auto":true}' > "$tmp/config2/rescue.json"; echo '{}' > "$tmp/config2/rescue-state.json"
expect "auto: public repo not pushed" "$(GH_VIS=PUBLIC D repos rescue --auto --yes --json | jq -r '.items[] | select(.name == "a8") | .state'):$(pushed a8)" "public:0"
expect "auto: unknown visibility not pushed" "$(GH_VIS=UNKNOWN D repos rescue --auto --yes --json | jq -r '.items[] | select(.name == "a8") | .state')" public
echo '{"auto":true,"public":true}' > "$tmp/config2/rescue.json"
expect "auto: public allowed by rescue.json" "$(GH_VIS=PUBLIC D repos rescue --auto --yes --json | jq -r '.items[] | select(.name == "a8") | .state')" rescued
repo a9; echo change >> "$root/a9/a.txt"; old "$root/a9"; a9="$(cd "$root/a9" && pwd -P)"
echo '{"auto":true}' > "$tmp/config2/rescue.json"
expect "auto: claude agents without an answer stops the run" "$(AGENTS_FAIL=1 D repos rescue --auto --yes --json | jq -r '.skipped // "ran"' | cut -c1-13):$(pushed a9)" "claude agents:0"
expect "auto: made public between plan and push, not pushed" "$(GH_FLIP="$a9" D repos rescue --auto --yes --json | jq -r '.items[] | select(.name == "a9") | .state'):$(pushed a9)" "public:0"
rm -f "$GH_LOG.flip"
expect "auto: push asks claude agents again" "$(AGENTS_LATE="$a9" D repos rescue --auto --yes --json | jq -r '.items[] | select(.name == "a9") | .state'):$(pushed a9)" "error:0"
rm -f "$tmp/agents.json.seen"
case "$(D repos rescue --auto)" in *"Automatic rescue:"*"Nothing was pushed"*) ok "auto: text output" ;; *) fail "auto: text output" "$(D repos rescue --auto)" ;; esac
if command -v launchctl >/dev/null 2>&1 && command -v plutil >/dev/null 2>&1; then
  ( export DEPLOYS_LAUNCH_DIR="$tmp/la"; launchctl() { [ "$1" != print ]; }; export -f launchctl
    echo '{"perRun":2}' > "$tmp/config2/rescue.json"; D repos rescue schedule on >/dev/null 2>&1 || true )
  plist="$tmp/la/com.deploycenter.rescue.plist"
  expect "schedule on: hourly, --auto --yes" "$(grep -c '<integer>3600</integer>' "$plist"):$(grep -c '<string>--auto</string>' "$plist")" "1:1"
  expect "schedule on: opt-in kept with the settings" "$(jq -c . "$tmp/config2/rescue.json")" '{"perRun":2,"auto":true}'
  ( export DEPLOYS_LAUNCH_DIR="$tmp/la"; launchctl() { :; }; export -f launchctl; D repos rescue schedule off >/dev/null 2>&1 || true )
  expect "schedule off" "$([ -f "$plist" ] && echo there || echo gone):$(jq -r .auto "$tmp/config2/rescue.json")" "gone:false"
else ok "schedule: skipped (no launchd here)"; fi

echo
if [ "$fails" = 0 ]; then echo "all stranded tests passed"; else echo "$fails failed"; exit 1; fi
