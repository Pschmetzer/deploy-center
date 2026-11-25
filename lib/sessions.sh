# shellcheck shell=bash
# lib/sessions.sh — `deploys sessions`: which Claude Code cloud sessions finished, wait or seem stuck.
#
#   deploys sessions [--hours 6] [--repo <owner/name>] [--json]   the sessions of the watched repos
#   deploys sessions add|remove <owner/name>                      watch a repo (or stop)
#   deploys sessions repos                                        the watched repos and the settings
#   deploys sessions set prefix|wait|idle|hours <value>           branch prefix (claude/), minutes, hours
#
# There is no public interface for the state of a cloud session, so GitHub is the signal: a cloud session pushes a
# branch (claude/… by default) and opens a pull request, and its commits carry a "Claude-Session: <url>" trailer.
# The commit dates are rewritten when it pushes, so the time a branch was last pushed says little; the authored
# date of its first commit is when the work began. One GraphQL call per repo: the newest pull requests and branches.
# States of a row:
#   merged   the pull request was merged: the session is done, a slot is free
#   closed   closed without a merge
#   open     a pull request opened less than `wait` minutes ago (sessions that merge themselves do it in seconds)
#   waiting  a pull request open for `wait` minutes or more: it waits for someone
#   stuck    no change for `idle` minutes: an open pull request nobody touches, or a branch pushed without one
#   pushed   a branch without a pull request, pushed less than `idle` minutes ago
# Settings in sessions.json in the config folder (never in the repo): {"repos":[…],"prefix":"claude/","wait":3,
# "idle":20,"hours":6}. Read only: nothing here pushes, merges or closes anything.

SESSIONS_FILE="${CONFIG_DIR:-$HOME/.config/deploys}/sessions.json"

sessions_conf() {  # the settings with their defaults
  { cat "$SESSIONS_FILE" 2>/dev/null || echo '{}'; } | jq -c '(if type == "object" then . else {} end)
    | {repos: ([.repos[]? | strings] | unique), prefix: (.prefix // "claude/"), wait: (.wait // 3), idle: (.idle // 20), hours: (.hours // 6)}' 2>/dev/null \
    || echo '{"repos":[],"prefix":"claude/","wait":3,"idle":20,"hours":6}'
}
sessions_save() { jq . | atomic_write "$SESSIONS_FILE"; }

sessions_query() {
  cat <<'GRAPHQL'
query($owner:String!,$name:String!,$refs:String!){repository(owner:$owner,name:$name){
 defaultBranchRef{name}
 pullRequests(first:60,orderBy:{field:UPDATED_AT,direction:DESC}){nodes{number title url state headRefName createdAt updatedAt mergedAt closedAt
  first:commits(first:1){nodes{commit{authoredDate}}} last:commits(last:1){nodes{commit{committedDate message}}}}}
 refs(refPrefix:$refs,first:40,orderBy:{field:TAG_COMMIT_DATE,direction:DESC}){nodes{name target{... on Commit{committedDate authoredDate message}}}}}}
GRAPHQL
}

# sessions_fetch <owner/name> <prefix>: the raw answer of GitHub for one repo, or {"error": "…"}.
sessions_fetch() {
  local out refs="refs/heads/$2"
  case "$refs" in */) ;; *) refs="refs/heads/" ;; esac   # GitHub takes only a prefix that ends with /
  if out="$(gh api graphql -f query="$(sessions_query)" -f owner="${1%%/*}" -f name="${1#*/}" -f refs="$refs" 2>&1)" \
     && jq -e '.data.repository' >/dev/null 2>&1 <<<"$out"; then
    jq -c --arg refs "${refs#refs/heads/}" '.data.repository + {refsPrefix: $refs}' <<<"$out"
  else
    jq -cn --arg e "$(printf '%s' "$out" | head -c 300)" '{error: (if $e == "" then "no answer from gh" else $e end)}'
  fi
}

