#!/bin/bash
# Tests for the nightly check (lib/nightly.sh): which repos, only new findings count, Claude gets only
# those, a refused scan keeps them for the next night, leaks are only reported. No network, no
# launchd, no real HOME, no real checker or Claude. Run: tests/nightly-tests.sh
set -uo pipefail
cd "$(dirname "$0")/.." || exit 1
exec </dev/null
fails=0
ok()   { echo "ok   $1"; }
fail() { echo "FAIL $1: $2"; fails=$((fails+1)); }
expect() { [ "$2" = "$3" ] && ok "$1" || fail "$1" "expected [$3], got [$2]"; }

tmp="$(mktemp -d)"; trap 'rm -rf "$tmp"' EXIT
export DEPLOYS_CONFIG="$tmp/config" DEPLOYS_LIB=1 DEPLOYS_TESTING=1 HOME="$tmp/home" NO_COLOR=1 DEPLOYS_NOTIFY=0
mkdir -p "$HOME" "$DEPLOYS_CONFIG"
# shellcheck source=../deploys
. ./deploys
set +e

# --- the repo list: once per repo and branch, without paused, ignored, skipped and non-GitHub ones ---
ng_projects() {
  cat <<'JSON'
[{"name":"web","platform":"vercel","repo":"acme/shop","ref":"main"},
 {"name":"api","platform":"render","repo":"acme/shop","ref":"main"},
 {"name":"old","platform":"vercel","repo":"acme/old","ref":"main","paused":true},
 {"name":"docs","platform":"vercel","repo":"acme/docs"},
 {"name":"gl","platform":"vercel","repo":"group/sub/proj","ref":"main"},
 {"name":"norepo","platform":"vercel","repo":null},
 {"name":"hidden","platform":"vercel","repo":"acme/hidden","ref":"main"}]
JSON
}
echo '["hidden"]' > "$DEPLOYS_CONFIG/ignored.json"
expect "repos: one line per repo and branch" "$(ng_repos | tr '\t' ' ' | tr '\n' ',')" "acme/docs main,acme/shop main,"
ng_set --arg r acme/docs '.skip = [$r]'
expect "repos: a skipped repo is left out" "$(ng_repos | cut -f1 | tr '\n' ',')" "acme/shop,"
ng_set '.skip = []'
expect "settings: off by default" "$(ng_settings | jq -c '[.fix, .at]')" '[false,"03:00"]'

# --- a run: fake checker and scan ---
ck_has() { return 0; }
FINDINGS='{"osv":{"items":[{"file":"package-lock.json","package":"lodash","version":"4.17.0","ecosystem":"npm","ids":["GHSA-1"],"vulns":1}]},
  "gitleaks":{"items":[{"rule":"generic-api-key","file":"a.js","line":3,"commit":"abc1234"}]},
  "semgrep":{"items":[{"rule":"js.eval","file":"b.js","line":9,"severity":"ERROR","message":"eval"},
                      {"rule":"js.style","file":"b.js","line":2,"severity":"WARNING","message":"meh"}],"secrets":[]}}'
check_run() {  # check_run <id> <repo> <branch>
  mkdir -p "$SCAN_DIR/checks"; echo "$FINDINGS" > "$SCAN_DIR/checks/$1.json"
  sc_edit '.checks = ((.checks // []) | map(if .id == $i then . + {status:"done"} else . end))' --arg i "$1"
}
SCANS="$tmp/scans"; : > "$SCANS"
scan_start() {  # records what Claude would get; SCAN_REFUSE makes it refuse like an open PR does
  [ -z "${SCAN_REFUSE:-}" ] || die "acme/docs has an open bug-scan PR (#4); merge or close it first"
  if jq -e .review "$SCAN_DIR/checks/$3.json" >/dev/null; then echo "$1 review $3" >> "$SCANS"
  else echo "$1 $(jq -c '[.osv.items[]?.package, .semgrep.items[]?.rule]' "$SCAN_DIR/checks/$3.json")" >> "$SCANS"; fi
  local id; id="$(sc_slug "$1")-$RANDOM"
  sc_edit '.runs = ([{id:$i, repo:$r, status:$s, prUrl:"https://example.invalid/pr/1"}] + .runs)' --arg i "$id" --arg r "$1" --arg s "${SCAN_STATUS:-pr}"
  echo "$id"
}
NOTES="$tmp/notes"; : > "$NOTES"
af_notify() { echo "$1" >> "$NOTES"; }
ng_projects() { echo '[{"name":"docs","platform":"vercel","repo":"acme/docs","ref":"main"}]'; }

