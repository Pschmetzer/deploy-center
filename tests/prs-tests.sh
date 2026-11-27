#!/bin/bash
# Tests for `deploys prs` (lib/prs.sh, lib/prsfix.sh): your open pull requests kept free of conflicts and merged.
# No network: a stand-in `gh` answers the GraphQL search with made-up pull requests of acme/web and logs merges, a
# stand-in `claude` resolves conflict markers (or fails on purpose), and `git` is a shim that logs every call and then
# runs the real git against bare repos in a temp folder, so a merge, a conflict and a push really happen.
# Run: tests/prs-tests.sh
set -uo pipefail
cd "$(dirname "$0")/.." || exit 1
exec </dev/null
fails=0
ok()   { echo "ok   $1"; }
fail() { echo "FAIL $1: $2"; fails=$((fails+1)); }
expect() { [ "$2" = "$3" ] && ok "$1" || fail "$1" "expected [$3], got [$2]"; }

tmp="$(mktemp -d)"; trap 'rm -rf "$tmp"' EXIT
realgit="$(command -v git)"
export DEPLOYS_CONFIG="$tmp/config" HOME="$tmp/home" NO_COLOR=1 DEPLOYS_TESTING=1 DEPLOYS_NOTIFY=0
export DEPLOYS_JOURNAL="$tmp/journal.jsonl" DEPLOYS_PRS_REMOTE="$tmp/remotes" DEPLOYS_PRS_BRAKE=""
export DEPLOYS_LOCAL_SESSIONS_DIR="$tmp/sessions" DEPLOYS_LAUNCH_DIR="$tmp/launch"
export GIT_AUTHOR_NAME=Test GIT_AUTHOR_EMAIL=test@example.com GIT_COMMITTER_NAME=Test GIT_COMMITTER_EMAIL=test@example.com
export GIT_CONFIG_NOSYSTEM=1
mkdir -p "$HOME" "$DEPLOYS_CONFIG" "$tmp/bin" "$tmp/sessions" "$tmp/remotes/acme"
printf '{"enabled":[]}' > "$DEPLOYS_CONFIG/providers.json"

# --- the remote: acme/web with a main and one branch per case ---
G() { "$realgit" "$@"; }
G init -q --bare -b main "$tmp/remotes/acme/web.git"
seed="$tmp/seed"; G init -q -b main "$seed"
printf 'one\n' > "$seed/a.txt"; printf 'base\n' > "$seed/b.txt"
G -C "$seed" add -A; G -C "$seed" commit -qm base; G -C "$seed" remote add origin "$tmp/remotes/acme/web.git"; G -C "$seed" push -q origin main
br() {  # br <branch> <file> <text>: a branch off the first commit with one change
  G -C "$seed" checkout -q -b "$1" main; printf '%s\n' "$3" > "$seed/$2"; G -C "$seed" add -A; G -C "$seed" commit -qm "$1"
  G -C "$seed" push -q origin "$1"; G -C "$seed" checkout -q main
}
br feat/conflict a.txt "one from the branch"
br feat/clean c.txt "new file"
br feat/fail a.txt "one from fail"
br feat/ready d.txt ready
br feat/ready2 e.txt ready2
br feat/busy a.txt "one from busy"
br feat/agent a.txt "one from agent"
br feat/behind f.txt behind
printf 'one from main\n' > "$seed/a.txt"; G -C "$seed" commit -qam "main moves"; G -C "$seed" push -q origin main
oid() { G -C "$tmp/remotes/acme/web.git" rev-parse "refs/heads/$1"; }

# A busy session on this Mac on feat/busy (a session file) and one on feat/agent (claude agents --json).
G clone -q "$tmp/remotes/acme/web.git" "$tmp/work1"; G -C "$tmp/work1" checkout -q feat/busy
G clone -q "$tmp/remotes/acme/web.git" "$tmp/work2"; G -C "$tmp/work2" checkout -q feat/agent
printf '{"pid":%s,"sessionId":"s1","cwd":"%s","status":"busy"}' "$$" "$tmp/work1" > "$tmp/sessions/1.json"
printf '{"pid":%s,"sessionId":"s0","cwd":"%s","status":"idle"}' "$$" "$tmp/work2" > "$tmp/sessions/0.json"
printf '[{"pid":1,"cwd":"%s","status":"busy"}]' "$tmp/work2" > "$tmp/agents.json"

