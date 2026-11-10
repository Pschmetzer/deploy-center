#!/usr/bin/env bash
# Fetches Sparkle's prebuilt release into vendor/ (not tracked) and prints the folder.
# Pinned to one version and its SHA-256 (the digest GitHub lists for the release asset).
# The tarball is cached and checked again on every use; a mismatch is never used.
#   scripts/sparkle.sh            prints e.g. vendor/Sparkle-2.10.1 (has Sparkle.framework and bin/)
set -euo pipefail
cd "$(dirname "$0")/.."

SPARKLE_VERSION=2.10.1
SPARKLE_SHA256=1a856d2a9edb8e628de88121d7be04cf0e2167f8641650b78fca00b14244cf27
url="https://github.com/sparkle-project/Sparkle/releases/download/${SPARKLE_VERSION}/Sparkle-${SPARKLE_VERSION}.tar.xz"
tarball="vendor/Sparkle-${SPARKLE_VERSION}.tar.xz"
dir="vendor/Sparkle-${SPARKLE_VERSION}"
die() { echo "sparkle.sh: $*" >&2; exit 1; }
sha_of() { shasum -a 256 "$1" | cut -d' ' -f1; }

mkdir -p vendor
if [ ! -f "$tarball" ] || [ "$(sha_of "$tarball")" != "$SPARKLE_SHA256" ]; then
  rm -rf "$tarball" "$dir"
  echo "Downloading Sparkle $SPARKLE_VERSION …" >&2
  curl -fsSL --retry 3 -o "$tarball.part" "$url" || die "could not download $url"
  got="$(sha_of "$tarball.part")"
  [ "$got" = "$SPARKLE_SHA256" ] || { rm -f "$tarball.part"; die "Sparkle download has SHA-256 $got, expected $SPARKLE_SHA256"; }
  mv "$tarball.part" "$tarball"
fi
# Unpacked once per verified tarball; the stamp names the tarball it came from.
if [ "$(cat "$dir/.sha256" 2>/dev/null)" != "$SPARKLE_SHA256" ]; then
  rm -rf "$dir"; mkdir -p "$dir"
  tar -xJf "$tarball" -C "$dir"
  [ -d "$dir/Sparkle.framework" ] && [ -x "$dir/bin/sign_update" ] || die "unexpected Sparkle archive"
  echo "$SPARKLE_SHA256" > "$dir/.sha256"
fi
echo "$dir"
