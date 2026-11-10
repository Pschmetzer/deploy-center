#!/bin/bash
# Builds a release: signed, notarized, stapled, zipped, with its SHA-256.
#   ./release.sh                 build and notarize; the zip ends up in dist/
#   ./release.sh --publish       also create the GitHub release vVERSION (app zip, CLI tarball,
#                                checksums.txt), sign the zip for Sparkle into site/appcast.xml,
#                                and write the Homebrew cask and formula
#   ./release.sh --publish-only  publish the zip already in dist/ (after a failed upload; no new build)
#   ./release.sh --check-addons  only check that every add-on changed since the last release has a new version
#   ./release.sh ... --dry-run   run the checks, then only print what would be built, tagged and uploaded
#
# Needs a "Developer ID Application" certificate and a notarytool profile. Give them as
# DEVELOPER_ID and NOTARY_PROFILE, or put them in .release.env (not tracked):
#   DEVELOPER_ID="Developer ID Application: Your Name (TEAMID)"
#   NOTARY_PROFILE=deploy-center
# The Sparkle signing key (EdDSA) lives in the login keychain; scripts/sparkle.sh fetches the tools.
#   SPARKLE_ACCOUNT=<keychain account of the key> (default: deploy-center; create once with
#   "$(scripts/sparkle.sh)/bin/generate_keys --account deploy-center").
# Optional: RELEASE_REPO=owner/name (default: the repo of the remote "origin"),
#           TAP_DIR=<a local clone of the Homebrew tap> (default: a fresh clone in dist/).
#
# Apple's answer can take an hour the first time. If the network drops while waiting, the
# submission keeps going at Apple; this script waits for the same submission again instead
# of giving up (build.sh's own --wait cannot). The notarized zip lives in dist/, which
# build.sh never touches, so a later ./build.sh cannot replace it with an unnotarized one.
set -euo pipefail
cd "$(dirname "$0")"

usage() { sed -n '2,9p' "$0" | sed 's/^# \{0,1\}//'; }
die() { echo "release.sh: $*" >&2; exit 1; }

mode=build; dry=""
for arg in "$@"; do
  case "$arg" in
    --dry-run) dry=1 ;;
    --publish|--publish-only)
      [ "$mode" = build ] || die "use only one of --publish and --publish-only"
      mode="${arg#--}" ;;
    --check-addons) mode="check-addons" ;;
    -h|--help) usage; exit 0 ;;
    *) usage >&2; echo >&2; echo "release.sh: unknown argument: $arg" >&2; exit 2 ;;
  esac
done

# Add-ons update by their own version (Claude Code reads plugin.json, VS Code and npm package.json):
# one that changed since the last release tag but kept its version never reaches anyone.
# Which number comes next stays the maintainer's call; this only refuses to forget it.
ADDON_VERSION_FILES="integrations/claude-code/.claude-plugin/plugin.json integrations/mcp/package.json integrations/vscode/package.json"
check_addons() {  # check_addons <commit>
  local base f dir old new bad=""
  base="$(git describe --tags --abbrev=0 --match 'v[0-9]*' "$1^" 2>/dev/null)" || { echo "release.sh: no earlier release tag; add-on versions not compared"; return 0; }
  for f in $ADDON_VERSION_FILES; do
    git cat-file -e "$1:$f" 2>/dev/null || continue
    dir="${f%/package.json}"; dir="${dir%/.claude-plugin/plugin.json}"
    [ -n "$(git diff --name-only "$base" "$1" -- "$dir" 2>/dev/null)" ] || continue
    new="$(git show "$1:$f" | jq -r '.version // empty')"
    old="$(git show "$base:$f" 2>/dev/null | jq -r '.version // empty' 2>/dev/null || true)"
    [ "$new" != "$old" ] || bad="$bad $dir ($new)"
  done
  [ -z "$bad" ] || die "changed since $base but still the same version:$bad. Raise their version first"
  echo "Add-on versions: fine (compared with $base)."
}
if [ "$mode" = "check-addons" ]; then check_addons HEAD; exit 0; fi

