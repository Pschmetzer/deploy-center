# shellcheck shell=bash
# lib/verify.sh - `deploys watch` and `deploys verify`, moved out of the script (it had grown past its ceiling in
# scripts/check-size.sh). Each is a function that takes the arguments the command had (the command word first), so
# `exit` and `die` end the script as they did in the case branch. Sourced by deploys; uses its helpers (watch_line,
# watch_final, watch_json, duration_s, resolve, site_url_of, journal_add, team_*, die_usage ...) and its globals.

watch_final() { case "$1" in ready|failed|canceled) return 0;; esac; return 1; }
# A wait of <n> seconds, a little different each time (up to a third more): twenty watches started together
# must not ask a platform at the same second for ever.
watch_jitter() { echo $(( $1 + RANDOM % ($1 / 3 + 1) )); }
# --json: the one line at the end of a watch: {project, id, phase, state, url}. phase: ready, failed, canceled,
# timeout (--timeout passed) or unreachable (the platform could not be asked). Nothing without --json.
watch_json() {  # watch_json <phase> <project> <id> [state] [url]
  [ "${json:-0}" = 1 ] || return 0
  jq -nc --arg ph "$1" --arg p "$2" --arg id "${3:-}" --arg st "${4:-$1}" --arg u "${5:-}" \
    '{project:$p, id:(if $id == "" then null else $id end), phase:$ph, state:$st, url:(if $u == "" then null else $u end)}'
}
# Ctrl-C of `watch a --and b`: every background watch and what it started.
watch_stop_all() {
  local j c
  for j in $(jobs -p); do
    for c in $(pgrep -P "$j" 2>/dev/null); do pkill -TERM -P "$c" 2>/dev/null; kill -TERM "$c" 2>/dev/null; done
    pkill -TERM -P "$j" 2>/dev/null; kill -TERM "$j" 2>/dev/null
  done
  return 0
}
watch_took() {
  if [ "$1" -ge 3600 ]; then printf '%dh%02dm\n' $(($1 / 3600)) $(($1 % 3600 / 60))
  elif [ "$1" -ge 60 ]; then echo "$(($1 / 60))m$(($1 % 60))s"; else echo "${1}s"; fi
}

