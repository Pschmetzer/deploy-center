# shellcheck shell=bash
# lib/desktopsessions.sh — `deploys desktop-sessions [--json]`: the Code sessions of the Claude desktop app, for every
# account signed in on this Mac, and which of them are done but still open (not archived). Read-only: it never writes,
# archives or ends anything. Archiving is the Claude app's own job: "Auto-archive sessions when their pull request
# closes" (Settings → Claude Code), once in each account. Bash 3.2.
#
# Sources (read-only, docs/LOCAL-SESSIONS.md):
#   ~/Library/Application Support/Claude/claude-code-sessions/<account>/<org>/local_*.json
#       one file per desktop session: isArchived, title, cwd, branch, prs[] (state MERGED, CLOSED or OPEN),
#       lastActivityAt (ms), interruptedAwaitingPerson, postTurnSummary {status_category, needs_action}, cliSessionId.
#       Only local_*.json is read; other files there, IndexedDB, Local Storage and .key files never are.
#   ~/.claude/sessions/<pid>.json    the live Claude Code processes: hostSessionId (= the desktop file's name),
#                                    sessionId, status (busy, idle, waiting). A pid counts only while it is alive.
#   claude agents --json             the same processes as Claude Code sees them (status busy or idle).
#   claude auth status --json        only its orgId is read, to mark the account in use; nothing else of it is kept.
#
# Done, conservatively: at least one pull request and every one MERGED or CLOSED, not busy, nobody is asked
# (interruptedAwaitingPerson unset, no needs_action, not waiting), and the summary is not review_ready or blocked.
# A completed session without a pull request is only "idle N h".
#
# Tests: DEPLOYS_DESKTOP_SESSIONS_BASE points at a made-up claude-code-sessions folder, DEPLOYS_LOCAL_SESSIONS_DIR at
# made-up live files, DEPLOYS_DESKTOP_SESSIONS_FIXTURE=<dir> reads <dir>/auth.json, <dir>/agents.json and <dir>/alive
# (live pids, one per line) instead of calling claude or kill -0; DEPLOYS_DESKTOP_SESSIONS_NOW fixes the clock.

DSESS_CONF="${CONFIG_DIR:-${DEPLOYS_CONFIG:-$HOME/.config/deploys}}/desktop-sessions.json"

dsess_now() { if [ -n "${DEPLOYS_DESKTOP_SESSIONS_NOW:-}" ]; then echo "$DEPLOYS_DESKTOP_SESSIONS_NOW"; else date +%s; fi; }
dsess_base() { echo "${DEPLOYS_DESKTOP_SESSIONS_BASE:-$HOME/Library/Application Support/Claude/claude-code-sessions}"; }
dsess_live_dir() { echo "${DEPLOYS_LOCAL_SESSIONS_DIR:-$HOME/.claude/sessions}"; }

# Labels per account: {"labels": {"<account folder id>": "Work"}} in ~/.config/deploys/desktop-sessions.json.
dsess_conf() {
  local f='{}'
  [ -f "$DSESS_CONF" ] && f="$(jq -c 'if type == "object" then . else {} end' "$DSESS_CONF" 2>/dev/null || echo '{}')"
  jq -nc --argjson f "$f" '{labels: {}, idleHours: 24} + $f
    | .labels |= (if type == "object" then with_entries(select(.value | type == "string")) else {} end)
    | .idleHours |= (if type == "number" and . >= 1 then floor else 24 end)'
}