[ -f .release.env ] && . ./.release.env
# A release always trusts the built-in key and feed: the two overrides are for local update tests
# only. Set in a shell (or in .release.env), they would ship an app whose updates break or go elsewhere.
for v in SPARKLE_PUBLIC_KEY SPARKLE_FEED_URL; do
  [ -z "${!v:-}" ] || echo "release.sh: ignoring $v (only for local update tests)" >&2
  unset "$v"
done
if [ "$mode" != publish-only ] && [ -z "$dry" ]; then
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

# The Sparkle key and feed the app is built with: the defaults in build.sh.
want_key="$(sed -n 's/^PUBLIC_ED_KEY="\${SPARKLE_PUBLIC_KEY:-\(.*\)}"$/\1/p' build.sh)"
want_feed="$(sed -n 's/^FEED_URL="\${SPARKLE_FEED_URL:-\(.*\)}"$/\1/p' build.sh)"
[ -n "$want_key" ] && [ -n "$want_feed" ] || die "could not read the Sparkle key and feed from build.sh"

# --- checks before anything slow ---------------------------------------------------------
if publishing; then
  command -v gh >/dev/null || die "gh is missing (brew install gh)"
  REPO="${RELEASE_REPO:-$(gh repo view "$(git remote get-url origin)" --json nameWithOwner -q .nameWithOwner)}"
  [ -n "$REPO" ] || die "could not tell the GitHub repo; set RELEASE_REPO=owner/name"
  grep -q '^- ' <<<"$(notes_of)" \
    || die "CHANGELOG.md has no entries under \"## $VERSION\"; rename Unreleased first (scripts/bump.sh)"
  # The key in the keychain must be the one the app trusts, or no installed copy accepts the update.
  # A dry run downloads nothing: it checks the key only when the Sparkle tools are here already.
  SPARKLE_ACCOUNT="${SPARKLE_ACCOUNT:-deploy-center}"; key_note="matches build.sh"
  if [ -n "$dry" ]; then SPARKLE="$(ls -d vendor/Sparkle-*/ 2>/dev/null | tail -n 1 || true)"; SPARKLE="${SPARKLE%/}"
  else SPARKLE="$(scripts/sparkle.sh)"; fi
  if [ -n "$SPARKLE" ] && [ -x "$SPARKLE/bin/generate_keys" ]; then
    have="$("$SPARKLE/bin/generate_keys" --account "$SPARKLE_ACCOUNT" -p 2>/dev/null)" \
      || die "no Sparkle key \"$SPARKLE_ACCOUNT\" in the keychain (see the top of this file)"
    [ "$have" = "$want_key" ] || die "the Sparkle key in the keychain ($have) is not the one in build.sh ($want_key)"
  else key_note="not checked (the Sparkle tools are not fetched in a dry run)"; fi
  command -v python3 >/dev/null || die "python3 is missing (xcode-select --install)"
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
  # The CLI tarball is packed from this commit after the slow part; fail now if it cannot be.
  git cat-file -e "$COMMIT:README-CLI.md" 2>/dev/null || die "$COMMIT has no README-CLI.md, which the CLI tarball needs"
  check_addons "$COMMIT"
fi

