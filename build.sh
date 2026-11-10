#!/bin/bash
# Builds "Deploy Center.app" and a zip for a release. Needs swiftc (Xcode or Command Line Tools).
#   ./build.sh            build into build/ (universal: Apple silicon and Intel)
#   ./build.sh --fast     only for this Mac's architecture (quicker; not for a release)
#   ./build.sh --install  also copy the app to ~/Applications (quits a running copy first); with a
#                         signing identity it always builds the widgets too
#   ./build.sh --widgets  also build the widget extension (widgets/) into the app, see docs/WIDGETS-IOS.md
# Only the app and its zip in build/ are replaced; other files there stay.
#
# Environment (all optional):
#   DEVELOPER_ID         signing identity "Developer ID Application: … (TEAMID)"; "-" forces ad hoc
#                        (default: ~/.config/deploys/signing-identity, else ad hoc)
#   NOTARY_PROFILE       a notarytool keychain profile: notarize and staple too (release.sh does it itself)
#   DC_MAC_PROFILE       the Developer ID provisioning profile for the iPhone link
#                        (default: ~/.config/deploys/mac-developer-id.provisionprofile)
#   SPARKLE_FEED_URL     update feed, and SPARKLE_PUBLIC_KEY its key: for local update tests only
#                        (release.sh ignores both)
set -euo pipefail
cd "$(dirname "$0")"

usage() { sed -n '2,/^set -euo/p' "$0" | sed '$d' | sed 's/^# \{0,1\}//'; }
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
# --install replaces the copy in ~/Applications. Without the widgets that copy loses them, and any
# widget placed on the desktop goes blank, so an install with a signing identity always has them.
if [ "$install" = 1 ] && [ "$widgets" = 0 ] && { [ -n "${DEVELOPER_ID:-}" ] || [ -s "$HOME/.config/deploys/signing-identity" ]; } \
   && [ "${DEVELOPER_ID:-}" != "-" ]; then
  widgets=1
  echo "build.sh: --install builds the widgets too (the installed copy keeps them)." >&2
fi
for tool in swiftc lipo ditto codesign plutil; do
  command -v "$tool" >/dev/null || die "$tool is missing; install Xcode or run: xcode-select --install"
done
# Only for what was asked: notarizing needs xcrun, --install quits a running copy with pgrep and osascript.
[ -z "${NOTARY_PROFILE:-}" ] || command -v xcrun >/dev/null || die "xcrun is missing (needed to notarize); run: xcode-select --install"
if [ "$install" = 1 ]; then
  for tool in pgrep osascript; do command -v "$tool" >/dev/null || die "$tool is missing (needed by --install)"; done
fi
# An Xcode whose license was never accepted makes swiftc fail with a confusing message.
if ! swiftc -version >/dev/null 2>&1; then
  die "swiftc does not run. If Xcode is new: sudo xcodebuild -license accept"
fi

VERSION="$(cat VERSION 2>/dev/null || true)"
[[ "$VERSION" =~ ^[0-9]+\.[0-9]+\.[0-9]+$ ]] || die "VERSION must be x.y.z, not \"$VERSION\""
BUILD="build/Deploy Center.app"
ZIP="build/DeployCenter-${VERSION}-universal.zip"
YEAR="$(date +%Y)"

# Sparkle (in-app updates): the pinned, checksum-verified release from scripts/sparkle.sh.
# SPARKLE_FEED_URL and SPARKLE_PUBLIC_KEY override the feed and key only for local update tests.
SPARKLE="$(scripts/sparkle.sh)"
FEED_URL="${SPARKLE_FEED_URL:-https://deploycenter.app/appcast.xml}"
# The public half of the EdDSA key (the private half is in the release Mac's keychain, account "deploy-center").
PUBLIC_ED_KEY="${SPARKLE_PUBLIC_KEY:-E9FOsb2DUpGj2c6VBR+/8/v4/diczdqTaVJ6RvCkOXQ=}"

mkdir -p build
rm -rf "$BUILD" "$ZIP" build/notarize.zip build/DeployCenter-arm64 build/DeployCenter-x86_64
mkdir -p "$BUILD/Contents/MacOS" "$BUILD/Contents/Resources"

