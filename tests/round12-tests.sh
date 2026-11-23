#!/bin/bash
# Tests for the round-12 CLI fixes: lock files, time limits, log following, hooks.d, the risk rules,
# the window zone, GitLab hosts, doctor, version and small helpers. No network, no real projects.
set -uo pipefail
cd "$(dirname "$0")/.." || exit 1
exec </dev/null
fails=0
ok()   { echo "ok   $1"; }
fail() { echo "FAIL $1: $2"; fails=$((fails+1)); }
expect() { [ "$2" = "$3" ] && ok "$1" || fail "$1" "expected [$3], got [$2]"; }

tmp="$(mktemp -d)"; trap 'rm -rf "$tmp"' EXIT
export DEPLOYS_CONFIG="$tmp/config" HOME="$tmp/home" NO_COLOR=1 DEPLOYS_LIB=1 DEPLOYS_TESTING=1
mkdir -p "$HOME" "$DEPLOYS_CONFIG"
# shellcheck source=../deploys
. ./deploys
set +e
cli() { env -u DEPLOYS_LIB bash ./deploys "$@"; }

# --- with_timeout: SIGALRM (142) and timeout (124) are one answer ---
if command -v perl >/dev/null 2>&1; then
  expect "with_timeout: a command that runs out of time ends with 124" "$( (with_timeout 1 sleep 5) 2>/dev/null; echo $?)" "124"
fi
with_timeout 5 true; expect "with_timeout: a quick command keeps its code" "$?" "0"
with_timeout 5 sh -c 'exit 7'; expect "with_timeout: another code is kept" "$?" "7"

# --- watch_took, duration_s, http_retry_after, cache_name, days_ago: boundaries ---
expect "watch_took: 59 s" "$(watch_took 59)" "59s"
expect "watch_took: 60 s" "$(watch_took 60)" "1m0s"
expect "watch_took: 3599 s" "$(watch_took 3599)" "59m59s"
expect "watch_took: an hour and more as h and m" "$(watch_took 3600):$(watch_took 7503)" "1h00m:2h05m"
expect "duration_s: units" "$(duration_s 90s):$(duration_s 30m):$(duration_s 2h):$(duration_s 1d):$(duration_s 45)" "90:1800:7200:86400:45"
expect "duration_s: octal-looking numbers are decimal" "$(duration_s 08m):$(duration_s 09s)" "480:9"
expect "duration_s: nonsense is refused" "$(duration_s abc >/dev/null; echo $?):$(duration_s '' >/dev/null; echo $?):$(duration_s -5 >/dev/null; echo $?)" "1:1:1"
printf 'HTTP/1.1 429\r\nRetry-After: 7\r\n\r\n' > "$tmp/h1"
printf 'HTTP/1.1 429\r\nretry-after: 900\r\n\r\n' > "$tmp/h2"
printf 'HTTP/1.1 429\r\nRetry-After: Wed, 21 Oct 2026 07:28:00 GMT\r\n\r\n' > "$tmp/h3"
printf 'HTTP/1.1 429\r\nRetry-After: 1\r\nRetry-After: 3\r\n\r\n' > "$tmp/h4"
: > "$tmp/h5"
# The wait is given as it is (http_call stops at more than a minute and says so); a date in the past is 0 seconds.
expect "http_retry_after: a number as it is, a date as seconds from now (past: 0), nothing is none, the last header counts" \
  "$(http_retry_after "$tmp/h1"):$(http_retry_after "$tmp/h2"):$(http_retry_after "$tmp/h3"):$(http_retry_after "$tmp/h4"):$(http_retry_after "$tmp/h5")" "7:900:0:3:"
expect "cache_name: a_b/c and a/b_c do not meet" "$([ "$(cache_name a_b/c)" != "$(cache_name a/b_c)" ] && echo different)" "different"
expect "cache_name: a plain key is only mapped" "$(cache_name me/app@main)" "me_app_main"
expect "days_ago: a date" "$(days_ago 0 | grep -cE '^[0-9]{4}-[0-9]{2}-[0-9]{2}$')" "1"

