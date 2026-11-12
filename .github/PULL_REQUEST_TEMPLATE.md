## What and why

<!-- One or two sentences. Link the issue if there is one. -->

## Checks

- [ ] The tests CI runs pass: `bash tests/script-tests.sh`, `tests/team-tests.sh`, `tests/install-tests.sh`,
      `tests/release-tests.sh`, `tests/app-tests.sh`, `integrations/tests/run.sh` (see `.github/workflows/ci.yml`)
- [ ] `shellcheck --severity=warning` is clean for changed shell scripts, and `scripts/check-public.sh` passes
- [ ] `./build.sh` builds
- [ ] `CHANGELOG.md` has a line under Unreleased (or the PR has the label `no-changelog`)
- [ ] Docs changed with the behaviour; a change to `README.md`, `docs/NUMBERS.md` or `docs/SAVINGS.md` also goes into its German twin
- [ ] New texts have English and German (`L("English", "Deutsch")`)
- [ ] Nothing starts a build without an explicit click or a command with `--yes`
- [ ] No real project names, team IDs, domains or personal paths (the repo is public)
- [ ] Screenshots, if any, are taken in demo mode
