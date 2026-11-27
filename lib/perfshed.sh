# shellcheck shell=bash
# lib/perfshed.sh — load shedding: when the Mac is yellow or red, stop dev servers nobody uses any more and Docker
# stacks `deploys perf docker` shows as idle, so the Mac never runs full. Off unless `deploys perf install --shed --yes`
# (perf.json "shed":{"enabled":true}); `deploys perf clean` lists what it would stop (rule S). Bash 3.2.
#
# Rule S, a dev server (next dev, vite, webpack-dev, nodemon; the topmost such process with everything below it).
# "Idle" means no client connected to any of its listening ports (ESTABLISHED with that port on our side) for
# shed.idleMin minutes (30), as the agent sees it every minute (perf/shed-seen.tsv). The folder decides by the most
# specific desktop-session folder that holds it (lib/desktopsessions.sh, read-only):
#   archived  every session with that folder is archived: stopped, even with a Claude process above it;
#   done      every session with that folder is archived or done, and the server is idle;
#   idle      idle, no Claude Code process above it, no terminal (tty), and no open session with that folder.
# At most shed.maxPerRun (3) per pass, biggest first; a server that comes back after a stop (same folder and command)
# is left alone for 24 h. Docker: perf tick's idle stop (lib/perfdocker.sh) also runs under memory pressure when
# shed is on, without stacks that hold a database unless docker.autoStop is on.
# Only under memory pressure (perf_judge memoryTight: pressure at warn, swapping, little memory or swap free; not load
# alone, a sleeping dev server costs no CPU), every 5 minutes, with a notification and a journal entry; TERM, then
# KILL after 10 s. Never: Claude, Chrome, databases, launchd jobs, a stopped process, anything under an editor or
# debugger (PERF_PROTECT_RE and the checks below).
# Tests: DEPLOYS_PERF_FIXTURE files shedps, shedlisten, shedcwd, shedest, launchctl; DEPLOYS_DESKTOP_SESSIONS_BASE.

perf_shed_conf() { perf_conf | jq -c '(.shed // {}) as $s | {enabled:($s.enabled // false), idleMin:($s.idleMin // 30), maxPerRun:($s.maxPerRun // 3)}'; }

# Folders of desktop sessions, one line `state<TAB>cwd`: archived, done, or open (anything else). Read-only.
perf_shed_sessions() {
  local base snap
  base="$(dsess_base 2>/dev/null)"; [ -d "$base" ] || return 0
  find "$base" -mindepth 3 -maxdepth 3 -type f -name 'local_*.json' -print0 2>/dev/null \
    | F='select(type == "object" and .isArchived == true and (.cwd | type) == "string") | .cwd' xargs -0 sh -c "$DSESS_READ" _ \
    | jq -r 'select(length > 0) | "archived\t\(.)"'
  snap="$(dsess_snapshot 2>/dev/null)" || return 0
  jq -r '.accounts[].sessions[] | select(.cwd != "") | "\(if .state == "done" then "done" else "open" end)\t\(.cwd)"' <<<"$snap" 2>/dev/null
}

