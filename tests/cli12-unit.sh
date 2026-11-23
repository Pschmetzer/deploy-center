#!/bin/bash
# Tests for round 12 of the CLI: `deploys digest`, `deploys freeze`, `deploys doctor --fix`, --json on the list
# commands that lacked it, completion of the new commands, and direct tests for lib/ helpers that had none
# (http_retry_after, gitlab_enc, githost_cache_name, hooks_ours, hooks_husky, team_repo_list, sv_rate, rules_on).
# No network, no real projects; the journal and window.json are files in a temp folder. Run: tests/cli12-unit.sh
set -uo pipefail
cd "$(dirname "$0")/.." || exit 1
exec </dev/null
fails=0
ok()   { echo "ok   $1"; }
fail() { echo "FAIL $1: $2"; fails=$((fails+1)); }
expect() { [ "$2" = "$3" ] && ok "$1" || fail "$1" "expected [$3], got [$2]"; }

tmp="$(mktemp -d)"; trap 'rm -rf "$tmp"' EXIT
export DEPLOYS_CONFIG="$tmp/config" DEPLOYS_LIB=1 DEPLOYS_TESTING=1 HOME="$tmp/home" NO_COLOR=1 DEPLOYS_JOURNAL="$tmp/journal.jsonl"
mkdir -p "$HOME" "$DEPLOYS_CONFIG" "$tmp/bin"
printf '#!/bin/bash\nexit 1\n' > "$tmp/bin/gh"; chmod +x "$tmp/bin/gh"
export PATH="$tmp/bin:$PATH"
# shellcheck source=../deploys
. ./deploys
# shellcheck source=../lib/savings.sh
. ./lib/savings.sh
set +e
cli() { env -u DEPLOYS_LIB bash ./deploys "$@"; }

# --- freeze_time ---
expect "freeze_time: 15" "$(freeze_time 15)" "15:00"
expect "freeze_time: 9:30" "$(freeze_time 9:30)" "09:30"
expect "freeze_time: 24:00 ends the day" "$(freeze_time 24:00)" "24:00"
expect "freeze_time: 08" "$(freeze_time 08)" "08:00"
for bad in 25 24:01 12:60 abc 1530 "" 9:5; do freeze_time "$bad" >/dev/null 2>&1; expect "freeze_time: refuses [$bad]" "$?" "1"; done

# --- freeze_day, freeze_days ---
expect "freeze_day: Friday" "$(freeze_day Friday)" "fri"
expect "freeze_day: THU" "$(freeze_day THU)" "thu"
freeze_day fr >/dev/null 2>&1; expect "freeze_day: refuses fr" "$?" "1"
expect "freeze_days: one day" "$(freeze_days fri)" '["fri"]'
expect "freeze_days: list in week order, once each" "$(freeze_days sun,fri,fri,mon)" '["mon","fri","sun"]'
expect "freeze_days: range" "$(freeze_days mon-wed)" '["mon","tue","wed"]'
expect "freeze_days: a range past Sunday" "$(freeze_days sat-mon)" '["mon","sat","sun"]'
expect "freeze_days: weekend" "$(freeze_days weekend)" '["sat","sun"]'
expect "freeze_days: weekdays" "$(freeze_days weekdays)" '["mon","tue","wed","thu","fri"]'
expect "freeze_days: daily is every day" "$(freeze_days daily)" '[]'
for bad in "" noday fri,xyz mon-xyz; do freeze_days "$bad" >/dev/null 2>&1; expect "freeze_days: refuses [$bad]" "$?" "1"; done

# --- freeze_add_json, freeze_remove_json, freeze_view ---
expect "freeze_add_json: into an empty file" "$(freeze_add_json '{}' '["fri"]' 15:00 24:00 '')" '{"deny":[{"from":"15:00","to":"24:00","days":["fri"]}]}'
expect "freeze_add_json: keeps tz and other rules, adds the reason" \
  "$(freeze_add_json '{"tz":"Europe/Berlin","deny":[{"dates":["2026-12-24"]}]}' '[]' 00:00 06:00 'night' | jq -c '{tz, n:(.deny | length), last:.deny[-1]}')" \
  '{"tz":"Europe/Berlin","n":2,"last":{"from":"00:00","to":"06:00","reason":"night"}}'
