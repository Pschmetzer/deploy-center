# shellcheck shell=bash
# lib/disk.sh — `deploys disk`: where the Mac's disk space goes, and freeing what comes back by itself.
#
#   deploys disk [--refresh] [--json]          a report per category (cached for 6 hours; --refresh measures again)
#   deploys disk free [--yes] [--json]         what can go; without --yes nothing is deleted
#   deploys disk schedule on|off|status [--min-free 100] [--yes]   the perf agent runs `disk free --yes` when less is free
#
# Measuring: every category at once in the background, each `du` with a time limit (DEPLOYS_DISK_TIMEOUT, 120 s), at
# the lowest priority. A category that runs out of time is marked timedOut and counts what it measured so far.
#
# `disk free --yes` only touches what comes back on the next build or install:
#   deploys clean --yes --docker (build folders of old worktrees, Docker's build cache older than 3 days, dangling
#   images), npm cache clean --force, pnpm store prune, yarn cache clean, brew cleanup -s, Xcode DerivedData older
#   than 7 days (not while Xcode runs), xcrun simctl delete unavailable, entries in this user's TMPDIR older than
#   3 days that no running process uses (lsof).
# Never, only shown: the Trash, Docker volumes and containers, ~/.claude/projects (Claude Code's own setting
# cleanupPeriodDays keeps them shorter), the Claude app's own folders, ~/.cache (huggingface never), bun and pip
# caches, /Applications and /Library.
#
# disk.json in the config folder (optional): {"auto":true,"minFreeGB":100,"everyHours":6}
# Sourced by deploys; uses die, journal_add, CONFIG_DIR and, when there, clean_main, clean_docker, perf_notify.

DISK_DIR="${CONFIG_DIR:-${DEPLOYS_CONFIG:-$HOME/.config/deploys}}/disk"

disk_cfg() {  # disk_cfg <jq path>: a value of disk.json, empty without one
  [ -f "$CONFIG_DIR/disk.json" ] || return 0
  jq -r "$1 // empty" "$CONFIG_DIR/disk.json" 2>/dev/null || true
}
disk_now() { if [ -n "${DEPLOYS_DISK_NOW:-}" ]; then echo "$DEPLOYS_DISK_NOW"; else date +%s; fi; }
disk_free_kb() { df -k "$HOME" 2>/dev/null | awk 'NR==2{print $4+0}'; }
disk_gb() { awk -v k="${1:-0}" 'BEGIN{printf "%.1f", k/1048576}'; }

# What each category is, for the text output (the app has its own texts per id) and the rule that decides it.
#   auto: `disk free --yes` frees it   manual: you decide (a hint says how)   never: left alone, only shown
DISK_CATS="worktrees:auto docker:auto npm:auto pnpm:auto yarn:auto brew:auto xcode:auto simulators:auto tmp:auto bun:manual pip:manual caches:manual trash:manual claude-projects:manual claude-app:never huggingface:never dotcache:manual applications:never library:never"
disk_label() {
  case "$1" in
    worktrees) echo "Build folders in old worktrees" ;; docker) echo "Docker" ;; npm) echo "npm cache" ;;
    pnpm) echo "pnpm store" ;; yarn) echo "Yarn cache" ;; brew) echo "Homebrew cache" ;; bun) echo "bun cache" ;;
    pip) echo "pip cache" ;; xcode) echo "Xcode DerivedData" ;; simulators) echo "iOS simulators" ;;
    caches) echo "Library/Caches (the rest)" ;; trash) echo "Trash" ;; claude-projects) echo "Claude Code transcripts" ;;
    claude-app) echo "Claude app folders" ;; huggingface) echo "Hugging Face models" ;;
    tmp) echo "Temporary files (TMPDIR)" ;; dotcache) echo ".cache (the rest)" ;; applications) echo "/Applications" ;; library) echo "/Library" ;; *) echo "$1" ;;
  esac
}
disk_hint() {
  case "$1" in
    bun) echo "bun pm cache rm" ;; pip) echo "pip cache purge" ;; caches) echo "app caches; quit the app and delete its folder if you must" ;;
    trash) echo "empty it in Finder" ;; claude-projects) echo "Claude Code keeps 30 days; set cleanupPeriodDays in ~/.claude/settings.json for fewer" ;;
    claude-app) echo "the Claude app's own state; it cleans it itself" ;; huggingface) echo "downloaded models (Whisper); they would be downloaded again" ;;
    docker) echo "build cache and dangling images go; volumes and containers stay" ;; xcode) echo "folders older than 7 days" ;;
    simulators) echo "only simulators of runtimes that are gone" ;;
    tmp) echo "entries older than 3 days that no process uses" ;; dotcache) echo "other tools' caches; delete one you no longer use" ;;
    applications|library) echo "apps and system files; only shown" ;; *) echo "" ;;
  esac
}

