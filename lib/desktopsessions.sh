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
# Stopped: a session that is not done, not running and nobody is asked, whose transcript
# (~/.claude/projects/*/<cliSessionId>.jsonl, last 80 lines) ends in a usage limit, an API error or a turn that was cut
# off (a tool result or prompt with no answer), idle for stoppedMin minutes (10). A turn the person stopped
# ("[Request interrupted by user") never counts. There is no clean way to resume a desktop session from outside the app
# (docs/LOCAL-SESSIONS.md), so a stopped session is only shown, with a link that opens it in the Claude app.
#
# Tests: DEPLOYS_DESKTOP_SESSIONS_BASE points at a made-up claude-code-sessions folder, DEPLOYS_LOCAL_SESSIONS_DIR at
# made-up live files, DEPLOYS_DESKTOP_SESSIONS_FIXTURE=<dir> reads <dir>/auth.json, <dir>/agents.json and <dir>/alive
# (live pids, one per line) and <dir>/claude.json instead of calling claude, kill -0 or reading ~/.claude.json;
# DEPLOYS_CLAUDE_PROJECTS points at made-up transcripts; DEPLOYS_DESKTOP_SESSIONS_NOW fixes the clock.

DSESS_CONF="${CONFIG_DIR:-${DEPLOYS_CONFIG:-$HOME/.config/deploys}}/desktop-sessions.json"

dsess_now() { if [ -n "${DEPLOYS_DESKTOP_SESSIONS_NOW:-}" ]; then echo "$DEPLOYS_DESKTOP_SESSIONS_NOW"; else date +%s; fi; }
dsess_base() { echo "${DEPLOYS_DESKTOP_SESSIONS_BASE:-$HOME/Library/Application Support/Claude/claude-code-sessions}"; }
dsess_live_dir() { echo "${DEPLOYS_LOCAL_SESSIONS_DIR:-$HOME/.claude/sessions}"; }
dsess_projects() { echo "${DEPLOYS_CLAUDE_PROJECTS:-$HOME/.claude/projects}"; }