watch_main() {
    # watch <project> [<deploy id>] [--preview] [--timeout 30m] [--interval 6s] [--quiet] [--json]
    # Follow one deploy until it is live or failed: the given one, or the newest (production, or
    # any target with --preview). If the newest is already finished, say so instead of "done".
    # Exit 0 live, 1 failed or canceled, 3 the platform could not be asked (or its answer not read) five times
    # in a row, or the key was refused (401/403: no waiting for that), 4 --timeout passed before it finished (it may
    # still go live; default: no limit). --json: one line at the end, {project,id,phase,state,url}; phase tells
    # failed from canceled. --quiet: no progress lines.
    p="${2:?Usage: deploys watch <project> [<deploy id>] [--preview] [--timeout 30m] [--interval 6s] [--quiet] [--json]}"; did=""; pv=""; maxw=""; wpoll=6
    # watch a --and b --and c: each followed at the same time (at most six at once), every line starting with its
    # project; the exit code is 1 if any failed, else 4 if any timed out, else 3 if any could not be asked, else 0.
    case " $* " in
      *" --and "*)
        wnames=("$p"); wshared=(); set -- "${@:3}"
        while [ $# -gt 0 ]; do
          case "$1" in
            --and) [ -n "${2:-}" ] || die "--and takes a project name"; case "$2" in -*) die "--and takes a project name";; esac; wnames+=("$2"); shift ;;
            *) wshared+=("$1") ;;
          esac; shift
        done
        # A deploy id belongs to one project: handing it to every project would watch the wrong (or no) deploy.
        wprev=""
        for wa in ${wshared[@]+"${wshared[@]}"}; do
          case "$wa" in -*) ;; *) case "$wprev" in --timeout|--interval) ;; *) die "A deploy id belongs to one project; with --and, watch the newest deploy of each (drop \"$wa\")." ;; esac ;; esac
          wprev="$wa"
        done
        wd="$(mktemp -d)"; wi=0
        # Ctrl-C: the background watches ignore SIGINT (a shell starts them so), so each is stopped here, with
        # what it started; and the folder goes on every way out.
        trap_fn exit_rmrf "$wd"
        trap 'watch_stop_all; exit 130' INT TERM
        for wn in "${wnames[@]}"; do
          wi=$((wi + 1))
          # At most six at once: a long list must not ask a platform for twenty answers every few seconds.
          while [ "$(jobs -r | wc -l | tr -d ' ')" -ge 6 ]; do sleep 0.2; done
          ( "$SELF" watch "$wn" ${wshared[@]+"${wshared[@]}"} 2>&1; echo $? > "$wd/$wi" ) | WNAME="$wn" perl -pe 'BEGIN { $| = 1 } s/^/[$ENV{WNAME}] /' &
        done
        wait
        wrc=0
        for ((wi = 1; wi <= ${#wnames[@]}; wi++)); do
          c="$(cat "$wd/$wi" 2>/dev/null || echo 3)"
          case "$c" in 0) ;; 1) wrc=1 ;; 4) [ "$wrc" = 1 ] || wrc=4 ;; *) [ "$wrc" = 1 ] || [ "$wrc" = 4 ] || wrc=3 ;; esac
        done
        exit "$wrc" ;;
    esac
    set -- "${@:3}"
    wquiet="${DEPLOYS_QUIET:-}"
    while [ $# -gt 0 ]; do
      case "$1" in
        --preview) pv=1 ;;
        --quiet) wquiet=1 ;;
        --timeout) maxw="$(duration_s "${2:-}")" || die "--timeout takes a time: 90s, 30m or 2h"; shift ;;
        --interval) wpoll="$(duration_s "${2:-}")" || die "--interval takes a time: 5s or 1m"; [ "$wpoll" -ge 2 ] || die "--interval is 2 seconds or more"; shift ;;
        -*) die "Unknown option $1. Usage: deploys watch <project> [<deploy id>] [--preview] [--timeout 30m] [--interval 6s] [--quiet] [--json]" ;;
        *) did="$1" ;;
      esac; shift
    done
    [ "$json" != 1 ] || wquiet=1
    resolve "$p"; plat="$PLAT"
    first=1; misses=0; waited=0; t0=$SECONDS; poll="$wpoll"; werr="$(mktemp)"; trap_fn exit_rm "$werr"; wlast=""
    while :; do
      if [ -n "$maxw" ] && [ "$waited" -ge "$maxw" ]; then
        echo "${ERED}Error:${EPLAIN} $p has not finished after $(watch_took "$waited") (--timeout); it may still go live: deploys watch $p${did:+ $did}" >&2
        watch_json timeout "$p" "${wlast:-$did}"; exit 4
      fi
      # The platform's own complaint is kept (not thrown away): a refused key ends the watch at once, and a
      # rate limit makes the wait longer instead of counting as a miss.
      : > "$werr"
      if [ -n "$did" ]; then raw="$("${plat}_status" "$PID" "$did" 2>"$werr")" || raw=""
      else raw="$("${plat}_latest" "$PID" ${pv:+--preview} 2>"$werr")" || raw=""; fi
      s="$(watch_line "$raw")"
      if [ -z "$s" ]; then
        if grep -qE 'HTTP (401|403)' "$werr" 2>/dev/null; then
          echo "${ERED}Error:${EPLAIN} $plat refused the key, so the deploy cannot be followed: $(grep -E 'HTTP (401|403)' "$werr" | head -n 1 | cut -c1-200)" >&2
          watch_json unreachable "$p" "${wlast:-$did}"; exit 3
        fi
        if grep -qiE 'HTTP 429|rate limit' "$werr" 2>/dev/null; then
          poll=$((poll * 2)); [ "$poll" -le 120 ] || poll=120
          [ -n "$wquiet" ] || printf '%s  (%s asks to slow down: next try in %ss)\n' "$(date +%H:%M:%S)" "$plat" "$poll" >&2
          sleep "$poll"; waited=$((waited + poll)); continue
        fi
        # A network blip is not a failed deploy: try again, and give up only after five in a row.
        # An answer whose phase cannot be read counts the same: it must never mean "wait for ever".
        misses=$((misses + 1))
        wwhy="$(grep -v '^[[:space:]]*$' "$werr" 2>/dev/null | tail -n 1 | cut -c1-160)"
        if [ -n "$raw" ]; then printf '%s  (could not read the answer of %s, try %s of 5)\n' "$(date +%H:%M:%S)" "$plat" "$misses" >&2
        else printf '%s  (could not ask %s, try %s of 5%s)\n' "$(date +%H:%M:%S)" "$plat" "$misses" "${wwhy:+: $wwhy}" >&2; fi
        [ "$misses" -lt 5 ] || { echo "Error: ${ERED}could not reach $plat; the deploy itself may be fine${EPLAIN}" >&2; watch_json unreachable "$p" "${wlast:-$did}"; exit 3; }
        sleep "$(watch_jitter "$poll")"; waited=$((waited + poll)); [ $((SECONDS - t0)) -le "$waited" ] || waited=$((SECONDS - t0)); [ "$waited" -lt 120 ] || [ "$poll" -ge 15 ] || poll=15; continue
      fi
      misses=0; poll="$wpoll"; IFS=$'\t' read -r id ph st <<<"$s"; wlast="$id"
      dbg "watch $p ($plat): id=$id phase=$ph state=$st, next ask in ${poll}s"
      [ "$id" != "none" ] || die "No deploy of $p found"
      if [ "$first" = 1 ] && [ -z "$did" ] && watch_final "$ph"; then
        [ -n "$wquiet" ] || echo "Nothing is building for $p. The newest deploy ($id) is $st."
        u=""; [ "$ph" != ready ] || [ "${json:-0}" != 1 ] || { u="$( ("${plat}_url" "$PID") 2>/dev/null || true)"; case "$u" in http*) ;; *) u="" ;; esac; }
        watch_json "$ph" "$p" "$id" "$st" "$u"
        case "$ph" in ready) exit 0;; *) exit 1;; esac
      fi
      first=0
      # The time since watch began, once there is some.
      [ -n "$wquiet" ] || printf '%s  %s%s\n' "$(date +%H:%M:%S)" "$st" "$([ "$waited" = 0 ] || echo "  ($(watch_took "$waited"))")"
      case "$ph" in
        ready) u="$( ("${plat}_url" "$PID") 2>/dev/null || true)"; case "$u" in http*) [ -n "$wquiet" ] && [ "$json" != 1 ] && echo "$u" || { [ -n "$wquiet" ] || echo "Live: $u"; } ;; *) u="" ;; esac
               watch_json ready "$p" "$id" "$st" "$u"; exit 0 ;;
        failed|canceled) watch_json "$ph" "$p" "$id" "$st"; exit 1 ;;
      esac
      sleep "$(watch_jitter "$poll")"; waited=$((waited + poll)); [ $((SECONDS - t0)) -le "$waited" ] || waited=$((SECONDS - t0)); [ "$waited" -lt 120 ] || [ "$poll" -ge 15 ] || poll=15
    done
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
    p="$2"; path=""; after=10; norb=""; url=""; expect=""; follow=(-L --max-redirs 5); tries=3; every=5; need=1; mtime=20; wto=30m; vmatch=""; vheader=""; certdays=""; warmup=0; retryconn=""; shift 2
    while [ $# -gt 0 ]; do
      case "$1" in
        --path) path="${2:?Usage: deploys verify <project> --path /health}"; shift ;;
        --rollback-after) [ $# -ge 2 ] || die "--rollback-after takes seconds. Usage: deploys verify <project> --rollback-after 10"; after="$2"; shift ;;
        --no-rollback) norb=1 ;;
        --url) url="${2:?Usage: deploys verify <project> --url https://…}"; shift ;;
        --expect) [ $# -ge 2 ] || die "--expect takes a status like 200 or 2xx"; expect="$2"; shift
          case "$expect" in [1-5][0-9][0-9]|[1-5]xx) ;; *) die "--expect takes a status like 200 or 2xx" ;; esac ;;
        --follow) follow=(-L --max-redirs 3) ;;
        # How hard it asks: --tries answers (default 3), --every seconds apart (5), at least --need of them good (1;
        # a slow cold start wants fewer tries, a strict check wants all), each answer within --max-time seconds (20).
        --tries) tries="${2:-}"; shift; case "$tries" in ''|*[!0-9]*|0) die "--tries takes a number of answers, 1 or more" ;; esac; tries="$((10#$tries))"; [ "$tries" -le 20 ] || die "--tries is at most 20" ;;
        --every) every="${2:-}"; shift; case "$every" in ''|*[!0-9]*) die "--every takes seconds, a number" ;; esac; every="$((10#$every))" ;;
        --need) need="${2:-}"; shift; case "$need" in ''|*[!0-9]*|0) die "--need takes how many good answers are enough, 1 or more" ;; esac; need="$((10#$need))" ;;
        --max-time) mtime="${2:-}"; shift; case "$mtime" in ''|*[!0-9]*|0) die "--max-time takes seconds, 1 or more" ;; esac; mtime="$((10#$mtime))" ;;
        # More than the status: --match <text> (the answer holds it), --header 'Name: part' (a response header has it),
        # --cert-days N (the TLS certificate lasts N more days), --warmup 30s (a fresh service may need a moment: asked
        # every two seconds until it answers), --retry-connrefused (curl asks again while the connection is refused).
        --match) vmatch="${2:?--match takes the text the answer must contain}"; shift ;;
        --header) vheader="${2:-}"; shift; case "$vheader" in *:*) ;; *) die "--header takes 'Name: part of the value'" ;; esac ;;
        --cert-days) certdays="${2:-}"; shift; case "$certdays" in ''|*[!0-9]*|0) die "--cert-days takes a number of days, 1 or more" ;; esac; certdays="$((10#$certdays))" ;;
        --warmup) warmup="$(duration_s "${2:-}")" || die "--warmup takes a time: 30s or 2m"; shift; [ "$warmup" -le 600 ] || die "--warmup is at most 10m" ;;
        --retry-connrefused) retryconn=1 ;;
        # How long to wait for the build to finish before checking (default 30m): a stuck build must not hold this for ever.
        --watch-timeout) wto="${2:-}"; shift; duration_s "$wto" >/dev/null 2>&1 || die "--watch-timeout takes a time: 90s, 30m or 2h" ;;
        *) die "Unknown option $1. Usage: deploys verify <project> [--path /health] [--expect 200|2xx] [--follow] [--tries 3] [--every 5] [--need 1] [--max-time 20] [--match <text>] [--header 'Name: part'] [--cert-days N] [--warmup 30s] [--retry-connrefused] [--watch-timeout 30m] [--rollback-after 10] [--no-rollback] [--url <address>] [--json]" ;;
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
    codes=""; target=""; cjson="[]"; failed=0
    # Every check is asked at the same time (at most six): a project with five paths takes as long as the slowest.
    vd="$(mktemp -d)"; trap_fn exit_rmrf "$vd"; vn=0; vtargets=()
    rcargs=(); [ -z "$retryconn" ] || rcargs=(--retry 3 --retry-connrefused --retry-delay 2)
    verify_check() {  # verify_check <n>: asks one check <tries> times; its files are $vd/<n>.codes .bad .log .why
      local n="$1" ctarget="$2" cexp="$3" cpath="$4" i c rc cbad=0 ccodes="" why="" whys="" log="$vd/$1.log" w=0 cfollow chdr
      cfollow=(${follow[@]+"${follow[@]}"}); case "$cexp" in 3*) cfollow=() ;; esac
      # --warmup: a service that was just deployed may need a moment; ask every two seconds until it answers at all.
      while [ "$w" -lt "$warmup" ]; do
        c="$(curl -sS -o /dev/null -w '%{http_code}' --proto =http,https --proto-redir =https --connect-timeout 5 --max-time "$mtime" -A "DeployCenter (verify)" "$ctarget" 2>/dev/null)" || true
        case "${c:-000}" in 000|5*) sleep 2; w=$((w + 2)) ;; *) break ;; esac
      done
      for ((i = 1; i <= tries; i++)); do
        rc=0; why=""
        c="$(curl -sS -o "$vd/$n.body" -D "$vd/$n.hdr" -w '%{http_code}' --proto =http,https --proto-redir =https ${cfollow[@]+"${cfollow[@]}"} ${rcargs[@]+"${rcargs[@]}"} --connect-timeout 10 --max-time "$mtime" -A "DeployCenter (verify)" "$ctarget" 2>"$vd/$n.err")" || rc=$?
        [ -n "$c" ] || c=000
        # Why there was no answer, in words: not found, refused, timed out, a TLS problem.
        if [ "$c" = 000 ]; then case "$rc" in
          6) why="DNS: the name was not found" ;; 7) why="the connection was refused" ;; 28) why="timed out after ${mtime}s" ;;
          35|51|58|59|60|77|83) why="TLS problem (certificate or handshake)" ;; 0) ;; *) why="curl exit $rc" ;; esac; fi
        ccodes="$ccodes${ccodes:+ }$c"
        local bad=0
        if [ -n "$cexp" ]; then
          case "$cexp" in *xx) [ "${c:0:1}" = "${cexp:0:1}" ] || bad=1 ;; *) [ "$c" = "$cexp" ] || bad=1 ;; esac
        else case "$c" in 000|5*) bad=1;; 4*) [ -z "$cpath" ] || bad=1;; esac; fi
        # --match <text>: the answer must hold it; --header 'Name: part': a header must have it.
        if [ "$bad" = 0 ] && [ -n "$vmatch" ] && ! head -c 1048576 "$vd/$n.body" 2>/dev/null | grep -qF -- "$vmatch"; then bad=1; why="the answer does not contain \"$vmatch\""; fi
        if [ "$bad" = 0 ] && [ -n "$vheader" ]; then
          chdr="$(tr -d '\r' < "$vd/$n.hdr" 2>/dev/null | awk 'BEGIN { RS = ""; ORS = "\n" } { b = $0 } END { print b }')"
          printf '%s\n' "$chdr" | grep -iqF -- "${vheader%%:*}:" && printf '%s\n' "$chdr" | grep -i -- "^${vheader%%:*}:" | grep -iqF -- "$(printf '%s' "${vheader#*:}" | sed 's/^ *//')" \
            || { bad=1; why="the header ${vheader%%:*} is missing or lacks \"$(printf '%s' "${vheader#*:}" | sed 's/^ *//')\""; }
        fi
        cbad=$((cbad + bad)); [ -z "$why" ] || whys="$whys${whys:+; }$why"
        echo "$(date +%H:%M:%S)  $c${why:+ ($why)}  $ctarget" >> "$log"
        [ "$i" = "$tries" ] || sleep "$every"
      done
      # --cert-days N: the TLS certificate must be good for N more days (the check fails, it is not rolled back for it alone... it is a failed check).
      if [ -n "$certdays" ]; then
        case "$ctarget" in https://*)
          if command -v openssl >/dev/null 2>&1; then
            local h="${ctarget#https://}"; h="${h%%/*}"; h="${h##*@}"; local port=443; case "$h" in *:*) port="${h##*:}"; h="${h%%:*}" ;; esac
            if ! openssl s_client -connect "$h:$port" -servername "$h" </dev/null 2>/dev/null | openssl x509 -noout -checkend $((certdays * 86400)) >/dev/null 2>&1; then
              cbad=$tries; whys="$whys${whys:+; }the certificate of $h ends within $certdays days (or could not be read)"
              echo "$(date +%H:%M:%S)  cert  $h: ends within $certdays days (or could not be read)" >> "$log"
            fi
          else echo "verify: --cert-days needs openssl, which is not here; the certificate was not checked" >> "$log"; fi ;;
        esac
      fi
      printf '%s' "$ccodes" > "$vd/$n.codes"; printf '%s' "$cbad" > "$vd/$n.bad"; printf '%s' "$whys" > "$vd/$n.why"
    }
    while IFS=$'\037' read -r cpath cexp <&3; do
      case "$cexp" in ''|[1-5][0-9][0-9]|[1-5]xx) ;; *) echo "verify: \"$cexp\" is not a status like 200 or 2xx; the check of $cpath counts 5xx" >&2; cexp="" ;; esac
      case "$cpath" in ''|/*) ;; *) cpath="/$cpath";; esac
      ctarget="${url%/}$cpath"; [ -n "$cpath" ] || ctarget="$url"
      vn=$((vn + 1)); vtargets[vn]="$ctarget"
      while [ "$(jobs -r | wc -l | tr -d ' ')" -ge 6 ]; do sleep 0.2; done
      verify_check "$vn" "$ctarget" "$cexp" "$cpath" &
    done 3<<< "$clist"
    wait
    for ((vi = 1; vi <= vn; vi++)); do
      ctarget="${vtargets[vi]}"; ccodes="$(cat "$vd/$vi.codes" 2>/dev/null)"; cbad="$(cat "$vd/$vi.bad" 2>/dev/null)"; cbad="${cbad:-$tries}"
      [ ! -s "$vd/$vi.log" ] || cat "$vd/$vi.log" >&2
      [ -n "$ccodes" ] || ccodes="000"
      cjson="$(echo "$cjson" | jq -c --arg u "$ctarget" --arg c "$ccodes" --arg w "$(cat "$vd/$vi.why" 2>/dev/null)" --argjson h "$([ "$cbad" -lt "$badlimit" ] && echo true || echo false)" \
        '. + [{url:$u, codes:($c | split(" ") | map(tonumber)), healthy:$h} + (if $w != "" then {why:($w | split("; "))} else {} end)]')"
      # The first failing check (else the first) is the one named, as one check was before.
      if [ -z "$target" ] || { [ "$cbad" -ge "$badlimit" ] && [ "$failed" = 0 ]; }; then target="$ctarget"; codes="$ccodes"; fi
      [ "$cbad" -lt "$badlimit" ] || failed=$((failed + 1))
    done
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
      # On a terminal one line that counts down; in a log (no terminal) one line each, not carriage returns.
      if [ -t 2 ]; then printf '\rRolling back %s in %2d s – Ctrl-C to stop ' "$p" "$s" >&2
      else printf 'Rolling back %s in %2d s – Ctrl-C to stop\n' "$p" "$s" >&2; fi
      sleep 1
      [ -z "$stop" ] || break
    done
    trap - INT TERM
    [ "$after" = 0 ] || ! [ -t 2 ] || echo >&2
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
