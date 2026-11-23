#!/bin/bash
# Tests for the round-10 fixes in `deploys`, lib/ and providers/: file modes, options, one risk list, token shapes,
# paging, hooks, traps, escapes. No network, no real projects. Run: tests/welle10-tests.sh
set -uo pipefail
cd "$(dirname "$0")/.." || exit 1
exec </dev/null
fails=0
ok()   { echo "ok   $1"; }
fail() { echo "FAIL $1: $2"; fails=$((fails+1)); }
expect() { [ "$2" = "$3" ] && ok "$1" || fail "$1" "expected [$3], got [$2]"; }

tmp="$(mktemp -d)"; trap 'rm -rf "$tmp"' EXIT
export DEPLOYS_CONFIG="$tmp/config" DEPLOYS_LIB=1 DEPLOYS_TESTING=1 HOME="$tmp/home" NO_COLOR=1
mkdir -p "$HOME" "$DEPLOYS_CONFIG" "$tmp/bin"
# gh and curl stand in, so nothing here reaches a network.
printf '#!/bin/bash\nexit 1\n' > "$tmp/bin/gh"; chmod +x "$tmp/bin/gh"
export PATH="$tmp/bin:$PATH"
# shellcheck source=../deploys
. ./deploys
set +e   # deploys sets -e; the tests look at failures themselves
cli() { env -u DEPLOYS_LIB bash ./deploys "$@"; }

# --- metrics --out: readable by the account that scrapes it (644, not mktemp's 0600) ---
echo '{"enabled":[]}' > "$DEPLOYS_CONFIG/providers.json"
cli metrics --out "$tmp/m.prom" >/dev/null 2>&1
expect "metrics --out: the file is 644" "$(ls -l "$tmp/m.prom" 2>/dev/null | cut -c1-10)" "-rw-r--r--"

# --- changed --platform with that platform off: an error that says how to turn it on, not "Nothing to deploy" ---
out="$(cli changed --platform netlify 2>&1)"; rc=$?
expect "changed --platform <off>: exit 1" "$rc" "1"
expect "changed --platform <off>: says it is off and how to turn it on" "$(grep -c 'is off. Turn it on: deploys providers enable netlify' <<<"$out")" "1"
expect "changed --platform <off>: no 'Nothing to deploy'" "$(grep -c 'Nothing to deploy' <<<"$out")" "0"

# --- watch a <id> --and b: a deploy id belongs to one project ---
out="$(cli watch a dpl_123 --and b 2>&1)"; rc=$?
expect "watch --and with a deploy id: refused" "$rc:$(grep -c 'A deploy id belongs to one project' <<<"$out")" "1:1"
out="$(cli watch a --and b --timeout 1s --preview 2>&1 | grep -c 'deploy id belongs')"
expect "watch --and: --timeout's value is not taken for an id" "$out" "0"

# --- log rotation: the cron line writes to ~/.local/state, which rotates too ---
mkdir -p "$HOME/.local/state" "$HOME/Library/Logs"
head -c 200 /dev/zero | tr '\0' x > "$HOME/.local/state/deploys-DeployCenter-daily.log"
head -c 200 /dev/zero | tr '\0' x > "$HOME/Library/Logs/DeployCenter-daily.log"
DEPLOYS_LOG_ROTATE=1 DEPLOYS_LOG_MAX_BYTES=100 log_rotate DeployCenter-daily
expect "log_rotate: the launchd log and the cron log both rotate" \
  "$([ -f "$HOME/Library/Logs/DeployCenter-daily.log.1" ] && echo a)$([ -f "$HOME/.local/state/deploys-DeployCenter-daily.log.1" ] && echo b)" "ab"
head -c 20 /dev/zero | tr '\0' x > "$HOME/.local/state/deploys-DeployCenter-daily.log"
DEPLOYS_LOG_ROTATE=1 DEPLOYS_LOG_MAX_BYTES=100 log_rotate DeployCenter-daily
expect "log_rotate: a small log stays" "$([ -f "$HOME/.local/state/deploys-DeployCenter-daily.log" ] && echo stays)" "stays"

