#!/bin/bash
# scheduler.sh — runs read-only jobs on a schedule inside the cron variant of the image (Dockerfile.cron). A small
# loop instead of cron: no extra package, no root, one process that logs to stdout and writes a heartbeat for the
# HEALTHCHECK. It cannot deploy: a job is `deploys <reading command>` or one of the integrations, nothing else,
# and anything with --yes is refused when the file is read, before the first job runs.
#
#   scheduler.sh [--jobs FILE] [--tick SECONDS] [--once] [--check] [--ticks N]
#
#   --jobs FILE   the schedule (default $DEPLOYS_JOBS, then /config/jobs.conf)
#   --once        run every job once now, whatever its schedule, and exit (1 if one failed)
#   --check       read and validate the file, print the plan, run nothing
#   --tick N      seconds between looks at the clock (default 30)
#   --ticks N     stop after N looks (tests; default: never)
#
# One job per line, `#` starts a comment. Times are UTC.
#
#   every 30m|6h|1d                       a first run at once, then after that long
#   daily 07:30                           once a day, from that minute on
#   weekly mon 07:30                      once a week (mon tue wed thu fri sat sun)
#
# followed by an optional `out=FILE` (the job's output is written there, atomically) and the job:
#
#   deploys changed --json                what `deploys` reads: changed status plan list digest notes history risk
#                                         doctor explain ledger simulate metrics costs window freeze (listing only)
#   statuspage --config /config/statuspage.json --out /data/status       integrations/statuspage/statuspage.sh
#   badges /data/badges        badge-stats /data/badges        report --out /data/reports
#
# Words are split at spaces: no quotes, pipes or redirects. A job that takes longer than DEPLOYS_JOB_TIMEOUT seconds
# (default 600, needs `timeout`) is stopped. A failed job is logged and tried again at its next time.
#
# Env: DEPLOYS_INTEGRATIONS   where the integrations are (default /opt/deploy-center/integrations)
#      DEPLOYS_HEARTBEAT_FILE the heartbeat file (default /tmp/scheduler.heartbeat)
#      DEPLOYS_PING_URL       an https URL asked (GET) after each job that worked: a dead man's switch
#      SCHEDULER_NOW, SCHEDULER_STEP   a fixed clock and how far it moves per look (tests)
set -eo pipefail   # no -u: bash 3.2 counts an empty array as unset
integ="${DEPLOYS_INTEGRATIONS:-/opt/deploy-center/integrations}"
hb="${DEPLOYS_HEARTBEAT_FILE:-/tmp/scheduler.heartbeat}"
jobs="${DEPLOYS_JOBS:-/config/jobs.conf}"
tick=30 once=0 check=0 ticks=0
while [ $# -gt 0 ]; do
  case "$1" in
    --jobs) jobs="${2:?--jobs FILE}"; shift ;;
    --tick) tick="${2:?--tick SECONDS}"; shift ;;
    --ticks) ticks="${2:?--ticks N}"; shift ;;
    --once) once=1 ;;
    --check) check=1 ;;
    -h|--help) sed -n '2,/^set /p' "$0" | sed -e '$d' -e 's/^# \{0,1\}//'; exit 0 ;;
    *) echo "Unknown option $1. See --help." >&2; exit 1 ;;
  esac
  shift
done
for v in "$tick" "$ticks"; do case "$v" in ''|*[!0-9]*) echo "--tick and --ticks take numbers." >&2; exit 1 ;; esac; done
[ -f "$jobs" ] || { echo "No schedule at $jobs. Start from integrations/docker/jobs.example.conf." >&2; exit 1; }
virtual="${SCHEDULER_NOW:-}"
clock() { if [ -n "$virtual" ]; then echo "$virtual"; else date +%s; fi; }
stamp() { jq -nr --argjson t "$1" '$t | strftime("%Y-%m-%dT%H:%M:%SZ")'; }

# What `deploys` may be asked for here: reading commands only.
allowed_cli=" changed status plan list digest notes history risk doctor explain ledger simulate metrics costs window freeze "

