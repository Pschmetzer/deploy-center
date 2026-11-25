#!/bin/bash
# Tests for the CLI and provider fixes of round 12, part B (docs/IDEEN-12.md): lib/http.sh, the hook
# provider, completion, watch, verify, release.sh and the small helpers. No network, no real projects.
set -uo pipefail
cd "$(dirname "$0")/.." || exit 1
exec </dev/null
fails=0
ok()   { echo "ok   $1"; }
fail() { echo "FAIL $1: $2"; fails=$((fails+1)); }
expect() { [ "$2" = "$3" ] && ok "$1" || fail "$1" "expected [$3], got [$2]"; }

tmp="$(mktemp -d)"; trap 'rm -rf "$tmp"' EXIT
export DEPLOYS_CONFIG="$tmp/config" HOME="$tmp/home" NO_COLOR=1 DEPLOYS_LIB=1 DEPLOYS_TESTING=1 DEPLOYS_JOURNAL="$tmp/journal.jsonl"
mkdir -p "$HOME" "$DEPLOYS_CONFIG" "$tmp/bin"
printf '#!/bin/bash\nexit 1\n' > "$tmp/bin/gh"; chmod +x "$tmp/bin/gh"
printf '#!/bin/bash\nexit 0\n' > "$tmp/bin/sleep"; chmod +x "$tmp/bin/sleep"
export PATH="$tmp/bin:$PATH"
# shellcheck source=../deploys
. ./deploys
set +e
root="$PWD"
cli() { env -u DEPLOYS_LIB bash "$root/deploys" "$@"; }

# --- lib/http.sh: a curl stand-in that answers from $HTTP_MODE and logs what it got ---
cat > "$tmp/bin/curl" <<'C'
#!/bin/bash
k="$(cat)"; echo "$*|$k" >> "$HTTP_LOG"
hf=""; p=""; for a in "$@"; do [ "$p" = -D ] && hf="$a"; p="$a"; done
n="$(wc -l < "$HTTP_LOG" | tr -d ' ')"
case "$HTTP_MODE" in
  ok) printf '%s\n200' '{"ok":true}' ;;
  date429) printf 'HTTP/1.1 429\r\nRetry-After: Wed, 21 Oct 2099 07:28:00 GMT\r\n\r\n' > "$hf"; printf '%s\n429' 'slow' ;;
  num429) printf 'HTTP/1.1 429\r\nRetry-After: 2\r\n\r\n' > "$hf"; printf '%s\n429' 'slow' ;;
  exit6) echo "curl: (6) Could not resolve host" >&2; exit 6 ;;
  exit6then) if [ "$n" = 1 ]; then echo "curl: (6) Could not resolve host" >&2; exit 6; fi; printf '%s\n200' '{"ok":true}' ;;
  html) printf '<html>502</html>\n502' ;;
  leak) printf '%s\n500' '{"error":"bad token ghp_abcdefghijklmnop1234"}' ;;
  nf) printf '%s\n404' 'no' ;;
