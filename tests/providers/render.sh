#!/bin/bash
# Tests for providers/render.sh beyond the shared contract: a 429 waits as long as Render's
# Retry-After says (at most 30 s), a name is looked up once a minute, not on every command.
# No network: curl is tests/lib/fake-curl.sh behind a wrapper. Run: bash tests/providers/render.sh
set -uo pipefail
cd "$(dirname "$0")/../.." || exit 1
fails=0
ok()   { echo "ok   $1"; }
fail() { echo "FAIL $1: $2"; fails=$((fails+1)); }
expect() { [ "$2" = "$3" ] && ok "$1" || fail "$1" "expected [$3], got [$2]"; }

tmp="$(mktemp -d)"; trap 'rm -rf "$tmp"' EXIT
mkdir -p "$tmp/bin"
cp tests/lib/fake-curl.sh "$tmp/bin/curl-fake"
# The wrapper: R429=<path part> answers that call once with 429 and the header "Retry-After: $RA"
# (none when RA is empty), written where -D asks. Every other call goes to the stand-in.
cat > "$tmp/bin/curl" <<'SH'
#!/bin/bash
hdr=""; prev=""; for a in "$@"; do [ "$prev" = -D ] && hdr="$a"; prev="$a"; done
url="${*: -1}"
if [ -n "${R429:-}" ] && [ ! -f "$RSTATE" ] && case "$url" in *"$R429"*) true;; *) false;; esac; then
  cat > /dev/null; : > "$RSTATE"; echo "curl 429 $url" >> "${CALLS:-/dev/null}"
  [ -z "$hdr" ] || { printf 'HTTP/2 429\r\n'; [ -z "${RA:-}" ] || printf 'retry-after: %s\r\n' "$RA"; printf '\r\n'; } > "$hdr"
  printf '%s\n429' '{"message":"rate limited"}'; exit 0
fi
exec "$(dirname "$0")/curl-fake" "$@"
SH
printf '#!/bin/bash\nexit 44\n' > "$tmp/bin/security"
printf '#!/bin/bash\necho "sleep $*" >> "$CALLS"\n' > "$tmp/bin/sleep"
chmod +x "$tmp/bin"/*
export FIXTURES="$PWD/tests/fixtures" CALLS="$tmp/calls.log" RSTATE="$tmp/rstate" RENDER_API_KEY=rnd_fixture
STUBPATH="$tmp/bin:/usr/bin:/bin"

lib() {  # lib <shell code>: the code with deploys sourced, under /bin/bash (bash 3.2 on macOS)
  rm -f "$RSTATE"; : > "$CALLS"
  ( PATH="$STUBPATH" DEPLOYS_CONFIG="$tmp/config" HOME="$tmp" NO_COLOR=1 DEPLOYS_LIB=1 \
      /bin/bash -c '. ./deploys; set +e; '"$1" 2>"$tmp/err" </dev/null )
}
mkdir -p "$tmp/config"

# --- PRV-032: Retry-After ---
out="$(R429=/services/srv-a RA=12 lib 'render_call GET /services/srv-a | jq -r .id')"
expect "429 waits as long as Retry-After says" "$out:$(grep '^sleep' "$CALLS")" "srv-a:sleep 12"
out="$(R429=/services/srv-a RA=600 lib 'render_call GET /services/srv-a | jq -r .id')"
expect "Retry-After is capped at 30 s" "$out:$(grep '^sleep' "$CALLS")" "srv-a:sleep 30"
out="$(R429=/services/srv-a RA='' lib 'render_call GET /services/srv-a | jq -r .id')"
expect "no Retry-After: 3 s as before" "$out:$(grep '^sleep' "$CALLS")" "srv-a:sleep 3"
R429=/deploys RA=7 lib 'render_json' > "$tmp/list.json"
# Eight run at once, so more than one may see the 429: every wait is the 7 s asked for.
expect "the list's parallel reads wait for Retry-After too" "$(grep '^sleep' "$CALLS" | sort -u):$(jq -r 'map(select(.fetchError != null)) | length' "$tmp/list.json")" "sleep 7:0"

# --- PRV-033: names are kept for a minute ---
rm -f "$tmp/config/render-names.json"
lib 'render_id_of web; render_id_of web' > "$tmp/ids"
expect "a name is looked up once, then kept" "$(tr '\n' ' ' < "$tmp/ids"):$(grep -c 'services?limit=100' "$CALLS")" "srv-a srv-a :1"
expect "the kept list holds only ids and names, 0600" "$(jq -c '.[0] | keys' "$tmp/config/render-names.json"):$(stat -f %Lp "$tmp/config/render-names.json" 2>/dev/null || stat -c %a "$tmp/config/render-names.json")" '["id","name"]:600'
echo '[{"id":"srv-old","name":"other"}]' > "$tmp/config/render-names.json"
expect "a name missing from the kept list is asked for again" "$(lib 'render_id_of web')" "srv-a"
echo '[{"id":"srv-old","name":"web"}]' > "$tmp/config/render-names.json"
expect "DEPLOYS_RENDER_NAME_TTL=0 never keeps it" "$(DEPLOYS_RENDER_NAME_TTL=0 lib 'render_id_of web')" "srv-a"
lib 'render_json' >/dev/null
expect "the list itself always asks Render" "$(grep -c 'services?limit=100' "$CALLS")" "1"

# --- FEA-110: autodeploy-on --dry-run lists the services that would build on push again ---
out="$(lib 'render_on --all --dry-run --json')"; rc=$?
expect "FEA-110: --all --dry-run --json: the services that are off" "$rc:$(echo "$out" | jq -c '[.provider, .dryRun, [.items[].id], .on]')" '0:["render",true,["srv-a","crn-c","srv-d"],3]'
expect "FEA-110: only reads" "$(grep -c '^curl \(POST\|PATCH\|PUT\|DELETE\)' "$CALLS")" 0
out="$(lib 'render_on srv-a --dry-run --json')"
expect "FEA-110: one service" "$(echo "$out" | jq -c '[.items[] | [.name, .action]]')" '[["web","on"]]'
out="$(PATH="$STUBPATH" DEPLOYS_CONFIG="$tmp/config" HOME="$tmp" NO_COLOR=1 /bin/bash ./deploys render autodeploy-on --all --dry-run --json 2>"$tmp/err" </dev/null)"
expect "FEA-110: through deploys render autodeploy-on" "$(echo "$out" | jq -c .on 2>&1)" 3

echo
[ "$fails" = 0 ] && echo "All Render tests passed." || { echo "$fails Render test(s) failed."; exit 1; }
