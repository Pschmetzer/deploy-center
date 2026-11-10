#!/bin/bash
# Compiles the app's sources without App.swift (it holds @main) and SoftwareUpdate.swift (it needs
# Sparkle.framework) together with the tests, and runs them.
set -euo pipefail
cd "$(dirname "$0")/.."
out="$(mktemp -d)"; trap 'rm -rf "$out"' EXIT
cp tests/app-tests.swift "$out/main.swift"
srcs=()
for f in app/*.swift shared/*.swift; do
  case "$f" in app/App.swift|app/SoftwareUpdate.swift) ;; *) srcs+=("$f") ;; esac
done
swiftc -swift-version 5 -o "$out/tests" "${srcs[@]}" "$out/main.swift"
"$out/tests"