esac
C
chmod +x "$tmp/bin/curl"
hlog="$tmp/http.log"
hcall() {  # hcall <mode> <method> [url] [body]: output, then |rc
  ( export HTTP_LOG="$hlog" HTTP_MODE="$1"; : > "$hlog"; . ./lib/http.sh; HTTP_AUTH="${HTTP_AUTH-Authorization: Bearer sekret}"
    ( http_call X "$2" "${3:-https://api.x.test/v1/things}" "${4:-}" ) 2>&1; echo "|rc=$?" )
}
expect "curl_cfg_quote: quotes and backslashes are escaped" "$(. ./lib/http.sh; curl_cfg_quote 'a"b\c')" 'a\"b\\c'
expect "curl_cfg_quote: a line break is refused" "$(. ./lib/http.sh; curl_cfg_quote $'a\nurl = x' >/dev/null; echo $?)" "1"
out="$(HTTP_AUTH=$'Authorization: Bearer fragment123\nurl = x' hcall ok GET)"
expect "http_call: a key with a line break stops before curl, without the key" "$(echo "$out" | grep -c fragment123):$(echo "$out" | grep -c 'line break'):$(grep -c . "$hlog")" "0:1:0"
HTTP_AUTH='Authorization: Bearer a"b' hcall ok GET >/dev/null
expect "http_call: a quote in the key is escaped in the config line" "$(grep -c 'header = "Authorization: Bearer a\\"b"' "$hlog")" "1"
expect "http_call: Retry-After as a date far away stops with a hint (one try)" "$(hcall date429 GET | grep -c 'asks to wait'):$(wc -l < "$hlog" | tr -d ' ')" "1:1"
expect "http_call: Retry-After as a number is waited for and asked again" "$(hcall num429 GET >/dev/null; wc -l < "$hlog" | tr -d ' ')" "3"
expect "http_call: a POST is asked again when the host was not found (curl 6)" "$(hcall exit6then POST '' '{"a":1}' | head -n 1):$(wc -l < "$hlog" | tr -d ' ')" '{"ok":true}|rc=0:2'
expect "http_call: a POST after a timeout (curl 28 or a 5xx) is not asked again" "$(hcall html POST >/dev/null; wc -l < "$hlog" | tr -d ' ')" "1"
expect "http_call: a deadline of 0 allows no second try" "$(HTTP_DEADLINE=0 hcall exit6 GET >/dev/null; wc -l < "$hlog" | tr -d ' ')" "1"
expect "http_call: 404 names the kind of thing" "$(hcall nf GET https://a.test/v1/services/srv-1 | head -n 1)" 'Error: X GET /v1/services/srv-1 -> HTTP 404 (not found: no service "srv-1"; renamed or deleted?): no'
expect "http_call: an error body is masked like a log" "$(af_mask() { sed 's/ghp_[A-Za-z0-9]*/[masked]/g'; }; export -f af_mask; hcall leak GET | grep -c 'ghp_')" "0"
expect "http_call: DEPLOYS_HTTP_TRACE prints method, path, code; no query, no key" \
  "$(DEPLOYS_HTTP_TRACE=1 hcall ok GET 'https://a.test/v1/x?token=zzz' | grep -c '^http: GET /v1/x -> 200'):$(DEPLOYS_HTTP_TRACE=1 hcall ok GET 'https://a.test/v1/x?token=zzz' | grep -c 'zzz\|sekret')" "1:0"
# A temp file made for the call is gone when the call ends.
mkdir -p "$tmp/tt"; TMPDIR="$tmp/tt" hcall ok POST '' '{"x":"secret-body"}' >/dev/null; TMPDIR="$tmp/tt" hcall html GET >/dev/null
expect "http_call: no temp file is left behind" "$(ls "$tmp/tt" | wc -l | tr -d ' ')" "0"

