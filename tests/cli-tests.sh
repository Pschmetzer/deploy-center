# shellcheck shell=bash
# Sourced by tests/script-tests.sh at its end: the e2e stand-ins (run, fresh, $e2e, $O, $E) and
# expect/ok/fail come from there. Fixes from docs/IDEEN-6.md, section 3, by number.
# shellcheck disable=SC2154,SC2034  # e2e, O, E, tmp come from script-tests.sh; variables set for the functions called

fresh; export RENDER_API_KEY=rnd_test

# 259: deploy --wait passes on watch's "platform not reachable" (3) instead of "did not go live" (1).
expect "deploy --wait: an unreachable platform is exit 3, not 1" \
  "$(run "$O" "$E" deploy web --wait; grep -c 'did not go live' "$E"; grep -c 'could not follow web' "$E")" $'3\n0\n1'

# 270: no provider on and set up: an error pointing to `deploys providers`, never "all up to date".
np="$tmp/noprov"; mkdir -p "$np"; cp -R "$e2e/config" "$np/config"; echo '{"enabled":[]}' > "$np/config/providers.json"
out="$(env -u DEPLOYS_LIB PATH="$e2e/bin:/usr/bin:/bin" E2E="$e2e" DEPLOYS_CONFIG="$np/config" HOME="$e2e" NO_COLOR=1 /bin/bash ./deploys changed 2>&1 </dev/null)"; rc=$?
expect "no provider on: changed fails and says where to look" "$rc:$(echo "$out" | grep -c 'deploys providers'):$(echo "$out" | grep -c 'every project is on its newest')" "1:1:0"

# 284: a misspelt --platform is refused before anything is read.
fresh
expect "changed --platform: a typo is refused" "$(run "$O" "$E" changed --platform vercle; grep -c 'takes one of' "$E"; grep -c '^vercel api' "$e2e/calls.log")" $'1\n1\n0'

# 281/282/293: logs 0, history past 100, open with a stray argument.
expect "logs: 0 lines is refused (not the whole log)" "$(run "$O" "$E" logs web 0; grep -c '1 or more' "$E")" $'1\n1'
expect "history: more than 100 is refused" "$(run "$O" "$E" history web 500; grep -c 'from 1 to 100' "$E")" $'1\n1'
expect "open: only --dashboard is taken" "$(run "$O" "$E" open web foo; grep -c 'Unknown option foo' "$E")" $'1\n1'

# 257: risk and verify take "p:name" like the other commands.
fresh
expect "risk: vercel:web is found" "$(run "$O" "$E" risk vercel:web --json; jq -r '"\(.project) \(.platform)"' "$O")" $'0\nweb vercel'
expect "verify: vercel:web is checked" "$(run "$O" "$E" verify vercel:web --json; jq -c '{project, healthy}' "$O")" $'0\n{"project":"web","healthy":true}'

# 258: an error is exit 3, never 1 ("rolled back").
expect "verify: an unknown project is exit 3" "$(run "$O" "$E" verify nosuch --no-rollback)" "3"

# 285: with --path, a 404 fails the check (a missing /health must not pass); without it, it does not.
fresh
expect "verify --path: 404 is a failure" "$(SITE=notfound run "$O" "$E" verify web --path /health --no-rollback)" "2"
expect "verify without --path: 404 is not" "$(SITE=notfound run "$O" "$E" verify web --no-rollback)" "0"

# 269: a locked keychain is named for an opt-in provider too, not "no token".
fresh; kp="$tmp/kc"; mkdir -p "$kp"; cp -R "$e2e/config" "$kp/config"; echo '{"enabled":["vercel","netlify"]}' > "$kp/config/providers.json"
printf '#!/bin/bash\nexit 36\n' > "$e2e/bin/security"
out="$(env -u DEPLOYS_LIB PATH="$e2e/bin:/usr/bin:/bin" E2E="$e2e" DEPLOYS_CONFIG="$kp/config" DEPLOYS_VERCEL_TEAM=team_test HOME="$e2e" NO_COLOR=1 /bin/bash ./deploys changed 2>&1 </dev/null)"; rc=$?
expect "keychain locked (Netlify): changed fails and says why" "$rc:$(echo "$out" | grep -c 'could not read netlify: Netlify: the keychain could not be read')" "1:1"
printf '#!/bin/bash\nexit 44\n' > "$e2e/bin/security"

