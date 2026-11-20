#!/bin/bash
# Smoke test on the simulator (IDEEN-12 C60): the Debug build starts in demo mode on an iPhone and an iPad, at the standard
# text size and at the largest accessibility size, and is still running after a few seconds. A screenshot of each goes to
# the folder given (default build/ios-smoke). Needs Xcode; nothing is sent anywhere and no account is used.
#   ios/smoke.sh /path/to/Debug-iphonesimulator/DeployCenter.app [project-name]
set -euo pipefail
app="${1:?usage: ios/smoke.sh <DeployCenter.app> [project-name]}"
name="${2:-}"
out="${SMOKE_OUT:-build/ios-smoke}"
mkdir -p "$out"
bundle="app.deploycenter.ios"
fail=0
first_of() { xcrun simctl list devices available | { grep -E "^ +$1" || true; } | head -1 | sed -E 's/^ +(.*) \(([0-9A-F-]{36})\).*/\2/' || true; }
for kind in iPhone iPad; do
  udid="$(first_of "$kind")"
  if [ -z "$udid" ]; then echo "skip $kind: no simulator"; continue; fi
  xcrun simctl boot "$udid" 2>/dev/null || true
  xcrun simctl bootstatus "$udid" -b >/dev/null
  xcrun simctl install "$udid" "$app"
  for size in large accessibility-extra-extra-extra-large; do
    xcrun simctl ui "$udid" content_size "$size"
    xcrun simctl terminate "$udid" "$bundle" 2>/dev/null || true
    args=(-demo)
    [ -n "$name" ] && args+=(-open "$name")
    xcrun simctl launch "$udid" "$bundle" "${args[@]}" >/dev/null
    sleep 6
    # A crashed app has no pid any more.
    if xcrun simctl spawn "$udid" launchctl list | grep -q "UIKitApplication:$bundle"; then
      echo "ok   $kind, $size: running"
    else
      echo "FAIL $kind, $size: the app is not running"; fail=1
    fi
    xcrun simctl io "$udid" screenshot "$out/$kind-$size.png" >/dev/null
  done
  xcrun simctl ui "$udid" content_size large
  xcrun simctl shutdown "$udid" 2>/dev/null || true
done
exit "$fail"
