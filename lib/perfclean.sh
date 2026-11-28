# shellcheck shell=bash
# lib/perfclean.sh — the other half of the performance guard (lib/perf.sh): `deploys perf clean` (orphaned dev
# processes), `perf tick` (what the launchd agent runs every minute: a sample, status.json for the app, a notification
# when red for a while, a cleanup pass every 10 minutes), `perf install|uninstall` (the agent) and `perf hook` (the
# Claude Code hook, printed for the person to add). Bash 3.2.
#
# What counts as orphaned (and nothing else is ever stopped), only processes of this user:
#   A  a short-lived check (tsc, vitest, jest worker, eslint, playwright, next build) whose parent is launchd (pid 1),
#      older than 30 minutes: its session or terminal is gone;
#   B  any node / check / dev server whose working folder is inside a .claude/worktrees/<name> folder that no longer
#      exists, older than 10 minutes, with no live Claude Code session above it.
#   P  a test browser (Playwright's, Chrome for Testing, chrome-headless-shell) whose parent is launchd, older than
#      30 minutes: stopped with its process group (its renderers);
#   C  a dev server (next dev, vite) started without a terminal, older than 2 hours, with no live Claude Code session
#      above it or in its folder: only listed, stopped only with --dev.
#   S  a dev server nobody uses any more (lib/perfshed.sh): only listed here, stopped under memory pressure.
# Never: a process launchd runs as a job, one listening on a TCP port (except C), Claude, Docker, databases, your
# Chrome (/Applications/Google Chrome.app), Xcode.
# The agent only reports (dry run) unless it was installed with --clean; `perf clean --yes` stops them by hand.

PERF_PROTECT_RE='Claude\.app|claude-code/|/\.local/bin/claude|Docker|com\.docker|postgres|mysqld|mariadb|redis|mongod|/Applications/Google Chrome\.app|/Applications/Chromium\.app|Xcode\.app|launchd'
PERF_LABEL="${DEPLOYS_PERF_LABEL:-app.deploycenter.perf}"

perf_log() { mkdir -p "$PERF_DIR" 2>/dev/null; printf '%s %s\n' "$(date '+%Y-%m-%d %H:%M:%S')" "$*" >> "$PERF_DIR/clean.log" 2>/dev/null || true; }

