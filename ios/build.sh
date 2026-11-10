#!/bin/bash
# Builds the iOS app (ios/DeployCenter.xcodeproj). Needs Xcode.
#   ios/build.sh               build for the simulator into build/ios-dd
#   ios/build.sh --run         also install and start it in the booted simulator, in demo mode
#   ios/build.sh --archive     archive for the App Store and export an .ipa into build/ios-export (no upload)
# The team id comes from the signing identity (~/.config/deploys/signing-identity or DEVELOPER_ID),
# never from the repo. Uploading is a separate, manual step: see docs/APP-STORE.md.
set -euo pipefail
cd "$(dirname "$0")/.."
mode="${1:-build}"
DD=build/ios-dd
die() { echo "ios/build.sh: $*" >&2; exit 1; }

case "$mode" in
  build|--run)
    xcodebuild -project ios/DeployCenter.xcodeproj -scheme DeployCenter -sdk iphonesimulator \
      -configuration Debug -derivedDataPath "$DD" CODE_SIGN_IDENTITY=- build -quiet
    APP="$DD/Build/Products/Debug-iphonesimulator/DeployCenter.app"
    echo "Built: $APP"
    if [ "$mode" = --run ]; then
      xcrun simctl install booted "$APP"
      xcrun simctl launch booted app.deploycenter.ios -demo
    fi ;;
  --archive)
    id="${DEVELOPER_ID:-}"
    if [ -z "$id" ] && [ -s "$HOME/.config/deploys/signing-identity" ]; then id="$(head -n1 "$HOME/.config/deploys/signing-identity")"; fi
    team="$(sed -n 's/.*(\([A-Z0-9]\{10\}\))$/\1/p' <<<"$id")"
    [ -n "$team" ] || die "no team id: set DEVELOPER_ID or ~/.config/deploys/signing-identity"
    mkdir -p build
    cat > build/ExportOptions.plist <<PLIST
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0"><dict>
  <key>method</key><string>app-store-connect</string>
  <key>destination</key><string>export</string>
  <key>teamID</key><string>${team}</string>
  <key>signingStyle</key><string>automatic</string>
  <key>uploadSymbols</key><true/>
</dict></plist>
PLIST
    xcodebuild -project ios/DeployCenter.xcodeproj -scheme DeployCenter -configuration Release \
      -destination 'generic/platform=iOS' -archivePath build/DeployCenter-iOS.xcarchive \
      DEVELOPMENT_TEAM="$team" CODE_SIGNING_ALLOWED=NO archive
    # The archive is unsigned: automatic signing would first need a development profile, and that
    # needs a registered device. An ad hoc signature carries the entitlements (the App Group) to the
    # export, which re-signs with App Store profiles; those need no device.
    built="build/DeployCenter-iOS.xcarchive/Products/Applications/DeployCenter.app"
    codesign --force -s - --entitlements ios/Config/DeployCenterWidgets.entitlements "$built/PlugIns/DeployCenterWidgets.appex"
    codesign --force -s - --entitlements ios/Config/DeployCenter.entitlements "$built"
    xcodebuild -exportArchive -archivePath build/DeployCenter-iOS.xcarchive \
      -exportOptionsPlist build/ExportOptions.plist -exportPath build/ios-export -allowProvisioningUpdates
    echo "Exported: build/ios-export (upload it with Transporter or xcrun altool, see docs/APP-STORE.md)" ;;
  -h|--help) sed -n '2,7p' "$0" | sed 's/^# \{0,1\}//' ;;
  *) die "unknown argument: $mode" ;;
esac
