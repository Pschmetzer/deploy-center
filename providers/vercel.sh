# shellcheck shell=bash
# shellcheck disable=SC2154  # CONFIG_DIR, REPOS, RED, PLAIN and the helpers come from `deploys`.
# Vercel, through the `vercel` CLI login on this Mac (`vercel login`). Sourced by `deploys`.
# The contract every provider fulfils is in docs/PROVIDERS.md. A Vercel project's id here is its
# name: the API takes either, and every command people type uses the name.

vercel_meta() {
  printf '%s\n' '{"id":"vercel","label":"Vercel","noun":"project","defaultOn":true,"keyEnv":["VERCEL_TOKEN"],"keychain":null,"auth":"vercel CLI login","onDryRun":true,"caps":{"off":true,"sha":true,"cancel":true,"rollback":true,"logs":true,"preview":true}}'
}

# Set up here: the CLI is installed, or projects are remembered. Under launchd's PATH the vercel
# CLI is often not found, and that must be an error, not a silent "no Vercel projects".
vercel_ready() {
  command -v vercel >/dev/null 2>&1 || [ "$(jq 'length' "$REPOS" 2>/dev/null || echo 0)" != 0 ]
}

# The team the commands act on. Detected once and remembered; a personal account has none.
# A team id goes into every API query string: letters, digits, _ and - only.
valid_team() { case "$1" in *[!A-Za-z0-9_-]*) return 1;; esac; }
vercel_team() {
  if [ -n "${DEPLOYS_VERCEL_TEAM:-}" ]; then
    valid_team "$DEPLOYS_VERCEL_TEAM" || die "DEPLOYS_VERCEL_TEAM is not a team id"
    echo "$DEPLOYS_VERCEL_TEAM"; return
  fi
  # A team is remembered for good. "No team" (a personal account) only for a day: one joined
  # later is then found without anyone deleting the file.
  if [ -s "$CONFIG_DIR/vercel-team" ]; then
    valid_team "$(cat "$CONFIG_DIR/vercel-team")" || die "$CONFIG_DIR/vercel-team does not hold a team id. Set it: deploys vercel team <id>"
    cat "$CONFIG_DIR/vercel-team"; return
  fi
  if [ -f "$CONFIG_DIR/vercel-team" ] && [ $(( $(date +%s) - $(mtime "$CONFIG_DIR/vercel-team") )) -lt 86400 ]; then echo ""; return; fi
  local teams n ef e
  # The CLI's own words go along: "fetch failed" is not "not logged in", and must not send
  # people to `vercel login`.
  ef="$(mktemp)"
  teams="$(vercel_api_raw /v2/teams 2>"$ef")" || { e="$(cat "$ef")"; rm -f "$ef"; die "Could not ask Vercel for your teams${e:+ ($e)}. If it says you are not logged in: vercel login"; }
  rm -f "$ef"
  # Only a real team list is remembered: an error body without .teams is not "no team" for a day.
  echo "$teams" | jq -e '.teams | type == "array"' >/dev/null 2>&1 || die "Vercel answered without a team list: $(printf '%s' "$teams" | head -c 200)"
  n="$(echo "$teams" | jq '.teams | length')"
  if [ "$n" = "0" ]; then
    : > "$CONFIG_DIR/vercel-team"; echo ""
  elif [ "$n" = "1" ]; then
    echo "$teams" | jq -r '.teams[0].id' | tr -d '\n' | tee "$CONFIG_DIR/vercel-team"
  else
    echo "$teams" | jq -r '.teams[] | "  \(.id)  \(.slug)"' >&2
    die "Several Vercel teams. Choose one: deploys vercel team <id>"
  fi
}

# Query string for the team, empty for a personal account. A failure (several teams, not logged
# in) is the caller's failure: never quietly ask the personal account instead.
team_q() { local t; t="$(vercel_team)" || return 1; if [ -n "$t" ]; then echo "teamId=$t"; else echo ""; fi; }
with_team() {
  local q; q="$(team_q)" || return 1
  case "$1" in *\?*) echo "$1${q:+&$q}";; *) echo "$1${q:+?$q}";; esac
}

# `vercel` with a time limit: macOS has no `timeout`, and perl's alarm survives the exec. A hung
# CLI then ends with 142 (SIGALRM). Without perl it runs as it is. Update notices stay off
# stderr: they would be the line a failure is reported with.
VERCEL_TIMEOUT="${DEPLOYS_VERCEL_TIMEOUT:-60}"
vercel_run() {
  # A `vercel` shell function (a test's stand-in) cannot be exec'd: it is called as it is.
  if [ "$(type -t vercel)" != function ] && command -v perl >/dev/null 2>&1; then
    NO_UPDATE_NOTIFIER=1 perl -e 'alarm shift; exec @ARGV or die "vercel: $!\n"' "$VERCEL_TIMEOUT" vercel "$@"
  else
    NO_UPDATE_NOTIFIER=1 vercel "$@"
  fi
}

