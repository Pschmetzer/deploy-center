# shellcheck shell=bash
# lib/perfdocker.sh — the performance guard's view of everything else that eats memory: Docker stacks (stop and wake
# by hand, optional idle stop), booted simulators, and caches that grow (reported only). `deploys perf docker`,
# `perf stop <stack> --yes`, `perf wake <stack>`, `perf consumers`. Bash 3.2. Fixtures in tests: DEPLOYS_PERF_FIXTURE
# (files dockerps, dockerstats, established, simctl).
#
# A stack is a compose project (label com.docker.compose.project), a Supabase CLI project (label
# com.supabase.cli.project, or the name supabase_<service>_<project>), or else one container. Only `docker stop` and
# `docker start`: containers, volumes and data stay. Supabase stops its db last and starts it first.
# Idle stop is OFF unless perf.json has "docker":{"autoStop":true}: the Docker VM gives freed memory back to macOS
# slowly, so stopping a stack helps less than Docker Desktop's own Resource Saver (it stops the VM when nothing runs).
# A stack counts as active while a TCP connection to one of its ports is open, its CPU is over 1 %, or a Claude Code
# session works in its compose folder. Stacks in "docker":{"always":[...]} are never stopped.

perfdocker_have() { [ -n "${DEPLOYS_PERF_FIXTURE:-}" ] || { command -v docker >/dev/null 2>&1 && docker ps -q >/dev/null 2>&1; }; }

