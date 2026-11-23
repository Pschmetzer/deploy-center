# shellcheck shell=bash
# Sourced by tests/cli-tests.sh (itself sourced at the end of tests/script-tests.sh): round6 open points.
# e2e, O, E, tmp, run, fresh, expect come from script-tests.sh.

# --- The CLI points of round 6 left open before (docs/IDEEN-6.md), by number ---
# In a subshell with the script sourced again: earlier tests replaced or removed some functions.
r6="$tmp/r6"; mkdir -p "$r6"
(
  # shellcheck source=/dev/null  # deploys_src is ./deploys, from script-tests.sh
  . "$deploys_src"; set +e

  # 280: a "&" or "<" in a path goes into the plist escaped (launchctl refuses broken XML).
  mkdir -p "$r6/R&D<x>/Library/Logs" "$r6/agents" "$r6/bin"
  printf '#!/bin/bash\necho "launchctl $*" >> "$CALLS"\nexit 0\n' > "$r6/bin/launchctl"; chmod +x "$r6/bin/launchctl"
  ( PATH="$r6/bin:$PATH" DEPLOYS_LAUNCH_DIR="$r6/agents" HOME="$r6/R&D<x>"; job_on test.r6 60 R6 guard "a&b" ) >/dev/null 2>&1
  pl="$r6/agents/test.r6.plist"
  expect "280: the plist escapes & and < in paths and arguments" \
    "$(grep -c 'R&amp;D&lt;x&gt;' "$pl"):$(grep -c '<string>a&amp;b</string>' "$pl"):$(grep -c 'R&D' "$pl")" "2:1:0"
  if command -v plutil >/dev/null 2>&1; then
    expect "280: the plist is valid" "$(plutil -lint "$pl" >/dev/null 2>&1 && echo ok)" "ok"
  fi

  # 292: a GitLab port stays with the host for the API; an ssh:// port is the SSH port and goes.
  expect "292: https with a port" "$(githost_split https://code.example.test:8443/g/app.git)" "code.example.test:8443 g/app"
  expect "292: a slug with a port" "$(githost_split code.example.test:8443/g/app)" "code.example.test:8443 g/app"
  expect "292: ssh:// drops its port" "$(githost_split ssh://u@code.example.test:2222/g/app)" "code.example.test g/app"
  : > "$CALLS"
  ( DEPLOYS_GITLAB_CURL=1 gitlab_api code.example.test:8443 user >/dev/null )
  expect "292: the API is asked on that port" "$(grep -c 'curl GET https://code.example.test:8443/api/v4/user' "$CALLS")" "1"

  # 295: 100 open PRs is one full page: the count is marked as a floor.
  mkdir -p "$r6/o"
  ( gh() { jq -nc '[range(100)] | map({draft:false, user:{type:"User"}})'; }; open_prs_of me/big "$r6/o" )
  expect "295: a full page of open PRs is partial" "$(jq -c '.value | [.all, .partial]' "$r6/o/me_big.json")" "[100,true]"

  # 289: the reason a branch head is unknown, in words.
  printf 'gh: API rate limit exceeded for user (HTTP 403)\n' > "$r6/e1"; printf 'gh: Not Found (HTTP 404)\n' > "$r6/e2"
  expect "289: a rate limit is named" "$(head_why "$r6/e1" GitHub)" "GitHub's rate limit is reached; try again later"
  expect "289: a missing repo is named" "$(head_why "$r6/e2" GitHub)" "the repo or branch is not on GitHub, or this login cannot see it"
  mkdir -p "$r6/h"
  ( gh() { echo "gh: HTTP 401: Bad credentials" >&2; return 1; }; head_of me/app main "$r6/h" )
  expect "289: head_of leaves a record of why" "$(jq -r '.value.error' "$r6/h/me_app_main.json")" "not logged in to GitHub (gh auth login)"

  # 260: every page of check runs counts: a red one on page 2 is red.
  ci260() { case "$*" in
      *check-runs*) [[ "$*" == *--paginate* ]] || { echo '{"check_runs":[]}'; return 0; }
        echo '{"total_count":2,"check_runs":[{"name":"a","status":"completed","conclusion":"success"}]}'
        echo '{"total_count":2,"check_runs":[{"name":"b","status":"completed","conclusion":"failure"}]}' ;;
      *) echo '{"statuses":[]}' ;; esac; }
  expect "260: a failure on the second page is red" "$( (gh() { ci260 "$@"; }; ci_of me/app abc1234) | jq -c '[.state, .checks]')" '["red",2]'

  # DEPLOYS_CI_IGNORE leaves out check runs by name (not only commit statuses): an optional red check does not block, another one does.
  ciign() { case "$*" in
      *check-runs*) [[ "$*" == *--paginate* ]] || { echo '{"check_runs":[]}'; return 0; }
        echo '{"total_count":2,"check_runs":[{"name":"build","status":"completed","conclusion":"success"},{"name":"lint-optional","status":"completed","conclusion":"failure"}]}' ;;
      *) echo '{"statuses":[]}' ;; esac; }
  expect "CI_IGNORE: a red optional check run is ignored" "$( (gh() { ciign "$@"; }; DEPLOYS_CI_IGNORE='^lint-optional$' ci_of me/app abc1234) | jq -r .state)" "green"
  expect "CI_IGNORE: without it the same check run is red" "$( (gh() { ciign "$@"; }; DEPLOYS_CI_IGNORE='' ci_of me/app abc1234) | jq -r .state)" "red"
  expect "CI_IGNORE: a pattern that does not match still blocks" "$( (gh() { ciign "$@"; }; DEPLOYS_CI_IGNORE='^other$' ci_of me/app abc1234) | jq -r .state)" "red"

  # 261: GitLab CI from the commit's newest pipeline; not readable is unknown and final (no wait).
  gl261() { echo "{\"id\":\"abc\",\"last_pipeline\":{\"id\":7,\"status\":\"$1\"}}"; }
  expect "261: a failed pipeline is red" "$( (gitlab_api() { gl261 failed; }; ci_of gitlab.com/g/app abc) | jq -r .state)" "red"
  expect "261: a passed pipeline is green" "$( (gitlab_api() { gl261 success; }; ci_of gitlab.com/g/app abc) | jq -r .state)" "green"
  expect "261: a running pipeline is pending" "$( (gitlab_api() { gl261 running; }; ci_of gitlab.com/g/app abc) | jq -r .state)" "pending"
  expect "261: a manual pipeline is no checks, not pending" "$( (gitlab_api() { gl261 manual; }; ci_of gitlab.com/g/app abc) | jq -r .state)" "none"
  : > "$CALLS"
  expect "261: GitLab not readable: unknown, final, and no wait" \
    "$( (gitlab_api() { echo "gitlab: HTTP 401: no" >&2; return 1; }; sleep() { echo slept >> "$CALLS"; }; ci_wait gitlab.com/g/app abc 1800) | jq -c '[.state, .final]'):$(grep -c slept "$CALLS")" '["unknown",true]:0'
  expect "261: a host deploys cannot read is final too" "$(ci_of bitbucket.org/me/app abc | jq -c '[.state, .final]')" '["unknown",true]'

  # 262: risk for GitLab, from the diffs of the comparison.
  gl262() { case "$2" in
      *compare*) echo '{"commits":[{"id":"c1","message":"x (!3)","committed_date":"2026-01-01T00:00:00Z"}],"diffs":[{"new_path":"db/migrations/001.sql","diff":"+a\n+b\n-c"}]}' ;;
      *merge_base*) echo '{"id":"base1"}' ;;
      *) echo '[]' ;; esac; }
  expect "262: gitlab_risk_of reads the diffs" "$( (gitlab_api() { gl262 "$@"; }; gitlab_risk_of gitlab.com/g/app base1 main) | jq -c '[.level, .lines]')" '["red",3]'
  mkdir -p "$r6/p"
  ( gitlab_api() { gl262 "$@"; }; gitlab_pending_of gitlab.com/g/app base1 main "$r6/p" )
  expect "262: pending of a GitLab repo has its risk" "$(jq -r '.value.risk.level' "$r6"/p/*.json)" "red"

  # details: without a branch, the repo's default branch (never a silent main).
  expect "details: the default branch is asked" "$( (gh() { [[ "$*" == *"repos/me/app"* ]] && echo trunk; }; default_branch_of me/app) )" "trunk"

  # 288: savings ask Render only about Render services.
  # shellcheck source=../lib/savings.sh
  . lib/savings.sh
  : > "$CALLS"
  expect "288: another provider's builds are not asked of Render" \
    "$(sv_builds netlify site1 id1 | jq -r '.unsupported'):$(grep -c 'api.render.com' "$CALLS")" "true:0"

  # 344: the guard covers every provider that can turn auto-deploy off.
  expect "344: ad_platforms lists the new providers too" \
    "$( (enabled_providers() { printf 'netlify\nhook\nvercel\n'; }; provider_on() { return 0; }; ad_platforms | paste -sd, -) )" "netlify,vercel"
  out="$( (netlify_off() { echo "Netlify: one step left"; }; ad_list_any() { echo '[{"name":"s","id":"s1","auto":true}]'; }; ad_off netlify s s1) 2>&1)"; rc=$?
  expect "344: an off that left auto-deploy on is a failure" "$rc:$(echo "$out" | grep -c 'still on')" "1:1"
  expect "344: an off that worked is fine" \
    "$( (coolify_off() { :; }; ad_list_any() { echo '[{"name":"a","id":"a1","auto":false}]'; }; ad_off coolify a a1) >/dev/null 2>&1; echo $?)" "0"
  expect "344: allowances take the new providers" "$(ad_scope coolify app)" $'coolify:app\tcoolify\tapp'
  out="$( (allow_main netlify site 2) 2>&1)"; rc=$?
  expect "344: no allowance where auto-deploy cannot come back on (Netlify)" "$rc:$(echo "$out" | grep -c 'cannot turn auto-deploy on again')" "1:1"

  # 346: the workflow check knows the deploy commands of the new providers.
  for w in "npx netlify deploy --prod" "npx wrangler pages deploy dist" "doctl apps create-deployment 123" "aws amplify start-job --app-id x" \
           "curl -X GET https://coolify.example.test/api/v1/deploy?uuid=abc"; do
    expect "346: a workflow running \"$w\" deploys by itself" "$(echo "$w" | grep -cE "$WORKFLOW_DEPLOY_RE")" "1"
  done

  # 255: the shared deploy window (an allowed time, in its own zone) closes a project outside it.
  team_on() { return 0; }
  team_eff_once() { echo '{"projects":{"shop":{"window":{"value":{"days":["mon","tue"],"from":"09:00","to":"16:00","tz":"Europe/Berlin"}}},"blog":{"window":{"value":{"deny":[]}}}}}'; }
  expect "255: inside the shared window it is open" "$(DEPLOYS_NOW="mon 10:00 2026-11-09" team_window_denied shop)" ""
  expect "255: outside it is closed, and says why" "$(DEPLOYS_NOW="fri 10:00 2026-11-13" team_window_denied vercel:shop | grep -c 'outside the shared deploy window')" "1"
  expect "255: a window.json-style deny list is left to window_json" "$(DEPLOYS_NOW="fri 10:00 2026-11-13" team_window_denied blog)" ""
  out="$( (forced=0; DEPLOYS_NOW="fri 10:00 2026-11-13" freeze_check shop) 2>&1)"; rc=$?
  expect "255: freeze_check refuses a deploy outside the shared window" "$rc:$(echo "$out" | grep -c 'No deploys of shop now')" "1:1"
  out="$( (forced=1; DEPLOYS_NOW="fri 10:00 2026-11-13" freeze_check shop; echo "frozen=$frozen") 2>&1)"; rc=$?
  expect "255: --force goes ahead and is journaled" "$rc:$(echo "$out" | grep -c 'frozen=shop: outside')" "0:1"
  [ "$fails" = 0 ] || exit 1
) || fails=$((fails + 1))

