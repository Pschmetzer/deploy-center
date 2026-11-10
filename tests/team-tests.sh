#!/bin/bash
# Tests for team mode (lib/team.sh): the merge order of the shared config, observer mode, and
# the two-person rule. No network: `gh` and `vercel` are stand-ins that answer from
# tests/fixtures/team. Run: tests/team-tests.sh
set -uo pipefail
cd "$(dirname "$0")/.." || exit 1
fails=0
ok()   { echo "ok   $1"; }
fail() { echo "FAIL $1: $2"; fails=$((fails+1)); }
expect() { [ "$2" = "$3" ] && ok "$1" || fail "$1" "expected [$3], got [$2]"; }
has()  { case "$2" in *"$3"*) ok "$1" ;; *) fail "$1" "no [$3] in: $(printf '%s' "$2" | head -c 600)" ;; esac; }
hasnt() { case "$2" in *"$3"*) fail "$1" "[$3] in: $(printf '%s' "$2" | head -c 600)" ;; *) ok "$1" ;; esac; }

tmp="$(mktemp -d)"; trap 'rm -rf "$tmp"' EXIT
export DEPLOYS_CONFIG="$tmp/config" FIX="$PWD/tests/fixtures/team" CALLS="$tmp/calls.log"
export DEPLOYS_VERCEL_TEAM=tm1 GH_USER=dev-one GH_HEAD=""
mkdir -p "$tmp/bin" "$DEPLOYS_CONFIG"; : > "$CALLS"

# gh: `gh api [flags] <path>`. Files in a repo come from fixtures/team/files, everything else
# from fixtures/team/api; GH_DOWN=<owner/repo> makes that repo answer 500, GH_USER is the login.
cat > "$tmp/bin/gh" <<'GH'
#!/bin/bash
echo "gh $*" >> "$CALLS"
[ "${1:-}" = api ] || exit 1; shift
path=""; jqx=""
while [ $# -gt 0 ]; do
  case "$1" in --jq) jqx="$2"; shift;; -H|--cache) shift;; --paginate) ;; -*) ;; *) path="$1";; esac; shift
done
answer() { if [ -n "$jqx" ]; then jq -r "$jqx"; else cat; fi; }
case "$path" in
  user) echo "{\"login\":\"$GH_USER\"}" | answer; exit 0 ;;
  repos/*/contents/*)
    repo="${path#repos/}"; repo="${repo%%/contents/*}"; file="${path#*/contents/}"
    [ "$repo" != "${GH_DOWN:-}" ] || { echo "gh: Server Error (HTTP 500)" >&2; exit 1; }
    [ -f "$FIX/files/$repo/$file" ] || { echo "gh: Not Found (HTTP 404)" >&2; exit 1; }
    jq -n --rawfile c "$FIX/files/$repo/$file" '{sha:"f1x", content:($c | @base64)}' | answer; exit 0 ;;
  repos/acme/shop/commits/main|repos/acme/shop/commits/release)
    [ -n "$GH_HEAD" ] || exit 1; echo "{\"sha\":\"$GH_HEAD\"}" | answer; exit 0 ;;
esac
f="$FIX/api/$(printf '%s' "$path" | tr '/?&=' '____').json"
[ -f "$f" ] || { echo "gh: Not Found (HTTP 404)" >&2; exit 1; }
answer < "$f"
GH
# vercel: the project exists; a deploy is logged with the commit it pins, and answers an id.
cat > "$tmp/bin/vercel" <<'VC'
#!/bin/bash
[ "${1:-}" = api ] || exit 0
url="$2"; m=GET; input=""; shift 2
while [ $# -gt 0 ]; do case "$1" in --method) m="$2"; shift;; --input) input="$2"; shift;; esac; shift; done
case "$m $url" in
  "POST /v13/deployments"*) echo "vercel POST sha=$(jq -r '.gitSource.sha // "none"' "$input") ref=$(jq -r .gitSource.ref "$input") target=$(jq -r '.target // "preview"' "$input")" >> "$CALLS"
    echo '{"id":"dpl_1","url":"web-1.vercel.app","readyState":"QUEUED"}' ;;
  "GET /v9/projects/web"*|"GET /v9/projects/docs"*) echo '{"name":"x","id":"p1"}' ;;
  *) echo '{"error":{"message":"not found"}}'; exit 1 ;;
