#!/bin/bash
# Tests for the CLI fixes of round 10 (docs: journal of terminal starts, launchd env, --when-green grace,
# no body in `ps`, observer guard for `check start`, --help in free text). No network, no launchd,
# no real HOME. Run: tests/cli-fixes-tests.sh
set -uo pipefail
cd "$(dirname "$0")/.." || exit 1
exec </dev/null
fails=0
ok()   { echo "ok   $1"; }
fail() { echo "FAIL $1: $2"; fails=$((fails+1)); }
expect() { [ "$2" = "$3" ] && ok "$1" || fail "$1" "expected [$3], got [$2]"; }

tmp="$(mktemp -d)"; trap 'rm -rf "$tmp"' EXIT
export DEPLOYS_CONFIG="$tmp/config" DEPLOYS_LIB=1 DEPLOYS_TESTING=1 HOME="$tmp/home" NO_COLOR=1 DEPLOYS_JOURNAL="$tmp/j.jsonl"
mkdir -p "$HOME"
unset DEPLOYS_CALLER DEPLOYS_NO_JOURNAL
# shellcheck source=../deploys
. ./deploys
set +e

# --- journal: deploy-changed starts, rollback and cancel from the terminal ---
vercel_deploy_json() { echo '{"id":"dpl_1","state":"building"}'; }
jn() { [ -s "$DEPLOYS_JOURNAL" ] && wc -l < "$DEPLOYS_JOURNAL" | tr -d ' ' || echo 0; }
deploy_one vercel shop abc1234def >/dev/null
expect "journal: deploy_one writes one line" "$(jn)" "1"
expect "journal: it names the commit and the id" "$(tail -n 1 "$DEPLOYS_JOURNAL" | jq -r '.name + "|" + .result + "|" + (.detail | contains("abc1234") and contains("dpl_1") | tostring)')" "shop|other|true"
vercel_deploy_json() { return 1; }
deploy_one vercel shop >/dev/null 2>&1
expect "journal: a failed start is a failed line" "$(tail -n 1 "$DEPLOYS_JOURNAL" | jq -r .result)" "failed"
: > "$DEPLOYS_JOURNAL"
vercel_deploy_json() { echo '{"id":"dpl_2"}'; }
DEPLOYS_CALLER=app deploy_one vercel shop >/dev/null
expect "journal: the app writes its own, so the CLI adds none" "$(jn)" "0"
n0="$(jn)"; DEPLOYS_NO_JOURNAL=1 journal_cli vercel shop other x
expect "journal: DEPLOYS_NO_JOURNAL skips (verify journals its own rollback)" "$(jn)" "$n0"

# --- launchd job: the DEPLOYS_* of whoever turns it on go into the plist ---
mkdir -p "$tmp/bin" "$tmp/la"
printf '#!/bin/sh\ncase "$1" in print) exit 1;; esac\nexit 0\n' > "$tmp/bin/launchctl"; chmod +x "$tmp/bin/launchctl"
( PATH="$tmp/bin:$PATH" DEPLOYS_LAUNCH_DIR="$tmp/la" DEPLOYS_NOTIFY_CMD='say "a&b"' job_on test.job 600 DeployCenter-test autofix >/dev/null 2>&1 )
pl="$tmp/la/test.job.plist"
expect "plist: DEPLOYS_CONFIG is in the job" "$(grep -c "<key>DEPLOYS_CONFIG</key><string>$tmp/config</string>" "$pl")" "1"
expect "plist: DEPLOYS_NOTIFY_CMD is in the job, escaped" "$(grep -c '<key>DEPLOYS_NOTIFY_CMD</key><string>say &quot;a&amp;b&quot;</string>' "$pl")" "1"
expect "plist: log rotation stays on" "$(grep -c '<key>DEPLOYS_LOG_ROTATE</key>' "$pl")" "1"
if command -v plutil >/dev/null 2>&1; then expect "plist: valid" "$(plutil -lint "$pl" >/dev/null 2>&1 && echo ok)" "ok"; fi

# --- log_rotate of the daily job (a run launchd started rotates its log) ---
mkdir -p "$HOME/Library/Logs"; head -c 2000 /dev/zero | tr '\0' x > "$HOME/Library/Logs/DeployCenter-daily.log"
( DEPLOYS_LOG_MAX_BYTES=1000 DEPLOYS_LOG_ROTATE=1 log_rotate DeployCenter-daily )
expect "log_rotate: the daily log is renamed past the limit" "$([ -f "$HOME/Library/Logs/DeployCenter-daily.log.1" ] && echo rotated)" "rotated"

