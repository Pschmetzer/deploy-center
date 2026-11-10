#!/bin/bash
# Builds "Deploy Center.app" and a zip for a release. Needs swiftc (Xcode or Command Line Tools).
#   ./build.sh            build into build/ (universal: Apple silicon and Intel)
#   ./build.sh --fast     only for this Mac's architecture (quicker; not for a release)
#   ./build.sh --install  also copy the app to ~/Applications (quits a running copy first)
#   ./build.sh --widgets  also build the widget extension (widgets/) into the app, see docs/WIDGETS-IOS.md
# Only the app and its zip in build/ are replaced; other files there stay.
set -euo pipefail
cd "$(dirname "$0")"

usage() { sed -n '2,7p' "$0" | sed 's/^# \{0,1\}//'; }
fast=0 install=0 widgets=0
for arg in "$@"; do
  case "$arg" in
    --fast) fast=1 ;;
    --install) install=1 ;;
    --widgets) widgets=1 ;;
    -h|--help) usage; exit 0 ;;
    *) usage >&2; echo "build.sh: unknown argument: $arg" >&2; exit 2 ;;
  esac
done

die() { echo "build.sh: $*" >&2; exit 1; }
for tool in swiftc lipo ditto codesign; do
  command -v "$tool" >/dev/null || die "$tool is missing; install Xcode or run: xcode-select --install"
done
# An Xcode whose license was never accepted makes swiftc fail with a confusing message.
if ! swiftc -version >/dev/null 2>&1; then
  die "swiftc does not run. If Xcode is new: sudo xcodebuild -license accept"
fi

VERSION="$(cat VERSION 2>/dev/null || true)"
[[ "$VERSION" =~ ^[0-9]+\.[0-9]+\.[0-9]+$ ]] || die "VERSION must be x.y.z, not \"$VERSION\""
BUILD="build/Deploy Center.app"
ZIP="build/DeployCenter-${VERSION}-universal.zip"
YEAR="$(date +%Y)"

mkdir -p build
rm -rf "$BUILD" "$ZIP" build/notarize.zip build/DeployCenter-arm64 build/DeployCenter-x86_64
mkdir -p "$BUILD/Contents/MacOS" "$BUILD/Contents/Resources"

