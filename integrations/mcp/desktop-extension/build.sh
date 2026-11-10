#!/bin/bash
# Packs the Claude Desktop extension: build/deploys.mcpb (or the path given).
# Double-click the .mcpb, or drag it onto Claude Desktop's Settings > Extensions, to install it.
#   integrations/mcp/desktop-extension/build.sh [out.mcpb]     needs node and npm
set -euo pipefail
here="$(cd "$(dirname "$0")" && pwd)"
repo="$(cd "$here/../../.." && pwd)"
out="${1:-$repo/build/deploys.mcpb}"
case "$out" in /*) ;; *) out="$PWD/$out" ;; esac

"$here/../build.sh" >/dev/null

stage="$(mktemp -d)"; trap 'rm -rf "$stage"' EXIT
mkdir -p "$stage/server"
cp "$here/manifest.json" "$stage/manifest.json"
cp "$here/../dist/server.js" "$stage/server/server.js"
cp "$repo/site/img/icon-512.png" "$stage/icon.png"   # the app icon
cp "$repo/LICENSE" "$stage/LICENSE"

# The extension's version follows the server's.
v="$(node -p 'require(process.argv[1]).version' "$here/../package.json")"
node -e 'const f=process.argv[1],m=require(f);m.version=process.argv[2];require("fs").writeFileSync(f,JSON.stringify(m,null,2)+"\n")' "$stage/manifest.json" "$v"

mcpb="$here/../node_modules/.bin/mcpb"
"$mcpb" validate "$stage/manifest.json" >/dev/null
mkdir -p "$(dirname "$out")"; rm -f "$out"
"$mcpb" pack "$stage" "$out" >/dev/null
echo "Built: $out"