# --- one list of risky files: risk and details .risky come from the same regexes ---
files='{"files":[{"filename":"prisma/migrations/1/x.sql"},{"filename":"package.json"},{"filename":"yarn.lock"},{"filename":".env.production"},{"filename":"vercel.json"},{"filename":".github/workflows/ci.yml"},{"filename":"src/app.ts"},{"filename":"README.md"}]}'
expect "risky_files: migrations, dependency files, env, config" \
  "$(echo "$files" | jq -c "$RISK_DEF"' risky_files')" '["prisma/migrations/1/x.sql","package.json","yarn.lock",".env.production","vercel.json",".github/workflows/ci.yml"]'
expect "risk: every risky file is named by some reason (the two lists agree)" \
  "$(echo "$files" | jq -c "$RISK_DEF"' . as $d | ([risk.reasons[].files[]] | sort) == (risky_files | sort)')" "true"
# 300 files is what GitHub lists at most: the answer is a floor, said so.
many="$(jq -nc '{files:[range(0;300) | {filename:"f\(.).txt", additions:1, deletions:0}]}')"
expect "risk: 300 files is partial" "$(echo "$many" | jq -c "$RISK_DEF"' risk | [.partial, .level]')" '[true,"red"]'
expect "risk: 20 files is not partial" "$(echo '{"files":[{"filename":"a"}]}' | jq -c "$RISK_DEF"' risk | .partial')" "false"
cmp300="$(jq -nc '{files:[range(0;300) | {filename:"f\(.).txt", additions:1, deletions:0, patch:"@@ -0,0 +1 @@\n+hello"}]}')"
expect "secret scan: 300 files is partial, not clean" "$(echo "$cmp300" | jq -c "$SECRETS_JQ"' | [.secrets, .secretsPartial]')" '[[],true]'
expect "secret scan: a small clean diff is clean" "$(echo '{"files":[{"filename":"a","patch":"@@ -0,0 +1 @@\n+hello"}]}' | jq -c "$SECRETS_JQ"' | .secretsPartial')" "false"
expect "secret scan: a file without its patch (too big) is partial" "$(echo '{"files":[{"filename":"a","changes":900}]}' | jq -c "$SECRETS_JQ"' | .secretsPartial')" "true"

# --- token shapes: the masker and the diff scan know the newer ones ---
masked="$(af_mask < tests/fixtures/mask/secrets-new.txt)"
expect "mask: no newer token shape survives" "$(grep -c SECRET <<<"$masked")" "0"
expect "mask: the same number of lines stays" "$(wc -l < tests/fixtures/mask/secrets-new.txt | tr -d ' ')" "$(wc -l <<<"$masked" | tr -d ' ')"
patch="$(awk 'BEGIN{printf "@@ -0,0 +1,%d @@\\n", 0} {printf "+%s\\n", $0}' tests/fixtures/mask/secrets-new.txt)"
n="$(wc -l < tests/fixtures/mask/secrets-new.txt | tr -d ' ')"
found="$(jq -nc --arg p "$(printf '@@ -0,0 +1,%s @@\n' "$n"; sed 's/^/+/' tests/fixtures/mask/secrets-new.txt)" '{files:[{filename:"x.env", patch:$p}]}' | jq -c "$SECRETS_JQ"' | [.secrets[].kind] | unique')"
for k in vercel-token cloudflare-token heroku-key fly-token digitalocean-token gitlab-token npm-token render-key; do
  expect "secret scan: $k is found" "$(jq -r --arg k "$k" 'index($k) != null' <<<"$found")" "true"
done
: "$patch"

# --- ci_of reads every page of the combined status ---
cat > "$tmp/bin/gh" <<'GH'
#!/bin/bash
case "$*" in
  *"/status?per_page=100"*) echo '{"state":"success","statuses":[{"context":"ci/a","state":"success"}]}'; echo '{"state":"success","statuses":[{"context":"ci/b","state":"failure"}]}' ;;
  *"/check-runs?per_page=100"*) echo '{"total_count":0,"check_runs":[]}' ;;
  *) exit 1 ;;
