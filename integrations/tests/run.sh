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
[{"name":"app-web","auto":false,"repo":"me/app","ref":"main","deployable":true,"changed":true,"pendingCommits":4,"lastAt":$((now - 3*86400)),"lastState":"READY","lastMsg":"Fix <b>login</b> & signup","lastSha":"aaaa111"},
 {"name":"site","auto":true,"repo":"me/site","ref":"main","deployable":true,"changed":false,"pendingCommits":0,"lastAt":$((now - 1)),"lastState":"READY","lastMsg":"Secret launch copy"}]
JSON
cat > "$tmp/render.json" <<JSON
[{"name":"api","auto":true,"repo":"me/app","ref":"main","deployable":true,"changed":true,"pendingCommits":null,"lastAt":$((now - 60)),"liveAt":$((now - 26*3600)),"lastSha":"bbbb222","lastState":"build_failed","lastMsg":"Add rate limits"}]
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
  # As the real one: every provider that is on and set up. Render only with a key.
  "list --json") [ -n "\${FAKE_SLEEP:-}" ] && sleep "\$FAKE_SLEEP"
    # An older CLI without list --json.
    [ -n "\${FAKE_NO_LIST:-}" ] && { echo "unknown command: list" >&2; exit 1; }
    if [ -n "\${RENDER_API_KEY:-}" ] || [ "\${FAKE_RENDER_KEY:-false}" = true ]; then r="$tmp/render.json"; else r=/dev/null; fi
    jq -s --arg dup "\${FAKE_DUP:-}" '(.[0] | map(. + {platform:"vercel"})) + ((.[1] // []) | map(. + {platform:"render"}))
      + (if \$dup != "" then [{name:"app-web", platform:"render"}] else [] end)' "$tmp/vercel.json" \$r ;;
  "notes app-web") printf '## app-web\\n- New billing page (#12) – Ana\\n- Faster search – Ben\\n\\nDependency updates:\\n- Bump jq – dependabot\\n' ;;
  "notes broken") printf '\033[31mpartial notes\033[0m\n'; echo "Error: GitHub rate limit" >&2; exit 1 ;;
  "notes "*) exit 1 ;;
  "simulate --days "*" --json") jq --argjson d "\$3" '.days = \$d' "$here/../tests/fixtures/savings/simulate-report.json" ;;
  "ledger --json") cat "$here/../tests/fixtures/savings/ledger-report.json" ;;
  "doctor") [ -n "\${FAKE_ENV_DUMP:-}" ] && { env | cut -d= -f1; exit 0; }
    [ -n "\${FAKE_DOCTOR_SLEEP:-}" ] && sleep "\$FAKE_DOCTOR_SLEEP"; echo "{\"renderKey\":\${FAKE_RENDER_KEY:-false}}" ;;
  "changed --json") jq -s --arg lv "\${FAKE_LEVEL:-}" '(.[0] | map(. + {platform:"vercel"})) + (.[1] | map(. + {platform:"render"})) | map(select(.changed))
      | if \$lv != "" then map(if .name == "app-web" then . + {risk:{level:\$lv, reasons:[{level:\$lv, text:"touches a migration"}]}} else . + {risk:{level:"green", reasons:[]}} end) else . end' "$tmp/vercel.json" "$tmp/render.json"; exit "\${FAKE_RC:-0}" ;;
  "deploy-changed") echo "Would deploy: app-web, api (run with --yes)" ;;
  "deploy-changed --json") echo '[{"platform":"vercel","name":"app-web","sha":"c4","action":"would-deploy","commits":4,"risk":"red"}]' ;;
  "deploy-changed --yes --json") echo "\$*" >> "$tmp/deploy.log"
    echo '[{"platform":"vercel","name":"app-web","action":"started","reason":null,"id":"dpl_1"},{"platform":"render","name":"api","action":"started","reason":null,"id":"dep-1"}]' ;;
  "watch vercel:app-web dpl_1") [ -n "\${FAKE_WATCH_SLOW:-}" ] && sleep 5; exit "\${FAKE_WATCH_WEB:-0}" ;;
  "watch render:api dep-1") exit "\${FAKE_WATCH_API:-0}" ;;
  "deploy-changed --yes") echo "\$*" >> "$tmp/deploy.log"
    if [ -n "\${FAKE_NO_SUMMARY:-}" ]; then :; elif [ "\${FAKE_RC:-0}" = 0 ]; then echo "2 started, 0 failed to start."; else echo "1 started, 1 failed to start."; fi
    exit "\${FAKE_RC:-0}" ;;
  "status --json"|"status --json --no-github")
    jq -s '(.[0] | map(. + {platform:"vercel"})) + (.[1] | map(. + {platform:"render"}))
      | map({platform, name, building:false, state:"READY", changed})' "$tmp/vercel.json" "$tmp/render.json" ;;
  "explain "*) echo "explain: \$2" ;;
  "diff "*) echo "diff: \$2" ;;
  "history "*) echo "history \$2 \$3" ;;
  "logs "*) if [ -n "\${FAKE_SECRET_LOG:-}" ]; then
      printf '%s\n' 'GITHUB_TOKEN=ghp_abcdefgh12345678' 'export DB_PASSWORD="hunter2"' 'key sk-ant-abc12345678 and rnd_abcdefgh123' \
        'postgres://app:s3cr3t@db.example.test/app' 'Build ok · Umlaut ä'
    else seq 1 "\${3:-80}"; fi ;;
  "vercel deploy-json app-web"|"vercel deploy-json app-web --preview") [ -n "\${FAKE_DEPLOY_SLEEP:-}" ] && sleep "\$FAKE_DEPLOY_SLEEP"; echo '{"id":"dpl_1","url":"https://app-web-x.vercel.app","state":"QUEUED"}' ;;
  "render deploy-json api") echo '{"id":"dep-1","serviceId":"srv-1","state":"created"}' ;;
  "vercel rollback app-web") echo '{"id":"dpl_0","state":"READY"}' ;;
  "render rollback api") echo '{"id":"dep-0","state":"live"}' ;;
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
  "issue list") [ -n "\${FAKE_GH_FAIL:-}" ] && { echo "HTTP 401: Bad credentials" >&2; exit 1; }; cat "$tmp/issues.json" 2>/dev/null || echo '[]' ;;
  "issue create") [ -n "\${FAKE_GH_CREATE_FAIL:-}" ] && { echo "HTTP 410: Issues are disabled" >&2; exit 1; }; echo "https://github.com/me/ops/issues/7" ;;
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

