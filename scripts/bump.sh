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
grep -q "^## \[\{0,1\}${new//./\\.}\]\{0,1\}\( \|$\)" CHANGELOG.md && die "CHANGELOG.md has \"## $new\" already"
awk '/^## Unreleased/{f=1;next} /^## /{f=0} f&&/^- /{n++} END{exit n?0:1}' CHANGELOG.md \
  || die "nothing under \"## Unreleased\" to release"
# A minor or major release has many changes: the update window shows the whole section, so it should start with
# "### Highlights" (three to five bullets, see CONTRIBUTING.md). Only a warning: a patch release needs none.
case "$new" in
  *.0)
    awk '/^## Unreleased/{f=1;next} /^## /{f=0} f&&/^### Highlights/{n++} END{exit n?0:1}' CHANGELOG.md \
      || echo "bump.sh: warning: \"## Unreleased\" has no \"### Highlights\"; a minor release should start with three to five bullets for the update window" >&2 ;;
esac
# Both version mentions on the home page must be found before anything changes: a replacement
# without a hit would leave the old version there silently, and a stop halfway would leave
# VERSION and CHANGELOG.md bumped.
if [ -f site/index.html ]; then
  for pat in "Version $cur ·" "\"softwareVersion\": \"$cur\""; do
    grep -qF "$pat" site/index.html || die "site/index.html has no '$pat'; set the version there by hand"
  done
fi
# The same for the version files of the integrations: a stop halfway must not leave a half bump.
for jf in integrations/mcp/package.json integrations/claude-code/.claude-plugin/plugin.json; do
  [ ! -f "$jf" ] || grep -q '"version": "[0-9.]*"' "$jf" || die "$jf has no \"version\""
done
cur_re="${cur//./\\.}"   # the dots of the old version are no wildcards in sed

tmp="$(mktemp)"
# The heading carries the date ("## 0.12.0 - 2027-01-05"); release.sh and the Sparkle notes accept it.
awk -v v="$new" -v d="$(date +%Y-%m-%d)" '!done && /^## Unreleased/ { print; print ""; print "## " v " - " d; done=1; next } { print }' CHANGELOG.md > "$tmp"
mv "$tmp" CHANGELOG.md
echo "$new" > VERSION
# The site's home page names the version three times (the line under the download button, softwareVersion and downloadUrl in the JSON-LD; fileSize follows after ./release.sh --publish).
if [ -f site/index.html ]; then
  sed -i.bak -e "s/Version $cur_re ·/Version $new ·/" -e "s/\"softwareVersion\": \"$cur_re\"/\"softwareVersion\": \"$new\"/" -e "s#/download/v$cur_re/DeployCenter-$cur_re-#/download/v$new/DeployCenter-$new-#" site/index.html
  rm -f site/index.html.bak
fi
# Workflow examples pin the action to a release tag; they must follow every release, or users copy an old one.
for ex in $(grep -rlE 'deploy-center/integrations/action@v[0-9]+\.[0-9]+\.[0-9]+' examples integrations/*/examples 2>/dev/null); do
  sed -i.bak -E "s#(deploy-center/integrations/action@v)[0-9]+\.[0-9]+\.[0-9]+#\1$new#" "$ex" && rm -f "$ex.bak"
done
# The MCP server and the Claude Code plugin ship inside the app, so they carry its version.
# (The VS Code and Raycast extensions are published on their own, with their own changelogs.)
set_json_version() {
  [ -f "$1" ] || return 0
  grep -q '"version": "[0-9.]*"' "$1" || die "$1 has no \"version\""
  sed -i.bak -e "1,/\"version\": \"[0-9.]*\"/s/\"version\": \"[0-9.]*\"/\"version\": \"$new\"/" "$1" && rm -f "$1.bak"
}
set_json_version integrations/mcp/package.json
set_json_version integrations/claude-code/.claude-plugin/plugin.json
if [ -f integrations/mcp/package-lock.json ]; then
  # The lock names the package's own version twice (top and packages[""]); dependencies stay.
  jq --arg v "$new" '.version = $v | .packages[""].version = $v' integrations/mcp/package-lock.json > integrations/mcp/package-lock.json.new \
    && mv integrations/mcp/package-lock.json.new integrations/mcp/package-lock.json
fi
# server.mjs reads its version from package.json; nothing to set there.
echo "VERSION $cur -> $new; CHANGELOG.md has \"## $new\" now, site/index.html, the MCP server and the Claude Code plugin too. Check: git diff"