# perf_candidates: TSV `pid<TAB>rule<TAB>age s<TAB>args` of the processes rules A and B find. Inputs are fixtures in tests.
perf_candidates() {
  local me jobs listen cwds
  me="$(id -u)"
  jobs="$(perf_src launchctl launchctl list | awk 'NR > 1 && $1 ~ /^[0-9]+$/ {print $1}' | tr '\n' ' ')"
  listen="$(perf_src listen lsof -nP -iTCP -sTCP:LISTEN -a -u "$me" -Fp | sed -n 's/^p//p' | tr '\n' ' ')"
  # One lsof for the working folders of all node processes (and the checks that run as their own binary).
  cwds="$(perf_src cwd lsof -a -d cwd -u "$me" -c node -c tsc -c esbuild -c next-buil -c vitest -Fpn | awk '/^p/ {p = substr($0, 2)} /^n/ {print p "\t" substr($0, 2)}')"
  { echo "$jobs"; echo "@@"; echo "$listen"; echo "@@"; echo "$cwds"; echo "@@"; perf_src psu ps -U "$me" -o pid=,ppid=,etime=,tty=,args=; } | awk -F'\n' \
    -v self="$$" -v prot="$PERF_PROTECT_RE" -v sess="$(perf_session_cwds 2>/dev/null | tr '\n' '\t')" "$PERF_AWK_FN"'
    function secs(e,   d, n, t, s) { d = 0; if (e ~ /-/) { d = substr(e, 1, index(e, "-") - 1); e = substr(e, index(e, "-") + 1) }
      n = split(e, t, ":"); s = 0; for (i = 1; i <= n; i++) s = s * 60 + t[i]; return d * 86400 + s }
    function isdev(a,   w) { w = base(substr(a, 1, index(a " ", " ") - 1))
      return ischeck(a) || a ~ /next dev|vite( |$)/ || w ~ /^(node|esbuild|next-server|next-router-worker)$/ || a ~ /next dev|next-server|vite( |$)/ }
    $0 == "@@" { part++; next }
    part == 0 { n = split($0, t, " "); for (i = 1; i <= n; i++) job[t[i]] = 1; next }
    part == 1 { n = split($0, t, " "); for (i = 1; i <= n; i++) lis[t[i]] = 1; next }
    part == 2 { if ($0 != "") { split($0, c, "\t"); cwd[c[1]] = c[2] } next }
    { line = $0; sub(/^ +/, "", line); split(line, f, " "); pid = f[1]; pp = f[2]; et = f[3]
      a = line; sub(/^[0-9]+ +[0-9]+ +[^ ]+ +[^ ]+ +/, "", a); P[pid] = pp; A[pid] = a; AGE[pid] = secs(et); TTY[pid] = f[4]; order[++np] = pid }
    END {
      for (k = 1; k <= np; k++) { pid = order[k]; a = A[pid]
        if (pid == self || (pid in job) || a ~ prot) continue
        rule = ""; live = 0; q = P[pid]; hops = 0
        while (q > 1 && hops < 40) { if (A[q] ~ /claude-code\/[^ ]*\/claude( |$)|\/\.local\/bin\/claude( |$)/) live = 1; q = P[q]; hops++ }
        if (a ~ /next dev|vite( |$)/ && TTY[pid] ~ /^\?+$/ && AGE[pid] > 7200 && !live) {
          ns = split(sess, ss, "\t"); insess = 0
          for (i = 1; i <= ns; i++) if (ss[i] != "" && (pid in cwd) && index(cwd[pid] "/", ss[i] "/") == 1) insess = 1
          if (!insess) { printf "%s\t%s\t%d\t%s\n", pid, "C", AGE[pid], substr(a, 1, 200); continue } }
        if (pid in lis) continue
        if (P[pid] == 1 && AGE[pid] > 1800 && a ~ /ms-playwright|Chrome for Testing|chrome-headless-shell|headless_shell/) rule = "P"
        else if (P[pid] == 1 && AGE[pid] > 1800 && ischeck(a)) rule = "A"
        else if ((pid in cwd) && cwd[pid] ~ /\/\.claude\/worktrees\/[^\/]+/ && AGE[pid] > 600 && isdev(a)) {
          match(cwd[pid], /.*\/\.claude\/worktrees\/[^\/]+/)
          wt = substr(cwd[pid], RSTART, RLENGTH)
          # a live session above it keeps it
          if (!live) rule = "B:" wt }
        if (rule != "") printf "%s\t%s\t%d\t%s\n", pid, rule, AGE[pid], substr(a, 1, 200) } }' \
  | while IFS="$(printf '\t')" read -r pid rule age args; do
      # B needs the worktree folder to be gone; checked here, where the file system is (a fixture names a made-up one).
      case "$rule" in B:*) [ ! -d "${rule#B:}" ] || continue; rule="B" ;; esac
      printf '%s\t%s\t%s\t%s\n' "$pid" "$rule" "$age" "$args"
    done
}

perf_ident() { ps -o lstart=,args= -p "$1" 2>/dev/null; }  # start time + args: the same process, not a reused pid

