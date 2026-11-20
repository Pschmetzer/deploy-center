#!/bin/bash
# Tests for providers/ghpages.sh. No network and no account: curl (a wrapper that logs the JSON body,
# then tests/lib/fake-curl.sh answers from tests/fixtures/ghpages), security and sleep are stand-ins.
# Run: bash tests/providers/ghpages.sh
set -uo pipefail
cd "$(dirname "$0")/../.." || exit 1
# The security stand-in reads stdin: never wait on a terminal.
exec </dev/null
fails=0
ok()   { echo "ok   $1"; }
fail() { echo "FAIL $1: $2"; fails=$((fails+1)); }
expect() { [ "$2" = "$3" ] && ok "$1" || fail "$1" "expected [$3], got [$2]"; }
has()  { case "$2" in *"$3"*) ok "$1" ;; *) fail "$1" "[$3] not in: $2" ;; esac; }

tmp="$(mktemp -d)"; trap 'rm -rf "$tmp"' EXIT
mkdir -p "$tmp/bin" "$tmp/real"
cp tests/lib/fake-curl.sh "$tmp/real/curl"
cat > "$tmp/bin/curl" <<'CURL'
#!/bin/bash
cfg="$(cat)"; prev=""; body=""
for a in "$@"; do [ "$prev" = --data-binary ] && body="$(cat "${a#@}")"; prev="$a"; done
echo "args $*" >> "$CALLS"; [ -z "$body" ] || echo "body $body" >> "$CALLS"
# NEWRUN: once the dispatch has gone out, the runs list gains a new run (a fixture swapped in).
case "$*" in *dispatches*) [ ! -f "${NEWRUN:-/nonexistent}" ] || cp "$NEWRUN" "$FIXTURES/ghpages/GET_repos_example_alpha_actions_workflows_pages.yml_runs_per_page_5_branch_main.json" ;; esac
printf '%s' "$cfg" | "$REAL_CURL" "$@"
CURL
cat > "$tmp/bin/security" <<'SEC'
#!/bin/bash
echo "security $* STDIN[$(cat)]" >> "$CALLS"
case "$1" in find-generic-password) exit 44 ;; esac
exit 0
SEC
printf '#!/bin/bash\nexit 0\n' > "$tmp/bin/sleep"
chmod +x "$tmp/bin"/* "$tmp/real"/*
export PATH="$tmp/bin:$PATH" REAL_CURL="$tmp/real/curl" FIXTURES="$tmp/fx" CALLS="$tmp/calls.log" DEPLOYS_CONFIG="$tmp/config" USER=tester
cp -R tests/fixtures "$tmp/fx"
export GITHUB_PAGES_TOKEN="ghp_secret_token_123"
export DEPLOYS_GHPAGES_SITES="example/alpha:pages.yml@main example/beta:deploy.yml@main example/gamma example/delta"
: > "$CALLS"
# shellcheck source=../../providers/ghpages.sh
. ./providers/ghpages.sh

R=5000000002
expect "meta: no push switch, rollback and logs refused, cancel yes" "$(ghpages_meta | jq -c '[.id, .keyEnv, .caps.off, .caps.rollback, .caps.logs, .caps.cancel]')" '["ghpages",["GITHUB_PAGES_TOKEN","GH_TOKEN","GITHUB_TOKEN"],false,false,false,true]'
expect "sites: defaults for workflow and branch" "$(ghpages_sites | jq -c '[.[] | [.repo, .workflow, .ref]]')" '[["example/alpha","pages.yml","main"],["example/beta","deploy.yml","main"],["example/gamma","pages.yml","main"],["example/delta","pages.yml","main"]]'
expect "sites: a bad entry is skipped, with a word" "$(DEPLOYS_GHPAGES_SITES='nope example/ok:x.yml@-bad example/fine:a.yml@dev' ghpages_sites 2>&1 | tr '\n' ' ')" 'GitHub Pages: "nope" in DEPLOYS_GHPAGES_SITES is not owner/name; skipped [{"repo":"example/fine","workflow":"a.yml","ref":"dev"}] '

j="$(ghpages_json)"
expect "json: phases" "$(echo "$j" | jq -cS 'map({(.name): .phase}) | add')" '{"alpha":"ready","beta":"building","delta":null,"gamma":"failed"}'
expect "json: sha and message of the newest successful run, repo and ref" "$(echo "$j" | jq -c '.[] | select(.name == "alpha") | [.lastSha[0:7], .lastMsg, .repo, .ref, .id, .lastState, .url, .domain]')" '["1a2b3c4","feat: new header","example/alpha","main","example/alpha","success","https://example.github.io/alpha/","example.github.io"]'
expect "json: no successful run, no live sha" "$(echo "$j" | jq -c '.[] | select(.name == "gamma") | .lastSha')" "null"
expect "json: Pages not readable is a warning, not an error" "$(echo "$j" | jq -c '.[] | select(.name == "delta") | [.fetchError, (.fetchWarn | length > 0), .url]')" "[null,true,null]"
expect "json: nothing is auto (a workflow's push trigger is not read)" "$(echo "$j" | jq -c 'map(.auto) | unique')" "[false]"
expect "json: the workflow page is the dashboard" "$(echo "$j" | jq -r '.[] | select(.name == "beta") | .dashboardUrl')" "https://github.com/example/beta/actions/workflows/deploy.yml"
expect "has: name and owner/repo, no call" "$(: > "$CALLS"; ghpages_has alpha):$(ghpages_has example/beta):$(ghpages_has nope >/dev/null; echo $?):$(grep -c '^curl' "$CALLS")" "example/alpha:example/beta:1:0"

expect "status: a run id" "$(ghpages_status alpha $R)" "$(printf '%s\tready\tsuccess' "$R")"
expect "status: an odd id is refused before a call" "$(: > "$CALLS"; (ghpages_status alpha '../x') >/dev/null 2>&1; echo $?:"$(grep -c '^curl' "$CALLS")")" "1:0"
expect "latest: in progress is building" "$(ghpages_latest beta | cut -f2,3)" "$(printf 'building\tin_progress')"
expect "latest: a site with no run is none" "$(ghpages_latest delta)" "$(printf 'none\t\t?')"
expect "url" "$(ghpages_url alpha):$(ghpages_url delta)" "https://example.github.io/alpha/:https://example.github.io/delta/"
expect "url --dashboard" "$(ghpages_url alpha --dashboard)" "https://github.com/example/alpha/actions/workflows/pages.yml"

# deploy: a dispatch on the branch, then the new run is looked for
: > "$CALLS"
d="$(ghpages_deploy_json alpha 2>/dev/null)"
expect "deploy: one dispatch POST with the branch as the body" "$(grep -c '^curl POST .*/workflows/pages.yml/dispatches' "$CALLS"):$(grep '^body ' "$CALLS" | sed 's/^body //')" '1:{"ref":"main"}'
expect "deploy: the run is not listed yet: queued, no id" "$(echo "$d" | jq -c '[.id, .phase, .url]')" '[null,"queued","https://example.github.io/alpha/"]'
printf '%s\n200\n' "$(head -n 1 tests/fixtures/ghpages/GET_repos_example_alpha_actions_workflows_pages.yml_runs_per_page_5_branch_main.json | jq -c '.workflow_runs |= ([{"id":5000000003,"status":"queued","conclusion":null,"head_sha":"4d4d4d4","head_branch":"main","event":"workflow_dispatch","created_at":"2026-03-03T10:00:00Z","html_url":"https://github.com/example/alpha/actions/runs/5000000003"}] + .)')" > "$tmp/newrun.json"
NEWRUN="$tmp/newrun.json" ghpages_deploy_json alpha > "$tmp/dj" 2>/dev/null
expect "deploy: the new run is named" "$(jq -c '[.id, .phase, .state, .dashboardUrl]' "$tmp/dj")" '["5000000003","queued","queued","https://github.com/example/alpha/actions/runs/5000000003"]'
rm -rf "$tmp/fx"; cp -R tests/fixtures "$tmp/fx"
for o in --sha --preview --no-cache; do
  : > "$CALLS"; msg="$( (ghpages_deploy_json alpha $o x) 2>&1 )"
  has "deploy $o is refused" "$msg" "GitHub Pages cannot"
  expect "deploy $o sends nothing" "$(grep -c '^curl' "$CALLS")" "0"
