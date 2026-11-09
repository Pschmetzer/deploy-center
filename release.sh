#!/bin/bash
# Builds a release: signed, notarized, stapled, zipped, with its SHA-256.
#   ./release.sh              build and notarize; the zip ends up in build/
#   ./release.sh --publish    also create the GitHub release vVERSION with the zip
#
# Needs a "Developer ID Application" certificate and a notarytool profile. Give them as
# DEVELOPER_ID and NOTARY_PROFILE, or put them in .release.env (not tracked):
#   DEVELOPER_ID="Developer ID Application: Your Name (TEAMID)"
#   NOTARY_PROFILE=deploy-center
#
# Apple's answer can take an hour the first time. If the network drops while waiting, the
# submission keeps going at Apple; this script waits for the same submission again instead
# of giving up (build.sh's own --wait cannot).
set -euo pipefail
cd "$(dirname "$0")"
[ -f .release.env ] && . ./.release.env
: "${DEVELOPER_ID:?Set DEVELOPER_ID (see the top of this file)}"
: "${NOTARY_PROFILE:?Set NOTARY_PROFILE (see the top of this file)}"

VERSION="$(cat VERSION)"
# A release without words in the changelog, or a version that is already tagged, is a mistake.
awk '/^## Unreleased/{f=1;next} /^## /{f=0} f&&/^- /{n++} END{exit n?0:1}' CHANGELOG.md \
  || grep -q "^## $VERSION" CHANGELOG.md || { echo "CHANGELOG.md has nothing under Unreleased or $VERSION" >&2; exit 1; }
! git rev-parse -q --verify "refs/tags/v$VERSION" >/dev/null || [ "${1:-}" != "--publish" ] \
  || { echo "Tag v$VERSION exists already: raise VERSION" >&2; exit 1; }
APP="build/Deploy Center.app"
ZIP="build/DeployCenter-${VERSION}-universal.zip"

# Signed by build.sh; notarized here, so the wait can be resumed.
DEVELOPER_ID="$DEVELOPER_ID" NOTARY_PROFILE="" ./build.sh

(cd build && ditto -c -k --keepParent "Deploy Center.app" notarize.zip)
id="$(xcrun notarytool submit build/notarize.zip --keychain-profile "$NOTARY_PROFILE" --output-format json | jq -r .id)"
[ -n "$id" ] && [ "$id" != null ] || { echo "Submitting to Apple failed" >&2; exit 1; }
echo "Submitted to Apple: $id"

for try in $(seq 1 30); do
  if xcrun notarytool wait "$id" --keychain-profile "$NOTARY_PROFILE" --timeout 30m >/dev/null 2>&1; then break; fi
  status="$(xcrun notarytool info "$id" --keychain-profile "$NOTARY_PROFILE" --output-format json 2>/dev/null | jq -r '.status // "unknown"')"
  case "$status" in
    Accepted) break ;;
    Invalid|Rejected)
      xcrun notarytool log "$id" --keychain-profile "$NOTARY_PROFILE" >&2 || true
      echo "Apple refused the app ($status). The log is above." >&2; exit 1 ;;
    *) echo "Still waiting for Apple ($status), try $try …"; sleep 60 ;;
  esac
done

status="$(xcrun notarytool info "$id" --keychain-profile "$NOTARY_PROFILE" --output-format json | jq -r .status)"
[ "$status" = Accepted ] || { echo "Not accepted yet ($status). Run again later: xcrun notarytool info $id" >&2; exit 1; }

xcrun stapler staple "$APP"
xcrun stapler validate "$APP"
spctl -a -vv "$APP"
rm -f build/notarize.zip "$ZIP"
(cd build && ditto -c -k --keepParent "Deploy Center.app" "$(basename "$ZIP")")
SHA="$(shasum -a 256 "$ZIP" | cut -d' ' -f1)"
echo "Ready: $ZIP"
echo "SHA-256: $SHA"

if [ "${1:-}" = "--publish" ]; then
  notes="$(mktemp)"
  { awk -v v="## $VERSION" '$0==v{f=1;next} /^## /{f=0} f' CHANGELOG.md 2>/dev/null
    printf '\nNotarized by Apple: opens without a warning.\n\nSHA-256 of the zip: `%s`\n' "$SHA"; } > "$notes"
  gh release create "v$VERSION" "$ZIP" --title "Deploy Center $VERSION" --notes-file "$notes"
  rm -f "$notes"
fi
