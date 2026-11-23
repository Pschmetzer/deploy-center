#!/bin/bash
# scripts/bench.sh — how fast is the CLI with a large account? A fake platform with N projects (default 200),
# a fake gh and nothing on the network. Prints one line per measurement: wall time and how many times jq, date,
# gh, tr and sed were started (a spawn is the cost on macOS: about 5 ms each).
#
#   bash scripts/bench.sh [N]            the table; always exit 0 (CI runs it without blocking)
#   BENCH_MAX_MS=8000 bash scripts/bench.sh   exit 1 when one run is slower than that (for a local check)
#   bash scripts/bench.sh --compare "status --json"   one command, e.g. to try a change
#
# Nothing here touches a real account: the config is a temp folder, the provider is made up (`fake`).
set -uo pipefail
here="$(cd "$(dirname "$0")/.." && pwd)"
n=200; only=""
while [ $# -gt 0 ]; do
  case "$1" in
    --compare) only="${2:?--compare takes a command}"; shift ;;
    ''|*[!0-9]*) echo "Usage: bash scripts/bench.sh [N] [--compare \"<deploys arguments>\"]" >&2; exit 2 ;;
    *) n="$1" ;;
  esac
  shift
done
command -v jq >/dev/null 2>&1 || { echo "bench: jq is needed" >&2; exit 2; }

w="$(mktemp -d)"; trap 'rm -rf "$w"' EXIT
mkdir -p "$w/dd/providers" "$w/cfg" "$w/bin" "$w/count"
cp "$here/deploys" "$w/dd/deploys"; cp -R "$here/lib" "$w/dd/lib"
cat > "$w/dd/providers/fake.sh" <<'PROV'
fake_meta() { printf '{"id":"fake","label":"Fake","noun":"project","defaultOn":true,"keyEnv":["FAKE_KEY"],"keychain":"deploy-center-fake","caps":{"off":false,"sha":false,"cancel":false,"rollback":false,"logs":false,"preview":false}}\n'; }
fake_ready() { return 0; }
fake_json() {
  jq -n --argjson n "${BENCH_N:-200}" '[range($n) | {name:"proj-\(.)", id:"p\(.)", auto:true, deployable:true, paused:false,
    repo:"acme/repo-\(. % 150)", ref:"main", lastAt:1700000000, lastState:"ready", lastSha:"aaaa", fetchError:null, phase:"ready"}]'
}
PROV
echo '{"enabled":["fake"]}' > "$w/cfg/providers.json"
# gh: the branch head is bbbb, two commits past aaaa. Every answer is canned.
cat > "$w/bin/gh" <<'GH'
#!/bin/bash
case "$*" in
  *rate_limit*) echo '{"remaining":4000,"limit":5000,"reset":0}' ;;
  *"/commits/main"*) echo '{"sha":"bbbb","commit":{"message":"head\nbody","committer":{"date":"2026-01-02T00:00:00Z"}}}' ;;
  *"/compare/"*) echo '{"ahead_by":2,"status":"ahead","commits":[
      {"sha":"c1","commit":{"message":"fix: one (#11)","committer":{"date":"2026-01-01T00:00:00Z"}}},
      {"sha":"bbbb","commit":{"message":"head bbbb","committer":{"date":"2026-01-02T00:00:00Z"}}}]}' ;;
  *"pulls?state=open"*) echo '[]' ;;
  *) exit 1 ;;
esac
GH
chmod +x "$w/bin/gh"
# Counting stand-ins for the tools whose starts we count: they note the start, then run the real one.
for t in jq date tr sed; do
  real="$(command -v "$t")" || continue
  printf '#!/bin/bash\n: >> "%s/count/%s.$$.$RANDOM"\nexec "%s" "$@"\n' "$w" "$t" "$real" > "$w/cnt-$t"
  chmod +x "$w/cnt-$t"
done

run() {  # run <label> <deploys arguments...>: the time without counting, then the starts with counting
  local label="$1"; shift
  local t0 t1 ms c out
  export PATH="$w/bin:$PATH" DEPLOYS_CONFIG="$w/cfg" DEPLOYS_DIR="$w/dd" BENCH_N="$n" HOME="$w" NO_COLOR=1
  t0="$(date +%s%N 2>/dev/null)"; case "$t0" in *N|"") t0="$(python3 -c 'import time;print(int(time.time()*1e9))')" ;; esac
  "$w/dd/deploys" "$@" > "$w/out.$label" 2>"$w/err.$label"; local rc=$?; [ -z "${BENCH_SHOW_ERR:-}" ] || head -3 "$w/err.$label" >&2
  t1="$(date +%s%N 2>/dev/null)"; case "$t1" in *N|"") t1="$(python3 -c 'import time;print(int(time.time()*1e9))')" ;; esac
  ms=$(( (t1 - t0) / 1000000 ))
  # The counting pass: the stand-ins first on PATH, named as the real tools.
  mkdir -p "$w/cbin"; for t in jq date tr sed; do [ -x "$w/cnt-$t" ] && ln -sf "$w/cnt-$t" "$w/cbin/$t"; done
  find "$w/count" -type f -delete
  PATH="$w/cbin:$PATH" "$w/dd/deploys" "$@" >/dev/null 2>&1
  c=""
  for t in jq date tr sed; do c="$c $t=$(find "$w/count" -name "$t.*" | wc -l | tr -d ' ')"; done
  printf '%-28s %6d ms  rc=%s  starts:%s\n' "$label" "$ms" "$rc" "$c"
  BENCH_LAST_MS="$ms"
}

worst=0
if [ -n "$only" ]; then
  # shellcheck disable=SC2086
  run "$only" $only; worst="$BENCH_LAST_MS"
else
  echo "bench: $n projects, fake platform and fake gh"
  for cmd in "fake json" "status --no-github --json" "status --json" "changed --json"; do
    # shellcheck disable=SC2086
    run "$cmd" $cmd; [ "$BENCH_LAST_MS" -le "$worst" ] || worst="$BENCH_LAST_MS"
  done
fi
if [ -n "${BENCH_MAX_MS:-}" ] && [ "$worst" -gt "$BENCH_MAX_MS" ]; then echo "bench: slowest run $worst ms is over BENCH_MAX_MS=$BENCH_MAX_MS" >&2; exit 1; fi
exit 0
