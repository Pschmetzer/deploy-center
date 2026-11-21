#!/usr/bin/env python3
"""Secrets stay off command lines and out of traces. A static scan of the shell code users run:

  * curl with a secret header (-H "Authorization: ...", X-Api-Key ...), -u/--user, --oauth2-bearer or a
    token in the URL: the process list shows all of those. The secret goes to curl on stdin (`-K -`).
  * `security add-generic-password ... -w <value>` on the command line (use `security -i` and stdin).
  * `set -x`, `bash -x` or `xtrace` outside tests: a trace prints every expanded secret.

    python3 -I scripts/check-secrets.py [file ...]

A line can opt out with `# secrets-ok` (and a reason in the same comment). Comment lines are skipped."""
import glob
import os
import re
import sys

ROOT = os.path.dirname(os.path.dirname(os.path.abspath(__file__)))
SECRET_HDR = r"(authorization|bearer|token|api[-_]?key|x-api|cookie|secret|private-token|x-auth)"

RULES = [
    (re.compile(r"\bcurl\b[^|]*?(-H|--header)\s*[\"']?[^\"'\s]*" + SECRET_HDR, re.I), "curl with a secret header on the command line (use -K - and stdin)"),
    (re.compile(r"\bcurl\b[^|]*?\s(-u|--user|--oauth2-bearer|--proxy-user)\s"), "curl with credentials on the command line"),
    (re.compile(r"\bcurl\b[^|]*?[?&](access_token|token|api_?key|key|secret)=", re.I), "curl with a secret in the URL"),
    (re.compile(r"\bsecurity\b[^|]*add-generic-password\b[^|]*\s-w\s+\S"), "security add-generic-password -w <value> (the keychain item goes through `security -i`)"),
    (re.compile(r"(^|[;&|(\s])set\s+-[a-zA-Z]*x|set\s+-o\s+xtrace|\bbash\s+-[a-zA-Z]*x\b|\bsh\s+-[a-zA-Z]*x\b"), "shell tracing (set -x) prints expanded secrets"),
]


def default_files():
    pats = ["deploys", "lib/*.sh", "providers/*.sh", "build.sh", "release.sh", "scripts/*.sh",
            "integrations/*/*.sh", "integrations/lib/*.sh", "integrations/claude-code/scripts/*.sh",
            "integrations/hooks/pre-push", "site/install.sh"]
    out = []
    for p in pats:
        out += sorted(glob.glob(os.path.join(ROOT, p)))
    return out


def scan(path):
    bad = []
    heredoc = None
    with open(path, encoding="utf-8", errors="replace") as f:
        for n, raw in enumerate(f, 1):
            line = raw.rstrip("\n")
            if heredoc:
                if line.strip() == heredoc:
                    heredoc = None
                continue
            m = re.search(r"<<-?\s*(['\"]?)([A-Za-z_][A-Za-z0-9_]*)\1", line)
            if m and "<<<" not in line:
                heredoc = m.group(2)
            if line.lstrip().startswith("#") or "secrets-ok" in line:
                continue
            for rx, why in RULES:
                if rx.search(line):
                    bad.append((n, why, line.strip()))
                    break
    return bad


def main(argv):
    files = argv or default_files()
    bad = 0
    for p in files:
        for n, why, text in scan(p):
            print("check-secrets: %s:%d: %s: %s" % (os.path.relpath(p, ROOT), n, why, text[:100]), file=sys.stderr)
            bad += 1
    if bad:
        return 1
    print("check-secrets: ok (%d files)" % len(files))
    return 0


if __name__ == "__main__":
    sys.exit(main(sys.argv[1:]))
