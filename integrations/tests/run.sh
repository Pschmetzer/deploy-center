#!/bin/bash
# Tests for integrations/: a stand-in `deploys` answers from fixtures, a stand-in `curl`
# records what would be posted. No network, no real projects. Run: integrations/tests/run.sh
set -uo pipefail
cd "$(dirname "$0")/.." || exit 1
here="$PWD"
fails=0 skips=0
ok()   { echo "ok   $1"; }
fail() { echo "FAIL $1: $2"; fails=$((fails+1)); }
# A part that could not run here is counted, not passed. REQUIRE_ALL=1 (CI) makes it a failure.
skip() { echo "skip $1"; skips=$((skips+1)); }
expect()   { [ "$2" = "$3" ] && ok "$1" || fail "$1" "expected [$3], got [$2]"; }
contains() { case "$2" in *"$3"*) ok "$1" ;; *) fail "$1" "[$3] not in [$2]" ;; esac; }

tmp="$(mktemp -d)"; trap 'rm -rf "$tmp"' EXIT
now="$(date +%s)"
# app-web: Vercel, 3 days old, 4 commits waiting. site: Vercel, live a second ago, up to date,
# Git still connected. api: Render, live 26 h ago (a newer attempt a minute ago), waiting (count unknown), auto-deploy on.
cat > "$tmp/vercel.json" <<JSON
[{"name":"app-web","auto":false,"repo":"me/app","ref":"main","deployable":true,"changed":true,"pendingCommits":4,"lastAt":$((now - 3*86400)),"lastState":"READY","lastMsg":"Fix <b>login</b> & signup","lastSha":"aaaa111"},
 {"name":"site","auto":true,"repo":"me/site","ref":"main","deployable":true,"changed":false,"pendingCommits":0,"lastAt":$((now - 1)),"lastState":"READY","lastMsg":"Secret launch copy"}]