# The fields one desktop file contributes. The account and org come from the path, never from the file.
DSESS_PICK="$(cat <<'JQ'
select(type == "object" and .isArchived != true)
  | (input_filename | split("/")) as $p
  | {id: ($p[-1] | rtrimstr(".json")), account: $p[-3], org: $p[-2],
     title: (.title // "" | tostring), cwd: (.cwd // "" | tostring), branch: (.branch // "" | tostring),
     prs: [(.prs // [] | if type == "array" then .[] else empty end) | select(type == "object")
           | {state: (.state // "" | tostring | ascii_upcase), number: .prNumber, repo: (.repo // null), url: (.url // null)}],
     lastActivity: (if (.lastActivityAt | type) == "number" then (.lastActivityAt / 1000 | floor) else null end),
     awaiting: (.interruptedAwaitingPerson as $a | $a != null and $a != false and $a != ""),
     status: (.postTurnSummary.status_category // null),
     needsAction: ((.postTurnSummary.needs_action // "") | if type == "string" then length > 0 else . == true end),
     cli: [.cliSessionId, .lastAssistantCliSessionId | select(type == "string" and length > 0)]}
JQ
)"
# Reads the files given to it; a batch that jq stops at a broken file is read again one by one.
DSESS_READ="$(cat <<'SH'
[ $# -gt 0 ] || exit 0
jq -c "$F" "$@" 2>/dev/null || for f in "$@"; do jq -c "$F" "$f" 2>/dev/null; done
SH
)"

# The desktop files as one JSON array. jq stops a batch at the first broken file, so a failed batch is read again
# file by file; the duplicates that leaves are dropped by id.
dsess_files() {
  local base; base="$(dsess_base)"
  [ -d "$base" ] || { echo '[]'; return 0; }
  find "$base" -mindepth 3 -maxdepth 3 -type f -name 'local_*.json' -print0 2>/dev/null \
    | F="$DSESS_PICK" xargs -0 sh -c "$DSESS_READ" _ \
    | jq -sc 'unique_by(.id)'
}

dsess_alive() {  # dsess_alive <pid>
  if [ -n "${DEPLOYS_DESKTOP_SESSIONS_FIXTURE:-}" ]; then grep -qx "$1" "$DEPLOYS_DESKTOP_SESSIONS_FIXTURE/alive" 2>/dev/null
  else kill -0 "$1" 2>/dev/null; fi
}

# The live processes with a pid that is still there: [{pid, host, sessionId, status}].
dsess_live() {
  local d f line pid; d="$(dsess_live_dir)"
  for f in "$d"/*.json; do
    [ -f "$f" ] || continue
    line="$(jq -c 'select(type == "object" and (.pid | type) == "number" and .pid > 0)
      | {pid, host: (.hostSessionId // "" | tostring), sessionId: (.sessionId // "" | tostring), status: (.status // "" | tostring)}' "$f" 2>/dev/null)"
    [ -n "$line" ] || continue
    pid="$(jq -r .pid <<<"$line")"
    dsess_alive "$pid" && echo "$line"
  done | jq -sc '.'
}

# `claude` and its answers. In the app the PATH is short, so the usual install places are tried too.
dsess_claude() {
  local c
  for c in "${DEPLOYS_CLAUDE_BIN:-}" "$(command -v claude 2>/dev/null)" "$HOME/.local/bin/claude" "$HOME/.claude/local/claude" /opt/homebrew/bin/claude /usr/local/bin/claude; do
    [ -n "$c" ] && [ -x "$c" ] && { echo "$c"; return 0; }
  done
  return 1
}

# Runs claude with a 10 s limit (macOS has no timeout). Prints its stdout, nothing on failure.
dsess_run_claude() {
  local c out pid w; c="$(dsess_claude)" || return 1
  out="$(mktemp "${TMPDIR:-/tmp}/dsess.XXXXXX")" || return 1
  "$c" "$@" >"$out" 2>/dev/null </dev/null & pid=$!
  # The watchdog keeps no pipe open (else $(...) waits for its sleep) and takes its sleep along when it is stopped.
  ( s=""; trap "kill \$s 2>/dev/null; exit 0" TERM; sleep 10 & s=$!; wait "$s"; kill "$pid" 2>/dev/null ) >/dev/null 2>&1 </dev/null & w=$!
  wait "$pid" 2>/dev/null; kill "$w" 2>/dev/null; wait "$w" 2>/dev/null
  cat "$out"; rm -f "$out"
}

# [{sessionId, status}] from claude agents --json.
dsess_agents() {
  local raw
  if [ -n "${DEPLOYS_DESKTOP_SESSIONS_FIXTURE:-}" ]; then raw="$(cat "$DEPLOYS_DESKTOP_SESSIONS_FIXTURE/agents.json" 2>/dev/null)"
  else raw="$(dsess_run_claude agents --json)"; fi
  jq -c '[if type == "array" then .[] else empty end | select(type == "object")
          | {sessionId: (.sessionId // "" | tostring), status: (.status // "" | tostring)}]' <<<"${raw:-[]}" 2>/dev/null || echo '[]'
}

# Only the orgId of the signed-in account; email and names in that answer are dropped right here.
dsess_active_org() {
  local raw
  if [ -n "${DEPLOYS_DESKTOP_SESSIONS_FIXTURE:-}" ]; then raw="$(cat "$DEPLOYS_DESKTOP_SESSIONS_FIXTURE/auth.json" 2>/dev/null)"
  else raw="$(dsess_run_claude auth status --json)"; fi
  jq -r 'if type == "object" and (.orgId | type) == "string" then .orgId else "" end' <<<"${raw:-null}" 2>/dev/null
}

# The whole picture as JSON. Pure jq over the inputs, so the tests can feed it directly.
dsess_judge() {  # dsess_judge <files> <live> <agents> <activeOrg> <conf> <now>
  jq -nc --argjson files "$1" --argjson live "$2" --argjson agents "$3" --arg org "$4" --argjson conf "$5" --argjson now "$6" '
    ($files | map(.account) | unique) as $ids
    | ($agents | map({key: .sessionId, value: .status}) | from_entries) as $ag
    | [ $files[] | . as $s
        | ([$live[] | select(.host == $s.id or (.sessionId as $x | $s.cli | index([$x]) != null))]) as $procs
        | ([$procs[].status] + [$procs[].sessionId as $x | $ag[$x] // empty] + [$s.cli[] as $x | $ag[$x] // empty]) as $st
        | ($st | index("busy") != null) as $busy
        | ($s.awaiting or $s.needsAction or ($st | index("waiting") != null)) as $asks
        | (($s.prs | length) > 0 and ($s.prs | all(.state == "MERGED" or .state == "CLOSED"))) as $prsDone
        | (if $s.lastActivity then ([($now - $s.lastActivity) / 3600 | floor, 0] | max) else null end) as $idleH
        | $s + {live: ($procs | length > 0), busy: $busy, waiting: $asks, idleHours: $idleH,
                folder: ($s.cwd | split("/") | map(select(. != "")) | last // ""),
                state: (if $busy then "running"
                        elif $asks then "waiting"
                        elif $prsDone and ($s.status != "review_ready" and $s.status != "blocked") then "done"
                        elif $s.status == "review_ready" then "review"
                        elif $s.status == "blocked" then "blocked"
                        elif ($s.prs | length) == 0 and $s.status == "completed" then "idle"
                        else "open" end)} ]
    | sort_by(-(.lastActivity // 0)) as $all
    | ([$ids | to_entries[] | select(.value as $a | $all | any(.account == $a and .org == $org))] | length) as $nActive
    | [ $ids | to_entries[] | .key as $i | .value as $a
        | ($all | map(select(.account == $a))) as $mine
        | {id: $a, short: ($a | gsub("[^0-9a-fA-F]"; "") | .[0:8]),
           label: ($conf.labels[$a] // "Account \($i + 1) (\($a | gsub("[^0-9a-fA-F]"; "") | .[0:8]))"),
           active: ($org != "" and ($mine | any(.org == $org))),
           open: ($mine | length),
           done: ($mine | map(select(.state == "done")) | length),
           waiting: ($mine | map(select(.state == "waiting")) | length),
           running: ($mine | map(select(.state == "running")) | length),
           idle: ($mine | map(select(.state == "idle" and (.idleHours // 0) >= $conf.idleHours)) | length),
           sessions: $mine} ] as $accounts
    | {time: $now, idleHours: $conf.idleHours,
       activeAmbiguous: ($nActive > 1),
       totals: {accounts: ($accounts | length), open: ($all | length),
                done: ($all | map(select(.state == "done")) | length),
                waiting: ($all | map(select(.state == "waiting")) | length),
                running: ($all | map(select(.state == "running")) | length),
                accountsWithDone: ($accounts | map(select(.done > 0)) | length)},
       accounts: $accounts,
       hint: (if ($accounts | any(.done > 0)) then "Turn on \"Auto-archive sessions when their pull request closes\" (Claude app, Settings → Claude Code) in every account that has done sessions." else null end)}'
}

dsess_snapshot() {
  local now files live agents org
  now="$(dsess_now)"
  files="$(dsess_files)"; [ -n "$files" ] || files='[]'
  live="$(dsess_live)"; [ -n "$live" ] || live='[]'
  agents="$(dsess_agents)"; [ -n "$agents" ] || agents='[]'
  org="$(dsess_active_org)"
  dsess_judge "$files" "$live" "$agents" "$org" "$(dsess_conf)" "$now"
}

dsess_print() {
  jq -r '
    def age: if . == null then "?" elif . < 48 then "\(.) h" else "\(. / 24 | floor) d" end;
    def name: if .title == "" then (if .folder == "" then .id else .folder end) else .title end;
    def prs: .prs | map("#\(.number // "?") \(.state | ascii_downcase)") | join(", ");
    .idleHours as $ih |
    "Claude desktop sessions: \(.totals.open) open across \(.totals.accounts) accounts · done, still open: \(.totals.done) · waiting on you: \(.totals.waiting)",
    (if .totals.accounts == 0 then "  no desktop sessions found on this Mac" else empty end),
    (.accounts[] |
      "",
      "\(.label)\(if .active then "  (signed in now)" else "" end): \(.open) open, \(.done) done but open, \(.waiting) waiting on you, \(.running) running",
      (.sessions[] | select(.state == "done") | "  done     \(name) — \(.folder) — \(prs) — \(.idleHours | age) ago"),
      (.sessions[] | select(.state == "waiting") | "  waiting  \(name) — \(.folder)"),
      (.sessions[] | select(.state == "idle" and (.idleHours // 0) >= $ih) | "  idle \(.idleHours | age)  \(name) — \(.folder) (no pull request)"),
      (if .done > 0 then "  Archiving is the Claude app'"'"'s job: turn on \"Auto-archive sessions when their pull request closes\" (Settings → Claude Code) in this account." else empty end)),
    (if .activeAmbiguous then "", "Note: the signed-in org appears in several accounts; \"signed in now\" may mark more than one." else empty end),
    "",
    "Read-only: nothing is archived or ended from here."'
}

desktopsessions_main() {
  local sub="list" a rest=(); json="${json:-0}"
  for a in "$@"; do case "$a" in --json) json=1 ;; *) rest+=("$a") ;; esac; done
  if [ "${#rest[@]}" -gt 0 ]; then sub="${rest[0]}"; fi
  case "$sub" in
    list|status)
      local snap; snap="$(dsess_snapshot)" || return 1
      if [ "$json" = 1 ]; then echo "$snap"; else dsess_print <<<"$snap"; fi ;;
    config) dsess_conf ;;
    *) echo "Usage: deploys desktop-sessions [--json] | config" >&2; return 2 ;;
  esac
}

# Run on its own: `bash lib/desktopsessions.sh --json`.
if [ "${BASH_SOURCE[0]}" = "$0" ]; then desktopsessions_main "$@"; exit $?; fi
