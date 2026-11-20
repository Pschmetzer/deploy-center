#!/bin/bash
# report.sh — a weekly or monthly deploy report, as Markdown and HTML, from the journal: deploys, failures and
# the failure rate (against the period before), rollbacks, the busiest day, the projects, and the estimated saving
# of `deploys ledger`. Optionally a mail file. Nothing is sent: the .eml is a file you give to your own mail tool.
#
#   integrations/digest/report.sh                         last 7 days, into ./reports/ (.md and .html)
#   integrations/digest/report.sh --period month          last 30 days
#   integrations/digest/report.sh --days 14 --out out     any number of days (1 to 365)
#   integrations/digest/report.sh --format md --print     Markdown on stdout, no files
#   integrations/digest/report.sh --mail-file report.eml --to team@example.com --from deploys@example.com
#   integrations/digest/report.sh --lang de --title "Deploy-Bericht Acme"
#
# Options: --period week|month  --days N  --out DIR  --format md|html|both  --lang en|de  --title TEXT
#          --mail-file FILE (needs --to and --from: plain addresses, several with commas)  --no-savings
#          --details (the error text of the latest failures; off, because it can hold paths or names)  --print
#
# The numbers are `deploys digest --json`, asked twice (the period, and twice the period for the one before), so
# this needs the CLI of this release. The saving needs the network (`deploys ledger`) and is left out, with a
# line that says so, when it cannot be read. Reads only; starts nothing.
#
# Env: DEPLOYS             the CLI to call (default: deploys on PATH)
#      DEPLOYS_REPORT_NOW  the time to make the report for, in seconds since 1970 (tests; default: now)
set -euo pipefail
DEPLOYS="${DEPLOYS:-deploys}"

period=week days="" out=reports format=both lang=en title="" mail="" to="" from="" savings=1 details=0 print=0
while [ $# -gt 0 ]; do
  case "$1" in
    --period) period="${2:?--period week|month}"; shift ;;
    --days) days="${2:?--days N}"; shift ;;
    --out) out="${2:?--out DIR}"; shift ;;
    --format) format="${2:?--format md|html|both}"; shift ;;
    --lang) lang="${2:?--lang en|de}"; shift ;;
    --title) title="${2:?--title TEXT}"; shift ;;
    --mail-file) mail="${2:?--mail-file FILE}"; shift ;;
    --to) to="${2:?--to ADDRESS}"; shift ;;
    --from) from="${2:?--from ADDRESS}"; shift ;;
    --no-savings) savings=0 ;;
    --details) details=1 ;;
    --print) print=1 ;;
    -h|--help) sed -n '2,/^set /p' "$0" | sed -e '$d' -e 's/^# \{0,1\}//'; exit 0 ;;
    *) echo "Unknown option $1. See --help." >&2; exit 1 ;;
  esac
  shift
done

case "$period" in week) pdays=7 ;; month) pdays=30 ;; *) echo "--period is week or month." >&2; exit 1 ;; esac
if [ -n "$days" ]; then
  case "$days" in ''|*[!0-9]*|0) echo "--days takes a number of days, 1 or more." >&2; exit 1 ;; esac
  [ "$days" -le 365 ] || { echo "--days: 365 at most." >&2; exit 1; }
  pdays="$days"; period="${days}d"
fi
case "$format" in md|html|both) ;; *) echo "--format is md, html or both." >&2; exit 1 ;; esac
case "$lang" in en|de) ;; *) echo "--lang is en or de." >&2; exit 1 ;; esac
now="${DEPLOYS_REPORT_NOW:-$(date +%s)}"; case "$now" in ''|*[!0-9]*) echo "DEPLOYS_REPORT_NOW must be seconds since 1970." >&2; exit 1 ;; esac
if [ -n "$mail" ]; then
  [ -n "$to" ] && [ -n "$from" ] || { echo "--mail-file needs --to and --from." >&2; exit 1; }
  # Plain addresses only: a name, a line break or a quote in a header would be a way to add headers.
  addr='^[A-Za-z0-9._%+-]+@[A-Za-z0-9.-]+\.[A-Za-z]{2,}$'
  case "$to$from" in *[[:cntrl:]]*) echo "--to and --from take plain addresses, no line breaks." >&2; exit 1 ;; esac
  case "$from" in *,*) echo "--from takes one address." >&2; exit 1 ;; esac
  [[ "$from" =~ $addr ]] || { echo "--from is not a plain address (name@example.com)." >&2; exit 1; }
  oldifs="$IFS"; IFS=,
  # shellcheck disable=SC2086
  set -- $to
  IFS="$oldifs"
  for a in "$@"; do [[ "$a" =~ $addr ]] || { echo "--to: \"$a\" is not a plain address (name@example.com)." >&2; exit 1; }; done
