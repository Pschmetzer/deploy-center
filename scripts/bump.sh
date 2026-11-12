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
# Both version mentions on the home page must be found before anything changes: a replacement
# without a hit would leave the old version there silently, and a stop halfway would leave
# VERSION and CHANGELOG.md bumped.
if [ -f site/index.html ]; then
  for pat in "Version $cur ·" "\"softwareVersion\": \"$cur\""; do
    grep -qF "$pat" site/index.html || die "site/index.html has no '$pat'; set the version there by hand"
  done
fi

tmp="$(mktemp)"
awk -v v="$new" '!done && /^## Unreleased/ { print; print ""; print "## " v; done=1; next } { print }' CHANGELOG.md > "$tmp"
mv "$tmp" CHANGELOG.md
echo "$new" > VERSION
# The site's home page names the version twice (the line under the download button and the JSON-LD).
if [ -f site/index.html ]; then
  sed -i.bak -e "s/Version $cur ·/Version $new ·/" -e "s/\"softwareVersion\": \"$cur\"/\"softwareVersion\": \"$new\"/" site/index.html
  rm -f site/index.html.bak
fi
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
if [ -f integrations/mcp/server.mjs ]; then
  grep -q '^const VERSION = "[0-9.]*";' integrations/mcp/server.mjs || die "integrations/mcp/server.mjs has no VERSION line"
  sed -i.bak -e "s/^const VERSION = \"[0-9.]*\";/const VERSION = \"$new\";/" integrations/mcp/server.mjs && rm -f integrations/mcp/server.mjs.bak
fi
echo "VERSION $cur -> $new; CHANGELOG.md has \"## $new\" now, site/index.html, the MCP server and the Claude Code plugin too. Check: git diff"
