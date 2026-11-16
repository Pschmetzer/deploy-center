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


def render():
    version = open(os.path.join(ROOT, "VERSION"), encoding="utf-8").read().strip()
    help_text = subprocess.run([os.path.join(ROOT, "deploys"), "--help"], capture_output=True, text=True,
                               env=dict(os.environ, NO_COLOR="1")).stdout
    s = sections(help_text)
    intro = s.get("", "").split("\n\n")[0]
    name_line = re.sub(r"\s+", " ", intro.split("\n\n")[0]).strip()
    name_desc = name_line.split("—", 1)[1].strip().rstrip(".") if "—" in name_line else "deploy by hand"
    out = [f'.TH DEPLOYS 1 "" "deploys {version}" "Deploy Center"\n',
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
            out += [".TP\n", f".B {esc(name)}\n", esc(what) + "\n"]
    out += [".SH SEE ALSO\n", "The full reference: docs/CLI.md in the repository, and https://deploycenter.app/docs/cli/\n"]
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
