#!/usr/bin/env python3
"""Exports every L("English", "Deutsch") pair of the Swift sources for translators, and finds
user-visible texts that are not in a pair.

    python3 -I scripts/export-strings.py                 TSV on stdout: file, line, English, Deutsch
    python3 -I scripts/export-strings.py --json          the same as a JSON list
    python3 -I scripts/export-strings.py --check         lists Text("…"), Button("…") and similar literals
                                                         that are not L(…) pairs (needs --strict to fail)
    python3 -I scripts/export-strings.py --check --strict   exit 1 when there are any
    … any of these with file.swift … to read those files instead of app/, shared/, widgets/ and ios/App/

The pair syntax is the one scripts/check-strings.py checks (it also checks the pairs themselves).
A check hit that is a symbol, a number, a path or a brand is not a missing pair: add it to
scripts/export-strings-ignore.txt (one literal per line) and it stays quiet. Standard library only.
"""
import glob
import signal
import json
import os
import re
import sys

ROOT = os.path.normpath(os.path.join(os.path.dirname(os.path.abspath(__file__)), ".."))
LIT = r'"((?:[^"\\\n]|\\\((?:[^()"]|"(?:[^"\\]|\\.)*"|\((?:[^()"]|"(?:[^"\\]|\\.)*")*\))*\)|\\.)*)"'
PAIR = re.compile(r"\bL\(\s*" + LIT + r"\s*,\s*" + LIT + r"\s*\)")
# Views that show their first argument as text; a literal there is a visible string.
VISIBLE = re.compile(r"\b(?:Text|Button|Label|Toggle|Section|TextField|SecureField|Picker|Menu|Link|DisclosureGroup|GroupBox|navigationTitle|help|alert|confirmationDialog)\(\s*" + LIT)
DIRS = ("app", "shared", "widgets", "ios/App")


FILES = []


def sources():
    if FILES:
        return FILES
    return sorted(sum((glob.glob(os.path.join(ROOT, d, "*.swift")) for d in DIRS), []))


def unescape(s):
    return s.replace('\\"', '"').replace("\\n", "\n").replace("\\t", "\t").replace("\\\\", "\\")


def pairs():
    out = []
    for path in sources():
        src = open(path, encoding="utf-8").read()
        for m in PAIR.finditer(src):
            out.append({"file": os.path.relpath(path, ROOT), "line": src.count("\n", 0, m.start()) + 1,
                        "en": unescape(m.group(1)), "de": unescape(m.group(2))})
    return out


def missing():
    ignore_path = os.path.join(ROOT, "scripts", "export-strings-ignore.txt")
    ignore = set()
    if os.path.exists(ignore_path):
        ignore = {l.rstrip("\n") for l in open(ignore_path, encoding="utf-8") if l.strip() and not l.startswith("#")}
    out = []
    for path in sources():
        src = open(path, encoding="utf-8").read()
        # The spans of the pairs: a literal inside L(…) is translated.
        spans = [(m.start(), m.end()) for m in PAIR.finditer(src)]
        for m in VISIBLE.finditer(src):
            if any(a <= m.start() < b for a, b in spans):
                continue
            text = m.group(1)
            # Needs a letter run of 3+ and no interpolation-only content; "·", "%", numbers and symbols are not texts.
            if not re.search(r"[A-Za-zÄÖÜäöüß]{3,}", re.sub(r"\\\([^)]*\)", "", text)) or text in ignore:
                continue
            out.append({"file": os.path.relpath(path, ROOT), "line": src.count("\n", 0, m.start()) + 1, "text": text})
    return out


def main(argv):
    FILES.extend(os.path.abspath(a) for a in argv if not a.startswith("-"))
    if any(a in ("-h", "--help") for a in argv):
        print(__doc__)
        return 0
    if "--check" in argv:
        found = missing()
        for f in found:
            print(f"{f['file']}:{f['line']}: not an L(English, Deutsch) pair: {f['text'][:70]}")
        print(f"{len(found)} visible literals without a pair")
        return 1 if found and "--strict" in argv else 0
    rows = pairs()
    if "--json" in argv:
        json.dump(rows, sys.stdout, ensure_ascii=False, indent=1)
        print()
    else:
        print("file\tline\tEnglish\tDeutsch")
        for r in rows:
            print("\t".join([r["file"], str(r["line"]), r["en"].replace("\t", " ").replace("\n", "\\n"), r["de"].replace("\t", " ").replace("\n", "\\n")]))
    return 0


signal.signal(signal.SIGPIPE, signal.SIG_DFL)
sys.exit(main(sys.argv[1:]))
