#!/bin/bash
# Tests for the rules in `deploys` that decide what has changes and what waits.
# No network: `gh` is a stand-in that answers from the cases below. Run: tests/script-tests.sh
set -uo pipefail
cd "$(dirname "$0")/.." || exit 1
# Stubs read stdin (the security stand-in does): never wait on a terminal or a pipe.
exec </dev/null
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
                           echo '{"status":"ahead","ahead_by":1,"behind_by":0,"commits":[{"sha":"bbbb","commit":{"message":"feat: new\n\nCo-Authored-By: Some Agent <agent@example.test>","committer":{"date":"2026-01-02T00:00:00Z"}},"author":{"type":"User"}}]}' ;;
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
# details: Co-Authored-By trailers are kept, the message stays its first line.
fresh
expect "details: co-authors from the trailers" "$(run "$O" "$E" details me/app aaaa main; jq -c '.commits[0] | [.msg, .coAuthors]' "$O")" $'0\n["feat: new",[{"name":"Some Agent","email":"agent@example.test"}]]'
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

# --- GitLab as a source: githost_of, glab, curl with GITLAB_TOKEN, a self-managed host ---
# One set of answers (answer.sh) behind both stand-ins: glab for `glab api`, curl for the API.
gl="$tmp/gl"; mkdir -p "$gl/glab" "$gl/curl"
cat > "$gl/answer.sh" <<'ANS'
#!/bin/bash
# answer.sh <api path>: the body on stdout, or exit 44 (404) / 42 (429).
p="${1#projects/*/}"
c() { printf '{"id":"%s","short_id":"%s","title":"%s","message":"%s","author_name":"%s","author_email":"%s@x","committed_date":"%s","web_url":"https://x/%s"}' "$1" "$1" "$2" "$3" "$4" "$4" "$5" "$1"; }
case "$p" in
  user) echo '{"username":"me"}' ;;
  "repository/commits/main") c bbbb "feat: two (!12)" "feat: two (!12)" ann "2026-01-02T01:00:00.000+01:00" ;;
  "repository/compare?from=aaaa&to=main") echo "{\"commit\":$(c bbbb t t ann 2026-01-02T00:00:00Z),\"web_url\":\"https://gl/compare\",\"commits\":[
      $(c c1 "fix: one" 'Merge branch b into main\n\nSee merge request me/app!11' ann 2026-01-01T00:00:00Z),
      $(c c3 "docs: squashed" "docs: squashed" ann 2026-01-01T02:00:00.000-01:00),
      $(c c4 "chore: from !12" "chore: from 12" ann 2026-01-01T04:00:00Z),
      $(c bbbb "feat: two (!12)" "feat: two (!12)" renovate-bot 2026-01-02T00:00:00Z)],
    \"diffs\":[{\"new_path\":\"src/a.ts\",\"diff\":\"@@ -1 +1,2 @@\n-x\n+y\n+z\n\"},{\"new_path\":\".gitlab-ci.yml\",\"diff\":\"@@ -1 +1 @@\n-a\n+b\n\"}]}" ;;
  "repository/merge_base?refs%5B%5D=aaaa&refs%5B%5D=main") echo '{"id":"aaaa"}' ;;
  "repository/commits/c3/merge_requests") echo '[{"iid":13,"state":"merged"}]' ;;
  "repository/commits/c4/merge_requests") echo '[{"iid":12,"state":"merged"},{"iid":99,"state":"closed"}]' ;;
  "repository/compare?from=div&to=main") echo "{\"commits\":[$(c d1 x x ann 2026-01-01T00:00:00Z)]}" ;;
  "repository/merge_base?refs%5B%5D=div&refs%5B%5D=main") echo '{"id":"zzzz"}' ;;
  "repository/compare?from=main&to=div") echo "{\"commits\":[$(c e1 x x ann 2026-01-01T00:00:00Z),$(c e2 x x ann 2026-01-01T00:00:00Z)]}" ;;
  "repository/compare?from=behi&to=main") echo '{"commits":[]}' ;;
  "repository/merge_base?refs%5B%5D=behi&refs%5B%5D=main") echo '{"id":"bbbb"}' ;;
  "repository/compare?from=main&to=behi") echo "{\"commits\":[$(c f1 x x ann 2026-01-01T00:00:00Z)]}" ;;
  "repository/compare?from=dead&to=main") exit 44 ;;
  "repository/compare?from=rate&to=main") exit 42 ;;
  "merge_requests?state=opened&per_page="*) echo '[
      {"iid":20,"title":"a","draft":false,"author":{"username":"ann"},"updated_at":"2026-01-01T00:00:00Z","web_url":"u20"},
      {"iid":21,"title":"b","draft":true,"author":{"username":"ann"},"updated_at":"2026-01-01T00:00:00Z","web_url":"u21"},
      {"iid":22,"title":"c","work_in_progress":false,"author":{"username":"renovate-bot"},"updated_at":"2026-01-01T00:00:00Z","web_url":"u22"},
      {"iid":23,"title":"d","author":{"username":"project_42_bot_1f2e"},"updated_at":"2026-01-01T00:00:00Z","web_url":"u23"}]' ;;
  "repository/commits/bbbb/statuses?per_page=100") echo '[{"status":"success"},{"status":"failed"},{"status":"running"}]' ;;
  *) exit 44 ;;