# perf_clean_main [--dry-run|--yes] [--quiet]: list (default) or stop the orphans; TERM, then KILL after 10 s.
perf_clean_main() {
  local doit=0 quiet=0 dev=0 list pid rule age args n=0 ids="" id tgt pg
  while [ "$#" -gt 0 ]; do
    case "$1" in --yes) doit=1 ;; --dry-run) doit=0 ;; --quiet) quiet=1 ;; --dev) dev=1 ;;
      *) echo "Usage: deploys perf clean [--dry-run|--yes] [--dev] [--json]" >&2; return 2 ;; esac
    shift
  done
  list="$(perf_candidates 2>/dev/null || true)"
  # Rule S (lib/perfshed.sh) is only listed here; it stops under memory pressure through perf shed or the agent.
  local shed="" quit=""; ! declare -F perf_shed_main >/dev/null || { shed="$(perf_shed_main --tsv --snap '{}' 2>/dev/null || true)"; quit="$(perf_quit_plan 2>/dev/null || true)"; }
  if [ "${json:-0}" = 1 ]; then
    printf '%s\n' "$list" | jq -Rsc --argjson y "$doit" --argjson d "$dev" --arg s "$shed" --arg q "$quit" '[split("\n")[] | select(length > 0) | split("\t") | {pid:(.[0] | tonumber), rule:.[1], ageS:(.[2] | tonumber), args:.[3]}] | {stopped:($y == 1), processes:(map(. + {stops:($y == 1 and (.rule != "C" or $d == 1))})
      + [$s | split("\n")[] | select(length > 0) | split("\t") | {pid:(.[0] | tonumber), rule:"S", reason:.[1], ageS:(.[2] | tonumber), mb:(.[3] | tonumber), args:.[4], stops:false}]),
      apps:[$q | split("\n")[] | select(length > 0) | split("\t") | select(.[0] != "#") | {name:.[0], mb:(.[1] | tonumber), idleMin:(.[2] | tonumber)}]}'
  fi
  if [ -n "$shed" ] && [ "$quiet" = 0 ] && [ "${json:-0}" != 1 ]; then
    printf '%s\n' "$shed" | awk -F'\t' '{ printf "would stop  %s  rule S (under memory pressure, with --shed)  %d min  %s MB  %s  %s\n", $1, $3 / 60, $4, $2, $5 }'
  fi
  if [ -n "$quit" ] && [ "$quiet" = 0 ] && [ "${json:-0}" != 1 ]; then
    printf '%s\n' "$quit" | awk -F'\t' '$1 == "#" { print "apps: " $2; next } { printf "would quit app  %s  %s MB  idle %s min  (when red with memory pressure for 5 min, like Cmd-Q, by the Deploy Center app)\n", $1, $2, $3 }'
  fi
  if [ -z "$list" ]; then
    [ "$quiet" = 1 ] || [ "${json:-0}" = 1 ] || echo "perf clean: no orphaned dev processes."
    perf_log "clean: none"; return 0
  fi
  while IFS="$(printf '\t')" read -r pid rule age args; do
    [ -n "$pid" ] || continue; n=$((n + 1))
    if [ "$doit" = 1 ] && { [ "$rule" != C ] || [ "$dev" = 1 ]; }; then
      id="$(perf_ident "$pid")"; [ -n "$id" ] || continue
      # A test browser goes with its process group (the renderers), when it leads one.
      tgt="$pid"; pg="$(ps -o pgid= -p "$pid" 2>/dev/null | tr -d ' ')"; [ "$rule" != P ] || [ "$pg" != "$pid" ] || tgt="-$pid"
      kill -TERM -- "$tgt" 2>/dev/null && { ids="$ids$pid"$'\t'"$id"$'\n'; perf_log "clean: TERM $tgt (rule $rule, $((age / 60)) min) $args"; }
      [ "$quiet" = 1 ] || [ "${json:-0}" = 1 ] || echo "stopped  $pid  rule $rule  $((age / 60)) min  $args"
    else
      perf_log "clean (dry run): would stop $pid (rule $rule, $((age / 60)) min) $args"
      [ "$quiet" = 1 ] || [ "${json:-0}" = 1 ] || echo "would stop  $pid  rule $rule$( [ "$rule" = C ] && echo " (needs --dev)")  $((age / 60)) min  $args"
    fi
  done <<<"$list"
  if [ -n "$ids" ]; then
    sleep "${DEPLOYS_PERF_KILL_AFTER:-10}"
    while IFS="$(printf '\t')" read -r pid id; do
      [ -n "$pid" ] || continue
      # Only the same process (start time and args unchanged) gets the KILL.
      if [ "$(perf_ident "$pid")" = "$id" ]; then { kill -KILL -- "-$pid" 2>/dev/null || kill -KILL "$pid" 2>/dev/null; } && perf_log "clean: KILL $pid (did not stop on TERM)"; fi
    done <<<"$ids"
  fi
  [ "$doit" = 1 ] || [ "$quiet" = 1 ] || [ "${json:-0}" = 1 ] || echo "($n found; dry run, nothing was stopped. deploys perf clean --yes stops them.)"
}

