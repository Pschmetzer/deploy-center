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
# A bare owner/name is GitHub.
githost_split() {
  local r="${1:-}"
  r="${r%/}"; r="${r%.git}"
  case "$r" in
    *://*) r="${r#*://}"; r="${r#*@}" ;;
    git@*:*) r="${r#git@}"; r="${r/://}" ;;
  esac
  local first="${r%%/*}"
  case "$first" in
    *.*|*:*) printf '%s %s\n' "$(echo "${first%%:*}" | tr '[:upper:]' '[:lower:]')" "${r#*/}" ;;
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
  elif (.type == "github" or .type == null) and .org and .repo then "\(.org)/\(.repo)"
  # Bitbucket (owner/slug) and anything else: not a repo the git-host code can ask, so none.
  else null end)'

# Whether any git host can be asked at all. Without one, `with_heads` adds no heads.
githost_available() {
  command -v gh >/dev/null 2>&1 || command -v glab >/dev/null 2>&1 || [ -n "${GITLAB_TOKEN:-}" ]
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
# Every call is a read: a rate limit (429), a server error (5xx), no answer or a hung glab
# (DEPLOYS_GITLAB_TIMEOUT seconds, 60) is asked again, three times in all, 2 s then 4 s apart.
gitlab_api() {
  local host="$1" path="$2" out code tok="" try err rc
  if [ -z "${DEPLOYS_GITLAB_CURL:-}" ] && command -v glab >/dev/null 2>&1; then
    err="$(mktemp)"
    for try in 1 2 3; do
      rc=0
      # perl's alarm survives the exec (macOS has no `timeout`); a hung glab ends with 142.
      if command -v perl >/dev/null 2>&1; then
        out="$(perl -e 'alarm shift; exec @ARGV or exit 127' "${DEPLOYS_GITLAB_TIMEOUT:-60}" glab api --hostname "$host" "$path" 2>"$err")" || rc=$?
      else
        out="$(glab api --hostname "$host" "$path" 2>"$err")" || rc=$?
      fi
      [ "$rc" = 0 ] && break
      [ "$try" -lt 3 ] && { [ "$rc" = 142 ] || grep -qE 'HTTP (429|5[0-9][0-9])|timed? ?out|connection (refused|reset)' "$err"; } \
        || break
      sleep $((try * 2))
    done
    [ "$rc" = 142 ] && echo "gitlab: no answer from glab in ${DEPLOYS_GITLAB_TIMEOUT:-60} s" >> "$err"
    cat "$err" >&2; rm -f "$err"
    [ "$rc" = 0 ] || return 1
    printf '%s\n' "$out"; return 0
  fi
  [ "$host" = "$(gitlab_host)" ] && tok="${GITLAB_TOKEN:-}"
  for try in 1 2 3; do
    # The token on stdin as a curl config line, so it never shows in the process list.
    out="$( { [ -z "$tok" ] || printf 'header = "PRIVATE-TOKEN: %s"\n' "$tok"; } \
      | curl -sS --connect-timeout 10 --max-time 60 -H "Accept: application/json" -K - -w '\n%{http_code}' \
        "https://$host/api/v4/$path" 2>/dev/null)" || out=$'\n000'
    code="${out##*$'\n'}"; out="${out%$'\n'*}"
    case "$code" in 429|5*|000) [ "$try" -lt 3 ] && { sleep $((try * 2)); continue; } ;; esac
    break
  done
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
  def glmr: (.message // "" | (capture("See merge request [^!\\s]*!(?<n>[0-9]+)") // capture("\\(!(?<n>[0-9]+)\\)")) | .n | tonumber) // null;'
# shellcheck disable=SC2090
export GITLAB_JQ

# The file name for a key like group/app@ref, the same as deploys' cache_name (used when it
# is there): "/" and "@" become "_"; a key with a "_" of its own also gets its checksum, so
# a_b/c@main and a/b_c@main do not meet in one file (PRV-129). Readers glob the folder and
# go by the key inside, so only the names change.
githost_cache_name() {
  if declare -F cache_name >/dev/null; then cache_name "$1"; return; fi
  local n; n="$(printf '%s' "$1" | tr '/@' '__')"
  case "$1" in *_*) n="$n-$(printf '%s' "$1" | cksum | cut -d' ' -f1)" ;; esac
  printf '%s' "$n"
}

gitlab_head_of() {
  local repo="$1" ref="$2" out="$3" host id
  read -r host id < <(gitlab_project "$repo")
  gitlab_api "$host" "projects/$id/repository/commits/$(gitlab_enc "$ref")" 2>/dev/null \
    | jq -c --arg k "$repo@$ref" "$GITLAB_JQ"'{key:$k, value:{at:(.committed_date | gldate), msg:(.title // (.message | split("\n")[0])), sha:.id}}' \
    > "$out/$(githost_cache_name "$repo@$ref").json" 2>/dev/null || true
}

# The same record pending_of writes: commits from the live commit to the branch, the merge
# requests among them, and how the branch stands to what is live. GitLab's compare has no
# ahead/behind, so: ahead = the commits listed; the merge base decides ahead, behind or diverged,
# and only when live is not an ancestor is the other direction compared for behindBy.
gitlab_pending_of() {
  local repo="$1" base="$2" ref="$3" out="$4" key f host id cmp mb status behind="null" n
  key="$repo@$base@$ref"; f="$out/$(githost_cache_name "$key").json"
  read -r host id < <(gitlab_project "$repo")
  if ! cmp="$(gitlab_api "$host" "projects/$id/repository/compare?from=$(gitlab_enc "$base")&to=$(gitlab_enc "$ref")" 2>"$f.err")"; then
    # As on GitHub, only a 404 (the live commit is gone: branch rewritten) is a record. GitLab
    # also answers 404 for a private project it will not show: rewritten only when the branch
    # itself can be read, else no record (not known), not "history rewritten" for every such repo.
    if grep -qE 'HTTP 404|404 Not Found|Ref Not Found' "$f.err" \
      && gitlab_api "$host" "projects/$id/repository/commits/$(gitlab_enc "$ref")" >/dev/null 2>&1; then
      jq -nc --arg k "$key" '{key:$k, value:{rewritten:true}}' > "$f"
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
  echo "$cmp" | jq -c --arg k "$key" --argjson st "$status" --argjson bb "$behind" "$GITLAB_JQ"'
      [.commits[] | {sha:.id, n:glmr}] as $c
      | {key:$k, value:{commits:(.commits | length), status:$st, behindBy:$bb,
          nums:[$c[] | .n // empty],
          # GitLab lists every commit of a comparison: the count is never a floor.
          partial:false,
          oldestAt:([.commits[].committed_date | gldate] | min),
          bare:([$c[] | select(.n == null) | .sha])}}' > "$f" 2>/dev/null || return 0
  # A squash or fast-forward merge often leaves no !number in the message. For a few such
  # commits, ask which merged MR they came from; numbers are counted once.
  # Which merged MR a commit came from does not change: each answer is kept, one file per commit
  # (gitlab_mrs_of), so a refresh asks only for commits it has not seen.
  local bare nums
  bare="$(jq -r '.value.bare | if length <= 10 then .[] else empty end' "$f")"
  nums="$(for s in $bare; do gitlab_mrs_of "$host" "$id" "$s"; done | jq -sc '.')"
  jq -c --argjson more "${nums:-[]}" '.value.prs = ((.value.nums + $more) | unique | length) | del(.value.bare, .value.nums)' "$f" > "$f.t" && mv "$f.t" "$f"
}

# gitlab_mrs_of <host> <project id> <sha>: the iids of the merged MRs a commit came from, one a
# line. Kept in <config>/cache/gitlab-mrs/ once GitLab answered; a failed answer is not kept.
gitlab_mrs_of() {
  local d f out
  d="${CONFIG_DIR:-${DEPLOYS_CONFIG:-$HOME/.config/deploys}}/cache/gitlab-mrs"
  f="$d/$(printf '%s_%s_%s' "$1" "$2" "$3" | tr -c 'A-Za-z0-9._-' '_')"
  if [ -f "$f" ]; then cat "$f"; return 0; fi
  out="$(gitlab_api "$1" "projects/$2/repository/commits/$3/merge_requests" 2>/dev/null)" || return 0
  out="$(printf '%s' "$out" | jq -r '.[] | select(.state == "merged") | .iid' 2>/dev/null)" || return 0
  if mkdir -p "$d" 2>/dev/null; then
    printf '%s\n' "$out" | grep . > "$f.$$" || true
    mv -f "$f.$$" "$f" 2>/dev/null || rm -f "$f.$$"
  fi
  printf '%s\n' "$out" | grep . || true
}

# Open merge requests: all, drafts, bots. The same record open_prs_of writes. Up to five pages
# of 100 (a page with fewer is the last); more than 500 count as 500.
gitlab_open_prs_of() {
  local repo="$1" out="$2" host id page=1 chunk all="[]"
  read -r host id < <(gitlab_project "$repo")
  while [ "$page" -le 5 ]; do
    chunk="$(gitlab_api "$host" "projects/$id/merge_requests?state=opened&per_page=100&page=$page" 2>/dev/null)" || return 0
    printf '%s' "$chunk" | jq -e 'type == "array"' >/dev/null 2>&1 || return 0
    all="$(jq -c -s '.[0] + .[1]' <(printf '%s' "$all") <(printf '%s' "$chunk"))"
    [ "$(printf '%s' "$chunk" | jq 'length')" -ge 100 ] || break
    page=$((page + 1))
  done
  printf '%s' "$all" \
    | jq -c --arg k "$repo" "$GITLAB_JQ"'{key:$k, value:{all:length,
        drafts:(map(select(.draft // .work_in_progress // false)) | length), bots:(map(select(.author | glbot)) | length)}}' \
    > "$out/$(githost_cache_name "$repo").json" 2>/dev/null || true
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

# The project id Vercel's gitSource needs for a GitLab repo (`vercel map`).
gitlab_project_id() { local host id; read -r host id < <(gitlab_project "$1"); gitlab_api "$host" "projects/$id" 2>/dev/null | jq -r '.id // empty'; }

# For doctor: whether GitLab can be read with the login or token here.
gitlab_logged_in() {
  if command -v glab >/dev/null 2>&1 && glab auth status --hostname "$(gitlab_host)" >/dev/null 2>&1; then return 0; fi
  [ -n "${GITLAB_TOKEN:-}" ] && DEPLOYS_GITLAB_CURL=1 gitlab_api "$(gitlab_host)" user >/dev/null 2>&1
}
# The GitLab user, for `deploys where`.
gitlab_user() { gitlab_api "$(gitlab_host)" user 2>/dev/null | jq -r '.username // empty' 2>/dev/null; }

export -f gitlab_host githost_cache_name githost_split githost_of githost_head_of githost_pending_of githost_open_prs_of \
  gitlab_api gitlab_enc gitlab_project gitlab_head_of gitlab_pending_of gitlab_open_prs_of gitlab_mrs_of
