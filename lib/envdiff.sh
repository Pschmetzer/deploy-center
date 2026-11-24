# shellcheck shell=bash
# lib/envdiff.sh — `deploys env-diff <project> [--json]`: which environment variable NAMES exist in production but not in
# preview, and the other way round. Names only: a value never leaves the provider function (it keeps just key and targets,
# inside the same jq pipe as the request) and is not printed, journaled or written anywhere.
# A provider opts in with `<p>_env_names <id>`, which prints [{"key":"NAME","targets":["production","preview",...]}].
# Hosts without it (no preview/production split, or no API for it) say so. Sourced by deploys; uses resolve, die.

# envdiff_from: stdin is the provider's [{key, targets}]. Only keys and targets are read.
envdiff_from() {
  jq -c '
    [ .[] | {key:(.key | tostring), targets:((.targets // []) | if type == "array" then . else [.] end | map(tostring))} ] as $e
    | ([ $e[] | select(.targets | index("production")) | .key ] | unique) as $prod
    | ([ $e[] | select(.targets | index("preview")) | .key ] | unique) as $prev
    | {exposed:true, production:($prod | length), preview:($prev | length),
       onlyProduction:($prod - $prev), onlyPreview:($prev - $prod), both:([ $prod[] | select(. as $k | $prev | index($k)) ] | length),
       same:(($prod - $prev | length) == 0 and ($prev - $prod | length) == 0)}'
}

envdiff_print() {  # stdin: envdiff JSON; argument: the project
  jq -r --arg p "$1" '
    "Environment variable names of \($p) (values are never read here)",
    "  production: \(.production), preview: \(.preview), in both: \(.both)",
    (if .same then "  The same names in production and preview." else empty end),
    (if (.onlyProduction | length) > 0 then "  Only in production (a preview build may miss them):", (.onlyProduction[] | "    - \(.)") else empty end),
    (if (.onlyPreview | length) > 0 then "  Only in preview:", (.onlyPreview[] | "    - \(.)") else empty end)'
}

envdiff_main() {
  local p="" names out
  while [ "$#" -gt 0 ]; do
    case "$1" in
      -*) die "Unknown option $1. Usage: deploys env-diff <project> [--json]" ;;
      *) [ -z "$p" ] || die "Usage: deploys env-diff <project> [--json]"; p="$1" ;;
    esac
    shift
  done
  [ -n "$p" ] || die_usage "Usage: deploys env-diff <project> [--json]"
  safe_name "$p"; resolve "$p"
  if ! declare -F "${PLAT}_env_names" >/dev/null; then
    if [ "${json:-0}" = 1 ]; then jq -nc --arg p "$PNAME" --arg pl "$PLAT" '{project:$p, platform:$pl, exposed:false}'
    else echo "$(meta_str "$PLAT" label) does not list environment variables for preview and production here: nothing to compare."; fi
    return 0
  fi
  names="$("${PLAT}_env_names" "$PID")" || die "The environment variable names of $PNAME could not be read."
  out="$(echo "$names" | envdiff_from)" || die "The environment variable names of $PNAME could not be read (unexpected answer)."
  out="$(echo "$out" | jq -c --arg p "$PNAME" --arg pl "$PLAT" '{project:$p, platform:$pl} + .')"
  if [ "${json:-0}" = 1 ]; then echo "$out" | jq .; else echo "$out" | envdiff_print "$PNAME"; fi
  [ "$(echo "$out" | jq -r .same)" = true ] || return 1
}
