#!/bin/bash
# deploys-journal.sh — an Alfred Script Filter: search the journal of the last 90 days (deploys, failures,
# rollbacks, forced starts) from `deploys journal export`. Read-only: it starts nothing.
#
#   integrations/alfred/deploys-journal.sh [query]
#
# Every word of the query must be in the project, platform, result or text. Newest first, 40 at most.
# ↵ shows the project in Deploy Center (deploycenter://select?project=…); ⌘C copies the line.
#
# Env: DEPLOYS  the CLI (default: the app bundle, then deploys on PATH)
set -uo pipefail
export PATH="$PATH:/opt/homebrew/bin:/usr/local/bin"
query="$(printf '%s' "${1:-}" | tr '[:upper:]' '[:lower:]')"

bin="${DEPLOYS:-}"
if [ -z "$bin" ]; then
  for c in "/Applications/Deploy Center.app/Contents/Resources/deploys" "$HOME/Applications/Deploy Center.app/Contents/Resources/deploys"; do
    [ -x "$c" ] && { bin="$c"; break; }
  done
  [ -n "$bin" ] || bin="$(command -v deploys 2>/dev/null)"
fi
say() { jq -nc --arg t "$1" --arg s "$2" '{items:[{title:$t, subtitle:$s, valid:false}]}'; exit 0; }
command -v jq >/dev/null 2>&1 || { printf '{"items":[{"title":"jq is missing","subtitle":"brew install jq","valid":false}]}\n'; exit 0; }
if [ -z "$bin" ] || ! command -v "$bin" >/dev/null 2>&1; then
  say "deploys not found" "Install Deploy Center, or set DEPLOYS in the workflow's environment"
fi

since="$(jq -nr 'now - 90 * 86400 | strftime("%Y-%m-%d")')"
csv="$("$bin" journal export --since "$since" </dev/null 2>/dev/null)"
case "$csv" in "at,platform,name,result,detail"*) ;; *) say "Could not read the journal" "Run deploys journal export in a terminal to see why" ;; esac

# The CSV has quoted fields ("" for a quote) and a detail may run over lines: awk joins the lines of an
# open quote with a space, jq then splits each record into its five fields.
awk '{ line = (carry != "" ? carry " " $0 : $0); n = gsub(/"/, "\"", line); if (n % 2) { carry = line } else { print line; carry = "" } }
     END { if (carry != "") print carry }' <<<"$csv" | tail -n +2 \
  | jq -Rc 'def csvline: [match("(?:\"((?:[^\"]|\"\")*)\"|([^,\"]*))(?:,|$)"; "g") | (.captures[0].string // .captures[1].string // "") | gsub("\"\""; "\"")];
            (csvline + ["", "", "", "", ""])[0:5]
            # The CLI puts a quote before a leading = + - @ (a spreadsheet would read a formula): taken off.
            | map(if test("^'"'"'[=+@\\t-]") then .[1:] else . end)
            | {at: .[0], platform: .[1], name: .[2], result: .[3], detail: .[4]}' \
  | jq -sc --arg q "$query" '
      ($q | split(" ") | map(select(. != ""))) as $w
      | map(select(. as $r | ("\($r.name) \($r.platform) \($r.result) \($r.detail) \($r.at)" | ascii_downcase) as $hay | all($w[]; . as $x | $hay | contains($x))))
      | sort_by(.at) | reverse | .[0:40]
      | {cache: {seconds: 30, loose_reload: true},
         items: (if length == 0 then [{title: (if $q == "" then "The journal is empty" else "No entry matches" end), valid: false}]
                 else map({
                   skipknowledge: true,
                   title: "\(.name) · \(.result)",
                   subtitle: "\(.at | sub("T"; " ") | .[0:16]) · \(.detail | gsub("[[:cntrl:]]"; " "))",
                   arg: "deploycenter://select?project=\(.name | @uri)",
                   text: {copy: "\(.at) \(.platform):\(.name) \(.result) \(.detail)", largetype: .detail}
                 }) end)}'
