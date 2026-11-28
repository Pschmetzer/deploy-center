# shellcheck shell=bash
# lib/clean.sh — `deploys clean`: free disk space that old git worktrees hold.
#
#   deploys clean [--root <dir>]... [--days 2] [--worktrees] [--min-free <GB>] [--yes] [--json]
#   deploys clean schedule on|off|status [--min-free 60]   a daily LaunchAgent that runs `clean --yes --docker`
#   --docker       also Docker's build cache older than 3 days and dangling images (never containers, volumes or
#                  tagged images); skipped when Docker does not run. Set "docker": false in clean.json to leave it.
#
# Without --yes nothing is deleted: the report says what would go and how much space it frees.
# What it looks at: every git repo directly under a root (--root, or "roots" in clean.json) and its linked
# worktrees. The main checkout of a repo is never touched, and neither is a worktree changed in the last
# --days days (default 2: a session may still use it).
#
# Two kinds of cleanup, both regenerable or already on GitHub:
#   build output   node_modules, .next, .turbo, dist, build, .build, target, .vercel/output in an old worktree,
#                  only when git ignores the folder and tracks no file in it. `npm install` brings it back.
#   worktrees      (--worktrees) the whole worktree, when it has no uncommitted change and everything on it is
#                  in origin/main already (merged, squash merges too), so it went out with the next deploy.
#                  Removed with `git worktree remove` (no --force: git itself refuses a worktree with changes);
#                  the branch stays.
#
# clean.json in the config folder (optional): {"roots":["~/Code"],"days":2,"minFreeGB":60}
# minFreeGB is the default of `clean schedule on`; a run by hand cleans whatever the disk has free.
# Sourced by deploys; uses die, journal_add and CONFIG_DIR.

CLEAN_DIRS="node_modules .next .turbo dist build .build target .vercel/output"

clean_cfg() {  # clean_cfg <jq path>: a value of clean.json, empty without one
  [ -f "$CONFIG_DIR/clean.json" ] || return 0
  jq -r "$1 // empty" "$CONFIG_DIR/clean.json" 2>/dev/null || true
}

clean_free_gb() { df -k "${1:-$HOME}" 2>/dev/null | awk 'NR==2{print int($4/1048576)}'; }

# A worktree counts as in use when, within <days> days, a commit or checkout happened there (its HEAD log),
# a top-level entry changed, or a file with uncommitted changes was saved. Not the index: a plain
# `git status` rewrites it, so looking would count as use.
clean_recent() {  # clean_recent <worktree> <days>
  local wt="$1" days="$2" gd f
  gd="$(git -C "$wt" rev-parse --absolute-git-dir 2>/dev/null)" || return 0
  [ -z "$(find "$gd/logs/HEAD" "$gd/HEAD" -mtime "-$days" -print -quit 2>/dev/null)" ] || return 0
  [ -z "$(find "$wt" -mindepth 1 -maxdepth 1 -mtime "-$days" -not -name node_modules -not -name .next -not -name .git -print -quit 2>/dev/null)" ] || return 0
  while IFS= read -r f; do
    [ -n "$f" ] && [ -n "$(find "$wt/$f" -maxdepth 0 -mtime "-$days" -print -quit 2>/dev/null)" ] && return 0
  done < <(git -C "$wt" status --porcelain --untracked-files=all 2>/dev/null | head -n 200 | cut -c4- | sed 's/^.* -> //; s/^"//; s/"$//')
  return 1
}

# Everything on <head> is in <main>: an ancestor, or merging it into main changes nothing (a squash merge).
clean_merged() {  # clean_merged <repo> <main ref> <head>
  local r="$1" m="$2" h="$3" t
  git -C "$r" merge-base --is-ancestor "$h" "$m" 2>/dev/null && return 0
  t="$(git -C "$r" merge-tree --write-tree "$m" "$h" 2>/dev/null | head -n 1)" || return 1
  [ -n "$t" ] && [ "$t" = "$(git -C "$r" rev-parse "$m^{tree}" 2>/dev/null)" ]
}

