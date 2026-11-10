#!/bin/bash
# A stand-in for curl, as the providers call it: logs "curl METHOD URL" to $CALLS and answers
# from $FIXTURES/<p>/<METHOD>_<path>.json, where <p> is the folder whose HOST file names the
# URL's host and <path> is the URL path and query with every other character as "_".
# A fixture holds the body, a newline and the HTTP status (what `-w '\n%{http_code}'` prints).
# No fixture: 404. CURLSTUB=401|503|down answers every call with that error instead.
# The key comes on stdin (-K -) and must never be needed here. A provider that puts the URL
# itself in that config (hook: `curl -K -` with url, request, output and write-out lines) gets
# them read from it: then the body goes to the output file and only the status is printed.
cfg="$(cat)"
m=GET; prev=""; for a in "$@"; do [ "$prev" = -X ] && m="$a"; prev="$a"; done
url="${*: -1}"; out=""
cfgval() { printf '%s\n' "$cfg" | sed -n "s/^$1 = \"\(.*\)\"\$/\1/p" | head -n 1; }
if [ "$url" = - ] && [ -n "$(cfgval url)" ]; then
  url="$(cfgval url)"; m="$(cfgval request)"; m="${m:-GET}"; out="$(cfgval output)"
fi
# answer <body+status>: as -w '\n%{http_code}' prints it, or split for an output file.
answer() {
  if [ -n "$out" ]; then printf '%s\n' "$1" | sed '$d' > "$out"; printf '%s' "$(printf '%s\n' "$1" | tail -n 1)"
  else printf '%s' "$1"; fi
}
echo "curl $m $url" >> "${CALLS:-/dev/null}"
case "${CURLSTUB:-}" in
  401) answer "$(printf '%s\n401' '{"message":"unauthorized"}')"; exit 0 ;;
  503) answer "$(printf '%s\n503' '{"message":"unavailable"}')"; exit 0 ;;
  down) echo "curl: (28) Operation timed out" >&2; exit 28 ;;
esac
host="${url#*://}"; host="${host%%/*}"; path="${url#*://*/}"
key="$(printf '%s' "$path" | sed 's/[^A-Za-z0-9.-]/_/g; s/_*$//')"
for d in "${FIXTURES:?}"/*/; do
  [ "$(cat "$d/HOST" 2>/dev/null)" = "$host" ] || continue
  [ -f "$d/${m}_$key.json" ] || continue
  if [ -n "$out" ]; then answer "$(cat "$d/${m}_$key.json")"; else cat "$d/${m}_$key.json"; fi
  exit 0
done
answer "$(printf '%s\n404' '{"message":"no fixture"}')"