# --- reap: every process class that costs memory, with one rule each ---------------------------------------------
# Classes (the topmost process of each tree counts, with everything below it):
#   check        lint, typecheck, test, build runs (ischeck in PERF_AWK_FN), not in watch mode
#   testbrowser  Playwright's browsers, Chrome for Testing, chrome-headless-shell (not --headed / --ui debug runs)
#   mcp          MCP servers
#   npmexec      `npm exec` / `npx` runs that are none of the above
#   devserver    next dev, vite, webpack-dev, nodemon, and checks in watch mode (tsc -w, vitest without run)
# Verdicts, and what the agent does on its own (after the person installed it with --reap):
#   hang     a check older than reap.limitMin (45) with no CPU progress for reap.stallMin (15) and over reap.stallMB
#            (500), or older than reap.hardLimitMin (90) at all: stopped. A test browser that stalls: reported.
#            Hang limits shrink with pressure (yellow x0.6, red x0.35; at least 5 min, 15 for checks).
#   orphan   its parent is launchd (the session is gone): check after 10 min, mcp after 10, npmexec and testbrowser
#            after 30: stopped. These waits never shrink.
#   useless  a dev server without a terminal, with no Claude Code session above it or in its folder, for 2 h:
#            reported, stopped only by a click or --pid.
# Never: Claude, your Chrome, databases, Docker, launchd jobs, a stopped process (state T, a debugger), anything under
# an editor (VS Code, Cursor, Xcode) or a debugger, and deploys itself (PERF_PROTECT_RE and the checks below).
# CPU progress: perf/cpu.tsv (pid, start, cpu seconds, last change), rewritten by every reap with the live processes.

