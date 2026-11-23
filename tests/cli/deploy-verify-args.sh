# shellcheck shell=bash
# Sourced by tests/cli-tests.sh (itself sourced at the end of tests/script-tests.sh): deploy verify args.
# e2e, O, E, tmp, run, fresh, expect come from script-tests.sh.

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

