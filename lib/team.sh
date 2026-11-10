# shellcheck shell=bash
# Team mode for `deploys`, without a server: a shared config in each repo, observers, and the
# two-person rule. Sourced by `deploys` (it needs CONFIG_DIR, REPOS, die and mtime from there).
# See docs/TEAM.md. Nothing here starts a build; it only decides whether one may start.
#
# The shared file is deploy-center.json (or .deploy-center.json) at a repo root, on the default
# branch, read with `gh api .../contents` and kept for ten minutes in $CONFIG_DIR/team-cache.
# Merge order, lowest first: what the platform says < the repo file's defaults < the repo file's
# entry for the project < this Mac's files (vercel-repos.json, ignored.json, window.json,
# overrides.json). Two values this Mac can only tighten, never loosen: `approvals` (a local
# number counts only when it is higher) and `observers` (all lists are joined). --force is the
# way past a missing approval, and it is journaled.

TEAM_CACHE="$CONFIG_DIR/team-cache"
TEAM_TTL="${DEPLOYS_TEAM_TTL:-600}"
TEAM_REPOS="$CONFIG_DIR/team-repos"
TEAM_OVERRIDES="$CONFIG_DIR/overrides.json"
TEAM_JOURNAL="$CONFIG_DIR/team-journal.jsonl"

