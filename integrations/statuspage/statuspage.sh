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
     # Only an http(s) address without spaces or quotes: it goes into the links and ids of the feed.
     baseUrl: ((.baseUrl // "") | if . == "" or test("^https?://[^\\s\"<>]+$") then . else error("baseUrl must be an http(s) address") end),
     hideMessages: (.hideMessages // false),
     showAuthors: (.showAuthors // false),
     timeline: (.timeline // 30),
     # The language of the page: its texts, the feed titles and "Updated" in status.json.
     lang: ((.lang // "en") | if . == "en" or . == "de" then . else error("lang must be en or de") end),
     # After this many hours the page warns that it is old (it is made by a job that may have stopped).
     staleHours: ((.staleHours // 48) | if type == "number" and . > 0 then . else error("staleHours must be a positive number") end),
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
# One site check: HTTP code and seconds. 2xx and 3xx count as up, and 401/403 too (a login
# wall answers, so the site is up). At most 5 redirects, http and https only.
check_of() {
  curl -sS -o /dev/null -L --max-redirs 5 --proto '=http,https' --proto-redir '=http,https' --max-time 10 \
    -w '%{http_code} %{time_total}' -- "$1" 2>/dev/null </dev/null || echo "000 0"
}

tmp_hist="$(mktemp)"; trap 'rm -f "$tmp_hist"' EXIT
extra='{}'
while IFS=$'\t' read -r i name changed url; do
  n='[]'; c='null'
  if [ "$notes" = 1 ] && [ "$changed" = true ]; then
    # A CLI with `notes --json` gives the author as a field; an older one only Markdown lines.
    if nj="$("$DEPLOYS" notes "$name" --json 2>/dev/null </dev/null)" && jq -e '.commits | type == "array"' >/dev/null 2>&1 <<<"$nj"; then
      n="$(jq -c '[.commits[] | {kind: (if .bot then "dep" else "msg" end),
            text: ((.message // "") + (if .pr and .bot != true then " (#\(.pr))" else "" end)), author: (.author // null)}]' <<<"$nj")"
    else
      n="$(notes_of "$name" | jq -R -s -c 'split("\n") | map(select(length > 0) | split("\t") | {kind: .[0], text: (.[1:] | join("\t")), author: false})')"
    fi
  fi
  if [ "$check" = 1 ] && [ -n "$url" ]; then
    read -r code secs <<<"$(check_of "$url")"
    c="$(jq -n -c --arg code "$code" --arg s "$secs" '($code | tonumber? // 0) as $c
      | {up: (($c >= 200 and $c < 400) or $c == 401 or $c == 403), code: $c, ms: (($s | tonumber? // 0) * 1000 | round)}')"
  fi
  extra="$(jq -c --arg i "$i" --argjson n "$n" --argjson c "$c" '. + {($i): {notes: $n, check: $c}}' <<<"$extra")"
done < <(jq -r 'to_entries[] | [.key, .value.name, (.value.changed // false), (.value.url // "")] | @tsv' <<<"$picked")

# The journal: one JSON object per line, oldest first (app/Journal.swift). Lines that do not
# read are skipped. Only live and failed deploys of listed projects; never the `detail` text.
timeline='[]'
if [ ! -f "$journal" ]; then
  # No journal (CI, another machine): the platforms' own history, from a CLI with history --json.
  # live and failed only; a provider without a history, or an older CLI, adds nothing.
  : > "$tmp_hist"
  while IFS=$'\t' read -r name plat label; do
    h="$("$DEPLOYS" history "$plat:$name" 10 --json 2>/dev/null </dev/null)" || continue
    jq -c --arg n "$name" --arg p "$plat" --arg l "$label" '.[]? | select(type == "object" and (.at | type) == "number")
      | ((.state // "") | ascii_downcase) as $s
      | (if ($s | test("fail|error")) then "failed" elif ($s | test("^(ready|live|success|succeeded|deployed|active)$")) then "live" else empty end) as $r
      | {at, name: $n, platform: $p, result: $r, seconds: null, label: $l}' <<<"$h" >> "$tmp_hist" 2>/dev/null || true
  done < <(jq -r '.[] | select(.found) | [.name, .platform, .label] | @tsv' <<<"$picked")
  timeline="$(jq -s -c --argjson cfg "$cfg" 'sort_by(.at) | reverse | .[0:$cfg.timeline]' "$tmp_hist")"
elif [ -f "$journal" ]; then
  timeline="$(jq -R -c 'fromjson? // empty' "$journal" | jq -s -c --argjson cfg "$cfg" '
    map(select(type == "object" and (.result == "live" or .result == "failed")) | . as $e
        | select(any($cfg.projects[]; .name == $e.name and (.platform == null or .platform == $e.platform)))
        | {at: ((.at // "") | sub("\\.[0-9]+"; "") | fromdateiso8601? // null), name, platform, result,
           seconds: (.seconds | if type == "number" then round else null end),
           label: ((.name as $n | .platform as $pl | $cfg.projects | map(select(.name == $n and (.platform == null or .platform == $pl))) | .[0].label) // .name)}
        | select(.at != null))
    | sort_by(.at) | reverse | .[0:$cfg.timeline]')"
fi

# The page's texts, English and German (config "lang").
texts='{
 "en": {"updated":"Updated","depUpdate":"Dependency update: ","never":"never","live":"Live","liveFailed":"Live · last deploy failed",
        "failed":"Failed","building":"Deploying","notYet":"Not deployed yet","unknown":"Unknown","feed":"Feed","projects":"Projects",
        "unread":"Could not be read just now.","lastDeploy":"Last deploy","siteUp":"Site up","siteDown":"Site not reachable",
        "next":"Coming next","waiting":"Changes waiting to ship.","recent":"Recent deploys","noDeploys":"No deploys recorded yet.",
        "wentLive":"went live","deployFailed":"deploy failed","footerUtc":"Made with Deploy Center. Times in UTC.",
        "footer":"Made with Deploy Center.","stale":"This page was last made {n} hours ago and may be out of date.",
        "staleDays":"This page was last made {n} days ago and may be out of date."},
 "de": {"updated":"Aktualisiert","depUpdate":"Abhängigkeit aktualisiert: ","never":"nie","live":"Live","liveFailed":"Live · letzter Deploy fehlgeschlagen",
        "failed":"Fehlgeschlagen","building":"Wird deployt","notYet":"Noch nicht deployt","unknown":"Unbekannt","feed":"Feed","projects":"Projekte",
        "unread":"Ließ sich gerade nicht lesen.","lastDeploy":"Letzter Deploy","siteUp":"Seite erreichbar","siteDown":"Seite nicht erreichbar",
        "next":"Als Nächstes","waiting":"Änderungen warten darauf, live zu gehen.","recent":"Letzte Deploys","noDeploys":"Noch keine Deploys aufgezeichnet.",
        "wentLive":"ging live","deployFailed":"Deploy fehlgeschlagen","footerUtc":"Erstellt mit Deploy Center. Zeiten in UTC.",
        "footer":"Erstellt mit Deploy Center.","stale":"Diese Seite wurde vor {n} Stunden zuletzt erstellt und ist vielleicht nicht aktuell.",
        "staleDays":"Diese Seite wurde vor {n} Tagen zuletzt erstellt und ist vielleicht nicht aktuell."}}'
L="$(jq -c --arg l "$(jq -r .lang <<<"$cfg")" '.[$l]' <<<"$texts")"

mkdir -p "$out"
# status.json is the source for the page and the feed.
jq -n --argjson cfg "$cfg" --argjson p "$picked" --argjson x "$extra" --argjson t "$timeline" --argjson L "$L" '
  def updated: $L.updated;
  # author false: a Markdown line "msg – author" (an older CLI), cut at the last " – ".
  def strip_author($a): if $a == false then (if $cfg.showAuthors then . else sub(" – [^–]*$"; "") end)
                        elif $cfg.showAuthors and $a != null then . + " – " + $a else . end;
  {title: $cfg.title, description: $cfg.description, generatedAt: (now | floor), lang: $cfg.lang, staleHours: $cfg.staleHours,
   url: ($cfg.baseUrl | if . != "" and (endswith("/") | not) then . + "/" else . end),
   projects: [$p | to_entries[] | .value as $v | ($x[.key | tostring] // {notes: [], check: null}) as $e
     | {name: $v.label, platform: $v.platform, state: (if $v.found then $v.state else "unknown" end),
        at: $v.at,
        message: (if $v.found | not then null elif $cfg.hideMessages then (if $v.at then updated else null end) else $v.message end),
        waiting: ($v.changed // false),
        next: (if $cfg.hideMessages then (if ($e.notes | length) > 0 then [updated] else [] end)
               else ($e.notes | map(if .kind == "dep" then $L.depUpdate + (.author as $a | .text | strip_author($a)) else (.author as $a | .text | strip_author($a)) end)) end),
        check: $e.check}],
   timeline: [$t[] | {name: .label, platform, result, at, seconds}]}' > "$out/status.json"

# --- index.html: one file, no external assets, light and dark, readable on a phone ---
jq -r --arg css "$(cat "$here/page.css")" --argjson L "$L" '
  def h: tostring | @html;
  def iso: todate;
  def when: if . then "<time datetime=\"\(iso)\">\(strftime("%Y-%m-%d %H:%M UTC"))</time>" else $L.never end;
  def dur: if . == null then "" elif . < 60 then "\(.) s" else "\((. / 60) | floor) min \(. % 60) s" end;
  def badge: {live: ["ok", $L.live], "live-failed": ["warn", $L.liveFailed], failed: ["bad", $L.failed],
               building: ["busy", $L.building], never: ["muted", $L.notYet], unknown: ["muted", $L.unknown]}[.]
             // ["muted", .];
  "<!doctype html>",
  "<html lang=\"\(.lang)\"><head><meta charset=\"utf-8\">",
  "<meta name=\"viewport\" content=\"width=device-width, initial-scale=1\">",
  "<meta name=\"color-scheme\" content=\"light dark\">",
  "<title>\(.title | h)</title>",
  (if .description != "" then "<meta name=\"description\" content=\"\(.description | h)\">" else empty end),
  "<link rel=\"alternate\" type=\"application/atom+xml\" title=\"\(.title | h)\" href=\"feed.xml\">",
  "<style>\($css)</style></head><body><main>",
  "<header><h1>\(.title | h)</h1>",
  (if .description != "" then "<p class=\"lead\">\(.description | h)</p>" else empty end),
  "<p class=\"meta\">\($L.updated | h) \(.generatedAt | when) · <a href=\"feed.xml\">\($L.feed | h)</a> · <a href=\"status.json\">JSON</a></p>",
  # Shown by the script below when the page is older than staleHours (the job that makes it may have stopped).
  "<p class=\"stale\" role=\"alert\" hidden data-generated=\"\(.generatedAt)\" data-hours=\"\(.staleHours)\" data-text=\"\($L.stale | h)\" data-text-days=\"\($L.staleDays | h)\"></p></header>",
  "<section aria-labelledby=\"now\"><h2 id=\"now\">\($L.projects | h)</h2><ul class=\"cards\">",
  (.projects[] | (.state | badge) as $b |
    "<li class=\"card\"><div class=\"row\"><h3>\(.name | h)</h3><span class=\"pill \($b[0])\">\($b[1] | h)</span></div>",
    (if .state == "unknown" then "<p class=\"when\">\($L.unread | h)</p>" else "<p class=\"when\">\($L.lastDeploy | h) \(.at | when)</p>" end),
    (if .message then "<p class=\"msg\">\(.message | h)</p>" else empty end),
    (if .check then "<p class=\"check \(if .check.up then "up" else "down" end)\">\(if .check.up then $L.siteUp else $L.siteDown end | h)"
       + (if .check.code > 0 then " · HTTP \(.check.code)" + (if .check.up then " · \(.check.ms) ms" else "" end) else "" end) + "</p>" else empty end),
    (if (.next | length) > 0 then "<details><summary>\($L.next | h) (\(.next | length))</summary><ul class=\"next\">"
       + (.next | map("<li>\(h)</li>") | join("")) + "</ul></details>"
     elif .waiting then "<p class=\"muted\">\($L.waiting | h)</p>" else empty end),
    "</li>"),
  "</ul></section>",
  "<section aria-labelledby=\"tl\"><h2 id=\"tl\">\($L.recent | h)</h2>",
  (if (.timeline | length) == 0 then "<p class=\"muted\">\($L.noDeploys | h)</p>"
   else "<ol class=\"timeline\">",
     (.timeline[] | "<li class=\"\(.result)\"><span class=\"dot\" aria-hidden=\"true\"></span><span class=\"what\"><b>\(.name | h)</b> \(if .result == "live" then $L.wentLive else $L.deployFailed end | h)</span>"
       + "<span class=\"t\">\(.at | when)\(if .seconds then " · " + (.seconds | dur) else "" end)</span></li>"),
     "</ol>" end),
  "</section>",
  "<footer>\($L.footerUtc | h)</footer>",
  "</main>",
  # Local time where scripts run; the UTC text stays where they do not.
  "<script>for(const t of document.querySelectorAll(\"time\")){const d=new Date(t.dateTime);if(!isNaN(d))t.textContent=d.toLocaleString([], {dateStyle:\"medium\",timeStyle:\"short\"})}document.querySelector(\"footer\").textContent=\($L.footer | tojson | gsub("<"; "\\u003c"));"
    + "const s=document.querySelector(\".stale\");if(s){const h=(Date.now()/1000-Number(s.dataset.generated))/3600;if(h>=Number(s.dataset.hours)){s.textContent=(h>=48?s.dataset.textDays:s.dataset.text).replace(\"{n}\",String(Math.floor(h>=48?h/24:h)));s.hidden=false}}</script>",
  "</body></html>"' "$out/status.json" > "$out/index.html"

# --- feed.xml: Atom, one entry per deploy in the timeline ---
jq -r --argjson L "$L" '
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
    "    <title>\(.name | x) \(if .result == "live" then $L.wentLive else $L.deployFailed end | x)</title>",
    "    <id>urn:deploy-center:\(.platform | x):\(.name | @uri | x):\(.at)</id>",
    "    <updated>\(.at | todate)</updated>",
    (if $link != "" then "    <link href=\"\($link | x)\"/>" else empty end),
    "  </entry>"),
  "</feed>"' "$out/status.json" > "$out/feed.xml"

echo "$(jq '.projects | length' "$out/status.json") project(s), $(jq '.timeline | length' "$out/status.json") deploy(s) in $out/"
