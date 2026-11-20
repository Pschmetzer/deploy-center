## What and why

<!-- One or two sentences. Link the issue if there is one. -->

## AI help

- [ ] Parts of this were written with an AI tool (Claude, Copilot, ...). Which parts, and did you read and run them yourself?

## Screenshots

<!-- A change to the app, the iPhone app or the website: before and after, taken in demo mode. Write "none" for anything else. -->

## Checks

- [ ] The tests pass: `bash tests/all.sh` (every suite; `--list` shows them, `--only <name>` runs one; CI runs the same, see `tests/suites.txt`)
- [ ] Integrations touched: `npm test` passes in the one you changed (`integrations/vscode`, `integrations/raycast`, `integrations/mcp`); iPhone app: `ios/test.sh` and `ios/Tests/run.sh`
- [ ] `scripts/lint.sh` passes (shellcheck, actionlint, `scripts/check-public.sh`, `scripts/check-size.sh`)
- [ ] `./build.sh` builds
- [ ] `CHANGELOG.md` has a line under Unreleased (or the PR has the label `no-changelog`)
- [ ] Docs changed with the behaviour; a change to `README.md`, `docs/NUMBERS.md` or `docs/SAVINGS.md` also goes into its German twin
- [ ] New texts have English and German (`L("English", "Deutsch")`)
- [ ] Nothing starts a build without an explicit click or a command with `--yes`
- [ ] No real project names, team IDs, domains or personal paths (the repo is public)
- [ ] Screenshots, if any, are taken in demo mode
- [ ] iPhone app or widgets touched: tried with a large Dynamic Type size and VoiceOver, light and dark
