#!/bin/bash
# Bundles server.js and the MCP SDK into one file without node_modules: dist/server.js
# (CommonJS, Node 18+). The Mac app ships it with deploys-mcp in Contents/Resources/mcp/,
# and the Claude Desktop extension uses it as server/server.js.
#   integrations/mcp/build.sh            needs node and npm; runs npm ci when node_modules is missing
set -euo pipefail
cd "$(dirname "$0")"

command -v npm >/dev/null || { echo "mcp/build.sh: npm is missing; install Node (brew install node)" >&2; exit 1; }
[ -x node_modules/.bin/esbuild ] || npm ci --no-audit --no-fund >/dev/null

mkdir -p dist
node_modules/.bin/esbuild server.js --bundle --platform=node --target=node18 --format=cjs \
  --legal-comments=eof --log-level=warning --outfile=dist/server.js
# A self-check: the bundle must start on its own (no node_modules next to it) and answer.
dir="$(mktemp -d)"; trap 'rm -rf "$dir"' EXIT
cp dist/server.js "$dir/server.js"
printf '%s\n' '{"jsonrpc":"2.0","id":1,"method":"initialize","params":{"protocolVersion":"2025-06-18","capabilities":{},"clientInfo":{"name":"build","version":"0"}}}' \
  | DEPLOYS_MCP_LOGIN_PATH=0 node "$dir/server.js" 2>/dev/null | grep -q '"name":"deploys"' \
  || { echo "mcp/build.sh: the bundle does not start on its own" >&2; exit 1; }
echo "Built: integrations/mcp/dist/server.js"