# Reads one repo's shared file into the cache. Runs under xargs, so it uses nothing but its
# arguments: <owner/repo> <cache dir> <ttl seconds> [cache-only].
# The cache holds the file ({config}), "no file here" ({none}, after a 404 on both names), or a
# file that is not a JSON object ({error}). A network error or a rate limit is not cached: the
# old copy stays (and reads as stale), or a .err note says why there is none.
team_fetch_one() {
  local repo="$1" dir="$2" ttl="$3" only="${4:-}" f now age p out err
  f="$dir/$(printf '%s' "$repo" | sed 's#/#__#').json"; now="$(date +%s)"
  if [ -f "$f" ]; then
    age=$(( now - $(mtime "$f") ))
    [ "$age" -lt "$ttl" ] && return 0
  fi
  [ -z "$only" ] || return 0
  command -v gh >/dev/null 2>&1 || return 0
  err="$(mktemp)"
  for p in deploy-center.json .deploy-center.json; do
    if out="$(gh api "repos/$repo/contents/$p" 2>"$err")"; then
      printf '%s' "$out" | jq -c --arg r "$repo" --arg p "$p" --argjson now "$now" '
          {repo:$r, path:$p, sha:(.sha // null), fetchedAt:$now}
          + ((try (.content // "" | gsub("\\s"; "") | @base64d | fromjson) catch null) as $c
             | if ($c | type) == "object" then {config:$c} else {error:"\($p) is not a JSON object"} end)' \
        > "$f.$$" 2>/dev/null && mv "$f.$$" "$f" && rm -f "$f.err"
      rm -f "$f.$$" "$err"; return 0
    fi
    grep -q 'HTTP 404' "$err" || break
    : > "$err"
  done
  if [ -s "$err" ]; then
    grep -v '^[[:space:]]*$' "$err" | tail -n 1 | cut -c1-200 > "$f.err"
  else
    printf '{"repo":"%s","none":true,"fetchedAt":%s}\n' "$repo" "$now" > "$f"; rm -f "$f.err"
  fi
  rm -f "$err"
}
export -f team_fetch_one

# The repos whose shared file counts here: every remembered Vercel repo, the repos added with
# `deploys team add`, and any given as arguments (a Render service's repo, for one deploy).
team_repo_list() {
  { jq -r '.[] | select(.org and .repo) | "\(.org)/\(.repo)"' "$REPOS" 2>/dev/null
    cat "$TEAM_REPOS" 2>/dev/null
    jq -r '.projects // {} | .[] | .repo // empty' "$TEAM_OVERRIDES" 2>/dev/null
    printf '%s\n' "$@"
  } | grep -E '^[A-Za-z0-9_.-]+/[A-Za-z0-9_.-]+$' | sort -u
}

# The shared files of those repos, as a JSON array. DEPLOYS_NO_GITHUB (or no gh) reads the
# cache only; DEPLOYS_TEAM_REFRESH=1 reads GitHub again whatever the cache's age.
team_sources() {
  local only="" ttl="$TEAM_TTL" list r f
  mkdir -p "$TEAM_CACHE"
  [ -z "${DEPLOYS_NO_GITHUB:-}" ] || only=1
  [ "${DEPLOYS_TEAM_REFRESH:-}" != 1 ] || ttl=0
  list="$(team_repo_list "$@")"
  if [ -n "$list" ]; then
    printf '%s\n' "$list" | xargs -P 8 -n 1 bash -c 'team_fetch_one "$4" "$1" "$2" "$3"' _ "$TEAM_CACHE" "$ttl" "$only" 2>/dev/null || true
  fi
  while IFS= read -r r; do
    [ -n "$r" ] || continue
    f="$TEAM_CACHE/$(printf '%s' "$r" | sed 's#/#__#').json"
    if [ -s "$f" ]; then cat "$f"; echo
    elif [ -s "$f.err" ]; then jq -nc --arg r "$r" --rawfile e "$f.err" '{repo:$r, error:("could not read: " + ($e | rtrimstr("\n")))}'; fi
  done <<< "$list" | jq -s --argjson now "$(date +%s)" --argjson ttl "$TEAM_TTL" \
    'map(. + {stale:(((.fetchedAt // 0) + $ttl) < $now)})'
}

# The GitHub login of whoever runs this, kept for an hour. Empty when gh cannot tell.
team_me() {
  local f="$TEAM_CACHE/me"; mkdir -p "$TEAM_CACHE"
  # Per gh login: after `gh auth switch` (which rewrites gh's hosts.yml) or with another GH_TOKEN,
  # the old name must not count. Without asking gh: a hash of the token variables (never the
  # token itself), and the age of hosts.yml.
  local key hosts; key="$(printf '%s' "${GH_TOKEN:-}${GITHUB_TOKEN:-}" | shasum 2>/dev/null | cut -c1-12)" || key=""
  [ -z "$key" ] || f="$TEAM_CACHE/me-$key"
  hosts="${GH_CONFIG_DIR:-${XDG_CONFIG_HOME:-$HOME/.config}/gh}/hosts.yml"
  if [ -s "$f" ] && [ $(( $(date +%s) - $(mtime "$f") )) -lt 3600 ] && ! [ "$hosts" -nt "$f" ]; then cat "$f"; return; fi
  if [ -z "${DEPLOYS_NO_GITHUB:-}" ] && command -v gh >/dev/null 2>&1; then
    local me; me="$(gh api user --jq .login 2>/dev/null | head -n 1)"
    if [ -n "$me" ]; then printf '%s' "$me" > "$f"; echo "$me"; return; fi
  fi
  cat "$f" 2>/dev/null || true
}

# The merge itself. Every value comes with where it came from: {value, from}.
TEAM_MERGE='
def cf: [$files[] | select(.config)];
def src: "\(.repo):\(.path)";
def userrepo($n): ($ov.projects[$n].repo // null) // ($repos[$n] | if . != null and .org and .repo then "\(.org)/\(.repo)" else null end);
def named($n): [cf[] | select(((.config.projects // {})[$n] != null) or ((.config.ignored // []) | index($n)))];
# The file that speaks for a project: the one in the repo it deploys from, else the first naming it.
def fileof($n):
  (userrepo($n) // (named($n)[0] | if . then ((.config.projects // {})[$n].repo // .repo) else null end) // ($extra[$n].repo // null)) as $r
  | ([cf[] | select(.repo == $r)][0]) // named($n)[0] // null;
def keep: with_entries(select(.key as $k | ["repo","branch","health","window","approvals","ignored","platform"] | index($k)));
def layers($n): fileof($n) as $f | [
  ($extra[$n] // null | if . then {from:"platform", v:(keep | with_entries(select(.value != null)))} else empty end),
  (if $f then {from:($f | src), v:($f.config | {window, approvals, health} | with_entries(select(.value != null)))} else empty end),
  (if $f then {from:($f | src), v:(
      (if (($f.config.ignored // []) | index($n)) then {ignored:true} else {} end)
      + (if ($f.config.projects // {})[$n] then {repo:$f.repo} + ($f.config.projects[$n] | keep) else {} end))} else empty end),
  ($repos[$n] | if . != null and .repo then {from:"vercel-repos.json", v:({repo:"\(.org)/\(.repo)"} + (if .ref then {branch:.ref} else {} end))} else empty end),
  (if ($ign | index($n)) then {from:"ignored.json", v:{ignored:true}} else empty end),
  (if $win != null then {from:"window.json", v:{window:$win}} else empty end),
  ($ov | {window, approvals, health} | with_entries(select(.value != null)) | if length > 0 then {from:"overrides.json", v:.} else empty end),
  (($ov.projects // {})[$n] // null | if . then {from:"overrides.json", v:keep} else empty end)];
def userfile: . as $f | ["vercel-repos.json","ignored.json","window.json","overrides.json"] | index($f);
def resolve($n):
  reduce (layers($n)[]) as $l ({approvals:{value:0, from:"default"}, ignored:{value:false, from:"default"}};
    reduce ($l.v | to_entries[]) as $e (.;
      if $e.key == "approvals" and ($l.from | userfile) then
        # This Mac can only tighten it: a lower number here does not count (--force is for that).
        (if (($e.value // 0) > .approvals.value) then .approvals = {value:$e.value, from:$l.from} else . end)
      else .[$e.key] = {value:$e.value, from:$l.from} end));
([cf[] | (.config.projects // {} | keys[]), (.config.ignored // [])[]] + ($repos | keys) + ($ign)
   + (($ov.projects // {}) | keys) + ($extra | keys) | unique) as $names
| (reduce ((cf[] as $f | ($f.config.observers // [])[] | {login:., from:($f | src)}),
           (($ov.observers // [])[] | {login:., from:"overrides.json"})) as $o
     ({}; if .[$o.login] then . else .[$o.login] = $o.from end)) as $obs
| ($obs | to_entries | map(select((.key | ascii_downcase) == ($me | ascii_downcase))) | .[0].value // null) as $meObs
| {me:(if $me == "" then null else $me end),
   # source: env, file or team, for the app (the from text is for people and may change).
   readonly:(if $ro != "" then {value:true, from:$ro, source:(if ($ro | startswith("DEPLOYS_READONLY")) then "env" else "file" end)}
             elif $meObs then {value:true, from:"observers in \($meObs)", source:"team"}
             else {value:false, from:"default", source:null} end),
   observers:{value:($obs | keys), from:$obs},
   groups:(reduce ((cf[] as $f | ($f.config.groups // {}) | to_entries[] | {k:.key, v:.value, from:($f | src)}),
                   (($ov.groups // {}) | to_entries[] | {k:.key, v:.value, from:"overrides.json"})) as $g
             ({}; .[$g.k] = {value:$g.v, from:$g.from})),
   projects:(reduce $names[] as $n ({}; .[$n] = resolve($n))),
   sources:[$files[] | {repo, path:(.path // null), sha:(.sha // null), fetchedAt:(.fetchedAt // null),
                        found:(.config != null), stale, error:(.error // null)}],
   configDir:$dir}'

# The effective config as JSON. Arguments: extra "name=owner/repo@branch@platform" entries for
# projects this Mac knows only from the platform (a Render service), for one deploy.
team_effective() {
  local extra='{}' e n rest repos=()
  for e in "$@"; do
    n="${e%%=*}"; rest="${e#*=}"
    extra="$(jq -c --arg n "$n" --arg r "${rest%%@*}" --arg rest "$rest" \
      '($rest | split("@")) as $p | .[$n] = {repo:(if $r == "" then null else $r end), branch:($p[1] // null | if . == "" then null else . end), platform:($p[2] // null)}' <<< "$extra")"
    [ -z "${rest%%@*}" ] || repos+=("${rest%%@*}")
  done
  local files ign='[]' win=null ov='{}'
  files="$(team_sources ${repos[@]+"${repos[@]}"})"
  [ -s "$CONFIG_DIR/ignored.json" ] && ign="$(jq -c 'if type == "array" then . else [] end' "$CONFIG_DIR/ignored.json" 2>/dev/null || echo '[]')"
  [ -s "$CONFIG_DIR/window.json" ] && win="$(jq -c . "$CONFIG_DIR/window.json" 2>/dev/null || echo null)"
  [ -s "$TEAM_OVERRIDES" ] && ov="$(jq -c 'if type == "object" then . else {} end' "$TEAM_OVERRIDES" 2>/dev/null || echo '{}')"
  jq -n --argjson files "$files" --slurpfile repos "$REPOS" --argjson ign "$ign" --argjson win "$win" \
    --argjson ov "$ov" --argjson extra "$extra" --arg ro "$(readonly_from)" --arg me "$(team_me)" \
    --arg dir "$CONFIG_DIR" '$repos[0] as $repos | '"$TEAM_MERGE"
}

# vercel-repos.json as the commands read it: the remembered repos, and below them the projects a
# shared file maps (so a new teammate can deploy without disconnecting anything first).
team_repos_json() {
  team_effective | jq --slurpfile r "$REPOS" '(.projects | to_entries
      | map(select(.value.repo.value and ((.value.platform.value // "vercel") == "vercel"))
            | {key, value:({org:(.value.repo.value | split("/")[0]), repo:(.value.repo.value | split("/")[1]),
                            ref:(.value.branch.value // "main"), shared:.value.repo.from})})
      | from_entries) + $r[0]'
}

# Names the effective config leaves out of `changed` and `deploy-changed`.
team_ignored() { team_effective | jq -c '[.projects | to_entries[] | select(.value.ignored.value == true) | .key]'; }

# Observer by the shared lists (cache only, no network): prints where it comes from, or nothing.
team_observer_from() {
  DEPLOYS_NO_GITHUB=1 team_effective 2>/dev/null | jq -r 'select(.readonly.value and (.readonly.from | startswith("observers"))) | .readonly.from' 2>/dev/null || true
}

# A group's members in deploy order, or nothing when the name is no group.
team_group() { team_effective | jq -r --arg g "$1" '.groups[$g].value // empty | if type == "array" then .[] else (.order // .projects // [])[] end'; }

team_journal() {  # team_journal <json object>
  mkdir -p "$CONFIG_DIR"
  jq -c --argjson at "$(date +%s)" '{at:$at} + .' <<< "$1" >> "$TEAM_JOURNAL"
}

# ---------- the two-person rule ----------

# Approvals of <sha> in <owner/repo> by anyone but <me>, as JSON {have:[{user, via, url}], prs:[...]}.
# Counted: an APPROVED review (the newest review of that person) on a PR the commit belongs to,
# and a label deploy-approved-by:<user> on that PR, or on an open issue that names the commit
# (its first 7 characters), added by <user> themself (read from the issue's events: anyone may
# add a label with someone else's name, and that does not count).
team_approvals() {
  local repo="$1" sha="$2" me="$3" prs issues have='[]' n
  prs="$(gh api "repos/$repo/commits/$sha/pulls" 2>/dev/null | jq -c '[.[] | {number, url:.html_url, labels:[.labels[]?.name], head:(.head.sha // null)}]' 2>/dev/null)" || prs='[]'
  [ -n "$prs" ] || prs='[]'
  # Reviews: the newest state of each person who is not the deployer. An approval counts for what
  # it saw: a review of an older head (pushed to after the approval) does not approve the PR's
  # final content. (Checked when GitHub names both commits.)
  local head
  for n in $(jq -r '.[].number' <<< "$prs"); do
    head="$(jq -r --argjson n "$n" '[.[] | select(.number == $n)][0].head // ""' <<< "$prs")"
    have="$(gh api --paginate "repos/$repo/pulls/$n/reviews" 2>/dev/null | jq -s -c --argjson have "$have" --arg me "$me" --argjson n "$n" --arg head "$head" \
      '[.[][]? | select(.user.login and ((.user.login | ascii_downcase) != ($me | ascii_downcase)) and (.state != "COMMENTED"))]
       | group_by(.user.login) | map(max_by(.submitted_at // "")) | map(select(.state == "APPROVED"))
       | map(select($head == "" or .commit_id == null or .commit_id == $head))
       | $have + map({user:.user.login, via:"review on PR #\($n)", url:(.html_url // null)})' 2>/dev/null || echo "$have")"
  done
  # Labels: on those PRs, and on open issues that name the commit.
  issues="$(gh api --paginate "repos/$repo/issues?state=open&per_page=100" 2>/dev/null | jq -s -c --arg s "${sha:0:7}" \
    '[add // [] | .[] | select(((.title // "") + " " + (.body // "")) | contains($s)) | {number, url:.html_url, labels:[.labels[]?.name]}]' 2>/dev/null)" || issues='[]'
  [ -n "$issues" ] || issues='[]'
  local item num lbl who by
  while IFS=$'\t' read -r num item lbl; do
    [ -n "$lbl" ] || continue
    who="${lbl#deploy-approved-by:}"
    [ "$(printf '%s' "$who" | tr '[:upper:]' '[:lower:]')" != "$(printf '%s' "$me" | tr '[:upper:]' '[:lower:]')" ] || continue
    by="$(gh api --paginate "repos/$repo/issues/$num/events" 2>/dev/null \
      | jq -s -r --arg l "$lbl" '[.[][]? | select(.event == "labeled" and .label.name == $l)] | last | .actor.login // empty' 2>/dev/null)"
    [ "$(printf '%s' "$by" | tr '[:upper:]' '[:lower:]')" = "$(printf '%s' "$who" | tr '[:upper:]' '[:lower:]')" ] || continue
    have="$(jq -c --arg u "$who" --arg via "label on #$num" --arg url "$item" '. + [{user:$u, via:$via, url:$url}]' <<< "$have")"
  done < <(jq -s -r 'add | unique_by(.number) | .[] | . as $i | .labels[] | select(startswith("deploy-approved-by:")) | "\($i.number)\t\($i.url)\t\(.)"' <(echo "$prs") <(echo "$issues"))
  jq -n -c --argjson have "$have" --argjson prs "$prs" '{have:($have | unique_by(.user | ascii_downcase)), prs:[$prs[] | {number, url}]}'
}

# Whether <project> may go live, and with which commit. Prints the commit to deploy (pinned, so
# what was approved is what goes live), or nothing when no approval is needed; stops with what
# is missing otherwise. DEPLOYS_FORCE_REASON skips a missing approval and is journaled.
# team_gate <platform> <project> <owner/repo> <branch> [<sha>]
team_gate() {
  local plat="$1" p="$2" repo="$3" ref="$4" sha="${5:-}" eff need me a n
  eff="$(team_effective "$p=$repo@$ref@$plat")" || die "Could not work out the team config for $p, so its approvals are unknown (see above)"
  me="$(jq -r '.me // ""' <<< "$eff")"
  if [ "$(jq -r '.readonly.value' <<< "$eff")" = true ]; then
    die "Observer mode ($(jq -r '.readonly.from' <<< "$eff")): $me may look, not deploy. Deploying $p is refused."
  fi
  need="$(jq -r --arg p "$p" '.projects[$p].approvals.value // 0' <<< "$eff")"
  local from; from="$(jq -r --arg p "$p" '.projects[$p].approvals.from' <<< "$eff")"
  # Only a whole number counts. "two", true or 1.5 must not read as "no approval needed": the rule
  # stays shut until the file says what it means (--force does not get past a broken file either).
  case "$need" in
    ''|*[!0-9]*) die "\"approvals\" for $p is \"$need\" ($from): it must be a whole number (0, 1, 2 …). Fix the file; until then $p is not deployed." ;;
  esac
  [ "$((10#$need))" -ge 1 ] || { [ -z "$sha" ] || echo "$sha"; return 0; }
  need="$((10#$need))"
  command -v gh >/dev/null 2>&1 || die "$p needs $need approval(s) ($from), and checking them needs the gh CLI. Install it, or: --force \"reason\""
  [ -n "$repo" ] || die "$p needs $need approval(s) ($from), but no GitHub repo is known for it (approvals are read from GitHub; a GitLab repo cannot have them yet)"
  [ -n "$me" ] || die "$p needs $need approval(s) ($from), but gh cannot tell who you are. Run: gh auth login"
  if [ -z "$sha" ]; then
    sha="$(gh api "repos/$repo/commits/${ref:-main}" --jq .sha 2>/dev/null | head -n 1)"
    [ -n "$sha" ] || die "$p needs $need approval(s), but the head of $repo ${ref:-main} could not be read"
  fi
  a="$(team_approvals "$repo" "$sha" "$me")"
  n="$(jq '.have | length' <<< "$a")"
  if [ "$n" -ge "$need" ]; then
    team_journal "$(jq -c --arg p "$p" --arg pl "$plat" --arg sha "$sha" --arg me "$me" --argjson need "$need" \
      '{kind:"approved", project:$p, platform:$pl, sha:$sha, by:$me, need:$need, approvals:.have}' <<< "$a")"
    echo "$p: approved by $(jq -r '[.have[] | "\(.user) (\(.via))"] | join(", ")' <<< "$a")" >&2
    echo "$sha"; return 0
  fi
  if [ -n "${DEPLOYS_FORCE_REASON:-}" ]; then
    team_journal "$(jq -c --arg p "$p" --arg pl "$plat" --arg sha "$sha" --arg me "$me" --argjson need "$need" --arg why "$DEPLOYS_FORCE_REASON" \
      '{kind:"forced", project:$p, platform:$pl, sha:$sha, by:$me, need:$need, approvals:.have, reason:$why}' <<< "$a")"
    echo "$p: $n of $need approval(s); deploying anyway (--force: $DEPLOYS_FORCE_REASON). Written to $TEAM_JOURNAL" >&2
    echo "$sha"; return 0
  fi
  # The verdict comes last: the app shows the end of a message (the whole of it is in its log).
  {
    echo "Approvals for $p at ${sha:0:7} ($from):"
    if [ "$n" -gt 0 ]; then echo "  Found $n: $(jq -r '[.have[] | "\(.user) (\(.via))"] | join(", ")' <<< "$a")"; else echo "  Found none. Your own reviews and labels do not count."; fi
    echo "  Any of these counts:"
    jq -r '.prs[] | "    - an approving review on PR #\(.number) (\(.url))"' <<< "$a"
    echo "    - the label deploy-approved-by:<their login> on $(jq -r 'if (.prs | length) > 0 then "that PR, or " else "" end' <<< "$a")an open issue in $repo that names ${sha:0:7}, added by that person"
    echo "  Or, deliberately: deploys deploy $p --force \"reason\" (written to the team journal)"
    echo "Error: $p needs $need approval(s) from someone other than you ($me) before ${sha:0:7} goes live."
  } >&2
  exit 1
}
