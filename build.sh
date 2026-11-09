#!/bin/bash
# Builds "Deploy Center.app" and a zip for a release. Needs swiftc (Xcode or Command Line Tools).
#   ./build.sh            build into build/
#   ./build.sh --install  also copy the app to ~/Applications
set -euo pipefail
cd "$(dirname "$0")"

VERSION="$(cat VERSION 2>/dev/null || echo 0.1.0)"
BUILD="build/Deploy Center.app"

rm -rf build && mkdir -p "$BUILD/Contents/MacOS" "$BUILD/Contents/Resources"

# Universal binary: Apple silicon and Intel. macOS 15 is the floor; the app checks for jq itself.
for arch in arm64 x86_64; do
  swiftc -O -parse-as-library -swift-version 5 \
    -target "$arch-apple-macosx15.0" \
    -o "build/DeployCenter-$arch" app/DeployCenter.swift
done
lipo -create build/DeployCenter-arm64 build/DeployCenter-x86_64 -output "$BUILD/Contents/MacOS/DeployCenter"
rm build/DeployCenter-arm64 build/DeployCenter-x86_64

cp deploys "$BUILD/Contents/Resources/deploys"
chmod +x "$BUILD/Contents/Resources/deploys"
[ -f app/AppIcon.icns ] && cp app/AppIcon.icns "$BUILD/Contents/Resources/AppIcon.icns"

cat > "$BUILD/Contents/Info.plist" <<PLIST
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0"><dict>
  <key>CFBundleName</key><string>Deploy Center</string>
  <key>CFBundleDisplayName</key><string>Deploy Center</string>
  <key>CFBundleIdentifier</key><string>app.deploycenter.mac</string>
  <key>CFBundleExecutable</key><string>DeployCenter</string>
  <key>CFBundleIconFile</key><string>AppIcon</string>
  <key>CFBundlePackageType</key><string>APPL</string>
  <key>CFBundleShortVersionString</key><string>${VERSION}</string>
  <key>CFBundleVersion</key><string>${VERSION}</string>
  <key>LSMinimumSystemVersion</key><string>15.0</string>
  <key>NSHighResolutionCapable</key><true/>
</dict></plist>
PLIST

# Signing. With a "Developer ID Application" certificate in the keychain and a notarytool
# profile, the app is signed for distribution and notarized, so it opens without a warning:
#   DEVELOPER_ID="Developer ID Application: Name (TEAMID)" NOTARY_PROFILE=deploy-center ./build.sh
# Without them it is signed ad hoc, which is enough on the Mac that built it.
ZIP="build/DeployCenter-${VERSION}-universal.zip"
if [ -n "${DEVELOPER_ID:-}" ]; then
  codesign --force --options runtime --timestamp -s "$DEVELOPER_ID" "$BUILD/Contents/Resources/deploys"
  codesign --force --options runtime --timestamp -s "$DEVELOPER_ID" "$BUILD"
  codesign --verify --strict "$BUILD"
  if [ -n "${NOTARY_PROFILE:-}" ]; then
    (cd build && ditto -c -k --keepParent "Deploy Center.app" notarize.zip)
    xcrun notarytool submit build/notarize.zip --keychain-profile "$NOTARY_PROFILE" --wait
    xcrun stapler staple "$BUILD"
    rm build/notarize.zip
  fi
else
  codesign --force --deep -s - "$BUILD"
fi
(cd build && ditto -c -k --keepParent "Deploy Center.app" "$(basename "$ZIP")")
echo "Built: $BUILD and build/DeployCenter-${VERSION}-universal.zip"

if [ "${1:-}" = "--install" ]; then
  mkdir -p "$HOME/Applications"
  rm -rf "$HOME/Applications/Deploy Center.app"
  cp -R "$BUILD" "$HOME/Applications/Deploy Center.app"
  echo "Installed: $HOME/Applications/Deploy Center.app"
fi