# Worth asking again: no answer, a network error, the rate limit or a server error. The words
# are the vercel CLI's and Node's (inferred, not checked against every CLI version).
vercel_transient() {  # <rc> <stderr file>
  [ "$1" = 142 ] && return 0
  grep -qiE 'fetch failed|ETIMEDOUT|ECONNRESET|ECONNREFUSED|ENOTFOUND|EAI_AGAIN|socket hang up|network|timed? ?out|too many requests|rate limit|\((429|5[0-9][0-9])\)' "$2"
}

# The reason of a failed call in one line: the first "error" line, or else the last line.
vercel_reason() {  # <rc> <stderr file>
  local r; r="$(grep -m 1 -i 'error' "$2" | cut -c1-300)"
  [ -n "$r" ] || r="$(grep -v '^[[:space:]]*$' "$2" | tail -n 1 | cut -c1-300)"
  [ "$1" != 142 ] || r="no answer within ${VERCEL_TIMEOUT} s${r:+ ($r)}"
  printf '%s' "${r:-failed (exit $1)}"
}

# vercel_api_raw <path> [args]: `vercel api` without the team. Reads (no --method, or GET) are
# asked up to three times when the failure looks passing; POST, PATCH and DELETE never: they may
# have happened already. On failure the reason goes to stderr ("not found" and "not logged in" differ).
vercel_api_raw() {
  local path="$1" m=GET prev="" a e rc try; shift
  for a in "$@"; do [ "$prev" = --method ] && m="$(echo "$a" | tr '[:lower:]' '[:upper:]')"; prev="$a"; done
  e="$(mktemp)"
  for try in 1 2 3; do
    rc=0; vercel_run api "$path" "$@" 2>"$e" || rc=$?
    [ "$rc" != 0 ] || break
    { [ "$m" = GET ] && [ "$try" -lt 3 ] && vercel_transient "$rc" "$e"; } || break
    sleep $((try * 2))
  done
  [ "$rc" = 0 ] || echo "vercel: $(vercel_reason "$rc" "$e")" >&2
  rm -f "$e"; return "$rc"
}

# vercel_call <path> [args]: the same for the chosen team.
vercel_call() {
  local u; u="$(with_team "$1")" || return 1
  shift; vercel_api_raw "$u" "$@"
}

vercel_projects() {
  local all="[]" page next="" prev="" url pages=0
  while :; do
    url="/v10/projects?limit=100${next:+&until=$next}"
    page="$(vercel_call "$url")" || die "Could not list Vercel projects"
    # An answer without a project list (a rate-limit body that came with exit 0) is an error,
    # not "no projects".
    echo "$page" | jq -e '.projects | type == "array"' >/dev/null 2>&1 \
      || die "Could not list Vercel projects: the answer has no project list ($(printf '%s' "$page" | head -c 200))"
    all="$(jq -s '.[0] + .[1].projects' <(echo "$all") <(echo "$page"))"
    prev="$next"; next="$(echo "$page" | jq -r '.pagination.next // empty')"
    pages=$((pages + 1))
    # A cursor that does not move, or more than 100 pages (10,000 projects): stop, never loop.
    [ -n "$next" ] && [ "$next" != "$prev" ] && [ "$pages" -lt 100 ] || break
  done
  echo "$all"
}

# Write down where a project deploys from. The first time auto-deploy was turned off (offAt)
# is kept: a later run must not move the line costs and triggers measure from.
remember_repo() {
  local entry="$1" tmp
  tmp="$(mktemp)"
  jq --argjson e "$entry" 'reduce ($e | to_entries[] | select(.value.repo != null)) as $x (.;
      .[$x.key] = ($x.value + (if .[$x.key].offAt then {offAt:.[$x.key].offAt} else {} end)))' "$REPOS" > "$tmp" && mv "$tmp" "$REPOS"
}

