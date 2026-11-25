# shellcheck shell=bash
# Sourced by tests/cli-tests.sh (itself sourced at the end of tests/script-tests.sh): watch hooks tokens.
# e2e, O, E, tmp, run, fresh, expect come from script-tests.sh.

# 313: watch --timeout ends with its own code (4), never 1 (failed) or 3 (unreachable).
fresh; rm -f "$e2e/polls"
expect "313: watch --timeout stops with 4 and says so" "$(run "$O" "$E" watch api --timeout 6s; grep -c 'has not finished after 6s' "$E")" $'4\n1'
expect "313: --timeout takes a time" "$(run "$O" "$E" watch api --timeout soon; grep -c 'takes a time' "$E")" $'1\n1'
rm -f "$e2e/polls"
expect "313: watch shows how long it ran" "$(run "$O" "$E" watch api; grep -c '(6s)\|(12s)' "$O")" $'0\n2'

# 314: deploy without --wait says how to follow it.
fresh
expect "314: deploy says how to follow" "$(run "$O" "$E" deploy web; grep -c 'Follow it: deploys watch web dpl_new' "$O")" $'0\n1'
# 302: one project with --json is still one object.
fresh
expect "302: deploy --json of one project is one object" "$(run "$O" "$E" deploy web --json; jq -r 'type' "$O")" $'0\nobject'

# 336: open opens only web addresses.
p336="$tmp/p336"; mkdir -p "$p336/providers" "$p336/config"
printf '%s\n' '# shellcheck shell=bash' \
  'odd_meta() { echo '"'"'{"id":"odd","label":"Odd","noun":"app","defaultOn":true,"keyEnv":[],"keychain":null,"caps":{"off":false}}'"'"'; }' \
  'odd_ready() { return 0; }' 'odd_has() { echo "id-$1"; }' 'odd_json() { echo "[]"; }' 'odd_url() { echo "file:///etc/hosts"; }' > "$p336/providers/odd.sh"
out="$(env -u DEPLOYS_LIB PATH="$e2e/bin:/usr/bin:/bin" DEPLOYS_DIR="$p336" DEPLOYS_CONFIG="$p336/config" HOME="$e2e" /bin/bash ./deploys open odd:web 2>&1)"; rc=$?
expect "336: open refuses a file:// address" "$rc:$(echo "$out" | grep -c 'no web address')" "1:1"

# 334: a hook over http only to this machine, by its exact host.
bad=""
for u in http://localhost.example.com/h http://127.0.0.1.example.test/h http://localhostx/h http://user@evil.test/h; do
  ( hook_check_url "$u" ) >/dev/null 2>&1 && bad="$bad $u"
done
for u in http://localhost/h http://localhost:8080/h http://127.0.0.1:9000/h 'http://[::1]:8080/h' https://hooks.example.test/h; do
  ( hook_check_url "$u" ) >/dev/null 2>&1 || bad="$bad !$u"
done
expect "334: http only for localhost, 127.0.0.1 and ::1 exactly" "$bad" ""

# 333: the Coolify token goes over plain http only to this machine, or when allowed on purpose.
expect "333: http to another machine is refused, localhost and https are not" \
  "$( (CONFIG_DIR="$tmp/c333"; coolify_http_ok http://10.0.0.5:8000; echo $?; coolify_http_ok http://localhost:8000; echo $?; coolify_http_ok https://c.example.test; echo $?) )" $'1\n0\n0'
mkdir -p "$tmp/c333"; echo '{"url":"http://10.0.0.5:8000","allowHttp":true}' > "$tmp/c333/coolify.json"
expect "333: allowed for that address in coolify.json, or with the variable" \
  "$( (CONFIG_DIR="$tmp/c333"; coolify_http_ok http://10.0.0.5:8000; echo $?; coolify_http_ok http://10.0.0.6; echo $?; DEPLOYS_COOLIFY_ALLOW_HTTP=1 coolify_http_ok http://10.0.0.6; echo $?) )" $'0\n1\n0'
expect "333: the refusal names the way to allow it, before any request" \
  "$( (CONFIG_DIR="$tmp/c333b"; COOLIFY_URL=http://10.0.0.7 COOLIFY_TOKEN=t coolify_call GET /applications) 2>&1 | grep -c 'set-url http://10.0.0.7 --allow-http')" "1"

# 331: with an observers list and no known login, writes are refused (fail closed).
expect "331: observers listed and no login: observer" \
  "$( (CONFIG_DIR="$tmp/t331"; mkdir -p "$CONFIG_DIR"; TEAM_CACHE="$CONFIG_DIR/team-cache"; TEAM_REPOS="$CONFIG_DIR/team-repos"
       TEAM_OVERRIDES="$CONFIG_DIR/overrides.json"; echo '{"observers":["someone"]}' > "$TEAM_OVERRIDES"
       DEPLOYS_NO_GITHUB=1 team_effective | jq -r '.readonly | "\(.value) \(.from)"') )" "true observers listed, and gh cannot tell who you are (gh auth login)"
expect "331: without an observers list nothing changes" \
  "$( (CONFIG_DIR="$tmp/t331b"; mkdir -p "$CONFIG_DIR"; TEAM_CACHE="$CONFIG_DIR/team-cache"; TEAM_REPOS="$CONFIG_DIR/team-repos"
       TEAM_OVERRIDES="$CONFIG_DIR/overrides.json"; DEPLOYS_NO_GITHUB=1 team_effective | jq -r '.readonly.value') )" "false"

# 332: an approval of an older head of the PR does not count.
t332() {  # t332 <commit the review approved>
  ( c332="$1"; gh() { case "$*" in
           *commits/s1/pulls*) echo '[{"number":5,"html_url":"https://x/5","head":{"sha":"h2"},"labels":[]}]' ;;
           *pulls/5/reviews*) echo '[{"user":{"login":"rev"},"state":"APPROVED","submitted_at":"2026-01-01T00:00:00Z","commit_id":"'"$c332"'"}]' ;;
           *collaborators*) echo '{"role_name":"write"}' ;;
           *issues*) echo '[]' ;;
           *) return 1 ;;
         esac; }
    team_approvals me/app s1 dev | jq '.have | length' )
}
expect "332: a review of the PR's last commit counts, one of an older commit does not" "$(t332 h2; t332 h1)" $'1\n0'

# 390: doctor has no key twice (jq would keep the last one without a word).
fresh
run "$O" "$E" doctor >/dev/null
expect "390: doctor's keys are unique" "$(jq -c --stream 'select(length == 2) | .[0]' "$O" | sort | uniq -d | head -n 3)" ""

# 343: after --, --json is a value.
expect "343: after -- nothing is an option" "$(run "$O" "$E" window -- --json; grep -c 'No deploy window set' "$O")" $'0\n1'