# --- hook: userinfo, DNS, the lock after a failed trigger ---
expect "hook_check_url: https://evil.com@127.0.0.1/x is refused (user@host)" "$( ( hook_check_url 'https://evil.com@127.0.0.1/x' ) 2>&1 | grep -c 'user name')" "1"
expect "hook_check_url: https://user:pw@example.com/x is refused" "$( ( hook_check_url 'https://user:pw@example.com/x' ) >/dev/null 2>&1; echo $?)" "1"
hook_resolve() { case "$1" in rebind.example.com) echo 127.0.0.1 ;; ok.example.com) printf '2606:4700::1\n93.184.216.34\n' ;; esac; }
expect "hook_check_url: a name that resolves to 127.0.0.1 is refused" "$( ( hook_check_url 'https://rebind.example.com/x' ) 2>&1 | grep -c 'private or local')" "1"
expect "hook_check_url: --allow-private lets it through" "$( ( HOOK_ALLOW_PRIVATE=1 hook_check_url 'https://rebind.example.com/x' ) >/dev/null 2>&1; echo $?)" "0"
expect "hook_pin: pins the address that was checked (IPv4 first)" "$(hook_pin 'https://ok.example.com:8443/x')" 'resolve = "ok.example.com:8443:93.184.216.34"'
expect "hook_pin: nothing for an address in the URL" "$(hook_pin 'https://93.184.216.34/x')" ""
export DEPLOYS_HOOK_STORE=file
hook_add h1 'https://ok.example.com/hook/secret' --status-url 'https://ok.example.com/status' >/dev/null
expect "hook add: --status-url is stored" "$(hook_entry h1 | jq -r .statusUrl)" "https://ok.example.com/status"
cat > "$tmp/bin/curl" <<'C'
#!/bin/bash
cfg="$(cat)"; echo "$cfg" >> "$HTTP_LOG"
case "$cfg" in *"/status"*) printf '{"status":"BUILDING"}' ;; *) out="$(printf '%s\n' "$cfg" | sed -n 's/^output = "\(.*\)"$/\1/p')"; printf '' > "$out"; printf '%s' "${HOOK_CODE:-200}" ;; esac
C
: > "$hlog"; export HTTP_LOG="$hlog"
expect "hook status: a statusUrl says building" "$(hook_status h1 | cut -f2)" "building"
: > "$hlog"
expect "hook deploy: the config pins the checked address" "$( ( HOOK_CODE=200 hook_deploy_json h1 ) >/dev/null 2>&1; grep -c 'resolve = "ok.example.com:443:93.184.216.34"' "$hlog")" "1"
rm -rf "$DEPLOYS_CONFIG/locks"
( HOOK_CODE=401 hook_deploy_json h1 ) >/dev/null 2>&1
expect "hook deploy: a 401 leaves no one-minute lock" "$(ls "$DEPLOYS_CONFIG/locks" 2>/dev/null | wc -l | tr -d ' ')" "0"
( HOOK_CODE=503 hook_deploy_json h1 ) >/dev/null 2>&1
expect "hook deploy: a 503 keeps the lock (a build may have started)" "$(ls "$DEPLOYS_CONFIG/locks" 2>/dev/null | wc -l | tr -d ' ')" "1"

# --- the window in another zone and over a clock change (Pacific/Auckland: UTC+12, +13 in summer) ---
if [ -f /usr/share/zoneinfo/Pacific/Auckland ]; then
  want="$(TZ=Pacific/Auckland LC_ALL=C date '+%a %H:%M %Y-%m-%d' | tr '[:upper:]' '[:lower:]')"
  got="$( unset DEPLOYS_NOW; now_parts Pacific/Auckland)"
  # The two reads may straddle a minute: the hour and the date must agree.
  expect "now_parts: reads the clock of the zone it is given" "${got%:*}" "${want%:*}"
  off="$(TZ=Pacific/Auckland date +%z)"
  expect "now_parts: Auckland is 12 or 13 hours ahead of UTC" "$([ "$off" = +1200 ] || [ "$off" = +1300 ] && echo yes)" "yes"
fi
printf '{"deny":[{"days":["sat"],"from":"22:00","to":"06:00","reason":"weekend night"}]}' > "$tmp/w.json"
wr() { jq -c --arg time "$1" --arg date "$2" --arg day "$3" "$WINDOW_RULE" "$tmp/w.json" | jq -r .denied; }
expect "window over the clock change: sunday 02:00 (the 2026-09-27 change in NZ) is still the night after saturday" "$(wr 02:00 2026-09-27 sun)" "true"
expect "window over the clock change: sunday 06:00 is open" "$(wr 06:00 2026-09-27 sun)" "false"
expect "window over the year end: sunday 02:00 on 2027-01-03 is closed, 2027-01-04 monday 02:00 is open" "$(wr 02:00 2027-01-03 sun):$(wr 02:00 2027-01-04 mon)" "true:false"
expect "window on a leap day: sunday 2028-02-27 03:00 closed after saturday night" "$(wr 03:00 2028-02-27 sun)" "true"

