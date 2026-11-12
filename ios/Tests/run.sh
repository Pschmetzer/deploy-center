#!/bin/bash
# Tests for the iPhone app's pure logic (no simulator): compiles the tested files with the tests and runs them.
#   ios/Tests/run.sh
set -euo pipefail
cd "$(dirname "$0")/../.."
out="$(mktemp -d)"; trap 'rm -rf "$out"' EXIT
cp ios/Tests/mask-tests.swift "$out/main.swift"
swiftc -swift-version 5 -o "$out/tests" ios/App/LogMask.swift "$out/main.swift"
"$out/tests" ios/Tests/fixtures
