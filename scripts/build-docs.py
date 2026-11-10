#!/usr/bin/env python3
"""Build site/docs/ from the repo's Markdown. Python 3.9+, standard library only.

    python3 scripts/build-docs.py            # writes site/docs/ and the docs part of site/sitemap.xml,
                                             # puts VERSION into site/index.html and site/llms.txt, and
                                             # the git date of each hand-written page into sitemap.xml

The pages are listed in PAGES below. Links between converted files become links between docs
pages; links to any other file in the repo go to GitHub. A relative link to a file that does not
exist stops the build. scripts/check-links.py then checks every link and #anchor in site/.

The Markdown converter covers what these files use: ATX headings, paragraphs, nested lists,
fenced code (also inside list items), tables, block quotes, rules, `code`, **bold**, *italic*
and [links](url). Raw HTML is shown as text.
"""
import datetime
import hashlib
import html
import json
import os
import posixpath
import re
import shutil
import subprocess
import sys

ROOT = os.path.dirname(os.path.dirname(os.path.abspath(__file__)))
SITE = os.path.join(ROOT, "site")
OUT = os.path.join(SITE, "docs")
ASSETS = os.path.join(ROOT, "scripts", "docs-assets")
BASE = "https://deploycenter.app"
REPO = "https://github.com/Pschmetzer/deploy-center"
BRANCH = "main"
# site/img/og.png (1200 x 630), the same picture as on the home page
OG_ALT = "Deploy Center: stop paying for a build on every push. Free Mac app for manual deploys."
# The footer line on every docs page; the home page lists the same names.
TRADEMARKS = ("Not affiliated with Vercel, Render, Netlify, Cloudflare, AWS, DigitalOcean, Coolify, GitHub, "
              "GitLab or Anthropic. Claude is a trademark of Anthropic.")

# slug, nav label, group, source file, description. Order = sidebar order.
PAGES = [
    ("getting-started", "Getting started", "Start", "README.md",
     "Install Deploy Center with Homebrew or by hand, what it needs, and how to connect Vercel, Render and GitHub."),
    ("safe-start", "Try it safely", "Start", "docs/SAFE-START.md",
     "Try Deploy Center without risk: only look first, then turn off auto-deploy for one project, then for all."),
    ("install-cli", "Install the CLI", "Start", "README-CLI.md",
     "Install the deploys CLI alone on macOS, Linux, WSL or in CI: the install script, Homebrew, Docker, and the variables CI needs."),
    ("cli", "CLI reference", "Start", "docs/CLI.md",
     "Every command of the deploys CLI: changed, deploy-changed, status, watch, logs, Vercel, Render, autofix, CI variables, exit codes and settings."),
    ("auto-deploy", "Auto-deploy off and on", "Using it", "docs/AUTO-DEPLOY.md",
     "What turning off auto-deploy changes on Vercel and Render, and how to turn it back on."),
    ("autofix", "Autofix", "Using it", "docs/AUTOFIX.md",
     "deploys autofix hands a failed Vercel or Render build to a Claude Code routine that opens a fix pull request. It never deploys."),
    ("safe-deploy", "Safe deploys", "Using it", "docs/SAFE-DEPLOY.md",
     "Batch many pushes into one deploy: deploy only when CI is green, a site check with automatic rollback, deploy windows and a risk score."),
    ("guard", "Auto-deploy guard", "Using it", "docs/GUARD.md",
     "deploys guard notices when auto-deploy comes back on by itself and turns it off again, and allows auto-deploy for a while on purpose."),
    ("savings", "Savings: simulate and ledger", "Using it", "docs/SAVINGS.md",
     "deploys simulate estimates what auto-deploy would cost a month, deploys ledger what turning it off saved, on Vercel and Render."),
    ("team", "Team mode", "Using it", "docs/TEAM.md",
     "The same deploy rules on every teammate's Mac without a server: a shared config file, observers and a two-person rule."),
    ("claude", "Claude in the app", "Using it", "docs/CLAUDE.md",
     "Ask Claude with your own Anthropic API key why a build failed, for release notes, and whether a deploy is safe to ship."),
    ("claude-code", "Claude Code", "Using it", "docs/CLAUDE-CODE.md",
     "Deploy Center with Claude Code: the MCP server, the plugin and Autofix. Claude writes and fixes the code, you decide what ships."),
    ("gitlab", "GitLab as a source", "Using it", "docs/GITLAB.md",
     "Read commits and merge requests waiting to deploy from gitlab.com or a self-managed GitLab, with glab or GITLAB_TOKEN."),
    ("deploy-hooks", "Deploy hooks (any host)", "Hosts", "docs/providers/hook.md",
     "Deploy any host with a build-trigger URL by hand: Cloudflare Pages, Netlify, DigitalOcean, Coolify, Dokploy, Amplify."),
    ("netlify", "Netlify", "Hosts", "docs/providers/netlify.md",
     "Netlify in Deploy Center: turn it on, stop builds on push with an ignore line, and deploy sites by hand with a build hook."),
    ("cloudflare-pages", "Cloudflare Pages", "Hosts", "docs/providers/cloudflare.md",
     "Cloudflare Pages in Deploy Center: an API token, turning push-deploys off, a self-test, and deploying projects by hand."),
    ("aws-amplify", "AWS Amplify", "Hosts", "docs/providers/amplify.md",
     "AWS Amplify Hosting in Deploy Center: an AWS profile, auto-build off per branch, and deploys by hand."),
    ("digitalocean", "DigitalOcean App Platform", "Hosts", "docs/providers/digitalocean.md",
     "DigitalOcean App Platform in Deploy Center: a token, deploy_on_push off, and deploys by hand."),
    ("coolify", "Coolify", "Hosts", "docs/providers/coolify.md",
     "Coolify in Deploy Center: your instance URL and token, auto-deploy off, and deploys by hand."),
    ("ci", "Deploy from CI", "Using it", "examples/README.md",
     "Run the deploys CLI without a Mac: a daily deploy from GitHub Actions, the environment variables it needs."),
    ("uninstall", "Uninstall", "Using it", "docs/UNINSTALL.md",
     "Remove Deploy Center, its Render key, its settings and its scheduled jobs from your Mac."),
    ("numbers", "Numbers explained", "Reference", "docs/NUMBERS.md",
     "How Deploy Center counts changed projects, commits waiting, PRs waiting and open pull requests."),
    ("glossary", "Glossary", "Reference", "docs/GLOSSARY.md",
     "Auto-deploy, Git connection, Ignored Build Step, Blueprint, deploy hook and the other words used in Deploy Center."),
    ("faq", "FAQ", "Reference", "docs/FAQ.md",
     "Short answers: cost, privacy, where the Render key is stored, GitLab, Linux, monorepos, builds that still run."),
    ("troubleshooting", "Troubleshooting", "Reference", "docs/TROUBLESHOOTING.md",
     "The error messages of Deploy Center and the deploys CLI, word for word, and what to do about each."),
    ("providers", "Adding a host", "Reference", "docs/PROVIDERS.md",
     "How a platform plugs into deploys: one file in providers/, its functions, its metadata and the contract tests."),
    ("verify", "Verify a release", "Reference", "integrations/VERIFY.md",
     "Check a Deploy Center release before you open it: SHA-256, codesign and Gatekeeper."),
    ("integrations", "Overview", "Integrations", "integrations/README.md",
     "Add-ons around the deploys CLI: GitHub Action, status badges, daily summary, pre-push hook, MCP server and Docker image."),
]
# integrations/<name>/README.md: known ones get a label and description; any other folder with a
# README is added under its own H1.
INTEGRATIONS = {
    "action": ("GitHub Action", "A GitHub Action that lists what has changes with deploys changed --json, and deploys only with deploy: true."),
    "badge": ("Status badges", "SVG status badges per project, such as deployed 3 d ago, 4 commits waiting. No server needed."),
    "notify": ("Daily summary", "A daily live today / waiting summary to Discord, Slack, ntfy or Telegram."),
    "statuspage": ("Status page", "A static what-shipped-when page with an Atom feed and status.json, for any static host."),
    "hooks": ("pre-push hook", "A git pre-push hook that warns how many Vercel and Render builds a push would start."),
    "mcp": ("MCP server", "An MCP server for Claude Code, Claude Desktop, Cursor and VS Code: what is waiting, release notes, logs, and opt-in deploys."),
    "docker": ("Docker image", "A Linux image with the deploys CLI and its tools, for CI."),
    "claude-code": ("Claude Code plugin", "A Claude Code plugin: the MCP server, a skill, commands and a push hook, so Claude knows how deploys work."),
    "digest": ("Agent digest", "Once a day, what coding agents pushed per project, with a one-click approval through a GitHub workflow."),
    "raycast": ("Raycast extension", "See which projects have commits waiting and deploy them by hand, from Raycast."),
    "vscode": ("VS Code extension", "What is merged but not live, and a deploy by hand, inside VS Code, Cursor and Windsurf."),
}
INTEGRATION_ORDER = ["action", "badge", "statuspage", "notify", "hooks", "mcp", "claude-code", "digest",
                     "raycast", "vscode", "docker"]
