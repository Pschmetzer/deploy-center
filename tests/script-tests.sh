#!/bin/bash
# Tests for the rules in `deploys` that decide what has changes and what waits.
# No network: `gh` is a stand-in that answers from the cases below. Run: tests/script-tests.sh
set -uo pipefail
cd "$(dirname "$0")/.." || exit 1
fails=0
ok()   { echo "ok   $1"; }
fail() { echo "FAIL $1: $2"; fails=$((fails+1)); }
expect() { [ "$2" = "$3" ] && ok "$1" || fail "$1" "expected [$3], got [$2]"; }

tmp="$(mktemp -d)"; trap 'rm -rf "$tmp"' EXIT
export DEPLOYS_CONFIG="$tmp/config" DEPLOYS_LIB=1
# A stand-in for gh: commits, a comparison, open PRs, the rate limit.
mkdir -p "$tmp/bin"
cat > "$tmp/bin/gh" <<'GH'
#!/bin/bash
args="$*"
case "$args" in
  *rate_limit*) echo '{"limit":5000,"remaining":4000,"reset":0}' | jq "${@: -1}" 2>/dev/null || echo '{"limit":5000,"remaining":4000,"reset":0}' ;;
  *"repos/me/app/commits/main"*) echo '{"sha":"bbbb","commit":{"message":"feat: two (#12)","committer":{"date":"2026-01-02T00:00:00Z"}}}' ;;
  *"repos/me/app/compare/aaaa...main"*) echo '{"ahead_by":3,"status":"ahead","html_url":"https://x","commits":[
      {"sha":"c1","commit":{"message":"fix: one (#11)","committer":{"date":"2026-01-01T00:00:00Z"}},"author":{"type":"User"}},
      {"sha":"c2","commit":{"message":"Merge pull request #12 from me/b","committer":{"date":"2026-01-01T01:00:00Z"}},"author":{"type":"User"}},
      {"sha":"c3","commit":{"message":"docs: rebase merged","committer":{"date":"2026-01-02T00:00:00Z"}},"author":{"type":"User"}}]}' ;;
  *"commits/c3/pulls"*) echo 13 ;;
  *"compare/dead...main"*) echo "gh: Not Found (HTTP 404)" >&2; exit 1 ;;
  *"compare/rate...main"*) echo "gh: API rate limit exceeded (HTTP 403)" >&2; exit 1 ;;
  *"pulls?state=open"*) echo '{"key":"me/app","value":{"all":4,"drafts":1,"bots":2}}' ;;
  *) exit 1 ;;
esac
GH
chmod +x "$tmp/bin/gh"; export PATH="$tmp/bin:$PATH"
# shellcheck source=../deploys
. ./deploys
# The script turns on set -e; these tests look at failures, so they must not end on one.
set +e

# --- robustness: Render calls, names, remembered repos, doctor, set-key ---
# curl and security stand in for Render and the keychain. CURLSTUB picks the answer; every
# call is logged, so "asked three times" and "saved nothing" can be checked.
cat > "$tmp/bin/curl" <<'CURL'
#!/bin/bash
cat >/dev/null
m=GET; prev=""; for a in "$@"; do [ "$prev" = -X ] && m="$a"; prev="$a"; done
echo "curl $m ${*: -1}" >> "$CALLS"
case "${CURLSTUB:-ok}" in
  503) printf '%s\n503' '{"message":"unavailable"}' ;;
  down) echo "curl: (28) Operation timed out" >&2; exit 28 ;;
  401) printf '%s\n401' '{"message":"unauthorized"}' ;;
  *) printf '%s\n200' '[]' ;;