vercel_off_one() {
  local p="$1" info
  info="$(vercel_call "/v9/projects/$p")" || die "Vercel project $p not found"
  # The link is the only place the repo is written down. Keep it before removing it.
  remember_repo "$(echo "$info" | jq --arg p "$p" '{($p): ((.link // {}) | (if .type == "gitlab"
      then {type:"gitlab", repo:'"$GITHOST_VERCEL_LINK_JQ"', projectId} else {org, repo, repoId} end)
      + {ref:(.productionBranch // "main"), offAt:(now | floor)})}')"
  [ "$(echo "$info" | jq '.link != null')" = "true" ] || { echo "Vercel: $p was already manual"; return; }
  # Without the repo written down, the project could never be connected again (a Bitbucket link
  # has owner/slug, not org/repo): leave it connected.
  jq -e --arg p "$p" '.[$p].repo != null' "$REPOS" >/dev/null 2>&1 \
    || die "Vercel: the repo of $p ($(echo "$info" | jq -r '.link.type // "unknown"')) could not be written down, so $p stays connected. Say where it deploys from first: deploys vercel map $p <owner/repo> [branch]"
  # vercel_call names the reason on stderr.
  vercel_call "/v9/projects/$p/link" --method DELETE --dangerously-skip-permissions >/dev/null \
    || die "Vercel: could not disconnect $p"
  echo "Vercel: $p no longer deploys on push"
}

# vercel_off <project>|--all: disconnect Git (remembers the repo first).
vercel_off() {
  local target="${1:-}" bad names p
  [ -n "$target" ] || die "Give a project name or --all"
  if [ "$target" = "--all" ]; then
    # One that fails does not stop the rest; they are counted and the exit code says so.
    # The list first, on its own line: a failed read must stop here (set -e), not look like "none left".
    bad=0; names="$(vercel_projects | jq -r '.[] | select(.link) | .name')"
    for p in $names; do ( vercel_off_one "$p" ) || bad=$((bad + 1)); done
    [ "$bad" = 0 ] || die "$bad Vercel projects could not be disconnected (see above); the others are done"
    echo "Done. No Vercel project deploys on push any more."
  else
    vercel_off_one "$target"
  fi
}

# Auto-deploy back on: Git connected again from the remembered repo. Every push builds (and costs) again.
vercel_on_one() {
  local p="$1" r t=github body err e u
  # A GitLab link is connected again in Vercel's dashboard: the body for it is not known here.
  if [ "$(jq -r --arg p "$p" '.[$p].type // ""' "$REPOS")" = gitlab ]; then
    die "Vercel: $p deploys from GitLab ($(jq -r --arg p "$p" '.[$p].repo' "$REPOS")); connect it again in the Vercel dashboard (Settings > Git). Deploys from here keep working without it."
  fi
  r="$(jq -r --arg p "$p" '.[$p] // {} | if .org and .repo then "\(.org)/\(.repo)" else "" end' "$REPOS")"
  [ -n "$r" ] || die "Vercel: the repo of $p is not known, so it cannot be connected again. Say where it deploys from: deploys vercel map $p <owner/repo> [branch]"
  u="$(with_team "/v9/projects/$p/link")" || exit 1
  body="$(mktemp)"; err="$(mktemp)"; jq -n --arg t "$t" --arg r "$r" '{type:$t, repo:$r}' > "$body"
  if ! vercel_run api "$u" --method POST --input "$body" --dangerously-skip-permissions >/dev/null 2>"$err"; then
    e="$(vercel_reason 1 "$err")"; rm -f "$body" "$err"
    die "Vercel: could not connect $p to $r again${e:+: $e}"
  fi
  rm -f "$body" "$err"
  echo "Vercel: $p deploys on push again ($r)"
}

# FEA-110: what `autodeploy-on` would do, without changing anything (reads only). Items are
# "name<TAB>id<TAB>action<TAB>reason" on stdin (action on|skip|already); --json prints
# {provider, dryRun:true, items:[{name, id, action, reason}], on, skipped}, otherwise one line each.
vercel_on_plan() {  # [--json]
  local items; items="$(jq -R -s -c 'split("\n") | map(select(length > 0) | split("\t")
    | {name:.[0], id:.[1], action:.[2], reason:(if (.[3] // "") == "" then null else .[3] end)})')" || return 1
  if [ "${1:-}" = --json ]; then
    jq -nc --argjson i "$items" '{provider:"vercel", dryRun:true, items:$i,
      on:($i | map(select(.action == "on")) | length), skipped:($i | map(select(.action != "on")) | length)}'
  else
    echo "$items" | jq -r '.[] | if .action == "on" then "Vercel: would turn on \(.name) (pushes build again)"
      else "Vercel: \(.name) \(.action)\(if .reason then ": \(.reason)" else "" end)" end'
    echo "Dry run: nothing changed."
  fi
}

vercel_on() {
  local dry="" j="" a args=()
  for a in "$@"; do case "$a" in --dry-run) dry=1 ;; --json) j=--json ;; *) args+=("$a") ;; esac; done
  # `deploys <p> autodeploy-on … --json` takes --json off the line and sets its json=1.
  [ "${json:-0}" != 1 ] || j=--json
  if [ -n "$dry" ]; then vercel_on_dry "${args[0]:-}" $j; return; fi
  set -- "${args[@]+"${args[@]}"}"
  local target="${1:-}" bad=0 skipped=0 names p
  [ -n "$target" ] || die "Give a project name or --all"
  if [ "$target" = "--all" ]; then
    names="$(vercel_projects | jq -r '.[] | select(.link | not) | .name')"
    for p in $names; do
      if ! jq -e --arg n "$p" '.[$n].repo != null' "$REPOS" >/dev/null; then skipped=$((skipped + 1)); echo "Vercel: $p skipped, its repo is not known (deploys vercel map)"; continue; fi
      ( vercel_on_one "$p" ) || bad=$((bad + 1))
    done
    [ "$bad" = 0 ] || die "$bad Vercel projects could not be connected (see above); the others are done"
    echo "Done. Every remembered Vercel project deploys on push again."
  else
    vercel_on_one "$target"
  fi
}
vercel_cli_autodeploy_on() { vercel_on "$@"; }