# --- traps: a path with a space and a quote is run as data, not as code (trap_fn / exit_rm) ---
odd="$tmp/a b'c"; : > "$odd"
( trap_fn exit_rm "$odd"; exit 0 ); expect "trap_fn: a file named a b'c is removed at exit" "$([ -e "$odd" ] && echo left || echo gone)" "gone"

# A $(...) that adds its own exit cleanup must not run the ones of the shell around it.
keep="$tmp/keep-me"; : > "$keep"
( trap_fn exit_rm "$keep"; _="$( trap_fn exit_rm "$tmp/not-there"; echo inner )"; [ -e "$keep" ] && echo kept || echo removed-too-early ) > "$tmp/depth.out"
expect "trap_fn: a command substitution does not run its parent's cleanups" "$(cat "$tmp/depth.out")" "kept"

# --- temp files: named deploys.XXXXXXXX, and the old ones of a killed run are swept (once a day) ---
mkdir -p "$tmp/tt2"; f1="$(TMPDIR="$tmp/tt2" mktemp)"; d1="$(TMPDIR="$tmp/tt2" mktemp -d)"
expect "mktemp: our files are named deploys.<8 characters>" "$(basename "$f1" | grep -cE '^deploys\.[A-Za-z0-9]{8}$'):$(basename "$d1" | grep -cE '^deploys\.[A-Za-z0-9]{8}$')" "1:1"
touch -d '3 days ago' "$f1" "$d1" 2>/dev/null || touch -t 202001010000 "$f1" "$d1"
: > "$tmp/tt2/other-program.tmp"; touch -t 202001010000 "$tmp/tt2/other-program.tmp"
rm -f "$DEPLOYS_CONFIG/.tmp-swept"; ( CONFIG_DIR="$DEPLOYS_CONFIG" TMPDIR="$tmp/tt2" tmp_sweep )
expect "tmp_sweep: an old deploys.* file and folder go, another program's file stays" "$(ls "$tmp/tt2" | tr '\n' ' ')" "other-program.tmp "
f2="$(TMPDIR="$tmp/tt2" mktemp)"; touch -t 202001010000 "$f2"; ( CONFIG_DIR="$DEPLOYS_CONFIG" TMPDIR="$tmp/tt2" tmp_sweep )
expect "tmp_sweep: only once a day (the stamp)" "$([ -e "$f2" ] && echo kept || echo swept)" "kept"

# --- check-public.sh and the masker know the same prefixes: a sample of each goes through both ---
samples=( "sk-abcdefgh12345" "sk_live_abcdefgh1234" "whsec_abcdefgh1234" "ghp_abcdefgh1234" "github_pat_abcdefgh1234" "glpat-abcdefgh1234"
  "xoxb-abcdefgh1234" "AKIAABCDEFGHIJKLMNOP" "AIzaabcdefghijklmnopqrstuvwxyz" "npm_abcdefghijklmnopqrstuvwxyz" "rnd_abcdefgh1234"
  "vcp_abcdefgh1234" "vck_abcdefgh1234" "cfut_abcdefgh1234" "cfat_abcdefgh1234" "HRKU-abcdefgh1234" "fo1_abcdefgh1234" "dp.st.abcdefgh1234"
  "nfp_abcdefgh1234" "dop_v1_0123456789abcdef0123" "sbp_abcdefghijklmnop1234" "sb_secret_abcdefgh1234" "SG.abcdefghijklmnop12.abcdefghijklmnop12"
  "re_abcdefghijklmnop1234" "sntrys_abcdefghijklmnop1234" "lin_api_abcdefghijklmnop12" "eyJabcdefghijk.abcdefgh" "hf_abcdefghijklmnopqrstu" )
miss_pub=""; miss_mask=""
for t in "${samples[@]}"; do
  printf 'x %s y\n' "$t" | bash scripts/check-public.sh --stdin >/dev/null 2>&1 && miss_pub="$miss_pub $t"
  [ "$(printf 'x %s y\n' "$t" | af_mask)" != "x $t y" ] || miss_mask="$miss_mask $t"
