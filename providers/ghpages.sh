#!/bin/bash
# providers/ghpages.sh — GitHub Pages for `deploys`, deployed by a workflow dispatch
# (opt-in: deploys providers enable ghpages).
#
# A Pages site built with GitHub Actions deploys when its workflow runs. This provider lists the
# repositories you name, shows the newest run of each one's workflow, and starts a deploy by
# dispatching that workflow on its branch (`workflow_dispatch`: the workflow must have that trigger).
# GitHub offers no way to turn a workflow's push trigger off from the API, and no rollback of
# a Pages site, so those are refused; re-run an older run in GitHub instead.
#
# Contract (docs/PROVIDERS.md): ghpages_meta, _ready, _json, _has, _off, _deploy_json, _status,
# _latest, _cancel, _rollback, _logs, _url, _set_key, _doctor. Phases: queued | building | ready | failed | canceled.
# A deploy id is a workflow run id.
#
# Sites: DEPLOYS_GHPAGES_SITES="owner/repo[:workflow.yml[@branch]] …" (space separated), and/or
# <config>/ghpages.json written by `deploys ghpages add owner/repo [workflow.yml] [branch]`
# ([{repo, workflow, ref}]; workflow defaults to pages.yml, branch to main).
# Token: GITHUB_PAGES_TOKEN, GH_TOKEN or GITHUB_TOKEN, else the keychain item deploy-center-ghpages.
# A fine-grained token needs Actions: read and write, Pages: read, Metadata: read. It goes to curl on stdin.

GHPAGES_KEYCHAIN="deploy-center-ghpages"
GHPAGES_API="${GHPAGES_API:-https://api.github.com}"

declare -F die >/dev/null || die() { echo "Error: $*" >&2; exit 1; }
# shellcheck source=../lib/http.sh
declare -F http_call >/dev/null || { _gp_h="$(dirname "${BASH_SOURCE[0]}")/../lib/http.sh"; [ ! -f "$_gp_h" ] || . "$_gp_h"; unset _gp_h; }

ghpages_config_dir() { echo "${CONFIG_DIR:-${DEPLOYS_CONFIG:-$HOME/.config/deploys}}"; }
ghpages_file() { echo "$(ghpages_config_dir)/ghpages.json"; }

ghpages_key() {
  local k=""
  if declare -F key_of >/dev/null; then k="$(key_of ghpages 2>/dev/null)" || k=""
  elif [ -n "${GITHUB_PAGES_TOKEN:-}" ]; then k="$GITHUB_PAGES_TOKEN"
  elif [ -n "${GH_TOKEN:-}" ]; then k="$GH_TOKEN"
  elif [ -n "${GITHUB_TOKEN:-}" ]; then k="$GITHUB_TOKEN"
  else k="$(security find-generic-password -a "${USER:-$(id -un)}" -s "$GHPAGES_KEYCHAIN" -w 2>/dev/null)" || k=""
  fi
  [ -n "$k" ] || { echo "No GitHub token. Create a fine-grained token (Actions: read and write, Pages: read), then: pbpaste | deploys ghpages set-key (or set GITHUB_PAGES_TOKEN)" >&2; return 1; }
  printf '%s' "$k"
}

# ghpages_call METHOD PATH [BODY]: the answer on stdout (empty for a 204); on failure the reason on stderr, rc 1.
ghpages_call() {
  local k e rc=0 fix="pbpaste | deploys ghpages set-key"
  declare -F http_call >/dev/null || { echo "GitHub Pages: lib/http.sh is missing" >&2; return 1; }
  k="$(ghpages_key)" || return 1
  [ -z "${GITHUB_PAGES_TOKEN:-}${GH_TOKEN:-}${GITHUB_TOKEN:-}" ] || fix="check the token in the environment (GITHUB_PAGES_TOKEN, GH_TOKEN or GITHUB_TOKEN)"
  # shellcheck disable=SC2034  # read by http_call
  local HTTP_AUTH="Authorization: Bearer $k" HTTP_FIX="$fix"
  e="$(mktemp)"
  ( http_call "GitHub" "$1" "$GHPAGES_API$2" "${3:-}" ) 2>"$e" || rc=$?
  [ "$rc" = 0 ] || sed '1s/^[^ ]*Error:[^ ]* //' "$e" >&2
  rm -f "$e"; return "$rc"
}

# ---------- the sites ----------

