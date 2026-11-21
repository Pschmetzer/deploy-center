# shellcheck shell=bash
# deploys watch: follow one deploy (or several with --and) until it is live or failed. Kept out of `deploys`
# (round 12 B, items 13-19). Sourced by deploys; uses resolve, duration_s, watch_line, watch_final, watch_took,
# trap_fn, exit_rm, die and the <provider>_status / _latest / _url functions from there.
#
# watch <project> [<deploy id>] [--preview] [--timeout 30m] [--interval 6] [--quiet] [--json]
# Exit 0 live, 1 failed or canceled, 3 the platform could not be asked (or its answer not read) five times in a
# row, or refused the key at once (401/403), 4 --timeout passed before it finished.
# --json: one line at the end, {"project","id","phase","state","exit"}; "phase" tells failed from canceled.
# --quiet: no progress lines, only the result and errors.

WATCH_USAGE='Usage: deploys watch <project> [<deploy id>] [--preview] [--timeout 30m] [--interval 6] [--quiet] [--json]'
WATCH_PARALLEL=6

# Ends the children of `watch --and` and removes their folder (Ctrl-C, kill, or the normal end).
watch_cleanup() {  # watch_cleanup <folder>
  local j
  for j in $(jobs -p 2>/dev/null); do kill "$j" 2>/dev/null || true; done
  rm -rf "$1"
}

# One error line of the platform, for people: one line, 200 characters, keys and tokens masked.
watch_errline() {  # watch_errline <file>
  local l
  l="$(tail -n 1 "$1" 2>/dev/null | tr '\r\t' '  ' | cut -c1-200)"
  if declare -F af_mask >/dev/null 2>&1; then l="$(printf '%s' "$l" | af_mask 2>/dev/null)" || l=""; fi
  printf '%s' "$l"
}

# A key that is wrong stays wrong: waiting five tries for it only delays the message.
watch_auth_error() { [[ "$1" =~ (^|[^0-9])(401|403)([^0-9]|$) ]] || [[ "$1" == *[Uu]nauthorized* ]] || [[ "$1" == *[Ff]orbidden* ]]; }
watch_rate_limited() { [[ "$1" =~ (^|[^0-9])429([^0-9]|$) ]] || [[ "$1" == *"rate limit"* ]]; }

watch_main() {
  local p="${1:?$WATCH_USAGE}" did="" pv="" maxw="" interval=6 quiet="" json=""
  shift
  case " $* " in
    *" --and "*) watch_many "$p" "$@"; return ;;
  esac
  while [ $# -gt 0 ]; do
    case "$1" in
      --preview) pv=1 ;;
      --quiet|-q) quiet=1 ;;
      --json) json=1 ;;
      --timeout) maxw="$(duration_s "${2:-}")" || die "--timeout takes a time: 90s, 30m or 2h"; shift ;;
      --interval) [[ "${2:-}" =~ ^[0-9]+$ ]] && [ "$((10#$2))" -ge 2 ] && [ "$((10#$2))" -le 300 ] || die "--interval takes seconds, 2 to 300"; interval="$((10#$2))"; shift ;;
      -*) die "Unknown option $1. $WATCH_USAGE" ;;
      *) did="$1" ;;
    esac; shift
  done
  resolve "$p"
  local plat="$PLAT" first=1 misses=0 waited=0 t0=$SECONDS poll="$interval" raw s id ph st u errf err backoff=0 base="$interval"
  errf="$(mktemp)"; trap_fn exit_rm "$errf"
  # finish <exit code>: the JSON line (when asked) and the exit.
  watch_finish() {
    [ "$json" != 1 ] || jq -nc --arg p "$p" --arg i "${id:-}" --arg ph "${ph:-}" --arg st "${st:-}" --argjson x "$1" \
      '{project:$p, id:$i, phase:$ph, state:$st, exit:$x}'
    exit "$1"
  }
  while :; do
    if [ -n "$maxw" ] && [ "$waited" -ge "$maxw" ]; then
      echo "${ERED}Error:${EPLAIN} $p has not finished after $(watch_took "$waited") (--timeout); it may still go live: deploys watch $p${did:+ $did}" >&2
      watch_finish 4
    fi
    : > "$errf"
    if [ -n "$did" ]; then raw="$("${plat}_status" "$PID" "$did" 2>"$errf")" || raw=""
    else raw="$("${plat}_latest" "$PID" ${pv:+--preview} 2>"$errf")" || raw=""; fi
    err="$(watch_errline "$errf")"
    s="$(watch_line "$raw")"
    if [ -z "$s" ]; then
      # A key the platform refuses is not a network blip: say so now (exit 3), do not try five times.
      if watch_auth_error "$err"; then
        echo "${ERED}Error:${EPLAIN} $plat refused the key ($err); check it with: deploys $plat set-key. The deploy itself may be fine." >&2
        watch_finish 3
      fi
      # A network blip is not a failed deploy: try again, and give up only after five in a row.
      # An answer whose phase cannot be read counts the same: it must never mean "wait for ever".
      misses=$((misses + 1))
      if [ -n "$raw" ]; then printf '%s  (could not read the answer of %s, try %s of 5)%s\n' "$(date +%H:%M:%S)" "$plat" "$misses" "${err:+: $err}" >&2
      else printf '%s  (could not ask %s, try %s of 5)%s\n' "$(date +%H:%M:%S)" "$plat" "$misses" "${err:+: $err}" >&2; fi
      [ "$misses" -lt 5 ] || { echo "Error: ${ERED}could not reach $plat; the deploy itself may be fine${EPLAIN}" >&2; watch_finish 3; }
      # After a 429 the next asks wait longer (doubling, at most a minute), not the same few seconds again.
      if watch_rate_limited "$err"; then backoff=$((backoff == 0 ? base * 2 : backoff * 2)); [ "$backoff" -le 60 ] || backoff=60; poll="$backoff"; fi
    else
      misses=0; backoff=0; poll="$base"
      IFS=$'\t' read -r id ph st <<<"$s"
      [ "$id" != "none" ] || die "No deploy of $p found"
      if [ "$first" = 1 ] && [ -z "$did" ] && watch_final "$ph"; then
        [ "$json" = 1 ] || echo "Nothing is building for $p. The newest deploy ($id) is $st."
        case "$ph" in ready) watch_finish 0;; *) watch_finish 1;; esac
      fi
      first=0
      # The time since watch began, once there is some.
      [ -n "$quiet" ] || [ "$json" = 1 ] || printf '%s  %s%s\n' "$(date +%H:%M:%S)" "$st" "$([ "$waited" = 0 ] || echo "  ($(watch_took "$waited"))")"
      case "$ph" in
        ready) u="$( ("${plat}_url" "$PID") 2>/dev/null || true)"; [ "$json" = 1 ] || case "$u" in http*) echo "Live: $u" ;; esac; watch_finish 0 ;;
        failed|canceled) [ "$json" = 1 ] || [ -z "$quiet" ] || echo "$p: $st" >&2; watch_finish 1 ;;
      esac
    fi
    # A few seconds of jitter, so many watchers do not ask a platform in the same second.
    sleep "$((poll + RANDOM % 3))"; waited=$((waited + poll)); [ $((SECONDS - t0)) -le "$waited" ] || waited=$((SECONDS - t0))
    [ "$waited" -lt 120 ] || [ "$poll" -ge 15 ] || [ "$base" -ge 15 ] || { base=15; [ "$backoff" -gt 0 ] || poll=15; }
  done
}

