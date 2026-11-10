#!/usr/bin/env bash
# Starts a release: sets VERSION and turns "## Unreleased" in CHANGELOG.md into "## <version>",
# with a new empty "## Unreleased" above it. Commit the result, then run ./release.sh --publish.
#   scripts/bump.sh 0.8.0
#   scripts/bump.sh patch|minor|major
set -euo pipefail
cd "$(dirname "$0")/.."
die() { echo "bump.sh: $*" >&2; exit 1; }

[ $# -eq 1 ] || { sed -n '2,5p' "$0" | sed 's/^# \{0,1\}//' >&2; exit 2; }
cur="$(cat VERSION)"
[[ "$cur" =~ ^([0-9]+)\.([0-9]+)\.([0-9]+)$ ]] || die "VERSION is not x.y.z: $cur"
ma="${BASH_REMATCH[1]}" mi="${BASH_REMATCH[2]}" pa="${BASH_REMATCH[3]}"
case "$1" in
  patch) new="$ma.$mi.$((pa+1))" ;;
  minor) new="$ma.$((mi+1)).0" ;;
  major) new="$((ma+1)).0.0" ;;
  *) new="$1" ;;
esac
[[ "$new" =~ ^[0-9]+\.[0-9]+\.[0-9]+$ ]] || die "not a version: $new"
[ "$new" != "$cur" ] || die "VERSION is $cur already"
grep -q '^## Unreleased' CHANGELOG.md || die "CHANGELOG.md has no \"## Unreleased\""
grep -q "^## \[\{0,1\}$new\]\{0,1\}\( \|$\)" CHANGELOG.md && die "CHANGELOG.md has \"## $new\" already"
awk '/^## Unreleased/{f=1;next} /^## /{f=0} f&&/^- /{n++} END{exit n?0:1}' CHANGELOG.md \
  || die "nothing under \"## Unreleased\" to release"

tmp="$(mktemp)"
awk -v v="$new" '!done && /^## Unreleased/ { print; print ""; print "## " v; done=1; next } { print }' CHANGELOG.md > "$tmp"
mv "$tmp" CHANGELOG.md
echo "$new" > VERSION
# The site's home page names the version twice (the line under the download button and the JSON-LD).
if [ -f site/index.html ]; then
  sed -i.bak -e "s/Version $cur ·/Version $new ·/" -e "s/\"softwareVersion\": \"$cur\"/\"softwareVersion\": \"$new\"/" site/index.html
  rm -f site/index.html.bak
fi
echo "VERSION $cur -> $new; CHANGELOG.md has \"## $new\" now, site/index.html too. Check: git diff"