freeze_add_json '[1]' '["fri"]' 15:00 24:00 '' >/dev/null 2>&1; expect "freeze_add_json: a file that is no object fails" "$([ $? -ne 0 ] && echo failed)" "failed"
expect "freeze_remove_json: rule 2 of 3" "$(freeze_remove_json '{"deny":[{"from":"1"},{"from":"2"},{"from":"3"}]}' 2)" '{"deny":[{"from":"1"},{"from":"3"}]}'
freeze_remove_json '{"deny":[{"from":"1"}]}' 2 >/dev/null 2>&1; expect "freeze_remove_json: no such rule" "$([ $? -ne 0 ] && echo failed)" "failed"
freeze_remove_json '{"deny":[{"from":"1"}]}' 0 >/dev/null 2>&1; expect "freeze_remove_json: rule 0 does not exist" "$([ $? -ne 0 ] && echo failed)" "failed"
expect "freeze_view: rules numbered, defaults filled in" \
  "$(freeze_view '{"deny":[{"days":["fri"],"from":"15:00"}]}' '{"configured":true,"denied":false}' | jq -c '{c:.configured, now:.closedNow, r:.rules}')" \
  '{"c":true,"now":false,"r":[{"n":1,"days":["fri"],"from":"15:00","to":"24:00","reason":null}]}'

# --- freeze, the command ---
out="$(cli freeze)"; expect "freeze: nothing set" "$(head -n 1 <<<"$out")" "No closed times set. Deploys are allowed at any time."
expect "freeze --json: nothing set" "$(cli freeze --json | jq -c '{configured, rules}')" '{"configured":false,"rules":[]}'
cli freeze add fri 15:00 --reason "no Friday deploys" >/dev/null; rc=$?
expect "freeze add: written" "$rc $(jq -c '.deny' "$DEPLOYS_CONFIG/window.json")" '0 [{"from":"15:00","to":"24:00","days":["fri"],"reason":"no Friday deploys"}]'
expect "freeze add: the file is private" "$(ls -l "$DEPLOYS_CONFIG/window.json" | cut -c1-10)" "-rw-------"
expect "window: closed on Friday 15:30" "$(DEPLOYS_NOW="fri 15:30 2026-11-13" cli window 2>&1 | grep -c 'Closed')" "1"
DEPLOYS_NOW="fri 15:30 2026-11-13" cli window >/dev/null 2>&1; expect "window: exit 1 when closed" "$?" "1"
DEPLOYS_NOW="fri 14:59 2026-11-13" cli window >/dev/null 2>&1; expect "window: open at 14:59" "$?" "0"
expect "freeze: says closed now" "$(DEPLOYS_NOW="fri 16:00 2026-11-13" cli freeze | grep -c '^Closed now')" "1"
expect "freeze --json: closedNow" "$(DEPLOYS_NOW="fri 16:00 2026-11-13" cli freeze --json | jq -c '{closedNow, reason}')" '{"closedNow":true,"reason":"no Friday deploys"}'
# A closed window stops a deploy before anything is asked of a platform (no --force).
echo '{"enabled":[]}' > "$DEPLOYS_CONFIG/providers.json"
out="$(DEPLOYS_NOW="fri 16:00 2026-11-13" cli deploy-changed --yes 2>&1)"
expect "freeze: deploy-changed --yes is refused in the window" "$(grep -c 'No deploys now\|deploy window is closed' <<<"$out")" "1"
cli freeze add sat,sun 0 >/dev/null; cli freeze add mon-wed 9:30 12 --reason='standup' >/dev/null
expect "freeze add: three rules" "$(cli freeze --json | jq -c '[.rules[] | "\(.n) \(.from)-\(.to)"]')" '["1 15:00-24:00","2 00:00-24:00","3 09:30-12:00"]'
cli freeze remove 2 >/dev/null; expect "freeze remove: rule 2 gone, the rest renumbered" "$(cli freeze --json | jq -c '[.rules[] | "\(.n) \(.from)"]')" '["1 15:00","2 09:30"]'
out="$(cli freeze remove 9 2>&1)"; rc=$?; expect "freeze remove: no such rule" "$rc $(grep -c 'There is no rule 9' <<<"$out")" "1 1"
out="$(cli freeze remove x 2>&1)"; expect "freeze remove: usage" "$(grep -c 'Usage: deploys freeze remove' <<<"$out")" "1"
for bad in "add bad 15:00" "add fri 25:00" "add fri 15:00 99" "add fri 15:00 15:00" "add fri" "add fri 15:00 --nope"; do
  # shellcheck disable=SC2086
  cli freeze $bad >/dev/null 2>&1; rc=$?
  case "$bad" in "add fri"|"add fri 15:00 --nope") want=2 ;; *) want=1 ;; esac   # a wrong call is 2, a bad value 1
  expect "freeze: refuses [$bad]" "$rc" "$want"
