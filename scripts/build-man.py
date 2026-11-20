#!/usr/bin/env python3
"""Writes man/deploys.1, the manual page of the deploys CLI, from `deploys --help` and docs/CLI.md.

    python3 scripts/build-man.py           write man/deploys.1
    python3 scripts/build-man.py --check   exit 1 when man/deploys.1 is not what the sources say now
    man man/deploys.1                      read it (macOS; GNU man: man -l man/deploys.1)

The text is the help the script prints (commands, exit codes, config files, provider commands) and
the environment-variable table of docs/CLI.md: nothing is written twice by hand, so the page cannot
drift from them. Standard library only, no network (deploys --help reads nothing).
"""
import os
import re
import subprocess
import sys

ROOT = os.path.dirname(os.path.dirname(os.path.abspath(__file__)))
OUT = os.path.join(ROOT, "man", "deploys.1")


def esc(text):
    """roff-safe text: backslashes and hyphens escaped, no line starts with . or '."""
    text = text.replace("\\", "\\e").replace("-", "\\-")
    return "\n".join(("\\&" + l) if l[:1] in (".", "'") else l for l in text.split("\n"))


def block(text):
    return ".nf\n" + esc(text.rstrip("\n")) + "\n.fi\n"


def para(text):
    text = re.sub(r"\s+", " ", text.strip())
    return esc(text[:1].upper() + text[1:]) + "\n"


def sections(help_text):
    """Split the help on its headings ("Commands:", "Exit codes:", …): heading -> body, in order."""
    out, head, buf = {}, "", []
    for line in help_text.split("\n"):
        m = re.match(r"^(Why|Access|Commands|Exit codes|Config lives in .*|Provider commands.*|Environment.*):\s*(.*)$", line)
        if m:
            out[head] = "\n".join(buf).strip("\n")
            head, buf = m.group(1), ([m.group(2)] if m.group(2) else [])
        else:
            buf.append(line)
    out[head] = "\n".join(buf).strip("\n")
    return out


def env_rows():
    text = open(os.path.join(ROOT, "docs", "CLI.md"), encoding="utf-8").read()
    m = re.search(r"^## Environment variables\n(.*?)(?=^\*\*|^## )", text, re.S | re.M)
    rows = []
    for line in (m.group(1) if m else "").split("\n"):
        c = re.match(r"^\|\s*(`[^|]+`)\s*\|\s*(.*?)\s*\|$", line)
        if c and not set(c.group(1)) <= set("-: "):
            name = re.sub(r"[`]", "", c.group(1))
            what = re.sub(r"\[([^\]]*)\]\([^)]*\)", r"\1", c.group(2)).replace("`", "")
            rows.append((name, what))
    return rows


def man_date():
    """A date that only a release changes: SOURCE_DATE_EPOCH, else the date in the CHANGELOG heading of VERSION,
    else the pubDate of that version in the appcast (so the page does not change with every commit)."""
    import datetime
    import email.utils
    epoch = os.environ.get("SOURCE_DATE_EPOCH")
    if epoch and epoch.isdigit():
        return datetime.datetime.fromtimestamp(int(epoch), datetime.timezone.utc).strftime("%Y-%m-%d")
    version = open(os.path.join(ROOT, "VERSION"), encoding="utf-8").read().strip()
    try:
        log = open(os.path.join(ROOT, "CHANGELOG.md"), encoding="utf-8").read()
        m = re.search(r"^## \[?" + re.escape(version) + r"\]? - (\d{4}-\d{2}-\d{2})", log, re.M)
        if m:
            return m.group(1)
        feed = open(os.path.join(ROOT, "site", "appcast.xml"), encoding="utf-8").read()
        for item in re.findall(r"<item>(.*?)</item>", feed, re.S):
            if re.search(r"shortVersionString>" + re.escape(version) + "<", item):
                pub = re.search(r"<pubDate>(.*?)</pubDate>", item)
                if pub:
                    return email.utils.parsedate_to_datetime(pub.group(1)).strftime("%Y-%m-%d")
    except (OSError, TypeError, ValueError):
        pass
    return ""


