#!/bin/bash
# Tests for `deploys sessions` (lib/sessions.sh): Claude cloud sessions read from GitHub. No network: a stand-in `gh`
# answers the GraphQL call with made-up pull requests and branches. Run: tests/sessions-tests.sh
set -uo pipefail
cd "$(dirname "$0")/.." || exit 1
exec </dev/null
fails=0
ok()   { echo "ok   $1"; }
fail() { echo "FAIL $1: $2"; fails=$((fails+1)); }
expect() { [ "$2" = "$3" ] && ok "$1" || fail "$1" "expected [$3], got [$2]"; }

tmp="$(mktemp -d)"; trap 'rm -rf "$tmp"' EXIT
export DEPLOYS_CONFIG="$tmp/config" HOME="$tmp/home" NO_COLOR=1 DEPLOYS_TESTING=1
mkdir -p "$HOME" "$DEPLOYS_CONFIG" "$tmp/bin"
printf '{"enabled":[]}' > "$DEPLOYS_CONFIG/providers.json"
now=1799841600
iso() { date -u -r "$(( now - $1 * 60 ))" +%Y-%m-%dT%H:%M:%SZ 2>/dev/null || date -u -d "@$(( now - $1 * 60 ))" +%Y-%m-%dT%H:%M:%SZ; }
export DEPLOYS_NOW="$now"

# Made-up repo acme/web: merged 5 min ago, merged 3 h ago, merged 9 h ago (outside 6 h), open 1 min, open 10 min,
# open but untouched 40 min, closed, a non-claude PR; branches: one pushed 2 min ago without PR, one 30 min ago,
# one that has a PR, and main.
cat > "$tmp/answer.json" <<J
{"data":{"repository":{"defaultBranchRef":{"name":"main"},
 "pullRequests":{"nodes":[
  {"number":11,"title":"feat: one","url":"https://github.com/acme/web/pull/11","state":"MERGED","headRefName":"claude/one","createdAt":"$(iso 6)","updatedAt":"$(iso 5)","mergedAt":"$(iso 5)","closedAt":"$(iso 5)",
   "first":{"nodes":[{"commit":{"authoredDate":"$(iso 47)"}}]},"last":{"nodes":[{"commit":{"committedDate":"$(iso 6)","message":"feat: one\n\nClaude-Session: https://claude.ai/code/session_01ABCdef\n"}}]}},
  {"number":10,"title":"fix: two","url":"https://github.com/acme/web/pull/10","state":"MERGED","headRefName":"claude/two","createdAt":"$(iso 181)","updatedAt":"$(iso 180)","mergedAt":"$(iso 180)","closedAt":"$(iso 180)",
   "first":{"nodes":[{"commit":{"authoredDate":"$(iso 200)"}}]},"last":{"nodes":[{"commit":{"committedDate":"$(iso 181)","message":"fix: two"}}]}},
  {"number":9,"title":"old","url":"u9","state":"MERGED","headRefName":"claude/old","createdAt":"$(iso 545)","updatedAt":"$(iso 540)","mergedAt":"$(iso 540)","closedAt":"$(iso 540)",
   "first":{"nodes":[]},"last":{"nodes":[]}},
  {"number":12,"title":"feat: fresh","url":"u12","state":"OPEN","headRefName":"claude/fresh","createdAt":"$(iso 1)","updatedAt":"$(iso 1)","mergedAt":null,"closedAt":null,
   "first":{"nodes":[{"commit":{"authoredDate":"$(iso 20)"}}]},"last":{"nodes":[{"commit":{"committedDate":"$(iso 1)","message":"x"}}]}},
  {"number":13,"title":"feat: waits","url":"u13","state":"OPEN","headRefName":"claude/waits","createdAt":"$(iso 10)","updatedAt":"$(iso 10)","mergedAt":null,"closedAt":null,
   "first":{"nodes":[{"commit":{"authoredDate":"$(iso 30)"}}]},"last":{"nodes":[{"commit":{"committedDate":"$(iso 10)","message":"x"}}]}},
  {"number":14,"title":"feat: hangs","url":"u14","state":"OPEN","headRefName":"claude/hangs","createdAt":"$(iso 45)","updatedAt":"$(iso 40)","mergedAt":null,"closedAt":null,
   "first":{"nodes":[{"commit":{"authoredDate":"$(iso 60)"}}]},"last":{"nodes":[{"commit":{"committedDate":"$(iso 45)","message":"x"}}]}},
  {"number":15,"title":"nope","url":"u15","state":"CLOSED","headRefName":"claude/nope","createdAt":"$(iso 30)","updatedAt":"$(iso 25)","mergedAt":null,"closedAt":"$(iso 25)",
   "first":{"nodes":[{"commit":{"authoredDate":"$(iso 35)"}}]},"last":{"nodes":[{"commit":{"committedDate":"$(iso 30)","message":"x"}}]}},
  {"number":16,"title":"by hand","url":"u16","state":"MERGED","headRefName":"fix/by-hand","createdAt":"$(iso 3)","updatedAt":"$(iso 2)","mergedAt":"$(iso 2)","closedAt":"$(iso 2)",
   "first":{"nodes":[]},"last":{"nodes":[]}}]},
 "refs":{"nodes":[
  {"name":"pushed","target":{"committedDate":"$(iso 2)","authoredDate":"$(iso 12)","message":"wip: pushed\n\nClaude-Session: https://claude.ai/code/session_01Pushed"}},
  {"name":"lost","target":{"committedDate":"$(iso 30)","authoredDate":"$(iso 50)","message":"wip: lost"}},
  {"name":"one","target":{"committedDate":"$(iso 6)","authoredDate":"$(iso 47)","message":"feat: one"}},
  {"name":"ancient","target":{"committedDate":"$(iso 2000)","authoredDate":"$(iso 2000)","message":"old"}}]}}}}
