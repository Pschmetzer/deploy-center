#!/bin/bash
# Tests for `deploys disk` (lib/disk.sh). No network, no real tool: a made-up home and fakes on PATH that log calls.
# Run: tests/disk-tests.sh
set -uo pipefail
cd "$(dirname "$0")/.." || exit 1
exec </dev/null
fails=0
ok()   { echo "ok   $1"; }
fail() { echo "FAIL $1: $2"; fails=$((fails+1)); }
expect() { [ "$2" = "$3" ] && ok "$1" || fail "$1" "expected [$3], got [$2]"; }

tmp="$(mktemp -d)"; trap 'rm -rf "$tmp"' EXIT
export DEPLOYS_CONFIG="$tmp/config" HOME="$tmp/home" NO_COLOR=1 DEPLOYS_TESTING=1 DEPLOYS_DISK_TIMEOUT=5
export TMPDIR="$tmp/T" DEPLOYS_DISK_APPS="$tmp/Applications" DEPLOYS_DISK_LIBRARY="$tmp/Library"
mkdir -p "$HOME" "$DEPLOYS_CONFIG" "$tmp/bin" "$TMPDIR" "$DEPLOYS_DISK_APPS" "$DEPLOYS_DISK_LIBRARY"
printf '{"enabled":[]}' > "$DEPLOYS_CONFIG/providers.json"
calls="$tmp/calls.log"; : > "$calls"

# Fakes: each logs its arguments. docker answers info and system df; no other docker call is allowed.
# lsof: a process has a file open in the "busy" temp folder.
printf '#!/bin/bash\necho p1\necho "n%s/busy/sock.log"\n' "$TMPDIR" > "$tmp/bin/lsof"
printf '#!/bin/bash\necho "Snapshots for disk /:"\necho com.apple.os.update-ABC\necho com.apple.TimeMachine.2026-01-01-000000.local\n' > "$tmp/bin/tmutil"
printf '#!/bin/bash\necho "yarn $*" >> "%s"\n[ "$1" = --version ] && echo "${FAKE_YARN:-1.22.19}"\nexit 0\n' "$calls" > "$tmp/bin/yarn"
for t in npm pnpm brew xcrun; do
  printf '#!/bin/bash\necho "%s $*" >> "%s"\n' "$t" "$calls" > "$tmp/bin/$t"
done
cat > "$tmp/bin/docker" <<EOF
#!/bin/bash
echo "docker \$*" >> "$calls"
case "\$1" in
  info) exit 0 ;;
  system) [ "\$2" = df ] || exit 1
    echo '{"Reclaimable":"1GB (50%)","Size":"2GB","Type":"Images"}'
    echo '{"Reclaimable":"0B","Size":"512MB","Type":"Local Volumes"}'
    echo '{"Reclaimable":"1.5GB","Size":"1.5GB","Type":"Build Cache"}' ;;
esac
EOF
chmod +x "$tmp/bin/"*
export PATH="$tmp/bin:$PATH" DEPLOYS_DOCKER_BIN="$tmp/bin/docker" DEPLOYS_PERF_NOTIFY_CMD="$tmp/bin/notify"
printf '#!/bin/bash\necho "notify $*" >> "%s"\n' "$calls" > "$tmp/bin/notify"; chmod +x "$tmp/bin/notify"
cli() { env DEPLOYS_JOURNAL="$tmp/journal.jsonl" bash ./deploys "$@"; }
fill() { mkdir -p "$1"; dd if=/dev/zero of="$1/blob" bs=1024 count="$2" 2>/dev/null; }

# A made-up home: caches, models, transcripts, the Trash, old and new DerivedData.
fill "$HOME/.npm/_cacache" 2048
fill "$HOME/Library/Caches/Yarn" 1024
fill "$HOME/Library/Caches/Other" 512
fill "$HOME/.cache/huggingface/hub" 1024
fill "$HOME/.claude/projects/p" 1024
fill "$HOME/.Trash" 256
fill "$HOME/Library/Application Support/Claude/vm_bundles" 300
fill "$HOME/Library/Developer/Xcode/DerivedData/Old-abc" 400
fill "$HOME/Library/Developer/Xcode/DerivedData/New-def" 400
touch -t 202001010000 "$HOME/Library/Developer/Xcode/DerivedData/Old-abc"
# Temp: old and unused (goes), old but open in a process (stays), old with a fresh file inside (stays), new (stays),
# Apple's own (stays).
for d in old busy fresh new com.apple.x; do fill "$TMPDIR/$d" 64; done
touch -t 202001010000 "$TMPDIR/old/blob" "$TMPDIR/old" "$TMPDIR/busy/blob" "$TMPDIR/busy" "$TMPDIR/fresh" "$TMPDIR/com.apple.x/blob" "$TMPDIR/com.apple.x"
fill "$HOME/.cache/other" 128
fill "$DEPLOYS_DISK_APPS/Some.app" 64