# The paths of a category, one per line (only those that exist).
disk_paths() {
  local p
  case "$1" in
    npm) p="$HOME/.npm" ;; pnpm) p="$HOME/Library/pnpm/store $HOME/Library/Caches/pnpm" ;;
    yarn) p="$HOME/Library/Caches/Yarn $HOME/.yarn/berry/cache" ;; bun) p="$HOME/.bun/install/cache" ;;
    pip) p="$HOME/Library/Caches/pip $HOME/.cache/pip" ;; brew) p="$HOME/Library/Caches/Homebrew" ;;
    xcode) p="$HOME/Library/Developer/Xcode/DerivedData" ;; simulators) p="$HOME/Library/Developer/CoreSimulator/Devices" ;;
    caches) p="$HOME/Library/Caches" ;; trash) p="$HOME/.Trash" ;; claude-projects) p="$HOME/.claude/projects" ;;
    huggingface) p="$HOME/.cache/huggingface" ;; dotcache) p="$HOME/.cache" ;; tmp) p="$(disk_tmpdir)" ;;
    applications) p="${DEPLOYS_DISK_APPS:-/Applications}" ;; library) p="${DEPLOYS_DISK_LIBRARY:-/Library}" ;;
    claude-app) find "$HOME/Library/Application Support/Claude" -maxdepth 3 -type d \( -name scratch-workspaces -o -name vm_bundles \) -prune -print 2>/dev/null; return 0 ;;
    *) return 0 ;;
  esac
  for p in $p; do [ -e "$p" ] && echo "$p"; done
  return 0
}

disk_tmpdir() { local t="${TMPDIR:-}"; [ -n "$t" ] && [ -d "$t" ] || t=""; printf '%s' "${t%/}"; }

# The entries directly in this user's TMPDIR that are older than 3 days, have nothing inside changed in that time,
# and no running process has open or as its folder (lsof). Not Apple's own (com.apple.*). One per line.
disk_tmp_old() {
  local t e used
  t="$(disk_tmpdir)"; [ -n "$t" ] || return 0
  case "$t" in /?*/?*) ;; *) return 0 ;; esac
  used="$(lsof -nP -u "$(id -u)" -Fn 2>/dev/null | sed -n "s#^n$t/\([^/]*\).*#\1#p" | sort -u)"
  find "$t" -mindepth 1 -maxdepth 1 -mtime +3 -user "$(id -u)" ! -name 'com.apple.*' ! -type s 2>/dev/null | while IFS= read -r e; do
    [ -z "$(find "$e" -mtime -3 -print -quit 2>/dev/null)" ] || continue
    printf '%s\n' "$used" | grep -qxF "$(basename "$e")" && continue
    printf '%s\n' "$e"
  done
}

# disk_du <seconds> <path>...: "<kb> <timedOut 0|1>" — what du finished in time.
disk_du() {
  local t="$1" out rc; shift
  [ $# -gt 0 ] || { echo "0 0"; return 0; }
  out="$(perl -e 'alarm shift; exec @ARGV' "$t" nice -n 19 du -sk "$@" 2>/dev/null)"; rc=$?
  printf '%s %s\n' "$(printf '%s\n' "$out" | awk '{s+=$1} END{print s+0}')" "$([ "$rc" -ge 128 ] && echo 1 || echo 0)"
}

# "1.2GB" / "512.3MB" / "0B" (docker system df) -> kb
disk_unit_kb() {
  echo "$1" | awk '{ v=$1; sub(/ .*/, "", v); n=v+0; u=v; gsub(/[0-9.]/, "", u); u=toupper(u)
    m=1/1024; if (u=="KB") m=1; else if (u=="MB") m=1024; else if (u=="GB") m=1048576; else if (u=="TB") m=1073741824
    printf "%d\n", n*m }'
}