GROUPS = ["Start", "Using it", "Hosts", "Reference", "Integrations"]
# CLI help lines without a description of their own.
MISSING = {
    "deploys --help | --version": "this help, or the version",
    "deploys render autodeploy-off <s>|--all": "set auto-deploy to Off for one service, or all",
}
# README sections that make up Getting started.
# The first one must exist; the others are taken when they are there.
README_SECTIONS = ["Install", "How it works", "What it changes, and how to undo it",
                   "Requirements", "Connect your accounts", "Good to know"]


class BuildError(Exception):
    pass


# ---------------------------------------------------------------- git

def git(*args):
    try:
        return subprocess.run(["git", *args], cwd=ROOT, capture_output=True, text=True, check=True).stdout.strip()
    except (OSError, subprocess.CalledProcessError):
        return ""


TODAY = datetime.date.today().isoformat()


def last_updated(path):
    return git("log", "-1", "--format=%cs", "--", path) or TODAY


def first_published(path):
    out = git("log", "--diff-filter=A", "--follow", "--format=%cs", "--", path)
    return out.splitlines()[-1] if out else last_updated(path)


# ---------------------------------------------------------------- markdown

def slugify(text, seen):
    """GitHub's heading ids: lower case, drop punctuation, spaces to hyphens, -1/-2 for repeats."""
    s = re.sub(r"[^\w\- ]", "", text.strip().lower()).replace(" ", "-")
    base, n = s, 1
    while s in seen:
        s = f"{base}-{n}"
        n += 1
    seen.add(s)
    return s


def plain(md):
    """Markdown inline -> plain text (for ids, the TOC, search and descriptions)."""
    s = re.sub(r"`([^`]*)`", r"\1", md)
    s = re.sub(r"!?\[([^\]]*)\]\([^)]*\)", r"\1", s)
    s = re.sub(r"\*\*(.+?)\*\*", r"\1", s)
    s = re.sub(r"(?<![\w*])\*(\S(?:.*?\S)?)\*(?![\w*])", r"\1", s)
    s = re.sub(r"(?<!\w)_(\S(?:.*?\S)?)_(?!\w)", r"\1", s)
    return s.replace("\\|", "|")


LIST_RE = re.compile(r"^( *)([-*+]|\d+[.)]) +(.*)$")
FENCE_RE = re.compile(r"^( *)(```+|~~~+)\s*([\w+-]*)")