out="$(cli disk --json)"
expect "report has every category" "$(echo "$out" | jq '.categories | length')" 20
kb() { echo "$out" | jq -r --arg i "$1" '.categories[] | select(.id == $i) | .kb'; }
expect "npm measured" "$([ "$(kb npm)" -ge 2048 ] && echo yes)" yes
expect "caches: Yarn is not counted twice" "$([ "$(kb caches)" -lt 1024 ] && [ "$(kb caches)" -ge 512 ] && echo yes)" yes
expect ".cache without the models" "$([ "$(kb dotcache)" -ge 128 ] && [ "$(kb dotcache)" -lt 1024 ] && echo yes)" yes
expect "/Applications shown, never freed" "$(echo "$out" | jq -r '.categories[] | select(.id == "applications") | .action')" never
expect "snapshots listed, never freed" "$(echo "$out" | jq -r '.categories[] | select(.id == "snapshots") | "\(.action) \(.parts | length)"')" "never 2"
expect "unassigned space reported" "$(echo "$out" | jq '.unassignedKB >= 0')" true
expect "claude-app found" "$([ "$(kb claude-app)" -ge 300 ] && echo yes)" yes
expect "docker parts parsed" "$(echo "$out" | jq -r '.categories[] | select(.id == "docker") | .parts | map(.name) | join(",")')" "Images,Local Volumes,Build Cache"
expect "docker freeable is build cache + images, not volumes" "$(echo "$out" | jq '.categories[] | select(.id == "docker") | .freeableKB')" "$((1048576 + 1572864))"
expect "huggingface stays" "$(echo "$out" | jq -r '.categories[] | select(.id == "huggingface") | .action')" never
expect "transcripts: by you, hint names cleanupPeriodDays" "$(echo "$out" | jq -r '.categories[] | select(.id == "claude-projects") | .action + " " + (.hint | test("cleanupPeriodDays") | tostring)')" "manual true"
expect "first report is not cached" "$(echo "$out" | jq .cached)" false
expect "second report comes from the cache" "$(cli disk --json | jq .cached)" true
expect "text report" "$(cli disk | grep -c 'deploys disk free')" 1

# A du that hangs: the category times out instead of blocking the report.
mkdir -p "$tmp/slow"; printf '#!/bin/bash\nexec sleep 30\n' > "$tmp/slow/du"; chmod +x "$tmp/slow/du"
start=$(date +%s)
slow="$(PATH="$tmp/slow:$PATH" DEPLOYS_DISK_TIMEOUT=2 cli disk --refresh --json)"
expect "slow du: timedOut" "$(echo "$slow" | jq '[.categories[] | select(.id == "npm") | .timedOut][0]')" true
expect "slow du: done within the limit" "$([ $(( $(date +%s) - start )) -lt 20 ] && echo yes)" yes
# Two timeouts in a row keep the last full count, also when the partial count equals it.
full="$(cli disk --refresh --json | jq '.categories[] | select(.id == "npm") | .kb')"
for _ in 1 2; do PATH="$tmp/slow:$PATH" DEPLOYS_DISK_TIMEOUT=1 cli disk --refresh --json >/dev/null; done
again="$(cli disk --json | jq -c '.categories[] | select(.id == "npm") | {kb, stale}')"
expect "two timeouts: last full count, stale" "$again" "{\"kb\":$full,\"stale\":true}"
# The .cache remainder is never the raw total: an overlap that times out makes it unknown, never "all of .cache".
dc_full="$(cli disk --refresh --json | jq '.categories[] | select(.id == "dotcache") | .kb')"
printf '#!/bin/bash\ncase "$*" in *huggingface*) exec sleep 30 ;; esac\nexec /usr/bin/du "$@"\n' > "$tmp/slow2-du"
mkdir -p "$tmp/slow2"; mv "$tmp/slow2-du" "$tmp/slow2/du"; chmod +x "$tmp/slow2/du"
dc="$(PATH="$tmp/slow2:$PATH" DEPLOYS_DISK_TIMEOUT=2 cli disk --refresh --json | jq -c '.categories[] | select(.id == "dotcache") | {kb, stale}')"
expect "overlap timeout: last remainder, not the raw total" "$dc" "{\"kb\":$dc_full,\"stale\":true}"
rm -f "$DEPLOYS_CONFIG/disk/report.json"
dc="$(PATH="$tmp/slow2:$PATH" DEPLOYS_DISK_TIMEOUT=2 cli disk --refresh --json | jq -c '.categories[] | select(.id == "dotcache") | {kb, timedOut}')"
expect "overlap timeout without an earlier count: unknown (0)" "$dc" '{"kb":0,"timedOut":true}'
cli disk --refresh --json >/dev/null   # a good cache again

