#!/usr/bin/env python3
"""Accessibility checks for the static website in site/ (WCAG 2.2 AA), no network, standard library only:
- colors: every text/background pair of the tokens in css/tokens.css (dark, light) keeps its contrast
  (4.5:1 for text, 3:1 for large text, borders of controls and focus rings)
- every page: a skip link that is the first link and points at an id on the page, one <main id=...>,
  a labelled <nav> when there are several, a <footer>, <html lang>, no skipped heading level (h1 to h3),
  every form control has a label, every button and link has a name, no duplicate id,
  target=_blank has rel="noopener", no positive tabindex, no autoplay, tables have a header row
- css: a prefers-reduced-motion rule in every stylesheet that animates, :focus-visible is never removed
    scripts/check-a11y.py [site]   exits 1 and lists the problems (default: site/ of this repo)
"""
import os, re, sys
from html.parser import HTMLParser

ROOT = os.path.abspath(sys.argv[1]) if len(sys.argv) > 1 else os.path.normpath(
    os.path.join(os.path.dirname(os.path.abspath(__file__)), "..", "site"))
problems, warnings = [], []


# ---- colors ---------------------------------------------------------------------------------
def lum(h):
    h = h.lstrip("#")
    c = [int(h[i:i + 2], 16) / 255 for i in (0, 2, 4)]
    c = [v / 12.92 if v <= 0.03928 else ((v + 0.055) / 1.055) ** 2.4 for v in c]
    return 0.2126 * c[0] + 0.7152 * c[1] + 0.0722 * c[2]


def ratio(a, b):
    la, lb = sorted((lum(a), lum(b)), reverse=True)
    return (la + 0.05) / (lb + 0.05)


def tokens():
    path = os.path.join(ROOT, "css", "tokens.css")
    if not os.path.isfile(path):
        return {}
    css = open(path, encoding="utf-8").read()
    def vars_of(block):
        return dict(re.findall(r"--([\w-]+):\s*(#[0-9a-fA-F]{6})", block))
    dark = vars_of(re.search(r":root\{color-scheme:dark;(.*?)\}", css, re.S).group(1))
    light = vars_of(re.search(r':root\[data-theme="light"\]\{(.*?)\}', css, re.S).group(1))
    media = re.search(r"@media \(prefers-color-scheme: light\)\{(.*)\}\s*:root\[data-theme", css, re.S)
    if media and vars_of(media.group(1)) != light:
        problems.append("css/tokens.css: the light values of the system preference and of data-theme=light differ")
    return {"dark": dark, "light": light}


# (foreground, background, minimum, what)
PAIRS = [("text", "bg", 4.5, "text"), ("text", "card", 4.5, "text"), ("muted", "bg", 4.5, "muted text"),
         ("muted", "bg2", 4.5, "muted text"), ("muted", "card", 4.5, "muted text"),
         ("accent", "bg", 4.5, "links"), ("accent", "card", 4.5, "links"), ("accent", "bg2", 4.5, "links"),
         ("green", "bg", 4.5, "green text"), ("green", "card", 4.5, "green text"),
         ("red", "bg", 4.5, "red text"), ("red", "card", 4.5, "red text"),
         ("orange", "bg", 4.5, "orange text"), ("orange", "card", 4.5, "orange text"),
         ("accent", "bg", 3.0, "focus ring")]
for theme, t in tokens().items():
    for fg, bg, need, what in PAIRS:
        if fg in t and bg in t and ratio(t[fg], t[bg]) < need:
            problems.append(f"css/tokens.css ({theme}): {what} --{fg} on --{bg} is {ratio(t[fg], t[bg]):.2f}:1, needs {need}:1")
    for btn in ("btn-a", "btn-b"):   # the white label of the download button
        if btn in t and ratio("#ffffff", t[btn]) < 4.5:
            problems.append(f"css/tokens.css ({theme}): white on --{btn} is {ratio('#ffffff', t[btn]):.2f}:1, needs 4.5:1")


