## What and why

<!-- One or two sentences. Link the issue if there is one. -->

## Checks

- [ ] `bash tests/script-tests.sh`, `bash tests/team-tests.sh` and `bash tests/app-tests.sh` pass
- [ ] Integrations touched: `bash integrations/tests/run.sh` and `npm test` in `integrations/vscode` pass
- [ ] `scripts/check-public.sh` passes
- [ ] `./build.sh` builds
- [ ] New texts have English and German (`L("English", "Deutsch")`)
- [ ] Nothing starts a build without an explicit click or a command with `--yes`
- [ ] No real project names, team IDs, domains or personal paths (the repo is public)
- [ ] Screenshots, if any, are taken in demo mode
