#!/usr/bin/env python3
"""A file in ios/App that imports only Foundation holds logic ios/test.sh can run on a Mac: it must be in the list there,
so new pure code is not left untested."""
import re, sys
from pathlib import Path

root = Path(__file__).resolve().parent.parent
test_sh = (root / "ios/test.sh").read_text(encoding="utf-8")
ui = re.compile(r"^import (?!Foundation$)", re.M)
problems = []
files = sorted((root / "ios/App").glob("*.swift"))
for f in files:
    text = f.read_text(encoding="utf-8")
    if ui.search(text):
        continue
    if f"ios/App/{f.name}" not in test_sh:
        problems.append(f"ios/App/{f.name} imports only Foundation but is not compiled by ios/test.sh")
for p in problems:
    print("FAIL", p)
print(f"{len(files)} files in ios/App looked at, {len(problems)} problems")
sys.exit(1 if problems else 0)
