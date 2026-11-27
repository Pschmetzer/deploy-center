# shellcheck shell=bash
# lib/perffinished.sh — stop the dev servers of finished work at any load: `deploys perf finished [--yes]`, and the
# launchd agent every 5 minutes after `deploys perf install --stop-finished --yes` (perf.json "stopFinished":
# {"enabled":true,"graceMin":10}). Bash 3.2.
#
# Finished: the dev server's folder belongs to a Claude desktop session that is archived or done (lib/desktopsessions.sh,
# read-only, the most specific folder decides, no open session there), or, without a session, the pull request of the
# folder's branch is merged or closed (gh, at most 5 look-ups a pass, cached for an hour in perf/branch-pr.tsv).
# The same dev servers as rule S (lib/perfshed.sh): next dev, vite, webpack-dev, nodemon with everything below them,
# never under an editor or debugger, never a launchd job, never Claude, Chrome or a database. A server has to stay
# finished for graceMin (10) minutes (perf/finished-seen.tsv) before it gets a TERM (KILL after 10 s), with a
# notification and a journal entry. One that comes back afterwards (same folder and command) is left alone for 24 h.
# Tests: the rule S fixtures, plus DEPLOYS_PERF_FIXTURE/branchpr (`folder<TAB>MERGED|CLOSED|OPEN|NONE` lines).

perf_finished_conf() { perf_conf | jq -c '(.stopFinished // {}) as $s | {enabled:($s.enabled // false), graceMin:($s.graceMin // 10)}'; }

# perf_branch_pr <folder>: MERGED, CLOSED, OPEN or NONE for the pull request of the folder's branch; empty when unknown.
perf_branch_pr() {
  local d="$1" c="$PERF_DIR/branch-pr.tsv" now hit br url st
  if [ -n "${DEPLOYS_PERF_FIXTURE:-}" ]; then awk -F'\t' -v d="$d" '$1 == d {print $2; exit}' "$DEPLOYS_PERF_FIXTURE/branchpr" 2>/dev/null; return 0; fi
  now="$(perf_now)"
  hit="$( [ -f "$c" ] && awk -F'\t' -v d="$d" -v now="$now" '$1 == d && $2 >= now - 3600 {s = $3} END {print s}' "$c")"
  [ -z "$hit" ] || { echo "$hit"; return 0; }
  [ "${PERF_BRANCH_LOOKUPS:-0}" -lt 5 ] || return 0
  PERF_BRANCH_LOOKUPS=$(( ${PERF_BRANCH_LOOKUPS:-0} + 1 ))
  command -v gh >/dev/null 2>&1 || return 0
  br="$(git -C "$d" rev-parse --abbrev-ref HEAD 2>/dev/null)"; url="$(git -C "$d" remote get-url origin 2>/dev/null)"
  case "$br" in ''|HEAD|main|master) return 0 ;; esac
  [ -n "$url" ] || return 0
  st="$(cd "$d" && gh pr list --head "$br" --state all --limit 1 --json state -q '.[0].state // "NONE"' 2>/dev/null)" || return 0
  [ -n "$st" ] || return 0
  mkdir -p "$PERF_DIR" 2>/dev/null; printf '%s\t%s\t%s\n' "$d" "$now" "$st" >> "$c" 2>/dev/null
  # keep the cache short
  if [ "$(wc -l < "$c")" -gt 400 ]; then tail -n 200 "$c" > "$c.$$" && mv -f "$c.$$" "$c"; fi
  echo "$st"
}

# perf_finished_list: TSV `pid<TAB>why<TAB>finished min<TAB>MB<TAB>pids<TAB>folder<TAB>args`; rewrites finished-seen.tsv.
perf_finished_list() {
  local now seen rows pid why age mb pids dir args st first start out=""
  now="$(perf_now)"; seen="$PERF_DIR/finished-seen.tsv"; mkdir -p "$PERF_DIR" 2>/dev/null; [ -f "$seen" ] || : > "$seen"
  rows="$(perf_shed_list --finished 2>/dev/null || true)"
  : > "$seen.new"
  while IFS="$(printf '\t')" read -r pid why age mb pids _ dir args; do
    [ -n "$pid" ] || continue
    case "$why" in
      archived) why="its Claude session is archived" ;;
      done) why="its Claude session is done" ;;
      '?') st="$(perf_branch_pr "$dir")"
           case "$st" in MERGED) why="the pull request of its branch is merged" ;; CLOSED) why="the pull request of its branch is closed" ;; *) continue ;; esac ;;
      *) continue ;;
    esac
    start=$(( now - age ))
    # first seen finished: kept from the last pass when it is the same process (start within 5 s)
    first="$(awk -F'\t' -v p="$pid" -v s="$start" '$1 == p && $2 - s < 6 && s - $2 < 6 {print $3}' "$seen")"
    [ -n "$first" ] || first="$now"
    printf '%s\t%s\t%s\n' "$pid" "$start" "$first" >> "$seen.new"
    out="$out$pid	$why	$(( (now - first) / 60 ))	$mb	$pids	$dir	$args
