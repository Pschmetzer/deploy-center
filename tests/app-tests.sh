#!/bin/bash
# Compiles the app's sources without App.swift (it holds @main) together with the tests, and runs them.
set -euo pipefail
cd "$(dirname "$0")/.."
out="$(mktemp -d)"; trap 'rm -rf "$out"' EXIT
cp tests/app-tests.swift "$out/main.swift"
srcs=()
for f in app/*.swift; do [ "$f" = app/App.swift ] || srcs+=("$f"); done
swiftc -swift-version 5 -o "$out/tests" "${srcs[@]}" "$out/main.swift"
"$out/tests"