# --- log_new_lines: a repeated line does not swallow what is new ---
printf 'a\nnpm warn x\nnpm warn x\nb\nnpm warn x\n' > "$tmp/old"
printf 'npm warn x\nnpm warn x\nb\nnpm warn x\nc\nnpm warn x\n' > "$tmp/new"
expect "log_new_lines: the block of the last lines is matched, not the last equal line" "$(log_new_lines "$tmp/old" "$tmp/new" | paste -sd, -)" "c,npm warn x"
printf 'x\ny\n' > "$tmp/old"; printf 'q\nr\n' > "$tmp/new"
expect "log_new_lines: no overlap shows all of the new log" "$(log_new_lines "$tmp/old" "$tmp/new" | paste -sd, -)" "q,r"
: > "$tmp/old"
expect "log_new_lines: an empty old log shows all" "$(log_new_lines "$tmp/old" "$tmp/new" | paste -sd, -)" "q,r"

# --- file_lock: two writers, 20 changes each, 40 entries (the providers' state files) ---
hf="$tmp/hooks.json"; echo '{}' > "$hf"
(
  # shellcheck source=../providers/netlify.sh
  . providers/netlify.sh 2>/dev/null
  netlify_hooks_file() { echo "$hf"; }
  w() { local i; for i in $(seq 1 20); do netlify_hooks_edit --arg k "$1$i" '.[$k] = 1'; done; }
  w a & w b & wait
  jq 'length' "$hf"
) > "$tmp/lock.out" 2>/dev/null
expect "netlify_hooks_edit: two parallel writers lose nothing" "$(tail -n 1 "$tmp/lock.out")" "40"
expect "the three providers use file_lock, not mkdir" "$(grep -c 'mkdir "\$lock"' providers/cloudflare.sh providers/netlify.sh providers/hook.sh | awk -F: '{s += $2} END {print s}')" "0"
cfs="$tmp/cf.json"
(
  echo '{}' > "$cfs"
  # shellcheck source=../providers/cloudflare.sh
  . providers/cloudflare.sh 2>/dev/null
  # shellcheck disable=SC2034  # read by cf_state_set
  CLOUDFLARE_STATE="$cfs"
  w() { local i; for i in $(seq 1 20); do cf_state_set '.[$k] = 1' --arg k "$1$i"; done; }
  w a & w b & wait
  jq 'length' "$cfs"
) > "$tmp/lock.out" 2>/dev/null
expect "cf_state_set: two parallel writers lose nothing" "$(tail -n 1 "$tmp/lock.out")" "40"

# --- hooks.d: backups, links and an open folder are not run ---
h="$CONFIG_DIR/hooks.d"; mkdir -p "$h"; chmod 700 "$h"
printf '#!/bin/sh\necho ran >> "%s/ran"\n' "$tmp" > "$h/pre-deploy"; chmod 700 "$h/pre-deploy"
cp "$h/pre-deploy" "$h/pre-deploy.bak"; cp "$h/pre-deploy" "$h/pre-deploy~"; cp "$h/pre-deploy" "$h/pre-deploy.orig"
ln -s "$h/pre-deploy" "$h/pre-deploy-link"
rm -f "$tmp/ran"; hook_run pre-deploy vercel shop abc >/dev/null 2>&1
expect "hook_run: only the real hook runs (not .bak, ~, .orig or a link)" "$(wc -l < "$tmp/ran" | tr -d ' ')" "1"
chmod 775 "$h"; rm -f "$tmp/ran"; hook_run pre-deploy vercel shop abc >/dev/null 2>&1
expect "hook_run: a hooks.d folder the group can write to runs nothing" "$(cat "$tmp/ran" 2>/dev/null | wc -l | tr -d ' ')" "0"
chmod 700 "$h"

