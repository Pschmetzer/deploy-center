#!/bin/bash
# A stand-in for the vercel CLI: `vercel api <path> [--method M] [--input f]` logs
# "vercel METHOD path" to $CALLS and answers from $FIXTURES/vercel/<METHOD>_<path>.json (body,
# newline, status; the teamId parameter is left out of <path>). A status other than 2xx is a
# failure with the CLI's kind of message on stderr. VSTUB=down: not logged in.
echo "vercel $*" >> "${CALLS:-/dev/null}"
[ "${VSTUB:-}" = down ] && { echo "Error: You are not logged in" >&2; exit 1; }
case "${1:-}" in
  whoami) echo "tester"; exit 0 ;;
  api) ;;
  *) exit 1 ;;
esac
[ "${2:-}" = --help ] && exit 0
path="$2"; shift 2; m=GET
while [ $# -gt 0 ]; do case "$1" in --method) m="$2"; shift;; --input) cat "$2" >/dev/null; shift;; esac; shift; done
key="$(printf '%s' "${path#/}" | sed -E 's/([?&])teamId=[^&]*/\1/; s/[?&]$//; s/&&/\&/' | sed 's/[^A-Za-z0-9.-]/_/g; s/_*$//')"
f="${FIXTURES:?}/vercel/${m}_$key.json"
[ -f "$f" ] || { echo "Error: Not Found (404) $m $path" >&2; exit 1; }
body="$(sed '$d' "$f")"; code="$(tail -n 1 "$f")"
case "$code" in 2*) printf '%s\n' "$body" ;; *) echo "Error: $(echo "$body" | jq -r '.error.message // "failed"' 2>/dev/null) ($code)" >&2; exit 1 ;; esac