# perfdocker_list: JSON array of stacks {stack, kind, folder, running, total, memMB, cpu, ports, ids, dbIds, active, always}.
perfdocker_list() {
  local ps stats est conf sessions
  ps="$(perf_src dockerps docker ps -a --format '{{.ID}}\t{{.Names}}\t{{.State}}\t{{.Label "com.docker.compose.project"}}\t{{.Label "com.supabase.cli.project"}}\t{{.Label "com.docker.compose.project.working_dir"}}\t{{.Ports}}' || true)"
  stats="$(perf_src dockerstats docker stats --no-stream --format '{{.ID}}\t{{.MemUsage}}\t{{.CPUPerc}}' || true)"
  # Local ports of open TCP connections (both ends), one per line.
  est="$(perf_src established lsof -nP -iTCP -sTCP:ESTABLISHED -Fn | sed -n 's/^n//p' | tr -- '->' '\n\n' | sed -n 's/.*:\([0-9][0-9]*\)$/\1/p' | sort -u | tr '\n' ' ' || true)"
  sessions="$(perf_session_cwds | tr '\n' '\t')"
  conf="$(perf_conf)"
  printf '%s\n@@\n%s\n' "$ps" "$stats" | awk -F'\t' -v est=" $est " -v sess="$sessions" '
    $0 == "@@" { part = 1; next }
    part == 1 { if ($1 == "") next; id = substr($1, 1, 12); m = $2; sub(/ .*/, "", m); v = m + 0
      if (m ~ /GiB/) v *= 1024; else if (m ~ /KiB/) v /= 1024; else if (m ~ /[^MKG]B$/ && m !~ /MiB/) v /= 1048576
      mem[id] = v; c = $3; sub(/%/, "", c); cpu[id] = c + 0; next }
    $1 != "" { id = substr($1, 1, 12); name = $2; st = $3
      if ($4 != "") { k = $4; kind = "compose" } else if ($5 != "") { k = $5; kind = "supabase" }
      else if (name ~ /^supabase_[a-z]+_/) { k = name; sub(/^supabase_[a-z]+_/, "", k); kind = "supabase" } else { k = name; kind = "container" }
      if (!(k in K)) { K[k] = kind; order[++n] = k }
      if ($6 != "") F[k] = $6; ids[k] = ids[k] " " id; tot[k]++
      if (name ~ /^supabase_db_/ || name ~ /(^|[-_])(db|postgres|pg)([-_0-9]|$)/) dbs[k] = dbs[k] " " id
      if (st == "running") { run[k]++; ID[id] = k }
      np = split($7, pp, ", "); for (i = 1; i <= np; i++) if (pp[i] ~ /:[0-9]+->/) { p = pp[i]; sub(/->.*/, "", p); sub(/.*:/, "", p); ports[k] = ports[k] " " p } }
    END {
      for (id in ID) { k = ID[id]; M[k] += mem[id]; C[k] += cpu[id] }
      printf "["
      for (j = 1; j <= n; j++) { k = order[j]; act = 0
        np = split(ports[k], pp, " "); for (i = 1; i <= np; i++) if (index(est, " " pp[i] " ")) act = 1
        if (C[k] > 1) act = 1
        if (F[k] != "") { ns = split(sess, ss, "\t"); for (i = 1; i <= ns; i++) if (ss[i] != "" && (index(ss[i] "/", F[k] "/") == 1)) act = 1 }
        gsub(/"/, "", F[k])
        printf "%s{\"stack\":\"%s\",\"kind\":\"%s\",\"folder\":%s,\"running\":%d,\"total\":%d,\"memMB\":%d,\"cpu\":%.1f,\"ports\":\"%s\",\"ids\":\"%s\",\"dbIds\":\"%s\",\"active\":%s}", \
          (j > 1 ? "," : ""), k, K[k], (F[k] == "" ? "null" : "\"" F[k] "\""), run[k], tot[k], M[k], C[k], substr(ports[k], 2), substr(ids[k], 2), substr(dbs[k], 2), (act ? "true" : "false") }
      print "]" }' | jq -c --argjson c "$conf" '[.[] | .stack as $n | . + {always:(((($c.docker // {}).always) // []) | index($n) != null), ports:(.ports | split(" ") | unique | join(" "))}] | sort_by(-.memMB)'
}

# The working folders of the live Claude Code sessions, one per line (lsof once).
perf_session_cwds() {
  local pids
  pids="$(perf_src ps ps -axo pid=,args= | awk '/claude-code\/[^ ]*\/claude( |$)|\/\.local\/bin\/claude( |$)/ && !/disclaimer/ {printf "%s,", $1}')"
  [ -n "$pids" ] || return 0
  perf_src sessioncwd lsof -a -d cwd -p "${pids%,}" -Fn | sed -n 's/^n//p'
}

perfdocker_log() { perf_log "docker: $*"; }

# perfdocker_act stop|start <stack JSON>: docker stop/start of its containers, Supabase db last on stop and first on start.
perfdocker_act() {
  local what="$1" s="$2" ids=() dbs=() rest=() i missing=""
  read -r -a ids <<<"$(jq -r .ids <<<"$s")"; read -r -a dbs <<<"$(jq -r .dbIds <<<"$s")"
  for i in ${ids[@]+"${ids[@]}"}; do case " ${dbs[*]-} " in *" $i "*) ;; *) rest+=("$i") ;; esac; done
  for i in ${ids[@]+"${ids[@]}"}; do docker inspect "$i" >/dev/null 2>&1 || missing="$missing $i"; done
  [ -z "$missing" ] || echo "perf: containers no longer there (removed with compose down?):$missing" >&2
  if [ "$what" = stop ]; then
    { [ "${#rest[@]}" = 0 ] || docker stop "${rest[@]}" >/dev/null; } && { [ "${#dbs[@]}" = 0 ] || docker stop "${dbs[@]}" >/dev/null; }
  else
    { [ "${#dbs[@]}" = 0 ] || { docker start "${dbs[@]}" >/dev/null && sleep "${DEPLOYS_PERF_DB_WAIT:-3}"; }; } && { [ "${#rest[@]}" = 0 ] || docker start "${rest[@]}" >/dev/null; }
  fi
}

perfdocker_print() {  # stdin: stack list
  jq -r '"STACK\tKIND\tRUNNING\tRAM\tCPU\tACTIVE\tPORTS",
    (.[] | [.stack, .kind, "\(.running)/\(.total)", "\(.memMB) MB", "\(.cpu) %", (if .always then "always on" elif .running == 0 then "stopped" elif .active then "yes" else "idle" end), .ports] | @tsv)' | column -t -s "$(printf '\t')"
}

perfdocker_find() {  # perfdocker_find <name>: the stack JSON or an error
  local all s
  all="$(perfdocker_list)"; s="$(jq -c --arg n "$1" '[.[] | select(.stack == $n)][0] // empty' <<<"$all")"
  [ -n "$s" ] || { echo "perf: no Docker stack named $1 (deploys perf docker lists them)" >&2; return 1; }
  echo "$s"
}

# perfdocker_idle_tick <level>: the optional idle stop (autoStop), every 5 minutes from perf tick.
perfdocker_idle_tick() {
  local lvl="$1" conf now seen list idle s k last
  conf="$(perf_conf)"; [ "$(jq -r '(.docker // {}).autoStop // false' <<<"$conf")" = true ] || return 0
  perfdocker_have || return 0
  now="$(perf_now)"; seen="$PERF_DIR/docker-seen.json"; [ -f "$seen" ] || echo '{}' > "$seen"
  idle="$(jq -r --arg l "$lvl" '(.docker // {}) as $d | if $l == "red" then ($d.idleMinRed // 30) elif $l == "yellow" then ($d.idleMinYellow // 60) else ($d.idleMin // 120) end' <<<"$conf")"
  list="$(perfdocker_list)" || return 0
  # Started again after an idle stop (by a person, a script or a restart policy): it is wanted. It is left alone for
  # 24 hours (its seen time lies in the future) and forgotten as stopped, instead of being stopped again and again.
  local stopf="$PERF_DIR/docker-stopped.json" back
  [ -f "$stopf" ] || echo '{}' > "$stopf"
  back="$(jq -c --argjson l "$list" '[$l[] | select(.running > 0) | .stack] as $up | [keys[] | select(. as $k | $up | index($k))]' "$stopf")"
  if [ "$back" != '[]' ]; then
    jq -c --argjson b "$back" 'with_entries(select(.key as $k | $b | index($k) | not))' "$stopf" > "$stopf.$$" && mv -f "$stopf.$$" "$stopf"
    jq -c --argjson b "$back" --argjson t "$((now + 86400))" 'reduce $b[] as $k (.; .[$k] = $t)' "$seen" > "$seen.$$" && mv -f "$seen.$$" "$seen"
    perfdocker_log "kept $(jq -r 'join(", ")' <<<"$back"): started again after an idle stop, left alone for 24 h"
  fi
  # Active or first seen: the time is now (a later time stays). Nothing is stopped right after install.
  jq -c --argjson now "$now" --argjson l "$list" '. as $s | reduce $l[] as $x ($s; if $x.active or (.[$x.stack] == null) or $x.running == 0 then .[$x.stack] = ([.[$x.stack] // 0, $now] | max) else . end)' "$seen" > "$seen.$$" && mv -f "$seen.$$" "$seen"
  while IFS= read -r s; do
    [ -n "$s" ] || continue
    k="$(jq -r .stack <<<"$s")"; last="$(jq -r --arg k "$k" '.[$k] // 0' "$seen")"
    [ $(( now - last )) -ge $(( idle * 60 )) ] || continue
    if perfdocker_act stop "$s"; then perfdocker_record "$k" "$s"; perfdocker_log "idle stop $k (idle $(( (now - last) / 60 )) min, level $lvl)"
      perf_notify "Docker stack stopped" "$k was idle for $(( (now - last) / 60 )) min. deploys perf wake $k starts it again."; fi
  done <<<"$(jq -c '.[] | select(.running > 0 and (.always | not) and (.active | not))' <<<"$list")"
}

perfdocker_record() {  # remember a stopped stack for wake
  local f="$PERF_DIR/docker-stopped.json"; [ -f "$f" ] || echo '{}' > "$f"
  jq -c --arg k "$1" --argjson s "$2" --argjson t "$(perf_now)" '.[$k] = ($s + {stoppedAt:$t})' "$f" > "$f.$$" && mv -f "$f.$$" "$f"
}

# Booted simulators and whether Xcode or Simulator.app runs (then they are left alone).
perf_sims() {
  perf_src simctl xcrun simctl list devices booted -j | jq -c '[.devices // {} | to_entries[] | .value[] | select(.state == "Booted") | {udid, name}]' 2>/dev/null || echo '[]'
}
perf_xcode_up() { perf_src ps ps -axo args= | grep -Eq '/(Xcode|Simulator)\.app/Contents/MacOS/(Xcode|Simulator)( |$)'; }

# Caches that grow: sizes in MB, measured at most once a day (nice, 60 s cap), read from perf/caches.json otherwise.
perf_caches() {
  local f="$PERF_DIR/caches.json" now d out="" kb
  now="$(perf_now)"
  if [ -f "$f" ] && [ $(( now - $(jq -r '.time // 0' "$f" 2>/dev/null || echo 0) )) -lt 86400 ]; then cat "$f"; return 0; fi
  [ "${1:-}" = measure ] || { [ -f "$f" ] && cat "$f" || echo '{"time":null,"caches":[]}'; return 0; }
  for d in "$HOME/.npm/_cacache" "$HOME/Library/Caches/ms-playwright" "$HOME/Library/Developer/Xcode/DerivedData" \
           "$HOME/Library/Developer/CoreSimulator/Caches" "$HOME/.cache" "$HOME/Library/Caches/pnpm" "$HOME/Library/Caches/Yarn"; do
    [ -d "$d" ] || continue
    kb="$(perl -e 'alarm 60; exec @ARGV' nice -n 19 du -sk "$d" 2>/dev/null | awk '{print $1}')"
    [ -n "$kb" ] && out="$out$d	$kb
"
  done
  mkdir -p "$PERF_DIR"
  printf '%s' "$out" | jq -Rsc --argjson t "$now" --arg h "$HOME" '{time:$t, caches:[split("\n")[] | select(length > 0) | split("\t") | {path:(.[0] | sub("^" + $h; "~")), mb:((.[1] | tonumber) / 1024 | floor)}] | sort_by(-.mb)}' | tee "$f"
}

perf_consumers_main() {
  local docker='[]' sims caches xcode=false
  ! perfdocker_have || docker="$(perfdocker_list 2>/dev/null || echo '[]')"
  sims="$(perf_sims)"; caches="$(perf_caches)"; perf_xcode_up && xcode=true
  local j; j="$(jq -nc --argjson d "$docker" --argjson s "$sims" --argjson c "$caches" --argjson x "$xcode" \
    '{docker:$d, simulators:$s, xcodeRunning:$x, caches:$c.caches, cachesMeasured:$c.time}')"
  if [ "${json:-0}" = 1 ]; then echo "$j"; return 0; fi
  echo "DOCKER"; if [ "$docker" = '[]' ]; then echo "  (Docker is not running)"; else perfdocker_print <<<"$docker" | sed 's/^/  /'; fi
  echo; echo "SIMULATORS (booted)"
  jq -r --argjson x "$xcode" 'if length == 0 then "  none" else (.[] | "  \(.name)  \(.udid)"), (if $x then "  (Xcode or Simulator.app runs: left alone)" else "  deploys perf stop simulators --yes shuts them down" end) end' <<<"$sims"
  echo; echo "CACHES (reported only, never deleted)"
  jq -r 'if (.caches | length) == 0 then "  not measured yet (the agent measures once a day)" else (.caches[] | "  \(.mb) MB  \(.path)") end' <<<"$caches"
}

perfdocker_main() {
  local sub="$1"; shift
  local yes=0 name="" a
  for a in "$@"; do case "$a" in --yes) yes=1 ;; -*) echo "Unknown option $a" >&2; return 2 ;; *) name="$a" ;; esac; done
  case "$sub" in
    docker)
      perfdocker_have || { echo "perf: Docker is not running." >&2; [ "${json:-0}" = 1 ] && echo '[]'; return 0; }
      if [ "${json:-0}" = 1 ]; then perfdocker_list; else perfdocker_list | perfdocker_print; fi ;;
    consumers) perf_consumers_main ;;
    stop)
      [ -n "$name" ] || { echo "Usage: deploys perf stop <docker stack>|simulators --yes" >&2; return 2; }
      if [ "$name" = simulators ]; then
        perf_xcode_up && { echo "perf: Xcode or Simulator.app runs; the simulators are left alone." >&2; return 1; }
        [ "$yes" = 1 ] || { echo "Would shut down: $(perf_sims | jq -r 'map(.name) | join(", ")'). Add --yes." ; return 0; }
        perf_sims | jq -r '.[].udid' | while read -r u; do xcrun simctl shutdown "$u" && perf_log "simulator: shut down $u"; done; return 0
      fi
      local s; s="$(perfdocker_find "$name")" || return 1
      [ "$yes" = 1 ] || { echo "Would stop Docker stack $name ($(jq -r '"\(.running) running, \(.memMB) MB"' <<<"$s")). Containers, volumes and data stay. Add --yes."; return 0; }
      perfdocker_act stop "$s" && perfdocker_record "$name" "$s" && perfdocker_log "stopped $name by hand" && echo "Stopped $name. deploys perf wake $name starts it again." ;;
    wake)
      [ -n "$name" ] || { echo "Usage: deploys perf wake <docker stack>" >&2; return 2; }
      local s; s="$(jq -c --arg k "$name" '.[$k] // empty' "$PERF_DIR/docker-stopped.json" 2>/dev/null)"
      [ -n "$s" ] || s="$(perfdocker_find "$name")" || return 1
      perfdocker_act start "$s" && perfdocker_log "woke $name" && echo "Started $name." || return 1
      [ ! -f "$PERF_DIR/docker-stopped.json" ] || { jq -c --arg k "$name" 'del(.[$k])' "$PERF_DIR/docker-stopped.json" > "$PERF_DIR/docker-stopped.json.$$" && mv -f "$PERF_DIR/docker-stopped.json.$$" "$PERF_DIR/docker-stopped.json"; } ;;
  esac
}