out="$(nightly_run 2>&1)"
expect "run 0: the first check of a repo is its baseline" "$(echo "$out" | grep -c 'baseline (2 finding(s) known)')" "1"
expect "run 0: a baseline notifies nothing and scans nothing" "$(wc -l < "$NOTES" | tr -d ' '):$(wc -l < "$SCANS" | tr -d ' ')" "0:0"
# From now on, a finding that appears is new (OSV + Semgrep ERROR, not WARNING).
FINDINGS="$(echo "$FINDINGS" | jq -c '.osv.items += [{"file":"package-lock.json","package":"axios","version":"0.1.0","ecosystem":"npm","ids":["GHSA-2"],"vulns":1}]
  | .gitleaks.items += [{"rule":"aws-key","file":"d.js","line":1,"commit":"def5678"}]
  | .semgrep.items += [{"rule":"js.other","file":"e.js","line":1,"severity":"WARNING","message":"x"}]')"
out="$(nightly_run 2>&1)"
expect "run 1, fix off: the new findings are counted (not WARNING)" "$(echo "$out" | grep -c '^Nightly check: 1 new finding(s), 1 new leak(s)')" "1"
expect "run 1, fix off: no scan" "$(wc -l < "$SCANS" | tr -d ' ')" "0"
expect "run 1: one notification, naming the leak" "$(grep -c 'rotated' "$NOTES")" "1"
: > "$NOTES"
out="$(nightly_run 2>&1)"
expect "run 2: nothing is new" "$(echo "$out" | grep -c '^Nightly check: 0 new finding(s), 0 new leak(s)')" "1"
expect "run 2: no notification when nothing is new" "$(wc -l < "$NOTES" | tr -d ' ')" "0"

# A new finding appears and fix is on: Claude gets only the new one.
FINDINGS="$(echo "$FINDINGS" | jq -c '.semgrep.items += [{"rule":"js.sqli","file":"c.js","line":5,"severity":"ERROR","message":"sql"}]')"
ng_set '.fix = true'
SCAN_REFUSE=1 nightly_run >/dev/null 2>&1
expect "run 3: a refused scan opens nothing" "$(wc -l < "$SCANS" | tr -d ' ')" "0"
expect "run 3: the refusal is kept as a note" "$(nightly_status | jq -r '.repos[0] | .code + " " + .note' | grep -c '^refused .*open bug-scan PR')" "1"
: > "$NOTES"; SCAN_REFUSE=1 nightly_run >/dev/null 2>&1
expect "run 3b: a finding still waiting is not notified again" "$(wc -l < "$NOTES" | tr -d ' ')" "0"
nightly_run >/dev/null 2>&1
expect "run 4: the finding kept from run 3 goes to Claude, alone" "$(cat "$SCANS")" 'acme/docs ["js.sqli"]'
nightly_run >/dev/null 2>&1
expect "run 5: the same finding is not sent twice" "$(wc -l < "$SCANS" | tr -d ' ')" "1"

# The nightly limit of scans.
: > "$SCANS"
ng_projects() { echo '[{"name":"a","platform":"vercel","repo":"acme/a"},{"name":"b","platform":"vercel","repo":"acme/b"},{"name":"c","platform":"vercel","repo":"acme/c"}]'; }
nightly_run >/dev/null 2>&1   # their baseline
FINDINGS="$(echo "$FINDINGS" | jq -c '.semgrep.items += [{"rule":"js.xss","file":"f.js","line":1,"severity":"ERROR","message":"xss"}]')"
NIGHTLY_MAX_SCANS=2 nightly_run >/dev/null 2>&1
expect "limit: at most NIGHTLY_MAX_SCANS scans a night" "$(wc -l < "$SCANS" | tr -d ' ')" "2"
expect "limit: the third repo waits for the next night" "$(nightly_status | jq -r '[.repos[] | select(.code == "limit")] | length')" "1"

# Status for the app: no finding text in it, the PR of a scan is.
st="$(nightly_status)"
expect "status: fix on, at 03:00, three repos plus docs" "$(echo "$st" | jq -c '[.fix, .at, (.repos | length)]')" '[true,"03:00",4]'
expect "status: no finding text leaves the run" "$(echo "$st" | grep -c 'lodash\|generic-api-key\|js.eval\|axios')" "0"
expect "status: the scan's PR is named" "$(echo "$st" | jq -r '[.repos[] | select(.prUrl != null)] | length > 0')" "true"

# A second run while one holds the lock does nothing.
mkdir -p "$DEPLOYS_CONFIG/locks/nightly"
expect "lock: a run in progress is not started twice" "$(nightly_run 2>&1 | grep -c 'in progress')" "1"
rmdir "$DEPLOYS_CONFIG/locks/nightly"

