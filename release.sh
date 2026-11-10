#!/bin/bash
# Builds a release: signed, notarized, stapled, zipped, with its SHA-256.
#   ./release.sh                 build and notarize; the zip ends up in dist/
#   ./release.sh --publish       also create the GitHub release vVERSION and write the Homebrew cask
#   ./release.sh --publish-only  publish the zip already in dist/ (after a failed upload; no new build)
#
# Needs a "Developer ID Application" certificate and a notarytool profile. Give them as
# DEVELOPER_ID and NOTARY_PROFILE, or put them in .release.env (not tracked):
#   DEVELOPER_ID="Developer ID Application: Your Name (TEAMID)"
#   NOTARY_PROFILE=deploy-center
# Optional: RELEASE_REPO=owner/name (default: the repo of the remote "origin"),
#           TAP_DIR=<a local clone of the Homebrew tap> (default: a fresh clone in dist/).
#
# Apple's answer can take an hour the first time. If the network drops while waiting, the
# submission keeps going at Apple; this script waits for the same submission again instead
# of giving up (build.sh's own --wait cannot). The notarized zip lives in dist/, which
# build.sh never touches, so a later ./build.sh cannot replace it with an unnotarized one.
set -euo pipefail
cd "$(dirname "$0")"

usage() { sed -n '2,5p' "$0" | sed 's/^# \{0,1\}//'; }
die() { echo "release.sh: $*" >&2; exit 1; }

mode=build
for arg in "$@"; do
  case "$arg" in
    --publish|--publish-only)
      [ "$mode" = build ] || die "use only one of --publish and --publish-only"
      mode="${arg#--}" ;;
    -h|--help) usage; exit 0 ;;
    *) usage >&2; echo >&2; echo "release.sh: unknown argument: $arg" >&2; exit 2 ;;
  esac
done

[ -f .release.env ] && . ./.release.env
if [ "$mode" != publish-only ]; then
  : "${DEVELOPER_ID:?Set DEVELOPER_ID (see the top of this file)}"
  : "${NOTARY_PROFILE:?Set NOTARY_PROFILE (see the top of this file)}"
fi

VERSION="$(cat VERSION)"
APP="build/Deploy Center.app"
DIST="dist"
ZIP="$DIST/DeployCenter-${VERSION}-universal.zip"
MARK="$ZIP.release"   # what was built: commit and zip SHA-256, one "key value" per line
TAG="v$VERSION"

# The release notes: the "## VERSION" section of CHANGELOG.md. Accepts "## 0.7.0",
# "## [0.7.0]" and "## 0.7.0 - 2026-01-01".
notes_of() {
  awk -v v="$VERSION" '
    /^## / { h=$2; gsub(/[][]/, "", h); f=(h==v); next }
    f' CHANGELOG.md
}

publishing() { [ "$mode" != build ]; }

# --- checks before anything slow ---------------------------------------------------------
if publishing; then
  command -v gh >/dev/null || die "gh is missing (brew install gh)"
  REPO="${RELEASE_REPO:-$(gh repo view "$(git remote get-url origin)" --json nameWithOwner -q .nameWithOwner)}"
  [ -n "$REPO" ] || die "could not tell the GitHub repo; set RELEASE_REPO=owner/name"
  grep -q '^- ' <<<"$(notes_of)" \
    || die "CHANGELOG.md has no entries under \"## $VERSION\"; rename Unreleased first (scripts/bump.sh)"
fi
if [ "$mode" = build ]; then
  awk '/^## Unreleased/{f=1;next} /^## /{f=0} f&&/^- /{n++} END{exit n?0:1}' CHANGELOG.md \
    || grep -q '^- ' <<<"$(notes_of)" || die "CHANGELOG.md has nothing under Unreleased or $VERSION"
fi

if [ "$mode" = publish-only ]; then
  [ -f "$ZIP" ] && [ -f "$MARK" ] || die "no $ZIP with its $MARK; run ./release.sh first"
  SHA="$(shasum -a 256 "$ZIP" | cut -d' ' -f1)"
  [ "$SHA" = "$(awk '$1=="sha256"{print $2}' "$MARK")" ] || die "$ZIP changed since it was notarized"
  COMMIT="$(awk '$1=="commit"{print $2}' "$MARK")"
  [ -n "$COMMIT" ] || die "$MARK names no commit"
  check="$(mktemp -d)"; trap 'rm -rf "$check"' EXIT
  ditto -x -k "$ZIP" "$check"
  xcrun stapler validate "$check/Deploy Center.app" >/dev/null || die "$ZIP holds an app without a notarization ticket"
else
  if publishing; then
    [ -z "$(git status --porcelain --untracked-files=no)" ] || die "the working tree has uncommitted changes"
    [ "$(git symbolic-ref --short -q HEAD)" = main ] || die "releases are built from main"
  fi
  COMMIT="$(git rev-parse HEAD)"
fi