done
expect "check-public.sh: every prefix of the masker is found in a text" "$miss_pub" ""
expect "af_mask: every sample prefix is masked" "$miss_mask" ""

# --- secrets are never arguments: a signed URL and a key go in on stdin ---
expect "curl_url_cfg: a signed link is a config line, quotes escaped" "$(. ./lib/http.sh; curl_url_cfg 'https://h.test/p?sig=a"b')" 'url = "https://h.test/p?sig=a\"b"'
expect "curl_url_cfg: a line break is refused" "$(. ./lib/http.sh; curl_url_cfg $'https://h.test/\nx' >/dev/null; echo $?)" "1"

# --- parallel_limit and par_fn ---
expect "parallel_limit: default, the variable, a bad value, the ceiling" "$(. ./lib/http.sh; parallel_limit 8):$(DEPLOYS_PARALLEL=3 parallel_limit 8):$(DEPLOYS_PARALLEL=x parallel_limit 8):$(DEPLOYS_PARALLEL=500 parallel_limit 8)" "8:3:8:32"
bashfn_here() { echo here; }; par_fn bashfn_here
expect "xargs_par: exports the functions to that xargs only" "$(echo x | xargs_par -n 1 bash -c 'bashfn_here'):$(env | grep -c '^BASH_FUNC_bashfn_here')" "here:0"

# --- exit codes ---
expect "die_usage: exit 2" "$( ( die_usage "x" ) >/dev/null 2>&1; echo $?)" "2"
expect "exit-codes: prints the table, with the wrong-call code" "$(cli exit-codes | grep -c '2 a wrong call')" "1"
expect "exit-codes: prints only its own block, not the code after it" "$(cli exit-codes | grep -c "autofix_run\|AF_NOT_FAILED")" "0"
expect "a command without its argument is a wrong call (exit 2)" "$(cli watch >/dev/null 2>&1; echo $?)" "2"

# --- completion: parses in every shell that is here, and finds the command after global options ---
for sh in bash zsh fish; do
  cli completion $sh > "$tmp/comp.$sh"
  case "$sh" in
    bash) ( bash -n "$tmp/comp.bash" ) 2>&1; expect "completion bash: bash -n" "$?" "0" ;;
    zsh) if command -v zsh >/dev/null 2>&1; then zsh -n "$tmp/comp.zsh" 2>&1; expect "completion zsh: zsh -n" "$?" "0"; fi ;;
    fish) if command -v fish >/dev/null 2>&1; then fish --no-execute "$tmp/comp.fish" 2>&1; expect "completion fish: fish --no-execute" "$?" "0"; fi ;;
  esac
done
bcomp() { bash -c 'eval "$1"; shift; COMP_WORDS=("$@"); COMP_CWORD=$(( $# - 1 )); _deploys; echo "${COMPREPLY[*]}"' _ "$(cat "$tmp/comp.bash")" "$@"; }
expect "completion: after --json the command word is found" "$(bcomp deploys --json guard '')" "status schedule"
expect "completion: ai, gitlab, providers and completion come from the one table" "$(bcomp deploys gitlab ''):$(bcomp deploys providers ''):$(bcomp deploys completion '')" "set-token forget-token:enable disable:zsh bash fish"
expect "completion: flags of a command after a dash" "$(bcomp deploys watch x --t)" "--timeout"
expect "completion: flags of a provider verb" "$(bcomp deploys vercel deploy web --pre)" "--preview"
expect "completion: the path of the names file is quoted for the shell (%q)" "$(DEPLOYS_CONFIG="$tmp/conf ig" cli completion bash | grep -c 'conf\\ ig/names')" "1"