esac
ANS
cat > "$gl/glab/glab" <<'GLAB'
#!/bin/bash
echo "glab $*" >> "$CALLS"
[ "$1 $2" = "auth status" ] && exit "${GLAB_AUTH:-0}"
[ "$1 $2" = "api --hostname" ] || exit 1
out="$("$(dirname "$0")/../answer.sh" "$4")"; rc=$?
case "$rc" in 0) echo "$out" ;; 44) echo "glab: 404 Not Found (HTTP 404)" >&2; exit 1 ;; *) echo "glab: 429 Too Many Requests (HTTP 429)" >&2; exit 1 ;; esac
GLAB
cat > "$gl/curl/curl" <<'CURL'
#!/bin/bash
echo "argv $*" >> "$CALLS"; sed 's/^/stdin /' >> "$CALLS"
url="${*: -1}"; host="${url#https://}"; host="${host%%/*}"
[ "${GLSTUB:-}" = 401 ] && { printf '%s\n401' '{"message":"401 Unauthorized"}'; exit 0; }
out="$("$(dirname "$0")/../answer.sh" "${url#https://*/api/v4/}")"; rc=$?
case "$rc" in 0) printf '%s\n200' "$out" ;; 44) printf '%s\n404' '{"message":"404 Ref Not Found"}' ;; *) printf '%s\n429' '{}' ;; esac
CURL
chmod +x "$gl/answer.sh" "$gl/glab/glab" "$gl/curl/curl"

expect "githost_of: owner/name is GitHub" "$(githost_of me/app)" "github"
expect "githost_of: a GitHub URL" "$(githost_of https://github.com/me/app.git)" "github"
expect "githost_of: a gitlab.com URL with subgroups" "$(githost_of https://gitlab.com/g/sub/app)" "gitlab"
expect "githost_of: an ssh remote" "$(githost_of git@gitlab.com:g/app.git)" "gitlab"
expect "githost_of: the .repo slug" "$(githost_of gitlab.com/g/app)" "gitlab"
expect "githost_of: a self-managed host needs GITLAB_HOST" \
  "$(githost_of git.example.com/g/app):$(GITLAB_HOST=https://git.example.com/ githost_of https://git.example.com/g/app)" "unknown:gitlab"
expect "githost_of: or DEPLOYS_GITLAB_HOSTS, or gitlab in the name" \
  "$(DEPLOYS_GITLAB_HOSTS="a.io code.b.io" githost_of code.b.io/g/app):$(githost_of gitlab.corp.io/g/app)" "gitlab:gitlab"
expect "githost_of: Bitbucket is neither" "$(githost_of https://bitbucket.org/me/app)" "unknown"
expect "slug: GitHub stays owner/name, GitLab keeps its host" \
  "$(jq -nc "[\"https://github.com/me/app.git\", \"https://gitlab.com/g/s/app.git\"] | map($GITHOST_SLUG_JQ)")" '["me/app","gitlab.com/g/s/app"]'
