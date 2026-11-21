#!/bin/bash
# The lint steps of CI in one command: shellcheck, actionlint, the checks for personal
# data and file sizes, and plutil on the example LaunchAgents.
#   scripts/lint.sh              everything that is installed here (a missing tool is named, not a failure)
#   scripts/lint.sh shellcheck   only shellcheck (what the lint job in CI runs)
set -uo pipefail
cd "$(dirname "$0")/.." || exit 1
only="${1:-}"
bad=0
step() { echo "== $1"; }
run() { "$@" || bad=1; }
# A missing tool is skipped on a Mac or laptop and fails in CI ($CI is set there): green with nothing checked is no check.
have() {
  command -v "$1" >/dev/null 2>&1 && return 0
  if [ -n "${CI:-}" ]; then echo "   $1 is not installed (and this is CI)"; bad=1; else echo "   $1 is not installed; skipped"; fi
  return 1
}

if [ -z "$only" ] || [ "$only" = shellcheck ]; then
  step shellcheck
  if have shellcheck; then
    # (a .shellcheckrc cannot set the severity, so it is spelled out here and in ci.yml)
    run shellcheck --severity=warning deploys providers/*.sh build.sh release.sh scripts/*.sh tests/*.sh tests/lib/*.sh tests/providers/*.sh lib/*.sh
    run shellcheck --severity=warning integrations/*/*.sh integrations/lib/*.sh integrations/claude-code/scripts/*.sh integrations/hooks/pre-push integrations/tests/*.sh
    run shellcheck --severity=style site/install.sh   # all severities: the install script runs on every POSIX shell
  fi
fi
if [ -z "$only" ]; then
  step actionlint
  if have actionlint; then run actionlint .github/workflows/*.yml docs/deploy-on-label.yml examples/*.yml integrations/*/examples/*.yml; fi
  step "personal data and file sizes"
  run scripts/check-public.sh
  run scripts/check-size.sh
  step "bash 3.2 and shellcheck disables"
  run scripts/check-bash32.sh
  run scripts/check-disables.sh
  run python3 -I scripts/check-bash32.py
  run python3 -I scripts/check-secrets.py
  step plutil
  if have plutil; then run plutil -lint scripts/*.plist.example; fi
fi
[ "$bad" = 0 ] && echo "lint: ok"
exit "$bad"