done
expect "freeze: a refused add changes nothing" "$(cli freeze --json | jq '.rules | length')" "2"
cp "$DEPLOYS_CONFIG/window.json" "$tmp/w.bak"; echo 'not json' > "$DEPLOYS_CONFIG/window.json"
out="$(cli freeze add fri 15:00 2>&1)"; rc=$?
expect "freeze add: a window.json that cannot be read is not overwritten" "$rc $(cat "$DEPLOYS_CONFIG/window.json")" "1 not json"
cp "$tmp/w.bak" "$DEPLOYS_CONFIG/window.json"
cli freeze add fri 17 --reason $'bad\001text' >/dev/null; expect "freeze add: control characters leave the reason" "$(jq -r '.deny[-1].reason' "$DEPLOYS_CONFIG/window.json")" "badtext"
cli freeze clear >/dev/null; expect "freeze clear: no rules, file kept" "$(jq -c '.deny' "$DEPLOYS_CONFIG/window.json")" "[]"
expect "freeze: nothing set after clear" "$(cli freeze | head -n 1)" "No closed times set. Deploys are allowed at any time."
rm -f "$DEPLOYS_CONFIG/window.json"; expect "freeze clear: without a file" "$(cli freeze clear)" "No closed times set."
# Observer mode may look and set a closed time: it only restricts.
cli freeze add fri 15:00 >/dev/null; expect "freeze add: allowed in observer mode" "$(DEPLOYS_READONLY=1 cli freeze add sat 8 >/dev/null 2>&1; echo $?)" "0"
rm -f "$DEPLOYS_CONFIG/window.json"

# --- digest_from ---
now=1800000000   # a fixed moment
iso() { date -u -r "$1" +%Y-%m-%dT%H:%M:%SZ 2>/dev/null || date -u -d "@$1" +%Y-%m-%dT%H:%M:%SZ; }
d1="$(iso $((now - 3600)))"; d2="$(iso $((now - 86400 * 2)))"; d3="$(iso $((now - 86400 * 6)))"; old="$(iso $((now - 86400 * 20)))"; future="$(iso $((now + 3600)))"
journal="$(cat <<J
{"at":"$d1","platform":"Vercel","name":"web","result":"live","detail":"ok"}
{"at":"$d1","platform":"Vercel","name":"web","result":"failed","detail":"Build failed: exit 1"}
{"at":"$d2","platform":"cli","name":"api","result":"other","detail":"Started from the terminal (dpl_1)"}
{"at":"$d2","platform":"cli","name":"api","result":"other","detail":"Rolled back: x answered 500"}
{"at":"$d2","platform":"Render","name":"api","result":"rollback","detail":"back"}
{"at":"$d3","platform":"Vercel","name":"web","result":"live","detail":"ok"}
{"at":"$d3","platform":"Vercel","name":"web","result":"forced","detail":"Deployed in the window"}
{"at":"$d3","platform":"Vercel","name":"web","result":"skipped","detail":"s"}
{"at":"$d3","platform":"Vercel","name":"web","result":"cancelled","detail":"c"}
{"at":"$d3","platform":"Vercel","name":"web","result":"preview","detail":"p"}
{"at":"$old","platform":"Vercel","name":"old","result":"live","detail":"too old"}
{"at":"$future","platform":"Vercel","name":"later","result":"live","detail":"in the future"}
{"at":"not a date","platform":"Vercel","name":"bad","result":"live"}
not json at all
[1,2]
J
)"
dg="$(digest_from "$now" 7 <<<"$journal")"
expect "digest_from: counts" "$(jq -c '{entries, deploys, failures, rollbacks, forced, previews, skipped, cancelled}' <<<"$dg")" \
  '{"entries":10,"deploys":3,"failures":1,"rollbacks":1,"forced":1,"previews":1,"skipped":1,"cancelled":1}'