expect "slug of a Vercel link: GitHub and GitLab" \
  "$(jq -nc "[{type:\"github\",org:\"me\",repo:\"app\"},{type:\"gitlab\",projectUrl:\"https://gitlab.com/g/app\"}] | map($GITHOST_VERCEL_LINK_JQ)")" '["me/app","gitlab.com/g/app"]'
expect "GitLab dates with fractions and offsets" \
  "$(jq -nc "$GITLAB_JQ"'["2026-01-02T01:00:00.000+01:00","2026-01-01T18:30:00-05:30","2026-01-02T00:00:00Z"] | map(gldate)')" '[1767312000,1767312000,1767312000]'

# glab: compare counting, MR counting (message, "(!n)", lookups, once each), open MRs.
glwh() { PATH="$gl/glab:$PATH" with_heads "$1"; }
out="$(glwh '[{"name":"gl","repo":"gitlab.com/me/app","ref":"main","deployable":true,"lastSha":"aaaa"}]' \
  | jq -c '.[0] | {changed, headSha, headAt, pendingCommits, pendingPRs, openPRs, openDrafts, openBots, compareStatus, behindBy, pendingPartial, oldestPendingAt}')"
expect "glab: commits, merge requests and open MRs counted" \
  "$out" '{"changed":true,"headSha":"bbbb","headAt":1767312000,"pendingCommits":4,"pendingPRs":3,"openPRs":4,"openDrafts":1,"openBots":2,"compareStatus":"ahead","behindBy":0,"pendingPartial":false,"oldestPendingAt":1767225600}'
out="$(glwh '[{"name":"gh","repo":"me/app","ref":"main","deployable":true,"lastSha":"aaaa"},{"name":"gl","repo":"gitlab.com/me/app","ref":"main","deployable":true,"lastSha":"aaaa"}]' \
  | jq -c 'map({name, pendingCommits, pendingPRs, openPRs})')"
expect "GitHub and GitLab side by side, GitHub as before" \
  "$out" '[{"name":"gh","pendingCommits":3,"pendingPRs":3,"openPRs":4},{"name":"gl","pendingCommits":4,"pendingPRs":3,"openPRs":4}]'
gpd="$tmp/glpend"; mkdir -p "$gpd"
PATH="$gl/glab:$PATH" gitlab_pending_of gitlab.com/me/app div main "$gpd"
expect "glab: live not an ancestor and new commits is diverged" "$(jq -c '.value | {commits, status, behindBy}' "$gpd"/gitlab.com_me_app_div_main.json)" '{"commits":1,"status":"diverged","behindBy":2}'
PATH="$gl/glab:$PATH" gitlab_pending_of gitlab.com/me/app behi main "$gpd"
expect "glab: a branch behind what is live" "$(jq -c '.value | {commits, status, behindBy}' "$gpd"/gitlab.com_me_app_behi_main.json)" '{"commits":0,"status":"behind","behindBy":1}'
expect "a GitLab branch behind is not a change" \
  "$(glwh '[{"name":"gl","repo":"gitlab.com/me/app","ref":"main","deployable":true,"lastSha":"behi"}]' | jq -c '.[0] | {changed, compareStatus}')" '{"changed":false,"compareStatus":"behind"}'
PATH="$gl/glab:$PATH" gitlab_pending_of gitlab.com/me/app dead main "$gpd"
expect "glab: compare 404 is a rewritten branch" "$(jq -c .value "$gpd"/gitlab.com_me_app_dead_main.json 2>/dev/null)" '{"rewritten":true}'
PATH="$gl/glab:$PATH" gitlab_pending_of gitlab.com/me/app rate main "$gpd"
expect "glab: a rate limit is not" "$(find "$gpd" -name '*rate*' | wc -l | tr -d ' ')" "0"

# curl with GITLAB_TOKEN against a self-managed host: the same answers, the token only on stdin
# and only to GITLAB_HOST.
: > "$CALLS"
out="$(PATH="$gl/curl:$PATH" DEPLOYS_GITLAB_CURL=1 GITLAB_HOST=https://git.example.com GITLAB_TOKEN=glpat-SECRET \
  with_heads '[{"name":"gl","repo":"git.example.com/grp/app","ref":"main","deployable":true,"lastSha":"aaaa"}]' \
  | jq -c '.[0] | {changed, pendingCommits, pendingPRs, openPRs, openDrafts, openBots, compareStatus}')"
expect "curl: a self-managed host counts the same" \
  "$out" '{"changed":true,"pendingCommits":4,"pendingPRs":3,"openPRs":4,"openDrafts":1,"openBots":2,"compareStatus":"ahead"}'
expect "curl: every call goes to that host's API" \
  "$(grep '^argv ' "$CALLS" | grep -vc 'https://git.example.com/api/v4/projects/grp%2Fapp/')" "0"
expect "curl: the token is never in argv" "$(grep '^argv ' "$CALLS" | grep -c SECRET)" "0"
expect "curl: the token goes in on stdin" "$(grep -c '^stdin header = "PRIVATE-TOKEN: glpat-SECRET"' "$CALLS")" "$(grep -c '^argv ' "$CALLS")"
: > "$CALLS"
PATH="$gl/curl:$PATH" DEPLOYS_GITLAB_CURL=1 GITLAB_HOST=git.example.com GITLAB_TOKEN=glpat-SECRET \
  gitlab_open_prs_of gitlab.com/me/app "$gpd"
expect "curl: the token is not sent to another host" "$(grep -c 'https://gitlab.com/api/v4/' "$CALLS"):$(grep -c SECRET "$CALLS")" "1:0"

# details: the same JSON shape as for GitHub.
glcli() { env -u DEPLOYS_LIB PATH="$gl/glab:$tmp/bin:/usr/bin:/bin" HOME="$tmp" NO_COLOR=1 /bin/bash ./deploys "$@" 2>&1 </dev/null; }
d="$(glcli details gitlab.com/me/app aaaa main)"
expect "details (GitLab): commits newest first, with their MRs" "$(echo "$d" | jq -c '[.commits[] | [.sha, .pr, .bot]]')" '[["bbbb",12,true],["c4",null,false],["c3",null,false],["c1",11,false]]'
expect "details (GitLab): files, lines, risky files, CI, open MRs" \
  "$(echo "$d" | jq -c '{files, additions, deletions, risky, onlyBots, compareUrl, checks, open:(.open | map([.number, .draft, .bot, .ci]))}')" \
  '{"files":2,"additions":3,"deletions":2,"risky":[".gitlab-ci.yml"],"onlyBots":false,"compareUrl":"https://gl/compare","checks":{"total":3,"failed":1,"running":1},"open":[[20,false,false,"none"],[21,true,false,"none"],[22,false,true,"none"],[23,false,true,"none"]]}'
expect "details (GitLab): the keys the app reads, as for GitHub" \
  "$(echo "$d" | jq -c 'keys')" '["additions","checks","commits","compareUrl","deletions","files","onlyBots","open","risky"]'

# doctor: gitlabCli and gitlabLoggedIn, from glab or from GITLAB_TOKEN.
expect "doctor: glab installed and logged in" "$(glcli doctor | jq -c '{gitlabCli, gitlabLoggedIn}')" '{"gitlabCli":true,"gitlabLoggedIn":true}'
expect "doctor: glab not logged in" "$(GLAB_AUTH=1 glcli doctor | jq -c '{gitlabCli, gitlabLoggedIn}')" '{"gitlabCli":true,"gitlabLoggedIn":false}'
gldoc() { env -u DEPLOYS_LIB PATH="$gl/curl:/usr/bin:/bin" HOME="$tmp" "$@" /bin/bash ./deploys doctor 2>/dev/null </dev/null | jq -c '{gitlabCli, gitlabLoggedIn}'; }
expect "doctor: a working GITLAB_TOKEN counts" "$(gldoc GITLAB_TOKEN=t)" '{"gitlabCli":false,"gitlabLoggedIn":true}'
expect "doctor: a refused GITLAB_TOKEN does not" "$(gldoc GITLAB_TOKEN=t GLSTUB=401)" '{"gitlabCli":false,"gitlabLoggedIn":false}'
expect "doctor: nothing set up" "$(gldoc)" '{"gitlabCli":false,"gitlabLoggedIn":false}'

# Vercel: a GitLab link is remembered with its project id, and deployed from it; GitHub as before.
real_vercel_call="$(declare -f vercel_call)"
vercel_call() { echo '{"link":{"type":"gitlab","projectId":"77","projectUrl":"https://gitlab.com/g/app","productionBranch":"prod"}}'; }
vercel() { local i=""; while [ $# -gt 0 ]; do [ "$1" = --input ] && i="$2"; shift; done
           [ -z "$i" ] || jq -c .gitSource "$i" >> "$CALLS"; echo '{"id":"d","url":"u","readyState":"QUEUED"}'; }
echo '{"gh":{"org":"me","repo":"app","ref":"main"}}' > "$REPOS"; rm -rf "$DEPLOYS_CONFIG/locks"; : > "$CALLS"
( vercel_off glv ) >/dev/null 2>&1
expect "vercel_off: a GitLab link is remembered" "$(jq -c '.glv | del(.offAt)' "$REPOS")" '{"type":"gitlab","repo":"gitlab.com/g/app","projectId":"77","ref":"prod"}'
( DEPLOYS_VERCEL_TEAM=t vercel_deploy_json glv "" abc ) >/dev/null 2>&1; ( DEPLOYS_VERCEL_TEAM=t vercel_deploy_json gh ) >/dev/null 2>&1
expect "vercel deploy: gitSource for GitLab and GitHub" "$(cat "$CALLS")" \
  $'{"type":"gitlab","ref":"prod","projectId":"77","sha":"abc"}\n{"type":"github","ref":"main","org":"me","repo":"app"}'
unset -f vercel; eval "$real_vercel_call"

# deploys without lib/ next to it (an old copy in ~/bin): GitHub works as before.
mkdir -p "$tmp/nolib"; cp deploys "$tmp/nolib/deploys"
expect "without lib/githost.sh: doctor still answers" \
  "$(env -u DEPLOYS_LIB PATH="$tmp/bin:/usr/bin:/bin" HOME="$tmp" /bin/bash "$tmp/nolib/deploys" doctor </dev/null | jq -c '{githubCli, gitlabLoggedIn}')" '{"githubCli":true,"gitlabLoggedIn":false}'
expect "without lib/githost.sh: GitHub counted, GitLab left unknown" \
  "$( (unset -f githost_of githost_available githost_head_of githost_pending_of githost_open_prs_of; DEPLOYS_LIB=1 . "$tmp/nolib/deploys"; set +e
       with_heads '[{"name":"gh","repo":"me/app","ref":"main","deployable":true,"lastSha":"aaaa"},{"name":"gl","repo":"gitlab.com/me/app","ref":"main","deployable":true,"lastSha":"aaaa"}]' \
       | jq -c 'map([.name, .pendingCommits, .headSha])') )" '[["gh",3,"bbbb"],["gl",null,null]]'
