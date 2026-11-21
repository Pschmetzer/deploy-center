#!/usr/bin/env python3
"""Bash 3.2 compatibility: the CLI runs on the bash macOS ships (3.2), so deploys, lib/, providers/ and the
integration scripts must not use bash 4+ features. A static scan, no bash needed.

    python3 -I scripts/check-bash32.py [file ...]      # default: the scripts users run

A line can opt out with `# bash32-ok` (for code behind a version check). Comment lines are skipped."""
import glob
import os
import re
import sys

ROOT = os.path.dirname(os.path.dirname(os.path.abspath(__file__)))

# (pattern, what it is). Patterns run on the code part of a line.
RULES = [
    (r"\b(declare|typeset|local|export|readonly)\s+-[a-zA-Z]*[AnN]\b", "associative array or nameref (declare -A / -n)"),
    (r"(^|[;&|(\s])(mapfile|readarray)\b", "mapfile / readarray"),
    (r"\$\{[A-Za-z_][A-Za-z0-9_]*(,,?|\^\^?)[^}]*\}", "case conversion ${x,,} / ${x^^}"),
    (r"\$\{[A-Za-z_][A-Za-z0-9_]*@[QEPAaUuLK]\}", "parameter transformation ${x@Q}"),
    (r"(;;&|;&)\s*$", "case fall-through ;& / ;;&"),
    (r"&>>", "&>> redirect"),
    (r"\|&", "|& pipe"),
    (r"(^|[;&|(\s])coproc\b", "coproc"),
    (r"\[\[\s+-v\s", "[[ -v var ]]"),
    (r"\btest\s+-v\s|\[\s+-v\s", "test -v var"),
    (r"\bwait\s+-n\b", "wait -n"),
    (r"\bread\b[^|;&]*\s-[a-zA-Z]*[iN]\s", "read -i / -N"),
    (r"\bread\b[^|;&]*\s-t\s*[0-9]*\.[0-9]", "read -t with a fraction"),
    (r"\bprintf\s+(-v\s+\S+\s+)?['\"][^'\"]*%\(", "printf %(...)T is bash 4.2"),
    (r"\$(EPOCHSECONDS|EPOCHREALTIME|SRANDOM|BASHPID)\b|\$\{(EPOCHSECONDS|EPOCHREALTIME|SRANDOM|BASHPID)\}", "bash 4/5 variable"),
    (r"\$\{[A-Za-z_][A-Za-z0-9_]*\[-[0-9]+\]\}", "negative array index"),
    (r"\bshopt\s+-s\s+(globstar|lastpipe|autocd|dirspell|checkjobs|assoc_expand_once|compat\d+)", "shopt option newer than 3.2"),
    (r"\blocal\s+-\s", "local -"),
    (r"(^|\s)(\{[a-z_]+\}>|\{[a-z_]+\}<)", "named file descriptor {var}>"),
    (r"\bcompgen\s+-V\b", "compgen -V"),
]
COMPILED = [(re.compile(p), why) for p, why in RULES]


def default_files():
    pats = ["deploys", "build.sh", "release.sh", "lib/*.sh", "providers/*.sh", "scripts/*.sh",
            "integrations/*/*.sh", "integrations/lib/*.sh", "integrations/claude-code/scripts/*.sh",
            "integrations/hooks/pre-push", "badge/*.sh"]
    out = []
    for p in pats:
        out += sorted(glob.glob(os.path.join(ROOT, p)))
    return out


def code_of(line):
    """The line without a trailing comment (a # that starts a word, outside quotes)."""
    q = None
    for i, ch in enumerate(line):
        if q:
            if ch == q:
                q = None
        elif ch in "'\"":
            q = ch
        elif ch == "#" and (i == 0 or line[i - 1] in " \t;"):
            return line[:i]
    return line


def scan(path):
    bad = []
    heredoc = None
    with open(path, encoding="utf-8", errors="replace") as f:
        for n, raw in enumerate(f, 1):
            line = raw.rstrip("\n")
            if heredoc:
                if line.strip() == heredoc:
                    heredoc = None
                continue  # text, not code
            m = re.search(r"<<-?\s*(['\"]?)([A-Za-z_][A-Za-z0-9_]*)\1", line)
            if m and "<<<" not in line:
                heredoc = m.group(2)
            if line.lstrip().startswith("#") or "bash32-ok" in line:
                continue
            code = code_of(line)
            for rx, why in COMPILED:
                if rx.search(code):
                    bad.append((n, why, line.strip()))
    return bad


def main(argv):
    files = argv or default_files()
    bad = 0
    for p in files:
        for n, why, text in scan(p):
            rel = os.path.relpath(p, ROOT)
            print("check-bash32: %s:%d: %s: %s" % (rel, n, why, text[:100]), file=sys.stderr)
            bad += 1
    if bad:
        return 1
    print("check-bash32: ok (%d files)" % len(files))
    return 0


if __name__ == "__main__":
    sys.exit(main(sys.argv[1:]))
