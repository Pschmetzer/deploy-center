#!/bin/bash
# digest.sh — one daily digest of what waits to be deployed, per project: how many commits came
# from agents and how many from people, the pull requests, and what to check first. Deploys nothing.
#
#   integrations/digest/digest.sh                       print the digest (Markdown)
#   integrations/digest/digest.sh --out digest.md       also write it to a file
#   integrations/digest/digest.sh --json                print it as JSON instead
#   integrations/digest/digest.sh --issue               open or update the issue "Deploys waiting – <date>"
#   integrations/digest/digest.sh --post                send it to DEPLOYS_NOTIFY_URL, with an approve button
#   integrations/digest/digest.sh --issue --post --dry-run    show what would be sent, change nothing
#
# Env:
#   DEPLOYS_DIGEST_REPO      owner/repo that holds approve-deploy.yml (and gets the issue). Without
#                            it the message has no button and --issue refuses.
#   DEPLOYS_DIGEST_WORKFLOW  the workflow file in that repo (default approve-deploy.yml)
#   DEPLOYS_NOTIFY_URL, DEPLOYS_NOTIFY_FORMAT   as for notify.sh (the URL is a secret)
#   DEPLOYS_AGENT_AUTHORS, DEPLOYS_AGENT_LABELS who counts as an agent (see classify.sh)
#   DEPLOYS                  the CLI to call (default: deploys on PATH)
#   GH_TOKEN                 for gh: reads pull requests, writes the issue
#   glab                     reads merge requests of GitLab repos (logged in, or GITLAB_TOKEN)
#
# "Today" is the UTC day. The approval list is the projects waiting when the digest was made;
# a deploy starts each of them at its branch head at the moment of approval.
set -euo pipefail
DEPLOYS="${DEPLOYS:-deploys}"
here="$(cd "$(dirname "$0")" && pwd)"
# shellcheck source=classify.sh
. "$here/classify.sh"
# shellcheck source=../lib/post.sh
. "$here/../lib/post.sh"

out="" json=0 issue=0 post=0 dry=0
while [ $# -gt 0 ]; do
  case "$1" in
    --out) out="${2:?--out <file>}"; shift ;;
    --json) json=1 ;;
    --issue) issue=1 ;;
    --post) post=1 ;;
    --dry-run) dry=1 ;;
    -h|--help) sed -n '2,/^set -euo/p' "$0" | sed '$d; s/^# \{0,1\}//'; exit 0 ;;
    *) echo "Unknown option $1 (see --help)" >&2; exit 1 ;;
  esac
  shift
done
repo="${DEPLOYS_DIGEST_REPO:-}"
workflow="${DEPLOYS_DIGEST_WORKFLOW:-approve-deploy.yml}"
url="${DEPLOYS_NOTIFY_URL:-}"
if [ -n "$repo" ]; then
  [[ "$repo" =~ ^[A-Za-z0-9_.-]+/[A-Za-z0-9_.-]+$ ]] || { echo "DEPLOYS_DIGEST_REPO must be owner/repo" >&2; exit 1; }
  [[ "$workflow" =~ ^[A-Za-z0-9_.-]+\.ya?ml$ ]] || { echo "DEPLOYS_DIGEST_WORKFLOW must be a file name like approve-deploy.yml" >&2; exit 1; }
fi
[ "$issue" = 0 ] || [ -n "$repo" ] || { echo "--issue needs DEPLOYS_DIGEST_REPO (owner/repo)" >&2; exit 1; }
[ "$post" = 0 ] || [ "$dry" = 1 ] || [ -n "$url" ] || { echo "--post needs DEPLOYS_NOTIFY_URL (or --dry-run)" >&2; exit 1; }

tmp="$(mktemp -d)"; trap 'rm -rf "$tmp"' EXIT
# The day in the title: DEPLOYS_TZ (e.g. Europe/Berlin), default UTC.
tz="${DEPLOYS_TZ:-UTC}"
[[ "$tz" =~ ^[A-Za-z0-9/_+-]+$ ]] || { echo "DEPLOYS_TZ must be a zone name like Europe/Berlin" >&2; exit 1; }
today="$(TZ="$tz" date +%Y-%m-%d)"
title="Deploys waiting – $today"

# --- what waits: deploys changed, then per project its commits and pull requests ---
rc=0; list="$("$DEPLOYS" changed --json </dev/null 2>"$tmp/changed.err")" || rc=$?
echo "$list" | jq -e 'type == "array"' >/dev/null 2>&1 || { cat "$tmp/changed.err" >&2; echo "deploys changed --json did not answer a list" >&2; exit 1; }
partial=false; [ "$rc" = 0 ] || partial=true

