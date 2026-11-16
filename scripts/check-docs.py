#!/usr/bin/env python3
"""Checks that the docs agree with each other, without a network:
- every docs/*.md (not IDEEN*, not maintainer notes) is linked from docs/README.md, and linked once
- README.md and README.de.md have the same number of "##" sections and the same docs/ links
- no markdown file has two top-level "# " headings (a docs page becomes one <h1>)
    python3 -I scripts/check-docs.py [repo-dir]   exits 1 and lists the problems
"""
import glob
import os
import re
import sys

root = os.path.abspath(sys.argv[1] if len(sys.argv) > 1 else os.path.join(os.path.dirname(__file__), ".."))
problems = []


def read(rel):
    with open(os.path.join(root, rel), encoding="utf-8") as f:
        return f.read()


def strip_code(text):
    return re.sub(r"```.*?```", "", text, flags=re.S)


# 1. docs/README.md names every page once
index = read("docs/README.md")
linked = re.findall(r"\]\((?!https?:)(?:\./)?([A-Za-z0-9_.\-/]+\.md)[#)]", index)
# rows of the table: count each target once per table row
rows = [ln for ln in index.splitlines() if ln.startswith("| [")]
row_targets = {}
for ln in rows:
    first = re.search(r"\]\((?!https?:)(?:\./)?([A-Za-z0-9_.\-/]+\.md)", ln)
    if first:
        row_targets.setdefault(first.group(1), []).append(ln)
SKIP = {"README.md"}
for path in sorted(glob.glob(os.path.join(root, "docs", "*.md"))):
    name = os.path.basename(path)
    if name in SKIP or name.startswith("IDEEN") or name in ("APP-STORE.md",):
        continue
    if name not in linked:
        problems.append(f"docs/README.md: does not link docs/{name}")
for target, lns in row_targets.items():
    if len(lns) > 1 and not target.startswith("../"):
        problems.append(f"docs/README.md: {target} is in {len(lns)} table rows")

# 2. README.md and README.de.md
def sections(text):
    return len(re.findall(r"^## ", strip_code(text), flags=re.M))


def doclinks(text):
    return sorted(set(re.findall(r"\]\((docs/[A-Za-z0-9_.\-/]+?\.md)", text)))


en, de = read("README.md"), read("README.de.md")
if sections(en) != sections(de):
    problems.append(f'README.de.md has {sections(de)} "##" sections, README.md {sections(en)}')
# the German pages that stand in for an English one
ALIAS = {"docs/NUMBERS.md": "docs/ZAHLEN.md", "docs/SAVINGS.md": "docs/ERSPARNIS.md"}
de_links = set(doclinks(de))
missing = [d for d in doclinks(en) if d not in de_links and ALIAS.get(d) not in de_links]
if missing:
    problems.append("README.de.md does not link: " + ", ".join(missing))

# 3. one H1 per markdown page
for path in sorted(glob.glob(os.path.join(root, "docs", "*.md")) + glob.glob(os.path.join(root, "docs", "providers", "*.md"))):
    name = os.path.relpath(path, root)
    if os.path.basename(name).startswith("IDEEN"):
        continue
    h1 = re.findall(r"^# ", strip_code(open(path, encoding="utf-8").read()), flags=re.M)
    if len(h1) > 1:
        problems.append(f"{name}: {len(h1)} top-level headings (one expected)")

for line in problems:
    print(line)
print(f"check-docs: {len(problems)} problems")
sys.exit(1 if problems else 0)