# --- autofix --only and the PR fields of autofix status ---
afonly() { ( set -e; PATH="$af/bin:$PATH" DEPLOYS_ROUTINE_TOKEN=sk-ant-oat01-SECRET DEPLOYS_NOTIFY=0 autofix_run "" "$@" ) >/dev/null 2>&1; echo $?; }
af_reset; OPENPRS='[]'; CLOSEDPRS='[]'
ALL='[{"platform":"vercel","name":"web","repo":"me/web","latestState":"ERROR","latestId":"d1","latestSha":"aaaa111"},
      {"platform":"render","name":"api","repo":"me/api","lastState":"build_failed","latestId":"r1","latestSha":"bbbb222"},
      {"platform":"vercel","name":"ok","repo":"me/ok","latestState":"READY","latestId":"d9","latestSha":"cccc"}]'
expect "autofix --only: hands over exactly the named one" "$(afonly render api):$(fired):$(jq -r '.fires[0].project' "$AUTOFIX_STATE")" "0:1:api"
: > "$CALLS"
expect "autofix --only: the same failure again is 3 (already fixing)" "$(afonly render api):$(fired)" "3:0"
expect "autofix --only: a project that did not fail is 2" "$(afonly vercel ok)" "2"
expect "autofix --only: an unknown project is 2" "$(afonly vercel nope)" "2"
af_reset; OPENPRS='[{"number":7,"ref":"claude/autofix-web-aaaa111"}]'
expect "autofix --only: an open autofix PR is 3" "$(afonly vercel web):$(fired)" "3:0"
OPENPRS='[]'; af_reset
jq -n --argjson t "$now" '{fires:[{deployId:"o1",project:"web",status:"fired",at:($t-100)},{deployId:"o2",project:"web",status:"failed",at:($t-200)}]}' > "$AUTOFIX_STATE"
expect "autofix --only: the per-project cap is 4" "$(afonly vercel web):$(fired)" "4:0"
af_reset; mkdir -p "$DEPLOYS_CONFIG/locks/autofix"
expect "autofix --only: a held lock is 6" "$(afonly vercel web)" "6"
rmdir "$DEPLOYS_CONFIG/locks/autofix"
af_reset; mv "$DEPLOYS_CONFIG/autofix-routine" "$af/routine.off"
out="$(env -u DEPLOYS_LIB PATH="$tmp/bin:/usr/bin:/bin" DEPLOYS_ROUTINE_TOKEN=sk-ant-x /bin/bash ./deploys autofix --only vercel web 2>&1 </dev/null)"; rc=$?
expect "autofix --only: no routine is 5" "$rc:$(echo "$out" | grep -c 'No routine set')" "5:1"
mv "$af/routine.off" "$DEPLOYS_CONFIG/autofix-routine"
out="$(env -u DEPLOYS_LIB PATH="$tmp/bin:/usr/bin:/bin" /bin/bash ./deploys autofix --only heroku web 2>&1 </dev/null)"; rc=$?
expect "autofix --only: a wrong platform is a usage error" "$rc:$(echo "$out" | grep -c 'Usage: deploys autofix --only')" "1:1"