done
expect "deploy: a site that was never added is refused before a call" "$(: > "$CALLS"; (ghpages_deploy_json other/site) >/dev/null 2>&1; echo $?:"$(grep -c '^curl' "$CALLS")")" "1:0"
# GitHub refuses the dispatch (no workflow_dispatch trigger: 422): said, with the hint
expect "deploy: a refused dispatch says what to check" "$( (ghpages_deploy_json beta) 2>&1 | grep -c 'workflow_dispatch')" "1"

# cancel
: > "$CALLS"
expect "cancel" "$(ghpages_cancel beta 5000000010 | jq -c '[.id, .phase]')" '["5000000010","canceled"]'
expect "cancel: a POST on the run" "$(grep -c '^curl POST .*/actions/runs/5000000010/cancel' "$CALLS")" "1"
expect "cancel: an odd run id is refused" "$( (ghpages_cancel beta 'x;y') >/dev/null 2>&1; echo $?)" "1"
for f in "ghpages_off alpha" "ghpages_rollback alpha" "ghpages_logs alpha 10"; do
  : > "$CALLS"; msg="$( ($f) 2>&1 )"; rc=$?
  expect "$f is refused: $rc, nothing sent" "$rc:$(grep -c '^curl' "$CALLS")" "1:0"
  has "$f says so" "$msg" "GitHub Pages cannot"