# Universal binary: Apple silicon and Intel. macOS 15 is the floor; the app checks for jq itself.
if [ "$fast" = 1 ]; then archs="$(uname -m)"; else archs="arm64 x86_64"; fi
slices=()
for arch in $archs; do
  swiftc -O -parse-as-library -swift-version 5 \
    -target "$arch-apple-macosx15.0" \
    -o "build/DeployCenter-$arch" app/*.swift shared/*.swift
  slices+=("build/DeployCenter-$arch")
done
lipo -create "${slices[@]}" -output "$BUILD/Contents/MacOS/DeployCenter"
rm -f "${slices[@]}"

# Widgets (opt-in): a WidgetKit extension in Contents/PlugIns, built with swiftc like the app.
if [ "$widgets" = 1 ]; then
  APPEX="$BUILD/Contents/PlugIns/DeployCenterWidgets.appex"
  mkdir -p "$APPEX/Contents/MacOS"
  wslices=()
  for arch in $archs; do
    swiftc -O -parse-as-library -application-extension -swift-version 5 -module-name DeployCenterWidgets \
      -target "$arch-apple-macosx15.0" -o "build/DeployCenterWidgets-$arch" widgets/*.swift shared/*.swift
    wslices+=("build/DeployCenterWidgets-$arch")
  done
  lipo -create "${wslices[@]}" -output "$APPEX/Contents/MacOS/DeployCenterWidgets"
  rm -f "${wslices[@]}"
fi

cp deploys "$BUILD/Contents/Resources/deploys"
chmod +x "$BUILD/Contents/Resources/deploys"
# The platforms, one file each, next to the script: it finds them as providers/*.sh.
cp -R providers "$BUILD/Contents/Resources/providers"
# Team mode (lib/team.sh) and GitLab support (lib/githost.sh) are sourced by the script from next to it.
mkdir -p "$BUILD/Contents/Resources/lib" && cp lib/*.sh "$BUILD/Contents/Resources/lib/"
[ -f app/AppIcon.icns ] && cp app/AppIcon.icns "$BUILD/Contents/Resources/AppIcon.icns"
# The MCP server for Settings > Claude, only when its packages are installed (cd integrations/mcp && npm ci).
# Without them the app points to the repo's copy, or says what is missing.
if [ -f integrations/mcp/server.mjs ] && [ -d integrations/mcp/node_modules/@modelcontextprotocol ]; then
  mkdir -p "$BUILD/Contents/Resources/mcp"
  cp integrations/mcp/server.mjs integrations/mcp/package.json "$BUILD/Contents/Resources/mcp/"
  ditto integrations/mcp/node_modules "$BUILD/Contents/Resources/mcp/node_modules"
fi
for f in integrations/mcp/deploy-center.mcpb integrations/claude-desktop/deploy-center.mcpb; do
  if [ -f "$f" ]; then cp "$f" "$BUILD/Contents/Resources/deploy-center.mcpb"; break; fi
done

# The identity is needed before signing: the App Group is "<TEAMID>.app.deploycenter", the team id
# taken from the identity, so it never lives in the repo. Without an identity there is no group.
if [ -z "${DEVELOPER_ID:-}" ] && [ -s "$HOME/.config/deploys/signing-identity" ]; then
  DEVELOPER_ID="$(head -n1 "$HOME/.config/deploys/signing-identity")"
fi
[ "${DEVELOPER_ID:-}" = "-" ] && DEVELOPER_ID=""   # DEVELOPER_ID=- forces an ad hoc build
APP_GROUP=""
if [ "$widgets" = 1 ] && [ -n "${DEVELOPER_ID:-}" ]; then
  team="$(sed -n 's/.*(\([A-Z0-9]\{10\}\))$/\1/p' <<<"$DEVELOPER_ID")"
  [ -n "$team" ] || die "no team id in the signing identity \"$DEVELOPER_ID\""
  APP_GROUP="$team.app.deploycenter"
fi
GROUP_KEY=""
[ "$widgets" = 1 ] && GROUP_KEY="<key>DCAppGroup</key><string>${APP_GROUP}</string>"

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
  <key>LSApplicationCategoryType</key><string>public.app-category.developer-tools</string>
  <key>NSHumanReadableCopyright</key><string>© ${YEAR} Deploy Center contributors. MIT License.</string>
  <key>NSHighResolutionCapable</key><true/>
  <key>CFBundleURLTypes</key><array><dict><key>CFBundleURLName</key><string>app.deploycenter.mac</string><key>CFBundleURLSchemes</key><array><string>deploycenter</string></array></dict></array>
  ${GROUP_KEY}
</dict></plist>
PLIST
plutil -lint -s "$BUILD/Contents/Info.plist"

if [ "$widgets" = 1 ]; then
  cat > "$APPEX/Contents/Info.plist" <<PLIST
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0"><dict>
  <key>CFBundleName</key><string>Deploy Center Widgets</string>
  <key>CFBundleDisplayName</key><string>Deploy Center</string>
  <key>CFBundleIdentifier</key><string>app.deploycenter.mac.widgets</string>
  <key>CFBundleExecutable</key><string>DeployCenterWidgets</string>
  <key>CFBundlePackageType</key><string>XPC!</string>
  <key>CFBundleShortVersionString</key><string>${VERSION}</string>
  <key>CFBundleVersion</key><string>${VERSION}</string>
  <key>LSMinimumSystemVersion</key><string>15.0</string>
  <key>NSExtension</key><dict><key>NSExtensionPointIdentifier</key><string>com.apple.widgetkit-extension</string></dict>
  ${GROUP_KEY}
</dict></plist>
PLIST
  plutil -lint -s "$APPEX/Contents/Info.plist"
  # Widgets must be sandboxed; both sides get the App Group when there is one.
  groups=""
  [ -n "$APP_GROUP" ] && groups="<key>com.apple.security.application-groups</key><array><string>${APP_GROUP}</string></array>"
  printf '%s\n' '<?xml version="1.0" encoding="UTF-8"?>' '<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">' \
    "<plist version=\"1.0\"><dict><key>com.apple.security.app-sandbox</key><true/>${groups}</dict></plist>" > build/widgets.entitlements
  printf '%s\n' '<?xml version="1.0" encoding="UTF-8"?>' '<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">' \
    "<plist version=\"1.0\"><dict>${groups}</dict></plist>" > build/app.entitlements
fi

# Signing. With a "Developer ID Application" certificate in the keychain and a notarytool
# profile, the app is signed for distribution and notarized, so it opens without a warning:
#   DEVELOPER_ID="Developer ID Application: Name (TEAMID)" NOTARY_PROFILE=deploy-center ./build.sh
# The identity can also live in ~/.config/deploys/signing-identity (one line, never in the repo).
# Without one it is signed ad hoc: the app runs, but macOS refuses it as a login item.
# (The identity was read above, before the Info.plist.)
# With widgets the extension is signed first, with its entitlements, and the app without --deep,
# which would sign the extension again and drop them.
if [ "$widgets" = 1 ]; then
  sid="${DEVELOPER_ID:--}"
  rt=(); [ -n "${DEVELOPER_ID:-}" ] && rt=(--options runtime --timestamp)
  codesign --force ${rt[@]+"${rt[@]}"} -s "$sid" "$BUILD/Contents/Resources/deploys"
  codesign --force ${rt[@]+"${rt[@]}"} -s "$sid" --entitlements build/widgets.entitlements "$APPEX"
  codesign --force ${rt[@]+"${rt[@]}"} -s "$sid" --entitlements build/app.entitlements "$BUILD"
  codesign --verify --strict --deep "$BUILD"
  if [ -n "${DEVELOPER_ID:-}" ] && [ -n "${NOTARY_PROFILE:-}" ]; then
    (cd build && ditto -c -k --keepParent "Deploy Center.app" notarize.zip)
    xcrun notarytool submit build/notarize.zip --keychain-profile "$NOTARY_PROFILE" --wait
    xcrun stapler staple "$BUILD"
    rm build/notarize.zip
  fi
elif [ -n "${DEVELOPER_ID:-}" ]; then
  codesign --force --options runtime --timestamp -s "$DEVELOPER_ID" "$BUILD/Contents/Resources/deploys"
  codesign --force --options runtime --timestamp -s "$DEVELOPER_ID" "$BUILD/Contents/Resources/providers/"*.sh
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
echo "Built: $BUILD and $ZIP"
[ "$fast" = 0 ] || echo "Note: --fast built only $archs; the zip is not universal."

if [ "$install" = 1 ]; then
  dest="$HOME/Applications/Deploy Center.app"
  was_running=0
  if pgrep -xq DeployCenter; then
    was_running=1
    osascript -e 'tell application id "app.deploycenter.mac" to quit' >/dev/null 2>&1 || true
    for _ in $(seq 1 20); do pgrep -xq DeployCenter || break; sleep 0.5; done
    pgrep -xq DeployCenter && die "Deploy Center is still running; quit it and run again"
  fi
  mkdir -p "$HOME/Applications"
  rm -rf "$dest"
  cp -R "$BUILD" "$dest"
  echo "Installed: $dest"
  [ "$was_running" = 0 ] || open "$dest"
fi