# One category as a JSON line into <dir>/<id>.json.
disk_measure_one() {  # disk_measure_one <id> <seconds> <dir>
  local id="$1" t="$2" dir="$3" kb=0 to=0 r paths=() p parts='[]' d line typ sz rec
  case "$id" in
    worktrees)
      if declare -F clean_main >/dev/null && [ -n "$(clean_cfg '.roots[]?' 2>/dev/null)" ]; then
        kb="$( (json=1 clean_main --json 2>/dev/null) | jq -r '.totalKB // 0' 2>/dev/null)"; kb="${kb:-0}"
      fi ;;
    docker)
      d="${DEPLOYS_DOCKER_BIN:-docker}"
      if command -v "$d" >/dev/null 2>&1 && perl -e 'alarm shift; exec @ARGV' 15 "$d" info >/dev/null 2>&1; then
        parts="$(perl -e 'alarm shift; exec @ARGV' "$t" "$d" system df --format '{{json .}}' 2>/dev/null | while IFS= read -r line; do
          typ="$(jq -r '.Type // empty' <<<"$line" 2>/dev/null)"; [ -n "$typ" ] || continue
          sz="$(disk_unit_kb "$(jq -r '.Size // "0B"' <<<"$line")")"; rec="$(disk_unit_kb "$(jq -r '.Reclaimable // "0B"' <<<"$line")")"
          jq -nc --arg n "$typ" --argjson kb "$sz" --argjson r "$rec" '{name:$n, kb:$kb, reclaimableKB:$r}'
        done | jq -sc '.')"
        [ -n "$parts" ] || parts='[]'
        kb="$(jq '[.[].kb] | add // 0' <<<"$parts")"
      fi ;;
    *)
      while IFS= read -r p; do [ -n "$p" ] && paths+=("$p"); done < <(disk_paths "$id")
      if [ ${#paths[@]} -gt 0 ]; then r="$(disk_du "$t" "${paths[@]}")"; kb="${r% *}"; to="${r#* }"; fi
      if [ "$id" = caches ]; then  # the rest: the caches counted elsewhere are left out
        for p in Yarn pip Homebrew pnpm; do
          [ -d "$HOME/Library/Caches/$p" ] && parts="$(jq -c --arg n "$p" '. + [$n]' <<<"$parts")"
        done
      fi ;;
  esac
  jq -nc --arg id "$id" --argjson kb "${kb:-0}" --argjson to "${to:-0}" --argjson parts "$parts" \
    --argjson paths "$(printf '%s\n' "${paths[@]+"${paths[@]}"}" | sed "s#^$HOME#~#" | jq -Rsc 'split("\n") | map(select(length > 0))')" \
    '{id:$id, kb:$kb, timedOut:($to == 1), paths:$paths, parts:$parts}' > "$dir/$id.json.tmp" && mv -f "$dir/$id.json.tmp" "$dir/$id.json"
}

# Measures every category at once; writes and prints the report.
disk_measure() {
  local t="${DEPLOYS_DISK_TIMEOUT:-120}" tmp c id pids="" left start now
  tmp="$(mktemp -d)"
  for c in $DISK_CATS; do
    id="${c%%:*}"
    disk_measure_one "$id" "$t" "$tmp" </dev/null >/dev/null 2>&1 &
    pids="$pids $id:$!"
  done
  start="$(date +%s)"
  while :; do
    left=0; for c in $pids; do [ -f "$tmp/${c%%:*}.json" ] || left=1; done
    [ "$left" = 1 ] || break
    now="$(date +%s)"; [ $(( now - start )) -le $(( t + 5 )) ] || break
    sleep 1
  done
  for c in $pids; do
    id="${c%%:*}"
    [ -f "$tmp/$id.json" ] && continue
    pkill -P "${c#*:}" 2>/dev/null; kill "${c#*:}" 2>/dev/null
    jq -nc --arg id "$id" '{id:$id, kb:0, timedOut:true, paths:[], parts:[]}' > "$tmp/$id.json"
  done
  wait 2>/dev/null
  local cats="" act
  for c in $DISK_CATS; do
    id="${c%%:*}"; act="${c#*:}"
    cats="$cats$(jq -c --arg a "$act" --arg l "$(disk_label "$id")" --arg h "$(disk_hint "$id")" '. + {action:$a, label:$l, hint:$h}' "$tmp/$id.json")
"
  done
  rm -rf "$tmp"
  # ~/Library/Caches: the caches that are their own category are subtracted (all are measured above).
  local df_line; df_line="$(df -k "$HOME" 2>/dev/null | awk 'NR==2{print $2+0, $3+0, $4+0}')"
  mkdir -p "$DISK_DIR"
  # A category that ran out of time keeps the number of the last report that had one (marked stale).
  local prev='{}'; [ ! -f "$DISK_DIR/report.json" ] || prev="$(jq -c '[.categories[]? | select(.timedOut | not) | {key:.id, value:.kb}] | from_entries' "$DISK_DIR/report.json" 2>/dev/null || echo '{}')"
  printf '%s' "$cats" | jq -sc --argjson time "$(disk_now)" --arg df "$df_line" --argjson prev "$prev" '
    (map({key:.id, value:.kb}) | from_entries) as $k |
    map(if .timedOut and ($prev[.id] // 0) > .kb then .kb = $prev[.id] | .stale = true else . end) |
    map(if .id == "dotcache" then .kb = ([.kb - ($k.huggingface // 0), 0] | max) else . end) |
    map(if .id == "caches" then .kb = ([.kb - (([.parts[] as $p | {Yarn:"yarn",pip:"pip",Homebrew:"brew",pnpm:"pnpm"}[$p]] | map($k[.] // 0) | add) // 0), 0] | max) else . end) |
    map(.freeableKB = (if .action != "auto" then 0
      elif .id == "docker" then ([.parts[] | select(.name == "Build Cache" or .name == "Images") | .reclaimableKB] | add // 0)
      elif .id == "simulators" or .id == "tmp" then 0 else .kb end)) |
    ($df | split(" ") | map(tonumber? // 0)) as $d |
    {time:$time, diskKB:($d[0] // 0), usedKB:($d[1] // 0), freeKB:($d[2] // 0), measuredKB:(map(.kb) | add // 0),
     autoKB:(map(.freeableKB) | add // 0), categories:.}' > "$DISK_DIR/report.json.$$" \
    && mv -f "$DISK_DIR/report.json.$$" "$DISK_DIR/report.json"
  cat "$DISK_DIR/report.json"
}

# The report: from the cache when it is younger than 6 hours (or --refresh), else measured now.
disk_report() {  # disk_report [refresh 0|1]
  local f="$DISK_DIR/report.json" age
  if [ "${1:-0}" != 1 ] && [ -f "$f" ]; then
    age=$(( $(disk_now) - $(jq -r '.time // 0' "$f" 2>/dev/null || echo 0) ))
    if [ "$age" -lt 21600 ]; then jq -c --argjson a "$age" --argjson f "$(disk_free_kb)" '. + {cached:true, ageSec:$a, freeKB:$f}' "$f"; return 0; fi
  fi
  disk_measure | jq -c '. + {cached:false, ageSec:0}'
}

disk_print() {  # the text report from JSON on stdin
  jq -r '
    def gb: . / 1048576 * 10 | round / 10 | tostring + " GB";
    "Disk: \(.usedKB | gb) used, \(.freeKB | gb) free of \(.diskKB | gb)" + (if .cached then "  (measured \(.ageSec / 60 | floor) min ago; --refresh measures again)" else "" end),
    "",
    (.categories | sort_by(-.kb)[] | "  \(.kb | gb | (" " * (9 - length)) + .)  \({auto:"frees  ",manual:"by you ",never:"stays  "}[.action])  \(.label)\(if .stale then " (time ran out: the last full count)" elif .timedOut then " (time ran out: at least this)" else "" end)\(if .hint != "" then "  – " + .hint else "" end)"),
    "",
    "Measured: \(.measuredKB | gb). `deploys disk free` frees up to about \(.autoKB | gb) of it (only what comes back by itself)."'
}

# The steps of `disk free`: "<id>\t<estimate kb>\t<what>" for each tool that is there.
disk_steps() {  # disk_steps <report json>
  local rep="$1"
  disk_k() { jq -r --arg i "$1" '[.categories[] | select(.id == $i) | .kb][0] // 0' <<<"$rep"; }
  local dk; dk="$(jq -r '[.categories[] | select(.id == "docker") | .parts[] | select(.name == "Build Cache") | .reclaimableKB][0] // 0' <<<"$rep")"
  printf 'clean\t%s\t%s\n' "$(( $(disk_k worktrees) + dk ))" "deploys clean --yes --docker (build folders of old worktrees, Docker build cache > 3 days, dangling images)"
  command -v npm >/dev/null 2>&1 && printf 'npm\t%s\t%s\n' "$(disk_k npm)" "npm cache clean --force"
  command -v pnpm >/dev/null 2>&1 && printf 'pnpm\t%s\t%s\n' "$(disk_k pnpm)" "pnpm store prune (up to)"
  command -v yarn >/dev/null 2>&1 && printf 'yarn\t%s\t%s\n' "$(disk_k yarn)" "yarn cache clean"
  command -v brew >/dev/null 2>&1 && printf 'brew\t%s\t%s\n' "$(disk_k brew)" "brew cleanup -s"
  local dd="$HOME/Library/Developer/Xcode/DerivedData" old
  if [ -d "$dd" ]; then
    old="$(find "$dd" -mindepth 1 -maxdepth 1 -type d -mtime +7 2>/dev/null)"
    [ -z "$old" ] || printf 'xcode\t%s\t%s\n' "$(printf '%s\n' "$old" | tr '\n' '\0' | xargs -0 du -sk 2>/dev/null | awk '{s+=$1} END{print s+0}')" "Xcode DerivedData older than 7 days ($(printf '%s\n' "$old" | wc -l | tr -d ' ') folders)"
  fi
  local tmpold; tmpold="$(disk_tmp_old)"
  [ -z "$tmpold" ] || printf 'tmp\t%s\t%s\n' "$(printf '%s\n' "$tmpold" | tr '\n' '\0' | xargs -0 du -sk 2>/dev/null | awk '{s+=$1} END{print s+0}')" "temporary files older than 3 days, not in use ($(printf '%s\n' "$tmpold" | wc -l | tr -d ' ') entries)"
  command -v xcrun >/dev/null 2>&1 && printf 'simulators\t0\t%s\n' "xcrun simctl delete unavailable"
  return 0
}

disk_run_step() {  # disk_run_step <id>
  case "$1" in
    clean)
      if declare -F clean_main >/dev/null && [ -n "$(clean_cfg '.roots[]?' 2>/dev/null)" ]; then (json=0 clean_main --yes --docker)
      elif declare -F clean_docker >/dev/null; then clean_docker; fi ;;
    npm) npm cache clean --force ;;
    pnpm) pnpm store prune ;;
    yarn) yarn cache clean ;;
    brew) brew cleanup -s ;;
    xcode)
      if declare -F perf_xcode_up >/dev/null && perf_xcode_up; then echo "Xcode runs: DerivedData left alone."; return 0; fi
      find "$HOME/Library/Developer/Xcode/DerivedData" -mindepth 1 -maxdepth 1 -type d -mtime +7 -exec rm -rf -- {} + ;;
    simulators) xcrun simctl delete unavailable ;;
    tmp) disk_tmp_old | while IFS= read -r e; do rm -rf -- "$e"; done ;;
  esac
}

disk_free_main() {
  local yes=0 auto=0 a rep steps
  for a in "$@"; do case "$a" in --yes) yes=1 ;; --auto) auto=1 ;; --json) ;; *) die "Usage: deploys disk free [--yes] [--json]" ;; esac; done
  rep="$(disk_report 0)"; steps="$(disk_steps "$rep")"
  local keep; keep="$(jq -c '[.categories[] | select(.action != "auto") | {id, label, kb, action, hint}]' <<<"$rep")"
  if [ "$yes" != 1 ]; then
    if [ "${json:-0}" = 1 ]; then
      printf '%s\n' "$steps" | jq -Rsc --argjson keep "$keep" --argjson f "$(disk_free_kb)" '
        (split("\n") | map(select(length > 0) | split("\t") | {id:.[0], kb:(.[1] | tonumber), what:.[2]})) as $s |
        {deleted:false, freeKB:$f, estimateKB:($s | map(.kb) | add // 0), steps:$s, untouched:$keep}'
    else
      echo "Would free (nothing was deleted; add --yes):"
      printf '%s\n' "$steps" | awk -F'\t' 'NF{printf "  %7.1f GB  %s\n", $2/1048576, $3}'
      echo "Left alone (only you decide):"
      jq -r '.[] | select(.kb > 0) | "  \(.kb / 1048576 * 10 | round / 10) GB  \(.label)\(if .hint != "" then "  – " + .hint else "" end)"' <<<"$keep"
    fi
    return 0
  fi
  mkdir -p "$DISK_DIR"
  mkdir "$DISK_DIR/lock" 2>/dev/null || { echo "disk free runs already (remove $DISK_DIR/lock if it does not)." >&2; return 1; }
  local before after id ok=0 failed=0 results=""
  before="$(disk_free_kb)"
  while IFS=$'\t' read -r id _ _; do
    [ -n "$id" ] || continue
    if disk_run_step "$id" </dev/null >> "$DISK_DIR/free.log" 2>&1; then ok=$((ok+1)); results="$results$id ok
"; else failed=$((failed+1)); results="$results$id failed
"; fi
  done <<<"$steps"
  after="$(disk_free_kb)"
  local freed=$(( ${after:-0} - ${before:-0} )); [ "$freed" -ge 0 ] || freed=0
  disk_now > "$DISK_DIR/last-free"
  rm -f "$DISK_DIR/report.json"; rmdir "$DISK_DIR/lock" 2>/dev/null
  journal_add cli disk live "Freed $(disk_gb "$freed") GB$([ "$auto" = 1 ] && echo " (automatic)"), $failed steps failed" 2>/dev/null || true
  if [ "$auto" = 1 ] && declare -F perf_notify >/dev/null; then
    perf_notify "Disk space freed" "$(disk_gb "$freed") GB freed, $(disk_gb "$after") GB free now."
  fi
  if [ "${json:-0}" = 1 ]; then
    printf '%s' "$results" | jq -Rsc --argjson b "$before" --argjson a "$after" --argjson fd "$freed" --argjson fl "$failed" \
      '{deleted:true, freeBeforeKB:$b, freeKB:$a, freedKB:$fd, failed:$fl, steps:(split("\n") | map(select(length > 0) | split(" ") | {id:.[0], status:.[1]}))}'
  else
    printf '%s' "$results" | sed 's/^/  /'
    echo "Freed $(disk_gb "$freed") GB, $(disk_gb "$after") GB free now. Steps failed: $failed (log: $DISK_DIR/free.log)"
  fi
}

disk_schedule() {
  local sub="${1:-status}" yes=0 min="" a; shift || true
  while [ $# -gt 0 ]; do
    case "$1" in
      --yes) yes=1; shift ;;
      --min-free) [[ "${2:-}" =~ ^[0-9]+$ ]] || die "--min-free needs a number of GB"; min="$2"; shift 2 ;;
      *) die "Usage: deploys disk schedule on|off|status [--min-free 100] [--yes]" ;;
    esac
  done
  [ -n "$min" ] || min="$(disk_cfg .minFreeGB)"; [ -n "$min" ] || min=100
  local f="$CONFIG_DIR/disk.json" agent="no"
  [ -f "$(job_plist "${PERF_LABEL:-app.deploycenter.perf}" 2>/dev/null)" ] && agent="yes"
  case "$sub" in
    on)
      [ "$yes" = 1 ] || { echo "disk schedule on lets the perf agent run \`deploys disk free --yes\` when less than $min GB are free (at most every 6 hours). Add --yes."; return 0; }
      mkdir -p "$CONFIG_DIR"; [ -f "$f" ] || echo '{}' > "$f"
      jq --argjson m "$min" '.auto = true | .minFreeGB = $m' "$f" > "$f.new" && mv -f "$f.new" "$f"
      echo "On: when less than $min GB are free, the perf agent frees what comes back by itself (checked every 10 minutes, at most every 6 hours)."
      [ "$agent" = yes ] || echo "The perf agent is not installed, so nothing runs yet: deploys perf install --yes" ;;
    off)
      [ ! -f "$f" ] || { jq '.auto = false' "$f" > "$f.new" && mv -f "$f.new" "$f"; }
      echo "Off: disk space is freed only by hand (deploys disk free --yes)." ;;
    status)
      if [ "$(disk_cfg .auto)" = true ]; then
        echo "on: below $min GB free, perf agent $([ "$agent" = yes ] && echo installed || echo "NOT installed (deploys perf install --yes)")$([ -f "$DISK_DIR/last-free" ] && echo ", last run $(date -r "$(cat "$DISK_DIR/last-free")" '+%Y-%m-%d %H:%M' 2>/dev/null)")"
      else echo "off"; fi ;;
    *) die "Usage: deploys disk schedule on|off|status [--min-free 100] [--yes]" ;;
  esac
}

# One run of the perf agent (every minute): every 10 minutes a look at the free space; below minFreeGB (and at most
# every everyHours) `disk free --yes --auto` in the background. Once a day a fresh report for the app, at low priority.
disk_tick() {
  local now last min every free
  now="$(disk_now)"
  last="$(cat "$DISK_DIR/last-check" 2>/dev/null || echo 0)"
  [ $(( now - last )) -ge 600 ] || return 0
  mkdir -p "$DISK_DIR"; echo "$now" > "$DISK_DIR/last-check"
  if [ "$(disk_cfg .auto)" = true ] && [ ! -d "$DISK_DIR/lock" ]; then
    min="$(disk_cfg .minFreeGB)"; [ -n "$min" ] || min=100
    every="$(disk_cfg .everyHours)"; [ -n "$every" ] || every=6
    free="$(disk_free_kb)"
    if [ "${free:-0}" -lt $(( min * 1048576 )) ] && [ $(( now - $(cat "$DISK_DIR/last-free" 2>/dev/null || echo 0) )) -ge $(( every * 3600 )) ]; then
      ( json=0 disk_free_main --yes --auto ) </dev/null >> "$DISK_DIR/free.log" 2>&1 &
      return 0
    fi
  fi
  if [ $(( now - $(jq -r '.time // 0' "$DISK_DIR/report.json" 2>/dev/null || echo 0) )) -ge 86400 ]; then
    DEPLOYS_DISK_TIMEOUT="${DEPLOYS_DISK_TICK_TIMEOUT:-900}" disk_measure </dev/null >/dev/null 2>&1 &
  fi
  return 0
}

disk_main() {
  local refresh=0 a
  case "${1:-}" in
    free) shift; disk_free_main "$@"; return ;;
    schedule) shift; disk_schedule "$@"; return ;;
    tick) disk_tick; return ;;
  esac
  for a in "$@"; do case "$a" in --refresh) refresh=1 ;; --json) ;; *) die "Usage: deploys disk [--refresh] [--json] | disk free [--yes] | disk schedule on|off|status" ;; esac; done
  if [ "${json:-0}" = 1 ]; then disk_report "$refresh"; else disk_report "$refresh" | disk_print; fi
}