J
cat > "$tmp/bin/gh" <<SH
#!/bin/bash
echo "\$*" >> "$tmp/gh.log"
case "\$*" in
  *"name=broken"*) echo "GraphQL: Could not resolve to a Repository" >&2; exit 1 ;;
  *"api graphql"*) cat "$tmp/answer.json" ;;
  *) exit 1 ;;
esac
SH
chmod +x "$tmp/bin/gh"
export PATH="$tmp/bin:$PATH"
cli() { bash ./deploys "$@"; }

# --- no repo watched: no call at all ---
out="$(cli sessions)"
expect "no repo: says how to add one" "$(grep -c 'deploys sessions add' <<<"$out")" 1
expect "no repo: gh is not asked" "$(cat "$tmp/gh.log" 2>/dev/null | wc -l | tr -d ' ')" 0

# --- settings ---
cli sessions add acme/web >/dev/null
cli sessions add acme/web >/dev/null
expect "add keeps one entry" "$(jq -c .repos "$DEPLOYS_CONFIG/sessions.json")" '["acme/web"]'
cli sessions add 'bad name' >/dev/null 2>&1; expect "add refuses a bad name (exit 2)" "$?" 2
cli sessions set idle 30 >/dev/null; expect "set idle" "$(jq .idle "$DEPLOYS_CONFIG/sessions.json")" 30
cli sessions set wait abc >/dev/null 2>&1; expect "set refuses a non-number" "$?" 2
cli sessions set idle 20 >/dev/null
expect "settings file is private (600)" "$(stat -c %a "$DEPLOYS_CONFIG/sessions.json" 2>/dev/null || stat -f %Lp "$DEPLOYS_CONFIG/sessions.json")" 600

# --- the report ---
j="$(cli sessions --json)"
st() { jq -r --arg b "$1" '[.sessions[] | select(.branch == $b) | .state] | join(",")' <<<"$j"; }
expect "merged 5 min ago"            "$(st claude/one)" merged
expect "merged 3 h ago is in 6 h"    "$(st claude/two)" merged
expect "merged 9 h ago is left out"  "$(st claude/old)" ""
expect "pull request of 1 min: open" "$(st claude/fresh)" open
expect "open 10 min: waiting"        "$(st claude/waits)" waiting
expect "untouched 40 min: stuck"     "$(st claude/hangs)" stuck
expect "closed"                      "$(st claude/nope)" closed
expect "other prefixes left out"     "$(st fix/by-hand)" ""
expect "branch without PR, 2 min: pushed" "$(st claude/pushed)" pushed
expect "branch without PR, 30 min: stuck" "$(st claude/lost)" stuck
expect "a branch with a PR is one row" "$(jq '[.sessions[] | select(.branch == "claude/one")] | length' <<<"$j")" 1
expect "old branch left out"         "$(st claude/ancient)" ""
expect "session link from the trailer" "$(jq -r '.sessions[] | select(.branch == "claude/one") | .session' <<<"$j")" https://claude.ai/code/session_01ABCdef
expect "last commit subject" "$(jq -r '.sessions[] | select(.branch == "claude/pushed") | .lastCommit' <<<"$j")" "wip: pushed"
expect "minutes from the first authored commit to the merge" "$(jq -r '.sessions[] | select(.branch == "claude/one") | .minutes' <<<"$j")" 42
expect "summary" "$(jq -c '.summary' <<<"$j")" '{"merged":2,"mergedLastHour":1,"open":2,"waiting":1,"stuck":2,"closed":1}'
expect "newest first" "$(jq -r '.sessions[0].branch' <<<"$j")" claude/fresh
expect "--hours 12 takes the old one in" "$(cli sessions --json --hours 12 | jq '[.sessions[] | select(.branch == "claude/old")] | length')" 1
expect "the query asks for the claude/ branches" "$(grep -c 'refs=refs/heads/claude/' "$tmp/gh.log")" 2
txt="$(cli sessions)"
expect "text: summary line" "$(grep -c '1 merged in the last hour, 1 waiting, 2 stuck, 2 open' <<<"$txt")" 1
expect "text: a row" "$(grep -c 'waiting  claude/waits  #13' <<<"$txt")" 1

# --- a repo that cannot be read: an error entry, the others still come ---
cli sessions add acme/broken >/dev/null
j="$(cli sessions --json)"
expect "unreadable repo is named in errors" "$(jq -r '.errors[0].repo' <<<"$j")" acme/broken
expect "the other repo still counts" "$(jq '.summary.merged' <<<"$j")" 2
expect "--repo reads only that one" "$(cli sessions --json --repo acme/web | jq '.errors | length')" 0
cli sessions remove acme/broken >/dev/null
expect "remove" "$(jq -c .repos "$DEPLOYS_CONFIG/sessions.json")" '["acme/web"]'
cli sessions --nope >/dev/null 2>&1; expect "unknown option: exit 2" "$?" 2

[ "$fails" = 0 ] && echo "sessions-tests: all passed" || echo "sessions-tests: $fails failed"
[ "$fails" = 0 ]