# PR state per fire: open, then merged; only the exact fix branch counts.
af_reset
jq -n --argjson t "$((now - 600))" '{fires:[{deployId:"d1",project:"web",platform:"vercel",repo:"me/web",sha:"aaaa111",status:"fired",at:$t,session:"https://claude.ai/code/s1"}]}' > "$AUTOFIX_STATE"
ALL='[{"platform":"vercel","name":"web","repo":"me/web","latestState":"ERROR","latestId":"d1","latestSha":"aaaa111"}]'
OPENPRS='[{"number":5,"ref":"claude/autofix-web-app-aaaa111","url":"https://github.com/me/web/pull/5"},{"number":9,"ref":"claude/autofix-web-aaaa111","url":"https://github.com/me/web/pull/9"}]'
afrun >/dev/null
expect "autofix: an open fix PR is recorded (the exact branch, not web-app's)" "$(jq -c '.fires[0] | [.prNumber, .prState, .prUrl]' "$AUTOFIX_STATE")" '[9,"open","https://github.com/me/web/pull/9"]'
OPENPRS='[]'
CLOSEDPRS="[{\"number\":9,\"merged_at\":\"$(date -u +%Y-%m-%dT%H:%M:%SZ)\",\"closed_at\":\"$(date -u +%Y-%m-%dT%H:%M:%SZ)\",\"merge_commit_sha\":\"ffff999\",\"ref\":\"claude/autofix-web-aaaa111\",\"url\":\"https://github.com/me/web/pull/9\"}]"
afrun >/dev/null
st="$(env -u DEPLOYS_LIB PATH="$tmp/bin:/usr/bin:/bin" /bin/bash ./deploys autofix status --json </dev/null)"
expect "autofix status --json: prNumber, prState, prUrl, session, mergedSha (and pr kept)" \
  "$(echo "$st" | jq -c '.fires[0] | [.prNumber, .prState, .prUrl, .session, .mergedSha, .pr]')" '[9,"merged","https://github.com/me/web/pull/9","https://claude.ai/code/s1","ffff999",9]'
