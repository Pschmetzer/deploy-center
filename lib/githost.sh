# shellcheck shell=bash
# lib/githost.sh — where a repo lives (GitHub or GitLab), and the GitLab side of "what waits".
#
# Sourced by `deploys` after its GitHub functions (head_of, pending_of, open_prs_of). GitHub stays
# exactly as it was: the dispatchers below hand a GitHub repo to those functions unchanged.
#
# How a repo is written in the JSON (`.repo`):
#   owner/name                    GitHub, as before
#   gitlab.com/group/sub/name     GitLab: the host first, then the full project path
#   git.example.com/group/name    a self-managed GitLab (see githost_of for when it counts as one)
#
# GitLab is read with `glab api` when glab is installed, else with curl against
# https://${GITLAB_HOST:-gitlab.com}/api/v4. GITLAB_TOKEN goes to curl on stdin, never in argv,
# and only to the host GITLAB_HOST names (gitlab.com by default): a repo URL from a platform
# must not be able to send the token elsewhere. See docs/GITLAB.md.

# The GitLab host the token is for, without scheme or trailing slash.
gitlab_host() { local h="${GITLAB_HOST:-gitlab.com}"; h="${h#*://}"; echo "${h%/}"; }

# "host path" of a repo URL or slug: https://, ssh:// and git@host:path forms, .git dropped.
# A bare owner/name is GitHub. A port stays with the host (git.example.com:8443): the API is
# asked there. Only an ssh:// port is dropped, since that is the SSH port, not the web one.
githost_split() {
  local r="${1:-}" ssh=""
  r="${r%/}"; r="${r%.git}"
  case "$r" in
    ssh://*|git+ssh://*) r="${r#*://}"; r="${r#*@}"; ssh=1 ;;
    *://*) r="${r#*://}"; r="${r#*@}" ;;
    git@*:*) r="${r#git@}"; r="${r/://}" ;;
  esac
  local first="${r%%/*}"
  [ -z "$ssh" ] || first="${first%%:*}"
  case "$first" in
    *.*|*:*) printf '%s %s\n' "$(echo "$first" | tr '[:upper:]' '[:lower:]')" "${r#*/}" ;;
    *) printf 'github.com %s\n' "$r" ;;
  esac
}

# github | gitlab | unknown, from a repo URL or the slug in `.repo`.
# GitLab: gitlab.com, the host in GITLAB_HOST, a host in DEPLOYS_GITLAB_HOSTS (spaces between),
# or any host with "gitlab" in its name. Anything else (Bitbucket, Gitea, ...) is unknown.
githost_of() {
  local host path h
  read -r host path < <(githost_split "${1:-}")
  [ -n "$path" ] && [ "$path" != "$host" ] || { echo unknown; return; }
  case "$host" in
    github.com|www.github.com) echo github; return ;;
    gitlab.com|"$(gitlab_host)") echo gitlab; return ;;
  esac
  for h in ${DEPLOYS_GITLAB_HOSTS:-}; do [ "$host" = "$h" ] && { echo gitlab; return; }; done
  case "$host" in *gitlab*) echo gitlab ;; *) echo unknown ;; esac
}

# jq: a platform's repo URL to the `.repo` slug. GitHub stays owner/name, as before; any other
# host keeps its name in front (gitlab.com/group/name).
# shellcheck disable=SC2016,SC2089,SC2034
GITHOST_SLUG_JQ='(sub("^https://github.com/";"") | sub("^https?://";"") | sub("\\.git$";"") | sub("/$";""))'
# jq: the slug of a Vercel link: GitHub {org, repo}; GitLab {projectUrl} or {projectNamespace, projectName}.
# Used by deploys (vercel json, vercel_off).
# shellcheck disable=SC2016,SC2089,SC2034
GITHOST_VERCEL_LINK_JQ='(if .type == "gitlab" then
    (if .projectUrl then (.projectUrl | '"$GITHOST_SLUG_JQ"') elif .projectNamespace and .projectName
     then "gitlab.com/\(.projectNamespace)/\(.projectName)" else null end)
  else "\(.org)/\(.repo)" end)'

# The GitLab token: GITLAB_TOKEN, else the keychain entry `deploys gitlab set-token` saved.
# Empty when there is none. Never printed anywhere else.
GITLAB_KEYCHAIN="deploy-center-gitlab"
gitlab_token() {
  if [ -n "${GITLAB_TOKEN:-}" ]; then printf '%s' "$GITLAB_TOKEN"; return 0; fi
  command -v security >/dev/null 2>&1 || return 0
  security find-generic-password -a "${USER:-$(id -un)}" -s "$GITLAB_KEYCHAIN" -w 2>/dev/null || true
}