# --- watch: with a fake platform (a function), in a subshell because it exits ---
# shellcheck disable=SC2034  # read by watch_main
resolve() { PLAT=fake; PID=x; PNAME=x; }
FAKE_MODE=ready
fake_latest() { case "$FAKE_MODE" in
  ready) printf 'd1\tready\tready\n' ;; failed) printf 'd1\tfailed\tfailed\n' ;; canceled) printf 'd1\tcanceled\tcanceled\n' ;;
  denied) echo "Fake GET /v1/x -> HTTP 401 (the key is wrong or expired)" >&2; return 1 ;;
  slow) n=$(( $(cat "$tmp/fake-n" 2>/dev/null || echo 0) + 1 )); echo $n > "$tmp/fake-n"
        if [ "$n" -lt 3 ]; then echo "Fake GET /v1/x -> HTTP 429 (rate limit)" >&2; return 1; fi; printf 'd1\tready\tready\n' ;; esac; }
fake_url() { echo "https://x.example.test"; }
wm() { ( watch_main watch x "$@" ) 2>"$tmp/wm.err"; echo "rc=$?"; }
expect "watch --json: ready, one JSON line with url" "$(FAKE_MODE=ready json=1 wm | head -n 1 | jq -c '[.phase, .url, .id]' 2>/dev/null)" '["ready","https://x.example.test","d1"]'
expect "watch --json: failed and canceled are told apart, both exit 1" "$(FAKE_MODE=failed json=1 wm | tr '\n' ' '; FAKE_MODE=canceled json=1 wm | tr '\n' ' ')" '{"project":"x","id":"d1","phase":"failed","state":"failed","url":null} rc=1 {"project":"x","id":"d1","phase":"canceled","state":"canceled","url":null} rc=1 '
expect "watch: a refused key (401) is exit 3 at once, said" "$(FAKE_MODE=denied wm; grep -c 'refused the key' "$tmp/wm.err")" $'rc=3\n1'
rm -f "$tmp/fake-n"
expect "watch: a 429 is waited for, not counted as a miss (ready on the third ask)" "$(FAKE_MODE=slow wm | tail -n 1; grep -c 'asks to slow down' "$tmp/wm.err")" $'rc=0\n2'
expect "watch --quiet: no progress lines" "$(FAKE_MODE=ready wm --quiet >/dev/null; wc -l < "$tmp/wm.err" | tr -d ' ')" "0"
expect "watch --interval: under 2 seconds is refused" "$(FAKE_MODE=ready wm --interval 1s | tail -n 1)" "rc=1"
expect "watch_jitter: between the wait and a third more" "$(for i in 1 2 3 4 5 6; do watch_jitter 6; done | awk '$1 < 6 || $1 > 8 { bad = 1 } END { print bad + 0 }')" "0"
( sleep 30 ) & sp1=$!; ( sleep 30 ) & sp2=$!
watch_stop_all; sleep 0.3
expect "watch_stop_all: Ctrl-C of --and ends the background watches" "$(kill -0 $sp1 2>/dev/null && echo alive || echo gone):$(kill -0 $sp2 2>/dev/null && echo alive || echo gone)" "gone:gone"

# --- verify: --match, --header, a reason for no answer, the countdown without a terminal ---
SELF="$tmp/fake-self"; printf '#!/bin/bash\nexit 0\n' > "$SELF"; chmod +x "$SELF"
site_url_of() { echo "https://site.example.test"; }; team_on() { return 1; }; journal_add() { :; }; safe_arg() { :; }
cat > "$tmp/bin/curl" <<'C'
#!/bin/bash
o=""; d=""; p=""; for a in "$@"; do [ "$p" = -o ] && o="$a"; [ "$p" = -D ] && d="$a"; p="$a"; done
cat >/dev/null 2>&1 </dev/null
case "${VMODE:-ok}" in
  dns) echo "curl: (6) Could not resolve host" >&2; printf 000; exit 6 ;;
  *) [ -z "$o" ] || [ "$o" = /dev/null ] || printf 'hello world' > "$o"; [ -z "$d" ] || printf 'HTTP/2 200\r\nX-Test: abc\r\n\r\n' > "$d"; printf 200 ;;
