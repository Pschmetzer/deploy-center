#!/bin/bash
# Tests for integrations/: a stand-in `deploys` answers from fixtures, a stand-in `curl`
# records what would be posted. No network, no real projects. Run: integrations/tests/run.sh
set -uo pipefail
cd "$(dirname "$0")/.." || exit 1
here="$PWD"
fails=0
ok()   { echo "ok   $1"; }
fail() { echo "FAIL $1: $2"; fails=$((fails+1)); }
expect()   { [ "$2" = "$3" ] && ok "$1" || fail "$1" "expected [$3], got [$2]"; }
contains() { case "$2" in *"$3"*) ok "$1" ;; *) fail "$1" "[$3] not in [$2]" ;; esac; }

tmp="$(mktemp -d)"; trap 'rm -rf "$tmp"' EXIT
now="$(date +%s)"
# app-web: Vercel, 3 days old, 4 commits waiting. site: Vercel, live a second ago, up to date,
# Git still connected. api: Render, live 26 h ago (a newer attempt a minute ago), waiting (count unknown), auto-deploy on.
cat > "$tmp/vercel.json" <<JSON
[{"name":"app-web","auto":false,"repo":"me/app","ref":"main","lastSha":"aaaa111","deployable":true,"changed":true,"pendingCommits":4,"lastAt":$((now - 3*86400))},
 {"name":"site","auto":true,"repo":"me/site","ref":"main","deployable":true,"changed":false,"pendingCommits":0,"lastAt":$((now - 1))}]
JSON
cat > "$tmp/render.json" <<JSON
[{"name":"api","auto":true,"repo":"me/app","ref":"main","lastSha":"bbbb222","deployable":true,"changed":true,"pendingCommits":null,"lastAt":$((now - 60)),"liveAt":$((now - 26*3600))}]
JSON
mkdir -p "$tmp/bin"
cat > "$tmp/bin/deploys" <<SH
#!/bin/bash
[ -n "\${FAKE_SLEEP:-}" ] && [ "\$1" = vercel ] && sleep "\$FAKE_SLEEP"
[ -n "\${FAKE_SLEEP_ALL:-}" ] && sleep "\$FAKE_SLEEP_ALL"
[ -n "\${MCP_CALLS:-}" ] && echo "\$*" >> "\$MCP_CALLS"
case "\$*" in
  "vercel list --json") cat "$tmp/vercel.json" ;;
  "render list --json") cat "$tmp/render.json" ;;
  "doctor") echo "{\"renderKey\":\${FAKE_RENDER_KEY:-false}}" ;;
  "changed --json") jq -s '(.[0] | map(. + {platform:"vercel"})) + (.[1] | map(. + {platform:"render"})) | map(select(.changed))' "$tmp/vercel.json" "$tmp/render.json"; exit "\${FAKE_RC:-0}" ;;
  "deploy-changed --yes") echo "\$*" >> "$tmp/deploy.log"
    if [ "\${FAKE_RC:-0}" = 0 ]; then echo "2 started, 0 failed to start."; else echo "1 started, 1 failed to start."; fi
    exit "\${FAKE_RC:-0}" ;;
  "status --json"|"status --json --no-github")
    jq -s '(.[0] | map(. + {platform:"vercel"})) + (.[1] | map(. + {platform:"render"}))
      | map({platform, name, building:false, state:"READY", changed})' "$tmp/vercel.json" "$tmp/render.json" ;;
  "explain "*) echo "explain: \$2" ;;
  "notes "*) echo "## Notes for \$2" ;;
  "logs "*) seq 1 "\${3:-80}" ;;
  "vercel deploy-json app-web"|"vercel deploy-json app-web --preview") echo '{"id":"dpl_1","url":"https://app-web-x.vercel.app","state":"QUEUED"}' ;;
  "render deploy-json api") echo '{"id":"dep-1","serviceId":"srv-1","state":"created"}' ;;
  "vercel rollback app-web") echo '{"id":"dpl_0","state":"READY"}' ;;
  "details me/app aaaa111 main") cat "$tmp/details-web.json" ;;
  "details me/app bbbb222 main") cat "$tmp/details-api.json" ;;
  "--help") echo "deploys changed [--json]"; [ -n "\${FAKE_RISK:-}" ] && echo "  deploys risk <project> [--json]" ;;
  "risk app-web --json") echo '{"hints":[{"hint":"touches the database schema"}]}' ;;
  "risk api --json") echo 'needs a new env var' ;;
  *) echo "unexpected: \$*" >&2; exit 1 ;;