# --- --when-green: "no checks" on a young commit is pending, not green ---
gh() {
  case "$*" in
    *"/status"*) echo '{"state":"pending","statuses":[]}' ;;
    *"/check-runs"*) echo '{"check_runs":[]}' ;;
    *"/commits/"*) date -u -r "$(( $(date +%s) - ${AGE:-5} ))" +%Y-%m-%dT%H:%M:%SZ 2>/dev/null || date -u -d "@$(( $(date +%s) - ${AGE:-5} ))" +%Y-%m-%dT%H:%M:%SZ ;;
  esac
}
githost_of() { echo github; }
expect "ci_of: no checks, 5 s old commit: pending" "$(AGE=5 ci_of me/app abc1234 | jq -r .state)" "pending"
expect "ci_of: no checks, old commit: none" "$(AGE=600 ci_of me/app abc1234 | jq -r .state)" "none"
expect "ci_of: DEPLOYS_CI_GRACE=0 turns it off" "$(DEPLOYS_CI_GRACE=0 AGE=5 ci_of me/app abc1234 | jq -r .state)" "none"
gh() { case "$*" in *"/status"*) echo '{"state":"pending","statuses":[]}' ;; *"/check-runs"*) echo '{"check_runs":[]}' ;; esac; }
expect "ci_of: commit date unknown: as before (none)" "$(ci_of me/app abc1234 | jq -r .state)" "none"

# --- a request body is not an argument of curl (ps shows arguments) ---
cat > "$tmp/bin/curl" <<'EOF'
#!/bin/bash
printf '%s\n' "$@" >> "$CURL_ARGS"
cat >/dev/null
printf '{}\n200'
EOF
chmod +x "$tmp/bin/curl"
export CURL_ARGS="$tmp/curl-args"
. ./lib/http.sh
: > "$CURL_ARGS"
( PATH="$tmp/bin:$PATH"; HTTP_AUTH="Authorization: Bearer k"; http_call T POST https://example.test/x '{"value":"s3cr3t-value"}' >/dev/null )
expect "http_call: the body is not on the command line" "$(grep -c 's3cr3t' "$CURL_ARGS")" "0"
expect "http_call: it goes in as a file" "$(grep -c '^@' "$CURL_ARGS")" "1"
expect "http_call: the file is removed afterwards" "$(grep '^@' "$CURL_ARGS" | head -n 1 | sed 's/^@//' | { read -r f; [ -e "$f" ] && echo left || echo gone; })" "gone"
. ./providers/render.sh 2>/dev/null
if declare -F render_call >/dev/null; then
  : > "$CURL_ARGS"
  ( PATH="$tmp/bin:$PATH"; RENDER_API_KEY=rnd_test; render_call PUT /services/x/env-vars '[{"key":"A","value":"s3cr3t-value"}]' >/dev/null )
  expect "render_call: the body is not on the command line" "$(grep -c 's3cr3t' "$CURL_ARGS")" "0"
fi

# --- the real script: observer guard and --help in free text ---
run() { env -u DEPLOYS_LIB PATH="$tmp/bin:$PATH" DEPLOYS_CONFIG="$tmp/config2" DEPLOYS_READONLY=1 HOME="$tmp/home" NO_COLOR=1 /bin/bash ./deploys "$@" 2>&1; }
mkdir -p "$tmp/config2"; for t in gh vercel security glab; do printf "#!/bin/sh\nexit 1\n" > "$tmp/bin/$t"; chmod +x "$tmp/bin/$t"; done
out="$(run check start me/app)"; rc=$?
expect "observer: check start is refused" "$rc:$(echo "$out" | grep -c 'Observer mode')" "1:1"
out="$(run deploy shop --force "tried --dry-run here")"; rc=$?
expect "observer: --dry-run inside --force text does not open the guard" "$rc:$(echo "$out" | grep -c 'Observer mode')" "1:1"
out="$(env -u DEPLOYS_LIB DEPLOYS_CONFIG="$tmp/config2" HOME="$tmp/home" NO_COLOR=1 /bin/bash ./deploys ai ask --help 2>&1)"
# args_has (the help and observer checks): a flag inside the text of --question/--force is not a flag.
eval "$(sed -n '/^args_has() {/,/^}/p' ./deploys)"
expect "args_has: --help inside the question is not a flag" "$(args_has "--help -h" shop --question "what does --help show?" && echo yes || echo no)" "no"
expect "args_has: a real --help is" "$(args_has "--help -h" shop --question "x" --help && echo yes || echo no)" "yes"
expect "args_has: -n after --force text is" "$(args_has "--dry-run -n" web --force "why --dry-run" -n && echo yes || echo no)" "yes"
expect "ai ask --help still shows its help line" "$(echo "$out" | grep -c '^  deploys ai ask')" "1"

echo
[ "$fails" = 0 ] && echo "All passed." || { echo "$fails failed."; exit 1; }
