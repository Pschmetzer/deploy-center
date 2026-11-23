#!/usr/bin/env python3
"""Checks that docs/CLI.md and `deploys help` name the same commands. No network.

    python3 -I scripts/check-cli-docs.py [repo-dir]    exits 1 and lists the problems

- every command word in the "Commands:" block of `deploys help` appears as `deploys <word>` in docs/CLI.md
- every `deploys <word>` in a code span of docs/CLI.md is a command of the help, a provider, or a known alias
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
    coded = set(re.findall(r"(?:`|^|\$\()deploys ([a-z][a-z0-9-]*)", text, flags=re.M))
    for c in sorted(help_cmds - mentioned):
        problems.append(f"{rel}: the help lists `deploys {c}`, the page never names it")
    if rel == "docs/CLI.md":
        for c in sorted(coded - help_cmds - providers - {"help", "exit-codes", "completion", "deploys"}):
            problems.append(f"{rel}: names `deploys {c}`, which is not a command in `deploys help`")

for line in problems:
    print(line)
print(f"check-cli-docs: {len(problems)} problems")
sys.exit(1 if problems else 0)
