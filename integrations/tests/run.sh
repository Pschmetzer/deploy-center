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
[{"name":"app-web","auto":false,"repo":"me/app","ref":"main","deployable":true,"changed":true,"pendingCommits":4,"lastAt":$((now - 3*86400)),"lastState":"READY","lastMsg":"Fix <b>login</b> & signup","lastSha":"abc1234"},
 {"name":"site","auto":true,"repo":"me/site","ref":"main","deployable":true,"changed":false,"pendingCommits":0,"lastAt":$((now - 1)),"lastState":"READY","lastMsg":"Secret launch copy"}]
JSON
cat > "$tmp/render.json" <<JSON
[{"name":"api","auto":true,"repo":"me/app","ref":"main","deployable":true,"changed":true,"pendingCommits":null,"lastAt":$((now - 60)),"liveAt":$((now - 26*3600)),"lastState":"build_failed","lastMsg":"Add rate limits"}]
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
  "notes app-web") printf '## app-web\\n- New billing page (#12) – Ana\\n- Faster search – Ben\\n\\nDependency updates:\\n- Bump jq – dependabot\\n' ;;
  "notes "*) exit 1 ;;
  "simulate --days "*" --json") jq --argjson d "\$3" '.days = \$d' "$here/../tests/fixtures/savings/simulate-report.json" ;;
  "ledger --json") cat "$here/../tests/fixtures/savings/ledger-report.json" ;;
  "doctor") echo "{\"renderKey\":\${FAKE_RENDER_KEY:-false}}" ;;
  "changed --json") jq -s 'add | map(select(.changed))' "$tmp/vercel.json" "$tmp/render.json"; exit "\${FAKE_RC:-0}" ;;
  "deploy-changed --yes") echo "\$*" >> "$tmp/deploy.log"
    if [ "\${FAKE_RC:-0}" = 0 ]; then echo "2 started, 0 failed to start."; else echo "1 started, 1 failed to start."; fi
    exit "\${FAKE_RC:-0}" ;;
  "status --json"|"status --json --no-github")
    jq -s '(.[0] | map(. + {platform:"vercel"})) + (.[1] | map(. + {platform:"render"}))
      | map({platform, name, building:false, state:"READY", changed})' "$tmp/vercel.json" "$tmp/render.json" ;;
  "explain "*) echo "explain: \$2" ;;
  "logs "*) seq 1 "\${3:-80}" ;;
  "vercel deploy-json app-web"|"vercel deploy-json app-web --preview") echo '{"id":"dpl_1","url":"https://app-web-x.vercel.app","state":"QUEUED"}' ;;
  "render deploy-json api") echo '{"id":"dep-1","serviceId":"srv-1","state":"created"}' ;;
  "vercel rollback app-web") echo '{"id":"dpl_0","state":"READY"}' ;;
  *) echo "unexpected: \$*" >&2; exit 1 ;;
esac
SH
cat > "$tmp/bin/curl" <<SH
#!/bin/bash
# Records the config from stdin (the URL) and the body file, like curl -K - --data-binary @f.
cat > "$tmp/curl.stdin"; printf '%s\n' "\$@" > "$tmp/curl.args"
for a in "\$@"; do case "\$a" in @*) cp "\${a#@}" "$tmp/curl.body" ;; esac; done
SH
chmod +x "$tmp/bin/deploys" "$tmp/bin/curl"
export PATH="$tmp/bin:$PATH" DEPLOYS="$tmp/bin/deploys" DEPLOYS_CONFIG="$tmp/config"
unset RENDER_API_KEY DEPLOYS_NOTIFY_URL DEPLOYS_NOTIFY_FORMAT

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

# --- status page ---
# A stand-in curl for the site check: up for *.up.test, a 503 otherwise. The journal mixes kinds
# and projects, has a broken line, and 35 deploys of app-web to check the limit of 30.
mkdir -p "$tmp/sp-bin"
cat > "$tmp/sp-bin/curl" <<'SH'
#!/bin/bash
for a in "$@"; do u="$a"; done
echo "$u" >> "${SP_CURL_LOG:?}"
case "$u" in *.up.test*) printf '200 0.123' ;; *) printf '503 0.050' ;; esac
SH
chmod +x "$tmp/sp-bin/curl"
{
  for i in $(seq 1 35); do printf '{"at":"%s","platform":"vercel","name":"app-web","result":"live","seconds":%d,"detail":null}\n' "$(date -u -d "@$((now - 86400*3 - i*3600))" +%Y-%m-%dT%H:%M:%SZ 2>/dev/null || date -u -r "$((now - 86400*3 - i*3600))" +%Y-%m-%dT%H:%M:%SZ)" "$((60 + i))"; done
  printf '{"at":"%s","platform":"render","name":"api","result":"failed","seconds":30,"detail":"token sk_live_SECRET in /Users/me/x"}\n' "$(date -u +%Y-%m-%dT%H:%M:%SZ)"
  echo 'not json'
  printf '{"at":"%s","platform":"vercel","name":"site","result":"live","seconds":10,"detail":null}\n' "$(date -u +%Y-%m-%dT%H:%M:%SZ)"
  printf '{"at":"%s","platform":"vercel","name":"app-web","result":"skipped","seconds":0,"detail":"nothing to do"}\n' "$(date -u +%Y-%m-%dT%H:%M:%SZ)"
} > "$tmp/journal.jsonl"
cat > "$tmp/sp.json" <<'JSON'
{"title":"Acme <deploys>","baseUrl":"https://status.example.test",
 "projects":["app-web",{"name":"api","platform":"render","label":"API","url":"https://api.up.test/health"},"vercel/missing"]}
