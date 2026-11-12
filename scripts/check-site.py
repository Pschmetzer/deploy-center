#!/usr/bin/env python3
"""Checks the static website in site/ without a network:
- every internal link (href/src) resolves to a file, and #anchors exist on the target page
- every JSON-LD block is valid JSON with @context and @type
- every indexable page has a title, description, canonical, og:title/og:url/og:image
- every page in sitemap.xml exists, and every indexable page is in sitemap.xml
- every page has <html lang>, every <img> an alt (alt="" for decoration) and (a warning) a width and height,
  every indexable page one <h1>; no image in site/ is larger than MAX_IMAGE bytes
- .well-known/security.txt, when there, has Contact and an Expires date still in the future
    scripts/check-site.py [site]   exits 1 and lists the problems (default: site/ of this repo)
"""
import importlib.util, json, os, re, sys
from html.parser import HTMLParser
from urllib.parse import urlsplit

ROOT = os.path.abspath(sys.argv[1]) if len(sys.argv) > 1 else os.path.normpath(
    os.path.join(os.path.dirname(os.path.abspath(__file__)), "..", "site"))
SITE = "https://deploycenter.app"
MAX_IMAGE = 400 * 1024   # the largest today, img/app.png, is about 324 KB
problems = []
warnings = []   # printed, not failing (yet): img width/height, until impressum and datenschutz have them


class Page(HTMLParser):
    def __init__(self):
        super().__init__()
        self.links, self.ids, self.meta, self.ld = [], set(), {}, []
        self.title, self._in_title, self._in_ld, self._buf = "", False, False, ""
        self.lang, self.h1, self.imgs = None, 0, []

    def handle_starttag(self, tag, attrs):
        a = dict(attrs)
        rels = set((a.get("rel") or "").lower().split())  # rel="shortcut icon", "preload stylesheet"
        if "id" in a:
            self.ids.add(a["id"])
        if tag == "html":
            self.lang = a.get("lang")
        if tag == "h1":
            self.h1 += 1
        if tag == "img":
            self.imgs.append(a)
        if tag == "a" and a.get("href"):
            self.links.append(a["href"])
        if tag == "link" and a.get("href") and rels & {"stylesheet", "icon", "apple-touch-icon", "manifest", "preload", "modulepreload"}:
            self.links.append(a["href"])
        if tag in ("img", "script", "source") and a.get("src"):
            self.links.append(a["src"])
        if tag == "link" and "canonical" in rels:
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


# One way to map a link to a file, shared with check-links.py (its .html fallback included), so the
# two checks never disagree about what a link points to.
_spec = importlib.util.spec_from_file_location(
    "check_links", os.path.join(os.path.dirname(os.path.abspath(__file__)), "check-links.py"))
check_links = importlib.util.module_from_spec(_spec)
_spec.loader.exec_module(check_links)


def resolve(page_path, url):
    """Map a link to a file in site/, or None for external links."""
    parts = urlsplit(url)
    if parts.scheme in ("mailto", "tel", "javascript", "data"):
        return None, None
    if parts.scheme or parts.netloc:
        if parts.netloc != check_links.SITE_HOST:
            return None, None
        url = (parts.path or "/") + (f"#{parts.fragment}" if parts.fragment else "")
    return check_links.resolve(ROOT, page_path, url)


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
    if not pg.lang:
        problems.append(f"{rel(p)}: no <html lang>")
    for img in pg.imgs:
        name = img.get("src", "?")
        if img.get("alt") is None:
            problems.append(f"{rel(p)}: <img {name}> has no alt")
        if not (img.get("width") and img.get("height")):
            warnings.append(f"{rel(p)}: <img {name}> has no width and height")
    if pg.meta.get("robots", "").startswith("noindex"):
        continue
    if pg.h1 != 1:
        problems.append(f"{rel(p)}: {pg.h1} <h1> (one expected)")
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

for d, _, files in os.walk(ROOT):
    for f in files:
        if f.lower().endswith((".png", ".jpg", ".jpeg", ".gif", ".webp")):
            p = os.path.join(d, f)
            if os.path.getsize(p) > MAX_IMAGE:
                problems.append(f"{rel(p)}: {os.path.getsize(p) // 1024} KB, more than {MAX_IMAGE // 1024} KB")

security = os.path.join(ROOT, ".well-known", "security.txt")
if os.path.isfile(security):
    import datetime
    text = open(security, encoding="utf-8").read()
    if not re.search(r"^Contact:\s*\S", text, re.M):
        problems.append(".well-known/security.txt: no Contact")
    m = re.search(r"^Expires:\s*(\S+)", text, re.M)
    try:
        expires = datetime.datetime.fromisoformat(m.group(1).replace("Z", "+00:00")) if m else None
    except ValueError:
        expires = None
    if not expires or expires.tzinfo is None:
        problems.append(".well-known/security.txt: no Expires date (RFC 9116, e.g. 2027-06-30T00:00:00Z)")
    elif expires <= datetime.datetime.now(datetime.timezone.utc):
        problems.append(f".well-known/security.txt: expired on {m.group(1)}")

for line in problems:
    print(line)
for line in warnings:
    print("warning: " + line)
print(f"{len(pages)} pages, {sum(len(p.links) for p in pages.values())} links, {len(problems)} problems")
sys.exit(1 if problems else 0)
