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
[{"name":"app-web","auto":false,"repo":"me/app","ref":"main","deployable":true,"changed":true,"pendingCommits":4,"lastAt":$((now - 3*86400))},
 {"name":"site","auto":true,"repo":"me/site","ref":"main","deployable":true,"changed":false,"pendingCommits":0,"lastAt":$((now - 1))}]
JSON
cat > "$tmp/render.json" <<JSON
[{"name":"api","auto":true,"repo":"me/app","ref":"main","deployable":true,"changed":true,"pendingCommits":null,"lastAt":$((now - 60)),"liveAt":$((now - 26*3600))}]
JSON
mkdir -p "$tmp/bin"
cat > "$tmp/bin/deploys" <<SH
#!/bin/bash
case "\$*" in
  "vercel list --json") cat "$tmp/vercel.json" ;;
  "render list --json") cat "$tmp/render.json" ;;
  "doctor") echo "{\"renderKey\":\${FAKE_RENDER_KEY:-false}}" ;;
  "changed --json") jq -s 'add | map(select(.changed))' "$tmp/vercel.json" "$tmp/render.json"; exit "\${FAKE_RC:-0}" ;;
  "deploy-changed --yes") echo "\$*" >> "$tmp/deploy.log"; exit "\${FAKE_RC:-0}" ;;
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
  expect "action: deployed=true after starting" "$(cat "$tmp/out")" "deployed=true"
  FAKE_RC=1 run_step deploy.sh; expect "action: a failed start fails the step" "$?" 1
  expect "action: no deployed=true after a failure" "$(cat "$tmp/out")" ""
  expect "action: deploy step only with deploy: true" "$(step deploy if)" "inputs.deploy == 'true' && steps.changed.outputs.count != '0'"
  case "$(cat "$tmp/changed.sh" "$tmp/deploy.sh")" in *'${{'*) fail "action: no inputs inside run scripts" "found" ;; *) ok "action: no inputs inside run scripts" ;; esac
fi

echo
[ "$fails" = 0 ] && echo "All passed." || { echo "$fails failed."; exit 1; }