class Converter:
    """One Markdown file -> HTML. link(url) rewrites link targets; headings are collected."""

    def __init__(self, link):
        self.link = link
        self.headings = []      # (level, id, text)
        self.seen = set()
        self.h1 = None

    # inline
    def inline(self, s):
        codes = []

        def keep(m):
            codes.append("<code>" + html.escape(m.group(2).strip() if m.group(2).strip() else m.group(2)) + "</code>")
            return f"\x00{len(codes) - 1}\x00"

        s = re.sub(r"(`+)(.+?)\1", keep, s)
        s = html.escape(s, quote=False)

        def link(m):
            text, url = m.group(1), html.unescape(m.group(2))
            href = self.link(url)
            # [NUMBERS.md](NUMBERS.md) reads like GitHub; on the site the page title says more
            label = PAGE_LABELS.get(href.split("#")[0])
            if label and re.fullmatch(r"[\w./-]+(\.md|/)", text):
                text = html.escape(label, quote=False)
            ext = href.startswith("http") and not href.startswith(BASE)
            attrs = ' rel="noopener"' if ext else ""
            return f'<a href="{html.escape(href)}"{attrs}>{text}</a>'

        s = re.sub(r"\[([^\]]+)\]\(([^)\s]+)(?:\s+&quot;[^&]*&quot;)?\)", link, s)
        s = re.sub(r"\*\*(.+?)\*\*", r"<strong>\1</strong>", s)
        s = re.sub(r"(?<![\w*])\*(\S(?:.*?\S)?)\*(?![\w*])", r"<em>\1</em>", s)
        s = re.sub(r"(?<![\w\x00])_(\S(?:.*?\S)?)_(?![\w\x00])", r"<em>\1</em>", s)
        s = s.replace("\\|", "|")
        return re.sub(r"\x00(\d+)\x00", lambda m: codes[int(m.group(1))], s)

    # blocks
    def convert(self, text):
        return self.blocks(text.replace("\t", "    ").split("\n"))

    def blocks(self, lines):
        out, i, n = [], 0, len(lines)
        while i < n:
            line = lines[i]
            if not line.strip():
                i += 1
                continue
            if line.lstrip().startswith("<!--"):  # HTML comment: not rendered, links not checked
                while i < n and "-->" not in lines[i]:
                    i += 1
                i += 1
                continue
            m = FENCE_RE.match(line)
            if m:
                ind, fence, lang = len(m.group(1)), m.group(2), m.group(3)
                body, i = [], i + 1
                while i < n and not lines[i].strip().startswith(fence[:3]):
                    body.append(lines[i][ind:] if lines[i][:ind].strip() == "" else lines[i])
                    i += 1
                i += 1
                cls = f' class="language-{lang}"' if lang else ""
                label = f' data-lang="{lang}"' if lang and lang != "text" else ""
                out.append(f'<div class="code"{label}><pre><code{cls}>{html.escape(chr(10).join(body), quote=False)}</code></pre></div>')
                continue
            m = re.match(r"^(#{1,6}) +(.*?)\s*#*\s*$", line)
            if m:
                out.append(self.heading(len(m.group(1)), m.group(2)))
                i += 1
                continue
            if re.match(r"^ {0,3}([-*_])( *\1){2,} *$", line):
                out.append("<hr>")
                i += 1
                continue
            if line.lstrip().startswith("|") and i + 1 < n and re.match(r"^\s*\|?\s*:?-+:?\s*(\|\s*:?-+:?\s*)*\|?\s*$", lines[i + 1]):
                rows, i = [line], i + 2
                while i < n and lines[i].lstrip().startswith("|"):
                    rows.append(lines[i])
                    i += 1
                out.append(self.table(rows))
                continue
            if line.lstrip().startswith(">"):
                quote = []
                while i < n and lines[i].lstrip().startswith(">"):
                    quote.append(re.sub(r"^\s*> ?", "", lines[i]))
                    i += 1
                out.append("<blockquote>" + self.blocks(quote) + "</blockquote>")
                continue
            if LIST_RE.match(line):
                html_, i = self.list_(lines, i)
                out.append(html_)
                continue
            para = []
            while i < n and lines[i].strip() and not self.starts_block(lines[i]):
                para.append(lines[i].strip())
                i += 1
            out.append("<p>" + self.inline("\n".join(para)) + "</p>")
        return "\n".join(out)

    @staticmethod
    def starts_block(line):
        return bool(FENCE_RE.match(line) or re.match(r"^#{1,6} ", line) or line.lstrip().startswith(">")
                    or LIST_RE.match(line) or line.lstrip().startswith("|"))

    def heading(self, level, md):
        text = plain(md)
        if level == 1 and self.h1 is None:
            self.h1 = text
            return ""  # the page template prints the H1
        hid = slugify(text, self.seen)
        if level in (2, 3):
            self.headings.append((level, hid, text))
        return (f'<h{level} id="{hid}">{self.inline(md)}'
                f'<a class="anchor" href="#{hid}" aria-label="Link to this section">#</a></h{level}>')

    def table(self, rows):
        def cells(row):
            row = row.strip()
            row = row[1:] if row.startswith("|") else row
            row = row[:-1] if row.endswith("|") and not row.endswith("\\|") else row
            return [c.strip() for c in re.split(r"(?<!\\)\|", row)]

        # \| is a pipe inside a cell, also inside `code`
        head, body = cells(rows[0]), [cells(r) for r in rows[1:]]
        head = [c.replace("\\|", "|") for c in head]
        body = [[c.replace("\\|", "|") for c in r] for r in body]
        h = "".join(f"<th>{self.inline(c)}</th>" for c in head)
        b = "".join("<tr>" + "".join(f"<td>{self.inline(c)}</td>" for c in r) + "</tr>" for r in body)
        thead = f"<thead><tr>{h}</tr></thead>" if any(head) else ""  # | | | has no header to show
        return f'<div class="tablewrap"><table>{thead}<tbody>{b}</tbody></table></div>'

    def list_(self, lines, i):
        m = LIST_RE.match(lines[i])
        base = len(m.group(1))
        ordered = m.group(2)[0].isdigit()
        start = int(m.group(2)[:-1]) if ordered else 1
        items, n = [], len(lines)
        while i < n:
            m = LIST_RE.match(lines[i])
            if not m or len(m.group(1)) != base or m.group(2)[0].isdigit() != ordered:
                break
            indent = len(m.group(1)) + len(m.group(2)) + 1
            item, i = [m.group(3)], i + 1
            while i < n:
                l = lines[i]
                if not l.strip():
                    # a blank line ends the item unless the next line is indented into it
                    if i + 1 < n and lines[i + 1].strip() and len(lines[i + 1]) - len(lines[i + 1].lstrip()) >= indent:
                        item.append("")
                        i += 1
                        continue
                    break
                ind = len(l) - len(l.lstrip())
                if ind >= indent or (ind > base and LIST_RE.match(l)):
                    item.append(l[min(ind, indent):])
                elif LIST_RE.match(l) or self.starts_block(l):
                    break
                else:
                    item.append(l.strip())  # lazy continuation
                i += 1
            body = self.blocks(item)
            if body.startswith("<p>") and body.count("<p>") == 1:
                body = body[3:].replace("</p>", "", 1)  # tight item
            items.append(f"<li>{body}</li>")
            # a blank line between items of the same list does not end it
            if i < n and not lines[i].strip() and i + 1 < n:
                nm = LIST_RE.match(lines[i + 1])
                if nm and len(nm.group(1)) == base and nm.group(2)[0].isdigit() == ordered:
                    i += 1
        tag = "ol" if ordered else "ul"
        st = f' start="{start}"' if ordered and start != 1 else ""
        return f"<{tag}{st}>" + "".join(items) + f"</{tag}>", i


