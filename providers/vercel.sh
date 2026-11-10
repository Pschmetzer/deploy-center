# shellcheck shell=bash
# shellcheck disable=SC2154  # CONFIG_DIR, REPOS, RED, PLAIN and the helpers come from `deploys`.
# Vercel, through the `vercel` CLI login on this Mac (`vercel login`). Sourced by `deploys`.
# The contract every provider fulfils is in docs/PROVIDERS.md. A Vercel project's id here is its
# name: the API takes either, and every command people type uses the name.

vercel_meta() {
  printf '%s\n' '{"id":"vercel","label":"Vercel","noun":"project","defaultOn":true,"keyEnv":["VERCEL_TOKEN"],"keychain":null,"auth":"vercel CLI login","caps":{"off":true,"sha":true,"cancel":true,"rollback":true,"logs":true,"preview":true}}'
}

# Set up here: the CLI is installed, or projects are remembered. Under launchd's PATH the vercel
# CLI is often not found, and that must be an error, not a silent "no Vercel projects".
vercel_ready() {
  type -P vercel >/dev/null 2>&1 || [ "$(jq 'length' "$REPOS" 2>/dev/null || echo 0)" != 0 ]
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
  local teams n e w
  e="$(mktemp)"
  # Only a login problem is "not logged in": a network error or a 5xx says what it was.
  if ! teams="$(vercel api /v2/teams 2>"$e")"; then
    w="$(grep -v '^[[:space:]]*$' "$e" | tail -n 1 | cut -c1-200)"; rm -f "$e"
    case "$w" in ""|*[Ll]ogin*|*"logged in"*|*[Cc]redentials*|*[Tt]oken*|*401*|*403*) die "The vercel CLI is not logged in. Run: vercel login" ;; esac
    die "Could not read the Vercel teams: $w"
  fi
  rm -f "$e"
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

# Query string for the team, empty for a personal account.
team_q() { local t; t="$(vercel_team)"; [ -n "$t" ] && echo "teamId=$t" || echo ""; }
with_team() { local q; q="$(team_q)"; case "$1" in *\?*) echo "$1${q:+&$q}";; *) echo "$1${q:+?$q}";; esac; }

# On failure the last line vercel printed goes to stderr: "not found" and "not logged in" differ.
# A read that met a rate limit, a server error or a network hiccup is asked again (three times
# in all), as the other providers do; a write never is: a timed-out POST may have started a build.
vercel_call() {
  local e rc try path a get=1 out; e="$(mktemp)"
  path="$(with_team "$1")"
  for a in "${@:2}"; do case "$a" in --method|-X) get="" ;; esac; done
  for try in 1 2 3; do
    rc=0; out="$(vercel api "$path" "${@:2}" 2>"$e")" || rc=$?
    [ "$rc" != 0 ] && [ -n "$get" ] && [ "$try" -lt 3 ] \
      && grep -qiE '(^|[^0-9])(429|50[0-9])([^0-9]|$)|rate.?limit|too many requests|ETIMEDOUT|ECONNRESET|ENOTFOUND|socket hang up|network' "$e" \
      && { sleep $((try * 2)); continue; }
    break
  done
  [ "$rc" = 0 ] || grep -v '^[[:space:]]*$' "$e" | tail -n 1 | sed 's/^/vercel: /' >&2
  rm -f "$e"
  [ -z "$out" ] || printf '%s\n' "$out"
  return "$rc"
}

vercel_projects() {
  local all="[]" page next="" url
  while :; do
    url="/v10/projects?limit=100${next:+&until=$next}"
    page="$(vercel_call "$url")" || die "Could not list Vercel projects"
    all="$(jq -s '.[0] + .[1].projects' <(echo "$all") <(echo "$page"))"
    next="$(echo "$page" | jq -r '.pagination.next // empty')"
    [ -n "$next" ] || break
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
  # A link deploys cannot write down (Bitbucket: no org and repo) must stay: removed, the project
  # could neither be deployed from here nor connected again.
  jq -e --arg p "$p" '.[$p].repo != null' "$REPOS" >/dev/null 2>&1 \
    || die "Vercel: the repo of $p ($(echo "$info" | jq -r '.link.type // "unknown"')) could not be written down, so $p stays connected. Say where it deploys from first: deploys vercel map $p <owner/repo> [branch]"
  vercel api "$(with_team "/v9/projects/$p/link")" --method DELETE --dangerously-skip-permissions >/dev/null 2>&1 \
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
  local p="$1" r body err e
  # A GitLab link is connected again in Vercel's dashboard: the body for it is not known here.
  if [ "$(jq -r --arg p "$p" '.[$p].type // ""' "$REPOS")" = gitlab ]; then
    die "Vercel: $p deploys from GitLab ($(jq -r --arg p "$p" '.[$p].repo' "$REPOS")); connect it again in the Vercel dashboard (Settings > Git). Deploys from here keep working without it."
  fi
  r="$(jq -r --arg p "$p" '.[$p] // {} | if .org and .repo then "\(.org)/\(.repo)" else "" end' "$REPOS")"
  [ -n "$r" ] || die "Vercel: the repo of $p is not known, so it cannot be connected again. Say where it deploys from: deploys vercel map $p <owner/repo> [branch]"
  body="$(mktemp)"; err="$(mktemp)"; jq -n --arg r "$r" '{type:"github", repo:$r}' > "$body"
  if ! vercel api "$(with_team "/v9/projects/$p/link")" --method POST --input "$body" --dangerously-skip-permissions >/dev/null 2>"$err"; then
    e="$(grep -v '^[[:space:]]*$' "$err" | tail -n 1 | cut -c1-300)"; rm -f "$body" "$err"
    die "Vercel: could not connect $p to $r again${e:+: $e}"
  fi
  rm -f "$body" "$err"
  echo "Vercel: $p deploys on push again ($r)"
}