clean_kb() { du -sk "$1" 2>/dev/null | awk '{print $1+0}'; }

# Delete one folder only when it is what it says: absolute, inside the worktree, not a link, a known name.
clean_rm() {  # clean_rm <worktree> <relative dir>
  local wt="$1" rel="$2" t
  case "$wt" in /?*/?*) ;; *) return 1 ;; esac
  case " $CLEAN_DIRS " in *" $rel "*) ;; *) return 1 ;; esac
  t="$wt/$rel"
  [ -d "$t" ] && [ ! -L "$t" ] || return 1
  rm -rf -- "$t"
}

clean_main() {
  local roots=() days="" yes=0 wts=0 dock=0 minfree="" r
  # Looking must not count as use: git status would otherwise rewrite the index and make a worktree "recent".
  local GIT_OPTIONAL_LOCKS=0; export GIT_OPTIONAL_LOCKS
  [ "${1:-}" != schedule ] || { shift; clean_schedule "$@"; return; }
  while [ $# -gt 0 ]; do
    case "$1" in
      --root) [ -n "${2:-}" ] || die "--root needs a folder"; roots+=("$2"); shift 2 ;;
      --days) [[ "${2:-}" =~ ^[0-9]+$ ]] || die "--days needs a number"; days="$2"; shift 2 ;;
      --min-free) [[ "${2:-}" =~ ^[0-9]+$ ]] || die "--min-free needs a number of GB"; minfree="$2"; shift 2 ;;
      --worktrees) wts=1; shift ;;
      --docker) dock=1; shift ;;
      --yes) yes=1; shift ;;
      --json) shift ;;
      *) die "Unknown option $1. Usage: deploys clean [--root <dir>]... [--days 2] [--worktrees] [--docker] [--min-free <GB>] [--yes] [--json]" ;;
    esac
  done
  if [ ${#roots[@]} -eq 0 ]; then
    while IFS= read -r r; do [ -n "$r" ] && roots+=("${r/#\~/$HOME}"); done < <(clean_cfg '.roots[]?')
  fi
  [ ${#roots[@]} -gt 0 ] || die "No folder to clean. Name one: deploys clean --root ~/Code (or \"roots\" in $CONFIG_DIR/clean.json)"
  [ -n "$days" ] || days="$(clean_cfg .days)"; [ -n "$days" ] || days=2

  local free; free="$(clean_free_gb "${roots[0]}")"
  if [ -n "$minfree" ] && [ "${free:-0}" -ge "$minfree" ]; then
    if [ "${json:-0}" = 1 ]; then printf '{"skipped":true,"freeGB":%s,"minFreeGB":%s,"items":[]}\n' "$free" "$minfree"
    else echo "${free} GB free (at least $minfree wanted): nothing to do."; fi
    return 0
  fi

  local items; items="$(mktemp)"
  local repo wt br head main kb d n_kept=0
  for r in "${roots[@]}"; do
    [ -d "$r" ] || { echo "Not a folder: $r" >&2; continue; }
    for repo in "$r"/*/; do
      repo="${repo%/}"
      [ -d "$repo/.git" ] || continue
      [ "$(git -C "$repo" worktree list 2>/dev/null | wc -l)" -gt 1 ] || continue
      main=""
      if [ "$wts" = 1 ]; then
        git -C "$repo" fetch -q origin 2>/dev/null || true
        main="$(git -C "$repo" rev-parse -q --verify origin/main 2>/dev/null || git -C "$repo" rev-parse -q --verify origin/master 2>/dev/null || true)"
      fi
      # The first entry is the main checkout: never touched.
      while IFS=$'\t' read -r wt br; do
        [ -d "$wt" ] || continue
        if clean_recent "$wt" "$days"; then n_kept=$((n_kept+1)); continue; fi
        if [ "$wts" = 1 ] && [ -n "$main" ] && [ -z "$(git -C "$wt" status --porcelain 2>/dev/null | head -n 1)" ]; then
          head="$(git -C "$wt" rev-parse HEAD 2>/dev/null)"
          if [ -n "$head" ] && clean_merged "$repo" "$main" "$head"; then
            printf 'worktree\t%s\t%s\t%s\t%s\n' "$(clean_kb "$wt")" "$repo" "$wt" "$br" >> "$items"; continue
          fi
        fi
        for d in $CLEAN_DIRS; do
          [ -d "$wt/$d" ] && [ ! -L "$wt/$d" ] || continue
          git -C "$wt" check-ignore -q "$d" 2>/dev/null || continue
          [ -z "$(git -C "$wt" ls-files -- "$d" 2>/dev/null | head -n 1)" ] || continue
          kb="$(clean_kb "$wt/$d")"
          printf 'build\t%s\t%s\t%s\t%s\n' "$kb" "$repo" "$wt" "$d" >> "$items"
        done
      done < <(git -C "$repo" worktree list --porcelain 2>/dev/null | awk '
        /^worktree /{p=substr($0,10); b="(detached)"} /^branch /{b=substr($0,19)}
        /^$/{ if (n++) print p "\t" b; p="" } END{ if (p!="" && n++) print p "\t" b }')
    done
  done

  local total_kb n_build n_wt done_kb=0 failed=0 kind kb2 rp p x
  total_kb="$(awk -F'\t' '{s+=$2} END{print s+0}' "$items")"
  n_build="$(awk -F'\t' '$1=="build"' "$items" | wc -l | tr -d ' ')"
  n_wt="$(awk -F'\t' '$1=="worktree"' "$items" | wc -l | tr -d ' ')"

  if [ "$yes" = 1 ]; then
    while IFS=$'\t' read -r kind kb2 rp p x; do
      if [ "$kind" = build ]; then
        clean_rm "$p" "$x" && done_kb=$((done_kb + kb2)) || failed=$((failed+1))
      else
        git -C "$rp" worktree remove "$p" 2>/dev/null && done_kb=$((done_kb + kb2)) || failed=$((failed+1))
      fi
    done < "$items"
    for r in "${roots[@]}"; do for repo in "$r"/*/; do [ -d "$repo/.git" ] && git -C "$repo" worktree prune 2>/dev/null; done; done
    [ "$dock" = 1 ] && [ "$(clean_cfg .docker)" != false ] && clean_docker
    journal_add cli clean live "Freed $((done_kb / 1048576)) GB: $n_build build folders, $n_wt worktrees, $failed failed" 2>/dev/null || true
  fi

  if [ "${json:-0}" = 1 ]; then
    jq -Rn --argjson yes "$yes" --argjson free "${free:-0}" --argjson freed "$done_kb" --argjson failed "$failed" --argjson kept "$n_kept" '
      [inputs | split("\t") | {kind:.[0], kb:(.[1]|tonumber), repo:.[2], path:.[3], what:.[4]}] as $i |
      {deleted:($yes==1), freeGB:$free, totalKB:($i|map(.kb)|add // 0), freedKB:$freed, failed:$failed,
       keptRecent:$kept, items:$i}' < "$items"
    rm -f "$items"; [ "$failed" -eq 0 ]; return
  fi
  printf '%s GB free now. Worktrees left alone because they changed in the last %s days: %s\n' "${free:-?}" "$days" "$n_kept"
  awk -F'\t' '{s[$3]+=$2; n[$3]++} END{for (k in s) printf "  %7.1f GB  %3d  %s\n", s[k]/1048576, n[k], k}' "$items" | sort -rn | head -n 20
  printf 'Build folders: %s   Worktrees (merged, no changes): %s   Together: %.1f GB\n' "$n_build" "$n_wt" "$(awk -v k="$total_kb" 'BEGIN{print k/1048576}')"
  if [ "$yes" = 1 ]; then
    printf 'Deleted: %.1f GB freed, %s could not be removed. %s GB free now.\n' "$(awk -v k="$done_kb" 'BEGIN{print k/1048576}')" "$failed" "$(clean_free_gb "${roots[0]}")"
  else
    echo "Nothing was deleted. To delete: deploys clean --yes$([ "$wts" = 1 ] && echo " --worktrees")"
    [ "$wts" = 1 ] || echo "Whole worktrees that are merged and unchanged too: add --worktrees"
  fi
  rm -f "$items"
  [ "$failed" -eq 0 ]  # a folder that could not be removed makes the run fail (disk free counts it)
}

# Docker's build cache (older than 3 days) and dangling images: both come back on the next build. Never containers,
# volumes or tagged images, so a stopped database keeps its data. DEPLOYS_DOCKER_BIN lets tests use a fake.
clean_docker() {
  local d="${DEPLOYS_DOCKER_BIN:-docker}"
  command -v "$d" >/dev/null 2>&1 && "$d" info >/dev/null 2>&1 || { echo "Docker does not run: its cache was left alone."; return 0; }
  "$d" builder prune -f --filter until=72h 2>/dev/null | tail -n 1 | sed 's/^/Docker build cache: /'
  "$d" image prune -f 2>/dev/null | tail -n 1 | sed 's/^/Docker dangling images: /'
}

CLEAN_LABEL="com.deploycenter.clean"
clean_schedule() {
  local plist="$HOME/Library/LaunchAgents/$CLEAN_LABEL.plist" minfree me
  minfree="$(clean_cfg .minFreeGB)"; [ -n "$minfree" ] || minfree=60
  case "${1:-status}" in
    on)
      [ "${2:-}" != --min-free ] || { [[ "${3:-}" =~ ^[0-9]+$ ]] || die "--min-free needs a number of GB"; minfree="$3"; }
      [ -n "$(clean_cfg '.roots[]?')" ] || die "Set the folders first: $CONFIG_DIR/clean.json {\"roots\":[\"~/Code\"]}"
      me="$(cd "$(dirname "${SELF:?}")" && pwd)/$(basename "$SELF")"
      mkdir -p "$HOME/Library/LaunchAgents" "$CONFIG_DIR"
      cat > "$plist" <<P
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0"><dict>
  <key>Label</key><string>$CLEAN_LABEL</string>
  <key>ProgramArguments</key><array><string>/bin/bash</string><string>$me</string><string>clean</string><string>--yes</string><string>--docker</string><string>--min-free</string><string>$minfree</string></array>
  <key>StartCalendarInterval</key><dict><key>Hour</key><integer>4</integer><key>Minute</key><integer>30</integer></dict>
  <key>StandardOutPath</key><string>$CONFIG_DIR/clean.log</string>
  <key>StandardErrorPath</key><string>$CONFIG_DIR/clean.log</string>
</dict></plist>
P
      launchctl bootout "gui/$(id -u)/$CLEAN_LABEL" 2>/dev/null || true
      launchctl bootstrap "gui/$(id -u)" "$plist" 2>/dev/null || launchctl load "$plist"
      echo "Daily at 04:30: build folders in old worktrees are deleted when less than $minfree GB are free. Log: $CONFIG_DIR/clean.log" ;;
    off)
      launchctl bootout "gui/$(id -u)/$CLEAN_LABEL" 2>/dev/null || launchctl unload "$plist" 2>/dev/null || true
      rm -f "$plist"; echo "The daily cleanup is off." ;;
    status)
      if [ -f "$plist" ]; then echo "on: $(sed -n 's#.*<string>--min-free</string><string>\([0-9]*\)</string>.*#\1#p' "$plist" | head -n 1) GB minimum, log $CONFIG_DIR/clean.log"; else echo "off"; fi ;;
    *) die "Usage: deploys clean schedule on|off|status [--min-free 60]" ;;
  esac
}