esac
CURL
printf '#!/bin/bash\necho "security $*" >> "$CALLS"; cat >/dev/null; exit 0\n' > "$tmp/bin/security"
printf '#!/bin/bash\nexit 0\n' > "$tmp/bin/sleep"
chmod +x "$tmp/bin"/*
export CALLS="$tmp/calls.log"
calls() { grep -c "$1" "$CALLS" 2>/dev/null || true; }

: > "$CALLS"
out="$(RENDER_API_KEY=k CURLSTUB=503 render_call GET /services 2>&1)"; rc=$?
expect "Render 503 on a read is asked three times" "$(calls 'curl GET')" "3"
expect "Render 503 ends in a clear error" "$rc:$(echo "$out" | grep -c 'HTTP 503 (Render had a problem')" "1:1"
: > "$CALLS"
(RENDER_API_KEY=k CURLSTUB=503 render_call POST /services/srv-1/deploys '{}' >/dev/null 2>&1)
expect "Render 503 on a POST is not repeated (it may have started a build)" "$(calls 'curl POST')" "1"
: > "$CALLS"
out="$(RENDER_API_KEY=k CURLSTUB=down render_call GET /services 2>&1)"; rc=$?
expect "no network: an error naming it, not a silent stop" "$rc:$(echo "$out" | grep -c 'HTTP 000 (no answer')" "1:1"
out="$(RENDER_API_KEY=k CURLSTUB=401 render_call GET /services 2>&1)"
expect "401 with the key from the environment points there" "$(echo "$out" | grep -c 'check RENDER_API_KEY')" "1"

out="$(env -u DEPLOYS_LIB PATH="$tmp/bin:/usr/bin:/bin" RENDER_API_KEY=k CURLSTUB=401 /bin/bash ./deploys render autodeploy-off --all 2>&1)"; rc=$?
expect "autodeploy-off --all: a list that cannot be read is an error, not \"Done\"" "$rc:$(echo "$out" | grep -c Done)" "1:0"

render_services() { echo '[{"id":"srv-a","name":"api"},{"id":"srv-b","name":"api"},{"id":"srv-c","name":"web"}]'; }
out="$(render_id_of api 2>&1)"; rc=$?
expect "two services with one name: an error, not two ids" "$rc:$(echo "$out" | grep -c 'Several Render services')" "1:1"
expect "one service with the name: its id" "$(render_id_of web)" "srv-c"
unset -f render_services

mkdir -p "$DEPLOYS_CONFIG"; echo '{"web":{"org":"me","repo":"app","ref":"main","offAt":100}}' > "$REPOS"
remember_repo '{"web":{"org":"me","repo":"app2","ref":"main","offAt":999},"new":{"org":"me","repo":"n","ref":"main","offAt":5},"none":{"repo":null}}'
expect "remember_repo keeps the first offAt, adds new ones, skips empty" \
  "$(jq -c '{w:.web.offAt, r:.web.repo, n:.new.offAt, none:has("none")}' "$REPOS")" '{"w":100,"r":"app2","n":5,"none":false}'

d="$(env -u DEPLOYS_LIB PATH="$tmp/bin:/usr/bin:/bin" RENDER_API_KEY=k /bin/bash ./deploys doctor)"
expect "doctor: key from the environment counts, versions shown" \
  "$(echo "$d" | jq -c '{renderKey, renderKeySource, jq:(.jqVersion | length > 0), bash:.bashVersion}')" \
  "{\"renderKey\":true,\"renderKeySource\":\"environment\",\"jq\":true,\"bash\":\"${BASH_VERSION%%(*}\"}"

: > "$CALLS"
echo rnd_wrong | env -u DEPLOYS_LIB PATH="$tmp/bin:/usr/bin:/bin" CURLSTUB=401 /bin/bash ./deploys render set-key >/dev/null 2>&1; rc=$?
expect "set-key: a key Render refuses is not saved" "$rc:$(calls security)" "1:0"
echo rnd_good | env -u DEPLOYS_LIB PATH="$tmp/bin:/usr/bin:/bin" /bin/bash ./deploys render set-key >/dev/null 2>&1; rc=$?
expect "set-key: a working key is saved" "$rc:$(calls 'security -i')" "0:1"

# --- the rule for "changed" ---
rule() { echo "$1" | jq -c "$CHANGED_RULE | .[0] | {changed, building}"; }
expect "new commit on GitHub is a change" \
  "$(rule '[{"deployable":true,"lastSha":"a","headSha":"b"}]')" '{"changed":true,"building":false}'
expect "same commit is not" \
  "$(rule '[{"deployable":true,"lastSha":"a","headSha":"a"}]')" '{"changed":false,"building":false}'
expect "building on Vercel (newest attempt) is not ticked" \
  "$(rule '[{"deployable":true,"lastSha":"a","headSha":"b","lastState":"READY","latestState":"BUILDING"}]')" '{"changed":false,"building":true}'
expect "building on Render is not ticked" \
  "$(rule '[{"deployable":true,"lastSha":"a","headSha":"b","lastState":"build_in_progress"}]')" '{"changed":false,"building":true}'
expect "a failed newest attempt still counts the change" \
  "$(rule '[{"deployable":true,"lastSha":"a","headSha":"b","lastState":"build_failed"}]')" '{"changed":true,"building":false}'
expect "paused is not" \
  "$(rule '[{"deployable":true,"paused":true,"lastSha":"a","headSha":"b"}]')" '{"changed":false,"building":false}'
expect "not deployable is not" \
  "$(rule '[{"deployable":false,"lastSha":"a","headSha":"b"}]')" '{"changed":false,"building":false}'
expect "no head known is not" \
  "$(rule '[{"deployable":true,"lastSha":"a"}]')" '{"changed":false,"building":false}'
expect "without commits, a newer head time is" \
  "$(rule '[{"deployable":true,"lastAt":100,"headAt":200}]')" '{"changed":true,"building":false}'
expect "a live deploy that could not be read is not a change" \
  "$(rule '[{"deployable":true,"headSha":"b","headAt":200,"fetchError":"HTTP 429"}]')" '{"changed":false,"building":false}'
expect "a branch behind what is live is not a change" \
  "$(rule '[{"deployable":true,"lastSha":"a","headSha":"b","compareStatus":"behind"}]')" '{"changed":false,"building":false}'
expect "a diverged branch is a change" \
  "$(rule '[{"deployable":true,"lastSha":"a","headSha":"b","compareStatus":"diverged"}]')" '{"changed":true,"building":false}'
expect "unknown: no head, or a fetch error" \
  "$(echo '[{"name":"a","deployable":true,"headSha":"b"},{"name":"b","deployable":true},{"name":"c","deployable":true,"headSha":"b","fetchError":"x"},{"name":"d","deployable":false}]' | jq -c "$UNKNOWN_RULE | map(.name)")" '["b","c"]'

# --- only a 404 means the branch was rewritten ---
pd="$tmp/pend"; mkdir -p "$pd"
pending_of me/app dead main "$pd"
expect "compare 404 is a rewritten branch" "$(cat "$pd"/me_app_dead_main.json 2>/dev/null | jq -c .value)" '{"rewritten":true}'
pending_of me/app rate main "$pd"
expect "compare rate limit is not" "$(find "$pd" -name '*rate*' | wc -l | tr -d ' ')" "0"
pending_of me/app aaaa main "$pd"
expect "compare status is kept" "$(jq -r .value.status "$pd"/me_app_aaaa_main.json)" "ahead"

# --- what waits: commits, PRs (squash, merge, rebase), open PRs ---
out="$(with_heads '[{"name":"app","repo":"me/app","ref":"main","deployable":true,"lastSha":"aaaa"}]' | jq -c '.[0] | {changed, pendingCommits, pendingPRs, openPRs, openDrafts, openBots, pendingPartial}')"
expect "with_heads counts commits and PRs, open PRs split" \
  "$out" '{"changed":true,"pendingCommits":3,"pendingPRs":3,"openPRs":4,"openDrafts":1,"openBots":2,"pendingPartial":false}'

# --- commands for a person: usage lines, help, version, ignore, costs, completion ---
cli() { env -u DEPLOYS_LIB PATH="$tmp/bin:/usr/bin:/bin" HOME="$tmp" NO_COLOR=1 /bin/bash ./deploys "$@" 2>&1; }
expect "a missing name is a usage line" "$(cli logs; echo "rc=$?")" $'Error: Usage: deploys logs <project> [lines] [--id <deploy>]\nrc=1'
expect "--help lists history and exits 0" "$(cli --help | grep -c 'deploys history'; cli --help >/dev/null; echo $?)" $'1\n0'
expect "--version is the VERSION file" "$(cli --version)" "$(cat VERSION)"
expect "costs refuses a word" "$(cli costs abc | grep -c 'days a number')" "1"
mkdir -p "$DEPLOYS_CONFIG"; printf 'api\nweb\n' > "$DEPLOYS_CONFIG/names"
expect "ignore refuses a name never seen" "$(cli ignore wbe | grep -c 'was seen yet')" "1"
cli ignore web >/dev/null
expect "ignore --list shows it" "$(cli ignore --list)" "web"
cli ignore web --undo >/dev/null
expect "ignore --undo removes it" "$(cli ignore --list)" ""
expect "zsh completion loads compinit when needed" "$(cli completion zsh | grep -c 'autoload -Uz compinit')" "1"
expect "unknown deploy option is refused" "$(cli vercel deploy web --prod | grep -c 'Unknown option --prod')" "1"

# --- the Render live commit comes from the last live deploy, not a failed newer one ---
live="$(echo '[{"deploy":{"status":"build_failed","commit":{"id":"new"},"createdAt":"2026-01-02T00:00:00Z"}},
               {"deploy":{"status":"live","commit":{"id":"old"},"createdAt":"2026-01-01T00:00:00Z"}}]' \
  | jq -r '[.[].deploy] as $d | (($d | map(select(.status=="live")) | .[0]) // {}) | .commit.id')"
expect "Render: live commit skips a failed newer deploy" "$live" "old"

# --- whole commands, with stand-ins for vercel, gh, curl (Render) and the keychain ---
# PATH holds only the stand-ins and the system: no real vercel, gh or Render call can happen.
# Every stand-in writes what it was asked to calls.log, so a test can say "nothing was started".
e2e="$tmp/e2e"; mkdir -p "$e2e/bin" "$e2e/config"
echo '{"web":{"org":"me","repo":"app","ref":"main"}}' > "$e2e/config/vercel-repos.json"
cat > "$e2e/bin/vercel" <<'VC'
#!/bin/bash
echo "vercel $*" >> "$E2E/calls.log"
[ "${VSTUB:-}" = down ] && { echo "Error: You are not logged in" >&2; exit 1; }
case "$*" in
  "api /v13/deployments"*POST*) echo '{"id":"dpl_new","url":"web-new.vercel.app","readyState":"QUEUED"}' ;;
  "api /v10/projects"*) echo '{"projects":[{"name":"web","link":null,"targets":{"production":{"id":"dpl_old","createdAt":1000,"readyState":"READY","meta":{"githubCommitSha":"'"${LIVE:-aaaa}"'"}}}}],"pagination":{}}' ;;
  "api /v9/projects/web"*) echo '{"id":"prj_web","name":"web"}' ;;
  "api /v6/deployments?app=web"*) [ "${WSTUB:-}" = down ] && exit 1; echo '{"deployments":[{"uid":"dpl_old","state":"READY","created":1767225600000,"target":"production"}]}' ;;
  "api /v6/deployments"*) echo '{"deployments":[]}' ;;
  *) exit 1 ;;
esac
VC
cat > "$e2e/bin/gh" <<'GH'
#!/bin/bash
echo "gh $*" >> "$E2E/calls.log"
[ "${GSTUB:-}" = down ] && { echo "gh: HTTP 401: Bad credentials" >&2; exit 1; }
case "$*" in
  *rate_limit*) echo '{"limit":5000,"remaining":4000,"reset":0}' ;;
  *"repos/me/app/commits/main"*) echo '{"sha":"bbbb","commit":{"message":"feat: new","committer":{"date":"2026-01-02T00:00:00Z"}}}' ;;
  *"compare/aaaa...main"*) [ -n "${BIG:-}" ] && { cat "$BIG"; exit 0; }
                           echo '{"status":"ahead","ahead_by":1,"behind_by":0,"commits":[{"sha":"bbbb","commit":{"message":"feat: new","committer":{"date":"2026-01-02T00:00:00Z"}},"author":{"type":"User"}}]}' ;;
  *"pulls?state=open"*) echo '{"key":"me/app","value":{"all":0,"drafts":0,"bots":0}}' ;;
  *) exit 1 ;;
esac
GH
# curl as render_call and render_last_of use it: the body, a newline, the HTTP status.
cat > "$e2e/bin/curl" <<'CURL'
#!/bin/bash
cat >/dev/null   # the key comes on stdin
m=GET; for a in "$@"; do [ "$prev" = -X ] && m="$a"; prev="$a"; done; url="${*: -1}"
echo "curl $m $url" >> "$E2E/calls.log"
case "$m $url" in
  "GET https://api.render.com/v1/services?limit=100"*) printf '%s\n200' '[{"cursor":"c1","service":{"id":"srv-1","name":"api","type":"web_service","suspended":"not_suspended","repo":"https://github.com/me/app","branch":"main","autoDeployTrigger":"off"}}]' ;;
  "GET https://api.render.com/v1/services/srv-1/deploys?limit=10")
    [ "${RSTUB:-}" = 429 ] && { printf '%s\n429' '{"message":"rate limit"}'; exit 0; }
    printf '%s\n200' '[{"deploy":{"id":"dep-1","status":"live","commit":{"id":"aaaa","message":"old"},"createdAt":"2026-01-01T00:00:00Z","finishedAt":"2026-01-01T00:01:00Z"}}]' ;;
  "GET https://api.render.com/v1/services/srv-1/deploys?limit=1")
    # Building for the first two questions, then live.
    n=$(( $(cat "$E2E/polls" 2>/dev/null || echo 0) + 1 )); echo "$n" > "$E2E/polls"
    if [ "$n" -le 2 ]; then printf '%s\n200' '[{"deploy":{"id":"dep-2","status":"build_in_progress"}}]'
    else printf '%s\n200' '[{"deploy":{"id":"dep-2","status":"live"}}]'; fi ;;
  "POST https://api.render.com/v1/services/srv-1/deploys") printf '%s\n201' '{"id":"dep-2","status":"created"}' ;;
  *) printf '%s\n404' '{}' ;;
esac
CURL
printf '#!/bin/bash\nexit 44\n' > "$e2e/bin/security"
printf '#!/bin/bash\nexit 0\n' > "$e2e/bin/sleep"
printf '#!/bin/bash\nexit 0\n' > "$e2e/bin/clear"
chmod +x "$e2e/bin"/*
run() {  # run <stdout file> <stderr file> deploys args... ; prints the exit code
  local o="$1" e="$2"; shift 2
  env -u DEPLOYS_LIB PATH="$e2e/bin:/usr/bin:/bin" E2E="$e2e" DEPLOYS_CONFIG="$e2e/config" DEPLOYS_VERCEL_TEAM=team_test \
    HOME="$e2e" NO_COLOR=1 /bin/bash ./deploys "$@" > "$o" 2> "$e" </dev/null
  echo $?
}
fresh() { : > "$e2e/calls.log"; rm -rf "$e2e/config/locks"; }
O="$e2e/out"; E="$e2e/err"

fresh; export RENDER_API_KEY=rnd_test
expect "everything readable: both changed" "$(run "$O" "$E" changed --json; jq -c 'map(.name) | sort' "$O")" $'0\n["api","web"]'
expect "changed --platform render --json keeps the filter" "$(run "$O" "$E" changed --platform render --json; jq -c 'map(.name)' "$O")" $'0\n["api"]'
expect "changed --json --platform vercel too" "$(run "$O" "$E" changed --json --platform vercel; jq -c 'map(.name)' "$O")" $'0\n["web"]'

# Everything live: `vercel json` must still answer (with nothing to compare, it used to fail).
fresh; unset RENDER_API_KEY
expect "all current: vercel json answers" "$(LIVE=bbbb run "$O" "$E" vercel json; jq -c 'map(.changed)' "$O")" $'0\n[false]'
expect "all current: Nothing to deploy" "$(LIVE=bbbb run "$O" "$E" changed; cat "$O")" $'0\nNothing to deploy: every project is on its newest commit.'
export RENDER_API_KEY=rnd_test

# Render answers 429 for the live deploy: the service is unknown, never "changed", never built.
fresh; export RSTUB=429
rc="$(run "$O" "$E" deploy-changed --yes)"
expect "Render 429: deploy-changed --yes exits non-zero" "$rc" "1"
expect "Render 429: no Render build started" "$(grep -c 'POST https://api.render.com/v1/services/srv-1/deploys' "$e2e/calls.log")" "0"
expect "Render 429: the service is named" "$(grep -c 'render api: HTTP 429' "$E")" "1"
expect "Render 429: the known Vercel change still starts" "$(grep -c 'Vercel: web started' "$O")" "1"
unset RSTUB

# Vercel not logged in, no Render key: an error, not "Nothing to deploy".
fresh; unset RENDER_API_KEY; export VSTUB=down
rc="$(run "$O" "$E" changed)"
expect "Vercel down: changed exits non-zero" "$rc" "1"
expect "Vercel down: no \"Nothing to deploy\"" "$(grep -c 'Nothing to deploy' "$O")" "0"
expect "Vercel down: the reason is shown" "$(grep -c 'could not read vercel' "$E")" "1"
rc="$(run "$O" "$E" deploy-changed --yes)"
expect "Vercel down: deploy-changed --yes starts nothing" "$rc:$(grep -c POST "$e2e/calls.log")" "1:0"
unset VSTUB

# The vercel CLI not on PATH (launchd) while projects are remembered: an error, not silence.
fresh; mv "$e2e/bin/vercel" "$e2e/vercel.off"
rc="$(run "$O" "$E" changed)"
expect "vercel CLI missing: changed exits non-zero and says why" "$rc:$(grep -c 'could not read vercel' "$E")" "1:1"
mv "$e2e/vercel.off" "$e2e/bin/vercel"

# gh not logged in: every head is unknown, so nothing is known to be current.
fresh; export GSTUB=down
rc="$(run "$O" "$E" changed)"
expect "GitHub down: changed exits non-zero, no \"Nothing to deploy\"" "$rc:$(grep -c 'Nothing to deploy' "$O")" "1:0"
expect "GitHub down: the project is named" "$(grep -c 'vercel web: branch head unknown' "$E")" "1"
unset GSTUB

# status --no-github asks GitHub nothing.
fresh; export RENDER_API_KEY=rnd_test
run "$O" "$E" status --no-github >/dev/null
expect "status --no-github makes no GitHub call" "$(grep -c '^gh ' "$e2e/calls.log")" "0"
expect "status --no-github prints no change count" "$(tail -n 1 "$O")" "0 building."
run "$O" "$E" status --no-github --json >/dev/null
expect "status --json carries the repo" "$(jq -r 'map(.repo) | join(",")' "$O")" "me/app,me/app"

# watch: a finished newest deploy is reported as such; a network failure is exit 3, not "failed".
fresh
expect "watch: nothing running" "$(run "$O" "$E" watch web; cat "$O")" $'0\nNothing is building for web. The newest deploy (dpl_old) is READY.'
rm -f "$e2e/polls"
expect "watch: follows a Render build to live" "$(run "$O" "$E" watch api; tail -n 1 "$O" | cut -c11-)" $'0\nlive'
# Once to find the platform, once for the id; not once per poll.
expect "watch: Render service list not read per poll" "$(grep -c 'services?limit=100' "$e2e/calls.log")" "2"

# history: empty fields show as "-", so the columns stay in place.
fresh
expect "history: one row, empty fields as -" "$(run "$O" "$E" history web; sed -n 2p "$O" | tr -s ' ')" $'0\n2026-01-01 00:00 production READY - - -'
# render json writes the Render names, so `ignore` knows them.
run "$O" "$E" render json >/dev/null
expect "render json: names remembered, ignore accepts a Render service" "$(run "$O" "$E" ignore api; run "$O" "$E" ignore --list; cat "$O")" $'0\n0\napi'
run "$O" "$E" ignore api --undo >/dev/null
fresh; export WSTUB=down
expect "watch: platform unreachable is exit 3" "$(run "$O" "$E" watch web)" "3"
unset WSTUB

# details: a comparison of several megabytes does not hit the argument limit.
fresh
python3 -c 'import json; print(json.dumps({"status":"ahead","ahead_by":1,"html_url":"x","commits":[],"files":[{"filename":"f%d"%i,"additions":1,"deletions":0,"patch":"x"*40000} for i in range(100)]}))' > "$e2e/big.json"
expect "details: a 4 MB comparison works" "$(BIG="$e2e/big.json" run "$O" "$E" details me/app aaaa main; jq -r .files "$O")" $'0\n100'
unset RENDER_API_KEY

# --- autofix: which failures fire, caps, no duplicates, token never in argv, one redeploy ---
af="$tmp/af"; mkdir -p "$af/bin"
cat > "$af/bin/curl" <<'CURL'
#!/bin/bash
echo "argv $*" >> "$CALLS"; sed 's/^/stdin /' >> "$CALLS"
case "${AFCODE:-200}" in
  200) printf '%s\n200' '{"type":"routine_fire","claude_code_session_url":"https://claude.ai/code/session_x"}' ;;
  *) printf '%s\n%s' '{"error":{"type":"x"}}' "$AFCODE" ;;
esac
CURL
chmod +x "$af/bin/curl"
afrun() { ( set -e; PATH="$af/bin:$PATH" DEPLOYS_ROUTINE_TOKEN=sk-ant-oat01-SECRET DEPLOYS_NOTIFY=0 autofix_run "$@" ) 2>&1; }
ALL='[]'; OPENPRS='[]'; CLOSEDPRS='[]'
af_all() { echo "$ALL"; }
af_logs() { printf 'npm ERR! build failed\nAPI_KEY=abc123 token: ghp_abcdefghijklmnop\n'; }
af_deploy() { echo "deploy $*" >> "$CALLS"; }
af_prs() { echo "prs $3" >> "$CALLS"; [ "$3" = open ] && echo "$OPENPRS" || echo "$CLOSEDPRS"; }
af_reset() { rm -f "$AUTOFIX_STATE"; : > "$CALLS"; }
mkdir -p "$DEPLOYS_CONFIG"; printf 'trig_test' > "$DEPLOYS_CONFIG/autofix-routine"
fired() { grep -c '^argv ' "$CALLS" 2>/dev/null || true; }

af_reset
ALL='[{"platform":"vercel","name":"web","repo":"me/web","ref":"main","latestState":"CANCELED","latestId":"d1","latestSha":"aaaa111"},
      {"platform":"render","name":"api","repo":"me/api","lastState":"update_failed","latestId":"r1","latestSha":"bbbb"},
      {"platform":"render","name":"job","repo":"me/job","lastState":"canceled","latestId":"r2","latestSha":"cccc"}]'
out="$(afrun)"
expect "autofix: canceled and update_failed never fire" "$(fired)" "0"
expect "autofix: update_failed is reported" "$(echo "$out" | grep -c 'api is update_failed')" "1"

af_reset
ALL='[{"platform":"vercel","name":"web","repo":"me/web","ref":"main","latestState":"ERROR","latestId":"d1","latestSha":"aaaa111"},
      {"platform":"render","name":"api","repo":"me/api","lastState":"build_failed","latestId":"r1","latestSha":"bbbb"}]'
afrun >/dev/null
expect "autofix: one fire per run" "$(fired)" "1"
expect "autofix: the token is never in argv" "$(grep '^argv ' "$CALLS" | grep -c SECRET)" "0"
expect "autofix: the token goes in on stdin" "$(grep -c '^stdin header = "Authorization: Bearer sk-ant-oat01-SECRET"' "$CALLS")" "1"
expect "autofix: fired is recorded with the session" "$(jq -r '.fires[0] | "\(.status) \(.session)"' "$AUTOFIX_STATE")" "fired https://claude.ai/code/session_x"
: > "$CALLS"; afrun >/dev/null
expect "autofix: the same failed deploy does not fire twice; the next project does" "$(fired):$(jq -c '[.fires[].deployId]' "$AUTOFIX_STATE")" '1:["d1","r1"]'
: > "$CALLS"; afrun >/dev/null
expect "autofix: nothing new, nothing fired" "$(fired)" "0"

# The payload has masked secrets.
af_reset; ALL='[{"platform":"vercel","name":"web","repo":"me/web","latestState":"ERROR","latestId":"d1","latestSha":"aaaa111"}]'
masked="$(af_logs | af_mask)"
expect "autofix: secrets in the log are masked" "$(echo "$masked" | grep -c 'abc123\|ghp_abcdef')" "0"

# 429 is retried next run; any other error is recorded and not retried.
af_reset; AFCODE=429 afrun >/dev/null
expect "autofix: 429 leaves it for the next run" "$(jq -r '.fires[0].status' "$AUTOFIX_STATE")" "ratelimited"
: > "$CALLS"; afrun >/dev/null
expect "autofix: after 429 the next run fires" "$(fired):$(jq -r '.fires[0].status' "$AUTOFIX_STATE")" "1:fired"
af_reset; AFCODE=500 afrun >/dev/null
: > "$CALLS"; AFCODE=500 afrun >/dev/null
expect "autofix: a 500 is recorded and not retried" "$(fired):$(jq -r '.fires[0].status' "$AUTOFIX_STATE")" "0:failed"

# An open autofix PR blocks a fire.
af_reset; OPENPRS='[{"number":7,"ref":"claude/autofix-web-aaaa111"}]'
expect "autofix: an open autofix PR blocks a fire" "$(afrun | grep -c 'open autofix PR'):$(fired)" "1:0"
OPENPRS='[]'

# Cap per project: two fires in 24 h, then none.
af_reset
now="$(date +%s)"
jq -n --argjson t "$now" '{fires:[{deployId:"o1",project:"web",status:"fired",at:($t-100)},{deployId:"o2",project:"web",status:"failed",at:($t-200)}]}' > "$AUTOFIX_STATE"
expect "autofix: two fires today stop a third" "$(afrun | grep -c 'already had 2'):$(fired)" "1:0"

# Merged fix: never deployed, only recorded and announced; its own failure does not fire again.
af_reset
jq -n --argjson t "$((now - 600))" '{fires:[{deployId:"d1",project:"web",platform:"vercel",repo:"me/web",sha:"aaaa111",status:"fired",at:$t}]}' > "$AUTOFIX_STATE"
CLOSEDPRS="[{\"number\":8,\"merged_at\":\"$(date -u +%Y-%m-%dT%H:%M:%SZ)\",\"merge_commit_sha\":\"ffff999\",\"ref\":\"claude/autofix-web-aaaa111\"}]"
afrun >/dev/null
expect "autofix: a merged fix is never deployed" "$(grep -c '^deploy ' "$CALLS"):$(jq -r '.fires[0].mergedSha' "$AUTOFIX_STATE")" "0:ffff999"
: > "$CALLS"; afrun >/dev/null
expect "autofix: a merged fix stays undeployed on the next run" "$(grep -c '^deploy ' "$CALLS")" "0"
ALL='[{"platform":"vercel","name":"web","repo":"me/web","latestState":"ERROR","latestId":"d2","latestSha":"ffff999"}]'
: > "$CALLS"; out="$(afrun)"
expect "autofix: the fix failing too is not fired again" "$(fired):$(echo "$out" | grep -c 'failed to build too')" "0:1"
ALL='[{"platform":"vercel","name":"web","repo":"me/web","latestState":"READY","latestId":"d3","latestSha":"ffff999"}]'
CLOSEDPRS='[]'

# The prompt in the docs is the one the app copies.
expect "autofix: docs/AUTOFIX.md shows the prompt af_prompt prints" \
  "$(awk '/^```text$/{f=1;next} /^```$/{if(f)exit} f' docs/AUTOFIX.md)" "$(af_prompt)"

# schedule on writes a launchd job that runs this script; off removes it; status never shows the token.
printf '#!/bin/bash\necho "launchctl $*" >> "$CALLS"\n' > "$af/bin/launchctl"; chmod +x "$af/bin/launchctl"
: > "$CALLS"
( PATH="$af/bin:$PATH" DEPLOYS_LAUNCH_DIR="$af/agents" af_schedule_on )
expect "autofix: schedule on writes the job and loads it" \
  "$(grep -c '<string>autofix</string>' "$af/agents/app.deploycenter.autofix.plist"):$(grep -c 'launchctl bootstrap' "$CALLS")" "1:1"
expect "autofix: the job is valid XML" "$(plutil -lint "$af/agents/app.deploycenter.autofix.plist" >/dev/null 2>&1 && echo ok || (command -v plutil >/dev/null && echo bad || echo ok))" "ok"
( PATH="$af/bin:$PATH" DEPLOYS_LAUNCH_DIR="$af/agents" af_schedule_off )
expect "autofix: schedule off removes it" "$([ -f "$af/agents/app.deploycenter.autofix.plist" ] && echo there || echo gone)" "gone"

# Dry run writes nothing; a held lock stops a second run.
af_reset; ALL='[{"platform":"vercel","name":"web","repo":"me/web","latestState":"ERROR","latestId":"d1","latestSha":"aaaa111"}]'
expect "autofix: dry run fires and saves nothing" "$(afrun dry | grep -c 'would hand'):$(fired):$([ -f "$AUTOFIX_STATE" ] && echo saved || echo none)" "1:0:none"
mkdir -p "$DEPLOYS_CONFIG/locks/autofix"
expect "autofix: a held lock stops a second run" "$(afrun | grep -c 'running already'):$(fired)" "1:0"
rmdir "$DEPLOYS_CONFIG/locks/autofix"

# Savings (simulate, ledger) have their own file with fixtures.
bash tests/savings-tests.sh || fails=$((fails+1))

echo
[ "$fails" = 0 ] && echo "All script tests passed." || { echo "$fails failed."; exit 1; }