# The repo vercel_on_one would connect, or nothing.
vercel_on_repo() {
  jq -r --arg p "$1" '.[$p] // {} | if .type == "gitlab" then (.repo // "" | sub("^[^/]+/"; ""))
    elif .org and .repo then "\(.org)/\(.repo)" else "" end' "$REPOS"
}
vercel_on_dry() {  # <project>|--all [--json]
  local target="$1" list p
  [ -n "$target" ] || die "Give a project name or --all"
  if [ "$target" = --all ]; then
    list="$(vercel_projects | jq -c '[.[] | {name, link:(.link != null)}]')" || exit 1
  else
    list="$(vercel_call "/v9/projects/$target" | jq -c '[{name, link:(.link != null)}]')" || die "Vercel project $target not found"
  fi
  while IFS=$'\t' read -r p linked; do
    [ -n "$p" ] || continue
    if [ "$linked" = true ]; then [ "$target" = --all ] || printf '%s\t%s\talready\tGit is connected\n' "$p" "$p"
    elif [ -n "$(vercel_on_repo "$p")" ]; then printf '%s\t%s\ton\tconnect %s\n' "$p" "$p" "$(vercel_on_repo "$p")"
    else printf '%s\t%s\tskip\tthe repo is not known (deploys vercel map %s <owner/repo>)\n' "$p" "$p" "$p"; fi
  done < <(echo "$list" | jq -r '.[] | "\(.name)\t\(.link)"') | vercel_on_plan "${2:-}"
}

# Raw Vercel states to the shared phase (docs/PROVIDERS.md). Unknown or none: null.
VERCEL_PHASE='def vphase: (. // "" | ascii_upcase) as $s
  | if $s == "QUEUED" or $s == "INITIALIZING" then "queued" elif $s == "BUILDING" then "building"
    elif $s == "READY" then "ready" elif $s == "ERROR" then "failed" elif $s == "CANCELED" then "canceled" else null end;'
# The commit of a deployment's .meta, whichever git host it came from.
VERCEL_META='def vsha: (.githubCommitSha // .gitlabCommitSha // .bitbucketCommitSha // null);
  def vmsg: (.githubCommitMessage // .gitlabCommitMessage // .bitbucketCommitMessage // null);'

# Start a build. Positional, for the commands below: <project> <preview: ""|1> <sha>.
# vercel_sha_on_ref <project> <repos json> <sha>: refuse a commit GitHub says is not in the
# remembered branch's history (compare ref...sha "ahead" or "diverged": on another branch or a
# fork). Not checked (a warning, and on): no gh, GitLab, or GitHub could not be asked.
# DEPLOYS_VERCEL_ANY_SHA=1 allows it on purpose.
vercel_sha_on_ref() {
  local repo ref st e
  repo="$(jq -r --arg p "$1" '.[$p] | if .type == "gitlab" or (.org | not) then "" else "\(.org)/\(.repo)" end' <<< "$2")"
  ref="$(jq -r --arg p "$1" '.[$p].ref // "main"' <<< "$2")"
  [ -n "$repo" ] && [ "${DEPLOYS_VERCEL_ANY_SHA:-}" != 1 ] || return 0
  command -v gh >/dev/null 2>&1 || { echo "Vercel: could not check that ${3:0:7} is on $repo $ref (no gh); deploying it" >&2; return 0; }
  e="$(mktemp)"
  if ! st="$(gh api "repos/$repo/compare/$ref...$3" --jq .status 2>"$e")" || [ -z "$st" ]; then
    # GitHub answered that it does not know the commit there (404/422): refused, not waved through.
    if grep -qE 'HTTP (404|422)' "$e"; then rm -f "$e"; die "Vercel: GitHub does not know ${3:0:7} in $repo $ref: a fork's commit or a typo. Deploy without --sha, or set DEPLOYS_VERCEL_ANY_SHA=1 if this is meant"; fi
    rm -f "$e"; echo "Vercel: could not check that ${3:0:7} is on $repo $ref (GitHub not reachable); deploying it" >&2; return 0
  fi
  rm -f "$e"
  case "$st" in
    identical|behind) return 0 ;;
    *) die "Vercel: ${3:0:7} is not on $repo $ref ($st): a fork or another branch would go live as $1. Deploy without --sha, or set DEPLOYS_VERCEL_ANY_SHA=1 if this is meant" ;;
  esac
}

