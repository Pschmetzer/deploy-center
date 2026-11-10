# shellcheck shell=bash
# Sourced by tests/script-tests.sh at its end: the e2e stand-ins (run, fresh, $e2e, $O, $E) and
# expect/ok/fail come from there. Fixes from docs/IDEEN-6.md, section 3, by number.
# shellcheck disable=SC2154,SC2034  # e2e, O, E, tmp come from script-tests.sh; variables set for the functions called

fresh; export RENDER_API_KEY=rnd_test

# 259: deploy --wait passes on watch's "platform not reachable" (3) instead of "did not go live" (1).
expect "deploy --wait: an unreachable platform is exit 3, not 1" \
  "$(run "$O" "$E" deploy web --wait; grep -c 'did not go live' "$E"; grep -c 'could not follow web' "$E")" $'3\n0\n1'

# 270: no provider on and set up: an error pointing to `deploys providers`, never "all up to date".
np="$tmp/noprov"; mkdir -p "$np"; cp -R "$e2e/config" "$np/config"; echo '{"enabled":[]}' > "$np/config/providers.json"
out="$(env -u DEPLOYS_LIB PATH="$e2e/bin:/usr/bin:/bin" E2E="$e2e" DEPLOYS_CONFIG="$np/config" HOME="$e2e" NO_COLOR=1 /bin/bash ./deploys changed 2>&1 </dev/null)"; rc=$?
expect "no provider on: changed fails and says where to look" "$rc:$(echo "$out" | grep -c 'deploys providers'):$(echo "$out" | grep -c 'every project is on its newest')" "1:1:0"

# 284: a misspelt --platform is refused before anything is read.
fresh
expect "changed --platform: a typo is refused" "$(run "$O" "$E" changed --platform vercle; grep -c 'takes one of' "$E"; grep -c '^vercel api' "$e2e/calls.log")" $'1\n1\n0'

# 281/282/293: logs 0, history past 100, open with a stray argument.
expect "logs: 0 lines is refused (not the whole log)" "$(run "$O" "$E" logs web 0; grep -c '1 or more' "$E")" $'1\n1'
expect "history: more than 100 is refused" "$(run "$O" "$E" history web 500; grep -c 'from 1 to 100' "$E")" $'1\n1'
expect "open: only --dashboard is taken" "$(run "$O" "$E" open web foo; grep -c 'Unknown option foo' "$E")" $'1\n1'

# 257: risk and verify take "p:name" like the other commands.
fresh
expect "risk: vercel:web is found" "$(run "$O" "$E" risk vercel:web --json; jq -r '"\(.project) \(.platform)"' "$O")" $'0\nweb vercel'
expect "verify: vercel:web is checked" "$(run "$O" "$E" verify vercel:web --json; jq -c '{project, healthy}' "$O")" $'0\n{"project":"web","healthy":true}'

# 258: an error is exit 3, never 1 ("rolled back").
expect "verify: an unknown project is exit 3" "$(run "$O" "$E" verify nosuch --no-rollback)" "3"

# 285: with --path, a 404 fails the check (a missing /health must not pass); without it, it does not.
fresh
expect "verify --path: 404 is a failure" "$(SITE=notfound run "$O" "$E" verify web --path /health --no-rollback)" "2"
expect "verify without --path: 404 is not" "$(SITE=notfound run "$O" "$E" verify web --no-rollback)" "0"

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