esac
GH
chmod +x "$tmp/bin/gh"
expect "ci_of: a red status on the second page is red" "$(ci_of me/app abc123 | jq -c '[.state, .checks, .failed]')" '["red",2,1]'
printf '#!/bin/bash\nexit 1\n' > "$tmp/bin/gh"

# --- verify: --watch-timeout is checked, and named in the usage ---
out="$(cli verify web --watch-timeout soon 2>&1)"; rc=$?
expect "verify --watch-timeout: a bad time is refused (exit 3, nothing checked)" "$rc:$(grep -c -- '--watch-timeout takes a time' <<<"$out")" "3:1"
expect "verify: the usage names --watch-timeout" "$(cli verify web --nope 2>&1 | grep -c -- '--watch-timeout 30m')" "1"

# --- schedule daily: more options go on, --weekdays means Monday to Friday ---
mkdir -p "$tmp/lc" "$tmp/agents"
printf '#!/bin/bash\nexit 0\n' > "$tmp/lc/launchctl"; chmod +x "$tmp/lc/launchctl"
sd() { PATH="$tmp/lc:$PATH" DEPLOYS_LAUNCH_DIR="$tmp/agents" cli schedule daily "$@"; }
out="$(sd 08:15 --weekdays --when-green --only web --exclude api --platform vercel --max 3 --wait 20m --wait-for-window 2h 2>&1)"
plist="$tmp/agents/app.deploycenter.daily.plist"
expect "schedule daily: the options are in the job" \
  "$(grep -c '<string>deploy-changed</string><string>--yes</string><string>--when-green</string><string>--only</string><string>web</string><string>--exclude</string><string>api</string><string>--platform</string><string>vercel</string><string>--max</string><string>3</string><string>--wait</string><string>20m</string><string>--wait-for-window</string><string>2h</string>' "$plist")" "1"
expect "schedule daily --weekdays: five calendar entries, Monday to Friday, at 08:15" \
  "$(grep -o '<key>Weekday</key><integer>[1-5]</integer><key>Hour</key><integer>8</integer><key>Minute</key><integer>15</integer>' "$plist" | wc -l | tr -d ' ')" "5"
expect "schedule daily: saved with its options and the weekdays" "$(jq -c '.daily | [.at, .weekdays, .args[0:2]]' "$DEPLOYS_CONFIG/schedule.json" 2>/dev/null)" '["08:15",true,["--when-green","--only"]]'
expect "schedule daily: the message says weekday" "$(grep -c 'every weekday (Monday to Friday) at 08:15' <<<"$out")" "1"
rm -f "$plist"
sd 07:00 >/dev/null 2>&1
expect "schedule daily: without --weekdays one calendar entry, no Weekday" "$(grep -c '<key>Weekday</key>' "$plist"):$(grep -c '<key>StartCalendarInterval</key><dict>' "$plist")" "0:1"
for bad in "--only" "--max 0" "--max x" "--wait soon" "--platform nope" "--nope" "--only a/b"; do
  # shellcheck disable=SC2086  # the words are the point
  rc=0; sd 09:00 $bad >/dev/null 2>&1 || rc=$?
  want=1; [ "$bad" != "--nope" ] || want=2   # an unknown option is a wrong call
  expect "schedule daily: [$bad] is refused" "$rc" "$want"
done
mkdir -p "$tmp/nolc"; for b in sed dirname basename; do ln -sf "$(command -v "$b")" "$tmp/nolc/$b"; done
# shellcheck disable=SC2123  # a PATH without launchctl is the point
expect "schedule daily --weekdays without launchd: a cron line for 1-5" \
  "$( (PATH="$tmp/nolc"; JOB_WEEKDAYS=1 job_on app.deploycenter.daily @07:30 DeployCenter-daily deploy-changed --yes) | grep -c '^30 7 \* \* 1-5 mkdir -p ')" "1"

