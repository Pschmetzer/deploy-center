# shellcheck shell=bash
# lib/localsessions.sh — `deploys local-sessions [--json]`: the Claude Code sessions running on this Mac, with folder, title,
# idle time, CPU and RAM. The hint is to bundle tasks: more than bundleTo sessions started within burstMin minutes on
# one repo, or the same task twice; two sessions in one folder and idle ones are flagged too. Read-only, except `deploys local-sessions stop <pid> --yes`, which
# ends one session after a click or a typed --yes. Bash 3.2.
#
# Sources (read-only, docs/LOCAL-SESSIONS.md):
#   ~/.claude/sessions/<pid>.json        one file per Claude Code process: sessionId, cwd, name (the title), status,
#                                        startedAt (ms). Only *.json is read; the .key files next to them never are.
#   ps                                   is the pid alive, is it claude, did it start before the session (pid reuse),
#                                        CPU and RAM of it and everything under it.
#   ~/.claude/projects/*/<sessionId>.jsonl   the transcript: its modification time is the last activity.
# Cloud sessions are not counted: nothing on this Mac says which of them are running (docs/LOCAL-SESSIONS.md).
#
# Tests: DEPLOYS_LOCAL_SESSIONS_FIXTURE=<dir> reads <dir>/ps instead of ps; DEPLOYS_LOCAL_SESSIONS_DIR and DEPLOYS_CLAUDE_PROJECTS
# point at made-up folders; DEPLOYS_LOCAL_SESSIONS_NOW fixes the clock.

LSESS_CONF="${CONFIG_DIR:-${DEPLOYS_CONFIG:-$HOME/.config/deploys}}/local-sessions.json"

lsess_now() { if [ -n "${DEPLOYS_LOCAL_SESSIONS_NOW:-}" ]; then echo "$DEPLOYS_LOCAL_SESSIONS_NOW"; else date +%s; fi; }
lsess_dir() { echo "${DEPLOYS_LOCAL_SESSIONS_DIR:-$HOME/.claude/sessions}"; }
lsess_projects() { echo "${DEPLOYS_CLAUDE_PROJECTS:-$HOME/.claude/projects}"; }

# The thresholds: defaults, overridden by ~/.config/deploys/local-sessions.json. One JSON object. maxLocal and maxCloud are
# high on purpose (20-30 sessions at once are fine; the app's own limit cannot be read from the Mac); the main hint is
# a burst: more than bundleTo sessions started within burstMin minutes on one repo, which should have been one to
# bundleTo sessions working the tasks one after another.
lsess_conf() {
  local f='{}'
  [ -f "$LSESS_CONF" ] && f="$(jq -c 'if type == "object" then . else {} end' "$LSESS_CONF" 2>/dev/null || echo '{}')"
  jq -nc --argjson f "$f" '{maxLocal:30, maxCloud:30, idleMin:60, burstMin:10, bundleTo:3} + $f
    | .maxLocal |= (if type == "number" and . >= 1 then floor else 30 end)
    | .maxCloud |= (if type == "number" and . >= 1 then floor else 30 end)
    | .idleMin |= (if type == "number" and . >= 1 then floor else 60 end)
    | .burstMin |= (if type == "number" and . >= 1 then floor else 10 end)
    | .bundleTo |= (if type == "number" and . >= 1 then floor else 3 end)'
}

# ps: `pid ppid pcpu rss etime args`, the fixture in tests.
lsess_ps() {
  if [ -n "${DEPLOYS_LOCAL_SESSIONS_FIXTURE:-}" ]; then cat "$DEPLOYS_LOCAL_SESSIONS_FIXTURE/ps" 2>/dev/null
  else LC_ALL=C ps -axo pid=,ppid=,pcpu=,rss=,etime=,args= 2>/dev/null; fi
}

lsess_mtime() { stat -c %Y "$1" 2>/dev/null || stat -f %m "$1" 2>/dev/null; }