# Universal binary: Apple silicon and Intel. macOS 15 is the floor; the app checks for jq itself.
if [ "$fast" = 1 ]; then archs="$(uname -m)"; else archs="arm64 x86_64"; fi
# One swiftc per architecture at the same time, each with its own module cache; each pid is
# waited for on its own (a bare `wait` returns 0 and would hide a failed slice). The output of
# each comes after, in order, so warnings do not interleave.
slices=()
build_slices() {  # build_slices <name> <swiftc args...>: build/<name>-<arch> for every arch, into slices
  local name="$1" arch pids=() i=0 bad=""; shift; slices=()
  for arch in $archs; do
    swiftc "$@" -target "$arch-apple-macosx15.0" -module-cache-path "build/ModuleCache-$arch" \
      -o "build/$name-$arch" > "build/$name-$arch.log" 2>&1 &
    pids+=("$!"); slices+=("build/$name-$arch")
  done
  for arch in $archs; do
    wait "${pids[$i]}" || bad="$bad $arch"; i=$((i + 1))
    cat "build/$name-$arch.log" >&2; rm -f "build/$name-$arch.log"
  done
  [ -z "$bad" ] || die "swiftc failed for $name:$bad (see above)"
}
build_slices DeployCenter -O -parse-as-library -swift-version 5 \
  -F "$SPARKLE" -framework Sparkle -Xlinker -rpath -Xlinker @executable_path/../Frameworks \
  app/*.swift shared/*.swift
lipo -create "${slices[@]}" -output "$BUILD/Contents/MacOS/DeployCenter"
rm -f "${slices[@]}"

# Sparkle.framework without what a non-sandboxed app does not need: the XPC services (only for
# sandboxed apps) and the headers.
FW="$BUILD/Contents/Frameworks/Sparkle.framework"
mkdir -p "$BUILD/Contents/Frameworks"
ditto "$SPARKLE/Sparkle.framework" "$FW"
rm -rf "$FW/XPCServices" "$FW/Versions/B/XPCServices" "$FW/Headers" "$FW/Versions/B/Headers" \
       "$FW/PrivateHeaders" "$FW/Versions/B/PrivateHeaders" "$FW/Modules" "$FW/Versions/B/Modules"

# Widgets (opt-in): a WidgetKit extension in Contents/PlugIns, built with swiftc like the app.
if [ "$widgets" = 1 ]; then
  APPEX="$BUILD/Contents/PlugIns/DeployCenterWidgets.appex"
  mkdir -p "$APPEX/Contents/MacOS"
  build_slices DeployCenterWidgets -O -parse-as-library -application-extension -swift-version 5 -module-name DeployCenterWidgets \
    widgets/*.swift shared/*.swift
  lipo -create "${slices[@]}" -output "$APPEX/Contents/MacOS/DeployCenterWidgets"
  rm -f "${slices[@]}"
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
# The iPhone link (Settings → iPhone) shares one iCloud Keychain item with the iOS app, in the team's
# keychain group "<TEAMID>.app.deploycenter.shared". macOS allows that group only with the Developer
# ID provisioning profile of app.deploycenter.mac, kept outside the repo: DC_MAC_PROFILE, or
# ~/.config/deploys/mac-developer-id.provisionprofile. Without it the app is built without the link
# (the QR code still works).
LINK_GROUP=""; LINK_ENT=""
PROFILE="${DC_MAC_PROFILE:-$HOME/.config/deploys/mac-developer-id.provisionprofile}"
if [ -n "${DEVELOPER_ID:-}" ] && [ -s "$PROFILE" ]; then
  lteam="$(sed -n 's/.*(\([A-Z0-9]\{10\}\))$/\1/p' <<<"$DEVELOPER_ID")"
  [ -n "$lteam" ] || die "no team id in the signing identity \"$DEVELOPER_ID\""
  # Read into a variable first: grep -q stops early, and under pipefail the SIGPIPE of security
  # would read as "not the profile".
  prof="$(security cms -D -i "$PROFILE" 2>/dev/null || true)"
  grep -qF "<string>$lteam.app.deploycenter.mac</string>" <<<"$prof" \
    || die "$PROFILE is not the Developer ID profile of app.deploycenter.mac for this team"
  LINK_GROUP="$lteam.app.deploycenter.shared"
  LINK_ENT="<key>com.apple.application-identifier</key><string>$lteam.app.deploycenter.mac</string><key>com.apple.developer.team-identifier</key><string>$lteam</string><key>keychain-access-groups</key><array><string>$LINK_GROUP</string></array>"
  GROUP_KEY="$GROUP_KEY<key>DCKeychainGroup</key><string>${LINK_GROUP}</string>"
fi

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
  <key>SUFeedURL</key><string>${FEED_URL}</string>
  <key>SUPublicEDKey</key><string>${PUBLIC_ED_KEY}</string>
  <key>SUVerifyUpdateBeforeExtraction</key><true/>
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
    "<plist version=\"1.0\"><dict>${groups}${LINK_ENT}</dict></plist>" > build/app.entitlements
fi
if [ -n "$LINK_ENT" ]; then
  cp "$PROFILE" "$BUILD/Contents/embedded.provisionprofile"
  if [ "$widgets" != 1 ]; then
    printf '%s\n' '<?xml version="1.0" encoding="UTF-8"?>' '<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">' \
      "<plist version=\"1.0\"><dict>${LINK_ENT}</dict></plist>" > build/app.entitlements
  fi
fi

# Signing. With a "Developer ID Application" certificate in the keychain and a notarytool
# profile, the app is signed for distribution and notarized, so it opens without a warning:
#   DEVELOPER_ID="Developer ID Application: Name (TEAMID)" NOTARY_PROFILE=deploy-center ./build.sh
# The identity can also live in ~/.config/deploys/signing-identity (one line, never in the repo).
# Without one it is signed ad hoc: the app runs, but macOS refuses it as a login item.
# (The identity was read above, before the Info.plist.)
# With widgets the extension is signed first, with its entitlements, and the app without --deep,
# which would sign the extension again and drop them.
# Sparkle's helpers and its framework are signed first (inside out) with the app's identity.
sign_sparkle() {
  local id="$1"; shift
  for p in "$FW/Versions/B/Autoupdate" "$FW/Versions/B/Updater.app" "$FW"; do codesign --force "$@" -s "$id" "$p"; done
}
# The script and every file it sources, the same way in both branches (the widgets branch, which
# release.sh takes, once signed only deploys; the other one left lib/ out).
sign_resources() {  # sign_resources <identity> [codesign options...]
  local id="$1" f; shift
  for f in "$BUILD/Contents/Resources/deploys" "$BUILD/Contents/Resources/providers/"*.sh "$BUILD/Contents/Resources/lib/"*.sh; do
    [ -f "$f" ] || continue
    codesign --force "$@" -s "$id" "$f"
  done
}
if [ "$widgets" = 1 ]; then
  sid="${DEVELOPER_ID:--}"
  rt=(); [ -n "${DEVELOPER_ID:-}" ] && rt=(--options runtime --timestamp)
  sign_sparkle "$sid" ${rt[@]+"${rt[@]}"}
  sign_resources "$sid" ${rt[@]+"${rt[@]}"}
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
  sign_sparkle "$DEVELOPER_ID" --options runtime --timestamp
  sign_resources "$DEVELOPER_ID" --options runtime --timestamp
  ent=(); [ -n "$LINK_ENT" ] && ent=(--entitlements build/app.entitlements)
  codesign --force --options runtime --timestamp ${ent[@]+"${ent[@]}"} -s "$DEVELOPER_ID" "$BUILD"
  codesign --verify --deep --strict "$BUILD"
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
  # Copied next to it first (ditto keeps attributes and signatures), then swapped: a copy that
  # breaks off leaves the old app in place, not none.
  rm -rf "$dest.new" "$dest.old"
  ditto "$BUILD" "$dest.new"
  [ ! -e "$dest" ] || mv "$dest" "$dest.old"
  mv "$dest.new" "$dest"
  rm -rf "$dest.old"
  echo "Installed: $dest"
  [ "$was_running" = 0 ] || open "$dest"
fi