ghpages_repo_ok() { [[ "$1" =~ ^[A-Za-z0-9_.-]+/[A-Za-z0-9_.-]+$ ]]; }
ghpages_wf_ok() { [[ "$1" =~ ^[A-Za-z0-9_.-]+\.ya?ml$ ]] || [[ "$1" =~ ^[0-9]+$ ]]; }
ghpages_ref_ok() { [[ "$1" =~ ^[A-Za-z0-9_./-]+$ ]] && [[ "$1" != -* ]]; }

# The sites as a JSON array [{repo, workflow, ref}], from the environment and the file.
ghpages_sites() {
  local tok repo rest wf ref lines="" f
  for tok in ${DEPLOYS_GHPAGES_SITES:-}; do
    repo="${tok%%:*}"; rest=""; [ "$repo" = "$tok" ] || rest="${tok#*:}"
    wf="${rest%%@*}"; ref=""; [ "$wf" = "$rest" ] || ref="${rest#*@}"
    ghpages_repo_ok "$repo" || { echo "GitHub Pages: \"$repo\" in DEPLOYS_GHPAGES_SITES is not owner/name; skipped" >&2; continue; }
    lines="$lines$(jq -nc --arg r "$repo" --arg w "${wf:-pages.yml}" --arg f "${ref:-main}" '{repo:$r, workflow:$w, ref:$f}')"$'\n'
  done
  f="$(ghpages_file)"
  [ ! -s "$f" ] || lines="$lines$(jq -c '.[]? | select(type == "object" and (.repo | type == "string")) | {repo, workflow:(.workflow // "pages.yml"), ref:(.ref // "main")}' "$f" 2>/dev/null)"$'\n'
  printf '%s' "$lines" | jq -sc '
    map(select(.repo | test("^[A-Za-z0-9_.-]+/[A-Za-z0-9_.-]+$")) | select(.workflow | test("^([A-Za-z0-9_.-]+\\.ya?ml|[0-9]+)$")) | select(.ref | test("^[A-Za-z0-9_./-]+$") and (startswith("-") | not)))
    | reduce .[] as $s ([]; if any(.[]; .repo == $s.repo) then . else . + [$s] end)'
}

# One site by its id (owner/repo) or its repository name; prints the JSON object.
ghpages_site() {
  local out
  out="$(ghpages_sites | jq -c --arg n "$1" '[.[] | select(.repo == $n or (.repo | split("/")[1]) == $n)] | .[0] // empty')"
  [ -n "$out" ] || return 1
  printf '%s' "$out"
}