# 273: two ids of one name on one platform: the ids are named, not "render:api" again.
echo '[{"name":"api","platform":"render","id":"srv-a"},{"name":"api","platform":"render","id":"srv-b"}]' > "$tmp/names2.json"
expect "lookup: two of one name on one platform names the ids" \
  "$( (CONFIG_DIR="$tmp/n2"; mkdir -p "$CONFIG_DIR"; cp "$tmp/names2.json" "$CONFIG_DIR/names.json"; lookup api) 2>&1 | grep -c 'srv-a, srv-b')" "1"

# 275: names that are gone from a provider's list leave `names` too.
expect "remember_names: a deleted project goes" \
  "$( (CONFIG_DIR="$tmp/n3"; mkdir -p "$CONFIG_DIR"; echo '[{"name":"old"},{"name":"web"}]' | remember_names vercel
       echo '[{"name":"web"}]' | remember_names vercel; echo '[{"name":"api","id":"srv-1"}]' | remember_names render; paste -sd, "$CONFIG_DIR/names") )" "api,web"

# 278: the journal writes a provider's label, not its id.
expect "journal: a provider's label" "$( (DEPLOYS_JOURNAL="$tmp/j.jsonl"; journal_add netlify shop other x; jq -r .platform "$tmp/j.jsonl") )" "Netlify"

# 279: a key with a CR or spaces around it is trimmed; one with a space inside is refused.
: > "$CALLS"
printf 'sk-ant-abc\r\n' | env -u DEPLOYS_LIB PATH="$tmp/bin:/usr/bin:/bin" /bin/bash ./deploys ai set-key >/dev/null 2>&1
expect "ai set-key: a trailing CR is trimmed" "$(grep -c 'security -i' "$CALLS"):$(grep -c $'\r' "$CALLS")" "1:0"
: > "$CALLS"
out="$(printf 'sk-ant-a b\n' | env -u DEPLOYS_LIB PATH="$tmp/bin:/usr/bin:/bin" /bin/bash ./deploys ai set-key 2>&1)"; rc=$?
expect "ai set-key: a space inside is refused, nothing saved" "$rc:$(grep -c security "$CALLS")" "1:0"

# 271: the guard counts as on only when launchd has the job, and a dropped job is loaded again.
mkdir -p "$tmp/g271/agents" "$tmp/g271/bin"; touch "$tmp/g271/agents/app.deploycenter.guard.plist"
printf '#!/bin/bash\necho "launchctl $*" >> "$CALLS"\n[ "$1" = print ] && exit 113\nexit 0\n' > "$tmp/g271/bin/launchctl"; chmod +x "$tmp/g271/bin/launchctl"
: > "$CALLS"
expect "guard: a job file launchd does not have is off" \
  "$( (PATH="$tmp/g271/bin:$PATH" DEPLOYS_LAUNCH_DIR="$tmp/g271/agents"; guard_scheduled && echo on || echo off) )" "off"
( PATH="$tmp/g271/bin:$PATH" DEPLOYS_LAUNCH_DIR="$tmp/g271/agents"; guard_reload ) 2>/dev/null
expect "guard: a dropped job is loaded again" "$(grep -c 'launchctl bootstrap' "$CALLS")" "1"

# 277: without `column`, tables still come out (awk), aligned.
mkdir -p "$tmp/nocol"; ln -sf "$(command -v awk)" "$tmp/nocol/awk"
expect "table: works without column" "$(printf 'a\tbb\tc\nxxx\ty\tz\n' | PATH="$tmp/nocol" table)" $'a    bb  c\nxxx  y   z'

# 272: "p:name" in ignore leaves out only that platform's project.
fresh; run "$O" "$E" changed --json >/dev/null
run "$O" "$E" ignore vercel:web >/dev/null
expect "ignore vercel:web: web is left out, api stays" "$(run "$O" "$E" changed --json; jq -c 'map(.name)' "$O")" $'0\n["api"]'
run "$O" "$E" ignore render:web >/dev/null; run "$O" "$E" ignore vercel:web --undo >/dev/null
expect "ignore render:web does not hide vercel web" "$(run "$O" "$E" changed --json; jq -c 'map(.name) | sort' "$O")" $'0\n["api","web"]'
run "$O" "$E" ignore render:web --undo >/dev/null

# 291: a name that is a group and a project is refused; group:<name> is the group.
printf '%s\n' '# shellcheck shell=bash' 'team_gate() { [ -z "${5:-}" ] || echo "$5"; }' \
  'team_group() { case "$1" in web|shop) echo web ;; esac; }' 'team_observer_from() { :; }' \
  'team_repos_json() { return 1; }' 'team_ignored() { return 1; }' > "$tmp/team-stub.sh"
