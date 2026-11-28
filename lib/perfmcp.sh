# shellcheck shell=bash
# lib/perfmcp.sh — `deploys perf mcp [--json] [--days 7]`: the MCP servers Claude Code sessions run on this Mac, grouped
# by name (processes, memory, how many sessions), how often their tools were called in the last days (from the session
# transcripts, read-only) and a suggestion which ones could be off, and where. Read-only: it never changes
# ~/.claude/settings.json, a project's .mcp.json or any Claude setting; turning a server off is the person's call.
# Bash 3.2.
#
# A server is a process (and everything below it) whose parent is a Claude Code process and that is not a shell (the
# Bash tool) or Claude itself. Its name: the app bundle it lives in, else the package (node_modules/.bin/<x>, npm exec
# <x>@1, uvx <x>), else the script's file name. Tool calls: `"name":"mcp__<server>__<tool>"` in
# ~/.claude/projects/<project>/*.jsonl changed in the last --days days; counted per file and kept in perf/mcp-usage.tsv,
# so a file is read again only after it changed. The tools of the Claude app itself (ccd_*, Claude_Browser ...) run in
# the app, not as a process of their own, and are never suggested.
# Tests: DEPLOYS_PERF_FIXTURE/mcpps (ps -axo pid=,ppid=,rss=,args=), DEPLOYS_CLAUDE_PROJECTS (made-up transcripts),
# DEPLOYS_PERF_NOW.

PERF_MCP_BUILTIN='^(ccd_|Claude_Browser|Claude_Code_|claude_ai_|terminal$|visualize$|computer-use$|mcp-registry$|scheduled-tasks$)'