JSON
cat > "$tmp/render.json" <<JSON
[{"name":"api","auto":true,"repo":"me/app","ref":"main","deployable":true,"changed":true,"pendingCommits":null,"lastAt":$((now - 60)),"liveAt":$((now - 26*3600)),"lastSha":"bbbb222","lastState":"build_failed","lastMsg":"Add rate limits"}]
JSON
# A build log with secrets in it (made up), for the MCP server's masking; and a long one.
cat > "$tmp/secret.log" <<'LOG'
Cloning github.com/me/app (dev@example.com)
VERCEL_TOKEN=s3cr3t-value npm run build
curl -H "Authorization: Bearer abcdefghijklmnopqrstu" https://api.example.com
pushing with ghp_abcdefghijklmnop1234 and glpat-abcdefgh12345
"password": "hunter2pass", stripe sk_live_abcdefgh1234, aws AKIAABCDEFGHIJKLMNOP
jwt eyJhbGciOiJIUzI1NiJ9.eyJzdWIiOiIxIn0.sig
DATABASE_URL=postgres://admin:dbpass@db.internal:5432/app
-----BEGIN PRIVATE KEY-----
MIIEvQIBADANBgkqhkiG9w0BAQEFAASCBKcwggSjAgEAAoIBAQC
-----END PRIVATE KEY-----
Build failed: missing module
LOG
# Its URL user:password@ line ends up as postgres://admin:[masked]@db only if the name rule does
# not take the whole value first; DATABASE_URL has no secret word, so it does not.
awk 'BEGIN { for (i = 1; i < 30000; i++) printf "line %d some build output here\n", i; print "line 30000 the real error" }' > "$tmp/big.log"
mkdir -p "$tmp/bin"
cat > "$tmp/bin/deploys" <<SH
#!/bin/bash
[ -n "\${FAKE_SLEEP:-}" ] && [ "\$1" = vercel ] && sleep "\$FAKE_SLEEP"
[ -n "\${FAKE_SLEEP_ALL:-}" ] && sleep "\$FAKE_SLEEP_ALL"
[ -n "\${MCP_CALLS:-}" ] && echo "\$*" >> "\$MCP_CALLS"
case "\$*" in
  "vercel list --json") cat "$tmp/vercel.json" ;;
  "render list --json") cat "$tmp/render.json" ;;
  # As the real one: every provider that is on and set up. Render only with a key.
  "list --json") [ -n "\${FAKE_SLEEP:-}" ] && sleep "\$FAKE_SLEEP"
    # An older CLI without list: the MCP server falls back to status --json --no-github.
    [ -n "\${FAKE_NO_LIST:-}" ] && { echo "Unknown command list" >&2; exit 1; }
    if [ -n "\${RENDER_API_KEY:-}" ] || [ "\${FAKE_RENDER_KEY:-false}" = true ]; then r="$tmp/render.json"; else r=/dev/null; fi
    # FAKE_MORE=1: a Netlify project too, and a name on two platforms.
    jq -s --arg more "\${FAKE_MORE:-}" '(.[0] | map(. + {platform:"vercel"})) + ((.[1] // []) | map(. + {platform:"render"}))
      + (if \$more == "1" then [{name:"shop",platform:"netlify"},{name:"twin",platform:"vercel"},{name:"twin",platform:"netlify"}] else [] end)' "$tmp/vercel.json" \$r ;;
  "notes app-web") printf '## app-web\\n- New billing page (#12) – Ana\\n- Faster search – Ben\\n\\nDependency updates:\\n- Bump jq – dependabot\\n' ;;
  "notes "*) exit 1 ;;
  "simulate --days "*" --json") jq --argjson d "\$3" '.days = \$d' "$here/../tests/fixtures/savings/simulate-report.json" ;;
  "ledger --json") cat "$here/../tests/fixtures/savings/ledger-report.json" ;;
  "doctor") echo "{\"renderKey\":\${FAKE_RENDER_KEY:-false}}" ;;
  "changed --json") [ -n "\${FAKE_NOTHING:-}" ] && { echo '[]'; exit 0; }
    jq -s '(.[0] | map(. + {platform:"vercel"})) + (.[1] | map(. + {platform:"render"})) | map(select(.changed))
      | if env.FAKE_GITLAB == "1" then map(if .repo == "me/app" then .repo = "gitlab.com/grp/sub/app" else . end) else . end' "$tmp/vercel.json" "$tmp/render.json"; exit "\${FAKE_RC:-0}" ;;
  # Without --yes: what it would start, leaving out ignored.json as the real one does
  # (FAKE_IGNORE_IGNORED=1: a CLI that starts more than the Action asked for).
  "deploy-changed --json") ign="\${DEPLOYS_CONFIG:-/nonexistent}/ignored.json"
    if [ -s "\$ign" ] && [ -z "\${FAKE_IGNORE_IGNORED:-}" ]; then ig="\$(cat "\$ign")"; else ig='[]'; fi
    jq -s --argjson ig "\$ig" '(.[0] | map(. + {platform:"vercel"})) + (.[1] | map(. + {platform:"render"}))
      | map(select(.changed and ((.name as \$n | \$ig | index(\$n)) | not)) | {platform, name, action:"would-deploy"})' "$tmp/vercel.json" "$tmp/render.json" ;;
  "deploy-changed --yes --json") echo "\$*" >> "$tmp/deploy.log"
    [ -n "\${FAKE_TEXT:-}" ] && { echo "2 started, 0 failed to start."; exit 0; }
    if [ "\${FAKE_RC:-0}" = 0 ]; then echo '[{"platform":"vercel","name":"app-web","action":"started","reason":null,"id":"dpl_1","url":"https://x"},{"platform":"render","name":"api","action":"started","reason":null,"id":"dep-1","url":null}]'
    else echo '[{"platform":"vercel","name":"app-web","action":"started","reason":null,"id":"dpl_1","url":null},{"platform":"render","name":"api","action":"failed","reason":"HTTP 500","id":null,"url":null}]'; fi
    exit "\${FAKE_RC:-0}" ;;
  "status --json"|"status --json --no-github")
    jq -s --arg b "\${FAKE_BUILDING:-}" '(.[0] | map(. + {platform:"vercel"})) + (.[1] | map(. + {platform:"render"}))
      | map({platform, name, building:(.name == \$b), state:"READY", changed})' "$tmp/vercel.json" "$tmp/render.json" ;;
  "explain "*) echo "explain: \$2" ;;
  "logs secret-app "*) cat "$tmp/secret.log" ;;
  # The last lines of a log can start or end inside a key.
  "logs topkey-app "*) printf 'QUJDREVGR0hJSktMTU5PUFFSU1RVVldYWVo1\\nQUJDREVGR0hJSktMTU5PUFFSU1RVVldYWVo2\\n-----END RSA PRIVATE KEY-----\\nafter the key\\n' ;;
  "logs bottomkey-app "*) printf 'before the key\\n-----BEGIN RSA PRIVATE KEY-----\\nQUJDREVGR0hJSktMTU5PUFFSU1RVVldYWVo3\\n' ;;
  "logs big-app "*) cat "$tmp/big.log" ;;
  "logs "*) seq 1 "\${3:-80}" ;;
  "vercel deploy-json app-web"|"vercel deploy-json app-web --preview") [ -n "\${FAKE_DEPLOY_SLEEP:-}" ] && sleep "\$FAKE_DEPLOY_SLEEP"
    echo '{"id":"dpl_1","url":"https://app-web-x.vercel.app","state":"QUEUED"}' ;;
  "netlify deploy-json shop") echo '{"id":"nd-1","url":"https://shop.netlify.app","state":"new"}' ;;
  "netlify rollback shop") echo '{"id":"nd-0","state":"ready"}' ;;
  "render deploy-json api") echo '{"id":"dep-1","serviceId":"srv-1","state":"created"}' ;;
  "vercel rollback app-web") echo '{"id":"dpl_0","state":"READY"}' ;;
  "details me/app aaaa111 main"|"details gitlab.com/grp/sub/app aaaa111 main") cat "$tmp/details-web.json" ;;
  "details gitlab.com/grp/sub/app bbbb222 main") cat "$tmp/details-api.json" ;;
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
  "api repos/me/ops/issues/5/comments") cat "$tmp/comments.json" 2>/dev/null || echo '[]' ;;
  "issue create") echo "https://github.com/me/ops/issues/7" ;;
  "label create"|"issue edit"|"issue close"|"issue comment") ;;
  *) echo "unexpected gh: \$*" >&2; exit 1 ;;
