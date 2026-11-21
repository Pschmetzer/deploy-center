# shellcheck shell=bash
# deploys verify: ask the site of the newest deploy and roll back when it fails its check. Kept out of `deploys`
# (round 12 B, items 21, 23, 24). Sourced by deploys; uses resolve, safe_arg, site_url_of, duration_s, journal_add,
# team_on and the rest of the script's helpers. Exit codes: 0 healthy, 1 failed and rolled back, 2 failed and not
# rolled back, 3 nothing was checked (the die below is meant: a script must never read an error as "rolled back").

# What a curl exit code means for people: "DNS", "connection refused", "timeout", "TLS". Nothing for the rest.
verify_curl_reason() {
  case "$1" in
    6) echo "DNS: the name does not resolve" ;;
    7) echo "connection refused" ;;
    28) echo "timeout" ;;
    35|51|58|59|60|64|66|77|82|83|90|91) echo "TLS problem" ;;
    0) ;;
    *) echo "curl exit $1" ;;
  esac
}

# Asks <url> until it answers at all (not DNS, refused, timeout) or <warm> seconds have passed (at most warm/every+1 asks).
verify_warmup() {  # verify_warmup <url> <warm s> <every s> <max-time s>
  local u="$1" w="$2" ev="$3" mt="$4" n=0 max cx c
  [ "$ev" -gt 0 ] || ev=1
  max=$(( w / ev + 1 ))
  echo "Waiting for $u to answer (up to ${w}s)" >&2
  while [ "$n" -lt "$max" ]; do
    cx=0
    c="$(curl -sS -o /dev/null -w '%{http_code}' --proto =http,https --proto-redir =https -L --max-redirs 5 --connect-timeout 10 --max-time "$mt" -A "DeployCenter (verify)" "$u" 2>/dev/null)" || cx=$?
    case "$cx" in 6|7|28) ;; *) return 0 ;; esac
    n=$((n + 1)); [ "$n" -ge "$max" ] || sleep "$ev"
  done
  return 0
}

