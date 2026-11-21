#!/bin/bash
# Fast tests for the round-8 changes in `deploys`: the masker, and small commands that need no network.
# No network, no real projects. Run: tests/round8-tests.sh
set -uo pipefail
cd "$(dirname "$0")/.." || exit 1
exec </dev/null
fails=0
ok()   { echo "ok   $1"; }
fail() { echo "FAIL $1: $2"; fails=$((fails+1)); }
expect() { [ "$2" = "$3" ] && ok "$1" || fail "$1" "expected [$3], got [$2]"; }

tmp="$(mktemp -d)"; trap 'rm -rf "$tmp"' EXIT
export DEPLOYS_CONFIG="$tmp/config" DEPLOYS_LIB=1 DEPLOYS_TESTING=1 HOME="$tmp/home" NO_COLOR=1
mkdir -p "$HOME"
# shellcheck source=../deploys
. ./deploys
set +e   # deploys sets -e; the tests look at failures themselves

# --- af_mask: more shapes, a line cap, and what stays readable ---
m() { printf '%s\n' "$1" | af_mask; }
expect "mask: a Slack webhook URL" "$(m 'post https://hooks.slack.com/services/T000/B000/XXXXsecretXXXX failed')" "post https://hooks.slack.com/services/[masked] failed"
expect "mask: a Discord webhook URL" "$(m 'https://discord.com/api/webhooks/123456789012345678/abc-DEF_ghi.jkl')" "https://discord.com/api/webhooks/[masked]"
expect "mask: a Telegram bot token in a URL" "$(m 'GET https://api.telegram.org/bot123456789:AAHdqTcvCH1vGWJxfSeofSAs0K5PALDsaw8/getMe')" "GET https://api.telegram.org/bot[masked]/getMe"
expect "mask: a bare Telegram bot token" "$(m 'bot 123456789:AAHdqTcvCH1vGWJxfSeofSAs0K5PALDsaw8 ok')" "bot [masked] ok"
expect "mask: a Hugging Face token" "$(m 'login hf_abcdefghijklmnopqrstuvwxyz0123')" "login [masked]"
expect "mask: a Coolify token" "$(m 'token 12|abcdefghijklmnopqrstuvwxyzABCDEFGHIJ0123 ok')" "token [masked] ok"
expect "mask: a long key-like run on a line about a secret" "$(m 'the secret was Zm9vYmFyYmF6cXV4Zm9vYmFyYmF6cXV4Zm9vYmFyYmF6cXV4MTIz end')" "the secret was [masked] end"
expect "mask: a long run on an ordinary line stays" "$(m 'sha512-Zm9vYmFyYmF6cXV4Zm9vYmFyYmF6cXV4Zm9vYmFyYmF6cXV4MTIz built')" "sha512-Zm9vYmFyYmF6cXV4Zm9vYmFyYmF6cXV4Zm9vYmFyYmF6cXV4MTIz built"
expect "mask: a commit sha on a line about a token stays" "$(m 'token check for 0123456789abcdef0123456789abcdef01234567')" "token check for 0123456789abcdef0123456789abcdef01234567"
expect "mask: git@host stays readable" "$(m 'git@github.com:me/app.git: Permission denied')" "git@github.com:me/app.git: Permission denied"
expect "mask: a password with an @ in a URL" "$(m 'postgres://u:p@ss@host/db')" "postgres://u:[masked]@host/db"
# A line of 150000 characters: cut, and fast (a crafted line must not make the patterns crawl).
start=$SECONDS
long="$(perl -e 'print "a." x 75000')"
cut="$(printf '%s\n' "$long" | af_mask | wc -c | tr -d ' ')"
[ "$cut" -lt 4100 ] && [ $((SECONDS - start)) -lt 10 ] && ok "mask: a 150000-character line is cut and handled fast" || fail "mask: long line" "bytes $cut, $((SECONDS - start)) s"

# --- the scan of an untrusted repo does not see the secrets of this shell ---
names="$(GH_TOKEN=a NPM_TOKEN=b VERCEL_TOKEN=c AWS_SECRET_ACCESS_KEY=d MY_PASSWORD=e SSH_AUTH_SOCK=/x DATABASE_URL=u STRIPE_KEY=k SENTRY_DSN=d LANG=C HTTPS_PROXY=p CLAUDE_CODE_OAUTH_TOKEN=keep ANTHROPIC_AUTH_TOKEN=keep2 HARMLESS=1 sc_secret_env_names | paste -sd, -)"
has_name() { case ",$names," in *",$1,"*) return 0 ;; esac; return 1; }
for n in GH_TOKEN NPM_TOKEN VERCEL_TOKEN AWS_SECRET_ACCESS_KEY MY_PASSWORD SSH_AUTH_SOCK DATABASE_URL STRIPE_KEY SENTRY_DSN HARMLESS; do
  expect "scan env: $n is taken away" "$(has_name "$n" && echo yes || echo no)" "yes"