expect "digest_from: failure rate" "$(jq .failureRate <<<"$dg")" "25"
expect "digest_from: projects, the most deploys first" "$(jq -c '[.projects[] | "\(.name) \(.deploys)/\(.failures)"]' <<<"$dg")" '["web 2/1","api 1/0"]'
expect "digest_from: the latest failure" "$(jq -c '.lastFailures | map(.detail)' <<<"$dg")" '["Build failed: exit 1"]'
expect "digest_from: a shorter window leaves the older lines out" "$(digest_from "$now" 1 <<<"$journal" | jq -c '{entries, deploys}')" '{"entries":2,"deploys":1}'
expect "digest_from: a longer window takes the old line in" "$(digest_from "$now" 30 <<<"$journal" | jq .deploys)" "4"
expect "digest_from: an empty journal" "$(digest_from "$now" 7 </dev/null | jq -c '{entries, deploys, failureRate, busiestDay, projects}')" '{"entries":0,"deploys":0,"failureRate":null,"busiestDay":null,"projects":[]}'
expect "digest_from: control characters in a detail are replaced" \
  "$(printf '{"at":"%s","name":"w","result":"failed","detail":"a\\u001b[31mb"}\n' "$d1" | digest_from "$now" 7 | jq -r '.lastFailures[0].detail' | cat -v)" "a [31mb"
expect "digest_from: a fraction in the time is read" "$(printf '{"at":"%s","name":"w","result":"live"}\n' "${d1%Z}.123Z" | digest_from "$now" 7 | jq .deploys)" "1"

# --- digest_savings, digest_print ---
expect "digest_savings: from a ledger" "$(digest_savings "$(cat tests/fixtures/savings/ledger-report.json)" | jq -c '{estimate, since, usdComplete, k:(.skippedBuilds | type)}')" '{"estimate":true,"since":"2026-01-20","usdComplete":false,"k":"number"}'
expect "digest_savings: no ledger is null" "$(digest_savings '{"error":"x"}')" "null"
expect "digest_savings: garbage is null" "$(digest_savings 'not json')" "null"
expect "digest_savings: nothing is null" "$(digest_savings '')" "null"
txt="$(jq -c '. + {savings:null, savingsAsked:false}' <<<"$dg" | digest_print)"
expect "digest_print: headline" "$(sed -n 2p <<<"$txt")" "  3 deploys, 1 failed (25%), 1 rolled back, 1 forced"
expect "digest_print: no savings line when not asked" "$(grep -c Savings <<<"$txt")" "0"
expect "digest_print: savings unavailable when asked" "$(jq -c '. + {savings:null, savingsAsked:true}' <<<"$dg" | digest_print | grep -c 'Savings: not available')" "1"
expect "digest_print: savings from the ledger" "$(jq -c --argjson s "$(digest_savings "$(cat tests/fixtures/savings/ledger-report.json)")" '. + {savings:$s, savingsAsked:true}' <<<"$dg" | digest_print | grep -c 'Savings (estimate')" "1"
expect "digest_print: an empty week" "$(digest_from "$now" 7 </dev/null | jq -c '. + {savings:null, savingsAsked:false}' | digest_print | sed -n 2p)" "  Nothing in the journal for this time."
expect "digest_print: one deploy is singular" "$(printf '{"at":"%s","name":"w","result":"live"}\n' "$d1" | digest_from "$now" 1 | jq -c '. + {savings:null, savingsAsked:false}' | digest_print | head -n 1 | cut -c1-24)" "Digest of the last 1 day"

# --- digest, the command (no network: --no-savings) ---
rm -f "$DEPLOYS_JOURNAL"
expect "digest: no journal yet" "$(cli digest --no-savings | sed -n 2p)" "  Nothing in the journal for this time."
nowiso="$(date -u +%Y-%m-%dT%H:%M:%SZ)"
printf '{"at":"%s","platform":"Vercel","name":"web","result":"live","detail":"ok"}\n{"at":"%s","platform":"Vercel","name":"web","result":"failed","detail":"x"}\n' "$nowiso" "$nowiso" > "$DEPLOYS_JOURNAL"
expect "digest --json: counts" "$(cli digest --no-savings --json | jq -c '{deploys, failures, days, savings, savingsAsked}')" '{"deploys":1,"failures":1,"days":7,"savings":null,"savingsAsked":false}'
expect "digest --days 30 --json" "$(cli digest --no-savings --days 30 --json | jq .days)" "30"
for bad in "--days 0" "--days x" "--days" "--days 99999" "--nope"; do
  # shellcheck disable=SC2086
  cli digest --no-savings $bad >/dev/null 2>&1; rc=$?
  want=1; [ "$bad" != "--nope" ] || want=2   # an unknown option is a wrong call
  expect "digest: refuses [$bad]" "$rc" "$want"
done
expect "digest: reads the journal and starts nothing" "$(wc -l < "$DEPLOYS_JOURNAL" | tr -d ' ')" "2"

# --- doctor --fix: shown, never run ---
dj='{"jq":true,"githubCli":true,"githubLoggedIn":false,"perl":true,"curl":false,"configWritable":true,"jobsMissing":["autofix:gh"],"readonly":true,"providers":{"netlify":{"provider":"netlify","tokenOk":false},"vercel":{"tokenOk":true},"render":{"error":"no key"}}}'
fx="$(fixes_from "$dj")"
expect "fixes_from: problems and commands" "$(jq -c '[.[] | .command]' <<<"$fx")" \
  '["gh auth login","install curl","deploys autofix schedule on","deploys netlify set-key","deploys render set-key","deploys readonly off"]'
expect "fixes_from: a healthy machine has none" "$(fixes_from '{"jq":true,"githubCli":true,"githubLoggedIn":true,"perl":true,"curl":true,"configWritable":true,"jobsMissing":[],"readonly":false,"providers":{}}')" "[]"
expect "fixes_from: no gh means no login hint, only the install" "$(fixes_from '{"jq":true,"githubCli":false,"perl":true,"curl":true,"configWritable":true}' | jq -c 'map(.command)')" '["brew install gh"]'
expect "fixes_from: not JSON gives []" "$(fixes_from 'nope')" "[]"
expect "fixes_window: no file" "$(fixes_window)" "[]"
echo '{"deny":[{"day":["fri"],"from":"25:00"}]}' > "$DEPLOYS_CONFIG/window.json"
expect "fixes_window: lines that would not work" "$(fixes_window | jq 'length')" "2"
rm -f "$DEPLOYS_CONFIG/window.json"
expect "fixes_print: none" "$(echo '[]' | fixes_print)" "Nothing to fix."
expect "fixes_print: says nothing was run" "$(jq -c '.[0:1]' <<<"$fx" | fixes_print | head -n 1)" "Suggestions (shown only: nothing was run or changed):"
out="$(cli doctor --fix --json)"
expect "doctor --fix --json: changed is false and fixes is a list" "$(jq -c '[.changed, (.fixes | type)]' <<<"$out")" '[false,"array"]'
expect "doctor --fix: text" "$(cli doctor --fix | grep -c 'Nothing to fix\|Suggestions (shown only')" "1"
before="$(ls -lR "$DEPLOYS_CONFIG" | md5sum 2>/dev/null || ls -lR "$DEPLOYS_CONFIG" | md5)"
cli doctor --fix >/dev/null 2>&1; after="$(ls -lR "$DEPLOYS_CONFIG" | md5sum 2>/dev/null || ls -lR "$DEPLOYS_CONFIG" | md5)"
expect "doctor --fix: writes nothing" "$after" "$before"

# --- --json on the list commands that lacked it ---
expect "ignore --list --json: empty" "$(cli ignore --list --json)" "[]"
echo '["a","b"]' > "$DEPLOYS_CONFIG/ignored.json"
expect "ignore --list --json: the names" "$(cli ignore --list --json)" '["a","b"]'
expect "ignore --list: still one per line" "$(cli ignore --list | tr '\n' ' ')" "a b "
expect "team list --json: empty" "$(cli team list --json)" "[]"
printf 'me/one\nme/two\n' > "$DEPLOYS_CONFIG/team-repos"
expect "team list --json: the repos" "$(cli team list --json)" '["me/one","me/two"]'
expect "team list: still one per line" "$(cli team list | tr '\n' ' ')" "me/one me/two "
echo '{"fires":[{"at":1800000000,"project":"web","status":"fired","sha":"abcdef1234","pr":7,"mergedSha":"1234567890"}]}' > "$DEPLOYS_CONFIG/autofix.json"
grep -q 'AUTOFIX_STATE=' deploys && out="$(cli autofix list --json 2>&1)" || out='[]'
expect "autofix list --json: an array" "$(jq -c 'type' <<<"$out" 2>/dev/null)" '"array"'
out="$(cli scan list --json 2>&1)"; expect "scan list --json: an array" "$(jq -c 'type' <<<"$out" 2>/dev/null)" '"array"'

# --- completion knows the new commands in all three shells ---
for sh in bash zsh fish; do
  c="$(cli completion "$sh")"
  expect "completion $sh: names freeze" "$([ "$(grep -c freeze <<<"$c")" -ge 1 ] && echo yes)" "yes"
  expect "completion $sh: names digest" "$([ "$(grep -c digest <<<"$c")" -ge 1 ] && echo yes)" "yes"
  expect "completion $sh: freeze subcommands" "$(grep -c 'add import remove clear' <<<"$c")" "1"
  expect "completion $sh: doctor --fix" "$(grep -c -- '--fix' <<<"$c")" "1"
done

# --- helpers in lib/ that had no test of their own ---
printf 'HTTP/2 429\r\nRetry-After: 7\r\n\r\n' > "$tmp/h1"
expect "http_retry_after: seconds" "$(http_retry_after "$tmp/h1")" "7"
printf 'retry-after: 500\r\n' > "$tmp/h2"; expect "http_retry_after: more than a minute is given as it is (http_call gives up on it)" "$(http_retry_after "$tmp/h2")" "500"
printf 'Retry-After: Wed, 21 Oct 2026 07:28:00 GMT\r\n' > "$tmp/h3"; expect "http_retry_after: a date in the past is 0 seconds" "$(http_retry_after "$tmp/h3")" "0"
printf 'Retry-After: 3\r\nRetry-After: 9\r\n' > "$tmp/h4"; expect "http_retry_after: the last one counts" "$(http_retry_after "$tmp/h4")" "9"
expect "http_retry_after: no file" "$(http_retry_after "$tmp/none")" ""
expect "gitlab_enc: a group path" "$(gitlab_enc 'group/sub group/app')" "group%2Fsub%20group%2Fapp"
expect "gitlab_enc: a plain name" "$(gitlab_enc app)" "app"
expect "githost_cache_name: slashes and at-signs" "$(githost_cache_name 'me/app@main')" "me_app_main"
a="$(githost_cache_name 'me/a_b')"; b="$(githost_cache_name 'me/a/b')"
[ "$a" != "$b" ] && ok "githost_cache_name: two names that look alike stay apart" || fail "githost_cache_name: two names that look alike stay apart" "both [$a]"
mkdir -p "$tmp/repo/.git/hooks" "$tmp/repo2/.husky"
printf '#!/bin/sh\n# %s\n' "$HOOKS_MARK" > "$tmp/ours"; printf '#!/bin/sh\nexit 0\n' > "$tmp/theirs"
hooks_ours "$tmp/ours"; expect "hooks_ours: our wrapper" "$?" "0"
hooks_ours "$tmp/theirs"; expect "hooks_ours: someone else's hook" "$?" "1"
hooks_ours "$tmp/none"; expect "hooks_ours: no file" "$?" "1"
hooks_husky "$tmp/repo2" "$tmp/repo2/.git/hooks"; expect "hooks_husky: a .husky folder" "$?" "0"
hooks_husky "$tmp/repo" "$tmp/repo/.husky/_"; expect "hooks_husky: a hooks dir inside .husky" "$?" "0"
hooks_husky "$tmp/repo" "$tmp/repo/.git/hooks"; expect "hooks_husky: plain git" "$?" "1"
rm -f "$REPOS" "$TEAM_REPOS" "$TEAM_OVERRIDES"
echo '[{"org":"me","repo":"web"},{"org":"me"}]' > "$REPOS"; printf 'me/web\nother/api\nnot a repo\n' > "$TEAM_REPOS"
echo '{"projects":{"x":{"repo":"me/x"}}}' > "$TEAM_OVERRIDES"
expect "team_repo_list: merged, valid, once each" "$(team_repo_list extra/one me/web | tr '\n' ' ')" "extra/one me/web me/x other/api "
echo '{}' > "$REPOS"; rm -f "$TEAM_REPOS" "$TEAM_OVERRIDES"
expect "team_repo_list: none" "$(team_repo_list)" ""
rm -f "$PRICES"; expect "sv_rate: no price" "$(sv_rate vercel)" ""
echo '{"vercelUsdPerMinute":0.008}' > "$PRICES"
expect "sv_rate: from prices.json" "$(sv_rate vercel)" "0.008"
expect "sv_rate: the environment wins" "$(DEPLOYS_VERCEL_USD_PER_MIN=0.5 sv_rate vercel)" "0.5"
expect "sv_rate: another platform has none" "$(sv_rate render)" ""
expect "sv_rate: an unknown platform" "$(sv_rate netlify)" ""
rm -f "$RULES"; rules_on; expect "rules_on: no file" "$?" "1"
echo '{"rules":[{"name":"x","enabled":false}]}' > "$RULES"; rules_on; expect "rules_on: only disabled rules" "$?" "1"
echo '{"rules":[{"name":"x"}]}' > "$RULES"; rules_on; expect "rules_on: an enabled rule" "$?" "0"
echo '{"rules":"no"}' > "$RULES"; (rules_on) >/dev/null 2>&1; expect "rules_on: a file that cannot be read stops" "$?" "1"
rm -f "$RULES"

# --- freeze import: an ICS calendar becomes dates rules ---
ics="$tmp/cal.ics"
printf 'BEGIN:VCALENDAR\r\nBEGIN:VEVENT\r\nDTSTART;VALUE=DATE:20261224\r\nDTEND;VALUE=DATE:20261227\r\nSUMMARY:Holiday\r\n  freeze\r\nEND:VEVENT\r\nBEGIN:VEVENT\r\nDTSTART:20261201T150000\r\nDTEND:20261201T170000\r\nSUMMARY:Launch\r\nEND:VEVENT\r\nBEGIN:VEVENT\r\nDTSTART:20261202T230000Z\r\nDTEND:20261203T010000Z\r\nSUMMARY:Night\r\nEND:VEVENT\r\nBEGIN:VEVENT\r\nDTSTART;VALUE=DATE:20200101\r\nSUMMARY:Past\r\nEND:VEVENT\r\nBEGIN:VEVENT\r\nDTSTART;VALUE=DATE:20261230\r\nRRULE:FREQ=YEARLY\r\nSUMMARY:Yearly\r\nEND:VEVENT\r\nEND:VCALENDAR\r\n' > "$ics"
rm -f "$WINDOW"; echo '{"tz":"Europe/Berlin","deny":[]}' > "$WINDOW"
out="$(DEPLOYS_NOW="mon 10:00 2026-11-23" freeze_main import "$ics" 2>&1)"
expect "import: rules written, past and repeating events left out" "$(jq -c '[.deny[] | [(.dates|join(",")), (.from // ""), (.to // ""), (.reason // "")]]' "$WINDOW")" '[["2026-12-24,2026-12-25,2026-12-26","","","Holiday freeze"],["2026-12-01","15:00","17:00","Launch"],["2026-12-02,2026-12-03","","","Night"]]'
expect "import: tz stays" "$(jq -r .tz "$WINDOW")" "Europe/Berlin"
expect "import: says what it skipped" "$(echo "$out" | grep -c 'repeating')" "1"
DEPLOYS_NOW="mon 10:00 2026-11-23" freeze_main import "$ics" >/dev/null 2>&1
expect "import: a second import adds nothing" "$(jq '.deny | length' "$WINDOW")" "3"
expect "import: a day of an imported rule is closed" "$(DEPLOYS_NOW="fri 10:00 2026-12-25" window_json | jq -r .denied)" "true"
expect "import: a timed rule closes only its hours" "$(DEPLOYS_NOW="tue 18:00 2026-12-01" window_json | jq -r .denied):$(DEPLOYS_NOW="tue 16:00 2026-12-01" window_json | jq -r .denied)" "false:true"
echo "no calendar" > "$tmp/bad.ics"
expect "import: not a calendar is refused, file unchanged" "$( (freeze_main import "$tmp/bad.ics") 2>&1 | grep -c 'no calendar'):$(jq '.deny | length' "$WINDOW")" "1:3"
expect "import: a missing file is refused" "$( (freeze_main import "$tmp/none.ics") 2>&1 | grep -c 'Usage\|not found')" "1"
freeze_main status 2>&1 | grep -q "2026-12-24" ; expect "status: shows dates" "$?" "0"
rm -f "$WINDOW"

echo
[ "$fails" = 0 ] && echo "All round 12 CLI tests passed." || { echo "$fails failed."; exit 1; }
