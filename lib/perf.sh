# shellcheck shell=bash
# lib/perf.sh — the performance guard: `deploys perf status|gate|wait`. How full the Mac is (kernel memory pressure,
# swap-out rate, free swap, load, the biggest consumers by group) and an admission gate that lets a heavy command
# (tsc, vitest, next build ...) start only while there is room. Read-only: nothing here stops a process; the cleanup
# is lib/perfclean.sh. Sourced by deploys, or run on its own (`bash lib/perf.sh wait`) by the Claude Code hook, which
# then does not pay for parsing all of deploys. Bash 3.2. Tests set DEPLOYS_PERF_FIXTURE to a folder with the
# outputs of sysctl, vm_stat and ps instead of the real ones.
#
# Signals (docs/PERF.md): kern.memorystatus_vm_pressure_level (1 normal, 2 warn, 4 critical), the rate of the
# cumulative "Swapouts" counter of vm_stat (MB/min between two readings), free swap, load1 per core and the number of
# heavy checks already running. memory_pressure's "free %" (kern.memorystatus_level) counts inactive and compressible
# pages and ignores swap, so it is only a side signal (red under 10 %).

PERF_DIR="${CONFIG_DIR:-${DEPLOYS_CONFIG:-$HOME/.config/deploys}}/perf"
PERF_CONF="${CONFIG_DIR:-${DEPLOYS_CONFIG:-$HOME/.config/deploys}}/perf.json"

perf_src() {  # perf_src <name> <command…>: the fixture file of that name in tests, else the command's output
  local n="$1"; shift
  if [ -n "${DEPLOYS_PERF_FIXTURE:-}" ]; then cat "$DEPLOYS_PERF_FIXTURE/$n" 2>/dev/null; else "$@" 2>/dev/null; fi
}
perf_now() { if [ -n "${DEPLOYS_PERF_NOW:-}" ]; then echo "$DEPLOYS_PERF_NOW"; else date +%s; fi; }

# The thresholds: defaults, overridden by ~/.config/deploys/perf.json. One JSON object.
perf_conf() {
  local f='{}'
  [ -f "$PERF_CONF" ] && f="$(jq -c 'if type == "object" then . else {} end' "$PERF_CONF" 2>/dev/null || echo '{}')"
  jq -nc --argjson f "$f" '{maxLoadPerCore:2.5, redLoadPerCore:4, maxSwapoutMBPerMin:20, redSwapoutMBPerMin:50,
    minSwapFreeMB:2048, redSwapFreeMB:1536, maxChecks:0, maxWait:"10m", stagger:20, pollEvery:10, clean:false,
    notifyAfterMin:5, notifyEveryMin:30} + $f'
}

# perf_raw: one line `epoch level freepct memMB ncpu load1 load5 load15 swapTotalMB swapUsedMB swapouts pagesize`.
perf_raw() {
  local sc vm
  sc="$(perf_src sysctl sysctl -n kern.memorystatus_vm_pressure_level kern.memorystatus_level hw.memsize hw.ncpu vm.loadavg vm.swapusage || true)"
  vm="$(perf_src vm_stat vm_stat || true)"
  [ -n "$sc" ] || return 1
  { echo "$sc"; echo "@@"; echo "$vm"; } | awk -v now="$(perf_now)" '
    $0 == "@@" { vm = 1; next }
    !vm { n++
      if (n == 1) lvl = $1; else if (n == 2) free = $1; else if (n == 3) mem = int($1 / 1048576); else if (n == 4) cpu = $1
      else if ($1 == "{") { l1 = $2; l5 = $3; l15 = $4 }
      else if ($0 ~ /total =/) { for (i = 1; i <= NF; i++) { v = $(i + 2); sub(/M$/, "", v)
          if ($i == "total") st = v; if ($i == "used") su = v } }
      next }
    /page size of/ { for (i = 1; i <= NF; i++) if ($i == "of") ps = $(i + 1) }
    /^Swapouts:/ { so = $2; sub(/\./, "", so) }
    END { if (lvl == "" || cpu == "") exit 1
      printf "%s %s %s %s %s %s %s %s %d %d %s %s\n", now, lvl, (free == "" ? -1 : free), mem, cpu, l1 + 0, l5 + 0, l15 + 0,
        st + 0, su + 0, (so == "" ? 0 : so), (ps == "" ? 16384 : ps) }'
}