esac
C
chmod +x "$tmp/bin/curl"
vm() { ( verify_main verify x --tries 1 --every 0 --no-rollback "$@" ) 2>"$tmp/vm.err" >"$tmp/vm.out"; echo "rc=$?"; }
expect "verify: --match finds the text" "$(vm --match hello)" "rc=0"
expect "verify: --match with text that is not there fails (exit 2, no rollback)" "$(vm --match nothere; grep -c 'does not contain' "$tmp/vm.err")" $'rc=2\n1'
expect "verify: --header with a value that is there" "$(vm --header 'X-Test: ab')" "rc=0"
expect "verify: --header that is missing fails" "$(vm --header 'X-Other: 1')" "rc=2"
expect "verify: no answer says why (DNS)" "$(VMODE=dns vm; grep -c 'DNS: the name was not found' "$tmp/vm.err")" $'rc=2\n1'
expect "verify: --json carries why for a failing check" "$(VMODE=dns json=1 vm >/dev/null; jq -c '.checks[0].why' "$tmp/vm.out")" '["DNS: the name was not found"]'
expect "verify: a bad --cert-days is refused" "$(vm --cert-days x | tail -n 1)" "rc=3"
expect "verify: --warmup is a time" "$(vm --warmup soon | tail -n 1)" "rc=3"

# --- config export / import ---
echo '{"monthlyUsd":50}' > "$DEPLOYS_CONFIG/budget.json"
cli config export "$tmp/cfg.json" >/dev/null
expect "config export: the file has the budget, a kind and a version" "$(jq -c '[.kind, .version, .files["budget.json"].monthlyUsd]' "$tmp/cfg.json")" '["deploys-config",1,50]'
expect "config export: private (0600)" "$(stat -c %a "$tmp/cfg.json" 2>/dev/null || stat -f %Lp "$tmp/cfg.json")" "600"
rm -f "$DEPLOYS_CONFIG/budget.json"
expect "config import: without --yes it writes nothing" "$(cli config import "$tmp/cfg.json" | tail -n 1; [ -e "$DEPLOYS_CONFIG/budget.json" ] && echo wrote || echo none)" $'Nothing written. Add --yes to write it.\nnone'
cli config import "$tmp/cfg.json" --yes >/dev/null
expect "config import --yes: written" "$(jq -c .monthlyUsd "$DEPLOYS_CONFIG/budget.json")" "50"
jq '.files["budget.json"].token = "ghp_abcdefgh1234567890abcdefgh1234567890"' "$tmp/cfg.json" > "$tmp/cfg-key.json"
expect "config import: a file with a key in it is refused" "$(cli config import "$tmp/cfg-key.json" --yes >/dev/null 2>"$tmp/ci.err"; echo $?; grep -c 'looks like a key' "$tmp/ci.err")" $'1\n1'
jq '.files["../evil.json"] = {}' "$tmp/cfg.json" > "$tmp/cfg-evil.json"
expect "config import: a file name outside the list is refused" "$(cli config import "$tmp/cfg-evil.json" --yes >/dev/null 2>&1; echo $?)" "1"

# --- digest and savings as Markdown ---
now="$(date +%s)"; at="$(date -u -d "@$((now - 3600))" +%Y-%m-%dT%H:%M:%SZ 2>/dev/null || date -u -r "$((now - 3600))" +%Y-%m-%dT%H:%M:%SZ)"
. ./lib/digest.sh
md="$(printf '{"at":"%s","result":"live","name":"a|b","platform":"vercel"}\n{"at":"%s","result":"failed","name":"web","platform":"vercel","detail":"boom"}\n' "$at" "$at" | digest_from "$now" 7 | digest_markdown)"
expect "digest --format markdown: heading, list, table; a | in a name is escaped" "$(echo "$md" | grep -c '^## Deploys of the last 7 days'):$(echo "$md" | grep -c '^| a\\|b | vercel | 1 | 0 |$')" "1:1"
. ./lib/savings.sh
sv='{"kind":"ledger","since":"2026-01-01","total":{"usd":12.5,"skipped":10},"method":"m","projects":[{"name":"web","platform":"vercel","offDay":"2026-01-01","skipped":10,"pushes":12,"savedUsd":12.5}]}'
expect "savings --format markdown: a table of projects" "$(echo "$sv" | sv_markdown | grep -c '^| web | vercel | 2026-01-01 | 10 of 12 | \$12.5 |$')" "1"