# perf_reap_list <level>: JSON [{pid, class, verdict, auto, reason, ageS, mb, pids, folder, key, args}].
perf_reap_list() {
  local lvl="${1:-green}" conf rows roots now cpu fac=1
  conf="$(perf_conf)"; now="$(perf_now)"
  [ "$lvl" = yellow ] && fac=0.6
  [ "$lvl" = red ] && fac=0.35
  cpu="$PERF_DIR/cpu.tsv"; mkdir -p "$PERF_DIR" 2>/dev/null; [ -f "$cpu" ] || : > "$cpu"
  rows="$( { cat "$cpu"; echo "@@"; perf_src psr ps -U "$(id -u)" -o pid=,ppid=,etime=,rss=,stat=,time=,tty=,args=; } \
    | awk -v prot="$PERF_PROTECT_RE|/deploys( |$)|lib/perf\\.sh" -v now="$now" -v sess="$(perf_session_cwds 2>/dev/null | tr '\n' '\t')" \
      -v c="$(jq -r '(.reap // {}) as $r | [($r.limitMin // 45), ($r.hardLimitMin // 90), ($r.stallMin // 15), ($r.stallMB // 500), ($r.devserverIdleMin // 120)] | map(tostring) | join(" ")' <<<"$conf")" \
      -v per="$(jq -r '((.reap // {}).perCommand // {}) | to_entries | map("\(.key)=\(.value)") | join(",")' <<<"$conf")" \
      -v f="$fac" -v cpuf="$cpu.new" "$PERF_AWK_FN"'
    function secs(e,   d, n, t, s, i) { d = 0; if (e ~ /-/) { d = substr(e, 1, index(e, "-") - 1); e = substr(e, index(e, "-") + 1) }
      n = split(e, t, ":"); s = 0; for (i = 1; i <= n; i++) s = s * 60 + t[i]; return d * 86400 + s }
    function cls(a,   w) { w = base(substr(a, 1, index(a " ", " ") - 1))
      if (a ~ /ms-playwright|Chrome for Testing|chrome-headless-shell|headless_shell/) return "testbrowser"
      if (a ~ /mcp-server|-mcp( |$)|\/mcp\/server|modelcontextprotocol|mcp\.mjs/) return "mcp"
      if (ischeck(a)) return (a ~ / (--watch|-w|watch)( |$)/ || (script(a) == "vitest" || w == "vitest") && a !~ / run( |$)/) ? "devserver" : "check"
      if (a ~ /next dev|vite( |$)|webpack-dev|nodemon/) return "devserver"
      if (w == "npx" || (w == "npm" && a ~ /^[^ ]+ exec /)) return "npmexec"
      return "" }
    $0 == "@@" { part = 1; next }
    part == 0 { split($0, x, "\t"); OS[x[1]] = x[2]; OC[x[1]] = x[3]; OT[x[1]] = x[4]; next }
    { line = $0; sub(/^ +/, "", line); split(line, f6, " "); pid = f6[1]
      a = line; sub(/^[0-9]+ +[0-9]+ +[^ ]+ +[0-9]+ +[^ ]+ +[^ ]+ +[^ ]+ +/, "", a)
      P[pid] = f6[2]; AGE[pid] = secs(f6[3]); R[pid] = f6[4]; ST[pid] = f6[5]; CPU[pid] = secs(f6[6]); TTY[pid] = f6[7]; A[pid] = a
      order[++n] = pid; C[pid] = cls(a); kids[f6[2]] = kids[f6[2]] " " pid }
    function tree(p,   k, m, i) { list = list "," p; mb += R[p]; m = split(kids[p], k, " "); for (i = 1; i <= m; i++) tree(k[i]) }
    function lim(x, floor) { x = x * f; return x < floor ? floor : x }
    END { split(c, L, " "); lim1 = lim(L[1], 15); np = split(per, pc, ","); for (i = 1; i <= np; i++) { split(pc[i], kv, "="); PER[kv[1]] = kv[2] }
      for (j = 1; j <= n; j++) { p = order[j]; k = C[p]; if (k == "" || A[p] ~ prot || ST[p] ~ /T/) continue
        # the topmost of its class; nothing under an editor, a debugger or a protected process
        up = 0; bad = 0; live = 0; q = P[p]; h = 0
        while (q > 1 && h < 40) { if (C[q] == k) up = 1
          if (A[q] ~ /Code Helper|Visual Studio Code|Cursor\.app|Xcode\.app|lldb|--inspect/ || ST[q] ~ /T/) bad = 1
          if (A[q] ~ /claude-code\/[^ ]*\/claude( |$)|\/\.local\/bin\/claude( |$)/) live = 1; q = P[q]; h++ }
        if (up || bad) continue
        # CPU progress: same process (start within 5 s), cpu seconds unchanged since OT
        start = now - AGE[p]; last = now
        if ((p in OS) && OS[p] - start < 6 && start - OS[p] < 6 && CPU[p] - OC[p] < 1) last = OT[p]
        printf "%s\t%d\t%s\t%d\n", p, start, CPU[p], last > cpuf
        stall = (now - last >= L[3] * 60 && R[p] / 1024 >= L[4])
        v = "ok"; auto = 0; why = ""; orph = (P[p] == 1)
        # the command, for reap.perCommand (its hard limit): lint, verify, tsc, eslint, next build ...
        w = base(substr(A[p], 1, index(A[p] " ", " ") - 1)); key = (w ~ /^(node|bun|deno|npx|npm|pnpm|yarn|rtk)$/ && script(A[p]) != "") ? script(A[p]) : w
        sub(/:.*/, "", key); if (A[p] ~ /next build|^next-build/) key = "next build"
        lim2 = lim((key in PER) ? PER[key] : L[2], 15)
        if (k == "check") {
          if (orph && AGE[p] > 600) { v = "orphan"; auto = 1; why = "its session is gone" }
          else if (AGE[p] > lim2 * 60) { v = "hang"; auto = 1; why = "over " int(lim2) " min" }
          else if (AGE[p] > lim1 * 60 && stall) { v = "hang"; auto = 1; why = "over " int(lim1) " min without CPU progress" } }
        else if (k == "testbrowser") {
          if (orph && AGE[p] > 1800) { v = "orphan"; auto = 1; why = "its test run is gone" }
          else if (a !~ /--headed|--ui|PWDEBUG/ && AGE[p] > lim(60, 5) * 60 && stall) { v = "hang"; why = "no CPU progress" } }
        else if (k == "mcp") { if (orph && AGE[p] > 600) { v = "orphan"; auto = 1; why = "its session is gone" } }
        else if (k == "npmexec") { if (orph && AGE[p] > 1800) { v = "orphan"; auto = 1; why = "its session is gone" } }
        else if (k == "devserver" && TTY[p] ~ /^\?+$/ && !live && AGE[p] > L[5] * 60) {
          ins = 0; ns = split(sess, ss, "\t"); for (i = 1; i <= ns; i++) if (ss[i] != "" && index(A[p], ss[i]) > 0) ins = 1
          if (!ins) { v = "useless"; why = "no Claude Code session for " int(L[5] / 60) " h" } }
        list = ""; mb = 0; tree(p)
        printf "%s\t%s\t%s\t%d\t%s\t%d\t%d\t%s\t%s\t%s\n", p, k, v, auto, why, AGE[p], mb / 1024, substr(list, 2), substr(A[p], 1, 200), key } }')"
  [ ! -f "$cpu.new" ] || mv -f "$cpu.new" "$cpu"
  [ -n "$rows" ] || { echo '[]'; return 0; }
  roots="$(printf '%s\n' "$rows" | awk -F'\t' '$3 != "ok" || $2 == "check" {print $1}' | tr '\n' ',' | sed 's/,$//')"
  printf '%s\n' "$rows" | jq -Rsc --arg cwds "$( [ -z "$roots" ] || perf_src reapcwd lsof -a -d cwd -p "$roots" -Fpn | awk '/^p/ {p = substr($0, 2)} /^n/ {print p "\t" substr($0, 2)}')" '
    ($cwds | split("\n") | map(select(length > 0) | split("\t") | {(.[0]): .[1]}) | add // {}) as $cwd
    | [split("\n")[] | select(length > 0) | split("\t")
       | {pid:(.[0] | tonumber), class:.[1], verdict:.[2], auto:(.[3] == "1"), reason:.[4], ageS:(.[5] | tonumber), mb:(.[6] | tonumber),
          pids:(.[7] | split(",") | map(tonumber)), args:.[8], key:.[9]}
       | .folder = ($cwd[.pid | tostring] // null)] | sort_by(-.mb)'
}

# perf_reap_main [--dry-run|--yes] [--pid N] [--all] [--quiet] [--notify]: stop what the agent may stop (verdict with
# auto), or with --pid one listed tree of any verdict (the app's click). --all lists every class member.
perf_reap_main() {
  local doit=0 quiet=0 notify=0 all=0 only="" lvl list sel n=0 freed=0 r pid id ids=""
  while [ "$#" -gt 0 ]; do
    case "$1" in --yes) doit=1 ;; --dry-run) doit=0 ;; --quiet) quiet=1 ;; --notify) notify=1 ;; --all) all=1 ;;
      --pid) only="${2:-}"; shift; case "$only" in ''|*[!0-9]*) echo "perf reap: --pid takes a process id" >&2; return 2 ;; esac ;;
      *) echo "Usage: deploys perf reap [--dry-run|--yes] [--pid N] [--all] [--json]" >&2; return 2 ;; esac
    shift
  done
  lvl="$(perf_snapshot 2>/dev/null | jq -r .level 2>/dev/null || echo green)"
  list="$(perf_reap_list "$lvl")" || return 0
  if [ -n "$only" ]; then
    sel="$(jq -c --argjson p "$only" '[.[] | select(.pid == $p)]' <<<"$list")"
    [ "$sel" != '[]' ] || { echo "perf reap: $only is not a listed check, test browser, MCP server, npm exec or dev server (deploys perf reap --all)" >&2; return 1; }
  else sel="$(jq -c '[.[] | select(.auto)]' <<<"$list")"; fi
  if [ "${json:-0}" = 1 ]; then jq -c --argjson y "$doit" --arg l "$lvl" '{level:$l, stopping:($y == 1), runs:.}' <<<"$( [ "$all" = 1 ] && echo "$list" || jq -c '[.[] | select(.verdict != "ok")]' <<<"$list")"
  elif [ "$quiet" = 0 ]; then
    jq -r --arg h "$HOME" '.[] | "\(.verdict | ascii_upcase | . + "       " | .[:8]) \(.pid)  \(.class)  \(.ageS / 60 | floor) min  \(.mb) MB  \(if .reason != "" then .reason + "  " else "" end)\((.folder // "") | sub("^" + $h; "~"))\(if .verdict != "ok" and (.auto | not) then "  (report only)" else "" end)"' \
      <<<"$( [ "$all" = 1 ] && echo "$list" || jq -c '[.[] | select(.verdict != "ok")]' <<<"$list")"
    [ "$(jq -r '[.[] | select(.verdict != "ok")] | length' <<<"$list")" != 0 ] || echo "perf reap: nothing hangs or is orphaned."
  fi
  [ "$doit" = 1 ] || { [ "$sel" = '[]' ] || [ "$quiet" = 1 ] || [ "${json:-0}" = 1 ] || echo "(dry run, nothing was stopped. deploys perf reap --yes stops the ones not marked report only.)"; return 0; }
  while IFS= read -r r; do
    [ -n "$r" ] || continue
    for pid in $(jq -r '.pids[]' <<<"$r"); do
      id="$(perf_ident "$pid")"; [ -n "$id" ] || continue
      kill -TERM "$pid" 2>/dev/null && ids="$ids$pid"$'\t'"$id"$'\n'
    done
    n=$((n + 1)); freed=$((freed + $(jq -r .mb <<<"$r")))
    perf_log "reap: stopped $(jq -r '"\(.pid) \(.class) (\(.verdict): \(.reason)) after \(.ageS / 60 | floor) min, \(.mb) MB, \(.pids | length) processes, in \(.folder // "?"): \(.args)"' <<<"$r")"
  done <<<"$(jq -c '.[]' <<<"$sel")"
  if [ -n "$ids" ]; then
    sleep "${DEPLOYS_PERF_KILL_AFTER:-10}"
    while IFS="$(printf '\t')" read -r pid id; do
      [ -n "$pid" ] || continue
      if [ "$(perf_ident "$pid")" = "$id" ]; then kill -KILL "$pid" 2>/dev/null && perf_log "reap: KILL $pid (did not stop on TERM)"; fi
    done <<<"$ids"
  fi
  [ "$n" = 0 ] && return 0
  local gb; gb="$(awk -v m="$freed" 'BEGIN { printf "%.1f", m / 1024 }')"
  [ "$quiet" = 1 ] || [ "${json:-0}" = 1 ] || echo "Stopped $n process tree(s), about $gb GB RSS."
  [ "$notify" = 0 ] || perf_notify "Stopped $n hung or orphaned process tree(s)" "About $gb GB RSS. Details: ~/.config/deploys/perf/clean.log"
}