: > "$calls"
dry="$(cli disk free --json)"
expect "dry run deletes nothing" "$(echo "$dry" | jq .deleted)" false
expect "dry run calls no tool but docker's read-only df" "$(grep -cv '^docker info\|^docker system df' "$calls")" 0
expect "dry run: steps" "$(echo "$dry" | jq -r '[.steps[].id] | join(",")')" "clean,npm,pnpm,yarn,brew,xcode,tmp,simulators"
expect "dry run: untouched lists the Trash" "$(echo "$dry" | jq '[.untouched[] | select(.id == "trash")] | length')" 1
expect "text dry run says nothing was deleted" "$(cli disk free | grep -c 'nothing was deleted')" 1

: > "$calls"
res="$(cli disk free --yes --json)"
expect "free: deleted" "$(echo "$res" | jq .deleted)" true
expect "npm cache clean --force" "$(grep -c '^npm cache clean --force$' "$calls")" 1
expect "pnpm store prune" "$(grep -c '^pnpm store prune$' "$calls")" 1
expect "yarn cache clean" "$(grep -c '^yarn cache clean$' "$calls")" 1
expect "brew cleanup -s" "$(grep -c '^brew cleanup -s$' "$calls")" 1
expect "simctl delete unavailable" "$(grep -c '^xcrun simctl delete unavailable$' "$calls")" 1
expect "docker build cache > 3 days" "$(grep -c '^docker builder prune -f --filter until=72h$' "$calls")" 1
expect "docker dangling images" "$(grep -c '^docker image prune -f$' "$calls")" 1
expect "never volumes, containers or system prune" "$(grep -cE 'volume|container|system prune|-a( |$)|--all' "$calls")" 0
expect "old DerivedData gone" "$([ -d "$HOME/Library/Developer/Xcode/DerivedData/Old-abc" ] || echo gone)" gone
expect "new DerivedData stays" "$([ -d "$HOME/Library/Developer/Xcode/DerivedData/New-def" ] && echo yes)" yes
expect "old unused temp entry gone" "$([ -d "$TMPDIR/old" ] || echo gone)" gone
expect "temp entries in use, fresh, new or Apple's stay" "$(ls "$TMPDIR" | sort | tr '\n' ' ')" "busy com.apple.x fresh new "
expect "Trash untouched" "$([ -f "$HOME/.Trash/blob" ] && echo yes)" yes
expect "transcripts untouched" "$([ -f "$HOME/.claude/projects/p/blob" ] && echo yes)" yes
expect "models untouched" "$([ -f "$HOME/.cache/huggingface/hub/blob" ] && echo yes)" yes
expect "Claude app folders untouched" "$([ -f "$HOME/Library/Application Support/Claude/vm_bundles/blob" ] && echo yes)" yes
expect "lock released" "$([ -d "$DEPLOYS_CONFIG/disk/lock" ] || echo free)" free
expect "journal line" "$(grep -c '"disk"' "$tmp/journal.jsonl" 2>/dev/null)" 1

