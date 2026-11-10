#!/usr/bin/env python3
"""Check every link in site/: pages, files and #anchors. Standard library only, no network.

    python3 scripts/check-links.py [site]

- href/src that point into the site (relative or starting with /) must exist, and a #fragment
  must be an id on the target page.
- Links to this repo on GitHub (blob/tree/edit on main) must name a file that exists in the checkout.
- Other external links are not fetched.
Exits 1 and lists each broken link.
"""
import html.parser
import os
import re
import sys
from urllib.parse import urlsplit, unquote

ROOT = os.path.dirname(os.path.dirname(os.path.abspath(__file__)))
REPO = re.compile(r"^https://github\.com/Pschmetzer/deploy-center/(?:blob|tree|edit)/main/([^#?]+)")
SITE_HOST = "deploycenter.app"


class Parser(html.parser.HTMLParser):
    def __init__(self):
        super().__init__()
        self.links, self.ids = [], set()

    def handle_starttag(self, tag, attrs):
        a = dict(attrs)
        if a.get("id"):
            self.ids.add(a["id"])
        if tag == "a" and a.get("name"):
            self.ids.add(a["name"])
        for key in ("href", "src"):
            if a.get(key) and not (tag == "link" and a.get("rel") in ("canonical", "preconnect", "dns-prefetch")):
                self.links.append((key, a[key], self.getpos()[0]))


def parse(path, cache={}):
    if path not in cache:
        p = Parser()
        with open(path, encoding="utf-8") as f:
            p.feed(f.read())
        cache[path] = p
    return cache[path]


def resolve(site, page, url):
    """URL in `page` -> (file in site or None, fragment)."""
    parts = urlsplit(url)
    path = unquote(parts.path)
    if path.startswith("/"):
        target = os.path.join(site, path.lstrip("/"))
    elif path:
        target = os.path.join(os.path.dirname(page), path)
    else:
        target = page
    target = os.path.normpath(target)
    if os.path.isdir(target):
        target = os.path.join(target, "index.html")
    elif not os.path.exists(target) and os.path.exists(target + ".html"):
        target += ".html"
    return target, parts.fragment


def main():
    site = os.path.abspath(sys.argv[1] if len(sys.argv) > 1 else os.path.join(ROOT, "site"))
    pages = [os.path.join(d, f) for d, _, fs in os.walk(site) for f in fs if f.endswith(".html")]
    errors, checked = [], 0
    for page in sorted(pages):
        rel = os.path.relpath(page, site)
        for key, url, line in parse(page).links:
            checked += 1
            if re.match(r"^(mailto|tel|javascript|data):", url):
                continue
            m = REPO.match(url)
            if m:
                if not os.path.exists(os.path.join(ROOT, unquote(m.group(1)))):
                    errors.append(f"{rel}:{line}: {url} (no such file in the repo)")
                continue
            parts = urlsplit(url)
            if parts.scheme or parts.netloc:
                if parts.netloc != SITE_HOST:
                    continue  # external, not fetched
                url = parts.path + (f"#{parts.fragment}" if parts.fragment else "")
            target, frag = resolve(site, page, url)
            if not target.startswith(site):
                errors.append(f"{rel}:{line}: {url} (outside the site)")
            elif not os.path.isfile(target):
                errors.append(f"{rel}:{line}: {url} (not found)")
            elif frag and target.endswith(".html") and unquote(frag) not in parse(target).ids:
                errors.append(f"{rel}:{line}: {url} (no id \"{frag}\" on {os.path.relpath(target, site)})")
    for e in errors:
        print(e)
    print(f"check-links: {len(pages)} pages, {checked} links, {len(errors)} broken", file=sys.stderr)
    sys.exit(1 if errors else 0)


if __name__ == "__main__":
    main()