esac
VC
chmod +x "$tmp/bin"/*
export PATH="$tmp/bin:$PATH"
D=(bash ./deploys)
fresh() { rm -rf "$DEPLOYS_CONFIG/team-cache" "$DEPLOYS_CONFIG/locks"; }

# --- the merge order: repo file < this Mac's files ---
cat > "$DEPLOYS_CONFIG/vercel-repos.json" <<'EOF'
{"web":{"org":"acme","repo":"shop","ref":"main"},"docs":{"org":"acme","repo":"shop","ref":"main"}}
EOF
echo '["old-site"]' > "$DEPLOYS_CONFIG/ignored.json"
echo '{"projects":{"web":{"health":"/up","approvals":0},"playground":{"ignored":false}}}' > "$DEPLOYS_CONFIG/overrides.json"
printf 'acme/tools\nacme/empty\n' > "$DEPLOYS_CONFIG/team-repos"

cfg="$("${D[@]}" config --json)"; rc=$?
expect "config --json answers" "$rc" "0"
q() { echo "$cfg" | jq -r "$1"; }
expect "a project's repo file is found through vercel-repos.json" "$(q '.sources[] | select(.repo=="acme/shop") | "\(.found) \(.path)"')" "true deploy-center.json"
expect ".deploy-center.json is read when deploy-center.json is not there" "$(q '.sources[] | select(.repo=="acme/tools") | .path')" ".deploy-center.json"
expect "a repo without a file is found:false, not an error" "$(q '.sources[] | select(.repo=="acme/empty") | "\(.found) \(.error)"')" "false null"
expect "branch: vercel-repos.json wins over the repo file" "$(q '.projects.web.branch | "\(.value) \(.from)"')" "main vercel-repos.json"
expect "health: overrides.json wins over the project entry" "$(q '.projects.web.health | "\(.value) \(.from)"')" "/up overrides.json"
expect "health: the file's default fills a project without one" "$(q '.projects.docs.health | "\(.value) \(.from)"')" "/api/health acme/shop:deploy-center.json"
expect "approvals: the file default applies to its projects" "$(q '.projects.web.approvals | "\(.value) \(.from)"')" "1 acme/shop:deploy-center.json"
expect "approvals: a project entry in the file may lower it" "$(q '.projects.docs.approvals.value')" "0"
expect "approvals: the project entry wins over the file default" "$(q '.projects.api.approvals.value')" "2"
expect "a project named only in a file deploys from that repo" "$(q '.projects.api.repo | "\(.value) \(.from)"')" "acme/shop acme/shop:deploy-center.json"
expect "a project in another repo's file takes that repo" "$(q '.projects.cli | "\(.repo.value) \(.branch.value)"')" "acme/tools stable"
expect "window from the repo file" "$(q '.projects.web.window | "\(.value.from)-\(.value.to) \(.from)"')" "09:00-16:00 acme/shop:deploy-center.json"
expect "ignored: overrides.json counts a team-ignored project again" "$(q '.projects.playground.ignored | "\(.value) \(.from)"')" "false overrides.json"
expect "ignored: ignored.json still works" "$(q '.projects["old-site"].ignored | "\(.value) \(.from)"')" "true ignored.json"
expect "groups from the file" "$(q '.groups.shop.value | join(",")')" "api,web"
expect "observers of all files are joined" "$(q '.observers.value | join(",")')" "dev-five,dev-watcher"
expect "not an observer by default" "$(q '.readonly | "\(.value) \(.from)"')" "false default"

echo '{"days":["fri"],"from":"10:00","to":"12:00","tz":"UTC"}' > "$DEPLOYS_CONFIG/window.json"
echo '{"approvals":3,"projects":{"docs":{"approvals":1}}}' > "$DEPLOYS_CONFIG/overrides.json"
cfg="$("${D[@]}" config --json)"
expect "window.json wins over the repo file's window" "$(q '.projects.web.window | "\(.value.days[0]) \(.from)"')" "fri window.json"
expect "a higher local approvals number tightens" "$(q '.projects.web.approvals | "\(.value) \(.from)"')" "3 overrides.json"
expect "a higher local number for one project tightens it" "$(q '.projects.docs.approvals | "\(.value) \(.from)"')" "3 overrides.json"
rm -f "$DEPLOYS_CONFIG/window.json"
echo '{"projects":{"web":{"health":"/up","approvals":0},"playground":{"ignored":false}}}' > "$DEPLOYS_CONFIG/overrides.json"

# The cache: read once in ten minutes; a failure keeps the old copy, marked stale.
: > "$CALLS"; "${D[@]}" config --json >/dev/null
expect "the shared files are cached (no second read)" "$(grep -c 'contents/' "$CALLS")" "0"
c="$DEPLOYS_CONFIG/team-cache/acme__shop.json"; jq -c '.fetchedAt = 1577836800' "$c" > "$c.t" && mv "$c.t" "$c"; touch -t 202001010000 "$c"
cfg="$(GH_DOWN=acme/shop "${D[@]}" config --json)"
expect "GitHub down: the old copy is used, marked stale" "$(q '.sources[] | select(.repo=="acme/shop") | "\(.found) \(.stale)"'):$(q '.projects.web.approvals.value')" "true true:1"
rm -f "$DEPLOYS_CONFIG/team-cache/acme__tools.json"
cfg="$(GH_DOWN=acme/tools "${D[@]}" config --json)"
has "GitHub down and no copy: the error is named" "$(q '.sources[] | select(.repo=="acme/tools") | .error')" "HTTP 500"
cfg="$(DEPLOYS_NO_GITHUB=1 "${D[@]}" config --json)"
expect "DEPLOYS_NO_GITHUB reads the cache only" "$(q '.sources | length')" "3"
human="$("${D[@]}" config 2>&1)"
has "config prints each value with where it came from" "$human" "vercel-repos.json"

# ignore --undo on a project a shared file leaves out is written to overrides.json.
echo 'playground' > "$DEPLOYS_CONFIG/names"
echo '{}' > "$DEPLOYS_CONFIG/overrides.json"
"${D[@]}" ignore playground --undo >/dev/null
expect "ignore --undo of a team-ignored project overrides it" "$(jq -r '.projects.playground.ignored' "$DEPLOYS_CONFIG/overrides.json")" "false"
"${D[@]}" ignore playground >/dev/null
expect "ignore again removes that override" "$(jq -r '.projects.playground.ignored // "gone"' "$DEPLOYS_CONFIG/overrides.json")" "gone"
echo '{"projects":{"web":{"health":"/up"}}}' > "$DEPLOYS_CONFIG/overrides.json"

# --- observer mode ---
fresh; : > "$CALLS"
for cmd in "deploy web" "vercel deploy web" "vercel rollback web" "vercel autodeploy-off --all" "vercel map web acme/shop" \
           "render deploy api" "render rollback api" "render cancel s1 d1" "deploy-changed --yes" "autofix"; do
  # shellcheck disable=SC2086  # the words of the command
  out="$(DEPLOYS_READONLY=1 "${D[@]}" $cmd 2>&1)"; rc=$?
  expect "DEPLOYS_READONLY=1 refuses: $cmd" "$rc:$(echo "$out" | grep -c 'Observer mode (DEPLOYS_READONLY is set)')" "1:1"
done
expect "observer mode made no call to Vercel, Render or GitHub" "$(grep -c . "$CALLS")" "0"
out="$(DEPLOYS_READONLY=1 "${D[@]}" deploy-changed 2>&1)"
hasnt "deploy-changed without --yes only shows, and is not refused" "$out" "Observer mode"
out="$(DEPLOYS_READONLY=0 "${D[@]}" readonly 2>&1)"
expect "DEPLOYS_READONLY=0 is off" "$out" "off"
"${D[@]}" readonly on >/dev/null
out="$("${D[@]}" vercel deploy web 2>&1)"; rc=$?
expect "the readonly file refuses too" "$rc:$(echo "$out" | grep -c 'deploys readonly off')" "1:1"
expect "doctor says readonly" "$("${D[@]}" doctor | jq .readonly)" "true"
out="$("${D[@]}" ignore old-site --undo 2>&1)"; rc=$?
expect "this Mac's own settings stay allowed" "$rc" "0"
"${D[@]}" readonly off >/dev/null
expect "readonly off" "$("${D[@]}" readonly):$("${D[@]}" doctor | jq .readonly)" "off:false"

# An observer by the shared list: the gh login is in observers.
fresh; rm -f "$DEPLOYS_CONFIG/team-cache/me"
cfg="$(GH_USER=dev-watcher "${D[@]}" config --json)"
expect "a login in observers is an observer" "$(q '.readonly | "\(.value) \(.from)"')" "true observers in acme/shop:deploy-center.json"
out="$(GH_USER=dev-watcher "${D[@]}" vercel deploy web 2>&1)"; rc=$?
expect "an observer by list cannot deploy" "$rc:$(echo "$out" | grep -c 'Observer mode (observers in acme/shop')" "1:1"
fresh

# --- the two-person rule ---
# The function first, for each fixture commit (the deployer is dev-one).
(
  export DEPLOYS_LIB=1
  # shellcheck source=../deploys
  . ./deploys; set +e
  n() { team_approvals acme/shop "$1" dev-one | jq -r '[.have[].user] | join(",")'; }
  expect "an approving review counts" "$(n aaaa111aaaa111aaaa111aaaa111aaaa111aaaa)" "dev-two"
  expect "the deployer's own review and a review later turned to changes do not count" "$(n bbbb222bbbb222bbbb222bbbb222bbbb222bbbb)" ""
  expect "a label counts only when its person added it" "$(n cccc333cccc333cccc333cccc333cccc333cccc)" "dev-four"
  expect "a label on an open issue naming the commit counts" "$(n dddd444dddd444dddd444dddd444dddd444dddd)" "dev-two"
  out="$(team_gate render api acme/shop main aaaa111aaaa111aaaa111aaaa111aaaa111aaaa 2>&1)"; rc=$?
  expect "two needed, one there: refused" "$rc:$(echo "$out" | grep -c 'needs 2 approval')" "1:1"
  [ "$fails" = 0 ] || exit 1
) || fails=$((fails + 1))

# Then through `deploys deploy`, with a Vercel stand-in that logs what it was asked to build.
: > "$CALLS"
out="$(GH_HEAD=bbbb222bbbb222bbbb222bbbb222bbbb222bbbb "${D[@]}" deploy web 2>&1)"; rc=$?
expect "no approval: refused" "$rc" "1"
has "it says what is missing" "$out" "needs 1 approval(s) from someone other than you (dev-one) before bbbb222 goes live."
has "it names the PR a review would count on" "$out" "approving review on PR #13"
has "it names the label" "$out" "deploy-approved-by:<their login>"
has "it names --force" "$out" '--force "reason"'
has "the verdict is the last line (the app shows the end)" "$(echo "$out" | tail -n 1)" "Error: web needs 1 approval(s)"
expect "refused: nothing was sent to Vercel" "$(grep -c 'vercel POST' "$CALLS")" "0"

fresh; : > "$CALLS"
out="$(GH_HEAD=aaaa111aaaa111aaaa111aaaa111aaaa111aaaa "${D[@]}" deploy web 2>&1)"; rc=$?
expect "approved: started" "$rc:$(echo "$out" | grep -c 'Vercel: web started')" "0:1"
has "approved: it says by whom" "$out" "approved by dev-two (review on PR #12)"
expect "the approved commit is the one deployed (pinned)" "$(grep 'vercel POST' "$CALLS")" "vercel POST sha=aaaa111aaaa111aaaa111aaaa111aaaa111aaaa ref=main target=production"
expect "an approved deploy is journaled" "$(tail -n 1 "$DEPLOYS_CONFIG/team-journal.jsonl" | jq -r '"\(.kind) \(.project) \(.by) \(.approvals[0].user)"')" "approved web dev-one dev-two"

fresh
out="$(GH_HEAD=cccc333cccc333cccc333cccc333cccc333cccc "${D[@]}" deploy web 2>&1)"; rc=$?
expect "approved by a label its person added: started" "$rc" "0"
fresh
out="$(GH_HEAD=dddd444dddd444dddd444dddd444dddd444dddd "${D[@]}" deploy web 2>&1)"; rc=$?
expect "approved on an issue: started" "$rc" "0"

fresh; : > "$CALLS"
out="$(GH_HEAD=bbbb222bbbb222bbbb222bbbb222bbbb222bbbb "${D[@]}" deploy web --force 2>&1)"; rc=$?
expect "--force without a reason is refused" "$rc:$(echo "$out" | grep -c 'needs a reason')" "1:1"
out="$(GH_HEAD=bbbb222bbbb222bbbb222bbbb222bbbb222bbbb "${D[@]}" deploy web --force "  " 2>&1)"; rc=$?
expect "--force with a blank reason is refused" "$rc" "1"
out="$(GH_HEAD=bbbb222bbbb222bbbb222bbbb222bbbb222bbbb "${D[@]}" deploy web --force "hotfix for the outage" 2>&1)"; rc=$?
expect "--force with a reason: started" "$rc:$(grep -c 'vercel POST sha=bbbb222' "$CALLS")" "0:1"
expect "--force is journaled with its reason" "$(tail -n 1 "$DEPLOYS_CONFIG/team-journal.jsonl" | jq -r '"\(.kind) \(.reason) \(.need) \(.approvals | length)"')" "forced hotfix for the outage 1 0"
has "team journal lists it" "$("${D[@]}" team journal --json | jq -r '.[-1].reason')" "hotfix"

fresh; : > "$CALLS"
out="$(GH_HEAD=bbbb222bbbb222bbbb222bbbb222bbbb222bbbb "${D[@]}" deploy web --preview 2>&1)"; rc=$?
expect "a preview needs no approval" "$rc:$(grep -c 'target=preview' "$CALLS")" "0:1"
fresh; : > "$CALLS"
out="$(GH_HEAD=bbbb222bbbb222bbbb222bbbb222bbbb222bbbb "${D[@]}" deploy docs 2>&1)"; rc=$?
expect "a project with approvals 0 deploys as before (no pin)" "$rc:$(grep -c 'vercel POST sha=none' "$CALLS")" "0:1"
fresh
out="$(GH_HEAD=bbbb222bbbb222bbbb222bbbb222bbbb222bbbb "${D[@]}" vercel deploy-json web 2>&1)"; rc=$?
expect "the app's path (vercel deploy-json) is checked too" "$rc:$(echo "$out" | grep -c 'needs 1 approval')" "1:1"

# A copy of the script without lib/team.sh still deploys, and observer mode still holds.
cp deploys "$tmp/deploys-alone"
out="$(DEPLOYS_READONLY=1 bash "$tmp/deploys-alone" vercel deploy web 2>&1)"; rc=$?
expect "without lib/team.sh observer mode still refuses" "$rc:$(echo "$out" | grep -c 'Observer mode')" "1:1"

# The fixtures follow the schema (when python3 with jsonschema is there; CI on macOS may lack it).
if python3 -c 'import jsonschema' 2>/dev/null; then
  out="$(python3 -I - docs/deploy-center.schema.json "$FIX"/files/*/*/*.json "$FIX"/files/*/*/.*.json <<'PY' 2>&1
import json, sys, jsonschema
schema = json.load(open(sys.argv[1])); jsonschema.Draft202012Validator.check_schema(schema)
for f in sys.argv[2:]: jsonschema.validate(json.load(open(f)), schema)
print("valid")
PY
)"
  expect "the schema is valid and the fixtures follow it" "$out" "valid"
else echo "skip schema check (no python3 jsonschema)"; fi

echo
[ "$fails" = 0 ] && echo "All passed." || { echo "$fails failed."; exit 1; }
