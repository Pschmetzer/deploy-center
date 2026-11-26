#!/usr/bin/env python3
"""The Siri phrases of the iPhone app: every phrase in ios/App/Intents.swift is in AppShortcuts.xcstrings in English and
German, and contains ${applicationName} (iOS rejects a phrase without it)."""
import json, re, sys
from pathlib import Path

root = Path(__file__).resolve().parent.parent
swift = (root / "ios/App/Intents.swift").read_text(encoding="utf-8")
catalog = json.loads((root / "ios/App/AppShortcuts.xcstrings").read_text(encoding="utf-8"))["strings"]
problems = []

def key(s):
    s = s.replace("\\(.applicationName)", "${applicationName}")
    return re.sub(r"\\\(\\\.\$(\w+)\)", r"${\1}", s)

phrases = []
for m in re.finditer(r"phrases:\s*\[(.*?)\]", swift, re.S):
    phrases += [key(p) for p in re.findall(r'"((?:[^"\\]|\\.)*)"', m.group(1))]
if not phrases:
    problems.append("no phrases found in ios/App/Intents.swift")
for p in phrases:
    if "${applicationName}" not in p:
        problems.append(f"phrase without ${{applicationName}}: {p}")
    loc = catalog.get(p, {}).get("localizations", {})
    for lang in ("en", "de"):
        if not loc.get(lang, {}).get("stringUnit", {}).get("value"):
            problems.append(f"phrase missing in {lang}: {p}")
for k, v in catalog.items():
    for lang in ("en", "de"):
        val = v.get("localizations", {}).get(lang, {}).get("stringUnit", {}).get("value", "")
        if "${applicationName}" not in val:
            problems.append(f"{lang} text of '{k}' has no ${{applicationName}}")
    if k not in phrases:
        problems.append(f"catalog entry not used in Intents.swift: {k}")
for p in problems:
    print("FAIL", p)
print(f"{len(phrases)} Siri phrases checked, {len(problems)} problems")
sys.exit(1 if problems else 0)
