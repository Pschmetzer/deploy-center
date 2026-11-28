#!/bin/bash
# Tests for the MCP server report (lib/perfmcp.sh): made-up processes (tests/fixtures/perf-mcp/mcpps), made-up
# transcripts and a made-up ~/.claude.json. Nothing real is read; nothing is changed. Run: bash tests/perf-mcp-tests.sh
set -uo pipefail
cd "$(dirname "$0")/.." || exit 1
exec </dev/null
fails=0
ok()   { echo "ok   $1"; }
fail() { echo "FAIL $1: $2"; fails=$((fails+1)); }
expect() { [ "$2" = "$3" ] && ok "$1" || fail "$1" "expected [$3], got [$2]"; }

tmp="$(mktemp -d)"; trap 'rm -rf "$tmp"' EXIT
export DEPLOYS_CONFIG="$tmp/config" HOME="$tmp/home" NO_COLOR=1 DEPLOYS_TESTING=1
mkdir -p "$HOME" "$DEPLOYS_CONFIG"
export DEPLOYS_PERF_FIXTURE="$PWD/tests/fixtures/perf-mcp" DEPLOYS_CLAUDE_PROJECTS="$tmp/projects"
mkdir -p "$tmp/projects/-work-shop" "$tmp/projects/-work-blog" "$tmp/projects/-work-shop--claude-worktrees-x"
tu() { printf '{"cwd":"%s","message":{"content":[{"type":"tool_use","id":"t%s","name":"mcp__%s__run","input":{}}]}}\n' "$1" "$RANDOM" "$2"; }
{ tu /work/shop seo-tool; tu /work/shop seo-tool; tu /work/shop example-hub; } > "$tmp/projects/-work-shop/a.jsonl"
{ tu /work/shop/.claude/worktrees/x example-hub; tu /work/shop/.claude/worktrees/x ccd_session_mgmt; } > "$tmp/projects/-work-shop--claude-worktrees-x/b.jsonl"
{ printf '{"cwd":"/work/blog","type":"user"}\n'; tu /work/blog example-hub; } > "$tmp/projects/-work-blog/c.jsonl"
printf '{"cwd":"/work/blog"}\n{"type":"tool_use","id":"old","name":"mcp__geo__x"}\n' > "$tmp/projects/-work-blog/old.jsonl"
touch -t 202001010000 "$tmp/projects/-work-blog/old.jsonl"
echo '{"mcpServers":{"example-hub":{"command":"secret-should-not-be-read"}},"projects":{"/work/shop":{"mcpServers":{"seo-tool":{},"geo":{}}},"/work/blog":{"mcpServers":{"seo-tool":{},"geo":{}}}}}' > "$HOME/.claude.json"
. lib/perf.sh; . lib/perfmcp.sh

p="$(perf_mcp_procs)"
expect "grouped by name: the app bundle, the package, the script" "$(cut -f1 <<<"$p" | sort | tr '\n' ' ')" "Example Hub geo-mcp seo-tool-mcp-server "
expect "npm exec with its node child, in one session" "$(awk -F'\t' '$1 == "seo-tool-mcp-server" {print $2, $3, $4}' <<<"$p")" "2 341 1"
expect "one server in two sessions" "$(awk -F'\t' '$1 == "Example Hub" {print $2, $4}' <<<"$p")" "2 2"
expect "the Bash tool's shell, a vitest run and a process without Claude are no MCP servers" "$(grep -cE 'zsh|vitest|server\.js' <<<"$p")" "0"

r="$(perf_mcp_report 7)"
expect "calls per server, a worktree counts as its repo, an old file does not count" "$(jq -c '[.servers[] | [.name, .calls, .projects]] | sort' <<<"$r")" '[["Example Hub",3,2],["geo-mcp",0,0],["seo-tool-mcp-server",2,1]]'
expect "unused: off where configured" "$(jq -r '.servers[] | select(.name == "geo-mcp") | [.suggestKind, (.configuredIn | join(","))] | join(" ")' <<<"$r")" "unused blog,shop"
expect "used in one project: off in the other" "$(jq -r '.servers[] | select(.name == "seo-tool-mcp-server") | [.suggestKind, (.offIn | join(","))] | join(" ")' <<<"$r")" "offIn blog"
expect "used where it is on everywhere: no suggestion" "$(jq -r '.servers[] | select(.name == "Example Hub") | .suggestKind' <<<"$r")" "null"
expect "the Claude app's own tools are not listed as idle servers" "$(jq -r '[.idleTools[].server] | map(select(startswith("ccd_"))) | length' <<<"$r")" "0"
expect "no command or env of ~/.claude.json in the report" "$(grep -c secret <<<"$r")" "0"
expect "a second run reads only changed files (cache)" "$(perf_mcp_usage 7 >/dev/null; wc -l < "$DEPLOYS_CONFIG/perf/mcp-usage.tsv" | tr -d ' ')" "5"
out="$(json=0 perf_mcp_main)"
expect "text: the suggestion and that nothing was changed" "$(grep -c 'suggestion: off in blog, shop\|Nothing was changed' <<<"$out")" "2"
expect "--json" "$(json=1 perf_mcp_main | jq -r .days)" "7"

[ "$fails" = 0 ] && echo "perf-mcp: all passed" || { echo "perf-mcp: $fails failed"; exit 1; }
