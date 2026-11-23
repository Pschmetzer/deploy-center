#!/usr/bin/env python3
"""Checks that docs/CLI.md and `deploys help` name the same commands. No network.

    python3 -I scripts/check-cli-docs.py [repo-dir]    exits 1 and lists the problems

- every command word in the "Commands:" block of `deploys help` appears as `deploys <word>` in docs/CLI.md
- every `deploys <word>` in a code span of docs/CLI.md is a command of the help, a provider, or a known alias
- every DEPLOYS_* variable the scripts read is named in some docs page
- the table of docs/providers/README.md has one row per provider with the caps `deploys providers --json` reports
Provider verbs (`deploys vercel list`) are not checked here; tests/contract-json.sh covers them.
"""
import os
import re
import subprocess
import sys

root = os.path.abspath(sys.argv[1] if len(sys.argv) > 1 else os.path.join(os.path.dirname(__file__), ".."))
problems = []

help_text = subprocess.run(["bash", os.path.join(root, "deploys"), "help"], capture_output=True, text=True,
                           env={**os.environ, "DEPLOYS_CONFIG": "/nonexistent"}).stdout
block = help_text.split("Commands:", 1)[-1].split("Exit codes:", 1)[0]
help_cmds = set(re.findall(r"^  deploys ([a-z][a-z0-9-]*)", block, flags=re.M))
help_cmds -= {"p"}
providers = {os.path.basename(f)[:-3] for f in os.listdir(os.path.join(root, "providers")) if f.endswith(".sh")}

if len(help_cmds) < 20:
    problems.append(f"could not read the command list of `deploys help` ({len(help_cmds)} found)")

for rel in ("docs/CLI.md",):
    text = open(os.path.join(root, rel), encoding="utf-8").read()
    mentioned = set(re.findall(r"deploys ([a-z][a-z0-9-]*)", text))
    coded = set(re.findall(r"(?:`|^|\$\(|[|&;] ?)deploys ([a-z][a-z0-9-]*)", text, flags=re.M))
    for c in sorted(help_cmds - mentioned):
        problems.append(f"{rel}: the help lists `deploys {c}`, the page never names it")
    if rel == "docs/CLI.md":
        for c in sorted(coded - help_cmds - providers - {"help", "exit-codes", "completion", "deploys"}):
            problems.append(f"{rel}: names `deploys {c}`, which is not a command in `deploys help`")

# docs/providers/README.md lists the caps each provider reports (`deploys providers --json`)
try:
    import json
    meta = json.loads(subprocess.run(["bash", os.path.join(root, "deploys"), "providers", "--json"], capture_output=True,
                                     text=True, env={**os.environ, "DEPLOYS_CONFIG": "/nonexistent"}).stdout)
    caps = {m["id"]: m["caps"] for m in meta}
except Exception as e:  # noqa: BLE001
    caps = {}
    problems.append(f"could not read `deploys providers --json`: {e}")
cols = ["off", "sha", "cancel", "rollback", "logs", "preview"]
table = open(os.path.join(root, "docs", "providers", "README.md"), encoding="utf-8").read()
seen = set()
for line in table.splitlines():
    m = re.match(r"\| \[[^\]]+\]\(([a-z0-9-]+)\.md\) \|(.*)\|\s*$", line)
    if not m or m.group(1) not in caps:
        continue
    pid = m.group(1)
    seen.add(pid)
    cells = [c.strip() for c in m.group(2).split("|")]
    if len(cells) != len(cols):
        problems.append(f"docs/providers/README.md: the row of {pid} has {len(cells)} cells, {len(cols)} expected")
        continue
    for col, cell in zip(cols, cells):
        want = "yes" if caps[pid].get(col) else "no"
        if cell != want:
            problems.append(f"docs/providers/README.md: {pid} / {col} says {cell}, `deploys providers --json` says {want}")
for pid in sorted(set(caps) - seen):
    problems.append(f"docs/providers/README.md: no row for the provider {pid}")

# every DEPLOYS_* variable the scripts read is in some docs page, except the ones that only pass a value between our own calls
INTERNAL = {"DEPLOYS_FORCE_REASON", "DEPLOYS_ONLY", "DEPLOYS_ONLY_ID", "DEPLOYS_SAVINGS_LIB", "DEPLOYS_SELF", "DEPLOYS_TEAM_LIB",
            "DEPLOYS_LIB", "DEPLOYS_NO_JOURNAL", "DEPLOYS_CALLER"}
def _read_all(paths):
    out = ""
    for pth in paths:
        with open(pth, encoding="utf-8") as fh:
            out += fh.read()
    return out
_scripts = [os.path.join(root, "deploys")] + [os.path.join(root, d, f) for d in ("lib", "providers")
                                                   for f in sorted(os.listdir(os.path.join(root, d))) if f.endswith(".sh")]
_docs = [os.path.join(root, f) for f in ("README.md", "README-CLI.md")]
for _d in ("docs", os.path.join("docs", "providers")):
    _docs += [os.path.join(root, _d, f) for f in sorted(os.listdir(os.path.join(root, _d)))
              if f.endswith(".md") and not f.startswith("IDEEN")]
_doc_text = _read_all(_docs)
for _v in sorted(set(re.findall(r"\b(DEPLOYS_[A-Z0-9_]+)\b", _read_all(_scripts))) - INTERNAL):
    if not re.search(r"\b" + _v + r"\b", _doc_text):
        problems.append(f"{_v} is read by the scripts and named in no docs page (add it to docs/CLI.md, or to INTERNAL in scripts/check-cli-docs.py)")

for line in problems:
    print(line)
print(f"check-cli-docs: {len(problems)} problems")
sys.exit(1 if problems else 0)