# Whether any git host can be asked at all. Without one, `with_heads` adds no heads.
githost_available() {
  command -v gh >/dev/null 2>&1 || command -v glab >/dev/null 2>&1 || [ -n "$(gitlab_token)" ]
}

# ---------- dispatch: same arguments and output files as the GitHub functions ----------

githost_head_of() {
  case "$(githost_of "$1")" in github) head_of "$@" ;; gitlab) gitlab_head_of "$@" ;; esac
  return 0
}
githost_pending_of() {
  case "$(githost_of "$1")" in github) pending_of "$@" ;; gitlab) gitlab_pending_of "$@" ;; esac
  return 0
}
githost_open_prs_of() {
  case "$(githost_of "$1")" in github) open_prs_of "$@" ;; gitlab) gitlab_open_prs_of "$@" ;; esac
  return 0
}

# ---------- GitLab ----------

# GET one API path (with query) on a GitLab host; the body on stdout. On failure: "HTTP <code>"
# (and the answer) on stderr, exit 1. glab when installed (DEPLOYS_GITLAB_CURL=1 forces curl).
gitlab_api() {
  local host="$1" path="$2" out code tok=""
  if [ -z "${DEPLOYS_GITLAB_CURL:-}" ] && command -v glab >/dev/null 2>&1; then
    glab api --hostname "$host" "$path"; return
  fi
  [ "$host" = "$(gitlab_host)" ] && tok="$(gitlab_token)"
  # The token on stdin as a curl config line, so it never shows in the process list.
  out="$( { [ -z "$tok" ] || printf 'header = "PRIVATE-TOKEN: %s"\n' "$tok"; } \
    | curl -sS --connect-timeout 10 --max-time 60 -H "Accept: application/json" -K - -w '\n%{http_code}' \
      "https://$host/api/v4/$path" 2>/dev/null)" || out=$'\n000'
  code="${out##*$'\n'}"; out="${out%$'\n'*}"
  if [[ "$code" != 2* ]]; then echo "gitlab: HTTP $code: $(printf '%s' "$out" | head -c 300)" >&2; return 1; fi
  printf '%s' "$out"
}

# A path or ref for a URL: group/name -> group%2Fname.
gitlab_enc() { jq -rn --arg s "$1" '$s | @uri'; }
# "host project-id" of a slug.
gitlab_project() { local host path; read -r host path < <(githost_split "$1"); printf '%s %s\n' "$host" "$(gitlab_enc "$path")"; }