# --- names for completion: plain ASCII only, in any locale ---
printf '%s\n' '[]' > "$DEPLOYS_CONFIG/names.json"
printf '%s' '[{"name":"web-1","id":"1"},{"name":"app.v2","id":"2"},{"name":"$(touch '"$tmp"'/pwn)","id":"3"},{"name":"a`b","id":"4"},{"name":"x;y","id":"5"}]' | LC_ALL=C remember_names vercel
expect "names: plain names are kept, shell syntax is not" "$(paste -sd, "$DEPLOYS_CONFIG/names")" "app.v2,web-1"
expect "names: nothing ran" "$([ -e "$tmp/pwn" ] && echo ran || echo clean)" "clean"

# --- team add: parallel adds lose none ---
cat > "$tmp/bin/gh" <<'GH'
#!/bin/bash
sleep 0.2; exit 1
GH
for i in 1 2 3 4 5 6; do cli team add "me/repo$i" >/dev/null 2>&1 & done
wait
expect "team add: six at once, six repos" "$(sort -u "$DEPLOYS_CONFIG/team-repos" 2>/dev/null | wc -l | tr -d ' ')" "6"
expect "team add: no lock left behind" "$(ls -d "$DEPLOYS_CONFIG"/team-repos.lock 2>/dev/null | wc -l | tr -d ' ')" "0"
printf '#!/bin/bash\nexit 1\n' > "$tmp/bin/gh"

# --- the journal: a forced start that did not happen is written; a write that fails is said ---
export DEPLOYS_JOURNAL="$tmp/j.jsonl"
export frozen="Friday freeze" force_reason="hotfix"   # read by journal_forced
journal_forced vercel web failed
expect "journal_forced: a start that failed is in the journal" "$(jq -r '[.result, (.detail | contains("did not start"))] | join(":")' "$DEPLOYS_JOURNAL")" "forced:true"
: > "$DEPLOYS_JOURNAL"; journal_forced vercel web
expect "journal_forced: a start that happened says deployed" "$(jq -r '.detail | startswith("Deployed in the window")' "$DEPLOYS_JOURNAL")" "true"
chmod 444 "$DEPLOYS_JOURNAL"
if [ "$(id -u)" != 0 ]; then
  expect "journal_add: a file that cannot be written gives a warning" "$(journal_add vercel web live x 2>&1 >/dev/null | grep -c 'could not write the history')" "1"
else ok "journal_add: warning (skipped as root)"; fi
chmod 644 "$DEPLOYS_JOURNAL"
unset DEPLOYS_JOURNAL frozen force_reason

# --- with_timeout: without perl, timeout or gtimeout does it ---
mkdir -p "$tmp/tb"
printf '#!/bin/bash\necho "timeout $*"\n' > "$tmp/tb/timeout"; chmod +x "$tmp/tb/timeout"
printf '#!/bin/bash\necho hello\n' > "$tmp/tb/hello"; chmod +x "$tmp/tb/hello"
# shellcheck disable=SC2123  # a PATH without perl is the point
expect "with_timeout: no perl, timeout is used" "$( (PATH="$tmp/tb"; with_timeout 5 hello) )" "timeout 5 hello"
rm "$tmp/tb/timeout"; printf '#!/bin/bash\necho "gtimeout $*"\n' > "$tmp/tb/gtimeout"; chmod +x "$tmp/tb/gtimeout"
# shellcheck disable=SC2123
expect "with_timeout: no perl and no timeout, gtimeout is used" "$( (PATH="$tmp/tb"; with_timeout 5 hello) )" "gtimeout 5 hello"
rm "$tmp/tb/gtimeout"
# shellcheck disable=SC2123
expect "with_timeout: none of them, the command runs as it is" "$( (PATH="$tmp/tb"; with_timeout 5 hello) )" "hello"

# --- terminal escapes in a log never reach a terminal ---
printf 'build\033]0;pwned\007 ok\n\033[31mred\033[0m \033[2Jcleared\r\nbell\007 tab\there\n\033Pdevice\033\\after\n' > "$tmp/esc.log"
cp "$tmp/esc.log" "$tmp/esc.raw"
DEPLOYS_STRIP_ESC=1 log_clean "$tmp/esc.log"
expect "log_clean: escapes, bells and returns are gone, text and tabs stay" "$(cat "$tmp/esc.log")" $'build ok\nred cleared\nbell tab\there\nafter'
log_clean "$tmp/esc.raw"
expect "log_clean: off a terminal, the log is left alone" "$(grep -c $'\033' "$tmp/esc.raw")" "3"