# --- the GitHub answer ---
node() {  # node <n> <branch> <mergeable> <mergeState> <ci or null> [draft] [cross] [review]
  local ci="null"; [ "$5" = null ] || ci="{\"state\":\"$5\"}"
  jq -nc --argjson n "$1" --arg b "$2" --arg m "$3" --arg s "$4" --argjson ci "$ci" --argjson d "${6:-false}" --argjson x "${7:-false}" \
    --arg r "${8:-}" --arg oid "$(oid "$2" 2>/dev/null || echo 0000000)" \
    '{number: $n, title: "PR \($n)", url: "https://github.com/acme/web/pull/\($n)", isDraft: $d, mergeable: $m, mergeStateStatus: $s,
      reviewDecision: (if $r == "" then null else $r end), baseRefName: "main", headRefName: $b, headRefOid: $oid, isCrossRepository: $x,
      updatedAt: "2026-01-01T00:00:00Z",
      repository: {nameWithOwner: "acme/web", mergeCommitAllowed: true, squashMergeAllowed: true, rebaseMergeAllowed: false},
      commits: {nodes: [{commit: {statusCheckRollup: $ci}}]}}'
}
answer() {
  { node 8 feat/clean CONFLICTING DIRTY SUCCESS
    node 1 feat/conflict CONFLICTING DIRTY SUCCESS
    node 6 feat/busy CONFLICTING DIRTY SUCCESS
    node 12 feat/agent CONFLICTING DIRTY SUCCESS
    node 7 feat/behind MERGEABLE BEHIND SUCCESS
    node 2 feat/ready MERGEABLE CLEAN SUCCESS
    node 9 feat/ready2 MERGEABLE CLEAN SUCCESS
    node 3 feat/unknown UNKNOWN UNKNOWN null
    node 4 feat/red MERGEABLE UNSTABLE FAILURE
    node 5 feat/draft CONFLICTING DIRTY SUCCESS true
    node 10 feat/fork CONFLICTING DIRTY SUCCESS false true
    node 13 feat/review MERGEABLE BLOCKED SUCCESS false false CHANGES_REQUESTED
    node 14 feat/nochecks MERGEABLE CLEAN null
  } | jq -sc '{data: {viewer: {login: "octo"}, search: {issueCount: length, nodes: .}}}' > "$tmp/answer.json"
}
answer

cat > "$tmp/bin/gh" <<SH
#!/bin/bash
echo "\$*" >> "$tmp/gh.log"
case "\$*" in
  *"api graphql"*) [ -f "$tmp/gh-broken" ] && { echo "HTTP 502" >&2; exit 1; }; cat "$tmp/answer.json" ;;
  *"pr merge"*) exit 0 ;;
  *"update-branch"*) exit 0 ;;
  "auth git-credential"*) exit 0 ;;
  *) exit 1 ;;
esac
SH
cat > "$tmp/bin/claude" <<SH
#!/bin/bash
echo "\$*" >> "$tmp/claude.log"
case "\$1" in
  agents) cat "$tmp/agents.json"; exit 0 ;;
  -p) if [ "\$(cat "$tmp/claude-mode" 2>/dev/null)" = fail ]; then echo '{"result":"Tried.\nRESULT: FAIL tests break"}'; exit 0; fi
      for f in \$(grep -rlE '^<<<<<<<' . --exclude-dir=.git); do perl -i -ne 'print unless /^(<<<<<<<|=======|>>>>>>>)/' "\$f"; done
      echo '{"result":"Resolved both sides.\nRESULT: PASS"}' ;;
esac
SH
cat > "$tmp/bin/git" <<SH
#!/bin/bash
echo "\$*" >> "$tmp/git.log"
exec "$realgit" "\$@"
SH
printf '#!/bin/sh\necho "$*" >> "%s/launchctl.log"\ncase "$1" in print) exit 1;; esac\nexit 0\n' "$tmp" > "$tmp/bin/launchctl"
chmod +x "$tmp/bin/"*
export PATH="$tmp/bin:$PATH"
cli() { bash ./deploys "$@"; }