# awk functions shared by perf.sh and perfclean.sh: base(), script() (the program a runner such as node, npm exec,
# npx or rtk runs) and ischeck() (a lint, typecheck, test or build run: the processes the cap counts and reap stops).
PERF_AWK_FN='
    function base(x) { sub(/.*\//, "", x); gsub(/[()]/, "", x); return x }
    function script(a,   t, n, i, w) { n = split(a, t, " ")
      for (i = 2; i <= n && i <= 7; i++) { w = t[i]; if (w ~ /^-/ || w == "exec" || w == "run" || w == "x" || w == "dlx") continue; return base(w) }
      return "" }
    function ischeck(a,   w, s) { w = base(substr(a, 1, index(a " ", " ") - 1))
      if (a ~ /next dev|next-server|vite( |$)|mcp-server|-mcp( |$)|\/mcp\/server|modelcontextprotocol/) return 0
      if (w ~ /^next-build/ || a ~ /jest-worker|processChild\.js|pool_entry|@typescript\/native-preview|typescript-darwin/) return 1
      if (w ~ /^(tsc|tsgo|vitest|jest|eslint|playwright|xcodebuild)$/) return 1
      if (w ~ /^(node|bun|deno|npm|npx|pnpm|yarn|rtk)$/) { s = script(a)
        if (s ~ /^(tsc[0-9]*|tsgo|vitest|jest|eslint|playwright)$/ || (s == "next" && a ~ / build( |$)/)) return 1
        if (w ~ /^(npm|pnpm|yarn|bun|rtk)$/ && s ~ /^(lint|typecheck|type-check|test|verify|build|e2e)(:|$)/) return 1 }
      return 0 }
'

# perf_procs: JSON {groups:[{key,label,count,mb}], top:[{pid,mb,group,name}], sessions, checks}. One ps pass.
perf_procs() {
  perf_src ps ps -axo pid=,ppid=,rss=,args= | awk "$PERF_AWK_FN"'
    function grp(a) {
      if (a ~ /Claude\.app\/Contents\/Helpers\/disclaimer/) return "claudeapp"
      if (a ~ /claude-code\/[^ ]*\/claude( |$)|\/\.local\/bin\/claude( |$)|^claude( |$)/) return "claude"
      if (a ~ /Claude\.app\//) return "claudeapp"
      if (a ~ /Google Chrome|Chromium/) return "chrome"
      if (a ~ /com\.docker|Docker\.app|Virtualization\.VirtualMachine|qemu/) return "docker"
      if (ischeck(a)) return "checks"
      if (a ~ /[Mm][Cc][Pp]/ && a ~ /node|python|uvx?( |$)|npm|npx|bun|deno/) return "mcp"
      if (a ~ /next dev|next-server|vite( |$)|webpack-dev|nodemon|esbuild/) return "dev"
      if (a ~ /Xcode\.app|swiftc|swift-frontend|sourcekit|clang|\/ld( |$)/) return "xcode"
      return "other" }
    { pid = $1; pp = $2; rss = $3; a = $0; sub(/^ *[0-9]+ +[0-9]+ +[0-9]+ +/, "", a)
      g = grp(a); n[g]++; mb[g] += rss / 1024; par[pid] = pp; G[pid] = g; A[pid] = a; R[pid] = rss }
    END {
      lab["claude"] = "Claude Code sessions"; lab["claudeapp"] = "Claude app"; lab["chrome"] = "Chrome"; lab["docker"] = "Docker and VMs"
      lab["mcp"] = "MCP servers"; lab["checks"] = "Checks and builds"; lab["dev"] = "Dev servers"; lab["xcode"] = "Xcode and Swift"; lab["other"] = "Other"
      # A check counts once: its workers (a parent that is a check too) do not.
      for (p in G) if (G[p] == "checks" && G[par[p]] != "checks") roots++
      printf "{\"sessions\":%d,\"checks\":%d,\"groups\":[", n["claude"], roots
      s = ""; for (g in n) { printf "%s{\"key\":\"%s\",\"label\":\"%s\",\"count\":%d,\"mb\":%d}", s, g, lab[g], n[g], mb[g]; s = "," }
      printf "],\"top\":["
      s = ""; for (k = 0; k < 5; k++) { best = ""; for (p in R) if (!(p in used) && (best == "" || R[p] > R[best])) best = p
        if (best == "") break; used[best] = 1; nm = A[best]; sub(/ .*/, "", nm); sub(/.*\//, "", nm); gsub(/[\\"]/, "", nm)
        printf "%s{\"pid\":%d,\"mb\":%d,\"group\":\"%s\",\"name\":\"%s\"}", s, best, R[best] / 1024, G[best], nm; s = "," }
      print "]}" }' | jq -c '.groups |= sort_by(-.mb)'
}

# The newest sample at least <min> seconds older than <now> and not older than 10 minutes: "epoch swapouts" or nothing.
perf_prev_sample() {  # perf_prev_sample <now> <min age>
  [ -f "$PERF_DIR/samples.tsv" ] || return 0
  awk -v now="$1" -v min="$2" '$1 <= now - min && $1 >= now - 600 { e = $1; s = $2 } END { if (e != "") print e, s }' "$PERF_DIR/samples.tsv"
}
perf_record() {  # perf_record <epoch> <swapouts>: append, keep the last 300 lines
  mkdir -p "$PERF_DIR" 2>/dev/null || return 0
  printf '%s %s\n' "$1" "$2" >> "$PERF_DIR/samples.tsv" 2>/dev/null || return 0
  if [ "$(wc -l < "$PERF_DIR/samples.tsv")" -gt 400 ]; then
    tail -n 300 "$PERF_DIR/samples.tsv" > "$PERF_DIR/samples.tsv.$$" && mv -f "$PERF_DIR/samples.tsv.$$" "$PERF_DIR/samples.tsv"
  fi
}

# perf_judge <raw line> <procs JSON> <conf JSON> [<prev "epoch swapouts">]: the status JSON with level and admit.
perf_judge() {
  local prev="${4:-}" t lvl free mem cpu l1 l5 l15 st su so pg
  read -r t lvl free mem cpu l1 l5 l15 st su so pg <<<"$1"
  jq -nc --argjson t "$t" --argjson lvl "$lvl" --argjson free "$free" --argjson mem "$mem" --argjson cpu "$cpu" \
    --argjson l1 "$l1" --argjson l5 "$l5" --argjson l15 "$l15" --argjson st "$st" --argjson su "$su" --argjson so "$so" \
    --argjson pg "$pg" --argjson p "$2" --argjson c "$3" --arg prev "$prev" '
    ($prev | split(" ") | map(select(length > 0) | tonumber)) as $pv
    | (if ($pv | length) == 2 and $t > $pv[0] then ((($so - $pv[1]) * $pg / 1048576) * 60 / ($t - $pv[0]) | if . < 0 then 0 else . end | . * 10 | round / 10) else null end) as $rate
    | (if $st == 0 then null else ($st - $su) end) as $sfree
    | (if $c.maxChecks > 0 then $c.maxChecks else ([2, ($cpu / 4 | floor)] | max) end) as $maxc
    | ($l1 / $cpu * 100 | round / 100) as $lpc
    | ([ (select($lvl >= 4) | "kernel memory pressure is critical"),
         (select($sfree != null and $sfree < $c.redSwapFreeMB and ($rate // 0) > $c.redSwapoutMBPerMin) | "swap almost full and still growing"),
         (select($lpc > $c.redLoadPerCore) | "load \($l1) is over \($c.redLoadPerCore) per core"),
         (select($free >= 0 and $free < 10) | "only \($free) % memory free") ]) as $red
    | ([ (select($lvl == 2) | "kernel memory pressure is at warn"),
         (select(($rate // 0) >= 1) | "swapping out \($rate) MB/min"),
         (select($l1 >= $cpu) | "load \($l1) on \($cpu) cores"),
         (select($p.checks >= $maxc) | "\($p.checks) heavy checks running (cap \($maxc))") ]) as $warn
    | ([ (select($lvl >= 4) | "pressure critical"),
         (select($lvl == 2 and ($rate == null)) | "pressure at warn, swap rate not known yet"),
         (select($lvl == 2 and $rate != null and $rate >= $c.maxSwapoutMBPerMin) | "pressure at warn and swapping \($rate) MB/min"),
         (select($lvl == 2 and $sfree != null and $sfree < $c.minSwapFreeMB) | "pressure at warn and only \($sfree) MB swap free"),
         (select($lpc >= $c.maxLoadPerCore and $lpc <= $c.redLoadPerCore) | "load \($l1) is over \($c.maxLoadPerCore) per core"),
         (select($p.checks >= $maxc) | "\($p.checks) heavy checks already running (cap \($maxc))") ]) as $hold
    | { time:$t, level:(if ($red | length) > 0 then "red" elif ($warn | length) == 0 and ($rate == null or $rate < 1) then "green" else "yellow" end),
        reasons:(if ($red | length) > 0 then $red else $warn end),
        admit:(($red | length) == 0 and ($hold | length) == 0), hold:($red + $hold | unique),
        pressure:{level:$lvl, name:({"1":"normal","2":"warn","4":"critical"}[$lvl | tostring] // "unknown")},
        memory:{totalMB:$mem, freePct:(if $free < 0 then null else $free end)},
        swap:{totalMB:$st, usedMB:$su, freeMB:$sfree, swapoutMBPerMin:$rate},
        load:{one:$l1, five:$l5, fifteen:$l15, cores:$cpu, perCore:$lpc},
        checks:{running:$p.checks, cap:$maxc}, claudeSessions:$p.sessions, groups:$p.groups, top:$p.top }'
}

# perf_snapshot [<prev>]: raw + procs + judge. Without <prev>, the newest stored sample ≥ 30 s old is used.
perf_snapshot() {
  local raw procs prev="${1:-}"
  raw="$(perf_raw)" || return 1; procs="$(perf_procs)" || return 1
  [ -n "$prev" ] || prev="$(perf_prev_sample "${raw%% *}" 30)"
  perf_judge "$raw" "$procs" "$(perf_conf)" "$prev"
}

perf_print() {  # stdin: status JSON
  jq -r '
    def mb: if . == null then "–" elif . >= 1024 then "\(. / 1024 * 10 | round / 10) GB" else "\(.) MB" end;
    "Performance: \(.level | ascii_upcase)" + (if (.reasons | length) > 0 then " – " + (.reasons | join("; ")) else "" end),
    "  memory pressure \(.pressure.name) · \(.memory.freePct // "–") % free (of \(.memory.totalMB | mb))",
    "  swap \(.swap.usedMB | mb) used, \(.swap.freeMB | mb) free · swapping out \(.swap.swapoutMBPerMin // "–") MB/min",
    "  load \(.load.one) / \(.load.five) / \(.load.fifteen) on \(.load.cores) cores (\(.load.perCore) per core)",
    "  \(.claudeSessions) Claude Code sessions · \(.checks.running) heavy checks running (cap \(.checks.cap))",
    "  heavy command now: " + (if .admit then "may start" else "waits (" + (.hold | join("; ")) + ")" end),
    "", "  BIGGEST GROUPS",
    (.groups[:6][] | "    \(.mb | mb | . + "        " | .[:9]) \(.label) (\(.count))"),
    "", "  TOP PROCESSES", (.top[] | "    \(.mb | mb | . + "        " | .[:9]) \(.name) [\(.group)] pid \(.pid)")'
}

perf_dur() {  # perf_dur 10m|90s|1h|90 → seconds
  case "$1" in *m) echo $(( ${1%m} * 60 )) ;; *h) echo $(( ${1%h} * 3600 )) ;; *s) echo "${1%s}" ;; *) echo "$1" ;; esac
}

perf_lock() {  # mkdir lock with pid and time; a lock older than 30 s or of a dead process is broken
  local l="$PERF_DIR/admit.lock" i=0 pid age
  mkdir -p "$PERF_DIR" 2>/dev/null || return 1
  while ! mkdir "$l" 2>/dev/null; do
    pid="$(cat "$l/pid" 2>/dev/null || true)"; age=$(( $(date +%s) - $(stat -c %Y "$l" 2>/dev/null || stat -f %m "$l" 2>/dev/null || date +%s) ))
    if [ "$age" -gt 30 ] || { [ -n "$pid" ] && ! kill -0 "$pid" 2>/dev/null; }; then rm -rf "$l"; continue; fi
    i=$((i + 1)); [ "$i" -lt 50 ] || return 1; sleep 0.2
  done
  echo "$$" > "$l/pid"
}
perf_unlock() { rm -rf "$PERF_DIR/admit.lock"; }

# perf_wait_main [--max-wait 10m] [--fail-open] [--quiet]: 0 when a heavy command may start, 75 when the Mac stayed red
# for the whole wait (and no --fail-open). Every error of the guard itself is 0: it never stops work on its own fault.
perf_wait_main() {
  local maxw="" failopen=0 quiet=0 conf start now snap prev="" raw last="" lastsay=0 stag poll lvl
  while [ "$#" -gt 0 ]; do
    case "$1" in
      --max-wait) maxw="${2:-}"; shift ;;
      --fail-open) failopen=1 ;;
      --quiet) quiet=1 ;;
      *) echo "Unknown option $1. Usage: deploys perf wait [--max-wait 10m] [--fail-open] [--quiet]" >&2; return 2 ;;
    esac
    shift
  done
  [ "${DEPLOYS_PERF_GATE:-1}" != 0 ] || return 0
  conf="$(perf_conf 2>/dev/null)" || return 0
  [ -n "$maxw" ] || maxw="$(jq -r .maxWait <<<"$conf")"
  maxw="$(perf_dur "$maxw")"; case "$maxw" in ''|*[!0-9]*) maxw=600 ;; esac
  stag="$(jq -r '.stagger | floor' <<<"$conf" 2>/dev/null || echo 20)"; poll="$(jq -r '.pollEvery | floor' <<<"$conf" 2>/dev/null || echo 10)"
  start="$(date +%s)"
  while :; do
    raw="$(perf_raw 2>/dev/null)" || return 0
    [ -n "$prev" ] || prev="$(perf_prev_sample "${raw%% *}" 30)"
    snap="$(perf_judge "$raw" "$(perf_procs 2>/dev/null || echo '{"sessions":0,"checks":0,"groups":[],"top":[]}')" "$conf" "$prev" 2>/dev/null)" || return 0
    [ -n "$snap" ] || return 0
    # The next reading measures the swap rate against this one (at least 5 s apart).
    prev="${raw%% *} $(echo "$raw" | awk '{print $11}')"
    if [ "$(jq -r .admit <<<"$snap")" = true ]; then
      perf_lock || return 0
      now="$(date +%s)"
      if [ $(( now - $(cat "$PERF_DIR/last-admit" 2>/dev/null || echo 0) )) -ge "$stag" ]; then
        echo "$now" > "$PERF_DIR/last-admit"; perf_unlock
        [ -z "$last" ] || [ "$quiet" = 1 ] || echo "perf: room now, starting." >&2
        return 0
      fi
      perf_unlock
      last="another heavy command started just now"
    else
      last="$(jq -r '.hold | join("; ")' <<<"$snap")"
    fi
    now="$(date +%s)"; lvl="$(jq -r .level <<<"$snap")"
    if [ $(( now - start )) -ge "$maxw" ]; then
      if [ "$lvl" = red ] && [ "$failopen" = 0 ]; then
        echo "perf: the Mac is overloaded ($last). Not started after waiting $(( (now - start) / 60 )) min. Do not retry right away: wait some minutes, or run it in a cloud session." >&2
        return 75
      fi
      [ "$quiet" = 1 ] || echo "perf: waited $(( (now - start) / 60 )) min ($last); starting anyway." >&2
      return 0
    fi
    if [ "$quiet" = 0 ] && [ $(( now - lastsay )) -ge 60 ]; then
      echo "perf: waiting for room ($last) – $(( now - start ))s of ${maxw}s" >&2; lastsay="$now"
    fi
    sleep "$poll"
  done
}

perf_gate_main() {  # perf gate [options] -- <command…>: wait, then run it with its exit code
  local opts=() rc
  # Options first; the command starts at `--` or at the first word that is not an option (deploys itself drops `--`).
  while [ "$#" -gt 0 ]; do
    case "$1" in
      --) shift; break ;;
      --max-wait) opts+=("$1" "${2:-}"); shift ;;
      --fail-open|--quiet) opts+=("$1") ;;
      *) break ;;
    esac
    shift
  done
  [ "$#" -gt 0 ] || { echo "Usage: deploys perf gate [--max-wait 10m] [--fail-open] [--quiet] -- <command…>" >&2; return 2; }
  perf_wait_main ${opts[@]+"${opts[@]}"}; rc=$?
  [ "$rc" = 0 ] || return "$rc"
  "$@"
}