fresh
expect "deploy: a group and a project of one name is refused" \
  "$(DEPLOYS_TEAM_LIB="$tmp/team-stub.sh" run "$O" "$E" deploy web; started; grep -c 'deploy group:web' "$E")" $'1\n0\n1'
expect "deploy group:shop starts the group" "$(DEPLOYS_TEAM_LIB="$tmp/team-stub.sh" run "$O" "$E" deploy group:shop; started; grep -c '^Group shop: web' "$O")" $'0\n1\n1'
expect "deploy group:nope is an error" "$(DEPLOYS_TEAM_LIB="$tmp/team-stub.sh" run "$O" "$E" deploy group:nope; grep -c 'No group named' "$E")" $'1\n1'

# 267: an unknown flag of deploy-json is refused, nothing starts.
fresh
expect "vercel deploy-json --sah: refused" "$(run "$O" "$E" vercel deploy-json web --sah abc; started)" $'1\n0'
expect "render deploy-json --sah: refused" "$(run "$O" "$E" render deploy-json api --sah abc; started)" $'1\n0'
# 266: vercel deploy --wait gives up like watch (exit 3) instead of asking for ever.
fresh
expect "vercel deploy --wait: gives up after five misses" "$(run "$O" "$E" vercel deploy web --wait; grep -c 'try 5 of 5' "$E")" $'3\n1'

# 263: a Vercel deploy from GitLab or Bitbucket has its commit as lastSha too.
expect "vercel json: gitlabCommitSha is the live commit" \
  "$( (vercel_projects() { echo '[{"name":"gl","link":null,"targets":{"production":{"createdAt":1000,"readyState":"READY","meta":{"gitlabCommitSha":"abc1","gitlabCommitMessage":"fix"}}}}]'; }
       vercel_call() { echo '{"deployments":[{"name":"gl","state":"READY","created":1,"uid":"d1","meta":{"bitbucketCommitSha":"abc1"}}]}'; }
       repos_json() { echo '{}'; }; vercel_json | jq -c '.[0] | [.lastSha, .lastMsg, .latestSha]') )" '["abc1","fix","abc1"]'

# 264: a link deploys cannot write down (Bitbucket) is not removed.
echo '{}' > "$tmp/repos264.json"; : > "$CALLS"
out="$( (REPOS="$tmp/repos264.json"; vercel_call() { echo '{"link":{"type":"bitbucket","productionBranch":"main"}}'; }
         vercel() { echo "vercel $*" >> "$CALLS"; }; vercel_off_one bb) 2>&1)"; rc=$?
expect "vercel off: a Bitbucket link stays when its repo is not known" "$rc:$(grep -c DELETE "$CALLS"):$(echo "$out" | grep -c 'stays connected')" "1:0:1"
# 265: a GitLab mapping says where to connect it again, not "repo is not known".
echo '{"gl":{"type":"gitlab","repo":"gitlab.com/g/app","projectId":7,"ref":"main"}}' > "$tmp/repos265.json"
expect "vercel on: a GitLab mapping points to the dashboard" \
  "$( (REPOS="$tmp/repos265.json"; vercel_on_one gl) 2>&1 | grep -c 'Vercel dashboard')" "1"

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

# ---------- wave 3 (docs/IDEEN-6.md, section 3) ----------

# 387: every command that changes something is refused in observer mode, in every flag order.
fresh; bad=""
for c in "deploy web" "deploy web --wait" "deploy-changed --yes" "deploy-changed --when-green --yes" "deploy-changed --yes --when-green" \
         "vercel deploy web" "vercel deploy-json web" "vercel rollback web" "vercel cancel web x" "vercel map web me/app" \
         "vercel autodeploy-off web" "vercel autodeploy-on web" "render deploy api" "render rollback api" "render autodeploy-off --all" \
         "render autodeploy-on api" "autodeploy allow vercel web 2" "autodeploy revoke vercel web" "verify web" "guard" "autofix" \
         "autofix --only vercel web" "scan start me/app" "cloudflare selftest x --yes" "hook deploy x" "amplify on a"; do
  # shellcheck disable=SC2086  # the words of the command
  rc="$(DEPLOYS_READONLY=1 run "$O" "$E" $c)"
  [ "$rc:$(grep -c 'Observer mode' "$E")" = "1:1" ] || bad="$bad [$c: rc $rc]"
