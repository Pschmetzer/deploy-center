#!/bin/bash
# Tests for the iPhone app's pure logic (no simulator): compiles the tested files with the tests and runs them.
# First checks that fixtures/mask-out.txt is what the CLI's af_mask makes of fixtures/mask-in.txt today,
# so the Swift masking is held against the script's, not against an old copy of it. mask-in.txt is the
# shared secret fixture: the MCP server and the VS Code and Raycast add-ons are checked against it too.
#   ios/Tests/run.sh
set -euo pipefail
cd "$(dirname "$0")/../.."
out="$(mktemp -d)"; trap 'rm -rf "$out"' EXIT
DEPLOYS_LIB=1 bash -c '. ./deploys; af_mask' < ios/Tests/fixtures/mask-in.txt > "$out/af-mask.txt"
if ! diff -u ios/Tests/fixtures/mask-out.txt "$out/af-mask.txt"; then
  echo "FAIL mask-out.txt is not af_mask's output for mask-in.txt (above: - fixture, + af_mask now)"; exit 1
fi
echo "ok   mask-out.txt is af_mask's output for mask-in.txt"
cp ios/Tests/mask-tests.swift "$out/main.swift"
swiftc -swift-version 5 -o "$out/tests" ios/App/LogMask.swift "$out/main.swift"
"$out/tests" ios/Tests/fixtures