JSON
sp() { SP_CURL_LOG="$tmp/sp-curl.log" PATH="$tmp/sp-bin:$PATH" RENDER_API_KEY=x DEPLOYS_JOURNAL="$tmp/journal.jsonl" statuspage/statuspage.sh "$@"; }
: > "$tmp/sp-curl.log"
sp --config "$tmp/sp.json" --out "$tmp/sp" >/dev/null; expect "statuspage: runs" "$?" 0
st="$(cat "$tmp/sp/status.json")"; page="$(cat "$tmp/sp/index.html")"; feed="$(cat "$tmp/sp/feed.xml")"
expect "statuspage: only allowlisted projects, in config order" "$(jq -c '[.projects[].name]' <<<"$st")" '["app-web","API","missing"]'
case "$page$st$feed" in *site*|*"Secret launch"*) fail "statuspage: a project not listed does not leak" "found" ;; *) ok "statuspage: a project not listed does not leak" ;; esac
expect "statuspage: a listed project that is not found is unknown" "$(jq -r '.projects[2].state' <<<"$st")" unknown
expect "statuspage: live message" "$(jq -r '.projects[0].message' <<<"$st")" 'Fix <b>login</b> & signup'
contains "statuspage: HTML-escaped" "$page" 'Fix &lt;b&gt;login&lt;/b&gt; &amp; signup'
contains "statuspage: title escaped" "$page" '<title>Acme &lt;deploys&gt;</title>'
expect "statuspage: notes from deploys notes, no authors by default" "$(jq -c '.projects[0].next' <<<"$st")" '["New billing page (#12)","Faster search","Dependency update: Bump jq"]'
expect "statuspage: Render shows the live time, not the failed attempt" "$(jq -r '.projects[1] | "\(.state) \(.at)"' <<<"$st")" "live-failed $((now - 26*3600))"
expect "statuspage: site check" "$(jq -c '.projects[1].check' <<<"$st")" '{"up":true,"code":200,"ms":123}'
expect "statuspage: only the configured URL is checked" "$(cat "$tmp/sp-curl.log")" "https://api.up.test/health"
expect "statuspage: timeline is the last 30" "$(jq '.timeline | length' <<<"$st")" 30
expect "statuspage: timeline newest first, only listed, live and failed" "$(jq -r '.timeline[0] | "\(.name) \(.result)"' <<<"$st")" "API failed"
case "$st$page$feed" in *SECRET*|*/Users/*|*"nothing to do"*|*abc1234*|*me/app*) fail "statuspage: no journal detail, SHA or repo" "found" ;; *) ok "statuspage: no journal detail, SHA or repo" ;; esac
expect "statuspage: feed has an entry per deploy" "$(grep -c '<entry>' <<<"$feed")" 30
contains "statuspage: feed links the page" "$feed" '<link rel="self" href="https://status.example.test/feed.xml"/>'
case "$page" in *'src="http'*|*'href="http'*|*"@import"*|*"url("*) fail "statuspage: no external assets" "found" ;; *) ok "statuspage: no external assets" ;; esac
contains "statuspage: dark mode" "$page" "prefers-color-scheme:dark"
if command -v xmllint >/dev/null; then
  xmllint --noout "$tmp/sp/feed.xml" && ok "statuspage: feed is well-formed XML" || fail "statuspage: feed is well-formed XML" xmllint
  xmllint --html --noout "$tmp/sp/index.html" 2>/dev/null && ok "statuspage: page parses as HTML" || fail "statuspage: page parses as HTML" xmllint
fi
# hideMessages: no commit text anywhere, only "Updated".
jq '. + {hideMessages: true}' "$tmp/sp.json" > "$tmp/sp-hide.json"
sp --config "$tmp/sp-hide.json" --out "$tmp/sph" --no-check >/dev/null
st="$(cat "$tmp/sph/status.json")"; all="$st$(cat "$tmp/sph/index.html" "$tmp/sph/feed.xml")"
expect "statuspage hide: message is Updated" "$(jq -r '[.projects[0,1].message] | join(",")' <<<"$st")" "Updated,Updated"
expect "statuspage hide: notes are one Updated" "$(jq -c '.projects[0].next' <<<"$st")" '["Updated"]'
case "$all" in *login*|*billing*|*"Faster search"*|*"rate limits"*|*"Bump jq"*) fail "statuspage hide: no commit message anywhere" "found" ;; *) ok "statuspage hide: no commit message anywhere" ;; esac
expect "statuspage: --no-check checks nothing" "$(jq -c '.projects[1].check' <<<"$st")" null
echo '{"title":"x","projects":["app-web"],"showAuthors":true}' > "$tmp/sp-auth.json"
expect "statuspage: authors only when asked" "$(sp --config "$tmp/sp-auth.json" --out "$tmp/spa" --no-check >/dev/null; jq -r '.projects[0].next[0]' "$tmp/spa/status.json")" "New billing page (#12) – Ana"
echo '{"title":"x"}' > "$tmp/sp-empty.json"
sp --config "$tmp/sp-empty.json" --out "$tmp/spe" >/dev/null 2>&1; expect "statuspage: no allowlist, no page" "$?" 1
[ -e "$tmp/spe" ] && fail "statuspage: nothing written without an allowlist" "written" || ok "statuspage: nothing written without an allowlist"
SP_CURL_LOG=/dev/null DEPLOYS_JOURNAL=/nonexistent RENDER_API_KEY=x statuspage/statuspage.sh --config "$tmp/sp-auth.json" --out "$tmp/spn" --no-check >/dev/null
expect "statuspage: no journal, empty timeline" "$(jq '.timeline | length' "$tmp/spn/status.json")" 0

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

echo
[ "$fails" = 0 ] && echo "All passed." || { echo "$fails failed."; exit 1; }