esac
SH
echo '{"number":12,"title":"Login page","html_url":"https://github.com/me/app/pull/12","user":{"login":"dev-one","type":"User"},"labels":[]}' > "$tmp/pr12.json"
echo '{"number":13,"title":"New copy","html_url":"https://github.com/me/app/pull/13","user":{"login":"dev-two","type":"User"},"labels":[{"name":"AI-Generated"}]}' > "$tmp/pr13.json"
echo '{"number":14,"title":"Pool size","html_url":"https://github.com/me/app/pull/14","user":{"login":"dev-two","type":"User"},"labels":[{"name":"perf"}]}' > "$tmp/pr14.json"
# glab: merge requests of gitlab.com/grp/sub/app (the path URL-encoded), as GitLab answers them.
cat > "$tmp/bin/glab" <<SH
#!/bin/bash
printf '%s\n' "\$*" >> "$tmp/glab.log"
case "\$*" in
  "api --hostname gitlab.com projects/grp%2Fsub%2Fapp/merge_requests/12") echo '{"iid":12,"title":"MR login","web_url":"https://gitlab.com/grp/sub/app/-/merge_requests/12","author":{"username":"dev-one"},"labels":["ai-generated"]}' ;;
  "api --hostname gitlab.com projects/grp%2Fsub%2Fapp/merge_requests/13") echo '{"iid":13,"title":"MR copy","web_url":"https://gitlab.com/grp/sub/app/-/merge_requests/13","author":{"username":"renovate-bot"},"labels":[]}' ;;
  *) echo "unexpected glab: \$*" >&2; exit 1 ;;
esac
SH
cat > "$tmp/bin/curl" <<SH
#!/bin/bash
# Records the config from stdin (the URL) and the body file, like curl -K - --data-binary @f.
cat > "$tmp/curl.stdin"; printf '%s\n' "\$@" > "$tmp/curl.args"
for a in "\$@"; do case "\$a" in @*) cp "\${a#@}" "$tmp/curl.body" ;; esac; done
SH
chmod +x "$tmp/bin/deploys" "$tmp/bin/curl" "$tmp/bin/gh" "$tmp/bin/glab"
export PATH="$tmp/bin:$PATH" DEPLOYS="$tmp/bin/deploys" DEPLOYS_CONFIG="$tmp/config"
unset RENDER_API_KEY DEPLOYS_NOTIFY_URL DEPLOYS_NOTIFY_FORMAT DEPLOYS_DIGEST_REPO DEPLOYS_DIGEST_WORKFLOW DEPLOYS_AGENT_AUTHORS DEPLOYS_AGENT_LABELS

# --- lib: every project from `deploys list --json`; ignored projects left out ---
# shellcheck source=lib/projects.sh
. lib/projects.sh
expect "without a Render key only Vercel is read" "$(all_projects | jq -c 'map(.name)')" '["app-web","site"]'
expect "with a key in the env Render is read too" "$(RENDER_API_KEY=x all_projects | jq -c 'map(.platform)')" '["vercel","vercel","render"]'
expect "doctor's renderKey counts as a key" "$(FAKE_RENDER_KEY=true all_projects | jq length)" 3
expect "a CLI that fails is an empty list, not an error" "$(DEPLOYS=/bin/false all_projects)" "[]"
mkdir -p "$DEPLOYS_CONFIG"; echo '["api"]' > "$DEPLOYS_CONFIG/ignored.json"
expect "changed leaves out ignored and up-to-date" "$(RENDER_API_KEY=x changed_projects | jq -c 'map(.name)')" '["app-web"]'
rm -f "$DEPLOYS_CONFIG/ignored.json"

