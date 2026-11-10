#!/bin/bash
# statuspage.sh — a static "what shipped when" page: index.html, feed.xml (Atom) and status.json.
#
#   integrations/statuspage/statuspage.sh [--config statuspage.json] [--out public] [--no-check] [--no-notes]
#
# Only the projects named in the config are shown (an allowlist: nothing else leaks). For each:
# the live deploy, its state and time, and what is merged but not live yet (`deploys notes`).
# Below that, the last deploys from the app's journal. With a `url` for a project, the site is
# checked once while the page is made. Nothing is deployed; the files go to any static host.
#
# Env: DEPLOYS            the CLI to call (default: deploys on PATH)
#      DEPLOYS_JOURNAL    the journal (default: the app's, in ~/Library/Application Support)
set -euo pipefail
DEPLOYS="${DEPLOYS:-deploys}"
here="$(cd "$(dirname "$0")" && pwd)"
# shellcheck source=../lib/projects.sh
. "$here/../lib/projects.sh"

config="statuspage.json"; out="public"; check=1; notes=1
while [ $# -gt 0 ]; do
  case "$1" in
    --config) config="${2:?--config needs a file}"; shift ;;
    --out) out="${2:?--out needs a folder}"; shift ;;
    --no-check) check=0 ;;
    --no-notes) notes=0 ;;
    -h|--help) sed -n '2,/^set /p' "$0" | sed -e '$d' -e 's/^# \{0,1\}//'; exit 0 ;;
    *) echo "Unknown option $1" >&2; exit 1 ;;
  esac
  shift
done

