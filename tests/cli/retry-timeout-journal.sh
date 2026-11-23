# shellcheck shell=bash
# Sourced by tests/cli-tests.sh (itself sourced at the end of tests/script-tests.sh): retry timeout journal.
# e2e, O, E, tmp, run, fresh, expect come from script-tests.sh.

# 296: a Vercel read that met a 5xx is asked again; a write is not.
# The stand-in counts its runs in a file: vercel_call runs it in a $( ) subshell.
vn="$tmp/vercel-runs"
expect "296: vercel_call asks a GET again after a 503" \
  "$( (: > "$vn"; vercel() { echo x >> "$vn"; if [ "$(wc -l < "$vn")" -lt 2 ]; then echo "Error: 503 Service Unavailable" >&2; return 1; fi; echo '{"ok":true}'; }
       sleep() { :; }; vercel_team() { echo ""; }; vercel_call /v9/projects/web | jq -r .ok; wc -l < "$vn" | tr -d ' ') )" $'true\n2'
expect "296: but not a POST" \
  "$( (: > "$vn"; vercel() { echo x >> "$vn"; echo "Error: 503" >&2; return 1; }; sleep() { :; }; vercel_team() { echo ""; }
       vercel_call /v13/deployments --method POST 2>/dev/null; wc -l < "$vn" | tr -d ' ') )" "1"

# 297: a CLI call that hangs ends after DEPLOYS_CLI_TIMEOUT with 124 and a line.
printf '#!/bin/bash\nexec /bin/sleep 5\n' > "$tmp/hang"; chmod +x "$tmp/hang"
expect "297: cli_limit stops a hanging call" "$( (DEPLOYS_CLI_TIMEOUT=1 cli_limit "$tmp/hang" 2>&1; echo "rc=$?") | tr '\n' ' ')" "$tmp/hang: no answer after 1s (DEPLOYS_CLI_TIMEOUT) rc=124 "

# 307: a window.json that cannot be read is exit 2, not 1 ("closed").
fresh; echo '{"deny":' > "$e2e/config/window.json"
expect "307: window with a broken window.json is 2" "$(run "$O" "$E" window)" "2"
rm -f "$e2e/config/window.json"

# 301: costs without Vercel says that costs is Vercel's.
cv="$tmp/cv"; mkdir -p "$cv"; cp -R "$e2e/config" "$cv/config"; echo '{"enabled":["render"]}' > "$cv/config/providers.json"
out="$(env -u DEPLOYS_LIB PATH="$e2e/bin:/usr/bin:/bin" DEPLOYS_CONFIG="$cv/config" HOME="$e2e" NO_COLOR=1 /bin/bash ./deploys costs 2>&1)"; rc=$?
expect "301: costs without Vercel" "$rc:$(echo "$out" | grep -c "costs reads Vercel's charges")" "1:1"

# 250: meta is read with or without spaces after the colon.
expect "250: meta_flag and meta_str take spaces" \
  "$( (spaced_meta() { echo '{"id": "spaced", "label": "Spaced", "defaultOn": true, "keyEnv": ["SPACED_KEY"]}'; }
       meta_flag spaced defaultOn && echo on; meta_str spaced label; key_env_names spaced) )" $'on\nSpaced\nSPACED_KEY'

# 320: deploy-changed starts a backend before the Vercel frontend of the same repo.
fresh
run "$O" "$E" deploy-changed --yes >/dev/null
expect "320: Render (backend) before Vercel (frontend) of one repo" \
  "$(grep -E '^vercel api /v13/deployments|^curl POST https://api.render.com/v1/services/srv-1/deploys' "$e2e/calls.log" | cut -c1-4 | paste -sd, -)" "curl,verc"

# Journal of the terminal: a start, a rollback and a cancel are in it (the app writes its own, DEPLOYS_CALLER=app).
fresh; : > "$DEPLOYS_JOURNAL"
run "$O" "$E" deploy web >/dev/null
expect "journal: deploy <project> writes one line" "$(jq -sc 'map([.platform, .name, .result])' "$DEPLOYS_JOURNAL")" '[["Vercel","web","other"]]'
: > "$DEPLOYS_JOURNAL"; fresh
run "$O" "$E" rollback web >/dev/null
expect "journal: rollback writes a rollback line" "$(jq -sc 'map([.platform, .result])' "$DEPLOYS_JOURNAL")" '[["Vercel","rollback"]]'
: > "$DEPLOYS_JOURNAL"; fresh
DEPLOYS_CALLER=app run "$O" "$E" deploy web >/dev/null
expect "journal: DEPLOYS_CALLER=app adds no line (the app writes its own)" "$(wc -l < "$DEPLOYS_JOURNAL" | tr -d ' ')" "0"
: > "$DEPLOYS_JOURNAL"; fresh
run "$O" "$E" deploy-changed --yes >/dev/null
expect "journal: deploy-changed --yes writes a line for each start" "$(wc -l < "$DEPLOYS_JOURNAL" | tr -d ' ')" "2"