# --dry-run: the checks above passed (they only read); this is what a real run would do next.
if [ -n "$dry" ]; then
  if [ "$mode" = build ] || [ "$mode" = publish ]; then built="built from $COMMIT"; else built="the one in $ZIP"; fi
  echo "Dry run: nothing was built, notarized, tagged, uploaded or written."
  echo "  version     $VERSION (tag $TAG)"
  echo "  commit      $COMMIT"
  if publishing; then
    echo "  repo        $REPO"
    if [ -n "${tag_sha:-}" ]; then echo "  release     $TAG exists on this commit: resumed (assets replaced, notes updated)"
    else echo "  release     $TAG is new: created at $COMMIT"; fi
    echo "  Sparkle key ${key_note:-}"
  fi
  [ "$mode" != publish ] || echo "would run   scripts/check-public.sh and the four test suites"
  if [ "$mode" != publish-only ]; then
    echo "would build ./build.sh --widgets, signed as ${DEVELOPER_ID:-<DEVELOPER_ID is not set>}"
    echo "would send  build/notarize.zip to Apple (profile ${NOTARY_PROFILE:-<NOTARY_PROFILE is not set>}), staple, zip to $ZIP"
  fi
  if publishing; then
    echo "would pack  the CLI tarball and checksums.txt from $COMMIT"
    echo "would upload $ZIP ($built), the CLI tarball and checksums.txt to the GitHub release $TAG"
    echo "would sign  the zip for Sparkle and add $VERSION to site/appcast.xml"
    echo "would write the Homebrew cask and formula in ${TAP_DIR:-a fresh clone in $DIST} (nothing pushed)"
  fi
  exit 0
fi

# Before a release goes out: the tests, and the guard against personal data in the public repo
# (CI runs both too, but a release can be built from a commit CI never saw).
if [ "$mode" = publish ]; then
  scripts/check-public.sh || die "scripts/check-public.sh found personal data; nothing was built"
  for t in tests/script-tests.sh tests/team-tests.sh tests/savings-tests.sh tests/install-tests.sh; do
    bash "$t" >/dev/null 2>&1 || die "$t fails; run it to see why. Nothing was built"
  done
fi

# --- build and notarize ------------------------------------------------------------------
if [ "$mode" != publish-only ]; then
  # The MCP server for Settings > Claude ships inside the app; build.sh copies it only with its packages.
  command -v npm >/dev/null || die "npm is missing (needed for the MCP server in the app): brew install node"
  (cd integrations/mcp && npm ci --omit=dev --no-audit --no-fund)
  # Signed by build.sh; notarized here, so the wait can be resumed.
  # The widgets ship with every release (App Group <TEAMID>.app.deploycenter, no profile needed on macOS).
  DEVELOPER_ID="$DEVELOPER_ID" NOTARY_PROFILE="" ./build.sh --widgets
  # What the built app trusts for updates must be the built-in key and feed (see above).
  plist="$APP/Contents/Info.plist"
  [ "$(/usr/libexec/PlistBuddy -c 'Print :SUPublicEDKey' "$plist" 2>/dev/null)" = "$want_key" ] \
    || die "the built app does not carry the Sparkle key from build.sh ($want_key)"
  [ "$(/usr/libexec/PlistBuddy -c 'Print :SUFeedURL' "$plist" 2>/dev/null)" = "$want_feed" ] \
    || die "the built app does not carry the update feed from build.sh ($want_feed)"

  (cd build && ditto -c -k --keepParent "Deploy Center.app" notarize.zip)
  id="$(xcrun notarytool submit build/notarize.zip --keychain-profile "$NOTARY_PROFILE" --output-format json | jq -r .id)" \
    || die "submitting to Apple failed (xcrun notarytool history --keychain-profile $NOTARY_PROFILE shows what arrived)"
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
  status="$(xcrun notarytool info "$id" --keychain-profile "$NOTARY_PROFILE" --output-format json | jq -r .status)" \
    || die "could not ask Apple about submission $id. Look again later: xcrun notarytool info $id --keychain-profile $NOTARY_PROFILE"
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

# --- the CLI on its own: tarball and checksums.txt, from the same commit as the app --------
CLI="$DIST/deploys-cli-${VERSION}.tar.gz"
scripts/package-cli.sh --ref "$COMMIT" --out "$DIST" "$ZIP"
CLI_SHA="$(shasum -a 256 "$CLI" | cut -d' ' -f1)"
ASSETS=("$ZIP" "$ZIP.sha256" "$CLI" "$DIST/checksums.txt")

