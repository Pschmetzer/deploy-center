# shellcheck shell=bash
# lib/domains.sh — `deploys domains [--warn 30] [--json]`: the address of every project and how long its TLS certificate
# lasts, custom domains apart from the platform's own (name.vercel.app, onrender.com ...). Exit 1 when one is inside
# the warning threshold or has expired. A host that cannot be reached is "unknown", not a failure.
# Registration expiry is not read (no whois): only the certificate. Sourced by deploys; uses all_json, cert_days_left, table.

# domains_from <warn days> <now unused>: stdin is TSV lines `platform<TAB>project<TAB>host<TAB>days` (days empty = unknown).
domains_from() {
  jq -cRs --argjson warn "$1" '
    def platformhost: test("(\\.vercel\\.app|\\.onrender\\.com|\\.netlify\\.app|\\.pages\\.dev|\\.workers\\.dev|\\.fly\\.dev|\\.herokuapp\\.com|\\.railway\\.app|\\.up\\.railway\\.app|\\.amplifyapp\\.com|\\.web\\.app|\\.firebaseapp\\.com)$");
    [ split("\n")[] | select(length > 0) | split("\t")
      | {platform:.[0], name:.[1], host:.[2], daysLeft:(if (.[3] // "") == "" then null else (.[3] | tonumber) end)}
      | . + {kind:(if (.host | platformhost) then "platform" else "custom" end)}
      | . + {state:(if .daysLeft == null then "unknown" elif .daysLeft < 0 then "expired" elif .daysLeft < $warn then "warn" else "ok" end)} ]
    | {warnDays:$warn, domains:., problems:([.[] | select(.state == "warn" or .state == "expired")] | length)}'
}

domains_print() {  # stdin: domains JSON
  jq -r '.domains[] | [.platform, .name, .host, .kind, (if .daysLeft == null then "unknown" elif .daysLeft < 0 then "expired \(-.daysLeft) days ago" else "\(.daysLeft) days" end), (if .state == "warn" then "RENEW SOON" elif .state == "expired" then "EXPIRED" else "" end)] | @tsv' \
    | (printf 'PLATFORM\tPROJECT\tHOST\tKIND\tCERT LEFT\tNOTE\n'; cat) | table
}

domains_main() {
  local warn=30 rc=0 all hosts rows pl nm h d out
  while [ "$#" -gt 0 ]; do
    case "$1" in
      --warn) case "${2:-}" in ''|*[!0-9]*|0) die "--warn takes a number of days, 1 or more" ;; esac; warn="$2"; shift ;;
      *) die "Unknown option $1. Usage: deploys domains [--warn 30] [--json]" ;;
    esac
    shift
  done
  command -v openssl >/dev/null 2>&1 || die "openssl is missing: the certificates cannot be read."
  all="$(all_json)" || rc=$?
  hosts="$(echo "$all" | jq -r '.[] | .platform as $pl | .name as $n | [.domain, .url] | map(select(. != null and . != "") | sub("^[a-z]+://"; "") | sub("[/:].*$"; "")) | unique | .[] | "\($pl)\t\($n)\t\(.)"')"
  rows=""
  while IFS=$'\t' read -r pl nm h; do
    [ -n "$h" ] || continue
    d="$(cert_days_left "$h")"
    rows="$rows$pl"$'\t'"$nm"$'\t'"$h"$'\t'"$d"$'\n'
  done <<< "$hosts"
  out="$(printf '%s' "$rows" | domains_from "$warn")"
  if [ "${json:-0}" = 1 ]; then echo "$out" | jq .; else echo "$out" | domains_print; fi
  [ "$(echo "$out" | jq .problems)" = 0 ] || exit 1
  exit "$rc"
}