# The session files as one JSON array (a broken or foreign file is skipped).
lsess_files() {
  local d f; d="$(lsess_dir)"
  for f in "$d"/*.json; do
    [ -f "$f" ] || continue
    jq -c 'select(type == "object" and (.pid | type) == "number" and (.sessionId | type) == "string")
      | {pid, sessionId, cwd: (.cwd // ""), title: (.name // ""), kind: (.kind // ""), entrypoint: (.entrypoint // ""),
         state: (.status // ""), startedAt: ((.startedAt // 0) / 1000 | floor)}' "$f" 2>/dev/null
  done | jq -sc '.'
}

# The live processes of those pids: JSON {pid: {start, claude, cpu, mb}} — start from etime, cpu and mb summed over
# the process and everything under it (the shells, checks and tools it started).
lsess_procs() {  # lsess_procs <pids, space separated> <now>
  lsess_ps | awk -v want=" $1 " -v now="$2" '
    function secs(e,   d, n, t, i, s) { d = 0
      if (index(e, "-")) { d = substr(e, 1, index(e, "-") - 1); e = substr(e, index(e, "-") + 1) }
      n = split(e, t, ":"); s = 0; for (i = 1; i <= n; i++) s = s * 60 + t[i]
      return d * 86400 + s }
    { pid = $1; par[pid] = $2; cpu[pid] = $3 + 0; rss[pid] = $4 + 0; et[pid] = $5
      a = $0; for (i = 1; i <= 5; i++) sub(/^[ \t]*[^ \t]+/, "", a); sub(/^[ \t]+/, "", a); args[pid] = a; seen[++n] = pid }
    END {
      for (i = 1; i <= n; i++) { p = seen[i]; q = p
        for (k = 0; k < 64 && q != "" && q != 0; k++) {
          if (index(want, " " q " ")) { tc[q] += cpu[p]; tr[q] += rss[p]; break }
          q = par[q] } }
      printf "{"; c = 0
      for (i = 1; i <= n; i++) { p = seen[i]; if (!index(want, " " p " ")) continue
        isc = (args[p] ~ /(^|\/)claude( |$)|claude-code|\/claude\.app\//) ? "true" : "false"
        printf "%s\"%s\":{\"start\":%d,\"claude\":%s,\"cpu\":%.1f,\"mb\":%d}", (c++ ? "," : ""), p, now - secs(et[p]), isc, tc[p], tr[p] / 1024 }
      print "}" }'
}

# Per session from its transcript: the last activity (the file's modification time) and when the task was created (the
# first time stamp in it; the process may be younger after the app restarted its sessions). JSON {sessionId: {last, first}}.
lsess_activity() {  # stdin: lines "sessionId<TAB>cwd"
  local pj sid cwd enc f m t first=1; pj="$(lsess_projects)"
  printf '{'
  while IFS="$(printf '\t')" read -r sid cwd; do
    case "$sid" in ""|*/*|*..*) continue ;; esac
    enc="$(printf '%s' "$cwd" | sed 's/[^A-Za-z0-9-]/-/g')"
    f="$pj/$enc/$sid.jsonl"
    if [ ! -f "$f" ]; then for f in "$pj"/*/"$sid.jsonl"; do [ -f "$f" ] && break; done; fi
    [ -f "$f" ] || continue
    m="$(lsess_mtime "$f")"; [ -n "$m" ] || continue
    t="$(head -n 30 "$f" 2>/dev/null | grep -o '"timestamp":"[0-9T:.-]*Z"' | head -n 1 | cut -d'"' -f4)"
    [ "$first" = 1 ] || printf ','; first=0
    printf '"%s":{"last":%s,"first":"%s"}' "$sid" "$m" "$t"
  done
  printf '}\n'
}

# The whole picture as JSON. Pure jq over the three inputs, so the tests can feed it directly.
lsess_judge() {  # lsess_judge <files> <procs> <activity> <conf> <now>
  jq -nc --argjson files "$1" --argjson procs "$2" --argjson act "$3" --argjson conf "$4" --argjson now "$5" '
    def norm: ascii_downcase | gsub("[^a-z0-9äöüß]+"; " ") | ltrimstr(" ") | rtrimstr(" ");
    [ $files[]
      | . as $s | ($procs[($s.pid | tostring)]) as $p
      # alive, a claude process, and started no later than the session (else the pid was reused)
      | select($p != null and $p.claude and ($s.startedAt == 0 or $p.start <= $s.startedAt + 5))
      | ($act[$s.sessionId].last // ($s.startedAt | if . > 0 then . else null end)) as $last
      | (($act[$s.sessionId].first // "") | sub("\\.[0-9]+Z$"; "Z") | (try fromdateiso8601 catch null)) as $created
      | $s + {cpu: $p.cpu, mb: $p.mb, lastActivity: $last, created: ($created // (if $s.startedAt > 0 then $s.startedAt else null end)),
              idleMin: (if $last then ([($now - $last) / 60 | floor, 0] | max) else null end),
              folder: ($s.cwd | split("/") | map(select(. != "")) | last // "")} ]
    | unique_by(.sessionId) | map(. + {repo: (.cwd | sub("/\\.claude/worktrees/[^/]+(/.*)?$"; ""))})
    | sort_by(-(.lastActivity // 0)) as $list
    | ([$list[] | select(.title | norm | length > 0)] | group_by(.title | norm) | map(select(length > 1))
        | map({title: .[0].title, pids: map(.pid)})) as $dups
    | ([$list[] | select(.cwd != "")] | group_by(.cwd) | map(select(length > 1))
        | map({cwd: .[0].cwd, folder: .[0].folder, pids: map(.pid)})) as $same
    # bursts: per repo, sessions in start order; a gap of more than burstMin minutes starts a new group
    | ([$list[] | select(.repo != "" and .created != null)] | group_by(.repo)
        | map(sort_by(.created) | reduce .[] as $x ([];
            if length > 0 and ($x.created - .[-1][-1].created) <= $conf.burstMin * 60 then .[-1] += [$x] else . + [[$x]] end)
          | .[] | select(length > $conf.bundleTo))
        | map({repo: .[0].repo, folder: (.[0].repo | split("/") | map(select(. != "")) | last // ""), count: length,
               keep: $conf.bundleTo, pids: map(.pid), extra: (.[$conf.bundleTo:] | map(.pid)),
               from: .[0].created, to: .[-1].created})) as $bursts
    | ([$dups[].pids[]]) as $dp | ([$same[].pids[]]) as $sp | ([$bursts[].pids[]]) as $bp | ([$bursts[].extra[]]) as $bx
    | [$list[] | . + {duplicate: (.pid as $x | $dp | index([$x]) != null),
                      sameFolder: (.pid as $x | $sp | index([$x]) != null),
                      burst: (.pid as $x | $bp | index([$x]) != null),
                      burstExtra: (.pid as $x | $bx | index([$x]) != null),
                      idle: (.idleMin != null and .idleMin >= $conf.idleMin)}] as $out
    | ($out | length) as $n
    | {time: $now,
       level: (if $n >= $conf.maxLocal then "yellow" else "green" end),
       local: {count: $n, max: $conf.maxLocal, over: ($n >= $conf.maxLocal)},
       cloud: {count: null, max: $conf.maxCloud, status: "unknown",
               note: "The number of running cloud sessions cannot be read on this Mac. deploys sessions shows cloud sessions as GitHub sees them (branches, pull requests)."},
       idleMin: $conf.idleMin, burstMin: $conf.burstMin, bundleTo: $conf.bundleTo,
       sessions: $out,
       bursts: $bursts,
       duplicates: $dups,
       sameFolder: $same,
       idle: [$out[] | select(.idle) | .pid],
       hint: (if $n >= $conf.maxLocal or ($bursts | length) > 0 or ($dups | length) > 0 then "bundle tasks" else null end)}'
}

lsess_snapshot() {
  local now files pids procs act
  now="$(lsess_now)"
  files="$(lsess_files)"; [ -n "$files" ] || files='[]'
  pids="$(jq -r '[.[].pid] | join(" ")' <<<"$files")"
  procs="$(lsess_procs "$pids" "$now")"; [ -n "$procs" ] || procs='{}'
  act="$(jq -r '.[] | [.sessionId, .cwd] | @tsv' <<<"$files" | lsess_activity)"
  lsess_judge "$files" "$procs" "$act" "$(lsess_conf)" "$now"
}

lsess_print() {
  jq -r '
    def age: if . == null then "?" elif . < 60 then "\(.) min" elif . < 2880 then "\(. / 60 | floor) h" else "\(. / 1440 | floor) d" end;
    def pad($n): tostring | (. + (" " * $n)) | .[0:$n];
    def mark: [(if .burstExtra then "started together: close" elif .burst then "started together" else empty end),
               (if .duplicate then "twice" else empty end), (if .sameFolder then "same folder" else empty end),
               (if .idle then "idle" else empty end)] | join(", ");
    "Claude Code sessions on this Mac: \(.local.count) (yellow at \(.local.max)) · cloud: unknown" + (if .level == "yellow" then "  [YELLOW]" else "" end),
    (if (.sessions | length) == 0 then "  none" else
      (.sessions[] | "  \(.pid | pad(7))\(.idleMin | age | pad(8))\("\(.cpu) %" | pad(9))\("\(.mb) MB" | pad(9))\(if .state == "idle" then "waits" else .state end | pad(6)) \(if .title == "" then "(no title)" else .title end) — \(.folder)" + (mark | if . == "" then "" else "  [\(.)]" end))
    end),
    (if (.bursts | length) > 0 then "Started together, should have been bundled into \(.bundleTo) at most:",
      (.bursts[] | "  \(.folder): \(.count) sessions within \(((.to - .from) / 60 | floor)) min (pids \(.pids | map(tostring) | join(", "))); extra: \(.extra | map(tostring) | join(", "))") else empty end),
    (if (.duplicates | length) > 0 then "Same task twice:", (.duplicates[] | "  \(.title): \(.pids | map(tostring) | join(", "))") else empty end),
    (if (.sameFolder | length) > 0 then "Two sessions in one folder:", (.sameFolder[] | "  \(.folder): \(.pids | map(tostring) | join(", "))") else empty end),
    (if (.idle | length) > 0 then "Idle for over \(.idleMin) min: \(.idle | map(tostring) | join(", "))" else empty end),
    (if .hint then "Hint: bundle tasks: tasks started together go to one to \(.bundleTo) sessions that work them one after another; close the extras and duplicates." else empty end),
    (if .hint then "Closing is yours: deploys local-sessions stop <pid> --yes" else empty end),
    "Cloud: running count unknown; for a GitHub view of cloud sessions see deploys sessions."'
}

# deploys local-sessions stop <pid> --yes: SIGTERM to one session, after checking again that the pid is a live Claude Code
# session of the list (not a reused pid). Without --yes it only says what it would do.
lsess_stop() {
  local yes=0 pid="" a snap s
  for a in "$@"; do case "$a" in --yes) yes=1 ;; -*) echo "Unknown option $a" >&2; return 2 ;; *) pid="$a" ;; esac; done
  case "$pid" in ""|*[!0-9]*) echo "Usage: deploys local-sessions stop <pid> --yes" >&2; return 2 ;; esac
  snap="$(lsess_snapshot)" || return 1
  s="$(jq -c --argjson p "$pid" '.sessions[] | select(.pid == $p)' <<<"$snap")"
  [ -n "$s" ] || { echo "No running Claude Code session has pid $pid." >&2; return 1; }
  if [ "$yes" != 1 ]; then
    echo "Would end session $pid ($(jq -r 'if .title == "" then .folder else .title end' <<<"$s")). Its transcript file stays; the Claude app may show it as stopped. Add --yes."
    return 0
  fi
  [ -z "${DEPLOYS_LOCAL_SESSIONS_FIXTURE:-}" ] || { echo "Ended session $pid (fixture: nothing sent)."; return 0; }
  kill -TERM "$pid" 2>/dev/null || { echo "Could not end session $pid." >&2; return 1; }
  echo "Ended session $pid."
}

# deploys local-sessions set max-local|max-cloud|idle-min <n>: writes ~/.config/deploys/local-sessions.json.
lsess_set() {
  local k="${1:-}" v="${2:-}" key cur
  case "$k" in max-local) key=maxLocal ;; max-cloud) key=maxCloud ;; idle-min) key=idleMin ;; burst-min) key=burstMin ;; bundle-to) key=bundleTo ;;
    *) echo "Usage: deploys local-sessions set max-local|max-cloud|idle-min|burst-min|bundle-to <number>" >&2; return 2 ;; esac
  case "$v" in ""|*[!0-9]*|0) echo "local-sessions set: $k needs a whole number of at least 1" >&2; return 2 ;; esac
  mkdir -p "$(dirname "$LSESS_CONF")"
  cur='{}'; [ -f "$LSESS_CONF" ] && cur="$(jq -c 'if type == "object" then . else {} end' "$LSESS_CONF" 2>/dev/null || echo '{}')"
  jq --arg k "$key" --argjson v "$v" '.[$k] = $v' <<<"$cur" > "$LSESS_CONF.tmp" && mv "$LSESS_CONF.tmp" "$LSESS_CONF"
  echo "local-sessions: $k = $v"
}

localsessions_main() {
  local sub="list" a rest=(); json="${json:-0}"
  for a in "$@"; do case "$a" in --json) json=1 ;; *) rest+=("$a") ;; esac; done
  if [ "${#rest[@]}" -gt 0 ]; then sub="${rest[0]}"; rest=("${rest[@]:1}"); fi
  case "$sub" in
    list|status)
      local snap; snap="$(lsess_snapshot)" || return 1
      if [ "$json" = 1 ]; then echo "$snap"; else lsess_print <<<"$snap"; fi ;;
    stop) lsess_stop ${rest[@]+"${rest[@]}"} ;;
    set) lsess_set ${rest[@]+"${rest[@]}"} ;;
    config) lsess_conf ;;
    *) echo "Usage: deploys local-sessions [--json] | stop <pid> [--yes] | set max-local|max-cloud|idle-min|burst-min|bundle-to <n> | config" >&2; return 2 ;;
  esac
}

# Run on its own: `bash lib/localsessions.sh --json`.
if [ "${BASH_SOURCE[0]}" = "$0" ]; then localsessions_main "$@"; exit $?; fi