# perf_shed_list [--no-sessions]: TSV `pid<TAB>why<TAB>age s<TAB>MB<TAB>pids<TAB>ports<TAB>folder<TAB>args`, and
# rewrites perf/shed-seen.tsv (pid, start, last time a client was connected).
perf_shed_list() {
  local me jobs listen est cwds sess="" seen now conf idle back
  me="$(id -u)"; now="$(perf_now)"; conf="$(perf_shed_conf)"; idle="$(jq -r '.idleMin | floor' <<<"$conf")"
  mkdir -p "$PERF_DIR" 2>/dev/null; seen="$PERF_DIR/shed-seen.tsv"; [ -f "$seen" ] || : > "$seen" 2>/dev/null
  jobs="$(perf_src launchctl launchctl list | awk 'NR > 1 && $1 ~ /^[0-9]+$/ {print $1}' | tr '\n' ' ')"
  listen="$(perf_src shedlisten lsof -nP -iTCP -sTCP:LISTEN -a -u "$me" -Fpn | awk '/^p/ {p = substr($0, 2)} /^n/ {n = $0; sub(/.*:/, "", n); print p, n}' | tr '\n' ',')"
  # Our side of each open connection (the part before ->): a client on a listening port shows there.
  est="$(perf_src shedest lsof -nP -iTCP -sTCP:ESTABLISHED -a -u "$me" -Fn | sed -n 's/^n//p' | sed 's/->.*//' | sed -n 's/.*:\([0-9][0-9]*\)$/\1/p' | sort -u | tr '\n' ' ')"
  cwds="$(perf_src shedcwd lsof -a -d cwd -u "$me" -c node -c next-serv -c vite -c nodemon -Fpn | awk '/^p/ {p = substr($0, 2)} /^n/ {print p "\t" substr($0, 2)}' | tr '\n' '\034')"
  [ "${1:-}" = --no-sessions ] || sess="$(perf_shed_sessions | tr '\n' '\034')"
  # folder+command of the servers stopped in the last 24 h: one that is back is wanted
  back="$( [ -f "$PERF_DIR/shed-stopped.tsv" ] && awk -F'\t' -v now="$now" '$1 >= now - 86400 {print $2}' "$PERF_DIR/shed-stopped.tsv" | tr '\n' '\034')"
  { cat "$seen"; echo "@@"; perf_src shedps ps -U "$me" -o pid=,ppid=,etime=,rss=,stat=,tty=,args=; } | awk \
    -v prot="$PERF_PROTECT_RE|/deploys( |$)|lib/perf\\.sh" -v now="$now" -v idle="$idle" -v jobs=" $jobs " -v listen="$listen" \
    -v est=" $est " -v cwds="$cwds" -v sess="$sess" -v back="$back" -v seenf="$seen.new" '
    function secs(e,   d, n, t, s, i) { d = 0; if (e ~ /-/) { d = substr(e, 1, index(e, "-") - 1); e = substr(e, index(e, "-") + 1) }
      n = split(e, t, ":"); s = 0; for (i = 1; i <= n; i++) s = s * 60 + t[i]; return d * 86400 + s }
    function isdev(a) { return a ~ /next dev|next-server|vite( |$)|webpack-dev|nodemon/ && a !~ /vite build|next build/ }
    function tree(p,   k, m, i) { pl = pl "," p; mb += R[p]; m = split(kids[p], k, " "); for (i = 1; i <= m; i++) tree(k[i]) }
    $0 == "@@" { part = 1; next }
    part == 0 { split($0, x, "\t"); OS[x[1]] = x[2]; OL[x[1]] = x[3]; next }
    { line = $0; sub(/^ +/, "", line); split(line, f, " "); pid = f[1]
      a = line; sub(/^[0-9]+ +[0-9]+ +[^ ]+ +[0-9]+ +[^ ]+ +[^ ]+ +/, "", a)
      P[pid] = f[2]; AGE[pid] = secs(f[3]); R[pid] = f[4]; ST[pid] = f[5]; TTY[pid] = f[6]; A[pid] = a; order[++n] = pid
      kids[f[2]] = kids[f[2]] " " pid }
    END {
      nl = split(listen, L, ","); for (i = 1; i <= nl; i++) if (L[i] != "") { split(L[i], lp, " "); LP[lp[1]] = LP[lp[1]] " " lp[2] }
      nc = split(cwds, CW, "\034"); for (i = 1; i <= nc; i++) if (CW[i] != "") { split(CW[i], cp, "\t"); CWD[cp[1]] = cp[2] }
      ns = split(sess, S, "\034")
      for (j = 1; j <= n; j++) { p = order[j]; a = A[p]
        if (!isdev(a) || a ~ prot || ST[p] ~ /T/ || index(jobs, " " p " ")) continue
        up = 0; bad = 0; live = 0; q = P[p]; h = 0
        while (q > 1 && h < 40) { if (isdev(A[q])) up = 1
          if (A[q] ~ /claude-code\/[^ ]*\/claude( |$)|\/\.local\/bin\/claude( |$)/) live = 1
          if (A[q] ~ /Code Helper|Visual Studio Code|Cursor\.app|Xcode\.app|lldb|--inspect/ || ST[q] ~ /T/) bad = 1
          q = P[q]; h++ }
        if (up || bad) continue
        pl = ""; mb = 0; tree(p); pl = substr(pl, 2)
        # ports and folder of the whole tree (the listening one is often a child, next-server)
        m = split(pl, T, ","); ports = ""; dir = ""; tty = (TTY[p] !~ /^\?+$/)
        for (i = 1; i <= m; i++) { ports = ports LP[T[i]]; if (dir == "" && (T[i] in CWD)) dir = CWD[T[i]]; if (TTY[T[i]] !~ /^\?+$/) tty = 1 }
        gsub(/^ +/, "", ports)
        # a client connected now: last = now; a pid seen before with the same start keeps its time, else first seen now
        start = now - AGE[p]; last = now; busy = 0
        np = split(ports, PP, " "); for (i = 1; i <= np; i++) if (index(est, " " PP[i] " ")) busy = 1
        if (!busy && (p in OS) && OS[p] - start < 6 && start - OS[p] < 6) last = OL[p]
        printf "%s\t%d\t%d\n", p, start, last > seenf
        why = ""; isidle = (np > 0 && now - last >= idle * 60); key = dir " " a
        if (index("\034" back, "\034" key "\034")) continue
        # the most specific session folder that holds it decides
        best = ""; for (i = 1; i <= ns; i++) if (S[i] != "") { split(S[i], sv, "\t")
          if (dir != "" && sv[2] != "" && index(dir "/", sv[2] "/") == 1 && length(sv[2]) > length(best)) best = sv[2] }
        st = ""; if (best != "") { st = "archived"; for (i = 1; i <= ns; i++) if (S[i] != "") { split(S[i], sv, "\t")
            if (sv[2] == best && sv[1] == "open") st = "open"; else if (sv[2] == best && sv[1] == "done" && st == "archived") st = "done" } }
        idlefor = "no client on port " ports " for " int((now - last) / 60) " min"
        if (st == "archived") why = "its Claude session is archived"
        else if (st == "done" && isidle) why = "its Claude session is done, " idlefor
        else if (st == "" && isidle && !live && !tty) why = idlefor
        if (why != "") printf "%s\t%s\t%d\t%d\t%s\t%s\t%s\t%s\n", p, why, AGE[p], mb / 1024, pl, ports, dir, substr(a, 1, 200) } }' \
    | sort -t "$(printf '\t')" -k4,4nr
  [ ! -f "$seen.new" ] || mv -f "$seen.new" "$seen"
}

