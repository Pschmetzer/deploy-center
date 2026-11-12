#!/usr/bin/env python3
"""Checks every L("English", "Deutsch") pair in the Swift sources:
- neither text is empty
- both interpolate the same values: \\(n) in one needs \\(n) in the other (string literals inside
  an interpolation, such as n == 1 ? "commit" : "commits", may differ: they are translated too)
- a text of more than three words is not the same in both languages (a German text left out)

    python3 -I scripts/check-strings.py [file.swift …]    default: app/ shared/ widgets/ ios/App/
Exits 1 and lists each problem. Standard library only.
"""
import glob
import os
import re
import sys

ROOT = os.path.normpath(os.path.join(os.path.dirname(os.path.abspath(__file__)), ".."))
# A one-line Swift string literal; an interpolation may hold parentheses and literals of its own.
LIT = r'"((?:[^"\\\n]|\\\((?:[^()"]|"(?:[^"\\]|\\.)*"|\((?:[^()"]|"(?:[^"\\]|\\.)*")*\))*\)|\\.)*)"'
PAIR = re.compile(r"\bL\(\s*" + LIT + r"\s*,\s*" + LIT + r"\s*\)")
INTERP = re.compile(r'\\\(((?:[^()"]|"(?:[^"\\]|\\.)*"|\((?:[^()"]|"(?:[^"\\]|\\.)*")*\))*)\)')


def values(text):
    """The interpolated expressions, with the string literals inside them blanked out."""
    return sorted(re.sub(r'"(?:[^"\\]|\\.)*"', '""', e).replace(" ", "") for e in INTERP.findall(text))


def check(path, problems):
    src = open(path, encoding="utf-8").read()
    rel = os.path.relpath(path, ROOT)
    count = 0
    for m in PAIR.finditer(src):
        count += 1
        en, de = m.group(1), m.group(2)
        line = src.count("\n", 0, m.start()) + 1
        if not en.strip() or not de.strip():
            problems.append(f"{rel}:{line}: an empty text in L(…)")
        elif values(en) != values(de):
            problems.append(f"{rel}:{line}: English and German interpolate different values: {values(en)} vs {values(de)}")
        elif en == de and len(en.split()) > 3:
            problems.append(f"{rel}:{line}: the German text is the English one: {en[:60]}")
    return count


files = sys.argv[1:] or sorted(sum((glob.glob(os.path.join(ROOT, d, "*.swift")) for d in ("app", "shared", "widgets", "ios/App")), []))
problems = []
pairs = sum(check(f, problems) for f in files)
for p in problems:
    print(p)
print(f"{pairs} L(en, de) pairs in {len(files)} files, {len(problems)} problems")
sys.exit(1 if problems else 0)