fi
if [ -z "$title" ]; then if [ "$lang" = de ]; then title="Deploy-Bericht"; else title="Deploy report"; fi; fi

digest() {  # digest <days> [--no-savings]
  local d="$1"; shift
  "$DEPLOYS" digest --days "$d" --json "$@" 2>/dev/null </dev/null
}
valid='type == "object" and (.deploys | type) == "number" and (.failures | type) == "number"'
nosav=(); [ "$savings" = 1 ] || nosav=(--no-savings)
cur="$(digest "$pdays" ${nosav[@]+"${nosav[@]}"})" || cur=""
jq -e "$valid" >/dev/null 2>&1 <<<"${cur:-null}" || { echo "Could not read the digest: \`$DEPLOYS digest --days $pdays --json\` gave no answer. Is the CLI current?" >&2; exit 1; }
# The period before is twice the period minus this one; a CLI that cannot say leaves the comparison out.
both="$(digest $((pdays * 2)) --no-savings)" || both=""
jq -e "$valid" >/dev/null 2>&1 <<<"${both:-null}" || both='null'

report="$(jq -c --argjson all "$both" --arg period "$period" --argjson now "$now" --argjson details "$details" '
  def rate($d; $f): if $d + $f == 0 then null else ($f * 1000 / ($d + $f) | round / 10) end;
  . as $c | ($all | if . == null then null else
     {deploys: ([.deploys - $c.deploys, 0] | max), failures: ([.failures - $c.failures, 0] | max)} end) as $prev
  | {period: $period, days: .days, since: (.since[0:10]), until: (.until[0:10]), generatedAt: $now,
     deploys, failures, failureRate: rate(.deploys; .failures), rollbacks, forced, skipped, cancelled,
     busiestDay,
     projects: [.projects[] | {name, platform, deploys, failures, failureRate: rate(.deploys; .failures)}],
     lastFailures: [.lastFailures[] | {at, name} + (if $details == 1 then {detail} else {} end)],
     savings: (.savings // null),
     savingsAsked: (.savingsAsked // false),
     previous: (if $prev == null then null else $prev + {failureRate: rate($prev.deploys; $prev.failures)} end)}' <<<"$cur")"

# The words, English and German.
texts='{
 "en": {"period":"Period","deploys":"Deploys","failures":"Failed","rate":"Failure rate","rollbacks":"Rolled back","forced":"Forced","busiest":"Busiest day",
        "projects":"Projects","project":"Project","platform":"Platform","latest":"Latest failures","savings":"Estimated saving",
        "noData":"Nothing in the journal for this time.","noSavings":"Not available (no ledger yet: deploys ledger).",
        "before":"before","savingsText":"about {usd} ({n} builds skipped since auto-deploy went off{since}). An estimate, not an invoice.",
        "savingsNoPrice":"{n} builds skipped since auto-deploy went off{since}; the price is unknown (deploys price set). An estimate.",
        "none":"none","footer":"Made with Deploy Center from the journal. Nothing was deployed to make it.","days":"days","on":" on "},
 "de": {"period":"Zeitraum","deploys":"Deploys","failures":"Fehlgeschlagen","rate":"Fehlerquote","rollbacks":"Zurückgerollt","forced":"Erzwungen","busiest":"Stärkster Tag",
        "projects":"Projekte","project":"Projekt","platform":"Plattform","latest":"Letzte Fehlschläge","savings":"Geschätzte Ersparnis",
        "noData":"Für diese Zeit steht nichts im Journal.","noSavings":"Nicht verfügbar (noch kein Ledger: deploys ledger).",
        "before":"davor","savingsText":"etwa {usd} ({n} Builds übersprungen, seit Auto-Deploy aus ist{since}). Eine Schätzung, keine Rechnung.",
        "savingsNoPrice":"{n} Builds übersprungen, seit Auto-Deploy aus ist{since}; der Preis ist unbekannt (deploys price set). Eine Schätzung.",
        "none":"keine","footer":"Erstellt mit Deploy Center aus dem Journal. Dafür wurde nichts deployt.","days":"Tage","on":" am "}}'
T="$(jq -c --arg l "$lang" '.[$l]' <<<"$texts")"

# Shared by both renderers: the lines of the report as data, so the Markdown and the HTML say the same.
common='
  def pct: if . == null then "–" else "\(.) %" end;
  def vs($p; $T): if $p == null then "" else " (\($T.before): \($p)" + (if ($p | type) == "number" then " %)" else ")" end) end;
  def usd: (. * 100 | round) as $c | "\($c / 100 | floor).\(($c % 100) | tostring | if length < 2 then "0" + . else . end)";
  def savtext($T): . as $r | if $r.savings == null then (if $r.savingsAsked then $T.noSavings else null end)
    else ((if $r.savings.since then $T.on + $r.savings.since[0:10] else "" end) as $since
          | (if $r.savings.usd != null then $T.savingsText | sub("\\{usd\\}"; "$" + ($r.savings.usd | usd)) else $T.savingsNoPrice end)
          | sub("\\{n\\}"; ($r.savings.skippedBuilds | tostring)) | sub("\\{since\\}"; $since)) end;
  def rows($T): [[$T.deploys, (.deploys | tostring), (.previous | if . then (.deploys | tostring) else null end)],
                 [$T.failures, (.failures | tostring), (.previous | if . then (.failures | tostring) else null end)],
                 [$T.rate, (.failureRate | pct), (.previous | if . then (.failureRate | pct) else null end)],
                 [$T.rollbacks, (.rollbacks | tostring), null], [$T.forced, (.forced | tostring), null]];'

md="$(jq -r --argjson T "$T" --arg title "$title" "$common"'
  def esc: tostring | gsub("[\\x00-\\x1f\\x7f]"; " ") | gsub("(?<c>[|`*_<>\\[\\]\\\\#])"; "\\" + .c);
  "# \($title | esc)", "",
  "\($T.period): \(.since) – \(.until) (\(.days) \($T.days))", "",
  (if .deploys + .failures + .rollbacks + .forced == 0 then $T.noData, ""
   else
     "| | | \(if .previous then $T.before else "" end) |", "|---|---:|---:|",
     (rows($T)[] | "| \(.[0]) | \(.[1]) | \(.[2] // "") |"), "",
     (if .busiestDay then "\($T.busiest): \(.busiestDay.day) (\(.busiestDay.deploys))", "" else empty end),
     (if (.projects | length) > 0 then
        "## \($T.projects)", "", "| \($T.project) | \($T.platform) | \($T.deploys) | \($T.failures) | \($T.rate) |", "|---|---|---:|---:|---:|",
        (.projects[] | "| \(.name | esc) | \(.platform | esc) | \(.deploys) | \(.failures) | \(.failureRate | pct) |"), "" else empty end),
     "## \($T.latest)", "",
     (if (.lastFailures | length) == 0 then "\($T.none)" else
        (.lastFailures[] | "- \(.at[0:16] | sub("T"; " ")) UTC \(.name | esc)" + (if has("detail") then ": \(.detail | esc)" else "" end)) end), ""
   end),
  "## \($T.savings)", "", (savtext($T) // $T.noSavings), "",
  "---", $T.footer' <<<"$report")"

html="$(jq -r --argjson T "$T" --arg title "$title" --arg lang "$lang" "$common"'
  def h: tostring | gsub("[\\x00-\\x1f\\x7f]"; " ") | @html;
  . as $r |
  "<!doctype html>",
  "<html lang=\"\($lang)\"><head><meta charset=\"utf-8\"><meta name=\"viewport\" content=\"width=device-width, initial-scale=1\">",
  "<meta name=\"color-scheme\" content=\"light dark\"><title>\($title | h)</title>",
  "<style>:root{--bg:#fafafa;--fg:#18181b;--muted:#71717a;--line:#e4e4e7;--bad:#b91c1c}@media (prefers-color-scheme:dark){:root{--bg:#0b0b0d;--fg:#e4e4e7;--muted:#a1a1aa;--line:#27272a;--bad:#f87171}}",
  "body{margin:0;background:var(--bg);color:var(--fg);font:15px/1.5 -apple-system,BlinkMacSystemFont,\"Segoe UI\",Roboto,Helvetica,Arial,sans-serif}main{max-width:44rem;margin:0 auto;padding:2rem 16px 3rem}",
  "h1{font-size:1.5rem;margin:0 0 .25rem}h2{font-size:.8rem;text-transform:uppercase;letter-spacing:.06em;color:var(--muted);margin:2rem 0 .5rem}",
  "table{border-collapse:collapse;width:100%}th,td{text-align:left;padding:.35rem .5rem;border-bottom:1px solid var(--line)}th{color:var(--muted);font-weight:600;font-size:.85rem}td.n,th.n{text-align:right;font-variant-numeric:tabular-nums}",
  ".muted,footer{color:var(--muted);font-size:.85rem}footer{margin-top:2rem;border-top:1px solid var(--line);padding-top:1rem}.bad{color:var(--bad)}</style></head><body><main>",
  "<h1>\($title | h)</h1>",
  "<p class=\"muted\">\($T.period | h): \(.since) – \(.until) (\(.days) \($T.days | h))</p>",
  (if .deploys + .failures + .rollbacks + .forced == 0 then "<p>\($T.noData | h)</p>"
   else
     "<table><thead><tr><th></th><th class=\"n\"></th>\(if .previous then "<th class=\"n\">\($T.before | h)</th>" else "" end)</tr></thead><tbody>",
     (rows($T)[] | "<tr><th scope=\"row\">\(.[0] | h)</th><td class=\"n\">\(.[1] | h)</td>\(if $r.previous then "<td class=\"n muted\">\(.[2] // "" | h)</td>" else "" end)</tr>"),
     "</tbody></table>",
     (if .busiestDay then "<p>\($T.busiest | h): \(.busiestDay.day) (\(.busiestDay.deploys))</p>" else empty end),
     (if (.projects | length) > 0 then
        "<h2>\($T.projects | h)</h2><table><thead><tr><th>\($T.project | h)</th><th>\($T.platform | h)</th><th class=\"n\">\($T.deploys | h)</th><th class=\"n\">\($T.failures | h)</th><th class=\"n\">\($T.rate | h)</th></tr></thead><tbody>",
        (.projects[] | "<tr><td>\(.name | h)</td><td>\(.platform | h)</td><td class=\"n\">\(.deploys)</td><td class=\"n\">\(.failures)</td><td class=\"n\">\(.failureRate | pct | h)</td></tr>"),
        "</tbody></table>" else empty end),
     "<h2>\($T.latest | h)</h2>",
     (if (.lastFailures | length) == 0 then "<p class=\"muted\">\($T.none | h)</p>" else
        "<ul>", (.lastFailures[] | "<li>\(.at[0:16] | sub("T"; " ")) UTC <b>\(.name | h)</b>" + (if has("detail") then ": \(.detail | h)" else "" end) + "</li>"), "</ul>" end)
   end),
  "<h2>\($T.savings | h)</h2><p>\((savtext($T) // $T.noSavings) | h)</p>",
  "<footer>\($T.footer | h)</footer></main></body></html>"' <<<"$report")"

stem="deploy-report-$period-$(jq -r '.until' <<<"$report")"
if [ "$print" = 1 ]; then
  case "$format" in html) printf '%s\n' "$html" ;; *) printf '%s\n' "$md" ;; esac