perf_shed_journal() {  # perf_shed_journal <name> <detail>
  declare -F journal_add >/dev/null || return 0
  journal_add local "$1" shed "$2" 2>/dev/null || true
}

# perf_shed_main [--dry-run|--yes] [--quiet] [--tsv] [--snap <status JSON>]: list (default) or stop. Stops only while
# the status says memoryTight, at most shed.maxPerRun. --tsv prints `pid<TAB>why<TAB>age s<TAB>MB<TAB>args` lines.
perf_shed_main() {
  local doit=0 quiet=0 tsv=0 snap="" lvl tight rows max r pid why age mb pids dir args id ids="" n=0 freed=0 x
  while [ "$#" -gt 0 ]; do
    case "$1" in --yes) doit=1 ;; --dry-run) doit=0 ;; --quiet) quiet=1 ;; --tsv) tsv=1 ;; --snap) snap="${2:-}"; shift ;;
      *) echo "Usage: deploys perf shed [--dry-run|--yes]" >&2; return 2 ;; esac
    shift
  done
  [ -n "$snap" ] || snap="$(perf_snapshot 2>/dev/null || echo '{}')"
  lvl="$(jq -r '.level // "green"' <<<"$snap" 2>/dev/null || echo green)"
  tight="$(jq -r '.memoryTight // false' <<<"$snap" 2>/dev/null || echo false)"
  [ "$tight" = true ] || doit=0
  max="$(perf_shed_conf | jq -r '.maxPerRun | floor')"
  rows="$(perf_shed_list 2>/dev/null || true)"
  while IFS="$(printf '\t')" read -r pid why age mb pids _ dir args; do
    [ -n "$pid" ] || continue
    if [ "$tsv" = 1 ]; then printf '%s\t%s\t%s\t%s\t%s\n' "$pid" "$why" "$age" "$mb" "$args"; continue; fi
    if [ "$doit" = 1 ] && [ "$n" -lt "$max" ]; then
      for x in $(echo "$pids" | tr ',' ' '); do
        id="$(perf_ident "$x")"; [ -n "$id" ] || continue
        kill -TERM "$x" 2>/dev/null && ids="$ids$x"$'\t'"$id"$'\n'
      done
      n=$((n + 1)); freed=$((freed + mb))
      mkdir -p "$PERF_DIR" 2>/dev/null; printf '%s\t%s %s\n' "$(perf_now)" "$dir" "$args" >> "$PERF_DIR/shed-stopped.tsv" 2>/dev/null || true
      perf_log "shed: stopped $pid dev server ($why, level $lvl), $mb MB, $(echo "$pids" | tr ',' '\n' | grep -c .) processes, in ${dir:-?}: $args"
      perf_shed_journal "${dir##*/}" "Stopped a dev server under memory pressure ($lvl): $why, about $mb MB"
      [ "$quiet" = 1 ] || echo "stopped  $pid  rule S  $why  $mb MB  $args"
    else
      [ "$quiet" = 1 ] || echo "would stop  $pid  rule S  $why  $mb MB  $args"
    fi
  done <<<"$rows"
  if [ -n "$ids" ]; then
    sleep "${DEPLOYS_PERF_KILL_AFTER:-10}"
    while IFS="$(printf '\t')" read -r pid id; do
      [ -n "$pid" ] || continue
      if [ "$(perf_ident "$pid")" = "$id" ]; then kill -KILL "$pid" 2>/dev/null && perf_log "shed: KILL $pid (did not stop on TERM)"; fi
    done <<<"$ids"
  fi
  if [ "$n" -gt 0 ]; then
    r="$(awk -v m="$freed" 'BEGIN { printf "%.1f", m / 1024 }')"
    perf_notify "Mac under memory pressure: stopped $n unused dev server(s)" "About $r GB. Details: ~/.config/deploys/perf/clean.log"
  elif [ "$quiet" = 0 ] && [ "$tsv" = 0 ] && [ -z "$rows" ]; then echo "perf shed: no unused dev servers."
  fi
  [ "$doit" = 1 ] || [ "$quiet" = 1 ] || [ "$tsv" = 1 ] || [ -z "$rows" ] || \
    echo "(dry run$( [ "$tight" = true ] || echo ", no memory pressure now"); stopped only under memory pressure, by the agent after deploys perf install --shed --yes, or deploys perf shed --yes.)"
  return 0
}