vercel_on() {
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

# Raw Vercel states to the shared phase (docs/PROVIDERS.md). Unknown or none: null.
VERCEL_PHASE='def vphase: (. // "" | ascii_upcase) as $s
  | if $s == "QUEUED" or $s == "INITIALIZING" then "queued" elif $s == "BUILDING" then "building"
    elif $s == "READY" then "ready" elif $s == "ERROR" then "failed" elif $s == "CANCELED" then "canceled" else null end;'

# Start a build. Positional, for the commands below: <project> <preview: ""|1> <sha>.
vercel_start() {
  local target="$1" preview="${2:-}" sha="${3:-}" body out lock
  local repos; repos="$(repos_json)"
  jq -e --arg p "$target" 'has($p)' <<< "$repos" >/dev/null || die "$target has no remembered repo. Turn its auto-deploy off with this tool, add it to $REPOS, or map it in the repo's deploy-center.json"
  # Production waits for its approvals (two-person rule); the commit checked is the one deployed.
  if [ -z "$preview" ] && team_on; then
    sha="$(team_gate vercel "$target" "$(jq -r --arg p "$target" '.[$p] | if .type == "gitlab" or (.org | not) then "" else "\(.org)/\(.repo)" end' <<< "$repos")" \
      "$(jq -r --arg p "$target" '.[$p].ref // "main"' <<< "$repos")" "$sha")" || exit 1
  fi
  lock="$(start_lock "vercel-$target")" || exit 1
  # Removed by hand on every way out: a `trap … RETURN` would stay set and fire on later returns.
  body="$(mktemp)"
  jq --arg p "$target" --arg prev "$preview" --arg sha "$sha" '.[$p] as $r | {name:$p, project:$p}
    + (if $prev == "" then {target:"production"} else {} end)
    + {gitSource:(if $r.type == "gitlab" then {type:"gitlab", ref:$r.ref, projectId:$r.projectId}
                  else {type:"github", ref:$r.ref} + (if $r.repoId then {repoId:$r.repoId} else {org:$r.org, repo:$r.repo} end) end
                  + (if $sha != "" then {sha:$sha} else {} end))}' <<< "$repos" > "$body"
  local errf; errf="$(mktemp)"
  out="$(vercel api "$(with_team /v13/deployments)" --method POST --input "$body" 2>"$errf")" \
    || { local e; e="$(tail -c 400 "$errf")"; rm -f "$errf" "$lock" "$body"; die "Vercel: $e $(echo "$out" | jq -r '.error.message // empty' 2>/dev/null)"; }
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
  local recent projects need deps='[]' page next=""
  projects="$(vercel_projects)" || return 1
  # The newest production attempt of each project. One page holds the 100 newest of the whole
  # account: while a project that has a production deploy is not on them yet, older pages follow
  # (three at most). A failed read leaves latestState empty, as before.
  need="$(jq -c '[.[] | select(.targets.production != null) | .name]' <<< "$projects")"
  for _ in 1 2 3; do
    page="$(vercel_call "/v6/deployments?limit=100&target=production${next:+&until=$next}" 2>/dev/null)" || break
    deps="$(jq -c --argjson p "$page" '. + ($p.deployments // [])' <<< "$deps" 2>/dev/null)" || break
    next="$(jq -r '.pagination.next // empty' <<< "$page" 2>/dev/null)"
    [ -n "$next" ] || break
    [ "$(jq --argjson n "$need" '[.[].name] as $have | [$n[] | select(. as $x | $have | index($x) | not)] | length' <<< "$deps")" -gt 0 ] || break
  done
  recent="$(jq 'group_by(.name) | map({key:.[0].name, value:(max_by(.created) | {state, created, id:.uid, sha:(.meta | (.githubCommitSha // .gitlabCommitSha // .bitbucketCommitSha) // null)})}) | from_entries' <<< "$deps" 2>/dev/null)"
  echo "$projects" | jq --slurpfile r <(repos_json) --argjson recent "${recent:-{\}}" "$VERCEL_PHASE"'[.[] |
    ((.link // null) | if . then {repo:'"$GITHOST_VERCEL_LINK_JQ"', ref:"main"} else null end) as $live |
    ($r[0][.name] // null) as $known |
    (((.targets.production.alias // []) | map(select(endswith(".vercel.app")|not)) | .[0]) // null) as $domain |
    {name, id:.name, auto:(.link != null), paused:false,
     repo:(if $known.repo then (if $known.type == "gitlab" then $known.repo else "\($known.org)/\($known.repo)" end) else $live.repo end),
     ref:($known.ref // (.link.productionBranch // null)),
     deployable:($known.repo != null),
     domain:$domain,
     url:(($domain // .targets.production.alias[0]?) // null | if . then "https://\(.)" else null end),
     dashboardUrl:null,
     lastAt:((.targets.production.createdAt // 0) / 1000 | floor),
     lastState:(.targets.production.readyState // null),
     lastSha:(.targets.production.meta | (.githubCommitSha // .gitlabCommitSha // .bitbucketCommitSha) // null),
     lastMsg:(.targets.production.meta | (.githubCommitMessage // .gitlabCommitMessage // .bitbucketCommitMessage) // null | if . then split("\n")[0] else null end),
     latestState:($recent[.name].state // null),
     latestId:($recent[.name].id // null), latestSha:($recent[.name].sha // null),
     fetchError:null}
    # A build under way in either the newest attempt or the production target counts.
    | ([.latestState, .lastState] | map(vphase)) as $ph
    | . + {phase:(if ($ph | index("building")) then "building" elif ($ph | index("queued")) then "queued"
                  else ((.latestState // .lastState) | vphase) end)}] | sort_by(.name | ascii_downcase)'
}

vercel_has() { vercel_call "/v9/projects/$1" >/dev/null 2>&1 && echo "$1"; }

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
  vercel api "$(with_team "/v12/deployments/${2:?deployment id}/cancel")" --method PATCH >/dev/null 2>&1 || die "Vercel: could not cancel ${2}"
  echo '{"state":"CANCELED"}'
}

# Production back to the previous ready production deployment.
vercel_rollback() {
  local p="${1:?project}" cur prev pid proj
  # "Before" means before the deployment that is live now, which after an earlier rollback or a
  # promotion is not always the newest one. One read of the project gives that and its id.
  proj="$(vercel_call "/v9/projects/$p")" || die "Could not read the Vercel project $p"
  cur="$(echo "$proj" | jq -r '.targets.production.id // empty' 2>/dev/null)"
  prev="$(vercel_call "/v6/deployments?projectId=$p&target=production&state=READY&limit=20" \
    | jq -r --arg cur "$cur" '.deployments as $d | (($d | map(.uid) | index($cur)) // 0) as $i
        | ($d[$i].meta | (.githubCommitSha // .gitlabCommitSha // .bitbucketCommitSha) // null) as $sha
        # An older deploy of the same commit (a redeploy) would change nothing: skip to a different one.
        | ($d | to_entries | map(select(.key > $i) | .value)
           | map(select($sha == null or (.meta | (.githubCommitSha // .gitlabCommitSha // .bitbucketCommitSha) // "") != $sha)) | .[0].uid // empty)')"
  [ -n "$prev" ] || die "No earlier production deployment of $p to roll back to"
  # The project's id, not its name: Vercel answers 404 to a name on these endpoints.
  pid="$(echo "$proj" | jq -r '.id // empty' 2>/dev/null)"
  vercel api "$(with_team "/v1/projects/${pid:-$p}/rollback/$prev")" --method POST >/dev/null 2>&1 || die "Vercel: rollback of $p failed"
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
  # Each vercel run is a Node start of a second or so: without the CLI, none.
  if type -P vercel >/dev/null 2>&1; then
    cli=true
    vercel api --help >/dev/null 2>&1 && vapi=true
    vercel whoami >/dev/null 2>&1 && vlogin=true
  fi
  printf '{"vercelCli":%s,"vercelApi":%s,"vercelLoggedIn":%s}\n' "$cli" "$vapi" "$vlogin"
}

# Lines for `deploys where`.
vercel_where() {
  local vu; vu="$(vercel whoami 2>/dev/null | tail -n 1 || true)"
  printf '%-13s%s\n' "vercel team" "$(cat "$CONFIG_DIR/vercel-team" 2>/dev/null || echo "not chosen yet")" "vercel user" "${vu:-not logged in}"
}

# The last n deploys: when, target, state, commit, source, build time.
vercel_history() {
  vercel_call "/v6/deployments?app=$1&limit=$2" | jq -r '.deployments[]
    | [(.created/1000 | strftime("%Y-%m-%d %H:%M")), (.target // "preview"), .state,
       ((.meta | (.githubCommitSha // .gitlabCommitSha // .bitbucketCommitSha) // "")[0:7]), (.source // ""),
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

# vercel deploy <project> [--preview] [--sha <commit>] [--wait]
vercel_cli_deploy() {
  local target="$1" pv="" sha="" wait_="" out did; shift
  while [ $# -gt 0 ]; do
    case "$1" in
      --preview) pv=1;; --wait) wait_=1;;
      --sha) [ -n "${2:-}" ] || die "Usage: deploys vercel deploy <project> --sha <commit>"; sha="$2"; shift;;
      *) die "Unknown option $1. Usage: deploys vercel deploy <project> [--preview] [--sha <commit>] [--wait]";;
    esac; shift
  done
  out="$(vercel_start "$target" "$pv" "$sha")"
  echo "$out" | jq -r '"Vercel: deploy started -> \(.url) (\(.state))"'
  # Follow exactly this deploy, not "the newest one", until it is live or failed.
  # `watch` follows it, with its give-up after five failed questions in a row (exit 3).
  if [ -n "$wait_" ]; then
    did="$(echo "$out" | jq -r .id)"
    exec "$0" watch "vercel:$target" "$did" ${pv:+--preview}
  fi
}

vercel_cli_status() {
  vercel_call "/v13/deployments/${1:?deployment id}" \
    | jq '{id, url:("https://" + .url), state:(.readyState // .status), error:(.errorMessage // null)}'
}

vercel_cli_cancel() { vercel_cancel "" "${1:?deployment id}"; }

# vercel team [<id>] [--no-check]: a new id is asked of Vercel first, so a typo is not kept
# (--no-check keeps it unasked, e.g. offline).
vercel_cli_team() {
  local id="" chk=1 a
  for a in "$@"; do case "$a" in --no-check) chk="" ;; *) id="$a" ;; esac; done
  if [ -n "$id" ]; then
    valid_team "$id" || die "A team id has letters, digits, _ and - only"
    if [ -n "$chk" ]; then vercel api "/v2/teams/$id" >/dev/null 2>&1 || die "Vercel does not know team $id here (or could not be asked). Check the id (vercel teams ls), or keep it unchecked: deploys vercel team $id --no-check"; fi
    printf '%s' "$id" > "$CONFIG_DIR/vercel-team"; echo "Vercel team set to $id"
  else vercel_team; echo; fi
}

# Say by hand where a project deploys from, for one disconnected before this tool knew it.
# vercel map <p> <owner/repo> [<branch>] [--no-check]: the project is asked of Vercel first.
vercel_cli_map() {
  local chk=1 a rest=()
  for a in "$@"; do case "$a" in --no-check) chk="" ;; *) rest+=("$a") ;; esac; done
  set -- ${rest[@]+"${rest[@]}"}
  local p="${1:?project}" r="${2:?owner/repo}" ref="${3:-main}" rid="" tmp
  if [ -n "$chk" ]; then vercel_call "/v9/projects/$p" >/dev/null 2>&1 || die "Vercel has no project $p in this team (or could not be asked). Check the name (deploys vercel list), or keep it unchecked: deploys vercel map $p $r $ref --no-check"; fi
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
  type -P gh >/dev/null 2>&1 && rid="$(gh api "repos/$r" --jq .id 2>/dev/null || true)"
  tmp="$(mktemp)"
  # The whole entry is replaced: an old repoId would win over the new repo name.
  jq --arg p "$p" --arg o "${r%%/*}" --arg n "${r#*/}" --arg ref "$ref" --arg rid "$rid" \
    '.[$p] = ({org:$o, repo:$n, ref:$ref} + (if .[$p].offAt then {offAt:.[$p].offAt} else {} end)
              + (if $rid != "" then {repoId:($rid|tonumber)} else {} end))' "$REPOS" > "$tmp" && mv "$tmp" "$REPOS"
  echo "Vercel: $p deploys from $r ($ref)"
}