esac
SH
# The commits between live and branch, as `deploys details` prints them. app-web: PR 12 (one
# commit with an agent co-author, one by the agent), PR 13 labelled by the agent, a human commit.
# api: a Dependabot commit and a human PR.
cat > "$tmp/details-web.json" <<'JSON'
{"commits":[
  {"sha":"c1","msg":"Add login page (#12)","author":"dev-one","bot":false,"coAuthors":[{"name":"Claude","email":"noreply@anthropic.com"}],"pr":12},
  {"sha":"c2","msg":"Fix nav (#12)","author":"claude","bot":false,"coAuthors":[],"pr":12},
  {"sha":"c3","msg":"Update copy (#13)","author":"dev-two","bot":false,"coAuthors":[],"pr":13},
  {"sha":"c4","msg":"Fix typo","author":"dev-two","bot":false,"coAuthors":[],"pr":null}],
 "risky":["package.json"],"checks":{"total":2,"failed":1,"running":0},"compareUrl":"https://github.com/me/app/compare/aaaa111...main"}
JSON
cat > "$tmp/details-api.json" <<'JSON'
{"commits":[
  {"sha":"c5","msg":"Bump lodash","author":"dependabot[bot]","bot":true,"coAuthors":[],"pr":null},
  {"sha":"c6","msg":"Tune pool (#14)","author":"dev-two","bot":false,"coAuthors":[],"pr":14}],
 "risky":[],"checks":{"total":1,"failed":0,"running":0},"compareUrl":null}
JSON
# gh: pull requests from fixtures (with --jq applied, as gh does), issues recorded in gh.log.
cat > "$tmp/bin/gh" <<SH
#!/bin/bash
printf '%s\n' "\$*" >> "$tmp/gh.log"
case "\$1 \$2" in
  "api repos/me/app/pulls/"*) n="\${2##*/}"; f="$tmp/pr\$n.json"; [ -f "\$f" ] || exit 1
    q=""; prev=""; for a in "\$@"; do [ "\$prev" = --jq ] && q="\$a"; prev="\$a"; done; jq -c "\$q" "\$f" ;;
  "issue list") cat "$tmp/issues.json" 2>/dev/null || echo '[]' ;;
  "issue create") echo "https://github.com/me/ops/issues/7" ;;
  "label create"|"issue edit"|"issue close"|"issue comment") ;;
  *) echo "unexpected gh: \$*" >&2; exit 1 ;;
esac
SH
echo '{"number":12,"title":"Login page","html_url":"https://github.com/me/app/pull/12","user":{"login":"dev-one","type":"User"},"labels":[]}' > "$tmp/pr12.json"
echo '{"number":13,"title":"New copy","html_url":"https://github.com/me/app/pull/13","user":{"login":"dev-two","type":"User"},"labels":[{"name":"AI-Generated"}]}' > "$tmp/pr13.json"
echo '{"number":14,"title":"Pool size","html_url":"https://github.com/me/app/pull/14","user":{"login":"dev-two","type":"User"},"labels":[{"name":"perf"}]}' > "$tmp/pr14.json"
cat > "$tmp/bin/curl" <<SH
#!/bin/bash
# Records the config from stdin (the URL) and the body file, like curl -K - --data-binary @f.
cat > "$tmp/curl.stdin"; printf '%s\n' "\$@" > "$tmp/curl.args"
for a in "\$@"; do case "\$a" in @*) cp "\${a#@}" "$tmp/curl.body" ;; esac; done
SH
chmod +x "$tmp/bin/deploys" "$tmp/bin/curl" "$tmp/bin/gh"
export PATH="$tmp/bin:$PATH" DEPLOYS="$tmp/bin/deploys" DEPLOYS_CONFIG="$tmp/config"
unset RENDER_API_KEY DEPLOYS_NOTIFY_URL DEPLOYS_NOTIFY_FORMAT DEPLOYS_DIGEST_REPO DEPLOYS_DIGEST_WORKFLOW DEPLOYS_AGENT_AUTHORS DEPLOYS_AGENT_LABELS

