#!/bin/bash
# Builds the iOS companion for the simulator with swiftc, without an Xcode project.
#   ios/build.sh           build build/ios/DeployCenter.app (simulator, this Mac's architecture)
#   ios/build.sh --run     also install and start it in the booted simulator (with sample data)
# A device or TestFlight build needs signing and provisioning: see docs/WIDGETS-IOS.md.
set -euo pipefail
cd "$(dirname "$0")/.."
run=0; [ "${1:-}" = "--run" ] && run=1
VERSION="$(cat VERSION)"
APP="build/ios/DeployCenter.app"
rm -rf "$APP"; mkdir -p "$APP"
arch="$(uname -m)"
xcrun --sdk iphonesimulator swiftc -O -parse-as-library -swift-version 5 \
  -target "$arch-apple-ios18.0-simulator" -o "$APP/DeployCenter" ios/*.swift shared/*.swift
cat > "$APP/Info.plist" <<PLIST
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0"><dict>
  <key>CFBundleName</key><string>Deploy Center</string>
  <key>CFBundleDisplayName</key><string>Deploy Center</string>
  <key>CFBundleIdentifier</key><string>app.deploycenter.ios</string>
  <key>CFBundleExecutable</key><string>DeployCenter</string>
  <key>CFBundlePackageType</key><string>APPL</string>
  <key>CFBundleShortVersionString</key><string>${VERSION}</string>
  <key>CFBundleVersion</key><string>${VERSION}</string>
  <key>MinimumOSVersion</key><string>18.0</string>
  <key>UIDeviceFamily</key><array><integer>1</integer></array>
  <key>UILaunchScreen</key><dict/>
  <key>UIApplicationSceneManifest</key><dict><key>UIApplicationSupportsMultipleScenes</key><false/></dict>
  <key>CFBundleSupportedPlatforms</key><array><string>iPhoneSimulator</string></array>
</dict></plist>
PLIST
codesign --force -s - "$APP"
echo "Built: $APP"
if [ "$run" = 1 ]; then
  xcrun simctl install booted "$APP"
  xcrun simctl launch booted app.deploycenter.ios -sample
fi