done
expect "387: observer mode refuses every write, in any flag order" "$bad" ""
expect "387: and nothing reached a platform" "$(grep -c 'POST\|--method' "$e2e/calls.log")" "0"

# 388/254: a name that would change an API path is refused by every command that takes one,
# before anything is asked.
fresh; bad=""
for c in "deploy" "verify" "risk" "watch" "logs" "open" "explain" "diff" "notes" "history" "ai explain" \
         "vercel deploy" "vercel status" "render deploy" "render status" "autofix --only vercel"; do
  for n in 'a/b' 'a?x' 'a%2F' 'vercel:a/b'; do
    # shellcheck disable=SC2086
    rc="$(run "$O" "$E" $c "$n")"
    [ "$rc:$(grep -c 'Invalid name or id' "$E")" = "1:1" ] || bad="$bad [$c $n: rc $rc]"
  done
done
expect "388: every command refuses / ? % in a name" "$bad" ""
expect "388: and asked no platform" "$(grep -c . "$e2e/calls.log")" "0"

# 318: Amplify ids are <appId>/<branch>: one / is taken for amplify, nowhere else.
expect "318: amplify takes <appId>/<branch>" \
  "$( (safe_name d1shop0001/main amplify) 2>/dev/null; echo $?; (safe_name amplify:d1shop0001/main) 2>/dev/null; echo $?)" $'0\n0'
expect "318: but not two / or one for another platform" \
  "$( (safe_name a/b/c amplify) 2>/dev/null; echo $?; (safe_name a/b) 2>/dev/null; echo $?; (safe_name render:a/b) 2>/dev/null; echo $?; (safe_name /main amplify) 2>/dev/null; echo $?)" $'1\n1\n1\n1'

# 309: a typo gets the nearest command, not the whole help.
expect "309: unknown command names the nearest" "$(run "$O" "$E" chaged; grep -c 'Unknown command "chaged". Did you mean: changed' "$E"; grep -c . "$O")" $'1\n1\n0'
# 312: the help lists each provider's commands, its own ones too.
expect "312: --help lists the provider commands" "$(run "$O" "$E" --help; grep -c '^Provider commands' "$O"; grep -Ec '^  vercel +list .* map' "$O")" $'0\n1\n1'
# A verb a provider does not have: refused with its commands (it used to print the help, exit 1).
expect "312: an unknown provider verb lists the provider's commands" "$(run "$O" "$E" render frob; grep -c 'Render has no command "frob". Its commands: list deploy' "$E")" $'1\n1'

