#!/bin/bash
# healthcheck.sh — the image's HEALTHCHECK. Exit 0 when the image can do its work, 1 with one line that says why
# (`docker inspect --format '{{json .State.Health}}'` shows it). It reads only and never asks the network:
# a platform that is down must not make the container "unhealthy" and get it restarted in a loop.
#
# Checks: the CLI runs and says its version; jq and curl are there; the providers folder holds the hosts;
# and, in the cron variant (DEPLOYS_HEARTBEAT_FILE is set), the scheduler wrote its heartbeat lately.
#
# Env: DEPLOYS                  the CLI (default: deploys)
#      DEPLOYS_DIR              the providers folder's parent (set by the image)
#      DEPLOYS_HEARTBEAT_FILE   the scheduler's heartbeat (seconds since 1970); unset: not checked
#      DEPLOYS_HEARTBEAT_MAX    how old it may be, in seconds (default 300)
DEPLOYS="${DEPLOYS:-deploys}"
bad() { echo "unhealthy: $1"; exit 1; }

command -v "$DEPLOYS" >/dev/null 2>&1 || bad "$DEPLOYS is not installed"
command -v jq >/dev/null 2>&1 || bad "jq is missing"
command -v curl >/dev/null 2>&1 || bad "curl is missing"
v="$("$DEPLOYS" --version 2>/dev/null </dev/null)" && [ -n "$v" ] || bad "$DEPLOYS --version does not answer"
if [ -n "${DEPLOYS_DIR:-}" ]; then
  ls "$DEPLOYS_DIR"/providers/*.sh >/dev/null 2>&1 || bad "no providers in $DEPLOYS_DIR/providers"
fi
if [ -n "${DEPLOYS_HEARTBEAT_FILE:-}" ]; then
  max="${DEPLOYS_HEARTBEAT_MAX:-300}"; case "$max" in ''|*[!0-9]*) max=300 ;; esac
  beat="$(cat "$DEPLOYS_HEARTBEAT_FILE" 2>/dev/null)"
  case "$beat" in ''|*[!0-9]*) bad "the scheduler has not written a heartbeat" ;; esac
  now="${HEALTHCHECK_NOW:-$(date +%s)}"
  [ $((now - beat)) -le "$max" ] || bad "the scheduler's last heartbeat is $((now - beat)) s old (more than $max)"
fi
echo "healthy: $v"
