#!/usr/bin/env python3
"""Release gate: VERSION, the website and the Sparkle appcast name the same release.

    python3 -I scripts/check-release.py [repo-dir]

- site/index.html names VERSION twice ("Version X ·" under the download button and
  "softwareVersion" in the JSON-LD). scripts/bump.sh sets both together with VERSION.
- The newest item in site/appcast.xml is not newer than VERSION.
- Once the tag vVERSION exists (release.sh --publish made the release), the newest appcast
  item is VERSION: until the appcast PR is merged, installed copies are never offered it.
  Without the tag (between bump and publish) the appcast may still name the release before.
Exits 1 and lists each mismatch. Standard library only, no network.
"""
import os
import re
import subprocess
import sys
import xml.etree.ElementTree as ET

SPARKLE = "{http://www.andymatuschak.org/xml-namespaces/sparkle}"
root = os.path.abspath(sys.argv[1] if len(sys.argv) > 1 else os.path.join(os.path.dirname(__file__), ".."))
problems = []


def vkey(v):
    return tuple(int(x) for x in v.split("."))


def read(rel):
    with open(os.path.join(root, rel), encoding="utf-8") as f:
        return f.read()


version = read("VERSION").strip()
if not re.fullmatch(r"\d+\.\d+\.\d+", version):
    sys.exit(f"check-release: VERSION is not x.y.z: {version!r}")

index = read("site/index.html")
shown = re.findall(r"Version (\d+\.\d+\.\d+) ·", index)
ld = re.findall(r'"softwareVersion":\s*"([^"]*)"', index)
if not shown:
    problems.append('site/index.html: no "Version x.y.z ·" line')
if not ld:
    problems.append('site/index.html: no "softwareVersion" in the JSON-LD')
for v in shown:
    if v != version:
        problems.append(f'site/index.html: says "Version {v}", VERSION is {version} (scripts/bump.sh sets both)')
for v in ld:
    if v != version:
        problems.append(f'site/index.html: "softwareVersion" is {v}, VERSION is {version}')

items = []
try:
    channel = ET.fromstring(read("site/appcast.xml")).find("channel")
    for item in channel.findall("item") if channel is not None else []:
        v = (item.findtext(SPARKLE + "shortVersionString") or item.findtext(SPARKLE + "version") or "").strip()
        if re.fullmatch(r"\d+\.\d+\.\d+", v):
            items.append(v)
        else:
            problems.append(f"site/appcast.xml: an item without an x.y.z version ({v!r})")
except (ET.ParseError, OSError) as e:
    problems.append(f"site/appcast.xml: {e}")

tagged = subprocess.run(["git", "-C", root, "rev-parse", "-q", "--verify", f"refs/tags/v{version}"],
                        stdout=subprocess.DEVNULL, stderr=subprocess.DEVNULL).returncode == 0
newest = max(items, key=vkey) if items else None
if newest and vkey(newest) > vkey(version):
    problems.append(f"site/appcast.xml: newest item is {newest}, newer than VERSION {version}")
if tagged and newest != version:
    problems.append(f"site/appcast.xml: tag v{version} exists, but the newest item is {newest or 'none'}"
                    f" (merge the appcast-{version} PR from release.sh --publish)")

for line in problems:
    print(line)
state = "tagged" if tagged else "not tagged yet"
print(f"VERSION {version} ({state}), site {'/'.join(sorted(set(shown + ld))) or '-'}, appcast {newest or '-'}: "
      f"{len(problems)} problems")
sys.exit(1 if problems else 0)
