#!/usr/bin/env python3
"""Check every link in site/: pages, files and #anchors. Standard library only, no network.

    python3 scripts/check-links.py [site]
    python3 scripts/check-links.py --external [site]   also ask every other https address once (HEAD, then GET); the
                                                      weekly CI job runs this, a normal run never touches the network

- href/src that point into the site (relative or starting with /) must exist, and a #fragment
  must be an id on the target page.
- Links to this repo on GitHub (blob/tree/edit on main) must name a file that exists in the checkout.
- Other external links are not fetched (unless --external).
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


# Example addresses in the docs (a made-up host, a placeholder, a local address) are never asked.
SKIP_HOSTS = re.compile(r"(^|\.)(example\.(com|org|net)|localhost|127\.0\.0\.1|deploycenter\.app)$|^\[|<|\{|\$")


def ask(url):
    """The HTTP status of an address, or an error text. HEAD first; some servers refuse it, so a failure is asked again with GET."""
    import urllib.error
    import urllib.request
    last = ""
    for method in ("HEAD", "GET"):
        req = urllib.request.Request(url, method=method, headers={"User-Agent": "deploy-center-link-check"})
        try:
            with urllib.request.urlopen(req, timeout=20) as r:
                return r.status
        except urllib.error.HTTPError as e:
            last = e.code
            if e.code in (401, 403, 429):   # the host answers, it only does not like a bot: not a dead link
                return e.code
        except (urllib.error.URLError, OSError, ValueError) as e:
            last = str(getattr(e, "reason", e))
    return last


def check_external(external):
    """external: {url: [pages]}. Returns the lines for the dead ones."""
    dead = []
    for url in sorted(external):
        code = ask(url)
        if not (isinstance(code, int) and code < 400) and code not in (401, 403, 429):
            dead.append(f"{', '.join(sorted(external[url])[:3])}: {url} ({code})")
    return dead


def main():
    args = [a for a in sys.argv[1:] if a != "--external"]
    want_external = "--external" in sys.argv[1:]
    external = {}
    site = os.path.abspath(args[0] if args else os.path.join(ROOT, "site"))
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
                    if want_external and parts.scheme == "https" and not SKIP_HOSTS.search(parts.netloc):
                        external.setdefault(url.split("#")[0], set()).add(rel)
                    continue  # external, not fetched without --external
                url = parts.path + (f"#{parts.fragment}" if parts.fragment else "")
            target, frag = resolve(site, page, url)
            if not target.startswith(site):
                errors.append(f"{rel}:{line}: {url} (outside the site)")
            elif not os.path.isfile(target):
                errors.append(f"{rel}:{line}: {url} (not found)")
            elif frag and target.endswith(".html") and unquote(frag) not in parse(target).ids:
                errors.append(f"{rel}:{line}: {url} (no id \"{frag}\" on {os.path.relpath(target, site)})")
    if want_external:
        print(f"check-links: asking {len(external)} external addresses ...", file=sys.stderr)
        errors += check_external(external)
    for e in errors:
        print(e)
    print(f"check-links: {len(pages)} pages, {checked} links, {len(errors)} broken", file=sys.stderr)
    sys.exit(1 if errors else 0)


if __name__ == "__main__":
    main()