# --- the risk rules ---
risk_of() {  # risk_of <comma separated files>: "level:kind,kind"
  printf '%s' "$1" | jq -Rc 'split(",") | {files: map({filename: .})}' \
    | jq -r "$RISK_DEF"' risk | .level + ":" + ([.reasons[].kind] | join(","))'
}
expect "risk: .env.example and .env.sample are templates, not environment files" "$(risk_of ".env.example,apps/web/.env.sample")" "green:"
expect "risk: a real .env is still yellow" "$(risk_of ".env.production")" "yellow:env"
expect "risk: netlify.toml, wrangler.toml and fly.toml are platform config" "$(risk_of "netlify.toml")/$(risk_of "wrangler.jsonc")/$(risk_of "fly.toml")" "yellow:config/yellow:config/yellow:config"
expect "risk: drizzle, alembic and flyway are migrations" "$(risk_of "drizzle/0001.ts")/$(risk_of "alembic/versions/a.py")/$(risk_of "db/flyway/V1__x.java")" "red:migrations/red:migrations/red:migrations"
expect "risk: pyproject.toml and Gemfile are dependencies" "$(risk_of "pyproject.toml")/$(risk_of "Gemfile")" "yellow:lockfile/yellow:lockfile"
expect "risk: a runtime pin is its own kind" "$(risk_of ".nvmrc")" "yellow:runtime"
expect "risk: a lockfile of 4000 lines does not make the diff very large" \
  "$(printf '%s' '{"files":[{"filename":"yarn.lock","additions":4000,"deletions":0}]}' | jq -r "$RISK_DEF"' risk | .level + ":" + ([.reasons[].kind] | join(","))')" "yellow:lockfile"

# --- the deploy window: a zone that is no zone ---
printf '{"tz":"../../etc/localtime","deny":[]}\n' > "$DEPLOYS_CONFIG/window.json"
WINDOW="$DEPLOYS_CONFIG/window.json"
expect "window: a tz with .. is refused" "$( (window_json) >/dev/null 2>&1; echo $?)" "1"
printf '{"tz":"/etc/localtime","deny":[]}\n' > "$WINDOW"
expect "window: a tz with a leading / is refused" "$( (window_json) >/dev/null 2>&1; echo $?)" "1"
printf '{"tz":"Europe/Berlin","deny":[]}\n' > "$WINDOW"
expect "window: a real zone is read" "$(window_json 2>/dev/null | jq -r .configured)" "true"
rm -f "$WINDOW"

# --- GitLab hosts: a name alone does not make a host GitLab ---
glabcfg="$tmp/glab"; mkdir -p "$glabcfg"; printf 'hosts:\n  gitlab.corp.example:\n    token: x\n' > "$glabcfg/config.yml"
expect "githost_of: a gitlab.* host that glab does not know is unknown" "$(GLAB_CONFIG_DIR="$glabcfg" githost_of gitlab.attacker.example/x/y)" "unknown"
expect "githost_of: one that glab knows is GitLab" "$(GLAB_CONFIG_DIR="$glabcfg" githost_of gitlab.corp.example/x/y)" "gitlab"

# --- secrets --stdin: hunks, not prefixes ---
sdiff="$(printf 'diff --git a/a b/a b\n--- a/a b\n+++ b/a b\n@@ -1,2 +1,3 @@\n x\n+++ y\n-old\n+new\n--- a/gone\n+++ /dev/null\n@@ -1 +0,0 @@\n-del\n')"
expect "secrets: a diff awk reads hunk counts (source check)" "$(grep -c 'The hunk counters' deploys)" "1"
expect "secrets --stdin: no hit in a clean diff" "$(printf '%s\n' "$sdiff" | cli secrets --stdin --json 2>/dev/null | jq -c '.found' 2>/dev/null)" "0"

# --- commands and flags ---
expect "version --json: version, bash, providers" "$(cli version --json | jq -r '(.version | length > 0 | tostring) + ":" + (.providers | index("vercel") != null | tostring)')" "true:true"
expect "doctor --text --strict is accepted and lists the helpers" "$(cli doctor --text --strict 2>/dev/null | grep -c '^\(ok\|off\)   *openssl')" "1"
expect "doctor: an unknown option is refused (a wrong call: 2)" "$(cli doctor --nope >/dev/null 2>&1; echo $?)" "2"
expect "deploy: --timeout is known (the usage line says so)" "$([ "$(grep -c 'wait \[--timeout 30m\]' deploys)" -gt 0 ] && echo yes)" "yes"
expect "gh: environment for scripts is set" "$GH_PROMPT_DISABLED:$GH_NO_UPDATE_NOTIFIER:$GLAB_SEND_TELEMETRY" "1:1:false"

[ "$fails" = 0 ] && echo "round12: all ok" || { echo "round12: $fails failed"; exit 1; }