verify_main() {
  # verify <project> [--path /health] [--rollback-after 10] [--no-rollback] [--url <address>]
  # Once the newest deploy is ready: ask the site three times, 5 s apart. When every answer is
  # 5xx or none (a timeout), the check failed (as in the app: a fresh service may answer 502 for a
  # moment); then a countdown, and production goes back unless --no-rollback or Ctrl-C.
  # Exit 0 healthy, 1 failed and rolled back, 2 failed and not rolled back, 3 nothing was checked
  # (unknown project, not live, no address, a wrong option): a script must never read an error
  # as "rolled back". Redirects are followed (up to 5); with --path a 4xx fails as well.
  # --expect 200 (or 2xx): only that answer is healthy, so a 401 from deployment protection fails
  # too; an expected 3xx is asked without following. --follow is the default now (kept for scripts).
  die() { echo "${ERED}Error:${EPLAIN} $*" >&2; exit 3; }
  p="${1:?Usage: deploys verify <project> [--path /health] [--expect 200|2xx]}"; path=""; after=10; norb=""; url=""; expect=""; follow=(-L --max-redirs 5); tries=3; every=5; need=1; mtime=20; wto=30m; warm=0; ebody=""; shift
  while [ $# -gt 0 ]; do
    case "$1" in
      --path) path="${2:?Usage: deploys verify <project> --path /health}"; shift ;;
      --rollback-after) [ $# -ge 2 ] || die "--rollback-after takes seconds. Usage: deploys verify <project> --rollback-after 10"; after="$2"; shift ;;
      --no-rollback) norb=1 ;;
      --url) url="${2:?Usage: deploys verify <project> --url https://…}"; shift ;;
      --expect) [ $# -ge 2 ] || die "--expect takes a status like 200 or 2xx"; expect="$2"; shift
        case "$expect" in [1-5][0-9][0-9]|[1-5]xx) ;; *) die "--expect takes a status like 200 or 2xx" ;; esac ;;
      --follow) follow=(-L --max-redirs 3) ;;
      # --expect-body: the answer must contain this text (first MB; the text is never printed). --warmup 30s: a fresh
      # service that refuses connections or does not resolve yet is asked again every --every seconds for up to that
      # long before the tries start; --retry-connrefused is --warmup 30s.
      --expect-body) [ -n "${2:-}" ] || die "--expect-body takes the text the answer must contain"; case "$2" in *$'\n'*) die "--expect-body takes one line of text";; esac; ebody="$2"; shift ;;
      --warmup) warm="$(duration_s "${2:-}")" || die "--warmup takes a time: 30s or 2m"; shift ;;
      --retry-connrefused) [ "$warm" -gt 0 ] || warm=30 ;;
      # How hard it asks: --tries answers (default 3), --every seconds apart (5), at least --need of them good (1;
      # a slow cold start wants fewer tries, a strict check wants all), each answer within --max-time seconds (20).
      --tries) tries="${2:-}"; shift; case "$tries" in ''|*[!0-9]*|0) die "--tries takes a number of answers, 1 or more" ;; esac; tries="$((10#$tries))"; [ "$tries" -le 20 ] || die "--tries is at most 20" ;;
      --every) every="${2:-}"; shift; case "$every" in ''|*[!0-9]*) die "--every takes seconds, a number" ;; esac; every="$((10#$every))" ;;
      --need) need="${2:-}"; shift; case "$need" in ''|*[!0-9]*|0) die "--need takes how many good answers are enough, 1 or more" ;; esac; need="$((10#$need))" ;;
      --max-time) mtime="${2:-}"; shift; case "$mtime" in ''|*[!0-9]*|0) die "--max-time takes seconds, 1 or more" ;; esac; mtime="$((10#$mtime))" ;;
      # How long to wait for the build to finish before checking (default 30m): a stuck build must not hold this for ever.
      --watch-timeout) wto="${2:-}"; shift; duration_s "$wto" >/dev/null 2>&1 || die "--watch-timeout takes a time: 90s, 30m or 2h" ;;
      *) die "Unknown option $1. Usage: deploys verify <project> [--path /health] [--expect 200|2xx] [--follow] [--expect-body text] [--warmup 30s] [--retry-connrefused] [--tries 3] [--every 5] [--need 1] [--max-time 20] [--watch-timeout 30m] [--rollback-after 10] [--no-rollback] [--url <address>] [--json]" ;;
    esac
    shift
  done
  [ "$need" -le "$tries" ] || die "--need $need is more than --tries $tries: no check could pass"
  # The check failed when this many answers are bad (with the defaults: all three).
  badlimit=$((tries - need + 1))
  case "$after" in ''|*[!0-9]*) die "--rollback-after takes seconds, a number";; esac
  after="$((10#$after))"   # 08 is eight: bash would read it as a bad octal number mid-countdown
  # "<p>:<name>" works too: the platform from it, the bare name for its API.
  # The platform's own id for its calls, the bare name for people and the journal.
  safe_arg "$p"; resolve "$p"; plat="$PLAT"; vid="$PID"; p="$PNAME"
  # A check while the build still runs would test what was live before.
  wrc=0; "$SELF" watch "$plat:$p" --timeout "$wto" >&2 || wrc=$?
  [ "$wrc" != 4 ] || die "The newest deploy of $p did not finish within $wto (--watch-timeout); nothing was checked"
  [ "$wrc" = 0 ] || die "The newest deploy of $p is not live; nothing to check"
  # A failed lookup is "no address known", with the hint below, not a silent stop.
  [ -n "$url" ] || url="$(site_url_of "$vid" "$plat")" || url=""
  [ -n "$url" ] || die "No address known for $p (give one with --url)"
  # FEA-033: without --path, the project's `checks` in deploy-center.json (["/health",
  # {"path":"/api","expect":"2xx"}]) are each asked; one failing fails the check. HTTP only:
  # a shared file never names a command to run here.
  clist=""
  if [ -z "$path" ] && team_on; then
    clist="$(team_effective 2>/dev/null | jq -r --arg p "$p" --arg e "$expect" '(.projects[$p].checks.value // [])
      | if type == "array" then .[] else empty end
      | if type == "string" then {path:.} elif type == "object" and (.path | type) == "string" then . else empty end
      | select(.path | test("^/?[A-Za-z0-9._~!$&()*+,;=:@%/?-]*$"))
      | "\(.path)\u001f\(.expect // $e | tostring)"' 2>/dev/null)" || clist=""
  fi
  # Without --path or checks: the health path of the shared config (deploy-center.json "health").
  if [ -z "$clist" ] && [ -z "$path" ] && team_on; then
    path="$(team_eff_once | jq -r --arg n "$p" '.projects[$n].health.value // empty | strings' 2>/dev/null)" || path=""
    [ -z "$path" ] || echo "Checking $path (health in the shared config)" >&2
  fi
  # Fields split by \037 (unit separator): a tab is whitespace to read and would drop an empty path.
  [ -n "$clist" ] || clist="$path"$'\037'"$expect"
  bodyf=""; [ -z "$ebody" ] || { bodyf="$(mktemp)"; trap_fn exit_rm "$bodyf"; }
  [ "$warm" = 0 ] || verify_warmup "$url" "$warm" "$every" "$mtime"
  codes=""; target=""; cjson="[]"; failed=0
  while IFS=$'\037' read -r cpath cexp <&3; do
    case "$cexp" in ''|[1-5][0-9][0-9]|[1-5]xx) ;; *) echo "verify: \"$cexp\" is not a status like 200 or 2xx; the check of $cpath counts 5xx" >&2; cexp="" ;; esac
    case "$cpath" in ''|/*) ;; *) cpath="/$cpath";; esac
    ctarget="${url%/}$cpath"; [ -n "$cpath" ] || ctarget="$url"
    ccodes=""; cbad=0; creason=""; cfollow=(${follow[@]+"${follow[@]}"})
    case "$cexp" in 3*) cfollow=() ;; esac
    for ((i = 1; i <= tries; i++)); do
      cx=0; pre=$cbad
      c="$(curl -sS -o "${bodyf:-/dev/null}" -w '%{http_code}' --proto =http,https --proto-redir =https ${cfollow[@]+"${cfollow[@]}"} --connect-timeout 10 --max-time "$mtime" -A "DeployCenter (verify)" "$ctarget" 2>/dev/null)" || cx=$?
      [ -n "$c" ] || c=000
      why="$(verify_curl_reason "$cx")"; [ -z "$why" ] || creason="$why"
      ccodes="$ccodes${ccodes:+ }$c"
      if [ -n "$cexp" ]; then
        case "$cexp" in *xx) [ "${c:0:1}" = "${cexp:0:1}" ] || cbad=$((cbad + 1)) ;; *) [ "$c" = "$cexp" ] || cbad=$((cbad + 1)) ;; esac
      else case "$c" in 000|5*) cbad=$((cbad + 1));; 4*) [ -z "$cpath" ] || cbad=$((cbad + 1));; esac; fi
      # The text must be in the answer, too (counted once per try).
      if [ -n "$ebody" ] && [ "$cbad" = "$pre" ] && ! head -c 1048576 "$bodyf" 2>/dev/null | grep -qF -- "$ebody"; then
        cbad=$((cbad + 1)); creason="the answer does not contain the expected text"
      fi
      echo "$(date +%H:%M:%S)  $c  $ctarget${why:+  ($why)}" >&2
      [ "$i" = "$tries" ] || sleep "$every"
    done
    cjson="$(echo "$cjson" | jq -c --arg u "$ctarget" --arg c "$ccodes" --arg r "$creason" --argjson h "$([ "$cbad" -lt "$badlimit" ] && echo true || echo false)" \
      '. + [{url:$u, codes:($c | split(" ") | map(tonumber)), healthy:$h} + (if $r == "" then {} else {reason:$r} end)]')"
    # The first failing check (else the first) is the one named, as one check was before.
    if [ -z "$target" ] || { [ "$cbad" -ge "$badlimit" ] && [ "$failed" = 0 ]; }; then target="$ctarget"; codes="$ccodes"; fi
    [ "$cbad" -lt "$badlimit" ] || failed=$((failed + 1))
  done 3<<< "$clist"
  report() {  # report <healthy> <rolledBack> <cancelled> <exit code>
    if [ "$json" = 1 ]; then
      jq -n --arg p "$p" --arg u "$target" --arg c "$codes" --argjson h "$1" --argjson r "$2" --argjson x "$3" --argjson cs "$cjson" \
        '{project:$p, url:$u, codes:($c | split(" ") | map(tonumber)), healthy:$h, rolledBack:$r, cancelled:$x, checks:$cs}'
    fi
    exit "$4"
  }
  if [ "$failed" = 0 ]; then
    [ "$json" = 1 ] || echo "${GREEN}ok${PLAIN}: $p answers ($codes)."
    report true false false 0
  fi
  [ "$json" = 1 ] || echo "${RED}$p fails its check${PLAIN} ($codes from $target)."
  if [ -n "$norb" ]; then [ "$json" = 1 ] || echo "Not rolled back (--no-rollback)."; report false false false 2; fi
  stop=""; trap 'stop=1' INT TERM
  for ((s = after; s > 0; s--)); do
    printf '\rRolling back %s in %2d s – Ctrl-C to stop ' "$p" "$s" >&2
    sleep 1
    [ -z "$stop" ] || break
  done
  trap - INT TERM
  [ "$after" = 0 ] || echo >&2
  if [ -n "$stop" ]; then
    [ "$json" = 1 ] || echo "Rollback stopped; $p stays on the deploy that failed its check."
    journal_add "$plat" "$p" skipped "Check failed ($codes), rollback stopped by hand"
    report false false true 2
  fi
  if out="$(DEPLOYS_NO_JOURNAL=1 "$SELF" "$plat" rollback "$vid" 2>&1)"; then
    journal_add "$plat" "$p" other "Rolled back: $target answered $codes"
    [ "$json" = 1 ] || echo "Rolled back $p to the deploy before."
    report false true false 1
  fi
  echo "$out" >&2
  journal_add "$plat" "$p" failed "Check failed ($codes) and the rollback failed too"
  report false false false 2
}
