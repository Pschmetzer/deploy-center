#!/usr/bin/env python3
"""Which URLs to tell IndexNow about: only the pages a push changed, as a JSON array.

  git diff --name-only A B | python3 scripts/indexnow-urls.py site/sitemap.xml
  python3 scripts/indexnow-urls.py site/sitemap.xml --all      every URL in the sitemap

A changed site/<path>.html (or <dir>/index.html) is its own URL. A change to a source of the
generated docs (README.md, deploys, docs/**.md, integrations/**.md, examples/README.md, VERSION,
the generator) means every /docs/ URL. Anything else (CSS, images, scripts) pings nothing.
Only URLs in the (built) sitemap are listed, so a page that is not public is never sent.
"""
import json
import re
import sys

DOCS_SOURCES = re.compile(r"^(README\.md|deploys|VERSION|examples/README\.md|docs/.*\.md|integrations/.*\.md"
                          r"|scripts/build-docs\.py|scripts/docs-assets/.*)$")


def urls_in(sitemap):
    with open(sitemap, encoding="utf-8") as f:
        return re.findall(r"<loc>([^<]+)</loc>", f.read())


def page_of(path):
    """site/a/index.html -> /a/, site/index.html -> /, site/x.html -> /x.html; None if not a page."""
    if not path.startswith("site/") or not path.endswith(".html"):
        return None
    rel = path[len("site/"):]
    if rel == "index.html":
        return "/"
    if rel.endswith("/index.html"):
        return "/" + rel[: -len("index.html")]
    return "/" + rel


def pick(changed, all_urls):
    wanted = set()
    for path in changed:
        if DOCS_SOURCES.match(path):
            wanted.update(u for u in all_urls if "/docs/" in u)
        page = page_of(path)
        if page:
            wanted.update(u for u in all_urls if re.sub(r"^https?://[^/]+", "", u) == page)
    return [u for u in all_urls if u in wanted]


def main():
    if len(sys.argv) < 2:
        sys.exit("usage: indexnow-urls.py <sitemap.xml> [--all]")
    all_urls = urls_in(sys.argv[1])
    if "--all" in sys.argv[2:]:
        print(json.dumps(all_urls))
        return
    changed = [l.strip() for l in sys.stdin if l.strip()]
    print(json.dumps(pick(changed, all_urls)))


if __name__ == "__main__":
    main()