done

# add / remove
rm -rf "$tmp/config"; unset DEPLOYS_GHPAGES_SITES
expect "add" "$(ghpages_cli_add example/zeta deploy.yml release | head -n 1)" "GitHub Pages: example/zeta added (workflow deploy.yml on release). The workflow needs \`on: workflow_dispatch\`."
expect "add: kept in the file, defaults for the rest" "$(ghpages_cli_add example/eta >/dev/null; jq -c 'map([.repo, .workflow, .ref])' "$tmp/config/ghpages.json")" '[["example/zeta","deploy.yml","release"],["example/eta","pages.yml","main"]]'
expect "add: the same repo again replaces it" "$(ghpages_cli_add example/zeta other.yml >/dev/null; jq -c 'map(.workflow)' "$tmp/config/ghpages.json")" '["pages.yml","other.yml"]'
expect "add: a bad name is refused" "$( (ghpages_cli_add 'a b') 2>&1 | grep -c 'is not owner/name'):$( (ghpages_cli_add example/x 'x;y.yml') 2>&1 | grep -c 'not a workflow file'):$( (ghpages_cli_add example/x pages.yml '--x') 2>&1 | grep -c 'not a branch')" "1:1:1"
expect "the file is private" "$(stat -c %a "$tmp/config/ghpages.json" 2>/dev/null || stat -f %Lp "$tmp/config/ghpages.json")" "600"
expect "remove" "$(ghpages_cli_remove example/eta; ghpages_sites | jq -c 'map(.repo)')" 'GitHub Pages: example/eta removed.
["example/zeta"]'
expect "remove: an unknown repo is an error" "$( (ghpages_cli_remove example/none) >/dev/null 2>&1; echo $?)" "1"

# The token travels on stdin only
: > "$CALLS"; DEPLOYS_GHPAGES_SITES="example/alpha" ghpages_json >/dev/null
expect "the token is in no logged call" "$(grep -c 'ghp_secret_token_123' "$CALLS")" "0"

# set-key
: > "$CALLS"
expect "set-key saves a working token" "$(printf 'ghp_new\n' | ghpages_set_key 2>&1 | tail -n 1)" "GitHub token saved and working."
expect "set-key: the token went to security on stdin" "$(grep -c '^security -i STDIN\[add-generic-password .* -s deploy-center-ghpages -w ghp_new\]' "$CALLS")" "1"
: > "$CALLS"
expect "set-key refuses a token GitHub does not take" "$(printf 'ghp_bad\n' | CURLSTUB=401 ghpages_set_key 2>&1 | grep -c 'nothing was saved'):$(grep -c '^security -i' "$CALLS")" "1:0"
expect "set-key refuses a space or a quote" "$(printf 'a b\n' | ghpages_set_key 2>&1 | grep -c 'does not look like'):$(printf 'a"b\n' | ghpages_set_key 2>&1 | grep -c 'does not look like')" "1:1"

rm -rf "$tmp/config"; export DEPLOYS_GHPAGES_SITES="example/alpha example/beta"
doc="$(ghpages_doctor)"
expect "doctor: key, sites and the rate limit from the body" "$(echo "$doc" | jq -c '[.key, .keyOk, .sites, .expiresAt, .rateLimit]')" '["env",true,2,null,{"remaining":4990,"resetAt":1772700000}]'
expect "doctor: a refused token is reported" "$(CURLSTUB=401 ghpages_doctor | jq -c '[.keyOk, (.error | length > 0)]')" "[false,true]"
expect "ready: needs sites too" "$(ghpages_ready; echo $?):$(DEPLOYS_GHPAGES_SITES='' ghpages_ready; echo $?)" "0:1"

echo
[ "$fails" = 0 ] && echo "All GitHub Pages tests passed." || { echo "$fails failed."; exit 1; }