kinds=() specs=() outs=() cmds=() lasts=()   # parallel arrays, one slot per job
n=0 lineno=0 problems=0
while IFS= read -r line || [ -n "$line" ]; do
  lineno=$((lineno + 1))
  line="${line%%#*}"
  set -f; set -- $line; set +f   # words on purpose, no globbing
  [ $# -gt 0 ] || continue
  bad() { echo "$jobs:$lineno: $1" >&2; problems=$((problems + 1)); }
  kind="$1" spec="" ; shift
  case "$kind" in
    every)
      case "${1:-}" in [0-9]*[mhd]) ;; *) bad "every takes a time like 30m, 6h or 1d"; continue ;; esac
      num="${1%[mhd]}"; unit="${1#"$num"}"
      case "$num" in ''|*[!0-9]*|0) bad "every: $1 is not a number of minutes, hours or days"; continue ;; esac
      case "$unit" in m) secs=$((num * 60)) ;; h) secs=$((num * 3600)) ;; *) secs=$((num * 86400)) ;; esac
      [ "$secs" -ge 60 ] || { bad "every: a minute at least"; continue; }
      spec="$secs"; shift ;;
    daily)
      case "${1:-}" in [0-2][0-9]:[0-5][0-9]) ;; *) bad "daily takes a time like 07:30"; continue ;; esac
      [ "${1%%:*}" -le 23 ] || { bad "daily: $1 is not a time"; continue; }
      spec="${1%%:*}${1##*:}"; shift ;;
    weekly)
      case "${1:-}" in mon) d=1 ;; tue) d=2 ;; wed) d=3 ;; thu) d=4 ;; fri) d=5 ;; sat) d=6 ;; sun) d=7 ;; *) bad "weekly takes a day (mon ... sun) and a time"; continue ;; esac
      case "${2:-}" in [0-2][0-9]:[0-5][0-9]) ;; *) bad "weekly takes a day and a time like 07:30"; continue ;; esac
      [ "${2%%:*}" -le 23 ] || { bad "weekly: $2 is not a time"; continue; }
      spec="$d ${2%%:*}${2##*:}"; shift 2 ;;
    *) bad "a job starts with every, daily or weekly, not \"$kind\""; continue ;;
  esac
  out=""
  case "${1:-}" in out=*) out="${1#out=}"; shift ;; esac
  [ $# -gt 0 ] || { bad "no job after the time"; continue; }
  for w in "$@"; do case "$w" in --yes|-y|--yes=*) bad "--yes is refused: this scheduler only reads"; continue 2 ;; esac; done
  case "$1" in
    deploys)
      case "$allowed_cli" in *" ${2:-} "*) ;; *) bad "deploys ${2:-}: not allowed here, the scheduler runs reading commands only"; continue ;; esac
      # A reading command can still change something with a flag or a sub-command: freeze clear, doctor --fix, digest --post.
      for w in "$@"; do case "$w" in --fix|--post|--notify|--apply|--write|--install|--force|--set|--clear|--remove|--delete) bad "deploys ${2:-} $w: not allowed here, the scheduler only reads"; continue 2 ;; esac; done
      case "${2:-}:${3:-}" in
        freeze:|freeze:status|freeze:list|freeze:check|freeze:--json) ;;
        freeze:*) bad "deploys freeze ${3:-}: only freeze, freeze status or freeze --json are allowed here"; continue ;;
      esac ;;
    statuspage|badges|badge-stats|report) ;;
    *) bad "unknown job \"$1\" (deploys, statuspage, badges, badge-stats or report)"; continue ;;
  esac
  kinds[n]="$kind"; specs[n]="$spec"; outs[n]="$out"; cmds[n]="$*"; lasts[n]=0
  n=$((n + 1))
done < "$jobs"
[ "$problems" = 0 ] || { echo "$problems problem(s) in $jobs; nothing was run." >&2; exit 1; }
[ "$n" -gt 0 ] || { echo "No jobs in $jobs." >&2; exit 1; }

if [ "$check" = 1 ]; then
  i=0; while [ "$i" -lt "$n" ]; do echo "job $((i + 1)): ${kinds[$i]} ${specs[$i]} -> ${cmds[$i]}${outs[$i]:+ (out=${outs[$i]})}"; i=$((i + 1)); done
  exit 0
fi