# --- lib: every project from `deploys list --json`; ignored projects left out ---
# shellcheck source=lib/projects.sh
. lib/projects.sh
expect "without a Render key only Vercel is read" "$(all_projects | jq -c 'map(.name)')" '["app-web","site"]'
expect "with a key in the env Render is read too" "$(RENDER_API_KEY=x all_projects | jq -c 'map(.platform)')" '["vercel","vercel","render"]'
expect "doctor's renderKey counts as a key" "$(FAKE_RENDER_KEY=true all_projects | jq length)" 3
expect "a CLI that fails is an empty list and an error" "$(DEPLOYS=/bin/false all_projects 2>/dev/null; echo "rc=$?")" $'[]\nrc=1'
expect "notify: a CLI that fails posts nothing" "$(DEPLOYS=/bin/false notify/notify.sh --dry-run 2>/dev/null; echo "rc=$?")" "rc=1"
expect "badge: a CLI that fails writes no badge" "$(DEPLOYS=/bin/false badge/badge.sh "$tmp/bfail" 2>/dev/null; echo "rc=$?"; ls "$tmp/bfail" 2>/dev/null | wc -l | tr -d ' ')" $'rc=1\n0'
mkdir -p "$DEPLOYS_CONFIG"; echo '["api"]' > "$DEPLOYS_CONFIG/ignored.json"
expect "changed leaves out ignored and up-to-date" "$(RENDER_API_KEY=x changed_projects | jq -c 'map(.name)')" '["app-web"]'
contains "notify: ignored projects are not waiting" "$(RENDER_API_KEY=x notify/notify.sh --dry-run)" 'Waiting (1): app-web (4 commits)'
rm -f "$DEPLOYS_CONFIG/ignored.json"

# --- badge ---
RENDER_API_KEY=x badge/badge.sh "$tmp/b" >/dev/null
expect "one badge per project" "$(cd "$tmp/b" && echo *.svg)" "api.svg app-web.svg site.svg"
contains "badge: days and commits" "$(cat "$tmp/b/app-web.svg")" "3 d ago · 4 commits waiting"
contains "badge: Render shows the live commit's age, and a failed newest build" "$(cat "$tmp/b/api.svg")" "1 d ago · build failed"
contains "badge: a failed build is red" "$(cat "$tmp/b/api.svg")" 'fill="#e05d44'
echo '[{"name":"busy","changed":false,"lastAt":1,"building":true}]' | badge/badge.sh "$tmp/bb" - >/dev/null
contains "badge: a running build is blue, not up to date" "$(cat "$tmp/bb/busy.svg")" 'building'
contains "badge: up to date is green" "$(cat "$tmp/b/site.svg")" 'fill="#4c1"'
echo '[{"name":"a<b>&\"c","changed":false,"lastAt":0}]' | badge/badge.sh "$tmp/e" - >/dev/null
contains "badge: names are XML-escaped" "$(cat "$tmp/e/a_b___c.svg")" 'a&lt;b&gt;&amp;&quot;c: deployed never'
echo '[{"name":"web","platform":"vercel","lastAt":1},{"name":"web","platform":"render","lastAt":1},{"name":"a/b","lastAt":1},{"name":"a_b","lastAt":1}]' | badge/badge.sh "$tmp/c" - >/dev/null
expect "badge: colliding names do not overwrite each other" "$(cd "$tmp/c" && echo *.svg)" "a_b.svg other_a_b.svg render_web.svg web.svg"
contains "badge: ids are per badge" "$(cat "$tmp/c/web.svg")" 'clip-path="url(#r-web)"'
expect "badge: the width counts characters, not bytes" "$(echo '[{"name":"x","changed":false,"lastAt":1}]' | LC_ALL=C badge/badge.sh "$tmp/w" - >/dev/null; sed -n 's/^<svg[^>]* width="\([0-9]*\)".*/\1/p' "$tmp/w/x.svg")" \
  "$(echo '[{"name":"x","changed":false,"lastAt":1}]' | badge/badge.sh "$tmp/w2" - >/dev/null; sed -n 's/^<svg[^>]* width="\([0-9]*\)".*/\1/p' "$tmp/w2/x.svg")"