perf_notify() {  # perf_notify <title> <text>
  if [ -n "${DEPLOYS_PERF_NOTIFY_CMD:-}" ]; then "$DEPLOYS_PERF_NOTIFY_CMD" "$1" "$2"; return; fi
  command -v osascript >/dev/null 2>&1 || return 0
  osascript -e 'on run a' -e 'display notification (item 2 of a) with title (item 1 of a)' -e 'end run' "$1" "$2" >/dev/null 2>&1 || true
}

# perf_tick: one run of the agent. Writes perf/status.json (the app and the MCP server read it), a sample, the
# red-since time; notifies once red for notifyAfterMin (at most every notifyEveryMin); cleanup every 10 min.
perf_tick_main() {
  local raw procs conf snap now lvl since last top lastc
  conf="$(perf_conf)"; raw="$(perf_raw)" || return 0; procs="$(perf_procs)" || return 0
  now="${raw%% *}"
  snap="$(perf_judge "$raw" "$procs" "$conf" "$(perf_prev_sample "$now" 30)")" || return 0
  perf_record "$now" "$(echo "$raw" | awk '{print $11}')"
  snap="$(perf_with_limits "$snap" "$conf" 2>/dev/null || echo "$snap")"
  perf_history_add "$snap"
  mkdir -p "$PERF_DIR"; echo "$snap" > "$PERF_DIR/status.json.$$" && mv -f "$PERF_DIR/status.json.$$" "$PERF_DIR/status.json"
  lvl="$(jq -r .level <<<"$snap")"
  if [ "$lvl" = red ]; then
    [ -f "$PERF_DIR/red-since" ] || echo "$now" > "$PERF_DIR/red-since"
    since="$(cat "$PERF_DIR/red-since")"; last="$(cat "$PERF_DIR/last-notify" 2>/dev/null || echo 0)"
    if [ $(( now - since )) -ge $(( $(jq -r '.notifyAfterMin | floor' <<<"$conf") * 60 )) ] \
       && [ $(( now - last )) -ge $(( $(jq -r '.notifyEveryMin | floor' <<<"$conf") * 60 )) ]; then
      top="$(jq -r '[.groups[] | select(.key != "other")][:3] | map("\(.label) \(.mb / 1024 * 10 | round / 10) GB") | join(", ")' <<<"$snap")"
      perf_notify "Mac overloaded for $(( (now - since) / 60 )) min" "Biggest: $top. $(jq -r '.reasons[0] // ""' <<<"$snap")"
      echo "$now" > "$PERF_DIR/last-notify"; perf_log "notify: red for $(( (now - since) / 60 )) min ($top)"
    fi
  else
    rm -f "$PERF_DIR/red-since"
  fi
  if [ "$(jq -r '(.reap // {}).enabled // false' <<<"$conf")" = true ] && [ $(( now - $(cat "$PERF_DIR/last-reap" 2>/dev/null || echo 0) )) -ge 300 ]; then
    echo "$now" > "$PERF_DIR/last-reap"; json=0 perf_reap_main --yes --quiet --notify || true
  fi
  if declare -F perfdocker_idle_tick >/dev/null && [ $(( now - $(cat "$PERF_DIR/last-docker" 2>/dev/null || echo 0) )) -ge 300 ]; then
    echo "$now" > "$PERF_DIR/last-docker"; perfdocker_idle_tick "$lvl" "$(jq -r '.memoryTight // false' <<<"$snap")" || true
  fi
  ! declare -F perf_shed_tick >/dev/null || perf_shed_tick "$snap" || true
  ! declare -F perf_finished_tick >/dev/null || perf_finished_tick || true
  declare -F perf_caches >/dev/null && perf_caches measure >/dev/null 2>&1 &
  lastc="$(cat "$PERF_DIR/last-clean" 2>/dev/null || echo 0)"
  if [ $(( now - lastc )) -ge 600 ]; then
    echo "$now" > "$PERF_DIR/last-clean"
    if [ "$(jq -r .clean <<<"$conf")" = true ]; then json=0 perf_clean_main --yes --quiet; else json=0 perf_clean_main --dry-run --quiet; fi
  fi
  return 0
}