# One job: its words become the command, never a shell line.
run_job() {  # run_job <index>
  local i="$1" words rc=0 tmp="" lim="${DEPLOYS_JOB_TIMEOUT:-600}"
  set -f
  # shellcheck disable=SC2206 # the job's words are split on purpose, without globbing
  words=(${cmds[$i]})
  set +f
  case "${words[0]}" in
    deploys) words=("${DEPLOYS:-deploys}" "${words[@]:1}") ;;
    statuspage) words=("$integ/statuspage/statuspage.sh" "${words[@]:1}") ;;
    badges) words=("$integ/badge/badge.sh" "${words[@]:1}") ;;
    badge-stats) words=("$integ/badge/stats.sh" "${words[@]:1}") ;;
    report) words=("$integ/digest/report.sh" "${words[@]:1}") ;;
  esac
  case "$lim" in ''|*[!0-9]*) lim=600 ;; esac
  if command -v timeout >/dev/null 2>&1; then words=(timeout "$lim" "${words[@]}"); fi
  echo "[$(stamp "$now")] job $((i + 1)) start: ${cmds[$i]}"
  # The job runs in the background and the scheduler waits for it: a TERM (docker stop) is then handled at once,
  # not after the job, and the job and its temp file go with it. The jobs only read: DEPLOYS_READONLY=1 says so to the CLI.
  if [ -n "${outs[$i]}" ]; then
    mkdir -p "$(dirname "${outs[$i]}")"; tmp="$(mktemp "${outs[$i]}.XXXXXX")"; cur_tmp="$tmp"
    DEPLOYS_READONLY=1 "${words[@]}" > "$tmp" </dev/null & cur_job=$!
    wait "$cur_job" || rc=$?
    cur_job=""
    if [ "$rc" = 0 ]; then mv "$tmp" "${outs[$i]}"; else rm -f "$tmp"; fi
    cur_tmp=""
  else
    DEPLOYS_READONLY=1 "${words[@]}" </dev/null & cur_job=$!
    wait "$cur_job" || rc=$?
    cur_job=""
  fi
  # A dead man's switch: one ping after a job that worked (healthchecks.io, Uptime Kuma push). https only.
  if [ "$rc" = 0 ] && [ -n "${DEPLOYS_PING_URL:-}" ]; then
    case "$DEPLOYS_PING_URL" in https://*) curl -fsS -m 10 -o /dev/null "$DEPLOYS_PING_URL" 2>/dev/null || echo "ping failed" >&2 ;; *) echo "DEPLOYS_PING_URL must start with https://" >&2 ;; esac
  fi
  if [ "$rc" = 0 ]; then echo "[$(stamp "$now")] job $((i + 1)) done"; else echo "[$(stamp "$now")] job $((i + 1)) failed (exit $rc); it runs again at its next time" >&2; fi
  return "$rc"
}

# Is job i due? every: that long after the last run (the first look runs it). daily/weekly: from the minute on,
# once per UTC day; `lasts` holds the day (YYYYMMDD) for those.
due() {  # due <index> <epoch> <hhmm> <weekday> <day>
  local i="$1"
  case "${kinds[$i]}" in
    every) [ $(($2 - lasts[i])) -ge "${specs[$i]}" ] ;;
    daily) [ "$3" -ge "$((10#${specs[$i]}))" ] && [ "${lasts[$i]}" != "$5" ] ;;
    weekly) [ "$4" = "${specs[$i]%% *}" ] && [ "$3" -ge "$((10#${specs[$i]#* }))" ] && [ "${lasts[$i]}" != "$5" ] ;;
  esac
}

# TERM or INT: the running job, the heartbeat ticker and a half-written output go; the exit status is the signal's (143, 130).
cur_job="" cur_tmp="" hb_pid=""
# Children first: without `timeout` (which signals its group) a job's own child would live on.
kill_tree() { local c; for c in $(pgrep -P "$1" 2>/dev/null); do kill_tree "$c"; done; kill -TERM "$1" 2>/dev/null || true; }
cleanup() {
  [ -z "$cur_job" ] || { kill_tree "$cur_job"; wait "$cur_job" 2>/dev/null || true; }
  [ -z "$cur_tmp" ] || rm -f "$cur_tmp"
  [ -z "$hb_pid" ] || kill "$hb_pid" 2>/dev/null || true
}
trap 'cleanup; exit 143' TERM
trap 'cleanup; exit 130' INT
trap 'cleanup' EXIT
now="$(clock)"
if [ "$once" = 1 ]; then
  failed=0; i=0
  while [ "$i" -lt "$n" ]; do run_job "$i" || failed=$((failed + 1)); i=$((i + 1)); done
  [ "$failed" = 0 ]; exit $?
fi
echo "[$(stamp "$now")] scheduler: $n job(s) from $jobs (UTC)"
# The heartbeat comes from a ticker of its own: a job that runs for minutes must not make the container look dead.
if [ -z "$virtual" ]; then
  ( while :; do date +%s > "$hb" 2>/dev/null || true; sleep "$((tick > 30 ? 30 : (tick < 1 ? 1 : tick)))"; done ) & hb_pid=$!
fi
count=0
while :; do
  now="$(clock)"
  printf '%s\n' "$now" > "$hb" 2>/dev/null || true
  read -r hhmm wd day <<<"$(jq -nr --argjson t "$now" '$t | strftime("%H%M %u %Y%m%d")')"
  i=0
  while [ "$i" -lt "$n" ]; do
    if due "$i" "$now" "$((10#$hhmm))" "$wd" "$day"; then
      case "${kinds[$i]}" in every) lasts[i]="$now" ;; *) lasts[i]="$day" ;; esac
      run_job "$i" || true
    fi
    i=$((i + 1))
  done
  count=$((count + 1))
  [ "$ticks" = 0 ] || [ "$count" -lt "$ticks" ] || break
  if [ -n "$virtual" ]; then virtual=$((virtual + ${SCHEDULER_STEP:-$tick})); else sleep "$tick"; fi
done