# jq helpers: GitLab dates carry fractions and an offset (2026-01-02T01:00:00.000+01:00), which
# fromdateiso8601 does not read. Bots: GitLab marks few, so names decide (Renovate, Dependabot,
# project and group access-token bots).
# A jq program, not a command: SC2089/SC2090 do not apply.
# shellcheck disable=SC2016,SC2089
GITLAB_JQ='def gldate: (. // null) | if . == null then null else sub("\\.[0-9]+"; "")
    | if test("Z$") then fromdateiso8601
      else capture("^(?<d>.*T[0-9:]+)(?<s>[+-])(?<h>[0-9]{2}):?(?<m>[0-9]{2})$") as $c
        | ($c.d + "Z" | fromdateiso8601) - (if $c.s == "-" then -1 else 1 end) * (($c.h | tonumber) * 3600 + ($c.m | tonumber) * 60) end end;
  def glbot: ((.bot // false) or ((.username // .author_name // "") | test("\\[bot\\]|dependabot|renovate|^(project|group)_[0-9]+_bot|(^|[-_ ])bot$"; "i"))
    or ((.author_email // "") | test("\\[bot\\]|dependabot|renovate|noreply.*bot|bot@"; "i")));
  def glmr: (.message // "" | (capture("See merge request [^!\\s]*!(?<n>[0-9]+)") // capture("\\(!(?<n>[0-9]+)\\)")) | .n | tonumber) // null;
  # A comparison with the .files GitHub gives ({filename, additions, deletions}), for RISK_DEF.
  def glfiles: .files = [(.diffs // [])[] | {filename:(.new_path // .old_path),
      additions:((.diff // "") | split("\n") | map(select(startswith("+"))) | length),
      deletions:((.diff // "") | split("\n") | map(select(startswith("-"))) | length)}];'
# shellcheck disable=SC2090
export GITLAB_JQ

gitlab_head_of() {
  local repo="$1" ref="$2" out="$3" host id
  local f ans; f="$out/$(echo "$repo@$ref" | tr '/@' '__').json"
  read -r host id < <(gitlab_project "$repo")
  if ans="$(gitlab_api "$host" "projects/$id/repository/commits/$(gitlab_enc "$ref")" 2>"$f.err")"; then
    echo "$ans" | jq -c --arg k "$repo@$ref" "$GITLAB_JQ"'{key:$k, value:{at:(.committed_date | gldate), msg:(.title // (.message | split("\n")[0])), sha:.id}}' \
      > "$f" 2>/dev/null || rm -f "$f"
  elif declare -F head_why >/dev/null; then
    jq -nc --arg k "$repo@$ref" --arg e "$(head_why "$f.err" GitLab | sed 's/(gh auth login)/(glab auth login, or deploys gitlab set-token)/')" '{key:$k, value:{error:$e}}' > "$f" 2>/dev/null || true
  fi
  rm -f "$f.err"
}

# The same record pending_of writes: commits from the live commit to the branch, the merge
# requests among them, and how the branch stands to what is live. GitLab's compare has no
# ahead/behind, so: ahead = the commits listed; the merge base decides ahead, behind or diverged,
# and only when live is not an ancestor is the other direction compared for behindBy.
gitlab_pending_of() {
  local repo="$1" base="$2" ref="$3" out="$4" key f host id cmp mb status behind="null" n
  key="$repo@$base@$ref"; f="$out/$(echo "$key" | tr '/@' '__').json"
  read -r host id < <(gitlab_project "$repo")
  if ! cmp="$(gitlab_api "$host" "projects/$id/repository/compare?from=$(gitlab_enc "$base")&to=$(gitlab_enc "$ref")" 2>"$f.err")"; then
    # As on GitHub, only a 404 (the live commit is gone: branch rewritten) is a record.
    if grep -qE 'HTTP 404|404 Not Found|Ref Not Found' "$f.err"; then
      printf '{"key":"%s","value":{"rewritten":true}}\n' "$key" > "$f"
    fi
    rm -f "$f.err"; return 0
  fi
  rm -f "$f.err"
  n="$(echo "$cmp" | jq '.commits | length' 2>/dev/null)" || return 0
  mb="$(gitlab_api "$host" "projects/$id/repository/merge_base?refs%5B%5D=$(gitlab_enc "$base")&refs%5B%5D=$(gitlab_enc "$ref")" 2>/dev/null | jq -r '.id // empty' 2>/dev/null)"
  if [ -z "$mb" ]; then status=null
  elif [ "${mb#"$base"}" != "$mb" ]; then  # live (full or short sha) is the merge base
    [ "$n" -gt 0 ] && status='"ahead"' || status='"identical"'; behind=0
  else
    behind="$(gitlab_api "$host" "projects/$id/repository/compare?from=$(gitlab_enc "$ref")&to=$(gitlab_enc "$base")" 2>/dev/null | jq '.commits | length' 2>/dev/null)" || behind=null
    [ -n "$behind" ] || behind=null
    [ "$n" -gt 0 ] && status='"diverged"' || status='"behind"'
  fi
  # The risk of the diff, as on GitHub, from the diffs of the same answer: no extra call.
  echo "$cmp" | jq -c --arg k "$key" --argjson st "$status" --argjson bb "$behind" "${RISK_DEF:-def risk: null;}$GITLAB_JQ"'
      (glfiles | risk) as $risk
      | [.commits[] | {sha:.id, n:glmr}] as $c
      | {key:$k, value:{commits:(.commits | length), status:$st, behindBy:$bb,
          nums:[$c[] | .n // empty],
          # GitLab lists every commit of a comparison: the count is never a floor.
          partial:false,
          oldestAt:([.commits[].committed_date | gldate] | min), risk:$risk,
          bare:([$c[] | select(.n == null) | .sha])}}' > "$f" 2>/dev/null || return 0
  # A squash or fast-forward merge often leaves no !number in the message. For a few such
  # commits, ask which merged MR they came from; numbers are counted once.
  local bare nums
  bare="$(jq -r '.value.bare | if length <= 10 then .[] else empty end' "$f")"
  nums="$(for s in $bare; do gitlab_api "$host" "projects/$id/repository/commits/$s/merge_requests" 2>/dev/null \
            | jq -r '.[] | select(.state == "merged") | .iid' 2>/dev/null; done | jq -sc '.')"
  jq -c --argjson more "${nums:-[]}" '.value.prs = ((.value.nums + $more) | unique | length) | del(.value.bare, .value.nums)' "$f" > "$f.t" && mv "$f.t" "$f"
}

# Open merge requests: all, drafts, bots. The same record open_prs_of writes.
gitlab_open_prs_of() {
  local repo="$1" out="$2" host id
  read -r host id < <(gitlab_project "$repo")
  gitlab_api "$host" "projects/$id/merge_requests?state=opened&per_page=100" 2>/dev/null \
    | jq -c --arg k "$repo" "$GITLAB_JQ"'{key:$k, value:{all:length, partial:(length >= 100),
        drafts:(map(select(.draft // .work_in_progress // false)) | length), bots:(map(select(.author | glbot)) | length)}}' \
    > "$out/$(echo "$repo" | tr '/' '_').json" 2>/dev/null || true
}

# `deploys details` for a GitLab repo: the same JSON as for GitHub. Checks come from the commit
# statuses of the branch head (one per CI job). Open MRs have no CI state in GitLab's list: "none".
gitlab_details() {
  local repo="$1" base="${2:-}" ref="${3:-main}" host id path dt sha
  read -r host id < <(gitlab_project "$repo"); read -r _ path < <(githost_split "$repo")
  dt="$(mktemp -d)"; echo null > "$dt/cmp"
  if [ -n "$base" ] && [ "$base" != "null" ]; then
    # Through a file: with its diffs a comparison can be megabytes. The diffs are only counted.
    gitlab_api "$host" "projects/$id/repository/compare?from=$(gitlab_enc "$base")&to=$(gitlab_enc "$ref")" 2>/dev/null \
      | jq '.diffs = [(.diffs // [])[] | {filename:(.new_path // .old_path),
              additions:((.diff // "") | split("\n") | map(select(startswith("+"))) | length),
              deletions:((.diff // "") | split("\n") | map(select(startswith("-"))) | length)}]' > "$dt/cmp.t" 2>/dev/null \
      && [ -s "$dt/cmp.t" ] && mv "$dt/cmp.t" "$dt/cmp"
  fi
  sha="$(jq -r '.commit.id // empty' "$dt/cmp")"
  [ -n "$sha" ] || sha="$(gitlab_api "$host" "projects/$id/repository/commits/$(gitlab_enc "$ref")" 2>/dev/null | jq -r '.id // empty' 2>/dev/null)"
  { [ -n "$sha" ] && gitlab_api "$host" "projects/$id/repository/commits/$sha/statuses?per_page=100" 2>/dev/null \
      | jq '{total:length, failed:(map(select(.status == "failed" or .status == "canceled")) | length),
             running:(map(select(.status == "running" or .status == "pending" or .status == "created")) | length)}' 2>/dev/null; } > "$dt/checks" \
    || echo null > "$dt/checks"
  [ -s "$dt/checks" ] || echo null > "$dt/checks"
  gitlab_api "$host" "projects/$id/merge_requests?state=opened&per_page=50&order_by=updated_at" 2>/dev/null \
    | jq "$GITLAB_JQ"'[.[] | {number:.iid, title, author:.author.username, bot:(.author | glbot),
          draft:(.draft // .work_in_progress // false), updatedAt:.updated_at, url:.web_url, ci:"none"}]' > "$dt/open" 2>/dev/null \
    || echo '[]' > "$dt/open"
  [ -s "$dt/open" ] || echo '[]' > "$dt/open"
  # Same list of risky files as `details` for GitHub.
  jq -n --slurpfile c "$dt/cmp" --slurpfile checks "$dt/checks" --slurpfile open "$dt/open" \
     --arg url "https://$host/$path/-/compare/$base...$ref" "$GITLAB_JQ"'
    ($c[0] // {}) as $c |
    {commits:[($c.commits // [])[] | {sha:.id[0:7], full:.id, url:.web_url, msg:(.title // (.message | split("\n")[0])),
               author:.author_name, bot:glbot, at:(.committed_date | gldate), pr:glmr}] | sort_by(.at) | reverse,
     files:($c.diffs // [] | length), additions:($c.diffs // [] | map(.additions) | add // 0),
     deletions:($c.diffs // [] | map(.deletions) | add // 0),
     risky:[($c.diffs // [])[] | .filename
            | select(test("(^|/)(migrations?|prisma)/|schema\\.(prisma|sql|rb)$|(^|/)\\.env|(^|/)(package\\.json|package-lock\\.json|pnpm-lock\\.yaml|yarn\\.lock|requirements\\.txt|Pipfile\\.lock|poetry\\.lock|go\\.mod|Gemfile\\.lock|Cargo\\.lock)$|Dockerfile|render\\.yaml$|vercel\\.json$|\\.github/workflows/|\\.gitlab-ci\\.yml$"))],
     onlyBots:(($c.commits // []) | length > 0 and all(glbot)),
     compareUrl:(if $c.commits then ($c.web_url // $url) else null end),
     checks:$checks[0], open:$open[0]}'
  rm -rf "$dt"
}

# `deploys ci` and --when-green for a GitLab repo: the newest pipeline of the commit, as one line
# of the same JSON ci_of gives for GitHub. GitLab already sums the jobs up (allow_failure jobs do
# not turn it red). A pipeline that waits for a person (manual, scheduled) is not "running": it
# would never end, so it counts as no checks. Not readable: unknown, final (no 30 minute wait).
gitlab_ci_of() {  # gitlab_ci_of <slug> <sha or branch>
  local host id c e
  read -r host id < <(gitlab_project "$1")
  e="$(mktemp)"
  if ! c="$(gitlab_api "$host" "projects/$id/repository/commits/$(gitlab_enc "$2")" 2>"$e")"; then
    jq -nc --arg w "$(if declare -F head_why >/dev/null; then head_why "$e" GitLab; else tail -n 1 "$e" | cut -c1-150; fi)" \
      '{state:"unknown", final:true, reason:"GitLab could not be asked: \($w)"}'
    rm -f "$e"; return 0
  fi
  rm -f "$e"
  echo "$c" | jq -c '(.last_pipeline // null) as $p
    | if $p == null then {state:"none", reason:"no pipeline on this commit", checks:0, failed:0, running:0}
      else ($p.status // "") as $s | "pipeline #\($p.id // "?")" as $n
        | if $s == "success" then {state:"green", reason:"\($n) passed", checks:1, failed:0, running:0}
          elif ($s | IN("failed", "canceled")) then {state:"red", reason:"\($n) \($s)", checks:1, failed:1, running:0}
          elif ($s | IN("created", "waiting_for_resource", "preparing", "pending", "running")) then {state:"pending", reason:"\($n) is \($s)", checks:1, failed:0, running:1}
          else {state:"none", reason:"\($n) is \($s) (nothing runs by itself)", checks:1, failed:0, running:0} end end' 2>/dev/null \
    || echo '{"state":"unknown","final":true,"reason":"GitLab gave an answer that could not be read"}'
}

# `deploys risk` for a GitLab repo: the risk of what waits between <base> and <ref>. Fails when
# GitLab cannot compare them.
gitlab_risk_of() {  # gitlab_risk_of <slug> <base> <ref>
  local host id
  read -r host id < <(gitlab_project "$1")
  gitlab_api "$host" "projects/$id/repository/compare?from=$(gitlab_enc "$2")&to=$(gitlab_enc "$3")" 2>/dev/null \
    | jq -ce "$RISK_DEF$GITLAB_JQ"'glfiles | risk' 2>/dev/null
}

# The default branch of a repo on GitLab; empty when it cannot be read.
gitlab_default_branch() {
  local host id; read -r host id < <(gitlab_project "$1")
  gitlab_api "$host" "projects/$id" 2>/dev/null | jq -r '.default_branch // empty' 2>/dev/null || true
}

# The project id Vercel's gitSource needs for a GitLab repo (`vercel map`).
gitlab_project_id() { local host id; read -r host id < <(gitlab_project "$1"); gitlab_api "$host" "projects/$id" 2>/dev/null | jq -r '.id // empty'; }

# For doctor: whether GitLab can be read with the login or token here.
gitlab_logged_in() {
  if command -v glab >/dev/null 2>&1 && glab auth status --hostname "$(gitlab_host)" >/dev/null 2>&1; then return 0; fi
  [ -n "$(gitlab_token)" ] && DEPLOYS_GITLAB_CURL=1 gitlab_api "$(gitlab_host)" user >/dev/null 2>&1
}
# The GitLab user, for `deploys where`.
gitlab_user() { gitlab_api "$(gitlab_host)" user 2>/dev/null | jq -r '.username // empty' 2>/dev/null; }

export -f gitlab_host githost_split githost_of githost_head_of githost_pending_of githost_open_prs_of \
  gitlab_api gitlab_enc gitlab_project gitlab_head_of gitlab_pending_of gitlab_open_prs_of gitlab_token
export GITLAB_KEYCHAIN