perf_hook_json() {  # the PreToolUse entry for ~/.claude/settings.json
  jq -n --arg c "$HOME/.claude/hooks/perf-gate.sh" '{matcher:"Bash", hooks:[{type:"command", command:$c, timeout:660, statusMessage:"Waiting for room on the Mac (perf gate) …"}]}'
}

perfclean_main() {
  local sub="$1"; shift
  case "$sub" in
    clean) perf_clean_main "$@" ;;
    reap) perf_reap_main "$@" ;;
    tick) perf_tick_main ;;
    hook)
      echo "The Claude Code hook (integrations/claude-code/hooks/perf-gate.sh): copy it to ~/.claude/hooks/perf-gate.sh"
      echo "and add this entry to \"hooks\".\"PreToolUse\" in ~/.claude/settings.json (nothing is changed here):"
      perf_hook_json ;;
    install)
      local yes=0 clean=0 dock=0 reap=0 shed=0 fin=0 a
      for a in "$@"; do case "$a" in --yes) yes=1 ;; --clean) clean=1 ;; --docker) dock=1 ;; --reap) reap=1 ;; --shed) shed=1 ;; --stop-finished) fin=1 ;; *) echo "Usage: deploys perf install [--reap] [--clean] [--docker] [--shed] [--stop-finished] --yes" >&2; return 2 ;; esac; done
      [ "$yes" = 1 ] || { echo "perf install writes a launchd agent ($PERF_LABEL, every minute: status, notification, cleanup report). Add --yes to do it; --reap lets it stop hung check runs, --clean orphaned dev processes, --docker idle Docker stacks, --shed unused dev servers and idle Docker stacks under memory pressure, --stop-finished dev servers of finished work." >&2; return 2; }
      declare -F job_on >/dev/null || { echo "perf install runs through deploys (deploys perf install --yes)." >&2; return 1; }
      mkdir -p "$(dirname "$PERF_CONF")"
      [ -f "$PERF_CONF" ] || echo '{}' > "$PERF_CONF"
      jq -c --argjson c "$clean" --argjson d "$dock" --argjson r "$reap" --argjson s "$shed" --argjson f "$fin" '.clean = ($c == 1) | .docker = ((.docker // {}) + {autoStop:($d == 1)}) | .reap = ((.reap // {}) + {enabled:($r == 1)}) | .shed = ((.shed // {}) + {enabled:($s == 1)}) | .stopFinished = ((.stopFinished // {}) + {enabled:($f == 1)})' "$PERF_CONF" > "$PERF_CONF.new" && mv -f "$PERF_CONF.new" "$PERF_CONF"
      job_on "$PERF_LABEL" 60 deploys-perf perf tick
      echo "Installed $PERF_LABEL: every minute status and samples, a notification when red for a while, cleanup every 10 min ($( [ "$clean" = 1 ] && echo "stops orphans" || echo "report only" )), Docker idle stop $( [ "$dock" = 1 ] && echo on || echo off ), hung check runs stopped every 5 min $( [ "$reap" = 1 ] && echo on || echo off ), shedding under memory pressure $( [ "$shed" = 1 ] && echo on || echo off ), dev servers of finished work stopped $( [ "$fin" = 1 ] && echo on || echo off ). Log: $PERF_DIR/clean.log" ;;
    uninstall)
      declare -F job_off >/dev/null || { echo "perf uninstall runs through deploys." >&2; return 1; }
      job_off "$PERF_LABEL"; echo "Removed $PERF_LABEL." ;;
  esac
}