# --- the report ---
j="$(cli prs --json)"
st() { jq -r --argjson n "$1" '.prs[] | select(.pr == $n) | .state' <<<"$j"; }
expect "CONFLICTING is a conflict"         "$(st 1)" conflict
expect "MERGEABLE, CLEAN and green: ready" "$(st 2)" ready
expect "UNKNOWN is neither"                "$(st 3)" unknown
expect "red checks"                        "$(st 4)" red
expect "a draft stays a draft"             "$(st 5)" draft
expect "BEHIND"                            "$(st 7)" behind
expect "changes requested"                 "$(st 13)" changes
expect "no checks: blocked by default"     "$(st 14)" blocked
expect "conflicts array: no UNKNOWN, no draft" "$(jq -c '[.conflicts[].pr]' <<<"$j")" '[8,1,6,12,10]'
expect "key is repo#pr:headOid" "$(jq -r '.prs[] | select(.pr == 1) | .key' <<<"$j")" "acme/web#1:$(oid feat/conflict)"
expect "summary" "$(jq -c '.summary | {open, conflicts, unknown, ready, red, draft}' <<<"$j")" '{"open":13,"conflicts":5,"unknown":1,"ready":2,"red":1,"draft":1}'
expect "one search for every repo" "$(grep -c 'author:@me' "$tmp/gh.log")" 1
expect "automatic parts are off by default" "$(jq -c '.settings | [.autoResolve, .autoMerge]' <<<"$j")" '[false,false]'
txt="$(cli prs)"
expect "text: a row" "$(grep -c 'conflict  acme/web#1  ' <<<"$txt")" 1
cli prs deny acme/web >/dev/null
expect "deny leaves the repo out" "$(cli prs --json | jq '.summary.open')" 0
cli prs unlist acme/web >/dev/null
cli prs allow acme/other >/dev/null
expect "allow limits to the listed repos" "$(cli prs --json | jq '.summary.open')" 0
cli prs unlist acme/other >/dev/null
touch "$tmp/gh-broken"; expect "GitHub not read: an error entry" "$(cli prs --json | jq '.errors | length')" 1; rm -f "$tmp/gh-broken"

# --- run: --yes, opt-in ---
cli prs run >/dev/null 2>&1; expect "run without --yes: exit 2" "$?" 2
out="$(cli prs run --yes)"
expect "off by default: says how to turn it on" "$(grep -c 'set autoResolve on' <<<"$out")" 1
expect "off: nothing merged" "$(grep -c 'pr merge' "$tmp/gh.log")" 0
cli prs set autoResolve maybe >/dev/null 2>&1; expect "set refuses a bad value" "$?" 2
cli prs set autoResolve on >/dev/null; cli prs set autoMerge on >/dev/null; cli prs set perRun 2 >/dev/null
expect "settings file is private (600)" "$(stat -c %a "$DEPLOYS_CONFIG/prs.json" 2>/dev/null || stat -f %Lp "$DEPLOYS_CONFIG/prs.json")" 600

# --- the load brake ---
n0="$(grep -c 'author:@me' "$tmp/gh.log")"
out="$(DEPLOYS_PRS_BRAKE="swap almost full" cli prs run --yes)"
expect "brake: the pass is skipped" "$(grep -c 'skipped, the Mac is busy' <<<"$out")" 1
expect "brake: GitHub is not even read" "$(grep -c 'author:@me' "$tmp/gh.log")" "$n0"

# --- the first real pass ---
: > "$tmp/git.log"
out="$(cli prs run --yes)"
state="$(cat "$DEPLOYS_CONFIG/prs-state.json")"
act() { jq -r --arg k "$1" --argjson n "$2" '[.lastRun.actions[] | select(.kind == $k and .pr == $n) | .result] | join(",")' <<<"$state"; }
skip() { jq -r --argjson n "$1" '[.lastRun.skips[] | select(.pr == $n) | .why] | join(",")' <<<"$state"; }
expect "clean merge pushed" "$(act resolve 8)" pushed
expect "the base is in the branch now" "$(G -C "$tmp/remotes/acme/web.git" merge-base --is-ancestor main feat/clean && echo yes)" yes
expect "conflict resolved by Claude and pushed" "$(act resolve 1)" pushed
expect "both sides kept, no markers" "$(G -C "$tmp/remotes/acme/web.git" show feat/conflict:a.txt | tr '\n' '|')" "one from the branch|one from main|"
expect "a merge commit, not a rewrite" "$(G -C "$tmp/remotes/acme/web.git" rev-list --parents -n1 feat/conflict | wc -w | tr -d ' ')" 3
expect "Claude ran with the CLI login, headless" "$(grep -c -- '--permission-mode acceptEdits' "$tmp/claude.log")" 1
expect "busy session file: skipped" "$(skip 6)" "a Claude Code session on this Mac is working on this branch"
expect "busy in claude agents: skipped" "$(skip 12)" "a Claude Code session on this Mac is working on this branch"
expect "busy branch untouched" "$(G -C "$tmp/remotes/acme/web.git" rev-parse feat/busy)" "$(jq -r '.prs[] | select(.pr == 6) | .headOid' <<<"$j")"
expect "fork: skipped" "$(skip 10)" "the branch is in a fork"
expect "cap per pass: behind waits" "$(skip 7)" "cap of 2 per pass reached"
expect "ready one merged" "$(act merge 2)" merged
expect "merged with --merge and the head SHA" "$(grep -c "pr merge 2 --repo acme/web --merge --match-head-commit $(oid feat/ready)" "$tmp/gh.log")" 1
expect "one merge per base per pass" "$(skip 9)" "another pull request was merged into main in this pass"
expect "red never merged" "$(grep -c 'pr merge 4 ' "$tmp/gh.log")" 0
expect "draft never touched" "$(grep -c 'pr merge 5 ' "$tmp/gh.log"; act resolve 5)" 0
expect "UNKNOWN left alone" "$(act resolve 3)$(act merge 3)" ""
expect "no --admin ever" "$(grep -c -- '--admin' "$tmp/gh.log")" 0
expect "never a rebase" "$(grep -c 'rebase' "$tmp/git.log")" 0
expect "never a force push" "$(grep -E 'push' "$tmp/git.log" | grep -cE -- '--force|-f |\+refs|\+HEAD')" 0
expect "journal: resolved and merged" "$(jq -r 'select(.platform == "github") | .result' "$DEPLOYS_JOURNAL" | sort | tr '\n' ' ')" "merged resolved resolved "