# --- lib: Render only with a key; ignored projects left out ---
# shellcheck source=lib/projects.sh
. lib/projects.sh
expect "without a Render key only Vercel is read" "$(all_projects | jq -c 'map(.name)')" '["app-web","site"]'
expect "with a key in the env Render is read too" "$(RENDER_API_KEY=x all_projects | jq -c 'map(.platform)')" '["vercel","vercel","render"]'
expect "doctor's renderKey counts as a key" "$(FAKE_RENDER_KEY=true all_projects | jq length)" 3
mkdir -p "$DEPLOYS_CONFIG"; echo '["api"]' > "$DEPLOYS_CONFIG/ignored.json"
expect "changed leaves out ignored and up-to-date" "$(RENDER_API_KEY=x changed_projects | jq -c 'map(.name)')" '["app-web"]'
rm -f "$DEPLOYS_CONFIG/ignored.json"

# --- badge ---
RENDER_API_KEY=x badge/badge.sh "$tmp/b" >/dev/null
expect "one badge per project" "$(cd "$tmp/b" && echo *.svg)" "api.svg app-web.svg site.svg"
contains "badge: days and commits" "$(cat "$tmp/b/app-web.svg")" "3 d ago · 4 commits waiting"
contains "badge: Render shows the live commit's age, not the newest attempt" "$(cat "$tmp/b/api.svg")" "1 d ago · changes waiting"
contains "badge: up to date is green" "$(cat "$tmp/b/site.svg")" 'fill="#4c1"'
echo '[{"name":"a<b>&\"c","changed":false,"lastAt":0}]' | badge/badge.sh "$tmp/e" - >/dev/null
contains "badge: names are XML-escaped" "$(cat "$tmp/e/a_b___c.svg")" 'a&lt;b&gt;&amp;&quot;c: deployed never'
if command -v xmllint >/dev/null; then
  xmllint --noout "$tmp"/b/*.svg "$tmp"/e/*.svg && ok "badges are well-formed XML" || fail "badges are well-formed XML" xmllint
fi

# --- notify ---
out="$(RENDER_API_KEY=x notify/notify.sh --dry-run)"
contains "notify: live today" "$out" 'Live today (1): site'
contains "notify: waiting with counts" "$out" 'Waiting (2): app-web (4 commits), api'
contains "notify: Slack-style by default" "$out" 'format: slack'
expect "notify: Discord by host" "$(DEPLOYS_NOTIFY_URL=https://discord.com/api/webhooks/1/x notify/notify.sh --dry-run | sed -n 2p | jq -r 'keys[0]')" content
expect "notify: Telegram by host" "$(DEPLOYS_NOTIFY_URL='https://api.telegram.org/botT/sendMessage?chat_id=1' notify/notify.sh --dry-run | head -1)" "format: telegram"
contains "notify: ntfy is plain text" "$(DEPLOYS_NOTIFY_URL=https://ntfy.sh/topic notify/notify.sh --dry-run)" $'format: ntfy\nDeploy Center'
DEPLOYS_NOTIFY_URL='https://hooks.example.test/T/secret' notify/notify.sh >/dev/null
expect "notify: the URL goes to curl on stdin" "$(cat "$tmp/curl.stdin")" 'url = "https://hooks.example.test/T/secret"'
case "$(cat "$tmp/curl.args")" in *secret*) fail "notify: URL not in curl's arguments" "found" ;; *) ok "notify: URL not in curl's arguments" ;; esac
expect "notify: posts the summary" "$(jq -r '.text' "$tmp/curl.body" | sed -n 2p)" 'Live today (1): site'
DEPLOYS_NOTIFY_URL='ftp://x' notify/notify.sh >/dev/null 2>&1; expect "notify: refuses a non-http URL" "$?" 1

# --- pre-push ---
z=0000000000000000000000000000000000000000; s1=1111111111111111111111111111111111111111
git init -q "$tmp/repo"
push() { (cd "$tmp/repo" && printf '%s\n' "$1" | RENDER_API_KEY=x "$here/hooks/pre-push" origin "$2" 2>&1); echo "exit=$?"; }
out="$(push "refs/heads/main $s1 refs/heads/main $z" git@github.com:me/app.git)"
contains "pre-push: Render auto-deploy on the pushed branch is counted" "$out" "starts 1 build(s)"
contains "pre-push: warns only, by default" "$out" "exit=0"
out="$(push "refs/heads/main $s1 refs/heads/main $z" https://github.com/me/site.git)"
contains "pre-push: Vercel Git-connected production" "$out" "vercel  site  (production, branch main)"
out="$(push "refs/heads/feature $s1 refs/heads/feature $z" https://github.com/me/site)"
contains "pre-push: Vercel builds a preview of any branch" "$out" "(preview, branch feature)"
out="$(push "refs/heads/feature $s1 refs/heads/feature $z" git@github.com:me/app.git)"
expect "pre-push: Render ignores other branches" "$out" "exit=0"
out="$(push "(delete) $z refs/heads/main $s1" git@github.com:me/site.git)"
expect "pre-push: a deleted branch builds nothing" "$out" "exit=0"
start=$(date +%s)
out="$(FAKE_SLEEP=30 DEPLOYS_PREPUSH_TIMEOUT=1 push "refs/heads/main $s1 refs/heads/main $z" git@github.com:me/site.git)"
contains "pre-push: a CLI that does not answer lets the push go" "$out" $'push not checked.\nexit=0'
[ $(( $(date +%s) - start )) -lt 6 ] && ok "pre-push: gives up after the timeout" || fail "pre-push: gives up after the timeout" "took too long"
pgrep -f "sleep 30" >/dev/null && fail "pre-push: the stuck CLI is stopped" "still running" || ok "pre-push: the stuck CLI is stopped"
git -C "$tmp/repo" config deploys.prepush.block true
out="$(push "refs/heads/main $s1 refs/heads/main $z" git@github.com:me/site.git)"
contains "pre-push: blocks only when configured" "$out" "exit=1"
out="$(DEPLOYS=/nonexistent push "refs/heads/main $s1 refs/heads/main $z" git@github.com:me/site.git)"
expect "pre-push: no CLI, no check, push goes" "$out" "exit=0"
git -C "$tmp/repo" config deploys.prepush.skip true
out="$(push "refs/heads/main $s1 refs/heads/main $z" git@github.com:me/site.git)"
expect "pre-push: skip turns it off" "$out" "exit=0"

# --- the Action's steps, run as GitHub would (needs ruby for the YAML) ---
if command -v ruby >/dev/null; then
  step() { ruby -ryaml -e 'puts YAML.load_file(ARGV[0])["runs"]["steps"].find { |s| s["id"] == ARGV[1] }[ARGV[2]]' action/action.yml "$1" "${2:-run}"; }
  step changed > "$tmp/changed.sh"; step deploy > "$tmp/deploy.sh"
  run_step() { : > "$tmp/out"; : > "$tmp/sum"; GITHUB_OUTPUT="$tmp/out" GITHUB_STEP_SUMMARY="$tmp/sum" bash "$tmp/$1" >/dev/null 2>&1; }
  run_step changed.sh; expect "action: the step passes" "$?" 0
  expect "action: count" "$(grep '^count=' "$tmp/out")" "count=2"
  expect "action: names" "$(grep '^names=' "$tmp/out")" "names=app-web,api"
  expect "action: projects is the JSON list" "$(sed -n '/^projects<</,$p' "$tmp/out" | sed -n 2p | jq -c 'map(.name)')" '["app-web","api"]'
  FAKE_RC=1 run_step changed.sh; expect "action: an unread project warns, does not fail" "$?" 0
  run_step deploy.sh; expect "action: deploy step calls deploy-changed --yes" "$(cat "$tmp/deploy.log")" "deploy-changed --yes"
  expect "action: outputs after starting" "$(tr '\n' ' ' < "$tmp/out")" "started=2 failed=0 deployed=true "
  FAKE_RC=1 run_step deploy.sh; expect "action: a failed start fails the step" "$?" 1
  expect "action: outputs are written before failing" "$(tr '\n' ' ' < "$tmp/out")" "started=1 failed=1 deployed=false "
  expect "action: deploy step only with deploy: true" "$(step deploy if)" "inputs.deploy == 'true' && steps.changed.outputs.count != '0'"
  case "$(cat "$tmp/changed.sh" "$tmp/deploy.sh")" in *'${{'*) fail "action: no inputs inside run scripts" "found" ;; *) ok "action: no inputs inside run scripts" ;; esac
fi

# --- the MCP server (needs node and `npm ci` in mcp/) ---
if command -v node >/dev/null && [ -d mcp/node_modules/@modelcontextprotocol/sdk ]; then
  DEPLOYS_BIN="$tmp/bin/deploys" MCP_CALLS="$tmp/mcp-calls.log" node tests/mcp.test.mjs || fails=$((fails+1))
  pgrep -f "sleep 20" >/dev/null && fail "mcp: a timed-out CLI is stopped with its children" "still running" || ok "mcp: a timed-out CLI is stopped with its children"
else
  echo "skip mcp: needs node and (cd integrations/mcp && npm ci)"
fi

# --- digest: classify (pure) ---
# shellcheck source=digest/classify.sh
. digest/classify.sh
kinds() { classify | jq -c 'map(.why)'; }
expect "classify: bot flag, author, co-author, label, PR author, else human" "$(echo '[
  {"author":"someone","bot":true},{"author":"renovate[bot]"},{"author":"Codex"},
  {"author":"dev-one","coAuthors":[{"name":"Claude Opus","email":"noreply@anthropic.com"}]},
  {"author":"dev-one","prLabels":["perf","AI-Generated"]},{"author":"dev-one","prAuthor":"devin-ai-integration"},
  {"author":"dev-one","prBot":true},{"author":"dev-one","coAuthors":[{"name":"Dev Two","email":"two@example.test"}],"prLabels":["perf"]}]' | kinds)" \
  '["bot account","author renovate[bot]","author Codex","co-author Claude Opus","label AI-Generated","pull request by devin-ai-integration","bot account","no agent sign"]'
expect "classify: patterns match the whole login" "$(echo '[{"author":"claudette"},{"author":"cursor-fan"}]' | classify | jq -c 'map(.kind)')" '["human","human"]'
expect "classify: own lists replace the defaults; @ patterns match co-author emails" \
  "$(echo '[{"author":"claude"},{"author":"ci.helper"},{"author":"x","coAuthors":[{"name":"Y","email":"y@agents.example.test"}]},{"author":"x","prLabels":["agent"]},{"author":"x","prLabels":["robot"]}]' \
     | DEPLOYS_AGENT_AUTHORS='ci.helper, *@agents.example.test' DEPLOYS_AGENT_LABELS='Robot' classify | jq -c 'map(.kind)')" \
  '["human","agent","agent","human","agent"]'
expect "classify: . in a pattern is a dot, not any character" "$(echo '[{"author":"ciXhelper"}]' | DEPLOYS_AGENT_AUTHORS='ci.helper' classify | jq -r '.[0].kind')" human
expect "classify: no commits, no list" "$(echo 'null' | classify | jq -c .)" '[]'
expect "classify: runs alone too" "$(echo '[{"author":"devin"}]' | digest/classify.sh | jq -r '.[0].kind')" agent

# --- digest ---
: > "$tmp/gh.log"
j="$(RENDER_API_KEY=x digest/digest.sh --json)"
expect "digest: agent and human per project" "$(jq -c '.projects | map([.name, .agent, .human])' <<<"$j")" '[["app-web",3,1],["api",1,1]]'
expect "digest: PR titles from GitHub, kind per PR" "$(jq -c '.projects[0].prs | map([.number, .title, .kind])' <<<"$j")" '[[12,"Login page","agent"],[13,"New copy","agent"]]'
expect "digest: a bot commit without PR is an agent's" "$(jq -c '.projects[1].loose | map([.author, .why])' <<<"$j")" '[["dependabot[bot]","bot account"]]'
expect "digest: risky files and failed CI from details" "$(jq -c '.projects[0].risk' <<<"$j")" '["CI failed on the branch head","changes package.json"]'
expect "digest: each pull request read once" "$(grep -c 'pulls/12' "$tmp/gh.log")" 1
j="$(RENDER_API_KEY=x FAKE_RISK=1 digest/digest.sh --json)"
contains "digest: deploys risk when the CLI has it (JSON)" "$(jq -c '.projects[0].risk' <<<"$j")" '"touches the database schema"'
expect "digest: deploys risk when the CLI has it (lines)" "$(jq -c '.projects[1].risk' <<<"$j")" '["needs a new env var"]'
md="$(RENDER_API_KEY=x DEPLOYS_DIGEST_REPO=me/ops digest/digest.sh --out "$tmp/digest.md")"
expect "digest: Markdown on stdout and in the file" "$md" "$(cat "$tmp/digest.md")"
contains "digest: title with the day" "$md" "# Deploys waiting – $(date -u +%Y-%m-%d)"
contains "digest: counts" "$md" $'## app-web (vercel, me/app)\n\n4 commits waiting: 3 agent, 1 human'
contains "digest: PR lines say why" "$md" '- #12 Login page – agent (author claude, co-author Claude)'
contains "digest: how to approve" "$md" 'projects: `app-web,api`'
nogh="$tmp/nogh"; mkdir -p "$nogh"; for t in jq bash date sed grep tr cat mktemp rm dirname tail head sort; do ln -sf "$(command -v $t)" "$nogh/$t"; done
ln -sf "$tmp/bin/deploys" "$nogh/deploys"
expect "digest: without gh, commit messages stand in for PR titles" \
  "$(PATH="$nogh" RENDER_API_KEY=x digest/digest.sh --json | jq -c '.projects[0].prs | map(.title)')" '["Add login page (#12)","Update copy (#13)"]'
expect "digest: --issue needs a repo" "$(digest/digest.sh --issue >/dev/null 2>&1; echo $?)" 1
expect "digest: --post needs a URL" "$(digest/digest.sh --post >/dev/null 2>&1; echo $?)" 1
expect "digest: a bad repo is refused" "$(DEPLOYS_DIGEST_REPO='me/ops;x' digest/digest.sh >/dev/null 2>&1; echo $?)" 1

# post: Slack gets a button to the workflow; the URL goes to curl on stdin
out="$(RENDER_API_KEY=x DEPLOYS_DIGEST_REPO=me/ops digest/digest.sh --post --dry-run)"
expect "digest post: Slack button to workflow_dispatch" "$(sed 1d <<<"$out" | jq -r '.blocks[1].elements[0].url')" "https://github.com/me/ops/actions/workflows/approve-deploy.yml"
contains "digest post: short text with counts and PRs" "$(sed 1d <<<"$out" | jq -r .text)" '• app-web: 3 agent, 1 human – #12 Login page; #13 New copy'
contains "digest post: says nothing deploys without approval" "$(sed 1d <<<"$out" | jq -r .text)" 'Nothing deploys until a person approves (projects: app-web,api).'
expect "digest post: no repo, no button" "$(RENDER_API_KEY=x digest/digest.sh --post --dry-run | sed 1d | jq -c 'has("blocks")')" false
expect "digest post: Telegram gets a URL button" "$(RENDER_API_KEY=x DEPLOYS_DIGEST_REPO=me/ops DEPLOYS_NOTIFY_FORMAT=telegram digest/digest.sh --post --dry-run | sed 1d | jq -r '.reply_markup.inline_keyboard[0][0].text')" "Approve deploy"
contains "digest post: Discord gets the link in the text" "$(RENDER_API_KEY=x DEPLOYS_DIGEST_REPO=me/ops DEPLOYS_NOTIFY_FORMAT=discord digest/digest.sh --post --dry-run | sed 1d | jq -r .content)" 'Approve deploy: <https://github.com/me/ops/actions/workflows/approve-deploy.yml>'
RENDER_API_KEY=x DEPLOYS_DIGEST_REPO=me/ops DEPLOYS_NOTIFY_URL='https://ntfy.sh/secret-topic' digest/digest.sh --post >/dev/null
contains "digest post: ntfy gets a view action" "$(cat "$tmp/curl.args")" 'Actions: view, Approve deploy, https://github.com/me/ops/actions/workflows/approve-deploy.yml'
expect "digest post: URL on stdin, not in arguments" "$(cat "$tmp/curl.stdin"; grep -c secret-topic "$tmp/curl.args")" $'url = "https://ntfy.sh/secret-topic"\n0'

# issue: opened once per day, updated after, older days closed
: > "$tmp/gh.log"; rm -f "$tmp/issues.json"
out="$(RENDER_API_KEY=x DEPLOYS_DIGEST_REPO=me/ops DEPLOYS_NOTIFY_URL=https://hooks.example.test/x digest/digest.sh --issue --post)"
contains "digest issue: opened" "$out" "Opened issue https://github.com/me/ops/issues/7"
contains "digest issue: with the day in the title and the digest label" "$(cat "$tmp/gh.log")" "issue create -R me/ops --title Deploys waiting – $(date -u +%Y-%m-%d) --body-file"
contains "digest issue: the approve label is made" "$(cat "$tmp/gh.log")" "label create deploy-approved -R me/ops"
contains "digest issue: the message links the issue" "$(jq -r .text "$tmp/curl.body")" 'Issue: https://github.com/me/ops/issues/7 (label deploy-approved)'
echo "[{\"number\":5,\"title\":\"Deploys waiting – $(date -u +%Y-%m-%d)\",\"url\":\"https://github.com/me/ops/issues/5\"},{\"number\":3,\"title\":\"Deploys waiting – 2000-01-01\",\"url\":\"u\"}]" > "$tmp/issues.json"
: > "$tmp/gh.log"
out="$(RENDER_API_KEY=x DEPLOYS_DIGEST_REPO=me/ops digest/digest.sh --issue)"
contains "digest issue: today's is updated, not opened again" "$out" "Updated issue #5."
case "$(cat "$tmp/gh.log")" in *"issue create"*) fail "digest issue: no second issue" "created" ;; *) ok "digest issue: no second issue" ;; esac
contains "digest issue: an older day's is closed" "$(cat "$tmp/gh.log")" "issue close 3 -R me/ops --comment Replaced by #5."
out="$(RENDER_API_KEY=x DEPLOYS_DIGEST_REPO=me/ops digest/digest.sh --issue --dry-run)"
contains "digest issue: the body carries the approve list" "$out" '<!-- deploys-approve: app-web,api -->'
rm -f "$tmp/issues.json"

# --- approve-deploy.yml: its steps, run as GitHub would (needs ruby for the YAML) ---
if command -v ruby >/dev/null; then
  wstep() { ruby -ryaml -e 'puts YAML.load_file(ARGV[0])["jobs"]["deploy"]["steps"].find { |s| s["id"] == ARGV[1] }[ARGV[2]]' digest/examples/approve-deploy.yml "$1" "${2:-run}"; }
  wstep approved > "$tmp/approved.sh"; wstep keep > "$tmp/keep.sh"; wstep report > "$tmp/report.sh"
  approve() { : > "$tmp/out"; env GITHUB_OUTPUT="$tmp/out" EVENT="${EVENT:-workflow_dispatch}" ACTOR="${ACTOR:-dev-one}" SENDER_TYPE="${SENDER_TYPE:-User}" \
      APPROVERS="${APPROVERS-dev-one, Dev-Two}" INPUT="${INPUT:-}" BODY="${BODY:-}" bash "$tmp/approved.sh" >/dev/null 2>&1; echo "$?:$(grep '^projects=' "$tmp/out")"; }
  expect "approve: an approver's list" "$(INPUT='api, app-web' approve)" "0:projects=api,app-web"
  expect "approve: logins match without case" "$(ACTOR=dev-two INPUT=api approve)" "0:projects=api"
  expect "approve: all means everything waiting" "$(INPUT=all approve)" "0:projects=*"
  expect "approve: someone not listed is refused" "$(ACTOR=dev-three INPUT=api approve)" "1:"
  expect "approve: a bot is refused" "$(ACTOR='claude[bot]' APPROVERS='claude[bot]' INPUT=api approve)" "1:"
  expect "approve: a bot sender is refused" "$(SENDER_TYPE=Bot INPUT=api approve)" "1:"
  expect "approve: no DEPLOYS_APPROVERS, no deploy" "$(APPROVERS='' INPUT=api approve)" "1:"
  expect "approve: odd names are refused" "$(INPUT='api,$(x)' approve)" "1:"
  expect "approve: nothing named, nothing deployed" "$(INPUT=' , ' approve)" "1:"
  expect "approve: the issue route reads the list from the body" "$(EVENT=issues BODY=$'# Deploys\r\n<!-- deploys-approve: app-web,api -->\r\n' approve)" "0:projects=api,app-web"
  expect "approve: an issue without the list deploys nothing" "$(EVENT=issues BODY='hello' approve)" "1:"
  expect "approve: a refusal says why" "$(ACTOR=dev-three INPUT=api approve >/dev/null; sed -n 's/^reason=//p' "$tmp/out")" "dev-three is not in DEPLOYS_APPROVERS."
  # keep: every known project not approved goes into ignored.json (the config the action set up)
  keep() { mkdir -p "$tmp/kc"; rm -f "$tmp/kc/ignored.json"; DEPLOYS_CONFIG="$tmp/kc" PROJECTS="$1" VERCEL_TOKEN=t RENDER_API_KEY="${2-k}" bash "$tmp/keep.sh" 2>&1; echo "rc=$?"; }
  out="$(keep app-web)"
  expect "keep: the rest is left out" "$(jq -c . "$tmp/kc/ignored.json")" '["api","site"]'
  contains "keep: says what goes" "$out" "Deploying only: app-web"
  out="$(keep app-web,gone)"
  contains "keep: an unknown name is named" "$out" "Not found, so not deployed: gone"
  keep site,api >/dev/null; expect "keep: two approved" "$(jq -c . "$tmp/kc/ignored.json")" '["app-web"]'
  keep app-web '' >/dev/null; expect "keep: without a Render key only Vercel is listed" "$(jq -c . "$tmp/kc/ignored.json")" '["site"]'
  out="$(keep '*')"; expect "keep: all leaves nothing out" "$([ -f "$tmp/kc/ignored.json" ] && echo file || echo none)" none
  expect "keep: a listing that fails stops the deploy" "$(FAKE_RC=0 DEPLOYS=/nonexistent keep app-web | tail -1)" "rc=127"
  # the result goes on the issue; the label comes off; a full deploy closes it
  report() { : > "$tmp/gh.log"; env REPO=me/ops ISSUE=5 RUN_URL=https://example.test/run REASON="${REASON:-}" NAMES="${NAMES:-}" STARTED="${STARTED-}" FAILED="${FAILED:-}" DEPLOYED="${DEPLOYED:-}" bash "$tmp/report.sh" >/dev/null 2>&1; cat "$tmp/gh.log"; }
  out="$(NAMES=app-web STARTED=1 FAILED=0 DEPLOYED=true report)"
  contains "report: started, on the issue" "$out" "issue comment 5 -R me/ops --body Started 1 deploy(s) (app-web), 0 failed to start."
  contains "report: label off" "$out" "issue edit 5 -R me/ops --remove-label deploy-approved"
  contains "report: closed when deployed" "$out" "issue close 5"
  out="$(REASON='dev-three is not in DEPLOYS_APPROVERS.' report)"
  contains "report: a refusal is said" "$out" "Not deployed: dev-three is not in DEPLOYS_APPROVERS."
  case "$out" in *"issue close"*) fail "report: open after a refusal" "closed" ;; *) ok "report: open after a refusal" ;; esac
  expect "approve-deploy: runs only on the deploy-approved label of a digest issue, or by hand" "$(ruby -ryaml -e 'puts YAML.load_file(ARGV[0])["jobs"]["deploy"]["if"]' digest/examples/approve-deploy.yml | tr -s ' \n' ' ' | sed 's/ $//')" \
    "github.event_name == 'workflow_dispatch' || (github.event.label.name == 'deploy-approved' && startsWith(github.event.issue.title, 'Deploys waiting – '))"
  expect "approve-deploy: deploy: true only after the approval steps" "$(ruby -ryaml -e 's = YAML.load_file(ARGV[0])["jobs"]["deploy"]["steps"]; puts s.each_with_index.select { |x, _| (x["with"] || {})["deploy"] == true }.map { |_, i| s[0...i].map { |y| y["id"] }.join(",") }' digest/examples/approve-deploy.yml)" "approved,list,keep"
  case "$(cat "$tmp/approved.sh" "$tmp/keep.sh" "$tmp/report.sh")" in *'${{'*) fail "approve-deploy: no expressions inside run scripts" "found" ;; *) ok "approve-deploy: no expressions inside run scripts" ;; esac
  ruby -ryaml -e 'YAML.load_file(ARGV[0])' digest/examples/daily-digest.yml && ok "daily-digest.yml is valid YAML" || fail "daily-digest.yml is valid YAML" ruby
fi

echo
[ "$fails" = 0 ] && echo "All passed." || { echo "$fails failed."; exit 1; }