# ---------------------------------------------------------------- pages

class Page:
    def __init__(self, slug, label, group, source, description):
        self.slug, self.label, self.group, self.source, self.description = slug, label, group, source, description
        self.url = f"/docs/{slug}/"
        self.title = label
        self.body = ""
        self.headings = []
        self.faq = []        # (question, answer text) for FAQPage


def page_list():
    pages = [Page(*p) for p in PAGES]
    names = sorted(d for d in os.listdir(os.path.join(ROOT, "integrations"))
                   if os.path.isfile(os.path.join(ROOT, "integrations", d, "README.md")))
    names.sort(key=lambda d: (INTEGRATION_ORDER.index(d) if d in INTEGRATION_ORDER else 99, d))
    for d in names:
        label, desc = INTEGRATIONS.get(d, (None, None))
        pages.append(Page(f"integrations/{d}", label or d, "Integrations", f"integrations/{d}/README.md", desc or ""))
    return pages


def link_rewriter(source, by_source, anchors_of):
    """Return link(url) for Markdown in `source`: docs pages for converted files, GitHub otherwise."""
    src_dir = posixpath.dirname(source)

    def link(url):
        if re.match(r"^[a-z][a-z0-9+.-]*:", url) or url.startswith("//"):
            return url
        path, _, frag = url.partition("#")
        if not path:
            if source == "README.md" and frag and frag not in anchors_of("README.md"):
                return f"{REPO}/blob/{BRANCH}/README.md#{frag}"
            return "#" + frag
        target = posixpath.normpath(posixpath.join(src_dir, path))
        if target.startswith(".."):
            raise BuildError(f"{source}: link {url!r} points outside the repo")
        full = os.path.join(ROOT, target)
        if not os.path.exists(full):
            raise BuildError(f"{source}: link {url!r} -> {target} does not exist")
        is_dir = os.path.isdir(full)
        key = target + "/README.md" if is_dir else target
        key = key[2:] if key.startswith("./") else key
        page = by_source.get(key)
        if page and (page.source != "README.md" or not frag or frag in anchors_of("README.md")):
            return page.url + (f"#{frag}" if frag else "")
        kind = "tree" if is_dir else "blob"
        return f"{REPO}/{kind}/{BRANCH}/{target}" + (f"#{frag}" if frag else "")

    return link


def readme_part(text):
    """Getting started: the README's pitch and its install / setup sections."""
    parts, cur = {}, None
    for line in text.split("\n"):
        m = re.match(r"^## (.*)$", line)
        if m:
            cur = m.group(1).strip()
            parts[cur] = []
        elif cur:
            # <details><summary>X</summary> folds text on GitHub; on the site it is a sub-heading
            if re.match(r"^\s*</?details>\s*$", line):
                continue
            line = re.sub(r"^\s*<summary>(.*?)</summary>\s*$", r"### \1", line)
            parts[cur].append(line)
    sections = [s for s in README_SECTIONS if s in parts]
    if README_SECTIONS[0] not in parts:
        raise BuildError(f"README.md: no '## {README_SECTIONS[0]}' section for Getting started "
                         f"(update README_SECTIONS in scripts/build-docs.py)")
    pitch = re.search(r"<p[^>]*>\s*<b>([^<]*)</b>\s*<br>(.*?)</p>", text, re.S)
    lead = ""
    if pitch:
        rest = re.sub(r"\s+", " ", re.sub(r"<[^>]+>", " ", pitch.group(2))).strip()
        lead = f"**{pitch.group(1).strip()}** {rest}\n\n"
    md = "# Getting started\n\n" + lead
    for s in sections:
        md += f"## {s}\n" + "\n".join(parts[s]) + "\n"
    md += ("## Next steps\n\n- [Try it safely](docs/SAFE-START.md): look first, then one project, then all\n"
           "- [CLI reference](docs/CLI.md): every `deploys` command\n"
           "- [Troubleshooting](docs/TROUBLESHOOTING.md) when a message is unclear\n")
    return md, ["Next steps"] + sections