# 246: doctor puts the plain-keyed objects of Netlify and Coolify under their names.
d246="$tmp/d246"; mkdir -p "$d246/config"; echo '{"enabled":["vercel","render","netlify","coolify"]}' > "$d246/config/providers.json"
expect "246: doctor has no clashing keys" \
  "$(env -u DEPLOYS_LIB PATH="$e2e/bin:/usr/bin:/bin" E2E="$e2e" DEPLOYS_CONFIG="$d246/config" HOME="$e2e" /bin/bash ./deploys doctor 2>/dev/null \
     | jq -c '[.netlify.provider, .coolify.provider, has("tokenOk"), (.vercelCli | type), (.renderKey | type)]')" '["netlify","coolify",false,"boolean","boolean"]'

# 536: logs --masked hides secrets; without it the log is as it was. A stand-in provider.
p536="$tmp/p536"; mkdir -p "$p536/providers" "$p536/config"
cat > "$p536/providers/fake.sh" <<'FAKE'
# shellcheck shell=bash
fake_meta() { echo '{"id":"fake","label":"Fake","noun":"app","defaultOn":true,"keyEnv":[],"keychain":null,"caps":{"off":false,"logs":true}}'; }
fake_ready() { return 0; }
fake_has() { echo "id-$1"; }
fake_json() { echo '[]'; }
fake_logs() { echo "building $1"; echo "API_TOKEN=supersecretvalue123"; }
FAKE
l536() { env -u DEPLOYS_LIB PATH="$e2e/bin:/usr/bin:/bin" DEPLOYS_DIR="$p536" DEPLOYS_CONFIG="$p536/config" HOME="$e2e" /bin/bash ./deploys logs fake:web "$@" 2>&1; }
expect "536: logs --masked hides the token" "$(l536 --masked | grep -c supersecretvalue123):$(l536 --masked | grep -c 'API_TOKEN=\[masked\]')" "0:1"
# Without --masked too: logs always masks (it reaches the app, the MCP server and models).
expect "536: logs without --masked is masked as well" "$(l536 | grep -c supersecretvalue123):$(l536 | grep -c 'API_TOKEN=\[masked\]')" "0:1"