def render():
    version = open(os.path.join(ROOT, "VERSION"), encoding="utf-8").read().strip()
    # With every host on, in an empty config folder: the page must not depend on the providers.json of whoever builds it.
    import glob
    import json
    import tempfile
    names = sorted(os.path.basename(f)[:-3] for f in glob.glob(os.path.join(ROOT, "providers", "*.sh")))
    with tempfile.TemporaryDirectory() as cfg:
        with open(os.path.join(cfg, "providers.json"), "w", encoding="utf-8") as f:
            json.dump({"enabled": names}, f)
        help_text = subprocess.run([os.path.join(ROOT, "deploys"), "--help"], capture_output=True, text=True,
                                   env=dict(os.environ, NO_COLOR="1", DEPLOYS_CONFIG=cfg)).stdout
    s = sections(help_text)
    intro = s.get("", "").split("\n\n")[0]
    name_line = re.sub(r"\s+", " ", intro.split("\n\n")[0]).strip()
    name_desc = name_line.split("—", 1)[1].strip().rstrip(".") if "—" in name_line else "deploy by hand"
    out = [f'.TH DEPLOYS 1 "{man_date()}" "deploys {version}" "Deploy Center"\n',
           ".SH NAME\n", f"deploys \\- {esc(name_desc)}\n",
           ".SH SYNOPSIS\n", ".B deploys\n", ".I command\n", "[options]\n",
           ".SH DESCRIPTION\n", para(name_line.split("—", 1)[-1] if "—" in name_line else name_line)]
    if s.get("Why"):
        out += [".PP\n", para(s["Why"])]
    if s.get("Access"):
        out += [".SS Access\n", block(s["Access"])]
    out += [".SH COMMANDS\n", block(s.get("Commands", ""))]
    out += [".SH EXIT STATUS\n", block(s.get("Exit codes", ""))]
    cfg = next((v for k, v in s.items() if k.startswith("Config lives in")), "")
    out += [".SH FILES\n", "In the config folder (DEPLOYS_CONFIG, default ~/.config/deploys):\n", block(cfg)]
    prov = next((v for k, v in s.items() if k.startswith("Provider commands")), "")
    if prov:
        out += [".SH PROVIDER COMMANDS\n", block(prov)]
    rows = env_rows()
    if rows:
        out.append(".SH ENVIRONMENT\n")
        for name, what in rows:
            if not what.strip():
                sys.exit(f"build-man: the environment variable {name} has no description in docs/CLI.md")
            out += [".TP\n", f".B {esc(name)}\n", esc(what) + "\n"]
    out += [".SH BUGS\n", "Report problems at https://github.com/Pschmetzer/deploy-center/issues; "
            "security problems as described in SECURITY.md in the repository.\n",
            ".SH AUTHORS\n", "Deploy Center contributors (see the repository).\n",
            ".SH LICENSE\n", "MIT.\n",
            ".SH SEE ALSO\n", "The full reference: docs/CLI.md in the repository, and https://deploycenter.app/docs/cli/\n",
            ".PP\n", ".BR jq (1),\n", ".BR curl (1),\n", ".BR gh (1)\n"]
    return "".join(out)


def main():
    text = render()
    if "--check" in sys.argv:
        have = open(OUT, encoding="utf-8").read() if os.path.exists(OUT) else ""
        if have != text:
            print("man/deploys.1 is out of date: run python3 scripts/build-man.py")
            sys.exit(1)
        print("man/deploys.1 is up to date")
        return
    os.makedirs(os.path.dirname(OUT), exist_ok=True)
    with open(OUT, "w", encoding="utf-8") as f:
        f.write(text)
    print(f"build-man: wrote {os.path.relpath(OUT, ROOT)} ({text.count(chr(10))} lines)")


if __name__ == "__main__":
    main()