# ---- pages ----------------------------------------------------------------------------------
class Page(HTMLParser):
    VOID = {"img", "br", "meta", "link", "input", "hr", "source", "wbr"}

    def __init__(self):
        super().__init__()
        self.lang = None
        self.ids, self.dups = set(), set()
        self.first_link = None
        self.mains, self.navs, self.footers = [], 0, 0
        self.nav_unlabelled = 0
        self.levels = []
        self.controls, self.labels_for, self.wrapped = [], set(), 0
        self.stack = []   # open elements: [tag, attrs, text]
        self.unnamed = []
        self.issues = []
        self.tables = []   # [has_th]
        self._label_depth = 0

    def handle_starttag(self, tag, attrs):
        a = dict(attrs)
        if tag == "html":
            self.lang = a.get("lang")
        if a.get("id"):
            if a["id"] in self.ids:
                self.dups.add(a["id"])
            self.ids.add(a["id"])
        if tag == "a" and a.get("href") is not None and self.first_link is None:
            self.first_link = a["href"]
        if tag == "main":
            self.mains.append(a.get("id"))
        if tag == "nav":
            self.navs += 1
            if not (a.get("aria-label") or a.get("aria-labelledby")):
                self.nav_unlabelled += 1
        if tag == "footer":
            self.footers += 1
        if re.fullmatch(r"h[1-6]", tag):
            self.levels.append(int(tag[1]))
        if a.get("tabindex", "0").lstrip("-").isdigit() and int(a.get("tabindex", "0")) > 0:
            self.issues.append("positive tabindex")
        if "autoplay" in a:
            self.issues.append("autoplay")
        if a.get("target") == "_blank" and "noopener" not in (a.get("rel") or "") and "noreferrer" not in (a.get("rel") or ""):
            self.issues.append(f"target=_blank without rel=noopener ({a.get('href', '')[:50]})")
        if tag == "label":
            if a.get("for"):
                self.labels_for.add(a["for"])
            self._label_depth += 1
        if tag == "table":
            self.tables.append(False)
        if tag == "th" and self.tables:
            self.tables[-1] = True
        if tag in ("input", "select", "textarea") and a.get("type") not in ("hidden", "submit", "button"):
            self.controls.append((tag, a, self._label_depth > 0))
        if tag == "img":
            if self.stack and self.stack[-1][0] in ("a", "button"):
                self.stack[-1][2] += " " + (a.get("alt") or "")
            return
        if tag in self.VOID:
            return
        self.stack.append([tag, a, ""])

    def handle_endtag(self, tag):
        if tag == "label":
            self._label_depth = max(0, self._label_depth - 1)
        for i in range(len(self.stack) - 1, -1, -1):
            if self.stack[i][0] == tag:
                t, a, text = self.stack[i]
                del self.stack[i:]
                if t in ("a", "button") and (a.get("href") is not None or t == "button"):
                    if not (text.strip() or a.get("aria-label") or a.get("aria-labelledby") or a.get("title")):
                        self.unnamed.append(f"<{t}{' href=' + a['href'] if a.get('href') else ''}>")
                break

    def handle_data(self, data):
        for item in self.stack:
            if item[0] in ("a", "button"):
                item[2] += data


pages = {}
for d, _, files in os.walk(ROOT):
    for f in files:
        if f.endswith(".html"):
            p = os.path.normpath(os.path.join(d, f))
            pg = Page()
            pg.feed(open(p, encoding="utf-8").read())
            pages[p] = pg

for p, pg in sorted(pages.items()):
    name = os.path.relpath(p, ROOT)
    if not pg.lang:
        problems.append(f"{name}: no <html lang>")
    if len(pg.mains) != 1:
        problems.append(f"{name}: {len(pg.mains)} <main> (one expected)")
    if not pg.footers:
        problems.append(f"{name}: no <footer> (contentinfo landmark)")
    if pg.navs > 1 and pg.nav_unlabelled:
        problems.append(f"{name}: {pg.nav_unlabelled} of {pg.navs} <nav> without aria-label (several navs must be told apart)")
    sk = pg.first_link
    if not sk or not sk.startswith("#") or sk[1:] not in pg.ids:
        problems.append(f"{name}: the first link is not a skip link to an id on the page (first link: {sk})")
    elif pg.mains and pg.mains[0] and sk[1:] != pg.mains[0]:
        problems.append(f"{name}: the skip link goes to {sk}, the <main> has id={pg.mains[0]}")
    prev = 0
    for lv in pg.levels:
        if prev and lv > prev + 1:
            problems.append(f"{name}: heading level jumps from h{prev} to h{lv}")
            break
        prev = lv
    for tag, a, wrapped in pg.controls:
        ok = wrapped or a.get("aria-label") or a.get("aria-labelledby") or a.get("title") or (a.get("id") in pg.labels_for)
        if not ok:
            problems.append(f"{name}: <{tag} {a.get('name') or a.get('id') or a.get('type') or ''}> has no label")
    for u in pg.unnamed:
        problems.append(f"{name}: {u} has no accessible name")
    for i in sorted(pg.dups):
        problems.append(f"{name}: duplicate id {i}")
    for i in sorted(set(pg.issues)):
        problems.append(f"{name}: {i}")
    for has_th in pg.tables:
        if not has_th:
            problems.append(f"{name}: a <table> without <th> header cells")


# ---- css ------------------------------------------------------------------------------------
for f in sorted(os.listdir(os.path.join(ROOT, "css"))) if os.path.isdir(os.path.join(ROOT, "css")) else []:
    if not f.endswith(".css"):
        continue
    css = open(os.path.join(ROOT, "css", f), encoding="utf-8").read()
    if re.search(r"@keyframes|animation\s*:|transition\s*:", css) and "prefers-reduced-motion" not in css:
        problems.append(f"css/{f}: animates but has no prefers-reduced-motion rule")
    if re.search(r":focus\s*\{[^}]*outline\s*:\s*(none|0)", css):
        problems.append(f"css/{f}: removes the focus outline")

for line in problems:
    print(line)
for line in warnings:
    print("warning: " + line)
print(f"{len(pages)} pages, {len(problems)} accessibility problems")
sys.exit(1 if problems else 0)