# 583: gitlab set-token, trimmed like the other keys, tried before it is saved.
: > "$CALLS"
printf 'glpat-abcdefgh12345678\r\n' | env -u DEPLOYS_LIB -u GITLAB_TOKEN PATH="$tmp/bin:/usr/bin:/bin" /bin/bash ./deploys gitlab set-token >/dev/null 2>&1
expect "583: gitlab set-token tries, then saves, without the CR" \
  "$(grep -c 'curl GET https://gitlab.com/api/v4/user' "$CALLS"):$(grep -c 'security -i' "$CALLS"):$(grep -c $'\r' "$CALLS")" "1:1:0"
: > "$CALLS"
out="$(printf 'glpat-wrong\n' | env -u DEPLOYS_LIB -u GITLAB_TOKEN CURLSTUB=401 PATH="$tmp/bin:/usr/bin:/bin" /bin/bash ./deploys gitlab set-token 2>&1)"; rc=$?
expect "583: a token GitLab refuses is not saved" "$rc:$(grep -c 'security -i' "$CALLS"):$(echo "$out" | grep -c 'did not accept')" "1:0:1"
: > "$CALLS"
out="$(printf 'glpat a b\n' | env -u DEPLOYS_LIB -u GITLAB_TOKEN PATH="$tmp/bin:/usr/bin:/bin" /bin/bash ./deploys gitlab set-token 2>&1)"; rc=$?
expect "583: a space inside is refused, nothing asked or saved" "$rc:$(grep -c 'curl\|security' "$CALLS")" "1:0"

# 289 end to end: `changed` says why GitHub did not answer.
fresh
expect "289: changed names the reason a head is unknown" \
  "$(GSTUB=down run "$O" "$E" changed >/dev/null; grep -c 'web: branch head unknown: not logged in to GitHub' "$E")" "1"
# details without a branch: the default branch could not be read, so it says so (no silent main).
fresh
expect "details: no branch and no default branch is an error, not main" \
  "$(run "$O" "$E" details me/app aaaa; grep -c 'default branch of me/app could not be read' "$E"; grep -c 'compare/aaaa...main' "$e2e/calls.log")" $'1\n1\n0'