CLOSEDPRS='[]'; ALL='[]'

# --- auto-deploy on again, allowances, the guard ---
gd="$tmp/gd"; mkdir -p "$gd"
export DEPLOYS_NOTIFY=0
# The platforms: VLIST/RLIST are what is there; switches are logged; GFAIL names one that fails.
VLIST='[]'; RLIST='[]'; GFAIL=""
ad_platforms() { printf 'vercel\nrender\n'; }
ad_list_vercel() { [ "$VLIST" = down ] && { echo "Error: vercel: not logged in" >&2; return 1; }; echo "$VLIST"; }
ad_list_render() { echo "$RLIST"; }
ad_off() { [ "$2" = "$GFAIL" ] && { echo "Error: Vercel: could not disconnect $2" >&2; exit 1; }; echo "off $1 $2 $3" >> "$CALLS"; echo "$1: $2 no longer deploys on push"; }
ad_on() { [ "$2" = "$GFAIL" ] && { echo "Error: no" >&2; exit 1; }; echo "on $1 $2 $3 allowed=$(jq -c 'keys' "$ALLOW_FILE" 2>/dev/null)" >> "$CALLS"; }
# guard_run in $(…) runs in a subshell: its GUARD_ACTIONS come back through a file.
gr() { : > "$CALLS"; guard_run "$@" >/dev/null 2>&1; local r=$?; echo "$GUARD_ACTIONS" > "$gd/actions"; echo "$r"; }
gacts() { cat "$gd/actions"; }
offs() { grep '^off ' "$CALLS" | cut -d' ' -f2,3 | tr '\n' ',' ; }
locked() { [ -d "$DEPLOYS_CONFIG/locks/autodeploy" ] && echo locked || echo free; }
now="$(date +%s)"

rm -f "$ALLOW_FILE" "$GUARD_STATE"
VLIST='[{"name":"web","id":"web","auto":true},{"name":"blog","id":"blog","auto":true},{"name":"docs","id":"docs","auto":false}]'
RLIST='[{"name":"api","id":"srv-1","auto":true}]'
jq -n --argjson t "$now" '{"vercel:blog":($t+3600), "render:*":($t+3600), "vercel:old":($t-10)}' > "$ALLOW_FILE"
expect "guard: on without an allowance goes off; allowed ones stay on" "$(gr ""):$(offs)" "0:vercel web,"
expect "guard: an expired allowance is removed" "$(jq -c 'keys' "$ALLOW_FILE")" '["render:*","vercel:blog"]'
expect "guard: the lock is released" "$(locked)" "free"

jq -n --argjson t "$now" '{"vercel:web":($t-10)}' > "$ALLOW_FILE"; cp "$ALLOW_FILE" "$gd/before"
expect "guard --dry-run: switches nothing, removes nothing" "$(gr 1):$(offs):$(cmp -s "$ALLOW_FILE" "$gd/before" && echo same)" "0::same"
expect "guard --dry-run: says what it would do" "$(gacts | jq -c '[.[] | "\(.action) \(.platform) \(.project)"]')" '["wouldOff vercel web","wouldOff vercel blog","wouldOff render api"]'

# An allowance given between the listing and the switch wins (read again under the lock).
rm -f "$ALLOW_FILE"; RLIST='[]'; VLIST='[{"name":"web","id":"web","auto":true}]'
eval "$(declare -f ad_lock | sed '1s/ad_lock/ad_lock_real/')"
# The first lock is the expiry sweep, the second the switch: the allowance arrives in between.
ad_lock() { n=$(cat "$gd/race" 2>/dev/null); n=$((${n:-0} + 1)); echo "$n" > "$gd/race"
            [ "$n" = 2 ] && jq -n --argjson t "$now" '{"vercel:web":($t+600)}' > "$ALLOW_FILE"; ad_lock_real; }