# Labels per account: {"labels": {"<account folder id>": "Work"}} in ~/.config/deploys/desktop-sessions.json.
dsess_conf() {
  local f='{}'
  [ -f "$DSESS_CONF" ] && f="$(jq -c 'if type == "object" then . else {} end' "$DSESS_CONF" 2>/dev/null || echo '{}')"
  jq -nc --argjson f "$f" '{labels: {}, idleHours: 24, stoppedMin: 10} + $f
    | .stoppedMin |= (if type == "number" and . >= 1 then floor else 10 end)
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

# The account the CLI is signed in to: only oauthAccount.accountUuid of ~/.claude.json (it names the account folder).
dsess_active_account() {
  local f="$HOME/.claude.json"
  [ -z "${DEPLOYS_DESKTOP_SESSIONS_FIXTURE:-}" ] || f="$DEPLOYS_DESKTOP_SESSIONS_FIXTURE/claude.json"
  [ -f "$f" ] || return 0
  jq -r '.oauthAccount.accountUuid // "" | if type == "string" then . else "" end' "$f" 2>/dev/null
}

# How each transcript ends, from its last 80 lines: JSON {cliSessionId: {end, key, note, mtime}}. end is finished,
# limit, error, cut (a tool result or prompt without an answer; a background task's notice does not count), tool (a tool call without its result: maybe a
# permission prompt, left alone), user-stopped or unknown. key is the uuid of that last entry (the stop point).
# Nothing of the conversation leaves this function except a limit's "resets ..." note.
DSESS_TAIL="$(cat <<'JQ'
split("\n") | map(fromjson? // empty | select(type == "object"))
| map(select(.type == "assistant" or .type == "user" or (.type == "system" and (.subtype == "api_error" or .subtype == "stop_hook_summary"))))
# a notice of a background task that arrived after the turn is no sign of a stop: it is skipped
| map(select((.type == "user" and ((.message.content // "") | type == "string" and startswith("<task-notification>"))) | not))
| (last // null) as $e
| ($e.message.content // "") as $c
| ([$c | if type == "array" then .[] else {type: "text", text: .} end]) as $parts
| ([$parts[] | (.text // (.content | if type == "array" then map(.text? // empty) | join(" ") else tostring end) // "") | tostring] | join(" ")) as $text
| {key: ($e.uuid // ""),
   end: (if $e == null then "unknown"
         elif $e.type == "system" then (if $e.subtype == "stop_hook_summary" then "finished" else "error" end)
         elif $text | contains("[Request interrupted by user") then "user-stopped"
         elif $e.type == "assistant" and $e.isApiErrorMessage == true then (if $e.error == "rate_limit" then "limit" else "error" end)
         elif $e.type == "assistant" then (if any($parts[]; .type == "tool_use") then "tool" else "finished" end)
         else "cut" end),
   note: (if $e.type == "assistant" and $e.error == "rate_limit" then ($text | capture("(?<r>resets [^·\n]+)").r // null | if . then rtrimstr(" ") else . end) else null end)}
JQ
)"

dsess_tails() {  # stdin: cli session ids, one per line
  local pj id f m out first=1; pj="$(dsess_projects)"
  printf '{'
  while IFS= read -r id; do
    case "$id" in ""|*[!0-9A-Za-z-]*) continue ;; esac
    for f in "$pj"/*/"$id.jsonl"; do [ -f "$f" ] && break; done
    [ -f "$f" ] || continue
    m="$(stat -c %Y "$f" 2>/dev/null || stat -f %m "$f" 2>/dev/null)"; [ -n "$m" ] || continue
    out="$(tail -n 80 "$f" 2>/dev/null | jq -Rsc --argjson m "$m" "$DSESS_TAIL + {mtime: \$m}" 2>/dev/null)" || continue
    [ -n "$out" ] || continue
    [ "$first" = 1 ] || printf ','; first=0
    printf '"%s":%s' "$id" "$out"
  done
  printf '}\n'
}

# The whole picture as JSON. Pure jq over the inputs, so the tests can feed it directly.
dsess_judge() {  # dsess_judge <files> <live> <agents> <activeOrg> <conf> <now> [tails] [activeAccount]
  jq -nc --argjson files "$1" --argjson live "$2" --argjson agents "$3" --arg org "$4" --argjson conf "$5" --argjson now "$6" \
    --argjson tails "${7:-null}" --arg acct "${8:-}" '
    ($files | map(.account) | unique) as $ids
    | ($agents | map({key: .sessionId, value: .status}) | from_entries) as $ag
    | [ $files[] | . as $s
        | ([$live[] | select(.host == $s.id or (.sessionId as $x | $s.cli | index([$x]) != null))]) as $procs
        | ([$procs[].status] + [$procs[].sessionId as $x | $ag[$x] // empty] + [$s.cli[] as $x | $ag[$x] // empty]) as $st
        | ($st | index("busy") != null) as $busy
        | ($s.awaiting or $s.needsAction or ($st | index("waiting") != null)) as $asks
        | (($s.prs | length) > 0 and ($s.prs | all(.state == "MERGED" or .state == "CLOSED"))) as $prsDone
        | (if $s.lastActivity then ([($now - $s.lastActivity) / 3600 | floor, 0] | max) else null end) as $idleH
        | (($tails // {}) as $tails | [$s.cli[] as $x | $tails[$x] // empty] | max_by(.mtime) // null) as $t
        | ([$s.lastActivity // 0, ($t.mtime // 0)] | max) as $last
        | (if $last > 0 then ([($now - $last) / 60 | floor, 0] | max) else null end) as $idleM
        | (if $busy then "running"
           elif $asks then "waiting"
           elif $prsDone and ($s.status != "review_ready" and $s.status != "blocked") then "done"
           elif $s.status == "review_ready" then "review"
           elif $s.status == "blocked" then "blocked"
           elif ($s.prs | length) == 0 and $s.status == "completed" then "idle"
           else "open" end) as $base
        | ($base != "running" and $base != "waiting" and $base != "done"
           and ($t.end // "") as $e | ($e == "limit" or $e == "error" or $e == "cut")
           and $idleM != null and $idleM >= $conf.stoppedMin) as $stopped
        | $s + {live: ($procs | length > 0), busy: $busy, waiting: $asks, idleHours: $idleH, idleMin: $idleM,
                folder: ($s.cwd | split("/") | map(select(. != "")) | last // ""),
                state: (if $stopped then "stopped" else $base end),
                stopReason: (if $stopped then $t.end else null end),
                stopKey: (if $stopped then $t.key else null end),
                stopNote: (if $stopped then $t.note else null end),
                userStopped: (($t.end // "") == "user-stopped"),
                openUrl: "claude://claude.ai/epitaxy/\($s.id)"} ]
    | sort_by(-(.lastActivity // 0)) as $all
    | ([$ids | to_entries[] | select(.value as $a | $all | any(.account == $a and .org == $org))] | length) as $nActive
    | [ $ids | to_entries[] | .key as $i | .value as $a
        | ($all | map(select(.account == $a))) as $mine
        | {id: $a, short: ($a | gsub("[^0-9a-fA-F]"; "") | .[0:8]),
           label: ($conf.labels[$a] // "Account \($i + 1) (\($a | gsub("[^0-9a-fA-F]"; "") | .[0:8]))"),
           active: (if $acct != "" then $a == $acct else ($org != "" and ($mine | any(.org == $org))) end),
           open: ($mine | length),
           done: ($mine | map(select(.state == "done")) | length),
           waiting: ($mine | map(select(.state == "waiting")) | length),
           running: ($mine | map(select(.state == "running")) | length),
           stopped: ($mine | map(select(.state == "stopped")) | length),
           idle: ($mine | map(select(.state == "idle" and (.idleHours // 0) >= $conf.idleHours)) | length),
           sessions: $mine} ] as $accounts
    | {time: $now, idleHours: $conf.idleHours,
       activeAmbiguous: ($acct == "" and $nActive > 1),
       totals: {accounts: ($accounts | length), open: ($all | length),
                done: ($all | map(select(.state == "done")) | length),
                waiting: ($all | map(select(.state == "waiting")) | length),
                running: ($all | map(select(.state == "running")) | length),
                stopped: ($all | map(select(.state == "stopped")) | length),
                accountsWithDone: ($accounts | map(select(.done > 0)) | length)},
       accounts: $accounts,
       hint: (if ($accounts | any(.done > 0)) then "Turn on \"Auto-archive sessions when their pull request closes\" (Claude app, Settings → Claude Code) in every account that has done sessions." else null end)}'
}

dsess_snapshot() {
  local now files live agents org tails
  now="$(dsess_now)"
  files="$(dsess_files)"; [ -n "$files" ] || files='[]'
  live="$(dsess_live)"; [ -n "$live" ] || live='[]'
  agents="$(dsess_agents)"; [ -n "$agents" ] || agents='[]'
  org="$(dsess_active_org)"
  tails="$(jq -r '.[] | select((.prs | length) == 0 or (.prs | any(.state == "OPEN"))) | .cli[]' <<<"$files" | dsess_tails)"
  [ -n "$tails" ] || tails='{}'
  dsess_judge "$files" "$live" "$agents" "$org" "$(dsess_conf)" "$now" "$tails" "$(dsess_active_account)"
}

dsess_print() {
  jq -r '
    def age: if . == null then "?" elif . < 48 then "\(.) h" else "\(. / 24 | floor) d" end;
    def name: if .title == "" then (if .folder == "" then .id else .folder end) else .title end;
    def prs: .prs | map("#\(.number // "?") \(.state | ascii_downcase)") | join(", ");
    .idleHours as $ih |
    "Claude desktop sessions: \(.totals.open) open across \(.totals.accounts) accounts · done, still open: \(.totals.done) · waiting on you: \(.totals.waiting) · stopped: \(.totals.stopped)",
    (if .totals.accounts == 0 then "  no desktop sessions found on this Mac" else empty end),
    (.accounts[] |
      "",
      "\(.label)\(if .active then "  (signed in now)" else "" end): \(.open) open, \(.done) done but open, \(.waiting) waiting on you, \(.stopped) stopped, \(.running) running",
      (.sessions[] | select(.state == "done") | "  done     \(name) — \(.folder) — \(prs) — \(.idleHours | age) ago"),
      (.sessions[] | select(.state == "waiting") | "  waiting  \(name) — \(.folder)"),
      (.sessions[] | select(.state == "stopped") | "  stopped  \(name) — \(.folder) — \(.stopReason)\(if .stopNote then " (\(.stopNote))" else "" end) — open: \(.openUrl)"),
      (.sessions[] | select(.state == "idle" and (.idleHours // 0) >= $ih) | "  idle \(.idleHours | age)  \(name) — \(.folder) (no pull request)"),
      (if .done > 0 then "  Archiving is the Claude app'"'"'s job: turn on \"Auto-archive sessions when their pull request closes\" (Settings → Claude Code) in this account." else empty end)),
    (if .activeAmbiguous then "", "Note: the signed-in org appears in several accounts; \"signed in now\" may mark more than one." else empty end),
    "",
    "Read-only: nothing is archived, ended or resumed from here."'
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