# watch a --and b --and c: each followed at the same time (at most $WATCH_PARALLEL at once), every line starting with its
# project; the exit code is 1 if any failed, else 4 if any timed out, else 3 if any could not be asked, else 0.
watch_many() {
  local p="$1" wnames wshared wprev wa wd wi wn c wrc=0 n
  shift
  wnames=("$p"); wshared=()
  while [ $# -gt 0 ]; do
    case "$1" in
      --and) [ -n "${2:-}" ] || die "--and takes a project name"; case "$2" in -*) die "--and takes a project name";; esac; wnames+=("$2"); shift ;;
      *) wshared+=("$1") ;;
    esac; shift
  done
  # A deploy id belongs to one project: handing it to every project would watch the wrong (or no) deploy.
  wprev=""
  for wa in ${wshared[@]+"${wshared[@]}"}; do
    case "$wa" in -*) ;; *) case "$wprev" in --timeout|--interval) ;; *) die "A deploy id belongs to one project; with --and, watch the newest deploy of each (drop \"$wa\")." ;; esac ;; esac
    wprev="$wa"
  done
  [ "${#wnames[@]}" -le 1 ] || case " ${wshared[*]-} " in *" --json "*) die "--json follows one project; drop --and" ;; esac
  wd="$(mktemp -d)"
  # Ctrl-C or a kill ends the children and removes the folder; the normal end removes it too.
  trap_fn watch_cleanup "$wd"
  trap 'exit 130' INT; trap 'exit 143' TERM
  wi=0
  for wn in "${wnames[@]}"; do
    wi=$((wi + 1))
    # At most WATCH_PARALLEL watchers at once (bash 3.2 has no wait -n): the rest start as places free up.
    while n="$(jobs -r | wc -l)"; [ "$n" -ge "$WATCH_PARALLEL" ]; do sleep 0.2; done
    ( "$SELF" watch "$wn" ${wshared[@]+"${wshared[@]}"} 2>&1; echo $? > "$wd/$wi" ) | WNAME="$wn" perl -pe 'BEGIN { $| = 1 } s/^/[$ENV{WNAME}] /' &
  done
  wait
  for ((wi = 1; wi <= ${#wnames[@]}; wi++)); do
    c="$(cat "$wd/$wi" 2>/dev/null || echo 3)"
    case "$c" in 0) ;; 1) wrc=1 ;; 4) [ "$wrc" = 1 ] || wrc=4 ;; *) [ "$wrc" = 1 ] || [ "$wrc" = 4 ] || wrc=3 ;; esac
  done
  exit "$wrc"
}