fi

wrote=""
if [ "$print" = 0 ] || [ -n "$mail" ]; then
  mkdir -p "$out"
  if [ "$print" = 0 ]; then
    if [ "$format" != html ]; then printf '%s\n' "$md" > "$out/$stem.md"; wrote="$wrote $out/$stem.md"; fi
    if [ "$format" != md ]; then printf '%s\n' "$html" > "$out/$stem.html"; wrote="$wrote $out/$stem.html"; fi
  fi
fi

if [ -n "$mail" ]; then
  mkdir -p "$(dirname "$mail")"
  b64() { printf '%s\n' "$1" | base64 | tr -d '\n' | fold -w 76; echo; }
  subject="$title ($(jq -r '.since + " – " + .until' <<<"$report"))"
  # A non-ASCII subject is encoded (RFC 2047); the bodies are base64, so no line is too long or needs quoting.
  if printf '%s' "$subject" | LC_ALL=C grep -q '[^ -~]'; then subject="=?UTF-8?B?$(printf '%s' "$subject" | base64 | tr -d '\n')?="; fi
  boundary="=_deploys_report_${now}"
  {
    printf 'From: %s\r\nTo: %s\r\n' "$from" "$to"
    printf 'Subject: %s\r\n' "$subject"
    printf 'Date: %s\r\n' "$(jq -nr --argjson t "$now" '$t | strftime("%a, %d %b %Y %H:%M:%S +0000")')"
    printf 'Message-ID: <deploy-report-%s-%s@deploys.invalid>\r\n' "$period" "$now"
    printf 'MIME-Version: 1.0\r\nX-Deploy-Center-Report: %s\r\n' "$period"
    printf 'Content-Type: multipart/alternative; boundary="%s"\r\n\r\n' "$boundary"
    printf -- '--%s\r\nContent-Type: text/plain; charset=utf-8\r\nContent-Transfer-Encoding: base64\r\n\r\n' "$boundary"
    b64 "$md" | sed 's/$/\r/'
    printf -- '--%s\r\nContent-Type: text/html; charset=utf-8\r\nContent-Transfer-Encoding: base64\r\n\r\n' "$boundary"
    b64 "$html" | sed 's/$/\r/'
    printf -- '--%s--\r\n' "$boundary"
  } > "$mail"
  wrote="$wrote $mail"
fi

if [ "$print" = 0 ]; then
  echo "Report for the last $pdays days:${wrote} (nothing was sent)"
fi
