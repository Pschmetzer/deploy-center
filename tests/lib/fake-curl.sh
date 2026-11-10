#!/bin/bash
# A stand-in for curl, as the providers call it: logs "curl METHOD URL" to $CALLS and answers
# from $FIXTURES/<p>/<METHOD>_<path>.json, where <p> is the folder whose HOST file names the
# URL's host and <path> is the URL path and query with every other character as "_".
# A fixture holds the body, a newline and the HTTP status (what `-w '\n%{http_code}'` prints).
# No fixture: 404. CURLSTUB=401|503|down answers every call with that error instead.
cat >/dev/null   # the key comes on stdin (-K -) and must never be needed here
m=GET; prev=""; for a in "$@"; do [ "$prev" = -X ] && m="$a"; prev="$a"; done
url="${*: -1}"
echo "curl $m $url" >> "${CALLS:-/dev/null}"
case "${CURLSTUB:-}" in
  401) printf '%s\n401' '{"message":"unauthorized"}'; exit 0 ;;
  503) printf '%s\n503' '{"message":"unavailable"}'; exit 0 ;;
  down) echo "curl: (28) Operation timed out" >&2; exit 28 ;;
esac
host="${url#*://}"; host="${host%%/*}"; path="${url#*://*/}"
key="$(printf '%s' "$path" | sed 's/[^A-Za-z0-9.-]/_/g; s/_*$//')"
for d in "${FIXTURES:?}"/*/; do
  [ "$(cat "$d/HOST" 2>/dev/null)" = "$host" ] || continue
  if [ -f "$d/${m}_$key.json" ]; then cat "$d/${m}_$key.json"; exit 0; fi
done
printf '%s\n404' '{"message":"no fixture"}'
