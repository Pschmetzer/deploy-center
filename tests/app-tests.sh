#!/bin/bash
# Compiles the app's sources without App.swift (it holds @main) and SoftwareUpdate.swift (it needs
# Sparkle.framework) together with the tests, and runs them twice: in English and in German, the
# two languages the app shows (L(en, de) follows AppleLanguages, not the Mac it runs on).
set -euo pipefail
cd "$(dirname "$0")/.."
out="$(mktemp -d)"; trap 'rm -rf "$out"' EXIT
cp tests/app-tests.swift "$out/main.swift"
srcs=()
for f in app/*.swift shared/*.swift; do
  case "$f" in app/App.swift|app/SoftwareUpdate.swift) ;; *) srcs+=("$f") ;; esac
done
swiftc -swift-version 5 -o "$out/tests" "${srcs[@]}" "$out/main.swift"
# What deploys really answers, for the contract tests (decoded with the app's models).
bash tests/contract-json.sh "$out/contract"
export DC_CONTRACT="$out/contract"
for lang in en de; do
  echo "--- app tests ($lang)"
  "$out/tests" -AppleLanguages "($lang)"
done
