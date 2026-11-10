#!/bin/bash
# Tests for providers/vercel.sh beyond the shared contract: a failing or odd answer must never
# break the whole list (the banner "jq: invalid JSON text passed to --argjson"), reads are asked
# again on a passing failure and writes never, a hung CLI ends, the team is never dropped.
# No network: vercel is tests/lib/fake-vercel.sh behind a wrapper. Run: bash tests/providers/vercel.sh
# Run it under /bin/bash too: macOS's bash 3.2 is where `${x:-{\}}` keeps its backslash.
set -uo pipefail
cd "$(dirname "$0")/../.." || exit 1
root="$PWD"
fails=0
ok()   { echo "ok   $1"; }
fail() { echo "FAIL $1: $2"; fails=$((fails+1)); }
expect() { [ "$2" = "$3" ] && ok "$1" || fail "$1" "expected [$3], got [$2]"; }

tmp="$(mktemp -d)"; trap 'rm -rf "$tmp"' EXIT
mkdir -p "$tmp/bin" "$tmp/fx"
cp -R tests/fixtures/vercel "$tmp/fx/vercel"
cp tests/lib/fake-vercel.sh "$tmp/bin/vercel-fake"
# The wrapper in front of the stand-in. VFAIL: a path part whose call fails; VFAIL_ONCE=1 only the
# first time. VFAIL_MSG: what the CLI says then. VHANG: a path part whose call never answers.
cat > "$tmp/bin/vercel" <<'SH'
#!/bin/bash
if [ -n "${VHANG:-}" ] && [ "${1:-}" = api ] && case "${2:-}" in *"$VHANG"*) true;; *) false;; esac; then
  echo "vercel $* (hung)" >> "${CALLS:-/dev/null}"; exec /bin/sleep 30
fi
if [ -n "${VFAIL:-}" ] && [ "${1:-}" = api ] && case "${2:-}" in *"$VFAIL"*) true;; *) false;; esac; then
  if [ -z "${VFAIL_ONCE:-}" ] || [ ! -f "$VSTATE" ]; then
    : > "$VSTATE"; echo "vercel $* (failed)" >> "${CALLS:-/dev/null}"
    echo "${VFAIL_MSG:-Error: fetch failed}" >&2; exit 1
  fi