# 392: every top-level command in the case labels is in --help (details and github-budget are
# the app's, not a person's).
run "$O" "$E" --help >/dev/null
missing="$(sed -n 's/^  "\([a-z][a-z-]*\)[ "].*/\1/p' ./deploys | sort -u | grep -vxE 'details|github-budget' \
  | while read -r c; do grep -qE "deploys $c([^a-z-]|\$)" "$O" || echo "$c"; done | paste -sd' ' -)"
expect "392: every command is in --help" "$missing" ""

# 315: enabling a provider that is not set up says the next step.
pe="$tmp/pe"; mkdir -p "$pe"; cp -R "$e2e/config" "$pe/config"
out="$(env -u DEPLOYS_LIB -u NETLIFY_AUTH_TOKEN PATH="$e2e/bin:/usr/bin:/bin" DEPLOYS_CONFIG="$pe/config" HOME="$e2e" NO_COLOR=1 /bin/bash ./deploys providers enable netlify 2>&1)"
expect "315: providers enable says what comes next" "$(echo "$out" | grep -c 'Next: pbpaste | deploys netlify set-key')" "1"

# 313: watch --timeout ends with its own code (4), never 1 (failed) or 3 (unreachable).
fresh; rm -f "$e2e/polls"
expect "313: watch --timeout stops with 4 and says so" "$(run "$O" "$E" watch api --timeout 6s; grep -c 'has not finished after 6s' "$E")" $'4\n1'
expect "313: --timeout takes a time" "$(run "$O" "$E" watch api --timeout soon; grep -c 'takes a time' "$E")" $'1\n1'
rm -f "$e2e/polls"
expect "313: watch shows how long it ran" "$(run "$O" "$E" watch api; grep -c '(6s)\|(12s)' "$O")" $'0\n2'

# 314: deploy without --wait says how to follow it.
fresh
expect "314: deploy says how to follow" "$(run "$O" "$E" deploy web; grep -c 'Follow it: deploys watch web dpl_new' "$O")" $'0\n1'
# 302: one project with --json is still one object.
fresh
expect "302: deploy --json of one project is one object" "$(run "$O" "$E" deploy web --json; jq -r 'type' "$O")" $'0\nobject'

# 336: open opens only web addresses.
p336="$tmp/p336"; mkdir -p "$p336/providers" "$p336/config"
printf '%s\n' '# shellcheck shell=bash' \
  'odd_meta() { echo '"'"'{"id":"odd","label":"Odd","noun":"app","defaultOn":true,"keyEnv":[],"keychain":null,"caps":{"off":false}}'"'"'; }' \
  'odd_ready() { return 0; }' 'odd_has() { echo "id-$1"; }' 'odd_json() { echo "[]"; }' 'odd_url() { echo "file:///etc/hosts"; }' > "$p336/providers/odd.sh"
out="$(env -u DEPLOYS_LIB PATH="$e2e/bin:/usr/bin:/bin" DEPLOYS_DIR="$p336" DEPLOYS_CONFIG="$p336/config" HOME="$e2e" /bin/bash ./deploys open odd:web 2>&1)"; rc=$?
expect "336: open refuses a file:// address" "$rc:$(echo "$out" | grep -c 'no web address')" "1:1"

# 334: a hook over http only to this machine, by its exact host.
bad=""
for u in http://localhost.example.com/h http://127.0.0.1.example.test/h http://localhostx/h http://user@evil.test/h; do
  ( hook_check_url "$u" ) >/dev/null 2>&1 && bad="$bad $u"
done
for u in http://localhost/h http://localhost:8080/h http://127.0.0.1:9000/h 'http://[::1]:8080/h' https://hooks.example.test/h; do
  ( hook_check_url "$u" ) >/dev/null 2>&1 || bad="$bad !$u"
done
expect "334: http only for localhost, 127.0.0.1 and ::1 exactly" "$bad" ""

# 333: the Coolify token goes over plain http only to this machine, or when allowed on purpose.
expect "333: http to another machine is refused, localhost and https are not" \
  "$( (CONFIG_DIR="$tmp/c333"; coolify_http_ok http://10.0.0.5:8000; echo $?; coolify_http_ok http://localhost:8000; echo $?; coolify_http_ok https://c.example.test; echo $?) )" $'1\n0\n0'
mkdir -p "$tmp/c333"; echo '{"url":"http://10.0.0.5:8000","allowHttp":true}' > "$tmp/c333/coolify.json"
expect "333: allowed for that address in coolify.json, or with the variable" \
  "$( (CONFIG_DIR="$tmp/c333"; coolify_http_ok http://10.0.0.5:8000; echo $?; coolify_http_ok http://10.0.0.6; echo $?; DEPLOYS_COOLIFY_ALLOW_HTTP=1 coolify_http_ok http://10.0.0.6; echo $?) )" $'0\n1\n0'
expect "333: the refusal names the way to allow it, before any request" \
  "$( (CONFIG_DIR="$tmp/c333b"; COOLIFY_URL=http://10.0.0.7 COOLIFY_TOKEN=t coolify_call GET /applications) 2>&1 | grep -c 'set-url http://10.0.0.7 --allow-http')" "1"

# 331: with an observers list and no known login, writes are refused (fail closed).
expect "331: observers listed and no login: observer" \
  "$( (CONFIG_DIR="$tmp/t331"; mkdir -p "$CONFIG_DIR"; TEAM_CACHE="$CONFIG_DIR/team-cache"; TEAM_REPOS="$CONFIG_DIR/team-repos"
       TEAM_OVERRIDES="$CONFIG_DIR/overrides.json"; echo '{"observers":["someone"]}' > "$TEAM_OVERRIDES"
       DEPLOYS_NO_GITHUB=1 team_effective | jq -r '.readonly | "\(.value) \(.from)"') )" "true observers listed, and gh cannot tell who you are (gh auth login)"
expect "331: without an observers list nothing changes" \
  "$( (CONFIG_DIR="$tmp/t331b"; mkdir -p "$CONFIG_DIR"; TEAM_CACHE="$CONFIG_DIR/team-cache"; TEAM_REPOS="$CONFIG_DIR/team-repos"
       TEAM_OVERRIDES="$CONFIG_DIR/overrides.json"; DEPLOYS_NO_GITHUB=1 team_effective | jq -r '.readonly.value') )" "false"