# perf_mcp_procs: TSV `name<TAB>processes<TAB>MB<TAB>sessions` of the running servers.
perf_mcp_procs() {
  perf_src mcpps ps -axo pid=,ppid=,rss=,args= | awk '
    function base(x) { sub(/.*\//, "", x); return x }
    function isclaude(a) { return a ~ /claude-code\/[^ ]*\/claude( |$)|\/\.local\/bin\/claude( |$)|^claude( |$)/ && a !~ /disclaimer/ }
    function name(a,   n, t, i, w) {
      sub(/^.*\/disclaimer( --?[a-z-]+)* -- /, "", a)
      if (match(a, /\/[^\/]+\.app\/Contents\//)) { w = substr(a, RSTART + 1, RLENGTH - 1); sub(/\.app\/Contents\/$/, "", w); return w }
      if (match(a, /node_modules\/\.bin\/[^ ]+/)) return base(substr(a, RSTART, RLENGTH))
      n = split(a, t, " ")
      for (i = 2; i <= n; i++) { w = t[i]; if (w ~ /^-/ || w == "exec" || w == "x" || w == "dlx" || w == "run" || w == "--") continue
        w = base(w); sub(/@[0-9][^ ]*$/, "", w); sub(/\.(m?js|py|ts)$/, "", w); return w }
      return base(t[1]) }
    { pid = $1; pp = $2; r = $3; a = $0; sub(/^ *[0-9]+ +[0-9]+ +[0-9]+ +/, "", a); P[pid] = pp; R[pid] = r; A[pid] = a; kids[pp] = kids[pp] " " pid; order[++np] = pid }
    function tree(p,   k, m, i) { mb += R[p]; cnt++; m = split(kids[p], k, " "); for (i = 1; i <= m; i++) tree(k[i]) }
    END {
      for (j = 1; j <= np; j++) { p = order[j]; q = P[p]
        # its parent is a Claude Code process; not a shell (the Bash tool), not Claude itself
        if (!(q in A) || !isclaude(A[q])) continue
        if (isclaude(A[p]) || A[p] ~ /^(\/bin\/)?(zsh|bash|sh)( |$)|caffeinate/) continue
        # a check or dev server the Bash tool started without a shell is no MCP server
        if (A[p] ~ /node_modules\/\.bin\/(vitest|jest|tsc|eslint|next|vite|playwright)( |$)|^(npm|pnpm|yarn|bun) (run|test|t)( |$)|(npm exec|npx) (-y )?(vitest|jest|tsc|eslint|next|vite|playwright)( |$)|next dev|vite( |$)/) continue
        n = name(A[p]); mb = 0; cnt = 0; tree(p)
        N[n] += cnt; M[n] += mb; S[n] = S[n] " " q }
      for (n in N) { k = split(S[n], ss, " "); delete u; c = 0; for (i = 1; i <= k; i++) if (!(ss[i] in u)) { u[ss[i]] = 1; c++ }
        printf "%s\t%d\t%d\t%d\n", n, N[n], M[n] / 1024, c } }' | sort -t "$(printf '\t')" -k3,3nr
}

# perf_mcp_usage <days>: TSV `server<TAB>project<TAB>calls` from the transcripts changed in the last <days> days.
perf_mcp_usage() {
  local days="${1:-7}" root cache f m line
  root="${DEPLOYS_CLAUDE_PROJECTS:-$HOME/.claude/projects}"; [ -d "$root" ] || return 0
  mkdir -p "$PERF_DIR" 2>/dev/null; cache="$PERF_DIR/mcp-usage.tsv"; [ -f "$cache" ] || : > "$cache"
  # file<TAB>mtime of every transcript in the window (a cache of an older format is dropped)
  awk -F'\t' 'NF != 5 {bad = 1} END {exit !bad}' "$cache" 2>/dev/null && : > "$cache"
  if [ "$(uname)" = Darwin ]; then
    find "$root" -mindepth 2 -maxdepth 2 -name '*.jsonl' -type f -mtime -"$days" -exec stat -f '%N%t%m' {} + 2>/dev/null > "$cache.files"
  else
    find "$root" -mindepth 2 -maxdepth 2 -name '*.jsonl' -type f -mtime -"$days" -printf '%p\t%T@\n' 2>/dev/null | sed 's/\.[0-9]*$//' > "$cache.files"
  fi
  # cache lines: file<TAB>mtime<TAB>server<TAB>calls<TAB>project (a file with no calls has one line with server "-").
  # The project is the folder the session worked in (its first "cwd"), a worktree counted as its repo, by its name.
  awk -F'\t' 'NR == FNR { want[$1] = $2; next } ($1 in want) && want[$1] == $2 { print; have[$1] = 1 } END { for (f in want) if (!(f in have)) print f > "/dev/stderr" }' \
    "$cache.files" "$cache" 2> "$cache.todo" > "$cache.keep"
  local proj
  while IFS= read -r f; do
    [ -n "$f" ] || continue
    m="$(awk -F'\t' -v f="$f" '$1 == f {print $2; exit}' "$cache.files")"
    proj="$(grep -m1 -oE '"cwd":"[^"]*"' "$f" 2>/dev/null | sed -E 's/^"cwd":"//; s/"$//; s#/\.claude/worktrees/.*##; s#.*/##')"
    [ -n "$proj" ] || proj="?"
    line="$(nice -n 19 grep -oE '"type":"tool_use","id":"[^"]*","name":"mcp__[A-Za-z0-9_.-]+' "$f" 2>/dev/null | sed -E 's/.*"name":"mcp__//; s/__.*//' | sort | uniq -c)"
    if [ -z "$line" ]; then printf '%s\t%s\t-\t0\t%s\n' "$f" "$m" "$proj"
    else printf '%s\n' "$line" | awk -v f="$f" -v m="$m" -v p="$proj" '{ printf "%s\t%s\t%s\t%d\t%s\n", f, m, $2, $1, p }'; fi
  done < "$cache.todo" >> "$cache.keep"
  mv -f "$cache.keep" "$cache"; rm -f "$cache.files" "$cache.todo"
  awk -F'\t' '$3 != "-" { c[$3 "\t" $5] += $4 } END { for (k in c) print k "\t" c[k] }' "$cache"
}

# perf_mcp_config: JSON [{name, where}] of the servers in ~/.claude.json: where is "everywhere" or a project's folder
# name. Only the names are read, never a command, an argument or an env value.
perf_mcp_config() {
  local f="$HOME/.claude.json"
  [ -f "$f" ] || { echo '[]'; return 0; }
  jq -c '[(.mcpServers // {} | keys[] | {name:., where:"everywhere"}),
          (.projects // {} | to_entries[] | (.key | split("/") | last) as $p | (.value.mcpServers // {}) | keys[] | {name:., where:$p})]' "$f" 2>/dev/null || echo '[]'
}

# perf_mcp_report <days>: JSON {days, servers:[{name, processes, mb, sessions, calls, projects, usedIn:[{project,calls}],
# builtin, suggest}]}. A running server is matched to the tool names by its name (letters and digits only, one in the other).
perf_mcp_report() {
  local days="${1:-7}" procs usage
  procs="$(perf_mcp_procs)"; usage="$(perf_mcp_usage "$days")"
  jq -nc --arg p "$procs" --arg u "$usage" --argjson d "$days" --arg b "$PERF_MCP_BUILTIN" --argjson cfg "$(perf_mcp_config)" '
    def norm: ascii_downcase | gsub("[^a-z0-9]"; "") | sub("^plugin"; "") | sub("(mcpserver|mcp|server)$"; "") | sub("^mcp"; "");
    ($p | split("\n") | map(select(length > 0) | split("\t") | {name:.[0], processes:(.[1] | tonumber), mb:(.[2] | tonumber), sessions:(.[3] | tonumber)})) as $procs
    | ($u | split("\n") | map(select(length > 0) | split("\t") | {server:.[0], project:.[1], calls:(.[2] | tonumber)})) as $use
    | ($use | group_by(.server) | map({key:.[0].server, value:(sort_by(-.calls) | map({project, calls}))}) | from_entries) as $by
    | def like($a; $k): ($a | length) >= 3 and ($k | length) >= 3 and (($a | contains($k)) or ($k | contains($a)));
      def match($n): ($n | norm) as $a | [$by | keys[] | select((norm) as $k | like($a; $k))];
      ($procs | map(. as $x | (match($x.name)) as $keys
        | ([$keys[] as $k | $by[$k][]] | group_by(.project) | map({project:.[0].project, calls:(map(.calls) | add)}) | sort_by(-.calls)) as $in
        | ($x.name | norm) as $a | ([$cfg[] | select((.name | norm) as $k | like($a; $k))]) as $c
        | $x + {tools:$keys, calls:([$in[].calls] | add // 0), projects:($in | length), usedIn:$in[:10],
                configuredIn:($c | map(.where) | unique), configName:($c[0].name // null),
                offIn:(($c | map(.where) | unique) - [$in[].project])})) as $running
    | ($running | map(.tools[]) ) as $taken
    | {days:$d,
       servers:($running | map(. + {suggest:(
           if .calls == 0 then "off\(if (.configuredIn | length) > 0 then " in " + (.configuredIn | join(", ")) else "" end): not one tool call in \($d) days, \(.mb) MB in \(.sessions) sessions"
           elif (.offIn | length) > 0 and (.offIn | index("everywhere")) == null then "off in \(.offIn | join(", ")) (no calls there in \($d) days); keep in \([.usedIn[].project] | join(", "))"
           elif (.configuredIn | index("everywhere")) != null and .projects <= 2 and .sessions > .projects * 2 then "only in the projects that use it (\([.usedIn[].project] | join(", "))) instead of everywhere"
           else null end),
         suggestKind:(if .calls == 0 then "unused" elif (.offIn | length) > 0 and (.offIn | index("everywhere")) == null then "offIn"
           elif (.configuredIn | index("everywhere")) != null and .projects <= 2 and .sessions > .projects * 2 then "onlyUsed" else null end),
         usedInNames:[.usedIn[].project]})),
       idleTools:([$by | to_entries[] | select(.key as $k | ($taken | index($k)) == null and ($k | test($b) | not))
                   | {server:.key, calls:([.value[].calls] | add), projects:(.value | length)}] | sort_by(-.calls))}'
}

perf_mcp_main() {
  local days=7 r
  while [ "$#" -gt 0 ]; do
    case "$1" in --days) days="${2:-7}"; shift ;; *) echo "Usage: deploys perf mcp [--days 7] [--json]" >&2; return 2 ;; esac
    shift
  done
  case "$days" in ''|*[!0-9]*) days=7 ;; esac
  r="$(perf_mcp_report "$days")" || return 1
  if [ "${json:-0}" = 1 ]; then echo "$r"; return 0; fi
  jq -r '
    "MCP SERVERS RUNNING (tool calls in the last \(.days) days)",
    (if (.servers | length) == 0 then "  none" else empty end),
    (.servers[] | "  \(.mb | tostring | . + " MB      " | .[:9]) \(.name)  \(.processes) processes in \(.sessions) sessions  \(.calls) calls in \(.projects) projects"
       + (if .suggest then "\n      suggestion: \(.suggest)" else "" end)),
    "", "Nothing was changed. Turning a server off is yours: claude mcp remove, the plugin or connector settings, or a project'"'"'s .mcp.json."' <<<"$r"
}
