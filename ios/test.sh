#!/bin/bash
# Checks the iOS app's code without UIKit (the rule, the API clients, the snapshot) on this Mac:
# compiles ios/App/Project.swift, ios/App/Clients.swift, ios/App/LogMask.swift and shared/ with ios/Tests/main.swift for macOS
# and runs it. Answers come from made-up JSON (ios/Tests), never the network. Needs swiftc.
set -euo pipefail
cd "$(dirname "$0")/.."
out="$(mktemp -d)"
trap 'rm -rf "$out"' EXIT
swiftc -swift-version 5 -target "$(uname -m)-apple-macosx14.0" -o "$out/ios-tests" \
  ios/App/Project.swift ios/App/Clients.swift ios/App/LogMask.swift shared/*.swift ios/Tests/main.swift
"$out/ios-tests"