perf_status_main() {
  local raw procs snap
  raw="$(perf_raw)" || { echo "perf: could not read the system figures (sysctl)" >&2; return 1; }
  procs="$(perf_procs)" || return 1
  snap="$(perf_judge "$raw" "$procs" "$(perf_conf)" "$(perf_prev_sample "${raw%% *}" 30)")" || return 1
  [ "${DEPLOYS_PERF_NORECORD:-0}" = 1 ] || perf_record "${raw%% *}" "$(echo "$raw" | awk '{print $11}')"
  if [ "${json:-0}" = 1 ]; then echo "$snap"; else perf_print <<<"$snap"; fi
}

perf_main() {
  local sub="${1:-status}"; [ "$#" -eq 0 ] || shift
  local a rest=()
  # --json belongs to perf itself, not to the command a gate runs.
  if [ "$sub" = gate ]; then rest=("$@"); else for a in "$@"; do case "$a" in --json) json=1 ;; *) rest+=("$a") ;; esac; done; fi
  case "$sub" in
    status) perf_status_main ;;
    wait) perf_wait_main ${rest[@]+"${rest[@]}"} ;;
    gate) perf_gate_main ${rest[@]+"${rest[@]}"} ;;
    docker|consumers|stop|wake)
      declare -F perfdocker_main >/dev/null || { echo "perf $sub needs lib/perfdocker.sh next to perf.sh" >&2; return 1; }
      perfdocker_main "$sub" ${rest[@]+"${rest[@]}"} ;;
    clean|reap|tick|install|uninstall|hook)
      declare -F perfclean_main >/dev/null || { echo "perf $sub needs lib/perfclean.sh next to perf.sh" >&2; return 1; }
      perfclean_main "$sub" ${rest[@]+"${rest[@]}"} ;;
    *) echo "Usage: deploys perf status|wait|gate|clean|reap|consumers|docker|stop|wake|install|uninstall|hook [--json]" >&2; return 2 ;;
  esac
}

# Run on its own: `bash lib/perf.sh wait --max-wait 10m` (the hook) or `bash lib/perf.sh status --json`.
if [ "${BASH_SOURCE[0]}" = "$0" ]; then
  json=0
  _pd="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
  # shellcheck source=lib/perfclean.sh
  [ -f "$_pd/perfclean.sh" ] && . "$_pd/perfclean.sh"
  # shellcheck source=lib/perfdocker.sh
  [ -f "$_pd/perfdocker.sh" ] && . "$_pd/perfdocker.sh"
  perf_main "$@"; exit $?
fi