vercel_start() {
  local target="$1" preview="${2:-}" sha="${3:-}" body out lock
  local repos; repos="$(repos_json)"
  # Only a repo written down is built from, never one read from the live link alone: stop
  # before anything is asked of Vercel.
  jq -e --arg p "$target" '.[$p].repo != null' <<< "$repos" >/dev/null \
    || die "$target has no remembered repo. Turn its auto-deploy off with this tool, add it to $REPOS, or map it: deploys vercel map $target <owner/repo> [branch]"
  # Production waits for its approvals (two-person rule); the commit checked is the one deployed.
  if [ -z "$preview" ] && team_on; then
    sha="$(team_gate vercel "$target" "$(jq -r --arg p "$target" '.[$p] | if .type == "gitlab" or (.org | not) then "" else "\(.org)/\(.repo)" end' <<< "$repos")" \
      "$(jq -r --arg p "$target" '.[$p].ref // "main"' <<< "$repos")" "$sha")" || exit 1
  fi
  # FEA-042: a production build of a given commit must be on the remembered branch, not on a
  # fork or another branch (its code would go live under the project's name).
  [ -n "$preview" ] || [ -z "$sha" ] || vercel_sha_on_ref "$target" "$repos" "$sha" || exit 1
  lock="$(start_lock "vercel-$target")" || exit 1
  # Removed by hand on every way out: a `trap … RETURN` would stay set and fire on later returns.
  body="$(mktemp)"
  jq --arg p "$target" --arg prev "$preview" --arg sha "$sha" '.[$p] as $r | {name:$p, project:$p}
    + (if $prev == "" then {target:"production"} else {} end)
    + {gitSource:(if $r.type == "gitlab" then {type:"gitlab", ref:$r.ref, projectId:$r.projectId}
                  else {type:"github", ref:$r.ref} + (if $r.repoId then {repoId:$r.repoId} else {org:$r.org, repo:$r.repo} end) end
                  + (if $sha != "" then {sha:$sha} else {} end))}' <<< "$repos" > "$body"
  local errf u rc=0; u="$(with_team /v13/deployments)" || { rm -f "$lock" "$body"; exit 1; }
  errf="$(mktemp)"
  # Never repeated: a POST without an answer may have started a build already.
  out="$(vercel_run api "$u" --method POST --input "$body" 2>"$errf")" || rc=$?
  if [ "$rc" != 0 ]; then
    local e; e="$(tail -c 400 "$errf")"; rm -f "$errf" "$lock" "$body"
    [ "$rc" != 142 ] || die "Vercel: no answer within ${VERCEL_TIMEOUT} s. A build may have started anyway: look at the list before starting another"
    die "Vercel: $e $(echo "$out" | jq -r '.error.message // empty' 2>/dev/null)"
  fi
  rm -f "$errf" "$body"
  echo "$out" | jq -e '.id' >/dev/null 2>&1 || { rm -f "$lock"; die "Vercel: $(echo "$out" | head -c 400)"; }
  echo "$out" | jq "$VERCEL_PHASE"'{id, url:("https://" + .url), state:(.readyState // .status), phase:((.readyState // .status) | vphase)}'
}

