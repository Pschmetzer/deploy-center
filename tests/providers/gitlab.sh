#!/bin/bash
# Tests for the GitLab side of lib/githost.sh beyond tests/script-tests.sh: a passing failure is
# asked again and a hung glab ends, a private project's 404 is not "history rewritten", the MR a
# commit came from is asked once, open MRs past 100 are counted.
# No network: glab and curl are stand-ins. Run: bash tests/providers/gitlab.sh
set -uo pipefail
cd "$(dirname "$0")/../.." || exit 1
fails=0
ok()   { echo "ok   $1"; }
fail() { echo "FAIL $1: $2"; fails=$((fails+1)); }
expect() { [ "$2" = "$3" ] && ok "$1" || fail "$1" "expected [$3], got [$2]"; }

tmp="$(mktemp -d)"; trap 'rm -rf "$tmp"' EXIT
mkdir -p "$tmp/bin" "$tmp/config" "$tmp/out"
export CALLS="$tmp/calls.log" GSTATE="$tmp/gstate" CONFIG_DIR="$tmp/config"
# glab api --hostname <host> <path>: GFAIL=<path part> fails that call once with GFAIL_MSG;
# GHANG=<path part> never answers; PRIVATE=1 answers 404 for every path of the project.
cat > "$tmp/bin/glab" <<'GLAB'
#!/bin/bash
p="$4"; echo "glab $p" >> "$CALLS"
if [ -n "${GHANG:-}" ] && case "$p" in *"$GHANG"*) true;; *) false;; esac; then exec /bin/sleep 30; fi
if [ -n "${GFAIL:-}" ] && [ ! -f "$GSTATE" ] && case "$p" in *"$GFAIL"*) true;; *) false;; esac; then
  : > "$GSTATE"; echo "${GFAIL_MSG:-glab: 429 Too Many Requests (HTTP 429)}" >&2; exit 1
fi
[ -z "${PRIVATE:-}" ] || { echo "glab: 404 Not Found (HTTP 404)" >&2; exit 1; }
case "$p" in
  "projects/me%2Fapp/repository/compare?from=dead&to=main") echo "glab: 404 Not Found (HTTP 404)" >&2; exit 1 ;;
  "projects/me%2Fapp/repository/commits/main") echo '{"id":"bbbb"}' ;;
  "projects/me%2Fapp/repository/commits/c3/merge_requests") echo '[{"iid":13,"state":"merged"}]' ;;
  "projects/me%2Fapp/merge_requests?state=opened&per_page=100&page=1") jq -nc '[range(100) | {iid: ., author: {username: "ann"}}]' ;;
  "projects/me%2Fapp/merge_requests?state=opened&per_page=100&page=2") jq -nc '[range(30) | {iid: (. + 100), draft: true, author: {username: "renovate-bot"}}]' ;;
  "projects/big%2Fapp/merge_requests?state=opened&per_page=100&page="*) jq -nc '[range(100) | {iid: ., author: {username: "ann"}}]' ;;
  *) echo "glab: 404 Not Found (HTTP 404)" >&2; exit 1 ;;
esac
GLAB
printf '#!/bin/bash\necho "sleep $*" >> "$CALLS"\n' > "$tmp/bin/sleep"
chmod +x "$tmp/bin"/*
export PATH="$tmp/bin:$PATH"
# shellcheck source=../../lib/githost.sh
. ./lib/githost.sh
reset() { : > "$CALLS"; rm -f "$GSTATE"; }

# --- PRV-079: asked again, and a hung glab ends ---
reset
out="$(GFAIL=commits/main gitlab_api gitlab.com "projects/me%2Fapp/repository/commits/main" 2>/dev/null | jq -r .id)"
expect "a 429 is asked again" "$out:$(grep -c '^glab ' "$CALLS"):$(grep -c '^sleep 2' "$CALLS")" "bbbb:2:1"
reset
GFAIL=commits/main GFAIL_MSG="glab: 403 Forbidden (HTTP 403)" gitlab_api gitlab.com "projects/me%2Fapp/repository/commits/main" >/dev/null 2>"$tmp/err"; rc=$?
expect "a 403 is not asked again, and says why" "$rc:$(grep -c '^glab ' "$CALLS"):$(grep -c 'HTTP 403' "$tmp/err")" "1:1:1"
reset
start="$(date +%s)"
GHANG=commits/main DEPLOYS_GITLAB_TIMEOUT=1 gitlab_api gitlab.com "projects/me%2Fapp/repository/commits/main" >/dev/null 2>"$tmp/err"; rc=$?
took=$(( $(date +%s) - start ))
expect "a hung glab ends (three tries of 1 s)" "$rc:$(grep -c '^glab ' "$CALLS"):$([ "$took" -lt 10 ] && echo fast)" "1:3:fast"
expect "and says so" "$(grep -c 'no answer from glab' "$tmp/err")" "1"

# --- PRV-078: a 404 is "rewritten" only when the branch itself can be read ---
reset; rm -f "$tmp/out"/*
gitlab_pending_of gitlab.com/me/app dead main "$tmp/out"
expect "compare 404, branch readable: rewritten" "$(jq -c .value "$tmp/out"/gitlab.com_me_app_dead_main.json 2>/dev/null)" '{"rewritten":true}'
reset; rm -f "$tmp/out"/*
PRIVATE=1 gitlab_pending_of gitlab.com/me/app dead main "$tmp/out"
expect "a private project (404 everywhere): no record, not rewritten" "$(find "$tmp/out" -type f | wc -l | tr -d ' ')" "0"

# --- PRV-127: the MR a commit came from is asked once ---
reset
first="$(gitlab_mrs_of gitlab.com "me%2Fapp" c3)"; second="$(gitlab_mrs_of gitlab.com "me%2Fapp" c3)"
expect "merged MRs of a commit: asked once, then kept" "$first:$second:$(grep -c 'c3/merge_requests' "$CALLS")" "13:13:1"
reset
GFAIL=c9/merge_requests gitlab_mrs_of gitlab.com "me%2Fapp" c9 >/dev/null
expect "a failed answer is not kept" "$(find "$CONFIG_DIR/cache/gitlab-mrs" -name '*c9*' | wc -l | tr -d ' ')" "0"

# --- PRV-128: open MRs past 100 ---
reset
gitlab_open_prs_of gitlab.com/me/app "$tmp/out"
expect "open MRs: a second page is read" "$(jq -c .value "$tmp/out/gitlab.com_me_app.json"):$(grep -c 'merge_requests?state=opened' "$CALLS")" '{"all":130,"partial":false,"drafts":30,"bots":30}:2'
reset
gitlab_open_prs_of gitlab.com/big/app "$tmp/out"
expect "open MRs: at most five pages" "$(jq -c .value.all "$tmp/out/gitlab.com_big_app.json"):$(grep -c 'merge_requests?state=opened' "$CALLS")" "500:5"

# --- PRV-129: one file per key ---
expect "cache name: no _ of its own, as before" "$(githost_cache_name gitlab.com/me/app@main)" "gitlab.com_me_app_main"
a="$(githost_cache_name gitlab.com/a_b/c@main)"; b="$(githost_cache_name gitlab.com/a/b_c@main)"
expect "cache name: a_b/c and a/b_c are two files" "$([ "$a" != "$b" ] && echo two || echo one)" "two"
expect "cache name: deploys' cache_name is used when there" "$(cache_name() { printf 'cn-%s' "$1"; }; githost_cache_name x/y)" "cn-x/y"

echo
[ "$fails" = 0 ] && echo "All GitLab tests passed." || { echo "$fails GitLab test(s) failed."; exit 1; }