if command -v xmllint >/dev/null; then
  xmllint --noout "$tmp"/b/*.svg "$tmp"/e/*.svg && ok "badges are well-formed XML" || fail "badges are well-formed XML" xmllint
fi

# --- notify ---
out="$(RENDER_API_KEY=x notify/notify.sh --dry-run)"
contains "notify: live today" "$out" 'Live today (1): site'
contains "notify: waiting with counts" "$out" 'Waiting (2): app-web (4 commits), api'
contains "notify: Slack-style by default" "$out" 'format: slack'
contains "notify: failed builds are named" "$out" 'Failed (1): api'
contains "notify: the day in UTC by default" "$out" "$(date -u +%Y-%m-%d) (UTC)"
contains "notify: DEPLOYS_NOTIFY_TZ names its day" "$(RENDER_API_KEY=x DEPLOYS_NOTIFY_TZ=Pacific/Kiritimati notify/notify.sh --dry-run)" "$(TZ=Pacific/Kiritimati date +%Y-%m-%d) (Pacific/Kiritimati)"
expect "notify: Discord never pings" "$(DEPLOYS_NOTIFY_URL=https://discord.com/api/webhooks/1/x notify/notify.sh --dry-run | sed -n 2p | jq -c .allowed_mentions)" '{"parse":[]}'
expect "notify: Discord by host" "$(DEPLOYS_NOTIFY_URL=https://discord.com/api/webhooks/1/x notify/notify.sh --dry-run | sed -n 2p | jq -r 'has("content")')" true
expect "notify: Telegram by host" "$(DEPLOYS_NOTIFY_URL='https://api.telegram.org/botT/sendMessage?chat_id=1' notify/notify.sh --dry-run | head -1)" "format: telegram"
contains "notify: ntfy is plain text" "$(DEPLOYS_NOTIFY_URL=https://ntfy.sh/topic notify/notify.sh --dry-run)" $'format: ntfy\nDeploy Center'
. lib/post.sh
webhook_body discord "$(printf 'x%.0s' $(seq 1 2500))"
expect "post: a long Discord message is cut below 2000" "$(jq -r '.content | length < 2000 and test("cut")' <<<"$WEBHOOK_BODY")" true
expect "notify: plain http is refused" "$(RENDER_API_KEY=x DEPLOYS_NOTIFY_URL=http://hooks.example.test/x notify/notify.sh 2>&1; echo "rc=$?")" $'DEPLOYS_NOTIFY_URL must start with https://\nrc=1'
DEPLOYS_NOTIFY_URL='https://hooks.example.test/T/secret' notify/notify.sh >/dev/null
expect "notify: the URL goes to curl on stdin" "$(cat "$tmp/curl.stdin")" 'url = "https://hooks.example.test/T/secret"'
case "$(cat "$tmp/curl.args")" in *secret*) fail "notify: URL not in curl's arguments" "found" ;; *) ok "notify: URL not in curl's arguments" ;; esac
expect "notify: posts the summary" "$(jq -r '.text' "$tmp/curl.body" | sed -n 2p)" 'Live today (1): site'
DEPLOYS_NOTIFY_URL='ftp://x' notify/notify.sh >/dev/null 2>&1; expect "notify: refuses a non-http URL" "$?" 1
# More formats: Teams, Google Chat, Matrix hookshot, Pushover; ntfy priority, tags and a token.
expect "notify: Teams by host, an Adaptive Card" "$(DEPLOYS_NOTIFY_URL='https://x.webhook.office.com/webhookb2/1' notify/notify.sh --dry-run | sed -n 2p | jq -r '.attachments[0].content.type + " " + (.attachments[0].content.body[0].text | split("\n")[1])')" "AdaptiveCard Live today (1): site"
webhook_body teams "hi" "https://example.test/x" "Approve"; expect "post: Teams link is a button" "$(jq -r '.attachments[0].content.actions[0] | .type + " " + .url' <<<"$WEBHOOK_BODY")" "Action.OpenUrl https://example.test/x"
expect "notify: Google Chat by host" "$(DEPLOYS_NOTIFY_URL='https://chat.googleapis.com/v1/spaces/A/messages?key=k' notify/notify.sh --dry-run | head -1)" "format: googlechat"
webhook_body googlechat "hi" "https://example.test/x" "Approve"; expect "post: Google Chat link" "$(jq -r .text <<<"$WEBHOOK_BODY")" $'hi\n<https://example.test/x|Approve>'
webhook_body matrix "hi"; expect "post: Matrix hookshot text" "$(jq -c . <<<"$WEBHOOK_BODY")" '{"text":"hi","username":"Deploy Center"}'
expect "post: Pushover needs its keys" "$(webhook_body pushover hi 2>&1; echo "rc=$?")" $'Pushover needs DEPLOYS_PUSHOVER_TOKEN and DEPLOYS_PUSHOVER_USER\nrc=1'
DEPLOYS_PUSHOVER_TOKEN=apptok DEPLOYS_PUSHOVER_USER=usr webhook_body pushover "hi" "https://example.test/x" "Open"
expect "post: Pushover message" "$(jq -c '{user, title, message, url}' <<<"$WEBHOOK_BODY")" '{"user":"usr","title":"Deploy Center","message":"hi","url":"https://example.test/x"}'
expect "notify: Pushover by host" "$(DEPLOYS_PUSHOVER_TOKEN=a DEPLOYS_PUSHOVER_USER=b DEPLOYS_NOTIFY_URL=https://api.pushover.net/1/messages.json notify/notify.sh --dry-run | head -1)" "format: pushover"
DEPLOYS_NOTIFY_PRIORITY=high DEPLOYS_NOTIFY_TAGS=rocket,warning DEPLOYS_NOTIFY_TOKEN=tk_secret123 DEPLOYS_NOTIFY_URL='https://ntfy.sh/topic' notify/notify.sh >/dev/null
contains "notify: ntfy priority and tags" "$(cat "$tmp/curl.args")" $'Priority: high\n-H\nTags: rocket,warning'
expect "notify: the ntfy token goes on stdin, not in the arguments" "$(sed -n 2p "$tmp/curl.stdin"):$(grep -c tk_secret123 "$tmp/curl.args")" 'header = "Authorization: Bearer tk_secret123":0'
DEPLOYS_NOTIFY_PRIORITY=loud DEPLOYS_NOTIFY_URL='https://ntfy.sh/topic' notify/notify.sh >/dev/null 2>&1; expect "notify: an unknown ntfy priority is refused" "$?" 1
DEPLOYS_NOTIFY_TOKEN='a"b' DEPLOYS_NOTIFY_URL='https://ntfy.sh/topic' notify/notify.sh >/dev/null 2>&1; expect "notify: a token with quotes is refused" "$?" 1

# --- examples/bot-only.sh: dependency-only projects held back, or kept alone ---
expect "bot-only: a human commit anywhere is not bot-only" "$(../examples/bot-only.sh)" '{"botOnly":[],"other":["app-web","api"],"unknown":[]}'
cp "$tmp/details-api.json" "$tmp/details-api.keep"
echo '{"commits":[{"sha":"c5","msg":"Bump lodash","author":"dependabot[bot]","bot":true,"pr":null},{"sha":"c7","msg":"Bump jq","author":"renovate[bot]","bot":true,"pr":3}]}' > "$tmp/details-api.json"
expect "bot-only: only bot commits" "$(../examples/bot-only.sh | jq -c .botOnly)" '["api"]'
mkdir -p "$tmp/bo"; echo '["old"]' > "$tmp/bo/ignored.json"
DEPLOYS_CONFIG="$tmp/bo" ../examples/bot-only.sh --hold >/dev/null
expect "bot-only --hold: the bot-only ones join ignored.json" "$(jq -c . "$tmp/bo/ignored.json")" '["api","old"]'
echo '[]' > "$tmp/bo/ignored.json"; DEPLOYS_CONFIG="$tmp/bo" ../examples/bot-only.sh --only >/dev/null
expect "bot-only --only: every other project is left out" "$(jq -c . "$tmp/bo/ignored.json")" '["app-web"]'
mv "$tmp/details-api.keep" "$tmp/details-api.json"
expect "bot-only: an unknown option is refused" "$(../examples/bot-only.sh --all >/dev/null 2>&1; echo $?)" 1

# --- examples/telegram-waiting-bot.sh: only listed chats, read-only answers ---
tg() { DEPLOYS_BOT_CHATS="${CHATS-42, -100}" ../examples/telegram-waiting-bot.sh --reply "$(jq -nc --argjson c "$1" --arg t "$2" '{update_id:1, message:{chat:{id:$c}, text:$t}}')"; }
expect "telegram bot: /waiting lists what waits" "$(tg 42 /waiting)" $'Waiting to go live (2):\n• app-web (vercel): 4 commit(s)\n• api (render): changes'
expect "telegram bot: /waiting@bot works in groups" "$(tg -100 /waiting@deploys_bot | head -1)" "Waiting to go live (2):"
expect "telegram bot: a chat not listed gets nothing" "$(tg 7 /waiting)" ""
expect "telegram bot: no list, no answers" "$(CHATS='' tg 42 /waiting)" ""
expect "telegram bot: other text is ignored" "$(tg 42 'deploy app-web')" ""
expect "telegram bot: /failed" "$(tg 42 /failed)" "No newest build failed."

# --- Alfred script filter ---
af="$(alfred/deploys-filter.sh)"
expect "alfred: every project, as Alfred items" "$(jq -r '.items | length' <<<"$af")" 3
expect "alfred: ↵ shows it in Deploy Center, ⌘ opens the site" "$(jq -r '.items[] | select(.title == "app-web") | .arg + " " + .mods.cmd.arg' <<<"$af")" "deploycenter://select?project=app-web open app-web"
expect "alfred: waiting before up to date" "$(jq -c '[.items[].title]' <<<"$af")" '["api","app-web","site"]'
expect "alfred: the query filters by name" "$(alfred/deploys-filter.sh WEB | jq -c '[.items[].title]')" '["app-web"]'
expect "alfred: no match is one item" "$(alfred/deploys-filter.sh zzz | jq -r '.items[0].title')" "No project matches"
expect "alfred: a CLI that gives no list says so" "$(DEPLOYS=/usr/bin/false alfred/deploys-filter.sh | jq -r '.items[0].title')" "Could not read the projects"
expect "alfred open: only a project name" "$(alfred/deploys-open.sh 'open a;b' 2>&1; echo "rc=$?")" $'Not a project: open a;b\nrc=1'

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
out="$(FAKE_SLEEP=30.017 DEPLOYS_PREPUSH_TIMEOUT=1 push "refs/heads/main $s1 refs/heads/main $z" git@github.com:me/site.git)"
contains "pre-push: a CLI that does not answer lets the push go" "$out" $'push not checked.\nexit=0'
[ $(( $(date +%s) - start )) -lt 6 ] && ok "pre-push: gives up after the timeout" || fail "pre-push: gives up after the timeout" "took too long"
pgrep -f "sleep 30.017" >/dev/null && fail "pre-push: the stuck CLI is stopped" "still running" || ok "pre-push: the stuck CLI is stopped"
start=$(date +%s)
out="$(FAKE_DOCTOR_SLEEP=30.029 DEPLOYS_PREPUSH_TIMEOUT=1 push "refs/heads/main $s1 refs/heads/main $z" git@github.com:me/site.git)"
contains "pre-push: a doctor that hangs lets the push go" "$out" "exit=0"
[ $(( $(date +%s) - start )) -lt 6 ] && ok "pre-push: a hanging doctor is bounded by the timeout" || fail "pre-push: a hanging doctor is bounded by the timeout" "took too long"
pgrep -f "sleep 30.029" >/dev/null && fail "pre-push: the hanging doctor is stopped" "still running" || ok "pre-push: the hanging doctor is stopped"
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
case "$st$page$feed" in *SECRET*|*/Users/*|*"nothing to do"*|*abc1234*|*aaaa111*|*bbbb222*|*me/app*) fail "statuspage: no journal detail, SHA or repo" "found" ;; *) ok "statuspage: no journal detail, SHA or repo" ;; esac
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
echo '{"title":"x","projects":["app-web"],"baseUrl":"javascript:alert(1)"}' > "$tmp/sp-bad.json"
sp --config "$tmp/sp-bad.json" --out "$tmp/spb" --no-check >/dev/null 2>&1; expect "statuspage: a baseUrl that is not http(s) is refused" "$?" 1
echo '{"title":"x"}' > "$tmp/sp-empty.json"
sp --config "$tmp/sp-empty.json" --out "$tmp/spe" >/dev/null 2>&1; expect "statuspage: no allowlist, no page" "$?" 1
[ -e "$tmp/spe" ] && fail "statuspage: nothing written without an allowlist" "written" || ok "statuspage: nothing written without an allowlist"
SP_CURL_LOG=/dev/null DEPLOYS_JOURNAL=/nonexistent RENDER_API_KEY=x statuspage/statuspage.sh --config "$tmp/sp-auth.json" --out "$tmp/spn" --no-check >/dev/null
expect "statuspage: no journal, empty timeline" "$(jq '.timeline | length' "$tmp/spn/status.json")" 0
# lang: the page, the feed and status.json in German; the stale warning is in the page, hidden until old.
jq '. + {lang: "de", hideMessages: true, staleHours: 24}' "$tmp/sp.json" > "$tmp/sp-de.json"
sp --config "$tmp/sp-de.json" --out "$tmp/spd" --no-check >/dev/null; expect "statuspage de: runs" "$?" 0
de_all="$(cat "$tmp/spd/index.html")"
case "$de_all" in *'<html lang="de">'*'Letzter Deploy'*'Letzte Deploys'*'Erstellt mit Deploy Center'*) ok "statuspage de: German page" ;; *) fail "statuspage de: German page" "English left" ;; esac
case "$de_all" in *'Last deploy'*|*'Recent deploys'*|*'Made with'*) fail "statuspage de: no English text left" "found" ;; *) ok "statuspage de: no English text left" ;; esac
expect "statuspage de: Updated is Aktualisiert in status.json" "$(jq -r '.projects[0].message' "$tmp/spd/status.json")" "Aktualisiert"
grep -q 'ging live\|Deploy fehlgeschlagen' "$tmp/spd/feed.xml" && ok "statuspage de: feed titles in German" || fail "statuspage de: feed titles in German" "English"
expect "statuspage: the stale warning waits hidden, with its limit" "$(grep -o '<p class="stale" role="alert" hidden data-generated="[0-9]*" data-hours="24"' "$tmp/spd/index.html" | wc -l | tr -d ' ')" 1
expect "statuspage: English page has the stale warning at 48 h" "$(grep -c 'data-hours="48"' "$tmp/sp/index.html")" 1
# The page script, run against a stand-in DOM: a page 3 days old says so; a fresh one stays quiet.
if command -v node >/dev/null; then
  grep -o '<script>.*</script>' "$tmp/spd/index.html" | sed -e 's/^<script>//' -e 's/<\/script>$//' > "$tmp/page.js"
  stale_js() { node -e '
    const code = require("fs").readFileSync(process.argv[1], "utf8");
    const st = { dataset: { generated: String(Date.now() / 1000 - Number(process.argv[2])), hours: "24", text: "{n} h", textDays: "{n} d" }, hidden: true, textContent: "" };
    global.document = { querySelectorAll: () => [], querySelector: (q) => (q === ".stale" ? st : { textContent: "" }) };
    eval(code); console.log(st.hidden ? "hidden" : st.textContent);' "$tmp/page.js" "$1"; }
  expect "statuspage: a page 3 days old warns" "$(stale_js 259200)" "3 d"
  expect "statuspage: a page 30 hours old warns in hours (limit 24)" "$(stale_js 108000)" "30 h"
  expect "statuspage: a fresh page does not warn" "$(stale_js 600)" "hidden"
else echo "skip statuspage page script: needs node"; fi
jq '. + {lang: "fr"}' "$tmp/sp.json" > "$tmp/sp-fr.json"
sp --config "$tmp/sp-fr.json" --out "$tmp/spf" --no-check >/dev/null 2>&1; expect "statuspage: an unknown lang is refused" "$?" 1

# --- one Vercel CLI version everywhere (the action's default is the source) ---
pin="$(sed -n '/vercel-cli-version:/,/default:/s/^ *default: "\([0-9.]*\)"/\1/p' action/action.yml)"
for f in docker/Dockerfile statuspage/examples/statuspage-daily.yml ../examples/daily-deploy.yml ../examples/dependency-updates-weekly.yml; do
  others="$(grep -oE '(vercel@|VERCEL_CLI_VERSION[=:] *"?)[0-9]+\.[0-9]+\.[0-9]+' "$f" | grep -oE '[0-9]+\.[0-9]+\.[0-9]+' | sort -u | tr '\n' ' ')"
  expect "vercel CLI pin in $f is the action's ($pin)" "$others" "$pin "
done
# --- one name for the team variable in the examples ---
grep -rn 'vars\.VERCEL_TEAM\b' action/examples digest/examples statuspage/examples ../examples >/dev/null && fail "examples use vars.DEPLOYS_VERCEL_TEAM" "vars.VERCEL_TEAM found" || ok "examples use vars.DEPLOYS_VERCEL_TEAM"

# --- the Action's steps, run as GitHub would (needs ruby for the YAML) ---
if command -v ruby >/dev/null; then
  step() { ruby -ryaml -e 'puts YAML.load_file(ARGV[0])["runs"]["steps"].find { |s| s["id"] == ARGV[1] }[ARGV[2]]' action/action.yml "$1" "${2:-run}"; }
  step changed > "$tmp/changed.sh"; step deploy > "$tmp/deploy.sh"; step setup > "$tmp/setup.sh"; step plan > "$tmp/plan.sh"; step wait > "$tmp/wait.sh"
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
  FAKE_NO_SUMMARY=1 run_step deploy.sh; expect "action: no summary line, the step still ends with outputs" "$?:$(tr '\n' ' ' < "$tmp/out")" "0:started=0 failed=0 deployed=true "
  expect "action: deploy step only with deploy: true" "$(step deploy if)" "inputs.deploy == 'true' && steps.changed.outputs.count != '0'"
  ONLY=api run_step changed.sh; expect "action: only keeps the named projects" "$(grep '^names=' "$tmp/out")" "names=api"
  expect "action: only writes the others to this run's ignored.json" "$(jq -c . "$DEPLOYS_CONFIG/ignored.json")" '["app-web"]'
  EXCLUDE='api, x' run_step changed.sh; expect "action: exclude leaves projects out" "$(grep '^count=' "$tmp/out"):$(jq -c . "$DEPLOYS_CONFIG/ignored.json")" 'count=1:["api"]'
  ONLY='a;b' run_step changed.sh; expect "action: only refuses what is not a name" "$?" 1
  rm -f "$DEPLOYS_CONFIG/ignored.json"
  run_step plan.sh; expect "action: dry-run shows the plan, starts nothing" "$?:$(grep -c 'Would deploy: app-web' "$tmp/sum")" "0:1"
  expect "action: plan step only with deploy: dry-run" "$(step plan if)" "inputs.deploy == 'dry-run' && steps.changed.outputs.count != '0'"
  # wait: the JSON answer gives the ids; each build is followed to live or failed, under one deadline.
  mkdir -p "$tmp/rt"; : > "$tmp/deploy.log"
  DEPLOYS_WAIT_S=60 RUNNER_TEMP="$tmp/rt" run_step deploy.sh
  expect "action wait: deploy asks for JSON" "$?:$(cat "$tmp/deploy.log")" "0:deploy-changed --yes --json"
  expect "action wait: outputs from the JSON answer" "$(tr '\n' ' ' < "$tmp/out")" "started=2 failed=0 deployed=true "
  expect "action wait: the started ids are kept for the wait step" "$(jq -c 'map(.id)' "$tmp/rt/deploys-started.json")" '["dpl_1","dep-1"]'
  DEPLOYS_WAIT_S=60 RUNNER_TEMP="$tmp/rt" run_step wait.sh
  expect "action wait: both live" "$?:$(tr '\n' ' ' < "$tmp/out")" '0:states={"app-web":"ready","api":"ready"} failed-builds= live=true '
  FAKE_WATCH_API=1 DEPLOYS_WAIT_S=60 RUNNER_TEMP="$tmp/rt" run_step wait.sh
  expect "action wait: a failed build fails the step and is named" "$?:$(grep '^failed-builds=' "$tmp/out")" "1:failed-builds=api"
  FAKE_WATCH_API=3 DEPLOYS_WAIT_S=60 RUNNER_TEMP="$tmp/rt" run_step wait.sh
  expect "action wait: a platform that cannot be asked is unknown, not failed" "$?:$(grep -c '"api":"unknown"' "$tmp/out")" "0:1"
  t0=$SECONDS; FAKE_WATCH_SLOW=1 DEPLOYS_WAIT_S=1 RUNNER_TEMP="$tmp/rt" run_step wait.sh; rc=$?
  expect "action wait: the deadline stops a slow watch" "$rc:$(grep '^live=' "$tmp/out"):$(grep -c '"app-web":"timeout"' "$tmp/out"):$(( SECONDS - t0 < 4 ))" "0:live=false:1:1"
  expect "action wait: only after deploy: true with a wait" "$(step wait if)" "\${{ !cancelled() && inputs.deploy == 'true' && inputs.wait != '' && inputs.wait != '0' && steps.deploy.outputs.started != '' && steps.deploy.outputs.started != '0' }}"
  # fail-on-risk: the risk of what waits, and a gate before anything starts.
  FAKE_LEVEL=red run_step changed.sh
  expect "action risk: highest risk and who has it" "$(grep -E '^risk(y)?=' "$tmp/out" | tr '\n' ' ')" "risk=red risky=app-web "
  expect "action risk: in the summary" "$(grep -c 'app-web\*\*: 4 commit(s) waiting, risk red: touches a migration' "$tmp/sum")" 1
  FAKE_LEVEL=red FAIL_ON_RISK=red run_step changed.sh; expect "action risk: red fails fail-on-risk: red" "$?" 1
  FAKE_LEVEL=yellow FAIL_ON_RISK=red run_step changed.sh; expect "action risk: yellow passes fail-on-risk: red" "$?" 0
  FAKE_LEVEL=yellow FAIL_ON_RISK=yellow run_step changed.sh; expect "action risk: yellow fails fail-on-risk: yellow" "$?" 1
  FAIL_ON_RISK=red run_step changed.sh; expect "action risk: no risk known passes" "$?:$(grep '^risk=' "$tmp/out")" "0:risk="
  FAIL_ON_RISK=orange run_step changed.sh; expect "action risk: an unknown level is refused" "$?" 1
  setup() { : > "$tmp/out"; : > "$tmp/genv"; env GITHUB_ENV="$tmp/genv" GITHUB_PATH="$tmp/gpath" RUNNER_TEMP="$tmp/rt" ACTION_PATH="$here/action" \
      VERCEL_TOKEN="${VT:-}" VERCEL_TEAM="${TEAM:-}" REPOS_JSON="${RJ:-}" CLI_VERSION="${CV:-65.12.1}" WAIT="${WT:-}" PATH="$PATH" bash "$tmp/setup.sh" >/dev/null 2>&1; echo $?; }
  mkdir -p "$tmp/rt"
  expect "action setup: wait 20m is 1200 s" "$(WT=20m setup):$(grep DEPLOYS_WAIT_S "$tmp/genv")" "0:DEPLOYS_WAIT_S=1200"
  expect "action setup: a plain wait is minutes" "$(WT=5 setup):$(grep DEPLOYS_WAIT_S "$tmp/genv")" "0:DEPLOYS_WAIT_S=300"
  expect "action setup: wait 0 does not wait" "$(WT=0 setup):$(grep -c DEPLOYS_WAIT_S "$tmp/genv")" "0:0"
  expect "action setup: a wait that is not a time fails" "$(WT='5m; ls' setup)" 1
  expect "action setup: a wait over 6h fails" "$(WT=7h setup)" 1
  expect "action setup: a team id passes" "$(TEAM=team_abc-1 setup)" 0
  expect "action setup: a team id with odd characters fails" "$(TEAM='x;y' setup)" 1
  expect "action setup: repos-json must be an object" "$(RJ='[1]' setup)" 1
  expect "action setup: repos-json that is not JSON fails" "$(RJ='{nope' setup)" 1
  if ! command -v vercel >/dev/null; then
    expect "action setup: a vercel-cli-version that is not a version fails" "$(VT=x CV='1.0; rm -rf /' setup)" 1
  fi
  case "$(cat "$tmp/changed.sh" "$tmp/deploy.sh" "$tmp/setup.sh" "$tmp/plan.sh" "$tmp/wait.sh")" in *'${{'*) fail "action: no inputs inside run scripts" "found" ;; *) ok "action: no inputs inside run scripts" ;; esac
else
  echo "skip action: needs ruby"
fi

# --- Raycast copies the log rules of VS Code (no shared package): the two must not drift ---
# Prettier wraps the Raycast copy differently: compared without whitespace and trailing commas.
rules() { sed -n '/^const errorPattern/,$p' "$1" | grep -v 'eslint-disable' | tr -d ' \n' | sed -e 's/,\]/]/g' -e 's/,)/)/g'; }
[ "$(rules vscode/src/log.ts)" = "$(rules raycast/src/lib/log.ts)" ] && ok "raycast log.ts has the same error and masking rules as vscode" || fail "raycast log.ts has the same error and masking rules as vscode" "they differ"

# --- VS Code extension: its own unit tests (node), when its dev dependencies are installed ---
if command -v npm >/dev/null && [ -d vscode/node_modules ]; then
  (cd vscode && npm test --silent >"$tmp/vscode.log" 2>&1) && ok "vscode: unit tests" || { fail "vscode: unit tests" "see below"; cat "$tmp/vscode.log"; }
else
  echo "skip vscode: run npm ci in integrations/vscode first"
fi


# --- Claude Code plugin: manifest checks, shellcheck, and the after-push hook ---
if integrations_cc="$(tests/claude-code.sh --quiet 2>&1)"; then ok "claude-code: plugin and marketplace files are valid"
else fail "claude-code: plugin and marketplace files are valid" "$(grep FAIL <<<"$integrations_cc" | head -5)"; fi
hook="$here/claude-code/scripts/after-push.sh"
if command -v shellcheck >/dev/null; then
  shellcheck --severity=style "$hook" && ok "claude-code: shellcheck after-push.sh" || fail "claude-code: shellcheck after-push.sh" "see above"
  shellcheck --severity=warning tests/claude-code.sh && ok "claude-code: shellcheck claude-code.sh" || fail "claude-code: shellcheck claude-code.sh" "see above"
fi
git init -q -b main "$tmp/cc" && git -C "$tmp/cc" remote add origin git@github.com:me/app.git
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
expect "claude-code hook: git push inside an echo is no push" "$(hk 'echo git push')" "exit=0"
expect "claude-code hook: a commit message about git push is no push" "$(hk 'git commit -m fix-git-push-docs')" "exit=0"
contains "claude-code hook: cd dir && git push" "$(hk "cd $tmp/cc && git push" "$tmp/cc-other" | head -1)" "app-web"
contains "claude-code hook: git -C dir push" "$(hk "git -C $tmp/cc push" "$tmp/cc-other" | head -1)" "app-web"
contains "claude-code hook: HEAD:main counts" "$(hk "git push origin HEAD:main" | head -1)" "app-web"
expect "claude-code hook: a feature branch is not what the projects deploy" "$(hk "git push -u origin feature/x")" "exit=0"
expect "claude-code hook: silent without deploys" "$(DEPLOYS=/nonexistent hk "git push")" "exit=0"
if [ ! -e "/Applications/Deploy Center.app" ] && [ ! -e "$HOME/Applications/Deploy Center.app" ]; then
  nodeploys="$tmp/nodeploys"; mkdir -p "$nodeploys"
  for t in jq git sed mktemp rm cat sleep pgrep kill dirname; do p="$(command -v "$t")" && ln -sf "$p" "$nodeploys/$t"; done
  expect "claude-code hook: silent with no deploys on PATH" "$(env -u DEPLOYS PATH="$nodeploys" HOME="$tmp" "$BASH" -c "$(declare -f hk); tmp='$tmp' hook='$hook'; hk 'git push'")" "exit=0"
fi
expect "claude-code hook: off with the plugin option" "$(CLAUDE_PLUGIN_OPTION_PUSH_REMINDER=false hk "git push")" "exit=0"
expect "claude-code hook: off with DEPLOYS_PUSH_REMINDER=off" "$(DEPLOYS_PUSH_REMINDER=off hk "git push")" "exit=0"
# --session-start: opt-in, the folder's repo, every branch, its own event name.
ss() { jq -nc --arg d "${1:-$tmp/cc}" '{hook_event_name:"SessionStart",source:"startup",cwd:$d}' | "$hook" --session-start; echo "exit=$?"; }
expect "claude-code session hint: off by default" "$(ss)" "exit=0"
out="$(CLAUDE_PLUGIN_OPTION_SESSION_HINT=true ss)"
expect "claude-code session hint: the folder's repo" "$(head -1 <<<"$out" | jq -r .systemMessage)" "Deploy Center: 4 commits waiting on app-web, changes waiting on api: deploy when ready (deploys changed)"
expect "claude-code session hint: event name" "$(head -1 <<<"$out" | jq -r .hookSpecificOutput.hookEventName)" SessionStart
expect "claude-code session hint: quiet for another repo" "$(CLAUDE_PLUGIN_OPTION_SESSION_HINT=true ss "$tmp/cc-other")" "exit=0"
expect "claude-code session hint: DEPLOYS_SESSION_HINT=off wins" "$(DEPLOYS_SESSION_HINT=off CLAUDE_PLUGIN_OPTION_SESSION_HINT=true ss)" "exit=0"
expect "claude-code hook: silent on bad input" "$(echo 'not json' | "$hook"; echo "exit=$?")" "exit=0"
start=$(date +%s)
cat > "$tmp/bin/slow-deploys" <<SH
#!/bin/bash
sleep 30.023
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
deploy_calls_before="$(cat "$tmp/deploy.log" 2>/dev/null | wc -l)"
hk "git push" >/dev/null
expect "claude-code hook: never deploys" "$(cat "$tmp/deploy.log" 2>/dev/null | wc -l)" "$deploy_calls_before"
# --- the MCP server (needs node and `npm ci` in mcp/) ---
if command -v node >/dev/null && [ -d mcp/node_modules/@modelcontextprotocol/sdk ]; then
  DEPLOYS_BIN="$tmp/bin/deploys" MCP_CALLS="$tmp/mcp-calls.log" node tests/mcp.test.mjs || fails=$((fails+1))
  pgrep -f "sleep 20.019" >/dev/null && fail "mcp: a timed-out CLI is stopped with its children" "still running" || ok "mcp: a timed-out CLI is stopped with its children"
else
  echo "skip mcp: needs node and (cd integrations/mcp && npm ci)"
fi

# --- digest: classify (pure) ---
# shellcheck source=digest/classify.sh
. digest/classify.sh
kinds() { classify | jq -c 'map(.why)'; }
expect "classify: an agent branch prefix of the pull request" "$(echo '[{"sha":"a","author":"dev","prBranch":"Claude/fix-x"},{"sha":"b","author":"dev","prBranch":"feature/claude/x"}]' | kinds)" '["branch Claude/fix-x","no agent sign"]'
expect "classify: DEPLOYS_AGENT_BRANCHES replaces the prefixes" "$(echo '[{"sha":"a","author":"dev","prBranch":"claude/x"},{"sha":"b","author":"dev","prBranch":"bot/y"}]' | DEPLOYS_AGENT_BRANCHES='bot/' kinds)" '["no agent sign","branch bot/y"]'
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
expect "digest: --json with --issue is refused" "$(digest/digest.sh --json --issue >/dev/null 2>&1; echo $?)" 1
cp "$tmp/pr14.json" "$tmp/pr14.bak"
echo '{"number":14,"title":"Thanks @everyone ![x](https://img.example.test/p.png)","html_url":"u","user":{"login":"dev-two","type":"User"},"labels":[]}' > "$tmp/pr14.json"
md="$(RENDER_API_KEY=x digest/digest.sh)"
case "$md" in *"@everyone"*|*"![x]"*) fail "digest: mentions and images in PR titles are defused" "$(grep -F '#14' <<<"$md")" ;; *"#14 Thanks @"*) ok "digest: mentions and images in PR titles are defused" ;; *) fail "digest: mentions and images in PR titles are defused" "PR 14 missing" ;; esac
mv "$tmp/pr14.bak" "$tmp/pr14.json"
out="$(FAKE_RC=1 RENDER_API_KEY=x digest/digest.sh --post --dry-run)"
contains "digest post: an incomplete list says so" "$(sed 1d <<<"$out" | jq -r .text)" "List incomplete"

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
# A body over GitHub's limit is cut; the approval part stays. gh failing stops the run, no post.
out="$(RENDER_API_KEY=x DEPLOYS_DIGEST_REPO=me/ops DEPLOYS_DIGEST_MAX_BODY=200 digest/digest.sh --issue --dry-run)"
contains "digest issue: a long body is cut with a note" "$out" "(cut: the list is longer than an issue can hold"
contains "digest issue: the approve marker survives the cut" "$out" '<!-- deploys-approve: app-web,api -->'
expect "digest issue: the cut body stays under the limit" "$(printf '%s' "$out" | sed -n '/^## Approve/q;p' | sed 1d | wc -c | awk '{print ($1 < 400)}')" 1
: > "$tmp/curl.body"
FAKE_GH_FAIL=1 RENDER_API_KEY=x DEPLOYS_DIGEST_REPO=me/ops DEPLOYS_NOTIFY_URL=https://hooks.example.test/x digest/digest.sh --issue --post >/dev/null 2>"$tmp/err"
expect "digest issue: gh failing fails the run, and nothing is posted" "$?:$(wc -c < "$tmp/curl.body" | tr -d ' ')" "1:0"
contains "digest issue: gh's own error is shown" "$(cat "$tmp/err")" "Bad credentials"
FAKE_GH_CREATE_FAIL=1 RENDER_API_KEY=x DEPLOYS_DIGEST_REPO=me/ops digest/digest.sh --issue >/dev/null 2>&1
expect "digest issue: an issue that cannot be opened fails the run" "$?" 1

# --- approve-deploy.yml: its steps, run as GitHub would (needs ruby for the YAML) ---
if command -v ruby >/dev/null; then
  wstep() { ruby -ryaml -e 'puts YAML.load_file(ARGV[0])["jobs"]["deploy"]["steps"].find { |s| s["id"] == ARGV[1] }[ARGV[2]]' digest/examples/approve-deploy.yml "$1" "${2:-run}"; }
  wstep approved > "$tmp/approved.sh"; wstep keep > "$tmp/keep.sh"; wstep report > "$tmp/report.sh"
  approve() { : > "$tmp/out"; env GITHUB_OUTPUT="$tmp/out" EVENT="${EVENT:-workflow_dispatch}" ACTOR="${ACTOR:-dev-one}" SENDER_TYPE="${SENDER_TYPE:-User}" \
      APPROVERS="${APPROVERS-dev-one, Dev-Two}" INPUT="${INPUT:-}" BODY="${BODY:-}" TITLE="${TITLE-Deploys waiting – $(date -u +%Y-%m-%d)}" bash "$tmp/approved.sh" >/dev/null 2>&1; echo "$?:$(grep '^projects=' "$tmp/out")"; }
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
  expect "approve: an older day's issue is refused" "$(EVENT=issues TITLE='Deploys waiting – 2000-01-01' BODY=$'<!-- deploys-approve: app-web -->' approve)" "1:"
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
  report() { : > "$tmp/gh.log"; env EVENT="${EVENT:-issues}" GITHUB_STEP_SUMMARY="$tmp/rsum" REPO=me/ops ISSUE=5 RUN_URL=https://example.test/run REASON="${REASON:-}" NAMES="${NAMES:-}" STARTED="${STARTED-}" FAILED="${FAILED:-}" DEPLOYED="${DEPLOYED:-}" bash "$tmp/report.sh" >/dev/null 2>&1; cat "$tmp/gh.log"; }
  out="$(NAMES=app-web STARTED=1 FAILED=0 DEPLOYED=true report)"
  contains "report: started, on the issue" "$out" "issue comment 5 -R me/ops --body Started 1 deploy(s) (app-web), 0 failed to start."
  contains "report: label off" "$out" "issue edit 5 -R me/ops --remove-label deploy-approved"
  contains "report: closed when deployed" "$out" "issue close 5"
  out="$(REASON='dev-three is not in DEPLOYS_APPROVERS.' report)"
  contains "report: a refusal is said" "$out" "Not deployed: dev-three is not in DEPLOYS_APPROVERS."
  case "$out" in *"issue close"*) fail "report: open after a refusal" "closed" ;; *) ok "report: open after a refusal" ;; esac
  : > "$tmp/rsum"; out="$(EVENT=workflow_dispatch NAMES=api STARTED=1 FAILED=0 DEPLOYED=true report)"
  expect "report: by hand, nothing goes to an issue" "$out" ""
  contains "report: by hand, the result is on the run's page" "$(cat "$tmp/rsum")" "Started 1 deploy(s) (api), 0 failed to start."
  expect "approve-deploy: the first action run only sets up" "$(ruby -ryaml -e 'puts YAML.load_file(ARGV[0])["jobs"]["deploy"]["steps"].find { |s| s["id"] == "list" }["with"]["deploy"]' digest/examples/approve-deploy.yml)" "setup"
  if command -v ruby >/dev/null; then
    expect "action: deploy: setup asks nothing" "$(ruby -ryaml -e 'puts YAML.load_file(ARGV[0])["runs"]["steps"].find { |s| s["id"] == "changed" }["if"]' action/action.yml)" "inputs.deploy != 'setup'"
  fi
  expect "approve-deploy: runs only on the deploy-approved label of a digest issue, or by hand" "$(ruby -ryaml -e 'puts YAML.load_file(ARGV[0])["jobs"]["deploy"]["if"]' digest/examples/approve-deploy.yml | tr -s ' \n' ' ' | sed 's/ $//')" \
    "github.event_name == 'workflow_dispatch' || (github.event.label.name == 'deploy-approved' && startsWith(github.event.issue.title, 'Deploys waiting – '))"
  expect "approve-deploy: deploy: true only after the approval steps" "$(ruby -ryaml -e 's = YAML.load_file(ARGV[0])["jobs"]["deploy"]["steps"]; puts s.each_with_index.select { |x, _| (x["with"] || {})["deploy"] == true }.map { |_, i| s[0...i].map { |y| y["id"] }.join(",") }' digest/examples/approve-deploy.yml)" "approved,body,list,keep"
  case "$(cat "$tmp/approved.sh" "$tmp/keep.sh" "$tmp/report.sh")" in *'${{'*) fail "approve-deploy: no expressions inside run scripts" "found" ;; *) ok "approve-deploy: no expressions inside run scripts" ;; esac
  ruby -ryaml -e 'YAML.load_file(ARGV[0])' digest/examples/daily-digest.yml && ok "daily-digest.yml is valid YAML" || fail "daily-digest.yml is valid YAML" ruby
else
  echo "skip approve-deploy: needs ruby"
fi

echo
[ "$fails" = 0 ] && echo "All passed." || { echo "$fails failed."; exit 1; }