# shellcheck disable=SC2016
GHPAGES_JQ='
  def t: (. // null) | if . then ((try (capture("^(?<d>[0-9]{4}-[0-9]{2}-[0-9]{2}T[0-9]{2}:[0-9]{2}:[0-9]{2})(\\.[0-9]+)?(?<z>Z|[+-][0-9]{2}:?[0-9]{2})?$") | (.d + "Z" | fromdateiso8601) - (if (.z // "Z") == "Z" then 0 else (.z | (if startswith("-") then -1 else 1 end) * ((.[1:3] | tonumber) * 3600 + (.[-2:] | tonumber) * 60)) end)) catch null) // null) else null end;
  def phase: if . == null then null
    elif .status != "completed" then (if .status == "in_progress" then "building" else "queued" end)
    elif .conclusion == "success" or .conclusion == "neutral" then "ready"
    elif .conclusion == "cancelled" or .conclusion == "skipped" then "canceled"
    else "failed" end;
  def state: if . == null then "?" else (if .status == "completed" then (.conclusion // "completed") else .status end) end;
  def line: if . == null then "none\t\t?" else "\(.id)\t\(phase // "")\t\(state)" end;
'

# The newest runs of a site's workflow on its branch, newest first, as a JSON array.
ghpages_runs() {  # ghpages_runs <site json> [n]
  local repo wf ref out
  repo="$(printf '%s' "$1" | jq -r .repo)"; wf="$(printf '%s' "$1" | jq -r .workflow)"; ref="$(printf '%s' "$1" | jq -r .ref)"
  out="$(ghpages_call GET "/repos/$repo/actions/workflows/$wf/runs?per_page=${2:-5}&branch=$ref")" || return 1
  printf '%s' "$out" | jq -ce '.workflow_runs | select(type == "array")' || { echo "GitHub answered without a run list for $repo" >&2; return 1; }
}

ghpages_meta() {
  printf '{"id":"ghpages","label":"GitHub Pages","noun":"site","defaultOn":false,"keyEnv":["GITHUB_PAGES_TOKEN","GH_TOKEN","GITHUB_TOKEN"],"keychain":"%s","caps":{"off":false,"sha":false,"cancel":true,"rollback":false,"logs":false,"preview":false}}\n' "$GHPAGES_KEYCHAIN"
}

ghpages_ready() {
  command -v curl >/dev/null 2>&1 && command -v jq >/dev/null 2>&1 && ghpages_key >/dev/null 2>&1 \
    && [ "$(ghpages_sites 2>/dev/null | jq 'length' 2>/dev/null)" -gt 0 ] 2>/dev/null
}

# No call: the sites are the ones you named.
ghpages_has() {
  local s
  s="$(ghpages_site "$1")" || return 1
  printf '%s\n' "$s" | jq -r .repo
}

ghpages_json() {
  local sites s repo run pg rows="" row
  sites="$(ghpages_sites)" || die "Could not read the GitHub Pages sites"
  while IFS= read -r s; do
    [ -n "$s" ] || continue
    repo="$(printf '%s' "$s" | jq -r .repo)"
    if run="$(ghpages_runs "$s" 5 2>&1)"; then
      if pg="$(ghpages_call GET "/repos/$repo/pages" 2>&1)" && printf '%s' "$pg" | jq -e 'type == "object"' >/dev/null 2>&1; then :
      else pg='null'; fi
      row="$(jq -nc --argjson s "$s" --argjson r "$run" --argjson p "$pg" '{site:$s, runs:$r, pages:$p}')"
    else
      row="$(jq -nc --argjson s "$s" --arg e "$run" '{site:$s, runs:[], pages:null, err:$e}')"
    fi
    rows="$rows$row"$'\n'
  done < <(printf '%s' "$sites" | jq -c '.[]')
  printf '%s' "$rows" | jq -s "$GHPAGES_JQ"'
    map(. as $x | $x.site as $s | ($x.runs[0] // null) as $new
      | ([$x.runs[] | select(.conclusion == "success")][0] // {}) as $live
      | ($s.repo | split("/")) as $rp
      | {name:$rp[1], id:$s.repo, auto:false, deployable:true, paused:false, repo:$s.repo, ref:$s.ref,
         domain:(($x.pages.cname // (($x.pages.html_url // "") | sub("^https?://";"") | sub("/.*$";""))) | if . == "" then null else . end),
         url:($x.pages.html_url // null),
         dashboardUrl:("https://github.com/" + $s.repo + "/actions/workflows/" + $s.workflow),
         lastAt:($new.created_at | t), lastState:($new | if . then state else null end),
         lastSha:($live.head_sha // null), lastMsg:(($live.head_commit.message // null) | if . then split("\n")[0] else null end),
         fetchError:($x.err // null),
         fetchWarn:(if $x.err == null and $x.pages == null then "GitHub Pages is not readable for this repository (not enabled, or the token lacks Pages: read)" else null end),
         phase:(if $x.err then null else ($new | phase) end), latestId:($new.id // null)})
    | sort_by(.name | ascii_downcase)'
}

ghpages_off() { die "GitHub Pages cannot turn auto-deploy off from here: remove the push trigger from the workflow file"; }
ghpages_rollback() { die "GitHub Pages cannot roll back from here: re-run an older successful run of the workflow in GitHub (Actions)"; }
ghpages_logs() { die "GitHub Pages cannot show logs from here: open the run in GitHub (deploys ghpages url $1 --dashboard)"; }

# ghpages_deploy_json <site>: dispatch the workflow on the site's branch, then look for the new run.
ghpages_deploy_json() {
  local name="${1:-}" site repo wf ref lock="" prev new="" n=0 runs pg u
  shift || true
  while [ $# -gt 0 ]; do
    case "$1" in
      --preview) die "GitHub Pages cannot deploy a preview from here" ;;
      --sha) die "GitHub Pages cannot deploy a given commit from here: a workflow dispatch runs on a branch" ;;
      --no-cache) die "GitHub Pages cannot build without a cache from here" ;;
      "") ;;
      *) die "Unknown option $1. Usage: deploy-json <owner/repo>" ;;
    esac; shift
  done
  site="$(ghpages_site "$name")" || die "GitHub Pages: \"$name\" is not one of your sites (deploys ghpages add owner/repo)"
  repo="$(printf '%s' "$site" | jq -r .repo)"; wf="$(printf '%s' "$site" | jq -r .workflow)"; ref="$(printf '%s' "$site" | jq -r .ref)"
  if declare -F start_lock >/dev/null; then lock="$(start_lock "ghpages-$repo")" || exit 1; fi
  runs="$(ghpages_runs "$site" 5)" || { rm -f "$lock"; die "GitHub: could not read the runs of $repo"; }
  prev="$(printf '%s' "$runs" | jq -r '[.[].id] | max // 0')"
  ghpages_call POST "/repos/$repo/actions/workflows/$wf/dispatches" "$(jq -nc --arg r "$ref" '{ref:$r}')" >/dev/null \
    || { rm -f "$lock"; die "GitHub did not start $wf on $ref for $repo (does the workflow have \`on: workflow_dispatch\`, and may the token run workflows?)"; }
  while [ "$n" -lt "${DEPLOYS_GHPAGES_POLLS:-6}" ]; do
    new="$(ghpages_runs "$site" 5 2>/dev/null | jq -c --argjson p "$prev" '[.[] | select(.id > $p)] | sort_by(.id) | last // empty')" || new=""
    [ -z "$new" ] || break
    n=$((n + 1)); sleep 3
  done
  pg="$(ghpages_call GET "/repos/$repo/pages" 2>/dev/null | jq -r '.html_url // empty' 2>/dev/null)" || pg=""
  u="${pg:-https://${repo%%/*}.github.io/${repo#*/}/}"
  if [ -z "$new" ]; then
    echo "GitHub: the dispatch is accepted but its run is not listed yet; see: deploys ghpages latest $repo" >&2
    jq -nc --arg u "$u" '{id:null, url:$u, state:"queued", phase:"queued"}'
  else
    printf '%s' "$new" | jq -c --arg u "$u" "$GHPAGES_JQ"'{id:(.id | tostring), url:$u, state:state, phase:(phase // "queued"), dashboardUrl:(.html_url // null)}'
  fi
}

ghpages_status() {
  local name="$1" d="${2:-}" site repo r
  case "$d" in ''|*[!0-9]*) die "Usage: status <owner/repo> <run id>" ;; esac
  site="$(ghpages_site "$name")" || die "GitHub Pages: \"$name\" is not one of your sites"
  repo="$(printf '%s' "$site" | jq -r .repo)"
  r="$(ghpages_call GET "/repos/$repo/actions/runs/$d")" || die "GitHub: could not read run $d"
  printf '%s' "$r" | jq -e 'type == "object" and has("id") and has("status")' >/dev/null 2>&1 || die "GitHub answered without a run for $d"
  printf '%s\n' "$r" | jq -r "$GHPAGES_JQ"'line'
}
ghpages_cli_status() { local s; s="$(ghpages_site "$1")" || die "GitHub Pages: \"$1\" is not one of your sites"; ghpages_call GET "/repos/$(printf '%s' "$s" | jq -r .repo)/actions/runs/$2"; }

ghpages_latest() {
  local site runs
  site="$(ghpages_site "$1")" || die "GitHub Pages: \"$1\" is not one of your sites"
  runs="$(ghpages_runs "$site" 5)" || die "GitHub: could not read the runs of $1"
  printf '%s' "$runs" | jq -r "$GHPAGES_JQ"'.[0] // null | line'
}
ghpages_cli_latest() { local s; s="$(ghpages_site "$1")" || die "GitHub Pages: \"$1\" is not one of your sites"; ghpages_runs "$s" 1 | jq '.[0] // null'; }

ghpages_cancel() {
  local name="$1" d="${2:-}" site repo
  case "$d" in ''|*[!0-9]*) die "GitHub Pages: \"$d\" is not a run id" ;; esac
  site="$(ghpages_site "$name")" || die "GitHub Pages: \"$name\" is not one of your sites"
  repo="$(printf '%s' "$site" | jq -r .repo)"
  ghpages_call POST "/repos/$repo/actions/runs/$d/cancel" >/dev/null || die "GitHub: could not cancel run $d"
  jq -nc --arg d "$d" '{id:$d, state:"cancelling", phase:"canceled", message:"GitHub: run \($d) is being canceled"}'
}

ghpages_url() {
  local site repo u
  site="$(ghpages_site "$1")" || die "GitHub Pages: \"$1\" is not one of your sites"
  repo="$(printf '%s' "$site" | jq -r .repo)"
  if [ "${2:-}" = --dashboard ]; then echo "https://github.com/$repo/actions/workflows/$(printf '%s' "$site" | jq -r .workflow)"; return 0; fi
  u="$(ghpages_call GET "/repos/$repo/pages" 2>/dev/null | jq -r '.html_url // empty' 2>/dev/null)" || u=""
  echo "${u:-https://${repo%%/*}.github.io/${repo#*/}/}"
}

# deploys ghpages add owner/repo [workflow.yml] [branch]  /  remove owner/repo
ghpages_write() { local f="$1" t; t="$(mktemp "$f.XXXXXX")" && cat > "$t" && chmod 600 "$t" && mv -f "$t" "$f"; }
ghpages_cli_add() {
  local repo="${1:-}" wf="${2:-pages.yml}" ref="${3:-main}" f cur
  [ -n "$repo" ] || die "Usage: deploys ghpages add owner/repo [workflow.yml] [branch]"
  ghpages_repo_ok "$repo" || die "\"$repo\" is not owner/name"
  ghpages_wf_ok "$wf" || die "\"$wf\" is not a workflow file name (for example pages.yml)"
  ghpages_ref_ok "$ref" || die "\"$ref\" is not a branch name"
  f="$(ghpages_file)"; mkdir -p "$(dirname "$f")"
  cur='[]'; [ ! -s "$f" ] || cur="$(jq -c 'if type == "array" then . else [] end' "$f" 2>/dev/null)" || cur='[]'
  printf '%s' "$cur" | jq --arg r "$repo" --arg w "$wf" --arg f "$ref" '(map(select(.repo != $r))) + [{repo:$r, workflow:$w, ref:$f}]' | ghpages_write "$f"
  echo "GitHub Pages: $repo added (workflow $wf on $ref). The workflow needs \`on: workflow_dispatch\`."
}
ghpages_cli_remove() {
  local repo="${1:-}" f
  [ -n "$repo" ] || die "Usage: deploys ghpages remove owner/repo"
  f="$(ghpages_file)"
  [ -s "$f" ] && jq -e --arg r "$repo" 'any(.[]?; .repo == $r)' "$f" >/dev/null 2>&1 || die "GitHub Pages: $repo is not in $f (a site from DEPLOYS_GHPAGES_SITES is removed there)"
  jq --arg r "$repo" 'map(select(.repo != $r))' "$f" | ghpages_write "$f"
  echo "GitHub Pages: $repo removed."
}

ghpages_setup_hint() { echo "deploys ghpages add owner/repo, then: pbpaste | deploys ghpages set-key   (or set GITHUB_PAGES_TOKEN)"; }

ghpages_set_key() {
  local key=""
  if [ -t 0 ]; then IFS= read -rs key || true; echo >&2; else IFS= read -r key || true; fi
  key="$(printf "%s" "$key" | tr -d "\r" | sed "s/^[[:space:]]*//; s/[[:space:]]*\$//")"
  [ -n "$key" ] || die "Pipe the token in: pbpaste | deploys ghpages set-key"
  case "$key" in *\'*|*\"*|*\\*|*[[:space:]]*|*[[:cntrl:]]*) die "That does not look like a GitHub token" ;; esac
  ( GITHUB_PAGES_TOKEN="$key"; key_of() { printf '%s' "$GITHUB_PAGES_TOKEN"; }; ghpages_call GET /rate_limit >/dev/null ) || die "GitHub did not accept that token; nothing was saved"
  printf 'add-generic-password -U -a %s -s %s -w %s\n' "${USER:-$(id -un)}" "$GHPAGES_KEYCHAIN" "$key" | security -i >/dev/null \
    || die "The token works, but could not be saved in the keychain"
  echo "GitHub token saved and working."
}

ghpages_doctor() {
  local src="missing" ok=false err="" n=0 e rl=null out
  if [ -n "${GITHUB_PAGES_TOKEN:-}" ] || [ -n "${GH_TOKEN:-}" ] || [ -n "${GITHUB_TOKEN:-}" ]; then src="env"
  elif security find-generic-password -a "${USER:-$(id -un)}" -s "$GHPAGES_KEYCHAIN" >/dev/null 2>&1; then src="keychain"; fi
  n="$(ghpages_sites 2>/dev/null | jq 'length' 2>/dev/null)" || n=0
  if [ "$src" != missing ]; then
    e="$(mktemp)"
    if out="$(ghpages_call GET /rate_limit 2>"$e")"; then
      ok=true
      rl="$(printf '%s' "$out" | jq -c '.resources.core | if (.remaining | type) == "number" then {remaining, resetAt:(.reset // null)} else null end' 2>/dev/null)" || rl=null
    else err="$(tail -n 1 "$e")"; fi
    rm -f "$e"
  fi
  jq -n --arg src "$src" --argjson ok "$ok" --arg err "$err" --argjson n "${n:-0}" --argjson rl "${rl:-null}" \
    '{provider:"ghpages", key:$src, keyOk:$ok, error:(if $err == "" then null else $err end), sites:$n, expiresAt:null, rateLimit:$rl}'
}