def help_commands():
    """The command list of `deploys --help`, as Markdown tables per platform."""
    try:
        out = subprocess.run(["bash", os.path.join(ROOT, "deploys"), "--help"], cwd=ROOT,
                             capture_output=True, text=True, timeout=30, check=True).stdout
    except (OSError, subprocess.SubprocessError) as e:
        raise BuildError(f"deploys --help failed: {e}")
    m = re.search(r"^Commands:\n(.*?)(?=^\S|\Z)", out, re.S | re.M)
    if not m:
        raise BuildError("deploys --help: no Commands: section")
    body = m.group(1).split("\n")
    # the column where descriptions start; a command that runs up to it has one space only
    starts = [m.end(1) + len(m.group(2)) for m in (re.match(r"^(  deploys \S.*?)( {2,})\S", l) for l in body) if m]
    col = max(set(starts), key=starts.count) if starts else 0
    rows = []
    for line in body:
        if not line.strip():
            continue
        m = re.match(r"^  (deploys \S.*?)(?: {2,}(\S.*))?$", line)
        if m and not m.group(2) and col and len(line) > col and line[col - 1] == " " and line[col] != " ":
            rows.append([line[:col].strip(), line[col:].strip()])
        elif m and not line.startswith("   "):
            rows.append([m.group(1).strip(), (m.group(2) or "").strip() or MISSING.get(m.group(1).strip(), "")])
        elif rows:
            rows[-1][1] = (rows[-1][1] + " " + line.strip()).strip()
    if not rows:
        raise BuildError("deploys --help: no commands found")
    groups = {"General": [], "Vercel": [], "Render": [], "Autofix": []}
    for cmd, desc in rows:
        groups[{"vercel": "Vercel", "render": "Render", "autofix": "Autofix"}.get(cmd.split()[1], "General")].append((cmd, desc))
    md = ["## All commands", "",
          "Generated from `deploys --help`, so it always matches the script.", ""]
    for g, items in groups.items():
        if not items:
            continue
        md += [f"### {g} commands", "", "| Command | What it does |", "|---|---|"]
        for cmd, desc in items:
            desc = desc.replace("docs/AUTOFIX.md", "[Autofix](AUTOFIX.md)")  # relative to docs/CLI.md
            md.append(f"| `{cmd.replace('|', chr(92) + '|')}` | {desc.replace('|', chr(92) + '|')} |")
        md.append("")
    return "\n".join(md)


PAGE_LABELS = {}


def build_pages(pages):
    by_source = {p.source: p for p in pages}
    PAGE_LABELS.update({p.url: p.label for p in pages})
    # Getting started has only some README sections; links to the others go to GitHub.
    gs_ids = set()
    anchors = lambda src: gs_ids if src == "README.md" else None
    for p in pages:
        src_for_links = p.source
        text = open(os.path.join(ROOT, p.source), encoding="utf-8").read()
        if p.source == "README.md":
            md, kept = readme_part(text)
            gs_ids.update(slugify(plain(k), set()) for k in kept)
        elif p.slug == "cli":
            md = text.rstrip("\n") + "\n\n" + help_commands() + "\n"
            p.dates_from = [p.source, "deploys"]
        else:
            md = text
        conv = Converter(link_rewriter(src_for_links, by_source, anchors))
        p.body = conv.convert(md)
        p.headings = conv.headings
        p.title = conv.h1 or p.label
        if not p.description:
            m = re.search(r"<p>(.*?)</p>", p.body, re.S)
            p.description = re.sub(r"<[^>]+>", "", html.unescape(m.group(1))) if m else p.title
        if p.slug == "faq":
            for q, a in re.findall(r'<h3 id="[^"]*">(.*?)<a class="anchor".*?</h3>\s*(.*?)(?=<h[23] |\Z)', p.body, re.S):
                text = lambda s: re.sub(r"\s+", " ", html.unescape(re.sub(r"<[^>]+>", "", s))).strip()
                p.faq.append((text(q), text(a)))
        srcs = getattr(p, "dates_from", [p.source])
        p.updated = max(last_updated(x) for x in srcs)
        p.published = min(first_published(x) for x in srcs)


# ---------------------------------------------------------------- html

def esc(s):
    return html.escape(s, quote=True)


def sidebar(pages, current):
    out = []
    for g in GROUPS:
        items = [p for p in pages if p.group == g]
        if not items:
            continue
        out.append(f'<p class="group">{esc(g)}</p><ul>')
        for p in items:
            cur = ' aria-current="page"' if p is current else ""
            out.append(f'<li><a href="{p.url}"{cur}>{esc(p.label)}</a></li>')
        out.append("</ul>")
    return "\n".join(out)


def toc(page):
    if len(page.headings) < 2:
        return ""
    items = "".join(f'<li class="l{lvl}"><a href="#{hid}">{esc(text)}</a></li>' for lvl, hid, text in page.headings)
    return (f'<details class="toc" id="toc" open><summary>On this page</summary>'
            f'<nav aria-label="On this page"><p class="group">On this page</p><ul>{items}</ul></nav></details>')