rm -f "$gd/race" "$ALLOW_FILE"
expect "guard: an allowance given a moment before the switch wins" "$(gr ""):$(offs)" "0:"
rm -f "$gd/race"; unset -f ad_lock; eval "$(declare -f ad_lock_real | sed '1s/ad_lock_real/ad_lock/')"

# One failing switch: the rest is done, the lock is free, the run says so.
rm -f "$ALLOW_FILE"; GFAIL=web
VLIST='[{"name":"web","id":"web","auto":true},{"name":"blog","id":"blog","auto":true}]'; RLIST='[{"name":"api","id":"srv-1","auto":true}]'
expect "guard: one failing switch does not stop the others" "$(gr ""):$(offs):$(locked)" "1:vercel blog,render api,:free"
expect "guard: the failure is recorded" "$(gacts | jq -r '.[] | select(.action == "failed") | "\(.project): \(.error)"')" "web: Vercel: could not disconnect web"
GFAIL=""

# A platform that cannot be read is an error, never "nothing is on"; the other one still runs.
VLIST=down
expect "guard: an unreadable platform is an error, the other is still checked" "$(gr ""):$(offs)" "1:render api,"
expect "guard: the unreadable platform is in the actions" "$(gacts | jq -c '[.[] | select(.action == "error") | .platform]')" '["vercel"]'
VLIST='[]'

# First run after turning it on: only a dry run. The next one acts.
printf '#!/bin/bash\necho "launchctl $*" >> "$CALLS"\n' > "$tmp/bin/launchctl"; chmod +x "$tmp/bin/launchctl"
export DEPLOYS_LAUNCH_DIR="$gd/agents"; rm -f "$GUARD_STATE" "$ALLOW_FILE"
: > "$CALLS"; guard_schedule_on
expect "guard schedule on: writes and loads a job that runs guard every 30 minutes" \
  "$(grep -c '<string>guard</string>' "$gd/agents/app.deploycenter.guard.plist"):$(grep -c '<integer>1800</integer>' "$gd/agents/app.deploycenter.guard.plist"):$(grep -c 'launchctl bootstrap' "$CALLS")" "1:1:1"
expect "guard: the job is valid XML" "$(plutil -lint "$gd/agents/app.deploycenter.guard.plist" >/dev/null 2>&1 && echo ok || (command -v plutil >/dev/null && echo bad || echo ok))" "ok"
RLIST='[{"name":"api","id":"srv-1","auto":true}]'
: > "$CALLS"; guard_main "" >/dev/null 2>&1
expect "guard: the first run after turning it on changes nothing" "$(offs):$(jq -r '.lastDry' "$GUARD_STATE")" ":true"
: > "$CALLS"; guard_main "" >/dev/null 2>&1
expect "guard: the second run turns it off" "$(offs):$(jq -r '.lastDry' "$GUARD_STATE")" "render api,:false"
st="$(env -u DEPLOYS_LIB PATH="$tmp/bin:/usr/bin:/bin" /bin/bash ./deploys guard status --json </dev/null)"
expect "guard status --json: the shape the app reads" \
  "$(echo "$st" | jq -c '[.enabled, (.lastRun | type), (.lastActions[0] | [.platform, .project, .action, (.at | type), .error]), .allowances]')" \
  '[true,"number",["render","api","off","number",null],[]]'
guard_schedule_off
expect "guard schedule off: removes the job" "$([ -f "$gd/agents/app.deploycenter.guard.plist" ] && echo there || echo gone)" "gone"

