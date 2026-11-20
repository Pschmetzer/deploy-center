#!/bin/bash
# Tests for the operations integrations: the status page (components, maintenance windows, JSON and Atom feed), the
# weekly/monthly report, the statistic badges, the Docker healthcheck and scheduler, and the Claude Code deploy hooks.
# Stand-ins and fixtures (tests/fixtures/ops), no network, no real projects and nothing is deployed.
# Run on its own (integrations/tests/ops.sh) or from integrations/tests/run.sh (--quiet).
set -uo pipefail
cd "$(dirname "$0")/.." || exit 1
here="$PWD"
fx="$here/tests/fixtures/ops"
fails=0 skips=0
ok()   { echo "ok   $1"; }
fail() { echo "FAIL $1: $2"; fails=$((fails+1)); }
skip() { echo "skip $1"; skips=$((skips+1)); }
expect()   { [ "$2" = "$3" ] && ok "$1" || fail "$1" "expected [$3], got [$2]"; }
contains() { case "$2" in *"$3"*) ok "$1" ;; *) fail "$1" "[$3] not in [$2]" ;; esac; }
lacks()    { case "$2" in *"$3"*) fail "$1" "[$3] found" ;; *) ok "$1" ;; esac; }

tmp="$(mktemp -d)"; trap 'rm -rf "$tmp"' EXIT
mkdir -p "$tmp/bin"

# --- stand-ins ---
# deploys: list, digest, and the reads of the hooks. Every call is logged; the log must never hold a deploy.
cat > "$tmp/bin/deploys" <<SH
#!/bin/bash
echo "\$*" >> "$tmp/calls.log"
case "\$*" in
  "list --json") cat "$fx/list.json" ;;
  "digest --days 7 --json") cat "$fx/digest-week.json" ;;
  "digest --days 7 --json --no-savings") jq 'del(.savings) | .savingsAsked = false' "$fx/digest-week.json" ;;
  "digest --days 14 --json --no-savings") cat "$fx/digest-two-weeks.json" ;;
  "digest --days 30 --json") jq '.days = 30' "$fx/digest-week.json" ;;
  "digest --days 30 --json --no-savings") jq '.days = 30 | del(.savings)' "$fx/digest-week.json" ;;
  "digest --days 60 --json --no-savings") cat "$fx/digest-two-weeks.json" ;;
  "risk app-web --json") echo '{"project":"app-web","platform":"vercel","level":"yellow","reasons":[{"level":"yellow","text":"a lockfile changed"}]}' ;;
  "window --json") echo '{"configured":true,"denied":true,"reason":"Friday freeze"}' ;;
  "changed --json") echo '[]' ;;
  *) echo "stand-in deploys: unexpected \$*" >&2; exit 2 ;;
esac
SH
chmod +x "$tmp/bin/deploys"
# curl: up for *.up.test, 503 otherwise (the status page's site check).
cat > "$tmp/bin/curl" <<'SH'
#!/bin/bash
for a in "$@"; do u="$a"; done
echo "$u" >> "${SP_CURL_LOG:?}"
case "$u" in *.up.test*) printf '200 0.050 ' ;; *) printf '503 0.050 ' ;; esac
SH
chmod +x "$tmp/bin/curl"
export DEPLOYS="$tmp/bin/deploys"