def jsonld(page, crumbs):
    url = BASE + page.url
    org = {"@type": "Organization", "name": "Deploy Center", "url": BASE + "/", "logo": BASE + "/img/icon-192.png"}
    data = [{
        "@context": "https://schema.org",
        "@type": "TechArticle" if page.slug != "" else "CollectionPage",
        "headline": page.title,
        "name": page.title,
        "description": page.description,
        "url": url,
        "mainEntityOfPage": url,
        "inLanguage": "en",
        "datePublished": page.published,
        "dateModified": page.updated,
        "author": org,
        "publisher": org,
        "isPartOf": {"@type": "WebSite", "name": "Deploy Center", "url": BASE + "/"},
        "about": {"@type": "SoftwareApplication", "name": "Deploy Center", "operatingSystem": "macOS",
                  "applicationCategory": "DeveloperApplication", "url": BASE + "/"},
    }, {
        "@context": "https://schema.org",
        "@type": "BreadcrumbList",
        "itemListElement": [{"@type": "ListItem", "position": k + 1, "name": name, "item": BASE + href}
                            for k, (name, href) in enumerate(crumbs)],
    }]
    if page.faq:
        data.append({"@context": "https://schema.org", "@type": "FAQPage", "mainEntity": [
            {"@type": "Question", "name": q, "acceptedAnswer": {"@type": "Answer", "text": a}} for q, a in page.faq]})
    return json.dumps(data, ensure_ascii=False).replace("</", "<\\/")


def render(page, pages, assets):
    crumbs = [("Home", "/"), ("Docs", "/docs/")]
    if page.slug:
        if page.group == "Integrations" and page.slug != "integrations":
            crumbs.append(("Integrations", "/docs/integrations/"))
        crumbs.append((page.label if page.slug != "integrations" else "Integrations", page.url))
    crumb_html = " ".join(
        (f'<li><a href="{h}">{esc(n)}</a></li>' if k < len(crumbs) - 1 else f'<li aria-current="page">{esc(n)}</li>')
        for k, (n, h) in enumerate(crumbs))
    title = f"{page.title} · Deploy Center docs" if page.slug else "Deploy Center docs"
    edit = (f' · <a href="{REPO}/edit/{BRANCH}/{page.source}" rel="noopener">Edit on GitHub</a>'
            if page.source else "")
    ud = datetime.date.fromisoformat(page.updated)
    updated = f"{ud:%B} {ud.day}, {ud.year}"  # not %-d: Windows has no such flag
    toc_html = toc(page)
    return f"""<!doctype html>
<html lang="en">
<head>
<meta charset="utf-8">
<meta name="viewport" content="width=device-width, initial-scale=1">
<title>{esc(title)}</title>
<meta name="description" content="{esc(page.description)}">
<meta name="color-scheme" content="dark light">
<meta name="theme-color" content="#0b0d12" media="(prefers-color-scheme: dark)">
<meta name="theme-color" content="#fbfbfd" media="(prefers-color-scheme: light)">
<link rel="canonical" href="{BASE}{page.url}">
<meta property="og:type" content="article">
<meta property="og:site_name" content="Deploy Center">
<meta property="og:title" content="{esc(page.title)}">
<meta property="og:description" content="{esc(page.description)}">
<meta property="og:url" content="{BASE}{page.url}">
<meta property="og:image" content="{BASE}/img/og.png">
<meta property="og:image:type" content="image/png">
<meta property="og:image:width" content="1200">
<meta property="og:image:height" content="630">
<meta property="og:image:alt" content="{OG_ALT}">
<meta property="og:locale" content="en_US">
<meta property="article:modified_time" content="{page.updated}">
<meta name="twitter:card" content="summary_large_image">
<meta name="twitter:title" content="{esc(page.title)}">
<meta name="twitter:description" content="{esc(page.description)}">
<meta name="twitter:image" content="{BASE}/img/og.png">
<meta name="twitter:image:alt" content="{OG_ALT}">
<link rel="icon" href="/img/icon-32.png" sizes="32x32" type="image/png">
<link rel="apple-touch-icon" href="/img/apple-touch-icon.png">
<link rel="stylesheet" href="/docs/assets/docs.css?v={assets["docs.css"]}">
<script>document.documentElement.classList.add('js');try{{var t=localStorage.getItem('theme');if(t==='light'||t==='dark')document.documentElement.setAttribute('data-theme',t)}}catch(e){{}}</script>
<script type="application/ld+json">{jsonld(page, crumbs)}</script>
</head>
<body>
<a class="skip" href="#content">Skip to content</a>
<header class="top"><div class="bar">
  <a class="brand" href="/"><img src="/img/icon-64.png" alt="" width="26" height="26">Deploy Center</a>
  <a class="section" href="/docs/">Docs</a>
  <div class="search" role="search">
    <label class="sr" for="q">Search the docs</label>
    <input id="q" type="search" placeholder="Search docs" autocomplete="off" spellcheck="false" aria-controls="results" aria-expanded="false">
    <kbd>/</kbd>
    <ul id="results" role="listbox" hidden></ul>
  </div>
  <a class="nav" href="/guides/">Guides</a>
  <a class="gh" href="{REPO}" rel="noopener">GitHub<span aria-hidden="true"> ★</span></a>
  <a class="dl" href="{REPO}/releases/latest">Download</a>
</div></header>
<div class="layout">
<aside class="side"><details id="sidenav" open><summary>Docs menu</summary>
<nav aria-label="Docs">
<p class="group"><a href="/docs/"{' aria-current="page"' if not page.slug else ''}>Docs home</a></p>
{sidebar(pages, page)}
</nav></details></aside>
<div class="head">
<nav aria-label="Breadcrumb"><ol class="crumbs">{crumb_html}</ol></nav>
<h1>{esc(page.title)}</h1>
<p class="meta">Last updated <time datetime="{page.updated}">{updated}</time>{edit}</p>
</div>
{toc_html}
<main id="content" class="prose">
{page.body}
</main>
</div>
<footer><div class="bar">
  <span>Deploy Center · MIT · <a href="/">deploycenter.app</a></span>
  <span><a href="{REPO}/blob/{BRANCH}/CHANGELOG.md" rel="noopener">Changelog</a> · <a href="{REPO}/issues" rel="noopener">Issues</a> · <a href="/impressum.html">Impressum</a> · <a href="/datenschutz.html">Datenschutz</a> </span>
  <span class="fine">{esc(TRADEMARKS)}</span>
</div></footer>
<script src="/docs/assets/docs.js?v={assets["docs.js"]}" defer></script>
</body>
</html>
"""