[ -f "$config" ] || { echo "No config at $config. Start from integrations/statuspage/statuspage.example.json." >&2; exit 1; }
cfg="$(jq -c '
  if type != "object" then error("the config must be a JSON object") else . end
  | {title: (.title // "Deploys"),
     description: (.description // ""),
     baseUrl: (.baseUrl // ""),
     hideMessages: (.hideMessages // false),
     showAuthors: (.showAuthors // false),
     timeline: (.timeline // 30),
     journal: (.journal // null),
     # "name", "platform/name" or {name, platform?, label?, url?}
     projects: ((.projects // []) | map(
        if type == "string" then
          (if test("^[a-z][a-z0-9]*/[^/]") then {platform: split("/")[0], name: (split("/")[1:] | join("/"))} else {name: .} end)
        elif type == "object" and (.name | type) == "string" then {name, platform: (.platform // null), label: (.label // null), url: (.url // null)}
        else error("each project is a name or an object with a name") end))}' "$config")" \
  || { echo "Could not read $config" >&2; exit 1; }
[ "$(jq '.projects | length' <<<"$cfg")" -gt 0 ] || { echo "No projects in $config: the page shows only the ones listed there." >&2; exit 1; }

journal="${DEPLOYS_JOURNAL:-$(jq -r '.journal // empty' <<<"$cfg")}"
journal="${journal:-$HOME/Library/Application Support/app.deploycenter.mac/journal.jsonl}"
journal="${journal/#\~/$HOME}"

# Every project the CLI can read, kept to the allowlist (in its order). Only the fields listed
# here go any further: no repo, no commit SHA, no error text.
picked="$(all_projects | jq -c --argjson cfg "$cfg" '. as $all | [$cfg.projects[] as $p
  | ($all | map(select(.name == $p.name and ($p.platform == null or .platform == $p.platform))) | .[0]) as $x
  | if $x == null then {name: $p.name, label: ($p.label // $p.name), platform: $p.platform, url: $p.url, found: false}
    else {name: $x.name, label: ($p.label // $x.name), platform: $x.platform, url: $p.url, found: true,
          at: (($x.liveAt // $x.lastAt // 0) | if . > 0 then . else null end),
          message: $x.lastMsg, changed: ($x.changed // false), pendingCommits: $x.pendingCommits,
          state: ((($x.lastState // "") | ascii_downcase) as $s
            | if $x.building then "building"
              elif ($x.liveAt // $x.lastAt // 0) == 0 then "never"
              # Render: the newest attempt failed, the one before is still live.
              elif ($s | test("fail|error")) then (if $x.liveAt then "live-failed" else "failed" end)
              else "live" end)} end]')"

# What is merged but not live: `deploys notes` lines "- message (#12) – author".
notes_of() {
  local md
  md="$("$DEPLOYS" notes "$1" 2>/dev/null </dev/null)" || return 0
  printf '%s\n' "$md" | awk '/^Dependency updates:/ {dep=1; next} /^- / {sub(/^- /, ""); print (dep ? "dep\t" : "msg\t") $0}'
}
# One site check: HTTP code and seconds. 2xx and 3xx count as up.
check_of() {
  curl -sS -o /dev/null -L --max-time 10 -w '%{http_code} %{time_total}' -- "$1" 2>/dev/null </dev/null || echo "000 0"
}

extra='{}'
while IFS=$'\t' read -r i name changed url; do
  n='[]'; c='null'
  if [ "$notes" = 1 ] && [ "$changed" = true ]; then
    n="$(notes_of "$name" | jq -R -s -c 'split("\n") | map(select(length > 0) | split("\t") | {kind: .[0], text: (.[1:] | join("\t"))})')"
  fi
  if [ "$check" = 1 ] && [ -n "$url" ]; then
    read -r code secs <<<"$(check_of "$url")"
    c="$(jq -n -c --arg code "$code" --arg s "$secs" '($code | tonumber? // 0) as $c
      | {up: ($c >= 200 and $c < 400), code: $c, ms: (($s | tonumber? // 0) * 1000 | round)}')"
  fi
  extra="$(jq -c --arg i "$i" --argjson n "$n" --argjson c "$c" '. + {($i): {notes: $n, check: $c}}' <<<"$extra")"
done < <(jq -r 'to_entries[] | [.key, .value.name, (.value.changed // false), (.value.url // "")] | @tsv' <<<"$picked")

# The journal: one JSON object per line, oldest first (app/Journal.swift). Lines that do not
# read are skipped. Only live and failed deploys of listed projects; never the `detail` text.
timeline='[]'
if [ -f "$journal" ]; then
  timeline="$(jq -R -c 'fromjson? // empty' "$journal" | jq -s -c --argjson cfg "$cfg" '
    map(select(type == "object" and (.result == "live" or .result == "failed")) | . as $e
        | select(any($cfg.projects[]; .name == $e.name and (.platform == null or .platform == $e.platform)))
        | {at: ((.at // "") | sub("\\.[0-9]+"; "") | fromdateiso8601? // null), name, platform, result,
           seconds: (.seconds | if type == "number" then round else null end),
           label: ((.name as $n | .platform as $pl | $cfg.projects | map(select(.name == $n and (.platform == null or .platform == $pl))) | .[0].label) // .name)}
        | select(.at != null))
    | sort_by(.at) | reverse | .[0:$cfg.timeline]')"
fi

mkdir -p "$out"
# status.json is the source for the page and the feed.
jq -n --argjson cfg "$cfg" --argjson p "$picked" --argjson x "$extra" --argjson t "$timeline" '
  def updated: "Updated";
  def strip_author: if $cfg.showAuthors then . else sub(" – [^–]*$"; "") end;
  {title: $cfg.title, description: $cfg.description, generatedAt: (now | floor),
   url: ($cfg.baseUrl | if . != "" and (endswith("/") | not) then . + "/" else . end),
   projects: [$p | to_entries[] | .value as $v | ($x[.key | tostring] // {notes: [], check: null}) as $e
     | {name: $v.label, platform: $v.platform, state: (if $v.found then $v.state else "unknown" end),
        at: $v.at,
        message: (if $v.found | not then null elif $cfg.hideMessages then (if $v.at then updated else null end) else $v.message end),
        waiting: ($v.changed // false),
        next: (if $cfg.hideMessages then (if ($e.notes | length) > 0 then [updated] else [] end)
               else ($e.notes | map(if .kind == "dep" then "Dependency update: " + (.text | strip_author) else (.text | strip_author) end)) end),
        check: $e.check}],
   timeline: [$t[] | {name: .label, platform, result, at, seconds}]}' > "$out/status.json"

# --- index.html: one file, no external assets, light and dark, readable on a phone ---
jq -r --arg css "$(cat "$here/page.css")" '
  def h: tostring | @html;
  def iso: todate;
  def when: if . then "<time datetime=\"\(iso)\">\(strftime("%Y-%m-%d %H:%M UTC"))</time>" else "never" end;
  def dur: if . == null then "" elif . < 60 then "\(.) s" else "\((. / 60) | floor) min \(. % 60) s" end;
  def badge: {live: ["ok", "Live"], "live-failed": ["warn", "Live · last deploy failed"], failed: ["bad", "Failed"],
               building: ["busy", "Deploying"], never: ["muted", "Not deployed yet"], unknown: ["muted", "Unknown"]}[.]
             // ["muted", .];
  "<!doctype html>",
  "<html lang=\"en\"><head><meta charset=\"utf-8\">",
  "<meta name=\"viewport\" content=\"width=device-width, initial-scale=1\">",
  "<meta name=\"color-scheme\" content=\"light dark\">",
  "<title>\(.title | h)</title>",
  (if .description != "" then "<meta name=\"description\" content=\"\(.description | h)\">" else empty end),
  "<link rel=\"alternate\" type=\"application/atom+xml\" title=\"\(.title | h)\" href=\"feed.xml\">",
  "<style>\($css)</style></head><body><main>",
  "<header><h1>\(.title | h)</h1>",
  (if .description != "" then "<p class=\"lead\">\(.description | h)</p>" else empty end),
  "<p class=\"meta\">Updated \(.generatedAt | when) · <a href=\"feed.xml\">Feed</a> · <a href=\"status.json\">JSON</a></p></header>",
  "<section aria-labelledby=\"now\"><h2 id=\"now\">Projects</h2><ul class=\"cards\">",
  (.projects[] | (.state | badge) as $b |
    "<li class=\"card\"><div class=\"row\"><h3>\(.name | h)</h3><span class=\"pill \($b[0])\">\($b[1] | h)</span></div>",
    (if .state == "unknown" then "<p class=\"when\">Could not be read just now.</p>" else "<p class=\"when\">Last deploy \(.at | when)</p>" end),
    (if .message then "<p class=\"msg\">\(.message | h)</p>" else empty end),
    (if .check then "<p class=\"check \(if .check.up then "up" else "down" end)\">\(if .check.up then "Site up" else "Site not reachable" end)"
       + (if .check.code > 0 then " · HTTP \(.check.code)" + (if .check.up then " · \(.check.ms) ms" else "" end) else "" end) + "</p>" else empty end),
    (if (.next | length) > 0 then "<details><summary>Coming next (\(.next | length))</summary><ul class=\"next\">"
       + (.next | map("<li>\(h)</li>") | join("")) + "</ul></details>"
     elif .waiting then "<p class=\"muted\">Changes waiting to ship.</p>" else empty end),
    "</li>"),
  "</ul></section>",
  "<section aria-labelledby=\"tl\"><h2 id=\"tl\">Recent deploys</h2>",
  (if (.timeline | length) == 0 then "<p class=\"muted\">No deploys recorded yet.</p>"
   else "<ol class=\"timeline\">",
     (.timeline[] | "<li class=\"\(.result)\"><span class=\"dot\" aria-hidden=\"true\"></span><span class=\"what\"><b>\(.name | h)</b> \(if .result == "live" then "went live" else "deploy failed" end)</span>"
       + "<span class=\"t\">\(.at | when)\(if .seconds then " · " + (.seconds | dur) else "" end)</span></li>"),
     "</ol>" end),
  "</section>",
  "<footer>Made with Deploy Center. Times in UTC.</footer>",
  "</main>",
  # Local time where scripts run; the UTC text stays where they do not.
  "<script>for(const t of document.querySelectorAll(\"time\")){const d=new Date(t.dateTime);if(!isNaN(d))t.textContent=d.toLocaleString([], {dateStyle:\"medium\",timeStyle:\"short\"})}document.querySelector(\"footer\").textContent=\"Made with Deploy Center.\"</script>",
  "</body></html>"' "$out/status.json" > "$out/index.html"

# --- feed.xml: Atom, one entry per deploy in the timeline ---
jq -r '
  def x: tostring | @html;
  . as $s | ($s.url // "") as $link |
  (if $link != "" then $link else "urn:deploy-center:statuspage:" + ($s.title | @uri) end) as $id |
  "<?xml version=\"1.0\" encoding=\"utf-8\"?>",
  "<feed xmlns=\"http://www.w3.org/2005/Atom\">",
  "  <title>\($s.title | x)</title>",
  "  <id>\($id | x)</id>",
  "  <updated>\((($s.timeline[0].at) // $s.generatedAt) | todate)</updated>",
  "  <author><name>\($s.title | x)</name></author>",
  (if $link != "" then "  <link rel=\"alternate\" href=\"\($link | x)\"/>", "  <link rel=\"self\" href=\"\($link | x)feed.xml\"/>" else empty end),
  ($s.timeline[] |
    "  <entry>",
    "    <title>\(.name | x) \(if .result == "live" then "went live" else "deploy failed" end)</title>",
    "    <id>urn:deploy-center:\(.platform | x):\(.name | @uri | x):\(.at)</id>",
    "    <updated>\(.at | todate)</updated>",
    (if $link != "" then "    <link href=\"\($link | x)\"/>" else empty end),
    "  </entry>"),
  "</feed>"' "$out/status.json" > "$out/feed.xml"

echo "$(jq '.projects | length' "$out/status.json") project(s), $(jq '.timeline | length' "$out/status.json") deploy(s) in $out/"
