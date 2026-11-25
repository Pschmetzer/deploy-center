#!/usr/bin/env python3
"""Package.swift (the editor's view) and build.sh / scripts/sparkle.sh (the release build) must agree:
the same minimum macOS and the same pinned Sparkle. Usage: check-build.py [repo-root]. Stdlib only."""
import re
import sys
from pathlib import Path

root = Path(sys.argv[1]) if len(sys.argv) > 1 else Path(__file__).resolve().parent.parent


def read(rel):
    try:
        return (root / rel).read_text(encoding="utf-8")
    except OSError as e:
        print(f"check-build: cannot read {rel}: {e.strerror}", file=sys.stderr)
        sys.exit(2)


def find(rel, pattern, what):
    m = re.search(pattern, read(rel), re.M)
    if not m:
        print(f"check-build: {what} not found in {rel}", file=sys.stderr)
        sys.exit(2)
    return m.group(1)


pkg_os = find("Package.swift", r"\.macOS\(\.v(\d+)\)", "the macOS platform")
build_os = find("build.sh", r'^MIN_OS="(\d+)(?:\.\d+)*"', "MIN_OS").strip()
pkg_sparkle = find("Package.swift", r'sparkle-project/Sparkle"?,\s*exact:\s*"([\d.]+)"', "the Sparkle pin")
script_sparkle = find("scripts/sparkle.sh", r"^SPARKLE_VERSION=([\d.]+)", "SPARKLE_VERSION")

bad = []
if pkg_os != build_os:
    bad.append(f"minimum macOS: Package.swift says {pkg_os}, build.sh MIN_OS says {build_os}")
if pkg_sparkle != script_sparkle:
    bad.append(f"Sparkle: Package.swift pins {pkg_sparkle}, scripts/sparkle.sh pins {script_sparkle}")
for b in bad:
    print("check-build: " + b, file=sys.stderr)
if bad:
    sys.exit(1)
print(f"check-build: macOS {build_os}, Sparkle {script_sparkle}: Package.swift and the build agree")