# --- hooks.d: group-writable files and slow hooks ---
hd="$CONFIG_DIR/hooks.d"; mkdir -p "$hd"
printf '#!/bin/bash\necho ran >> "%s"\n' "$tmp/hook.log" > "$hd/post-deploy-1"; chmod 775 "$hd/post-deploy-1"; : > "$tmp/hook.log"
hook_run post-deploy fake web abc 2>"$tmp/err"
expect "hooks.d: a hook its group can write to is not run" "$(grep -c 'writable by its group' "$tmp/err"):$(wc -c < "$tmp/hook.log" | tr -d ' ')" "1:0"
chmod 755 "$hd/post-deploy-1"; hook_run post-deploy fake web abc 2>/dev/null
expect "hooks.d: a 755 hook of mine runs" "$(cat "$tmp/hook.log")" "ran"
rm -f "$hd"/*
printf '#!/bin/bash\nsleep 5\n' > "$hd/pre-deploy-1"; chmod 755 "$hd/pre-deploy-1"
start=$SECONDS; DEPLOYS_HOOK_TIMEOUT=1 hook_run pre-deploy fake web abc 2>"$tmp/err"; rc=$?
expect "hooks.d: a slow pre-deploy hook is stopped and refuses the start" "$rc:$(grep -c 'ran longer than 1s' "$tmp/err")" "1:1"
[ $((SECONDS - start)) -lt 4 ] && ok "hooks.d: and it did not wait for the hook" || fail "hooks.d: timeout" "took $((SECONDS - start)) s"
rm -rf "$hd"

# --- messages name the website, not a path of the repo ---
expect "provider_doc_url: hook is deploy-hooks on the site" "$(provider_doc_url hook)" "https://deploycenter.app/docs/deploy-hooks/"
expect "provider_doc_url: cloudflare, amplify, vercel" "$(provider_doc_url cloudflare) $(provider_doc_url amplify) $(provider_doc_url vercel)" \
  "https://deploycenter.app/docs/cloudflare-pages/ https://deploycenter.app/docs/aws-amplify/ https://deploycenter.app/docs/vercel/"
expect "no user-facing message points at docs/providers/ (a path a curl or Homebrew install does not have)" \
  "$(grep -hn 'docs/providers/' deploys providers/*.sh lib/*.sh | grep -vc '^[0-9]*:[[:space:]]*#')" "0"

# --- the bug scan never runs the repo's own hooks, and its report is masked ---
expect "scan: commit and push skip hooks of the scanned repo" "$(grep -c 'core.hooksPath=/dev/null' deploys)" "2"
expect "scan: both pass --no-verify" "$(grep -c -- '--no-verify' deploys)" "2"
expect "scan: the report goes through af_mask before the PR" "$(grep -c 'af_mask < "\$log"' deploys)" "1"

# --- CI, owners and examples agree with the repo ---
miss=""
for s in tests/*-tests.sh; do
  case "$s" in tests/app-tests.sh|tests/cli-tests.sh|tests/savings-tests.sh) continue ;; esac   # the last two run from script-tests.sh
  grep -q "bash $s" .github/workflows/ci.yml || miss="$miss $s"
done
expect "ci.yml runs every shell suite (the app suite aside)" "$miss" ""
miss=""
for s in tests/*-tests.sh; do case "$s" in tests/app-tests.sh|tests/cli-tests.sh|tests/savings-tests.sh) continue ;; esac; grep -q "$s" tests/suites.txt || miss="$miss $s"; done
expect "suites.txt (the list all.sh runs) names every shell suite" "$miss" ""
expect "CODEOWNERS: lib/ and site/install.sh" "$(grep -c '^/lib/ \|^/site/install.sh ' .github/CODEOWNERS)" "2"
expect "examples pin the current release" "$(grep -h 'DEPLOYS_VERSION: "' examples/*.yml | grep -vc "\"$(cat VERSION)\"")" "0"

echo
[ "$fails" -eq 0 ] && echo "All round-10 tests passed." || { echo "$fails failed."; exit 1; }