has_gh=0; command -v gh >/dev/null 2>&1 && has_gh=1
has_glab=0; command -v glab >/dev/null 2>&1 && has_glab=1
has_risk=0; "$DEPLOYS" --help 2>/dev/null | grep -qE '^[[:space:]]*deploys risk' && has_risk=1

# The facts of one pull request (GitHub) or merge request (GitLab), read once per repo and number.
# A repo is owner/name on GitHub and host/group[/sub]/name elsewhere, as deploys writes it. Any
# host but github.com is read as GitLab, with glab (logged in, or GITLAB_TOKEN).
pr_facts() {
  local r="$1" n="$2" f host="" path="$1"
  f="$tmp/pr_${1////_}_$2.json"
  if [ ! -f "$f" ]; then
    case "${r%%/*}" in *.*) host="${r%%/*}"; path="${r#*/}" ;; esac
    [ "$host" != github.com ] || host=""
    if [ -z "$host" ]; then
      { [ "$has_gh" = 1 ] && gh api "repos/$path/pulls/$n" --jq '{number, title, url:.html_url, prAuthor:.user.login, prBot:(.user.type == "Bot"), prLabels:[.labels[].name]}' 2>/dev/null; } > "$f" || true
    else
      # GitLab labels are plain strings; few bots are marked as such, so names decide too.
      { [ "$has_glab" = 1 ] && glab api --hostname "$host" "projects/$(jq -rn --arg s "$path" '$s | @uri')/merge_requests/$n" 2>/dev/null \
          | jq -c '{number:.iid, title, url:.web_url, prAuthor:.author.username,
              prBot:((.author.bot // false) or ((.author.username // "") | test("\\[bot\\]|dependabot|renovate|^(project|group)_[0-9]+_bot"; "i"))),
              prLabels:((.labels // []) | map(if type == "object" then .name else . end))}' 2>/dev/null; } > "$f" || true
    fi
    jq -e 'type == "object" and .number != null' "$f" >/dev/null 2>&1 || echo "{\"number\":$n}" > "$f"
  fi
  cat "$f"
}

# What `deploys risk` says, if this CLI has it: JSON (a list, or an object with a list) or lines.
risk_hints() {
  local raw
  [ "$has_risk" = 1 ] || { echo '[]'; return; }
  raw="$("$DEPLOYS" risk "$1" --json </dev/null 2>/dev/null)" || true
  printf '%s' "$raw" | jq -c '
    def str: if type == "string" then . elif type == "object" then (.hint // .message // .reason // .text // .title // tostring) else tostring end;
    if type == "array" then map(str) elif type == "object" then ((.hints // .risks // .reasons // .items // []) | map(str)) else [] end' 2>/dev/null \
    || printf '%s' "$raw" | jq -Rsc 'split("\n") | map(select(test("\\S")))'
}

: > "$tmp/projects.jsonl"
while IFS= read -r p; do
  name="$(jq -r '.name' <<<"$p")"; prepo="$(jq -r '.repo // empty' <<<"$p")"
  live="$(jq -r '.lastSha // empty' <<<"$p")"; ref="$(jq -r '.ref // "main"' <<<"$p")"
  d='null'
  if [ -n "$prepo" ] && [ -n "$live" ]; then
    d="$("$DEPLOYS" details "$prepo" "$live" "$ref" </dev/null 2>/dev/null)" || d='null'
    jq -e 'type == "object"' >/dev/null 2>&1 <<<"$d" || d='null'
  fi
  # Each commit gets its pull request's facts, then a kind.
  : > "$tmp/prs.jsonl"
  for n in $(jq -r '.commits // [] | map(.pr // empty) | unique | .[]' <<<"$d"); do pr_facts "$prepo" "$n" >> "$tmp/prs.jsonl"; done
  commits="$(jq -c --slurpfile prs "$tmp/prs.jsonl" '
    ($prs | map({key:(.number | tostring), value:.}) | from_entries) as $by
    | (.commits // []) | map(. + (if .pr then ($by[.pr | tostring] // {} | {prAuthor, prBot, prLabels, prTitle:.title, prUrl:.url} | with_entries(select(.value != null))) else {} end))' <<<"$d" | classify)"
  jq -c --argjson d "$d" --argjson c "$commits" --argjson risk "$(risk_hints "$name")" '
    {name, platform:(.platform // null), repo:(.repo // null), ref:(.ref // null), pending:(.pendingCommits // null),
     known:($d != null), compareUrl:($d.compareUrl // null),
     agent:($c | map(select(.kind == "agent")) | length), human:($c | map(select(.kind == "human")) | length),
     prs:($c | map(select(.pr)) | group_by(.pr) | map({number:.[0].pr, title:(.[0].prTitle // .[0].msg), url:(.[0].prUrl // null),
            kind:(if all(.kind == "agent") then "agent" elif all(.kind == "human") then "human" else "mixed" end),
            why:(map(select(.kind == "agent") | .why) | unique)})),
     loose:($c | map(select(.pr | not)) | map({sha, msg, author, kind, why})),
     risk:($risk + (($d.risky // []) | map("changes \(.)")) + (if ($d.checks.failed // 0) > 0 then ["CI failed on the branch head"] else [] end) | unique)}' <<<"$p" >> "$tmp/projects.jsonl"
done < <(jq -c '.[]' <<<"$list")

digest="$(jq -s --arg date "$today" --arg title "$title" --argjson partial "$partial" '
  {date:$date, title:$title, partial:$partial, projects:.,
   names:(map(.name | select(test("^[A-Za-z0-9._-]+$")))),
   agent:(map(.agent) | add // 0), human:(map(.human) | add // 0)}' "$tmp/projects.jsonl")"

if [ "$json" = 1 ]; then echo "$digest"; [ -n "$out" ] && echo "$digest" > "$out"; exit 0; fi

# Commit and PR titles are written by anyone who can push: in the issue they must not ping people
# (@login gets a zero-width space), open an HTML comment (a fake deploys-approve marker) or add links.
markdown="$(jq -r '
  def safe: tostring | gsub("<"; "&lt;") | gsub(">"; "&gt;") | gsub("@"; "@\u200b") | gsub("(?<c>[\\[\\]`])"; "\\\(.c)");
  def kindtxt: if .kind == "agent" then "agent" + (if (.why | type) == "array" and (.why | length) > 0 then " (" + (.why | map(safe) | join(", ")) + ")" elif (.why | type) == "string" then " (\(.why | safe))" else "" end) else .kind end;
  "# \(.title)", "",
  (if (.projects | length) == 0 then "Nothing waiting: every project is on its newest commit."
   else "\(.projects | length) project\(if (.projects | length) == 1 then "" else "s" end) waiting: \(.agent) commit\(if .agent == 1 then "" else "s" end) by agents, \(.human) by people." end),
  (if .partial then "", "Some projects could not be read and are left out (see `deploys changed`)." else empty end),
  (.projects[] |
    "", "## \(.name | safe)" + ([.platform, .repo] | map(select(.) | safe) | if length > 0 then " (\(join(", ")))" else "" end), "",
    (if .known then "\(.agent + .human) commit\(if (.agent + .human) == 1 then "" else "s" end) waiting: \(.agent) agent, \(.human) human"
     else "Changes waiting (\(.pending // "?") commits; the commits could not be read)" end),
    (if (.prs | length) > 0 then "", "Pull requests:", (.prs[] | "- #\(.number) \(.title | safe) – \(kindtxt)") else empty end),
    (if (.loose | length) > 0 then "", "Commits without a pull request:",
       (.loose[0:10][] | "- `\(.sha | safe)` \(.msg | safe) – \(.author // "?" | safe), \(.kind)"),
       (if (.loose | length) > 10 then "- … and \((.loose | length) - 10) more" else empty end) else empty end),
    (if (.risk | length) > 0 then "", "Check before shipping:", (.risk[] | "- \(. | safe)") else empty end),
    (if .compareUrl then "", "[All changes](\(.compareUrl))" else empty end))' <<<"$digest")"

approve_url=""; [ -n "$repo" ] && approve_url="https://github.com/$repo/actions/workflows/$workflow"
names_csv="$(jq -r '.names | join(",")' <<<"$digest")"
howto=""
if [ -n "$names_csv" ]; then
  howto="Nothing is deployed until a person approves."
  [ -n "$repo" ] && howto="$howto
- Add the label \`deploy-approved\` to the issue \"$title\" in $repo, or
- open [approve-deploy]($approve_url), press **Run workflow**, projects: \`$names_csv\`"
fi
[ -n "$out" ] && printf '%s\n%s\n' "$markdown" "${howto:+
## Approve

$howto}" > "$out"

# --- the issue: one per day, updated in place; older open digests are closed ---
# The list to approve is also posted as a comment by this token's account: approve-deploy.yml
# reads it from there (an unedited comment of that account), never from the issue body, which
# anyone with write access could change between the digest and the label.
issue_url=""
if [ "$issue" = 1 ] && [ -z "$names_csv" ]; then
  # Nothing waits now: an open digest of today (or earlier) must not approve this morning's list later.
  if [ "$dry" = 1 ]; then
    echo "issue: nothing waiting; open digests in $repo would be closed"
  else
    command -v gh >/dev/null 2>&1 || { echo "--issue needs gh (GitHub CLI)" >&2; exit 1; }
    open="$(gh issue list -R "$repo" --state open --label deploys-digest --limit 50 --json number,title,url)"
    for old in $(jq -r '.[] | select(.title | startswith("Deploys waiting – ")) | .number' <<<"$open"); do
      gh issue close "$old" -R "$repo" --comment "Nothing is waiting any more; closed so its label cannot approve an old list." >/dev/null 2>&1 || true
      echo "Closed issue #$old (nothing waiting)."
    done
  fi
elif [ "$issue" = 1 ]; then
  body="$markdown

## Approve

Add the label \`deploy-approved\` to this issue to deploy: \`$names_csv\`.
Or run [approve-deploy]($approve_url) with these projects. Nothing is deployed before.

<!-- deploys-approve: $names_csv -->"
  printf '%s\n' "$body" > "$tmp/body.md"
  if [ "$dry" = 1 ]; then
    printf 'issue: %s in %s\n%s\n' "$title" "$repo" "$body"
  else
    command -v gh >/dev/null 2>&1 || { echo "--issue needs gh (GitHub CLI)" >&2; exit 1; }
    gh label create deploys-digest -R "$repo" --color ededed --description "Daily list of deploys waiting" >/dev/null 2>&1 || true
    gh label create deploy-approved -R "$repo" --color 0e8a16 --description "A person approves the deploys listed in this issue" >/dev/null 2>&1 || true
    open="$(gh issue list -R "$repo" --state open --label deploys-digest --limit 50 --json number,title,url)"
    num="$(jq -r --arg t "$title" 'map(select(.title == $t)) | .[0].number // empty' <<<"$open")"
    if [ -n "$num" ]; then
      gh issue edit "$num" -R "$repo" --body-file "$tmp/body.md" >/dev/null
      issue_url="$(jq -r --arg t "$title" 'map(select(.title == $t)) | .[0].url' <<<"$open")"
      echo "Updated issue #$num."
    else
      issue_url="$(gh issue create -R "$repo" --title "$title" --body-file "$tmp/body.md" --label deploys-digest | tail -n 1)"
      num="${issue_url##*/}"
      echo "Opened issue $issue_url"
    fi
    # The list approve-deploy.yml deploys: the newest unedited comment of this account.
    printf 'The list a `deploy-approved` label deploys now: `%s`\n\n<!-- deploys-approve: %s -->\n' "$names_csv" "$names_csv" > "$tmp/approve.md"
    gh issue comment "$num" -R "$repo" --body-file "$tmp/approve.md" >/dev/null
    # A digest of an earlier day lists what waited then: close it, so its label cannot approve.
    for old in $(jq -r --arg t "$title" '.[] | select(.title != $t and (.title | startswith("Deploys waiting – "))) | .number' <<<"$open"); do
      gh issue close "$old" -R "$repo" --comment "Replaced by #$num." >/dev/null 2>&1 || true
    done
  fi
fi

# --- the message: a short version of the digest, with the button ---
if [ "$post" = 1 ]; then
  text="$(jq -r '
    "\(.title)",
    (if (.projects | length) == 0 then "Nothing waiting." else
      "\(.agent) agent and \(.human) human commit\(if .human == 1 then "" else "s" end) in \(.projects | length) project\(if (.projects | length) == 1 then "" else "s" end).",
      (.projects[] | "• \(.name): " + (if .known then "\(.agent) agent, \(.human) human" else "changes waiting" end)
        + (if (.prs | length) > 0 then " – " + (.prs[0:5] | map("#\(.number) \(.title)") | join("; ")) + (if (.prs | length) > 5 then "; …" else "" end) else "" end)
        + (if (.risk | length) > 0 then " – check: " + (.risk[0:3] | join(", ")) else "" end)) end)' <<<"$digest")"
  link="" label=""
  if [ -n "$names_csv" ]; then
    text="$text
Nothing deploys until a person approves${repo:+ (projects: $names_csv)}."
    [ -n "$issue_url" ] && text="$text
Issue: $issue_url (label deploy-approved)"
    [ -n "$approve_url" ] && { link="$approve_url"; label="Approve deploy"; }
  fi
  format="$(webhook_format "$url")"
  webhook_body "$format" "$text" "$link" "$label"
  if [ "$dry" = 1 ]; then printf 'format: %s\n%s\n' "$format" "$WEBHOOK_BODY"
  else webhook_send "$url" "$format"; echo "Posted ($format)."; fi
fi

[ "$post" = 1 ] || [ "$issue" = 1 ] || printf '%s\n%s\n' "$markdown" "${howto:+
## Approve

$howto}"