# allow: written before the switch (a guard run in between sees it); a failed switch withdraws it.
rm -f "$ALLOW_FILE"; VLIST='[]'; RLIST='[]'
: > "$CALLS"; ( allow_main vercel web 4 ) >/dev/null 2>&1; rc=$?
expect "autodeploy allow: the allowance exists before auto-deploy is turned on" "$rc:$(grep '^on ' "$CALLS")" '0:on vercel web web allowed=["vercel:web"]'
exp="$(jq '."vercel:web"' "$ALLOW_FILE")"
expect "autodeploy allow: expires after the hours given" "$(( (exp - now + 30) / 3600 ))" "4"
GFAIL=blog; out="$( ( allow_main vercel blog 1 ) 2>&1)"; rc=$?
expect "autodeploy allow: a failed switch withdraws the allowance" "$rc:$(jq -c 'keys' "$ALLOW_FILE"):$(echo "$out" | grep -c withdrawn)" '1:["vercel:web"]:1'
GFAIL=""
out="$( ( allow_main vercel web 0 ) 2>&1)"; rc=$?
expect "autodeploy allow: hours outside 1-168 are refused" "$rc:$(echo "$out" | grep -c 'between 1 and 168')" "1:1"
out="$( ( allow_main heroku web 2 ) 2>&1)"; rc=$?
expect "autodeploy allow: a wrong platform is refused" "$rc" "1"
# --all: only Vercel projects whose repo is remembered are connected again.
echo '{"web":{"org":"me","repo":"web","ref":"main"}}' > "$REPOS"
VLIST='[{"name":"web","id":"web","auto":false},{"name":"lost","id":"lost","auto":false},{"name":"on","id":"on","auto":true}]'
RLIST='[{"name":"api","id":"srv-1","auto":false}]'
: > "$CALLS"; out="$( ( allow_main all --all 1 ) 2>&1)"; rc=$?
expect "autodeploy allow all --all: the * allowance, remembered ones on, unknown repos skipped" \
  "$rc:$(jq -c 'has("*")' "$ALLOW_FILE"):$(grep '^on ' "$CALLS" | cut -d' ' -f2,3 | tr '\n' ','):$(echo "$out" | grep -c '1 Vercel projects left manual')" "0:true:vercel web,render api,:1"
expect "autodeploy allowed --json: platform all, project * for everything" \
  "$(allow_list | jq -c '[.[] | [.platform, .project, (.expiresAt | type)]]')" '[["all","*","number"],["vercel","web","number"]]'

# revoke: the allowance goes; only what nothing else allows is turned off.
VLIST='[{"name":"web","id":"web","auto":true}]'; RLIST='[{"name":"api","id":"srv-1","auto":true}]'
: > "$CALLS"; ( revoke_main vercel web ) >/dev/null 2>&1
expect "autodeploy revoke: with * still running, the project stays on" "$(jq -c 'keys' "$ALLOW_FILE"):$(offs)" '["*"]:'
: > "$CALLS"; ( revoke_main all --all ) >/dev/null 2>&1
expect "autodeploy revoke all --all: everything withdrawn and off" "$(jq -c 'keys' "$ALLOW_FILE"):$(offs)" '[]:vercel web,render api,'
jq -n --argjson t "$now" '{"vercel:web":($t+600), "render:api":($t+600)}' > "$ALLOW_FILE"
: > "$CALLS"; ( revoke_main render --all ) >/dev/null 2>&1
expect "autodeploy revoke render --all: only that platform" "$(jq -c 'keys' "$ALLOW_FILE"):$(offs)" '["vercel:web"]:render api,'
echo '{}' > "$REPOS"

# Turning auto-deploy on: Vercel from the remembered repo (body on --input), Render "commit".
unset -f ad_on ad_off ad_list_vercel ad_list_render ad_platforms
cat > "$gd/vercel" <<'VC'
#!/bin/bash
echo "vercel $*" >> "$CALLS"; prev=""; for a in "$@"; do [ "$prev" = --input ] && sed 's/^/body /' "$a" >> "$CALLS"; prev="$a"; done; exit 0
VC
chmod +x "$gd/vercel"
out="$( (PATH="$gd:$PATH" DEPLOYS_VERCEL_TEAM=team_x vercel_on lost) 2>&1)"; rc=$?
expect "autodeploy-on: a Vercel project with an unknown repo stops with what to do" "$rc:$(echo "$out" | grep -c 'deploys vercel map lost')" "1:1"
echo '{"web":{"org":"me","repo":"web","ref":"main"}}' > "$REPOS"
: > "$CALLS"; (PATH="$gd:$PATH" DEPLOYS_VERCEL_TEAM=team_x vercel_on web) >/dev/null 2>&1
expect "autodeploy-on: Vercel gets POST /link with the remembered repo" \
  "$(grep -c '^vercel api /v9/projects/web/link?teamId=team_x --method POST' "$CALLS"):$(grep '^body ' "$CALLS" | cut -c6- | jq -c .)" '1:{"type":"github","repo":"me/web"}'
echo '{}' > "$REPOS"
render_call() { echo "render_call $*" >> "$CALLS"; echo '{}'; }
: > "$CALLS"; render_on srv-1 api >/dev/null
expect "autodeploy-on: Render is set to On Commit" "$(cat "$CALLS")" 'render_call PATCH /services/srv-1 {"autoDeployTrigger":"commit"}'
unset -f render_call
unset DEPLOYS_LAUNCH_DIR
# Savings (simulate, ledger) have their own file with fixtures.
bash tests/savings-tests.sh || fails=$((fails+1))

echo
[ "$fails" = 0 ] && echo "All script tests passed." || { echo "$fails failed."; exit 1; }
