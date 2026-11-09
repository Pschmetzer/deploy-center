#!/bin/bash
# Builds "Deploy Center.app" and a zip for a release. Needs swiftc (Xcode or Command Line Tools).
#   ./build.sh            build into build/
#   ./build.sh --install  also copy the app to ~/Applications
set -euo pipefail
cd "$(dirname "$0")"

VERSION="$(cat VERSION 2>/dev/null || echo 0.1.0)"
BUILD="build/Deploy Center.app"

rm -rf build && mkdir -p "$BUILD/Contents/MacOS" "$BUILD/Contents/Resources"

# macOS 15 is the floor because it ships /usr/bin/jq, which the script needs.
swiftc -O -parse-as-library -swift-version 5 \
  -target arm64-apple-macosx15.0 \
  -o "$BUILD/Contents/MacOS/DeployCenter" app/DeployCenter.swift

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

codesign --force --deep -s - "$BUILD"
(cd build && ditto -c -k --keepParent "Deploy Center.app" "DeployCenter-${VERSION}-arm64.zip")
echo "Built: $BUILD and build/DeployCenter-${VERSION}-arm64.zip"

if [ "${1:-}" = "--install" ]; then
  mkdir -p "$HOME/Applications"
  rm -rf "$HOME/Applications/Deploy Center.app"
  cp -R "$BUILD" "$HOME/Applications/Deploy Center.app"
  echo "Installed: $HOME/Applications/Deploy Center.app"
fi
