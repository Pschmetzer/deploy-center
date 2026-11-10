#!/usr/bin/env python3
"""Adds a release to Sparkle's appcast (site/appcast.xml), newest first.

    scripts/appcast.py --appcast site/appcast.xml --version 0.9.0 --url <zip url> \
        --length <bytes> --signature <EdDSA from sign_update> --notes <markdown file> \
        [--min-os 15.0] [--release-page <url>] [--keep 10]

An item with the same version is replaced, so publishing again after a failed upload is fine.
Only the standard library: run it with python3 -I.
"""
import argparse
import email.utils
import os
import re
import sys
import xml.etree.ElementTree as ET

SPARKLE = "http://www.andymatuschak.org/xml-namespaces/sparkle"
ET.register_namespace("sparkle", SPARKLE)
S = "{%s}" % SPARKLE

EMPTY = f"""<?xml version="1.0" encoding="utf-8"?>
<rss version="2.0" xmlns:sparkle="{SPARKLE}">
  <channel>
    <title>Deploy Center</title>
    <link>https://deploycenter.app/</link>
    <description>Updates for Deploy Center</description>
    <language>en</language>
  </channel>
</rss>
"""


def main(argv=None):
    p = argparse.ArgumentParser(description=__doc__.splitlines()[0])
    p.add_argument("--appcast", required=True)
    p.add_argument("--version", required=True)
    p.add_argument("--url", required=True)
    p.add_argument("--length", required=True, type=int)
    p.add_argument("--signature", required=True)
    p.add_argument("--notes", required=True, help="markdown file with the release notes")
    p.add_argument("--min-os", default="15.0")
    p.add_argument("--release-page", default="")
    p.add_argument("--keep", default=10, type=int, help="how many releases stay in the feed")
    a = p.parse_args(argv)

    if not re.fullmatch(r"\d+\.\d+\.\d+", a.version):
        sys.exit(f"appcast.py: not a version: {a.version}")
    if not a.url.startswith("https://"):
        sys.exit("appcast.py: the download must be https")
    if not re.fullmatch(r"[A-Za-z0-9+/]{86}==", a.signature):
        sys.exit("appcast.py: that is not an EdDSA signature from sign_update")
    if a.length <= 0:
        sys.exit("appcast.py: length must be positive")
    with open(a.notes, encoding="utf-8") as f:
        notes = f.read().strip()

    if os.path.exists(a.appcast):
        tree = ET.parse(a.appcast)
    else:
        tree = ET.ElementTree(ET.fromstring(EMPTY))
    channel = tree.getroot().find("channel")
    if channel is None:
        sys.exit(f"appcast.py: {a.appcast} has no <channel>")

    for old in channel.findall("item"):
        if old.findtext(S + "version") == a.version:
            channel.remove(old)

    item = ET.Element("item")
    ET.SubElement(item, "title").text = f"Version {a.version}"
    ET.SubElement(item, "pubDate").text = email.utils.formatdate(usegmt=True)
    ET.SubElement(item, S + "version").text = a.version
    ET.SubElement(item, S + "shortVersionString").text = a.version
    ET.SubElement(item, S + "minimumSystemVersion").text = a.min_os
    if a.release_page:
        ET.SubElement(item, S + "fullReleaseNotesLink").text = a.release_page
    desc = ET.SubElement(item, "description", {S + "format": "markdown"})
    desc.text = notes
    ET.SubElement(item, "enclosure", {
        "url": a.url,
        "length": str(a.length),
        "type": "application/octet-stream",
        S + "edSignature": a.signature,
    })

    # Newest first: right after the channel's own fields.
    first = next((i for i, el in enumerate(channel) if el.tag == "item"), len(channel))
    channel.insert(first, item)
    for extra in channel.findall("item")[a.keep:]:
        channel.remove(extra)

    ET.indent(tree, space="  ")
    tmp = a.appcast + ".tmp"
    tree.write(tmp, encoding="utf-8", xml_declaration=True)
    with open(tmp, "a", encoding="utf-8") as f:
        f.write("\n")
    os.replace(tmp, a.appcast)
    print(f"appcast: {a.version} in {a.appcast}")


if __name__ == "__main__":
    main()