def index_page(pages):
    p = Page("", "Docs", "", "", "Documentation for Deploy Center, the free Mac app and deploys CLI that turn off "
             "auto-deploy on Vercel and Render and deploy what changed when you decide.")
    p.url = "/docs/"
    p.title = "Deploy Center docs"
    p.updated = max(x.updated for x in pages)
    p.published = min(x.published for x in pages)
    body = ['<p class="lead">Deploy Center turns off auto-deploy on Vercel and Render and deploys what changed when you '
            'decide: a Mac app, and the <code>deploys</code> CLI it runs, which also works on Linux and in CI.</p>']
    for g in GROUPS:
        items = [x for x in pages if x.group == g]
        hid = slugify(g, set())
        p.headings.append((2, hid, g))
        body.append(f'<h2 id="{hid}">{esc(g)}<a class="anchor" href="#{hid}" aria-label="Link to this section">#</a></h2>'
                    '<div class="cards">')
        for x in items:
            body.append(f'<a class="cardlink" href="{x.url}"><b>{esc(x.label)}</b><span>{esc(x.description)}</span></a>')
        body.append("</div>")
    p.body = "\n".join(body)
    return p


def search_index(pages):
    """One entry per page and per h2/h3 section: title, heading, url, a bit of text."""
    entries = []
    for p in pages:
        parts = re.split(r'(<h[23] id="[^"]+">.*?</h[23]>)', p.body, flags=re.S)
        head, hid = None, None
        for part in parts:
            m = re.match(r'<h[23] id="([^"]+)">(.*?)<a class="anchor"', part, re.S)
            if m:
                hid, head = m.group(1), html.unescape(re.sub(r"<[^>]+>", "", m.group(2)))
                continue
            text = re.sub(r"\s+", " ", html.unescape(re.sub(r"<[^>]+>", " ", part))).strip()
            if not text and not head:
                continue
            entries.append({"p": p.title if p.slug else "Docs", "h": head or "", "u": p.url + (f"#{hid}" if hid else ""),
                            "t": text[:600]})
    return entries


def sync_hand_dates():
    """The pages in site/ written by hand: their <lastmod> in sitemap.xml and the "dateModified"
    of their JSON-LD come from the last commit of the file, so neither is kept up by hand."""
    path = os.path.join(SITE, "sitemap.xml")
    if not os.path.exists(path):
        return
    text = open(path, encoding="utf-8").read()

    def date_of(url_path):
        rel = os.path.join("site", url_path.strip("/"), "index.html")
        return last_updated(rel) if os.path.isfile(os.path.join(ROOT, rel)) else None

    def fix(m):
        if m.group(2).startswith("/docs/"):
            return m.group(0)
        d = date_of(m.group(2))
        if not d:
            return m.group(0)
        page = os.path.join(ROOT, "site", m.group(2).strip("/"), "index.html")
        html_text = open(page, encoding="utf-8").read()
        new = re.sub(r'("dateModified":\s*")\d{4}-\d\d-\d\d"', r"\g<1>" + d + '"', html_text)
        # and the visible "Last updated", so it says the same as the JSON-LD
        day = datetime.date.fromisoformat(d)
        new = re.sub(r'(Last updated )<time datetime="[^"]*">[^<]*</time>',
                     lambda m: f'{m.group(1)}<time datetime="{d}">{day.day} {day:%B} {day.year}</time>', new)
        if new != html_text:
            with open(page, "w", encoding="utf-8") as f:
                f.write(new)
        return f"{m.group(1)}{m.group(2)}</loc><lastmod>{d}</lastmod>"

    new = re.sub(r"(<url><loc>" + re.escape(BASE) + r")(/[^<]*)</loc><lastmod>[^<]*</lastmod>", fix, text)
    if new != text:
        with open(path, "w", encoding="utf-8") as f:
            f.write(new)


def update_sitemap(urls):
    """Replace the docs block in site/sitemap.xml (between markers), leave everything else."""
    path = os.path.join(SITE, "sitemap.xml")
    block = "  <!-- docs: written by scripts/build-docs.py -->\n" + "".join(
        f"  <url><loc>{BASE}{u}</loc><lastmod>{d}</lastmod></url>\n" for u, d in urls) + "  <!-- /docs -->\n"
    if not os.path.exists(path):
        text = '<?xml version="1.0" encoding="UTF-8"?>\n<urlset xmlns="http://www.sitemaps.org/schemas/sitemap/0.9">\n</urlset>\n'
    else:
        text = open(path, encoding="utf-8").read()
    text = re.sub(r"  <!-- docs: written by scripts/build-docs.py -->\n.*?  <!-- /docs -->\n", "", text, flags=re.S)
    # also drop docs URLs someone added by hand, so none is listed twice
    text = re.sub(r"  <url><loc>" + re.escape(BASE) + r"/docs/[^<]*</loc>.*?</url>\n", "", text)
    if "</urlset>" not in text:
        raise BuildError("site/sitemap.xml has no </urlset>")
    text = text.replace("</urlset>", block + "</urlset>", 1)
    with open(path, "w", encoding="utf-8") as f:
        f.write(text)


VERSION_RE = r"\d+\.\d+\.\d+"


