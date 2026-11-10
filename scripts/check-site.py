#!/usr/bin/env python3
"""Checks the static website in site/ without a network:
- every internal link (href/src) resolves to a file, and #anchors exist on the target page
- every JSON-LD block is valid JSON with @context and @type
- every indexable page has a title, description, canonical, og:title/og:url/og:image
- every page in sitemap.xml exists, and every indexable page is in sitemap.xml
    scripts/check-site.py        exits 1 and lists the problems
"""
import json, os, re, sys
from html.parser import HTMLParser
from urllib.parse import urlsplit, unquote

ROOT = os.path.join(os.path.dirname(os.path.abspath(__file__)), "..", "site")
SITE = "https://deploycenter.app"
problems = []


class Page(HTMLParser):
    def __init__(self):
        super().__init__()
        self.links, self.ids, self.meta, self.ld = [], set(), {}, []
        self.title, self._in_title, self._in_ld, self._buf = "", False, False, ""

    def handle_starttag(self, tag, attrs):
        a = dict(attrs)
        if "id" in a:
            self.ids.add(a["id"])
        if tag == "a" and a.get("href"):
            self.links.append(a["href"])
        if tag == "link" and a.get("href") and a.get("rel") in ("stylesheet", "icon", "apple-touch-icon", "manifest"):
            self.links.append(a["href"])
        if tag in ("img", "script", "source") and a.get("src"):
            self.links.append(a["src"])
        if tag == "link" and a.get("rel") == "canonical":
            self.meta["canonical"] = a.get("href", "")
        if tag == "meta":
            key = a.get("name") or a.get("property")
            if key:
                self.meta[key] = a.get("content", "")
        if tag == "title":
            self._in_title = True
        if tag == "script" and a.get("type") == "application/ld+json":
            self._in_ld, self._buf = True, ""

    def handle_endtag(self, tag):
        if tag == "title":
            self._in_title = False
        if tag == "script" and self._in_ld:
            self._in_ld = False
            self.ld.append(self._buf)

    def handle_data(self, data):
        if self._in_title:
            self.title += data
        if self._in_ld:
            self._buf += data


def resolve(page_path, url):
    """Map a link to a file in site/, or None for external links."""
    parts = urlsplit(url)
    if parts.scheme in ("mailto", "tel", "javascript", "data"):
        return None, None
    if parts.scheme or parts.netloc:
        if parts.netloc != "deploycenter.app":
            return None, None
        path = parts.path or "/"
    else:
        path = parts.path
    if path == "":
        target = page_path
    elif path.startswith("/"):
        target = os.path.join(ROOT, unquote(path.lstrip("/")))
    else:
        target = os.path.normpath(os.path.join(os.path.dirname(page_path), unquote(path)))
    if os.path.isdir(target) or path.endswith("/"):
        target = os.path.join(target, "index.html")
    return target, parts.fragment


pages = {}
for d, _, files in os.walk(ROOT):
    for f in files:
        if f.endswith(".html"):
            p = os.path.normpath(os.path.join(d, f))
            parser = Page()
            parser.feed(open(p, encoding="utf-8").read())
            pages[p] = parser

def rel(p):
    return os.path.relpath(p, ROOT)

for p, pg in pages.items():
    for url in pg.links:
        target, frag = resolve(p, url)
        if target is None:
            continue
        if not os.path.isfile(target):
            problems.append(f"{rel(p)}: broken link {url}")
        elif frag and target.endswith(".html") and frag not in pages[os.path.normpath(target)].ids:
            problems.append(f"{rel(p)}: missing anchor {url}")
    for block in pg.ld:
        try:
            data = json.loads(block)
            for item in data if isinstance(data, list) else [data]:
                if "@context" not in item or "@type" not in item:
                    problems.append(f"{rel(p)}: JSON-LD item without @context/@type")
        except ValueError as e:
            problems.append(f"{rel(p)}: invalid JSON-LD: {e}")
    if pg.meta.get("robots", "").startswith("noindex"):
        continue
    for key in ("description", "canonical", "og:title", "og:url", "og:image"):
        if not pg.meta.get(key):
            problems.append(f"{rel(p)}: no {key}")
    if not pg.title.strip():
        problems.append(f"{rel(p)}: no <title>")
    if not pg.ld:
        problems.append(f"{rel(p)}: no JSON-LD")

sitemap = open(os.path.join(ROOT, "sitemap.xml"), encoding="utf-8").read()
locs = re.findall(r"<loc>([^<]+)</loc>", sitemap)
for loc in locs:
    target, _ = resolve(os.path.join(ROOT, "index.html"), loc)
    if not target or not os.path.isfile(target):
        problems.append(f"sitemap.xml: {loc} has no page")
for p, pg in pages.items():
    if not pg.meta.get("robots", "").startswith("noindex") and pg.meta.get("canonical") not in locs:
        problems.append(f"{rel(p)}: canonical {pg.meta.get('canonical')} is not in sitemap.xml")

for line in problems:
    print(line)
print(f"{len(pages)} pages, {sum(len(p.links) for p in pages.values())} links, {len(problems)} problems")
sys.exit(1 if problems else 0)