# vercel_deploy_json <project> [--preview] [--sha <commit>]
vercel_deploy_json() {
  local p="${1:?project}" pv="" sha=""; shift || true
  # An unknown flag (--sah) is refused: ignored, the newest commit would go live instead.
  while [ $# -gt 0 ]; do case "$1" in --preview) pv=1;; --sha) sha="${2:?commit}"; shift;; "") ;; *) die "Unknown option $1. Usage: deploy-json <project> [--preview] [--sha <commit>]";; esac; shift; done
  vercel_start "$p" "$pv" "$sha"
}

# Every project, the newest production attempt per project from one call: a build started in the
# dashboard or the terminal is BUILDING here while targets.production still shows the finished one.
vercel_json() {
  local raw recent="" partial=false projects all next page=1 missing
  projects="$(vercel_projects)" || exit 1
  # The newest attempts are extra: when they cannot be read (a network blip, an odd answer), the
  # list still comes, marked partial, and a build under way may not show. Never an empty
  # --argjson: a `:-` default of {} keeps its backslash under macOS bash 3.2 ({\}).
  if raw="$(vercel_call "/v6/deployments?limit=100&target=production")" \
    && all="$(printf '%s' "$raw" | jq -c '.deployments | if type == "array" then . else error("no list") end' 2>/dev/null)"; then
    # 100 attempts of all projects together: a busy project can push the others out, and theirs
    # would then read as "ready" while a build runs. Further pages (`until`), at most five in
    # all, while a project that has deployed to production is still missing.
    while [ "$page" -lt 5 ]; do
      next="$(printf '%s' "$raw" | jq -r '.pagination.next // empty' 2>/dev/null)"
      [ -n "$next" ] && [ "$(printf '%s' "$all" | jq 'length')" -ge $((page * 100)) ] || break
      missing="$(jq -n --argjson p "$projects" --argjson d "$all" '[$p[] | select(.targets.production) | .name] - [$d[].name] | length')"
      [ "$missing" -gt 0 ] || break
      # Into a variable of its own: a page that is not a list must not wipe the pages before it.
      local more
      if ! raw="$(vercel_call "/v6/deployments?limit=100&target=production&until=$next")" \
        || ! more="$(jq -c -s '.[0] + (.[1].deployments | if type == "array" then . else error("no list") end)' <(printf '%s' "$all") <(printf '%s' "$raw") 2>/dev/null)" \
        || [ -z "$more" ]; then
        partial=true; break
      fi
      all="$more"
      page=$((page + 1))
    done
    recent="$(printf '%s' "$all" | jq "$VERCEL_META"'group_by(.name)
      | map({key:.[0].name, value:(max_by(.created) | {state, created, id:.uid, sha:(.meta | vsha)})}) | from_entries' 2>/dev/null)" || recent=""
  fi
  if [ -z "$recent" ] || ! printf '%s' "$recent" | jq -e 'type == "object"' >/dev/null 2>&1; then recent='{}'; partial=true; fi
  [ "$partial" = false ] || echo "vercel: the newest builds could not be read; the list shows the live deploys only" >&2
  printf '%s' "$projects" | jq --slurpfile r <(repos_json) --argjson recent "$recent" --argjson partial "$partial" "$VERCEL_PHASE$VERCEL_META"'[.[] |
    ((.link // null) | if . then {repo:'"$GITHOST_VERCEL_LINK_JQ"', ref:(.productionBranch // "main"),
      } else null end) as $live |
    ($r[0][.name] // null) as $known |
    (((.targets.production.alias // []) | map(select(endswith(".vercel.app")|not)) | .[0]) // null) as $domain |
    {name, id:.name, auto:(.link != null), paused:(.paused // false),
     repo:(if $known.repo then (if $known.type == "gitlab" then $known.repo else "\($known.org)/\($known.repo)" end) else $live.repo end),
     ref:($known.ref // (.link.productionBranch // null)),
     # Only a repo written down deploys. A project connected to Git without one is shown, not
     # built from its live link (repoUnknown): write it down with `deploys vercel map` first.
     deployable:($known.repo != null), repoUnknown:($known.repo == null and $live != null),
     domain:$domain,
     url:(($domain // .targets.production.alias[0]?) // null | if . then "https://\(.)" else null end),
     dashboardUrl:null,
     lastAt:((.targets.production.createdAt // 0) / 1000 | floor),
     lastState:(.targets.production.readyState // null),
     lastSha:(.targets.production.meta // {} | vsha),
     lastMsg:(.targets.production.meta // {} | vmsg | if . then split("\n")[0] else null end),
     latestState:($recent[.name].state // null),
     latestId:($recent[.name].id // null), latestSha:($recent[.name].sha // null),
     fetchError:null}
    + (if $partial then {partial:true} else {} end)
    # A build under way in either the newest attempt or the production target counts.
    | ([.latestState, .lastState] | map(vphase)) as $ph
    | . + {phase:(if ($ph | index("building")) then "building" elif ($ph | index("queued")) then "queued"
                  else ((.latestState // .lastState) | vphase) end)}] | sort_by(.name | ascii_downcase)'
}

# Exit 1: no such project. Exit 2: Vercel could not be asked (the reason on stderr), which is not
# "not found".
vercel_has() {
  local e rc=0; e="$(mktemp)"
  vercel_call "/v9/projects/$1" >/dev/null 2>"$e" || rc=$?
  if [ "$rc" = 0 ]; then rm -f "$e"; echo "$1"; return 0; fi
  if grep -qiE 'not found|\(404\)' "$e"; then rm -f "$e"; return 1; fi
  cat "$e" >&2; rm -f "$e"; return 2
}

# deployId<TAB>phase<TAB>raw state of one deployment.
vercel_status() {
  vercel_call "/v13/deployments/${2:?deployment id}" \
    | jq -r "$VERCEL_PHASE"'"\(.id // .uid)\t\((.readyState // .status) | vphase // "")\t\(.readyState // .status // "?")"'
}

# The newest deployment of a project: production, or any target with --preview. "none" if there is none.
vercel_latest() {
  local tgt="&target=production"; [ "${2:-}" = --preview ] && tgt=""
  vercel_call "/v6/deployments?app=$1&limit=1$tgt" \
    | jq -r "$VERCEL_PHASE"'(.deployments[0] // {uid:"none"}) | "\(.uid)\t\(.state | vphase // "")\t\(.state // "?")"'
}

vercel_cancel() {
  vercel_call "/v12/deployments/${2:?deployment id}/cancel" --method PATCH >/dev/null || die "Vercel: could not cancel ${2}"
  echo '{"state":"CANCELED"}'
}

# Production back to the previous ready production deployment.
vercel_rollback() {
  local p="${1:?project}" cur prev pid
  # "Before" means before the deployment that is live now, which after an earlier rollback or a
  # promotion is not always the newest one.
  cur="$(vercel_call "/v9/projects/$p" | jq -r '.targets.production.id // empty')"
  prev="$(vercel_call "/v6/deployments?projectId=$p&target=production&state=READY&limit=20" \
    | jq -r --arg cur "$cur" "$VERCEL_META"'.deployments as $d | (($d | map(.uid) | index($cur)) // 0) as $i
        | ($d[$i].meta // {} | vsha) as $sha
        # An older deploy of the same commit (a redeploy) would change nothing: skip to a different one.
        | ($d | to_entries | map(select(.key > $i) | .value)
           | map(select($sha == null or ((.meta // {} | vsha) // "") != $sha)) | .[0].uid // empty)')"
  [ -n "$prev" ] || die "No earlier production deployment of $p to roll back to"
  # The project's id, not its name: Vercel answers 404 to a name on these endpoints.
  pid="$(vercel_call "/v9/projects/$p" | jq -r '.id // empty')"
  vercel_call "/v1/projects/${pid:-$p}/rollback/$prev" --method POST >/dev/null || die "Vercel: rollback of $p failed"
  echo "{\"id\":\"$prev\",\"state\":\"READY\"}"
}

# vercel_logs <project> <lines> [deployId]: the end of a build log (newest production by default).
vercel_logs() {
  local p="$1" n="${2:-80}" d="${3:-}"
  # jq's .[-0:] is the whole array: 0 lines must not print the whole log.
  case "$n" in ''|*[!0-9]*|0) die "lines must be a number, 1 or more";; esac
  [ -n "$d" ] || d="$(vercel_call "/v6/deployments?app=$p&limit=1&target=production" | jq -r '.deployments[0].uid // empty')"
  [ -n "$d" ] || die "No deployment of $p"
  vercel_call "/v3/deployments/$d/events?builds=1&direction=backward&limit=2000" \
    | jq -r --argjson n "$n" 'sort_by(.created) | map(.payload.text // .text // "" | select(test("\\S"))) | .[-$n:][]'
}

# The site, or with --dashboard the project's page at Vercel.
vercel_url() {
  local p="$1" slug
  if [ "${2:-}" = "--dashboard" ]; then
    # A team's page is under its slug, a personal account's under the user name.
    if [ -n "$(vercel_team)" ]; then slug="$(vercel_call "/v2/teams/$(vercel_team)" | jq -r '.slug // empty' 2>/dev/null || true)"
    else slug="$(vercel_call "/v2/user" | jq -r '.user.username // empty' 2>/dev/null || true)"; fi
    [ -n "$slug" ] || die "Could not read the Vercel team or user name for the dashboard address"
    echo "https://vercel.com/$slug/$p"
  else
    vercel_call "/v9/projects/$p" | jq -r '((.targets.production.alias // []) | map(select(endswith(".vercel.app")|not)) | .[0]) // (.targets.production.alias[0] // empty) | "https://\(.)"'
  fi
}

vercel_set_key() { die "Vercel uses the vercel CLI login, not a stored key. Run: vercel login (or set VERCEL_TOKEN)"; }

# Written with printf, not jq: doctor has to work when jq is missing.
vercel_doctor() {
  local cli=false vapi=false vlogin=false
  command -v vercel >/dev/null 2>&1 && cli=true
  vercel api --help >/dev/null 2>&1 && vapi=true
  vercel whoami >/dev/null 2>&1 && vlogin=true
  printf '{"vercelCli":%s,"vercelApi":%s,"vercelLoggedIn":%s}\n' "$cli" "$vapi" "$vlogin"
}

# Lines for `deploys where`.
vercel_where() {
  local vu; vu="$(vercel whoami 2>/dev/null | tail -n 1 || true)"
  printf '%-13s%s\n' "vercel team" "$(cat "$CONFIG_DIR/vercel-team" 2>/dev/null || echo "not chosen yet")" "vercel user" "${vu:-not logged in}"
}

# The last n deploys: when, target, state, commit, source, build time.
vercel_history() {
  vercel_call "/v6/deployments?app=$1&limit=$2" | jq -r "$VERCEL_META"'.deployments[]
    | [(.created/1000 | strftime("%Y-%m-%d %H:%M")), (.target // "preview"), .state,
       (((.meta // {} | vsha) // "")[0:7]), (.source // ""),
       (if .ready and .buildingAt then "\(((.ready - .buildingAt)/1000) | floor)s" else "" end)]
    # "-" for an empty field: BSD column merges empty fields and would shift the row.
    | map(if . == "" or . == null then "-" else . end) | @tsv' \
    | (printf 'WHEN (UTC)\tTARGET\tSTATE\tCOMMIT\tSOURCE\tBUILD\n'; cat) | table
}

# Usage lines for the verbs that take more than a project.
vercel_usage() {  # <argc> <verb>
  case "$2" in
    map) usage_if_short "$1" 4 "vercel map <project> <owner/repo> [branch]" ;;
    cancel|status) usage_if_short "$1" 3 "vercel $2 <deployment id>" ;;
  esac
}

# ---------- Commands people type (deploys vercel <verb>), kept as they always were ----------

vercel_cli_list() {
  vercel_projects | jq -r '.[] | [.name, (if .link then "AUTO (\(.link.org // "")/\(.link.repo // ""))" else "manual" end)] | @tsv' \
    | table
}

# vercel deploy <project> [--preview] [--sha <commit>] [--wait [--timeout <seconds>]]
vercel_cli_deploy() {
  local target="$1" pv="" sha="" wait_="" tmo="" out did; shift
  while [ $# -gt 0 ]; do
    case "$1" in
      --preview) pv=1;; --wait) wait_=1;;
      --sha) [ -n "${2:-}" ] || die "Usage: deploys vercel deploy <project> --sha <commit>"; sha="$2"; shift;;
      --timeout) case "${2:-}" in ''|*[!0-9]*) die "Usage: deploys vercel deploy <project> --wait --timeout <seconds>";; esac; tmo="$2"; shift;;
      *) die "Unknown option $1. Usage: deploys vercel deploy <project> [--preview] [--sha <commit>] [--wait [--timeout <seconds>]]";;
    esac; shift
  done
  out="$(vercel_start "$target" "$pv" "$sha")"
  echo "$out" | jq -r '"Vercel: deploy started -> \(.url) (\(.state))"'
  # Follow exactly this deploy, not "the newest one", until it is live or failed.
  # `watch` follows it, with its give-up after five failed questions in a row (exit 3) and, with
  # --timeout, after that many seconds (exit 4).
  if [ -n "$wait_" ]; then
    did="$(echo "$out" | jq -r .id)"
    exec "$0" watch "vercel:$target" "$did" ${pv:+--preview} ${tmo:+--timeout "${tmo}s"}
  fi
}

vercel_cli_status() {
  vercel_call "/v13/deployments/${1:?deployment id}" \
    | jq '{id, url:("https://" + .url), state:(.readyState // .status), error:(.errorMessage // null)}'
}

vercel_cli_cancel() { vercel_cancel "" "${1:?deployment id}"; }

vercel_cli_team() {
  if [ -n "${1:-}" ]; then valid_team "$1" || die "A team id has letters, digits, _ and - only"; printf '%s' "$1" > "$CONFIG_DIR/vercel-team"; echo "Vercel team set to $1"; else vercel_team; echo; fi
}

# Say by hand where a project deploys from, for one disconnected before this tool knew it.
vercel_cli_map() {
  local p="${1:?project}" r="${2:?owner/repo}" ref="${3:-main}" rid="" tmp
  case "$r" in */*) ;; *) die "Give the repo as owner/name";; esac
  if [ "$(githost_of "$r")" = gitlab ]; then
    # GitLab: host/group/name (or its URL). Vercel deploys it by project id.
    local glh glp pid
    read -r glh glp < <(githost_split "$r"); r="$glh/$glp"
    pid="$(gitlab_project_id "$r" || true)"; [ -n "$pid" ] || die "GitLab project $r not found (is glab logged in, or GITLAB_TOKEN set?)"
    tmp="$(mktemp)"
    jq --arg p "$p" --arg r "$r" --arg ref "$ref" --argjson pid "$pid" \
      '.[$p] = ({type:"gitlab", repo:$r, projectId:$pid, ref:$ref} + (if .[$p].offAt then {offAt:.[$p].offAt} else {} end))' "$REPOS" > "$tmp" && mv "$tmp" "$REPOS"
    echo "Vercel: $p deploys from $r ($ref)"; return 0
  fi
  command -v gh >/dev/null 2>&1 && rid="$(gh api "repos/$r" --jq .id 2>/dev/null || true)"
  tmp="$(mktemp)"
  # The whole entry is replaced: an old repoId would win over the new repo name.
  jq --arg p "$p" --arg o "${r%%/*}" --arg n "${r#*/}" --arg ref "$ref" --arg rid "$rid" \
    '.[$p] = ({org:$o, repo:$n, ref:$ref} + (if .[$p].offAt then {offAt:.[$p].offAt} else {} end)
              + (if $rid != "" then {repoId:($rid|tonumber)} else {} end))' "$REPOS" > "$tmp" && mv "$tmp" "$REPOS"
  echo "Vercel: $p deploys from $r ($ref)"
}