done
for n in CLAUDE_CODE_OAUTH_TOKEN ANTHROPIC_AUTH_TOKEN HOME PATH LANG HTTPS_PROXY; do
  expect "scan env: $n stays" "$(has_name "$n" && echo taken || echo stays)" "stays"
done

# --- EXIT traps chain instead of replacing each other ---
: > "$tmp/trap.log"
rc=0; ( trap_add "echo first >> '$tmp/trap.log'"; trap_add "echo \"second rc=\$?\" >> '$tmp/trap.log'"; exit 3 ) || rc=$?
expect "trap_add: both run, the newest first, with the exit status" "$rc:$(paste -sd, "$tmp/trap.log")" "3:second rc=3,first"
: > "$tmp/trap.log"
( trap_add "echo a >> '$tmp/trap.log'"; trap_add "echo b >> '$tmp/trap.log'"; trap_pop; exit 0 )
expect "trap_pop: takes the newest off" "$(paste -sd, "$tmp/trap.log")" "a"
: > "$tmp/trap.log"
( trap_add "echo only >> '$tmp/trap.log'"; trap_pop; exit 0 )
expect "trap_pop: the last one leaves no trap" "$(wc -c < "$tmp/trap.log" | tr -d ' ')" "0"

# --- logs --follow: only the new lines of a log that is read again ---
printf 'a\nb\nc\n' > "$tmp/old"; printf 'b\nc\nd\ne\n' > "$tmp/new"
expect "log_new_lines: what comes after the last old line" "$(log_new_lines "$tmp/old" "$tmp/new" | paste -sd, -)" "d,e"
printf 'x\n' > "$tmp/old"; printf 'p\nq\n' > "$tmp/new"
expect "log_new_lines: no overlap, all of it is new" "$(log_new_lines "$tmp/old" "$tmp/new" | paste -sd, -)" "p,q"
printf 'p\nq\n' > "$tmp/old"
expect "log_new_lines: nothing new" "$(log_new_lines "$tmp/old" "$tmp/new" | paste -sd, -)" ""
printf 'p\nq\n\n\n' > "$tmp/old"; printf 'q\nr\n' > "$tmp/new"
expect "log_new_lines: blank lines at the end of the old log do not count" "$(log_new_lines "$tmp/old" "$tmp/new" | paste -sd, -)" "r"
: > "$tmp/old"
expect "log_new_lines: the first read is all of it" "$(log_new_lines "$tmp/old" "$tmp/new" | paste -sd, -)" "q,r"

# --- hooks.d around a start ---
fake_deploy_json() { echo '{"id":"x","state":"queued"}'; }
hd="$CONFIG_DIR/hooks.d"; mkdir -p "$hd"
printf '#!/bin/bash\necho "$DEPLOYS_HOOK $DEPLOYS_PLATFORM $DEPLOYS_PROJECT $DEPLOYS_SHA $DEPLOYS_STATE" >> "%s"\n' "$tmp/hook.log" > "$hd/pre-deploy-1"
cp "$hd/pre-deploy-1" "$hd/post-deploy-1"; chmod 755 "$hd/pre-deploy-1" "$hd/post-deploy-1"; : > "$tmp/hook.log"
expect "hooks.d: the start's JSON is unchanged" "$(deploy_one fake web abc123 2>/dev/null)" '{"id":"x","state":"queued"}'
expect "hooks.d: pre and post ran with the environment" "$(cat "$tmp/hook.log")" $'pre-deploy fake web abc123 \npost-deploy fake web abc123 queued'
printf '#!/bin/bash\nexit 1\n' > "$hd/pre-deploy-2"; chmod 755 "$hd/pre-deploy-2"; : > "$tmp/hook.log"
rc=0; out="$(deploy_one fake web abc123 2>"$tmp/err")" || rc=$?
expect "hooks.d: a failing pre-deploy hook stops the start" "$rc:[$out]:$(grep -c 'pre-deploy hook refused web' "$tmp/err")" "1:[]:1"
expect "hooks.d: and no post-deploy hook ran" "$(grep -c '^post-deploy' "$tmp/hook.log")" "0"
chmod 757 "$hd/pre-deploy-2"
rc=0; out="$(deploy_one fake web abc123 2>"$tmp/err")" || rc=$?
expect "hooks.d: a hook everyone can write to is not run" "$rc:$(grep -c 'writable by everyone' "$tmp/err")" "0:1"
rm -rf "$hd"