# A check that keeps failing is notified when it starts failing, not every night.
check_run() { return 1; }
: > "$NOTES"; nightly_run >/dev/null 2>&1; nightly_run >/dev/null 2>&1
expect "failing: notified once, not every night" "$(grep -c 'check(s) failed' "$NOTES")" "1"

# The schedule: a launchd job at the set time that runs `deploys nightly run`.
mkdir -p "$tmp/bin" "$tmp/la"
printf '#!/bin/sh\ncase "$1" in print) exit 1;; esac\nexit 0\n' > "$tmp/bin/launchctl"; chmod +x "$tmp/bin/launchctl"
( PATH="$tmp/bin:$PATH" DEPLOYS_LAUNCH_DIR="$tmp/la" nightly_main schedule on 22:30 >/dev/null 2>&1 )
pl="$tmp/la/$NIGHTLY_LABEL.plist"
expect "schedule: the time is saved" "$(ng_settings | jq -r .at)" "22:30"
expect "schedule: launchd runs it at 22:30" "$(tr -d '\n ' < "$pl" | grep -c '<key>Hour</key><integer>22</integer><key>Minute</key><integer>30</integer>')" "1"
expect "schedule: it runs deploys nightly run" "$(tr -d '\n ' < "$pl" | grep -c '<string>nightly</string><string>run</string>')" "1"

# Commands: argument checks.
expect "schedule: a bad time is refused" "$( (nightly_main schedule on 25:00) 2>&1 | grep -c Usage)" "1"
( nightly_main skip acme/a ) >/dev/null; expect "skip: kept in the settings" "$(ng_settings | jq -c .skip)" '["acme/a"]'
( nightly_main unskip acme/a ) >/dev/null; expect "unskip: removed again" "$(ng_settings | jq -c .skip)" '[]'

# --- the weekly review: last week's changes of a repo, from its clone ---
export GIT_AUTHOR_NAME=t GIT_AUTHOR_EMAIL=t@example.invalid GIT_COMMITTER_NAME=t GIT_COMMITTER_EMAIL=t@example.invalid
clone="$SCAN_DIR/repos/acme-rev"; mkdir -p "$clone"; git -C "$clone" init -q
commit() {  # commit <file> <days ago> <message>
  echo "$RANDOM" > "$clone/$1"; git -C "$clone" add -A
  GIT_AUTHOR_DATE="$(( $(date +%s) - $2 * 86400 )) +0000" GIT_COMMITTER_DATE="$(( $(date +%s) - $2 * 86400 )) +0000" git -C "$clone" commit -qm "$3"
  git -C "$clone" update-ref refs/remotes/origin/main HEAD
}
commit a.js 10 "old"; OLD="$(git -C "$clone" rev-parse HEAD)"
commit b.js 2 "SECRET-COMMIT-TEXT"; commit README.md 1 "docs"; HEAD1="$(git -C "$clone" rev-parse HEAD)"
check_run() {
  mkdir -p "$SCAN_DIR/checks"; echo "$FINDINGS" | jq --arg s "$(git -C "$clone" rev-parse origin/main)" '. + {sha:$s}' > "$SCAN_DIR/checks/$1.json"
  sc_edit '.checks = ((.checks // []) | map(if .id == $i then . + {status:"done"} else . end))' --arg i "$1"
}
ng_projects() { echo '[{"name":"rev","platform":"vercel","repo":"acme/rev","ref":"main"}]'; }
ng_set '.fix = false | .review = true | .reviewDay = 7'
DAY=3; ng_weekday() { echo "$DAY"; }
rv() { jq -r --arg k "$1" '.repos["acme/rev"][$k] | if . == null then "" else tostring end' "$(ng_state_file)"; }
: > "$SCANS"; nightly_run >/dev/null 2>&1
expect "review: not on another weekday" "$(grep -c review "$SCANS")" "0"
DAY=7; nightly_run >/dev/null 2>&1
expect "review: on the review day, one scan" "$(grep -c 'acme/rev review' "$SCANS")" "1"
rf="$(grep 'acme/rev review' "$SCANS" | tail -1 | cut -d' ' -f3)"; pr="$(ck_findings_prompt "$rf")"
expect "review: the base is the last commit older than a week" "$(echo "$pr" | grep -c "git diff $OLD..HEAD")" "1"
expect "review: changed code is listed, docs are not" "$(echo "$pr" | grep -c '^- b.js$'):$(echo "$pr" | grep -c README)" "1:0"
expect "review: no commit message in the prompt" "$(echo "$pr" | grep -c SECRET-COMMIT-TEXT)" "0"
expect "review: the reviewed commit moves on" "$(rv reviewedSha)" "$HEAD1"
nightly_run >/dev/null 2>&1
expect "review: not twice within five days" "$(grep -c 'acme/rev review' "$SCANS")" "1"

