#!/bin/bash
# The speed changes must not change what the CLI prints: a list of made-up projects (odd repos on purpose: an
# underscore, capitals in the host, a host that is not supported, no repo, a rebase merge without a PR number)
# read with a fake gh must equal tests/fixtures/perf/list.golden.json, which was made by the code before the changes.
# No network, no account. Run: bash tests/perf-tests.sh   (BLESS=1 writes the golden file from the code in this tree)
set -uo pipefail
cd "$(dirname "$0")/.." || exit 1
fails=0
ok()   { echo "ok   $1"; }
fail() { echo "FAIL $1: $2"; fails=$((fails+1)); }
w="$(mktemp -d)"; trap 'rm -rf "$w"' EXIT
mkdir -p "$w/dd/providers" "$w/cfg" "$w/bin"
cp deploys "$w/dd/deploys"; cp -R lib "$w/dd/lib"
cat > "$w/dd/providers/fake.sh" <<'PROV'
fake_meta() { printf '{"id":"fake","label":"Fake","noun":"project","defaultOn":true,"keyEnv":["FAKE_KEY"],"keychain":"deploy-center-fake","caps":{"off":false,"sha":false,"cancel":false,"rollback":false,"logs":false,"preview":false}}\n'; }
fake_ready() { return 0; }
fake_json() {
  jq -n '[
    {name:"a-plain",   repo:"acme/app",                     ref:"main", lastSha:"aaaa"},
    {name:"b-under",   repo:"acme/my_app",                  ref:"main", lastSha:"aaaa"},
    {name:"c-same",    repo:"acme/app",                     ref:"main", lastSha:"bbbb"},
    {name:"d-bare",    repo:"acme/rebased",                 ref:"main", lastSha:"aaaa"},
    {name:"e-bitb",    repo:"bitbucket.org/acme/app",       ref:"main", lastSha:"aaaa"},
    {name:"f-caps",    repo:"https://GitHub.com/acme/app.git", ref:"main", lastSha:"aaaa"},
    {name:"g-norepo",  repo:null,                           ref:null,   lastSha:null},
    {name:"h-noref",   repo:"acme/app",                     ref:null,   lastSha:"aaaa"},
    {name:"i-ssh",     repo:"git@github.com:acme/app.git",  ref:"main", lastSha:"aaaa"}
  ] | map(. + {id:.name, auto:true, deployable:true, paused:false, lastAt:1700000000, lastState:"ready", fetchError:null, phase:"ready"})';
}
PROV
echo '{"enabled":["fake"]}' > "$w/cfg/providers.json"
cat > "$w/bin/gh" <<'GH'
#!/bin/bash
case "$*" in
  *rate_limit*) echo '{"remaining":4000,"limit":5000,"reset":0}' ;;
  *"/commits/main"*) echo '{"sha":"bbbb","commit":{"message":"head bbbb (#12)\nbody","committer":{"date":"2026-01-02T00:00:00Z"}}}' ;;
  *"/commits/rb"*"/pulls"*) echo '[{"number":13}]' ;;
  *"compare/aaaa...main"*)
    if [[ "$*" == *rebased* ]]; then
      echo '{"ahead_by":2,"status":"ahead","commits":[{"sha":"rb1","commit":{"message":"rebased change","committer":{"date":"2026-01-01T00:00:00Z"}}},
        {"sha":"bbbb","commit":{"message":"head bbbb (#12)","committer":{"date":"2026-01-02T00:00:00Z"}}}]}'
    else
      echo '{"ahead_by":2,"status":"ahead","commits":[{"sha":"c1","commit":{"message":"fix: one (#11)","committer":{"date":"2026-01-01T00:00:00Z"}}},
        {"sha":"bbbb","commit":{"message":"head bbbb (#12)","committer":{"date":"2026-01-02T00:00:00Z"}}}]}'
    fi ;;
  *"pulls?state=open"*) echo '[{"draft":true,"user":{"type":"User"}},{"draft":false,"user":{"type":"Bot"}}]' ;;
  *) exit 1 ;;
esac
GH
sed -i 's#\*"/commits/rb"\*"/pulls"\*#*"/commits/rb1/pulls"*#' "$w/bin/gh"
chmod +x "$w/bin/gh"
golden=tests/fixtures/perf/list.golden.json
got="$(PATH="$w/bin:$PATH" DEPLOYS_CONFIG="$w/cfg" DEPLOYS_DIR="$w/dd" HOME="$w" "$w/dd/deploys" fake json 2>"$w/err" | jq -S .)"
[ -n "$got" ] || { fail "list is printed" "$(head -3 "$w/err")"; echo "$fails failed"; exit 1; }
if [ -n "${BLESS:-}" ]; then printf '%s\n' "$got" > "$golden"; echo "wrote $golden"; exit 0; fi
if [ "$got" = "$(cat "$golden")" ]; then ok "fake json is the same as before the speed changes"
else fail "fake json is the same as before" "$(diff <(echo "$got") "$golden" | head -10)"; fi
n="$(printf '%s' "$got" | jq length)"; [ "$n" = 9 ] && ok "all 9 projects are in the list" || fail "all projects listed" "$n"
[ "$(printf '%s' "$got" | jq -r '.[] | select(.name=="e-bitb") | .noRepo')" = "the git host of bitbucket.org/acme/app is not supported" ] \
  && ok "an unsupported host is named" || fail "an unsupported host is named" "see the golden file"
[ "$fails" = 0 ] || { echo "$fails failed"; exit 1; }
echo "all ok"