def appcast_enclosure(version):
    """(url, length) of the enclosure of <version> in site/appcast.xml, or (None, 0)."""
    path = os.path.join(SITE, "appcast.xml")
    if not os.path.exists(path):
        return None, 0
    for item in re.findall(r"<item>(.*?)</item>", open(path, encoding="utf-8").read(), re.S):
        if f"<sparkle:shortVersionString>{version}</sparkle:shortVersionString>" not in item:
            continue
        m = re.search(r'<enclosure url="(https://[^"]+)" length="(\d+)"', item)
        if m:
            return m.group(1), int(m.group(2))
    return None, 0


def sync_site_version(version):
    """Put VERSION into site/index.html: the line under the download button and the JSON-LD.

    scripts/bump.sh does the same, but only from the previous version; this catches any drift.
    """
    if not re.fullmatch(VERSION_RE, version):
        raise BuildError(f"VERSION is not x.y.z: {version!r}")
    path = os.path.join(SITE, "index.html")
    if not os.path.exists(path):
        return
    text = open(path, encoding="utf-8").read()
    new, n1 = re.subn(r'("softwareVersion":\s*")' + VERSION_RE + '"', r"\g<1>" + version + '"', text)
    new, n2 = re.subn(r'(id="version">Version )' + VERSION_RE, r"\g<1>" + version, new)
    if not (n1 and n2):
        raise BuildError("site/index.html: softwareVersion or the Version line is missing")
    # downloadUrl and fileSize in the JSON-LD: the zip of this version, as site/appcast.xml lists it.
    # Before the release is in the appcast, they keep pointing at the previous one.
    zip_url, size = appcast_enclosure(version)
    if zip_url:
        new = re.sub(r'("downloadUrl":\s*")[^"]*"', lambda m: m.group(1) + zip_url + '"', new, count=1)
        mb = f"{size / 1_000_000:.1f} MB"
        if re.search(r'"fileSize":\s*"', new):
            new = re.sub(r'("fileSize":\s*")[^"]*"', lambda m: m.group(1) + mb + '"', new, count=1)
        else:
            new = re.sub(r'("downloadUrl":\s*"[^"]*")', lambda m: m.group(1) + f', "fileSize": "{mb}"', new, count=1)
    if new != text:
        with open(path, "w", encoding="utf-8") as f:
            f.write(new)
        print(f"build-docs: site/index.html now says version {version}")
    path = os.path.join(SITE, "llms.txt")
    if os.path.exists(path):
        text = open(path, encoding="utf-8").read()
        new, n = re.subn(r"(^- Version: )" + VERSION_RE, r"\g<1>" + version, text, flags=re.M)
        if not n:
            raise BuildError("site/llms.txt: the line '- Version: x.y.z' is missing")
        if new != text:
            with open(path, "w", encoding="utf-8") as f:
                f.write(new)
            print(f"build-docs: site/llms.txt now says version {version}")


def llms_full(pages, version):
    """Every docs page as plain text in one file, for AI assistants (llms.txt points here)."""
    out = [f"# Deploy Center documentation (version {version})", "",
           f"> All pages of {BASE}/docs/ as plain text. Generated by scripts/build-docs.py.", ""]
    for p in pages:
        text = re.sub(r"<pre[^>]*>(.*?)</pre>", lambda m: "\n```\n" + m.group(1) + "\n```\n", p.body, flags=re.S)
        text = re.sub(r'<a class="anchor"[^>]*>#</a>', "", text)
        text = re.sub(r"<h([1-6])[^>]*>", lambda m: "\n" + "#" * (int(m.group(1)) + 1) + " ", text)
        text = re.sub(r"<li[^>]*>", "\n- ", text)
        text = re.sub(r"</(p|h[1-6]|tr|ul|ol|blockquote|table)>", "\n", text)
        text = re.sub(r"</t[dh]>", " | ", text)
        text = html.unescape(re.sub(r"<[^>]+>", "", text))
        text = re.sub(r"\n{3,}", "\n\n", text).strip()
        out += [f"## {p.title}", "", f"URL: {BASE}{p.url}", "", text, ""]
    return "\n".join(out)


def main():
    pages = page_list()
    build_pages(pages)
    index = index_page(pages)
    version = (open(os.path.join(ROOT, "VERSION")).read().strip() if os.path.exists(os.path.join(ROOT, "VERSION")) else "0")
    if version != "0":
        sync_site_version(version)
    # ?v= changes only when the file does, so browsers keep the cached copy across commits
    assets = {name: hashlib.sha256(open(os.path.join(ASSETS, name), "rb").read()).hexdigest()[:10]
              for name in ("docs.css", "docs.js")}
    if os.path.isdir(OUT):
        shutil.rmtree(OUT)
    os.makedirs(os.path.join(OUT, "assets"))
    for name in os.listdir(ASSETS):
        shutil.copy(os.path.join(ASSETS, name), os.path.join(OUT, "assets", name))
    for p in [index] + pages:
        d = os.path.join(OUT, p.slug)
        os.makedirs(d, exist_ok=True)
        with open(os.path.join(d, "index.html"), "w", encoding="utf-8") as f:
            f.write(render(p, pages, assets))
    with open(os.path.join(OUT, "search-index.json"), "w", encoding="utf-8") as f:
        json.dump(search_index(pages), f, ensure_ascii=False, separators=(",", ":"))
    with open(os.path.join(OUT, "llms-full.txt"), "w", encoding="utf-8") as f:
        f.write(llms_full(pages, version))
    update_sitemap([(index.url, index.updated)] + [(p.url, p.updated) for p in pages])
    sync_hand_dates()
    print(f"build-docs: {len(pages) + 1} pages in site/docs/")


if __name__ == "__main__":
    try:
        main()
    except BuildError as e:
        print(f"build-docs: {e}", file=sys.stderr)
        sys.exit(1)
