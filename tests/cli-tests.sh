# shellcheck shell=bash
# Sourced by tests/script-tests.sh at its end: the e2e stand-ins (run, fresh, $e2e, $O, $E) and
# expect/ok/fail come from there. The tests themselves are one file per topic in tests/cli/, run in this order
# (they share the shell and the e2e state, so the order matters). Fixes from docs/IDEEN-6.md, section 3, by number.

# shellcheck source=cli/deploy-verify-args.sh
. tests/cli/deploy-verify-args.sh
# shellcheck source=cli/keychain-names-journal.sh
. tests/cli/keychain-names-journal.sh
# shellcheck source=cli/deploy-json-gitlab.sh
. tests/cli/deploy-json-gitlab.sh
# shellcheck source=cli/round6-open-points.sh
. tests/cli/round6-open-points.sh
# shellcheck source=cli/wave3-observer-help.sh
. tests/cli/wave3-observer-help.sh
# shellcheck source=cli/watch-hooks-tokens.sh
. tests/cli/watch-hooks-tokens.sh
# shellcheck source=cli/retry-timeout-journal.sh
. tests/cli/retry-timeout-journal.sh