# jq: the rows of one repo. In: {repo, data, now, conf}. A pull request or branch outside the window is left out.
sessions_jq() {
  cat <<'JQ'
def t: if . == null then null else (sub("\\.[0-9]+Z$"; "Z") | fromdateiso8601) end;
def link: (tostring | [scan("https://claude\\.ai/code/session_[A-Za-z0-9]+")][0]);
.now as $now | .conf as $c | .repo as $repo | .data as $d
| ($d.defaultBranchRef.name // "main") as $main
| [$d.pullRequests.nodes[]? | select(($c.prefix == "") or (.headRefName | startswith($c.prefix)))] as $prs
| ($prs | map(.headRefName)) as $withPr
| ($now - $c.hours * 3600) as $from
| ([ $prs[] |
      (.last.nodes[0].commit.committedDate | t) as $pushed
      | ([.createdAt, .updatedAt, .mergedAt, .closedAt] | map(t) | max) as $touched
      | select($touched >= $from)
      | (.first.nodes[0].commit.authoredDate | t) as $began
      | (if .state == "MERGED" then "merged" elif .state == "CLOSED" then "closed"
         elif ($now - ([(.updatedAt | t), $pushed] | max)) >= $c.idle * 60 then "stuck"
         elif ($now - (.createdAt | t)) >= $c.wait * 60 then "waiting" else "open" end) as $s
      | {repo: $repo, branch: .headRefName, state: $s, title, pr: .number, url, session: (.last.nodes[0].commit.message | link),
         began: .first.nodes[0].commit.authoredDate, pushed: .last.nodes[0].commit.committedDate, opened: .createdAt,
         lastCommit: ((.last.nodes[0].commit.message // "") | split("\n")[0]),
         ended: (.mergedAt // .closedAt),
         minutes: (if $began == null then null else ((((.mergedAt // .closedAt) | t) // $now) - $began) / 60 | floor end),
         idleMinutes: (if $s == "merged" or $s == "closed" then null else (($now - ([(.updatedAt | t), $pushed] | max)) / 60 | floor) end)} ]
  + [ $d.refs.nodes[]? | ($d.refsPrefix + .name) as $b
      | select($b != $main and (($withPr | index($b)) | not))
      | (.target.committedDate | t) as $pushed | select($pushed != null and $pushed >= $from)
      | (($now - $pushed) / 60 | floor) as $idle
      | {repo: $repo, branch: $b, state: (if $idle >= $c.idle then "stuck" else "pushed" end), title: (.target.message | split("\n")[0]),
         pr: null, url: null, session: (.target.message | link), began: .target.authoredDate, pushed: .target.committedDate,
         lastCommit: ((.target.message // "") | split("\n")[0]),
         opened: null, ended: null, minutes: ((($now - ((.target.authoredDate | t) // $pushed)) / 60) | floor), idleMinutes: $idle} ])
JQ
}

sessions_report() {  # sessions_report <hours or ""> <repo or "">: the whole answer as JSON
  local conf now repos r data rows='[]' errors='[]'
  conf="$(sessions_conf)"; now="${DEPLOYS_NOW:-$(date +%s)}"
  [ -z "$1" ] || conf="$(jq -c --argjson h "$1" '.hours = $h' <<<"$conf")"
  if [ -n "$2" ]; then repos="$2"; else repos="$(jq -r '.repos[]' <<<"$conf")"; fi
  for r in $repos; do
    data="$(sessions_fetch "$r" "$(jq -r .prefix <<<"$conf")")"
    if jq -e '.error' >/dev/null <<<"$data"; then
      errors="$(jq -c --arg r "$r" --argjson d "$data" '. + [{repo: $r, error: $d.error}]' <<<"$errors")"; continue
    fi
    rows="$(jq -c --argjson rows "$rows" --arg r "$r" --argjson now "$now" --argjson c "$conf" \
      "\$rows + ({repo: \$r, data: ., now: \$now, conf: \$c} | $(sessions_jq))" <<<"$data")"
  done
  jq -n --argjson rows "$rows" --argjson errors "$errors" --argjson conf "$conf" --argjson now "$now" '
    ($rows | sort_by(.ended // .pushed // .opened // "") | reverse) as $r
    | {at: ($now | todate), settings: ($conf | del(.repos)), repos: $conf.repos, errors: $errors,
       summary: {merged: ([$r[] | select(.state == "merged")] | length),
                 mergedLastHour: ([$r[] | select(.state == "merged" and ((.ended | sub("\\.[0-9]+Z$"; "Z") | fromdateiso8601) >= $now - 3600))] | length),
                 open: ([$r[] | select(.state == "open" or .state == "pushed")] | length),
                 waiting: ([$r[] | select(.state == "waiting")] | length), stuck: ([$r[] | select(.state == "stuck")] | length),
                 closed: ([$r[] | select(.state == "closed")] | length)},
       sessions: $r}'
}

sessions_print() {  # stdin: the JSON of sessions_report
  jq -r '
    def ago: if . == null then "" else "\(.) min" end;
    if (.repos | length) == 0 and (.sessions | length) == 0 then
      "No repo is watched. Add one: deploys sessions add <owner/name>"
    else
      "Cloud sessions of the last \(.settings.hours) h (\(.repos | join(", "))):",
      "  \(.summary.mergedLastHour) merged in the last hour, \(.summary.waiting) waiting, \(.summary.stuck) stuck, \(.summary.open) open",
      (.errors[] | "  \(.repo): not read (\(.error | split("\n")[0]))"),
      (if (.sessions | length) == 0 then "  No session branch or pull request in this time." else empty end),
      (.sessions[] | "  \(.state | ("        " + .)[-7:])  \(.branch)\(if .pr then "  #\(.pr)" else "" end)  \(.minutes | ago)\(if .idleMinutes then ", quiet \(.idleMinutes) min" else "" end)  \(.title // "" | .[0:60])\(if .pushed then "  (pushed \(.pushed[11:16]) UTC: \(.lastCommit // "" | .[0:50]))" else "" end)")
    end'
}

sessions_main() {
  local hours="" repo="" conf
  case "${1:-}" in
    add|remove)
      [[ "${2:-}" =~ ^[A-Za-z0-9_.-]+/[A-Za-z0-9_.-]+$ ]] || die_usage "deploys sessions $1 <owner/name>"
      conf="$(sessions_conf)"
      if [ "$1" = add ]; then jq --arg r "$2" '.repos = (.repos + [$r] | unique)' <<<"$conf" | sessions_save
      else jq --arg r "$2" '.repos -= [$r]' <<<"$conf" | sessions_save; fi
      echo "Watched repos: $(sessions_conf | jq -r '.repos | if length == 0 then "none" else join(", ") end')"; return ;;
    repos)
      if [ "${json:-0}" = 1 ]; then sessions_conf | jq .; else sessions_conf | jq -r '"Watched repos: \(.repos | if length == 0 then "none" else join(", ") end)",
        "Branch prefix: \(if .prefix == "" then "(every branch)" else .prefix end), waiting after \(.wait) min, stuck after \(.idle) min, window \(.hours) h"'; fi
      return ;;
    set)
      case "${2:-}" in
        prefix) [[ "${3-}" =~ ^([A-Za-z0-9_.-]+/)*$ ]] || die_usage "deploys sessions set prefix <name/> (empty: every branch)"
                sessions_conf | jq --arg v "${3-}" '.prefix = $v' | sessions_save ;;
        wait|idle|hours) [[ "${3:-}" =~ ^[1-9][0-9]{0,3}$ ]] || die_usage "deploys sessions set $2 <number, 1-9999>"
                sessions_conf | jq --arg k "$2" --argjson v "$3" '.[$k] = $v' | sessions_save ;;
        *) die_usage "deploys sessions set prefix|wait|idle|hours <value>" ;;
      esac
      sessions_main repos; return ;;
  esac
  while [ "$#" -gt 0 ]; do
    case "$1" in
      --hours) [[ "${2:-}" =~ ^[1-9][0-9]{0,2}$ ]] || die_usage "--hours takes 1 to 999"; hours="$2"; shift ;;
      --repo) [[ "${2:-}" =~ ^[A-Za-z0-9_.-]+/[A-Za-z0-9_.-]+$ ]] || die_usage "--repo takes owner/name"; repo="$2"; shift ;;
      *) die_usage "Unknown option $1. Usage: deploys sessions [--hours 6] [--repo <owner/name>] [--json] | add|remove <owner/name> | repos | set <key> <value>" ;;
    esac
    shift
  done
  command -v gh >/dev/null 2>&1 || die "deploys sessions needs the GitHub CLI (gh), logged in: gh auth login"
  if [ "${json:-0}" = 1 ]; then sessions_report "$hours" "$repo"; else sessions_report "$hours" "$repo" | sessions_print; fi
}
