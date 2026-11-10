#!/bin/bash
# A stand-in for the aws CLI, as providers/amplify.sh calls it: logs "aws <service> <command> ..."
# to $CALLS and answers from $FIXTURES/<p>/AWS_<service>_<command>[_<app id>[_<job id>]].json,
# the most specific file first. --output, --profile and --region are left out of the log.
# No fixture: the CLI's error on stderr and exit 254. Never reaches AWS.
[ "${1:-}" = --version ] && { echo "aws-cli/2.0.0 fake"; exit 0; }
args=(); skip=0; app=""; job=""; prev=""
for a in "$@"; do
  [ "$skip" = 1 ] && { skip=0; prev="$a"; continue; }
  case "$a" in --output|--profile|--region) skip=1; prev="$a"; continue ;; esac
  case "$prev" in --app-id) app="$a" ;; --job-id) job="$a" ;; esac
  args+=("$a"); prev="$a"
done
echo "aws ${args[*]}" >> "${CALLS:-/dev/null}"
svc="${args[0]:-}"; cmd="${args[1]:-}"
[ "$svc $cmd" = "configure get" ] && exit 1
for k in "${svc}_${cmd}${app:+_$app}${job:+_$job}" "${svc}_${cmd}${app:+_$app}" "${svc}_${cmd}"; do
  for f in "${FIXTURES:?}"/*/"AWS_$(printf '%s' "$k" | sed 's/[^A-Za-z0-9.-]/_/g').json"; do
    [ -f "$f" ] && { cat "$f"; exit 0; }
  done
done
echo "An error occurred (NotFoundException) when calling $cmd: no fixture" >&2
exit 254