if publishing; then
  # The commit must be on GitHub's main (no remote names involved: two remotes broke this once).
  cmp="$(gh api "repos/$REPO/compare/main...$COMMIT" -q .status 2>/dev/null)" || die "$COMMIT is not on GitHub ($REPO); push first"
  case "$cmp" in identical|behind) ;; *) die "$COMMIT is not on $REPO main ($cmp); push it first" ;; esac
  # An existing tag must point at this commit; then the release is resumed, not refused.
  # gh prints the error body on stdout when the tag is missing, so only a SHA counts.
  tag_sha="$(gh api "repos/$REPO/commits/$TAG" -q .sha 2>/dev/null || true)"
  [[ "$tag_sha" =~ ^[0-9a-f]{40}$ ]] || tag_sha=""
  [ -z "$tag_sha" ] || [ "$tag_sha" = "$COMMIT" ] || die "$TAG exists already on another commit ($tag_sha): raise VERSION"
fi

# --- build and notarize ------------------------------------------------------------------
if [ "$mode" != publish-only ]; then
  # Signed by build.sh; notarized here, so the wait can be resumed.
  DEVELOPER_ID="$DEVELOPER_ID" NOTARY_PROFILE="" ./build.sh

  (cd build && ditto -c -k --keepParent "Deploy Center.app" notarize.zip)
  id="$(xcrun notarytool submit build/notarize.zip --keychain-profile "$NOTARY_PROFILE" --output-format json | jq -r .id)"
  [ -n "$id" ] && [ "$id" != null ] || die "submitting to Apple failed"
  echo "Submitted to Apple: $id"

  refused() {
    xcrun notarytool log "$id" --keychain-profile "$NOTARY_PROFILE" >&2 || true
    die "Apple refused the app ($1). The log is above."
  }
  for try in $(seq 1 30); do
    if xcrun notarytool wait "$id" --keychain-profile "$NOTARY_PROFILE" --timeout 30m >/dev/null 2>&1; then break; fi
    status="$(xcrun notarytool info "$id" --keychain-profile "$NOTARY_PROFILE" --output-format json 2>/dev/null | jq -r '.status // "unknown"')"
    case "$status" in
      Accepted) break ;;
      Invalid|Rejected) refused "$status" ;;
      *) echo "Still waiting for Apple ($status), try $try …"; sleep 60 ;;
    esac
  done

  # "wait" also ends without an error when Apple says Invalid, so look again.
  status="$(xcrun notarytool info "$id" --keychain-profile "$NOTARY_PROFILE" --output-format json | jq -r .status)"
  case "$status" in
    Accepted) ;;
    Invalid|Rejected) refused "$status" ;;
    *) die "not accepted yet ($status). Look again later: xcrun notarytool info $id" ;;
  esac

  xcrun stapler staple "$APP"
  xcrun stapler validate "$APP"
  spctl -a -vv "$APP"
  rm -f build/notarize.zip
  mkdir -p "$DIST"
  rm -f "$ZIP" "$ZIP.sha256" "$MARK"
  ditto -c -k --keepParent "$APP" "$ZIP"
  SHA="$(shasum -a 256 "$ZIP" | cut -d' ' -f1)"
  printf 'commit %s\nsha256 %s\n' "$COMMIT" "$SHA" > "$MARK"
fi
(cd "$DIST" && shasum -a 256 "$(basename "$ZIP")" > "$(basename "$ZIP").sha256")
echo "Ready: $ZIP"
echo "SHA-256: $SHA"
echo "Commit: $COMMIT"
publishing || exit 0

# --- publish -----------------------------------------------------------------------------
notes="$(mktemp)"
{ notes_of
  printf '\nNotarized by Apple: opens without a warning.\n\nSHA-256 of the zip: `%s`\n' "$SHA"; } > "$notes"
if gh release view "$TAG" --repo "$REPO" >/dev/null 2>&1; then
  echo "Release $TAG exists; replacing its files."
  gh release upload "$TAG" "$ZIP" "$ZIP.sha256" --repo "$REPO" --clobber
else
  gh release create "$TAG" "$ZIP" "$ZIP.sha256" --repo "$REPO" --target "$COMMIT" \
    --title "Deploy Center $VERSION" --notes-file "$notes"
fi
rm -f "$notes"

# The file people download must be the one that was notarized.
url="https://github.com/$REPO/releases/download/$TAG/$(basename "$ZIP")"
got="$(curl -fsSL --retry 3 "$url" | shasum -a 256 | cut -d' ' -f1)"
[ "$got" = "$SHA" ] || die "the published zip has SHA-256 $got, expected $SHA ($url)"
echo "Published: https://github.com/$REPO/releases/tag/$TAG"

# --- Homebrew: write the cask, print how to propose it (nothing is pushed) ---------------
TAP_REPO="${TAP_REPO:-${REPO%%/*}/homebrew-tap}"
tap="${TAP_DIR:-$DIST/homebrew-tap}"
if [ -z "${TAP_DIR:-}" ]; then
  rm -rf "$tap"
  gh repo clone "$TAP_REPO" "$tap" -- --quiet --depth 1
fi
scripts/homebrew-cask.sh --write "$tap" "$VERSION" "$SHA"
branch="deploy-center-$VERSION"
cat <<NEXT

Cask written: $tap/Casks/deploy-center.rb. To propose it in $TAP_REPO (review the diff first):
  cd "$tap"
  git diff
  git switch -c $branch
  git commit -am "deploy-center $VERSION"
  git push -u origin $branch
  gh pr create --repo $TAP_REPO --fill
NEXT