# ============ status page: components, maintenance, feeds ============
now=1799582400   # 2027-01-10 12:00 UTC
sp() { SP_CURL_LOG="$tmp/curl.log" PATH="$tmp/bin:$PATH" STATUSPAGE_NOW="$1" STATUSPAGE_RETRY_WAIT=0 DEPLOYS_JOURNAL="$fx/journal.jsonl" statuspage/statuspage.sh --config "$fx/statuspage-ops.json" --out "$2" --no-notes >/dev/null; }
: > "$tmp/curl.log"
sp "$now" "$tmp/sp1"; expect "statuspage: runs with components and maintenance" "$?" 0
st="$(cat "$tmp/sp1/status.json")"; page="$(cat "$tmp/sp1/index.html")"; atom="$(cat "$tmp/sp1/feed.xml")"; jf="$(cat "$tmp/sp1/feed.json")"
expect "statuspage: status.json keeps schema 1" "$(jq -r .schema <<<"$st")" 1
expect "statuspage: a project has its components, each checked alone" "$(jq -c '.projects[0].components | map([.name, .check.up])' <<<"$st")" '[["Pages",true],["Login",false]]'
expect "statuspage: each component address is checked once" "$(sort "$tmp/curl.log" | uniq -c | awk '{print $1}' | sort -u | tr '\n' ' ')" "1 2 "
contains "statuspage: the page lists the components" "$page" '<ul class="comps">'
expect "statuspage: maintenance windows: scheduled, and the one a week gone is dropped" "$(jq -c '[.maintenance[] | [.id, .state]]' <<<"$st")" '[["db-upgrade","scheduled"],["old-window-20270108","completed"]]'
expect "statuspage: a window names who it concerns" "$(jq -c '.maintenance[0].projects' <<<"$st")" '["API"]'
expect "statuspage: the project is not in maintenance before the window" "$(jq -c '[.projects[].maintenance]' <<<"$st")" '[false,false]'
contains "statuspage: the page has a maintenance section" "$page" "<h2 id=\"mt\">Maintenance</h2>"
contains "statuspage: title of the window is escaped" "$page" 'Database &lt;upgrade&gt;'
# During the window: the project is in maintenance, and its failed check is planned, not an outage.
sp 1799618700 "$tmp/sp2"   # 2027-01-10 22:05 UTC
st2="$(cat "$tmp/sp2/status.json")"; atom2="$(cat "$tmp/sp2/feed.xml")"
expect "statuspage: an active window puts the project in maintenance" "$(jq -c '[.projects[].maintenance]' <<<"$st2")" '[false,true]'
expect "statuspage: the window is active" "$(jq -r '.maintenance[0].state' <<<"$st2")" active
expect "statuspage: a check that fails during the window is marked planned" "$(jq -c '.projects[1].check | [.up, .maintenance]' <<<"$st2")" '[false,true]'
contains "statuspage: the card says planned maintenance" "$(cat "$tmp/sp2/index.html")" 'Not reachable during planned maintenance'
lacks "statuspage: no outage entry for the planned one" "$atom2" 'urn:deploy-center:check:render:API'
contains "statuspage: but the real outage of a component stays an entry" "$atom2" 'urn:deploy-center:check:vercel:Website:Login'
contains "statuspage: outside the window the API is an outage entry" "$atom" 'urn:deploy-center:check:render:API'
# The feeds: the same stable ids in both; a window keeps its id as its state changes.
mid() { grep -o 'urn:deploy-center:maintenance:[^<]*' <<<"$1" | head -1; }
expect "statuspage: the Atom id of a window is its configured id" "$(mid "$atom")" "urn:deploy-center:maintenance:db-upgrade"
expect "statuspage: the id does not change when the window starts" "$(mid "$atom2")" "$(mid "$atom")"
expect "statuspage: the JSON feed has the version" "$(jq -r .version <<<"$jf")" "https://jsonfeed.org/version/1.1"
expect "statuspage: the JSON feed has the same ids as the Atom feed" "$(jq -r '.items[].id' <<<"$jf" | sort | tr '\n' ' ')" "$(grep -o '<id>urn:deploy-center:[^<]*' <<<"$atom" | sed 's/<id>//' | sort | tr '\n' ' ')"
expect "statuspage: the JSON feed ids are unique" "$(jq -r '[.items[].id] | length == (unique | length)' <<<"$jf")" true
expect "statuspage: the JSON feed links itself" "$(jq -r '[.home_page_url, .feed_url] | join(" ")' <<<"$jf")" "https://status.example.test/ https://status.example.test/feed.json"
expect "statuspage: feed ids do not change between two runs" "$(jq -r '.items[].id' "$tmp/sp1/feed.json" | md5sum)" "$(sp "$now" "$tmp/sp1b"; jq -r '.items[].id' "$tmp/sp1b/feed.json" | md5sum)"
case "$jf$atom$st$page" in *SECRET*|*/Users/*|*"Secret launch"*|*sk_live*) fail "statuspage: nothing from the journal detail or messages" "found" ;; *) ok "statuspage: nothing from the journal detail or messages" ;; esac
expect "statuspage: the page links the JSON feed" "$(grep -c 'rel="alternate" type="application/feed+json"' "$tmp/sp1/index.html")" 1
if command -v xmllint >/dev/null; then
  xmllint --noout "$tmp/sp1/feed.xml" "$tmp/sp2/feed.xml" && ok "statuspage: both Atom feeds are well-formed XML" || fail "statuspage: both Atom feeds are well-formed XML" xmllint
else skip "statuspage: XML check needs xmllint"; fi
# Bad configs are refused, nothing is written.
for bad in '{"projects":["a"],"maintenance":[{"title":"x","start":"soon","end":"later"}]}' \
           '{"projects":["a"],"maintenance":[{"title":"x","start":"2027-01-02T10:00:00Z","end":"2027-01-02T09:00:00Z"}]}' \
           '{"projects":["a"],"maintenance":[{"title":"x","start":"2027-01-02T10:00:00Z","end":"2027-01-02T11:00:00Z","id":"a b"}]}' \
           '{"projects":[{"name":"a","components":[{"name":"x"}]}]}'; do
  echo "$bad" > "$tmp/bad.json"; rm -rf "$tmp/badout"
  PATH="$tmp/bin:$PATH" statuspage/statuspage.sh --config "$tmp/bad.json" --out "$tmp/badout" --no-check >/dev/null 2>&1; rc=$?
  [ "$rc" != 0 ] && [ ! -e "$tmp/badout/status.json" ] && ok "statuspage: refuses $(printf '%s' "$bad" | cut -c30-90)" || fail "statuspage: refuses a bad config" "rc=$rc $bad"
done
# A German page says the words in German.
jq '. + {lang:"de"}' "$fx/statuspage-ops.json" > "$tmp/sp-de.json"
SP_CURL_LOG="$tmp/curl.log" PATH="$tmp/bin:$PATH" STATUSPAGE_NOW=1799618700 DEPLOYS_JOURNAL="$fx/journal.jsonl" statuspage/statuspage.sh --config "$tmp/sp-de.json" --out "$tmp/spde" --no-notes >/dev/null
contains "statuspage: German maintenance" "$(cat "$tmp/spde/index.html")" 'Wartung'
contains "statuspage: German feed title" "$(cat "$tmp/spde/feed.xml")" 'Wartung: Database'

# ============ report: weekly and monthly, Markdown and HTML, a mail file ============
rp() { PATH="$tmp/bin:$PATH" DEPLOYS_REPORT_NOW="$now" digest/report.sh "$@"; }
: > "$tmp/calls.log"
rp --out "$tmp/rep" >/dev/null; expect "report: runs" "$?" 0
expect "report: Markdown and HTML are written, named by period and day" "$(cd "$tmp/rep" && echo *)" "deploy-report-week-2027-01-08.html deploy-report-week-2027-01-08.md"
md="$(cat "$tmp/rep/deploy-report-week-2027-01-08.md")"; html="$(cat "$tmp/rep/deploy-report-week-2027-01-08.html")"
contains "report: deploys, failures and the rate" "$md" '| Failure rate | 10 % | 20 % |'
contains "report: the period before is the two weeks minus this week" "$md" '| Deploys | 9 | 12 |'
contains "report: the busiest day" "$md" 'Busiest day: 2027-01-05 (4)'
contains "report: a project with no deploys has no rate" "$md" '| netlify | 0 | 0 | – |'
contains "report: the saving is an estimate in dollars" "$md" 'about $12.40 (42 builds skipped since auto-deploy went off on 2026-12-01). An estimate'
contains "report: Markdown special characters in names are escaped" "$md" 'x\|y\_\<z\>'
contains "report: HTML escapes names" "$html" 'x|y_&lt;z&gt;'
lacks "report: the error text of a failure is not in it by default" "$md$html" '/Users/me'
rp --out "$tmp/rep2" --details --format md >/dev/null
contains "report: --details adds the error text" "$(cat "$tmp/rep2"/*.md)" '/Users/me'
case "$(cat "$tmp/calls.log")" in *deploy\ *|*rollback*|*--yes*) fail "report: it only reads" "$(cat "$tmp/calls.log")" ;; *) ok "report: it only reads" ;; esac
rp --period month --print --no-savings | grep -q '^Period: .* (30 days)' && ok "report: a month is 30 days" || fail "report: a month is 30 days" "no 30 days line"
expect "report: --no-savings leaves the saving out (and says so)" "$(rp --print --no-savings | grep -c 'Not available')" 1
expect "report: German texts" "$(rp --print --lang de | grep -c '^| Fehlerquote')" 1
rp --out "$tmp/rep3" --format html --lang de >/dev/null
contains "report: German HTML has lang=de" "$(cat "$tmp/rep3"/*.html)" '<html lang="de">'
# The mail file: headers, both parts, encoded; and nothing sent.
rp --out "$tmp/rep4" --mail-file "$tmp/rep4/week.eml" --to "a@example.com,b@example.org" --from "deploys@example.com" --lang de --format md >/dev/null
eml="$(tr -d '\r' < "$tmp/rep4/week.eml")"
contains "report mail: From and To" "$eml" $'From: deploys@example.com\nTo: a@example.com,b@example.org'
contains "report mail: a non-ASCII subject is RFC 2047 encoded" "$eml" 'Subject: =?UTF-8?B?'
contains "report mail: MIME alternative with both parts" "$eml" 'Content-Type: multipart/alternative'
expect "report mail: a plain and an HTML part" "$(grep -c '^Content-Type: text/' <<<"$eml")" 2
expect "report mail: a date header in UTC" "$(grep '^Date:' <<<"$eml")" "Date: Sun, 10 Jan 2027 12:00:00 +0000"
plain="$(awk '/text\/plain/{f=1;next} f&&/^$/{g=1;next} g&&/^--/{exit} g{print}' <<<"$eml" | base64 -d 2>/dev/null)"
contains "report mail: the plain part is the Markdown report" "$plain" 'Fehlerquote'
for bad in 'x@example.com
Bcc: evil@example.com' 'not an address' 'a@b'; do
  rp --out "$tmp/rep5" --mail-file "$tmp/rep5/x.eml" --to "$bad" --from deploys@example.com >/dev/null 2>&1; rc=$?
  [ "$rc" != 0 ] && [ ! -e "$tmp/rep5/x.eml" ] && ok "report mail: refuses the address [$(printf '%s' "$bad" | head -1)]" || fail "report mail: refuses a bad address" "rc=$rc"
done
rp --out "$tmp/rep6" --mail-file "$tmp/rep6/x.eml" --to a@example.com >/dev/null 2>&1; [ "$?" != 0 ] && ok "report mail: --from is needed" || fail "report mail: --from is needed" "passed"
DEPLOYS=/bin/false digest/report.sh --out "$tmp/rep7" >/dev/null 2>&1; rc=$?
[ "$rc" = 1 ] && [ ! -d "$tmp/rep7" ] && ok "report: a CLI that fails writes nothing" || fail "report: a CLI that fails writes nothing" "rc=$rc"
digest/report.sh --days 400 >/dev/null 2>&1 && fail "report: --days is capped" "accepted" || ok "report: --days is capped"

# ============ badges: failure rate, saving, last deploy ============
bs() { BADGE_NOW="$now" PATH="$tmp/bin:$PATH" badge/stats.sh "$@"; }
bs "$tmp/bs" --days 7 --list "$fx/list.json" >/dev/null; expect "badge stats: runs" "$?" 0
expect "badge stats: three badges, each with an SVG and a shields JSON" "$(cd "$tmp/bs" && echo *)" "failure-rate.json failure-rate.svg last-deploy.json last-deploy.svg savings.json savings.svg"
expect "badge stats: failure rate" "$(jq -c '[.label, .message, .color]' "$tmp/bs/failure-rate.json")" '["failure rate","10 % (1 of 10, 7 d)","9a6700"]'
expect "badge stats: saving is an estimate" "$(jq -c '[.label, .message]' "$tmp/bs/savings.json")" '["saved (estimate)","~$12.40 saved"]'
expect "badge stats: the last deploy is the newest live time, in UTC" "$(jq -r '.message' "$tmp/bs/last-deploy.json")" "2027-01-03 18:13 UTC"
expect "badge stats: a deploy of the last week is green" "$(jq -r .color "$tmp/bs/last-deploy.json")" "2e7d32"
BADGE_NOW=$((1799000000 + 10 * 86400)) PATH="$tmp/bin:$PATH" badge/stats.sh "$tmp/bsold" --digest "$fx/digest-week.json" --list "$fx/list.json" >/dev/null
expect "badge stats: a deploy older than 7 days is yellow" "$(jq -r .color "$tmp/bsold/last-deploy.json")" "9a6700"
BADGE_NOW=$((1799000000 + 40 * 86400)) PATH="$tmp/bin:$PATH" badge/stats.sh "$tmp/bsold2" --digest "$fx/digest-week.json" --list "$fx/list.json" >/dev/null
expect "badge stats: a deploy older than 30 days is grey" "$(jq -r .color "$tmp/bsold2/last-deploy.json")" "6e6e6e"
contains "badge stats: the SVG says it" "$(cat "$tmp/bs/failure-rate.svg")" 'failure rate: 10 % (1 of 10, 7 d)'
expect "badge stats: schemaVersion and cache" "$(jq -c '[.schemaVersion, .cacheSeconds]' "$tmp/bs/savings.json")" '[1,300]'
jq '.deploys = 9 | .failures = 9' "$fx/digest-week.json" > "$tmp/d-red.json"
bs "$tmp/bs2" --digest "$tmp/d-red.json" --list "$fx/list.json" >/dev/null
expect "badge stats: a high rate is red and an error for shields" "$(jq -c '[.color, .isError]' "$tmp/bs2/failure-rate.json")" '["c0392b",true]'
jq '.deploys = 99 | .failures = 1 | .savings = null' "$fx/digest-week.json" > "$tmp/d-ok.json"
bs "$tmp/bs3" --digest "$tmp/d-ok.json" --list "$fx/list.json" >/dev/null
expect "badge stats: a low rate is green" "$(jq -r .color "$tmp/bs3/failure-rate.json")" 2e7d32
expect "badge stats: no saving known is grey" "$(jq -c '[.message, .color]' "$tmp/bs3/savings.json")" '["unknown","6e6e6e"]'
jq '.deploys = 0 | .failures = 0' "$fx/digest-week.json" > "$tmp/d-none.json"
bs "$tmp/bs4" --digest "$tmp/d-none.json" --list <(echo '[]') >/dev/null
expect "badge stats: no deploys: grey, and the last deploy is never" "$(jq -r '.message' "$tmp/bs4/failure-rate.json")|$(jq -r '.message' "$tmp/bs4/last-deploy.json")" "no deploys in 30 d|never"
bs "$tmp/bs5" --digest "$fx/digest-week.json" --list "$fx/list.json" --project api >/dev/null
expect "badge stats: a project's own rate" "$(jq -r .message "$tmp/bs5/failure-rate.json")" "0 % (0 of 3, 30 d)"
bs "$tmp/bs6" --digest "$fx/digest-week.json" --list "$fx/list.json" --no-savings >/dev/null
expect "badge stats: --no-savings writes two" "$(cd "$tmp/bs6" && echo *.svg)" "failure-rate.svg last-deploy.svg"
DEPLOYS=/bin/false badge/stats.sh "$tmp/bs7" >/dev/null 2>&1; rc=$?
[ "$rc" = 1 ] && [ ! -d "$tmp/bs7" ] && ok "badge stats: a CLI that fails writes no badge" || fail "badge stats: a CLI that fails writes no badge" "rc=$rc"
if command -v xmllint >/dev/null; then xmllint --noout "$tmp"/bs/*.svg && ok "badge stats: well-formed XML" || fail "badge stats: well-formed XML" xmllint; else skip "badge stats: XML check needs xmllint"; fi

# ============ Docker: healthcheck, scheduler, compose, Dockerfiles ============
hc() { PATH="$tmp/bin:$PATH" docker/healthcheck.sh; }
mkdir -p "$tmp/dd/providers"; touch "$tmp/dd/providers/vercel.sh"
cat > "$tmp/bin/okcli" <<'SH'
#!/bin/bash
[ "$1" = --version ] && echo "deploys 9.9.9"
SH
chmod +x "$tmp/bin/okcli"
hout="$(DEPLOYS="$tmp/bin/okcli" DEPLOYS_DIR="$tmp/dd" hc)"; expect "healthcheck: healthy with a CLI and providers" "$?|$hout" "0|healthy: deploys 9.9.9"
hout="$(DEPLOYS="$tmp/bin/missing" hc)"; expect "healthcheck: a missing CLI is unhealthy, with a reason" "$?|$hout" "1|unhealthy: $tmp/bin/missing is not installed"
hout="$(DEPLOYS="$tmp/bin/okcli" DEPLOYS_DIR="$tmp/empty" hc)"; expect "healthcheck: no providers is unhealthy" "$?" 1
echo 1799582400 > "$tmp/hb"
hout="$(DEPLOYS="$tmp/bin/okcli" DEPLOYS_HEARTBEAT_FILE="$tmp/hb" HEALTHCHECK_NOW=1799582500 hc)"; expect "healthcheck: a fresh heartbeat is healthy" "$?" 0
hout="$(DEPLOYS="$tmp/bin/okcli" DEPLOYS_HEARTBEAT_FILE="$tmp/hb" HEALTHCHECK_NOW=1799583000 hc)"; expect "healthcheck: a stale heartbeat is unhealthy and says how old" "$?|${hout#*heartbeat is }" "1|600 s old (more than 300)"
hout="$(DEPLOYS="$tmp/bin/okcli" DEPLOYS_HEARTBEAT_FILE="$tmp/nohb" hc)"; expect "healthcheck: no heartbeat file is unhealthy" "$?" 1

cat > "$tmp/jobs.conf" <<EOF
# a comment
every 30m out=$tmp/changed.json deploys changed --json
daily 07:30 out=$tmp/digest.txt deploys digest --days 7 --json
weekly mon 08:00 report --out $tmp/sched-rep --no-savings
EOF
sch() { DEPLOYS="$tmp/bin/deploys" DEPLOYS_INTEGRATIONS="$here" DEPLOYS_HEARTBEAT_FILE="$tmp/sched.hb" PATH="$tmp/bin:$PATH" DEPLOYS_REPORT_NOW="$now" docker/scheduler.sh "$@"; }
expect "scheduler: --check lists the jobs and runs nothing" "$(: > "$tmp/calls.log"; sch --jobs "$tmp/jobs.conf" --check | wc -l | tr -d ' ')|$(wc -c < "$tmp/calls.log" | tr -d ' ')" "3|0"
# 2027-01-04 is a Monday. 06:00 to 08:30 in steps of 30 minutes: 6 looks.
t0=1799042400
: > "$tmp/calls.log"
SCHEDULER_NOW="$t0" SCHEDULER_STEP=1800 sch --jobs "$tmp/jobs.conf" --ticks 6 >"$tmp/sched.out" 2>&1
expect "scheduler: the 30 minute job runs at every look" "$(grep -c '^changed --json' "$tmp/calls.log")" 6
expect "scheduler: the daily job runs once, from 07:30 on" "$(grep -c '^digest --days 7 --json$' "$tmp/calls.log")" 1
contains "scheduler: the daily job ran at 07:30" "$(cat "$tmp/sched.out")" '[2027-01-04T07:30:00Z] job 2 start'
contains "scheduler: the weekly Monday job ran at 08:00" "$(cat "$tmp/sched.out")" '[2027-01-04T08:00:00Z] job 3 start'
expect "scheduler: the weekly job ran once" "$(grep -c 'job 3 start' "$tmp/sched.out")" 1
expect "scheduler: out= writes the job's output to the file" "$(jq -c . "$tmp/changed.json")" '[]'
[ -z "$(ls "$tmp"/changed.json.* 2>/dev/null)" ] && ok "scheduler: no temp file is left" || fail "scheduler: no temp file is left" "$(ls "$tmp"/changed.json.*)"
expect "scheduler: the weekly report is written" "$(ls "$tmp/sched-rep" | wc -l | tr -d ' ')" 2
expect "scheduler: the heartbeat is the last look" "$(cat "$tmp/sched.hb")" "$((t0 + 5 * 1800))"
SCHEDULER_NOW="$t0" SCHEDULER_STEP=1800 sch --jobs "$tmp/jobs.conf" --ticks 1 >"$tmp/sched1.out" 2>&1
expect "scheduler: the first look runs the every-job and not the daily one before its time" "$(grep -c 'start' "$tmp/sched1.out")" 1
# Anything that deploys is refused when the file is read, before a job runs.
printf 'every 5m deploys deploy app-web\n' > "$tmp/bad1.conf"
printf 'every 5m deploys changed --yes\n' > "$tmp/bad2.conf"
printf 'every 5m deploys deploy-changed --yes\n' > "$tmp/bad3.conf"
printf 'every 5m deploys rollback app-web\n' > "$tmp/bad4.conf"
printf 'every 5m sh -c "echo hi"\n' > "$tmp/bad5.conf"
printf 'every 5s deploys changed\n' > "$tmp/bad6.conf"
printf 'daily 25:00 deploys changed\n' > "$tmp/bad7.conf"
printf 'every 5m deploys changed\nevery 5m deploys deploy x\n' > "$tmp/bad8.conf"
for i in 1 2 3 4 5 6 7 8; do
  : > "$tmp/calls.log"
  SCHEDULER_NOW="$t0" sch --jobs "$tmp/bad$i.conf" --ticks 1 >/dev/null 2>&1; rc=$?
  [ "$rc" = 1 ] && [ ! -s "$tmp/calls.log" ] && ok "scheduler: refuses $(tr '\n' '/' < "$tmp/bad$i.conf")" || fail "scheduler: refuses bad$i.conf" "rc=$rc calls=$(cat "$tmp/calls.log")"
done
printf 'every 5m deploys changed --json\n' > "$tmp/one.conf"
: > "$tmp/calls.log"; sch --jobs "$tmp/one.conf" --once >/dev/null 2>&1; expect "scheduler: --once runs each job and exits" "$?|$(cat "$tmp/calls.log")" "0|changed --json"
printf 'every 5m deploys doctor\n' > "$tmp/fail.conf"
sch --jobs "$tmp/fail.conf" --once >/dev/null 2>&1; expect "scheduler: a failing job is exit 1 with --once (the stand-in exits 2)" "$?" 1
expect "scheduler: the example schedule is valid" "$(DEPLOYS_INTEGRATIONS="$here" docker/scheduler.sh --jobs docker/jobs.example.conf --check >/dev/null 2>&1; echo $?)" 0
# The files of the image.
grep -q '^HEALTHCHECK' docker/Dockerfile && ok "docker: the image has a HEALTHCHECK" || fail "docker: the image has a HEALTHCHECK" missing
grep -q '^HEALTHCHECK' docker/Dockerfile.cron && ok "docker: the cron image has a HEALTHCHECK" || fail "docker: the cron image has a HEALTHCHECK" missing
grep -q 'healthcheck.sh' docker/Dockerfile.dockerignore && ok "docker: the healthcheck is in the build context" || fail "docker: the healthcheck is in the build context" missing
grep -q 'scheduler.sh' docker/Dockerfile.cron.dockerignore && ok "docker: the scheduler is in the cron build context" || fail "docker: the scheduler is in the cron build context" missing
[ "$(grep '^USER ' docker/Dockerfile.cron | tail -n 1)" = "USER node" ] && ok "docker: the cron image ends as the unprivileged user" || fail "docker: the cron image ends as the unprivileged user" "$(grep '^USER ' docker/Dockerfile.cron | tail -n 1)"
grep -q 'ENTRYPOINT \["deploys-scheduler"\]' docker/Dockerfile.cron && ok "docker: the cron image starts the scheduler" || fail "docker: the cron image starts the scheduler" missing
expect "docker: the healthcheck calls no network tool" "$(grep -E '^[^#]*curl' docker/healthcheck.sh | grep -vc 'command -v')" 0
expect "docker: the compose file passes keys by name, not by value" "$(grep -cE '^\s+- (VERCEL_TOKEN|RENDER_API_KEY|GH_TOKEN)$' docker/compose.example.yml)" 6
expect "docker: no key has a value in the examples" "$(grep -ciE '(token|api_key)=[^ ]' docker/compose.example.yml docker/jobs.example.conf | awk -F: '{s+=$2} END {print s+0}')" 0
if command -v docker >/dev/null && docker compose version >/dev/null 2>&1; then
  mkdir -p "$tmp/cc" && cp docker/compose.example.yml "$tmp/cc/" && (cd "$tmp/cc" && docker compose -f compose.example.yml config -q 2>/dev/null) && ok "docker: the compose example is valid" || fail "docker: the compose example is valid" "docker compose config"
else skip "docker: the compose check needs docker compose"; fi

# ============ Claude Code: the deploy hooks and the two skills ============
plug="$here/claude-code"
bd="$plug/scripts/before-deploy.sh" af="$plug/scripts/after-failure.sh"
pre() { jq -cn --arg c "$1" '{hook_event_name:"PreToolUse", tool_name:"Bash", tool_input:{command:$c}, cwd:"/tmp"}' | PATH="$tmp/bin:$PATH" "$bd"; }
: > "$tmp/calls.log"
o="$(pre 'deploys deploy app-web --wait')"
expect "hook before: a deploy is answered with ask" "$(jq -r '.hookSpecificOutput | [.hookEventName, .permissionDecision] | join(" ")' <<<"$o")" "PreToolUse ask"
r="$(jq -r .hookSpecificOutput.permissionDecisionReason <<<"$o")"
contains "hook before: the question names the project" "$r" 'a deploy to production of app-web'
contains "hook before: the question carries the risk" "$r" 'Risk: yellow (a lockfile changed).'
contains "hook before: the question carries the closed window" "$r" 'Deploy window: closed (Friday freeze).'
contains "hook before: it points to the precheck" "$r" '/deploy-center:deploys-precheck app-web'
expect "hook before: it only read (risk and window)" "$(sort -u "$tmp/calls.log" | tr '\n' '|')" "risk app-web --json|window --json|"
for c in 'cd /srv/app && deploys deploy app-web' 'deploys vercel deploy app-web' 'bash -c "deploys deploy app-web"' 'FOO=1 /usr/local/bin/deploys deploy-changed --yes' 'deploys rollback app-web' 'git pull; deploys deploy app-web --wait'; do
  [ -n "$(pre "$c")" ] && ok "hook before: asks for [$c]" || fail "hook before: asks for [$c]" "silent"
done
for c in 'deploys deploy app-web --dry-run' 'deploys deploy-changed' 'deploys deploy-changed --json' 'deploys changed --json' 'deploys status' 'echo deploys deploy app-web' 'git commit -m "deploys deploy x"' 'ls' 'deploys logs app-web' 'deploys verify app-web --no-rollback'; do
  [ -z "$(pre "$c")" ] && ok "hook before: silent for [$c]" || fail "hook before: silent for [$c]" "$(pre "$c")"
done
o="$(pre 'deploys deploy-changed --yes')"; contains "hook before: deploy-changed says every project" "$(jq -r .hookSpecificOutput.permissionDecisionReason <<<"$o")" 'every project that has changes waiting'
o="$(pre 'deploys deploy "x; rm -rf ~"')"
lacks "hook before: a project word that is not a plain name is not repeated" "$o" 'rm -rf'
o="$(pre 'deploys rollback app-web')"; lacks "hook before: a rollback reads no risk" "$(jq -r .hookSpecificOutput.permissionDecisionReason <<<"$o")" 'Risk:'
expect "hook before: off with DEPLOYS_DEPLOY_GATE=off" "$(DEPLOYS_DEPLOY_GATE=off pre 'deploys deploy app-web')" ""
expect "hook before: off with the plugin option" "$(CLAUDE_PLUGIN_OPTION_DEPLOY_GATE=false pre 'deploys deploy app-web')" ""
o="$(DEPLOYS="$tmp/bin/nothing" pre 'deploys deploy app-web')"
expect "hook before: without a CLI it still asks" "$(jq -r '.hookSpecificOutput.permissionDecision' <<<"$o")" ask
lacks "hook before: and states no risk it did not read" "$o" 'Risk:'
printf '#!/bin/bash\nsleep 30.31\n' > "$tmp/bin/slow"; chmod +x "$tmp/bin/slow"
s0=$SECONDS; o="$(DEPLOYS="$tmp/bin/slow" DEPLOYS_HOOK_TIMEOUT=1 pre 'deploys deploy app-web')"; took=$((SECONDS - s0))
[ "$took" -le 6 ] && [ -n "$o" ] && ok "hook before: a CLI that hangs is given up on (asks after ${took}s)" || fail "hook before: a CLI that hangs is given up on" "took ${took}s, out=[$o]"
pkill -f 'sleep 30.31' 2>/dev/null || true
echo 'not json' | "$bd"; expect "hook before: bad input is silent and exit 0" "$?" 0
case "$(jq -c '.hookSpecificOutput.permissionDecision' <<<"$(pre 'deploys deploy app-web')")" in '"ask"') ok "hook before: the only decision it ever gives is ask" ;; *) fail "hook before: the only decision is ask" "other" ;; esac
expect "hook before: the script names no decision but ask" "$(grep -oE 'permissionDecision: *"[a-z]*"' "$bd" | sort -u | tr -d ' ')" 'permissionDecision:"ask"' 

fl() { jq -cn --arg ev "$1" --arg c "$2" --arg out "${3:-}" '{hook_event_name:$ev, tool_name:"Bash", tool_input:{command:$c}, tool_response:{stdout:$out, stderr:"", interrupted:false}, error:"exit 1"}' | "$af"; }
: > "$tmp/calls.log"
o="$(fl PostToolUseFailure 'deploys deploy app-web --wait')"
expect "hook after: a failed deploy is named" "$(jq -r .systemMessage <<<"$o")" "Deploy Center: app-web failed. Read the log, read-only: /deploy-center:deploys-diagnose app-web"
expect "hook after: the event name is echoed" "$(jq -r .hookSpecificOutput.hookEventName <<<"$o")" PostToolUseFailure
contains "hook after: Claude is told not to deploy again or change code" "$(jq -r .hookSpecificOutput.additionalContext <<<"$o")" 'Do not deploy again, do not roll back and do not change code unless the user says so.'
contains "hook after: the log command is read-only" "$(jq -r .hookSpecificOutput.additionalContext <<<"$o")" 'deploys logs app-web'
expect "hook after: it calls nothing" "$(wc -c < "$tmp/calls.log" | tr -d ' ')" 0
o="$(fl PostToolUse 'deploys deploy app-web' 'Deploy of app-web failed: build error')"
expect "hook after: a PostToolUse whose output says failed counts" "$(jq -r .hookSpecificOutput.hookEventName <<<"$o")" PostToolUse
expect "hook after: a PostToolUse that went well is silent" "$(fl PostToolUse 'deploys deploy app-web' 'app-web is live')" ""
expect "hook after: a command that is no deploy is silent" "$(fl PostToolUseFailure 'npm run build')" ""
expect "hook after: a dry run is silent" "$(fl PostToolUseFailure 'deploys deploy app-web --dry-run')" ""
expect "hook after: a failed read is silent" "$(fl PostToolUseFailure 'deploys logs app-web')" ""
o="$(fl PostToolUseFailure 'deploys deploy-changed --yes')"; contains "hook after: no project: the status command" "$(jq -r .hookSpecificOutput.additionalContext <<<"$o")" 'deploys status --json'
o="$(fl PostToolUseFailure 'deploys rollback app-web')"; contains "hook after: a rollback that failed says so" "$(jq -r .systemMessage <<<"$o")" 'did not work'
expect "hook after: interrupted by the user is silent" "$(jq -cn '{hook_event_name:"PostToolUseFailure", tool_input:{command:"deploys deploy app-web"}, is_interrupt:true}' | "$af")" ""
expect "hook after: off with DEPLOYS_FAILURE_HINT=off" "$(DEPLOYS_FAILURE_HINT=off fl PostToolUseFailure 'deploys deploy app-web')" ""
o="$(fl PostToolUseFailure 'deploys deploy "x; rm -rf ~"')"; lacks "hook after: a project word that is not a plain name is not repeated" "$o" 'rm -rf'
echo 'not json' | "$af"; expect "hook after: bad input is silent and exit 0" "$?" 0
# Registered, executable, and the manifest has the options.
hooks="$plug/hooks/hooks.json"
expect "hooks.json: PreToolUse runs before-deploy.sh on Bash" "$(jq -r '.hooks.PreToolUse[0] | [.matcher, (.hooks[0].command | test("before-deploy.sh"))] | join(" ")' "$hooks")" "Bash true"
expect "hooks.json: PostToolUseFailure and PostToolUse run after-failure.sh" "$(jq -r '[.hooks.PostToolUseFailure[0].hooks[0].command, .hooks.PostToolUse[1].hooks[0].command] | map(test("after-failure.sh")) | join(" ")' "$hooks")" "true true"
expect "hooks.json: the push hook stays first" "$(jq -r '.hooks.PostToolUse[0].hooks[0].command | test("after-push.sh")' "$hooks")" true
expect "plugin.json: deploy_gate and failure_hint are on by default" "$(jq -r '[.userConfig.deploy_gate.default, .userConfig.failure_hint.default] | join(" ")' "$plug/.claude-plugin/plugin.json")" "true true"
for f in before-deploy.sh after-failure.sh deploys-call.sh; do [ -x "$plug/scripts/$f" ] && ok "plugin: scripts/$f is executable" || fail "plugin: scripts/$f is executable" "not +x"; done
# The skills: format, read-only, and no deploy command in allowed-tools.
for s in deploys-precheck deploys-diagnose; do
  f="$plug/skills/$s/SKILL.md"; fm="$(awk 'NR==1{next} /^---$/{exit} {print}' "$f")"
  [ "$(head -1 "$f")" = --- ] && grep -qE '^description: .{20,}' <<<"$fm" && ok "skill $s: has frontmatter and a description" || fail "skill $s: has frontmatter and a description" "missing"
  grep -q '^disable-model-invocation: true' "$f" && ok "skill $s: only the user runs it" || fail "skill $s: only the user runs it" "model-invocable"
  tools="$(sed -nE 's/^allowed-tools: *//p' <<<"$fm")"
  case "$tools" in *deploy-changed*|*"deploys deploy"*|*rollback*|*autodeploy*|*guard*|*autofix*|*verify*|*cancel*|*ignore*) fail "skill $s: reading commands only" "$tools" ;; *) ok "skill $s: reading commands only" ;; esac
  bad=""; for c in $(grep -oE 'Bash\(deploys [a-z-]+' <<<"$tools" | sed 's/Bash(deploys //'); do grep -qE "^#   deploys $c( |\$)" "$here/../deploys" || bad="$bad $c"; done
  [ -z "$bad" ] && ok "skill $s: every command in allowed-tools exists in deploys" || fail "skill $s: every command in allowed-tools exists" "$bad"
  grep -q 'That is not one project name' "$f" && ok "skill $s: refuses a project word that is not a plain name" || fail "skill $s: refuses a bad project word" missing
done
grep -q 'Do not edit files' "$plug/skills/deploys-diagnose/SKILL.md" && ok "skill deploys-diagnose: changes nothing" || fail "skill deploys-diagnose: changes nothing" missing
grep -q 'deploy-changed. itself' "$plug/skills/deploys-precheck/SKILL.md" && ok "skill deploys-precheck: never deploy-changed" || fail "skill deploys-precheck: never deploy-changed" missing

[ "${1:-}" = --quiet ] || { echo; if [ "$skips" -gt 0 ]; then echo "$skips skipped."; fi; [ "$fails" = 0 ] && echo "All passed." || echo "$fails failed."; }
[ "$fails" = 0 ]
