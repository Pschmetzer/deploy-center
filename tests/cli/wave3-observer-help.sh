# shellcheck shell=bash
# Sourced by tests/cli-tests.sh (itself sourced at the end of tests/script-tests.sh): wave3 observer help.
# e2e, O, E, tmp, run, fresh, expect come from script-tests.sh.

# ---------- wave 3 (docs/IDEEN-6.md, section 3) ----------

# 387: every command that changes something is refused in observer mode, in every flag order.
fresh; bad=""
for c in "deploy web" "deploy web --wait" "deploy-changed --yes" "deploy-changed --when-green --yes" "deploy-changed --yes --when-green" \
         "vercel deploy web" "vercel deploy-json web" "vercel rollback web" "vercel cancel web x" "vercel map web me/app" \
         "vercel autodeploy-off web" "vercel autodeploy-on web" "render deploy api" "render rollback api" "render autodeploy-off --all" \
         "render autodeploy-on api" "autodeploy allow vercel web 2" "autodeploy revoke vercel web" "verify web" "guard" "autofix" \
         "autofix --only vercel web" "scan start me/app" "cloudflare selftest x --yes" "hook deploy x" "amplify on a"; do
  # shellcheck disable=SC2086  # the words of the command
  rc="$(DEPLOYS_READONLY=1 run "$O" "$E" $c)"
  [ "$rc:$(grep -c 'Observer mode' "$E")" = "1:1" ] || bad="$bad [$c: rc $rc]"
done
expect "387: observer mode refuses every write, in any flag order" "$bad" ""
expect "387: and nothing reached a platform" "$(grep -c 'POST\|--method' "$e2e/calls.log")" "0"

# 388/254: a name that would change an API path is refused by every command that takes one,
# before anything is asked.
fresh; bad=""
for c in "deploy" "verify" "risk" "watch" "logs" "open" "explain" "diff" "notes" "history" "ai explain" \
         "vercel deploy" "vercel status" "render deploy" "render status" "autofix --only vercel"; do
  for n in 'a/b' 'a?x' 'a%2F' 'vercel:a/b'; do
    # shellcheck disable=SC2086
    rc="$(run "$O" "$E" $c "$n")"
    [ "$rc:$(grep -c 'Invalid name or id' "$E")" = "1:1" ] || bad="$bad [$c $n: rc $rc]"
  done
done
expect "388: every command refuses / ? % in a name" "$bad" ""
expect "388: and asked no platform" "$(grep -c . "$e2e/calls.log")" "0"

# 318: Amplify ids are <appId>/<branch>: one / is taken for amplify, nowhere else.
expect "318: amplify takes <appId>/<branch>" \
  "$( (safe_name d1shop0001/main amplify) 2>/dev/null; echo $?; (safe_name amplify:d1shop0001/main) 2>/dev/null; echo $?)" $'0\n0'
expect "318: but not two / or one for another platform" \
  "$( (safe_name a/b/c amplify) 2>/dev/null; echo $?; (safe_name a/b) 2>/dev/null; echo $?; (safe_name render:a/b) 2>/dev/null; echo $?; (safe_name /main amplify) 2>/dev/null; echo $?)" $'1\n1\n1\n1'

# 309: a typo gets the nearest command, not the whole help.
expect "309: unknown command names the nearest" "$(run "$O" "$E" chaged; grep -c 'Unknown command "chaged". Did you mean: changed' "$E"; grep -c . "$O")" $'2\n1\n0'
# 312: the help lists each provider's commands, its own ones too.
expect "312: --help lists the provider commands" "$(run "$O" "$E" --help; grep -c '^Provider commands' "$O"; grep -Ec '^  vercel +list .* map' "$O")" $'0\n1\n1'
# A verb a provider does not have: refused with its commands (it used to print the help, exit 1).
expect "312: an unknown provider verb lists the provider's commands" "$(run "$O" "$E" render frob; grep -c 'Render has no command "frob". Its commands: list deploy' "$E")" $'1\n1'

# 392: every top-level command in the case labels is in --help (details and github-budget are
# the app's, not a person's).
run "$O" "$E" --help >/dev/null
missing="$(sed -n 's/^  "\([a-z][a-z-]*\)[ "].*/\1/p' ./deploys | sort -u | grep -vxE 'details|github-budget' \
  | while read -r c; do grep -qE "deploys $c([^a-z-]|\$)" "$O" || echo "$c"; done | paste -sd' ' -)"
expect "392: every command is in --help" "$missing" ""

# 315: enabling a provider that is not set up says the next step.
pe="$tmp/pe"; mkdir -p "$pe"; cp -R "$e2e/config" "$pe/config"
out="$(env -u DEPLOYS_LIB -u NETLIFY_AUTH_TOKEN PATH="$e2e/bin:/usr/bin:/bin" DEPLOYS_CONFIG="$pe/config" HOME="$e2e" NO_COLOR=1 /bin/bash ./deploys providers enable netlify 2>&1)"
expect "315: providers enable says what comes next" "$(echo "$out" | grep -c 'Next: pbpaste | deploys netlify set-key')" "1"