# 332: an approval of an older head of the PR does not count.
t332() {  # t332 <commit the review approved>
  ( c332="$1"; gh() { case "$*" in
           *commits/s1/pulls*) echo '[{"number":5,"html_url":"https://x/5","head":{"sha":"h2"},"labels":[]}]' ;;
           *pulls/5/reviews*) echo '[{"user":{"login":"rev"},"state":"APPROVED","submitted_at":"2026-01-01T00:00:00Z","commit_id":"'"$c332"'"}]' ;;
           *issues*) echo '[]' ;;
           *) return 1 ;;
         esac; }
    team_approvals me/app s1 dev | jq '.have | length' )
}
expect "332: a review of the PR's last commit counts, one of an older commit does not" "$(t332 h2; t332 h1)" $'1\n0'

# 390: doctor has no key twice (jq would keep the last one without a word).
fresh
run "$O" "$E" doctor >/dev/null
expect "390: doctor's keys are unique" "$(jq -c --stream 'select(length == 2) | .[0]' "$O" | sort | uniq -d | head -n 3)" ""

# 343: after --, --json is a value.
expect "343: after -- nothing is an option" "$(run "$O" "$E" window -- --json; grep -c 'No deploy window set' "$O")" $'0\n1'

# 296: a Vercel read that met a 5xx is asked again; a write is not.
# The stand-in counts its runs in a file: vercel_call runs it in a $( ) subshell.
vn="$tmp/vercel-runs"
expect "296: vercel_call asks a GET again after a 503" \
  "$( (: > "$vn"; vercel() { echo x >> "$vn"; if [ "$(wc -l < "$vn")" -lt 2 ]; then echo "Error: 503 Service Unavailable" >&2; return 1; fi; echo '{"ok":true}'; }
       sleep() { :; }; vercel_team() { echo ""; }; vercel_call /v9/projects/web | jq -r .ok; wc -l < "$vn" | tr -d ' ') )" $'true\n2'
expect "296: but not a POST" \
  "$( (: > "$vn"; vercel() { echo x >> "$vn"; echo "Error: 503" >&2; return 1; }; sleep() { :; }; vercel_team() { echo ""; }
       vercel_call /v13/deployments --method POST 2>/dev/null; wc -l < "$vn" | tr -d ' ') )" "1"

# 297: a CLI call that hangs ends after DEPLOYS_CLI_TIMEOUT with 124 and a line.
printf '#!/bin/bash\nexec /bin/sleep 5\n' > "$tmp/hang"; chmod +x "$tmp/hang"
expect "297: cli_limit stops a hanging call" "$( (DEPLOYS_CLI_TIMEOUT=1 cli_limit "$tmp/hang" 2>&1; echo "rc=$?") | tr '\n' ' ')" "$tmp/hang: no answer after 1s (DEPLOYS_CLI_TIMEOUT) rc=124 "

# 307: a window.json that cannot be read is exit 2, not 1 ("closed").
fresh; echo '{"deny":' > "$e2e/config/window.json"
expect "307: window with a broken window.json is 2" "$(run "$O" "$E" window)" "2"
rm -f "$e2e/config/window.json"

# 301: costs without Vercel says that costs is Vercel's.
cv="$tmp/cv"; mkdir -p "$cv"; cp -R "$e2e/config" "$cv/config"; echo '{"enabled":["render"]}' > "$cv/config/providers.json"
out="$(env -u DEPLOYS_LIB PATH="$e2e/bin:/usr/bin:/bin" DEPLOYS_CONFIG="$cv/config" HOME="$e2e" NO_COLOR=1 /bin/bash ./deploys costs 2>&1)"; rc=$?
expect "301: costs without Vercel" "$rc:$(echo "$out" | grep -c "costs reads Vercel's charges")" "1:1"

# 250: meta is read with or without spaces after the colon.
expect "250: meta_flag and meta_str take spaces" \
  "$( (spaced_meta() { echo '{"id": "spaced", "label": "Spaced", "defaultOn": true, "keyEnv": ["SPACED_KEY"]}'; }
       meta_flag spaced defaultOn && echo on; meta_str spaced label; key_env_names spaced) )" $'on\nSpaced\nSPACED_KEY'

# 320: deploy-changed starts a backend before the Vercel frontend of the same repo.
fresh
run "$O" "$E" deploy-changed --yes >/dev/null
expect "320: Render (backend) before Vercel (frontend) of one repo" \
  "$(grep -E '^vercel api /v13/deployments|^curl POST https://api.render.com/v1/services/srv-1/deploys' "$e2e/calls.log" | cut -c1-4 | paste -sd, -)" "curl,verc"