# lsof failing: no temp file is deleted, and the step is reported as failed.
fill "$TMPDIR/old2" 64; touch -t 202001010000 "$TMPDIR/old2/blob" "$TMPDIR/old2"
printf '#!/bin/bash\nexit 1\n' > "$tmp/bin/lsof"; : > "$calls"
lres="$(cli disk free --yes --json)"
expect "lsof failed: tmp step failed" "$(echo "$lres" | jq -r '.steps[] | select(.id == "tmp") | .status')" failed
expect "lsof failed: old temp entry stays" "$([ -d "$TMPDIR/old2" ] && echo yes)" yes

# Stopped with SIGTERM while a step runs: the step ends, nothing after it runs, the lock is released.
printf '#!/bin/bash\necho "lsof ok"\n' > "$tmp/bin/lsof"
printf '#!/bin/bash\necho "npm $*" >> "%s"\nsleep 3\n' "$calls" > "$tmp/bin/npm"; : > "$calls"
env DEPLOYS_JOURNAL="$tmp/journal.jsonl" bash ./deploys disk free --yes --json > /dev/null 2>&1 &
p=$!
for _ in $(seq 1 50); do grep -q '^npm cache clean' "$calls" && break; sleep 0.1; done
kill -TERM "$p"; wait "$p" 2>/dev/null
expect "SIGTERM: lock released" "$([ -d "$DEPLOYS_CONFIG/disk/lock" ] || echo free)" free
expect "SIGTERM: later steps do not run" "$(grep -c '^brew' "$calls")" 0
printf '#!/bin/bash\necho "npm $*" >> "%s"\n' "$calls" > "$tmp/bin/npm"
# Yarn 2+: its global cache folder goes, a project's own .yarn/cache stays.
fill "$HOME/.yarn/berry/cache" 64; fill "$tmp/proj/.yarn/cache" 64
(cd "$tmp/proj" && FAKE_YARN=4.1.0 env DEPLOYS_JOURNAL="$tmp/journal.jsonl" bash "$OLDPWD/deploys" disk free --yes >/dev/null 2>&1)
expect "yarn 2+: global cache gone" "$([ -d "$HOME/.yarn/berry/cache" ] || echo gone)" gone
expect "yarn 2+: project cache stays" "$([ -f "$tmp/proj/.yarn/cache/blob" ] && echo yes)" yes

# The schedule: opt-in, writes disk.json, the tick runs free below the minimum and not again within 6 hours.
expect "schedule on without --yes changes nothing" "$(cli disk schedule on >/dev/null; [ -f "$DEPLOYS_CONFIG/disk.json" ] || echo none)" none
cli disk schedule on --min-free 100 --yes >/dev/null
expect "disk.json" "$(jq -c '{auto, minFreeGB}' "$DEPLOYS_CONFIG/disk.json")" '{"auto":true,"minFreeGB":100}'
expect "status on" "$(cli disk schedule status | cut -d: -f1)" on
# The disk of this machine has less than a huge minimum free: the tick must run free (in the background).
jq '.minFreeGB = 999999' "$DEPLOYS_CONFIG/disk.json" > "$tmp/d.json" && mv "$tmp/d.json" "$DEPLOYS_CONFIG/disk.json"
rm -f "$DEPLOYS_CONFIG/disk/last-free" "$DEPLOYS_CONFIG/disk/last-check"; : > "$calls"
cli disk tick
for _ in 1 2 3 4 5 6 7 8 9 10; do grep -q '^notify ' "$calls" && break; sleep 1; done
expect "tick below the minimum: free ran" "$(grep -c '^npm cache clean --force$' "$calls")" 1
expect "tick: a notification with the freed GB" "$(grep -c '^notify Disk space freed .* GB freed' "$calls")" 1
: > "$calls"; rm -f "$DEPLOYS_CONFIG/disk/last-check"
cli disk tick; sleep 1
expect "tick again within 6 hours: nothing" "$(grep -c '^npm' "$calls")" 0
cli disk schedule off >/dev/null
expect "schedule off" "$(cli disk schedule status)" off
rm -f "$DEPLOYS_CONFIG/disk/last-free" "$DEPLOYS_CONFIG/disk/last-check"; : > "$calls"
cli disk tick; sleep 1
expect "tick when off: nothing" "$(grep -c '^npm' "$calls")" 0

[ "$fails" = 0 ] && echo "disk tests: all ok" || echo "disk tests: $fails failed"
exit "$fails"