# --- the next pass: one attempt per SHA (the answer still names the old heads) ---
: > "$tmp/claude.log"
cli prs run --yes >/dev/null
state="$(cat "$DEPLOYS_CONFIG/prs-state.json")"
expect "no second attempt at the same SHA" "$(skip 2)" "tried once at this commit"
expect "behind one now: GitHub updates the branch" "$(act update 7)" pushed
expect "update-branch with the expected head" "$(grep -c "update-branch -f expected_head_sha=$(oid feat/behind)" "$tmp/gh.log")" 1
expect "the other ready one merged now" "$(act merge 9)" merged
expect "Claude not asked again" "$(grep -c -- '--permission-mode' "$tmp/claude.log" 2>/dev/null || true)" 0
expect "report: merged today" "$(cli prs --json | jq '.summary.mergedToday')" 2

# --- Claude fails: nothing is pushed; the day cap ---
rm -f "$DEPLOYS_CONFIG/prs-state.json"; echo fail > "$tmp/claude-mode"
before="$(oid feat/fail)"
{ node 11 feat/fail CONFLICTING DIRTY SUCCESS; node 15 feat/ready2 CONFLICTING DIRTY SUCCESS; } \
  | jq -sc '{data: {viewer: {login: "octo"}, search: {issueCount: length, nodes: .}}}' > "$tmp/answer.json"
cli prs set perDay 1 >/dev/null
cli prs run --yes >/dev/null
state="$(cat "$DEPLOYS_CONFIG/prs-state.json")"
expect "Claude FAIL: failed" "$(act resolve 11)" failed
expect "Claude FAIL: the branch is unchanged" "$(oid feat/fail)" "$before"
expect "Claude FAIL: in the journal" "$(jq -r 'select(.name == "acme/web#11") | .result' "$DEPLOYS_JOURNAL")" failed
expect "cap per day" "$(skip 15)" "cap of 1 per day reached"
cli prs set perDay 8 >/dev/null

# --- the schedule: launchd every 5 minutes, the first pass only reports ---
rm -f "$DEPLOYS_CONFIG/prs-state.json"; rm -f "$tmp/claude-mode"; answer; : > "$tmp/gh.log"
out="$(cli prs schedule on)"
expect "schedule: the job file" "$(grep -c '<string>prs</string><string>run</string><string>--yes</string>' "$tmp/launch/app.deploycenter.prs.plist")" 1
expect "schedule: every 300 s" "$(grep -c '<integer>300</integer>' "$tmp/launch/app.deploycenter.prs.plist")" 1
out="$(cli prs run --yes)"
expect "first pass is a dry run" "$(grep -c 'dry run, the first pass' <<<"$out")" 1
expect "first pass: nothing merged" "$(grep -c 'pr merge' "$tmp/gh.log")" 0
expect "first pass: would merge" "$(grep -c 'would merge acme/web#2' <<<"$out")" 1
expect "then the flag is gone" "$(jq '.firstRunPending' "$DEPLOYS_CONFIG/prs-state.json")" false
cli prs schedule off >/dev/null
expect "schedule off removes the job" "$([ -f "$tmp/launch/app.deploycenter.prs.plist" ] && echo there || echo gone)" gone

[ "$fails" = 0 ] && echo "prs-tests: all ok" || echo "prs-tests: $fails failed"
[ "$fails" = 0 ]