# --- badge ---
RENDER_API_KEY=x badge/badge.sh "$tmp/b" >/dev/null
expect "one badge per project" "$(cd "$tmp/b" && echo *.svg)" "api.svg app-web.svg site.svg"
contains "badge: days and commits" "$(cat "$tmp/b/app-web.svg")" "3 d ago · 4 commits waiting"
contains "badge: Render shows the live commit's age, not the newest attempt" "$(cat "$tmp/b/api.svg")" "1 d ago · changes waiting"
contains "badge: up to date is green" "$(cat "$tmp/b/site.svg")" 'fill="#4c1"'
echo '[{"name":"web","platform":"vercel","changed":false,"lastAt":0},{"name":"web","platform":"netlify","changed":false,"lastAt":0},{"name":"solo","platform":"render","changed":false,"lastAt":0}]' | badge/badge.sh "$tmp/tw" - >/dev/null
expect "badge: a name on two platforms gets one badge each" "$(cd "$tmp/tw" && echo *.svg)" "netlify-web.svg solo.svg vercel-web.svg"
echo '[{"name":"a<b>&\"c","changed":false,"lastAt":0}]' | badge/badge.sh "$tmp/e" - >/dev/null
contains "badge: names are XML-escaped" "$(cat "$tmp/e/a_b___c.svg")" 'a&lt;b&gt;&amp;&quot;c: deployed never'
if command -v xmllint >/dev/null; then
  xmllint --noout "$tmp"/b/*.svg "$tmp"/e/*.svg && ok "badges are well-formed XML" || fail "badges are well-formed XML" xmllint
else
  skip "badges: XML check needs xmllint"
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
DEPLOYS_NOTIFY_URL='http://api.telegram.org/botT/sendMessage' notify/notify.sh >/dev/null 2>&1; expect "notify: refuses http:// to another host" "$?" 1
DEPLOYS_NOTIFY_URL='http://localhost:8080/topic' notify/notify.sh >/dev/null 2>&1; expect "notify: http:// to localhost is fine" "$?" 0

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
git -C "$tmp/repo" config deploys.prepush.skip false; git -C "$tmp/repo" config deploys.prepush.block false
cat > "$tmp/bin/pp-deploys" <<SH
#!/bin/bash
[ "\$*" = "list --json" ] && echo '[{"name":"shop","platform":"netlify","auto":true,"repo":"gitlab.com/grp/sub/app","ref":"main"},{"name":"cf","platform":"cloudflare","auto":true,"repo":"github.com/me/app","ref":"main"}]'
SH
chmod +x "$tmp/bin/pp-deploys"
out="$(DEPLOYS="$tmp/bin/pp-deploys" push "refs/heads/main $s1 refs/heads/main $z" git@gitlab.com:grp/sub/app.git)"
contains "pre-push: a GitLab remote and Netlify are checked" "$out" "netlify  shop  (production, branch main)"
out="$(DEPLOYS="$tmp/bin/pp-deploys" push "refs/heads/main $s1 refs/heads/main $z" https://github.com/me/app.git)"
contains "pre-push: every platform from list --json (cloudflare)" "$out" "cloudflare  cf  (production, branch main)"
out="$(FAKE_NO_LIST=1 push "refs/heads/main $s1 refs/heads/main $z" https://github.com/me/site.git)"
contains "pre-push: a CLI without list falls back to vercel and render" "$out" "vercel  site  (production, branch main)"

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
echo '{"projects":["netlify/shop"]}' > "$tmp/sp-nl.json"
sp --config "$tmp/sp-nl.json" --out "$tmp/sp-nl" >/dev/null
expect "statuspage: platform/name works for any platform" "$(jq -c '.projects[0] | [.name, .platform]' "$tmp/sp-nl/status.json")" '["shop","netlify"]'
expect "statuspage: live message" "$(jq -r '.projects[0].message' <<<"$st")" 'Fix <b>login</b> & signup'
contains "statuspage: HTML-escaped" "$page" 'Fix &lt;b&gt;login&lt;/b&gt; &amp; signup'
contains "statuspage: title escaped" "$page" '<title>Acme &lt;deploys&gt;</title>'
expect "statuspage: notes from deploys notes, no authors by default" "$(jq -c '.projects[0].next' <<<"$st")" '["New billing page (#12)","Faster search","Dependency update: Bump jq"]'
expect "statuspage: Render shows the live time, not the failed attempt" "$(jq -r '.projects[1] | "\(.state) \(.at)"' <<<"$st")" "live-failed $((now - 26*3600))"
expect "statuspage: site check" "$(jq -c '.projects[1].check' <<<"$st")" '{"up":true,"code":200,"ms":123}'
expect "statuspage: only the configured URL is checked" "$(cat "$tmp/sp-curl.log")" "https://api.up.test/health"
expect "statuspage: timeline is the last 30" "$(jq '.timeline | length' <<<"$st")" 30
expect "statuspage: timeline newest first, only listed, live and failed" "$(jq -r '.timeline[0] | "\(.name) \(.result)"' <<<"$st")" "API failed"
case "$st$page$feed" in *SECRET*|*/Users/*|*"nothing to do"*|*abc1234*|*aaaa111*|*bbbb222*|*me/app*) fail "statuspage: no journal detail, SHA or repo" "found" ;; *) ok "statuspage: no journal detail, SHA or repo" ;; esac
expect "statuspage: feed has an entry per deploy" "$(grep -c '<entry>' <<<"$feed")" 30
contains "statuspage: feed links the page" "$feed" '<link rel="self" href="https://status.example.test/feed.xml"/>'
case "$page" in *'src="http'*|*'href="http'*|*"@import"*|*"url("*) fail "statuspage: no external assets" "found" ;; *) ok "statuspage: no external assets" ;; esac
contains "statuspage: dark mode" "$page" "prefers-color-scheme:dark"
if command -v xmllint >/dev/null; then
  xmllint --noout "$tmp/sp/feed.xml" && ok "statuspage: feed is well-formed XML" || fail "statuspage: feed is well-formed XML" xmllint
  xmllint --html --noout "$tmp/sp/index.html" 2>/dev/null && ok "statuspage: page parses as HTML" || fail "statuspage: page parses as HTML" xmllint
else
  skip "statuspage: XML checks need xmllint"
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
  # repo: "*" is the whole account, as before.
  REPO='*' run_step deploy.sh; expect "action: deploy step calls deploy-changed --yes" "$(cat "$tmp/deploy.log")" "deploy-changed --yes --json"
  expect "action: outputs after starting" "$(tr '\n' ' ' < "$tmp/out")" "started=2 failed=0 deployed=true "
  REPO='*' FAKE_RC=1 run_step deploy.sh; expect "action: a failed start fails the step" "$?" 1
  expect "action: outputs are written before failing" "$(tr '\n' ' ' < "$tmp/out")" "started=1 failed=1 deployed=false "
  REPO='*' FAKE_TEXT=1 run_step deploy.sh; expect "action: an answer that is not JSON fails the step" "$?" 1
  expect "action: and says the counts are unknown" "$(tr '\n' ' ' < "$tmp/out")" "started=0 failed=0 deployed=false "
  expect "action: repo defaults to the workflow's repository" "$(ruby -ryaml -e 'puts YAML.load_file(ARGV[0])["inputs"]["repo"]["default"]' action/action.yml)" '${{ github.repository }}'
  # Only this repo: the other repos' projects go into this run's ignored.json, then deploy-changed.
  mkdir -p "$DEPLOYS_CONFIG"; : > "$tmp/deploy.log"; rm -f "$DEPLOYS_CONFIG/ignored.json"
  REPO=me/app FAKE_RENDER_KEY=true run_step deploy.sh; expect "action: repo: the step passes" "$?" 0
  expect "action: repo: other repos' projects are left out" "$(jq -c . "$DEPLOYS_CONFIG/ignored.json")" '["site"]'
  expect "action: repo: then deploy-changed --yes" "$(cat "$tmp/deploy.log")" "deploy-changed --yes --json"
  : > "$tmp/deploy.log"; rm -f "$DEPLOYS_CONFIG/ignored.json"
  REPO=GitHub.com/Me/Site FAKE_RENDER_KEY=true run_step deploy.sh; expect "action: repo: case and github.com/ do not matter" "$?" 0
  expect "action: repo: me/site leaves out me/app's projects" "$(jq -c . "$DEPLOYS_CONFIG/ignored.json")" '["api","app-web"]'
  : > "$tmp/deploy.log"; rm -f "$DEPLOYS_CONFIG/ignored.json"
  REPO=me/site FAKE_RENDER_KEY=true FAKE_IGNORE_IGNORED=1 run_step deploy.sh; expect "action: repo: a CLI that would start more fails the step" "$?" 1
  expect "action: repo: and starts nothing" "$(cat "$tmp/deploy.log")" ""
  # Render is not listed without a key, but api still shows as changed: fail closed.
  rm -f "$DEPLOYS_CONFIG/ignored.json"
  REPO=me/site run_step deploy.sh; expect "action: repo: a project missing from the list fails the step" "$?" 1
  expect "action: repo: and starts nothing either" "$(cat "$tmp/deploy.log")" ""
  rm -f "$DEPLOYS_CONFIG/ignored.json"
  REPO=me/app DEPLOYS=/bin/false run_step deploy.sh; expect "action: repo: no list, no deploy" "$?" 1
  expect "action: repo: no list, nothing started" "$(cat "$tmp/deploy.log")" ""
  REPO=other/none FAKE_RENDER_KEY=true run_step deploy.sh; expect "action: repo: no project from that repo passes" "$?" 0
  expect "action: repo: and starts nothing" "$(cat "$tmp/deploy.log")$(tr '\n' ' ' < "$tmp/out")" "started=0 failed=0 deployed=true "
  REPO='me/app;x' run_step deploy.sh; expect "action: repo: a strange value is refused" "$?" 1
  rm -f "$DEPLOYS_CONFIG/ignored.json"
  expect "action: deploy step only with deploy: true" "$(step deploy if)" "inputs.deploy == 'true' && steps.changed.outputs.count != '0'"
  case "$(cat "$tmp/changed.sh" "$tmp/deploy.sh")" in *'${{'*) fail "action: no inputs inside run scripts" "found" ;; *) ok "action: no inputs inside run scripts" ;; esac
else
  skip "action: its steps need ruby"
fi

# --- VS Code extension: its own unit tests (node), when its dev dependencies are installed ---
if command -v npm >/dev/null && [ -d vscode/node_modules ]; then
  (cd vscode && npm test --silent >"$tmp/vscode.log" 2>&1) && ok "vscode: unit tests" || { fail "vscode: unit tests" "see below"; cat "$tmp/vscode.log"; }
  # A timed-out CLI is stopped with its process group: the stand-in's sleep does not outlive the tests.
  pgrep -f "sleep 20(\.3)?$" >/dev/null && fail "vscode: no sleep left behind" "$(pgrep -fl 'sleep 20')" || ok "vscode: no sleep left behind"
else
  skip "vscode: run npm ci in integrations/vscode first"
fi


# --- Claude Code plugin: manifest checks, shellcheck, and the after-push hook ---
if integrations_cc="$(tests/claude-code.sh --quiet 2>&1)"; then ok "claude-code: plugin and marketplace files are valid"
else fail "claude-code: plugin and marketplace files are valid" "$(grep FAIL <<<"$integrations_cc" | head -5)"; fi
hook="$here/claude-code/scripts/after-push.sh"
if command -v shellcheck >/dev/null; then
  shellcheck --severity=style "$hook" && ok "claude-code: shellcheck after-push.sh" || fail "claude-code: shellcheck after-push.sh" "see above"
  shellcheck --severity=warning tests/claude-code.sh && ok "claude-code: shellcheck claude-code.sh" || fail "claude-code: shellcheck claude-code.sh" "see above"
else
  skip "claude-code: shellcheck is not installed"
fi
git init -q "$tmp/cc" && git -C "$tmp/cc" remote add origin git@github.com:me/app.git
git init -q "$tmp/cc-other" && git -C "$tmp/cc-other" remote add origin https://github.com/someone/else.git
git -C "$tmp/cc" remote add mirror https://github.com/me/site.git
hk() { jq -nc --arg c "$1" --arg d "${2:-$tmp/cc}" '{hook_event_name:"PostToolUse",tool_name:"Bash",cwd:$d,tool_input:{command:$c},tool_response:{stdout:"",stderr:"",interrupted:false}}' | "$hook"; echo "exit=$?"; }
out="$(hk "git push")"
expect "claude-code hook: one line for the pushed repo" "$(head -1 <<<"$out" | jq -r .systemMessage)" \
  "4 commits waiting on app-web, changes waiting on api: deploy when ready (deploys changed)"
contains "claude-code hook: tells Claude not to deploy" "$(head -1 <<<"$out" | jq -r .hookSpecificOutput.additionalContext)" "Do not deploy unless the user explicitly says so"
expect "claude-code hook: event name" "$(head -1 <<<"$out" | jq -r .hookSpecificOutput.hookEventName)" PostToolUse
contains "claude-code hook: always exit 0" "$out" "exit=0"
contains "claude-code hook: git push origin main -u" "$(hk "git push -u origin main" | head -1)" "app-web"
expect "claude-code hook: another remote, nothing waiting there" "$(hk "git push mirror main")" "exit=0"
expect "claude-code hook: a repo with no projects is silent" "$(hk "git push" "$tmp/cc-other")" "exit=0"
expect "claude-code hook: not a push, silent" "$(hk "git status")" "exit=0"
expect "claude-code hook: git stash push is not a push" "$(hk "git stash push -m wip")" "exit=0"
expect "claude-code hook: --dry-run is not a push" "$(hk "git push --dry-run origin main")" "exit=0"
expect "claude-code hook: -n is not a push" "$(hk "git push -n")" "exit=0"
contains "claude-code hook: cd dir && git push reads that repo" "$(hk "cd $tmp/cc && git push" "$tmp/cc-other" | head -1)" "app-web"
contains "claude-code hook: git -C dir push reads that repo" "$(hk "git -C $tmp/cc push origin main" "$tmp/cc-other" | head -1)" "app-web"
expect "claude-code hook: git -C another repo, silent" "$(hk "git -C $tmp/cc-other push")" "exit=0"
contains "claude-code hook: a push after other commands" "$(hk "git add -A && git commit -m x; git push" | head -1)" "app-web"
hk_err() { jq -nc --arg c "git push" --arg d "$tmp/cc" --arg e "$1" '{hook_event_name:"PostToolUse",tool_name:"Bash",cwd:$d,tool_input:{command:$c},tool_response:{stdout:"",stderr:$e,interrupted:false}}' | "$hook"; echo "exit=$?"; }
expect "claude-code hook: a rejected push, silent" "$(hk_err $' ! [rejected]        main -> main (fetch first)\nerror: failed to push some refs')" "exit=0"
contains "claude-code hook: a normal push's stderr still counts" "$(hk_err $'To github.com:me/app.git\n   abc..def  main -> main' | head -1)" "app-web"
expect "claude-code hook: silent without deploys" "$(DEPLOYS=/nonexistent hk "git push")" "exit=0"
if [ ! -e "/Applications/Deploy Center.app" ] && [ ! -e "$HOME/Applications/Deploy Center.app" ]; then
  nodeploys="$tmp/nodeploys"; mkdir -p "$nodeploys"
  for t in jq git sed mktemp rm cat sleep pgrep kill dirname; do p="$(command -v "$t")" && ln -sf "$p" "$nodeploys/$t"; done
  expect "claude-code hook: silent with no deploys on PATH" "$(env -u DEPLOYS PATH="$nodeploys" HOME="$tmp" "$BASH" -c "$(declare -f hk); tmp='$tmp' hook='$hook'; hk 'git push'")" "exit=0"
else
  skip "claude-code hook: no-deploys-on-PATH check (Deploy Center.app is installed here)"
fi
expect "claude-code hook: off with the plugin option" "$(CLAUDE_PLUGIN_OPTION_PUSH_REMINDER=false hk "git push")" "exit=0"
expect "claude-code hook: off with DEPLOYS_PUSH_REMINDER=off" "$(DEPLOYS_PUSH_REMINDER=off hk "git push")" "exit=0"
expect "claude-code hook: silent on bad input" "$(echo 'not json' | "$hook"; echo "exit=$?")" "exit=0"
start=$(date +%s)
cat > "$tmp/bin/slow-deploys" <<SH
#!/bin/bash
sleep 30
SH
chmod +x "$tmp/bin/slow-deploys"
expect "claude-code hook: a CLI that does not answer is silent" "$(DEPLOYS="$tmp/bin/slow-deploys" DEPLOYS_HOOK_TIMEOUT=1 hk "git push")" "exit=0"
[ $(( $(date +%s) - start )) -lt 6 ] && ok "claude-code hook: gives up after the timeout" || fail "claude-code hook: gives up after the timeout" "took too long"
cat > "$tmp/bin/one-deploys" <<SH
#!/bin/bash
echo '[{"name":"web","repo":"Me/App","platform":"vercel","pendingCommits":1}]'; exit 1
SH
chmod +x "$tmp/bin/one-deploys"
expect "claude-code hook: singular, repo case ignored, exit 1 list still used" \
  "$(DEPLOYS="$tmp/bin/one-deploys" hk "git push" | head -1 | jq -r .systemMessage)" "1 commit waiting on web: deploy when ready (deploys changed)"
git init -q "$tmp/cc-gl" && git -C "$tmp/cc-gl" remote add origin git@gitlab.com:grp/sub/app.git
git -C "$tmp/cc-gl" remote add gh https://github.com/Me/App.git
cat > "$tmp/bin/gl-deploys" <<SH
#!/bin/bash
echo '[{"name":"gl-web","repo":"gitlab.com/grp/sub/app","platform":"netlify","pendingCommits":2},{"name":"web","repo":"github.com/me/app","platform":"vercel","pendingCommits":1}]'
SH
chmod +x "$tmp/bin/gl-deploys"
expect "claude-code hook: a GitLab remote (subgroup) is read" \
  "$(DEPLOYS="$tmp/bin/gl-deploys" hk "git push" "$tmp/cc-gl" | head -1 | jq -r .systemMessage)" "2 commits waiting on gl-web: deploy when ready (deploys changed)"
expect "claude-code hook: github.com/owner/name in .repo counts as owner/name" \
  "$(DEPLOYS="$tmp/bin/gl-deploys" hk "git push gh" "$tmp/cc-gl" | head -1 | jq -r .systemMessage)" "1 commit waiting on web: deploy when ready (deploys changed)"
deploy_calls_before="$(cat "$tmp/deploy.log" 2>/dev/null | wc -l)"
hk "git push" >/dev/null
expect "claude-code hook: never deploys" "$(cat "$tmp/deploy.log" 2>/dev/null | wc -l)" "$deploy_calls_before"
# --- the MCP server (needs node and `npm ci` in mcp/) ---
if command -v node >/dev/null && [ -d mcp/node_modules/@modelcontextprotocol/sdk ]; then
  DEPLOYS_BIN="$tmp/bin/deploys" MCP_CALLS="$tmp/mcp-calls.log" node tests/mcp.test.mjs || fails=$((fails+1))
  # 20.7: a length no other test sleeps, so only this test's child can match.
  pgrep -f "sleep 20\.7" >/dev/null && fail "mcp: a timed-out CLI is stopped with its children" "still running" || ok "mcp: a timed-out CLI is stopped with its children"
else
  skip "mcp: needs node and (cd integrations/mcp && npm ci)"
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
j="$(FAKE_GITLAB=1 RENDER_API_KEY=x digest/digest.sh --json)"
expect "digest: GitLab merge requests through glab" "$(jq -c '.projects[0].prs | map([.number, .title, .url])' <<<"$j")" \
  '[[12,"MR login","https://gitlab.com/grp/sub/app/-/merge_requests/12"],[13,"MR copy","https://gitlab.com/grp/sub/app/-/merge_requests/13"]]'
contains "digest: glab asked for the MR" "$(cat "$tmp/glab.log" 2>/dev/null)" "merge_requests/12"
expect "digest: GitLab repos never go to gh" "$(grep -c 'grp' "$tmp/gh.log" || true)" 0
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
: > "$tmp/gh.log"; RENDER_API_KEY=x DEPLOYS_DIGEST_REPO=me/ops digest/digest.sh --issue >/dev/null
contains "digest issue: the list goes into a comment of the digest" "$(cat "$tmp/gh.log")" "issue comment 5 -R me/ops --body-file"
: > "$tmp/gh.log"; FAKE_NOTHING=1 RENDER_API_KEY=x DEPLOYS_DIGEST_REPO=me/ops digest/digest.sh --issue >/dev/null
contains "digest issue: nothing waiting closes today's open digest" "$(cat "$tmp/gh.log")" "issue close 5 -R me/ops --comment Nothing is waiting any more"
case "$(cat "$tmp/gh.log")" in *"issue edit"*|*"issue create"*) fail "digest issue: nothing waiting, nothing written" "$(cat "$tmp/gh.log")" ;; *) ok "digest issue: nothing waiting, nothing written" ;; esac
rm -f "$tmp/issues.json"

# --- approve-deploy.yml: its steps, run as GitHub would (needs ruby for the YAML) ---
if command -v ruby >/dev/null; then
  wstep() { ruby -ryaml -e 'puts YAML.load_file(ARGV[0])["jobs"]["deploy"]["steps"].find { |s| s["id"] == ARGV[1] }[ARGV[2]]' digest/examples/approve-deploy.yml "$1" "${2:-run}"; }
  wstep approved > "$tmp/approved.sh"; wstep keep > "$tmp/keep.sh"; wstep report > "$tmp/report.sh"
  approve() { : > "$tmp/out"; env GITHUB_OUTPUT="$tmp/out" EVENT="${EVENT:-workflow_dispatch}" ACTOR="${ACTOR:-dev-one}" SENDER_TYPE="${SENDER_TYPE:-User}" \
      APPROVERS="${APPROVERS-dev-one, Dev-Two}" INPUT="${INPUT:-}" ISSUE=5 REPO=me/ops DIGEST_BOT='github-actions[bot]' bash "$tmp/approved.sh" >/dev/null 2>&1; echo "$?:$(grep '^projects=' "$tmp/out")"; }
  expect "approve: an approver's list" "$(INPUT='api, app-web' approve)" "0:projects=api,app-web"
  expect "approve: logins match without case" "$(ACTOR=dev-two INPUT=api approve)" "0:projects=api"
  expect "approve: all means everything waiting" "$(INPUT=all approve)" "0:projects=*"
  expect "approve: someone not listed is refused" "$(ACTOR=dev-three INPUT=api approve)" "1:"
  expect "approve: a bot is refused" "$(ACTOR='claude[bot]' APPROVERS='claude[bot]' INPUT=api approve)" "1:"
  expect "approve: a bot sender is refused" "$(SENDER_TYPE=Bot INPUT=api approve)" "1:"
  expect "approve: no DEPLOYS_APPROVERS, no deploy" "$(APPROVERS='' INPUT=api approve)" "1:"
  expect "approve: odd names are refused" "$(INPUT='api,$(x)' approve)" "1:"
  expect "approve: nothing named, nothing deployed" "$(INPUT=' , ' approve)" "1:"
  cmt() { jq -nc --arg u "$1" --arg b "$2" --arg c "${3:-2026-01-01T00:00:00Z}" --arg e "${4:-2026-01-01T00:00:00Z}" '{user:{login:$u}, body:$b, created_at:$c, updated_at:$e}'; }
  { echo '['; cmt 'github-actions[bot]' $'list\r\n<!-- deploys-approve: site -->'; echo ','; cmt 'github-actions[bot]' $'newer\n<!-- deploys-approve: app-web,api -->'
    echo ','; cmt dev-two '<!-- deploys-approve: all -->'; echo ']'; } > "$tmp/comments.json"
  expect "approve: the issue route reads the digest's newest comment" "$(EVENT=issues approve)" "0:projects=api,app-web"
  { echo '['; cmt 'github-actions[bot]' '<!-- deploys-approve: app-web -->' 2026-01-01T00:00:00Z 2026-01-01T00:05:00Z; echo ']'; } > "$tmp/comments.json"
  expect "approve: an edited list deploys nothing" "$(EVENT=issues approve)" "1:"
  { echo '['; cmt dev-two '<!-- deploys-approve: all -->'; echo ']'; } > "$tmp/comments.json"
  expect "approve: a list from someone else deploys nothing" "$(EVENT=issues approve)" "1:"
  echo '[]' > "$tmp/comments.json"
  expect "approve: an issue without the list deploys nothing" "$(EVENT=issues approve)" "1:"
  expect "approve: platform:name is a valid name" "$(INPUT='vercel:app-web' approve)" "0:projects=vercel:app-web"
  expect "approve: a refusal says why" "$(ACTOR=dev-three INPUT=api approve >/dev/null; sed -n 's/^reason=//p' "$tmp/out")" "dev-three is not in DEPLOYS_APPROVERS."
  # keep: every known project not approved goes into ignored.json (the config the action set up)
  keep() { mkdir -p "$tmp/kc"; rm -f "$tmp/kc/ignored.json"; DEPLOYS_CONFIG="$tmp/kc" PROJECTS="$1" VERCEL_TOKEN=t RENDER_API_KEY="${2-k}" bash "$tmp/keep.sh" 2>&1; echo "rc=$?"; }
  out="$(keep app-web)"
  expect "keep: the rest is left out" "$(jq -c . "$tmp/kc/ignored.json")" '["api","site"]'
  contains "keep: says what goes" "$out" "Deploying only: app-web"
  out="$(keep app-web,gone)"
  contains "keep: an unknown name is named" "$out" "Not found, so not deployed: gone"
  keep site,api >/dev/null; expect "keep: two approved" "$(jq -c . "$tmp/kc/ignored.json")" '["app-web"]'
  keep render:api >/dev/null; expect "keep: platform:name" "$(jq -c . "$tmp/kc/ignored.json")" '["app-web","site"]'
  out="$(keep vercel:api)"; contains "keep: platform:name on the wrong platform is named" "$out" "Not found on that platform, so not deployed: vercel:api"
  out="$(FAKE_MORE=1 keep vercel:twin)"; contains "keep: one platform of a name on two is refused" "$out" "rc=1"
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
else
  skip "approve-deploy: its steps need ruby"
fi

echo
if [ "$skips" -gt 0 ] && [ "${REQUIRE_ALL:-0}" = 1 ]; then
  echo "$skips skipped, and REQUIRE_ALL=1 counts a skip as a failure."; fails=$((fails + skips))
fi
if [ "$fails" != 0 ]; then echo "$fails failed$([ "$skips" -gt 0 ] && echo ", $skips skipped")."; exit 1; fi
if [ "$skips" -gt 0 ]; then echo "Passed, but $skips skipped (not tested here)."; else echo "All passed."; fi