"
  done <<<"$rows"
  mv -f "$seen.new" "$seen"
  printf '%s' "$out"
}

# perf_finished_main [--dry-run|--yes] [--quiet] [--tsv]: list (default) or stop the ones past the grace time.
perf_finished_main() {
  local doit=0 quiet=0 tsv=0 grace rows pid why mins mb pids dir args x id ids="" n=0 freed=0 r
  while [ "$#" -gt 0 ]; do
    case "$1" in --yes) doit=1 ;; --dry-run) doit=0 ;; --quiet) quiet=1 ;; --tsv) tsv=1 ;;
      *) echo "Usage: deploys perf finished [--dry-run|--yes]" >&2; return 2 ;; esac
    shift
  done
  grace="$(perf_finished_conf | jq -r '.graceMin | floor')"
  rows="$(perf_finished_list)"
  while IFS="$(printf '\t')" read -r pid why mins mb pids dir args; do
    [ -n "$pid" ] || continue
    if [ "$tsv" = 1 ]; then printf '%s\t%s\t%s\t%s\t%s\n' "$pid" "$why" "$mins" "$mb" "$args"; continue; fi
    if [ "$doit" = 1 ] && [ "$mins" -ge "$grace" ]; then
      for x in $(echo "$pids" | tr ',' ' '); do
        id="$(perf_ident "$x")"; [ -n "$id" ] || continue
        kill -TERM "$x" 2>/dev/null && ids="$ids$x"$'\t'"$id"$'\n'
      done
      n=$((n + 1)); freed=$((freed + mb))
      printf '%s\t%s %s\n' "$(perf_now)" "$dir" "$args" >> "$PERF_DIR/shed-stopped.tsv" 2>/dev/null || true
      perf_log "finished: stopped $pid dev server ($why for $mins min), $mb MB, in ${dir:-?}: $args"
      perf_shed_journal "${dir##*/}" "Stopped a dev server of finished work: $why, about $mb MB"
      [ "$quiet" = 1 ] || echo "stopped  $pid  $why  $mb MB  $args"
    else
      [ "$quiet" = 1 ] || echo "would stop  $pid  $why$( [ "$mins" -lt "$grace" ] && echo " (in $(( grace - mins )) min)")  $mb MB  $args"
    fi
  done <<<"$rows"
  if [ -n "$ids" ]; then
    sleep "${DEPLOYS_PERF_KILL_AFTER:-10}"
    while IFS="$(printf '\t')" read -r pid id; do
      [ -n "$pid" ] || continue
      if [ "$(perf_ident "$pid")" = "$id" ]; then kill -KILL "$pid" 2>/dev/null && perf_log "finished: KILL $pid (did not stop on TERM)"; fi
    done <<<"$ids"
  fi
  if [ "$n" -gt 0 ]; then
    r="$(awk -v m="$freed" 'BEGIN { printf "%.1f", m / 1024 }')"
    perf_notify "Stopped $n dev server(s) of finished work" "Archived or done sessions, merged pull requests. About $r GB. Details: ~/.config/deploys/perf/clean.log"
  elif [ "$quiet" = 0 ] && [ "$tsv" = 0 ] && [ -z "$rows" ]; then echo "perf finished: no dev servers of finished work."
  fi
  [ "$doit" = 1 ] || [ "$quiet" = 1 ] || [ "$tsv" = 1 ] || [ -z "$rows" ] || echo "(dry run. deploys perf finished --yes stops the ones past the $grace min grace; the agent does it after deploys perf install --stop-finished --yes.)"
  return 0
}

# perf_finished_tick: from perf tick, every 5 minutes when stopFinished is on.
perf_finished_tick() {
  local now
  [ "$(perf_finished_conf | jq -r .enabled)" = true ] || return 0
  now="$(perf_now)"
  [ $(( now - $(cat "$PERF_DIR/last-finished" 2>/dev/null || echo 0) )) -ge 300 ] || return 0
  echo "$now" > "$PERF_DIR/last-finished"; json=0 perf_finished_main --yes --quiet || true
}
