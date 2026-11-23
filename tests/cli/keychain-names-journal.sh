# shellcheck shell=bash
# Sourced by tests/cli-tests.sh (itself sourced at the end of tests/script-tests.sh): keychain names journal.
# e2e, O, E, tmp, run, fresh, expect come from script-tests.sh.

# 269: a locked keychain is named for an opt-in provider too, not "no token".
fresh; kp="$tmp/kc"; mkdir -p "$kp"; cp -R "$e2e/config" "$kp/config"; echo '{"enabled":["vercel","netlify"]}' > "$kp/config/providers.json"
printf '#!/bin/bash\nexit 36\n' > "$e2e/bin/security"
out="$(env -u DEPLOYS_LIB PATH="$e2e/bin:/usr/bin:/bin" E2E="$e2e" DEPLOYS_CONFIG="$kp/config" DEPLOYS_VERCEL_TEAM=team_test HOME="$e2e" NO_COLOR=1 /bin/bash ./deploys changed 2>&1 </dev/null)"; rc=$?
expect "keychain locked (Netlify): changed fails and says why" "$rc:$(echo "$out" | grep -c 'could not read netlify: Netlify: the keychain could not be read')" "1:1"
printf '#!/bin/bash\nexit 44\n' > "$e2e/bin/security"

# 273: two ids of one name on one platform: the ids are named, not "render:api" again.
echo '[{"name":"api","platform":"render","id":"srv-a"},{"name":"api","platform":"render","id":"srv-b"}]' > "$tmp/names2.json"
expect "lookup: two of one name on one platform names the ids" \
  "$( (CONFIG_DIR="$tmp/n2"; mkdir -p "$CONFIG_DIR"; cp "$tmp/names2.json" "$CONFIG_DIR/names.json"; lookup api) 2>&1 | grep -c 'srv-a, srv-b')" "1"

# 275: names that are gone from a provider's list leave `names` too.
expect "remember_names: a deleted project goes" \
  "$( (CONFIG_DIR="$tmp/n3"; mkdir -p "$CONFIG_DIR"; echo '[{"name":"old"},{"name":"web"}]' | remember_names vercel
       echo '[{"name":"web"}]' | remember_names vercel; echo '[{"name":"api","id":"srv-1"}]' | remember_names render; paste -sd, "$CONFIG_DIR/names") )" "api,web"

# 278: the journal writes a provider's label, not its id.
expect "journal: a provider's label" "$( (DEPLOYS_JOURNAL="$tmp/j.jsonl"; journal_add netlify shop other x; jq -r .platform "$tmp/j.jsonl") )" "Netlify"

# 279: a key with a CR or spaces around it is trimmed; one with a space inside is refused.
: > "$CALLS"
printf 'sk-ant-abc\r\n' | env -u DEPLOYS_LIB PATH="$tmp/bin:/usr/bin:/bin" /bin/bash ./deploys ai set-key >/dev/null 2>&1
expect "ai set-key: a trailing CR is trimmed" "$(grep -c 'security -i' "$CALLS"):$(grep -c $'\r' "$CALLS")" "1:0"
: > "$CALLS"
out="$(printf 'sk-ant-a b\n' | env -u DEPLOYS_LIB PATH="$tmp/bin:/usr/bin:/bin" /bin/bash ./deploys ai set-key 2>&1)"; rc=$?
expect "ai set-key: a space inside is refused, nothing saved" "$rc:$(grep -c security "$CALLS")" "1:0"

# 271: the guard counts as on only when launchd has the job, and a dropped job is loaded again.
mkdir -p "$tmp/g271/agents" "$tmp/g271/bin"; touch "$tmp/g271/agents/app.deploycenter.guard.plist"
printf '#!/bin/bash\necho "launchctl $*" >> "$CALLS"\n[ "$1" = print ] && exit 113\nexit 0\n' > "$tmp/g271/bin/launchctl"; chmod +x "$tmp/g271/bin/launchctl"
: > "$CALLS"
expect "guard: a job file launchd does not have is off" \
  "$( (PATH="$tmp/g271/bin:$PATH" DEPLOYS_LAUNCH_DIR="$tmp/g271/agents"; guard_scheduled && echo on || echo off) )" "off"
( PATH="$tmp/g271/bin:$PATH" DEPLOYS_LAUNCH_DIR="$tmp/g271/agents"; guard_reload ) 2>/dev/null
expect "guard: a dropped job is loaded again" "$(grep -c 'launchctl bootstrap' "$CALLS")" "1"

# 277: without `column`, tables still come out (awk), aligned.
mkdir -p "$tmp/nocol"; ln -sf "$(command -v awk)" "$tmp/nocol/awk"
expect "table: works without column" "$(printf 'a\tbb\tc\nxxx\ty\tz\n' | PATH="$tmp/nocol" table)" $'a    bb  c\nxxx  y   z'

# 272: "p:name" in ignore leaves out only that platform's project.
fresh; run "$O" "$E" changed --json >/dev/null
run "$O" "$E" ignore vercel:web >/dev/null
expect "ignore vercel:web: web is left out, api stays" "$(run "$O" "$E" changed --json; jq -c 'map(.name)' "$O")" $'0\n["api"]'
run "$O" "$E" ignore render:web >/dev/null; run "$O" "$E" ignore vercel:web --undo >/dev/null
expect "ignore render:web does not hide vercel web" "$(run "$O" "$E" changed --json; jq -c 'map(.name) | sort' "$O")" $'0\n["api","web"]'
run "$O" "$E" ignore render:web --undo >/dev/null

# 291: a name that is a group and a project is refused; group:<name> is the group.
printf '%s\n' '# shellcheck shell=bash' 'team_gate() { [ -z "${5:-}" ] || echo "$5"; }' \
  'team_group() { case "$1" in web|shop) echo web ;; esac; }' 'team_observer_from() { :; }' \
  'team_repos_json() { return 1; }' 'team_ignored() { return 1; }' > "$tmp/team-stub.sh"
fresh
expect "deploy: a group and a project of one name is refused" \
  "$(DEPLOYS_TEAM_LIB="$tmp/team-stub.sh" run "$O" "$E" deploy web; started; grep -c 'deploy group:web' "$E")" $'1\n0\n1'
expect "deploy group:shop starts the group" "$(DEPLOYS_TEAM_LIB="$tmp/team-stub.sh" run "$O" "$E" deploy group:shop; started; grep -c '^Group shop: web' "$O")" $'0\n1\n1'
expect "deploy group:nope is an error" "$(DEPLOYS_TEAM_LIB="$tmp/team-stub.sh" run "$O" "$E" deploy group:nope; grep -c 'No group named' "$E")" $'1\n1'