# --- publish -----------------------------------------------------------------------------
notes="$(mktemp)"
{ notes_of
  printf '\nNotarized by Apple: opens without a warning.\n\nSHA-256 of the zip: `%s`\n' "$SHA"
  printf '\nThe CLI on its own (macOS, Linux, CI): `curl -fsSL https://deploycenter.app/install.sh | sh` or `brew install pschmetzer/tap/deploys`. SHA-256 of %s: `%s`\n' "$(basename "$CLI")" "$CLI_SHA"; } > "$notes"
if gh release view "$TAG" --repo "$REPO" >/dev/null 2>&1; then
  echo "Release $TAG exists; replacing its files."
  gh release upload "$TAG" "${ASSETS[@]}" --repo "$REPO" --clobber
  # The notes too: a resumed release must not keep those of the failed attempt.
  gh release edit "$TAG" --repo "$REPO" --notes-file "$notes" >/dev/null
else
  gh release create "$TAG" "${ASSETS[@]}" --repo "$REPO" --target "$COMMIT" \
    --title "Deploy Center $VERSION" --notes-file "$notes"
fi
rm -f "$notes"

# The file people download must be the one that was notarized.
url="https://github.com/$REPO/releases/download/$TAG/$(basename "$ZIP")"
got="$(curl -fsSL --retry 3 "$url" | shasum -a 256 | cut -d' ' -f1)"
[ "$got" = "$SHA" ] || die "the published zip has SHA-256 $got, expected $SHA ($url)"
url="https://github.com/$REPO/releases/download/$TAG/$(basename "$CLI")"
got="$(curl -fsSL --retry 3 "$url" | shasum -a 256 | cut -d' ' -f1)"
[ "$got" = "$CLI_SHA" ] || die "the published CLI tarball has SHA-256 $got, expected $CLI_SHA ($url)"
echo "Published: https://github.com/$REPO/releases/tag/$TAG"

# --- Sparkle: sign the published zip, add it to the appcast (served by the website) --------
sig="$("$SPARKLE/bin/sign_update" --account "$SPARKLE_ACCOUNT" -p "$ZIP")" || die "sign_update failed"
"$SPARKLE/bin/sign_update" --account "$SPARKLE_ACCOUNT" --verify "$ZIP" "$sig" >/dev/null || die "the EdDSA signature does not verify"
notes="$(mktemp)"
notes_of > "$notes"
python3 -I scripts/appcast.py --appcast site/appcast.xml --version "$VERSION" \
  --url "https://github.com/$REPO/releases/download/$TAG/$(basename "$ZIP")" \
  --length "$(stat -f%z "$ZIP")" --signature "$sig" --notes "$notes" \
  --release-page "https://github.com/$REPO/releases/tag/$TAG"
rm -f "$notes"

# --- Homebrew: write the cask and the formula, print how to propose them (nothing is pushed)
TAP_REPO="${TAP_REPO:-${REPO%%/*}/homebrew-tap}"
tap="${TAP_DIR:-$DIST/homebrew-tap}"
if [ -z "${TAP_DIR:-}" ]; then
  rm -rf "$tap"
  gh repo clone "$TAP_REPO" "$tap" -- --quiet --depth 1
fi
scripts/homebrew-cask.sh --write "$tap" "$VERSION" "$SHA"
scripts/homebrew-formula.sh --write "$tap" "$VERSION" "$CLI_SHA"
branch="deploy-center-$VERSION"
cat <<NEXT

Appcast updated: site/appcast.xml. Installed copies see the update once it is on main
(the Website workflow publishes site/ to https://deploycenter.app/appcast.xml):
  git switch -c appcast-$VERSION
  git commit -m "appcast: $VERSION" site/appcast.xml
  git push -u origin appcast-$VERSION
  gh pr create --fill

Written: $tap/Casks/deploy-center.rb and $tap/Formula/deploys.rb. To propose them in $TAP_REPO
(review the diff first):
  cd "$tap"
  git add Casks/deploy-center.rb Formula/deploys.rb
  git diff --cached
  git switch -c $branch
  git commit -m "deploy-center $VERSION, deploys $VERSION"
  git push -u origin $branch
  gh pr create --repo $TAP_REPO --fill
NEXT