# --- a command of your own for notifications ---
DEPLOYS_NOTIFY=0 DEPLOYS_NOTIFY_CMD="cat > '$tmp/n.txt'" af_notify "build web failed" >/dev/null
expect "notify: the command gets the message on stdin" "$(cat "$tmp/n.txt")" "build web failed"
DEPLOYS_NOTIFY=0 DEPLOYS_NOTIFY_CMD="printf %s \"\$DEPLOYS_MESSAGE\" > '$tmp/n2.txt'" af_notify "second" >/dev/null
expect "notify: and in DEPLOYS_MESSAGE" "$(cat "$tmp/n2.txt")" "second"

# --- a key from a command ---
fk_meta() { echo '{"id":"fk","label":"Fk","keyEnv":["FK_KEY"],"keychain":"x","caps":{}}'; }
expect "key command: FK_KEY_CMD gives the key" "$(FK_KEY_CMD='echo secretvalue' key_of fk)" "secretvalue"
expect "key command: the variable still wins" "$(FK_KEY=fromenv FK_KEY_CMD='echo secretvalue' key_of fk)" "fromenv"
expect "key command: a key with a quote is refused" "$(FK_KEY_CMD="echo 'a\"b'" key_of fk 2>&1 | grep -c 'cannot be in one')" "1"
expect "key command: a command that prints nothing is an error" "$(FK_KEY_CMD='true' key_of fk 2>&1 | grep -c 'printed no key')" "1"
expect "key command: counts as a key in the environment" "$(FK_KEY_CMD='true'; export FK_KEY_CMD; key_of_env fk && echo yes)" "yes"

# --- observer attempts are journaled, and the chain is checked ---
export DEPLOYS_JOURNAL="$tmp/j.jsonl"
( export DEPLOYS_READONLY=1; require_write "deploy web" ) >/dev/null 2>&1
expect "observer: a refused attempt is in the journal" "$(jq -r '[.result, (.detail | startswith("Refused in observer mode"))] | join(":")' "$DEPLOYS_JOURNAL")" "skipped:true"
rm -f "$DEPLOYS_JOURNAL"
journal_add a1 n1 live "one"; journal_add a2 n2 live "two"; journal_add a3 n3 live "three"
cli() { env -u DEPLOYS_LIB bash ./deploys "$@"; }
expect "journal verify: an untouched chain" "$(cli journal verify; echo "rc=$?")" $'Journal: 3 lines, 2 linked to the line before, 0 without a link. No broken link.\nrc=0'
perl -pi -e 's/"two"/"TWO"/ if $. == 2' "$DEPLOYS_JOURNAL"
expect "journal verify: a changed line breaks the link after it" "$(cli journal verify | grep -c 'link before line 3')" "1"
expect "journal verify --json names the line" "$(cli journal verify --json | jq -c '.broken')" "[3]"
rc=0; cli journal verify >/dev/null || rc=$?
expect "journal verify: a broken chain exits 1" "$rc" "1"
unset DEPLOYS_JOURNAL

# --- completion: commands come from the case labels, and the second word is completed for the multi-command ones ---
cli() { env -u DEPLOYS_LIB bash ./deploys "$@"; }
comp="$(cli completion bash)"
# The bash completion is run, not read: what a word completes to is what counts.
bcomp() { bash -c 'eval "$1"; shift; COMP_WORDS=("$@"); COMP_CWORD=$(( $# - 1 )); _deploys; echo "${COMPREPLY[*]}"' _ "$comp" "$@"; }
expect "completion: a command of the case labels (rollback) is offered" "$(bcomp deploys roll)" "rollback"
expect "completion bash: schedule completes daily off status" "$(bcomp deploys schedule '')" "daily off status"
expect "completion bash: after --json the command word is still found" "$(bcomp deploys --json schedule '')" "daily off status"
expect "completion zsh: autofix completes its subcommands" "$(cli completion zsh | grep -c -F 'cmd == autofix && $pos == 3 ]]; then compadd -- set-token routine')" "1"
expect "completion fish: hooks completes install uninstall status" "$(cli completion fish | grep -c "seen_subcommand_from hooks' -a 'install uninstall status'")" "1"

echo
[ "$fails" -eq 0 ] && echo "All round-8 tests passed." || { echo "$fails failed."; exit 1; }