fi
exec "$(dirname "$0")/vercel-fake" "$@"
SH
printf '#!/bin/bash\nexit 44\n' > "$tmp/bin/security"
printf '#!/bin/bash\nexit 0\n' > "$tmp/bin/sleep"
chmod +x "$tmp/bin"/*
export FIXTURES="$tmp/fx" CALLS="$tmp/calls.log" VSTATE="$tmp/vstate"
STUBPATH="$tmp/bin:/usr/bin:/bin"

lib() {  # lib <shell code>: the code with deploys sourced, under /bin/bash (bash 3.2 on macOS)
  rm -f "$VSTATE"
  ( PATH="$STUBPATH" DEPLOYS_CONFIG="$tmp/config" HOME="$tmp" NO_COLOR=1 DEPLOYS_LIB=1 \
      /bin/bash -c '. ./deploys; set +e; '"$1" 2>"$tmp/err" </dev/null )
}
fresh() { rm -rf "$tmp/config"; mkdir -p "$tmp/config"; cp tests/fixtures/vercel/config/* "$tmp/config/"; : > "$CALLS"; }
export DEPLOYS_VERCEL_TEAM=team_fixture
calls() { grep -c "${1}" "$CALLS"; }

# --- the banner: the newest-deploys call fails, the list still comes ---
fresh
out="$(VFAIL=/v6/deployments lib 'vercel_json')"; rc=$?
expect "deployments call down: the list still comes" "$rc:$(echo "$out" | jq -r 'type' 2>&1):$(echo "$out" | jq length)" "0:array:4"
expect "deployments call down: no jq error" "$(grep -c 'jq:' "$tmp/err")" "0"
expect "deployments call down: marked partial, and said why" \
  "$(echo "$out" | jq -c '[.[].partial] | unique'):$(grep -c 'newest builds could not be read' "$tmp/err")" "[true]:1"
expect "deployments call down: the live state still shows" "$(echo "$out" | jq -r '.[] | select(.name == "alpha") | .phase')" "ready"
expect "deployments call down: a read is asked three times" "$(calls 'v6/deployments?limit=100')" "3"

fresh
out="$(VFAIL=/v6/deployments VFAIL_ONCE=1 lib 'vercel_json')"
expect "one blip: asked again, nothing missing" \
  "$(echo "$out" | jq -c '[(.[] | select(.name == "beta") | .phase), ([.[] | has("partial")] | any)]'):$(calls 'v6/deployments?limit=100')" '["building",false]:2'

# An answer that is not JSON (a proxy's login page with exit 0): partial, not an abort.
fresh
printf '<html>sign in</html>\n200\n' > "$tmp/fx/vercel/GET_v6_deployments_limit_100_target_production.json"
out="$(lib 'vercel_json')"; rc=$?
expect "HTML answer: the list still comes, partial" "$rc:$(echo "$out" | jq -c '[.[].partial] | unique'):$(grep -c 'jq:' "$tmp/err")" "0:[true]:0"
cp tests/fixtures/vercel/GET_v6_deployments_limit_100_target_production.json "$tmp/fx/vercel/"

# A GitLab commit counts as well as a GitHub one.
fresh
sed 's/"githubCommitSha":"a1a1a1a"/"gitlabCommitSha":"a1a1a1a"/' tests/fixtures/vercel/GET_v10_projects_limit_100.json > "$tmp/fx/vercel/GET_v10_projects_limit_100.json"
expect "a GitLab commit is the live commit" "$(lib 'vercel_json' | jq -r '.[] | select(.name == "alpha") | .lastSha')" "a1a1a1a"
cp tests/fixtures/vercel/GET_v10_projects_limit_100.json "$tmp/fx/vercel/"

# --- what is asked again, and what never ---
fresh
lib 'vercel_has nope' >/dev/null; rc=$?
expect "not found: exit 1, asked once (a 404 is an answer)" "$rc:$(calls 'v9/projects/nope')" "1:1"
fresh
VFAIL=/v9/projects/alpha lib 'vercel_has alpha' >/dev/null; rc=$?
expect "network down: _has says 2 (not \"not found\") with the reason" "$rc:$(grep -c 'fetch failed' "$tmp/err")" "2:1"
fresh
VFAIL=/v12/deployments lib 'vercel_cancel alpha dpl_x' >/dev/null; rc=$?
expect "a write is never repeated, and the reason is named" "$rc:$(calls 'v12/deployments'):$(grep -c 'fetch failed' "$tmp/err")" "1:1:1"
fresh
VFAIL=/v6/deployments VFAIL_MSG='Error: Not Found (404)' lib 'vercel_latest alpha' >/dev/null
expect "a 404 is not asked again" "$(calls 'v6/deployments?app=alpha')" "1"
fresh
VFAIL=/v6/deployments VFAIL_MSG='Error: Too Many Requests (429)' lib 'vercel_latest alpha' >/dev/null
expect "a 429 is asked again" "$(calls 'v6/deployments?app=alpha')" "3"

# A hung CLI ends: 142 after the time limit, said in words.
fresh
start=$(date +%s)
VHANG=/v13/deployments DEPLOYS_VERCEL_TIMEOUT=1 lib 'vercel_status alpha dpl_alpha2' >/dev/null; rc=$?
took=$(( $(date +%s) - start ))
expect "hung CLI: ends, and says it" "$([ "$took" -lt 15 ] && echo fast):$(grep -c 'no answer within 1 s' "$tmp/err")" "fast:1"

# --- the team is never dropped ---
fresh
out="$(DEPLOYS_VERCEL_TEAM="" VFAIL=/v2/teams lib 'vercel_call /v9/projects/alpha')"; rc=$?
expect "team unknown: no call without it" "$rc:$(grep -c 'v9/projects/alpha' "$CALLS")" "1:0"
expect "team unknown: the reason is the CLI's, not only \"log in\"" "$(grep -c 'fetch failed' "$tmp/err")" "1"
fresh
printf '{"teams":[{"id":"t1","slug":"a"},{"id":"t2","slug":"b"}]}\n200\n' > "$tmp/fx/vercel/GET_v2_teams.json"
DEPLOYS_VERCEL_TEAM="" lib 'vercel_off alpha' >/dev/null; rc=$?
expect "several teams: off stops, nothing sent" "$rc:$(grep -cE 'DELETE|/v9/projects/alpha' "$CALLS"):$(grep -c 'Several Vercel teams' "$tmp/err")" "1:0:1"
printf '{"error":{"code":"rate_limited"}}\n200\n' > "$tmp/fx/vercel/GET_v2_teams.json"
DEPLOYS_VERCEL_TEAM="" lib 'vercel_team' >/dev/null; rc=$?
expect "an answer without teams is not cached as \"no team\"" "$rc:$([ -e "$tmp/config/vercel-team" ] && echo cached || echo none)" "1:none"
rm -f "$tmp/fx/vercel/GET_v2_teams.json"

# --- off and on ---
fresh
printf '{"id":"prj_bb","name":"bb","link":{"type":"bitbucket","owner":"me","slug":"bb","productionBranch":"main"}}\n200\n' > "$tmp/fx/vercel/GET_v9_projects_bb.json"
lib 'vercel_off bb' >/dev/null; rc=$?
expect "repo not written down: stays connected" "$rc:$(grep -c 'DELETE' "$CALLS"):$(grep -c 'stays connected' "$tmp/err")" "1:0:1"
fresh
jq '. + {gl:{type:"gitlab", repo:"gitlab.com/grp/gl", projectId:7, ref:"main"}}' tests/fixtures/vercel/config/vercel-repos.json > "$tmp/config/vercel-repos.json"
printf '{}\n200\n' > "$tmp/fx/vercel/POST_v9_projects_gl_link.json"
# The body the stand-in was sent: the wrapper keeps it.
sed -i.bak 's|^exec "$(dirname "$0")/vercel-fake" "$@"|for a in "$@"; do [ "${p:-}" = --input ] \&\& cp "$a" "$CALLS.body"; p="$a"; done\nexec "$(dirname "$0")/vercel-fake" "$@"|' "$tmp/bin/vercel"
out="$(lib 'vercel_on_one gl')"; rc=$?
expect "on: a GitLab project is linked as GitLab" "$rc:$(jq -c . "$CALLS.body" 2>&1)" '0:{"type":"gitlab","repo":"grp/gl"}'

# --- no `${x:-{\}}` anywhere here: under bash 3.2 that is the text {\} ---
expect "no \${x:-{\\}} default in providers/ or lib/githost.sh" \
  "$(grep -n ':-{\\}}' providers/*.sh lib/githost.sh | wc -l | tr -d ' ')" "0"

# --- PRV-020: 100 attempts of a busy project push the others out: further pages ---
fresh
fx="$tmp/fx/vercel"
jq -n '{deployments: [range(100) | {uid: "dpl_b\(.)", name: "beta", state: "READY", created: (1767312000000 - .), meta: {}}],
        pagination: {next: 1767000000000}}' | { cat; echo; echo 200; } > "$fx/GET_v6_deployments_limit_100_target_production.json"
printf '%s\n200\n' '{"deployments":[{"uid":"dpl_alpha9","name":"alpha","state":"BUILDING","created":1767200000000,"meta":{}},{"uid":"dpl_gamma9","name":"gamma","state":"READY","created":1767100000000,"meta":{}}],"pagination":{"next":null}}' \
  > "$fx/GET_v6_deployments_limit_100_target_production_until_1767000000000.json"
out="$(lib 'vercel_json')"
expect "a second page is read while a deployed project is missing" \
  "$(echo "$out" | jq -c '[.[] | select(.name == "alpha" or .name == "gamma") | [.name, .phase]]'):$(calls 'until=1767000000000')" '[["alpha","building"],["gamma","ready"]]:1'
printf '<html>sign in</html>\n200\n' > "$fx/GET_v6_deployments_limit_100_target_production_until_1767000000000.json"
fresh; out="$(lib 'vercel_json')"
expect "a follow page that is not a list: page one stays, partial" "$(echo "$out" | jq -c '[(.[] | select(.name == "beta") | .latestId), ([.[].partial] | unique)]')" '["dpl_b0",[true]]'
rm -f "$fx/GET_v6_deployments_limit_100_target_production_until_1767000000000.json"
fresh; out="$(lib 'vercel_json')"
expect "a follow page that fails: the list still comes, partial" "$(echo "$out" | jq -c '[length, ([.[].partial] | unique)]')" '[4,[true]]'
cp tests/fixtures/vercel/GET_v6_deployments_limit_100_target_production.json "$fx/"
fresh; lib 'vercel_json' >/dev/null
expect "one page that is not full: no second one" "$(calls 'until=')" "0"

# --- PRV-027: connected but not written down: deployable from the live link ---
fresh
jq 'del(.alpha)' tests/fixtures/vercel/config/vercel-repos.json > "$tmp/config/vercel-repos.json"
expect "a live GitHub link is deployable" "$(lib 'vercel_json' | jq -c '.[] | select(.name == "alpha") | [.deployable, .repo]')" '[true,"example/alpha"]'
printf '%s\n200\n' '{"name":"alpha","link":{"type":"github","org":"example","repo":"alpha","repoId":42,"productionBranch":"trunk"}}' > "$fx/GET_v9_projects_alpha.json"
# A wrapper in front of the wrapper that keeps the --input body of the call.
mkdir -p "$tmp/vb"
cat > "$tmp/vb/vercel" <<SH
#!/bin/bash
prev=""; for a in "\$@"; do [ "\$prev" = --input ] && cp "\$a" "\$VBODY"; prev="\$a"; done
exec "$tmp/bin/vercel" "\$@"
SH
chmod +x "$tmp/vb/vercel"
out="$(VBODY="$tmp/body.json" STUBPATH="$tmp/vb:$STUBPATH" lib 'vercel_start alpha "" ""')"; rc=$?
expect "deploy from the live link" "$rc:$(jq -c '.gitSource' "$tmp/body.json" 2>/dev/null)" '0:{"type":"github","ref":"trunk","repoId":42}'
printf '%s\n200\n' '{"name":"alpha","link":null}' > "$fx/GET_v9_projects_alpha.json"
: > "$CALLS"; out="$(lib 'vercel_start alpha "" ""' 2>&1)"; rc=$?
expect "no link and nothing written down: refused, nothing started" "$rc:$(grep -c 'no remembered repo' "$tmp/err"):$(calls 'POST')" "1:1:0"
cp tests/fixtures/vercel/GET_v9_projects_alpha.json "$fx/"

# --- FEA-110: autodeploy-on --dry-run lists what would be connected again, and writes nothing ---
fresh
out="$(lib 'vercel_on --all --dry-run --json')"; rc=$?
expect "FEA-110: --all --dry-run --json is a plan" "$rc:$(echo "$out" | jq -c '[.provider, .dryRun, (.items | type), (.on + .skipped == (.items | length))]')" '0:["vercel",true,"array",true]'
expect "FEA-110: only reads" "$(grep -cE -- '--method (POST|PATCH|PUT|DELETE)' "$CALLS")" 0
expect "FEA-110: each item says on, skip or already" "$(echo "$out" | jq -c '[.items[].action] | all(. == "on" or . == "skip" or . == "already")')" true
expect "FEA-110: _meta says onDryRun (older copies would really switch on)" "$(lib vercel_meta | jq .onDryRun)" true
out="$(lib 'vercel_on --all --dry-run')"
expect "FEA-110: the text form ends with nothing changed" "$(echo "$out" | tail -n 1)" "Dry run: nothing changed."

# --- FEA-042: a production build of a given commit must be on the remembered branch ---
# gh: compare <ref>...<sha> answers GHCMP (identical, behind, ahead, diverged); GHCMP=down fails.
cat > "$tmp/bin/gh" <<'SH'
#!/bin/bash
echo "gh $*" >> "${CALLS:-/dev/null}"
[ "${GHCMP:-}" != down ] || exit 1
[ "${GHCMP:-}" != 404 ] || { echo "gh: Not Found (HTTP 404)" >&2; exit 1; }
case "$*" in *"/compare/"*) echo "${GHCMP:-behind}" ;; esac
SH
chmod +x "$tmp/bin/gh"
fresh
out="$(GHCMP=behind lib 'vercel_deploy_json alpha --sha abc1234def' | jq -r .id)"
expect "FEA-042: a commit on main is deployed" "$out:$(calls 'gh api repos/example/alpha/compare/main...abc1234def')" "dpl_alpha3:1"
fresh
GHCMP=diverged lib 'vercel_deploy_json alpha --sha abc1234def' >/dev/null; rc=$?
expect "FEA-042: a commit off the branch is refused, nothing sent" "$rc:$(calls -- '--method POST'):$(grep -c 'not on example/alpha main (diverged)' "$tmp/err")" "1:0:1"
fresh
out="$(GHCMP=ahead DEPLOYS_VERCEL_ANY_SHA=1 lib 'vercel_deploy_json alpha --sha abc1234def' | jq -r .id)"
expect "FEA-042: DEPLOYS_VERCEL_ANY_SHA=1 allows it, without asking" "$out:$(calls '/compare/')" "dpl_alpha3:0"
fresh
out="$(GHCMP=down lib 'vercel_deploy_json alpha --sha abc1234def' | jq -r .id)"
expect "FEA-042: GitHub not reachable: a warning, deployed" "$out:$(grep -c 'could not check' "$tmp/err")" "dpl_alpha3:1"
fresh
GHCMP=404 lib 'vercel_deploy_json alpha --sha abc1234def' >/dev/null; rc=$?
expect "FEA-042: a commit GitHub does not know there is refused" "$rc:$(calls -- '--method POST'):$(grep -c 'does not know abc1234' "$tmp/err")" "1:0:1"
fresh
GHCMP=diverged lib 'vercel_deploy_json alpha --preview --sha abc1234def' >/dev/null
expect "FEA-042: a preview is not checked" "$(calls '/compare/')" 0
rm -f "$tmp/bin/gh"

: "$root"
echo; [ "$fails" = 0 ] && echo "All vercel tests passed." || { echo "$fails vercel tests failed."; exit 1; }