# A week later, new code, but the scan is refused: it waits, and the reviewed commit stays.
old_review() { jq '.repos["acme/rev"].reviewAt -= 604800' "$(ng_state_file)" | ng_save; }
commit c.js 0 "new"; HEAD2="$(git -C "$clone" rev-parse HEAD)"; old_review
SCAN_REFUSE=1 nightly_run >/dev/null 2>&1
expect "review: a refused scan waits" "$(rv reviewPending):$(rv reviewCode):$(rv reviewedSha)" "true:refused:$HEAD1"
DAY=1; nightly_run >/dev/null 2>&1
rf="$(grep 'acme/rev review' "$SCANS" | tail -1 | cut -d' ' -f3)"
expect "review: a waiting one runs the next night, from the last reviewed commit" "$(ck_findings_prompt "$rf" | grep -c "git diff $HEAD1..HEAD")" "1"
expect "review: then it is done" "$(rv reviewPending):$(rv reviewedSha)" "false:$HEAD2"

# Nothing changed: no scan.
DAY=7; old_review; n="$(wc -l < "$SCANS")"; nightly_run >/dev/null 2>&1
expect "review: nothing changed, no scan" "$(wc -l < "$SCANS"):$(rv reviewCode)" "$n:reviewNothing"

# Fixes first, the review shares the nightly limit.
ng_set '.fix = true'; commit d.js 0 "more"; old_review
FINDINGS="$(echo "$FINDINGS" | jq -c '.semgrep.items += [{"rule":"js.path","file":"g.js","line":1,"severity":"ERROR","message":"path"}]')"
NIGHTLY_MAX_SCANS=1 nightly_run >/dev/null 2>&1
expect "review: the fix used the one scan, the review waits" "$(tail -1 "$SCANS" | grep -c 'js.path'):$(rv reviewCode)" "1:reviewWaiting"
ng_set '.fix = false'

# A scan that fails is tried twice, then left.
DAY=7; old_review; SCAN_STATUS=failed nightly_run >/dev/null 2>&1
expect "review: a failed scan is tried again" "$(rv reviewPending):$(rv reviewFails)" "true:1"
DAY=2; SCAN_STATUS=failed nightly_run >/dev/null 2>&1
expect "review: after two failures it is left until the next week" "$(rv reviewPending):$(rv reviewCode)" "false:reviewGaveUp"
expect "review: settings in the status" "$(nightly_status | jq -c '[.review, .reviewDay]')" "[true,7]"
expect "review: a bad weekday is refused" "$( (nightly_main review on 8) 2>&1 | grep -c Usage)" "1"

# --- history: every run leaves one line, newest first, capped; an empty repo list is a run too ---
rm -f "$(ng_history_file)"
ng_projects() { echo '[]'; }
nightly_run >/dev/null 2>&1
expect "history: a run with no repos is recorded" "$(ng_history | jq -c '[length, .[0].repos, .[0].newFindings]')" "[1,0,0]"
ng_projects() { echo '[{"name":"docs","platform":"vercel","repo":"acme/docs","ref":"main"}]'; }
nightly_run >/dev/null 2>&1; nightly_run >/dev/null 2>&1
expect "history: one entry per run" "$(ng_history | jq length)" "3"
expect "history: view prints the summary" "$(nightly_main history 2>&1 | grep -c 'Nightly check:')" "3"
expect "history: --limit" "$(nightly_main history --limit 1 2>&1 | grep -c 'Nightly check:')" "1"
expect "history: json" "$(json=1 nightly_main history | jq -c 'length')" "3"
i=0; while [ $i -lt 110 ]; do echo "$(jq -c '. + {at:1}' <<<'{"summary":"x"}')"; i=$((i+1)); done | jq -sc . > "$(ng_history_file)"
nightly_run >/dev/null 2>&1
expect "history: capped at 90" "$(ng_history | jq length)" "90"
echo "garbage" > "$(ng_history_file)"
expect "history: a damaged file reads as empty" "$(ng_history | jq length)" "0"
expect "history: with none, says so" "$(nightly_main history 2>&1 | grep -c 'No nightly run yet')" "1"

[ "$fails" = 0 ] && echo "nightly: all passed" || { echo "nightly: $fails failed"; exit 1; }
