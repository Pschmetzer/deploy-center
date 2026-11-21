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
  echo "$1 $(jq -c '[.osv.items[].package, .semgrep.items[].rule]' "$SCAN_DIR/checks/$3.json")" >> "$SCANS"
  local id; id="$(sc_slug "$1")-$RANDOM"
  sc_edit '.runs = ([{id:$i, repo:$r, status:"pr", prUrl:"https://example.invalid/pr/1"}] + .runs)' --arg i "$id" --arg r "$1"
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

[ "$fails" = 0 ] && echo "nightly: all passed" || { echo "nightly: $fails failed"; exit 1; }
