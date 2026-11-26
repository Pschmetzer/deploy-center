#!/usr/bin/env python3
"""Checks that the docs agree with each other, without a network:
- every docs/*.md (not IDEEN*, not maintainer notes) is linked from docs/README.md, and linked once
- README.md and README.de.md have the same number of "##" sections and the same docs/ links
- man/deploys.1 is what scripts/build-man.py writes from the help and docs/CLI.md
- every providers/<x>.sh is named on the home page, in llms.txt, SECURITY.md, the plugin listing, the skills and (keychain item) UNINSTALL.md
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
ALIAS = {"docs/NUMBERS.md": "docs/ZAHLEN.md", "docs/SAVINGS.md": "docs/ERSPARNIS.md",
         "docs/FAQ.md": "docs/FAQ.de.md", "docs/SAFE-START.md": "docs/SAFE-START.de.md",
         "docs/TROUBLESHOOTING.md": "docs/TROUBLESHOOTING.de.md", "docs/CLI.md": "docs/CLI.de.md",
         "docs/FIRST-START.md": "docs/FIRST-START.de.md", "docs/SETTINGS.md": "docs/SETTINGS.de.md",
         "docs/SEARCH.md": "docs/SEARCH.de.md", "docs/AUTO-DEPLOY.md": "docs/AUTO-DEPLOY.de.md", "docs/GUARD.md": "docs/GUARD.de.md",
         "docs/JOURNAL.md": "docs/JOURNAL.de.md", "docs/DEPLOY-FROM-APP.md": "docs/DEPLOY-FROM-APP.de.md"}
# every other docs/X.md with a docs/X.de.md stands in for itself
for _p in glob.glob(os.path.join(root, "docs", "*.de.md")):
    _n = os.path.basename(_p)[:-6]
    ALIAS.setdefault("docs/" + _n + ".md", "docs/" + _n + ".de.md")
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

# 4. the Settings tabs named in docs/README.md are the tabs of the app
if os.path.exists(os.path.join(root, "app", "SettingsSupport.swift")):
    m = re.search(r"enum SettingsTab[^{]*\{\s*(?:///[^\n]*\n\s*)*case ([a-z, ]+)", read("app/SettingsSupport.swift"))
    if m:
        tabs = [t.strip() for t in m.group(1).split(",") if t.strip()]
        words = ["zero", "one", "two", "three", "four", "five", "six", "seven", "eight", "nine", "ten", "eleven", "twelve"]
        said = re.search(r"Settings window has (\w+) tabs", index)
        if said and said.group(1) != words[len(tabs)]:
            problems.append(f'docs/README.md: says "{said.group(1)} tabs", the app has {len(tabs)} ({", ".join(tabs)})')
        first_cells = [ln.split("|")[1].strip().lower() for ln in index.splitlines() if ln.startswith("| ") and ln.count("|") >= 3]
        for t in tabs:
            if not any(c.startswith(t) for c in first_cells):
                problems.append(f"docs/README.md: the Settings table has no row for the tab '{t}'")

# 5. man/deploys.1 is what scripts/build-man.py writes from `deploys --help` and docs/CLI.md now
builder = os.path.join(root, "scripts", "build-man.py")
if os.path.exists(builder) and os.path.exists(os.path.join(root, "man", "deploys.1")):
    import subprocess
    r = subprocess.run([sys.executable, "-I", builder, "--check"], capture_output=True, text=True)
    if r.returncode != 0:
        problems.append("man/deploys.1 is out of date: run python3 scripts/build-man.py")

# 6. a provider in providers/ must not be missing from the places that list hosts by hand
PROVIDER_NAMES = {  # id -> the name the text must contain; a new provider has to be added here
    "vercel": "Vercel", "render": "Render", "netlify": "Netlify", "cloudflare": "Cloudflare",
    "amplify": "Amplify", "digitalocean": "DigitalOcean", "coolify": "Coolify", "fly": "Fly.io",
    "railway": "Railway", "heroku": "Heroku", "firebase": "Firebase", "ghpages": "GitHub Pages",
    "koyeb": "Koyeb", "northflank": "Northflank", "deno": "Deno", "hook": "deploy hook",
}
HOST_LISTS = ["site/index.html", "site/llms.txt", "SECURITY.md", "README.md", "README-CLI.md",
              ".claude-plugin/marketplace.json", "integrations/claude-code/skills/deploys-status/SKILL.md",
              "integrations/claude-code/skills/deploys-waiting/SKILL.md"]
KEYCHAIN_LISTS = ["docs/UNINSTALL.md", "docs/UNINSTALL.de.md"]
for path in sorted(glob.glob(os.path.join(root, "providers", "*.sh"))):
    pid = os.path.basename(path)[:-3]
    name = PROVIDER_NAMES.get(pid)
    if name is None:
        problems.append(f"scripts/check-docs.py: providers/{pid}.sh is new; add it to PROVIDER_NAMES and name it in the host lists")
        continue
    for rel in HOST_LISTS:
        if os.path.exists(os.path.join(root, rel)) and name.lower() not in read(rel).lower():
            problems.append(f"{rel}: does not name {name} (providers/{pid}.sh)")
    if pid in ("vercel", "hook"):
        continue
    for rel in KEYCHAIN_LISTS:
        if os.path.exists(os.path.join(root, rel)) and "deploy-center-" + pid not in read(rel) and pid not in ("render",):
            problems.append(f"{rel}: no keychain item deploy-center-{pid}")

for line in problems:
    print(line)
print(f"check-docs: {len(problems)} problems")
sys.exit(1 if problems else 0)