# perf_shed_tick <status JSON>: from perf tick when shed is on. The idle times stay current every minute; a stop pass
# runs at most every 5 minutes and only under memory pressure.
perf_shed_tick() {
  local snap="$1" now
  [ "$(perf_shed_conf | jq -r .enabled)" = true ] || return 0
  now="$(perf_now)"
  if [ "$(jq -r '.memoryTight // false' <<<"$snap")" = true ] && [ $(( now - $(cat "$PERF_DIR/last-shed" 2>/dev/null || echo 0) )) -ge 300 ]; then
    echo "$now" > "$PERF_DIR/last-shed"; json=0 perf_shed_main --yes --quiet --snap "$snap" || true
    # The Mac app quits picked apps only after a shedding pass had its effect (app/AppQuit.swift).
    perf_now > "$PERF_DIR/shed-done" 2>/dev/null || true
  else
    perf_shed_list --no-sessions >/dev/null 2>&1 || true
  fi
}

# perf_quit_plan: what the Mac app would quit now (perf/quit-plan.json, app/AppQuit.swift), as lines
# `name<TAB>MB<TAB>idle min`, or one line `#<TAB>reason` when it cannot tell. Read-only.
perf_quit_plan() {
  local f="$PERF_DIR/quit-plan.json" on
  on="$(perf_conf | jq -r '(.quitApps // {}).enabled // false')"
  [ "$on" = true ] || return 0
  if [ ! -f "$f" ] || [ $(( $(perf_now) - $(jq -r '.time // 0' "$f" 2>/dev/null || echo 0) )) -gt 180 ]; then
    printf '#\tthe Deploy Center app is not running: no apps are quit\n'; return 0
  fi
  jq -r '.candidates[]? | "\(.name)\t\(.mb)\t\(.idleMin)"' "$f" 2>/dev/null
}