# --- metrics ---
# (the up and timestamp lines are asserted in script-tests, next to the other metrics tests)

# --- hooks: pre-commit, a global hooksPath, a pre-push.local that cannot run ---
hr="$tmp/hr"; git init -q "$hr"; git -C "$hr" config user.email t@example.test; git -C "$hr" config user.name t
cli hooks install "$hr" --hook pre-commit >/dev/null 2>&1
printf 'k = "ghp_abcdefghijklmnopqrstuvwxyz0123456789"\n' > "$hr/f.txt"; git -C "$hr" add f.txt
expect "hooks pre-commit: a commit that adds a token is stopped" "$(cd "$hr" && env -u DEPLOYS_LIB git commit -qm x >/dev/null 2>&1; echo $?)" "1"
git -C "$hr" reset -q; printf 'plain\n' > "$hr/f.txt"; git -C "$hr" add f.txt
expect "hooks pre-commit: a clean commit goes" "$(cd "$hr" && env -u DEPLOYS_LIB git commit -qm y >/dev/null 2>&1; echo $?)" "0"
cli hooks uninstall "$hr" --hook pre-commit >/dev/null 2>&1
expect "hooks uninstall --hook pre-commit: the hook is gone" "$([ -e "$hr/.git/hooks/pre-commit" ] && echo there || echo gone)" "gone"
printf '#!/bin/bash\nexit 0\n' > "$hr/.git/hooks/pre-push"; chmod -x "$hr/.git/hooks/pre-push"
cli hooks install "$hr" >/dev/null 2>&1
expect "hooks status: a pre-push.local that is not executable is said" "$(cli hooks status "$hr" | grep -c 'not executable')" "1"
expect "hooks status --json: localExecutable false" "$(cli hooks status "$hr" --json | jq -c .localExecutable)" "false"
hg="$tmp/hg"; git init -q "$hg"
expect "hooks install: a global core.hooksPath asks for --yes" "$(HOME="$tmp/hhome" ; mkdir -p "$tmp/hhome"; HOME="$tmp/hhome" git config --global core.hooksPath "$tmp/ghooks"; HOME="$tmp/hhome" cli hooks install "$hg" 2>&1 >/dev/null | grep -c 'EVERY repo')" "1"
expect "hooks install --yes: goes ahead into the global folder" "$(HOME="$tmp/hhome" cli hooks install "$hg" --yes >/dev/null 2>&1; [ -e "$tmp/ghooks/pre-push" ] && echo yes || echo no)" "yes"

# --- release.sh ---
rd="$tmp/rel"; mkdir -p "$rd"; cp release.sh "$rd/"
expect "release.sh: --dry-run with --check-addons is said, exit 2" "$(bash "$rd/release.sh" --check-addons --dry-run >/dev/null 2>&1; echo $?)" "2"
expect "release.sh: --help is the whole first block, with --force-republish" "$(bash "$rd/release.sh" --help | grep -c -e '--dry-run\|--force-republish')" "2"
: > "$rd/.release.env"; chmod 666 "$rd/.release.env"
expect "release.sh: a .release.env others can write is not used" "$(bash "$rd/release.sh" --dry-run 2>&1 | grep -c 'can be written by others')" "1"
eval "$(sed -n '/^notes_of() {/,/^}/p' release.sh)"
( cd "$tmp" && printf '# Changelog\n\n## v0.7.0 - 2026-01-01\n\n- a fix\n\n## 0.6.0\n\n- old\n' > CHANGELOG.md )
expect "release.sh notes_of: '## v0.7.0' is found" "$( cd "$tmp" && VERSION=0.7.0 notes_of | grep -c 'a fix')" "1"

[ "$fails" = 0 ] && echo "All tests passed." || { echo "$fails failed."; exit 1; }
